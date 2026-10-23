#!/usr/bin/env -S nix shell nixpkgs#bash nixpkgs#jq nixpkgs#coreutils --command bash

# Builds every package a flake publishes for one system, which is the part of a flake's
# published surface that `nix flake check` only evaluates. See "Build every published
# package" in README.md for what it deliberately leaves out.
#
# Like the workflow refresher this is flake-lib's own tool rather than a copy each producer
# republishes, because nothing about the calling flake is baked into it: what to build is
# read from the flake at the revision the runner checked out.

set -euo pipefail

FLAKE='.'
SYSTEM=''
DRY_RUN=false

die() {
  printf 'error: %s\n' "${1}" >&2
  exit 1
}

usage() {
  cat >&2 <<'USAGE'
usage: build-packages [--flake URL] [--system SYSTEM] [--dry-run]

  --flake URL     flake to build, default: the working directory
  --system SYSTEM system whose packages are built, default: the building system
  --dry-run       report what would be built and build nothing
USAGE
  exit 2
}

while [[ ${#} -gt 0 ]]; do
  case ${1} in
  --flake)
    FLAKE=${2:-}
    [[ -n ${FLAKE} ]] || usage
    shift 2
    ;;
  --system)
    SYSTEM=${2:-}
    [[ -n ${SYSTEM} ]] || usage
    shift 2
    ;;
  --dry-run)
    DRY_RUN=true
    shift
    ;;
  -h | --help) usage ;;
  *) die "unrecognized argument: ${1}" ;;
  esac
done

SELECT=${BUILD_PACKAGES_SELECT:?required env var}

if [[ -z ${SYSTEM} ]]; then
  SYSTEM=$(nix config show system) || die "this nix does not report the system it builds for"
fi

# The selection travels as text because a pure evaluation refuses a path literal. An absent
# output family and a flake that fails to evaluate reach this point with the same exit
# status, and only the first is named alone among the candidates in nix's message.
STDERR=$(mktemp)
trap 'rm -f "${STDERR}"' EXIT
if ! SELECTION=$(nix eval --no-write-lock-file --json --apply "$(cat "${SELECT}")" "${FLAKE}#packages.${SYSTEM}" 2>"${STDERR}"); then
  cat "${STDERR}" >&2
  if grep -Fq "or 'packages.${SYSTEM}'" "${STDERR}"; then
    printf 'publishes no packages for %s, so there is nothing to build.\n' "${SYSTEM}"
    exit 0
  fi
  die "evaluating ${FLAKE}#packages.${SYSTEM} failed"
fi
cat "${STDERR}" >&2

# The lists below are read through a process substitution, whose exit status this shell
# cannot see, so the shape is required before it is read rather than trusted afterwards.
jq -e 'has("build") and has("skip")' >/dev/null <<<"${SELECTION}" ||
  die "the selection did not report a build list and a skip list"
mapfile -t BUILD_NAMES < <(jq -r '.build[]' <<<"${SELECTION}")
mapfile -t SKIPPED_NAMES < <(jq -r '.skip[]' <<<"${SELECTION}")

if ((${#SKIPPED_NAMES[@]} > 0)); then
  printf 'skipped by passthru.ciBuildSkip: %s\n' "${SKIPPED_NAMES[*]}" >&2
fi

# Quoted because an attribute name is not necessarily an identifier: a name with a dot in it
# would otherwise read as a nested attribute, and one starting with a digit would not read at
# all. nix resolves either form once quoted.
TARGETS=()
for NAME in "${BUILD_NAMES[@]}"; do
  TARGETS+=("${FLAKE}#packages.${SYSTEM}.\"${NAME}\"")
done

if ((${#TARGETS[@]} == 0)); then
  printf 'publishes no package for %s that a runner builds.\n' "${SYSTEM}"
  exit 0
fi

if [[ ${DRY_RUN} == true ]]; then
  printf '%s\n' "${TARGETS[@]}"
  exit 0
fi

printf 'building %d package(s) for %s.\n' "${#TARGETS[@]}" "${SYSTEM}"
nix build --no-link -L --no-write-lock-file "${TARGETS[@]}"
