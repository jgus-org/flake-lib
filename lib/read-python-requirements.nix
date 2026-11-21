# The distribution names a requirements file asks for, in the shape a python package set names its members.
with builtins;
{ lib }:
requirementsFile:
let
  askedLines = filter (line: match "^[A-Za-z0-9].*" line != null) (
    lib.splitString "\n" (readFile requirementsFile)
  );

  bareNames = map (line: head (match "^([^<>=!~;[ ]*).*" line)) askedLines;

  setNames = map (name: replaceStrings [ "." "_" ] [ "-" "-" ] (lib.toLower name)) bareNames;
in
sort (a: b: a < b) (
  attrNames (
    listToAttrs (
      map (name: {
        inherit name;
        value = true;
      }) setNames
    )
  )
)
