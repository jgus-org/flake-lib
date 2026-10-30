# Assembles a leaf flake's per-system outputs (package, update machinery, formatter) from a source/package/pin spec.
{
  eachDefaultSystem,
  mkFormatting,
  mkSourcePackage,
  mkUpdateBranches,
  mkUpdateVersion,
}:
{
  self,
  branchOwnedFiles ? null,
  branches ? true,
  excludes ? [ ],
  extraChecks ? _: { },
  nixpkgs,
  overlays ? [ ],
  package,
  pin,
  siblingRefsInPin ? false,
  siblings ? [ ],
  source,
  updateBranches ? { },
  updateVersion ? { },
}:
eachDefaultSystem (
  system:
  let
    inherit (nixpkgs.lib) optionalAttrs;
    pkgs = import nixpkgs {
      inherit overlays system;
    };
    pkg = mkSourcePackage {
      inherit
        package
        pin
        pkgs
        source
        ;
    };
    pinSchema = if (source.type or "pypi") == "pypi" then "pypi" else "github";
    update-version = mkUpdateVersion (
      {
        inherit
          pkgs
          siblingRefsInPin
          siblings
          source
          ;
      }
      // updateVersion
    );
    update-branches = mkUpdateBranches (
      {
        inherit
          pinSchema
          pkgs
          source
          ;
      }
      // optionalAttrs (branchOwnedFiles != null) { inherit branchOwnedFiles; }
      // updateBranches
    );
    formatting = mkFormatting {
      inherit
        excludes
        self
        system
        ;
    };
  in
  {
    checks =
      (extraChecks {
        inherit pkgs system;
        package = pkg;
      })
      // {
        formatting = formatting.check;
      };
    formatter = formatting.formatter;
    packages = {
      inherit update-version;
      ${package.attr} = pkg;
      default = pkg;
    }
    // optionalAttrs branches { inherit update-branches; };
  }
)
