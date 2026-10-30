# Builds a python package (or application) from a pin + spec, from PyPI or a GitHub source tree.
{
  package,
  pin,
  pkgs,
  source,
}:
let
  inherit (pkgs) lib;
  ps = pkgs.python3Packages;
  inherit (pin) version;

  kind = package.kind or "pythonPackage";
  builder = if kind == "pythonApplication" then ps.buildPythonApplication else ps.buildPythonPackage;
  format = source.format or "sdist";
  sourceType = source.type or "pypi";
  description = package.description or "";

  deps = (package.dependencies or (_: [ ])) ps;
  meta = (lib.optionalAttrs (description != "") { inherit description; }) // (package.meta or { });
  extra =
    if builtins.isFunction (package.extra or { }) then (package.extra ps) else (package.extra or { });

  # `mkUpdateVersion` writes the artifact hash as `hash` for a PyPI release and as
  # `sourceHash` beside `sourceRev` for a GitHub tree, because only the latter has a
  # revision to name.
  builtFromSource = src: {
    inherit src;
    build-system = (package.buildSystem or (p: [ p.setuptools ])) ps;
    pyproject = true;
  };
  srcAttrs =
    if sourceType == "github" then
      builtFromSource (
        pkgs.fetchFromGitHub {
          inherit (source) owner repo;
          hash = pin.sourceHash;
          rev = pin.sourceRev;
        }
      )
    else if format == "wheel" then
      {
        format = "wheel";
        # Universal wheel. fetchPypi's `dist` (URL path segment) and `python` (filename tag) both default to py2.py3; a py3-none-any wheel needs both set to py3, else the path 404s. Platform-specific wheels aren't covered here.
        src = ps.fetchPypi {
          inherit version;
          dist = "py3";
          format = "wheel";
          hash = pin.hash;
          pname = source.pname;
          python = "py3";
        };
      }
    else
      builtFromSource (
        ps.fetchPypi {
          inherit version;
          hash = pin.hash;
          pname = source.pname;
        }
      );
in
builder (
  {
    inherit version;
    doCheck = false;
    pname = package.attr;
  }
  // srcAttrs
  // lib.optionalAttrs (deps != [ ]) { dependencies = deps; }
  // lib.optionalAttrs (meta != { }) { inherit meta; }
  // extra
)
