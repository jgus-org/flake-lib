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
      guarded = if (pinned.format or "") == "wheel" then forbidBuild recipe else recipe;
    in
    builder (({ doCheck = false; } // guarded) // pinned);
in
{
  buildApplication = stamp python.buildPythonApplication;
  buildPackage = stamp python.buildPythonPackage;
}
