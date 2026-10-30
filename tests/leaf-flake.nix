{
  self,
  mkLeafFlake,
  nixpkgs,
  pkgs,
}:
let
  system = "x86_64-linux";
  pin = {
    hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
    version = "1.17.0";
  };
  source = {
    format = "sdist";
    pname = "six";
    type = "pypi";
  };
  leaf =
    extra:
    mkLeafFlake (
      {
        inherit nixpkgs pin source;
        package = {
          attr = "six";
          dependencies = p: [ p.six ];
        };
      }
      // extra
    );
  overlaidSix = _final: prev: {
    pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
      (_pyfinal: pyprev: {
        six = pyprev.six.overridePythonAttrs (_: {
          version = "999.0";
        });
      })
    ];
  };
  versionOf = d: d.version or null;
in
{
  testAnOverlayReachesTheRecipe = {
    expected = true;
    expr =
      builtins.any (d: versionOf d == "999.0")
        (leaf { overlays = [ overlaidSix ]; }).packages.${system}.six.propagatedBuildInputs;
  };
  testBranchesFalseLeavesTheBranchUpdaterOut = {
    expected = [
      "default"
      "six"
      "update-version"
    ];
    expr = builtins.attrNames (leaf { branches = false; }).packages.${system};
  };
  testExtraChecksMergeWithTheFormatterCheck = {
    expected = [
      "formatting"
      "payload"
    ];
    expr = builtins.attrNames (
      (leaf {
        inherit self;
        extraChecks = { package, ... }: { payload = package; };
      }).checks.${system}
    );
  };
  testTheBranchUpdaterTakesItsOptionsThrough = {
    expected = false;
    expr =
      (leaf { updateBranches.minimumTrackingVersion = "9.9.9"; })
      .packages.${system}.update-branches.drvPath == (leaf { })
      .packages.${system}.update-branches.drvPath;
  };
  testTheFormatterArrivesWithSelfAndGoesWithoutIt = {
    expected = {
      withFormatter = [ "formatting" ];
      without = [ ];
    };
    expr = {
      withFormatter = builtins.attrNames (leaf { inherit self; }).checks.${system};
      without = builtins.attrNames (leaf { }).checks.${system};
    };
  };
  testTheLeafPublishesTheFormatterItself = {
    expected = true;
    expr = (leaf { inherit self; }).formatter.${system} != null;
  };
  testTheLeafPublishesThePackageUnderItsAttrAndAsDefault = {
    expected = true;
    expr =
      let
        packages = (leaf { }).packages.${system};
      in
      packages.default.drvPath == packages.six.drvPath;
  };
  testTheLeafPublishesTheUpdaters = {
    expected = [
      "default"
      "six"
      "update-branches"
      "update-version"
    ];
    expr = builtins.attrNames (leaf { }).packages.${system};
  };
  testTheVersionUpdaterTakesItsOptionsThrough = {
    expected = false;
    expr =
      (leaf { updateVersion.extraHashes = [ "otherHash" ]; }).packages.${system}.update-version.drvPath
      == (leaf { }).packages.${system}.update-version.drvPath;
  };
}
