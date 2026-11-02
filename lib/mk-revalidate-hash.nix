# Generates a `revalidate-hash` package that rewrites a flake's fixed-output hash pin from a build-time hash mismatch.
{
  # Published package the hash is recovered from; empty recovers from the whole published family.
  buildTarget ? "",
  hashField ? "hash",
  meta ? {
    license = pkgs.lib.licenses.mit;
  },
  pkgs,
}:
pkgs.writeShellApplication {
  inherit meta;
  # The default HASH_FIELD value "hash" collides with the `hash` shell builtin, so writeShellApplication's generated `HASH_FIELD=hash` trips SC2209 (false positive).
  excludeShellChecks = [ "SC2209" ];
  name = "revalidate-hash";
  runtimeEnv = {
    BUILD_PACKAGES_SCRIPT = "${pkgs.copyPathToStore ../scripts/build-packages.sh}";
    BUILD_PACKAGES_SELECT = "${pkgs.copyPathToStore ../scripts/build-packages-select.nix}";
    BUILD_TARGET = buildTarget;
    HASH_FIELD = hashField;
  };
  text = ''exec ${../scripts/revalidate-build-hash.sh} "$@"'';
}
