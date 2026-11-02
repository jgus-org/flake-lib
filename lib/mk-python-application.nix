{
  dependencies,
  env ? { },
  envDefaults ? { },
  name,
  pkgs,
  pythonPath ? [ ],
  runtimeInputs ? [ ],
  script,
  workDir ? null,
}:
let
  inherit (pkgs) lib;
  baseLayer = pkgs.python3.withPackages dependencies;
  envFlags = lib.concatStringsSep " " (
    lib.mapAttrsToList (n: v: "--set ${n} ${lib.escapeShellArg (toString v)}") env
  );
  envDefaultFlags = lib.concatStringsSep " " (
    lib.mapAttrsToList (n: v: "--set-default ${n} ${lib.escapeShellArg (toString v)}") envDefaults
  );
in
pkgs.runCommand name
  {
    meta.mainProgram = name;
    nativeBuildInputs = [ pkgs.makeWrapper ];
    passthru = {
      inherit baseLayer;
    };
  }
  ''
    mkdir -p $out/bin
    makeWrapper ${baseLayer.interpreter} $out/bin/${name} \
      --add-flags ${script} \
      ${lib.optionalString (workDir != null) "--chdir ${lib.escapeShellArg (toString workDir)}"} \
      --prefix PATH : ${lib.makeBinPath ([ baseLayer ] ++ runtimeInputs)} \
      ${
        lib.optionalString (
          pythonPath != [ ]
        ) "--prefix PYTHONPATH : ${lib.concatStringsSep ":" (map toString pythonPath)}"
      } \
      ${envFlags} \
      ${envDefaultFlags}
  ''
