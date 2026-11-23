# Resolves the pnpm major a workspace declares against the package set, and hands back a tree whose manifest names the release that runs.
#
# A workspace names its toolchain through `packageManager`, and pnpm honors that field by switching to the named release whenever it can reach one. A build sandbox reaches no registry, so a tree naming a release other than the one it is handed dies inside `pnpmConfigHook`, which runs from `postConfigureHooks`. Correcting the declaration that late would leave the dependency fetch and the build reading different trees, so the manifest names what it is given, in the source both are handed. Where the resolution crossed into another major, the pnpm settings kept under `pnpm` in the manifest additionally move to the top level of `pnpm-workspace.yaml`, where a newer pnpm looks for them; within one major the rest of the tree is read as upstream wrote it, and a manifest that already names the release the package set supplies is handed back with its contents untouched.
#
# Which release the tree names is known only from the tree, so the decision is made in the builder rather than at evaluation. The whole tree is copied, and the copy preserves symlinks, which a workspace's own `node_modules`-shaped layout and a `fetchFromGitHub` tree both contain.
#
# A retired major keeps its attribute in the package set and throws when forced, and a major never published throws at the selection itself, which `tryEval` does not catch. Both cases are therefore tested before one is chosen.
#
#   declaredMajor : the pnpm major upstream declares at the revision the pin resolved to, as `mkPnpmDeclarationHook` records it. With none, the package set's default is taken and the tree is handed back untouched.
#   workspaceDir  : the workspace whose manifest is adapted, relative to `src`, for an upstream repository that keeps its app in a subdirectory.
#
# The nearest major above the declaration is substituted rather than the newest available: the lockfile was written one release line away rather than as far away as the package set permits, and the newest major moves again every time nixpkgs publishes one, which would re-resolve every substituted producer with it.
{
  declaredMajor ? null,
  pkgs,
  src,
  workspaceDir ? null,
}:
let
  inherit (pkgs) lib;

  available = name: builtins.hasAttr name pkgs && (builtins.tryEval pkgs.${name}.version).success;

  pnpm =
    let
      declaredName = "pnpm_${toString declaredMajor}";

      substitution = lib.findFirst available null (
        map (major: "pnpm_${toString major}") (
          lib.range (lib.toInt declaredMajor + 1) (lib.toInt (lib.versions.major pkgs.pnpm.version))
        )
      );
    in
    if declaredMajor == null then
      pkgs.pnpm
    else if available declaredName then
      pkgs.${declaredName}
    else if substitution != null then
      pkgs.${substitution}
    else
      throw "pnpmToolchain: the package set carries no pnpm ${toString declaredMajor} and no major above it, so ${baseNameOf (toString src)} has no toolchain to build with.";
in
{
  inherit pnpm;

  # The tree the fetcher reads and the tree the build compiles have to be the same tree, so the adaptation is published here rather than left for each producer to reproduce. The adapted tree keeps the name of the tree it replaces, because a producer locates its workspace inside the unpacked source by that name and `fetchPnpmDeps` unpacks the same way, so a new name would make the adaptation visible wherever the source is named.
  src =
    pkgs.runCommand (if lib.isPath src then baseNameOf (toString src) else src.name)
      {
        dontFixup = true;
        nativeBuildInputs = [ pkgs.jq ];
        targetVersion = pnpm.version;
        workspaceDir = if workspaceDir == null then "" else workspaceDir;
      }
      ''
        cp -r ${src} $out
        chmod -R u+w $out
        cd $out
        bash ${./adapt-workspace.sh}
      '';
}
