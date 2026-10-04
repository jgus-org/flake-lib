#!/usr/bin/env bash

set -euo pipefail

OCI_TEST_ROOT=$(mktemp -d)
trap 'rm -rf "${OCI_TEST_ROOT}"' EXIT
OCI_LOG="${OCI_TEST_ROOT}/skopeo.log"
OCI_EVALUATION_LOG="${OCI_TEST_ROOT}/evaluate.log"
OCI_FIRST_DIGEST="sha256:$(printf 'a%.0s' {1..64})"
OCI_SECOND_DIGEST="sha256:$(printf 'b%.0s' {1..64})"
OCI_SETTINGS="${OCI_TEST_SETTINGS}"
OCI_FINGERPRINT="${OCI_TEST_FINGERPRINT}"
OCI_METADATA=$(jq -cn --arg DIGEST "${OCI_FIRST_DIGEST}" '{Digest:$DIGEST,Os:"linux",Architecture:"amd64"}')
printf '%s\n' '{' '  imageDigest = "";' '  imageHash = "";' '  archiveFingerprint = "";' '}' > "${OCI_TEST_ROOT}/pin.nix"
printf '%s\n' '{"fixture":"reviewed-feature-lock"}' > "${OCI_TEST_ROOT}/flake.lock"
cp "${OCI_TEST_ROOT}/flake.lock" "${OCI_TEST_ROOT}/original.lock"

run_oci_update() {
  local -a OCI_ARGS=()
  if [[ -n "${1:-}" ]]; then
    OCI_ARGS+=("${1}")
  fi
  FLAKE_ROOT="${OCI_TEST_ROOT}" \
    SOURCE_TYPE=oci \
    OCI_SETTINGS="${OCI_SETTINGS}" \
    OCI_FINGERPRINT="${OCI_FINGERPRINT}" \
    OCI_SKOPEO="${OCI_SELECTED_SKOPEO:-${OCI_TEST_SKOPEO}}" \
    REGISTRY_AUTH_FILE=/fixture-must-not-read \
    TEST_OCI_METADATA="${OCI_METADATA}" \
    TEST_OCI_LOG="${OCI_LOG}" \
    TEST_OCI_EVALUATION_LOG="${OCI_EVALUATION_LOG}" \
    TEST_OCI_FAIL="${OCI_FAIL:-}" \
    BUILD_ATTR=image \
    HASH_MODE=prefetch \
    EXTRA_HASHES='[]' \
    PIN_HASHES='[]' \
    VERIFICATION="${OCI_VERIFICATION:-evaluate}" \
    SIBLINGS='[]' \
    bash "${UPDATE_VERSION}" "${OCI_ARGS[@]}"
}

run_oci_update
grep -Fq "imageDigest = \"${OCI_FIRST_DIGEST}\";" "${OCI_TEST_ROOT}/pin.nix"
grep -Fq "imageHash = \"${OCI_TEST_HASH}\";" "${OCI_TEST_ROOT}/pin.nix"
grep -Fq "archiveFingerprint = \"${OCI_TEST_FINGERPRINT}\";" "${OCI_TEST_ROOT}/pin.nix"
cmp "${OCI_TEST_ROOT}/flake.lock" "${OCI_TEST_ROOT}/original.lock"
cp "${OCI_TEST_ROOT}/pin.nix" "${OCI_TEST_ROOT}/original.pin"
grep -Fqx 'inspect os=linux arch=amd64 variant= source=docker://registry.example/image:latest' "${OCI_LOG}"
grep -Fqx "copy os=linux arch=amd64 variant= source=docker://registry.example/image@${OCI_FIRST_DIGEST}" "${OCI_LOG}"
[[ "$(sha256sum "${OCI_TEST_IMAGE}" | cut -d' ' -f1)" == "$(printf '%s\n' 'source=docker://registry.example/image@'"${OCI_FIRST_DIGEST}" 'os=linux' 'arch=amd64' 'variant=' 'reference=example/image:latest' | sha256sum | cut -d' ' -f1)" ]]

OCI_NOOP=$(run_oci_update)
grep -Fq 'Already up to date' <<<"${OCI_NOOP}"
[[ "$(grep -c '^copy ' "${OCI_LOG}")" -eq 1 ]]
[[ "$(wc -l < "${OCI_EVALUATION_LOG}")" -eq 2 ]]
cmp "${OCI_TEST_ROOT}/pin.nix" "${OCI_TEST_ROOT}/original.pin"
cmp "${OCI_TEST_ROOT}/flake.lock" "${OCI_TEST_ROOT}/original.lock"

OCI_METADATA=$(jq -cn --arg DIGEST "${OCI_SECOND_DIGEST}" '{Digest:$DIGEST,Os:"linux",Architecture:"amd64"}')
run_oci_update
grep -Fq "imageDigest = \"${OCI_SECOND_DIGEST}\";" "${OCI_TEST_ROOT}/pin.nix"
grep -Fqx "copy os=linux arch=amd64 variant= source=docker://registry.example/image@${OCI_SECOND_DIGEST}" "${OCI_LOG}"

cp "${OCI_TEST_ROOT}/original.pin" "${OCI_TEST_ROOT}/pin.nix"
run_oci_update "${OCI_SECOND_DIGEST}"
grep -Fqx "inspect os=linux arch=amd64 variant= source=docker://registry.example/image@${OCI_SECOND_DIGEST}" "${OCI_LOG}"
grep -Fq "imageDigest = \"${OCI_SECOND_DIGEST}\";" "${OCI_TEST_ROOT}/pin.nix"

cp "${OCI_TEST_ROOT}/original.pin" "${OCI_TEST_ROOT}/pin.nix"
OCI_METADATA=$(jq -cn --arg DIGEST "${OCI_FIRST_DIGEST}" '{Digest:$DIGEST,Os:"linux",Architecture:"amd64"}')
OCI_SETTINGS=$(jq -c '.finalImageTag = "renamed"' <<<"${OCI_TEST_SETTINGS}")
OCI_FINGERPRINT=$(printf 'c%.0s' {1..64})
run_oci_update
[[ "$(nix eval --raw --file "${OCI_TEST_ROOT}/pin.nix" imageHash)" != "${OCI_TEST_HASH}" ]]
grep -Fq "archiveFingerprint = \"${OCI_FINGERPRINT}\";" "${OCI_TEST_ROOT}/pin.nix"

OCI_SETTINGS=$(jq -c '.os = "windows" | .arch = "arm64" | .variant = "v8"' <<<"${OCI_TEST_SETTINGS}")
OCI_SELECTED_SKOPEO="${OCI_TEST_ARM_SKOPEO}"
OCI_FINGERPRINT=$(printf 'd%.0s' {1..64})
OCI_METADATA=$(jq -cn --arg DIGEST "${OCI_FIRST_DIGEST}" '{Digest:$DIGEST,Os:"windows",Architecture:"arm64"}')
run_oci_update
grep -Fqx "copy os=windows arch=arm64 variant=v8 source=docker://registry.example/image@${OCI_FIRST_DIGEST}" "${OCI_LOG}"

OCI_SETTINGS="${OCI_TEST_SETTINGS}"
OCI_SELECTED_SKOPEO="${OCI_TEST_SKOPEO}"
OCI_FINGERPRINT="${OCI_TEST_FINGERPRINT}"
OCI_METADATA=$(jq -cn --arg DIGEST "${OCI_SECOND_DIGEST}" '{Digest:$DIGEST,Os:"linux",Architecture:"amd64"}')
for OCI_LOCK_STATE in existing absent; do
  for OCI_FAIL in inspect copy hash store lock evaluate build; do
    cp "${OCI_TEST_ROOT}/original.pin" "${OCI_TEST_ROOT}/pin.nix"
    if [[ "${OCI_LOCK_STATE}" == existing ]]; then
      cp "${OCI_TEST_ROOT}/original.lock" "${OCI_TEST_ROOT}/flake.lock"
    else
      rm -f "${OCI_TEST_ROOT}/flake.lock"
    fi
    OCI_VERIFICATION=evaluate
    if [[ "${OCI_FAIL}" == build ]]; then
      OCI_VERIFICATION=build
    fi
    if run_oci_update > "${OCI_TEST_ROOT}/failure.log" 2>&1; then
      echo "error: OCI failure fixture succeeded" >&2
      exit 1
    fi
    cmp "${OCI_TEST_ROOT}/pin.nix" "${OCI_TEST_ROOT}/original.pin"
    if [[ "${OCI_LOCK_STATE}" == existing ]]; then
      cmp "${OCI_TEST_ROOT}/flake.lock" "${OCI_TEST_ROOT}/original.lock"
    else
      [[ ! -e "${OCI_TEST_ROOT}/flake.lock" ]]
    fi
  done
done
OCI_FAIL=""
OCI_VERIFICATION=evaluate
cp "${OCI_TEST_ROOT}/original.pin" "${OCI_TEST_ROOT}/pin.nix"
OCI_METADATA=$(jq -cn --arg DIGEST "${OCI_FIRST_DIGEST}" '{Digest:$DIGEST,Os:"linux",Architecture:"amd64"}')
if run_oci_update "${OCI_SECOND_DIGEST}" > "${OCI_TEST_ROOT}/failure.log" 2>&1; then
  echo "error: OCI mismatched digest fixture succeeded" >&2
  exit 1
fi
cmp "${OCI_TEST_ROOT}/pin.nix" "${OCI_TEST_ROOT}/original.pin"
OCI_METADATA=$(jq -cn --arg DIGEST "${OCI_FIRST_DIGEST}" '{Digest:$DIGEST,Os:"windows",Architecture:"arm64"}')
if run_oci_update > "${OCI_TEST_ROOT}/failure.log" 2>&1; then
  echo "error: OCI mismatched platform fixture succeeded" >&2
  exit 1
fi
cmp "${OCI_TEST_ROOT}/pin.nix" "${OCI_TEST_ROOT}/original.pin"
if run_oci_update 'other.example/image:latest' > "${OCI_TEST_ROOT}/failure.log" 2>&1; then
  echo "error: OCI foreign reference fixture succeeded" >&2
  exit 1
fi
cmp "${OCI_TEST_ROOT}/pin.nix" "${OCI_TEST_ROOT}/original.pin"
