{
  self,
  mkPythonFlake,
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
  producer =
    extra:
    mkPythonFlake (
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
        (producer { overlays = [ overlaidSix ]; }).packages.${system}.six.propagatedBuildInputs;
  };
  testBranchesFalseLeavesTheBranchUpdaterOut = {
    expected = [
      "default"
      "six"
      "update-version"
    ];
    expr = builtins.attrNames (producer { branches = false; }).packages.${system};
  };
  testComputingTheOutputsNeverForcesSelf =
    let
      poisoned = producer {
        self.outPath = throw "this flake forced self while computing the outputs it defines";
      };
    in
    {
      expected = true;
      expr =
        poisoned.packages.${system}.six.drvPath == (producer { }).packages.${system}.six.drvPath
        && (poisoned.checks.${system} ? formatting)
        && (poisoned ? formatter);
    };
  testExtraChecksMergeWithTheFormatterCheck = {
    expected = [
      "formatting"
      "payload"
    ];
    expr = builtins.attrNames (
      (producer {
        inherit self;
        extraChecks = { package, ... }: { payload = package; };
      }).checks.${system}
    );
  };
  testTheBranchUpdaterTakesItsOptionsThrough = {
    expected = false;
    expr =
      (producer { updateBranches.minimumTrackingVersion = "9.9.9"; })
      .packages.${system}.update-branches.drvPath == (producer { })
      .packages.${system}.update-branches.drvPath;
  };
  testTheProducerPublishesTheFormatter = {
    expected = true;
    expr = (producer { }).formatter.${system} != null;
  };
  testTheProducerPublishesThePackageUnderItsAttrAndAsDefault = {
    expected = true;
    expr =
      let
        packages = (producer { }).packages.${system};
      in
      packages.default.drvPath == packages.six.drvPath;
  };
  testTheProducerPublishesTheUpdaters = {
    expected = [
      "default"
      "six"
      "update-branches"
      "update-version"
    ];
    expr = builtins.attrNames (producer { }).packages.${system};
  };
  testTheVersionUpdaterTakesItsOptionsThrough = {
    expected = false;
    expr =
      (producer { updateVersion.extraHashes = [ "otherHash" ]; })
      .packages.${system}.update-version.drvPath == (producer { })
      .packages.${system}.update-version.drvPath;
  };
}
