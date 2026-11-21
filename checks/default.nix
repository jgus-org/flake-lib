{
  self,
  lib,
  nixpkgs,
  orgFormatting,
  pkgs,
  system,
}:
let
  # Building the example generators fetches nothing: writeShellApplication only shellchecks the exec wrappers.
  exampleSource = {
    format = "sdist";
    pname = "iso639_lang";
    type = "pypi";
  };
in
(import ./build-gate.nix { inherit pkgs; })
// (import ./formatting.nix {
  inherit
    lib
    orgFormatting
    pkgs
    self
    system
    ;
})
// (import ./hooks.nix { inherit lib pkgs; })
// (import ./lib-tests.nix {
  inherit
    lib
    nixpkgs
    pkgs
    self
    ;
})
// (import ./python-tools.nix { inherit lib pkgs; })
// (import ./revalidate-hash.nix { inherit lib pkgs; })
// (import ./update-branches.nix { inherit exampleSource lib pkgs; })
// (import ./update-examples.nix { inherit exampleSource lib pkgs; })
// (import ./update-version.nix {
  inherit
    exampleSource
    lib
    orgFormatting
    pkgs
    ;
})
// (import ./workflow-refresh.nix { inherit pkgs self system; })
