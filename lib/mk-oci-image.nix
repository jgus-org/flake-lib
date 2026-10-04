{
  pkgs,
  source,
  pin,
}:
let
  contract = import ./oci-image.nix { inherit pkgs source; };
  baseImage = contract.pullArgs // {
    imageDigest = pin.imageDigest;
    hash = pin.imageHash;
  };
in
assert builtins.match "sha256:[0-9a-f]{64}" pin.imageDigest != null;
assert (pin.archiveFingerprint or "") == "" || pin.archiveFingerprint == contract.fingerprint;
(pkgs.dockerTools.pullImage baseImage).overrideAttrs (old: {
  nativeBuildInputs = [ contract.skopeo ];
  passthru = (old.passthru or { }) // {
    inherit baseImage;
    archiveFingerprint = contract.fingerprint;
  };
})
