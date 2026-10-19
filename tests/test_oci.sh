#!/usr/bin/env bash
set -euo pipefail

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "${TEST_ROOT}"' EXIT
export FLAKE_ROOT="${TEST_ROOT}" SOURCE_TYPE=oci BUILD_ATTR=image
export SIBLINGS='[]' VERIFICATION=evaluate
export OCI_SETTINGS='{"imageName":"registry.example/image","tag":"stable","os":"linux","arch":"amd64","variant":""}'
export TEST_OCI_COPY_LOG="${TEST_ROOT}/copy.log" TEST_OCI_EVALUATION_LOG="${TEST_ROOT}/eval.log" TEST_OCI_INSPECT_LOG="${TEST_ROOT}/inspect.log"
export OCI_SKOPEO="${TEST_ROOT}/skopeo"
sed "1c#!${TEST_BASH}/bin/bash" "${OCI_SKOPEO_SOURCE}" >"${OCI_SKOPEO}"
chmod +x "${OCI_SKOPEO}"

write_empty_pin() {
  printf '%s\n' '{ imageDigest = ""; imageHash = ""; }' >"${TEST_ROOT}/pin.nix"
}

write_empty_pin
printf '%s\n' '{"dependency":"old"}' >"${TEST_ROOT}/flake.lock"
bash "${UPDATE_VERSION}"
grep -Fq "imageDigest = \"sha256:$(printf 'a%.0s' {1..64})\";" "${TEST_ROOT}/pin.nix"
grep -Eq 'imageHash = "sha256-[A-Za-z0-9+/]{43}=";' "${TEST_ROOT}/pin.nix"
! grep -Fq 'version = ' "${TEST_ROOT}/pin.nix"
grep -Fqx "docker://registry.example/image:stable" "${TEST_OCI_INSPECT_LOG}"
cp "${TEST_ROOT}/pin.nix" "${TEST_ROOT}/expected-pin.nix"
printf '%s\n' '{"dependency":"new"}' >"${TEST_ROOT}/flake.lock"
cp "${TEST_ROOT}/flake.lock" "${TEST_ROOT}/expected-lock"
bash "${UPDATE_VERSION}"
cmp "${TEST_ROOT}/pin.nix" "${TEST_ROOT}/expected-pin.nix"
cmp "${TEST_ROOT}/flake.lock" "${TEST_ROOT}/expected-lock"
[[ "$(wc -l <"${TEST_OCI_COPY_LOG}")" -eq 1 ]]
[[ "$(wc -l <"${TEST_OCI_EVALUATION_LOG}")" -eq 2 ]]
sed -i '$i\  archiveFingerprint = "legacy";' "${TEST_ROOT}/pin.nix"
bash "${UPDATE_VERSION}"
cmp "${TEST_ROOT}/pin.nix" "${TEST_ROOT}/expected-pin.nix"
cmp "${TEST_ROOT}/flake.lock" "${TEST_ROOT}/expected-lock"
[[ "$(wc -l <"${TEST_OCI_COPY_LOG}")" -eq 2 ]]

OCI_SETTINGS='{"imageName":"registry.example/image","tag":"stable","os":"linux","arch":"arm64","variant":"v8"}' bash "${UPDATE_VERSION}"
grep -Fq "imageDigest = \"sha256:$(printf 'b%.0s' {1..64})\";" "${TEST_ROOT}/pin.nix"
write_empty_pin
TEST_OCI_MANIFEST=single bash "${UPDATE_VERSION}" "sha256:$(printf 'a%.0s' {1..64})"

for FAILURE in platform digest copy hash store lock evaluate build; do
  write_empty_pin
  cp "${TEST_ROOT}/pin.nix" "${TEST_ROOT}/expected-pin.nix"
  cp "${TEST_ROOT}/flake.lock" "${TEST_ROOT}/expected-lock"
  if TEST_OCI_FAIL="${FAILURE}" VERIFICATION=build bash "${UPDATE_VERSION}"; then
    exit 1
  fi
  cmp "${TEST_ROOT}/pin.nix" "${TEST_ROOT}/expected-pin.nix"
  cmp "${TEST_ROOT}/flake.lock" "${TEST_ROOT}/expected-lock"
done
if TEST_OCI_MANIFEST=ambiguous bash "${UPDATE_VERSION}"; then
  exit 1
fi
if OCI_SETTINGS='{"imageName":"registry.example/image","tag":"stable","os":"linux","arch":"arm64","variant":"v7"}' bash "${UPDATE_VERSION}"; then
  exit 1
fi

SENTINEL_HASH="sha256-$(printf 'c%.0s' {1..43})="
write_seeded_pin() {
  printf '%s\n' '{' "  imageDigest = \"${1}\";" "  imageHash = \"${SENTINEL_HASH}\";" '}' >"${TEST_ROOT}/pin.nix"
}

# A version branch seeded from a base that already carries its image claims its own version and keeps the pinned content.
write_seeded_pin "sha256:$(printf 'a%.0s' {1..64})"
COPIES="$(wc -l <"${TEST_OCI_COPY_LOG}")"
VERSION_SOURCE_TYPE=github GH_OWNER=example GH_REPO=example bash "${UPDATE_VERSION}" 2026.10.0
grep -Fq '  version = "2026.10.0";' "${TEST_ROOT}/pin.nix"
grep -Fq "  imageHash = \"${SENTINEL_HASH}\";" "${TEST_ROOT}/pin.nix"
grep -Fq "  imageDigest = \"sha256:$(printf 'a%.0s' {1..64})\";" "${TEST_ROOT}/pin.nix"
[[ "$(wc -l <"${TEST_OCI_COPY_LOG}")" -eq ${COPIES} ]]
[[ "$(tail -1 "${TEST_OCI_INSPECT_LOG}")" == 'docker://registry.example/image:2026.10.0' ]]

# Resolving a version whose image is not the pinned content copies it and writes the version beside it.
write_seeded_pin "sha256:$(printf 'b%.0s' {1..64})"
VERSION_SOURCE_TYPE=github GH_OWNER=example GH_REPO=example bash "${UPDATE_VERSION}" 2026.9.4
grep -Fq '  version = "2026.9.4";' "${TEST_ROOT}/pin.nix"
grep -Fq "  imageDigest = \"sha256:$(printf 'a%.0s' {1..64})\";" "${TEST_ROOT}/pin.nix"
[[ "$(wc -l <"${TEST_OCI_COPY_LOG}")" -eq $((COPIES + 1)) ]]

# A discovered release tag names the GitHub release, not the image, so the registry ref is its version.
write_empty_pin
TEST_RELEASE_TAG=v1.2.3 VERSION_SOURCE_TYPE=github GH_OWNER=example GH_REPO=example bash "${UPDATE_VERSION}"
[[ "$(tail -1 "${TEST_OCI_INSPECT_LOG}")" == 'docker://registry.example/image:1.2.3' ]]
grep -Fq '  version = "1.2.3";' "${TEST_ROOT}/pin.nix"

# The orchestrator's canonical version names the pin while its upstream version selects the image.
write_seeded_pin "sha256:$(printf 'a%.0s' {1..64})"
VERSION_SOURCE_TYPE=github GH_OWNER=example GH_REPO=example bash "${UPDATE_VERSION}" 2026.10.0.rc1 2026.10.0b7
[[ "$(tail -1 "${TEST_OCI_INSPECT_LOG}")" == 'docker://registry.example/image:2026.10.0b7' ]]
grep -Fq '  version = "2026.10.0.rc1";' "${TEST_ROOT}/pin.nix"
if VERSION_SOURCE_TYPE=github GH_OWNER=example GH_REPO=example bash "${UPDATE_VERSION}" latest 2026.10.0b7; then
  exit 1
fi

# Without a version source the updater still refuses a second argument and pins no version.
if bash "${UPDATE_VERSION}" 2026.10.0 v2026.10.0; then
  exit 1
fi
