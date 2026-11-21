#!/usr/bin/env -S nix shell nixpkgs#bash nixpkgs#git nixpkgs#jq nixpkgs#nix nixpkgs#coreutils --command bash

# Installs this repository's GitHub Actions workflows from the templates shipped by the newest flake-lib revision its declared input can reach, and advances the lock to that revision in the same commit: a workflow that tracks flake-lib N must not run the scripts of revision N+1, or the repository is green against a library nothing else locks.
#
# A template replaces its workflow wholesale. Every repository-owned knob is a constructor argument in flake.nix baked into the package the workflow invokes, so the workflow file carries no repository state worth rescuing.
#
# With no arguments this keeps installed workflows current. It removes, renames, or picks names for none of them, because which workflows a repository has is the author's decision. `adopt <name>` is how a repository joins that set, and it is the only way: the author names the template, so the tool never guesses which publication model a repository wants.
#
# A workflow follows the templates only because this runs for it on a schedule, so every run keeps update-workflows.yml, the workflow that runs this, installed and current too.

set -euo pipefail

FLAKE_ROOT="${FLAKE_ROOT:-${PWD}}"
cd "${FLAKE_ROOT}"

WORKFLOW_DIR=".github/workflows"
REFRESHER_WORKFLOW="${WORKFLOW_DIR}/update-workflows.yml"

die() {
  printf 'error: %s\n' "${1}" >&2
  exit 1
}

usage() {
  cat >&2 <<'USAGE'
usage: update-workflows [adopt <workflow-name>.yml]

  (no arguments)  advance flake-lib and rewrite every installed workflow that
                  revision has a template for, under the same name
  adopt <name>    advance flake-lib and install that one template, creating the
                  workflow if this repository does not have it yet
USAGE
  exit 2
}

MODE=refresh
ADOPT_TARGET=''
case ${1:-} in
'') ;;
adopt)
  MODE=adopt
  ADOPT_TARGET=${2:-}
  [[ -n ${ADOPT_TARGET} ]] || usage
  [[ ${ADOPT_TARGET} != */* ]] ||
    die "adopt takes a workflow name, not a path: ${ADOPT_TARGET}"
  case ${ADOPT_TARGET} in
  *.yml | *.yaml) ;;
  *) die "adopt takes a workflow name ending in .yml or .yaml, not ${ADOPT_TARGET}" ;;
  esac
  shift 2
  ;;
-h | --help) usage ;;
*) die "unrecognized argument: ${1}" ;;
esac
[[ ${#} -eq 0 ]] || usage

# shellcheck source=/dev/null
source "${GIT_PUSH_LIB:?required env var}"

NODE=$(jq -r '.nodes.root.inputs["flake-lib"] // ""' flake.lock)
[[ -n ${NODE} ]] || die "flake.lock has no flake-lib input, so there is no template to install"
LOCKED_URL=$(jq -r '.nodes.root.inputs["flake-lib"] as $n | .nodes[$n].locked
  | select(.type == "github") | "\(.owner)/\(.repo)/\(.rev)"' flake.lock)
[[ -n ${LOCKED_URL} ]] || die "flake.lock's flake-lib is not a github input, so its templates have no public revision to install from"

if ! nix flake update flake-lib; then
  die "advancing the flake-lib input failed"
fi
CURRENT_URL=$(jq -r '.nodes.root.inputs["flake-lib"] as $n | .nodes[$n].locked
  | select(.type == "github") | "\(.owner)/\(.repo)/\(.rev)"' flake.lock)
[[ -n ${CURRENT_URL} ]] || die "advancing flake-lib left a lock whose flake-lib input is no longer a github input"

SYSTEM=$(nix config show system) || die "this nix does not report the system it builds for"
TEMPLATES_REF="github:${CURRENT_URL}#packages.${SYSTEM}.workflow-templates"
STDERR=$(mktemp)
trap 'rm -f "${STDERR}"' EXIT
if ! TEMPLATES_SRC=$(nix build --no-link --no-write-lock-file --print-out-paths "${TEMPLATES_REF}" 2>"${STDERR}"); then
  cat "${STDERR}" >&2
  die "flake-lib ${CURRENT_URL} publishes no packages.${SYSTEM}.workflow-templates, so the installed workflows cannot be refreshed from it"
fi

install_from_template() {
  local TEMPLATE="${1}" DESTINATION="${2}"
  cp "${TEMPLATE}" "${DESTINATION}"
}

carries_schedule() {
  grep -qE '^[[:space:]]*schedule:' "${1}"
}

declare -a INSTALLED=()
if [[ ${MODE} == adopt ]]; then
  TEMPLATE="${TEMPLATES_SRC}/${ADOPT_TARGET}"
  if [[ ! -s ${TEMPLATE} ]]; then
    AVAILABLE=$(cd "${TEMPLATES_SRC}" && printf '%s ' *.yml *.yaml 2>/dev/null || true)
    die "flake-lib ${CURRENT_URL##*/} ships no templates/workflows/${ADOPT_TARGET}; it ships ${AVAILABLE}"
  fi
  DESTINATION="${WORKFLOW_DIR}/${ADOPT_TARGET}"
  mkdir -p "${WORKFLOW_DIR}"
  install_from_template "${TEMPLATE}" "${DESTINATION}"
  INSTALLED+=("${DESTINATION}")
  # Adopting a flake-lib workflow adopts the schedule that rewrites flake-lib workflows with it, so the adopted template is current the day it lands rather than after someone installs the schedule by hand.
  if [[ ${DESTINATION} != "${REFRESHER_WORKFLOW}" ]]; then
    install_from_template "${TEMPLATES_SRC}/update-workflows.yml" "${REFRESHER_WORKFLOW}"
    INSTALLED+=("${REFRESHER_WORKFLOW}")
  fi
  # A workflow flake-lib has no template for is invisible to every later refresh, and a scheduled one keeps publishing beside the adopted template forever. Retiring it is the author's decision, so it is named rather than removed. Whether a file schedules anything is the author's intent and lives only in the file, which is the one place it can be read. The schedule installed above is skipped: it is refreshed by every run, which is what it is for.
  OTHERS=()
  for OTHER in "${WORKFLOW_DIR}"/*.yml "${WORKFLOW_DIR}"/*.yaml; do
    [[ -f ${OTHER} && ${OTHER} != "${DESTINATION}" ]] || continue
    [[ ${OTHER} == "${REFRESHER_WORKFLOW}" ]] && continue
    if carries_schedule "${OTHER}"; then
      OTHERS+=("${OTHER}")
    fi
  done
  if ((${#OTHERS[@]} > 0)); then
    printf 'note: %s also carries a schedule, and a workflow flake-lib has no template for is never refreshed: %s\n' \
      "${MODE}" "${OTHERS[*]}"
  fi
else
  for DESTINATION in "${WORKFLOW_DIR}"/*.yml "${WORKFLOW_DIR}"/*.yaml; do
    [[ -e ${DESTINATION} ]] || continue
    TEMPLATE="${TEMPLATES_SRC}/${DESTINATION##*/}"
    [[ -f ${TEMPLATE} ]] || continue
    install_from_template "${TEMPLATE}" "${DESTINATION}"
    INSTALLED+=("${DESTINATION}")
  done
  # A repository that runs this tool follows flake-lib's templates, and the workflow that rewrites them is one of them: an installed copy is refreshed by the loop above, which is also how its cron keeps up with the template, and a repository with none gets it here. The case that matters is a repository whose only flake-lib workflow is the pull-request gate, which has nothing else that would ever update it.
  if ((${#INSTALLED[@]} == 0)); then
    echo "no workflow here matched flake-lib's templates/workflows. This run installs the schedule that runs it and advances the input."
  fi
  if [[ ! -e ${REFRESHER_WORKFLOW} ]]; then
    mkdir -p "${WORKFLOW_DIR}"
    install_from_template "${TEMPLATES_SRC}/update-workflows.yml" "${REFRESHER_WORKFLOW}"
    INSTALLED+=("${REFRESHER_WORKFLOW}")
  fi
fi

BRANCH=$(git symbolic-ref --quiet --short HEAD) ||
  die "the flake-lib update commit needs a branch to push to, but HEAD is detached"
BASE=$(git rev-parse HEAD)

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git add flake.lock "${INSTALLED[@]}"
if git diff --cached --quiet; then
  echo "flake-lib ${CURRENT_URL} changed neither the installed workflows nor this flake's inputs."
  exit 0
fi
mapfile -t COMMITTED < <(git diff --cached --name-only)
# A template can be byte-identical to what is already installed, in which case the commit is the input advance alone and its subject should not claim otherwise.
if printf '%s\n' "${COMMITTED[@]}" | grep -qvxF flake.lock; then
  if [[ ${MODE} == adopt ]]; then
    SUBJECT="Adopt flake-lib's ${ADOPT_TARGET} at ${CURRENT_URL##*/}"
  else
    SUBJECT="Update workflows from flake-lib ${CURRENT_URL##*/}"
  fi
else
  SUBJECT="Advance flake-lib to ${CURRENT_URL##*/}"
fi
git commit -q -m "${SUBJECT}"

push_ref HEAD "${BRANCH}" "${BASE}" lease
echo "Committed ${#COMMITTED[@]} file(s) from flake-lib ${CURRENT_URL}: ${COMMITTED[*]}"
