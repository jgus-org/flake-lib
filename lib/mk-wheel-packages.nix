# Turns a producer's resolved wheel manifest into members of the deployment's own python set, so a pinned wheel is an ordinary python package rather than a second tree joined by PYTHONPATH.
{
  manifest,
  noEmit ? [ ],
  pkgs,
}:
let
  lib = pkgs.lib;

  # The manifest carries PEP 503 names; a consumer may spell a name any other way.
  canonical = name: lib.replaceStrings [ "_" "." ] [ "-" "-" ] (lib.toLower name);

  listed = builtins.isList noEmit;
  wanted = lib.unique (map canonical (if listed then noEmit else [ ]));
  wheels =
    if builtins.isList manifest then manifest else builtins.fromJSON (builtins.readFile manifest);
  names = map (wheel: canonical wheel.name) wheels;
  unmatched = lib.unique (lib.subtractLists names wanted);
  excluded = wheel: if listed then lib.elem (canonical wheel.name) wanted else noEmit wheel.name;
  selected = lib.filter (wheel: !excluded wheel) wheels;
  duplicates = lib.unique (lib.subtractLists (lib.unique names) names);

  # A wheel is installed rather than built: the artifact's own tags decide which
  # interpreter and libc it loads into, and the manifest names the artifact per target
  # because a platform-tagged wheel's URL path is a content hash.
  wheelPackage =
    wheel:
    pkgs.python3Packages.buildPythonPackage {
      format = "wheel";
      pname = wheel.name;
      src = pkgs.fetchurl {
        inherit (wheel) sha256 url;
        name = wheel.filename;
      };
      version = wheel.version;
    };
in
if duplicates != [ ] then
  throw "mkWheelPackages: the manifest names [${lib.concatStringsSep ", " duplicates}] more than once"
else
  lib.warnIf (listed && unmatched != [ ])
    "mkWheelPackages: noEmit names [${lib.concatStringsSep ", " unmatched}] match no wheel in the manifest; the exclusion had no effect."
    (
      lib.listToAttrs (
        map (wheel: {
          name = canonical wheel.name;
          value = wheelPackage wheel;
        }) selected
      )
    )
