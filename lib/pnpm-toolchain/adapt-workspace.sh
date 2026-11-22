#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${workspaceDir:-}" ]]; then
  cd "${workspaceDir}"
fi

MANIFEST="package.json"
WORKSPACE="pnpm-workspace.yaml"

[[ -f "${MANIFEST}" ]] || {
  echo "adapt-workspace: ${PWD}/${MANIFEST} not found" >&2
  exit 1
}

if [[ -f "${WORKSPACE}" ]] && grep -Eq '^(overrides|onlyBuiltDependencies):' "${WORKSPACE}"; then
  echo "adapt-workspace: ${PWD}/${WORKSPACE} already declares these settings at the top level" >&2
  exit 1
fi

OVERRIDES="$(jq -r '(.pnpm.overrides // {}) | to_entries[] | "  \(.key | tojson): \(.value | tojson)"' "${MANIFEST}")"
ONLY_BUILT="$(jq -r '(.pnpm.onlyBuiltDependencies // [])[] | "  - \(tojson)"' "${MANIFEST}")"

if [[ -z "${OVERRIDES}" && -z "${ONLY_BUILT}" ]]; then
  if jq -e 'has("pnpm")' "${MANIFEST}" >/dev/null; then
    echo "adapt-workspace: ${MANIFEST} declares a pnpm field carrying neither overrides nor onlyBuiltDependencies" >&2
    exit 1
  fi
elif [[ -f "${WORKSPACE}" ]]; then
  {
    cat "${WORKSPACE}"
    if [[ -n "${OVERRIDES}" ]]; then
      printf 'overrides:\n%s\n' "${OVERRIDES}"
    fi
    if [[ -n "${ONLY_BUILT}" ]]; then
      printf 'onlyBuiltDependencies:\n%s\n' "${ONLY_BUILT}"
    fi
  } >"${WORKSPACE}.new"
  mv "${WORKSPACE}.new" "${WORKSPACE}"
else
  {
    if [[ -n "${OVERRIDES}" ]]; then
      printf 'overrides:\n%s\n' "${OVERRIDES}"
    fi
    if [[ -n "${ONLY_BUILT}" ]]; then
      printf 'onlyBuiltDependencies:\n%s\n' "${ONLY_BUILT}"
    fi
  } >"${WORKSPACE}"
fi

jq --arg manager "pnpm@${targetVersion}" '(.packageManager = $manager) | del(.pnpm)' "${MANIFEST}" >"${MANIFEST}.new"
mv "${MANIFEST}.new" "${MANIFEST}"

jq -e --arg manager "pnpm@${targetVersion}" '(.packageManager == $manager) and (has("pnpm") | not)' "${MANIFEST}" >/dev/null
