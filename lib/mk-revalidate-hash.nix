# Generates a `revalidate-hash` package that rewrites a flake's fixed-output hash pin from a build-time hash mismatch.
{
  # Published package the hash is mined from, by name. Empty mines from the whole published family,
  # which needs nothing of the caller and is therefore the default; naming one package narrows only
  # the build the hash is mined from, never the build that verifies the rewritten tree.
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
    # The build the hash is mined from is the same one a pull request is gated by, run from the
    # script text the published tool wraps rather than by nesting one wrapper in another.
    BUILD_PACKAGES_SCRIPT = "${pkgs.copyPathToStore ../scripts/build-packages.sh}";
    BUILD_PACKAGES_SELECT = "${pkgs.copyPathToStore ../scripts/build-packages-select.nix}";
    BUILD_TARGET = buildTarget;
    HASH_FIELD = hashField;
  };
  # That build step reads its selection with jq, so the tool that runs it carries jq though this
  # script never calls it directly.
  runtimeInputs = [ pkgs.jq ];
  text = ''exec ${../scripts/revalidate-build-hash.sh} "$@"'';
}
