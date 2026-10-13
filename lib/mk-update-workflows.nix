# Generates the `update-workflows` package: it refreshes the repository's own GitHub
# Actions workflow files from the templates shipped by the flake-lib revision its lock
# names, and advances that revision in the same commit. Nothing here is specific to the
# flake using it -- the tool reads the lock and the installed workflows -- so any flake
# that locks flake-lib can publish it beside its updater.
{ pkgs }:
pkgs.writeShellApplication {
  name = "update-workflows";
  runtimeEnv = {
    GIT_PUSH_LIB = "${../scripts/git-push.sh}";
  };
  text = ''exec ${../scripts/update-workflows.sh} "$@"'';
}
