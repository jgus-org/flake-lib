{
  pkgs,
  name,
  manifest,
  model,
  stampName ? ".${name}-verified.json",
}:
let
  python = pkgs.python3.withPackages (pythonPackages: [
    pythonPackages.hf-xet
    pythonPackages.huggingface-hub
  ]);
in
(pkgs.writeShellApplication {
  inherit name;
  runtimeInputs = [ python ];
  text = ''
    export HF_HUB_DISABLE_IMPLICIT_TOKEN=1
    export HF_HUB_DISABLE_TELEMETRY=1
    exec ${python}/bin/python ${../scripts/huggingface-model-manager.py} ${manifest} ${pkgs.lib.escapeShellArg stampName} "''${@}"
  '';
}).overrideAttrs
  (oldAttrs: {
    passthru = (oldAttrs.passthru or { }) // {
      inherit model;
    };
  })
