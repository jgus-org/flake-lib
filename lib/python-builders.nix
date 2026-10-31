# Builds an ordinary buildPythonPackage recipe against the pinned source, adding the fleet's test default and the rule that an installed wheel has no build.
{
  pinned ? { },
  python,
}:
let
  # A wheel is unpacked into site-packages, so nothing in the recipe that describes a build reaches the derivation.
  buildKeys = [
    "build-system"
    "pyproject"
  ];

  forbidBuild =
    recipe:
    let
      named = builtins.filter (key: recipe ? ${key}) buildKeys;
    in
    if named == [ ] then
      recipe
    else
      throw "mkPythonFlake: recipe '${recipe.pname or "?"}' names ${builtins.toString named} for a wheel source, and a wheel is installed rather than built, so a build never reaches the derivation";

  stamp =
    builder: recipe:
    let
      wheel = (pinned.format or "") == "wheel";
      guarded = if wheel then forbidBuild recipe else recipe;
      # nixpkgs refuses to guess how a recipe builds; a recipe that says nothing gets the fleet's answer, and one that says `format` keeps its own answer.
      statesItsBuild = builtins.any (key: guarded ? ${key}) (buildKeys ++ [ "format" ]);
      buildDefault =
        if wheel || statesItsBuild then
          { }
        else
          {
            build-system = [ python.setuptools ];
            pyproject = true;
          };
    in
    builder ((({ doCheck = false; } // buildDefault) // guarded) // pinned);
in
{
  buildApplication = stamp python.buildPythonApplication;
  buildPackage = stamp python.buildPythonPackage;
}
