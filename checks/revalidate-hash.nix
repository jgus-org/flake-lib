# The published revalidator's wrapper build, and the suite for the script it wraps.
{ lib, pkgs }:
let
  revalidate-hash = lib.mkRevalidateHash {
    inherit pkgs;
  };
in
{
  # The revalidator builds only through the step the package installs, so this suite needs no nix: the stub is the build.
  revalidate-hash-tests =
    pkgs.runCommand "revalidate-hash-tests"
      {
        REVALIDATE_BUILD_HASH = ../scripts/revalidate-build-hash.sh;
        nativeBuildInputs = [
          pkgs.bash
          pkgs.coreutils
          pkgs.gnugrep
          pkgs.gnused
        ];
      }
      ''
        # Nothing else in the suite runs the wrapper, so building it is covered here.
        test -x ${pkgs.lib.getExe revalidate-hash}
        bash ${./test_revalidate_build_hash.sh}
        touch $out
      '';
}
