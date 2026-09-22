#!/usr/bin/env -S nix shell nixpkgs#bash nixpkgs#coreutils --command bash

set -euo pipefail

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "${TEST_ROOT}"' EXIT

write_empty_pin() {
  printf '%s\n' \
    '{' \
    '  version = "";' \
    '  sourceRev = "";' \
    '  sourceHash = "";' \
    '}' > "${TEST_ROOT}/pin.nix"
}

run_update() {
  local TRACK="${1}" TAG_PREFIXES="${2}" RELEASE_TAG="${3}" TAGS="${4}"
  local REQUESTED="${5:-}" REQUESTED_REF="${6:-}"
  local -a ARGS=()
  if [[ -n "${REQUESTED}" ]]; then
    ARGS+=("${REQUESTED}")
  fi
  if [[ -n "${REQUESTED_REF}" ]]; then
    ARGS+=("${REQUESTED_REF}")
  fi
  FLAKE_ROOT="${TEST_ROOT}" \
    SOURCE_TYPE=github \
    GH_OWNER=openai \
    GH_REPO=codex \
    GH_TAG_PREFIXES="${TAG_PREFIXES}" \
    GH_TRACK="${TRACK}" \
    TEST_RELEASE_TAG="${RELEASE_TAG}" \
    TEST_TAGS="${TAGS}" \
    BUILD_ATTR=codex \
    HASH_MODE=prefetch \
    EXTRA_HASHES='[]' \
    PIN_HASHES='[]' \
    VERIFICATION=evaluate \
    SIBLINGS='[]' \
    bash "${UPDATE_VERSION}" "${ARGS[@]}"
}

assert_pin() {
  grep -Fq 'version = "1.2.3";' "${TEST_ROOT}/pin.nix"
  grep -Fq 'sourceRev = "source-revision";' "${TEST_ROOT}/pin.nix"
  grep -Fq 'sourceHash = "sha256-source";' "${TEST_ROOT}/pin.nix"
}

ARTIFACT_HOOK="${TEST_ROOT}/artifact-hook"
ARTIFACT_LOG="${TEST_ROOT}/artifact-hook.log"
printf '%s\n' \
  "#!${TEST_BASH}/bin/bash" \
  'printf "%s\n" "${SOURCE_TYPE}" >> "${TEST_ARTIFACT_LOG}"' \
  'if [[ -n "${TEST_ARTIFACT_FILE:-}" ]]; then printf "%s\n" migrated > "${FLAKE_ROOT}/${TEST_ARTIFACT_FILE}"; fi' \
  'if [[ -n "${TEST_STALE_ARTIFACT:-}" ]]; then rm -f "${FLAKE_ROOT}/${TEST_STALE_ARTIFACT}"; fi' \
  'printf "%s\n" "artifactFingerprint=${TEST_ARTIFACT_FINGERPRINT}"' \
  'printf "%s\n" "requirementsHash=requirements-hash"' \
  'printf "%s\n" "wheelManifestHash=manifest-hash"' > "${ARTIFACT_HOOK}"
chmod +x "${ARTIFACT_HOOK}"

write_empty_pin
run_update release '["rust-v"]' rust-v1.2.3 ''
assert_pin

write_empty_pin
run_update tag '["rust-v"]' '' $'v9.9.9\nrust-v1.2.3'
assert_pin

write_empty_pin
run_update release '["v","V",""]' v1.2.3 ''
assert_pin

write_empty_pin
run_update release '["rust-v"]' '' '' rust-v1.2.3
assert_pin

write_empty_pin
run_update release '["rust-v"]' '' '' 1.2.3 1.2.3
assert_pin

cat > "${TEST_ROOT}/pin.nix" <<'EOF'
{
  version = "1.2.3";
  sourceRev = "source-revision";
  sourceHash = "sha256-source";
  artifactFingerprint = "exact-fingerprint";
  requirementsHash = "requirements-hash";
  wheelManifestHash = "manifest-hash";
}
EOF
NOOP_OUTPUT=$(FLAKE_ROOT="${TEST_ROOT}" \
  SOURCE_TYPE=github \
  GH_OWNER=openai \
  GH_REPO=codex \
  GH_TAG_PREFIXES='["v","V",""]' \
  GH_TRACK=release \
  TEST_RELEASE_TAG=v1.2.3 \
  TEST_TAGS='' \
  BUILD_ATTR=codex \
  HASH_MODE=prefetch \
  EXTRA_HASHES='["artifactFingerprint","requirementsHash","wheelManifestHash"]' \
  PIN_HASHES='["artifactFingerprint","requirementsHash","wheelManifestHash"]' \
  ARTIFACT_FINGERPRINT=exact-fingerprint \
  ARTIFACT_HOOK=/must-not-run \
  VERIFICATION=evaluate \
  SIBLINGS='[]' \
  bash "${UPDATE_VERSION}" 1.2.3)
grep -Fq 'Already up to date (1.2.3).' <<<"${NOOP_OUTPUT}"

sed -i 's/artifactFingerprint = "exact-fingerprint";/pythonEnvironment = "3.13";/' "${TEST_ROOT}/pin.nix"
: > "${ARTIFACT_LOG}"
TEST_ARTIFACT_LOG="${ARTIFACT_LOG}" \
TEST_ARTIFACT_FINGERPRINT=exact-fingerprint \
FLAKE_ROOT="${TEST_ROOT}" \
SOURCE_TYPE=github \
GH_OWNER=openai \
GH_REPO=codex \
GITLAB_OWNER='' \
GITLAB_REPO='' \
GH_TAG_PREFIXES='["v","V",""]' \
GH_TRACK=release \
TEST_RELEASE_TAG=v1.2.3 \
TEST_TAGS='' \
BUILD_ATTR=codex \
HASH_MODE=prefetch \
EXTRA_HASHES='["artifactFingerprint","requirementsHash","wheelManifestHash"]' \
PIN_HASHES='["artifactFingerprint","requirementsHash","wheelManifestHash"]' \
ARTIFACT_FINGERPRINT=exact-fingerprint \
ARTIFACT_HOOK="${ARTIFACT_HOOK}" \
VERIFICATION=evaluate \
SIBLINGS='[]' \
bash "${UPDATE_VERSION}" 1.2.3
grep -Fqx github "${ARTIFACT_LOG}"
grep -Fq 'artifactFingerprint = "exact-fingerprint";' "${TEST_ROOT}/pin.nix"

run_artifact_git_case() {
  local CASE_ROOT="${1}" ORCHESTRATED_FILES="${2}" EXPECT_TRACKED_FILE="${3}"
  mkdir -p "${CASE_ROOT}"
  cat > "${CASE_ROOT}/pin.nix" <<'EOF'
{
  version = "1.2.3";
  sourceRev = "source-revision";
  sourceHash = "sha256-source";
  artifactFingerprint = "old-fingerprint";
  requirementsHash = "requirements-hash";
  wheelManifestHash = "manifest-hash";
}
EOF
  printf '%s\n' legacy > "${CASE_ROOT}/wheels-3.14.json"
  git -C "${CASE_ROOT}" init -q
  git -C "${CASE_ROOT}" add pin.nix wheels-3.14.json
  git -C "${CASE_ROOT}" -c user.name=test -c user.email=test@example.com commit -qm initial
  (
    cd "${CASE_ROOT}"
    TEST_ARTIFACT_LOG="${ARTIFACT_LOG}" \
    TEST_ARTIFACT_FINGERPRINT=exact-fingerprint \
    TEST_ARTIFACT_FILE=wheels-3.14-x86_64-linux.json \
    TEST_STALE_ARTIFACT=wheels-3.14.json \
    TEST_EXPECT_TRACKED_FILE="${EXPECT_TRACKED_FILE}" \
    FLAKE_ROOT="${CASE_ROOT}" \
    ORCHESTRATED_OWNED_FILES="${ORCHESTRATED_FILES}" \
    SOURCE_TYPE=github \
    GH_OWNER=openai \
    GH_REPO=codex \
    GITLAB_OWNER='' \
    GITLAB_REPO='' \
    GH_TAG_PREFIXES='["v","V",""]' \
    GH_TRACK=release \
    TEST_RELEASE_TAG=v1.2.3 \
    TEST_TAGS='' \
    BUILD_ATTR=codex \
    HASH_MODE=prefetch \
    EXTRA_HASHES='["artifactFingerprint","requirementsHash","wheelManifestHash"]' \
    PIN_HASHES='["artifactFingerprint","requirementsHash","wheelManifestHash"]' \
    ARTIFACT_FINGERPRINT=exact-fingerprint \
    ARTIFACT_HOOK="${ARTIFACT_HOOK}" \
    VERIFICATION=evaluate \
    SIBLINGS='[]' \
    bash "${UPDATE_VERSION}" 1.2.3
  )
}

DIRECT_ROOT="${TEST_ROOT}/direct-artifacts"
run_artifact_git_case "${DIRECT_ROOT}" '' ''
! git -C "${DIRECT_ROOT}" ls-files --error-unmatch -- wheels-3.14-x86_64-linux.json >/dev/null 2>&1

ORCHESTRATED_ROOT="${TEST_ROOT}/orchestrated-artifacts"
run_artifact_git_case "${ORCHESTRATED_ROOT}" 'pin.nix flake.lock requirements-*.lock wheels-*.json' wheels-3.14-x86_64-linux.json
git -C "${ORCHESTRATED_ROOT}" ls-files --error-unmatch -- wheels-3.14-x86_64-linux.json >/dev/null
! git -C "${ORCHESTRATED_ROOT}" ls-files --error-unmatch -- wheels-3.14.json >/dev/null 2>&1

sed -i -e 's/sourceRev = "source-revision";/hash = "sha256-pypi";/' -e 's/sourceHash = "sha256-source";//' -e 's/artifactFingerprint = "exact-fingerprint";/pythonEnvironment = "3.13";/' "${TEST_ROOT}/pin.nix"
: > "${ARTIFACT_LOG}"
TEST_ARTIFACT_LOG="${ARTIFACT_LOG}" \
TEST_ARTIFACT_FINGERPRINT=exact-fingerprint \
TEST_PYPI_METADATA='{"info":{"version":"1.2.3"},"urls":[{"packagetype":"sdist","url":"https://files.example.test/example-1.2.3.tar.gz"}]}' \
FLAKE_ROOT="${TEST_ROOT}" \
SOURCE_TYPE=pypi \
PYPI_NAME=example \
PYPI_FORMAT=sdist \
GH_OWNER='' \
GH_REPO='' \
GITLAB_OWNER='' \
GITLAB_REPO='' \
BUILD_ATTR=example \
HASH_MODE=prefetch \
EXTRA_HASHES='["artifactFingerprint","requirementsHash","wheelManifestHash"]' \
PIN_HASHES='["artifactFingerprint","requirementsHash","wheelManifestHash"]' \
ARTIFACT_FINGERPRINT=exact-fingerprint \
ARTIFACT_HOOK="${ARTIFACT_HOOK}" \
VERIFICATION=evaluate \
SIBLINGS='[]' \
bash "${UPDATE_VERSION}" 1.2.3
grep -Fqx pypi "${ARTIFACT_LOG}"
grep -Fq 'artifactFingerprint = "exact-fingerprint";' "${TEST_ROOT}/pin.nix"

cat > "${TEST_ROOT}/pin.nix" <<'EOF'
{
  version = "";
  sourceRev = "";
  manifestHash = "";
}
EOF
TEST_HF_METADATA='{
  "sha": "model-revision",
  "lastModified": "2026-08-26T12:34:56.000Z",
  "siblings": [
    {"rfilename":"weights.safetensors","size":20,"blobId":"large-blob","lfs":{"sha256":"large-sha256"}},
    {"rfilename":".gitattributes","size":10,"blobId":"hidden-blob"},
    {"rfilename":"config.json","size":5,"blobId":"config-blob"},
    {"rfilename":"conversion.complete.json","size":7,"blobId":"receipt-blob"}
  ]
}' \
FLAKE_ROOT="${TEST_ROOT}" \
SOURCE_TYPE=huggingface \
HF_REPO=example/model \
HF_REVISION=main \
HF_FILES='[]' \
HF_MANIFEST_PATH=model-manifest.json \
HF_MANIFEST_INCLUDE='[]' \
HF_MANIFEST_EXCLUDE='["^\\.","\\.complete\\.json$"]' \
HF_MANIFEST_HASH_FIELD=manifestHash \
BUILD_ATTR=model \
HASH_MODE=prefetch \
EXTRA_HASHES='["manifestHash"]' \
PIN_HASHES='["manifestHash"]' \
VERIFICATION=evaluate \
SIBLINGS='[]' \
bash "${UPDATE_VERSION}"

grep -Fq 'version = "0-unstable-2026-08-26";' "${TEST_ROOT}/pin.nix"
grep -Fq 'sourceRev = "model-revision";' "${TEST_ROOT}/pin.nix"
MANIFEST_HASH=$(sha256sum "${TEST_ROOT}/model-manifest.json" | cut -d' ' -f1)
grep -Fq "manifestHash = \"${MANIFEST_HASH}\";" "${TEST_ROOT}/pin.nix"
jq -e '
  .repo == "example/model"
  and .revision == "model-revision"
  and .total_bytes == 25
  and [.files[].path] == ["config.json", "weights.safetensors"]
  and .files[0].sha256 == null
  and .files[0].git_blob == "config-blob"
  and .files[1].sha256 == "large-sha256"
' "${TEST_ROOT}/model-manifest.json" >/dev/null

cat > "${TEST_ROOT}/pin.nix" <<'EOF'
{
  version = "0-unstable-2026-08-26";
  sourceRev = "model-revision";
  pythonEnvironment = "3.13";
  requirementsHash = "requirements-hash";
  wheelManifestHash = "manifest-hash";
}
EOF
: > "${ARTIFACT_LOG}"
HF_MISMATCH_OUTPUT=$(TEST_ARTIFACT_LOG="${ARTIFACT_LOG}" \
  TEST_ARTIFACT_FINGERPRINT=exact-fingerprint \
  TEST_HF_METADATA='{"sha":"model-revision","lastModified":"2026-08-26T12:34:56.000Z","siblings":[]}' \
  FLAKE_ROOT="${TEST_ROOT}" \
  SOURCE_TYPE=huggingface \
  GH_OWNER='' \
  GH_REPO='' \
  GITLAB_OWNER='' \
  GITLAB_REPO='' \
  HF_REPO=example/model \
  HF_REVISION=main \
  HF_FILES='[]' \
  HF_MANIFEST_PATH='' \
  BUILD_ATTR=model \
  HASH_MODE=prefetch \
  EXTRA_HASHES='["artifactFingerprint","requirementsHash","wheelManifestHash"]' \
  PIN_HASHES='["artifactFingerprint","requirementsHash","wheelManifestHash"]' \
  ARTIFACT_FINGERPRINT=exact-fingerprint \
  ARTIFACT_HOOK="${ARTIFACT_HOOK}" \
  VERIFICATION=evaluate \
  SIBLINGS='[]' \
  bash "${UPDATE_VERSION}")
grep -Fqx huggingface "${ARTIFACT_LOG}"
grep -Fq 'artifactFingerprint = "exact-fingerprint";' "${TEST_ROOT}/pin.nix"
grep -Fq 'Updated model to 0-unstable-2026-08-26.' <<<"${HF_MISMATCH_OUTPUT}"
