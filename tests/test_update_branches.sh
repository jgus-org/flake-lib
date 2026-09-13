#!/usr/bin/env -S nix shell nixpkgs#bash nixpkgs#coreutils nixpkgs#git --command bash

set -euo pipefail

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "${TEST_ROOT}"' EXIT

write_pin() {
  local FILE="${1}" VERSION="${2}" HASH="${3}"
  printf '%s\n' \
    '{' \
    "  version = \"${VERSION}\";" \
    "  assets.fixture = \"${HASH}\";" \
    '}' > "${FILE}"
}

initialize_repository() {
  CASE_ROOT=$(mktemp -d "${TEST_ROOT}/case.XXXXXX")
  REMOTE="${CASE_ROOT}/remote.git"
  CHECKOUT="${CASE_ROOT}/checkout"

  git init -q --bare "${REMOTE}"
  git init -q -b main "${CHECKOUT}"
  git -C "${CHECKOUT}" remote add origin "${REMOTE}"
  write_pin "${CHECKOUT}/pin.nix" "1.0.0" "original-hash"
  printf '%s\n' '{ "fixture": "original" }' > "${CHECKOUT}/flake.lock"
  printf '%s\n' 'pin.nix merge=ours' 'flake.lock merge=ours' > "${CHECKOUT}/.gitattributes"
  git -C "${CHECKOUT}" add pin.nix flake.lock .gitattributes
  git -C "${CHECKOUT}" -c user.name=test -c user.email=test@example.com commit -qm initial
  git -C "${CHECKOUT}" push -q -u origin main
}

seed_exact_branch() {
  local VERSION="${1}"
  git -C "${CHECKOUT}" switch -q -C "v${VERSION}" main
  write_pin "${CHECKOUT}/pin.nix" "${VERSION}" "original-hash"
  git -C "${CHECKOUT}" add pin.nix
  git -C "${CHECKOUT}" -c user.name=test -c user.email=test@example.com commit -qm "${VERSION}"
  git -C "${CHECKOUT}" push -q origin "v${VERSION}"
  git -C "${CHECKOUT}" switch -q main
}

point_aggregate() {
  local AGGREGATE="${1}" VERSION="${2}"
  git --git-dir="${REMOTE}" update-ref "refs/heads/${AGGREGATE}" "refs/heads/v${VERSION}"
}

invoke_update() {
  local VERSIONS="${1}" TAG_PREFIXES="${2}" FAILED_VERSIONS="${3}"
  local FAILED_REFRESH_VERSIONS="${4}"
  shift 4
  (
    cd "${CHECKOUT}"
    BRANCH_OWNED_FILES='pin.nix flake.lock' \
    GH_OWNER=example \
    GH_REPO=example \
    GH_TAG_PREFIXES="${TAG_PREFIXES}" \
    MINIMUM_TRACKING_VERSION=1.0.0 \
    MIN_VERSION_COMPONENTS=3 \
    PIN_SCHEMA=version-only \
    SOURCE_TYPE=github \
    TEST_VERSIONS="${VERSIONS}" \
    TEST_FAILED_VERSIONS="${FAILED_VERSIONS}" \
    TEST_FAILED_REFRESH_VERSIONS="${FAILED_REFRESH_VERSIONS}" \
    TEST_UPDATE_VERSION_LOG="${CASE_ROOT}/update-version.log" \
    VERSION_CANON='' \
    VERSION_OVERRIDES='{}' \
    bash "${UPDATE_BRANCHES_CORE}" "$@"
  )
}

run_update() {
  local VERSIONS="${1}" TAG_PREFIXES="${2:-[\"v\",\"V\",\"\"]}" FAILED_VERSIONS="${3:-}"
  local FAILED_REFRESH_VERSIONS="${4:-}"
  invoke_update "${VERSIONS}" "${TAG_PREFIXES}" "${FAILED_VERSIONS}" "${FAILED_REFRESH_VERSIONS}"
}

run_command() {
  local VERSIONS="${1}"
  shift
  invoke_update "${VERSIONS}" '["v","V",""]' '' '' "$@"
}

assert_ref_version() {
  local REF="${1}" VERSION="${2}"
  git --git-dir="${REMOTE}" show "refs/heads/${REF}:pin.nix" | grep -Fq "version = \"${VERSION}\";"
}

assert_same_ref() {
  local LEFT="${1}" RIGHT="${2}"
  [[ "$(git --git-dir="${REMOTE}" rev-parse "refs/heads/${LEFT}")" == "$(git --git-dir="${REMOTE}" rev-parse "refs/heads/${RIGHT}")" ]]
}

commit_specification() {
  git -C "${CHECKOUT}" fetch -q origin
  git -C "${CHECKOUT}" reset --hard -q origin/main
  printf '%s\n' 'new packaging patch' > "${CHECKOUT}/patch.fixture"
  git -C "${CHECKOUT}" add patch.fixture
  git -C "${CHECKOUT}" -c user.name=test -c user.email=test@example.com commit -qm 'Apply packaging patch'
  git -C "${CHECKOUT}" push -q origin main
  SPECIFICATION_SHA=$(git -C "${CHECKOUT}" rev-parse HEAD)
}

assert_contains_specification() {
  local REF="${1}"
  git --git-dir="${REMOTE}" merge-base --is-ancestor "${SPECIFICATION_SHA}" "refs/heads/${REF}"
  [[ "$(git --git-dir="${REMOTE}" show "refs/heads/${REF}:patch.fixture")" == 'new packaging patch' ]]
}

assert_ref_sha() {
  local REF="${1}" SHA="${2}"
  local ACTUAL_SHA
  ACTUAL_SHA=$(git --git-dir="${REMOTE}" rev-parse "refs/heads/${REF}")
  if [[ "${ACTUAL_SHA}" != "${SHA}" ]]; then
    echo "${REF}: expected ${SHA}, got ${ACTUAL_SHA}" >&2
    return 1
  fi
}

assert_missing_ref() {
  local REF="${1}"
  if git --git-dir="${REMOTE}" show-ref --verify --quiet "refs/heads/${REF}"; then
    echo "${REF}: expected no published branch" >&2
    return 1
  fi
}

run_failed_update() {
  local UPDATE_EXIT=0
  # Run outside a conditional: bash would otherwise disable errexit throughout run_update.
  set +e
  (set -e; run_update "$@") > "${CASE_ROOT}/update.log" 2>&1
  UPDATE_EXIT=$?
  set -e
  cat "${CASE_ROOT}/update.log"
  if [[ "${UPDATE_EXIT}" != 1 ]]; then
    echo "Expected updater exit 1, got ${UPDATE_EXIT}" >&2
    return 1
  fi
}

initialize_repository
run_update '1.2.3-rc1'
assert_same_ref v1.2 v1.2.3-rc1
assert_same_ref v1 v1.2.3-rc1
assert_ref_version main 1.0.0
assert_ref_version v1.2.3-rc1 1.2.3-rc1
git --git-dir="${REMOTE}" show 'refs/heads/v1.2.3-rc1:pin.nix' | grep -Fq 'assets.fixture = "updated-hash";'

initialize_repository
seed_exact_branch 1.2.3-rc1
point_aggregate v1.2 1.2.3-rc1
point_aggregate v1 1.2.3-rc1
point_aggregate main 1.2.3-rc1
run_update $'1.2.3-rc1\n1.2.4-rc1'
assert_same_ref v1.2 v1.2.4-rc1
assert_same_ref v1 v1.2.4-rc1
assert_same_ref main v1.2.4-rc1

initialize_repository
seed_exact_branch 1.2.1-rc1
seed_exact_branch 1.2.2
point_aggregate v1.2 1.2.1-rc1
point_aggregate v1 1.2.2
point_aggregate main 1.2.2
run_update $'1.2.1-rc1\n1.2.2\n1.2.3-rc1'
assert_same_ref v1.2 v1.2.3-rc1
assert_same_ref v1 v1.2.2
assert_same_ref main v1.2.2

initialize_repository
seed_exact_branch 1.2.3-rc1
point_aggregate v1.2 1.2.3-rc1
point_aggregate v1 1.2.3-rc1
point_aggregate main 1.2.3-rc1
run_update $'1.2.3-rc1\n1.2.3'
assert_same_ref v1.2 v1.2.3
assert_same_ref v1 v1.2.3
assert_same_ref main v1.2.3

# An older branch's failed input refresh must not run its version updater or publish its partial lockfile; a newer healthy branch still advances main.
initialize_repository
seed_exact_branch 1.1.0
seed_exact_branch 1.2.0
point_aggregate v1.1 1.1.0
point_aggregate main 1.2.0
OLD_EXACT_SHA=$(git --git-dir="${REMOTE}" rev-parse refs/heads/v1.1.0)
commit_specification
export GITHUB_STEP_SUMMARY="${CASE_ROOT}/summary.md"
run_failed_update $'1.1.0\n1.2.0' '["v",""]' '' '1.1.0'
assert_ref_sha v1.1.0 "${OLD_EXACT_SHA}"
assert_ref_sha v1.1 "${OLD_EXACT_SHA}"
assert_contains_specification main
assert_same_ref main v1.2.0
assert_same_ref v1 v1.2.0
assert_same_ref v1.2 v1.2.0
[[ "$(cat "${CASE_ROOT}/update-version.log")" == '1.2.0' ]]
grep -Fq 'nix flake update failed for 1.1.0 (exit 42)' "${CASE_ROOT}/update.log"
grep -Fqx -- "- \`v1.1.0\`: nix flake update failed (exit 42)" "${GITHUB_STEP_SUMMARY}"
unset GITHUB_STEP_SUMMARY

# A failed input refresh on the only new branch leaves both its partial lockfile and the version updater unpublished.
initialize_repository
commit_specification
export GITHUB_STEP_SUMMARY="${CASE_ROOT}/summary.md"
run_failed_update '1.2.0' '["v",""]' '' '1.2.0'
assert_ref_sha main "${SPECIFICATION_SHA}"
assert_missing_ref v1.2.0
assert_missing_ref v1.2
assert_missing_ref v1
[[ ! -e "${CASE_ROOT}/update-version.log" ]]
grep -Fqx -- "- \`v1.2.0\`: nix flake update failed (exit 42)" "${GITHUB_STEP_SUMMARY}"
unset GITHUB_STEP_SUMMARY

# A failed existing exact branch must not roll back the specification. Aggregates shared with a lower successful stable advance to that successful branch.
initialize_repository
seed_exact_branch 1.1.0
seed_exact_branch 1.2.0
point_aggregate v1.1 1.1.0
point_aggregate v1.2 1.2.0
point_aggregate v1 1.2.0
point_aggregate main 1.2.0
OLD_EXACT_SHA=$(git --git-dir="${REMOTE}" rev-parse refs/heads/v1.2.0)
commit_specification
run_failed_update $'1.1.0\n1.2.0\n1.3.0-rc1' '["v",""]' '1.2.0'
assert_contains_specification main
assert_same_ref main v1.1.0
assert_ref_sha v1.2.0 "${OLD_EXACT_SHA}"
assert_ref_sha v1.2 "${OLD_EXACT_SHA}"
assert_same_ref v1 v1.1.0
assert_contains_specification v1.1.0
assert_same_ref v1.1 v1.1.0
assert_contains_specification v1.3.0-rc1
assert_same_ref v1.3 v1.3.0-rc1

# A failed new branch has no published target; the successful version can still advance all its aggregates.
initialize_repository
seed_exact_branch 1.1.0
point_aggregate main 1.1.0
commit_specification
run_failed_update $'1.1.0\n1.2.0' '["v",""]' '1.2.0'
assert_missing_ref v1.2.0
assert_contains_specification main
assert_same_ref main v1.1.0
assert_same_ref v1 v1.1.0
assert_same_ref v1.1 v1.1.0

# When all existing versions fail, retain the new specification and leave the exact branches untouched.
initialize_repository
seed_exact_branch 1.2.0
point_aggregate main 1.2.0
OLD_EXACT_SHA=$(git --git-dir="${REMOTE}" rev-parse refs/heads/v1.2.0)
commit_specification
export GITHUB_STEP_SUMMARY="${CASE_ROOT}/summary.md"
run_failed_update '1.2.0' '["v",""]' '1.2.0'
assert_ref_sha main "${SPECIFICATION_SHA}"
assert_ref_sha v1.2.0 "${OLD_EXACT_SHA}"
assert_missing_ref v1
grep -Fqx -- "- \`v1.2.0\`: update-version failed (exit 1)" "${GITHUB_STEP_SUMMARY}"
unset GITHUB_STEP_SUMMARY

# A successful prerelease must not select its failed stable counterpart when choosing aggregate targets.
initialize_repository
seed_exact_branch 1.2.3
point_aggregate main 1.2.3
commit_specification
run_failed_update $'1.2.3\n1.2.3-rc1' '["v",""]' '1.2.3'
assert_ref_sha main "${SPECIFICATION_SHA}"
assert_contains_specification v1.2.3-rc1
assert_same_ref v1.2 v1.2.3-rc1

# Keeping an aggregate stable can choose an exact branch outside the tracked set. It also needs the specification, even when every attempted update succeeded.
initialize_repository
seed_exact_branch 1.1.0
point_aggregate main 1.1.0
commit_specification
export GITHUB_STEP_SUMMARY="${CASE_ROOT}/summary.md"
run_failed_update '1.2.0-rc1'
assert_ref_sha main "${SPECIFICATION_SHA}"
assert_contains_specification v1.2.0-rc1
assert_same_ref v1.2 v1.2.0-rc1
assert_same_ref v1 v1.2.0-rc1
grep -Fq 'main' "${GITHUB_STEP_SUMMARY}"
unset GITHUB_STEP_SUMMARY

# Successful refreshes publish the specification and remain idempotent on the next run.
initialize_repository
seed_exact_branch 1.2.0
point_aggregate main 1.2.0
commit_specification
run_update '1.2.0'
assert_contains_specification main
assert_same_ref main v1.2.0
assert_same_ref v1 v1.2.0
assert_same_ref v1.2 v1.2.0
PUBLISHED_SHA=$(git --git-dir="${REMOTE}" rev-parse refs/heads/main)
run_update '1.2.0'
assert_ref_sha main "${PUBLISHED_SHA}"

initialize_repository
run_update $'V1.2.2\nv1.2.3'
assert_same_ref v1.2 v1.2.3
assert_same_ref v1 v1.2.3
assert_same_ref main v1.2.3

initialize_repository
run_update $'v9.9.9\nrust-v1.2.3' '["rust-v"]'
assert_same_ref v1.2 v1.2.3
assert_same_ref v1 v1.2.3
assert_same_ref main v1.2.3

# Discovery is clean JSON, newest-first, and carries one immutable specification SHA plus the canonical/raw version mapping.
initialize_repository
seed_exact_branch 1.2.1
seed_exact_branch 1.2.2
point_aggregate v1.2 1.2.2
point_aggregate v1 1.2.2
point_aggregate main 1.2.2
commit_specification
UNREFRESHED_SHA=$(git --git-dir="${REMOTE}" rev-parse refs/heads/v1.2.1)
VERSIONS=$'1.2.1\n1.2.2\n1.2.3\n1.3.0-rc1'
PLAN=$(run_command "${VERSIONS}" list)
BASE_SHA=$(jq -r '.baseSha' <<<"${PLAN}")
VERSIONS_JSON=$(jq -c '.versions' <<<"${PLAN}")
[[ "${BASE_SHA}" == "${SPECIFICATION_SHA}" ]]
[[ "$(jq -c '[.versions[].version]' <<<"${PLAN}")" == '["1.3.0-rc1","1.2.3","1.2.2","1.2.1"]' ]]
jq -e '.newestStable == {version:"1.2.3", upstreamVersion:"1.2.3", stable:true}' <<<"${PLAN}" >/dev/null

# A per-version invocation refreshes only the requested exact branch. Publishing can then advance main before the higher prerelease maintenance job has run.
run_command "${VERSIONS}" refresh \
  --base-sha "${BASE_SHA}" \
  --version 1.2.3 \
  --upstream-version 1.2.3
[[ "$(cat "${CASE_ROOT}/update-version.log")" == '1.2.3' ]]
assert_ref_sha v1.2.1 "${UNREFRESHED_SHA}"
assert_missing_ref v1.3.0-rc1
run_command "${VERSIONS}" publish --base-sha "${BASE_SHA}" --versions-json "${VERSIONS_JSON}"
assert_same_ref main v1.2.3
assert_same_ref v1 v1.2.3
assert_same_ref v1.2 v1.2.3
assert_missing_ref v1.3.0-rc1

# Even after early publication moves main, the later exact job branches from the discovery SHA, not the live main aggregate. The final publisher guards that same SHA and keeps stable aggregates on the highest successful stable.
STABLE_SHA=$(git --git-dir="${REMOTE}" rev-parse refs/heads/v1.2.3)
run_command "${VERSIONS}" refresh \
  --base-sha "${BASE_SHA}" \
  --version 1.2.1 \
  --upstream-version 1.2.1
assert_contains_specification v1.2.1
if git --git-dir="${REMOTE}" merge-base --is-ancestor "${STABLE_SHA}" refs/heads/v1.2.1; then
  echo 'v1.2.1 unexpectedly merged the early-published main target' >&2
  exit 1
fi
run_command "${VERSIONS}" refresh \
  --base-sha "${BASE_SHA}" \
  --version 1.3.0-rc1 \
  --upstream-version 1.3.0-rc1
assert_contains_specification v1.3.0-rc1
if git --git-dir="${REMOTE}" merge-base --is-ancestor "${STABLE_SHA}" refs/heads/v1.3.0-rc1; then
  echo 'v1.3.0-rc1 unexpectedly branched from the early-published main target' >&2
  exit 1
fi
run_command "${VERSIONS}" publish --base-sha "${BASE_SHA}" --versions-json "${VERSIONS_JSON}"
assert_same_ref main v1.2.3
assert_same_ref v1 v1.2.3
assert_same_ref v1.2 v1.2.3
assert_same_ref v1.3 v1.3.0-rc1

# GitHub tags accepted by the existing version grammar are retained even when they are not PEP 440; a final release sorts ahead of its same-core prerelease.
initialize_repository
PLAN=$(run_command $'1.2.3-ubuntu1\n1.2.3' list)
[[ "$(jq -c '[.versions[].version]' <<<"${PLAN}")" == '["1.2.3","1.2.3-ubuntu1"]' ]]
jq -e '.newestStable.version == "1.2.3"' <<<"${PLAN}" >/dev/null
