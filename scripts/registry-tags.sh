# shellcheck shell=bash

# Registry tag listing shared by the updater and the orchestrator. Source it and call
# `registry_tag_names`.
#
# Registries serve this from the OCI distribution API, which challenges an anonymous
# request with a bearer realm naming the service and the repository scope to pull with,
# so no registry-specific endpoint or credential is configured: the challenge answers
# all three. A registry that challenges with something else is not public-read.

REGISTRY_TAGS_PAGE_SIZE="${REGISTRY_TAGS_PAGE_SIZE:-100}"
REGISTRY_TAGS_MAX_PAGES="${REGISTRY_TAGS_MAX_PAGES:-100}"

# Splits an image reference into the host its /v2 API lives on and the repository path
# that host addresses. `docker.io` is a short name for the host Docker Hub serves its
# API on, and a repository it names without a namespace lives under `library/`.
registry_api_target() {
  local REFERENCE="${1}"
  REGISTRY_API_HOST="${REFERENCE%%/*}"
  REGISTRY_API_PATH="${REFERENCE#*/}"
  if [[ ${REGISTRY_API_HOST} == "docker.io" || ${REGISTRY_API_HOST} == "index.docker.io" ]]; then
    REGISTRY_API_HOST="registry-1.docker.io"
    if [[ ${REGISTRY_API_PATH} != */* ]]; then
      REGISTRY_API_PATH="library/${REGISTRY_API_PATH}"
    fi
  fi
  if [[ ${REGISTRY_API_PATH} == "${REGISTRY_API_HOST}" || -z ${REGISTRY_API_PATH} ]]; then
    echo "error: ${REFERENCE} names no repository" >&2
    return 1
  fi
}

# Exchanges a `www-authenticate` bearer challenge for a token that pulls this repository.
registry_bearer_token() {
  local CHALLENGE="${1}" REALM SERVICE SCOPE TOKEN
  local -a QUERY=()
  REALM=$(sed -nE 's/.*[Rr]ealm="([^"]*)".*/\1/p' <<<"${CHALLENGE}")
  SERVICE=$(sed -nE 's/.*[Ss]ervice="([^"]*)".*/\1/p' <<<"${CHALLENGE}")
  SCOPE=$(sed -nE 's/.*[Ss]cope="([^"]*)".*/\1/p' <<<"${CHALLENGE}")
  if [[ -z ${REALM} ]]; then
    echo "error: ${REGISTRY_API_HOST} challenges ${REGISTRY_API_PATH} with no bearer realm" >&2
    return 1
  fi
  [[ -z ${SERVICE} ]] || QUERY+=(--data-urlencode "service=${SERVICE}")
  [[ -z ${SCOPE} ]] || QUERY+=(--data-urlencode "scope=${SCOPE}")
  if ! TOKEN=$(curl -fsSL -G "${REALM}" "${QUERY[@]}" | jq -r '.token // .access_token // ""'); then
    echo "error: the bearer realm for ${REGISTRY_API_PATH} could not be reached" >&2
    return 1
  fi
  if [[ -z ${TOKEN} ]]; then
    echo "error: the bearer realm for ${REGISTRY_API_PATH} returned no token" >&2
    return 1
  fi
  printf '%s' "${TOKEN}"
}

# Prints every tag name a registry publishes for an image reference, one per line.
registry_tag_names() {
  local REFERENCE="${1}" BODY CHALLENGE CODE HEADER LINK NEXT PAGES=0 TOKEN
  local -a AUTH=()
  registry_api_target "${REFERENCE}" || return 1
  NEXT="https://${REGISTRY_API_HOST}/v2/${REGISTRY_API_PATH}/tags/list?n=${REGISTRY_TAGS_PAGE_SIZE}"
  while [[ -n ${NEXT} ]]; do
    if ((PAGES >= REGISTRY_TAGS_MAX_PAGES)); then
      echo "error: ${REGISTRY_API_PATH} lists past ${REGISTRY_TAGS_MAX_PAGES} pages, so its tags are not enumerable here" >&2
      return 1
    fi
    HEADER=$(mktemp)
    BODY=$(mktemp)
    CODE=$(curl -sS -o "${BODY}" -D "${HEADER}" -w '%{http_code}' \
      "${AUTH[@]}" "${NEXT}") || {
      rm -f "${HEADER}" "${BODY}"
      echo "error: ${REGISTRY_API_HOST} could not be queried for ${REGISTRY_API_PATH} tags" >&2
      return 1
    }
    if [[ ${CODE} == "401" || ${CODE} == "403" ]] && ((${#AUTH[@]} == 0)); then
      CHALLENGE=$(grep -iE '^www-authenticate:' "${HEADER}" | tr -d '\r')
      rm -f "${HEADER}" "${BODY}"
      if [[ ${CHALLENGE} != *[Bb]earer* ]]; then
        echo "error: ${REGISTRY_API_PATH} is not readable anonymously on ${REGISTRY_API_HOST}" >&2
        return 1
      fi
      if ! TOKEN=$(registry_bearer_token "${CHALLENGE#*:}"); then
        return 1
      fi
      AUTH=(-H "Authorization: Bearer ${TOKEN}")
      continue
    fi
    if [[ ${CODE} != "200" ]]; then
      rm -f "${HEADER}" "${BODY}"
      echo "error: ${REGISTRY_API_HOST} returned ${CODE} for the tags of ${REGISTRY_API_PATH}" >&2
      return 1
    fi
    jq -r '.tags[]? // empty' "${BODY}"
    LINK=$(grep -iE '^link:' "${HEADER}" | tr -d '\r')
    NEXT=""
    if [[ ${LINK} == *'rel="next"'* || ${LINK} == *'rel=next'* ]]; then
      NEXT=$(sed -nE 's/.*<[[:space:]]*([^;>]+)[[:space:]]*>.*/\1/Ip' <<<"${LINK}")
      case ${NEXT} in
      http://* | https://*) ;;
      /*) NEXT="https://${REGISTRY_API_HOST}${NEXT}" ;;
      esac
    fi
    rm -f "${HEADER}" "${BODY}"
    PAGES=$((PAGES + 1))
  done
}
