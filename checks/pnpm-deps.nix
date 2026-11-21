# Pure tests for mkPnpmDeps: which store path a fetched dependency tree lands under is asserted at evaluation, and nothing is built.
{
  lib,
  mkPnpmDeps,
  pkgs,
}:
let
  # A second toolchain differing from the default only in its major, so the pair exercises the naming without nixpkgs having to carry two majors of pnpm.
  otherMajor = pkgs.pnpm.overrideAttrs {
    __intentionallyOverridingVersion = true;
    version = "99.0.0";
  };

  deps =
    toolchain:
    mkPnpmDeps {
      inherit pkgs;
      fetcherVersion = 4;
      hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
      pname = "pnpm-deps-test";
      pnpm = toolchain;
      src = ./fixtures/pnpm-deps/apps;
      version = "1.0.0";
    };

  default = deps pkgs.pnpm;
  other = deps otherMajor;
in
{
  # The hazard: a fixed-output path is keyed on name and declared hash alone, so without the major in the name one pnpm's fetched tree answers for another's and the second fetch never runs.
  testAnotherMajorGetsItsOwnStorePath = {
    expected = true;
    expr = default.outPath != other.outPath;
  };
  testOneToolchainIsRepeatable = {
    expected = true;
    expr = (deps pkgs.pnpm).outPath == default.outPath;
  };
  testStoreNameCarriesThePnpmMajor = {
    expected = true;
    expr = pkgs.lib.strings.hasInfix ("-pnpm${pkgs.lib.versions.major pkgs.pnpm.version}-pnpm-deps") (
      baseNameOf default.outPath
    );
  };
}
