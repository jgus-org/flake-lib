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
    {
      sourceFingerprint ? null,
      toolchain ? pkgs.pnpm,
    }:
    mkPnpmDeps {
      inherit pkgs sourceFingerprint;
      fetcherVersion = 4;
      hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
      pname = "pnpm-deps-test";
      pnpm = toolchain;
      src = ./fixtures/pnpm-deps/apps;
      version = "1.0.0";
    };

  default = deps { };
  other = deps { toolchain = otherMajor; };

  # Chosen for the `/` and `=` a store path name cannot carry, so the name also proves the fingerprint reached it in a usable spelling.
  fingerprint = "sha256-RblR6SOFYZoGzVFU/c6+7JnqT8bs3P6Uh8xm+N7/pc8=";
  fingerprintInName = "RblR6SOFYZoGzVFU-c6+7JnqT8bs3P6Uh8xm+N7-pc8-";
  named = deps {
    sourceFingerprint = fingerprint;
  };
  moved = deps {
    sourceFingerprint = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
  };
in
{
  # The updater's build-failure hash refresh needs the fetch to run at a bump, and it runs only when the declared name and hash resolve to a path the store has not seen.
  testAChangedSourceFingerprintGetsItsOwnStorePath = {
    expected = true;
    expr = named.outPath != default.outPath && moved.outPath != named.outPath;
  };
  # The hazard: a fixed-output path is keyed on name and declared hash alone, so without the major in the name one pnpm's fetched tree answers for another's and the second fetch never runs.
  testAnotherMajorGetsItsOwnStorePath = {
    expected = true;
    expr = default.outPath != other.outPath;
  };
  testOneToolchainIsRepeatable = {
    expected = true;
    expr = (deps { }).outPath == default.outPath;
  };
  testSourceFingerprintIsDeclaredNotAssumed = {
    expected = true;
    expr = !(pkgs.lib.strings.hasInfix "sha256-" (baseNameOf default.outPath));
  };
  testStoreNameCarriesThePnpmMajor = {
    expected = true;
    expr = pkgs.lib.strings.hasInfix ("-pnpm${pkgs.lib.versions.major pkgs.pnpm.version}-pnpm-deps") (
      baseNameOf default.outPath
    );
  };
  testStoreNameCarriesTheSourceFingerprint = {
    expected = true;
    expr = pkgs.lib.strings.hasInfix fingerprintInName (baseNameOf named.outPath);
  };
}
