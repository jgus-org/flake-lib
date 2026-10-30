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
        inherit
          nixpkgs
          pin
          self
          source
          ;
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
  testComputingTheOutputsNeverForcesSelf =
    let
      poisoned = leaf {
        self.outPath = throw "the leaf forced self while computing the outputs it defines";
      };
    in
    {
      expected = true;
      expr =
        poisoned.packages.${system}.six.drvPath == (leaf { }).packages.${system}.six.drvPath
        && (poisoned.checks.${system} ? formatting)
        && (poisoned ? formatter);
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
  testTheLeafPublishesTheFormatter = {
    expected = true;
    expr = (leaf { }).formatter.${system} != null;
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
