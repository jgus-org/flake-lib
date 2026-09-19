{
  description = "Shared library for jgus sub-flakes: per-version-branch orchestrator, update-version machinery, and PyPI package builders.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    let
      pythonPolicy = {
        pythonVersions = [ "3.14" "3.15" ];
        platform = "x86_64-manylinux_2_28";
      };
    in
    {
      lib = import ./lib { inherit pythonPolicy; };
    }
    //
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        inherit (self) lib;
        # Building the generators fetches nothing — writeShellApplication only shellchecks the exec wrappers.
        exampleSource = { type = "pypi"; pname = "iso639_lang"; format = "sdist"; };
        update-version = lib.mkUpdateVersion { inherit pkgs; source = exampleSource; buildAttr = "iso639-lang"; };
        update-branches = lib.mkUpdateBranches { inherit pkgs; source = exampleSource; pinSchema = "pypi"; };
        update-version-pypi-cargo = lib.mkUpdateVersion {
          inherit pkgs;
          source = exampleSource;
          buildAttr = "example";
          buildFailureHash = "cargoHash";
          verification = "evaluate";
        };
        update-branches-pypi-cargo = lib.mkUpdateBranches {
          inherit pkgs;
          source = exampleSource;
          pinSchema = "pypi";
          extraHashes = [ "cargoHash" ];
        };
        update-version-github = lib.mkUpdateVersion {
          inherit pkgs;
          source = { type = "github"; owner = "example"; repo = "example"; };
          buildAttr = "example";
          hashMode = "build-failure";
          extraHashes = [ "npmDepsHash" ];
        };
        update-version-github-pnpm = lib.mkUpdateVersion {
          inherit pkgs;
          source = { type = "github"; owner = "example"; repo = "example"; };
          buildAttr = "example";
          buildFailureHash = "pnpmDepsHash";
        };
        update-branches-github-pnpm = lib.mkUpdateBranches {
          inherit pkgs;
          source = { type = "github"; owner = "example"; repo = "example"; };
          pinSchema = "github-pnpm";
        };
        revalidate-hash = lib.mkRevalidateHash { inherit pkgs; buildAttr = "example"; };
        # track="commit": default-branch HEAD becomes version 0-unstable-DATE.
        update-version-github-commit = lib.mkUpdateVersion {
          inherit pkgs;
          source = { type = "github"; owner = "example"; repo = "example"; track = "commit"; };
          buildAttr = "example";
        };
        update-version-huggingface = lib.mkUpdateVersion {
          inherit pkgs;
          source = {
            type = "huggingface";
            repo = "example/model";
            files = [ "config.json" ];
            manifest = {
              path = "model-manifest.json";
              exclude = [ "^\\." ];
            };
          };
          buildAttr = "model";
        };
        npm-shipped-hook = lib.mkJsDepsHook { inherit pkgs; manager = "npm"; fetcherVersion = 2; };
        wheelhouse-example-hook = (lib.mkPythonWheelhouse {
          inherit pkgs;
          sources = [{ kind = "repo-file"; path = "requirements.in"; }];
        }).hook;
        npm-generated-hook = lib.mkJsDepsHook { inherit pkgs; manager = "npm"; source = "generated"; };
        yarn-hook = lib.mkJsDepsHook { inherit pkgs; manager = "yarn"; };
        composed-hook = lib.mkComposedHook { inherit pkgs; hooks = [ npm-generated-hook yarn-hook ]; };
        hookCheck = name: exe: pkgs.runCommand name { } "test -x ${exe} && touch $out";
        cascade-tests = pkgs.runCommand "cascade-tests"
          {
            nativeBuildInputs = [ (pkgs.python3.withPackages (pythonPackages: [ pythonPackages.packaging ])) ];
            CASCADE_PY = ./scripts/cascade.py;
            DEPS_CORE = ./scripts/deps_core.py;
          } ''
          python3 ${./tests/test_cascade.py}
          touch $out
        '';
        deps-core-tests = pkgs.runCommand "deps-core-tests"
          {
            nativeBuildInputs = [ (pkgs.python3.withPackages (pythonPackages: [ pythonPackages.packaging ])) ];
            DEPS_CORE = ./scripts/deps_core.py;
          } ''
          python3 ${./tests/test_deps_core.py}
          touch $out
        '';
        version-matches-comparison-tests =
          let
            failures = pkgs.lib.runTests (import ./tests/version-matches-comparison.nix { inherit (lib) versionMatchesComparison; });
          in
          pkgs.lib.throwIf (failures != [ ]) "versionMatchesComparison tests failed"
            (pkgs.runCommand "version-matches-comparison-tests" { } "touch $out");
        eval-marker-tree-tests =
          let
            failures = pkgs.lib.runTests (import ./tests/eval-marker-tree.nix { inherit (lib) evalMarkerTree; });
          in
          pkgs.lib.throwIf (failures != [ ]) "evalMarkerTree tests failed"
            (pkgs.runCommand "eval-marker-tree-tests" { } "touch $out");
        wheelhouse-tags-tests =
          let
            failures = pkgs.lib.runTests (import ./tests/wheelhouse-tags.nix { inherit (lib) platformTags; });
          in
          pkgs.lib.throwIf (failures != [ ]) "platformTags tests failed"
            (pkgs.runCommand "wheelhouse-tags-tests" { } "touch $out");
        python-wheelhouse-tests = pkgs.runCommand "python-wheelhouse-tests"
          {
            nativeBuildInputs = [ pkgs.bash (pkgs.python3.withPackages (pythonPackages: [ pythonPackages.packaging ])) ];
            TEST_BASH = pkgs.bash;
            WHEELHOUSE_PY = ./scripts/python-wheelhouse.py;
            DEPS_CORE = ./scripts/deps_core.py;
          } ''
          python3 ${./tests/test_python_wheelhouse.py}
          touch $out
        '';
        python-wheelhouse-integration =
          let
            wheelhouse = (lib.mkWheelhouse { inherit pkgs; wheels = ./tests/fixtures/mini-wheels.json; }).wheelhouse;
            python = pkgs.python313;
          in
          pkgs.runCommand "python-wheelhouse-integration"
            {
              nativeBuildInputs = [ pkgs.uv pkgs.autoPatchelfHook ];
              buildInputs = [ pkgs.stdenv.cc.cc.lib pkgs.zlib ];
            } ''
            export HOME=$TMPDIR
            mkdir "$out"
            ${lib.installWheelhouse { inherit python; target = "$out"; inherit wheelhouse; }}
            PYTHONPATH="$out" ${python}/bin/python -c 'import attrs, iniconfig, msgpack'
          '';
        update-branches-test-gh = pkgs.writeShellApplication {
          name = "gh";
          text = ''printf '%s\n' "''${TEST_VERSIONS}"'';
        };
        update-branches-test-nix = pkgs.writeShellApplication {
          name = "nix";
          runtimeInputs = [ pkgs.git pkgs.gnugrep ];
          text = ''
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
            [[ "''${1}" == "run" ]]
            grep -Fq 'assets.fixture' "''${FLAKE_ROOT}/pin.nix"
            while [[ "''${1}" != "--" ]]; do
              shift
            done
            shift
            TARGET_VERSION="''${1}"
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
            printf '%s\n' \
              '{' \
              "  version = \"''${TARGET_VERSION}\";" \
              '  assets.fixture = "updated-hash";' \
              '}' > "''${FLAKE_ROOT}/pin.nix"
          '';
        };
        update-version-test-gh = pkgs.writeShellApplication {
          name = "gh";
          text = ''
            case "''${*}" in
              *'/releases/latest'*) printf '%s\n' "''${TEST_RELEASE_TAG}" ;;
              *'/tags'*) printf '%s\n' "''${TEST_TAGS}" ;;
              *'/commits/'*) printf '%s\n' source-revision ;;
              *) exit 1 ;;
            esac
          '';
        };
        update-version-test-curl = pkgs.writeShellApplication {
          name = "curl";
          text = ''
            [[ "''${*}" == *'huggingface.co/api/models/'*'?blobs=true'* ]]
            printf '%s\n' "''${TEST_HF_METADATA}"
          '';
        };
        update-version-test-nix = pkgs.writeShellApplication {
          name = "nix";
          text = ''
            case "''${1}" in
              eval) ;;
              flake) printf '%s\n' '{}' > "''${FLAKE_ROOT}/flake.lock" ;;
              *) exit 1 ;;
            esac
          '';
        };
        update-version-test-prefetch = pkgs.writeShellApplication {
          name = "nix-prefetch-github";
          text = ''printf '%s\n' '{"hash":"sha256-source"}' '';
        };
        update-version-tests = pkgs.runCommand "update-version-tests"
          {
            nativeBuildInputs = [
              pkgs.bash
              pkgs.coreutils
              pkgs.gnugrep
              pkgs.jq
              update-version-test-gh
              update-version-test-curl
              update-version-test-nix
              update-version-test-prefetch
            ];
            UPDATE_VERSION = ./scripts/update-version.sh;
          } ''
            bash ${./tests/test_update_version.sh}
            touch "''${out}"
          '';
        update-branches-tests = pkgs.runCommand "update-branches-tests"
          {
            nativeBuildInputs = [
              pkgs.bash
              pkgs.coreutils
              pkgs.git
              pkgs.gnused
              pkgs.jq
              (pkgs.python3.withPackages (pythonPackages: [ pythonPackages.packaging ]))
              update-branches-test-gh
              update-branches-test-nix
            ];
            CASCADE_PY = ./scripts/cascade.py;
            DEPS_CORE = ./scripts/deps_core.py;
            UPDATE_BRANCHES_CORE = ./scripts/update-branches-core.sh;
          } ''
          bash ${./tests/test_update_branches.sh}
          touch $out
        '';
      in
      {
        packages = { inherit update-version update-branches update-version-pypi-cargo update-branches-pypi-cargo update-version-github update-version-github-pnpm update-version-github-commit update-version-huggingface update-branches-github-pnpm revalidate-hash; };
        checks = {
          inherit update-version update-branches update-version-pypi-cargo update-branches-pypi-cargo update-version-github update-version-github-pnpm update-version-github-commit update-version-huggingface update-branches-github-pnpm revalidate-hash;
          npm-shipped-hook = hookCheck "npm-shipped-hook" npm-shipped-hook;
          npm-generated-hook = hookCheck "npm-generated-hook" npm-generated-hook;
          yarn-hook = hookCheck "yarn-hook" yarn-hook;
          composed-hook = hookCheck "composed-hook" composed-hook;
          wheelhouse-hook = hookCheck "wheelhouse-hook" wheelhouse-example-hook;
          inherit cascade-tests deps-core-tests update-branches-tests version-matches-comparison-tests eval-marker-tree-tests wheelhouse-tags-tests python-wheelhouse-tests python-wheelhouse-integration;
          inherit update-version-tests;
        };
      });
}
