#!/usr/bin/env -S nix shell nixpkgs#bash nixpkgs#jq nixpkgs#nix nixpkgs#gnused nixpkgs#coreutils --command bash

# Revalidate a fixed-output (vendor) hash that can't be prefetched — Go modules, cargo deps, npm FODs, xcaddy plugin trees — by building and recovering the correct hash from nix's mismatch error.
#
#   HASH_FIELD   pin.nix field to rewrite (default "hash")
#   BUILD_TARGET published package the hash is mined from (default: the whole published family)
#
# The mismatch is attributed to this field by the hash it states as the one in use, so a drift in
# some other package is not written into this field. Only the recovery build narrows: the rewritten
# tree is still verified over the whole family. Run from the flake root (or set FLAKE_ROOT). Used
# directly by manifest-style flakes (e.g. caddy).

set -euo pipefail

FLAKE_ROOT="${FLAKE_ROOT:-${PWD}}"
HASH_FIELD="${HASH_FIELD:-hash}"
BUILD_TARGET="${BUILD_TARGET:-}"
BUILD_PACKAGES_SCRIPT="${BUILD_PACKAGES_SCRIPT:?required env var}"
pin="${FLAKE_ROOT}/pin.nix"

if [[ ! -f ${pin} ]]; then
  echo "error: no pin.nix in ${FLAKE_ROOT}" >&2
  exit 1
fi

# The hash a mismatch was built against is stated above the one it produced, so the pair is read as
# fields rather than cut at a fixed distance, and the first pair naming this field's hash is it.
mine_drift() {
  local line label value specified=''
  while IFS= read -r line; do
    read -r label value <<<"${line}" || true
    case ${label} in
    specified:) specified=${value} ;;
    got:)
      if [[ -z ${specified} || ${specified} == "${1}" ]]; then
        printf '%s\n' "${value}"
        return 0
      fi
      ;;
    esac
  done < <(printf '%s\n' "${out}")
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
out=$(bash "${BUILD_PACKAGES_SCRIPT}" --flake "${FLAKE_ROOT}" "${MINING_ARGS[@]}" 2>&1)
rc=$?
set -e

if ((rc == 0)); then
  echo "  ${HASH_FIELD} already correct."
  exit 0
fi

# A placeholder pin names no hash a build could have been mismatched against, so the first mismatch
# in the log is the one to recover from; a field that names one is only wrong about that one.
current_hash=$(sed -nE "s/^[[:space:]]*${HASH_FIELD}[[:space:]]*=[[:space:]]*\"([^\"]*)\";.*/\1/p" "${pin}" |
  head -1)
new_hash=$(mine_drift "${current_hash}") || new_hash=''
if [[ -z ${new_hash} ]]; then
  echo "error: building ${MINING_BUILD} failed and it wasn't a hash mismatch over ${HASH_FIELD}:" >&2
  printf '%s\n' "${out}" >&2
  exit 1
fi

echo "  ${HASH_FIELD} drift -> ${new_hash}"
# Anchor the field at start-of-line so HASH_FIELD=hash doesn't also match `sourceHash = ...`.
sed -i -E "s|^([[:space:]]*${HASH_FIELD}[[:space:]]*=[[:space:]]*\")[^\"]*(\";)|\\1${new_hash}\\2|" "${pin}"

echo "Verifying build..."
bash "${BUILD_PACKAGES_SCRIPT}" --flake "${FLAKE_ROOT}" --require-build
echo "  ${HASH_FIELD} validated."
