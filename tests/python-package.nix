{
  mkPypiPackage,
  mkPythonPackage,
  pkgs,
}:
let
  fakeSha256 = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
  pypiPin = {
    hash = fakeSha256;
    version = "1.17.0";
  };
  githubPin = {
    sourceHash = fakeSha256;
    sourceRev = "1.17.0";
    version = "1.17.0";
  };
  source = {
    owner = "benjaminp";
    repo = "six";
    type = "github";
  };
  build = spec: mkPythonPackage (spec // { inherit pkgs; });
  fromPypi =
    format:
    (build {
      package.attr = "six";
      pin = pypiPin;
      source = {
        inherit format;
        pname = "six";
        type = "pypi";
      };
    }).src;
  names = builtins.map pkgs.lib.getName;
  githubPackage =
    extra:
    build (
      {
        inherit source;
        package.attr = "six";
        pin = githubPin;
      }
      // extra
    );
  sdistSpec = {
    package.attr = "six";
    pin = pypiPin;
    source = {
      format = "sdist";
      pname = "six";
      type = "pypi";
    };
  };
in
{
  testExtraAsAFunctionResolvesInThePythonSet = {
    expected = true;
    expr =
      let
        pkg = githubPackage {
          package = {
            attr = "six";
            dependencies = p: [ p.requests ];
            extra = p: { buildInputs = [ p.requests ]; };
          };
        };
      in
      builtins.elem (builtins.head pkg.propagatedBuildInputs) pkg.buildInputs;
  };
  testExtraAsTwoArgumentsNamesTheFlakesOwnSet = {
    expected = true;
    expr =
      let
        pkg = githubPackage {
          package = {
            attr = "six";
            extra = p: outer: {
              buildInputs = [ outer.iana-etc ];
            };
          };
        };
      in
      builtins.elem "iana-etc" (names pkg.buildInputs);
  };
  testExtraOverridesTheGeneratedAttributes = {
    expected = [ "six" ];
    expr =
      (githubPackage {
        package = {
          attr = "six";
          extra.pythonImportsCheck = [ "six" ];
        };
      }).pythonImportsCheck;
  };
  testGithubPinFetchesTheTaggedTree = {
    expected = {
      owner = "benjaminp";
      rev = "1.17.0";
      url = "https://github.com/benjaminp/six/archive/1.17.0.tar.gz";
    };
    expr =
      let
        src = (githubPackage { }).src;
      in
      {
        inherit (src) owner rev;
        url = builtins.head src.urls;
      };
  };
  testGithubSourceBuildsLikeAnSdist = {
    expected = true;
    expr = builtins.elem "setuptools" (names (githubPackage { }).nativeBuildInputs or [ ]);
  };
  testPypiSdistKeepsTheSdistFetch = {
    expected = "mirror://pypi/s/six/six-1.17.0.tar.gz";
    expr = builtins.head (fromPypi "sdist").urls;
  };
  testPypiWheelKeepsTheUniversalWheelFetch = {
    expected = "https://files.pythonhosted.org/packages/py3/s/six/six-1.17.0-py3-none-any.whl";
    expr = builtins.head (fromPypi "wheel").urls;
  };
  testSpecDependenciesPropagate = {
    expected = true;
    expr = builtins.elem "requests" (
      names
        (githubPackage {
          package = {
            attr = "six";
            dependencies = p: [ p.requests ];
          };
        }).propagatedBuildInputs or [ ]
    );
  };
  testThePypiNameIsTheSameBuilder = {
    expected = (build sdistSpec).drvPath;
    expr = (mkPypiPackage (sdistSpec // { inherit pkgs; })).drvPath;
  };
}
