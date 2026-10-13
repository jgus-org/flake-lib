#!/usr/bin/env -S nix shell nixpkgs#bash nixpkgs#git nixpkgs#jq nixpkgs#gnused nixpkgs#nix nixpkgs#coreutils --command bash

# Installs this repository's GitHub Actions workflows from the templates shipped by the
# flake-lib revision its lock names, then advances that lock, so a repository's CI moves
# with the library it locks instead of drifting from it. Both halves land in one commit:
# a workflow that tracks flake-lib N would otherwise refresh the scripts it invokes from
# revision N as well, and the run would be green against a library nobody else uses.
#
# Which workflows a repository has is the author's decision; this keeps the installed ones
# current and never adds, removes, or renames one. A workflow whose name flake-lib has no
# template for is left exactly as it is.
#
# A workflow is read when its run starts, so what is written here takes effect for the
# next run. The commit is reported as `sha` so the run that made it can check that commit
# out for its remaining jobs, which is what lets a workflow update itself: a push made
# with GITHUB_TOKEN triggers no run, so nothing else would pick the new file up in time.
#
# Values a repository owns rather than flake-lib are carried across the update instead of
# being reset to the template's default; see CARRIED_ENV_KEYS.

set -euo pipefail

FLAKE_ROOT="${FLAKE_ROOT:-${PWD}}"
cd "${FLAKE_ROOT}"

TEMPLATE_DIR="templates/workflows"
WORKFLOW_DIR=".github/workflows"
CARRIED_ENV_KEYS=(MINIMUM_TRACKING_VERSION BUILD_ATTR)

die() {
  printf 'error: %s\n' "${1}" >&2
  exit 1
}

# shellcheck source=/dev/null
source "${GIT_PUSH_LIB:?required env var}"

node=$(jq -r '.nodes.root.inputs["flake-lib"] // ""' flake.lock)
[[ -n "${node}" ]] || die "flake.lock has no flake-lib input, so there is no template to install"
locked_url=$(jq -r '.nodes.root.inputs["flake-lib"] as $n | .nodes[$n].locked
  | select(.type == "github") | "\(.owner)/\(.repo)/\(.rev)"' flake.lock)
[[ -n "${locked_url}" ]] || die "flake.lock's flake-lib is not a github input, so its templates have no public revision to install from"

if ! nix flake update flake-lib; then
  die "advancing the flake-lib input failed"
fi
current_url=$(jq -r '.nodes.root.inputs["flake-lib"] as $n | .nodes[$n].locked
  | select(.type == "github") | "\(.owner)/\(.repo)/\(.rev)"' flake.lock)
[[ -n "${current_url}" ]] || die "advancing flake-lib left a lock whose flake-lib input is no longer a github input"

if [[ "${locked_url}" == "${current_url}" ]]; then
  echo "flake-lib is already at its newest revision; no workflow to update."
  exit 0
fi

flake_lib_src=$(nix flake metadata --no-write-lock-file --json "github:${current_url}" | jq -r .path)
if [[ ! -d "${flake_lib_src}/${TEMPLATE_DIR}" ]]; then
  die "flake-lib ${current_url} ships no ${TEMPLATE_DIR}, so the installed workflows cannot be refreshed from it"
fi

# The repository's own values, read from the file just before it is replaced.
carried_values() {
  local destination="${1}" key value
  for key in "${CARRIED_ENV_KEYS[@]}"; do
    value=$(sed -nE "s/^[[:space:]]*${key}: \"(.*)\"[[:space:]]*\$/\1/p" "${destination}" | head -1)
    [[ -n "${value}" ]] || continue
    printf '%s\t%s\n' "${key}" "${value}"
  done
}

declare -a installed=()
for destination in "${WORKFLOW_DIR}"/*.yml "${WORKFLOW_DIR}"/*.yaml; do
  [[ -e "${destination}" ]] || continue
  template="${flake_lib_src}/${TEMPLATE_DIR}/${destination##*/}"
  [[ -f "${template}" ]] || continue
  carried=$(carried_values "${destination}")
  cp "${template}" "${destination}"
  while IFS=$'\t' read -r key value; do
    [[ -n "${key}" ]] || continue
    sed -i -E "s|^([[:space:]]*)${key}: \"[^\"]*\"|\1${key}: \"${value}\"|" "${destination}"
  done <<<"${carried}"
  installed+=("${destination}")
done
if (( ${#installed[@]} == 0 )); then
  echo "no workflow here was installed from flake-lib's ${TEMPLATE_DIR}; only the input advances."
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
  subject="Update workflows from flake-lib ${current_url##*/}"
else
  subject="Advance flake-lib to ${current_url##*/}"
fi
git commit -q -m "${subject}"
sha=$(git rev-parse HEAD)

push_ref HEAD "${branch}" "${base}" lease
echo "Committed ${#committed[@]} file(s) from flake-lib ${current_url}: ${committed[*]}"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'sha=%s\n' "${sha}" >>"${GITHUB_OUTPUT}"
fi
