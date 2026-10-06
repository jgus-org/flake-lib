{
  pkgs,
  name,
  manifest,
  model,
  stampName ? ".${name}-verified.json",
}:
let
  client = import ./huggingface-client.nix { inherit pkgs; };
in
(pkgs.writeShellApplication {
  inherit name;
  runtimeInputs = [ client.python ];
  text = ''
    export HF_HUB_DISABLE_TELEMETRY=1
    exec ${client.python}/bin/python ${client.script} ${manifest} ${pkgs.lib.escapeShellArg stampName} "''${@}"
  '';
}).overrideAttrs
  (oldAttrs: {
    passthru = (oldAttrs.passthru or { }) // {
      inherit model stampName;
    };
  })
