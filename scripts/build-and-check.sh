#!/usr/bin/env -S nix shell nixpkgs#bash nixpkgs#nix --command bash

# The whole gate one tree has to pass, defined in the one place: build the packages the flake publishes for this system, check the flake, then run the command the tree publishes for itself. No step covers another. `nix flake check` builds `checks` and only looks at the shape of `packages`, and building the published packages says nothing about a `checks` entry that stopped building.
#
# Every step runs even when an earlier one fails, because a tree with two problems and a gate that stops at the first will report only one. The command runs last: it is the step a producer wrote to take minutes, not seconds.
#
# See "Gate a pull request" in README.md for the paths that run this, for the tree's own command and what earns a place in it, and for what an overlay materializes in someone else's package set and the check that builds it.

set -uo pipefail

STATUS=0

"${BUILD_PACKAGES_SCRIPT:?required env var}" || STATUS=1

echo 'checking the flake...'
nix flake check --no-write-lock-file || STATUS=1

# The tree's own command is the app named `test-ci`, the published shape that runs instead of builds. It carries the verification a derivation cannot be: one that needs the network a build sandbox is denied, a path outside the build tree, or hardware the runner is standing next to. A tree that publishes none is the common case, so the probe's failure is not a failure. The name is asked of the `apps` family for the runner's system rather than resolved as an installable, because a package of the same name would win that resolution and the app would go unrun in silence.
if SYSTEM=$(nix config show system 2>/dev/null); then
  CI_PROGRAM_KIND=$(
    nix eval --raw ".#apps.${SYSTEM}.test-ci" --apply 'a: builtins.typeOf (a.program or null)' 2>/dev/null
  ) || CI_PROGRAM_KIND=''
  case ${CI_PROGRAM_KIND} in
  '') ;;
  string | path)
    echo 'running the repository command...'
    nix run ".#apps.${SYSTEM}.test-ci" || STATUS=1
    ;;
  *)
    printf 'error: apps.%s.test-ci publishes a program that is neither a string nor a path, so the gate cannot run it\n' "${SYSTEM}" >&2
    STATUS=1
    ;;
  esac
fi

exit ${STATUS}
