#!/usr/bin/env -S nix shell nixpkgs#bash nixpkgs#nix nixpkgs#gnused nixpkgs#coreutils --command bash

# Revalidate a fixed-output (vendor) hash that can't be prefetched — Go modules, cargo deps, npm FODs, xcaddy plugin trees — by building and recovering the correct hash from nix's mismatch error.
#
#   HASH_FIELD   pin.nix field to rewrite (default "hash")
#
# The build target is the flake's published package family: the mismatch states its own hash and
# the pin field holding it is looked up from there, so no caller names a target. Run from the flake
# root (or set FLAKE_ROOT). Used directly by manifest-style flakes (e.g. caddy).

set -euo pipefail

FLAKE_ROOT="${FLAKE_ROOT:-${PWD}}"
HASH_FIELD="${HASH_FIELD:-hash}"
SYSTEM=$(nix config show system) || {
  echo "error: this nix does not report the system it builds for" >&2
  exit 1
}
pin="${FLAKE_ROOT}/pin.nix"

if [[ ! -f ${pin} ]]; then
  echo "error: no pin.nix in ${FLAKE_ROOT}" >&2
  exit 1
fi

echo "Building the packages this flake publishes for ${SYSTEM} to validate ${HASH_FIELD}..."
set +e
out=$(nix build "${FLAKE_ROOT}#packages.${SYSTEM}" --no-link 2>&1)
rc=$?
set -e

if ((rc == 0)); then
  echo "  ${HASH_FIELD} already correct."
  exit 0
fi

new_hash=$(printf '%s\n' "${out}" | sed -nE 's/.*got:[[:space:]]+(sha256-[A-Za-z0-9+/=]+).*/\1/p' | head -1)
if [[ -z ${new_hash} ]]; then
  echo "error: building what this flake publishes failed and it wasn't a hash mismatch:" >&2
  printf '%s\n' "${out}" >&2
  exit 1
fi

echo "  ${HASH_FIELD} drift -> ${new_hash}"
# Anchor the field at start-of-line so HASH_FIELD=hash doesn't also match `sourceHash = ...`.
sed -i -E "s|^([[:space:]]*${HASH_FIELD}[[:space:]]*=[[:space:]]*\")[^\"]*(\";)|\\1${new_hash}\\2|" "${pin}"

echo "Verifying build..."
nix build "${FLAKE_ROOT}#packages.${SYSTEM}" --no-link
echo "  ${HASH_FIELD} validated."
