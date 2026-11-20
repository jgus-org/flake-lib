#!/usr/bin/env -S nix shell nixpkgs#bash nixpkgs#git nixpkgs#curl nixpkgs#gh nixpkgs#jq nixpkgs#gnused nixpkgs#gnugrep nixpkgs#nix nixpkgs#coreutils --command bash

# Per-version branch orchestrator. It supports both a backwards-compatible all-in-one invocation and job-splittable discovery, exact-refresh, and aggregate-publication commands.
#
# For each upstream version >= $MINIMUM_TRACKING_VERSION, ensures:
#   - an exact branch `v<M>.<m>.<p>` exists and its pin is hash-validated
#   - aggregate pointer branches `v<M>.<m>`, `v<M>`, `main` are force-pushed to the highest matching exact branch (only the levels shorter than a version's component count, and `main` always)
#
# Single knob: $MINIMUM_TRACKING_VERSION. Permanent pins are git tags, which the action never touches, so there is no in-band freeze list.
#
# Failures: the run surfaces per-branch input-refresh or update-version failures, and aggregate targets missing the discovery base commit, as GH Actions ::warning:: annotations plus a step summary, and exits non-zero at the end of the run. An aggregate whose current tip is reachable from neither the new target nor any tracked exact branch is likewise retained. Advancing it would orphan commits that exist only on the aggregate. An aggregate that already contains its target is left where it is without being retained. It is ahead of the target, not stranded from it.
#
# Per-flake variation is driven by env vars injected by flake-lib's mkUpdateBranches:
#   SOURCE_TYPE          pypi | github | github-release-asset | gitlab | oci
#   VERSION_SOURCE_TYPE  the source whose named versions drive discovery. For an oci producer, its upstream release tree or the registry its image lives in. Defaults to SOURCE_TYPE.
#   VERSION_TRACK        github vocabulary: release (GitHub Releases) | tag (git tags). A github source's versions live in exactly one of those, and only the flake knows which. Defaults to release.
#   PYPI_NAME            [pypi]
#   PYPI_FORMAT          sdist | wheel  [pypi]
#   GH_OWNER/GH_REPO     [github, github-release-asset, oci with source.versions]
#   GITLAB_OWNER/GITLAB_REPO  [gitlab] A gitlab source's version names are the project's git tags, which is where its updater resolves a release from too, so tracking mode says nothing about where to look.
#   GITLAB_DOMAIN             GitLab host (default gitlab.com)  [gitlab]
#   OCI_IMAGE_NAME       the image reference whose registry tag list holds an oci producer's version names  [registry]
#   REGISTRY_TAGS_LIB    the sourced helper that lists a registry's tags  [registry]
#   PIN_SCHEMA           pypi | github | github-npm | github-pnpm | github-yarn | github-asset | oci | version-only
#   EXTRA_HASHES         JSON array of pin field names the producer's artifact hook resolves. Every schema's placeholder carries them
#   FORMATTER            the repository's formatter binary, which puts a nested pin field in its canonical shape
#   BRANCH_OWNED_FILES   space-separated files update-version mutates per branch
#   VERSION_OVERRIDES    JSON map raw version -> canonical version
#   VERSION_CANON        newline-separated `sed -E` rules mapping raw version -> canonical version
#   MIN_VERSION_COMPONENTS  fewest dot-separated numeric components a tag may have and still be tracked (default 3)
#   TRACK_STABLE_ONLY    true: exclude prereleases from the tracked set entirely, so they get no branch, no maintenance job, and no publication (default false)
#   BUILD_VERIFICATION_SKIP  true: publish a refreshed branch without running the gate a pull request would have passed (default false). Otherwise the gate runs against the worktree before anything is pushed.

set -euo pipefail
: "${MINIMUM_TRACKING_VERSION:?required env var}"
MIN_VERSION_COMPONENTS="${MIN_VERSION_COMPONENTS:-3}"
VERSION_TRACK="${VERSION_TRACK:-release}"
TRACK_STABLE_ONLY="${TRACK_STABLE_ONLY:-false}"
BUILD_VERIFICATION_SKIP="${BUILD_VERIFICATION_SKIP:-false}"
GH_TAG_PREFIXES="${GH_TAG_PREFIXES:-[\"v\",\"V\",\"\"]}"
GITLAB_DOMAIN="${GITLAB_DOMAIN:-gitlab.com}"
FORMATTER="${FORMATTER:-}"
mapfile -t GITHUB_TAG_PREFIXES < <(jq -r '.[]' <<<"${GH_TAG_PREFIXES}")

FLAKE_ROOT="${FLAKE_ROOT:-${PWD}}"
cd "${FLAKE_ROOT}"

TRANSIENT_MAX_ATTEMPTS="${TRANSIENT_MAX_ATTEMPTS:-2}"
TRANSIENT_RETRY_DELAY_SECONDS="${TRANSIENT_RETRY_DELAY_SECONDS:-5}"
GITHUB_REF_MAX_ATTEMPTS="${GITHUB_REF_MAX_ATTEMPTS:-3}"
GITHUB_REF_RETRY_DELAY_SECONDS="${GITHUB_REF_RETRY_DELAY_SECONDS:-30}"
if [[ ! ${TRANSIENT_MAX_ATTEMPTS} =~ ^[1-9][0-9]*$ || ! ${GITHUB_REF_MAX_ATTEMPTS} =~ ^[1-9][0-9]*$ ]]; then
  echo "error: retry attempt counts must be positive integers" >&2
  exit 2
fi

# GitLab pages by number and names the page that follows in a response header, so there is no --paginate equivalent to hand the enumeration to. The cap bounds how many pages are fetched, whatever the API keeps naming.
GITLAB_MAX_PAGES="${GITLAB_MAX_PAGES:-20}"

# GitHub's release and tag lists answer one page per request and name nothing that follows, so a short page ends the enumeration and this cap bounds it. A release page carries every release's note body, and GitHub stops answering before it finishes sending a hundred of them for an upstream with a long release history, so the page is deliberately small.
GITHUB_MAX_PAGES="${GITHUB_MAX_PAGES:-500}"
GITHUB_PAGE_SIZE="${GITHUB_PAGE_SIZE:-30}"

# shellcheck source=/dev/null
source "${GIT_PUSH_LIB:?required env var}"

if [[ ${VERSION_SOURCE_TYPE:-${SOURCE_TYPE}} == "registry" ]]; then
  # shellcheck source=/dev/null
  source "${REGISTRY_TAGS_LIB:?required env var}"
fi

# Buffers output and emits it only on success, so a consumer never sees partial data from an attempt that died mid-stream (e.g. gh --paginate failing between pages).
retry() {
  local ATTEMPT OUTPUT
  for ATTEMPT in 1 2 3 4 5; do
    if OUTPUT=$("${@}"); then
      [[ -z ${OUTPUT} ]] || printf '%s\n' "${OUTPUT}"
      return 0
    fi
    if ((ATTEMPT < 5)); then
      echo "  ${1} failed (attempt ${ATTEMPT}/5). Retrying in ${TRANSIENT_RETRY_DELAY_SECONDS}s..." >&2
      sleep "${TRANSIENT_RETRY_DELAY_SECONDS}"
    fi
  done
  echo "  ${1} failed after 5 attempts" >&2
  return 1
}

transient_failure_kind() {
  local LOG="${1}"
  if grep -Fqi 'No commit found for SHA' "${LOG}"; then
    echo github-ref
    return 0
  fi
  if grep -Eiq '(requested URL returned error: (429|5[0-9]{2})|HTTP[^[:space:]]* (429|5[0-9]{2})|Internal Server Error|Could not resolve host|Failed to connect|Connection reset by peer|Operation timed out|TLS connect error|UNEXPECTED_EOF_WHILE_READING|Temporary failure in name resolution)' "${LOG}"; then
    echo network
    return 0
  fi
  return 1
}

# Branch updates run in disposable worktrees, so retrying the whole command is safe. Keep this deliberately narrow. Explicit transient network errors get one fast retry. GitHub's "No commit found for SHA" (the commits API lagging behind a just-pushed ref) gets a longer bounded wait. Deterministic build/update failures return at once.
run_with_transient_retry() {
  local LABEL="${1}" KIND EXIT_CODE=0 LOG
  local -i NETWORK_FAILURES=0 GITHUB_REF_FAILURES=0
  local ATTEMPT_COUNT ATTEMPT_LIMIT DELAY_SECONDS FAILURE_TEXT
  shift
  LOG=$(mktemp)
  while :; do
    : >"${LOG}"
    set +e
    "${@}" 2>&1 | tee "${LOG}"
    EXIT_CODE=${PIPESTATUS[0]}
    set -e
    if ((EXIT_CODE == 0)); then
      rm -f "${LOG}"
      return 0
    fi
    if ! KIND=$(transient_failure_kind "${LOG}"); then
      rm -f "${LOG}"
      return "${EXIT_CODE}"
    fi
    rm -f "${LOG}"
    case "${KIND}" in
    network)
      NETWORK_FAILURES+=1
      ATTEMPT_COUNT="${NETWORK_FAILURES}"
      ATTEMPT_LIMIT="${TRANSIENT_MAX_ATTEMPTS}"
      DELAY_SECONDS="${TRANSIENT_RETRY_DELAY_SECONDS}"
      FAILURE_TEXT="a transient network error"
      ;;
    github-ref)
      GITHUB_REF_FAILURES+=1
      ATTEMPT_COUNT="${GITHUB_REF_FAILURES}"
      ATTEMPT_LIMIT="${GITHUB_REF_MAX_ATTEMPTS}"
      DELAY_SECONDS="${GITHUB_REF_RETRY_DELAY_SECONDS}"
      FAILURE_TEXT="a not-yet-visible GitHub ref"
      ;;
    esac
    if ((ATTEMPT_COUNT >= ATTEMPT_LIMIT)); then
      return "${EXIT_CODE}"
    fi
    echo "  ${LABEL} hit ${FAILURE_TEXT} (attempt ${ATTEMPT_COUNT}/${ATTEMPT_LIMIT}). Retrying in ${DELAY_SECONDS}s..." >&2
    sleep "${DELAY_SECONDS}"
  done
}

# The API holding a source's version names. Derived rather than remembered across the enumeration, which runs in a subshell and so cannot report it back.
discovery_endpoint() {
  case "${VERSION_SOURCE_TYPE:-${SOURCE_TYPE}}" in
  pypi) printf '%s' "https://pypi.org/pypi/${PYPI_NAME}/json" ;;
  github)
    if [[ ${VERSION_TRACK} == "tag" ]]; then
      printf '%s' "/repos/${GH_OWNER}/${GH_REPO}/tags"
    else
      printf '%s' "/repos/${GH_OWNER}/${GH_REPO}/releases"
    fi
    ;;
  github-release-asset) printf '%s' "/repos/${GH_OWNER}/${GH_REPO}/releases" ;;
  gitlab)
    printf '%s' "https://${GITLAB_DOMAIN}/api/v4/projects/${GITLAB_OWNER}%2F${GITLAB_REPO}/repository/tags"
    ;;
  registry)
    registry_api_target "${OCI_IMAGE_NAME:?an oci version source names its image}" || exit 1
    printf '%s' "https://${REGISTRY_API_HOST}/v2/${REGISTRY_API_PATH}/tags/list"
    ;;
  *) printf '%s' "the upstream API" ;;
  esac
}

list_gitlab_tags() {
  local ENDPOINT="${1}" PAGE=1 NEXT HEADERS_FILE PAGES=0
  HEADERS_FILE=$(mktemp)
  while :; do
    PAGES=$((PAGES + 1))
    if ((PAGES > GITLAB_MAX_PAGES)); then
      rm -f "${HEADERS_FILE}"
      echo "error: gitlab tag enumeration did not end within ${GITLAB_MAX_PAGES} pages" >&2
      exit 1
    fi
    # curl truncates the dump as it opens it, so clear it the same way: a next-page named by the previous response must not be read as this response's.
    : >"${HEADERS_FILE}"
    retry curl -sSfL -D "${HEADERS_FILE}" \
      "${ENDPOINT}?per_page=100&page=${PAGE}" | jq -r '.[].name'
    # curl -L dumps every response's headers into the file, so the page the last one names is the one to follow.
    NEXT=$(sed -nE 's/^[Xx]-[Nn]ext-[Pp]age:[[:space:]]*([0-9]+)[[:space:]]*$/\1/p' "${HEADERS_FILE}" | tail -1)
    if [[ -z ${NEXT} ]]; then
      rm -f "${HEADERS_FILE}"
      return 0
    fi
    PAGE="${NEXT}"
  done
}

# GitHub answers one page per request and names nothing that follows it, so a short page ends the enumeration. A page is retried on its own because an upstream with a long release history has pages that fail by themselves: retrying the whole enumeration re-rolls every page already fetched, so a list that stops partway is what a run with any flaky page produces. A page that never answers fails the enumeration instead.
list_github_pages() {
  local ENDPOINT="${1}" JQ_FILTER="${2}" PAGE=1 PAGES=0 NAMES COUNT
  while :; do
    PAGES=$((PAGES + 1))
    if ((PAGES > GITHUB_MAX_PAGES)); then
      echo "error: github enumeration of ${ENDPOINT} did not end within ${GITHUB_MAX_PAGES} pages" >&2
      return 1
    fi
    if ! NAMES=$(retry gh api "${ENDPOINT}?per_page=${GITHUB_PAGE_SIZE}&page=${PAGE}" --jq "${JQ_FILTER}"); then
      return 1
    fi
    if [[ -z ${NAMES} ]]; then
      return 0
    fi
    printf '%s\n' "${NAMES}"
    COUNT=$(wc -l <<<"${NAMES}")
    if ((COUNT < GITHUB_PAGE_SIZE)); then
      return 0
    fi
    PAGE=$((PAGE + 1))
  done
}

list_upstream_versions() {
  local DISCOVERY_TYPE="${VERSION_SOURCE_TYPE:-${SOURCE_TYPE}}" ENDPOINT
  ENDPOINT=$(discovery_endpoint)
  case "${DISCOVERY_TYPE}" in
  pypi)
    # Only enumerate releases the flake can actually fetch. For sdist that is a source tarball, and for wheel a universal py3-none-any wheel (the one mk-pypi-package builds). Releases lacking it are skipped.
    if [ "${PYPI_FORMAT:-sdist}" = "wheel" ]; then
      retry curl -sSfL "${ENDPOINT}" |
        jq -r '.releases | to_entries[] | select(.value | any(.packagetype == "bdist_wheel" and (.filename | endswith("-py3-none-any.whl")))) | .key'
    else
      retry curl -sSfL "${ENDPOINT}" |
        jq -r '.releases | to_entries[] | select(.value | any(.packagetype == "sdist")) | .key'
    fi
    ;;
  github)
    # A github source names its versions either as GitHub Releases or as plain git tags, and an upstream that ships tags without Releases has an empty releases list. Only the flake's tracking mode says which endpoint holds its names.
    if [[ ${VERSION_TRACK} == "tag" ]]; then
      list_github_pages "${ENDPOINT}" '.[].name'
    else
      list_github_pages "${ENDPOINT}" '.[].tag_name'
    fi
    ;;
  github-release-asset)
    list_github_pages "${ENDPOINT}" '.[].tag_name'
    ;;
  gitlab)
    list_gitlab_tags "${ENDPOINT}"
    ;;
  registry)
    retry registry_tag_names "${OCI_IMAGE_NAME:?an oci version source names its image}"
    ;;
  *)
    echo "error: update-branches cannot enumerate versions for source type ${DISCOVERY_TYPE}" >&2
    exit 1
    ;;
  esac
}

format_pin() {
  # $1 pin path, relative to the working tree. The placeholder is written as flat lines, and a dotted field name asks for a nested attribute whose shape only the org formatter defines.
  [[ -z ${FORMATTER} ]] && return 0
  # One file per run, and treefmt's evaluation cache lives under a HOME the updater may not have.
  (cd "$(dirname "${1}")" && "${FORMATTER}" --no-cache "$(basename "${1}")")
}

seed_declared_pin_fields() {
  # A declared extra hash is a pin field the producer's artifact hook resolves, so every schema's placeholder carries every declared field: a consumer reads one pin shape at each point in a branch's life instead of testing whether a field is there yet, and an empty field is what re-runs the hook.
  local FIELD
  while IFS= read -r FIELD; do
    [[ -n ${FIELD} ]] || continue
    # Replacing the closing brace rather than inserting before it: sed's insert text loses its leading whitespace.
    sed -i "s|^}|  ${FIELD} = \"\";\\n}|" pin.nix
  done < <(jq -r '.[]' <<<"${EXTRA_HASHES:-[]}")
  format_pin pin.nix
}

prepare_new_branch_pin() {
  local VERSION="${1}" BASE_DIGEST BASE_HASH
  case "${PIN_SCHEMA}" in
  pypi)
    cat >pin.nix <<EOF
{
  version = "${VERSION}";
  hash = "";
}
EOF
    ;;
  github)
    cat >pin.nix <<EOF
# Auto-managed by \`nix run .#update-version\`. Manual edits will be overwritten by the next bump.
{
  version = "${VERSION}";
  sourceRev = "";
  sourceHash = "";
}
EOF
    ;;
  github-npm)
    cat >pin.nix <<EOF
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
    cat >pin.nix <<EOF
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
    cat >pin.nix <<EOF
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
    # Prebuilt release asset. The URL is a GitHub release download (SOURCE_TYPE=github-release-asset in update-version.sh).
    cat >pin.nix <<EOF
# Auto-managed by \`nix run .#update-version\`. Manual edits will be overwritten by the next bump.
{
  version = "${VERSION}";
  hash = "";
}
EOF
    ;;
  oci)
    # A content-addressed image pin has no evaluable blank placeholder: mk-oci-image asserts the digest shape when the image is evaluated, so an empty imageDigest would make the new branch unevaluable. Seed the branch with the base pin's content fields and nothing else: the version the branch is named for is not claimed until update-version resolves that version's image.
    BASE_DIGEST=$(sed -nE 's/^[[:space:]]*imageDigest = "(sha256:[0-9a-f]{64})";$/\1/p' pin.nix | head -1 || true)
    BASE_HASH=$(sed -nE 's/^[[:space:]]*imageHash = "(sha256-[A-Za-z0-9+/]{43}=");$/\1/p' pin.nix | head -1 || true)
    if [[ -z ${BASE_DIGEST} || -z ${BASE_HASH} ]]; then
      echo "error: PIN_SCHEMA=oci branches from a base pin.nix carrying imageDigest and imageHash" >&2
      exit 1
    fi
    cat >pin.nix <<EOF
{
  imageDigest = "${BASE_DIGEST}";
  imageHash = "${BASE_HASH}";
}
EOF
    ;;
  version-only)
    # Keeps the base branch's pin as it stands, declared fields and their values already in it.
    return 0
    ;;
  *)
    echo "error: unknown PIN_SCHEMA=${PIN_SCHEMA}" >&2
    exit 1
    ;;
  esac
  seed_declared_pin_fields
}

version_lt() { [[ ${1} != "${2}" ]] && [[ "$(printf '%s\n%s\n' "${1}" "${2}" | sort -V | head -1)" == "${1}" ]]; }

is_prerelease() {
  local VERSION="${1}"
  [[ ${SOURCE_TYPE} != "pypi" && ${VERSION%%+*} == *-* ]] || python3 "${CASCADE_PY}" prerelease "${VERSION}"
}

canonicalize_version() {
  local VERSION="${1}" CANON RULE
  CANON=$(jq -r --arg v "${VERSION}" '.[$v] // ""' <<<"${VERSION_OVERRIDES}")
  if [[ -n ${CANON} ]]; then
    printf '%s' "${CANON}"
    return
  fi
  CANON="${VERSION}"
  while IFS= read -r RULE; do
    if [[ -n ${RULE} ]]; then
      CANON=$(sed -E "${RULE}" <<<"${CANON}")
    fi
  done <<<"${VERSION_CANON}"
  printf '%s' "${CANON}"
}

github_version_from_tag() {
  local TAG="${1}" PREFIX VERSION
  for PREFIX in "${GITHUB_TAG_PREFIXES[@]}"; do
    [[ ${TAG} == "${PREFIX}"* ]] || continue
    VERSION="${TAG#"${PREFIX}"}"
    if [[ ${VERSION} =~ ^[0-9] ]]; then
      printf '%s\n' "${VERSION}"
      return 0
    fi
  done
  return 1
}

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

matching_owned_paths() {
  # Unmatched patterns must not reach git: they are fatal pathspec errors there.
  local PATTERN
  local -a MATCHES=() OWNED_PATTERNS=()
  read -r -a OWNED_PATTERNS <<<"${BRANCH_OWNED_FILES}"
  for PATTERN in "${OWNED_PATTERNS[@]}"; do
    if compgen -G "${PATTERN}" >/dev/null || git ls-files --error-unmatch -- "${PATTERN}" >/dev/null 2>&1; then
      MATCHES+=("${PATTERN}")
    fi
  done
  if [[ ${#MATCHES[@]} -gt 0 ]]; then
    printf '%s\n' "${MATCHES[@]}"
  fi
}

merge_preserving_owned() {
  local BASE="${1}" BRANCH_TREE TEMP_INDEX TREE SYNTHETIC PATTERN CANDIDATE METADATA
  local -a OWNED_PATTERNS=() PATHS=()
  if git merge-base --is-ancestor "${BASE}" HEAD; then
    return 0
  fi
  if ! BRANCH_TREE=$(git rev-parse HEAD); then
    return 1
  fi
  if ! TEMP_INDEX=$(mktemp); then
    return 1
  fi
  rm -f "${TEMP_INDEX}"
  if ! GIT_INDEX_FILE="${TEMP_INDEX}" git read-tree "${BASE}"; then
    rm -f "${TEMP_INDEX}"
    return 1
  fi
  read -r -a OWNED_PATTERNS <<<"${BRANCH_OWNED_FILES}"
  for PATTERN in "${OWNED_PATTERNS[@]}"; do
    mapfile -t PATHS < <(GIT_INDEX_FILE="${TEMP_INDEX}" git ls-files -- "${PATTERN}")
    if ((${#PATHS[@]} > 0)); then
      if ! GIT_INDEX_FILE="${TEMP_INDEX}" git update-index --force-remove -- "${PATHS[@]}"; then
        rm -f "${TEMP_INDEX}"
        return 1
      fi
    fi
    if ! while IFS=$'\t' read -r METADATA CANDIDATE; do
      if [[ ${CANDIDATE} == ${PATTERN} || ${CANDIDATE} == ${PATTERN%/}/* ]]; then
        printf '%s\t%s\n' "${METADATA}" "${CANDIDATE}"
      fi
    done < <(git ls-tree -r "${BRANCH_TREE}") | GIT_INDEX_FILE="${TEMP_INDEX}" git update-index --index-info; then
      rm -f "${TEMP_INDEX}"
      return 1
    fi
  done
  if ! TREE=$(GIT_INDEX_FILE="${TEMP_INDEX}" git write-tree); then
    rm -f "${TEMP_INDEX}"
    return 1
  fi
  if ! SYNTHETIC=$(printf '%s\n' "overlay owned files from ${BRANCH_TREE}" | git commit-tree "${TREE}" -p "${BASE}"); then
    rm -f "${TEMP_INDEX}"
    return 1
  fi
  rm -f "${TEMP_INDEX}"
  git merge --no-edit "${SYNTHETIC}"
}

VERSION_OVERRIDES="${VERSION_OVERRIDES:-}"
[[ -n ${VERSION_OVERRIDES} ]] || VERSION_OVERRIDES='{}'
VERSION_CANON="${VERSION_CANON:-}"
VERSION_RE="^[0-9]+(\.[0-9]+){$((MIN_VERSION_COMPONENTS - 1)),2}([-+a-zA-Z0-9.]+)?$"
SAFE_VERSION_RE='^[0-9]+(\.[0-9]+)*([-+a-zA-Z0-9.]+)?$'
# The name upstream publishes a version under is not necessarily a version: a registry publishes a release under whatever tag it likes, and that name is what the version updater has to fetch. It only has to be spellable as a tag and safe as an argument.
SAFE_REF_RE='^[A-Za-z0-9_][A-Za-z0-9_.+-]*$'
declare -a TRACKED=()
declare -A ORIG_OF=()
BASE_SHA=""
LAST_FAILURE_REASON=""
declare -a BLOCKED_AGGREGATES=()
declare -A BLOCKED_AGGREGATE_REASONS=()

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
  local V NUMERIC STABLE
  if (($# == 0)); then
    return
  fi
  if [[ ${SOURCE_TYPE} == "pypi" ]]; then
    printf '%s\n' "${@}" | python3 "${CASCADE_PY}" sort "${MINIMUM_TRACKING_VERSION}" all | tac
    return
  fi
  # GitHub's accepted version grammar is broader than PEP 440, so retain GNU version sorting there. The explicit stability rank corrects sort -V's treatment of 1.2.3-rc1 as newer than the final 1.2.3 with the same numeric core, without dropping non-PEP tags such as 1.2.3-ubuntu1.
  for V in "${@}"; do
    [[ ${V} =~ ^([0-9]+(\.[0-9]+)*)(.*)$ ]]
    NUMERIC="${BASH_REMATCH[1]}"
    STABLE=1
    if is_prerelease "${V}"; then STABLE=0; fi
    printf '%s\t%s\t%s\n' "${NUMERIC}" "${STABLE}" "${V}"
  done | sort -t $'\t' -k1,1Vr -k2,2nr -k3,3Vr | cut -f3-
}

capture_base_sha() {
  git fetch --prune --quiet origin
  BASE_SHA=$(git rev-parse --verify 'origin/main^{commit}')
}

use_base_sha() {
  local REQUESTED_SHA="${1}"
  if [[ ! ${REQUESTED_SHA} =~ ^[0-9a-fA-F]{40,64}$ ]]; then
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
  local V CANON RAW RAW_OUTPUT
  local -a RAW_VERSIONS=() ALL_VERSIONS=() SORTED_VERSIONS=()
  local -A SEEN=() STRIPPED_OF=()
  TRACKED=()
  ORIG_OF=()

  echo "Querying upstream..." >&2
  # A process substitution's failure is invisible to mapfile, so capture the output instead: an enumeration that stops partway would otherwise be taken for upstream's whole version list, and the versions it never reached would go unbranched.
  if ! RAW_OUTPUT=$(list_upstream_versions); then
    return 1
  fi
  if [[ -n ${RAW_OUTPUT} ]]; then
    mapfile -t RAW_VERSIONS <<<"${RAW_OUTPUT}"
  fi
  if ((${#RAW_VERSIONS[@]} == 0)); then
    echo "error: upstream discovery found no version names at $(discovery_endpoint) for source type ${VERSION_SOURCE_TYPE:-${SOURCE_TYPE}} tracking ${VERSION_TRACK}" >&2
    return 1
  fi
  # Canonical versions drive sorting and branch naming. The name the version updater has to fetch is retained for the exact refresh job: a registry's tag list names the images it publishes, so its tag is that name, while a release tree only names versions, which is what the artifact behind each one is published under.
  local REGISTRY_NAMES=false
  if [[ ${VERSION_SOURCE_TYPE:-${SOURCE_TYPE}} == "registry" ]]; then
    REGISTRY_NAMES=true
  fi
  for RAW in "${RAW_VERSIONS[@]}"; do
    V=$(github_version_from_tag "${RAW}" || true)
    if [[ ${V} =~ ${VERSION_RE} ]]; then
      CANON=$(canonicalize_version "${V}")
      if [[ ! ${CANON} =~ ${SAFE_VERSION_RE} ]]; then
        echo "error: upstream version ${V} canonicalizes to unsafe branch version ${CANON}" >&2
        return 1
      fi
      if [[ -n ${STRIPPED_OF[${CANON}]+set} && ${STRIPPED_OF[${CANON}]} != "${V}" ]]; then
        echo "error: upstream versions ${STRIPPED_OF[${CANON}]} and ${V} canonicalize to ${CANON}" >&2
        return 1
      fi
      STRIPPED_OF["${CANON}"]="${V}"
      if [[ ${REGISTRY_NAMES} == true && -n ${ORIG_OF[${CANON}]+set} && ${ORIG_OF[${CANON}]} != "${RAW}" ]]; then
        echo "error: ${RAW} and ${ORIG_OF[${CANON}]} are both tags of ${CANON}, so its image has no single name" >&2
        return 1
      fi
      ALL_VERSIONS+=("${CANON}")
      if [[ ${REGISTRY_NAMES} == true ]]; then
        ORIG_OF["${CANON}"]="${RAW}"
      else
        ORIG_OF["${CANON}"]="${V}"
      fi
    fi
  done

  if [[ ${SOURCE_TYPE} == "pypi" ]]; then
    mapfile -t SORTED_VERSIONS < <(sort_versions_descending "${ALL_VERSIONS[@]}")
  else
    for V in "${ALL_VERSIONS[@]}"; do
      if ! version_lt "${V}" "${MINIMUM_TRACKING_VERSION}"; then
        SORTED_VERSIONS+=("${V}")
      fi
    done
    mapfile -t SORTED_VERSIONS < <(sort_versions_descending "${SORTED_VERSIONS[@]}")
  fi
  for V in "${SORTED_VERSIONS[@]}"; do
    if [[ -z ${SEEN[${V}]+set} ]]; then
      SEEN["${V}"]=1
      if [[ ${TRACK_STABLE_ONLY} == "true" ]] && is_prerelease "${V}"; then continue; fi
      TRACKED+=("${V}")
    fi
  done

  if ((${#TRACKED[@]} == 0)); then
    echo "No upstream versions >= ${MINIMUM_TRACKING_VERSION}." >&2
  else
    echo "Tracking ${#TRACKED[@]} upstream versions (newest first): ${TRACKED[*]}" >&2
  fi
}

versions_json() {
  local V STABLE
  {
    for V in "${TRACKED[@]}"; do
      STABLE=true
      if is_prerelease "${V}"; then STABLE=false; fi
      jq -cn \
        --arg version "${V}" \
        --arg upstreamVersion "${ORIG_OF[${V}]}" \
        --argjson stable "${STABLE}" \
        '{version: $version, upstreamVersion: $upstreamVersion, stable: $stable}'
    done
  } | jq -sc '.'
}

load_versions_json() {
  local JSON="${1}" ROW V UPSTREAM
  local -a ROWS=() SORTED_VERSIONS=()
  local -A SEEN=()
  if ! jq -e 'type == "array" and all(.[]; type == "object" and (.version | type == "string") and (.upstreamVersion | type == "string") and (.stable | type == "boolean"))' <<<"${JSON}" >/dev/null; then
    echo "error: --versions-json must be the versions array emitted by update-branches list" >&2
    return 2
  fi
  TRACKED=()
  ORIG_OF=()
  mapfile -t ROWS < <(jq -r '.[] | [.version, .upstreamVersion] | @tsv' <<<"${JSON}")
  for ROW in "${ROWS[@]}"; do
    IFS=$'\t' read -r V UPSTREAM <<<"${ROW}"
    if [[ ! ${V} =~ ${SAFE_VERSION_RE} || ! ${UPSTREAM} =~ ${SAFE_REF_RE} ]]; then
      echo "error: discovery manifest contains an unsafe version" >&2
      return 2
    fi
    if [[ -n ${SEEN[${V}]+set} ]]; then
      echo "error: discovery manifest contains duplicate version ${V}" >&2
      return 2
    fi
    SEEN["${V}"]=1
    SORTED_VERSIONS+=("${V}")
    ORIG_OF["${V}"]="${UPSTREAM}"
  done
  mapfile -t TRACKED < <(sort_versions_descending "${SORTED_VERSIONS[@]}")
}

remove_worktree() {
  local WT="${1}"
  git worktree remove --force "${WT}" >/dev/null 2>&1 || true
}

refresh_version() {
  local VERSION="${1}" UPSTREAM="${2}" BRANCH="v${1}" WT UPDATE_PHASE UPDATE_EXIT
  local EXPECTED_REMOTE_SHA=""
  local -a OWNED_PATHS=()
  LAST_FAILURE_REASON=""
  if [[ ! ${VERSION} =~ ${SAFE_VERSION_RE} || ! ${UPSTREAM} =~ ${SAFE_REF_RE} ]]; then
    LAST_FAILURE_REASON="unsafe version argument"
    return 2
  fi
  WT=$(mktemp -d)
  if git rev-parse --verify --quiet "origin/${BRANCH}" >/dev/null; then
    echo
    echo "=== Refreshing existing branch ${BRANCH} from base ${BASE_SHA:0:8}"
    if ! retry git fetch --quiet origin "${BRANCH}:refs/remotes/origin/${BRANCH}"; then
      LAST_FAILURE_REASON="fetching ${BRANCH} failed"
      remove_worktree "${WT}"
      return 1
    fi
    EXPECTED_REMOTE_SHA=$(git rev-parse --verify "origin/${BRANCH}^{commit}")
    if ! git worktree add -B "${BRANCH}" "${WT}" "origin/${BRANCH}" >/dev/null; then
      LAST_FAILURE_REASON="git worktree add failed"
      remove_worktree "${WT}"
      return 1
    fi
    # Never merge a live aggregate: every exact job uses the specification SHA captured by discovery, even if an earlier publisher has advanced main.
    if ! (cd "${WT}" && merge_preserving_owned "${BASE_SHA}"); then
      LAST_FAILURE_REASON="merge of discovery base ${BASE_SHA} failed"
      remove_worktree "${WT}"
      return 1
    fi
  else
    echo
    echo "=== Creating new branch ${BRANCH} from base ${BASE_SHA:0:8}"
    if ! git worktree add -B "${BRANCH}" "${WT}" "${BASE_SHA}" >/dev/null; then
      LAST_FAILURE_REASON="git worktree add failed"
      remove_worktree "${WT}"
      return 1
    fi
    if ! (cd "${WT}" && prepare_new_branch_pin "${VERSION}"); then
      LAST_FAILURE_REASON="preparing the new branch pin failed"
      remove_worktree "${WT}"
      return 1
    fi
  fi

  pushd "${WT}" >/dev/null
  UPDATE_PHASE="nix flake update"
  UPDATE_EXIT=0
  if run_with_transient_retry "nix flake update for ${BRANCH}" nix flake update; then
    UPDATE_PHASE="update-version"
    run_with_transient_retry "update-version for ${BRANCH}" env FLAKE_ROOT="${WT}" ORCHESTRATED_OWNED_FILES="${BRANCH_OWNED_FILES}" nix run .#update-version -- "${VERSION}" "${UPSTREAM}" || UPDATE_EXIT=${?}
  else
    UPDATE_EXIT=${?}
  fi
  if ((UPDATE_EXIT != 0)); then
    LAST_FAILURE_REASON="${UPDATE_PHASE} failed (exit ${UPDATE_EXIT})"
    echo "::warning title=Branch ${BRANCH} skipped::${UPDATE_PHASE} failed for ${VERSION} (exit ${UPDATE_EXIT}). See the orchestrator log above."
    echo "  WARN: ${UPDATE_PHASE} failed for ${BRANCH} (exit ${UPDATE_EXIT}). Skipping." >&2
    popd >/dev/null
    remove_worktree "${WT}"
    return 1
  fi
  # A machine commit that is not formatted leaves the branch failing its own formatting check until a human formats the tree.
  if ! nix fmt; then
    LAST_FAILURE_REASON="formatting ${BRANCH} failed"
    echo "::warning title=Branch ${BRANCH} not published::nix fmt failed, so nothing was committed on ${BRANCH}."
    echo "  ERROR: nix fmt failed for ${BRANCH}, so ${BRANCH} was not published." >&2
    popd >/dev/null
    remove_worktree "${WT}"
    return 1
  fi
  # The pull-request gate, run here against the worktree this branch is about to push: one definition of what a runner verifies, so a producer publishes exactly what a pull request would have gated. The gate builds the packages this flake publishes and checks the flake, which builds the checks that realize what an overlay produces.
  if [[ ${BUILD_VERIFICATION_SKIP} == "true" ]]; then
    echo "  publication verification skipped"
  elif ! run_with_transient_retry "gate for ${BRANCH}" "${BUILD_AND_CHECK_SCRIPT:?required env var}"; then
    LAST_FAILURE_REASON="a build or check failed at ${VERSION}"
    echo "::warning title=Branch ${BRANCH} not published::a build or check failed at ${VERSION}, so no commit was pushed to ${BRANCH}."
    echo "  ERROR: a build or check failed at ${VERSION}, so ${BRANCH} was not published." >&2
    popd >/dev/null
    remove_worktree "${WT}"
    return 1
  fi
  mapfile -t OWNED_PATHS < <(matching_owned_paths || true)
  if ((${#OWNED_PATHS[@]} > 0)) && { ! git diff --quiet HEAD -- "${OWNED_PATHS[@]}" || [[ -n "$(git ls-files --others --exclude-standard -- "${OWNED_PATHS[@]}")" ]]; }; then
    if ! git add -A -- "${OWNED_PATHS[@]}" || ! git commit -q -m "auto: ${VERSION} pin"; then
      LAST_FAILURE_REASON="committing ${BRANCH} failed"
      popd >/dev/null
      remove_worktree "${WT}"
      return 1
    fi
    if ! push_ref HEAD "${BRANCH}" "${EXPECTED_REMOTE_SHA}" normal; then
      LAST_FAILURE_REASON="pushing ${BRANCH} failed"
      popd >/dev/null
      remove_worktree "${WT}"
      return 1
    fi
  else
    echo "  no change on ${BRANCH}"
    # Merge may have advanced HEAD without touching the branch-owned files.
    if [[ "$(git rev-parse HEAD)" != "${EXPECTED_REMOTE_SHA}" ]]; then
      if ! push_ref HEAD "${BRANCH}" "${EXPECTED_REMOTE_SHA}" normal; then
        LAST_FAILURE_REASON="pushing ${BRANCH} failed"
        popd >/dev/null
        remove_worktree "${WT}"
        return 1
      fi
    fi
  fi
  popd >/dev/null
  remove_worktree "${WT}"
}

aggregate_keys_for_version() {
  local VERSION="${1}" MAJOR MINOR PATCH
  printf '%s\n' main
  IFS='.' read -r MAJOR MINOR PATCH <<<"${VERSION}"
  if [[ -n ${MINOR} ]]; then printf 'v%s\n' "${MAJOR}"; fi
  if [[ -n ${PATCH} ]]; then printf 'v%s.%s\n' "${MAJOR}" "${MINOR}"; fi
}

aggregate_tip_retained_elsewhere() {
  local TIP_SHA="${1}" V
  for V in "${TRACKED[@]}"; do
    if git rev-parse --verify --quiet "origin/v${V}^{commit}" >/dev/null &&
      git merge-base --is-ancestor "${TIP_SHA}" "origin/v${V}^{commit}"; then
      return 0
    fi
  done
  return 1
}

publish_aggregates() {
  # Aggregate refs move to a commit an exact branch already published, and that refresh built what the branch publishes before pushing it. Nothing is built here.
  local V BRANCH TARGET_SHA STABLE AGG TARGET_V TARGET_BRANCH CUR_SHA CURRENT_V CURRENT_BRANCH CURRENT_BRANCH_SHA CURRENT_IS_SAFE STABLE_V
  local -a KEYS=() AGGREGATES=()
  local -A HIGHEST_ANY=() HIGHEST_STABLE=() AGGREGATE_SET=()
  BLOCKED_AGGREGATES=()
  BLOCKED_AGGREGATE_REASONS=()

  git fetch --prune --quiet origin || return
  for V in "${TRACKED[@]}"; do
    BRANCH="v${V}"
    if ! git rev-parse --verify --quiet "origin/${BRANCH}" >/dev/null; then
      continue
    fi
    TARGET_SHA=$(git rev-parse --verify "origin/${BRANCH}^{commit}")
    STABLE=true
    if is_prerelease "${V}"; then STABLE=false; fi
    mapfile -t KEYS < <(aggregate_keys_for_version "${V}")
    if ! git merge-base --is-ancestor "${BASE_SHA}" "${TARGET_SHA}"; then
      for AGG in "${KEYS[@]}"; do
        AGGREGATE_SET["${AGG}"]=1
      done
      continue
    fi
    for AGG in "${KEYS[@]}"; do
      AGGREGATE_SET["${AGG}"]=1
      if [[ -z ${HIGHEST_ANY[${AGG}]+set} ]]; then HIGHEST_ANY["${AGG}"]="${V}"; fi
      if [[ ${STABLE} == true && -z ${HIGHEST_STABLE[${AGG}]+set} ]]; then HIGHEST_STABLE["${AGG}"]="${V}"; fi
    done
  done

  echo
  echo "=== Updating aggregate pointers from base ${BASE_SHA:0:8}"
  if ((${#AGGREGATE_SET[@]} > 0)); then
    mapfile -t AGGREGATES < <(printf '%s\n' "${!AGGREGATE_SET[@]}" | sort)
  fi
  for AGG in "${AGGREGATES[@]}"; do
    if [[ -z ${HIGHEST_ANY[${AGG}]+set} ]]; then
      BLOCKED_AGGREGATES+=("${AGG}")
      BLOCKED_AGGREGATE_REASONS["${AGG}"]="no candidate for ${AGG} contains discovery base ${BASE_SHA}"
      echo "::warning title=Aggregate ${AGG} skipped::No candidate for ${AGG} contains discovery base ${BASE_SHA}. Retaining ${AGG}."
      continue
    fi
    TARGET_V="${HIGHEST_ANY[${AGG}]}"
    TARGET_BRANCH="v${TARGET_V}"
    TARGET_SHA=$(git rev-parse --verify "origin/${TARGET_BRANCH}^{commit}")
    CUR_SHA=$(git rev-parse --verify "origin/${AGG}^{commit}" 2>/dev/null || true)

    # Prereleases may advance an absent/prerelease aggregate. A currently stable aggregate instead advances to the highest successful stable candidate, which need not be the stable counterpart of the highest prerelease.
    if is_prerelease "${TARGET_V}" && [[ -n ${CUR_SHA} ]]; then
      CURRENT_V=$(git show "${CUR_SHA}:pin.nix" 2>/dev/null | sed -nE 's/^[[:space:]]*version = "([^"]+)";$/\1/p' | head -1 || true)
      if ! is_prerelease "${CURRENT_V}"; then
        STABLE_V="${HIGHEST_STABLE[${AGG}]:-}"
        CURRENT_BRANCH="v${CURRENT_V}"
        CURRENT_BRANCH_SHA=""
        CURRENT_IS_SAFE=false
        if [[ -n ${CURRENT_V} ]] && git rev-parse --verify --quiet "origin/${CURRENT_BRANCH}" >/dev/null; then
          CURRENT_BRANCH_SHA=$(git rev-parse --verify "origin/${CURRENT_BRANCH}^{commit}")
          if git merge-base --is-ancestor "${BASE_SHA}" "${CURRENT_BRANCH_SHA}"; then CURRENT_IS_SAFE=true; fi
        fi
        if [[ -n ${STABLE_V} ]] && { [[ ${CURRENT_IS_SAFE} == false ]] || version_lt "${CURRENT_V}" "${STABLE_V}"; }; then
          TARGET_V="${STABLE_V}"
          TARGET_BRANCH="v${TARGET_V}"
          TARGET_SHA=$(git rev-parse --verify "origin/${TARGET_BRANCH}^{commit}")
        elif [[ ${CURRENT_IS_SAFE} == true ]]; then
          TARGET_BRANCH="${CURRENT_BRANCH}"
          TARGET_SHA="${CURRENT_BRANCH_SHA}"
        elif [[ -z ${STABLE_V} && -n ${CURRENT_BRANCH_SHA} ]]; then
          TARGET_BRANCH="${CURRENT_BRANCH}"
          TARGET_SHA="${CURRENT_BRANCH_SHA}"
        else
          echo "  ${AGG} remains at its current stable target"
          continue
        fi
      fi
    fi
    if [[ ${CUR_SHA} == "${TARGET_SHA}" ]]; then
      echo "  ${AGG} already at ${TARGET_BRANCH}"
      continue
    fi
    # A commit merged onto the aggregate after discovery captured the base leaves it ahead of the target rather than behind it. The next run discovers that tip and carries it into the exact branches.
    if [[ -n ${CUR_SHA} ]] && git merge-base --is-ancestor "${TARGET_SHA}" "${CUR_SHA}"; then
      echo "  ${AGG} is ahead of ${TARGET_BRANCH} (tip ${CUR_SHA:0:8} carries it)"
      continue
    fi
    if ! git merge-base --is-ancestor "${BASE_SHA}" "${TARGET_SHA}"; then
      BLOCKED_AGGREGATES+=("${AGG}")
      BLOCKED_AGGREGATE_REASONS["${AGG}"]="${TARGET_BRANCH} does not contain discovery base ${BASE_SHA}"
      echo "::warning title=Aggregate ${AGG} skipped::${TARGET_BRANCH} does not contain discovery base ${BASE_SHA}. Retaining ${AGG}."
      continue
    fi
    # Advancing past a tip reachable from no tracked exact branch would discard commits that exist only on the aggregate (e.g. a specification merged to main after discovery captured its base).
    if [[ -n ${CUR_SHA} ]] &&
      ! git merge-base --is-ancestor "${CUR_SHA}" "${TARGET_SHA}" &&
      ! aggregate_tip_retained_elsewhere "${CUR_SHA}"; then
      BLOCKED_AGGREGATES+=("${AGG}")
      BLOCKED_AGGREGATE_REASONS["${AGG}"]="current tip ${CUR_SHA:0:8} is reachable from neither ${TARGET_BRANCH} nor any tracked exact branch"
      echo "::warning title=Aggregate ${AGG} skipped::Advancing ${AGG} to ${TARGET_BRANCH} would orphan its current tip ${CUR_SHA:0:8}. Retaining ${AGG}."
      continue
    fi
    echo "  ${AGG} -> ${TARGET_BRANCH} (${TARGET_SHA:0:8})"
    if ! push_ref "${TARGET_SHA}" "${AGG}" "${CUR_SHA}" lease; then
      echo "error: aggregate ${AGG} could not be published" >&2
      return 1
    fi
  done
}

write_failure_summary() {
  local -n FAILED_REF="${1}" REASONS_REF="${2}"
  local V AGG
  if ((${#FAILED_REF[@]} > 0)); then
    echo "=== ${#FAILED_REF[@]} branch(es) failed: ${FAILED_REF[*]}"
    if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
      {
        echo "## :warning: ${#FAILED_REF[@]} branch(es) failed to update"
        echo
        echo "These upstream versions failed during input refresh or package update. Their exact branches were left unchanged. Aggregate pointers were checked separately before publication."
        echo
        for V in "${FAILED_REF[@]}"; do echo "- \`v${V}\`: ${REASONS_REF[${V}]}"; done
        echo
        echo "See the orchestrator log for the underlying error per version."
      } >>"${GITHUB_STEP_SUMMARY}"
    fi
  fi
  if ((${#BLOCKED_AGGREGATES[@]} > 0)); then
    echo "=== ${#BLOCKED_AGGREGATES[@]} aggregate pointer(s) retained: ${BLOCKED_AGGREGATES[*]}"
    if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
      {
        echo "## :warning: ${#BLOCKED_AGGREGATES[@]} aggregate pointer(s) retained"
        echo
        echo "Their selected exact branches were not safe publication targets."
        echo
        for AGG in "${BLOCKED_AGGREGATES[@]}"; do echo "- \`${AGG}\`: ${BLOCKED_AGGREGATE_REASONS[${AGG}]:-unspecified reason}"; done
      } >>"${GITHUB_STEP_SUMMARY}"
    fi
  fi
}

command_list() {
  local JSON
  capture_base_sha
  discover_versions
  JSON=$(versions_json)
  JSON=$(jq -cn --arg baseSha "${BASE_SHA}" --argjson versions "${JSON}" '{baseSha: $baseSha, versions: $versions}')
  # Under Actions the fan-out is the workflow's only input, so it is written in the form the next jobs read rather than having the workflow parse this back apart.
  if [[ -n ${GITHUB_OUTPUT:-} ]]; then
    jq -r '"base_sha=\(.baseSha)", "versions=\(.versions | tojson)"' <<<"${JSON}" >>"${GITHUB_OUTPUT}"
  fi
  printf '%s\n' "${JSON}"
}

command_refresh() {
  local BASE="" VERSION="" UPSTREAM=""
  shift
  while (($# > 0)); do
    case "${1}" in
    --base-sha)
      [[ $# -ge 2 ]] || {
        usage
        return 2
      }
      BASE="${2}"
      shift 2
      ;;
    --version)
      [[ $# -ge 2 ]] || {
        usage
        return 2
      }
      VERSION="${2}"
      shift 2
      ;;
    --upstream-version)
      [[ $# -ge 2 ]] || {
        usage
        return 2
      }
      UPSTREAM="${2}"
      shift 2
      ;;
    *)
      usage
      return 2
      ;;
    esac
  done
  if [[ -z ${BASE} || -z ${VERSION} || -z ${UPSTREAM} ]]; then
    usage
    return 2
  fi
  use_base_sha "${BASE}"
  if ! refresh_version "${VERSION}" "${UPSTREAM}"; then
    local -a FAILED=("${VERSION}")
    local -A REASONS=(["${VERSION}"]="${LAST_FAILURE_REASON}")
    write_failure_summary FAILED REASONS
    return 1
  fi
  echo "Done."
}

command_publish() {
  local BASE="" JSON=""
  local -a FAILED=()
  local -A REASONS=()
  shift
  while (($# > 0)); do
    case "${1}" in
    --base-sha)
      [[ $# -ge 2 ]] || {
        usage
        return 2
      }
      BASE="${2}"
      shift 2
      ;;
    --versions-json)
      [[ $# -ge 2 ]] || {
        usage
        return 2
      }
      JSON="${2}"
      shift 2
      ;;
    *)
      usage
      return 2
      ;;
    esac
  done
  if [[ -z ${BASE} || -z ${JSON} ]]; then
    usage
    return 2
  fi
  use_base_sha "${BASE}"
  load_versions_json "${JSON}"
  publish_aggregates
  write_failure_summary FAILED REASONS
  if ((${#BLOCKED_AGGREGATES[@]} > 0)); then return 1; fi
  echo "Done."
}

command_all() {
  local JSON V PUBLISH_EXIT=0
  local -a FAILED=()
  local -A FAILURE_REASON=()
  capture_base_sha
  discover_versions
  if ((${#TRACKED[@]} == 0)); then
    echo "Done."
    return
  fi
  JSON=$(versions_json)
  for V in "${TRACKED[@]}"; do
    if ! refresh_version "${V}" "${ORIG_OF[${V}]}"; then
      FAILED+=("${V}")
      FAILURE_REASON["${V}"]="${LAST_FAILURE_REASON}"
    fi
  done
  load_versions_json "${JSON}"
  publish_aggregates || PUBLISH_EXIT=${?}
  echo
  write_failure_summary FAILED FAILURE_REASON
  if ((${#FAILED[@]} > 0 || ${#BLOCKED_AGGREGATES[@]} > 0 || PUBLISH_EXIT != 0)); then return 1; fi
  echo "Done."
}

case "${1:-}" in
"") command_all ;;
list)
  [[ $# == 1 ]] || {
    usage
    exit 2
  }
  command_list
  ;;
refresh) command_refresh "${@}" ;;
publish) command_publish "${@}" ;;
*)
  usage
  exit 2
  ;;
esac
