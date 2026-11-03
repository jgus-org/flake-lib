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
assert
  !(source ? wheelTag)
  || (
    type == "pypi"
    && (source.format or "sdist") == "wheel"
    && builtins.match "[a-zA-Z0-9_.]+-[a-zA-Z0-9_.]+-[a-zA-Z0-9_.]+" source.wheelTag != null
  );
if type == "github" then
  {
    inherit (pin) version;
    # Evaluation may read a source file only from an eval-time fetch, never from a derivation output; the same pin hash covers both because a pinned tree is hashed by content.
    sourcePath = builtins.fetchTarball {
      sha256 = pin.sourceHash;
      url = "https://codeload.github.com/${source.owner}/${source.repo}/tarball/${pin.sourceRev}";
    };
    src = pkgs.fetchFromGitHub {
      inherit (source) owner repo;
      hash = pin.sourceHash;
      rev = pin.sourceRev;
    };
  }
else if type == "gitlab" then
  {
    inherit (pin) version;
    sourcePath = builtins.fetchTarball {
      sha256 = pin.sourceHash;
      url = "https://gitlab.com/${source.owner}/${source.repo}/-/archive/${pin.sourceRev}/${source.repo}-${pin.sourceRev}.tar.gz";
    };
    src = pkgs.fetchFromGitLab {
      inherit (source) owner repo;
      hash = pin.sourceHash;
      rev = pin.sourceRev;
    };
  }
else if (source.format or "sdist") == "wheel" then
  {
    inherit (pin) version;
    format = "wheel";
    src =
      let
        tags = pkgs.lib.splitString "-" (source.wheelTag or "py3-none-any");
      in
      pkgs.python3.pkgs.fetchPypi (
        pypiName
        // {
          abi = builtins.elemAt tags 1;
          dist = builtins.elemAt tags 0;
          format = "wheel";
          hash = pin.hash;
          platform = builtins.elemAt tags 2;
          python = builtins.elemAt tags 0;
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
