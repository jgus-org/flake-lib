# Builds a PyPI-sourced python package (or application) from a pin + spec.
{
  package,
  pin,
  pkgs,
  source,
}:
let
  inherit (pkgs) lib;
  ps = pkgs.${package.python or "python3"}.pkgs;
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
        src =
          let
            wheelTags = lib.splitString "-" (source.wheelTag or "py3-none-any");
          in
          ps.fetchPypi {
            inherit hash version;
            abi = builtins.elemAt wheelTags 1;
            dist = builtins.elemAt wheelTags 0;
            format = "wheel";
            platform = builtins.elemAt wheelTags 2;
            pname = source.pname;
            python = builtins.elemAt wheelTags 0;
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
assert
  !(source ? wheelTag)
  || (
    format == "wheel"
    && builtins.match "[a-zA-Z0-9_.]+-[a-zA-Z0-9_.]+-[a-zA-Z0-9_.]+" source.wheelTag != null
  );
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
