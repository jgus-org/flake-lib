#!/usr/bin/env -S nix shell nixpkgs#bash nixpkgs#nix nixpkgs#gnused nixpkgs#coreutils --command bash

# Revalidate a fixed-output (vendor) hash that cannot be prefetched, such as Go modules, cargo deps, npm FODs and xcaddy plugin trees, by building and recovering the correct hash from nix's mismatch error.
#
#   HASH_FIELD   pin.nix field to rewrite (default "hash")
#   BUILD_TARGET published package the hash is mined from (default: the whole published family)
#
# The mismatch is attributed to this field by the hash it states as the one in use, so a drift in some other package is not written into this field. Only the recovery build narrows: the rewritten tree is still verified over the whole family. Run from the flake root (or set FLAKE_ROOT). Used directly by manifest-style flakes (e.g. caddy).

set -euo pipefail

FLAKE_ROOT="${FLAKE_ROOT:-${PWD}}"
HASH_FIELD="${HASH_FIELD:-hash}"
BUILD_TARGET="${BUILD_TARGET:-}"
BUILD_PACKAGES_SCRIPT="${BUILD_PACKAGES_SCRIPT:?required env var}"
PIN="${FLAKE_ROOT}/pin.nix"

if [[ ! -f ${PIN} ]]; then
  echo "error: no pin.nix in ${FLAKE_ROOT}" >&2
  exit 1
fi

# The hash a mismatch was built against is stated above the one it produced, so the pair is read as fields rather than cut at a fixed distance, and the first pair naming this field's hash is it.
mine_drift() {
  local LINE LABEL VALUE SPECIFIED=''
  while IFS= read -r LINE; do
    read -r LABEL VALUE <<<"${LINE}" || true
    case ${LABEL} in
    specified:) SPECIFIED=${VALUE} ;;
    got:)
      if [[ -z ${SPECIFIED} || ${SPECIFIED} == "${1}" ]]; then
        printf '%s\n' "${VALUE}"
        return 0
      fi
      ;;
    esac
  done < <(printf '%s\n' "${OUT}")
  return 1
}

MINING_BUILD='the packages this flake publishes'
MINING_ARGS=(--require-build)
if [[ -n ${BUILD_TARGET} ]]; then
  MINING_BUILD="the published package ${BUILD_TARGET}"
  MINING_ARGS=(--only "${BUILD_TARGET}")
fi
echo "Building ${MINING_BUILD} to validate ${HASH_FIELD}..."
set +e
OUT=$("${BUILD_PACKAGES_SCRIPT}" --flake "${FLAKE_ROOT}" "${MINING_ARGS[@]}" 2>&1)
RC=${?}
set -e

if ((RC == 0)); then
  echo "  ${HASH_FIELD} already correct."
  exit 0
fi

# A placeholder pin names no hash a build could have been mismatched against, so the first mismatch in the log is the one to recover from. A field that names one is only wrong about that one.
CURRENT_HASH=$(sed -nE "s/^[[:space:]]*${HASH_FIELD}[[:space:]]*=[[:space:]]*\"([^\"]*)\";.*/\1/p" "${PIN}" |
  head -1)
NEW_HASH=$(mine_drift "${CURRENT_HASH}") || NEW_HASH=''
if [[ -z ${NEW_HASH} ]]; then
  echo "error: building ${MINING_BUILD} failed and it wasn't a hash mismatch over ${HASH_FIELD}:" >&2
  printf '%s\n' "${OUT}" >&2
  exit 1
fi

echo "  ${HASH_FIELD} drift -> ${NEW_HASH}"
# Anchor the field at start-of-line so HASH_FIELD=hash doesn't also match `sourceHash = ...`.
sed -i -E "s|^([[:space:]]*${HASH_FIELD}[[:space:]]*=[[:space:]]*\")[^\"]*(\";)|\\1${NEW_HASH}\\2|" "${PIN}"

echo "Verifying build..."
"${BUILD_PACKAGES_SCRIPT}" --flake "${FLAKE_ROOT}" --require-build
echo "  ${HASH_FIELD} validated."
