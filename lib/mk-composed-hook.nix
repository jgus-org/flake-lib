# Composes several flake-lib artifactHooks into one executable usable in a single `artifactHook` slot.
{
  hooks,
  pkgs,
}:
pkgs.lib.getExe (
  pkgs.writeShellApplication {
    name = "composed-hook";
    text = pkgs.lib.concatMapStringsSep "\n" (h: ''"${h}"'') hooks;
  }
)
