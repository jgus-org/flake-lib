# Assembles a python producer flake's outputs from what it publishes and the upstream it tracks.
{
  eachDefaultSystem,
  eachSystem,
  mkFormatting,
  mkUpdateBranches,
  mkUpdateVersion,
  pinnedSource,
  pythonBuilders,
}:
{
  self,
  branchOwnedFiles ? null,
  branches ? true,
  excludes ? [ ],
  gate ? { },
  nixpkgs,
  overlays ? [ ],
  payload,
  siblingRefsInPin ? false,
  siblings ? [ ],
  systems ? null,
  updateBranches ? { },
  updateVersion ? { },
  upstream ? null,
}:
let
  inherit (nixpkgs.lib) genAttrs optionalAttrs;
  inherit (builtins)
    attrNames
    elem
    filter
    head
    length
    ;

  each = if systems == null then eachDefaultSystem else eachSystem systems;

  # `upstream` is the source shape the updaters write plus the pin the build reads: pypi, or a github/gitlab repository by revision.
  source = if upstream == null then { } else builtins.removeAttrs upstream [ "pin" ];
  pin =
    if upstream == null then
      null
    else
      upstream.pin
        or (throw "mkPythonFlake: upstream is given without a pin, so the build has no pinned source to fetch");
  pinSchema = if (source.type or "pypi") == "pypi" then "pypi" else "github";

  packagesPayload = payload.packages or (_: { });
  overlaysPayload = payload.overlays or (_: { });

  # A payload states its publishables as a function of the set they land in, so the same payload serves the producer's own build and every consumer's tree.
  recordIn =
    pkgsFor: pythonSet:
    let
      pinned =
        if upstream == null then
          { }
        else
          pinnedSource {
            inherit pin source;
            pkgs = pkgsFor;
          };
    in
    {
      pkgs = pkgsFor;
      python = pythonSet;
    }
    // pythonBuilders {
      # Builders merge every pinned key into the recipe, so the eval-time path travels on the payload argument, not in the recipe's own attributes.
      pinned = builtins.removeAttrs pinned [ "sourcePath" ];
      python = pythonSet;
    }
    // optionalAttrs (upstream != null) {
      sourcePath =
        pinned.sourcePath
          or (throw "mkPythonFlake: a payload reads source files, but this pin's source has no eval-time path; only a github or gitlab pin carries one");
      src = pinned.src;
      version = pinned.version;
    };

  packagesIn = pkgsFor: packagesPayload (recordIn pkgsFor pkgsFor.python3.pkgs);

  ownOverlay =
    final: prev:
    packagesIn final
    // optionalAttrs (payload ? overlays) {
      pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
        # The set arrives as it stands after every earlier extension, so a bump reads what the consumer already has and the payload's return value replaces pieces of it.
        (_pyfinal: pyprev: overlaysPayload (recordIn final pyprev))
      ];
    };
in
{
  overlays.default = ownOverlay;
}
// each (
  system:
  let
    pkgs = import nixpkgs {
      inherit overlays system;
    };
    published = packagesIn pkgs;
    packageNames = attrNames published;
    overlayOnly = filter (name: !elem name packageNames) (
      attrNames (overlaysPayload (recordIn pkgs pkgs.python3.pkgs))
    );
    publishedNames = packageNames ++ overlayOnly;

    treeWith =
      config:
      import nixpkgs {
        inherit config system;
        overlays = overlays ++ [ ownOverlay ];
      };
    overlayTree = treeWith { };
    gateTree = if (gate.config or { }) == { } then overlayTree else treeWith gate.config;
    publishedAll = published // genAttrs overlayOnly (name: overlayTree.python3Packages.${name});
    checkOf =
      name: if elem name packageNames then gateTree.${name} else gateTree.python3Packages.${name};

    formatting = mkFormatting {
      inherit excludes self system;
    };
    # An artifact hook is a built executable, so one taken from the deployment's set arrives as a function of it.
    updaterArgs =
      updateVersion
      // optionalAttrs (builtins.isFunction (updateVersion.artifactHook or null)) {
        artifactHook = updateVersion.artifactHook { inherit pkgs; };
      };
    update-version = mkUpdateVersion (
      {
        inherit
          pkgs
          siblingRefsInPin
          siblings
          source
          ;
      }
      // updaterArgs
    );
    update-branches = mkUpdateBranches (
      {
        inherit pinSchema pkgs source;
      }
      // optionalAttrs (branchOwnedFiles != null) { inherit branchOwnedFiles; }
      // updateBranches
    );
  in
  {
    checks = genAttrs publishedNames checkOf // {
      formatting = formatting.check;
    };
    formatter = formatting.formatter;
    packages =
      publishedAll
      // optionalAttrs (length publishedNames == 1) {
        default = publishedAll.${head publishedNames};
      }
      // optionalAttrs (upstream != null) (
        { inherit update-version; } // optionalAttrs branches { inherit update-branches; }
      );
  }
)
