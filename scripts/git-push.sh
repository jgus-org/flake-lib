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

# The `.git` form of an HTTPS remote addresses the same repository and is not covered by a
# key scoped to the URL without it, which is the form actions/checkout configures.
push_url() {
  local url
  url=$(git remote get-url origin) || return 1
  case "${url}" in
    https://*) ;;
    *)
      printf 'origin\n'
      return 0
      ;;
  esac
  url="${url%/}"
  [[ "${url}" == *.git ]] || url="${url}.git"
  printf '%s\n' "${url}"
}

# actions/checkout leaves the run's own credential in git config under a key scoped to the
# repository URL. `git -c` cannot displace that key: extraHeader is a multivar, so git puts
# both values on the wire and the server refuses the request with "Duplicate header:
# Authorization". A key scoped to the `.git` URL is the only one that matches a push there,
# so the run credential cannot ride along with ours and nothing is written to the repository.
push_credential_args() {
  local token="${1}" url
  [[ -n "${token}" ]] || return 0
  url=$(push_url) || return 0
  [[ "${url}" == https://* ]] || return 0
  printf '%s\n%s\n' '-c' "http.${url}/.extraheader=AUTHORIZATION: basic $(printf 'x-access-token:%s' "${token}" | base64 | tr -d '\n')"
}

# A failed push can be ambiguous: the server may have updated the ref before
# returning an error. Re-read the remote before retrying. Treat the desired SHA
# as success, retry only while the ref remains at the expected SHA, and never
# overwrite a genuinely different concurrent update.
push_ref() {
  local source="${1}" ref="${2}" expected_sha="${3}" mode="${4}"
  local attempt desired_sha remote_sha="" query_exit=0 target
  desired_sha=$(git rev-parse --verify "${source}^{commit}")
  target=$(push_url) || target=origin
  local -a credential=()
  while IFS= read -r -d '' arg; do credential+=("${arg}"); done < <(push_credential_args "${GIT_PUSH_TOKEN:-}")

  for ((attempt = 1; attempt <= PUSH_MAX_ATTEMPTS; attempt++)); do
    if [[ "${mode}" == lease ]]; then
      if git "${credential[@]}" push --force-with-lease="refs/heads/${ref}:${expected_sha}" --quiet "${target}" "${desired_sha}:refs/heads/${ref}"; then
        return 0
      fi
    elif git "${credential[@]}" push --quiet "${target}" "${desired_sha}:refs/heads/${ref}"; then
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
