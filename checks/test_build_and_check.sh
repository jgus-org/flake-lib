#!/usr/bin/env -S nix shell nixpkgs#bash nixpkgs#coreutils nixpkgs#gnugrep --command bash

set -euo pipefail

# The gate is the one command every path runs, so this suite checks that both steps run whatever the first one reported. A tree with a package that does not build and a check that does not pass has two problems. A gate that stops at the first costs a runner a second round trip to learn the second one.

# This suite runs the script through bash for determinism, so nothing else here would notice a missing executable bit. flake.nix's package wrapper execs the script directly, so a missing bit breaks every producer's run.
[[ -x ${BUILD_AND_CHECK:?} ]] || {
  printf 'gate script is not executable, so the package wrapper cannot exec it: %s\n' "${BUILD_AND_CHECK}" >&2
  exit 1
}

CASES=$(mktemp -d)
STUBS=$(mktemp -d)
trap 'rm -rf "${CASES}" "${STUBS}"' EXIT
mkdir -p "${STUBS}/bin"
# The stubs are scripts the gate invokes, so their shebangs have to resolve where the test runs. The bash already on PATH is the one that does. The build step is a script text handed in through the environment, the same text the published tool wraps.
{
  printf '#!%s\n' "$(command -v bash)"
  cat <<'STUB'
printf '%s\n' "${*}" >>"${STEP_LOG:?}"
exit "${STUB_BUILD_STATUS:-0}"
STUB
} >"${STUBS}/bin/build-step"
{
  printf '#!%s\n' "$(command -v bash)"
  cat <<'STUB'
printf '%s\n' "${*}" >>"${STEP_LOG:?}"
if [[ ${1} == config ]]; then
  printf '%s\n' "${STUB_SYSTEM}"
  exit 0
fi
if [[ ${1} == eval ]]; then
  [[ -n ${STUB_CI_PROGRAM_KIND:-} ]] || exit 1
  printf '%s\n' "${STUB_CI_PROGRAM_KIND}"
  exit 0
fi
if [[ ${1} == run ]]; then
  exit "${STUB_CI_STATUS:-0}"
fi
exit "${STUB_CHECK_STATUS:-0}"
STUB
} >"${STUBS}/bin/nix"
chmod +x "${STUBS}/bin/build-step" "${STUBS}/bin/nix"

# The gate names the tree's command by the app family of the system nix reports, so the probe and the run are both spelled with it.
SYSTEM=x86_64-linux
CI_SYSTEM='config show system'
CI_PROBE=$(
  printf 'eval --raw .#apps.%s.test-ci --apply %s' "${SYSTEM}" 'a: builtins.typeOf (a.program or null)'
)
CI_RUN="run .#apps.${SYSTEM}.test-ci"

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
      STUB_SYSTEM="${SYSTEM}" \
      STUB_CI_PROGRAM_KIND="${STUB_CI_PROGRAM_KIND:-}" \
      STUB_CI_STATUS="${STUB_CI_STATUS:-0}" \
      bash "${BUILD_AND_CHECK}" >"${OUT}" 2>&1
  )
}

steps() { cat "${CASE}/steps"; }

# A tree with nothing wrong in it runs every step, in order, and the gate asks each about the working directory. The gate verifies the tree it is run in, which is where both paths put it. A tree that publishes no command of its own is asked once, and the asking is not a failure.
run_gate
[[ "$(steps)" == "$(
  printf '%s\n' '' 'flake check --no-write-lock-file' "${CI_SYSTEM}" "${CI_PROBE}"
)" ]]
grep -Fq 'checking the flake' "${OUT}"
grep -Fq 'running the repository command' "${OUT}" && {
  printf 'a tree with no repository command must not claim to run one\n' >&2
  exit 1
}

# A package that does not build does not hide a check that also fails. The run names the failure it saw, runs the rest anyway, and does not pass.
STUB_BUILD_STATUS=1 run_gate && {
  printf 'a published package that does not build must fail the gate\n' >&2
  exit 1
}
[[ "$(steps)" == "$(
  printf '%s\n' '' 'flake check --no-write-lock-file' "${CI_SYSTEM}" "${CI_PROBE}"
)" ]]

# A check that does not pass fails the run on its own, and the build step is what a producer sees first.
STUB_CHECK_STATUS=1 run_gate && {
  printf 'a check that fails must fail the gate\n' >&2
  exit 1
}
[[ "$(steps | grep -c -F 'flake check')" == 1 ]]

# A tree that publishes the `test-ci` app has its own verification run, and it runs after the two steps that report in seconds.
STUB_CI_PROGRAM_KIND=string run_gate
[[ "$(steps)" == "$(
  printf '%s\n' '' 'flake check --no-write-lock-file' "${CI_SYSTEM}" "${CI_PROBE}" "${CI_RUN}"
)" ]]
grep -Fq 'running the repository command' "${OUT}"

# A command that fails fails the run on its own, whatever the derivations did. The command is the only step that reaches the network, the filesystem, and the hardware, so a gate that let it pass quietly would wave through the verification the producer added the app for.
STUB_CI_PROGRAM_KIND=string STUB_CI_STATUS=1 run_gate && {
  printf 'a repository command that fails must fail the gate\n' >&2
  exit 1
}

# A package that does not build does not excuse the tree's own verification either. Both problems are named in one run, which is what every other pair of steps in this gate already owes.
STUB_BUILD_STATUS=1 STUB_CI_PROGRAM_KIND=string run_gate && {
  printf 'a published package that does not build must not skip the repository command\n' >&2
  exit 1
}
[[ "$(steps | grep -c -F "${CI_RUN}")" == 1 ]]

# An app whose program nix cannot print is a command the gate cannot run. The run says so rather than reporting a tree that published nothing.
STUB_CI_PROGRAM_KIND=set run_gate && {
  printf 'an app with no printable program must fail the gate\n' >&2
  exit 1
}
grep -Fq 'neither a string nor a path' "${OUT}"
[[ "$(steps | grep -c -F "${CI_RUN}")" == 0 ]]

# The gate reaches its build step through the environment the package installs. A caller that runs the script text without it gets an error instead of a quiet flake-only check.
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
