{
  dependencies,
  env ? { },
  envDefaults ? { },
  meta ? { },
  name,
  pkgs,
  pythonPath ? [ ],
  runtimeInputs ? [ ],
  script,
  workDir ? null,
}:
let
  baseLayer = pkgs.python3.withPackages dependencies;
  envFlags = pkgs.lib.concatStringsSep " " (
    pkgs.lib.mapAttrsToList (n: v: "--set ${n} ${pkgs.lib.escapeShellArg (toString v)}") env
  );
  envDefaultFlags = pkgs.lib.concatStringsSep " " (
    pkgs.lib.mapAttrsToList (
      n: v: "--set-default ${n} ${pkgs.lib.escapeShellArg (toString v)}"
    ) envDefaults
  );
in
pkgs.runCommand name
  {
    meta = {
      mainProgram = name;
    }
    // meta;
    nativeBuildInputs = [ pkgs.makeWrapper ];
    passthru = {
      inherit baseLayer;
    };
  }
  ''
    mkdir -p $out/bin
    makeWrapper ${baseLayer.interpreter} $out/bin/${name} \
      --add-flags ${script} \
      ${
        pkgs.lib.optionalString (workDir != null) "--chdir ${pkgs.lib.escapeShellArg (toString workDir)}"
      } \
      --prefix PATH : ${pkgs.lib.makeBinPath ([ baseLayer ] ++ runtimeInputs)} \
      ${
        pkgs.lib.optionalString (
          pythonPath != [ ]
        ) "--prefix PYTHONPATH : ${pkgs.lib.concatStringsSep ":" (map toString pythonPath)}"
      } \
      ${envFlags} \
      ${envDefaultFlags}
  ''
