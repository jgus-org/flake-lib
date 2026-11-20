with builtins;
{ nixpkgs, treefmt-nix }:
let
  systems = import ./default-systems.nix;
  mkUpdateVersion = import ./mk-update-version.nix;
  mkUpdateBranches = import ./mk-update-branches.nix;
  versionMatchesComparison = import ./version-matches-comparison.nix;
  formatting = import ./mk-formatting.nix {
    inherit nixpkgs treefmt-nix;
  };
  mkPythonFlake = import ./mk-python-flake.nix {
    inherit
      mkUpdateBranches
      mkUpdateVersion
      ;
    inherit (systems) eachDefaultSystem eachSystem;
    inherit (formatting) mkFormatting;
    pinnedSource = import ./pinned-source.nix;
    pythonBuilders = import ./python-builders.nix;
  };

  warnIfNewerMajor =
    {
      lib ? pkgs.lib,
      name,
      pkgs,
    }:
    let
      parts = match "([^0-9]*)([0-9]+)(.*)" name;
      prefix = elemAt parts 0;
      current = lib.toInt (elemAt parts 1);
      suffix = elemAt parts 2;
      majorOf =
        n:
        let
          m = match "${prefix}([0-9]+)${suffix}" n;
        in
        if m == null then null else lib.toInt (head m);
      newest = foldl' (a: b: if b > a then b else a) current (
        filter (x: x != null) (map majorOf (attrNames pkgs))
      );
    in
    lib.warnIf (newest > current)
      "warnIfNewerMajor: ${name} is pinned, but nixpkgs has ${prefix}${toString newest}${suffix}."
      pkgs.${name};
in
{
  inherit
    mkPythonFlake
    mkUpdateBranches
    mkUpdateVersion
    versionMatchesComparison
    warnIfNewerMajor
    ;
  inherit (systems)
    defaultLinuxSystems
    defaultSystems
    eachDefaultLinuxSystem
    eachDefaultSystem
    eachSystem
    ;
  inherit (formatting) mkFormatting;
  depsCore = ../scripts/deps_core.py;
  evalMarkerTree = import ./eval-marker-tree.nix { inherit versionMatchesComparison; };
  mkComposedHook = import ./mk-composed-hook.nix;
  mkHuggingFaceModelManager = import ./mk-huggingface-model-manager.nix;
  mkJsDepsHook = import ./mk-js-deps-hook.nix;
  mkOciImage = import ./mk-oci-image.nix;
  mkPnpmDeclarationHook = import ./mk-pnpm-declaration-hook.nix;
  mkPythonApplication = import ./mk-python-application.nix;
  mkRevalidateHash = import ./mk-revalidate-hash.nix;
  pythonDualStackIPv6 = import ./python-dual-stack-ipv6.nix;
  readPythonRequirements = import ./read-python-requirements.nix { inherit (nixpkgs) lib; };
}
