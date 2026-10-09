{ pkgs, source }:
let
  settings = {
    imageName = source.imageName;
    tag = source.tag or "latest";
    os = source.os or "linux";
    arch = source.arch or "amd64";
    variant = source.variant or "";
    finalImageName = source.finalImageName or source.imageName;
    finalImageTag = source.finalImageTag or (source.tag or "latest");
  };
  registry = builtins.head (pkgs.lib.splitString "/" settings.imageName);
  registries = pkgs.writeText "oci-registries.conf" ''
    unqualified-search-registries = []
  '';
  auth = pkgs.writeText "oci-auth.json" (builtins.toJSON { auths = { }; });
  skopeo = pkgs.writeShellApplication {
    name = "skopeo";
    text = ''
      export REGISTRY_AUTH_FILE=${pkgs.lib.escapeShellArg (toString auth)}
      export SSL_CERT_FILE=${pkgs.lib.escapeShellArg "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"}
      exec ${pkgs.lib.getExe pkgs.skopeo} --registries-conf ${registries} ${
        pkgs.lib.optionalString (
          settings.variant != ""
        ) "--override-variant ${pkgs.lib.escapeShellArg settings.variant}"
      } "''${@}"
    '';
  };
in
assert source.type == "oci";
assert
  builtins.match "[a-z0-9][a-z0-9.-]*(:[0-9]+)?/[a-z0-9][a-z0-9._/-]*" settings.imageName != null;
assert registry == "localhost" || pkgs.lib.hasInfix "." registry || pkgs.lib.hasInfix ":" registry;
assert builtins.match "[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}" settings.tag != null;
assert builtins.match "[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}" settings.finalImageTag != null;
assert
  builtins.match "[a-z0-9][a-z0-9._/-]*(:[0-9]+)?(/[a-z0-9][a-z0-9._/-]*)?" settings.finalImageName
  != null;
assert builtins.match "[a-z0-9][a-z0-9_-]*" settings.os != null;
assert builtins.match "[a-z0-9][a-z0-9_-]*" settings.arch != null;
assert builtins.match "[A-Za-z0-9_.-]*" settings.variant != null;
{
  inherit settings skopeo;
  fingerprint = builtins.hashString "sha256" (
    builtins.toJSON {
      inherit settings;
      archiveFormat = "nix2container-oci-dir";
      skopeoVersion = pkgs.skopeo.version;
      skopeoIdentity = toString skopeo;
    }
  );
}
