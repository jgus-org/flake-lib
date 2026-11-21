{
  description = "Shared library for jgus sub-flakes: the per-version-branch orchestrator, update-version machinery, artifact producers, and the install shapes they share.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    treefmt-nix = {
      inputs.nixpkgs.follows = "nixpkgs";
      url = "github:numtide/treefmt-nix";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      treefmt-nix,
    }:
    let
      lib = import ./lib {
        inherit nixpkgs treefmt-nix;
      };
    in
    {
      inherit lib;
    }
    // lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
        orgFormatting = lib.mkFormatting {
          inherit self system;
        };
      in
      {
        checks = import ./checks {
          inherit
            lib
            nixpkgs
            orgFormatting
            pkgs
            self
            system
            ;
        };
        formatter = orgFormatting.formatter;
        packages = {
          # The gate one tree has to pass, so that the pull-request template and the publication path run one definition rather than each naming the attribute it builds.
          build-and-check = pkgs.writeShellApplication {
            name = "build-and-check";
            runtimeEnv = {
              BUILD_PACKAGES_SCRIPT = pkgs.copyPathToStore ./scripts/build-packages.sh;
              BUILD_PACKAGES_SELECT = pkgs.copyPathToStore ./scripts/build-packages-select.nix;
            };
            text = ''exec ${./scripts/build-and-check.sh} "$@"'';
          };

          # A flake's published packages are what its consumers build, and `nix flake check` only evaluates them, so the build is a tool of its own. It reads what to build from the tree it runs in, as the refresher reads the tree it rewrites.
          build-packages = pkgs.writeShellApplication {
            name = "build-packages";
            runtimeEnv.BUILD_PACKAGES_SELECT = pkgs.copyPathToStore ./scripts/build-packages-select.nix;
            runtimeInputs = [ pkgs.jq ];
            text = ''exec ${./scripts/build-packages.sh} "$@"'';
          };

          # The tool every producer's workflow invokes by flake URL. Not a lib function: it takes no inputs from the caller, so a per-producer copy would be identical boilerplate that also pins the program to the caller's own locked revision.
          update-workflows = pkgs.writeShellApplication {
            name = "update-workflows";
            runtimeEnv.GIT_PUSH_LIB = pkgs.copyPathToStore ./scripts/git-push.sh;
            text = ''exec ${./scripts/update-workflows.sh} "$@"'';
          };

          # Ordering is observed from the consumer side, so like the refresher this takes nothing from the caller: its edges are the caller's own flake inputs, read from its lock.
          wait-for-deps = pkgs.writeShellApplication {
            name = "wait-for-deps";
            runtimeInputs = [ pkgs.python3 ];
            text = ''exec python3 ${./scripts/wait_for_deps.py} "$@"'';
          };

          workflow-templates = pkgs.runCommand "workflow-templates" { } ''
            cp --recursive ${./templates/workflows} "$out"
          '';
        };
      }
    );
}
