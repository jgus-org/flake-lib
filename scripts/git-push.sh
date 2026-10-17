# shellcheck shell=bash

# Push helper shared by the scripts that publish commits into a repository other
# processes may be updating at the same time. Source it and call `push_ref`.

PUSH_MAX_ATTEMPTS="${PUSH_MAX_ATTEMPTS:-5}"
PUSH_RETRY_DELAY_SECONDS="${PUSH_RETRY_DELAY_SECONDS:-5}"
if [[ ! "${PUSH_MAX_ATTEMPTS}" =~ ^[1-9][0-9]*$ ]]; then
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

# actions/checkout leaves the run's own credential in the repository config. A push that
# must be made as another actor replaces the key holding it for that one invocation, so
# nothing is written to the repository and the read paths keep the run's credential.
push_credential_args() {
  local token="${1}" key
  [[ -n "${token}" ]] || return 0
  key=$(git config --local --name-only --get-regexp '^http\..*\.extraheader$' | head -n1)
  [[ -n "${key}" ]] || key="http.$(git remote get-url origin).extraheader"
  printf '%s\n%s\n' '-c' "${key}=AUTHORIZATION: basic $(printf 'x-access-token:%s' "${token}" | base64 | tr -d '\n')"
}

# A failed push can be ambiguous: the server may have updated the ref before
# returning an error. Re-read the remote before retrying. Treat the desired SHA
# as success, retry only while the ref remains at the expected SHA, and never
# overwrite a genuinely different concurrent update.
push_ref() {
  local source="${1}" ref="${2}" expected_sha="${3}" mode="${4}"
  local attempt desired_sha remote_sha="" query_exit=0
  desired_sha=$(git rev-parse --verify "${source}^{commit}")
  local -a credential=()
  while IFS= read -r -d '' arg; do credential+=("${arg}"); done < <(push_credential_args "${GIT_PUSH_TOKEN:-}")

  for ((attempt = 1; attempt <= PUSH_MAX_ATTEMPTS; attempt++)); do
    if [[ "${mode}" == lease ]]; then
      if git "${credential[@]}" push --force-with-lease="refs/heads/${ref}:${expected_sha}" --quiet origin "${desired_sha}:refs/heads/${ref}"; then
        return 0
      fi
    elif git "${credential[@]}" push --quiet origin "${desired_sha}:refs/heads/${ref}"; then
      return 0
    fi

    query_exit=0
    remote_sha=$(remote_ref_sha "${ref}") || query_exit=$?
    if (( query_exit == 0 )); then
      if [[ "${remote_sha}" == "${desired_sha}" ]]; then
        echo "  ${ref} reached ${desired_sha:0:8} despite the push error; continuing."
        return 0
      fi
      if [[ "${remote_sha}" != "${expected_sha}" ]]; then
        echo "error: ${ref} changed concurrently (expected ${expected_sha:-absent}, found ${remote_sha:-absent}); refusing to overwrite it" >&2
        return 1
      fi
    fi

    if (( attempt < PUSH_MAX_ATTEMPTS )); then
      echo "  push of ${ref} failed (attempt ${attempt}/${PUSH_MAX_ATTEMPTS}); retrying in ${PUSH_RETRY_DELAY_SECONDS}s..." >&2
      sleep "${PUSH_RETRY_DELAY_SECONDS}"
    fi
  done
  echo "error: push of ${ref} failed after ${PUSH_MAX_ATTEMPTS} attempts" >&2
  return 1
}
