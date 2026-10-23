#!/usr/bin/env -S nix shell nixpkgs#bash nixpkgs#coreutils nixpkgs#gnugrep nixpkgs#jq --command bash

set -euo pipefail

# The build gate is exercised against a nix that answers from fixtures, because what the
# tool owes its caller is the exact set of installables it hands to `nix build`, which
# packages it names as excused from the build, and which failures it refuses to mistake for
# a flake that publishes nothing.

# This suite runs the script through bash for determinism; flake.nix's package wrapper execs
# it directly, so a missing executable bit breaks every producer's run and nothing here
# would notice.
[[ -x ${BUILD_PACKAGES:?} ]] || {
  printf 'build script is not executable, so the package wrapper cannot exec it: %s\n' "${BUILD_PACKAGES}" >&2
  exit 1
}

CASES=$(mktemp -d)
STUB_NIX=$(mktemp -d)
trap 'rm -rf "${CASES}" "${STUB_NIX}"' EXIT
mkdir -p "${STUB_NIX}/bin"
# The stub is a script the tool execs by name, so its shebang has to resolve where the test
# runs: the bash already on PATH is the one that does.
{
  printf '#!%s\n' "$(command -v bash)"
  cat <<'STUB'
set -euo pipefail
printf '%s\n' "$*" >>"${STUB_NIX_LOG:?}"
printf '%s\n' "$@" >"${STUB_NIX_ARGV:?}"
if [[ ${1} == config && ${2} == show ]]; then
  if [[ -n ${STUB_NIX_NO_SYSTEM:-} ]]; then
    printf 'error: no system configured\n' >&2
    exit 1
  fi
  printf '%s\n' "${STUB_NIX_SYSTEM:?fixture: no system to report}"
  exit 0
fi
if [[ ${1} == eval ]]; then
  [[ -z ${STUB_NIX_EVAL_STDERR:-} ]] || printf '%s\n' "${STUB_NIX_EVAL_STDERR}" >&2
  [[ -z ${STUB_NIX_SELECTION:-} ]] || printf '%s\n' "${STUB_NIX_SELECTION}"
  exit "${STUB_NIX_EVAL_STATUS:-0}"
fi
exit "${STUB_NIX_BUILD_STATUS:-0}"
STUB
} >"${STUB_NIX}/bin/nix"
chmod +x "${STUB_NIX}/bin/nix"

CASE=''
OUT=''
ERR=''
run_tool() {
  CASE=$(mktemp -d -p "${CASES}")
  OUT="${CASE}/stdout"
  ERR="${CASE}/stderr"
  (
    cd "${CASE}"
    PATH="${STUB_NIX}/bin:${PATH}" \
      BUILD_PACKAGES_SELECT="${BUILD_PACKAGES_SELECT:?}" \
      STUB_NIX_LOG="${CASE}/nix-log" \
      STUB_NIX_ARGV="${CASE}/nix-argv" \
      STUB_NIX_SYSTEM="${STUB_NIX_SYSTEM:-x86_64-linux}" \
      STUB_NIX_SELECTION="${STUB_NIX_SELECTION:-}" \
      STUB_NIX_EVAL_STATUS="${STUB_NIX_EVAL_STATUS:-0}" \
      STUB_NIX_EVAL_STDERR="${STUB_NIX_EVAL_STDERR:-}" \
      STUB_NIX_BUILD_STATUS="${STUB_NIX_BUILD_STATUS:-0}" \
      STUB_NIX_NO_SYSTEM="${STUB_NIX_NO_SYSTEM:-}" \
      bash "${BUILD_PACKAGES}" "$@" >"${OUT}" 2>"${ERR}"
  )
}

build_lines() { grep -E '^build ' "${CASE}/nix-log" || true; }

# The arguments of the last nix call, one per line, so an argument that split on a space
# would show up as two.
last_call() { cat "${CASE}/nix-argv"; }

# A package excused by passthru.ciBuildSkip is named for what it was excused, and its
# siblings are still built.
STUB_NIX_SELECTION='{"build": ["a", "z"], "skip": ["model"]}' run_tool
grep -Fxq 'skipped by passthru.ciBuildSkip: model' "${ERR}"
grep -Fxq 'building 2 package(s) for x86_64-linux.' "${OUT}"
[[ "$(last_call)" == "$(
  printf '%s\n' build --no-link -L --no-write-lock-file \
    '.#packages.x86_64-linux."a"' '.#packages.x86_64-linux."z"'
)" ]]
grep -Fq "eval --no-write-lock-file --json --apply" "${CASE}/nix-log"

# The flake the caller named is the flake that is evaluated and built.
STUB_NIX_SELECTION='{"build": ["a"], "skip": []}' run_tool --flake 'github:eg/other'
grep -Fq 'eval --no-write-lock-file --json --apply' "${CASE}/nix-log"
grep -Fq 'github:eg/other#packages.x86_64-linux."a"' "${CASE}/nix-argv"

# --dry-run reports the same installables and orders no build.
STUB_NIX_SELECTION='{"build": ["a", "z"], "skip": ["model"]}' run_tool --dry-run
grep -Fxq '.#packages.x86_64-linux."a"' "${OUT}"
grep -Fxq '.#packages.x86_64-linux."z"' "${OUT}"
[[ -z $(build_lines) ]]

# --system is what selects the family, so a cross-system audit reads the names it asks for.
STUB_NIX_SELECTION='{"build": ["a"], "skip": []}' run_tool --system aarch64-linux
grep -Fq '.#packages.aarch64-linux' "${CASE}/nix-log"
grep -Fxq 'build --no-link -L --no-write-lock-file .#packages.aarch64-linux."a"' "${CASE}/nix-log"

# An attribute name is not necessarily an identifier: a dot is not a nesting level and a
# leading digit is not a syntax error, so each name has to arrive as one argument.
STUB_NIX_SELECTION='{"build": ["8bitdo-2c-re", "a.b"], "skip": []}' run_tool
[[ "$(last_call)" == "$(
  printf '%s\n' build --no-link -L --no-write-lock-file \
    '.#packages.x86_64-linux."8bitdo-2c-re"' '.#packages.x86_64-linux."a.b"'
)" ]]

# A flake with no packages family for this system is not a failure: the run says what it
# found and builds nothing, which is what lets every published flake carry the gate.
STUB_NIX_EVAL_STATUS=1 \
  STUB_NIX_EVAL_STDERR="error: flake 'github:eg/x' does not provide attribute 'packages.x86_64-linux.packages.aarch64-darwin', 'legacyPackages.x86_64-linux.packages.aarch64-darwin' or 'packages.aarch64-darwin'" \
  run_tool --system aarch64-darwin
grep -Fxq 'publishes no packages for aarch64-darwin, so there is nothing to build.' "${OUT}"
[[ -z $(build_lines) ]]

# A flake that fails to evaluate is not that. The reason reaches the caller, and the run
# does not pass.
STUB_NIX_EVAL_STATUS=1 STUB_NIX_EVAL_STDERR='error: boom' run_tool && {
  printf 'an evaluating flake that throws must not pass the build gate\n' >&2
  exit 1
}
grep -Fq 'error: boom' "${ERR}"
grep -Fq 'error: evaluating .#packages.x86_64-linux failed' "${ERR}"
[[ -z $(build_lines) ]]

# A selection the tool cannot read builds nothing, so it has to fail rather than report a
# gate that passed.
STUB_NIX_SELECTION='the selection expression is not the only thing that can go wrong' run_tool && {
  printf 'a selection that does not parse must not pass the build gate\n' >&2
  exit 1
}
grep -Fxq 'error: the selection did not report a build list and a skip list' "${ERR}"
[[ -z $(build_lines) ]]

# A nix that will not name the system it builds for cannot be asked what to build, and says
# so itself rather than evaluating an installable nobody asked for.
STUB_NIX_NO_SYSTEM=1 run_tool && {
  printf 'a nix that reports no system must not pass the build gate\n' >&2
  exit 1
}
grep -Fxq 'error: this nix does not report the system it builds for' "${ERR}"
[[ -z $(build_lines) ]]

# Every package excused leaves nothing to build, and the reason is still named.
STUB_NIX_SELECTION='{"build": [], "skip": ["model"]}' run_tool
grep -Fxq 'skipped by passthru.ciBuildSkip: model' "${ERR}"
grep -Fxq 'publishes no package for x86_64-linux that a runner builds.' "${OUT}"
[[ -z $(build_lines) ]]

# A build that fails is the gate failing, with the builder's own output passed through.
STUB_NIX_SELECTION='{"build": ["a"], "skip": []}' STUB_NIX_BUILD_STATUS=17 run_tool && {
  printf 'a failed build must fail the gate\n' >&2
  exit 1
}
grep -Fxq 'build --no-link -L --no-write-lock-file .#packages.x86_64-linux."a"' "${CASE}/nix-log"

echo 'build-packages tests passed'
