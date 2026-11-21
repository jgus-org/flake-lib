# shellcheck shell=bash

# Push helper shared by the scripts that publish commits into a repository other processes may be updating at the same time. Source it and call `push_ref`.

PUSH_MAX_ATTEMPTS="${PUSH_MAX_ATTEMPTS:-5}"
PUSH_RETRY_DELAY_SECONDS="${PUSH_RETRY_DELAY_SECONDS:-5}"
if [[ ! ${PUSH_MAX_ATTEMPTS} =~ ^[1-9][0-9]*$ ]]; then
  echo "error: push retry attempts must be a positive integer" >&2
  exit 2
fi

remote_ref_sha() {
  local REF="${1}" OUTPUT
  if ! OUTPUT=$(git ls-remote --heads origin "refs/heads/${REF}"); then
    return 1
  fi
  printf '%s\n' "${OUTPUT%%[[:space:]]*}"
}

push_ref() {
  local SOURCE="${1}" REF="${2}" EXPECTED_SHA="${3}" MODE="${4}"
  push_with_retries "${SOURCE}" "${REF}" "${EXPECTED_SHA}" "${MODE}"
}

# A failed push can be ambiguous: the server may have updated the ref before returning an error. Re-read the remote before retrying. Treat the desired SHA as success, retry only while the ref remains at the expected SHA, and never overwrite a genuinely different concurrent update.
push_with_retries() {
  local SOURCE="${1}" REF="${2}" EXPECTED_SHA="${3}" MODE="${4}"
  local ATTEMPT DESIRED_SHA REMOTE_SHA="" QUERY_EXIT=0
  DESIRED_SHA=$(git rev-parse --verify "${SOURCE}^{commit}")

  for ((ATTEMPT = 1; ATTEMPT <= PUSH_MAX_ATTEMPTS; ATTEMPT++)); do
    if [[ ${MODE} == lease ]]; then
      if git push --force-with-lease="refs/heads/${REF}:${EXPECTED_SHA}" --quiet origin "${DESIRED_SHA}:refs/heads/${REF}"; then
        return 0
      fi
    elif git push --quiet origin "${DESIRED_SHA}:refs/heads/${REF}"; then
      return 0
    fi

    QUERY_EXIT=0
    REMOTE_SHA=$(remote_ref_sha "${REF}") || QUERY_EXIT=${?}
    if ((QUERY_EXIT == 0)); then
      if [[ ${REMOTE_SHA} == "${DESIRED_SHA}" ]]; then
        echo "  ${REF} reached ${DESIRED_SHA:0:8} despite the push error. Continuing."
        return 0
      fi
      if [[ ${REMOTE_SHA} != "${EXPECTED_SHA}" ]]; then
        echo "error: ${REF} changed concurrently (expected ${EXPECTED_SHA:-absent}, found ${REMOTE_SHA:-absent}). Refusing to overwrite it." >&2
        return 1
      fi
    fi

    if ((ATTEMPT < PUSH_MAX_ATTEMPTS)); then
      echo "  push of ${REF} failed (attempt ${ATTEMPT}/${PUSH_MAX_ATTEMPTS}). Retrying in ${PUSH_RETRY_DELAY_SECONDS}s..." >&2
      sleep "${PUSH_RETRY_DELAY_SECONDS}"
    fi
  done
  echo "error: push of ${REF} failed after ${PUSH_MAX_ATTEMPTS} attempts" >&2
  return 1
}
