# Every documented example generator, built here so the shapes stay real without publishing tools no consumer invokes.
{
  exampleSource,
  lib,
  pkgs,
}:
let
  # The image tag is the OCI version, so a versioned spec names no tag.
  ociVersionedSource = {
    arch = "amd64";
    imageName = "registry.example/image";
    os = "linux";
    type = "oci";
    versions = {
      owner = "example";
      repo = "example";
      type = "github";
    };
  };

  examples = {
    update-branches-github-pnpm = lib.mkUpdateBranches {
      inherit pkgs;
      pinSchema = "github-pnpm";
      source = {
        owner = "example";
        repo = "example";
        type = "github";
      };
    };
    update-branches-oci-github = lib.mkUpdateBranches {
      inherit pkgs;
      pinSchema = "oci";
      source = ociVersionedSource;
    };
    update-branches-pypi-cargo = lib.mkUpdateBranches {
      inherit pkgs;
      extraHashes = [ "cargoHash" ];
      pinSchema = "pypi";
      source = exampleSource;
    };
    update-version-github = lib.mkUpdateVersion {
      inherit pkgs;
      extraHashes = [ "npmDepsHash" ];
      hashMode = "build-failure";
      source = {
        owner = "example";
        repo = "example";
        type = "github";
      };
    };
    update-version-github-commit = lib.mkUpdateVersion {
      inherit pkgs;
      source = {
        owner = "example";
        repo = "example";
        track = "commit";
        type = "github";
      };
    };
    update-version-github-pnpm = lib.mkUpdateVersion {
      inherit pkgs;
      buildFailureHash = "pnpmDepsHash";
      source = {
        owner = "example";
        repo = "example";
        type = "github";
      };
    };
    update-version-github-pnpm-go = lib.mkUpdateVersion {
      inherit pkgs;
      buildFailureHashes = [
        "pnpmDepsHash"
        "vendorHash"
      ];
      source = {
        owner = "example";
        repo = "example";
        type = "github";
      };
    };
    update-version-huggingface = lib.mkUpdateVersion {
      inherit pkgs;
      source = {
        files = [ "config.json" ];
        manifest = {
          exclude = [ "^\\." ];
          path = "model-manifest.json";
        };
        repo = "example/model";
        type = "huggingface";
      };
    };
    update-version-mutable-url = lib.mkUpdateVersion {
      inherit pkgs;
      source = {
        type = "mutable-url";
        url = "https://downloads.example.test/artifact.bin";
      };
    };
    update-version-oci = lib.mkUpdateVersion {
      inherit pkgs;
      source = {
        arch = "amd64";
        imageName = "registry.example/image";
        os = "linux";
        tag = "latest-sm86";
        type = "oci";
      };
    };
    update-version-oci-github = lib.mkUpdateVersion {
      inherit pkgs;
      source = ociVersionedSource;
    };
    update-version-pypi-cargo = lib.mkUpdateVersion {
      inherit pkgs;
      buildFailureHash = "cargoHash";
      source = exampleSource;
    };
  };
in
{
  update-examples = pkgs.runCommand "update-examples" { } ''
    ${builtins.concatStringsSep "\n" (
      map (drv: "test -x ${pkgs.lib.getExe drv}") (builtins.attrValues examples)
    )}
    touch $out
  '';
}
