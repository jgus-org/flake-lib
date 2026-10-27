#!/usr/bin/env -S nix shell nixpkgs#bash nixpkgs#git nixpkgs#jq nixpkgs#nix nixpkgs#coreutils --command bash

# Installs this repository's GitHub Actions workflows from the templates shipped by the
# newest flake-lib revision its declared input can reach, and advances the lock to that
# revision in the same commit: a workflow that tracks flake-lib N must not run the scripts of
# revision N+1, or the repository is green against a library nothing else locks.
#
# A template replaces its workflow wholesale. Every repository-owned knob is a constructor
# argument in flake.nix baked into the package the workflow invokes, so the workflow file
# carries no repository state worth rescuing.
#
# With no arguments this keeps installed workflows current; it never adds, removes, or renames
# one, because which workflows a repository has is the author's decision. `adopt <name>` is
# how a repository joins that set, and it is the only way: the author names the template, so
# the tool never guesses which publication model a repository wants.
#
# A workflow that follows the templates only does so because this runs for it on a schedule,
# so writing one writes update-workflows.yml, the workflow that runs this.

set -euo pipefail

FLAKE_ROOT="${FLAKE_ROOT:-${PWD}}"
cd "${FLAKE_ROOT}"

TEMPLATE_DIR="templates/workflows"
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

node=$(jq -r '.nodes.root.inputs["flake-lib"] // ""' flake.lock)
[[ -n ${node} ]] || die "flake.lock has no flake-lib input, so there is no template to install"
locked_url=$(jq -r '.nodes.root.inputs["flake-lib"] as $n | .nodes[$n].locked
  | select(.type == "github") | "\(.owner)/\(.repo)/\(.rev)"' flake.lock)
[[ -n ${locked_url} ]] || die "flake.lock's flake-lib is not a github input, so its templates have no public revision to install from"

if ! nix flake update flake-lib; then
  die "advancing the flake-lib input failed"
fi
current_url=$(jq -r '.nodes.root.inputs["flake-lib"] as $n | .nodes[$n].locked
  | select(.type == "github") | "\(.owner)/\(.repo)/\(.rev)"' flake.lock)
[[ -n ${current_url} ]] || die "advancing flake-lib left a lock whose flake-lib input is no longer a github input"

flake_lib_src=$(nix flake metadata --no-write-lock-file --json "github:${current_url}" | jq -r .path)
if [[ ! -d "${flake_lib_src}/${TEMPLATE_DIR}" ]]; then
  die "flake-lib ${current_url} ships no ${TEMPLATE_DIR}, so the installed workflows cannot be refreshed from it"
fi

install_from_template() {
  local template="${1}" destination="${2}"
  # The template is the whole file: every repository-owned knob is a flake.nix
  # constructor argument baked into the invoked package, so nothing here is worth
  # rescuing from the file being replaced.
  cp "${template}" "${destination}"
}

carries_schedule() {
  grep -qE '^[[:space:]]*schedule:' "${1}"
}

declare -a installed=()
if [[ ${MODE} == adopt ]]; then
  template="${flake_lib_src}/${TEMPLATE_DIR}/${ADOPT_TARGET}"
  if [[ ! -s ${template} ]]; then
    available=$(cd "${flake_lib_src}/${TEMPLATE_DIR}" && printf '%s ' *.yml *.yaml 2>/dev/null || true)
    die "flake-lib ${current_url##*/} ships no ${TEMPLATE_DIR}/${ADOPT_TARGET}; it ships ${available}"
  fi
  destination="${WORKFLOW_DIR}/${ADOPT_TARGET}"
  mkdir -p "${WORKFLOW_DIR}"
  install_from_template "${template}" "${destination}"
  installed+=("${destination}")
  # A workflow flake-lib has no template for is invisible to every later refresh, and a
  # scheduled one keeps publishing beside the adopted template forever. Retiring it is the
  # author's decision, so it is named rather than removed. Whether a file schedules anything is
  # the author's intent and lives only in the file, which is the one place it can be read.
  others=()
  for other in "${WORKFLOW_DIR}"/*.yml "${WORKFLOW_DIR}"/*.yaml; do
    [[ -f ${other} && ${other} != "${destination}" ]] || continue
    [[ ${other} == "${REFRESHER_WORKFLOW}" ]] && continue
    if carries_schedule "${other}"; then
      others+=("${other}")
    fi
  done
  if ((${#others[@]} > 0)); then
    printf 'note: %s also carries a schedule, and a workflow flake-lib has no template for is never refreshed: %s\n' \
      "${MODE}" "${others[*]}"
  fi
else
  for destination in "${WORKFLOW_DIR}"/*.yml "${WORKFLOW_DIR}"/*.yaml; do
    [[ -e ${destination} ]] || continue
    template="${flake_lib_src}/${TEMPLATE_DIR}/${destination##*/}"
    [[ -f ${template} ]] || continue
    install_from_template "${template}" "${destination}"
    installed+=("${destination}")
  done
  if ((${#installed[@]} == 0)); then
    echo "no workflow here was installed from flake-lib's ${TEMPLATE_DIR}; only the input advances."
  fi
fi

# The update workflows advance the input as they publish, so a repository holding one without
# update-workflows.yml moves its pin while its workflow files freeze. Installing the schedule
# beside the workflow it refreshes is the only fix that does not depend on noticing: the
# installed update workflow already runs this tool, so a repository rolls onto the schedule
# from the run that rewrote its update workflow.
follows_templates=0
for installed_workflow in "${installed[@]}"; do
  case ${installed_workflow##*/} in
  update-version.yml | update-branches.yml) follows_templates=1 ;;
  esac
done
if ((follows_templates)) && [[ ! -e ${REFRESHER_WORKFLOW} ]]; then
  refresher_template="${flake_lib_src}/${TEMPLATE_DIR}/update-workflows.yml"
  [[ -s ${refresher_template} ]] ||
    die "flake-lib ${current_url##*/} ships no ${TEMPLATE_DIR}/update-workflows.yml, so the workflows written here have no schedule that rewrites them"
  install_from_template "${refresher_template}" "${REFRESHER_WORKFLOW}"
  installed+=("${REFRESHER_WORKFLOW}")
fi

branch=$(git symbolic-ref --quiet --short HEAD) ||
  die "the flake-lib update commit needs a branch to push to, but HEAD is detached"
base=$(git rev-parse HEAD)

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git add flake.lock "${installed[@]}"
if git diff --cached --quiet; then
  echo "flake-lib ${current_url} changed neither the installed workflows nor this flake's inputs."
  exit 0
fi
mapfile -t committed < <(git diff --cached --name-only)
# A template can be byte-identical to what is already installed, in which case the commit
# is the input advance alone and its subject should not claim otherwise.
if printf '%s\n' "${committed[@]}" | grep -qvxF flake.lock; then
  if [[ ${MODE} == adopt ]]; then
    subject="Adopt flake-lib's ${ADOPT_TARGET} at ${current_url##*/}"
  else
    subject="Update workflows from flake-lib ${current_url##*/}"
  fi
else
  subject="Advance flake-lib to ${current_url##*/}"
fi
git commit -q -m "${subject}"

push_ref HEAD "${branch}" "${base}" lease
echo "Committed ${#committed[@]} file(s) from flake-lib ${current_url}: ${committed[*]}"
