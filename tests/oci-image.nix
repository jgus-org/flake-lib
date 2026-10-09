{ pkgs, lib }:
let
  fixture = pkgs.runCommand "oci-image-fixture" { nativeBuildInputs = [ pkgs.jq ]; } ''
    mkdir "''${out}"
    printf '%s' '${
      builtins.toJSON {
        architecture = "amd64";
        os = "linux";
        config = {
          Entrypoint = [ "/init" ];
          Cmd = [ "serve" ];
          Env = [ "FIXTURE=preserved" ];
          User = "123:456";
          WorkingDir = "/data";
          Labels.fixture = "preserved";
          Volumes."/data" = { };
          ExposedPorts."8123/tcp" = { };
          StopSignal = "SIGINT";
          Healthcheck.Test = [
            "CMD"
            "true"
          ];
        };
        rootfs = {
          type = "layers";
          diff_ids = [ ];
        };
      }
    }' > "''${out}/config"
    CONFIG_DIGEST=$(sha256sum "''${out}/config" | cut -d' ' -f1)
    CONFIG_SIZE=$(wc -c < "''${out}/config")
    mv "''${out}/config" "''${out}/''${CONFIG_DIGEST}"
    jq -n --arg DIGEST "sha256:''${CONFIG_DIGEST}" --argjson SIZE "''${CONFIG_SIZE}" '{schemaVersion:2,mediaType:"application/vnd.docker.distribution.manifest.v2+json",config:{mediaType:"application/vnd.docker.container.image.v1+json",digest:$DIGEST,size:$SIZE},layers:[]}' > "''${out}/manifest.json"
  '';
  skopeo = pkgs.writeShellApplication {
    name = "skopeo";
    text = ''
      if [[ "''${*}" == *'docker://registry.example/image@sha256:'* ]]; then
        DESTINATION="''${*: -1}"
        cp -r ${fixture} "''${DESTINATION#dir://}"
      else
        exec ${pkgs.lib.getExe pkgs.skopeo} "''${@}"
      fi
    '';
  };
  testPkgs = pkgs // {
    inherit skopeo;
  };
  image = lib.mkOciImage {
    pkgs = testPkgs;
    source = {
      type = "oci";
      imageName = "registry.example/image";
      tag = "stable";
    };
    pin = {
      imageDigest = "sha256:${pkgs.lib.concatStrings (pkgs.lib.replicate 64 "a")}";
      imageHash = "sha256-pdvWZEkndjjekvTaWJlBHmUbIJlGVkiBjJJJs7/3xiQ=";
    };
  };
in
pkgs.runCommand "oci-image-tests" { nativeBuildInputs = [ pkgs.jq ]; } ''
  test '${image.imageName}' = registry.example/image
  test '${image.imageTag}' = '${pkgs.lib.removePrefix "sha256:" image.imageDigest}'
  test -x ${pkgs.lib.getExe image.copyToPodman}
  ${pkgs.lib.getExe image.copyTo} dir:"''${TMPDIR}/loaded"
  cmp ${fixture}/manifest.json "''${TMPDIR}/loaded/manifest.json"
  CONFIG_DIGEST=$(jq -r '.config.digest | ltrimstr("sha256:")' ${fixture}/manifest.json)
  cmp ${fixture}/"''${CONFIG_DIGEST}" "''${TMPDIR}/loaded/''${CONFIG_DIGEST}"
  touch "''${out}"
''
