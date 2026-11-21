# Builds an ordinary buildPythonPackage recipe against the pinned source, adding the fleet's test default and the rule that an installed wheel has no build.
with builtins;
{
  pinned ? { },
  python,
}:
let
  stamp =
    builder: recipe:
    let
      # A wheel is unpacked into site-packages, so nothing in the recipe that describes a build reaches the derivation.
      buildKeys = [
        "build-system"
        "pyproject"
      ];
      named = filter (key: recipe ? ${key}) buildKeys;
      wheel = (pinned.format or "") == "wheel";
      guarded =
        if !wheel || named == [ ] then
          recipe
        else
          throw "mkPythonFlake: recipe '${recipe.pname or "?"}' names ${toString named} for a wheel source, and a wheel is installed rather than built, so a build never reaches the derivation";
      # nixpkgs refuses to guess how a recipe builds. A recipe that says nothing gets the fleet's answer, and one that says `format` keeps its own answer.
      statesItsBuild = any (key: guarded ? ${key}) (buildKeys ++ [ "format" ]);
      buildDefault =
        if wheel || statesItsBuild then
          { }
        else
          {
            build-system = [ python.setuptools ];
            pyproject = true;
          };
      # nixpkgs runs pythonImportsCheck in installCheck and derives doInstallCheck from doCheck, so stamping the fleet's test default would void that check. nixpkgs' own default is already off, so the stamp is withheld in that case.
      testDefault =
        if !guarded ? doCheck && (guarded.pythonImportsCheck or [ ]) != [ ] then
          { }
        else
          { doCheck = false; };
    in
    builder ((testDefault // buildDefault // guarded) // pinned);
in
{
  buildApplication = stamp python.buildPythonApplication;
  buildPackage = stamp python.buildPythonPackage;
}
