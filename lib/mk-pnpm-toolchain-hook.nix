# Generates a flake-lib artifactHook that reads upstream's declared pnpm version at NEW_REV and prints the nixpkgs attribute that satisfies it, as one `name=value` line for mkUpdateVersion to capture into pin.nix.
#
#   field         : the pin field to write; defaults to pnpmPackage
#   manifestPath  : the package.json carrying `packageManager`, relative to the repository root. A monorepo names the workspace root that owns the lockfile its build reads.
#
# Upstream expresses the toolchain constraint through `packageManager`, so the pin names a nixpkgs attribute instead of a version and a tarball hash, and the derivation selects `pkgs.${pin.pnpmPackage}`. Where upstream declares no package manager, the top-level attribute is the selection and nothing is pinned.
{
  field ? "pnpmPackage",
  manifestPath ? "package.json",
  pkgs,
}:
let
  inherit (pkgs) lib;
  # raw media type, not the JSON `.content` field: the latter is base64 and capped at 1 MB by the Contents API.
  ghFetch = ''gh api "/repos/''${GH_OWNER}/''${GH_REPO}/contents/${manifestPath}?ref=''${NEW_REV}" -H "Accept: application/vnd.github.raw"'';
in
lib.getExe (
  pkgs.writeShellApplication {
    name = "pnpm-toolchain-hook";
    runtimeInputs = [
      pkgs.gh
      pkgs.jq
    ];
    text = ''
      declared="$(${ghFetch} | jq -r '.packageManager // ""')"
      case "''${declared}" in
        "") attr="pnpm" ;;
        pnpm@*)
          # pnpm writes `pnpm@<version>+sha512.<digest>` where the digest is integrity metadata for the release, not part of the version.
          version="''${declared#pnpm@}"
          attr="pnpm_''${version%%.*}"
          ;;
        *)
          echo "pnpm toolchain hook: ${manifestPath} declares ''${declared}, which is not pnpm" >&2
          exit 1
          ;;
      esac
      echo "${field}=''${attr}"
    '';
  }
)
