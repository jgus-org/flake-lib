{
  self,
  mkPythonFlake,
  nixpkgs,
  pkgs,
}:
let
  system = "x86_64-linux";

  fakeSha256 = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";

  pypi = {
    pin = {
      hash = fakeSha256;
      version = "1.17.0";
    };
    pname = "six";
    type = "pypi";
  };

  packagesPayload =
    { buildPackage, python, ... }:
    {
      six = buildPackage {
        dependencies = [ python.requests ];
        pname = "six";
      };
    };

  bumpPayload =
    { python, ... }:
    {
      six = python.six.overridePythonAttrs (_: {
        version = "999.0";
      });
    };

  producer =
    extra:
    mkPythonFlake (
      {
        inherit nixpkgs self;
        systems = [ system ];
      }
      // extra
    );

  packagesProducer =
    extra:
    producer (
      {
        payload.packages = packagesPayload;
        upstream = pypi;
      }
      // extra
    );

  overlayOutputs = producer {
    payload.overlays = bumpPayload;
  };
  overlaidTree = import nixpkgs {
    inherit system;
    overlays = [ overlayOutputs.overlays.default ];
  };

  markerPayload =
    { pkgs, ... }:
    {
      marker = pkgs.writeText "marker" (builtins.toString pkgs.config.cudaSupport);
    };

  gatedOutputs = producer {
    gate.config.cudaSupport = true;
    payload.packages = markerPayload;
  };
  ungatedOutputs = producer {
    payload.packages = markerPayload;
  };
in
{
  testARecipeNamingABuildForAWheelSourceThrows = {
    expected = {
      success = false;
      value = false;
    };
    expr = builtins.tryEval (
      (producer {
        payload.packages = { buildPackage, ... }: {
          six = buildPackage {
            pname = "six";
            pyproject = true;
          };
        };
        upstream = pypi // {
          format = "wheel";
        };
      }).packages.${system}.six.drvPath
    );
  };
  testARecipeNamingDoCheckOwnsTheInstallCheck = {
    expected = false;
    expr =
      (producer {
        payload.packages = { buildPackage, ... }: {
          six = buildPackage {
            doCheck = false;
            pname = "six";
            pythonImportsCheck = [ "six" ];
          };
        };
        upstream = pypi;
      }).packages.${system}.six.doInstallCheck;
  };
  testAnArtifactHookWrittenAsAFunctionOfTheSetIsBuiltWithIt = {
    expected = true;
    expr =
      let
        hook =
          { pkgs, ... }:
          pkgs.writeShellApplication {
            name = "artifact-hook";
            text = "true";
          };
        updaterOf =
          artifactHook:
          (packagesProducer { updateVersion.artifactHook = artifactHook; })
          .packages.${system}.update-version.drvPath;
      in
      updaterOf hook == updaterOf (hook {
        pkgs = import nixpkgs { inherit system; };
      });
  };
  testAnOverlayOnlyAttributeIsPublishedAndChecked = {
    expected = {
      checks = [
        "formatting"
        "six"
      ];
      version = "999.0";
    };
    expr = {
      checks = builtins.attrNames overlayOutputs.checks.${system};
      version = overlayOutputs.packages.${system}.six.version;
    };
  };
  testBranchesFalseLeavesTheBranchUpdaterOut = {
    expected = [
      "default"
      "six"
      "update-version"
    ];
    expr = builtins.attrNames (packagesProducer { branches = false; }).packages.${system};
  };
  testCheckInputsNeverInheritTheSuite = {
    expected = false;
    expr =
      (producer {
        payload.packages =
          { buildPackage, python, ... }:
          {
            six = buildPackage {
              nativeCheckInputs = [ python.pytestCheckHook ];
              pname = "six";
            };
          };
        upstream = pypi;
      }).packages.${system}.six.doCheck;
  };
  testComputingTheOutputsNeverForcesSelf =
    let
      poisoned = packagesProducer {
        self.outPath = throw "this flake forced self while computing the outputs it defines";
      };
    in
    {
      expected = true;
      expr =
        poisoned.packages.${system}.six.drvPath == (packagesProducer { }).packages.${system}.six.drvPath
        && (poisoned.checks.${system} ? formatting)
        && (poisoned ? formatter);
    };
  testTheFleetTestDefaultKeepsADeclaredImportCheck = {
    expected = true;
    expr =
      (producer {
        payload.packages = { buildPackage, ... }: {
          six = buildPackage {
            pname = "six";
            pythonImportsCheck = [ "six" ];
          };
        };
        upstream = pypi;
      }).packages.${system}.six.doInstallCheck;
  };
  testTheGateConfigReachesTheChecksAndNotThePublishedPackage = {
    expected = {
      checksAreThePublishedPackagesWithoutAGate = true;
      checksDifferFromThePublishedPackagesWithOne = true;
    };
    expr = {
      checksAreThePublishedPackagesWithoutAGate =
        ungatedOutputs.checks.${system}.marker.outPath == ungatedOutputs.packages.${system}.marker.outPath;
      checksDifferFromThePublishedPackagesWithOne =
        gatedOutputs.checks.${system}.marker.outPath != gatedOutputs.packages.${system}.marker.outPath;
    };
  };
  testTheOverlayHalfReachesTheConsumersPythonSet = {
    expected = "999.0";
    expr = overlaidTree.python3Packages.six.version;
  };
  testThePackagesHalfPublishesItsAttributesAndTheirChecks = {
    expected = {
      checks = [
        "formatting"
        "six"
      ];
      packages = [
        "default"
        "six"
        "update-branches"
        "update-version"
      ];
    };
    expr =
      let
        outputs = packagesProducer { };
      in
      {
        checks = builtins.attrNames outputs.checks.${system};
        packages = builtins.attrNames outputs.packages.${system};
      };
  };
  testTheProducerPublishesTheFormatter = {
    expected = true;
    expr = (packagesProducer { }).formatter.${system} != null;
  };
  testThePublishedPackageBuildsThePinnedSource = {
    expected = "mirror://pypi/s/six/six-1.17.0.tar.gz";
    expr = builtins.head (packagesProducer { }).packages.${system}.six.src.urls;
  };
  testTheSinglePublishedPackageIsAlsoTheDefault = {
    expected = true;
    expr =
      let
        packages = (packagesProducer { }).packages.${system};
      in
      packages.default.drvPath == packages.six.drvPath;
  };
  testTheUpdaterOptionsPassThrough = {
    expected = false;
    expr =
      (packagesProducer { updateVersion.extraHashes = [ "otherHash" ]; })
      .packages.${system}.update-version.drvPath == (packagesProducer { })
      .packages.${system}.update-version.drvPath
      ||
        (packagesProducer { updateBranches.minimumTrackingVersion = "9.9.9"; })
        .packages.${system}.update-branches.drvPath == (packagesProducer { })
        .packages.${system}.update-branches.drvPath;
  };
  testTheUpdatersArePublishedOnlyWithAnUpstream = {
    expected = [
      "default"
      "six"
    ];
    expr = builtins.attrNames (producer { payload.packages = packagesPayload; }).packages.${system};
  };
}
