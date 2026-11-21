# The refresher's suite, and the template lint that reads the published set out of this flake.
{
  self,
  pkgs,
  system,
}:
let
  fixtures = import ./fakes.nix { inherit pkgs; };
in
{
  update-workflows-tests =
    pkgs.runCommand "update-workflows-tests"
      {
        GIT_PUSH_LIB = ../scripts/git-push.sh;
        UPDATE_WORKFLOWS = ../scripts/update-workflows.sh;
        nativeBuildInputs = [
          pkgs.bash
          pkgs.coreutils
          pkgs.git
          pkgs.gnused
          pkgs.jq
          fixtures.update-branches-test-nix
        ];
      }
      ''
        bash ${./test_update_workflows.sh}
        touch $out
      '';

  workflow-templates-check =
    pkgs.runCommand "workflow-templates-check"
      {
        PUBLISHED_TOOLS = pkgs.writeText "published-tools" (
          pkgs.lib.concatStringsSep "\n" (builtins.attrNames self.packages.${system})
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
        # A composite action is not a workflow, and actionlint parses a file it is
        # handed as a workflow, so the action files are parsed here and linted nowhere.
        for TEMPLATE in ${../templates/workflows}/*.yml ${../.github/actions}/*/action.yml; do
          yq eval 'true' "$TEMPLATE" > /dev/null
        done
        # A workflow file GitHub refuses to parse fails every repository that installs
        # it at once, and that run has no job and no log to read: an expression
        # written where its position has no such context is the mistake, and it is
        # caught here rather than on somebody's pull request. actionlint lints the
        # shell inside a step only when it finds shellcheck on its PATH.
        for TEMPLATE in ${../templates/workflows}/*.yml; do
          actionlint "$TEMPLATE"
        done
        # flake-lib is not one of its own inputs, so the refresher that keeps every
        # other repository's installed copy current has nothing to refresh here: the
        # copy this repository runs is kept honest by comparison.
        cmp ${../templates/workflows/build-and-check.yml} ${../.github/workflows/build-and-check.yml}
        # A template naming a tool this flake does not publish breaks every
        # repository that installs it at once, so the names are read from what is
        # published rather than from a second list that could disagree.
        for TOOL in $(grep -rhoE 'github:jgus-org/flake-lib/v1#[a-z0-9-]+' ${../templates/workflows} | sed 's|.*#||' | sort -u); do
          grep -Fxq "$TOOL" "$PUBLISHED_TOOLS"
        done
        # A job that evaluates a flake locking a private repository needs a credential for
        # it, and the credential belongs to being given nix, which makes the rule a count:
        # every step that asks the action for nix passes it.
        for TEMPLATE in ${../templates/workflows}/*.yml; do
          if ! NIX_CALLS=$(yq -r '[.jobs[].steps[]? | select(.uses? // "" | test("/.github/actions/nix@"))] | length' "$TEMPLATE"); then
            echo "error: $TEMPLATE has no readable steps" >&2
            exit 1
          fi
          if ! WITH_TOKEN=$(yq -r '[.jobs[].steps[]? | select(.uses? // "" | test("/.github/actions/nix@")) | select(.with["github-token"] // "" | test("BUILD_TOKEN"))] | length' "$TEMPLATE"); then
            echo "error: $TEMPLATE has no readable nix steps" >&2
            exit 1
          fi
          if [ "$NIX_CALLS" -ne "$WITH_TOKEN" ]; then
            echo "error: $TEMPLATE passes the github credential to $WITH_TOKEN of $NIX_CALLS steps that ask for nix" >&2
            exit 1
          fi
        done
        # A job scheduled inside a run that is being cancelled is never dispatched: the run
        # stays queued with nobody able to cancel or complete it, and it holds the
        # concurrency group that every later update in that repository waits behind. A
        # dependency that ended badly is worth running anyway, so a job waiting on another
        # names cancellation as the one outcome it does not run through.
        for TEMPLATE in ${../templates/workflows}/*.yml; do
          if ! WAITING=$(yq -r '[.jobs | to_entries[] | select(.value.needs?) | select((.value.if // "") | test("cancelled") | not) | .key] | join(" ")' "$TEMPLATE"); then
            echo "error: $TEMPLATE has unreadable job conditions" >&2
            exit 1
          fi
          if [ -n "$WAITING" ]; then
            echo "error: $TEMPLATE schedules $WAITING through a cancelled dependency" >&2
            exit 1
          fi
        done
        touch $out
      '';
}
