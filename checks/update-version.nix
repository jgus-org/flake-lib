# The version updater's suites, with the grep that reads its baked NIX_PATH.
{
  exampleSource,
  lib,
  orgFormatting,
  pkgs,
}:
let
  fixtures = import ./fakes.nix { inherit pkgs; };

  update-version = lib.mkUpdateVersion {
    inherit pkgs;
    source = exampleSource;
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
        *'/tags/list'* | *'/token'*) exec ${fixtures.registry-test-curl}/bin/registry-test-curl "''${@}" ;;
      esac
      # Which host a gitlab source was asked about is what the gitlab cases read back off this log.
      if [[ -n "''${TEST_GITLAB_URL_LOG:-}" ]]; then
        for argument in "$@"; do
          if [[ "''${argument}" == *://* ]]; then
            printf '%s\n' "''${argument}" >> "''${TEST_GITLAB_URL_LOG}"
          fi
        done
      fi
      gitlab_tags="''${TEST_GITLAB_TAGS:-}"
      if [[ -z "''${gitlab_tags}" ]]; then
        gitlab_tags='[{"name":"v1.2.3"}]'
      fi
      case "''${*}" in
        *'downloads.example.test/artifact.bin'*) printf '%s\n' 'HTTP/2 200' 'Last-Modified: Tue, 25 Aug 2026 12:34:56 GMT' ;;
        *'pypi.org/pypi/'*) printf '%s\n' "''${TEST_PYPI_METADATA}" ;;
        *'huggingface.co/api/models/'*) printf '%s\n' "''${TEST_HF_METADATA}" ;;
        *'api/v4/projects/'*'/repository/branches/'*) printf '%s\n' '{"commit":{"id":"gitlab-revision","committed_date":"2026-08-25T12:34:56+00:00"}}' ;;
        *'api/v4/projects/'*'/repository/tags'*) printf '%s\n' "''${gitlab_tags}" ;;
        *'api/v4/projects/'*'/repository/commits/'*) printf '%s\n' '{"id":"gitlab-revision","committed_date":"2026-08-25T12:34:56+00:00"}' ;;
        *) exit 1 ;;
      esac
    '';
  };

  # A gitlab source's hash comes from prefetching the project's git remote, so which remote was named is the same answer the curl fixture records.
  update-version-test-prefetch-git = pkgs.writeShellApplication {
    name = "nix-prefetch-git";
    text = ''
      if [[ -n "''${TEST_GITLAB_URL_LOG:-}" ]]; then
        for argument in "$@"; do
          if [[ "''${argument}" == https://* ]]; then
            printf '%s\n' "''${argument}" >> "''${TEST_GITLAB_URL_LOG}"
          fi
        done
      fi
      printf '%s\n' '{"hash":"sha256-source"}'
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
        config)
          printf '%s\n' x86_64-linux
          ;;
        eval)
          # What `build-packages` selects comes back as JSON; the family the updater counts
          # below comes back with --raw, so the two fixture shapes tell each other apart.
          if [[ "''${*}" == *'#packages.'* && "''${*}" == *'--apply'* && "''${*}" == *'--json'* ]]; then
            printf '%s\n' '{"build":["fixture"],"skip":[]}'
            exit 0
          fi
          # The published-family evaluation the updater runs before it writes a pin. The
          # count is not what the fixture is about, only that the updater asked. The
          # failure injection and the evaluation log keep applying to it, because a run that
          # cannot evaluate what it publishes has to stop before the pin is written.
          if [[ "''${*}" == *'#packages.'* && "''${*}" == *'--apply'* ]]; then
            [[ "''${TEST_OCI_FAIL:-}" != evaluate ]] || exit 42
            if [[ -n "''${TEST_OCI_EVALUATION_LOG:-}" ]]; then
              printf '%s\n' evaluated >> "''${TEST_OCI_EVALUATION_LOG}"
            fi
            printf '1\n'
            exit 0
          fi
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
          elif [[ "''${*}" == *'/releases/download/'* ]]; then
            # Which release asset a release-asset source downloaded is the answer the asset cases read back, and the tag it came from is part of that URL.
            if [[ -n "''${TEST_PREFETCH_LOG:-}" ]]; then
              for argument in "''${@}"; do
                if [[ "''${argument}" == *'/releases/download/'* ]]; then
                  printf '%s\n' "''${argument}" >> "''${TEST_PREFETCH_LOG}"
                fi
              done
            fi
            printf '%s\n' '{"hash":"sha256-asset"}'
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
in
{
  update-version-tests =
    pkgs.runCommand "update-version-tests"
      {
        # The recovery build is the gate's own tool, so its script text reaches the fake `nix`.
        BUILD_PACKAGES_SCRIPT = "${fixtures.build-packages-test-shim}/bin/build-packages";
        BUILD_PACKAGES_SELECT = ../scripts/build-packages-select.nix;
        CASCADE_PY = ../scripts/cascade.py;
        DEPS_CORE = ../scripts/deps_core.py;
        NIX_PATH = "nixpkgs=${pkgs.path}";
        REGISTRY_TAGS_LIB = ../scripts/registry-tags.sh;
        TEST_BASH = pkgs.bash;
        TEST_FORMATTER = pkgs.lib.getExe orgFormatting.formatter;
        UPDATE_VERSION = ../scripts/update-version.sh;
        nativeBuildInputs = [
          pkgs.bash
          pkgs.coreutils
          pkgs.git
          pkgs.gnugrep
          pkgs.jq
          (pkgs.python3.withPackages (pythonPackages: [ pythonPackages.packaging ]))
          orgFormatting.formatter
          update-version-test-gh
          update-version-test-curl
          update-version-test-prefetch-git
          update-version-test-nix
          update-version-test-prefetch
          update-version-test-store
        ];
      }
      ''
        grep -Fqx "NIX_PATH='nixpkgs=${pkgs.path}'" ${update-version}/bin/update-version
        bash ${./test_update_version.sh}
        OCI_SKOPEO_SOURCE=${./oci-skopeo.sh} bash ${./test_oci.sh}
        touch "''${out}"
      '';
}
