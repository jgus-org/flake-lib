#!/usr/bin/env -S nix shell nixpkgs#bash nixpkgs#coreutils nixpkgs#gnugrep nixpkgs#gnused --command bash

set -euo pipefail

# The revalidator's whole interface is a tree and the build that tree is verified by: it runs the
# published-family build, mines the hash a mismatch states, rewrites the pin field that holds it,
# and builds again to prove the rewrite. What this suite owes is that the build it mines is the
# build step the package installs, not one the script names for itself -- a tool free to build what
# it likes is a tool free to build something the gate will not, which is how a producer's update
# came to fail on an attribute no flake publishes.

# This suite runs the script through bash for determinism; flake.nix's package wrapper execs it
# directly, so a missing executable bit breaks every producer's run and nothing here would notice.
[[ -x ${REVALIDATE_BUILD_HASH:?} ]] || {
  printf 'revalidator script is not executable, so the package wrapper cannot exec it: %s\n' "${REVALIDATE_BUILD_HASH}" >&2
  exit 1
}

CASES=$(mktemp -d)
STUBS=$(mktemp -d)
trap 'rm -rf "${CASES}" "${STUBS}"' EXIT

# The stub stands in for the build step and is run as a script text under bash, so it needs neither
# an executable bit nor a shebang that resolves. Each build consumes the first line of the plan,
# which says what that build reports; a plan with no lines left builds clean.
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
run_revalidator() {
  CASE=$(mktemp -d -p "${CASES}")
  mkdir -p "${CASE}/tree"
  printf '%s\n' "${1}" >"${CASE}/plan"
  printf '%s\n' "${2}" >"${CASE}/tree/pin.nix"
  OUT="${CASE}/out"
  BUILDS="${CASE}/builds"
  : >"${BUILDS}"
  # The tree is named through the environment while the run starts somewhere else, so a revalidator
  # that read its own working directory instead would build the wrong tree and still exit clean.
  (
    cd "${CASES}"
    FLAKE_ROOT="${CASE}/tree" \
      BUILD_PACKAGES_SCRIPT="${STUBS}/build-step" \
      BUILD_STUB_PLAN="${CASE}/plan" \
      HASH_FIELD="${FIELD}" \
      STEP_LOG="${BUILDS}" \
      bash "${REVALIDATE_BUILD_HASH}" >"${OUT}" 2>&1
  )
}

build_count() { wc -l <"${BUILDS}"; }

# A vendor hash that drifted: the mismatch states the hash the pin carries and the one the build
# produced, so the field is rewritten to the second and the tree is built again to prove it.
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

# The build is asked for one that builds something, because a family that builds nothing reports
# success, and this script reads success as the hash having been proven.
grep -Fq -- '--require-build' "${BUILDS}"

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

# A pin that carries the field named by HASH_FIELD beside a field whose name ends with it: the
# rewrite is anchored to the start of the line, so `hash` never reaches a `sourceHash` beside it.
run_revalidator 'mismatch sha256-vendorold sha256-vendornew
ok' '{
  sourceHash = "sha256-source";
  hash = "sha256-vendorold";
}'
grep -Fq 'hash = "sha256-vendornew";' "${CASE}/tree/pin.nix"
grep -Fq 'sourceHash = "sha256-source";' "${CASE}/tree/pin.nix"

# The family is built whole, so a mismatch over some other published package is not this field's
# drift: nothing is written, and the run says it did not find this field's mismatch.
run_revalidator 'mismatch sha256-someone-elses sha256-vendornew
ok' '{
  hash = "sha256-vendorold";
}' && {
  printf 'a mismatch over a hash this field does not hold must not be mined into it\n' >&2
  exit 1
}
grep -Fq 'hash = "sha256-vendorold";' "${CASE}/tree/pin.nix"
[[ "$(build_count)" -eq 1 ]]

# A published package that does not build for a reason other than the hash has no correct hash to
# recover: the run stops, leaves the pin alone, and does not rewrite and rebuild on a guess.
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

# The build step arrives with the installed package, so a caller that runs the script text without
# it has to be told rather than report a hash it never built anything for.
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
