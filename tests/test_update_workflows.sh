#!/usr/bin/env -S nix shell nixpkgs#bash nixpkgs#coreutils nixpkgs#git nixpkgs#gnused nixpkgs#jq --command bash

set -euo pipefail

# The workflow refresher is exercised against a local bare remote, a flake.lock naming
# flake-lib, and the fake nix that advances the lock to whatever revision it is told to.
# The templates come from a synthetic flake-lib source tree, because what matters is the
# repository's own state afterwards: which files a run installs, which values it carries,
# and which commit it reports for the rest of the run to build from.

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "${TEST_ROOT}"' EXIT

# This suite runs the script through bash for determinism; flake.nix's package wrapper
# execs it directly, so a missing executable bit breaks every producer's run and nothing
# here would notice.
[[ -x "${UPDATE_WORKFLOWS}" ]] || {
  printf 'refresher script is not executable, so the package wrapper cannot exec it: %s\n' "${UPDATE_WORKFLOWS}" >&2
  exit 1
}

rev_of() { printf '%s%.0s' "${1}" {1..40}; }

initialize_repository() {
  CASE_ROOT=$(mktemp -d "${TEST_ROOT}/case.XXXXXX")
  REMOTE="${CASE_ROOT}/remote.git"
  CHECKOUT="${CASE_ROOT}/checkout"
  LOCKED_REV=$(rev_of a)

  git init -q --bare "${REMOTE}"
  git init -q -b main "${CHECKOUT}"
  git -C "${CHECKOUT}" remote add origin "${REMOTE}"
  jq -nc --arg rev "${LOCKED_REV}" '{
    nodes: {
      root: {inputs: {"flake-lib": "flake-lib"}},
      "flake-lib": {locked: {type: "github", owner: "jgus-org", repo: "flake-lib", rev: $rev}}
    }
  }' >"${CHECKOUT}/flake.lock"
  git -C "${CHECKOUT}" add flake.lock
  git -C "${CHECKOUT}" -c user.name=test -c user.email=test@example.com commit -qm 'Track flake-lib'
  git -C "${CHECKOUT}" push -q -u origin main
}

install_workflow() {
  local NAME="${1}" BODY="${2}"
  mkdir -p "${CHECKOUT}/.github/workflows"
  printf '%s\n' "${BODY}" >"${CHECKOUT}/.github/workflows/${NAME}"
  git -C "${CHECKOUT}" add ".github/workflows/${NAME}"
  git -C "${CHECKOUT}" -c user.name=test -c user.email=test@example.com commit -qm "Install ${NAME}"
  git -C "${CHECKOUT}" push -q origin main
}

write_template() {
  local NAME="${1}" BODY="${2}"
  mkdir -p "${TEMPLATE_SOURCE}/templates/workflows"
  printf '%s\n' "${BODY}" >"${TEMPLATE_SOURCE}/templates/workflows/${NAME}"
}

run_refresher() {
  (
    cd "${CHECKOUT}"
    TEST_NIX_TEMPLATE_SOURCE="${TEMPLATE_SOURCE}" \
    TEST_NIX_FLAKE_LIB_REV="${ADVANCE_TO_REV}" \
    GITHUB_OUTPUT="${OUTPUTS}" \
    PUSH_RETRY_DELAY_SECONDS=0 \
    bash "${UPDATE_WORKFLOWS}" "$@"
  )
}

assert_committed_subject() {
  git --git-dir="${REMOTE}" log -1 --format=%s refs/heads/main | grep -qxF -- "${1}"
}

# A refresh replaces each templated workflow wholesale with the template's text: values the
# repository had placed in the workflow are discarded (they belong in flake.nix now, baked
# into the invoked package), a workflow flake-lib has no template for is left exactly as it
# is, and nothing the repository did not choose is installed.
TEMPLATE_SOURCE=$(mktemp -d "${TEST_ROOT}/flake-lib-src.XXXXXX")
initialize_repository
install_workflow update-branches.yml 'env:
  MINIMUM_TRACKING_VERSION: "3.1.4.1"
  TRACK_STABLE_ONLY: "true"'
install_workflow update-version.yml 'jobs:
  update:
    env:
      BUILD_ATTR: "wine-wineland"'
install_workflow release.yml 'name: release'
write_template update-branches.yml 'env:
  MINIMUM_TRACKING_VERSION: "0.0.0"
jobs:
  discover: {}'
write_template update-version.yml 'jobs:
  update:
    steps:
      - run: nix build --no-link -L ".#default"'
write_template needs-rebase.yml 'jobs:
  label: {}'
ADVANCE_TO_REV=$(rev_of b)
OUTPUTS="${CASE_ROOT}/outputs"
run_refresher
grep -Fq 'MINIMUM_TRACKING_VERSION: "0.0.0"' "${CHECKOUT}/.github/workflows/update-branches.yml"
grep -Fq 'discover: {}' "${CHECKOUT}/.github/workflows/update-branches.yml"
! grep -Fq '3.1.4.1' "${CHECKOUT}/.github/workflows/update-branches.yml"
! grep -Fq 'TRACK_STABLE_ONLY' "${CHECKOUT}/.github/workflows/update-branches.yml"
grep -Fq 'nix build --no-link -L ".#default"' "${CHECKOUT}/.github/workflows/update-version.yml"
! grep -Fq 'wine-wineland' "${CHECKOUT}/.github/workflows/update-version.yml"
grep -Fq 'name: release' "${CHECKOUT}/.github/workflows/release.yml"
[[ ! -e "${CHECKOUT}/.github/workflows/needs-rebase.yml" ]]
[[ "$(git --git-dir="${REMOTE}" show refs/heads/main:flake.lock | jq -r '.nodes["flake-lib"].locked.rev')" == "${ADVANCE_TO_REV}" ]]
assert_committed_subject "Update workflows from flake-lib ${ADVANCE_TO_REV}"
[[ "$(sed -nE 's/^sha=//p' "${OUTPUTS}")" == "$(git --git-dir="${REMOTE}" rev-parse refs/heads/main)" ]]

# Templates identical to what is installed still advance the locked flake-lib: the scripts
# a workflow invokes come from that revision, so a scripts-only fix is not discarded
# because no workflow file changed. The commit says so rather than claiming a refresh.
initialize_repository
install_workflow update-branches.yml 'env:
  MINIMUM_TRACKING_VERSION: "2.0.0"'
write_template update-branches.yml 'env:
  MINIMUM_TRACKING_VERSION: "2.0.0"'
ADVANCE_TO_REV=$(rev_of c)
OUTPUTS="${CASE_ROOT}/outputs"
run_refresher
grep -Fq 'MINIMUM_TRACKING_VERSION: "2.0.0"' "${CHECKOUT}/.github/workflows/update-branches.yml"
assert_committed_subject "Advance flake-lib to ${ADVANCE_TO_REV}"
[[ "$(sed -nE 's/^sha=//p' "${OUTPUTS}")" == "$(git --git-dir="${REMOTE}" rev-parse refs/heads/main)" ]]

# A repository whose workflows are all its own advances the input and leaves them alone,
# which is the same commit-with-a-SHA handoff rather than a silent no-op.
initialize_repository
install_workflow pages.yml 'on: push'
write_template update-branches.yml 'jobs: {}'
ADVANCE_TO_REV=$(rev_of d)
OUTPUTS="${CASE_ROOT}/outputs"
run_refresher
grep -Fq 'on: push' "${CHECKOUT}/.github/workflows/pages.yml"
assert_committed_subject "Advance flake-lib to ${ADVANCE_TO_REV}"
[[ "$(sed -nE 's/^sha=//p' "${OUTPUTS}")" == "$(git --git-dir="${REMOTE}" rev-parse refs/heads/main)" ]]

# flake-lib already at its newest revision, with every workflow already matching the template
# that revision ships, pushes nothing and reports no SHA, leaving the rest of the run on the
# revision it started from.
initialize_repository
install_workflow update-branches.yml 'env:
  MINIMUM_TRACKING_VERSION: "1.0.0"'
write_template update-branches.yml 'env:
  MINIMUM_TRACKING_VERSION: "1.0.0"'
UNCHANGED_SHA=$(git --git-dir="${REMOTE}" rev-parse refs/heads/main)
ADVANCE_TO_REV="${LOCKED_REV}"
OUTPUTS="${CASE_ROOT}/outputs"
run_refresher
[[ "$(git --git-dir="${REMOTE}" rev-parse refs/heads/main)" == "${UNCHANGED_SHA}" ]]
grep -Fq 'MINIMUM_TRACKING_VERSION: "1.0.0"' "${CHECKOUT}/.github/workflows/update-branches.yml"
[[ ! -s "${OUTPUTS}" ]]

# A lock that reached its revision without a refresh ever running -- the pin path advances
# flake-lib as it commits pins -- still gets the templates that revision ships, because what
# is compared is the installed file against the locked revision, not the revision the run
# started on. Without this the repository runs old workflow files against new scripts forever.
initialize_repository
install_workflow update-branches.yml 'env:
  MINIMUM_TRACKING_VERSION: "1.0.0"'
write_template update-branches.yml 'env:
  MINIMUM_TRACKING_VERSION: "9.9.9"'
ADVANCE_TO_REV="${LOCKED_REV}"
OUTPUTS="${CASE_ROOT}/outputs"
run_refresher
grep -Fq 'MINIMUM_TRACKING_VERSION: "9.9.9"' "${CHECKOUT}/.github/workflows/update-branches.yml"
assert_committed_subject "Update workflows from flake-lib ${LOCKED_REV}"
[[ "$(sed -nE 's/^sha=//p' "${OUTPUTS}")" == "$(git --git-dir="${REMOTE}" rev-parse refs/heads/main)" ]]

# Adopting is how a repository joins the tracked set, which is the upgrade path for a
# producer that lives only on GitHub and so has no local source to promote from. The
# author names the template; the tool installs exactly that one and reports the workflow
# it cannot refresh that is still in the way, rather than removing it.
initialize_repository
install_workflow update.yml 'on:
  schedule:
    - cron: "0 7 * * *"
jobs:
  update: {}'
write_template update-version.yml 'on:
  schedule:
    - cron: "0 7 * * *"
jobs:
  update:
    env:
      BUILD_ATTR: "default"'
ADVANCE_TO_REV=$(rev_of e)
OUTPUTS="${CASE_ROOT}/outputs"
RUN_REPORT=$(run_refresher adopt update-version.yml)
grep -Fq 'BUILD_ATTR: "default"' "${CHECKOUT}/.github/workflows/update-version.yml"
grep -Fq '.github/workflows/update.yml' <<<"${RUN_REPORT}"
grep -Fq 'jobs:' "${CHECKOUT}/.github/workflows/update.yml"
assert_committed_subject "Adopt flake-lib's update-version.yml at ${ADVANCE_TO_REV}"
[[ "$(sed -nE 's/^sha=//p' "${OUTPUTS}")" == "$(git --git-dir="${REMOTE}" rev-parse refs/heads/main)" ]]

# Adopting does not depend on the input moving: a repository joining at the revision it
# already locks gets the template, which is the case for a producer adopting flake-lib's
# model without a flake-lib change of its own.
initialize_repository
write_template update-version.yml 'jobs:
  update: {}'
UNCHANGED_SHA=$(git --git-dir="${REMOTE}" rev-parse refs/heads/main)
ADVANCE_TO_REV="${LOCKED_REV}"
OUTPUTS="${CASE_ROOT}/outputs"
run_refresher adopt update-version.yml >/dev/null
grep -Fq 'update: {}' "${CHECKOUT}/.github/workflows/update-version.yml"
assert_committed_subject "Adopt flake-lib's update-version.yml at ${LOCKED_REV}"
[[ "$(git --git-dir="${REMOTE}" rev-parse refs/heads/main)" != "${UNCHANGED_SHA}" ]]

# Adopting over a hand-written workflow of the same name replaces it wholesale: the
# template is the whole file, and per-producer knobs belong in flake.nix, not the workflow.
initialize_repository
install_workflow update-version.yml 'jobs:
  update:
    env:
      BUILD_ATTR: "lazylibrarian"'
write_template update-version.yml 'jobs:
  update:
    steps:
      - run: nix run .#update-version'
ADVANCE_TO_REV=$(rev_of f)
OUTPUTS="${CASE_ROOT}/outputs"
run_refresher adopt update-version.yml >/dev/null
grep -Fq 'nix run .#update-version' "${CHECKOUT}/.github/workflows/update-version.yml"
! grep -Fq 'lazylibrarian' "${CHECKOUT}/.github/workflows/update-version.yml"

# A name flake-lib ships no template for is refused without a commit, because the
# alternative is an empty or half-written workflow scheduled against a pin.
initialize_repository
write_template update-version.yml 'jobs: {}'
BEFORE_SHA=$(git --git-dir="${REMOTE}" rev-parse refs/heads/main)
ADVANCE_TO_REV=$(rev_of g)
OUTPUTS="${CASE_ROOT}/outputs"
if REFUSAL=$(run_refresher adopt nightly-scan.yml 2>&1 >/dev/null); then
  echo 'adopting a template flake-lib does not ship should have failed' >&2
  exit 1
fi
grep -Fq 'templates/workflows/nightly-scan.yml' <<<"${REFUSAL}"
[[ "$(git --git-dir="${REMOTE}" rev-parse refs/heads/main)" == "${BEFORE_SHA}" ]]
[[ ! -e "${CHECKOUT}/.github/workflows/nightly-scan.yml" ]]
