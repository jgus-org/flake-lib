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
    '}' >"${TEST_ROOT}/pin.nix"
}

run_update() {
  local TRACK="${1}" TAG_PREFIXES="${2}" RELEASE_TAG="${3}" TAGS="${4}"
  local REQUESTED="${5:-}" REQUESTED_REF="${6:-}"
  local -a ARGS=()
  if [[ -n ${REQUESTED} ]]; then
    ARGS+=("${REQUESTED}")
  fi
  if [[ -n ${REQUESTED_REF} ]]; then
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
    HASH_MODE=prefetch \
    EXTRA_HASHES='[]' \
    PIN_HASHES='[]' \
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
  'printf "%s\n" "wheelManifestHash=manifest-hash"' >"${ARTIFACT_HOOK}"
chmod +x "${ARTIFACT_HOOK}"

printf '%s\n' \
  '{' \
  '  lastModified = "";' \
  '  hash = "";' \
  '}' >"${TEST_ROOT}/pin.nix"
PREFETCH_LOG="${TEST_ROOT}/mutable-prefetch.log"
MUTABLE_OUTPUT=$(TEST_PREFETCH_LOG="${PREFETCH_LOG}" \
  FLAKE_ROOT="${TEST_ROOT}" \
  SOURCE_TYPE=mutable-url \
  MUTABLE_URL=https://downloads.example.test/artifact.bin \
  SIBLINGS='[]' \
  bash "${UPDATE_VERSION}")
grep -Fq 'lastModified = "Tue, 25 Aug 2026 12:34:56 GMT";' "${TEST_ROOT}/pin.nix"
grep -Fq 'hash = "sha256-mutable";' "${TEST_ROOT}/pin.nix"
grep -Fq 'Updated the pin to main.' <<<"${MUTABLE_OUTPUT}"
MUTABLE_NOOP_OUTPUT=$(TEST_PREFETCH_LOG="${PREFETCH_LOG}" \
  FLAKE_ROOT="${TEST_ROOT}" \
  SOURCE_TYPE=mutable-url \
  MUTABLE_URL=https://downloads.example.test/artifact.bin \
  SIBLINGS='[]' \
  bash "${UPDATE_VERSION}")
grep -Fq 'Already up to date (main).' <<<"${MUTABLE_NOOP_OUTPUT}"
[[ "$(wc -l <"${PREFETCH_LOG}")" -eq 1 ]]

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

# A pin is machine-written into a repository that formats itself, so the writer's field order has to be the formatter's sorted order. Written any other way, the updater's own commit fails the repository's formatting check until a human reformats it.
write_empty_pin
run_update release '["v","V",""]' v1.2.3 ''
diff -u <(printf '%s\n' \
  '{' \
  '  sourceHash = "sha256-source";' \
  '  sourceRev = "source-revision";' \
  '  version = "1.2.3";' \
  '}') <(grep -v '^#' "${TEST_ROOT}/pin.nix")

# A dotted field name is a nested attribute, and how deeply it nests is the formatter's rule rather than the writer's,
# so the updater hands the pin to the repository's own formatter. The property is that nothing is left to reformat; a
# pin the formatter would change is a pin that fails the formatting check on the updater's own commit.
NESTED_ROOT="${TEST_ROOT}/nested-pin"
mkdir -p "${NESTED_ROOT}"
printf '%s\n' '{}' >"${NESTED_ROOT}/flake.nix"
printf '%s\n' '{' '  version = "";' '  sourceRev = "";' '  sourceHash = "";' '}' >"${NESTED_ROOT}/pin.nix"
NESTED_OUTPUT=$(FLAKE_ROOT="${NESTED_ROOT}" \
  SOURCE_TYPE=github \
  GH_OWNER=openai \
  GH_REPO=codex \
  GH_TAG_PREFIXES='["v","V",""]' \
  GH_TRACK=release \
  TEST_RELEASE_TAG=v1.2.3 \
  TEST_TAGS='' \
  HASH_MODE=prefetch \
  EXTRA_HASHES='["v8.archive.aarch64-linux","v8.archive.x86_64-linux","v8.version"]' \
  PIN_HASHES='["v8.archive.aarch64-linux","v8.archive.x86_64-linux","v8.version"]' \
  FORMATTER="${TEST_FORMATTER}" \
  SIBLINGS='[]' \
  bash "${UPDATE_VERSION}" 1.2.3)
grep -Fq 'Updated the pin to 1.2.3.' <<<"${NESTED_OUTPUT}"
grep -Fq 'v8 = {' "${NESTED_ROOT}/pin.nix"
cp "${NESTED_ROOT}/pin.nix" "${NESTED_ROOT}/pin.nix.before"
(cd "${NESTED_ROOT}" && "${TEST_FORMATTER}" --no-cache pin.nix)
diff -u "${NESTED_ROOT}/pin.nix.before" "${NESTED_ROOT}/pin.nix"

# Without a formatter the flat lines stand, which is what every pin naming only flat fields has always been.
FLAT_ROOT="${TEST_ROOT}/flat-pin"
mkdir -p "${FLAT_ROOT}"
printf '%s\n' '{}' >"${FLAT_ROOT}/flake.nix"
printf '%s\n' '{' '  version = "";' '  sourceRev = "";' '  sourceHash = "";' '}' >"${FLAT_ROOT}/pin.nix"
FLAT_OUTPUT=$(FLAKE_ROOT="${FLAT_ROOT}" \
  SOURCE_TYPE=github \
  GH_OWNER=openai \
  GH_REPO=codex \
  GH_TAG_PREFIXES='["v","V",""]' \
  GH_TRACK=release \
  TEST_RELEASE_TAG=v1.2.3 \
  TEST_TAGS='' \
  HASH_MODE=prefetch \
  EXTRA_HASHES='["npmDepsHash"]' \
  PIN_HASHES='["npmDepsHash"]' \
  SIBLINGS='[]' \
  bash "${UPDATE_VERSION}" 1.2.3)
grep -Fq 'Updated the pin to 1.2.3.' <<<"${FLAT_OUTPUT}"
grep -Fq 'npmDepsHash = "";' "${FLAT_ROOT}/pin.nix"

cat >"${TEST_ROOT}/pin.nix" <<'EOF'
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
  HASH_MODE=prefetch \
  EXTRA_HASHES='["artifactFingerprint","requirementsHash","wheelManifestHash"]' \
  PIN_HASHES='["artifactFingerprint","requirementsHash","wheelManifestHash"]' \
  ARTIFACT_FINGERPRINT=exact-fingerprint \
  ARTIFACT_HOOK=/must-not-run \
  SIBLINGS='[]' \
  bash "${UPDATE_VERSION}" 1.2.3)
grep -Fq 'Already up to date (1.2.3).' <<<"${NOOP_OUTPUT}"

sed -i 's/artifactFingerprint = "exact-fingerprint";/pythonEnvironment = "3.13";/' "${TEST_ROOT}/pin.nix"
: >"${ARTIFACT_LOG}"
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
  HASH_MODE=prefetch \
  EXTRA_HASHES='["artifactFingerprint","requirementsHash","wheelManifestHash"]' \
  PIN_HASHES='["artifactFingerprint","requirementsHash","wheelManifestHash"]' \
  ARTIFACT_FINGERPRINT=exact-fingerprint \
  ARTIFACT_HOOK="${ARTIFACT_HOOK}" \
  SIBLINGS='[]' \
  bash "${UPDATE_VERSION}" 1.2.3
grep -Fqx github "${ARTIFACT_LOG}"
grep -Fq 'artifactFingerprint = "exact-fingerprint";' "${TEST_ROOT}/pin.nix"

run_artifact_git_case() {
  local CASE_ROOT="${1}" ORCHESTRATED_FILES="${2}" EXPECT_TRACKED_FILE="${3}"
  mkdir -p "${CASE_ROOT}"
  cat >"${CASE_ROOT}/pin.nix" <<'EOF'
{
  version = "1.2.3";
  sourceRev = "source-revision";
  sourceHash = "sha256-source";
  artifactFingerprint = "old-fingerprint";
  requirementsHash = "requirements-hash";
  wheelManifestHash = "manifest-hash";
}
EOF
  printf '%s\n' legacy >"${CASE_ROOT}/wheels-3.14.json"
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
      HASH_MODE=prefetch \
      EXTRA_HASHES='["artifactFingerprint","requirementsHash","wheelManifestHash"]' \
      PIN_HASHES='["artifactFingerprint","requirementsHash","wheelManifestHash"]' \
      ARTIFACT_FINGERPRINT=exact-fingerprint \
      ARTIFACT_HOOK="${ARTIFACT_HOOK}" \
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
: >"${ARTIFACT_LOG}"
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
  HASH_MODE=prefetch \
  EXTRA_HASHES='["artifactFingerprint","requirementsHash","wheelManifestHash"]' \
  PIN_HASHES='["artifactFingerprint","requirementsHash","wheelManifestHash"]' \
  ARTIFACT_FINGERPRINT=exact-fingerprint \
  ARTIFACT_HOOK="${ARTIFACT_HOOK}" \
  SIBLINGS='[]' \
  bash "${UPDATE_VERSION}" 1.2.3
grep -Fqx pypi "${ARTIFACT_LOG}"
grep -Fq 'artifactFingerprint = "exact-fingerprint";' "${TEST_ROOT}/pin.nix"

cat >"${TEST_ROOT}/pin.nix" <<'EOF'
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
  HASH_MODE=prefetch \
  EXTRA_HASHES='["manifestHash"]' \
  PIN_HASHES='["manifestHash"]' \
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

cat >"${TEST_ROOT}/pin.nix" <<'EOF'
{
  version = "0-unstable-2026-08-26";
  sourceRev = "model-revision";
  pythonEnvironment = "3.13";
  requirementsHash = "requirements-hash";
  wheelManifestHash = "manifest-hash";
}
EOF
: >"${ARTIFACT_LOG}"
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
  HASH_MODE=prefetch \
  EXTRA_HASHES='["artifactFingerprint","requirementsHash","wheelManifestHash"]' \
  PIN_HASHES='["artifactFingerprint","requirementsHash","wheelManifestHash"]' \
  ARTIFACT_FINGERPRINT=exact-fingerprint \
  ARTIFACT_HOOK="${ARTIFACT_HOOK}" \
  SIBLINGS='[]' \
  bash "${UPDATE_VERSION}")
grep -Fqx huggingface "${ARTIFACT_LOG}"
grep -Fq 'artifactFingerprint = "exact-fingerprint";' "${TEST_ROOT}/pin.nix"
grep -Fq 'Updated the pin to 0-unstable-2026-08-26.' <<<"${HF_MISMATCH_OUTPUT}"

PNPM_ARTIFACT_HOOK="${TEST_ROOT}/pnpm-artifact-hook"
printf '%s\n' \
  "#!${TEST_BASH}/bin/bash" \
  'printf "%s\n" "pnpmDepsHash=sha256-pnpmold" "vendorHash=sha256-vendorold"' >"${PNPM_ARTIFACT_HOOK}"
chmod +x "${PNPM_ARTIFACT_HOOK}"

run_build_failure_case() {
  local CASE_ROOT="${1}" PLAN="${2}" FAILURE_HASHES="${3}" PIN_HASHES_JSON="${4}" EXTRA_HASHES_JSON="${5}"
  mkdir -p "${CASE_ROOT}"
  printf '%s\n' '{ version = ""; sourceRev = ""; sourceHash = ""; }' >"${CASE_ROOT}/pin.nix"
  FLAKE_ROOT="${CASE_ROOT}" \
    SOURCE_TYPE=github \
    GH_OWNER=openai \
    GH_REPO=codex \
    GITLAB_OWNER='' \
    GITLAB_REPO='' \
    GH_TAG_PREFIXES='["v","V",""]' \
    GH_TRACK=release \
    TEST_RELEASE_TAG=v1.2.3 \
    TEST_TAGS='' \
    HASH_MODE=prefetch \
    EXTRA_HASHES="${EXTRA_HASHES_JSON}" \
    PIN_HASHES="${PIN_HASHES_JSON}" \
    BUILD_FAILURE_HASHES="${FAILURE_HASHES}" \
    ARTIFACT_HOOK="${PNPM_ARTIFACT_HOOK}" \
    SIBLINGS='[]' \
    TEST_BUILD_PLAN="${PLAN}" \
    TEST_BUILD_LOG="${CASE_ROOT}/builds.log" \
    bash "${UPDATE_VERSION}" 1.2.3
}

RECOVERY_ROOT="${TEST_ROOT}/build-failure-recovery"
RECOVERY_PLAN="${TEST_ROOT}/recovery.plan"
cat >"${RECOVERY_PLAN}" <<'EOF'
mismatch sha256-vendorold sha256-vendornew
mismatch sha256-pnpmold sha256-pnpmnew
ok
EOF
run_build_failure_case "${RECOVERY_ROOT}" "${RECOVERY_PLAN}" '["pnpmDepsHash","vendorHash"]' '["pnpmDepsHash","vendorHash"]' '[]'
grep -Fq 'pnpmDepsHash = "sha256-pnpmnew";' "${RECOVERY_ROOT}/pin.nix"
grep -Fq 'vendorHash = "sha256-vendornew";' "${RECOVERY_ROOT}/pin.nix"
[[ "$(wc -l <"${RECOVERY_ROOT}/builds.log")" -eq 3 ]]

UNDECLARED_ROOT="${TEST_ROOT}/build-failure-undeclared"
UNDECLARED_PLAN="${TEST_ROOT}/undeclared.plan"
cat >"${UNDECLARED_PLAN}" <<'EOF'
mismatch sha256-vendorold sha256-vendornew
ok
EOF
if UNDECLARED_OUTPUT=$(run_build_failure_case "${UNDECLARED_ROOT}" "${UNDECLARED_PLAN}" '["pnpmDepsHash"]' '["pnpmDepsHash","vendorHash"]' '["vendorHash"]' 2>&1); then
  echo "expected the run to stop on a mismatch naming an undeclared pin field" >&2
  exit 1
fi
grep -Fq 'names pin field vendorHash' <<<"${UNDECLARED_OUTPUT}"
grep -Fq 'pnpmDepsHash = "sha256-pnpmold";' "${UNDECLARED_ROOT}/pin.nix"
grep -Fq 'vendorHash = "sha256-vendorold";' "${UNDECLARED_ROOT}/pin.nix"

BOUND_ROOT="${TEST_ROOT}/build-failure-bound"
BOUND_PLAN="${TEST_ROOT}/bound.plan"
cat >"${BOUND_PLAN}" <<'EOF'
mismatch sha256-straya sha256-pnpmnew
mismatch sha256-strayb sha256-vendornew
mismatch sha256-strayc sha256-stillwrong
ok
EOF
if BOUND_OUTPUT=$(run_build_failure_case "${BOUND_ROOT}" "${BOUND_PLAN}" '["pnpmDepsHash","vendorHash"]' '["pnpmDepsHash","vendorHash"]' '[]' 2>&1); then
  echo "expected the run to stop once each declared field had been resolved once" >&2
  exit 1
fi
grep -Fq 'resolved once each' <<<"${BOUND_OUTPUT}"
[[ "$(wc -l <"${BOUND_ROOT}/builds.log")" -eq 3 ]]
