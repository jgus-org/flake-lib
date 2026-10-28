#!/usr/bin/env -S nix shell nixpkgs#bash nixpkgs#coreutils nixpkgs#gnugrep --command bash

set -euo pipefail

# The gate is the one command every path runs, so what this suite owes is that it runs both steps
# whatever the first one reported: a tree with a package that does not build and a check that does
# not pass is a tree with two problems, and a gate that stops at the first costs a runner a second
# round trip to learn the second one.

# This suite runs the script through bash for determinism; flake.nix's package wrapper execs it
# directly, so a missing executable bit breaks every producer's run and nothing here would notice.
[[ -x ${BUILD_AND_CHECK:?} ]] || {
  printf 'gate script is not executable, so the package wrapper cannot exec it: %s\n' "${BUILD_AND_CHECK}" >&2
  exit 1
}

CASES=$(mktemp -d)
STUBS=$(mktemp -d)
trap 'rm -rf "${CASES}" "${STUBS}"' EXIT
mkdir -p "${STUBS}/bin"
# The stubs are scripts the gate invokes, so their shebangs have to resolve where the test runs:
# the bash already on PATH is the one that does. The build step is a script text handed in through
# the environment, the same text the published tool wraps.
{
  printf '#!%s\n' "$(command -v bash)"
  cat <<'STUB'
printf '%s\n' "$*" >>"${STEP_LOG:?}"
exit "${STUB_BUILD_STATUS:-0}"
STUB
} >"${STUBS}/bin/build-step"
{
  printf '#!%s\n' "$(command -v bash)"
  cat <<'STUB'
printf '%s\n' "$*" >>"${STEP_LOG:?}"
exit "${STUB_CHECK_STATUS:-0}"
STUB
} >"${STUBS}/bin/nix"
chmod +x "${STUBS}/bin/build-step" "${STUBS}/bin/nix"

CASE=''
OUT=''
run_gate() {
  CASE=$(mktemp -d -p "${CASES}")
  OUT="${CASE}/stdout"
  (
    cd "${CASE}"
    PATH="${STUBS}/bin:${PATH}" \
      BUILD_PACKAGES_SCRIPT="${STUBS}/bin/build-step" \
      STEP_LOG="${CASE}/steps" \
      STUB_BUILD_STATUS="${STUB_BUILD_STATUS:-0}" \
      STUB_CHECK_STATUS="${STUB_CHECK_STATUS:-0}" \
      bash "${BUILD_AND_CHECK}" >"${OUT}" 2>&1
  )
}

steps() { cat "${CASE}/steps"; }

# A tree with nothing wrong in it runs both steps, in order, and each is asked about the working
# directory: the gate verifies the tree it is run in, which is where both paths put it.
run_gate
[[ "$(steps)" == "$(
  printf '%s\n' '' 'flake check --no-write-lock-file'
)" ]]
grep -Fq 'checking the flake' "${OUT}"

# A package that does not build does not hide a check that also fails: the run names the failure it
# saw, runs the rest anyway, and does not pass.
STUB_BUILD_STATUS=1 run_gate && {
  printf 'a published package that does not build must fail the gate\n' >&2
  exit 1
}
[[ "$(steps)" == "$(
  printf '%s\n' '' 'flake check --no-write-lock-file'
)" ]]

# A check that does not pass fails the run on its own, and the build step is what a producer sees
# first.
STUB_CHECK_STATUS=1 run_gate && {
  printf 'a check that fails must fail the gate\n' >&2
  exit 1
}
[[ "$(steps | grep -c -F 'flake check')" == 1 ]]

# The gate reaches its build step through the environment the package installs, so a caller that
# runs the script text without it has to be told rather than quietly check the flake alone.
CASE=$(mktemp -d -p "${CASES}")
(
  cd "${CASE}"
  PATH="${STUBS}/bin:${PATH}" STEP_LOG="${CASE}/steps" \
    env -u BUILD_PACKAGES_SCRIPT bash "${BUILD_AND_CHECK}" >"${CASE}/out" 2>&1
) && {
  printf 'the gate must not run without the build step it was installed with\n' >&2
  exit 1
}
grep -Fq 'BUILD_PACKAGES_SCRIPT' "${CASE}/out"
[[ ! -e ${CASE}/steps ]] || {
  printf 'a gate with no build step must not check the flake either\n' >&2
  exit 1
}

echo 'build-and-check tests passed'
