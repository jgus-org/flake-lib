# shellcheck shell=bash

# Push helper shared by the scripts that publish commits into a repository other
# processes may be updating at the same time. Source it and call `push_ref`.

PUSH_MAX_ATTEMPTS="${PUSH_MAX_ATTEMPTS:-5}"
PUSH_RETRY_DELAY_SECONDS="${PUSH_RETRY_DELAY_SECONDS:-5}"
if [[ ! ${PUSH_MAX_ATTEMPTS} =~ ^[1-9][0-9]*$ ]]; then
  echo "error: push retry attempts must be a positive integer" >&2
  exit 2
fi

remote_ref_sha() {
  local ref="${1}" output
  if ! output=$(git ls-remote --heads origin "refs/heads/${ref}"); then
    return 1
  fi
  printf '%s\n' "${output%%[[:space:]]*}"
}

# actions/checkout configures the run's own credential for the server host, and extraHeader
# is a multivar: a second key that matches the same request puts two Authorization headers on
# the wire, and the server refuses the request rather than choose. So the installed value has
# to be replaced for the push, not layered over, and put back afterwards so the read paths
# keep the run's credential. The local config file is restored from a copy because it is the
# only way to put a multivar back exactly, comments and ordering included.
PUSH_CONFIG_PATH=''
PUSH_CONFIG_BACKUP=''

push_credential_key() {
  local url="${1}" scheme="${1%%://*}" authority="${1#*://}"
  authority="${authority%%/*}"
  printf 'http.%s://%s/.extraheader' "${scheme}" "${authority#*@}"
}

push_credential_install() {
  local token="${1}" url key
  PUSH_CREDENTIAL_INSTALLED=false
  [[ -n ${token} ]] || return 0
  url=$(git remote get-url origin) || return 1
  [[ ${url} == https://* ]] || return 0

  PUSH_CONFIG_PATH="$(git rev-parse --absolute-git-dir)/config"
  PUSH_CONFIG_BACKUP=$(mktemp) || return 1
  cp "${PUSH_CONFIG_PATH}" "${PUSH_CONFIG_BACKUP}" || return 1
  PUSH_CREDENTIAL_INSTALLED=true

  while IFS= read -r key; do
    git config --local --unset-all "${key}"
  done < <(git config --local --name-only --get-regexp '^http\..*\.extraheader$')

  git config --local "$(push_credential_key "${url}")" \
    "AUTHORIZATION: basic $(printf 'x-access-token:%s' "${token}" | base64 | tr -d '\n')"
}

push_credential_uninstall() {
  [[ ${PUSH_CREDENTIAL_INSTALLED:-false} == true ]] || return 0
  cp "${PUSH_CONFIG_BACKUP}" "${PUSH_CONFIG_PATH}"
  rm -f "${PUSH_CONFIG_BACKUP}"
  PUSH_CREDENTIAL_INSTALLED=false
}

push_ref() {
  local source="${1}" ref="${2}" expected_sha="${3}" mode="${4}" result=0
  push_credential_install "${GIT_PUSH_TOKEN:-}" || return 1
  push_with_retries "${source}" "${ref}" "${expected_sha}" "${mode}" || result=$?
  push_credential_uninstall
  return "${result}"
}

# A failed push can be ambiguous: the server may have updated the ref before
# returning an error. Re-read the remote before retrying. Treat the desired SHA
# as success, retry only while the ref remains at the expected SHA, and never
# overwrite a genuinely different concurrent update.
push_with_retries() {
  local source="${1}" ref="${2}" expected_sha="${3}" mode="${4}"
  local attempt desired_sha remote_sha="" query_exit=0
  desired_sha=$(git rev-parse --verify "${source}^{commit}")

  for ((attempt = 1; attempt <= PUSH_MAX_ATTEMPTS; attempt++)); do
    if [[ ${mode} == lease ]]; then
      if git push --force-with-lease="refs/heads/${ref}:${expected_sha}" --quiet origin "${desired_sha}:refs/heads/${ref}"; then
        return 0
      fi
    elif git push --quiet origin "${desired_sha}:refs/heads/${ref}"; then
      return 0
    fi

    query_exit=0
    remote_sha=$(remote_ref_sha "${ref}") || query_exit=$?
    if ((query_exit == 0)); then
      if [[ ${remote_sha} == "${desired_sha}" ]]; then
        echo "  ${ref} reached ${desired_sha:0:8} despite the push error; continuing."
        return 0
      fi
      if [[ ${remote_sha} != "${expected_sha}" ]]; then
        echo "error: ${ref} changed concurrently (expected ${expected_sha:-absent}, found ${remote_sha:-absent}); refusing to overwrite it" >&2
        return 1
      fi
    fi

    if ((attempt < PUSH_MAX_ATTEMPTS)); then
      echo "  push of ${ref} failed (attempt ${attempt}/${PUSH_MAX_ATTEMPTS}); retrying in ${PUSH_RETRY_DELAY_SECONDS}s..." >&2
      sleep "${PUSH_RETRY_DELAY_SECONDS}"
    fi
  done
  echo "error: push of ${ref} failed after ${PUSH_MAX_ATTEMPTS} attempts" >&2
  return 1
}
