{
  dependencies,
  name,
  pkgs,
  script,
}:
let
  baseLayer = pkgs.python3.withPackages dependencies;
in
pkgs.writeShellApplication {
  inherit name;
  passthru = {
    inherit baseLayer;
  };
  runtimeInputs = [ baseLayer ];
  text = ''
    exec python3 ${script} "$@"
  '';
}
