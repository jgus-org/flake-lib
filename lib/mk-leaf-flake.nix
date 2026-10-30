# Assembles a leaf flake's per-system outputs (package, update-version, optional update-branches) from a source/package/pin spec.
{
  eachDefaultSystem,
  mkSourcePackage,
  mkUpdateBranches,
  mkUpdateVersion,
}:
{
  branchOwnedFiles ? [
    "pin.nix"
    "flake.lock"
    "requirements.in"
    "requirements-*.lock"
    "wheels-*.json"
    "python-readiness.json"
  ],
  branches ? true,
  nixpkgs,
  package,
  pin,
  siblingRefsInPin ? false,
  siblings ? [ ],
  source,
}:
eachDefaultSystem (
  system:
  let
    pkgs = import nixpkgs { inherit system; };
    pkg = mkSourcePackage {
      inherit
        package
        pin
        pkgs
        source
        ;
    };
    pinSchema = if source.type == "pypi" then "pypi" else "github";
    update-version = mkUpdateVersion {
      inherit
        pkgs
        siblingRefsInPin
        siblings
        source
        ;
    };
    update-branches = mkUpdateBranches {
      inherit
        branchOwnedFiles
        pinSchema
        pkgs
        source
        ;
    };
  in
  {
    packages = {
      inherit update-version;
      ${package.attr} = pkg;
      default = pkg;
    }
    // pkgs.lib.optionalAttrs branches { inherit update-branches; };
  }
)
