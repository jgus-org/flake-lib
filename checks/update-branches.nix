# The branch updater: its suites, and the greps that read the baked knobs out of the generated script.
{
  exampleSource,
  lib,
  pkgs,
}:
let
  fixtures = import ./fakes.nix { inherit pkgs; };

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

  update-branches-test-gh = pkgs.writeShellApplication {
    name = "gh";
    text = ''
      # Discovery consults one endpoint per source and asks for one numbered page per
      # request, so record each request and read from that log how many times this
      # page has already been asked for.
      endpoint=""
      for argument in "$@"; do
        if [[ "''${argument}" == /* ]]; then
          endpoint="''${argument}"
          break
        fi
      done
      attempts=0
      if [[ -n "''${TEST_GH_ENDPOINTS:-}" ]]; then
        if [[ -f "''${TEST_GH_ENDPOINTS}" ]]; then
          attempts="$(grep -c -x -F -- "''${endpoint}" "''${TEST_GH_ENDPOINTS}" || true)"
        fi
        printf '%s\n' "''${endpoint}" >> "''${TEST_GH_ENDPOINTS}"
      fi
      # A request naming no page is the single-shot lookup an updater other than
      # discovery makes, and it reaches the page-one content.
      page="''${endpoint##*page=}"
      if [[ "''${page}" == "''${endpoint}" ]]; then
        page=1
      fi
      # A page named as dead never answers; a page named as flaky fails the request
      # that first reaches it and answers the retry.
      if [[ " ''${TEST_GH_DEAD_PAGES:-} " == *" ''${page} "* ]] ||
        {
          [[ " ''${TEST_GH_FLAKY_PAGES:-} " == *" ''${page} "* ]] &&
            [[ "''${attempts}" == "0" ]]
        }; then
        printf 'gh: could not respond in time (HTTP 504)\n' >&2
        exit 1
      fi
      names=""
      case "''${endpoint%%'?'*}" in
      */tags)
        if [[ "''${page}" == "1" ]]; then
          names="''${TEST_TAGS_VERSIONS:-}"
        else
          names="''${TEST_TAGS_VERSIONS_NEXT:-}"
        fi
        ;;
      *)
        if [[ "''${page}" == "1" ]]; then
          names="''${TEST_VERSIONS:-}"
        else
          names="''${TEST_VERSIONS_NEXT:-}"
        fi
        ;;
      esac
      printf '%s\n' "''${names}"
    '';
  };

  update-branches-test-curl = pkgs.writeShellApplication {
    name = "curl";
    runtimeInputs = [ pkgs.jq ];
    text = ''
      case "''${*}" in
        *'/tags/list'* | *'/token'*) exec ${fixtures.registry-test-curl}/bin/registry-test-curl "''${@}" ;;
      esac
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
in
{
  update-branches-tests =
    pkgs.runCommand "update-branches-tests"
      {
        # The publication path runs the gate a pull request runs, from the same script texts the published tools wrap, so the fixture's fake `nix` has to be reached through those texts rather than a stand-in for them.
        BUILD_AND_CHECK_SCRIPT = "${fixtures.build-and-check-test-shim}/bin/build-and-check";
        BUILD_PACKAGES_SCRIPT = "${fixtures.build-packages-test-shim}/bin/build-packages";
        BUILD_PACKAGES_SELECT = ../scripts/build-packages-select.nix;
        CASCADE_PY = ../scripts/cascade.py;
        DEPS_CORE = ../scripts/deps_core.py;
        GIT_PUSH_LIB = ../scripts/git-push.sh;
        REGISTRY_TAGS_LIB = ../scripts/registry-tags.sh;
        UPDATE_BRANCHES_CORE = ../scripts/update-branches-core.sh;
        nativeBuildInputs = [
          pkgs.bash
          pkgs.coreutils
          pkgs.git
          pkgs.gnused
          pkgs.jq
          (pkgs.python3.withPackages (pythonPackages: [ pythonPackages.packaging ]))
          update-branches-test-gh
          update-branches-test-curl
          fixtures.update-branches-test-nix
        ];
      }
      ''
        # The tracking knobs are baked into each package at instantiation, not the
        # workflow env: the default package carries the defaults, one that sets the knobs
        # carries its values. This is what lets the workflow ship no env block for them.
        grep -Fx "MINIMUM_TRACKING_VERSION=0.0.0" ${update-branches}/bin/update-branches > /dev/null
        grep -Fx "TRACK_STABLE_ONLY=false" ${update-branches}/bin/update-branches > /dev/null
        grep -Fx "MINIMUM_TRACKING_VERSION=1.2.3" ${update-branches-knobs}/bin/update-branches > /dev/null
        grep -Fx "TRACK_STABLE_ONLY=true" ${update-branches-knobs}/bin/update-branches > /dev/null
        ! grep -Fx "BUILD_VERIFICATION_SKIP=true" ${update-branches}/bin/update-branches
        grep -Fx "BUILD_VERIFICATION_SKIP=true" ${update-branches-knobs}/bin/update-branches > /dev/null
        bash ${./test_update_branches.sh}
        touch $out
      '';
}
