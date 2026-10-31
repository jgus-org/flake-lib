# The fetch a pin names, so the build path resolves a pin through one place and never reads a pin field itself.
{
  pin,
  pkgs,
  source,
}:
let
  type = source.type or "pypi";

  pypiName = {
    inherit (pin) version;
    pname = source.pname;
  };
in
if type == "github" then
  {
    inherit (pin) version;
    src = pkgs.fetchFromGitHub {
      inherit (source) owner repo;
      hash = pin.sourceHash;
      rev = pin.sourceRev;
    };
  }
else if (source.format or "sdist") == "wheel" then
  {
    inherit (pin) version;
    format = "wheel";
    src = pkgs.python3.pkgs.fetchPypi (
      pypiName
      // {
        dist = "py3";
        format = "wheel";
        hash = pin.hash;
        python = "py3";
      }
    );
  }
else
  {
    inherit (pin) version;
    src = pkgs.python3.pkgs.fetchPypi (
      pypiName
      // {
        hash = pin.hash;
      }
    );
  }
