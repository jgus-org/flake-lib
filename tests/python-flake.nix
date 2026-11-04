{
  self,
  mkPythonApplication,
  mkPythonFlake,
  nixpkgs,
  pkgs,
  readPythonRequirements,
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
  testACheckNamedLikeAPublishedAttributeThrows = {
    expected = {
      success = false;
      value = false;
    };
    expr = builtins.tryEval (
      (producer {
        payload = {
          checks =
            { pkgs, ... }:
            {
              marker = pkgs.writeText "clash" "clash";
            };
          packages = markerPayload;
        };
      }).checks.${system}
    );
  };
  testAGitlabSourceFetchesItsSourceFromGitLab = {
    expected = {
      owner = "someone";
      repo = "something";
      version = "1.17.0";
    };
    expr =
      let
        package =
          (producer {
            payload.packages =
              { buildPackage, ... }:
              {
                six = buildPackage {
                  pname = "six";
                };
              };
            upstream = {
              owner = "someone";
              pin = {
                sourceHash = fakeSha256;
                sourceRev = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef";
                version = "1.17.0";
              };
              repo = "something";
              type = "gitlab";
            };
          }).packages.${system}.six;
      in
      {
        inherit (package) version;
        owner = package.src.owner;
        repo = package.src.repo;
      };
  };
  testAPayloadReadingSourceFilesFromAPinWithoutThemThrows = {
    expected = {
      success = false;
      value = false;
    };
    expr = builtins.tryEval (
      (producer {
        payload.packages =
          { pkgs, sourcePath, ... }:
          {
            six = pkgs.writeText "six" (toString sourcePath);
          };
        upstream = pypi;
      }).packages.${system}.six.drvPath
    );
  };
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
  testComputingTheOutputsNeverFetchesTheEvalTimeSourcePath = {
    expected = true;
    expr =
      let
        unfetchable =
          (producer {
            payload.packages = { buildPackage, ... }: {
              six = buildPackage {
                pname = "six";
              };
            };
            upstream = {
              owner = "someone";
              pin = {
                sourceHash = fakeSha256;
                sourceRev = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef";
                version = "1.17.0";
              };
              repo = "something";
              type = "github";
            };
          }).packages.${system}.six;
      in
      unfetchable.drvPath != null;
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
  testReadPythonRequirementsNamesThePackagesTheFileAsksFor = {
    expected = [
      "comfyui-frontend-package"
      "duplicate"
      "importlib-metadata"
      "numpy"
      "pillow"
      "pydantic"
      "requests"
      "sqlalchemy"
      "torch"
      "typing-extensions"
      "zope-interface"
    ];
    expr = readPythonRequirements ./fixtures/requirements-sample.txt;
  };
  testTheChecksHalfIsBuiltInTheGatedTree = {
    expected = true;
    expr =
      (producer {
        gate.config.cudaSupport = true;
        payload = {
          checks =
            { pkgs, ... }:
            {
              gate = pkgs.writeText "marker" (builtins.toString pkgs.config.cudaSupport);
            };
          packages = markerPayload;
        };
      }).checks.${system}.gate.drvPath == (producer {
        gate.config.cudaSupport = true;
        payload.packages = markerPayload;
      }).checks.${system}.marker.drvPath;
  };
  testTheChecksHalfIsCheckedBesideThePublishedFamily = {
    expected = {
      checks = [
        "formatting"
        "six"
        "suite"
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
        outputs = producer {
          payload = {
            checks =
              { pkgs, ... }:
              {
                suite = pkgs.writeText "suite" "suite";
              };
            packages = packagesPayload;
          };
          upstream = pypi;
        };
      in
      {
        checks = builtins.attrNames outputs.checks.${system};
        packages = builtins.attrNames outputs.packages.${system};
      };
  };
  testTheChecksHalfIsCheckedWithoutBeingPublished = {
    expected = {
      checks = [
        "formatting"
        "suite"
      ];
      packages = [ ];
    };
    expr =
      let
        outputs = producer {
          payload.checks =
            { pkgs, ... }:
            {
              suite = pkgs.writeText "suite" "suite";
            };
        };
      in
      {
        checks = builtins.attrNames outputs.checks.${system};
        packages = builtins.attrNames outputs.packages.${system};
      };
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
  testThePythonApplicationCarriesItsDependencyLayerAsBaseLayer = {
    expected = true;
    expr =
      (mkPythonApplication {
        inherit pkgs;
        dependencies = p: [ p.six ];
        name = "demo";
        script = ./fixtures/requirements-sample.txt;
      }).baseLayer.drvPath == (pkgs.python3.withPackages (p: [ p.six ])).drvPath;
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
