#!/usr/bin/env bash
set -euo pipefail

DIGEST="sha256:$(printf 'a%.0s' {1..64})"
ARM_DIGEST="sha256:$(printf 'b%.0s' {1..64})"
case "${*}" in
  *'inspect --raw '*)
    case "${TEST_OCI_MANIFEST:-index}" in
      index)
        jq -n --arg DIGEST "${DIGEST}" --arg ARM_DIGEST "${ARM_DIGEST}" '{manifests:[{digest:$DIGEST,platform:{os:"linux",architecture:"amd64"}},{digest:$ARM_DIGEST,platform:{os:"linux",architecture:"arm64",variant:"v8"}}]}'
        ;;
      single) printf '%s' '{"schemaVersion":2}' ;;
      ambiguous)
        jq -n --arg DIGEST "${DIGEST}" '{manifests:[{digest:$DIGEST,platform:{os:"linux",architecture:"amd64"}},{digest:$DIGEST,platform:{os:"linux",architecture:"amd64"}}]}'
        ;;
    esac
    ;;
  *'inspect --no-tags '*)
    ARCH=amd64
    if [[ "${*}" == *"${ARM_DIGEST}"* ]]; then
      ARCH=arm64
      DIGEST="${ARM_DIGEST}"
    fi
    if [[ "${TEST_OCI_FAIL:-}" == platform ]]; then
      ARCH=wrong
    elif [[ "${TEST_OCI_FAIL:-}" == digest ]]; then
      DIGEST="${ARM_DIGEST}"
    fi
    jq -n --arg DIGEST "${DIGEST}" --arg ARCH "${ARCH}" '{Digest:$DIGEST,Os:"linux",Architecture:$ARCH}'
    ;;
  *'inspect --config '*)
    jq -n '{variant:"v8"}'
    ;;
  *' copy '*)
    [[ "${*}" == *'--preserve-digests'* && "${*}" == *'docker://registry.example/image@sha256:'* ]]
    [[ "${TEST_OCI_FAIL:-}" != copy ]]
    DESTINATION="${*: -1}"
    mkdir "${DESTINATION#dir://}"
    printf '%s\n' fixture > "${DESTINATION#dir://}/fixture"
    printf '%s\n' copied >> "${TEST_OCI_COPY_LOG}"
    ;;
  *) exit 1 ;;
esac
