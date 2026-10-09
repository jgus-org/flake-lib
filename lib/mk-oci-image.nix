{
  pkgs,
  source,
  pin,
  nix2container,
}:
let
  contract = import ./oci-image.nix { inherit pkgs source; };
  settings = contract.settings;
  nix2containerPackages = nix2container.packages.${pkgs.system};
  nix2container-bin = nix2containerPackages.nix2container-bin;
  nix2container-lib = nix2containerPackages.nix2container;

  dirName =
    builtins.replaceStrings [ "/" ":" ] [ "-" "-" ]
      "nix2container-${settings.finalImageName}-${settings.finalImageTag}";

  # flake-lib's hermetic skopeo wrapper, not nix2container's pullImage: pullImage's bare
  # skopeo reads an unwritable auth path on the fleet's sandboxed builders.
  ociDir =
    pkgs.runCommand dirName
      {
        outputHashMode = "recursive";
        outputHashAlgo = "sha256";
        outputHash = pin.imageHash;
        nativeBuildInputs = [
          pkgs.cacert
          contract.skopeo
        ];
      }
      ''
        skopeo copy \
          --insecure-policy \
          --tmpdir "$TMPDIR" \
          --override-os ${pkgs.lib.escapeShellArg settings.os} \
          --override-arch ${pkgs.lib.escapeShellArg settings.arch} \
          --src-tls-verify=true \
          "docker://${settings.imageName}@${pin.imageDigest}" \
          "dir://$out"
      '';

  baseImage = pkgs.runCommand "${dirName}-image" { nativeBuildInputs = [ nix2container-bin ]; } ''
    nix2container image-from-dir $out ${ociDir}
  '';

  image =
    (nix2container-lib.buildImage {
      name = settings.finalImageName;
      tag = settings.finalImageTag;
      fromImage = baseImage;
      fromImageEnv = true;
    }).overrideAttrs
      (old: {
        passthru = (old.passthru or { }) // {
          archiveFingerprint = contract.fingerprint;
          imageDigest = pin.imageDigest;
          ociDir = ociDir;
        };
      });
in
assert builtins.match "sha256:[0-9a-f]{64}" pin.imageDigest != null;
assert (pin.archiveFingerprint or "") == "" || pin.archiveFingerprint == contract.fingerprint;
image
