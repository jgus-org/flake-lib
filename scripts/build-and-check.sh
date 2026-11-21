#!/usr/bin/env -S nix shell nixpkgs#bash nixpkgs#nix --command bash

# The whole gate one tree has to pass, defined in the one place: build the packages the flake publishes for this system, then check the flake. Neither half covers the other. `nix flake check` builds `checks` and only looks at the shape of `packages`, and building the published packages says nothing about a `checks` entry that stopped building.
#
# Both steps run even when the first fails, because a tree with two problems and a gate that stops at the first will report only one.
#
# See "Gate a pull request" in README.md for the paths that run this, and for what an overlay materializes in someone else's package set and the check that builds it.

set -uo pipefail

STATUS=0

"${BUILD_PACKAGES_SCRIPT:?required env var}" || STATUS=1

echo 'checking the flake...'
nix flake check --no-write-lock-file || STATUS=1

exit ${STATUS}
