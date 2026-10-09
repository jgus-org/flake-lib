{
  pkgs,
  source,
  pin,
}:
let
  contract = import ./oci-image.nix { inherit pkgs source; };
  inherit (contract) settings;
  image =
    pkgs.runCommand "oci-image-${pkgs.lib.removePrefix "sha256:" pin.imageDigest}"
      {
        outputHashMode = "recursive";
        outputHashAlgo = "sha256";
        outputHash = pin.imageHash;
        nativeBuildInputs = [ contract.skopeo ];
        passthru = rec {
          inherit (pin) imageDigest;
          imageName = settings.finalImageName;
          imageTag = settings.finalImageTag or (pkgs.lib.removePrefix "sha256:" pin.imageDigest);
          copyTo = pkgs.writeShellApplication {
            name = "copy-to";
            runtimeInputs = [ contract.skopeo ];
            text = ''
              exec skopeo --insecure-policy copy --preserve-digests dir:${image} "''${@}"
            '';
          };
          copyToPodman = pkgs.writeShellApplication {
            name = "copy-to-podman";
            text = ''
              exec ${pkgs.lib.getExe copyTo} containers-storage:${imageName}:${imageTag} "''${@}"
            '';
          };
        };
      }
      ''
        skopeo --insecure-policy copy \
          --preserve-digests \
          --tmpdir "''${TMPDIR}" \
          --src-tls-verify=true \
          "docker://${settings.imageName}@${pin.imageDigest}" \
          "dir://''${out}"
      '';
in
assert builtins.match "sha256:[0-9a-f]{64}" pin.imageDigest != null;
image
