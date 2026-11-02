{
  dependencies,
  dualStack ? false,
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
  inherit (pkgs) lib;
  baseLayer = pkgs.python3.withPackages dependencies;
  dualStackSite = pkgs.writeTextDir "sitecustomize.py" ''
    import socket
    _orig = socket.socket.setsockopt
    def setsockopt(self, level, optname, value, *a, **kw):
        if level == socket.IPPROTO_IPV6 and optname == socket.IPV6_V6ONLY and value:
            return
        return _orig(self, level, optname, value, *a, **kw)
    socket.socket.setsockopt = setsockopt
  '';
  pythonDirs = lib.optionals dualStack [ dualStackSite ] ++ pythonPath;
  envFlags = lib.concatStringsSep " " (
    lib.mapAttrsToList (n: v: "--set ${n} ${lib.escapeShellArg (toString v)}") env
  );
  envDefaultFlags = lib.concatStringsSep " " (
    lib.mapAttrsToList (n: v: "--set-default ${n} ${lib.escapeShellArg (toString v)}") envDefaults
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
      ${lib.optionalString (workDir != null) "--chdir ${lib.escapeShellArg (toString workDir)}"} \
      --prefix PATH : ${lib.makeBinPath ([ baseLayer ] ++ runtimeInputs)} \
      ${
        lib.optionalString (
          pythonDirs != [ ]
        ) "--prefix PYTHONPATH : ${lib.concatStringsSep ":" (map toString pythonDirs)}"
      } \
      ${envFlags} \
      ${envDefaultFlags}
  ''
