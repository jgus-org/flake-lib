# The gate: the scripts a producer tree builds and checks its published set with.
{ pkgs }:
{
  build-and-check-tests =
    pkgs.runCommand "build-and-check-tests"
      {
        BUILD_AND_CHECK = ../scripts/build-and-check.sh;
        nativeBuildInputs = [
          pkgs.bash
          pkgs.coreutils
          pkgs.gnugrep
        ];
      }
      ''
        bash ${./test_build_and_check.sh}
        touch $out
      '';

  # The selection is pure Nix handed to `nix eval --apply`, so it is tested as pure Nix: the assertions run when the flake is evaluated, not inside a builder that would have to nest nix inside itself.
  build-packages-select-tests =
    let
      failures = pkgs.lib.runTests (
        import ./build-packages-select.nix { select = import ../scripts/build-packages-select.nix; }
      );
    in
    pkgs.lib.throwIf (failures != [ ]) "build-packages selection tests failed" (
      pkgs.runCommand "build-packages-select-tests" { } "touch $out"
    );

  build-packages-tests =
    pkgs.runCommand "build-packages-tests"
      {
        BUILD_PACKAGES = ../scripts/build-packages.sh;
        BUILD_PACKAGES_SELECT = ../scripts/build-packages-select.nix;
        nativeBuildInputs = [
          pkgs.bash
          pkgs.coreutils
          pkgs.gnugrep
          pkgs.jq
        ];
      }
      ''
        bash ${./test_build_packages.sh}
        touch $out
      '';
}
