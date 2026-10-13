# Assembles a leaf flake's per-system outputs (package, update-version, optional update-branches) from a source/package/pin spec.
{ mkPypiPackage, mkUpdateVersion, mkUpdateBranches }:
{ nixpkgs
, flake-utils
, source
, package
, pin
, branches ? true
, siblings ? [ ]
, siblingRefsInPin ? false
, verification ? "evaluate"
, branchOwnedFiles ? [
    "pin.nix"
    "flake.lock"
    "requirements.in"
    "requirements-*.lock"
    "wheels-*.json"
    "python-readiness.json"
  ]
}:
flake-utils.lib.eachDefaultSystem (system:
  let
    pkgs = import nixpkgs { inherit system; };
    pkg = mkPypiPackage { inherit pkgs source package pin; };
    pinSchema = if source.type == "pypi" then "pypi" else "github";
    update-version = mkUpdateVersion { inherit pkgs source siblings siblingRefsInPin verification; buildAttr = package.attr; };
    update-branches = mkUpdateBranches { inherit pkgs source pinSchema branchOwnedFiles; };
  in
  {
    packages =
      {
        ${package.attr} = pkg;
        default = pkg;
        inherit update-version;
      }
      // pkgs.lib.optionalAttrs branches { inherit update-branches; };
  })
