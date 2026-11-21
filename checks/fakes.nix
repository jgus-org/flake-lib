# Fixtures shared by more than one check module.
{ pkgs }:
let
  # A build sandbox has no /usr/bin/env, so a script that names its tools in a `nix shell` shebang cannot be exec'd there. These shims run the same script texts production execs through an interpreter the sandbox already has, with the suite's own PATH still around.
  build-packages-test-shim = pkgs.writeShellApplication {
    name = "build-packages";
    text = ''exec ${pkgs.lib.getExe pkgs.bash} ${../scripts/build-packages.sh} "$@"'';
  };

  build-and-check-test-shim = pkgs.writeShellApplication {
    name = "build-and-check";
    text = ''exec ${pkgs.lib.getExe pkgs.bash} ${../scripts/build-and-check.sh} "$@"'';
  };

  update-branches-test-nix = pkgs.writeShellApplication {
    name = "nix";
    runtimeInputs = [
      pkgs.git
      pkgs.gnugrep
      pkgs.jq
    ];
    text = ''
      if [[ "''${1}" == "flake" && "''${2:-}" == "update" && "''${3:-}" == "flake-lib" ]]; then
        node=$(jq -r '.nodes.root.inputs["flake-lib"]' flake.lock)
        # Real nix leaves the lock byte-identical when nothing moved. Rewriting it anyway
        # would make an unchanged lock look like a change to the refresh's commit test.
        if [[ "$(jq -r --arg n "''${node}" '.nodes[$n].locked.rev' flake.lock)" == "''${TEST_NIX_FLAKE_LIB_REV:?fixture: no flake-lib revision to advance to}" ]]; then
          exit 0
        fi
        jq --arg n "''${node}" --arg rev "''${TEST_NIX_FLAKE_LIB_REV}" \
          '.nodes[$n].locked.rev = $rev' flake.lock > flake.lock.next
        mv flake.lock.next flake.lock
        exit 0
      fi
      if [[ "''${1}" == "flake" ]]; then
        CURRENT_BRANCH=$(git branch --show-current)
        for FAILED_VERSION in ''${TEST_FAILED_REFRESH_VERSIONS:-}; do
          if [[ "''${CURRENT_BRANCH}" == "v''${FAILED_VERSION}" ]]; then
            printf '%s\n' '{ "fixture": "partial-input-refresh" }' > flake.lock
            exit 42
          fi
        done
        exit 0
      fi
      if [[ "''${1}" == "config" ]]; then
        printf '%s\n' x86_64-linux
        exit 0
      fi
      if [[ "''${1}" == "eval" ]]; then
        # The published selection the build gate reads. A case that needs another family
        # names one; the default carries one buildable package and excuses nothing.
        if [[ -n "''${TEST_NIX_SELECTION:-}" ]]; then
          printf '%s\n' "''${TEST_NIX_SELECTION}"
        else
          printf '%s\n' '{"build":["fixture"],"skip":[]}'
        fi
        exit 0
      fi
      if [[ "''${1}" == "build" && "''${*}" == *workflow-templates* ]]; then
        if [[ -n "''${TEST_NIX_NO_TEMPLATES:-}" ]]; then
          printf '%s\n' "error: fixture: this revision publishes no workflow templates" >&2
          exit 1
        fi
        printf '%s\n' "''${TEST_NIX_TEMPLATE_SOURCE:?fixture: no template source}/templates/workflows"
        exit 0
      fi
      if [[ "''${1}" == "build" ]]; then
        for FAILED_VERSION in ''${TEST_NIX_BUILD_FAILURES:-}; do
          if grep -Fq "version = \"''${FAILED_VERSION}\";" pin.nix; then
            printf 'error: fixture: a published package does not build at %s\n' "''${FAILED_VERSION}" >&2
            exit 1
          fi
        done
        printf '%s\n' /nix/store/00000000000000000000000000000000-fixture-default
        exit 0
      fi
      if [[ "''${1}" == "fmt" ]]; then
        # A fixture is written formatted, so formatting succeeds unless a version names a failure.
        for FAILED_VERSION in ''${TEST_NIX_FMT_FAILURES:-}; do
          if grep -Fq "version = \"''${FAILED_VERSION}\";" pin.nix; then
            printf 'error: fixture: formatting failed at %s\n' "''${FAILED_VERSION}" >&2
            exit 1
          fi
        done
        exit 0
      fi
      [[ "''${1}" == "run" ]]
      if [[ "''${PIN_SCHEMA:-}" == "oci" ]]; then
        grep -Fq 'imageDigest = "sha256:' "''${FLAKE_ROOT}/pin.nix"
        if [[ -n "''${TEST_EXPECT_SEEDED_PIN:-}" ]]; then
          if grep -Fq 'version = ' "''${FLAKE_ROOT}/pin.nix"; then
            printf '%s\n' 'fixture: a new oci branch must be seeded without a version' >&2
            exit 1
          fi
        fi
      else
        # The fixture stands in for the producer's own updater, so it checks it was handed this repository's pin.
        # Only version-only keeps the base branch's pin on a new branch; every other schema writes its own
        # template, whose fields are the schema's and not the fixture's.
        if [[ "''${PIN_SCHEMA:-version-only}" == "version-only" ]]; then
          grep -Fq 'assets.fixture' "''${FLAKE_ROOT}/pin.nix"
        else
          grep -Fq 'version = "' "''${FLAKE_ROOT}/pin.nix"
        fi
      fi
      while [[ "''${1}" != "--" ]]; do
        shift
      done
      shift
      TARGET_VERSION="''${1}"
      [[ "''${2:-}" == "''${TEST_EXPECTED_UPSTREAM_VERSION:-''${TARGET_VERSION}}" ]]
      printf '%s\n' "''${TARGET_VERSION}" >> "''${TEST_UPDATE_VERSION_LOG}"
      for TRANSIENT_VERSION in ''${TEST_TRANSIENT_UPDATE_VERSIONS:-}; do
        if [[ "''${TARGET_VERSION}" == "''${TRANSIENT_VERSION}" ]]; then
          ATTEMPT_FILE="''${TEST_TRANSIENT_ATTEMPT_DIR}/update-version-''${TARGET_VERSION}"
          ATTEMPT=$(cat "''${ATTEMPT_FILE}" 2>/dev/null || printf '%s\n' 0)
          printf '%s\n' "$((ATTEMPT + 1))" > "''${ATTEMPT_FILE}"
          if (( ATTEMPT == 0 )); then
            case "''${TEST_TRANSIENT_FAILURE_MODE:-network}" in
              network)
                printf '%s\n' 'curl: (22) The requested URL returned error: 504' >&2
                ;;
              python-tls-eof)
                printf '%s\n' 'urllib.error.URLError: <urlopen error [SSL: UNEXPECTED_EOF_WHILE_READING] EOF occurred in violation of protocol (_ssl.c:1082)>' >&2
                ;;
              github-ref)
                printf '%s\n' "error: unable to download 'https://api.github.com/repos/example/example/commits/v1.2.0': HTTP error 422" >&2
                printf '%s\n' '"message": "No commit found for SHA: v1.2.0",' >&2
                ;;
            esac
            exit 1
          fi
        fi
      done
      for FAILED_VERSION in ''${TEST_FAILED_VERSIONS:-}; do
        if [[ "''${TARGET_VERSION}" == "''${FAILED_VERSION}" ]]; then
          exit 1
        fi
      done
      if [[ -n "''${TEST_DELETE_OWNED:-}" ]]; then
        rm -f "''${FLAKE_ROOT}/''${TEST_DELETE_OWNED}"
      fi
      # The placeholder the orchestrator handed this version's update is the pin a new branch starts its life
      # with, so a case that cares about its shape reads it before the fixture rewrites it.
      if [[ -n "''${TEST_CAPTURED_PIN:-}" ]]; then
        cp "''${FLAKE_ROOT}/pin.nix" "''${TEST_CAPTURED_PIN}"
      fi
      if [[ "''${PIN_SCHEMA:-}" == "oci" ]]; then
        UPDATED_DIGEST="sha256:$(printf 'b%.0s' {1..64})"
        UPDATED_HASH="sha256-$(printf 'd%.0s' {1..43})="
        printf '%s\n' \
          '{' \
          "  version = \"''${TARGET_VERSION}\";" \
          "  imageDigest = \"''${UPDATED_DIGEST}\";" \
          "  imageHash = \"''${UPDATED_HASH}\";" \
          '}' > "''${FLAKE_ROOT}/pin.nix"
      else
        printf '%s\n' \
          '{' \
          "  version = \"''${TARGET_VERSION}\";" \
          '  assets.fixture = "updated-hash";' \
          '}' > "''${FLAKE_ROOT}/pin.nix"
      fi
      if [[ -n "''${TEST_STAGE_OWNED:-}" ]]; then
        [[ "''${ORCHESTRATED_OWNED_FILES}" == 'pin.nix flake.lock wheels-*.json' ]]
        rm -f "''${FLAKE_ROOT}/wheels-3.14.json"
        printf '%s\n' migrated > "''${FLAKE_ROOT}/wheels-3.14-x86_64-linux.json"
        read -r -a OWNED_PATTERNS <<<"''${ORCHESTRATED_OWNED_FILES}"
        git -C "''${FLAKE_ROOT}" add -A -- "''${OWNED_PATTERNS[@]}"
      fi
    '';
  };
in
{
  inherit
    build-and-check-test-shim
    build-packages-test-shim
    update-branches-test-nix
    ;
}
