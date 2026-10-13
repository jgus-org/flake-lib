# Generates the `update-workflows` package: it refreshes the repository's own GitHub
# Actions workflow files from the templates shipped by the flake-lib revision its lock
# names, and advances that revision in the same commit. Nothing here is specific to the
# flake using it -- the tool reads the lock and the installed workflows -- so consumers
# run this very package through flake-lib's flake URL rather than re-exporting it from
# their own outputs. A re-export would also be self-defeating: `nix run .#update-workflows`
# evaluates the tool at the revision the flake currently locks, so the program doing the
# adopting would always be the one before the templates it installs.
{ pkgs }:
pkgs.writeShellApplication {
  name = "update-workflows";
  runtimeEnv = {
    GIT_PUSH_LIB = "${../scripts/git-push.sh}";
  };
  text = ''exec ${../scripts/update-workflows.sh} "$@"'';
}
