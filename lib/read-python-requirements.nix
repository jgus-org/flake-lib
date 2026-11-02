# The distribution names a requirements file asks for, in the shape a python package set names its members.
{ lib }:
requirementsFile:
let
  inherit (builtins)
    attrNames
    filter
    head
    listToAttrs
    match
    replaceStrings
    sort
    ;

  askedLines = filter (line: match "^[A-Za-z0-9].*" line != null) (
    lib.splitString "\n" (builtins.readFile requirementsFile)
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
