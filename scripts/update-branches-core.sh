#!/usr/bin/env -S nix shell nixpkgs#bash nixpkgs#git nixpkgs#curl nixpkgs#gh nixpkgs#jq nixpkgs#gnused nixpkgs#gnugrep nixpkgs#nix nixpkgs#coreutils --command bash

# Per-version branch orchestrator. It supports both a backwards-compatible
# all-in-one invocation and job-splittable discovery, exact-refresh, and
# aggregate-publication commands.
#
# For each upstream version >= $MINIMUM_TRACKING_VERSION, ensures:
#   - an exact branch `v<M>.<m>.<p>` exists and its pin is hash-validated
#   - aggregate pointer branches `v<M>.<m>`, `v<M>`, `main` are force-pushed to the highest matching exact branch (only the levels shorter than a version's component count; `main` always)
#
# Single knob: $MINIMUM_TRACKING_VERSION. Permanent pins are done via git tags (which the action never touches); there is no in-band freeze list.
#
# Each existing exact branch is `git merge`d with the immutable specification SHA captured by discovery before its update-version runs. Branch-owned files (pin.nix, flake.lock, the wheelhouse artifacts, ...) stay as-is: ensure_owned_merge_attributes keeps their `merge=ours` declarations in .gitattributes in step with BRANCH_OWNED_FILES. The shared scripts come from the flake-lib input, so the per-branch `nix flake update` below picks up their improvements automatically.
#
# Failures: per-branch input-refresh or update-version failures and aggregate targets missing the discovery base commit are surfaced as GH Actions ::warning::
# annotations + a step summary, and cause a non-zero exit at the end of the run. An aggregate whose current tip is reachable from neither the new target nor
# any tracked exact branch is likewise retained: advancing it would orphan commits that exist only on the aggregate.
#
# Per-flake variation is driven by env vars injected by flake-lib's mkUpdateBranches:
#   SOURCE_TYPE          pypi | github | github-release-asset  (gitlab leaves are single-branch, no orchestrator)
#   PYPI_NAME            [pypi]
#   PYPI_FORMAT          sdist | wheel  [pypi]
#   GH_OWNER/GH_REPO     [github, github-release-asset]
#   PIN_SCHEMA           pypi | github | github-npm | github-pnpm | github-yarn | github-asset | version-only
#   BRANCH_OWNED_FILES   space-separated files update-version mutates per branch
#   VERSION_OVERRIDES    JSON map raw version -> canonical version
#   VERSION_CANON        newline-separated `sed -E` rules mapping raw version -> canonical version
#   MIN_VERSION_COMPONENTS  fewest dot-separated numeric components a tag may have and still be tracked (default 3)

set -euo pipefail
: "${MINIMUM_TRACKING_VERSION:?required env var}"
MIN_VERSION_COMPONENTS="${MIN_VERSION_COMPONENTS:-3}"
GH_TAG_PREFIXES="${GH_TAG_PREFIXES:-[\"v\",\"V\",\"\"]}"
mapfile -t GITHUB_TAG_PREFIXES < <(jq -r '.[]' <<<"${GH_TAG_PREFIXES}")

FLAKE_ROOT="${FLAKE_ROOT:-${PWD}}"
cd "${FLAKE_ROOT}"

PUSH_MAX_ATTEMPTS="${PUSH_MAX_ATTEMPTS:-5}"
PUSH_RETRY_DELAY_SECONDS="${PUSH_RETRY_DELAY_SECONDS:-5}"
TRANSIENT_MAX_ATTEMPTS="${TRANSIENT_MAX_ATTEMPTS:-2}"
TRANSIENT_RETRY_DELAY_SECONDS="${TRANSIENT_RETRY_DELAY_SECONDS:-5}"
GITHUB_REF_MAX_ATTEMPTS="${GITHUB_REF_MAX_ATTEMPTS:-3}"
GITHUB_REF_RETRY_DELAY_SECONDS="${GITHUB_REF_RETRY_DELAY_SECONDS:-30}"
if [[ ! "${PUSH_MAX_ATTEMPTS}" =~ ^[1-9][0-9]*$ || ! "${TRANSIENT_MAX_ATTEMPTS}" =~ ^[1-9][0-9]*$ || ! "${GITHUB_REF_MAX_ATTEMPTS}" =~ ^[1-9][0-9]*$ ]]; then
  echo "error: retry attempt counts must be positive integers" >&2
  exit 2
fi

# Buffers output and emits it only on success, so a consumer never sees partial data from an attempt that died mid-stream (e.g. gh --paginate failing between pages).
retry() {
  local attempt output
  for attempt in 1 2 3 4 5; do
    if output=$("$@"); then
      [[ -z "${output}" ]] || printf '%s\n' "${output}"
      return 0
    fi
    if (( attempt < 5 )); then
      echo "  ${1} failed (attempt ${attempt}/5); retrying in 5s..." >&2
      sleep 5
    fi
  done
  echo "  ${1} failed after 5 attempts" >&2
  return 1
}

remote_ref_sha() {
  local ref="${1}" output
  if ! output=$(git ls-remote --heads origin "refs/heads/${ref}"); then
    return 1
  fi
  printf '%s\n' "${output%%[[:space:]]*}"
}

# A failed push can be ambiguous: the server may have updated the ref before
# returning an error. Re-read the remote before retrying. Treat the desired SHA
# as success, retry only while the ref remains at the expected SHA, and never
# overwrite a genuinely different concurrent update.
push_ref() {
  local source="${1}" ref="${2}" expected_sha="${3}" mode="${4}"
  local attempt desired_sha remote_sha="" query_exit=0
  desired_sha=$(git rev-parse --verify "${source}^{commit}")

  for ((attempt = 1; attempt <= PUSH_MAX_ATTEMPTS; attempt++)); do
    if [[ "${mode}" == lease ]]; then
      if git push --force-with-lease="refs/heads/${ref}:${expected_sha}" --quiet origin "${desired_sha}:refs/heads/${ref}"; then
        return 0
      fi
    elif git push --quiet origin "${desired_sha}:refs/heads/${ref}"; then
      return 0
    fi

    query_exit=0
    remote_sha=$(remote_ref_sha "${ref}") || query_exit=$?
    if (( query_exit == 0 )); then
      if [[ "${remote_sha}" == "${desired_sha}" ]]; then
        echo "  ${ref} reached ${desired_sha:0:8} despite the push error; continuing."
        return 0
      fi
      if [[ "${remote_sha}" != "${expected_sha}" ]]; then
        echo "error: ${ref} changed concurrently (expected ${expected_sha:-absent}, found ${remote_sha:-absent}); refusing to overwrite it" >&2
        return 1
      fi
    fi

    if (( attempt < PUSH_MAX_ATTEMPTS )); then
      echo "  push of ${ref} failed (attempt ${attempt}/${PUSH_MAX_ATTEMPTS}); retrying in ${PUSH_RETRY_DELAY_SECONDS}s..." >&2
      sleep "${PUSH_RETRY_DELAY_SECONDS}"
    fi
  done
  echo "error: push of ${ref} failed after ${PUSH_MAX_ATTEMPTS} attempts" >&2
  return 1
}

transient_failure_kind() {
  local log="${1}"
  if grep -Fqi 'No commit found for SHA' "${log}"; then
    echo github-ref
    return 0
  fi
  if grep -Eiq '(requested URL returned error: (429|5[0-9]{2})|HTTP[^[:space:]]* (429|5[0-9]{2})|Internal Server Error|Could not resolve host|Failed to connect|Connection reset by peer|Operation timed out|TLS connect error|Temporary failure in name resolution)' "${log}"; then
    echo network
    return 0
  fi
  return 1
}

# Branch updates run in disposable worktrees, so retrying the whole command is
# safe. Keep this deliberately narrow: explicit transient network errors get one
# fast retry; GitHub's "No commit found for SHA" (the commits API lagging behind
# a just-pushed ref) gets a longer bounded wait; deterministic build/update
# failures return at once.
run_with_transient_retry() {
  local label="${1}" kind exit_code=0 log
  local -i network_failures=0 github_ref_failures=0
  local attempt_count attempt_limit delay_seconds failure_text
  shift
  log=$(mktemp)
  while :; do
    : > "${log}"
    set +e
    "$@" 2>&1 | tee "${log}"
    exit_code=${PIPESTATUS[0]}
    set -e
    if (( exit_code == 0 )); then
      rm -f "${log}"
      return 0
    fi
    if ! kind=$(transient_failure_kind "${log}"); then
      rm -f "${log}"
      return "${exit_code}"
    fi
    rm -f "${log}"
    case "${kind}" in
      network)
        network_failures+=1
        attempt_count="${network_failures}"
        attempt_limit="${TRANSIENT_MAX_ATTEMPTS}"
        delay_seconds="${TRANSIENT_RETRY_DELAY_SECONDS}"
        failure_text="a transient network error"
        ;;
      github-ref)
        github_ref_failures+=1
        attempt_count="${github_ref_failures}"
        attempt_limit="${GITHUB_REF_MAX_ATTEMPTS}"
        delay_seconds="${GITHUB_REF_RETRY_DELAY_SECONDS}"
        failure_text="a not-yet-visible GitHub ref"
        ;;
    esac
    if (( attempt_count >= attempt_limit )); then
      return "${exit_code}"
    fi
    echo "  ${label} hit ${failure_text} (attempt ${attempt_count}/${attempt_limit}); retrying in ${delay_seconds}s..." >&2
    sleep "${delay_seconds}"
  done
}

list_upstream_versions() {
  case "${SOURCE_TYPE}" in
    pypi)
      # Only enumerate releases the flake can actually fetch: sdist -> a source tarball; wheel -> a universal py3-none-any wheel (the one mk-pypi-package builds). Releases lacking it are skipped.
      if [ "${PYPI_FORMAT:-sdist}" = "wheel" ]; then
        retry curl -sSfL "https://pypi.org/pypi/${PYPI_NAME}/json" \
          | jq -r '.releases | to_entries[] | select(.value | any(.packagetype == "bdist_wheel" and (.filename | endswith("-py3-none-any.whl")))) | .key'
      else
        retry curl -sSfL "https://pypi.org/pypi/${PYPI_NAME}/json" \
          | jq -r '.releases | to_entries[] | select(.value | any(.packagetype == "sdist")) | .key'
      fi
      ;;
    github | github-release-asset)
      retry gh api --paginate "/repos/${GH_OWNER}/${GH_REPO}/releases" --jq '.[].tag_name'
      ;;
    *)
      echo "error: update-branches does not support SOURCE_TYPE=${SOURCE_TYPE}" >&2
      exit 1
      ;;
  esac
}

prepare_new_branch_pin() {
  local VERSION="${1}" EXTRA_HASH
  case "${PIN_SCHEMA}" in
    pypi)
      {
        cat <<EOF
{
  version = "${VERSION}";
  hash = "";
EOF
        for EXTRA_HASH in $(jq -r '.[]' <<<"${EXTRA_HASHES:-[]}"); do
          echo "  ${EXTRA_HASH} = \"\";"
        done
        echo "}"
      } > pin.nix
      ;;
    github)
      cat > pin.nix <<EOF
# Auto-managed by \`nix run .#update-version\`. Manual edits will be overwritten by the next bump.
{
  version = "${VERSION}";
  sourceRev = "";
  sourceHash = "";
}
EOF
      ;;
    github-npm)
      cat > pin.nix <<EOF
# Auto-managed by \`nix run .#update-version\`. Manual edits will be overwritten by the next bump.
{
  version = "${VERSION}";
  sourceRev = "";
  sourceHash = "";
  npmDepsHash = "";
}
EOF
      ;;
    github-pnpm)
      cat > pin.nix <<EOF
# Auto-managed by \`nix run .#update-version\`. Manual edits will be overwritten by the next bump.
{
  version = "${VERSION}";
  sourceRev = "";
  sourceHash = "";
  pnpmDepsHash = "";
}
EOF
      ;;
    github-yarn)
      cat > pin.nix <<EOF
# Auto-managed by \`nix run .#update-version\`. Manual edits will be overwritten by the next bump.
{
  version = "${VERSION}";
  sourceRev = "";
  sourceHash = "";
  yarnHash = "";
}
EOF
      ;;
    github-asset)
      # Prebuilt release asset; URL is a GitHub release download (SOURCE_TYPE=github-release-asset in update-version.sh).
      cat > pin.nix <<EOF
# Auto-managed by \`nix run .#update-version\`. Manual edits will be overwritten by the next bump.
{
  version = "${VERSION}";
  hash = "";
}
EOF
      ;;
    version-only)
      ;;
    *)
      echo "error: unknown PIN_SCHEMA=${PIN_SCHEMA}" >&2
      exit 1
      ;;
  esac
}

version_lt() { [[ "$1" != "$2" ]] && [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" == "$1" ]]; }

is_prerelease() {
  local VERSION="${1}"
  [[ "${SOURCE_TYPE}" != "pypi" && "${VERSION%%+*}" == *-* ]] || python3 "${CASCADE_PY}" prerelease "${VERSION}"
}

canonicalize_version() {
  local v="$1" canon rule
  canon=$(jq -r --arg v "${v}" '.[$v] // ""' <<<"${VERSION_OVERRIDES}")
  if [[ -n "${canon}" ]]; then
    printf '%s' "${canon}"
    return
  fi
  canon="${v}"
  while IFS= read -r rule; do
    if [[ -n "${rule}" ]]; then
      canon=$(sed -E "${rule}" <<<"${canon}")
    fi
  done <<<"${VERSION_CANON}"
  printf '%s' "${canon}"
}

github_version_from_tag() {
  local TAG="${1}" PREFIX VERSION
  for PREFIX in "${GITHUB_TAG_PREFIXES[@]}"; do
    [[ "${TAG}" == "${PREFIX}"* ]] || continue
    VERSION="${TAG#"${PREFIX}"}"
    if [[ "${VERSION}" =~ ^[0-9] ]]; then
      printf '%s\n' "${VERSION}"
      return 0
    fi
  done
  return 1
}

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
# Define the `ours` merge driver so .gitattributes' `merge=ours` rules take effect: `true` exits 0 without touching the file, leaving the branch's version.
git config merge.ours.driver true

matching_owned_paths() {
  # Owned patterns that match something in the current worktree. Unmatched
  # patterns must not reach git: they are fatal pathspec errors there.
  local pattern
  local matches=()
  # shellcheck disable=SC2086
  for pattern in ${BRANCH_OWNED_FILES}; do
    if compgen -G "${pattern}" >/dev/null; then
      matches+=("${pattern}")
    fi
  done
  if [[ ${#matches[@]} -gt 0 ]]; then
    printf '%s\n' "${matches[@]}"
  fi
}

ensure_owned_merge_attributes() {
  # The ours driver configured above only applies to patterns declared in
  # .gitattributes; keep the declarations in step with the owned files so
  # merges of the discovery base cannot clobber branch-owned artifacts.
  local pattern
  touch .gitattributes
  # shellcheck disable=SC2086
  for pattern in ${BRANCH_OWNED_FILES}; do
    if [[ "$(git check-attr merge -- "${pattern}")" != *"merge: ours"* ]]; then
      printf '%s\tmerge=ours\n' "${pattern}" >> .gitattributes
    fi
  done
}

VERSION_OVERRIDES="${VERSION_OVERRIDES:-}"
[[ -n "${VERSION_OVERRIDES}" ]] || VERSION_OVERRIDES='{}'
VERSION_CANON="${VERSION_CANON:-}"
version_re="^[0-9]+(\.[0-9]+){$((MIN_VERSION_COMPONENTS - 1)),2}([-+a-zA-Z0-9.]+)?$"
safe_version_re='^[0-9]+(\.[0-9]+)*([-+a-zA-Z0-9.]+)?$'
declare -a tracked=()
declare -A orig_of=()
BASE_SHA=""
LAST_FAILURE_REASON=""
declare -a blocked_aggregates=()
declare -A blocked_aggregate_reasons=()

usage() {
  cat >&2 <<'EOF'
Usage:
  update-branches
  update-branches list
  update-branches refresh --base-sha SHA --version VERSION --upstream-version VERSION
  update-branches publish --base-sha SHA --versions-json JSON
EOF
}

sort_versions_descending() {
  local v numeric stable
  if (( $# == 0 )); then
    return
  fi
  if [[ "${SOURCE_TYPE}" == "pypi" ]]; then
    printf '%s\n' "$@" | python3 "${CASCADE_PY}" sort "${MINIMUM_TRACKING_VERSION}" all | tac
    return
  fi
  # GitHub's accepted version grammar is broader than PEP 440, so retain GNU
  # version sorting there. The explicit stability rank corrects sort -V's
  # treatment of 1.2.3-rc1 as newer than the final 1.2.3 with the same numeric
  # core, without dropping non-PEP tags such as 1.2.3-ubuntu1.
  for v in "$@"; do
    [[ "${v}" =~ ^([0-9]+(\.[0-9]+)*)(.*)$ ]]
    numeric="${BASH_REMATCH[1]}"
    stable=1
    if is_prerelease "${v}"; then stable=0; fi
    printf '%s\t%s\t%s\n' "${numeric}" "${stable}" "${v}"
  done | sort -t $'\t' -k1,1Vr -k2,2nr -k3,3Vr | cut -f3-
}

capture_base_sha() {
  git fetch --prune --quiet origin
  BASE_SHA=$(git rev-parse --verify 'origin/main^{commit}')
}

use_base_sha() {
  local REQUESTED_SHA="${1}"
  if [[ ! "${REQUESTED_SHA}" =~ ^[0-9a-fA-F]{40,64}$ ]]; then
    echo "error: --base-sha must be a full commit SHA" >&2
    return 2
  fi
  git fetch --prune --quiet origin
  if ! git cat-file -e "${REQUESTED_SHA}^{commit}" 2>/dev/null; then
    git fetch --quiet origin "${REQUESTED_SHA}"
  fi
  BASE_SHA=$(git rev-parse --verify "${REQUESTED_SHA}^{commit}")
}

discover_versions() {
  local v canon
  local -a raw_versions=() all_versions=() sorted_versions=()
  local -A seen=()
  tracked=()
  orig_of=()

  echo "Querying upstream..." >&2
  mapfile -t raw_versions < <(list_upstream_versions)
  if (( ${#raw_versions[@]} == 0 )); then
    echo "error: list_upstream_versions returned no rows (auth issue?)" >&2
    return 1
  fi
  # Canonical versions drive sorting and branch naming. The upstream version is
  # retained in the discovery manifest for the exact refresh job.
  for v in "${raw_versions[@]}"; do
    v=$(github_version_from_tag "${v}" || true)
    if [[ "${v}" =~ ${version_re} ]]; then
      canon=$(canonicalize_version "${v}")
      if [[ ! "${canon}" =~ ${safe_version_re} ]]; then
        echo "error: upstream version ${v} canonicalizes to unsafe branch version ${canon}" >&2
        return 1
      fi
      if [[ -n "${orig_of[${canon}]+set}" && "${orig_of[${canon}]}" != "${v}" ]]; then
        echo "error: upstream versions ${orig_of[${canon}]} and ${v} canonicalize to ${canon}" >&2
        return 1
      fi
      all_versions+=("${canon}")
      orig_of["${canon}"]="${v}"
    fi
  done

  if [[ "${SOURCE_TYPE}" == "pypi" ]]; then
    mapfile -t sorted_versions < <(sort_versions_descending "${all_versions[@]}")
  else
    for v in "${all_versions[@]}"; do
      if ! version_lt "${v}" "${MINIMUM_TRACKING_VERSION}"; then
        sorted_versions+=("${v}")
      fi
    done
    mapfile -t sorted_versions < <(sort_versions_descending "${sorted_versions[@]}")
  fi
  for v in "${sorted_versions[@]}"; do
    if [[ -z "${seen[${v}]+set}" ]]; then
      tracked+=("${v}")
      seen["${v}"]=1
    fi
  done

  if (( ${#tracked[@]} == 0 )); then
    echo "No upstream versions >= ${MINIMUM_TRACKING_VERSION}." >&2
  else
    echo "Tracking ${#tracked[@]} upstream versions (newest first): ${tracked[*]}" >&2
  fi
}

versions_json() {
  local v stable
  {
    for v in "${tracked[@]}"; do
      stable=true
      if is_prerelease "${v}"; then stable=false; fi
      jq -cn \
        --arg version "${v}" \
        --arg upstreamVersion "${orig_of[${v}]}" \
        --argjson stable "${stable}" \
        '{version: $version, upstreamVersion: $upstreamVersion, stable: $stable}'
    done
  } | jq -sc '.'
}

load_versions_json() {
  local JSON="${1}" row v upstream
  local -a rows=() sorted_versions=()
  local -A seen=()
  if ! jq -e 'type == "array" and all(.[]; type == "object" and (.version | type == "string") and (.upstreamVersion | type == "string") and (.stable | type == "boolean"))' <<<"${JSON}" >/dev/null; then
    echo "error: --versions-json must be the versions array emitted by update-branches list" >&2
    return 2
  fi
  tracked=()
  orig_of=()
  mapfile -t rows < <(jq -r '.[] | [.version, .upstreamVersion] | @tsv' <<<"${JSON}")
  for row in "${rows[@]}"; do
    IFS=$'\t' read -r v upstream <<<"${row}"
    if [[ ! "${v}" =~ ${safe_version_re} || ! "${upstream}" =~ ${safe_version_re} ]]; then
      echo "error: discovery manifest contains an unsafe version" >&2
      return 2
    fi
    if [[ -n "${seen[${v}]+set}" ]]; then
      echo "error: discovery manifest contains duplicate version ${v}" >&2
      return 2
    fi
    seen["${v}"]=1
    sorted_versions+=("${v}")
    orig_of["${v}"]="${upstream}"
  done
  mapfile -t tracked < <(sort_versions_descending "${sorted_versions[@]}")
}

remove_worktree() {
  local WT="${1}"
  git worktree remove --force "${WT}" >/dev/null 2>&1 || true
}

refresh_version() {
  local v="${1}" upstream="${2}" branch="v${1}" wt update_phase update_exit
  local expected_remote_sha=""
  LAST_FAILURE_REASON=""
  if [[ ! "${v}" =~ ${safe_version_re} || ! "${upstream}" =~ ${safe_version_re} ]]; then
    LAST_FAILURE_REASON="unsafe version argument"
    return 2
  fi
  wt=$(mktemp -d)
  if git rev-parse --verify --quiet "origin/${branch}" >/dev/null; then
    echo
    echo "=== Refreshing existing branch ${branch} from base ${BASE_SHA:0:8}"
    if ! retry git fetch --quiet origin "${branch}:refs/remotes/origin/${branch}"; then
      LAST_FAILURE_REASON="fetching ${branch} failed"
      remove_worktree "${wt}"
      return 1
    fi
    expected_remote_sha=$(git rev-parse --verify "origin/${branch}^{commit}")
    if ! git worktree add -B "${branch}" "${wt}" "origin/${branch}" >/dev/null; then
      LAST_FAILURE_REASON="git worktree add failed"
      remove_worktree "${wt}"
      return 1
    fi
    # Never merge a live aggregate: every exact job uses the specification SHA
    # captured by discovery, even if an earlier publisher has advanced main.
    if ! (cd "${wt}" && ensure_owned_merge_attributes && git merge --no-edit "${BASE_SHA}"); then
      LAST_FAILURE_REASON="merge of discovery base ${BASE_SHA} failed"
      remove_worktree "${wt}"
      return 1
    fi
  else
    echo
    echo "=== Creating new branch ${branch} from base ${BASE_SHA:0:8}"
    if ! git worktree add -B "${branch}" "${wt}" "${BASE_SHA}" >/dev/null; then
      LAST_FAILURE_REASON="git worktree add failed"
      remove_worktree "${wt}"
      return 1
    fi
    if ! (cd "${wt}" && ensure_owned_merge_attributes && prepare_new_branch_pin "${v}"); then
      LAST_FAILURE_REASON="preparing the new branch pin failed"
      remove_worktree "${wt}"
      return 1
    fi
  fi

  pushd "${wt}" >/dev/null
  update_phase="nix flake update"
  update_exit=0
  if run_with_transient_retry "nix flake update for ${branch}" nix flake update --option post-build-hook ""; then
    update_phase="update-version"
    run_with_transient_retry "update-version for ${branch}" env FLAKE_ROOT="${wt}" nix run --option post-build-hook "" .#update-version -- "${v}" "${upstream}" || update_exit=$?
  else
    update_exit=$?
  fi
  if (( update_exit != 0 )); then
    LAST_FAILURE_REASON="${update_phase} failed (exit ${update_exit})"
    echo "::warning title=Branch ${branch} skipped::${update_phase} failed for ${v} (exit ${update_exit}); see the orchestrator log above."
    echo "  WARN: ${update_phase} failed for ${branch} (exit ${update_exit}); skipping." >&2
    popd >/dev/null
    remove_worktree "${wt}"
    return 1
  fi
  owned_paths="$(matching_owned_paths || true)"
  if ! git diff --quiet -- .gitattributes || [[ -n "$(git ls-files --others --exclude-standard -- .gitattributes)" ]]; then
    owned_paths="${owned_paths:+${owned_paths} }.gitattributes"
  fi
  # shellcheck disable=SC2086
  if [[ -n "${owned_paths}" ]] && { ! git diff --quiet -- ${owned_paths} || [[ -n "$(git ls-files --others --exclude-standard -- ${owned_paths})" ]]; }; then
    # shellcheck disable=SC2086
    if ! git add ${owned_paths} || ! git commit -q -m "auto: ${v} pin"; then
      LAST_FAILURE_REASON="committing ${branch} failed"
      popd >/dev/null
      remove_worktree "${wt}"
      return 1
    fi
    if ! push_ref HEAD "${branch}" "${expected_remote_sha}" normal; then
      LAST_FAILURE_REASON="pushing ${branch} failed"
      popd >/dev/null
      remove_worktree "${wt}"
      return 1
    fi
  else
    echo "  no change on ${branch}"
    # Merge may have advanced HEAD without touching the branch-owned files.
    if [[ "$(git rev-parse HEAD)" != "${expected_remote_sha}" ]]; then
      if ! push_ref HEAD "${branch}" "${expected_remote_sha}" normal; then
        LAST_FAILURE_REASON="pushing ${branch} failed"
        popd >/dev/null
        remove_worktree "${wt}"
        return 1
      fi
    fi
  fi
  popd >/dev/null
  remove_worktree "${wt}"
}

aggregate_keys_for_version() {
  local v="${1}" M m p
  printf '%s\n' main
  IFS='.' read -r M m p <<<"${v}"
  if [[ -n "${m}" ]]; then printf 'v%s\n' "${M}"; fi
  if [[ -n "${p}" ]]; then printf 'v%s.%s\n' "${M}" "${m}"; fi
}

aggregate_tip_retained_elsewhere() {
  local TIP_SHA="${1}" v
  for v in "${tracked[@]}"; do
    if git rev-parse --verify --quiet "origin/v${v}^{commit}" >/dev/null \
      && git merge-base --is-ancestor "${TIP_SHA}" "origin/v${v}^{commit}"; then
      return 0
    fi
  done
  return 1
}

publish_aggregates() {
  local v branch target_sha stable agg target_v target_branch cur_sha current_v current_branch current_branch_sha current_is_safe stable_v
  local -a keys=() aggregates=()
  local -A highest_any=() highest_stable=() aggregate_set=()
  blocked_aggregates=()
  blocked_aggregate_reasons=()

  git fetch --prune --quiet origin || return
  for v in "${tracked[@]}"; do
    branch="v${v}"
    if ! git rev-parse --verify --quiet "origin/${branch}" >/dev/null; then
      continue
    fi
    target_sha=$(git rev-parse --verify "origin/${branch}^{commit}")
    stable=true
    if is_prerelease "${v}"; then stable=false; fi
    mapfile -t keys < <(aggregate_keys_for_version "${v}")
    if ! git merge-base --is-ancestor "${BASE_SHA}" "${target_sha}"; then
      for agg in "${keys[@]}"; do
        aggregate_set["${agg}"]=1
      done
      continue
    fi
    for agg in "${keys[@]}"; do
      aggregate_set["${agg}"]=1
      if [[ -z "${highest_any[${agg}]+set}" ]]; then highest_any["${agg}"]="${v}"; fi
      if [[ "${stable}" == true && -z "${highest_stable[${agg}]+set}" ]]; then highest_stable["${agg}"]="${v}"; fi
    done
  done

  echo
  echo "=== Updating aggregate pointers from base ${BASE_SHA:0:8}"
  if (( ${#aggregate_set[@]} > 0 )); then
    mapfile -t aggregates < <(printf '%s\n' "${!aggregate_set[@]}" | sort)
  fi
  for agg in "${aggregates[@]}"; do
    if [[ -z "${highest_any[${agg}]+set}" ]]; then
      blocked_aggregates+=("${agg}")
      blocked_aggregate_reasons["${agg}"]="no candidate for ${agg} contains discovery base ${BASE_SHA}"
      echo "::warning title=Aggregate ${agg} skipped::No candidate for ${agg} contains discovery base ${BASE_SHA}; retaining ${agg}."
      continue
    fi
    target_v="${highest_any[${agg}]}"
    target_branch="v${target_v}"
    target_sha=$(git rev-parse --verify "origin/${target_branch}^{commit}")
    cur_sha=$(git rev-parse --verify "origin/${agg}^{commit}" 2>/dev/null || true)

    # Prereleases may advance an absent/prerelease aggregate. A currently stable
    # aggregate instead advances to the highest successful stable candidate,
    # which need not be the stable counterpart of the highest prerelease.
    if is_prerelease "${target_v}" && [[ -n "${cur_sha}" ]]; then
      current_v=$(git show "${cur_sha}:pin.nix" 2>/dev/null | sed -nE 's/^[[:space:]]*version = "([^"]+)";$/\1/p' | head -1 || true)
      if ! is_prerelease "${current_v}"; then
        stable_v="${highest_stable[${agg}]:-}"
        current_branch="v${current_v}"
        current_branch_sha=""
        current_is_safe=false
        if [[ -n "${current_v}" ]] && git rev-parse --verify --quiet "origin/${current_branch}" >/dev/null; then
          current_branch_sha=$(git rev-parse --verify "origin/${current_branch}^{commit}")
          if git merge-base --is-ancestor "${BASE_SHA}" "${current_branch_sha}"; then current_is_safe=true; fi
        fi
        if [[ -n "${stable_v}" ]] && { [[ "${current_is_safe}" == false ]] || version_lt "${current_v}" "${stable_v}"; }; then
          target_v="${stable_v}"
          target_branch="v${target_v}"
          target_sha=$(git rev-parse --verify "origin/${target_branch}^{commit}")
        elif [[ "${current_is_safe}" == true ]]; then
          target_branch="${current_branch}"
          target_sha="${current_branch_sha}"
        elif [[ -z "${stable_v}" && -n "${current_branch_sha}" ]]; then
          target_branch="${current_branch}"
          target_sha="${current_branch_sha}"
        else
          echo "  ${agg} remains at its current stable target"
          continue
        fi
      fi
    fi
    if [[ "${cur_sha}" == "${target_sha}" ]]; then
      echo "  ${agg} already at ${target_branch}"
      continue
    fi
    if ! git merge-base --is-ancestor "${BASE_SHA}" "${target_sha}"; then
      blocked_aggregates+=("${agg}")
      blocked_aggregate_reasons["${agg}"]="${target_branch} does not contain discovery base ${BASE_SHA}"
      echo "::warning title=Aggregate ${agg} skipped::${target_branch} does not contain discovery base ${BASE_SHA}; retaining ${agg}."
      continue
    fi
    # Advancing past a tip reachable from no tracked exact branch would discard
    # commits that exist only on the aggregate (e.g. a specification merged to
    # main after discovery captured its base).
    if [[ -n "${cur_sha}" ]] \
      && ! git merge-base --is-ancestor "${cur_sha}" "${target_sha}" \
      && ! aggregate_tip_retained_elsewhere "${cur_sha}"; then
      blocked_aggregates+=("${agg}")
      blocked_aggregate_reasons["${agg}"]="current tip ${cur_sha:0:8} is reachable from neither ${target_branch} nor any tracked exact branch"
      echo "::warning title=Aggregate ${agg} skipped::Advancing ${agg} to ${target_branch} would orphan its current tip ${cur_sha:0:8}; retaining ${agg}."
      continue
    fi
    echo "  ${agg} -> ${target_branch} (${target_sha:0:8})"
    if ! push_ref "${target_sha}" "${agg}" "${cur_sha}" lease; then
      echo "error: aggregate ${agg} could not be published; rerun publication" >&2
      return 1
    fi
  done
}

write_failure_summary() {
  local -n FAILED_REF="${1}" REASONS_REF="${2}"
  local v agg
  if (( ${#FAILED_REF[@]} > 0 )); then
    echo "=== ${#FAILED_REF[@]} branch(es) failed: ${FAILED_REF[*]}"
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
      {
        echo "## :warning: ${#FAILED_REF[@]} branch(es) failed to update"
        echo
        echo "These upstream versions failed during input refresh or package update. Their exact branches were left unchanged; aggregate pointers were checked separately before publication."
        echo
        for v in "${FAILED_REF[@]}"; do echo "- \`v${v}\`: ${REASONS_REF[$v]}"; done
        echo
        echo "See the orchestrator log for the underlying error per version."
      } >> "${GITHUB_STEP_SUMMARY}"
    fi
  fi
  if (( ${#blocked_aggregates[@]} > 0 )); then
    echo "=== ${#blocked_aggregates[@]} aggregate pointer(s) retained: ${blocked_aggregates[*]}"
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
      {
        echo "## :warning: ${#blocked_aggregates[@]} aggregate pointer(s) retained"
        echo
        echo "Their selected exact branches were not safe publication targets."
        echo
        for agg in "${blocked_aggregates[@]}"; do echo "- \`${agg}\`: ${blocked_aggregate_reasons[${agg}]:-unspecified reason}"; done
      } >> "${GITHUB_STEP_SUMMARY}"
    fi
  fi
}

command_list() {
  local JSON NEWEST_STABLE
  capture_base_sha
  discover_versions
  JSON=$(versions_json)
  NEWEST_STABLE=$(jq -c '[.[] | select(.stable)][0] // null' <<<"${JSON}")
  jq -cn --arg baseSha "${BASE_SHA}" --argjson versions "${JSON}" --argjson newestStable "${NEWEST_STABLE}" \
    '{baseSha: $baseSha, versions: $versions, newestStable: $newestStable}'
}

command_refresh() {
  local BASE="" VERSION="" UPSTREAM=""
  shift
  while (( $# > 0 )); do
    case "${1}" in
      --base-sha) [[ $# -ge 2 ]] || { usage; return 2; }; BASE="${2}"; shift 2 ;;
      --version) [[ $# -ge 2 ]] || { usage; return 2; }; VERSION="${2}"; shift 2 ;;
      --upstream-version) [[ $# -ge 2 ]] || { usage; return 2; }; UPSTREAM="${2}"; shift 2 ;;
      *) usage; return 2 ;;
    esac
  done
  if [[ -z "${BASE}" || -z "${VERSION}" || -z "${UPSTREAM}" ]]; then usage; return 2; fi
  use_base_sha "${BASE}"
  if ! refresh_version "${VERSION}" "${UPSTREAM}"; then
    local -a failed=("${VERSION}")
    local -A reasons=(["${VERSION}"]="${LAST_FAILURE_REASON}")
    write_failure_summary failed reasons
    return 1
  fi
  echo "Done."
}

command_publish() {
  local BASE="" JSON=""
  local -a failed=()
  local -A reasons=()
  shift
  while (( $# > 0 )); do
    case "${1}" in
      --base-sha) [[ $# -ge 2 ]] || { usage; return 2; }; BASE="${2}"; shift 2 ;;
      --versions-json) [[ $# -ge 2 ]] || { usage; return 2; }; JSON="${2}"; shift 2 ;;
      *) usage; return 2 ;;
    esac
  done
  if [[ -z "${BASE}" || -z "${JSON}" ]]; then usage; return 2; fi
  use_base_sha "${BASE}"
  load_versions_json "${JSON}"
  publish_aggregates
  write_failure_summary failed reasons
  if (( ${#blocked_aggregates[@]} > 0 )); then return 1; fi
  echo "Done."
}

command_all() {
  local JSON v publish_exit=0
  local -a failed=()
  local -A failure_reason=()
  capture_base_sha
  discover_versions
  if (( ${#tracked[@]} == 0 )); then
    echo "Done."
    return
  fi
  JSON=$(versions_json)
  for v in "${tracked[@]}"; do
    if ! refresh_version "${v}" "${orig_of[${v}]}"; then
      failed+=("${v}")
      failure_reason["${v}"]="${LAST_FAILURE_REASON}"
    fi
  done
  load_versions_json "${JSON}"
  publish_aggregates || publish_exit=$?
  echo
  write_failure_summary failed failure_reason
  if (( ${#failed[@]} > 0 || ${#blocked_aggregates[@]} > 0 || publish_exit != 0 )); then return 1; fi
  echo "Done."
}

case "${1:-}" in
  "") command_all ;;
  list) [[ $# == 1 ]] || { usage; exit 2; }; command_list ;;
  refresh) command_refresh "$@" ;;
  publish) command_publish "$@" ;;
  *) usage; exit 2 ;;
esac
