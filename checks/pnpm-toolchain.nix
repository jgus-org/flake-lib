# Pure tests for the toolchain a pnpm dependency fetch is resolved to: which major answers a declaration, and which tree the fetcher and the build are then handed. Nothing is built, and the package set is a fixture, so no test here depends on which pnpm majors nixpkgs happens to carry. The manifest edits themselves are behavior and belong to `pnpm-adaptation.nix`, which runs them.
{
  lib,
  mkPnpmDeps,
  pkgs,
}:
let
  # The fetcher is replaced by its own arguments, so every assertion reads what the fetch was actually asked to do.
  pkgs' = pkgs // {
    fetchPnpmDeps = args: args;
    pnpm.version = "12.9.0";
    pnpm_10.version = "10.34.7";
    pnpm_11.version = "11.27.0";
    pnpm_8 = throw "'pnpm_8' was removed because it reached EOL";
    pnpm_9 = throw "'pnpm_9' was removed because it reached EOL";
    runCommand = name: env: script: {
      inherit env name script;
      drvPath = "/nix/store/fake.drv";
      outPath = "/nix/store/fake";
      targetVersion = env.targetVersion;
    };
  };

  # A producer locates its workspace by the source's name, so the adapted tree has to keep it.
  src = {
    drvPath = "/nix/store/fake-source.drv";
    name = "kandev-web-src";
    outPath = "/nix/store/fake-source";
    type = "path";
  };

  deps =
    pnpmMajor:
    (mkPnpmDeps {
      inherit pname pnpmMajor src;
      fetcherVersion = 4;
      hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
      pkgs = pkgs';
      version = "1.0.0";
    });

  pname = "pnpm-toolchain-test";
  kept = deps "11";
  skipped = deps "8";
  substituted = deps "9";
in
{
  # Two declarations resolving to different majors must not share a store path, and a fixed-output path is keyed on name and hash alone.
  testDeclarationsThatResolveApartGetDistinctFetchNames = {
    expected = true;
    expr = kept.pname != substituted.pname;
  };
  # The name is what makes the resolved toolchain legible, so it carries the major that runs rather than the one upstream asked for, and it carries the fetcher version the hash was generated against.
  testFetchNameCarriesTheResolvedMajor = {
    expected = true;
    expr =
      pkgs.lib.strings.hasSuffix "-pnpm11-fetcher4" kept.pname
      && pkgs.lib.strings.hasSuffix "-pnpm10-fetcher4" substituted.pname;
  };
  # The adapted tree is handed to the fetcher and to the build, and it keeps the name of the tree it replaces, because that name is where a producer locates its workspace.
  testFetcherAndBuildAreHandedTheAdaptedTree = {
    expected = true;
    expr =
      substituted.src == substituted.passthru.pnpmToolchain.src
      && substituted.src != src
      && substituted.src.name == src.name;
  };
  # The resolution is published for the producer's build inputs, so the tree and the tool that installs it are resolved once and by nobody else.
  testFetcherAndBuildResolveOneToolchain = {
    expected = true;
    expr = kept.src == kept.passthru.pnpmToolchain.src && kept.pnpm == kept.passthru.pnpmToolchain.pnpm;
  };
  # A major nixpkgs has retired cannot be supplied, and reaching past the package set for it fails rather than resolving to a major nobody declared.
  testMajorAbsentFromThePackageSetIsAFailure = {
    expected = false;
    expr = (builtins.tryEval (deps "13").pname).success;
  };
  # The nearest available major above the declaration, not the newest one: the newest moves whenever nixpkgs publishes a major and would re-resolve every substituted producer with it.
  testNearestMajorAboveTheDeclarationIsSubstituted = {
    expected = true;
    expr = substituted.pnpm.version == "10.34.7" && skipped.pnpm.version == "10.34.7";
  };
  # One toolchain source per call: a producer naming both a package and a declaration leaves the resolution ambiguous.
  testPnpmAndDeclaredMajorAreMutuallyExclusive = {
    expected = false;
    expr =
      (builtins.tryEval
        (mkPnpmDeps {
          inherit pname src;
          fetcherVersion = 4;
          hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
          pkgs = pkgs';
          pnpm = pkgs'.pnpm_10;
          pnpmMajor = "11";
          version = "1.0.0";
        }).pname
      ).success;
  };
  # A declaration the package set can honor resolves to the major it names, and the tree it is handed names the release that runs rather than one a sandbox cannot reach.
  testResolvedToolchainIsNamedByTheTreeItIsHanded = {
    expected = true;
    expr = kept.pnpm.version == "11.27.0" && kept.src.targetVersion == "11.27.0";
  };
}
