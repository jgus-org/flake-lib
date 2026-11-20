# Resolves the pnpm major a workspace declares against the package set, and adapts that workspace's manifest when the resolution is not the declared major.
#
# A workspace names its toolchain through `packageManager`, and pnpm honors that field by switching to the named release whenever it can reach one. A producer whose declared major the package set still carries builds with that major and reads the tree as upstream wrote it. A producer whose declared major the package set has retired cannot: the retired release is not something nixpkgs can supply, so the build runs a different major than the one that wrote the lockfile, and the manifest has to say so.
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

  declaredName = "pnpm_${toString declaredMajor}";
  newestMajor = lib.toInt (lib.versions.major pkgs.pnpm.version);

  substitution = lib.findFirst available null (
    map (major: "pnpm_${toString major}") (lib.range (lib.toInt declaredMajor + 1) newestMajor)
  );

  resolvedName =
    if declaredMajor == null then
      "pnpm"
    else if available declaredName then
      declaredName
    else if substitution != null then
      substitution
    else
      throw "pnpmToolchain: the package set carries no pnpm ${toString declaredMajor} and no major above it, so ${baseNameOf (toString src)} has no toolchain to build with.";

  pnpm = pkgs.${resolvedName};
  substituted = resolvedName != declaredName && declaredMajor != null;

  # The adapted tree keeps the name of the tree it replaces. A producer locates its workspace inside the unpacked source by that name, and `fetchPnpmDeps` unpacks the same way, so a new name would make the adaptation visible wherever the source is named.
  adapted =
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
in
{
  inherit pnpm substituted;

  # The tree the fetcher reads and the tree the build compiles have to be the same tree, so the adaptation is published here rather than left for each producer to reproduce.
  src = if substituted then adapted else src;
}
