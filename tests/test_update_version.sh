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
