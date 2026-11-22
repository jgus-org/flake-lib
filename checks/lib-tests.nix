# Pure-Nix tests for library functions: they assert at evaluation, and the derivation records the pass.
{
  self,
  lib,
  nixpkgs,
  pkgs,
}:
{
  default-systems-tests =
    let
      failures = pkgs.lib.runTests (
        import ./default-systems.nix {
          inherit (lib)
            defaultLinuxSystems
            defaultSystems
            eachDefaultLinuxSystem
            eachDefaultSystem
            eachSystem
            ;
        }
      );
    in
    pkgs.lib.throwIf (failures != [ ]) "defaultSystems tests failed" (
      pkgs.runCommand "default-systems-tests" { } "touch $out"
    );

  eval-marker-tree-tests =
    let
      failures = pkgs.lib.runTests (import ./eval-marker-tree.nix { inherit (lib) evalMarkerTree; });
    in
    pkgs.lib.throwIf (failures != [ ]) "evalMarkerTree tests failed" (
      pkgs.runCommand "eval-marker-tree-tests" { } "touch $out"
    );

  oci-image-tests = import ./oci-image.nix { inherit lib pkgs; };

  pnpm-deps-tests =
    let
      failures = pkgs.lib.runTests (
        import ./pnpm-deps.nix {
          inherit lib pkgs;
          inherit (lib) mkPnpmDeps;
        }
      );
    in
    pkgs.lib.throwIf (failures != [ ]) "mkPnpmDeps tests failed" (
      pkgs.runCommand "pnpm-deps-tests" { } "touch $out"
    );

  pnpm-toolchain-tests =
    let
      failures = pkgs.lib.runTests (
        import ./pnpm-toolchain.nix {
          inherit lib pkgs;
          inherit (lib) mkPnpmDeps;
        }
      );
    in
    pkgs.lib.throwIf (failures != [ ]) "pnpmToolchain tests failed" (
      pkgs.runCommand "pnpm-toolchain-tests" { } "touch $out"
    );

  python-flake-tests =
    let
      failures = pkgs.lib.runTests (
        import ./python-flake.nix {
          inherit
            nixpkgs
            pkgs
            self
            ;
          inherit (lib)
            mkPythonApplication
            mkPythonFlake
            readPythonRequirements
            ;
        }
      );
    in
    pkgs.lib.throwIf (failures != [ ]) "mkPythonFlake tests failed" (
      pkgs.runCommand "python-flake-tests" { } "touch $out"
    );

  version-matches-comparison-tests =
    let
      failures = pkgs.lib.runTests (
        import ./version-matches-comparison.nix { inherit (lib) versionMatchesComparison; }
      );
    in
    pkgs.lib.throwIf (failures != [ ]) "versionMatchesComparison tests failed" (
      pkgs.runCommand "version-matches-comparison-tests" { } "touch $out"
    );
}
