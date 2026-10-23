# Builds a PyPI-sourced python package (or application) from a pin + spec.
{
  package,
  pin,
  pkgs,
  source,
}:
let
  inherit (pkgs) lib;
  ps = pkgs.python3Packages;
  inherit (pin) hash version;

  kind = package.kind or "pythonPackage";
  builder = if kind == "pythonApplication" then ps.buildPythonApplication else ps.buildPythonPackage;
  format = source.format or "sdist";
  description = package.description or "";

  deps = (package.dependencies or (_: [ ])) ps;
  meta = (lib.optionalAttrs (description != "") { inherit description; }) // (package.meta or { });

  srcAttrs =
    if format == "wheel" then
      {
        format = "wheel";
        # Universal wheel. fetchPypi's `dist` (URL path segment) and `python` (filename tag) both default to py2.py3; a py3-none-any wheel needs both set to py3, else the path 404s. Platform-specific wheels aren't covered here.
        src = ps.fetchPypi {
          inherit hash version;
          dist = "py3";
          format = "wheel";
          pname = source.pname;
          python = "py3";
        };
      }
    else
      {
        build-system = (package.buildSystem or (p: [ p.setuptools ])) ps;
        pyproject = true;
        src = ps.fetchPypi {
          inherit hash version;
          pname = source.pname;
        };
      };
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
  // (package.extra or { })
)
