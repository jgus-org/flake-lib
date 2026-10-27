#!/usr/bin/env -S nix shell nixpkgs#bash nixpkgs#coreutils nixpkgs#git nixpkgs#gnused nixpkgs#jq --command bash

set -euo pipefail

# The workflow refresher is exercised against a local bare remote, a flake.lock naming
# flake-lib, and the fake nix that advances the lock to whatever revision it is told to.
# The templates come from a synthetic flake-lib source tree, because what matters is the
# repository's own state afterwards: which files a run installs, which values it carries,
# what it reports having committed, and which notes it raises about what it cannot refresh.

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "${TEST_ROOT}"' EXIT

# This suite runs the script through bash for determinism; flake.nix's package wrapper
# execs it directly, so a missing executable bit breaks every producer's run and nothing
# here would notice.
[[ -x ${UPDATE_WORKFLOWS} ]] || {
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

# The refresh names the files its commit carried on the last line of its log and writes
# nothing to the run's output at all. The sha it used to emit existed only so a later job of
# the same run could check out the commit it had just pushed; the refresh is a workflow of
# its own now, so no job shares a run with it.
assert_committed_report() {
  local REPORT="${1}" COUNT="${2}" FILES="${3}"
  [[ "$(tail -n1 <<<"${REPORT}")" == "Committed ${COUNT} file(s) from flake-lib jgus-org/flake-lib/${ADVANCE_TO_REV}: ${FILES}" ]]
}

assert_no_run_output() {
  [[ ! -e ${OUTPUTS} ]]
}

# A scheduled workflow with no refresher installed to rewrite it follows no schedule at all,
# so the refresh reports the gap rather than leaving the repository quietly stale.
REFRESH_NOTE='note: no update-workflows.yml is installed here, so nothing refreshes these workflows on a schedule.'
# The adopt note lists what is still in the way. The refresher's own workflow is exempt: it
# writes the same branch by design and shares the update workflows' concurrency group.
ADOPT_NOTE='note: adopt also carries a schedule, and a workflow flake-lib has no template for is never refreshed:'

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
RUN_REPORT=$(run_refresher)
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
assert_committed_report "${RUN_REPORT}" 3 '.github/workflows/update-branches.yml .github/workflows/update-version.yml flake.lock'
assert_no_run_output

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
RUN_REPORT=$(run_refresher)
grep -Fq 'MINIMUM_TRACKING_VERSION: "2.0.0"' "${CHECKOUT}/.github/workflows/update-branches.yml"
assert_committed_subject "Advance flake-lib to ${ADVANCE_TO_REV}"
assert_committed_report "${RUN_REPORT}" 1 'flake.lock'
assert_no_run_output

# A repository whose workflows are all its own advances the input and leaves them alone,
# which is a committed input advance reported like any other rather than a silent no-op.
initialize_repository
install_workflow pages.yml 'on: push'
write_template update-branches.yml 'jobs: {}'
ADVANCE_TO_REV=$(rev_of d)
OUTPUTS="${CASE_ROOT}/outputs"
RUN_REPORT=$(run_refresher)
grep -Fq 'on: push' "${CHECKOUT}/.github/workflows/pages.yml"
assert_committed_subject "Advance flake-lib to ${ADVANCE_TO_REV}"
assert_committed_report "${RUN_REPORT}" 1 'flake.lock'
assert_no_run_output
grep -Fq "no workflow here was installed from flake-lib's templates/workflows; only the input advances." <<<"${RUN_REPORT}"

# flake-lib already at its newest revision, with every workflow already matching the template
# that revision ships, pushes nothing and produces no run output, leaving the repository on
# the revision it started from.
initialize_repository
install_workflow update-branches.yml 'env:
  MINIMUM_TRACKING_VERSION: "1.0.0"'
write_template update-branches.yml 'env:
  MINIMUM_TRACKING_VERSION: "1.0.0"'
UNCHANGED_SHA=$(git --git-dir="${REMOTE}" rev-parse refs/heads/main)
ADVANCE_TO_REV="${LOCKED_REV}"
OUTPUTS="${CASE_ROOT}/outputs"
RUN_REPORT=$(run_refresher)
[[ "$(git --git-dir="${REMOTE}" rev-parse refs/heads/main)" == "${UNCHANGED_SHA}" ]]
grep -Fq 'MINIMUM_TRACKING_VERSION: "1.0.0"' "${CHECKOUT}/.github/workflows/update-branches.yml"
assert_no_run_output
grep -Fq 'changed neither the installed workflows nor this flake' <<<"${RUN_REPORT}"

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
RUN_REPORT=$(run_refresher)
grep -Fq 'MINIMUM_TRACKING_VERSION: "9.9.9"' "${CHECKOUT}/.github/workflows/update-branches.yml"
assert_committed_subject "Update workflows from flake-lib ${LOCKED_REV}"
# The input was already at the revision the templates come from, so the commit is the
# rewritten workflow alone; the subject says "Update workflows", not "Advance flake-lib".
assert_committed_report "${RUN_REPORT}" 1 '.github/workflows/update-branches.yml'
assert_no_run_output

# A refresh that installs a scheduled workflow into a repository with no update-workflows.yml
# leaves that workflow following no schedule: the daily update workflow advances flake-lib as
# it pins, so the templates the new revision ships are never installed. The note names the
# gap once, however many scheduled workflows the run just wrote.
initialize_repository
install_workflow update-version.yml 'jobs:
  update: {}'
install_workflow update-branches.yml 'jobs:
  discover: {}'
write_template update-version.yml 'on:
  schedule:
    - cron: "0 7 * * *"
jobs:
  update: {}'
write_template update-branches.yml 'on:
  schedule:
    - cron: "0 7 * * *"
jobs:
  discover: {}'
ADVANCE_TO_REV=$(rev_of h)
OUTPUTS="${CASE_ROOT}/outputs"
RUN_REPORT=$(run_refresher)
[[ "$(grep -cF -- "${REFRESH_NOTE}" <<<"${RUN_REPORT}")" == 1 ]]
assert_committed_subject "Update workflows from flake-lib ${ADVANCE_TO_REV}"
assert_no_run_output

# With the refresher's own workflow installed the same repository has a schedule that will
# rewrite what this run just wrote, so the note would be wrong. The refresher refreshes that
# file like any other templated workflow, including the schedule it carries.
initialize_repository
install_workflow update-version.yml 'jobs:
  update: {}'
install_workflow update-workflows.yml 'on:
  schedule:
    - cron: "0 5 * * *"
jobs:
  workflows: {}'
write_template update-version.yml 'on:
  schedule:
    - cron: "0 7 * * *"
jobs:
  update: {}'
write_template update-workflows.yml 'on:
  schedule:
    - cron: "0 6 * * *"
jobs:
  workflows: {}'
ADVANCE_TO_REV=$(rev_of i)
OUTPUTS="${CASE_ROOT}/outputs"
RUN_REPORT=$(run_refresher)
grep -Fq 'cron: "0 6 * * *"' "${CHECKOUT}/.github/workflows/update-workflows.yml"
! grep -Fq '0 5 * * *' "${CHECKOUT}/.github/workflows/update-workflows.yml"
assert_committed_subject "Update workflows from flake-lib ${ADVANCE_TO_REV}"
! grep -Fq -- "${REFRESH_NOTE}" <<<"${RUN_REPORT}"
assert_no_run_output

# A repository whose only templated workflow is the pull-request gate has nothing installed
# that runs on a schedule at all, so there is no gap for the note to name.
initialize_repository
install_workflow build-and-check.yml 'jobs:
  check: {}'
write_template build-and-check.yml 'jobs:
  check:
    runs-on: ubuntu-latest'
ADVANCE_TO_REV=$(rev_of j)
OUTPUTS="${CASE_ROOT}/outputs"
RUN_REPORT=$(run_refresher)
grep -Fq 'runs-on: ubuntu-latest' "${CHECKOUT}/.github/workflows/build-and-check.yml"
assert_committed_subject "Update workflows from flake-lib ${ADVANCE_TO_REV}"
! grep -Fq -- "${REFRESH_NOTE}" <<<"${RUN_REPORT}"
assert_no_run_output

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
grep -Fxq -- "${ADOPT_NOTE} .github/workflows/update.yml" <<<"${RUN_REPORT}"
grep -Fq 'jobs:' "${CHECKOUT}/.github/workflows/update.yml"
assert_committed_subject "Adopt flake-lib's update-version.yml at ${ADVANCE_TO_REV}"
assert_no_run_output

# The refresher's own workflow shares the update workflows' concurrency group and writes the
# same branch by design, so it is never what is in the way and the adopt note stays quiet.
initialize_repository
install_workflow update-workflows.yml 'on:
  schedule:
    - cron: "0 6 * * *"
jobs:
  workflows: {}'
write_template update-version.yml 'on:
  schedule:
    - cron: "0 7 * * *"
jobs:
  update: {}'
ADVANCE_TO_REV=$(rev_of k)
OUTPUTS="${CASE_ROOT}/outputs"
RUN_REPORT=$(run_refresher adopt update-version.yml)
grep -Fq 'update: {}' "${CHECKOUT}/.github/workflows/update-version.yml"
! grep -Fq 'never refreshed' <<<"${RUN_REPORT}"
assert_committed_subject "Adopt flake-lib's update-version.yml at ${ADVANCE_TO_REV}"
assert_no_run_output

# The exemption is that one file: a scheduled workflow flake-lib has no template for is still
# named, even alongside the refresher's own workflow.
initialize_repository
install_workflow update-workflows.yml 'on:
  schedule:
    - cron: "0 6 * * *"
jobs:
  workflows: {}'
install_workflow update.yml 'on:
  schedule:
    - cron: "0 7 * * *"
jobs:
  update: {}'
write_template update-version.yml 'jobs:
  update: {}'
ADVANCE_TO_REV=$(rev_of l)
OUTPUTS="${CASE_ROOT}/outputs"
RUN_REPORT=$(run_refresher adopt update-version.yml)
grep -Fxq -- "${ADOPT_NOTE} .github/workflows/update.yml" <<<"${RUN_REPORT}"
assert_committed_subject "Adopt flake-lib's update-version.yml at ${ADVANCE_TO_REV}"
assert_no_run_output

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
assert_no_run_output

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
assert_no_run_output

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

# The push goes out with the credential the job's checkout configured, whatever shape that
# takes: checkout@v7 writes it to a separate file and reaches it with an includeIf keyed to
# the git directory, where a read of the repository's own config file does not see it. The
# push is intercepted and the credential visible at that moment is recorded, because a second
# one -- from any extraHeader installed or layered on for the push -- reaches the same
# request, and the server refuses the request rather than choose between them.
source "${GIT_PUSH_LIB}"

PUSH_CASE=$(mktemp -d "${TEST_ROOT}/push-identity.XXXXXX")
git init -q "${PUSH_CASE}"
git -C "${PUSH_CASE}" remote add origin https://github.com/o/r
git -C "${PUSH_CASE}" -c user.name=test -c user.email=test@example.com commit -q --allow-empty -m 'base'
HEAD_SHA=$(git -C "${PUSH_CASE}" rev-parse HEAD)
CHECKOUT_CREDENTIAL='AUTHORIZATION: basic UnVuQ3JlZGVudGlhbA=='
CHECKOUT_CREDENTIALS_FILE="${TEST_ROOT}/checkout-credentials"
printf '[http "https://github.com/"]\n\textraHeader = %s\n' "${CHECKOUT_CREDENTIAL}" >"${CHECKOUT_CREDENTIALS_FILE}"
git -C "${PUSH_CASE}" config "includeIf.gitdir:${PUSH_CASE}/.git.path" "${CHECKOUT_CREDENTIALS_FILE}"
CONFIG_PATH="${PUSH_CASE}/.git/config"
CONFIG_BEFORE="${TEST_ROOT}/config.before"
cp "${CONFIG_PATH}" "${CONFIG_BEFORE}"
[[ "$(git -C "${PUSH_CASE}" config --get-regexp '^http\..*\.extraheader$' | wc -l)" == 1 ]]

STUB_BIN=$(mktemp -d "${TEST_ROOT}/stub.XXXXXX")
PUSH_ARGV="${TEST_ROOT}/push-argv"
PUSH_CREDENTIALS="${TEST_ROOT}/push-credentials"
REAL_GIT=$(command -v git)
cat >"${STUB_BIN}/git" <<STUB
#!$(command -v bash)
if [[ "\${1}" == '-c' || "\${1}" == 'push' ]]; then
  printf '%s\\0' "\${@}" >"\${PUSH_ARGV}"
  # Effective configuration, not --local: checkout@v7 keeps the credential in a separate
  # file that this repository's config includes, and both reach the request.
  "\${REAL_GIT}" config --get-regexp '^http\\..*\\.extraheader\$' >"\${PUSH_CREDENTIALS}"
  exit 0
fi
exec "\${REAL_GIT}" "\${@}"
STUB
chmod +x "${STUB_BIN}/git"

(
  cd "${PUSH_CASE}"
  export PUSH_ARGV PUSH_CREDENTIALS REAL_GIT
  PATH="${STUB_BIN}:${PATH}"
  # A caller that offers the push its own token is refused the same way the server would
  # refuse it, so the shape that caused the duplicate header cannot come back unnoticed.
  GIT_PUSH_TOKEN='pusher-token' \
    PUSH_MAX_ATTEMPTS=1 PUSH_RETRY_DELAY_SECONDS=0 \
    push_ref HEAD main "${HEAD_SHA}" lease
)
mapfile -t -d '' PUSH_INVOCATION <"${PUSH_ARGV}"

if [[ "$(wc -l <"${PUSH_CREDENTIALS}")" != 1 ]]; then
  printf 'the push had %s credentials visible, so the server refuses it: %s\n' \
    "$(wc -l <"${PUSH_CREDENTIALS}")" "$(tr '\n' '|' <"${PUSH_CREDENTIALS}")" >&2
  exit 1
fi
[[ "$(cut -d' ' -f2- "${PUSH_CREDENTIALS}")" == "${CHECKOUT_CREDENTIAL}" ]] || {
  printf 'the push would not have carried the credential this job checked out with\n' >&2
  exit 1
}
if printf '%s\n' "${PUSH_INVOCATION[@]}" | grep -qx -- '-c'; then
  printf 'the push carried a credential override of its own: %s\n' "${PUSH_INVOCATION[*]}" >&2
  exit 1
fi
[[ " ${PUSH_INVOCATION[*]} " == *' origin '* ]]
[[ " ${PUSH_INVOCATION[*]} " == *'--force-with-lease=refs/heads/main:'* ]] || {
  printf 'the refresh must push under a lease on the branch it read\n' >&2
  exit 1
}
[[ "$(cat "${CONFIG_PATH}")" == "$(cat "${CONFIG_BEFORE}")" ]] || {
  printf 'the push rewrote the repository configuration\n' >&2
  exit 1
}
