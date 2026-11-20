# Generates a flake-lib artifactHook that reads the pnpm major upstream declares at NEW_REV and prints it as one `name=value` line for mkUpdateVersion to capture into pin.nix.
#
#   field         : the pin field to write; defaults to pnpmMajor
#   manifestPath  : the package.json carrying `packageManager`, relative to the repository root. A monorepo names the workspace root that owns the lockfile its build reads.
#
# The pin states which major the lockfile was written for; the build selects the package set's release for that major. Upstream already expresses the constraint through `packageManager`, so the pin carries a major rather than a version and a tarball hash for a tool nothing vouches for.
#
# An unfilled pin field is written empty, so a manifest that declares nothing, or declares a package manager other than pnpm, ends the run rather than pinning nothing.
{
  field ? "pnpmMajor",
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
    name = "pnpm-declaration-hook";
    runtimeInputs = [
      pkgs.gh
      pkgs.jq
    ];
    text = ''
      declared="$(${ghFetch} | jq -r '.packageManager // ""')"
      case "''${declared}" in
        pnpm@*)
          # pnpm writes `pnpm@<version>+sha512.<digest>` where the digest is integrity metadata for the release, not part of the version.
          version="''${declared#pnpm@}"
          echo "${field}=''${version%%.*}"
          ;;
        "")
          echo "pnpm declaration hook: ${manifestPath} declares no packageManager, so there is no pnpm major to pin" >&2
          exit 1
          ;;
        *)
          echo "pnpm declaration hook: ${manifestPath} declares ''${declared}, which is not pnpm" >&2
          exit 1
          ;;
      esac
    '';
  }
)
