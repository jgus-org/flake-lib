#!/usr/bin/env -S nix shell nixpkgs#bash nixpkgs#curl nixpkgs#jq nixpkgs#nix nixpkgs#gh nixpkgs#gnused nixpkgs#nix-prefetch-github nixpkgs#nix-prefetch-git nixpkgs#coreutils --command bash

# Generic update-version for jgus sub-flakes, driven by env vars injected by flake-lib's mkUpdateVersion:
#   SOURCE_TYPE   pypi | github | github-release-asset | gitlab | huggingface | oci | mutable-url
#   PYPI_NAME     PyPI distribution name (underscore form)   [pypi]
#   PYPI_FORMAT   sdist | wheel                              [pypi]
#   VERSION_SOURCE_TYPE       the source an oci producer discovers versions from (github | registry). Empty for a single-branch image    [oci]
#   VERSION_TAG_PREFIX        the prefix an oci registry puts on the tag it publishes a version under    [oci registry]
#   REGISTRY_TAGS_LIB         the sourced helper that lists a registry's tags    [oci registry]
#   GH_OWNER/GH_REPO          GitHub owner/repo              [github, github-release-asset, oci release source]
#   GH_TRACK                  release (Releases API) | tag (latest version git tag) | commit (default-branch HEAD -> 0.devDATE+gREV)  [github]
#   GH_BRANCH                 commit-tracking: branch to follow (default: repo default branch)  [github]
#   GH_ASSET                  release-asset filename template; tokens ${version} (tag minus leading v) and ${tag}  [github-release-asset]
#   GH_TAG                    release-tag template; token ${version} (default: the declared tag prefix, or v, before the version)  [github-release-asset]
#   GH_TAG_PREFIXES           JSON array of the prefixes a version's tag may carry; the source's tagPrefix when it declares one
#   GITLAB_OWNER/GITLAB_REPO  GitLab owner/repo              [gitlab]
#   GITLAB_DOMAIN             GitLab host (default gitlab.com)                       [gitlab]
#   GITLAB_TRACK              release (tags -> X.Y.Z) | commit (master HEAD -> 0.devDATE+gREV)  [gitlab]
#   HF_REPO/HF_REVISION       repository and followed revision                    [huggingface]
#   HF_MANIFEST_*             optional metadata-only artifact manifest settings   [huggingface]
#   SIBLINGS      JSON array of sibling-cascade specs (may be [])
#   CASCADE_PY    path to cascade.py (python3+packaging supplied via runtimeInputs)
#
#   nix run .#update-version            # latest upstream
#   nix run .#update-version -- X.Y.Z   # specific version / ref
#
# Run from the flake root (or set FLAKE_ROOT).

set -euo pipefail

FLAKE_ROOT="${FLAKE_ROOT:-${PWD}}"
PIN_PATH="${FLAKE_ROOT}/pin.nix"
FLAKE_PATH="${FLAKE_ROOT}/flake.nix"

if [[ ! -f ${PIN_PATH} ]]; then
  echo "error: no pin.nix in ${FLAKE_ROOT}" >&2
  exit 1
fi

REQUESTED="${1:-}"
# Optional upstream ref to fetch, distinct from the version written to the pin. Lets the orchestrator pin a canonical version string (e.g. 0.1.40.5-beta) while still resolving the raw upstream tag (e.g. v0.1.405-beta). Defaults to `REQUESTED`, i.e. version == ref.
REQUESTED_REF="${2:-}"
PIN_CHANGED=0
NEW_VERSION=""
CASCADE_CHANGED=0
LOCK_CHANGED=0

# Optional seams (defaulted so simple pypi leaves need not set them):
HASH_MODE="${HASH_MODE:-prefetch}" # prefetch | build-failure (source/vendor hash)
EXTRA_HASHES="${EXTRA_HASHES:-[]}" # JSON array of extra pin field names (e.g. ["npmDepsHash"])
PIN_HASHES="${PIN_HASHES:-${EXTRA_HASHES}}"
BUILD_FAILURE_HASHES="${BUILD_FAILURE_HASHES:-[]}"
BUILD_FAILURE_TARGETS="${BUILD_FAILURE_TARGETS:-}" # JSON object of pin field name -> the published package whose fetch produces it
ARTIFACT_HOOK="${ARTIFACT_HOOK:-}"                 # consumer script: regenerate vendored files, emit name=value extra hashes
FORMATTER="${FORMATTER:-}"                         # the repository's formatter binary, which puts a nested pin field in its canonical shape
ORCHESTRATED_OWNED_FILES="${ORCHESTRATED_OWNED_FILES:-}"
SIBLINGS="${SIBLINGS:-[]}"
SIBLING_REFS_IN_PIN="${SIBLING_REFS_IN_PIN:-}"
MARKER_ENV="${MARKER_ENV:-}"
CASCADE_PY="${CASCADE_PY:-}"
VERSION_SOURCE_TYPE="${VERSION_SOURCE_TYPE:-}"
GH_TRACK="${GH_TRACK:-release}"
GH_BRANCH="${GH_BRANCH:-}"
GH_TAG_PREFIXES="${GH_TAG_PREFIXES:-[\"v\",\"V\",\"\"]}"
GH_FETCH_SUBMODULES="${GH_FETCH_SUBMODULES:-}" # non-empty: hash the tree with submodules
GH_ASSET="${GH_ASSET:-}"
GH_TAG="${GH_TAG:-}"
GITLAB_DOMAIN="${GITLAB_DOMAIN:-gitlab.com}"
GITLAB_TRACK="${GITLAB_TRACK:-commit}"
HF_REPO="${HF_REPO:-}"
HF_REVISION="${HF_REVISION:-main}"
HF_FILES="${HF_FILES:-[]}"
HF_MANIFEST_PATH="${HF_MANIFEST_PATH:-}"
HF_MANIFEST_INCLUDE="${HF_MANIFEST_INCLUDE:-[]}"
HF_MANIFEST_EXCLUDE="${HF_MANIFEST_EXCLUDE:-[]}"
HF_MANIFEST_HASH_FIELD="${HF_MANIFEST_HASH_FIELD:-}"
MUTABLE_URL="${MUTABLE_URL:-}"
VERSION_TAG_PREFIX="${VERSION_TAG_PREFIX:-}"
mapfile -t GITHUB_TAG_PREFIXES < <(jq -r '.[]' <<<"${GH_TAG_PREFIXES}")
mapfile -t BUILD_FAILURE_FIELDS < <(jq -r '.[]' <<<"${BUILD_FAILURE_HASHES}")

if [[ ${SOURCE_TYPE} == "oci" && ${VERSION_SOURCE_TYPE} == "registry" ]]; then
  # shellcheck source=/dev/null
  source "${REGISTRY_TAGS_LIB:?required env var}"
fi

declare -A EXTRA=()
declare -A HF_HASHES=()
RESOLVED_SIBLING_REFS='{}'

# Every derivation this flake publishes has to instantiate, not only the tracked one. A producer whose deliverable is an overlay publishes no payload of its own, and what is left in `packages` is its tooling. That tooling still has to evaluate before a pin is written.
evaluate_published_packages() {
  local SYSTEM
  SYSTEM=$(nix config show system) || {
    echo "error: this nix does not report the system it builds for" >&2
    exit 1
  }
  echo "Evaluating the packages this flake publishes for ${SYSTEM}..."
  nix eval --raw "${FLAKE_ROOT}#packages.${SYSTEM}" --apply '
    packages: builtins.toString (
      builtins.length (builtins.filter (package: package ? drvPath) (builtins.attrValues packages))
    )
  ' >/dev/null
}

finish_unchanged() {
  local VERSION="${1}"
  evaluate_published_packages
  echo "Already up to date (${VERSION})."
  exit 0
}

# A commit-tracked source has no upstream version to carry, and a producer that is a python one puts whatever label the pin holds into package metadata: `0-unstable-YYYY-MM-DD` is what the updater used to write, and `packaging.version.Version` refuses it, so the payload fails the build that reads its own version. A dev release of 0 sorts below every real release the upstream may one day tag, and the rev suffix distinguishes two commits taken on one day in a branch name as well as in the pin.
commit_version() {
  local DATE="${1}" REV="${2}"
  printf '0.dev%s+g%s' "$(tr -dc '0-9' <<<"${DATE}" | cut -c1-8)" "${REV:0:8}"
}

# The org formatter sorts attributes, so a pin written in any other order comes back changed from the next format of the tree, traded between the updater's commit and a human's reformat.
write_pin_fields() {
  local -n PIN_FIELDS="${1}"
  local NAME
  while IFS= read -r NAME; do
    printf '%s\n' "${PIN_FIELDS[${NAME}]}"
  done < <(printf '%s\n' "${!PIN_FIELDS[@]}" | LC_ALL=C sort)
}

format_pin() {
  # The writer emits one flat line per field, and a dotted field name asks for a nested attribute whose shape only the org formatter defines, so the pin is written and then formatted by the formatter the repository's own formatting check runs. Without FORMATTER the flat lines stand, which is all a pin of only flat field names ever needed.
  [[ -z ${FORMATTER} ]] && return 0
  # One file per run, and treefmt's evaluation cache lives under a HOME the updater may not have.
  (cd "$(dirname "${1}")" && "${FORMATTER}" --no-cache "$(basename "${1}")")
}

pin_sibling_refs_field() {
  local -n PIN_FIELDS="${1}"
  [[ -z ${SIBLING_REFS_IN_PIN} ]] && return 0
  PIN_FIELDS[dependencies]="$(
    {
      echo "  dependencies = {"
      jq -r 'to_entries | sort_by(.key)[] | "    " + (.key | tojson) + " = " + (.value | tojson) + ";"' <<<"${RESOLVED_SIBLING_REFS}"
      echo "  };"
    }
  )"
}

sibling_refs_current() {
  [[ -z ${SIBLING_REFS_IN_PIN} ]] && return 0
  local CURRENT_REFS
  CURRENT_REFS=$(nix eval --json --file "${PIN_PATH}" dependencies 2>/dev/null || echo '{}')
  [[ "$(jq -cS . <<<"${CURRENT_REFS}")" == "$(jq -cS . <<<"${RESOLVED_SIBLING_REFS}")" ]]
}

write_pypi_pin() {
  local VERSION="${1}" HASH="${2}" NAME
  local -A FIELDS=()
  FIELDS[version]="  version = \"${VERSION}\";"
  FIELDS[hash]="  hash = \"${HASH}\";"
  for NAME in $(jq -r '.[]' <<<"${PIN_HASHES}"); do
    FIELDS["${NAME}"]="  ${NAME} = \"${EXTRA[${NAME}]:-}\";"
  done
  pin_sibling_refs_field FIELDS
  {
    echo "{"
    write_pin_fields FIELDS
    echo "}"
  } >"${PIN_PATH}"
}

pypi_pin_current() {
  local VERSION="${1}" HASH="${2}" CURRENT_VERSION CURRENT_HASH NAME VALUE
  CURRENT_VERSION=$(nix eval --raw --file "${PIN_PATH}" version 2>/dev/null || echo "")
  CURRENT_HASH=$(nix eval --raw --file "${PIN_PATH}" hash 2>/dev/null || echo "")
  [[ ${CURRENT_VERSION} == "${VERSION}" && ${CURRENT_HASH} == "${HASH}" ]] || return 1
  for NAME in $(jq -r '.[]' <<<"${PIN_HASHES}"); do
    VALUE=$(nix eval --raw --file "${PIN_PATH}" "${NAME}" 2>/dev/null || echo "")
    [[ -n ${VALUE} ]] || return 1
  done
  artifact_pin_current || return 1
  sibling_refs_current
}

# Buffers output and emits it only on success, so a consumer never sees partial data from an attempt that died mid-stream. The tag-spelling probes are wrapped at whole-sweep granularity (resolve_*_ref_sha) so an expected 404 on one candidate spelling is never individually retried.
retry() {
  local ATTEMPT OUTPUT
  for ATTEMPT in 1 2 3 4 5; do
    if OUTPUT=$("${@}"); then
      [[ -z ${OUTPUT} ]] || printf '%s\n' "${OUTPUT}"
      return 0
    fi
    if ((ATTEMPT < 5)); then
      echo "  ${1} failed (attempt ${ATTEMPT}/5). Retrying in 5s..." >&2
      sleep 5
    fi
  done
  echo "  ${1} failed after 5 attempts" >&2
  return 1
}

fetch_repo_file() {
  local FILE_PATH="${1}" REV="${2}" PROJ ENC
  case "${SOURCE_TYPE}" in
  github)
    retry gh api "/repos/${GH_OWNER}/${GH_REPO}/contents/${FILE_PATH}?ref=${REV}" --jq '.content' | base64 -d
    ;;
  gitlab)
    PROJ="${GITLAB_OWNER}%2F${GITLAB_REPO}"
    ENC=$(jq -rn --arg p "${FILE_PATH}" '$p|@uri')
    retry curl -sSfL "https://${GITLAB_DOMAIN}/api/v4/projects/${PROJ}/repository/files/${ENC}/raw?ref=${REV}"
    ;;
  esac
}

resolve_github_ref_sha() {
  local REF_BASE="${1}" PREFIX CANDIDATE SHA
  local -a CANDIDATES=()
  for PREFIX in "${GITHUB_TAG_PREFIXES[@]}"; do
    CANDIDATES+=("${PREFIX}${REF_BASE}")
  done
  for CANDIDATE in "${CANDIDATES[@]}"; do
    if SHA=$(gh api "/repos/${GH_OWNER}/${GH_REPO}/commits/${CANDIDATE}" --jq '.sha' 2>/dev/null) && [[ -n ${SHA} ]]; then
      echo "${SHA}"
      return 0
    fi
  done
  return 1
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

resolve_gitlab_ref_sha() {
  local PROJ="${1}" REF_BASE="${2}" CANDIDATE ID PREFIX
  local -a CANDIDATES=()
  for PREFIX in "${GITHUB_TAG_PREFIXES[@]}"; do
    CANDIDATES+=("${PREFIX}${REF_BASE}")
  done
  for CANDIDATE in "${CANDIDATES[@]}"; do
    if ID=$(curl -sSfL "https://${GITLAB_DOMAIN}/api/v4/projects/${PROJ}/repository/commits/${CANDIDATE}" 2>/dev/null | jq -r '.id // ""') && [[ -n ${ID} && ${ID} != "null" ]]; then
      echo "${ID}"
      return 0
    fi
  done
  return 1
}

rewrite_sibling_url() {
  local FLAKE_REPO="${1}" REF="${2}" BEFORE AFTER
  BEFORE=$(sha256sum "${FLAKE_PATH}")
  sed -i -E "s|(url = \"github:${FLAKE_REPO})(/[^\"]*)?(\")|\\1/${REF}\\3|" "${FLAKE_PATH}"
  AFTER=$(sha256sum "${FLAKE_PATH}")
  if [[ ${BEFORE} != "${AFTER}" ]]; then
    CASCADE_CHANGED=1
  fi
}

apply_sibling_ref() {
  local INPUT_NAME="${1}" FLAKE_REPO="${2}" REF="${3}"
  if [[ -n ${SIBLING_REFS_IN_PIN} ]]; then
    RESOLVED_SIBLING_REFS=$(jq -c --arg NAME "${INPUT_NAME}" --arg REF "${REF}" '. + {($NAME): $REF}' <<<"${RESOLVED_SIBLING_REFS}")
  else
    rewrite_sibling_url "${FLAKE_REPO}" "${REF}"
  fi
}

update_flake_lock() {
  local BEFORE="" AFTER COUNT INDEX INPUT_NAME FLAKE_REPO REF
  local -a OVERRIDE_ARGS=()
  if [[ -f "${FLAKE_ROOT}/flake.lock" ]]; then
    BEFORE=$(sha256sum "${FLAKE_ROOT}/flake.lock")
  fi
  if [[ -n ${SIBLING_REFS_IN_PIN} ]]; then
    COUNT=$(jq 'length' <<<"${SIBLINGS}")
    for ((INDEX = 0; INDEX < COUNT; INDEX++)); do
      INPUT_NAME=$(jq -r ".[${INDEX}].inputName // .[${INDEX}].reqName" <<<"${SIBLINGS}")
      FLAKE_REPO=$(jq -r ".[${INDEX}].flakeRepo" <<<"${SIBLINGS}")
      REF=$(jq -r --arg NAME "${INPUT_NAME}" '.[$NAME]' <<<"${RESOLVED_SIBLING_REFS}")
      OVERRIDE_ARGS+=(--override-input "${INPUT_NAME}" "github:${FLAKE_REPO}/${REF}")
    done
  fi
  nix flake lock "${OVERRIDE_ARGS[@]}" "${FLAKE_ROOT}"
  AFTER=$(sha256sum "${FLAKE_ROOT}/flake.lock")
  if [[ ${BEFORE} != "${AFTER}" ]]; then
    LOCK_CHANGED=1
  fi
}

resolve_siblings_from_source() {
  local REV="${1}" COUNT INDEX REQUIREMENT_NAME INPUT_NAME PYPI_NAME FLAKE_REPO MODE REQUIREMENT_FILE REQUIREMENT_FORMAT REQUIREMENT_GROUPS REF REQUIREMENT_TEXT MARKER_ARGS
  COUNT=$(jq 'length' <<<"${SIBLINGS}")
  for ((INDEX = 0; INDEX < COUNT; INDEX++)); do
    REQUIREMENT_NAME=$(jq -r ".[${INDEX}].reqName" <<<"${SIBLINGS}")
    INPUT_NAME=$(jq -r ".[${INDEX}].inputName // .[${INDEX}].reqName" <<<"${SIBLINGS}")
    PYPI_NAME=$(jq -r ".[${INDEX}].pypiName // \"\"" <<<"${SIBLINGS}")
    FLAKE_REPO=$(jq -r ".[${INDEX}].flakeRepo" <<<"${SIBLINGS}")
    MODE=$(jq -r ".[${INDEX}].mode // \"resolve\"" <<<"${SIBLINGS}")
    REQUIREMENT_FILE=$(jq -r ".[${INDEX}].reqFile // \"requirements.txt\"" <<<"${SIBLINGS}")
    REQUIREMENT_FORMAT=$(jq -r ".[${INDEX}].reqFormat // \"requirements\"" <<<"${SIBLINGS}")
    REQUIREMENT_GROUPS=$(jq -c ".[${INDEX}].reqGroups // []" <<<"${SIBLINGS}")
    REQUIREMENT_TEXT=$(fetch_repo_file "${REQUIREMENT_FILE}" "${REV}" || true)
    if [[ -z ${REQUIREMENT_TEXT} ]]; then
      if [[ -n ${SIBLING_REFS_IN_PIN} ]]; then
        echo "error: ${REQUIREMENT_FILE} is unavailable at ${REV}" >&2
        return 1
      fi
      echo "warning: could not fetch ${REQUIREMENT_FILE} at ${REV}, so the ${FLAKE_REPO} URL is left unchanged." >&2
      continue
    fi
    MARKER_ARGS=()
    [[ -n ${MARKER_ENV} ]] && MARKER_ARGS+=(--marker-env "${MARKER_ENV}")
    REF=$(python3 "${CASCADE_PY}" "${MARKER_ARGS[@]}" "${REQUIREMENT_FORMAT}" "${REQUIREMENT_NAME}" "${PYPI_NAME}" "${MODE}" "${REQUIREMENT_GROUPS}" <<<"${REQUIREMENT_TEXT}" || true)
    if [[ -z ${REF} ]]; then
      if [[ -n ${SIBLING_REFS_IN_PIN} ]]; then
        echo "error: ${REQUIREMENT_FILE} does not resolve ${REQUIREMENT_NAME}" >&2
        return 1
      fi
      echo "warning: could not resolve ${REQUIREMENT_NAME} from ${REQUIREMENT_FILE}, so the ${FLAKE_REPO} URL is left unchanged." >&2
      continue
    fi
    echo "  ${REQUIREMENT_NAME} -> github:${FLAKE_REPO}/${REF}"
    apply_sibling_ref "${INPUT_NAME}" "${FLAKE_REPO}" "${REF}"
  done
}

resolve_siblings_from_metadata() {
  local METADATA="${1}" COUNT INDEX REQUIREMENT_NAME INPUT_NAME PYPI_NAME FLAKE_REPO MODE REF MARKER_ARGS
  COUNT=$(jq 'length' <<<"${SIBLINGS}")
  for ((INDEX = 0; INDEX < COUNT; INDEX++)); do
    REQUIREMENT_NAME=$(jq -r ".[${INDEX}].reqName" <<<"${SIBLINGS}")
    INPUT_NAME=$(jq -r ".[${INDEX}].inputName // .[${INDEX}].reqName" <<<"${SIBLINGS}")
    PYPI_NAME=$(jq -r ".[${INDEX}].pypiName // \"\"" <<<"${SIBLINGS}")
    FLAKE_REPO=$(jq -r ".[${INDEX}].flakeRepo" <<<"${SIBLINGS}")
    MODE=$(jq -r ".[${INDEX}].mode // \"resolve\"" <<<"${SIBLINGS}")
    MARKER_ARGS=()
    [[ -n ${MARKER_ENV} ]] && MARKER_ARGS+=(--marker-env "${MARKER_ENV}")
    REF=$(python3 "${CASCADE_PY}" "${MARKER_ARGS[@]}" metadata "${REQUIREMENT_NAME}" "${PYPI_NAME}" "${MODE}" <<<"${METADATA}" || true)
    if [[ -z ${REF} ]]; then
      if [[ -n ${SIBLING_REFS_IN_PIN} ]]; then
        echo "error: release metadata does not resolve ${REQUIREMENT_NAME}" >&2
        return 1
      fi
      echo "warning: no applicable ${REQUIREMENT_NAME} requirement could be resolved, so the ${FLAKE_REPO} URL is left unchanged." >&2
      continue
    fi
    echo "  ${REQUIREMENT_NAME} -> github:${FLAKE_REPO}/${REF}"
    apply_sibling_ref "${INPUT_NAME}" "${FLAKE_REPO}" "${REF}"
  done
}

write_source_pin() {
  local VERSION="${1}" REV="${2}" HASH="${3}" NAME
  local -A FIELDS=()
  FIELDS[version]="  version = \"${VERSION}\";"
  FIELDS[sourceRev]="  sourceRev = \"${REV}\";"
  FIELDS[sourceHash]="  sourceHash = \"${HASH}\";"
  for NAME in $(jq -r '.[]' <<<"${PIN_HASHES}"); do
    FIELDS["${NAME}"]="  ${NAME} = \"${EXTRA[${NAME}]:-}\";"
  done
  pin_sibling_refs_field FIELDS
  {
    echo '# Auto-managed by `nix run .#update-version`. Manual edits will be overwritten by the next bump.'
    echo "{"
    write_pin_fields FIELDS
    echo "}"
  } >"${PIN_PATH}"
}

write_huggingface_pin() {
  local VERSION="${1}" REV="${2}" FILE FILE_LITERAL HASH_LITERAL NAME
  local -A FIELDS=()
  FIELDS[version]="  version = \"${VERSION}\";"
  FIELDS[sourceRev]="  sourceRev = \"${REV}\";"
  if [[ "$(jq 'length' <<<"${HF_FILES}")" -gt 0 ]]; then
    FIELDS[hashes]="$(
      echo "  hashes = {"
      while IFS= read -r FILE; do
        FILE_LITERAL=$(jq -Rn --arg VALUE "${FILE}" '$VALUE')
        HASH_LITERAL=$(jq -Rn --arg VALUE "${HF_HASHES[${FILE}]}" '$VALUE')
        printf '    %s = %s;\n' "${FILE_LITERAL}" "${HASH_LITERAL}"
      done < <(jq -r '.[]' <<<"${HF_FILES}" | LC_ALL=C sort)
      echo "  };"
    )"
  fi
  for NAME in $(jq -r '.[]' <<<"${PIN_HASHES}"); do
    FIELDS["${NAME}"]="  ${NAME} = \"${EXTRA[${NAME}]:-}\";"
  done
  {
    echo '# Auto-managed by `nix run .#update-version`. Manual edits will be overwritten by the next bump.'
    echo "{"
    write_pin_fields FIELDS
    echo "}"
  } >"${PIN_PATH}"
}

huggingface_pin_current() {
  local VERSION="${1}" REV="${2}" CURRENT_VERSION CURRENT_REV CURRENT_HASHES CURRENT_FILES EXPECTED_FILES FILE HASH NAME CURRENT_EXTRA
  CURRENT_VERSION=$(nix eval --raw --file "${PIN_PATH}" version 2>/dev/null || echo "")
  CURRENT_REV=$(nix eval --raw --file "${PIN_PATH}" sourceRev 2>/dev/null || echo "")
  [[ ${CURRENT_VERSION} == "${VERSION}" && ${CURRENT_REV} == "${REV}" ]] || return 1
  CURRENT_HASHES=$(nix eval --json --file "${PIN_PATH}" hashes 2>/dev/null || echo '{}')
  CURRENT_FILES=$(jq -c 'keys | sort' <<<"${CURRENT_HASHES}")
  EXPECTED_FILES=$(jq -c 'sort' <<<"${HF_FILES}")
  [[ ${CURRENT_FILES} == "${EXPECTED_FILES}" ]] || return 1
  while IFS= read -r FILE; do
    HASH=$(jq -r --arg FILE "${FILE}" '.[$FILE] // ""' <<<"${CURRENT_HASHES}")
    [[ -n ${HASH} ]] || return 1
  done < <(jq -r '.[]' <<<"${HF_FILES}")
  for NAME in $(jq -r '.[]' <<<"${PIN_HASHES}"); do
    CURRENT_EXTRA=$(nix eval --raw --file "${PIN_PATH}" "${NAME}" 2>/dev/null || echo "")
    [[ -n ${CURRENT_EXTRA} && ${CURRENT_EXTRA} == "${EXTRA[${NAME}]:-}" ]] || return 1
  done
  artifact_pin_current || return 1
  return 0
}

write_huggingface_manifest() {
  local METADATA="${1}" OUTPUT TMP
  [[ -z ${HF_MANIFEST_PATH} ]] && return 0
  case "${HF_MANIFEST_PATH}" in
  /* | .. | ../* | */.. | */../*)
    echo "error: huggingface manifest path must stay within FLAKE_ROOT" >&2
    exit 1
    ;;
  esac
  OUTPUT="${FLAKE_ROOT}/${HF_MANIFEST_PATH}"
  mkdir -p "$(dirname "${OUTPUT}")"
  TMP="${OUTPUT}.tmp"
  jq --arg REPO "${HF_REPO}" \
    --argjson INCLUDE "${HF_MANIFEST_INCLUDE}" \
    --argjson EXCLUDE "${HF_MANIFEST_EXCLUDE}" '
      def matches_any($value; $patterns): reduce $patterns[] as $pattern (false; . or ($value | test($pattern)));
      ([
        .siblings[]
        | {
            path: .rfilename,
            bytes: .size,
            sha256: (.lfs.sha256 // null),
            git_blob: .blobId
          }
        | select(($INCLUDE | length) == 0 or matches_any(.path; $INCLUDE))
        | select(($EXCLUDE | length) == 0 or (matches_any(.path; $EXCLUDE) | not))
      ] | sort_by(.path)) as $FILES
      | {
        repo: $REPO,
        revision: .sha,
        total_bytes: ([$FILES[].bytes] | add // 0),
        files: $FILES
      }
      | if any(.files[]; (.path | type) != "string" or (.bytes | type) != "number" or (.git_blob | type) != "string")
        then error("Hugging Face returned incomplete blob metadata")
        else .
        end
    ' <<<"${METADATA}" >"${TMP}"
  mv "${TMP}" "${OUTPUT}"
  EXTRA["${HF_MANIFEST_HASH_FIELD}"]=$(sha256sum "${OUTPUT}" | cut -d' ' -f1)
}

stage_orchestrated_owned_files() {
  local PATTERN
  local -a MATCHED_PATTERNS=() OWNED_PATTERNS=()
  [[ -z ${ORCHESTRATED_OWNED_FILES} ]] && return 0
  read -r -a OWNED_PATTERNS <<<"${ORCHESTRATED_OWNED_FILES}"
  for PATTERN in "${OWNED_PATTERNS[@]}"; do
    if compgen -G "${FLAKE_ROOT}/${PATTERN}" >/dev/null || git -C "${FLAKE_ROOT}" ls-files --error-unmatch -- "${PATTERN}" >/dev/null 2>&1; then
      MATCHED_PATTERNS+=("${PATTERN}")
    fi
  done
  if ((${#MATCHED_PATTERNS[@]} > 0)); then
    git -C "${FLAKE_ROOT}" add -A -- "${MATCHED_PATTERNS[@]}"
  fi
}

run_artifact_hook() {
  # Runs the consumer hook (regenerates vendored files in FLAKE_ROOT) and captures its `name=value` stdout lines into `EXTRA`.
  local REV="${1}" VERSION="${2}" HOOK_OUT K LINE
  [[ -z ${ARTIFACT_HOOK} ]] && return 0
  echo "Running artifact hook..."
  HOOK_OUT=$(NEW_REV="${REV}" NEW_VERSION="${VERSION}" FLAKE_ROOT="${FLAKE_ROOT}" \
    GH_OWNER="${GH_OWNER}" GH_REPO="${GH_REPO}" \
    GITLAB_OWNER="${GITLAB_OWNER}" GITLAB_REPO="${GITLAB_REPO}" "${ARTIFACT_HOOK}")
  while IFS= read -r LINE; do
    # Split on the first '=' only, so a base64 SRI's trailing '=' padding survives.
    K="${LINE%%=*}"
    [[ -n ${K} ]] && EXTRA["${K}"]="${LINE#*=}"
  done <<<"${HOOK_OUT}"
  if [[ -n ${ARTIFACT_FINGERPRINT:-} && ${EXTRA[artifactFingerprint]:-} != "${ARTIFACT_FINGERPRINT}" ]]; then
    echo "error: artifact hook did not emit the declared artifactFingerprint" >&2
    return 1
  fi
  stage_orchestrated_owned_files
  return 0 # the loop's status is its last body command, a falsy `[[ -n ]]` on an empty/keyless line, and that would trip the caller's set -e. This function has no meaningful return.
}

pin_field_holding() {
  local WANT="${1}" NAME PAIR
  while IFS= read -r PAIR; do
    # Split on the first '=' only, so a base64 SRI's trailing '=' padding survives.
    NAME="${PAIR%%=*}"
    if [[ ${PAIR#*=} == "${WANT}" ]]; then
      printf '%s\n' "${NAME}"
      return 0
    fi
  done < <(sed -nE 's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*"([^"]*)";.*/\1=\2/p' "${PIN_PATH}")
  return 1
}

declared_failure_field() {
  local NAME
  for NAME in "${BUILD_FAILURE_FIELDS[@]}"; do
    [[ ${NAME} == "${1}" ]] && return 0
  done
  return 1
}

next_unresolved_failure_field() {
  local NAME
  for NAME in "${BUILD_FAILURE_FIELDS[@]}"; do
    if [[ -z ${BUILD_FAILURE_RESOLVED[${NAME}]:-} ]]; then
      printf '%s\n' "${NAME}"
      return 0
    fi
  done
  return 1
}

resolve_bound_failure_hashes() {
  # Mines a bound field's hash from a build narrowed to the one published package that fetches it, so interleaved output from parallel fetchers cannot pair one fetcher's hash with another field. A binding whose package fetches another bound field's output must be declared after it, since the first failing fetch inside a narrowed build is the one mined.
  local FIELD TARGET OUT RC GOT_HASH
  if [[ -z ${BUILD_FAILURE_TARGETS} || ${BUILD_FAILURE_TARGETS} == '{}' ]]; then
    return 0
  fi
  for FIELD in "${BUILD_FAILURE_FIELDS[@]}"; do
    TARGET=$(jq -r --arg field "${FIELD}" '.[$field] // empty' <<<"${BUILD_FAILURE_TARGETS}")
    if [[ -z ${TARGET} ]]; then
      continue
    fi
    echo "Mining ${FIELD} from a build of ${TARGET}..."
    set +e
    OUT=$("${BUILD_PACKAGES_SCRIPT:?required env var}" --flake "${FLAKE_ROOT}" --only "${TARGET}" 2>&1)
    RC=${?}
    set -e
    if ((RC == 0)); then
      continue
    fi
    GOT_HASH=$(printf '%s\n' "${OUT}" | sed -nE 's/.*got:[[:space:]]+(sha256-[A-Za-z0-9+/=]+).*/\1/p' | head -1)
    if [[ -z ${GOT_HASH} ]]; then
      echo "error: building ${TARGET}, the package bound to pin field ${FIELD}, failed and it wasn't a hash mismatch:" >&2
      printf '%s\n' "${OUT}" >&2
      exit 1
    fi
    echo "  ${FIELD} drift -> ${GOT_HASH}"
    sed -i -E "s|^([[:space:]]*${FIELD}[[:space:]]*=[[:space:]]*\")[^\"]*(\";)|\\1${GOT_HASH}\\2|" "${PIN_PATH}"
  done
}

revalidate_build_hashes() {
  local -A BUILD_FAILURE_RESOLVED=()
  local OUT RC SPECIFIED_HASH GOT_HASH FIELD OWNER
  local -a DISCOVERY_ARGS=(--require-build)
  if [[ -n ${BUILD_TARGET:-} ]]; then
    DISCOVERY_ARGS=(--only "${BUILD_TARGET}")
  fi
  resolve_bound_failure_hashes
  # A mismatch states its own hash, so the field holding it is looked up from there and no producer has to name a target. A producer that does narrows this build to what its hash fetches. A family that builds nothing would report the incomplete pin's hashes as resolved, so a build is required either way.
  while :; do
    echo "Validating ${BUILD_FAILURE_FIELDS[*]} via build..."
    set +e
    OUT=$("${BUILD_PACKAGES_SCRIPT:?required env var}" --flake "${FLAKE_ROOT}" "${DISCOVERY_ARGS[@]}" 2>&1)
    RC=${?}
    set -e
    if ((RC == 0)); then
      # The narrowed build proved one package's fetch, not the tree the run commits.
      if [[ -n ${BUILD_TARGET:-} ]]; then
        "${BUILD_PACKAGES_SCRIPT}" --flake "${FLAKE_ROOT}" --require-build
      fi
      return 0
    fi
    SPECIFIED_HASH=$(printf '%s\n' "${OUT}" | sed -nE 's/.*specified:[[:space:]]+(sha256-[A-Za-z0-9+/=]+).*/\1/p' | head -1)
    GOT_HASH=$(printf '%s\n' "${OUT}" | sed -nE 's/.*got:[[:space:]]+(sha256-[A-Za-z0-9+/=]+).*/\1/p' | head -1)
    if [[ -z ${GOT_HASH} ]]; then
      echo "error: building what this flake publishes failed and it wasn't a hash mismatch:" >&2
      printf '%s\n' "${OUT}" >&2
      exit 1
    fi
    OWNER=$(pin_field_holding "${SPECIFIED_HASH}") || OWNER=""
    if [[ -n ${OWNER} ]] && ! declared_failure_field "${OWNER}"; then
      echo "error: building what this flake publishes names pin field ${OWNER} as the hash mismatch, and ${OWNER} is not a declared build-failure hash field (${BUILD_FAILURE_FIELDS[*]})" >&2
      printf '%s\n' "${OUT}" >&2
      exit 1
    fi
    if [[ -n ${OWNER} && -n ${BUILD_FAILURE_RESOLVED[${OWNER}]:-} ]]; then
      echo "error: building what this flake publishes still names pin field ${OWNER} after ${OWNER} was resolved from its own hash mismatch" >&2
      printf '%s\n' "${OUT}" >&2
      exit 1
    fi
    if [[ -n ${OWNER} ]]; then
      FIELD="${OWNER}"
    else
      FIELD=$(next_unresolved_failure_field) || FIELD=""
    fi
    if [[ -z ${FIELD} ]]; then
      echo "error: building what this flake publishes still reports a hash mismatch with every declared build-failure hash field (${BUILD_FAILURE_FIELDS[*]}) resolved once each" >&2
      printf '%s\n' "${OUT}" >&2
      exit 1
    fi
    echo "  ${FIELD} drift -> ${GOT_HASH}"
    sed -i -E "s|^([[:space:]]*${FIELD}[[:space:]]*=[[:space:]]*\")[^\"]*(\";)|\\1${GOT_HASH}\\2|" "${PIN_PATH}"
    BUILD_FAILURE_RESOLVED["${FIELD}"]=1
  done
}

artifact_pin_current() {
  local CURRENT
  [[ -z ${ARTIFACT_FINGERPRINT:-} ]] && return 0
  CURRENT=$(nix eval --raw --file "${PIN_PATH}" artifactFingerprint 2>/dev/null || echo "")
  [[ -n ${CURRENT} && ${CURRENT} == "${ARTIFACT_FINGERPRINT}" ]]
}

source_pin_current() {
  # True (0) when pin.nix already matches at this version+rev with sourceHash and every EXTRA_HASHES field populated. Lets a no-op run skip the artifactHook + cascade regeneration (which can be non-deterministic, e.g. npm lockfiles) instead of churning the pin on every run. A placeholder pin (empty hash) returns false, so the populate path still runs. Callers skip this in build-failure mode, where the hash can drift without a rev change.
  local VERSION="${1}" REV="${2}" CUR_VERSION CUR_REV CUR_HASH NAME VALUE
  CUR_VERSION=$(nix eval --raw --file "${PIN_PATH}" version 2>/dev/null || echo "")
  CUR_REV=$(nix eval --raw --file "${PIN_PATH}" sourceRev 2>/dev/null || echo "")
  CUR_HASH=$(nix eval --raw --file "${PIN_PATH}" sourceHash 2>/dev/null || echo "")
  [[ ${CUR_VERSION} == "${VERSION}" && ${CUR_REV} == "${REV}" && -n ${CUR_HASH} ]] || return 1
  for NAME in $(jq -r '.[]' <<<"${PIN_HASHES}"); do
    VALUE=$(nix eval --raw --file "${PIN_PATH}" "${NAME}" 2>/dev/null || echo "")
    [[ -n ${VALUE} ]] || return 1
  done
  artifact_pin_current || return 1
  sibling_refs_current
}

case "${SOURCE_TYPE}" in
oci)
  if [[ -z ${OCI_SETTINGS:-} || -z ${OCI_SKOPEO:-} ]]; then
    echo "error: oci requires image settings and skopeo" >&2
    exit 1
  fi
  OCI_NAME=$(jq -er '.imageName' <<<"${OCI_SETTINGS}")
  OCI_OS=$(jq -er '.os' <<<"${OCI_SETTINGS}")
  OCI_ARCH=$(jq -er '.arch' <<<"${OCI_SETTINGS}")
  OCI_VARIANT=$(jq -r '.variant' <<<"${OCI_SETTINGS}")
  OCI_VERSION=""
  case "${VERSION_SOURCE_TYPE}" in
  "")
    if [[ -n ${REQUESTED_REF} ]]; then
      echo "error: oci accepts one tag or digest" >&2
      exit 1
    fi
    OCI_REF="${REQUESTED:-$(jq -er '.tag' <<<"${OCI_SETTINGS}")}"
    ;;
  github)
    OCI_REF="${REQUESTED_REF:-${REQUESTED}}"
    if [[ -z ${OCI_REF} ]]; then
      if [[ -z ${GH_OWNER} || -z ${GH_REPO} ]]; then
        echo "error: oci version discovery needs a GitHub release source" >&2
        exit 1
      fi
      echo "Querying GitHub for latest release of ${GH_OWNER}/${GH_REPO}..."
      # The image is published under its version, not under the spelling of the GitHub release tag, so a discovered tag is normalized the same way the orchestrator's upstream-version argument already is.
      OCI_REF=$(retry gh api "/repos/${GH_OWNER}/${GH_REPO}/releases/latest" --jq '.tag_name')
      OCI_REF=$(github_version_from_tag "${OCI_REF}" || printf '%s\n' "${OCI_REF}")
    fi
    OCI_VERSION="${REQUESTED:-$(github_version_from_tag "${OCI_REF}" || printf '%s\n' "${OCI_REF}")}"
    if [[ ! ${OCI_VERSION} =~ ^[0-9] ]]; then
      echo "error: oci reference ${OCI_REF} does not yield a version for ${GH_OWNER}/${GH_REPO}" >&2
      exit 1
    fi
    ;;
  registry)
    # A registry publishes a version under whatever tag it likes, so the tag is never inferred from the version except by the one prefix the flake declares.
    if [[ -n ${REQUESTED_REF} ]]; then
      OCI_REF="${REQUESTED_REF}"
      OCI_VERSION="${REQUESTED}"
    elif [[ -n ${REQUESTED} ]]; then
      OCI_REF="${VERSION_TAG_PREFIX}${REQUESTED}"
      OCI_VERSION="${REQUESTED}"
    else
      # The registry's own tag list is the only authority on what it published, and the newest stable version in it is the answer, the same as a release source's latest release. A tag that names no version is not trackable.
      echo "Listing the tags the registry publishes for ${OCI_NAME}..."
      if ! OCI_TAGS=$(retry registry_tag_names "${OCI_NAME}"); then
        exit 1
      fi
      declare -A OCI_TAG_OF=()
      while IFS= read -r OCI_TAG; do
        OCI_TAG_VERSION=$(github_version_from_tag "${OCI_TAG}" || true)
        [[ ${OCI_TAG_VERSION} =~ ^[0-9] ]] || continue
        OCI_TAG_OF["${OCI_TAG_VERSION}"]="${OCI_TAG}"
      done <<<"${OCI_TAGS}"
      if ((${#OCI_TAG_OF[@]} == 0)); then
        echo "error: ${OCI_NAME} publishes no tag that names a version" >&2
        exit 1
      fi
      OCI_VERSION=$(printf '%s\n' "${!OCI_TAG_OF[@]}" |
        python3 "${CASCADE_PY}" sort 0 stable | tail -1)
      if [[ -z ${OCI_VERSION} ]]; then
        echo "error: ${OCI_NAME} publishes no stable version tag" >&2
        exit 1
      fi
      OCI_REF="${OCI_TAG_OF[${OCI_VERSION}]}"
    fi
    if [[ ! ${OCI_VERSION} =~ ^[0-9] ]]; then
      echo "error: oci reference ${OCI_REF} does not yield a version for ${OCI_NAME}" >&2
      exit 1
    fi
    ;;
  *)
    echo "error: oci cannot discover versions from VERSION_SOURCE_TYPE=${VERSION_SOURCE_TYPE}" >&2
    exit 1
    ;;
  esac
  if [[ ${OCI_REF} =~ ^sha256:[0-9a-f]{64}$ ]]; then
    OCI_URL="docker://${OCI_NAME}@${OCI_REF}"
  elif [[ ${OCI_REF} =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]]; then
    OCI_URL="docker://${OCI_NAME}:${OCI_REF}"
  else
    echo "error: oci reference is not a tag or sha256 digest" >&2
    exit 1
  fi
  OCI_MANIFEST=$("${OCI_SKOPEO}" inspect --raw "${OCI_URL}")
  if jq -e 'has("manifests")' <<<"${OCI_MANIFEST}" >/dev/null; then
    OCI_DIGEST=$(jq -er --arg OS "${OCI_OS}" --arg ARCH "${OCI_ARCH}" --arg VARIANT "${OCI_VARIANT}" '
        [.manifests[] | select(.platform.os == $OS and .platform.architecture == $ARCH and ($VARIANT == "" or .platform.variant == $VARIANT)) | .digest]
        | if length == 1 then .[0] else error("image index does not identify a unique platform manifest") end
      ' <<<"${OCI_MANIFEST}")
  else
    OCI_DIGEST=$("${OCI_SKOPEO}" inspect --no-tags "${OCI_URL}" | jq -er '.Digest')
    if [[ ${OCI_REF} == sha256:* && ${OCI_REF} != "${OCI_DIGEST}" ]]; then
      echo "error: oci inspection returned a different digest" >&2
      exit 1
    fi
  fi
  if [[ ! ${OCI_DIGEST} =~ ^sha256:[0-9a-f]{64}$ ]]; then
    echo "error: oci manifest digest is not a sha256 digest" >&2
    exit 1
  fi
  OCI_METADATA=$("${OCI_SKOPEO}" inspect --no-tags "docker://${OCI_NAME}@${OCI_DIGEST}")
  if [[ "$(jq -er '.Digest' <<<"${OCI_METADATA}")" != "${OCI_DIGEST}" ]]; then
    echo "error: oci inspection returned a different digest" >&2
    exit 1
  fi
  if ! jq -e --arg OS "${OCI_OS}" --arg ARCH "${OCI_ARCH}" '.Os == $OS and .Architecture == $ARCH' <<<"${OCI_METADATA}" >/dev/null; then
    echo "error: oci inspection returned a different platform" >&2
    exit 1
  fi
  if [[ -n ${OCI_VARIANT} ]] && ! "${OCI_SKOPEO}" inspect --config "docker://${OCI_NAME}@${OCI_DIGEST}" | jq -e --arg VARIANT "${OCI_VARIANT}" '.variant == $VARIANT' >/dev/null; then
    echo "error: oci inspection returned a different platform variant" >&2
    exit 1
  fi
  OCI_CURRENT_DIGEST=$(nix eval --raw --file "${PIN_PATH}" imageDigest 2>/dev/null || echo "")
  OCI_CURRENT_HASH=$(nix eval --raw --file "${PIN_PATH}" imageHash 2>/dev/null || echo "")
  OCI_PIN_VERSION=$(nix eval --raw --file "${PIN_PATH}" version 2>/dev/null || echo "")
  OCI_LEGACY_FINGERPRINT=$(nix eval --raw --file "${PIN_PATH}" archiveFingerprint 2>/dev/null || echo "")
  OCI_CONTENT_MATCHES=0
  if [[ ${OCI_CURRENT_DIGEST} == "${OCI_DIGEST}" && ${OCI_CURRENT_HASH} =~ ^sha256-[A-Za-z0-9+/]{43}=$ && -z ${OCI_LEGACY_FINGERPRINT} ]]; then
    OCI_CONTENT_MATCHES=1
  fi
  # The image is unchanged only when the pin already claims the version being resolved. A version branch created from a base that carries this release's image must record its own version, reusing the pinned content.
  if ((OCI_CONTENT_MATCHES)) && [[ -z ${OCI_VERSION} || ${OCI_PIN_VERSION} == "${OCI_VERSION}" ]]; then
    finish_unchanged "${OCI_VERSION:-${OCI_DIGEST}}"
  fi
  OCI_WORK=$(mktemp -d)
  cp "${PIN_PATH}" "${OCI_WORK}/pin.nix"
  OCI_HAD_LOCK=0
  if [[ -f "${FLAKE_ROOT}/flake.lock" ]]; then
    cp "${FLAKE_ROOT}/flake.lock" "${OCI_WORK}/flake.lock"
    OCI_HAD_LOCK=1
  fi
  trap '
      OCI_STATUS="${?}"
      if (( OCI_STATUS != 0 )); then
        cp "${OCI_WORK}/pin.nix" "${PIN_PATH}" || echo "error: oci pin restoration failed" >&2
        if (( OCI_HAD_LOCK )); then
          cp "${OCI_WORK}/flake.lock" "${FLAKE_ROOT}/flake.lock" || echo "error: oci lock restoration failed" >&2
        else
          rm -f "${FLAKE_ROOT}/flake.lock"
        fi
      fi
      rm -rf "${OCI_WORK}"
      exit "${OCI_STATUS}"
    ' EXIT
  if ((OCI_CONTENT_MATCHES)); then
    OCI_HASH="${OCI_CURRENT_HASH}"
  else
    OCI_DIR="${OCI_WORK}/oci-image-${OCI_DIGEST#sha256:}"
    "${OCI_SKOPEO}" --insecure-policy --tmpdir "${OCI_WORK}" copy --preserve-digests --src-tls-verify=true "docker://${OCI_NAME}@${OCI_DIGEST}" "dir://${OCI_DIR}" | cat
    OCI_HASH=$(nix hash path "${OCI_DIR}")
    if [[ ! ${OCI_HASH} =~ ^sha256-[A-Za-z0-9+/]{43}=$ ]]; then
      echo "error: oci image directory hash is not a sha256 SRI" >&2
      exit 1
    fi
    nix-store --add-fixed --recursive sha256 "${OCI_DIR}" >/dev/null
  fi
  {
    echo "{"
    if [[ -n ${OCI_VERSION} ]]; then
      echo "  version = \"${OCI_VERSION}\";"
    fi
    echo "  imageDigest = \"${OCI_DIGEST}\";"
    echo "  imageHash = \"${OCI_HASH}\";"
    echo "}"
  } >"${PIN_PATH}"
  NEW_VERSION="${OCI_VERSION:-${OCI_DIGEST}}"
  PIN_CHANGED=1
  ;;

mutable-url)
  if [[ -n ${REQUESTED} || -n ${REQUESTED_REF} ]]; then
    echo "error: mutable-url does not support requested versions or refs" >&2
    exit 1
  fi
  if [[ -z ${MUTABLE_URL} ]]; then
    echo "error: mutable-url requires source.url" >&2
    exit 1
  fi
  HEADER_OUTPUT=$(retry curl -sSfIL "${MUTABLE_URL}")
  LAST_MODIFIED=""
  while IFS= read -r HEADER; do
    HEADER="${HEADER%$'\r'}"
    if [[ ${HEADER,,} == last-modified:* ]]; then
      LAST_MODIFIED="${HEADER#*:}"
      LAST_MODIFIED="${LAST_MODIFIED#"${LAST_MODIFIED%%[![:space:]]*}"}"
    fi
  done <<<"${HEADER_OUTPUT}"
  if [[ -z ${LAST_MODIFIED} ]]; then
    echo "error: mutable-url response has no Last-Modified header" >&2
    exit 1
  fi
  CURRENT_LAST_MODIFIED=$(nix eval --raw --file "${PIN_PATH}" lastModified 2>/dev/null || echo "")
  CURRENT_HASH=$(nix eval --raw --file "${PIN_PATH}" hash 2>/dev/null || echo "")
  if [[ ${CURRENT_LAST_MODIFIED} == "${LAST_MODIFIED}" && -n ${CURRENT_HASH} ]]; then
    finish_unchanged "main"
  fi
  echo "Prefetching ${MUTABLE_URL}..."
  NEW_HASH=$(nix store prefetch-file --json --hash-type sha256 "${MUTABLE_URL}" | jq -r '.hash')
  NEW_VERSION="main"
  printf '%s\n' \
    '{' \
    "  lastModified = \"${LAST_MODIFIED}\";" \
    "  hash = \"${NEW_HASH}\";" \
    '}' >"${PIN_PATH}"
  PIN_CHANGED=1
  ;;

pypi)
  if [[ -n ${REQUESTED} ]]; then
    NEW_VERSION="${REQUESTED}"
  else
    NEW_VERSION=$(retry curl -sSfL "https://pypi.org/pypi/${PYPI_NAME}/json" | jq -r '.info.version')
  fi
  CUR_VERSION=$(nix eval --raw --file "${PIN_PATH}" version 2>/dev/null || echo "")
  echo "Resolving ${PYPI_NAME} ${NEW_VERSION} on PyPI..."
  RELEASE_JSON=$(retry curl -sSfL "https://pypi.org/pypi/${PYPI_NAME}/${NEW_VERSION}/json")
  if [[ ${PYPI_FORMAT} == "wheel" ]]; then
    # Prefer the universal py3-none-any wheel (what mk-pypi-package fetches). Fall back to the first wheel.
    URL=$(jq -r '([.urls[] | select(.packagetype == "bdist_wheel") | select(.filename | endswith("-py3-none-any.whl"))][0].url) // ([.urls[] | select(.packagetype == "bdist_wheel")][0].url)' <<<"${RELEASE_JSON}")
  else
    URL=$(jq -r '[.urls[] | select(.packagetype == "sdist")][0].url' <<<"${RELEASE_JSON}")
  fi
  if [[ -z ${URL} || ${URL} == "null" ]]; then
    echo "error: no ${PYPI_FORMAT} artifact for ${PYPI_NAME} ${NEW_VERSION}" >&2
    exit 1
  fi
  NEW_HASH=$(nix store prefetch-file --json --hash-type sha256 "${URL}" | jq -r '.hash')
  if [[ "$(jq 'length' <<<"${SIBLINGS}")" -gt 0 ]]; then
    echo "Resolving sibling cascades..."
    resolve_siblings_from_metadata "${RELEASE_JSON}"
  fi
  if pypi_pin_current "${NEW_VERSION}" "${NEW_HASH}"; then
    if [[ -z ${SIBLING_REFS_IN_PIN} ]] && ((CASCADE_CHANGED == 0)); then
      finish_unchanged "${CUR_VERSION}"
    fi
    echo "Source pin already up to date (${CUR_VERSION})."
  else
    run_artifact_hook "" "${NEW_VERSION}"
    echo "Writing pin.nix (${CUR_VERSION:-<none>} -> ${NEW_VERSION})..."
    write_pypi_pin "${NEW_VERSION}" "${NEW_HASH}"
    PIN_CHANGED=1
    if ((${#BUILD_FAILURE_FIELDS[@]} > 0)); then
      revalidate_build_hashes
    fi
  fi
  ;;

github)
  if [[ ${GH_TRACK} == "commit" ]]; then
    if [[ -n ${REQUESTED} ]]; then
      COMMIT=$(retry gh api "/repos/${GH_OWNER}/${GH_REPO}/commits/${REQUESTED}")
    else
      BRANCH="${GH_BRANCH:-$(retry gh api "/repos/${GH_OWNER}/${GH_REPO}" --jq '.default_branch')}"
      echo "Querying GitHub for latest commit on ${GH_OWNER}/${GH_REPO}@${BRANCH}..."
      COMMIT=$(retry gh api "/repos/${GH_OWNER}/${GH_REPO}/commits/${BRANCH}")
    fi
    NEW_REV=$(jq -r '.sha' <<<"${COMMIT}")
    NEW_VERSION=$(commit_version "$(jq -r '.commit.committer.date' <<<"${COMMIT}")" "${NEW_REV}")
  else
    if [[ -n ${REQUESTED} ]]; then
      if [[ ${REQUESTED} =~ ^[0-9] ]]; then
        NEW_VERSION="${REQUESTED}"
      else
        NEW_VERSION=$(github_version_from_tag "${REQUESTED}" || true)
      fi
    elif [[ ${GH_TRACK} == "tag" ]]; then
      echo "Querying GitHub for latest tag of ${GH_OWNER}/${GH_REPO}..."
      NEW_VERSION=""
      TAG_NAMES=$(retry gh api "/repos/${GH_OWNER}/${GH_REPO}/tags" --jq '.[].name')
      while IFS= read -r TAG; do
        if NEW_VERSION=$(github_version_from_tag "${TAG}"); then
          break
        fi
      done <<<"${TAG_NAMES}"
      if [[ -z ${NEW_VERSION} ]]; then
        echo "error: could not determine a version tag for ${GH_OWNER}/${GH_REPO}" >&2
        exit 1
      fi
    else
      echo "Querying GitHub for latest release of ${GH_OWNER}/${GH_REPO}..."
      RELEASE_TAG=$(retry gh api "/repos/${GH_OWNER}/${GH_REPO}/releases/latest" --jq '.tag_name')
      NEW_VERSION=$(github_version_from_tag "${RELEASE_TAG}" || true)
    fi
    if [[ -z ${NEW_VERSION} ]]; then
      echo "error: ${REQUESTED:-${RELEASE_TAG:-release tags}} does not match a supported version prefix for ${GH_OWNER}/${GH_REPO}" >&2
      exit 1
    fi
    REF_BASE="${REQUESTED_REF:-${NEW_VERSION}}"
    REF_BASE=$(github_version_from_tag "${REF_BASE}" || printf '%s\n' "${REF_BASE}")
    NEW_REV=$(retry resolve_github_ref_sha "${REF_BASE}" || true)
    if [[ -z ${NEW_REV} ]]; then
      echo "error: could not resolve ${REF_BASE} with tag prefixes ${GH_TAG_PREFIXES} on ${GH_OWNER}/${GH_REPO}" >&2
      exit 1
    fi
  fi
  if [[ "$(jq 'length' <<<"${SIBLINGS}")" -gt 0 ]]; then
    echo "Resolving sibling cascades..."
    resolve_siblings_from_source "${NEW_REV}"
  fi
  if [[ ${HASH_MODE} != "build-failure" ]] && source_pin_current "${NEW_VERSION}" "${NEW_REV}"; then
    if [[ -z ${SIBLING_REFS_IN_PIN} ]] && ((CASCADE_CHANGED == 0)); then
      finish_unchanged "${NEW_VERSION}"
    fi
    echo "Source pin already up to date (${NEW_VERSION})."
  else
    run_artifact_hook "${NEW_REV}" "${NEW_VERSION}"
    if [[ ${HASH_MODE} == "build-failure" ]]; then
      NEW_HASH=""
    else
      echo "Computing source hash for ${GH_OWNER}/${GH_REPO}@${NEW_REV}..."
      NEW_HASH=$(nix-prefetch-github ${GH_FETCH_SUBMODULES:+--fetch-submodules} --rev "${NEW_REV}" "${GH_OWNER}" "${GH_REPO}" --json | jq -r '.hash // .sha256')
    fi
    echo "Writing pin.nix (-> ${NEW_VERSION})..."
    write_source_pin "${NEW_VERSION}" "${NEW_REV}" "${NEW_HASH}"
    PIN_CHANGED=1
    if ((${#BUILD_FAILURE_FIELDS[@]} > 0)); then
      revalidate_build_hashes
    fi
  fi
  ;;

github-release-asset)
  # A prebuilt release asset (single file), not the source tree: resolve the version like `github` (latest release tag, or the requested version), then prefetch-file the asset URL into a { version, hash } pin. There is no tree to hash, so no sourceRev. Release assets are immutable, so a matching populated pin short-circuits before the (potentially large) download.
  if [[ -z ${GH_ASSET} ]]; then
    echo "error: github-release-asset requires source.asset (GH_ASSET)" >&2
    exit 1
  fi
  if [[ -n ${REQUESTED} ]]; then
    NEW_VERSION=$(github_version_from_tag "${REQUESTED}" || printf '%s\n' "${REQUESTED}")
  else
    echo "Querying GitHub for latest release of ${GH_OWNER}/${GH_REPO}..."
    NEW_VERSION=$(retry gh api "/repos/${GH_OWNER}/${GH_REPO}/releases/latest" --jq '.tag_name')
    NEW_VERSION=$(github_version_from_tag "${NEW_VERSION}" || printf '%s\n' "${NEW_VERSION}")
  fi
  CUR_VERSION=$(nix eval --raw --file "${PIN_PATH}" version 2>/dev/null || echo "")
  CUR_HASH=$(nix eval --raw --file "${PIN_PATH}" hash 2>/dev/null || echo "")
  if [[ ${CUR_VERSION} == "${NEW_VERSION}" && -n ${CUR_HASH} ]]; then
    finish_unchanged "${NEW_VERSION}"
  fi
  TAG_TMPL="${GH_TAG}"
  # A release tag is the version under the prefix the source declares, and under `v` when it declares none, which is how the first entry of the default prefix list spells it.
  [[ -n ${TAG_TMPL} ]] || TAG_TMPL="${GITHUB_TAG_PREFIXES[0]}\${version}"
  TAG="${TAG_TMPL//'${version}'/${NEW_VERSION}}"
  ASSET="${GH_ASSET//'${version}'/${NEW_VERSION}}"
  ASSET="${ASSET//'${tag}'/${TAG}}"
  URL="https://github.com/${GH_OWNER}/${GH_REPO}/releases/download/${TAG}/${ASSET}"
  echo "Prefetching ${URL}..."
  NEW_HASH=$(nix store prefetch-file --json --hash-type sha256 "${URL}" | jq -r '.hash')
  echo "Writing pin.nix (${CUR_VERSION:-<none>} -> ${NEW_VERSION})..."
  cat >"${PIN_PATH}" <<EOF
# Auto-managed by \`nix run .#update-version\`. Manual edits will be overwritten by the next bump.
{
  version = "${NEW_VERSION}";
  hash = "${NEW_HASH}";
}
EOF
  PIN_CHANGED=1
  ;;

huggingface)
  if [[ -z ${HF_REPO} ]]; then
    echo "error: huggingface requires source.repo (HF_REPO)" >&2
    exit 1
  fi
  HF_REF="${REQUESTED:-${HF_REVISION}}"
  echo "Querying Hugging Face for ${HF_REPO}@${HF_REF}..."
  HF_METADATA=$(retry curl -sSfL "https://huggingface.co/api/models/${HF_REPO}/revision/${HF_REF}${HF_MANIFEST_PATH:+?blobs=true}")
  HF_REV=$(jq -r '.sha // ""' <<<"${HF_METADATA}")
  HF_DATE=$(jq -r '.lastModified // ""' <<<"${HF_METADATA}" | cut -d'T' -f1)
  if [[ -z ${HF_REV} || -z ${HF_DATE} || ${HF_REV} == "null" || ${HF_DATE} == "null" ]]; then
    echo "error: could not resolve ${HF_REPO}@${HF_REF}" >&2
    exit 1
  fi
  NEW_VERSION=$(commit_version "${HF_DATE}" "${HF_REV}")
  write_huggingface_manifest "${HF_METADATA}"
  run_artifact_hook "${HF_REV}" "${NEW_VERSION}"
  if huggingface_pin_current "${NEW_VERSION}" "${HF_REV}"; then
    finish_unchanged "${NEW_VERSION}"
  fi
  while IFS= read -r HF_FILE; do
    HF_FILE_URL=$(jq -rn --arg VALUE "${HF_FILE}" '$VALUE | split("/") | map(@uri) | join("/")')
    echo "Prefetching ${HF_FILE}..."
    HF_HASHES["${HF_FILE}"]=$(nix store prefetch-file --json --hash-type sha256 "https://huggingface.co/${HF_REPO}/resolve/${HF_REV}/${HF_FILE_URL}" | jq -r '.hash')
  done < <(jq -r '.[]' <<<"${HF_FILES}")
  echo "Writing pin.nix (-> ${NEW_VERSION})..."
  write_huggingface_pin "${NEW_VERSION}" "${HF_REV}"
  PIN_CHANGED=1
  ;;

gitlab)
  PROJ="${GITLAB_OWNER}%2F${GITLAB_REPO}"
  if [[ ${GITLAB_TRACK} == "release" ]]; then
    if [[ -n ${REQUESTED} ]]; then
      NEW_VERSION=$(github_version_from_tag "${REQUESTED}" || printf '%s\n' "${REQUESTED}")
    else
      echo "Querying GitLab for latest tag of ${GITLAB_OWNER}/${GITLAB_REPO}..."
      # The project's own tag list answers with its newest tag first, and a tag names a version only under the prefixes the source declares.
      NEW_VERSION=""
      while IFS= read -r TAG; do
        if STRIPPED=$(github_version_from_tag "${TAG}"); then
          NEW_VERSION="${STRIPPED}"
          break
        fi
      done < <(retry curl -sSfL "https://${GITLAB_DOMAIN}/api/v4/projects/${PROJ}/repository/tags" |
        jq -r '.[].name')
    fi
    if [[ -z ${NEW_VERSION} ]]; then
      echo "error: could not determine a release tag for ${GITLAB_OWNER}/${GITLAB_REPO}" >&2
      exit 1
    fi
    REF_BASE="${REQUESTED_REF:-${NEW_VERSION}}"
    REF_BASE=$(github_version_from_tag "${REF_BASE}" || printf '%s\n' "${REF_BASE}")
    NEW_REV=$(retry resolve_gitlab_ref_sha "${PROJ}" "${REF_BASE}" || true)
    if [[ -z ${NEW_REV} ]]; then
      echo "error: could not resolve a ref for version ${REF_BASE} on ${GITLAB_OWNER}/${GITLAB_REPO}" >&2
      exit 1
    fi
  else
    if [[ -n ${REQUESTED} ]]; then
      COMMIT=$(retry curl -sSfL "https://${GITLAB_DOMAIN}/api/v4/projects/${PROJ}/repository/commits/${REQUESTED}")
    else
      echo "Querying GitLab for latest master commit of ${GITLAB_OWNER}/${GITLAB_REPO}..."
      COMMIT=$(retry curl -sSfL "https://${GITLAB_DOMAIN}/api/v4/projects/${PROJ}/repository/branches/master" | jq -r '.commit')
    fi
    NEW_REV=$(jq -r '.id' <<<"${COMMIT}")
    NEW_DATE=$(jq -r '.committed_date' <<<"${COMMIT}" | cut -d'T' -f1)
    NEW_VERSION=$(commit_version "${NEW_DATE}" "${NEW_REV}")
  fi
  if [[ "$(jq 'length' <<<"${SIBLINGS}")" -gt 0 ]]; then
    echo "Resolving sibling cascades..."
    resolve_siblings_from_source "${NEW_REV}"
  fi
  if [[ ${HASH_MODE} != "build-failure" ]] && source_pin_current "${NEW_VERSION}" "${NEW_REV}"; then
    if [[ -z ${SIBLING_REFS_IN_PIN} ]] && ((CASCADE_CHANGED == 0)); then
      finish_unchanged "${NEW_VERSION}"
    fi
    echo "Source pin already up to date (${NEW_VERSION})."
  else
    run_artifact_hook "${NEW_REV}" "${NEW_VERSION}"
    if [[ ${HASH_MODE} == "build-failure" ]]; then
      NEW_HASH=""
    else
      echo "Computing source hash for ${GITLAB_OWNER}/${GITLAB_REPO}@${NEW_REV}..."
      NEW_HASH=$(nix-prefetch-git --quiet --url "https://${GITLAB_DOMAIN}/${GITLAB_OWNER}/${GITLAB_REPO}.git" --rev "${NEW_REV}" | jq -r '.hash')
    fi
    echo "Writing pin.nix (-> ${NEW_VERSION})..."
    write_source_pin "${NEW_VERSION}" "${NEW_REV}" "${NEW_HASH}"
    PIN_CHANGED=1
    if ((${#BUILD_FAILURE_FIELDS[@]} > 0)); then
      revalidate_build_hashes
    fi
  fi
  ;;

*)
  echo "error: unknown SOURCE_TYPE=${SOURCE_TYPE}" >&2
  exit 1
  ;;
esac

if ((PIN_CHANGED)); then
  format_pin "${PIN_PATH}"
fi

if ((PIN_CHANGED || CASCADE_CHANGED)) || [[ -n ${SIBLING_REFS_IN_PIN} ]]; then
  echo "Updating flake.lock..."
  update_flake_lock
fi

if ((PIN_CHANGED == 0 && CASCADE_CHANGED == 0 && LOCK_CHANGED == 0)); then
  finish_unchanged "${NEW_VERSION}"
fi

evaluate_published_packages

echo
if ((PIN_CHANGED)); then
  echo "Updated the pin to ${NEW_VERSION}."
else
  echo "Pin unchanged (${NEW_VERSION})."
fi
