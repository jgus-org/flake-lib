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

  # The store-name of the pinned OCI dir, with the characters the Nix store
  # disallows folded out.
  dirName =
    builtins.replaceStrings [ "/" ":" ] [ "-" "-" ]
      "nix2container-${settings.finalImageName}-${settings.finalImageTag}";

  # The pull: a hermetic `skopeo copy` (flake-lib's authenticated wrapper) into a
  # recursive fixed-output store path, pinned by the same recursive hash the update
  # machinery prefetches with that same wrapper. The registry bytes are the `imageDigest`
  # manifest; `imageHash` is the recursive hash of this directory. This is the skopeo ->
  # dir primitive nix2container's pullImage performs, but via the wrapper that works under
  # the fleet's sandboxed builders (pullImage's bare skopeo reads an unwritable auth path
  # there).
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

  # nix2container's image.json for that directory, which buildImage --from-image and the
  # layer-path source extraction both read.
  baseImage = pkgs.runCommand "${dirName}-image" { nativeBuildInputs = [ nix2container-bin ]; } ''
    nix2container image-from-dir $out ${ociDir}
  '';

  # Re-export the base as a nix2container image so consumers get the ordinary image surface
  # (copyToPodman, imageName, imageTag) rather than a bare image.json. With no copyToRoot
  # this is the base's own config and layers, retagged.
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
