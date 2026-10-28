#!/usr/bin/env -S nix shell nixpkgs#bash nixpkgs#nix --command bash

# The whole gate one tree has to pass, defined in the one place: build the packages the flake
# publishes for this system, then check the flake. Neither half covers the other -- `nix flake
# check` builds `checks` and only looks at the shape of `packages`, and building the published
# packages says nothing about a `checks` entry that stopped building.
#
# Both steps run even when the first fails, because a tree with two problems and a gate that stops
# at the first reports one.
#
# Every path that verifies a tree runs this rather than writing its own build: the pull-request
# template, and the publication path before it commits or pushes what an update resolved. What an
# overlay materializes in someone else's package set is built by a check in the flake's own tree,
# which the second step builds.

set -uo pipefail

STATUS=0

# Run from the script text rather than the published wrapper, so the gate resolves its nix shell
# once instead of nesting a second one to reach the same tools.
bash "${BUILD_PACKAGES_SCRIPT:?required env var}" || STATUS=1

echo 'checking the flake...'
nix flake check --no-write-lock-file || STATUS=1

exit ${STATUS}
