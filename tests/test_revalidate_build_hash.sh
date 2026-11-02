#!/usr/bin/env -S nix shell nixpkgs#bash nixpkgs#coreutils nixpkgs#gnugrep nixpkgs#gnused --command bash

set -euo pipefail

# What this suite owes is that the build the hash is recovered from is the build step the installed
# package provides rather than one the script names for itself -- which is how a producer's update
# came to fail on an attribute no flake publishes.

# The suite runs the script through bash, so nothing else here would notice a bit the wrapper needs.
[[ -x ${REVALIDATE_BUILD_HASH:?} ]] || {
  printf 'revalidator script is not executable, so the package wrapper cannot exec it: %s\n' "${REVALIDATE_BUILD_HASH}" >&2
  exit 1
}

CASES=$(mktemp -d)
STUBS=$(mktemp -d)
trap 'rm -rf "${CASES}" "${STUBS}"' EXIT

# The stub is run as a script text under bash, so it needs no exec bit and no resolvable shebang.
# Each build consumes the plan's first line; a plan with no lines left builds clean.
cat <<'STUB' >"${STUBS}/build-step"
printf '%s\n' "$*" >>"${STEP_LOG:?}"
OUTCOME=''
TEST_SPECIFIED=''
TEST_GOT=''
read -r OUTCOME TEST_SPECIFIED TEST_GOT <"${BUILD_STUB_PLAN:?}" || true
tail -n +2 "${BUILD_STUB_PLAN}" >"${BUILD_STUB_PLAN}.rest"
mv "${BUILD_STUB_PLAN}.rest" "${BUILD_STUB_PLAN}"
case "${OUTCOME:-ok}" in
mismatch)
  printf 'error: hash mismatch in fixed-output derivation %s:\n         specified: %s\n            got:    %s\n' \
    '/nix/store/fixture-fod.drv' "${TEST_SPECIFIED}" "${TEST_GOT}"
  exit 1
  ;;
fails)
  printf 'error: fixture: a published package does not build\n' >&2
  exit 1
  ;;
esac
STUB

CASE=''
OUT=''
BUILDS=''
FIELD='hash'
TARGET=''
run_revalidator() {
  CASE=$(mktemp -d -p "${CASES}")
  mkdir -p "${CASE}/tree"
  printf '%s\n' "${1}" >"${CASE}/plan"
  printf '%s\n' "${2}" >"${CASE}/tree/pin.nix"
  OUT="${CASE}/out"
  BUILDS="${CASE}/builds"
  : >"${BUILDS}"
  # The run starts outside the tree, so a revalidator reading its own directory fails here.
  (
    cd "${CASES}"
    FLAKE_ROOT="${CASE}/tree" \
      BUILD_PACKAGES_SCRIPT="${STUBS}/build-step" \
      BUILD_STUB_PLAN="${CASE}/plan" \
      BUILD_TARGET="${TARGET}" \
      HASH_FIELD="${FIELD}" \
      STEP_LOG="${BUILDS}" \
      bash "${REVALIDATE_BUILD_HASH}" >"${OUT}" 2>&1
  )
}

build_count() { wc -l <"${BUILDS}"; }

# A drifted hash is rewritten to the one the build produced.
run_revalidator 'mismatch sha256-vendorold sha256-vendornew
ok' '{
  plugins = [ "example@v1.0.0" ];
  hash = "sha256-vendorold";
}'
grep -Fq 'hash = "sha256-vendornew";' "${CASE}/tree/pin.nix"
[[ "$(build_count)" -eq 2 ]] || {
  printf 'a recovered hash has to be proven by a second build, not trusted\n' >&2
  exit 1
}
grep -Fq -- "--flake ${CASE}/tree" "${BUILDS}"

# A family that builds nothing reports success, so the recovery build is asked for a build.
grep -Fq -- '--require-build' "${BUILDS}"

# Naming the package narrows the recovery build without narrowing what the finished pin is proven
# against.
TARGET='caddy'
run_revalidator 'mismatch sha256-vendorold sha256-vendornew
ok' '{
  hash = "sha256-vendorold";
}'
grep -Fq 'hash = "sha256-vendornew";' "${CASE}/tree/pin.nix"
[[ "$(build_count)" -eq 2 ]]
MINED_BUILD=$(head -1 "${BUILDS}")
VERIFIED_BUILD=$(tail -1 "${BUILDS}")
grep -Fq -- '--only caddy' <<<"${MINED_BUILD}"
if grep -Fq -- '--require-build' <<<"${MINED_BUILD}"; then
  printf 'a named target is built whether or not the family would build anything, so requiring a build is not asked of it\n' >&2
  exit 1
fi
grep -Fq -- '--require-build' <<<"${VERIFIED_BUILD}"
if grep -Fq -- '--only' <<<"${VERIFIED_BUILD}"; then
  printf 'the build that verifies the rewritten tree has to be the whole family, not the mined target\n' >&2
  exit 1
fi
TARGET=''

# A pin whose field is named something other than `hash` is the field that is read and rewritten.
FIELD='vendorHash'
run_revalidator 'mismatch sha256-vendorold sha256-vendornew
ok' '{
  hash = "sha256-source";
  vendorHash = "sha256-vendorold";
}'
grep -Fq 'vendorHash = "sha256-vendornew";' "${CASE}/tree/pin.nix"
grep -Fq 'hash = "sha256-source";' "${CASE}/tree/pin.nix"
FIELD='hash'

# The rewrite is anchored to line start, so `hash` never reaches a `sourceHash` beside it.
run_revalidator 'mismatch sha256-vendorold sha256-vendornew
ok' '{
  sourceHash = "sha256-source";
  hash = "sha256-vendorold";
}'
grep -Fq 'hash = "sha256-vendornew";' "${CASE}/tree/pin.nix"
grep -Fq 'sourceHash = "sha256-source";' "${CASE}/tree/pin.nix"

# A mismatch over a hash this field does not hold is not this field's drift.
run_revalidator 'mismatch sha256-someone-elses sha256-vendornew
ok' '{
  hash = "sha256-vendorold";
}' && {
  printf 'a mismatch over a hash this field does not hold must not be mined into it\n' >&2
  exit 1
}
grep -Fq 'hash = "sha256-vendorold";' "${CASE}/tree/pin.nix"
[[ "$(build_count)" -eq 1 ]]

# A build that fails for another reason has no correct hash to recover.
if run_revalidator 'fails' '{
  hash = "sha256-vendorold";
}'; then
  printf 'a build that fails without a hash mismatch has to fail the run\n' >&2
  exit 1
fi
grep -Fq 'hash = "sha256-vendorold";' "${CASE}/tree/pin.nix"
[[ "$(build_count)" -eq 1 ]] || {
  printf 'a run that could not recover a hash must not rewrite the pin and build again\n' >&2
  exit 1
}

# Running the script text without its installed build step is an error, not a verdict.
CASE=$(mktemp -d -p "${CASES}")
mkdir -p "${CASE}/tree"
printf '%s\n' '{
  hash = "sha256-vendorold";
}' >"${CASE}/tree/pin.nix"
if (
  cd "${CASE}"
  FLAKE_ROOT="${CASE}/tree" env -u BUILD_PACKAGES_SCRIPT \
    bash "${REVALIDATE_BUILD_HASH}" >"${CASE}/out" 2>&1
); then
  printf 'the revalidator must not run without the build step it was installed with\n' >&2
  exit 1
fi
grep -Fq 'BUILD_PACKAGES_SCRIPT' "${CASE}/out"
grep -Fq 'hash = "sha256-vendorold";' "${CASE}/tree/pin.nix"

echo 'revalidate-build-hash tests passed'
