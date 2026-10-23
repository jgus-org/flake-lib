{
  description = "Shared library for jgus sub-flakes: recurring flake-production patterns — per-version-branch orchestrator, update-version machinery, artifact producers, and the install shapes they share.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    treefmt-nix = {
      inputs.nixpkgs.follows = "nixpkgs";
      url = "github:numtide/treefmt-nix";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      treefmt-nix,
    }:
    let
      lib = import ./lib { inherit nixpkgs treefmt-nix; };
    in
    {
      inherit lib;
    }
    // lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
        orgFormatting = lib.mkFormatting {
          inherit self system;
        };
        # Building the generators fetches nothing — writeShellApplication only shellchecks the exec wrappers.
        exampleSource = {
          format = "sdist";
          pname = "iso639_lang";
          type = "pypi";
        };
        update-version = lib.mkUpdateVersion {
          inherit pkgs;
          source = exampleSource;
        };
        update-branches = lib.mkUpdateBranches {
          inherit pkgs;
          pinSchema = "pypi";
          source = exampleSource;
        };
        update-branches-knobs = lib.mkUpdateBranches {
          inherit pkgs;
          buildVerificationSkip = true;
          minimumTrackingVersion = "1.2.3";
          pinSchema = "pypi";
          source = exampleSource;
          trackStableOnly = true;
        };
        # The tool every producer's workflow invokes by flake URL. Not a lib function:
        # it takes no inputs from the caller, so a per-producer copy would be identical
        # boilerplate that also pins the program to the caller's own locked revision.
        update-workflows = pkgs.writeShellApplication {
          name = "update-workflows";
          runtimeEnv.GIT_PUSH_LIB = pkgs.copyPathToStore ./scripts/git-push.sh;
          text = ''exec ${./scripts/update-workflows.sh} "$@"'';
        };
        # A flake's published packages are what its consumers build and `nix flake check`
        # only evaluates them, so the build is a tool of its own: what to build is read from
        # the tree it runs in, exactly as the refresher reads the tree it rewrites.
        build-packages = pkgs.writeShellApplication {
          name = "build-packages";
          runtimeEnv.BUILD_PACKAGES_SELECT = pkgs.copyPathToStore ./scripts/build-packages-select.nix;
          runtimeInputs = [ pkgs.jq ];
          text = ''exec ${./scripts/build-packages.sh} "$@"'';
        };
        # Ordering is observed from the consumer side, so like the refresher this takes nothing
        # from the caller: its edges are the caller's own flake inputs, read from its lock.
        wait-for-deps = pkgs.writeShellApplication {
          name = "wait-for-deps";
          runtimeInputs = [ pkgs.python3 ];
          text = ''exec python3 ${./scripts/wait_for_deps.py} "$@"'';
        };
        update-version-pypi-cargo = lib.mkUpdateVersion {
          inherit pkgs;
          buildFailureHash = "cargoHash";
          source = exampleSource;
        };
        update-branches-pypi-cargo = lib.mkUpdateBranches {
          inherit pkgs;
          extraHashes = [ "cargoHash" ];
          pinSchema = "pypi";
          source = exampleSource;
        };
        update-version-github = lib.mkUpdateVersion {
          inherit pkgs;
          extraHashes = [ "npmDepsHash" ];
          hashMode = "build-failure";
          source = {
            owner = "example";
            repo = "example";
            type = "github";
          };
        };
        update-version-github-pnpm = lib.mkUpdateVersion {
          inherit pkgs;
          buildFailureHash = "pnpmDepsHash";
          source = {
            owner = "example";
            repo = "example";
            type = "github";
          };
        };
        update-version-github-pnpm-go = lib.mkUpdateVersion {
          inherit pkgs;
          buildFailureHashes = [
            "pnpmDepsHash"
            "vendorHash"
          ];
          source = {
            owner = "example";
            repo = "example";
            type = "github";
          };
        };
        update-branches-github-pnpm = lib.mkUpdateBranches {
          inherit pkgs;
          pinSchema = "github-pnpm";
          source = {
            owner = "example";
            repo = "example";
            type = "github";
          };
        };
        revalidate-hash = lib.mkRevalidateHash {
          inherit pkgs;
        };
        # track="commit": default-branch HEAD becomes version 0-unstable-DATE.
        update-version-github-commit = lib.mkUpdateVersion {
          inherit pkgs;
          source = {
            owner = "example";
            repo = "example";
            track = "commit";
            type = "github";
          };
        };
        update-version-huggingface = lib.mkUpdateVersion {
          inherit pkgs;
          source = {
            files = [ "config.json" ];
            manifest = {
              exclude = [ "^\\." ];
              path = "model-manifest.json";
            };
            repo = "example/model";
            type = "huggingface";
          };
        };
        update-version-mutable-url = lib.mkUpdateVersion {
          inherit pkgs;
          source = {
            type = "mutable-url";
            url = "https://downloads.example.test/artifact.bin";
          };
        };
        update-version-oci = lib.mkUpdateVersion {
          inherit pkgs;
          source = {
            arch = "amd64";
            imageName = "registry.example/image";
            os = "linux";
            tag = "latest-sm86";
            type = "oci";
          };
        };
        # source.versions opts an OCI producer into the version tree; the image tag is its version, so the spec pins no tag.
        ociVersionedSource = {
          arch = "amd64";
          imageName = "registry.example/image";
          os = "linux";
          type = "oci";
          versions = {
            owner = "example";
            repo = "example";
            type = "github";
          };
        };
        update-version-oci-github = lib.mkUpdateVersion {
          inherit pkgs;
          source = ociVersionedSource;
        };
        update-branches-oci-github = lib.mkUpdateBranches {
          inherit pkgs;
          pinSchema = "oci";
          source = ociVersionedSource;
        };
        oci-image-tests = import ./tests/oci-image.nix { inherit lib pkgs; };
        npm-shipped-hook = lib.mkJsDepsHook {
          inherit pkgs;
          fetcherVersion = 2;
          manager = "npm";
        };
        wheelhouse-example = lib.mkPythonWheelhouse {
          inherit pkgs;
          sources = [
            {
              kind = "repo-file";
              path = "requirements.in";
            }
          ];
        };
        huggingface-model-manager = lib.mkHuggingFaceModelManager {
          inherit pkgs;
          manifest = pkgs.writeText "huggingface-model-manager-manifest.json" ''
            {
              "repo": "example/model",
              "revision": "revision-one",
              "total_bytes": 32,
              "files": [
                { "path": "sha256.txt", "bytes": 15, "sha256": "85ad1c506a0c0e1eb1b7d36d4a5128b90d2e411863baf1f275279aec8b3e458a" },
                { "path": "git-blob.txt", "bytes": 17, "sha256": null, "git_blob": "9a5c9c50f67f7be093ed07dc3bc185066b5c9067" }
              ]
            }
          '';
          model = { };
          name = "huggingface-model-manager";
        };
        wheelhouse-example-hook = wheelhouse-example.hook;
        npm-generated-hook = lib.mkJsDepsHook {
          inherit pkgs;
          manager = "npm";
          source = "generated";
        };
        yarn-hook = lib.mkJsDepsHook {
          inherit pkgs;
          manager = "yarn";
        };
        composed-hook = lib.mkComposedHook {
          inherit pkgs;
          hooks = [
            npm-generated-hook
            yarn-hook
          ];
        };
        hookCheck = name: exe: pkgs.runCommand name { } "test -x ${exe} && touch $out";
        cascade-tests =
          pkgs.runCommand "cascade-tests"
            {
              CASCADE_PY = ./scripts/cascade.py;
              DEPS_CORE = ./scripts/deps_core.py;
              nativeBuildInputs = [ (pkgs.python3.withPackages (pythonPackages: [ pythonPackages.packaging ])) ];
            }
            ''
              python3 ${./tests/test_cascade.py}
              touch $out
            '';
        deps-core-tests =
          pkgs.runCommand "deps-core-tests"
            {
              DEPS_CORE = ./scripts/deps_core.py;
              nativeBuildInputs = [ (pkgs.python3.withPackages (pythonPackages: [ pythonPackages.packaging ])) ];
            }
            ''
              python3 ${./tests/test_deps_core.py}
              touch $out
            '';
        version-matches-comparison-tests =
          let
            failures = pkgs.lib.runTests (
              import ./tests/version-matches-comparison.nix { inherit (lib) versionMatchesComparison; }
            );
          in
          pkgs.lib.throwIf (failures != [ ]) "versionMatchesComparison tests failed" (
            pkgs.runCommand "version-matches-comparison-tests" { } "touch $out"
          );
        eval-marker-tree-tests =
          let
            failures = pkgs.lib.runTests (
              import ./tests/eval-marker-tree.nix { inherit (lib) evalMarkerTree; }
            );
          in
          pkgs.lib.throwIf (failures != [ ]) "evalMarkerTree tests failed" (
            pkgs.runCommand "eval-marker-tree-tests" { } "touch $out"
          );
        default-systems-tests =
          let
            failures = pkgs.lib.runTests (
              import ./tests/default-systems.nix {
                inherit (lib)
                  defaultLinuxSystems
                  defaultSystems
                  eachDefaultLinuxSystem
                  eachDefaultSystem
                  ;
              }
            );
          in
          pkgs.lib.throwIf (failures != [ ]) "defaultSystems tests failed" (
            pkgs.runCommand "default-systems-tests" { } "touch $out"
          );
        wheelhouse-tags-tests =
          let
            failures = pkgs.lib.runTests (import ./tests/wheelhouse-tags.nix { inherit (lib) platformTags; });
          in
          pkgs.lib.throwIf (failures != [ ]) "platformTags tests failed" (
            pkgs.runCommand "wheelhouse-tags-tests" { } "touch $out"
          );
        wheelhouse-environment-tests =
          let
            x86 = lib.mkPythonWheelhouse {
              inherit pkgs;
              pythonVersions = [ "3.13" ];
              sources = [
                {
                  kind = "repo-file";
                  path = "requirements.in";
                }
              ];
              systems = [ "x86_64-linux" ];
            };
            arm = lib.mkPythonWheelhouse {
              inherit pkgs;
              pythonVersions = [ "3.13" ];
              sources = [
                {
                  kind = "repo-file";
                  path = "requirements.in";
                }
              ];
              systems = [ "aarch64-linux" ];
            };
            unsupportedSystem = builtins.tryEval (
              lib.wheelhouseArtifactPaths {
                pythonVersion = "3.13";
                root = ./.;
                system = "armv7-linux";
              }
            );
            unsupportedPython = builtins.tryEval (
              lib.wheelhouseArtifactPaths {
                pythonVersion = "3.12";
                root = ./.;
                system = "x86_64-linux";
              }
            );
            customPython = lib.wheelhouseArtifactPaths {
              pythonVersion = "3.12";
              pythonVersions = [ "3.12" ];
              root = ./.;
              system = "x86_64-linux";
            };
          in
          assert x86.fingerprint != arm.fingerprint;
          assert !unsupportedSystem.success;
          assert !unsupportedPython.success;
          assert builtins.baseNameOf customPython.wheelManifest == "wheels-3.12-x86_64-linux.json";
          pkgs.runCommand "wheelhouse-environment-tests" { } "touch $out";
        wheelhouse-fingerprint-tests =
          let
            changedMenu = lib.mkPythonWheelhouse {
              inherit pkgs;
              pythonVersions = [ "3.13" ];
              sources = [
                {
                  kind = "repo-file";
                  path = "requirements.in";
                }
              ];
            };
            changedSource = lib.mkPythonWheelhouse {
              inherit pkgs;
              extraRequirements = [ "example" ];
              sources = [
                {
                  kind = "repo-file";
                  path = "requirements.in";
                }
              ];
            };
            changedIndex = lib.mkPythonWheelhouse {
              inherit pkgs;
              index = "https://index.example.test/simple";
              sources = [
                {
                  kind = "repo-file";
                  path = "requirements.in";
                }
              ];
            };
            reordered = lib.mkPythonWheelhouse {
              inherit pkgs;
              pythonVersions = [
                "3.14"
                "3.13"
              ];
              sources = [
                {
                  kind = "repo-file";
                  path = "requirements.in";
                }
              ];
            };
          in
          assert wheelhouse-example.fingerprint != changedMenu.fingerprint;
          assert wheelhouse-example.fingerprint != changedSource.fingerprint;
          assert wheelhouse-example.fingerprint != changedIndex.fingerprint;
          assert wheelhouse-example.fingerprint != reordered.fingerprint;
          pkgs.runCommand "wheelhouse-fingerprint-tests" { } "touch $out";
        wheelhouse-consumer-selection-tests =
          let
            python = pkgs.python313;
            artifacts = lib.wheelhouseArtifactPaths {
              pythonVersion = python.pythonVersion;
              root = ./.;
              system = "aarch64-linux";
            };
          in
          assert builtins.baseNameOf artifacts.requirementsLock == "requirements-3.13-aarch64-linux.lock";
          assert builtins.baseNameOf artifacts.wheelManifest == "wheels-3.13-aarch64-linux.json";
          pkgs.runCommand "wheelhouse-consumer-selection-tests" { } "touch $out";
        python-wheelhouse-tests =
          pkgs.runCommand "python-wheelhouse-tests"
            {
              DEPS_CORE = ./scripts/deps_core.py;
              TEST_BASH = pkgs.bash;
              WHEELHOUSE_PY = ./scripts/python-wheelhouse.py;
              nativeBuildInputs = [
                pkgs.bash
                (pkgs.python3.withPackages (pythonPackages: [ pythonPackages.packaging ]))
              ];
            }
            ''
              python3 ${./tests/test_python_wheelhouse.py}
              touch $out
            '';
        python-wheelhouse-integration =
          let
            wheelhouse =
              (lib.mkWheelhouse {
                inherit pkgs;
                wheels = ./tests/fixtures/mini-wheels.json;
              }).wheelhouse;
            python = pkgs.python313;
          in
          pkgs.runCommand "python-wheelhouse-integration"
            {
              buildInputs = [
                pkgs.stdenv.cc.cc.lib
                pkgs.zlib
              ];
              nativeBuildInputs = [
                pkgs.uv
                pkgs.autoPatchelfHook
              ];
            }
            ''
              export HOME=$TMPDIR
              mkdir "$out"
              ${lib.installWheelhouse {
                inherit python;
                inherit wheelhouse;
                target = "$out";
              }}
              PYTHONPATH="$out" ${python}/bin/python -c 'import attrs, iniconfig, msgpack'
            '';
        wheelhouse-no-emit-tests =
          let
            failures = pkgs.lib.runTests (
              import ./tests/wheelhouse-no-emit.nix {
                inherit pkgs;
                inherit (lib) mkWheelhouse;
              }
            );
          in
          pkgs.lib.throwIf (failures != [ ]) "mkWheelhouse noEmit tests failed" (
            pkgs.runCommand "wheelhouse-no-emit-tests" { } "touch $out"
          );
        # The manifest names a wheel the consumer provides itself; the installed tree must not carry it, and
        # must not need the interpreter-side fixups the vendored copy would have dragged in.
        python-wheelhouse-no-emit-integration =
          let
            wheelhouse =
              (lib.mkWheelhouse {
                inherit pkgs;
                noEmit = [ "msgpack" ];
                wheels = ./tests/fixtures/mini-wheels.json;
              }).wheelhouse;
            python = pkgs.python313;
          in
          pkgs.runCommand "python-wheelhouse-no-emit-integration" { nativeBuildInputs = [ pkgs.uv ]; } ''
            export HOME=$TMPDIR
            mkdir "$out"
            ${lib.installWheelhouse {
              inherit python;
              inherit wheelhouse;
              target = "$out";
            }}
            test ! -e "$out/msgpack"
            ! PYTHONPATH="$out" ${python}/bin/python -c 'import msgpack'
            PYTHONPATH="$out" ${python}/bin/python -c 'import attrs, iniconfig'
          '';
        python-wheelhouse-site-tree-integration = lib.mkWheelhouseSiteTree {
          inherit pkgs;
          checkImports = [ "numpy" ];
          dontUnpack = true;
          pname = "python-wheelhouse-site-tree";
          python = pkgs.python313;
          version = "1";
          wheelhouse =
            (lib.mkWheelhouse {
              inherit pkgs;
              wheels = ./tests/fixtures/native-wheels.json;
            }).wheelhouse;
        };
        # The import check above only measures a real rewrite if the same wheel cannot import untouched.
        python-wheelhouse-site-tree-unpatched-import =
          let
            python = pkgs.python313;
            wheel =
              pkgs.lib.head
                (lib.mkWheelhouse {
                  inherit pkgs;
                  wheels = ./tests/fixtures/native-wheels.json;
                }).files;
          in
          pkgs.runCommand "python-wheelhouse-site-tree-unpatched-import"
            {
              nativeBuildInputs = [
                pkgs.unzip
                python
              ];
            }
            ''
              mkdir -p "$out/${python.sitePackages}"
              unzip -q ${wheel} -d "$out/${python.sitePackages}"
              test ! -e "$out/${python.sitePackages}/numpy.libs/libstdc++.so.6"
              ! env -i PYTHONPATH="$out/${python.sitePackages}" ${python}/bin/python -c 'import numpy'
            '';
        huggingface-model-manager-tests =
          pkgs.runCommand "huggingface-model-manager-tests"
            {
              MODEL_MANAGER = "${huggingface-model-manager}/bin/huggingface-model-manager";
              nativeBuildInputs = [
                pkgs.python3
                huggingface-model-manager
              ];
            }
            ''
              python3 ${./tests/test_huggingface_model_manager.py}
              touch "$out"
            '';
        update-branches-test-gh = pkgs.writeShellApplication {
          name = "gh";
          text = ''
            # Discovery consults one endpoint per source, so record which one a tracking
            # mode reached for rather than only what came back from it.
            endpoint="''${3:-}"
            if [[ -n "''${TEST_GH_ENDPOINTS:-}" ]]; then
              printf '%s\n' "''${endpoint}" >> "''${TEST_GH_ENDPOINTS}"
            fi
            if [[ "''${endpoint}" == */tags ]]; then
              if [[ -n "''${TEST_TAGS_VERSIONS:-}" ]]; then
                printf '%s\n' "''${TEST_TAGS_VERSIONS}"
              fi
            else
              printf '%s\n' "''${TEST_VERSIONS}"
            fi
          '';
        };
        update-branches-test-curl = pkgs.writeShellApplication {
          name = "curl";
          runtimeInputs = [ pkgs.jq ];
          text = ''
            # GitLab names the page that follows in a response header, so the fake writes
            # the header dump the orchestrator asked for as well as the body it reads.
            headers=""
            url=""
            while [[ $# -gt 0 ]]; do
              if [[ "''${1}" == "-D" ]]; then
                headers="''${2}"
                shift 2
              else
                url="''${1}"
                shift
              fi
            done
            if [[ -n "''${TEST_GITLAB_ENDPOINTS:-}" ]]; then
              printf '%s\n' "''${url}" >> "''${TEST_GITLAB_ENDPOINTS}"
            fi
            names="''${TEST_GITLAB_TAGS:-}"
            page="''${url##*page=}"
            if [[ "''${page}" != "1" ]]; then
              names="''${TEST_GITLAB_TAGS_NEXT:-}"
            fi
            if [[ -n "''${headers}" ]]; then
              if [[ ( "''${page}" == "1" || -n "''${TEST_GITLAB_ALWAYS_NEXT_PAGE:-}" ) && -n "''${TEST_GITLAB_NEXT_PAGE:-}" ]]; then
                printf 'HTTP/2 200\r\nX-Next-Page: %s\r\n\r\n' "''${TEST_GITLAB_NEXT_PAGE}" > "''${headers}"
              else
                printf 'HTTP/2 200\r\n\r\n' > "''${headers}"
              fi
            fi
            printf '%s\n' "''${names}" | jq -R -s 'split("\n") | map(select(length > 0) | {name: .})'
          '';
        };
        update-branches-test-nix = pkgs.writeShellApplication {
          name = "nix";
          runtimeInputs = [
            pkgs.git
            pkgs.gnugrep
            pkgs.jq
          ];
          text = ''
            if [[ "''${1}" == "flake" && "''${2:-}" == "metadata" ]]; then
              printf '{ "path": "%s" }\n' "''${TEST_NIX_TEMPLATE_SOURCE:?fixture: no template source}"
              exit 0
            fi
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
            if [[ "''${1}" == "build" ]]; then
              for FAILED_VERSION in ''${TEST_NIX_BUILD_FAILURES:-}; do
                if grep -Fq "version = \"''${FAILED_VERSION}\";" pin.nix; then
                  printf 'error: fixture: packages.default does not build at %s\n' "''${FAILED_VERSION}" >&2
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
              grep -Fq 'assets.fixture' "''${FLAKE_ROOT}/pin.nix"
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
            case "''${*}" in
              *'downloads.example.test/artifact.bin'*) printf '%s\n' 'HTTP/2 200' 'Last-Modified: Tue, 25 Aug 2026 12:34:56 GMT' ;;
              *'pypi.org/pypi/'*) printf '%s\n' "''${TEST_PYPI_METADATA}" ;;
              *'huggingface.co/api/models/'*) printf '%s\n' "''${TEST_HF_METADATA}" ;;
              *) exit 1 ;;
            esac
          '';
        };
        update-version-test-nix = pkgs.writeShellApplication {
          name = "nix";
          runtimeInputs = [
            pkgs.git
            pkgs.gnused
          ];
          text = ''
            case "''${1}" in
              eval)
                if [[ "''${*}" == *'--file '* ]]; then
                  FIELD="''${*: -1}"
                  sed -nE "s/^[[:space:]]*''${FIELD}[[:space:]]*=[[:space:]]*\"([^\"]*)\";.*/\1/p" "''${FLAKE_ROOT}/pin.nix"
                elif [[ "''${TEST_OCI_FAIL:-}" == evaluate ]]; then
                  exit 42
                elif [[ -n "''${TEST_EXPECT_TRACKED_FILE:-}" ]]; then
                  git -C "''${FLAKE_ROOT}" ls-files --error-unmatch -- "''${TEST_EXPECT_TRACKED_FILE}" >/dev/null
                fi
                if [[ "''${*}" != *'--file '* && -n "''${TEST_OCI_EVALUATION_LOG:-}" ]]; then
                  printf '%s\n' evaluated >> "''${TEST_OCI_EVALUATION_LOG}"
                fi
                ;;
              flake)
                [[ "''${2}" == lock ]]
                if [[ "''${TEST_OCI_FAIL:-}" == lock ]]; then
                  printf '%s\n' '{"fixture":"partial"}' > "''${FLAKE_ROOT}/flake.lock"
                  exit 42
                fi
                if [[ ! -f "''${FLAKE_ROOT}/flake.lock" ]]; then
                  printf '%s\n' '{}' > "''${FLAKE_ROOT}/flake.lock"
                fi
                ;;
              hash)
                [[ "''${TEST_OCI_FAIL:-}" != hash ]]
                exec ${pkgs.nix}/bin/nix --extra-experimental-features nix-command "''${@}"
                ;;
              build)
                if [[ -n "''${TEST_BUILD_PLAN:-}" ]]; then
                  printf '%s\n' build >> "''${TEST_BUILD_LOG}"
                  read -r OUTCOME TEST_SPECIFIED TEST_GOT <<<"$(head -1 "''${TEST_BUILD_PLAN}")"
                  tail -n +2 "''${TEST_BUILD_PLAN}" > "''${TEST_BUILD_PLAN}.rest"
                  mv "''${TEST_BUILD_PLAN}.rest" "''${TEST_BUILD_PLAN}"
                  case "''${OUTCOME}" in
                    ok) exit 0 ;;
                    mismatch)
                      printf 'error: hash mismatch in fixed-output derivation %s:\n         specified: %s\n            got:    %s\n' "'/nix/store/fixture-fod.drv" "''${TEST_SPECIFIED}" "''${TEST_GOT}"
                      exit 1
                      ;;
                    *) exit 1 ;;
                  esac
                fi
                [[ "''${TEST_OCI_FAIL:-}" != build ]]
                ;;
              store)
                if [[ "''${*}" == *'downloads.example.test/artifact.bin'* ]]; then
                  if [[ -n "''${TEST_PREFETCH_LOG:-}" ]]; then
                    printf '%s\n' mutable-url >> "''${TEST_PREFETCH_LOG}"
                  fi
                  printf '%s\n' '{"hash":"sha256-mutable"}'
                else
                  printf '%s\n' '{"hash":"sha256-pypi"}'
                fi
                ;;
              *) exit 1 ;;
            esac
          '';
        };
        update-version-test-prefetch = pkgs.writeShellApplication {
          name = "nix-prefetch-github";
          text = ''
            [[ "''${NIX_PATH:-}" == 'nixpkgs=${pkgs.path}' ]]
            printf '%s\n' '{"hash":"sha256-source"}'
          '';
        };
        update-version-test-store = pkgs.writeShellApplication {
          name = "nix-store";
          text = ''
            [[ "''${1}" == --add-fixed ]]
            if [[ "''${2}" == --recursive ]]; then
              [[ "''${3}" == sha256 && -d "''${4}" ]]
            else
              [[ "''${2}" == sha256 && -f "''${3}" ]]
            fi
            [[ "''${TEST_OCI_FAIL:-}" != store ]]
          '';
        };
        update-version-tests =
          pkgs.runCommand "update-version-tests"
            {
              NIX_PATH = "nixpkgs=${pkgs.path}";
              TEST_BASH = pkgs.bash;
              UPDATE_VERSION = ./scripts/update-version.sh;
              nativeBuildInputs = [
                pkgs.bash
                pkgs.coreutils
                pkgs.git
                pkgs.gnugrep
                pkgs.jq
                update-version-test-gh
                update-version-test-curl
                update-version-test-nix
                update-version-test-prefetch
                update-version-test-store
              ];
            }
            ''
              grep -Fqx "NIX_PATH='nixpkgs=${pkgs.path}'" ${update-version}/bin/update-version
              bash ${./tests/test_update_version.sh}
              OCI_SKOPEO_SOURCE=${./tests/oci-skopeo.sh} bash ${./tests/test_oci.sh}
              touch "''${out}"
            '';
        update-branches-tests =
          pkgs.runCommand "update-branches-tests"
            {
              CASCADE_PY = ./scripts/cascade.py;
              DEPS_CORE = ./scripts/deps_core.py;
              GIT_PUSH_LIB = ./scripts/git-push.sh;
              UPDATE_BRANCHES_CORE = ./scripts/update-branches-core.sh;
              nativeBuildInputs = [
                pkgs.bash
                pkgs.coreutils
                pkgs.git
                pkgs.gnused
                pkgs.jq
                (pkgs.python3.withPackages (pythonPackages: [ pythonPackages.packaging ]))
                update-branches-test-gh
                update-branches-test-curl
                update-branches-test-nix
              ];
            }
            ''
              # The tracking knobs are baked into the package from flake.nix, not the workflow
              # env: the default package carries the defaults, one that sets the knobs carries
              # its values. This is what lets the workflow ship no env block for them.
              grep -Fx "MINIMUM_TRACKING_VERSION=0.0.0" ${update-branches}/bin/update-branches > /dev/null
              grep -Fx "TRACK_STABLE_ONLY=false" ${update-branches}/bin/update-branches > /dev/null
              grep -Fx "MINIMUM_TRACKING_VERSION=1.2.3" ${update-branches-knobs}/bin/update-branches > /dev/null
              grep -Fx "TRACK_STABLE_ONLY=true" ${update-branches-knobs}/bin/update-branches > /dev/null
              ! grep -Fx "BUILD_VERIFICATION_SKIP=true" ${update-branches}/bin/update-branches
              grep -Fx "BUILD_VERIFICATION_SKIP=true" ${update-branches-knobs}/bin/update-branches > /dev/null
              bash ${./tests/test_update_branches.sh}
              touch $out
            '';
        update-workflows-tests =
          pkgs.runCommand "update-workflows-tests"
            {
              GIT_PUSH_LIB = ./scripts/git-push.sh;
              UPDATE_WORKFLOWS = ./scripts/update-workflows.sh;
              nativeBuildInputs = [
                pkgs.bash
                pkgs.coreutils
                pkgs.git
                pkgs.gnused
                pkgs.jq
                update-branches-test-nix
              ];
            }
            ''
              bash ${./tests/test_update_workflows.sh}
              touch $out
            '';
        wait-for-deps-tests =
          pkgs.runCommand "wait-for-deps-tests"
            {
              WAIT_FOR_DEPS = ./scripts/wait_for_deps.py;
              nativeBuildInputs = [ pkgs.python3 ];
            }
            ''
              python3 ${./tests/test_wait_for_deps.py}
              touch $out
            '';
        build-packages-tests =
          pkgs.runCommand "build-packages-tests"
            {
              BUILD_PACKAGES = ./scripts/build-packages.sh;
              BUILD_PACKAGES_SELECT = ./scripts/build-packages-select.nix;
              nativeBuildInputs = [
                pkgs.bash
                pkgs.coreutils
                pkgs.gnugrep
                pkgs.jq
              ];
            }
            ''
              bash ${./tests/test_build_packages.sh}
              touch $out
            '';
        # The selection is pure Nix handed to `nix eval --apply`, so it is tested as pure
        # Nix: the assertions run when the flake is evaluated, not inside a builder that
        # would have to nest nix inside itself.
        build-packages-select-tests =
          let
            failures = pkgs.lib.runTests (
              import ./tests/build-packages-select.nix { select = import ./scripts/build-packages-select.nix; }
            );
          in
          pkgs.lib.throwIf (failures != [ ]) "build-packages selection tests failed" (
            pkgs.runCommand "build-packages-select-tests" { } "touch $out"
          );
        publishedTools = {
          inherit
            build-packages
            revalidate-hash
            update-branches
            update-branches-github-pnpm
            update-branches-oci-github
            update-branches-pypi-cargo
            update-version
            update-version-github
            update-version-github-commit
            update-version-github-pnpm
            update-version-github-pnpm-go
            update-version-huggingface
            update-version-mutable-url
            update-version-oci
            update-version-oci-github
            update-version-pypi-cargo
            update-workflows
            wait-for-deps
            ;
        };
        workflow-templates =
          pkgs.runCommand "workflow-templates-check"
            {
              PUBLISHED_TOOLS = pkgs.writeText "published-tools" (
                pkgs.lib.concatStringsSep "\n" (builtins.attrNames publishedTools)
              );
              nativeBuildInputs = [
                pkgs.actionlint
                pkgs.coreutils
                pkgs.gnugrep
                pkgs.shellcheck
                pkgs.yq-go
              ];
            }
            ''
              for TEMPLATE in ${./templates/workflows}/*.yml ${./.github/actions/fleet-nix-cache/action.yml}; do
                yq eval 'true' "$TEMPLATE" > /dev/null
              done
              # A workflow file GitHub refuses to parse fails every repository that installs
              # it at once, and that run has no job and no log to read -- an expression
              # written where its position has no such context is the mistake, and it is
              # caught here rather than on somebody's pull request. actionlint lints the
              # shell inside a step only when it finds shellcheck on its PATH.
              for TEMPLATE in ${./templates/workflows}/*.yml; do
                actionlint "$TEMPLATE"
              done
              # A template naming a tool this flake does not publish breaks every
              # repository that installs it at once, so the names are read from what is
              # published rather than from a second list that could disagree.
              for TOOL in $(grep -rhoE 'github:jgus-org/flake-lib/v1#[a-z0-9-]+' ${./templates/workflows} | sed 's|.*#||' | sort -u); do
                grep -Fxq "$TOOL" "$PUBLISHED_TOOLS"
              done
              touch $out
            '';
        formatting-tests =
          pkgs.runCommand "formatting-tests"
            {
              EXCLUDING_FORMATTER =
                (lib.mkFormatting {
                  inherit self system;
                  excludes = [ "skipped/**" ];
                }).formatter;
              FORMATTER = orgFormatting.formatter;
            }
            ''
              bash ${./tests/test_formatting.sh}
              touch $out
            '';
      in
      {
        checks = {
          inherit formatting-tests;
          inherit
            build-packages
            revalidate-hash
            update-branches
            update-branches-github-pnpm
            update-branches-oci-github
            update-branches-pypi-cargo
            update-version
            update-version-github
            update-version-github-commit
            update-version-github-pnpm
            update-version-github-pnpm-go
            update-version-huggingface
            update-version-mutable-url
            update-version-oci
            update-version-oci-github
            update-version-pypi-cargo
            update-workflows
            ;
          inherit
            cascade-tests
            default-systems-tests
            deps-core-tests
            eval-marker-tree-tests
            huggingface-model-manager-tests
            python-wheelhouse-integration
            python-wheelhouse-no-emit-integration
            python-wheelhouse-site-tree-integration
            python-wheelhouse-site-tree-unpatched-import
            python-wheelhouse-tests
            update-branches-tests
            version-matches-comparison-tests
            wheelhouse-consumer-selection-tests
            wheelhouse-environment-tests
            wheelhouse-fingerprint-tests
            wheelhouse-no-emit-tests
            wheelhouse-tags-tests
            ;
          inherit update-version-tests;
          inherit
            build-packages-select-tests
            build-packages-tests
            update-workflows-tests
            wait-for-deps-tests
            workflow-templates
            ;
          inherit oci-image-tests;
          composed-hook = hookCheck "composed-hook" composed-hook;
          formatting = orgFormatting.check;
          npm-generated-hook = hookCheck "npm-generated-hook" npm-generated-hook;
          npm-shipped-hook = hookCheck "npm-shipped-hook" npm-shipped-hook;
          wheelhouse-hook = hookCheck "wheelhouse-hook" wheelhouse-example-hook;
          yarn-hook = hookCheck "yarn-hook" yarn-hook;
        };
        formatter = orgFormatting.formatter;
        packages = publishedTools;
      }
    );
}
