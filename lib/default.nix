{ nixpkgs, treefmt-nix }:
let
  inherit (import ./default-systems.nix)
    defaultLinuxSystems
    defaultSystems
    eachDefaultLinuxSystem
    eachDefaultSystem
    eachSystem
    ;
  mkSourcePackage = import ./mk-source-package.nix;
  # The name this builder shipped under before it fetched GitHub trees too; the v1
  # family may not move an interface out from under a consumer.
  mkPypiPackage = mkSourcePackage;
  mkUpdateVersion = import ./mk-update-version.nix;
  mkUpdateBranches = import ./mk-update-branches.nix;
  mkRevalidateHash = import ./mk-revalidate-hash.nix;
  mkJsDepsHook = import ./mk-js-deps-hook.nix;
  mkComposedHook = import ./mk-composed-hook.nix;
  mkHuggingFaceModelManager = import ./mk-huggingface-model-manager.nix;
  mkOciImage = import ./mk-oci-image.nix;
  versionMatchesComparison = import ./version-matches-comparison.nix;
  evalMarkerTree = import ./eval-marker-tree.nix { inherit versionMatchesComparison; };
  mkLeafFlake = import ./mk-leaf-flake.nix {
    inherit
      eachDefaultSystem
      mkSourcePackage
      mkUpdateBranches
      mkUpdateVersion
      ;
  };
  pythonWheelhouse = import ./python-wheelhouse.nix;
  formatting = import ./mk-formatting.nix {
    inherit nixpkgs treefmt-nix;
  };
  depsCore = ../scripts/deps_core.py;

  warnIfNewerMajor =
    {
      lib ? pkgs.lib,
      name,
      pkgs,
    }:
    let
      parts = builtins.match "([^0-9]*)([0-9]+)(.*)" name;
      prefix = builtins.elemAt parts 0;
      current = lib.toInt (builtins.elemAt parts 1);
      suffix = builtins.elemAt parts 2;
      majorOf =
        n:
        let
          m = builtins.match "${prefix}([0-9]+)${suffix}" n;
        in
        if m == null then null else lib.toInt (builtins.head m);
      newest = builtins.foldl' (a: b: if b > a then b else a) current (
        builtins.filter (x: x != null) (map majorOf (builtins.attrNames pkgs))
      );
    in
    lib.warnIf (newest > current)
      "warnIfNewerMajor: ${name} is pinned, but nixpkgs has ${prefix}${toString newest}${suffix}. Consider migrating."
      pkgs.${name};
in
{
  inherit
    defaultLinuxSystems
    defaultSystems
    depsCore
    eachDefaultLinuxSystem
    eachDefaultSystem
    eachSystem
    evalMarkerTree
    mkComposedHook
    mkHuggingFaceModelManager
    mkJsDepsHook
    mkLeafFlake
    mkOciImage
    mkPypiPackage
    mkRevalidateHash
    mkSourcePackage
    mkUpdateBranches
    mkUpdateVersion
    versionMatchesComparison
    warnIfNewerMajor
    ;
  inherit (pythonWheelhouse)
    installWheelhouse
    mkPythonWheelhouse
    mkWheelhouse
    mkWheelhouseSiteTree
    platformTags
    pythonEnvironments
    wheelhouseArtifactPaths
    ;
  inherit (formatting) mkFormatting;
}
