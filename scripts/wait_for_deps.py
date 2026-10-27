"""Block a producer's update run until the producers it depends on have updated.

The dependency edges are the flake inputs this repository already declares: every github
input owned by this repository's own owner is a producer whose published refs this run is
about to consume. Edges are therefore never declared twice, and the graph cannot cycle,
because a flake's inputs are acyclic by construction.

Ordering is observed, not announced. A producer knows its dependencies and nothing knows its
consumers, so no dependency can report its own completion to the repository waiting on it:
this reads each dependency's update runs and waits. A dependency that has finished within the
freshness window is done; one that is running is waited for; one that is neither is started
and then waited for. Every failure to establish ordering ends in continuing without waiting,
because a dependency that will not or cannot report its state must not stop the fleet. The
one exception is a credential the API refuses: nothing can be observed or started through it,
so a wait that could see nothing through the credential at all is an error rather than a
result.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
from collections.abc import Callable, Mapping, Sequence
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any
from urllib.parse import quote

DEFAULT_API = "https://api.github.com"
# The workflow files flake-lib's templates install, then the name producers wrote by hand
# before flake-lib shipped templates. A dependency whose repository has none of these has no
# update run to wait for.
WORKFLOW_CANDIDATES = (
    "update-branches.yml",
    "update-version.yml",
    "update.yml",
)
# The only Actions state a workflow can still run in. `inactive` means no file is behind the
# path at all; `disabled_manually` and `disabled_inactivity` leave the file on the default
# branch but run no more, the latter once GitHub has seen sixty days without a run. A
# dispatch on either disabled workflow is refused, and its schedule will not fire again.
ACTIVE_STATE = "active"
# The library every producer takes as an input, and the one dependency that is not a
# dependency: its own revision is advanced by the refresh job that runs before this one.
LIBRARY_REPO = "flake-lib"
REQUEST_TIMEOUT_S = 30.0
# A repository whose state cannot be read at all. Polling it again for the whole budget would
# spend the wait and report nothing new.
UNOBSERVABLE = (401, 403, 404, 451)
# The members of UNOBSERVABLE that say the credential is what is missing rather than the
# repository being out of sight: through them no run can be read and none can be started.
REFUSED = (401, 403)
INFLIGHT = frozenset(
    {"queued", "requested", "waiting", "pending", "in_progress"}
)
SUCCEEDED = frozenset({"success", "neutral", "skipped"})


@dataclass(frozen=True)
class Run:
    number: int
    status: str
    conclusion: str | None
    updated_at: datetime

    @property
    def inflight(self) -> bool:
        return self.status in INFLIGHT

    @property
    def completed(self) -> bool:
        return self.status == "completed"

    @property
    def succeeded(self) -> bool:
        return self.completed and self.conclusion in SUCCEEDED


@dataclass(frozen=True)
class UpdateWorkflow:
    name: str
    state: str

    @property
    def enabled(self) -> bool:
        return self.state == ACTIVE_STATE


@dataclass(frozen=True)
class Config:
    api: str
    workflows: tuple[str, ...]
    fresh_window: timedelta
    timeout: float
    poll_interval: float
    max_dispatches: int


@dataclass(frozen=True)
class Outcome:
    repo: str
    state: str
    detail: str
    # The refusal that ended the wait, when a refusal did. `detail` says the same as prose.
    status: int | None = None

    def __str__(self) -> str:
        return f"{self.repo}: {self.state} ({self.detail})"


class GitHubError(RuntimeError):
    def __init__(self, status: int, detail: str) -> None:
        super().__init__(f"HTTP {status}: {detail}")
        self.status = status

    @property
    def transient(self) -> bool:
        # status 0 is a transport failure, which is as retryable as a server-side one.
        return self.status == 0 or self.status >= 500 or self.status == 429


class GitHub:
    def __init__(self, api: str, token: str) -> None:
        self.api = api.rstrip("/")
        self.token = token

    def _call(
        self, method: str, path: str, body: Mapping[str, str] | None = None
    ) -> Any:
        request = urllib.request.Request(
            f"{self.api}{path}",
            method=method,
            data=None if body is None else json.dumps(body).encode(),
            headers={
                "Accept": "application/vnd.github+json",
                "Authorization": f"Bearer {self.token}",
                "Content-Type": "application/json",
                "User-Agent": "flake-lib-wait-for-deps",
            },
        )
        try:
            with urllib.request.urlopen(
                request, timeout=REQUEST_TIMEOUT_S
            ) as response:
                payload = response.read()
        except urllib.error.HTTPError as error:
            detail = error.read().decode(errors="replace").strip()[:200]
            # The response body outlives this frame otherwise, and its eventual collection
            # prints a ResourceWarning into the middle of the run's report.
            error.close()
            raise GitHubError(error.code, detail or error.reason) from error
        except urllib.error.URLError as error:
            raise GitHubError(0, str(error.reason)) from error
        return json.loads(payload) if payload else None

    def default_branch(self, repo: str) -> str:
        return self._call("GET", f"/repos/{repo}")["default_branch"]

    def update_workflow(
        self, repo: str, candidates: Sequence[str]
    ) -> UpdateWorkflow | None:
        page = self._call(
            "GET", f"/repos/{repo}/actions/workflows?per_page=100"
        )
        shipped = {
            Path(workflow["path"]).name: workflow.get("state") or ""
            for workflow in page.get("workflows", [])
        }
        for name in candidates:
            if name in shipped:
                return UpdateWorkflow(name, shipped[name])
        return None

    def runs(self, repo: str, workflow: str) -> list[Run]:
        path = f"/repos/{repo}/actions/workflows/{quote(workflow, safe='')}/runs?per_page=20"
        page = self._call("GET", path)
        return [
            run
            for item in page.get("workflow_runs", [])
            if (run := parse_run(item)) is not None
        ]

    def dispatch(self, repo: str, workflow: str, ref: str) -> None:
        path = f"/repos/{repo}/actions/workflows/{quote(workflow, safe='')}/dispatches"
        self._call("POST", path, {"ref": ref})


def parse_run(item: Mapping[str, Any]) -> Run | None:
    try:
        return Run(
            number=item["run_number"],
            status=item["status"],
            conclusion=item.get("conclusion"),
            updated_at=datetime.fromisoformat(
                item["updated_at"].replace("Z", "+00:00")
            ),
        )
    except (KeyError, TypeError, ValueError):
        return None


def discover_dependencies(
    lock_path: Path, owner: str, self_repo: str
) -> list[str]:
    lock = json.loads(lock_path.read_text())
    dependencies = set()
    for node in lock.get("nodes", {}).values():
        locked = node.get("locked") or {}
        if locked.get("type") != "github" or locked.get("owner") != owner:
            continue
        repo = locked.get("repo")
        if not isinstance(repo, str) or repo in {self_repo, LIBRARY_REPO}:
            continue
        dependencies.add(f"{owner}/{repo}")
    return sorted(dependencies)


def completed_within(
    runs: Sequence[Run], window: timedelta, now: datetime
) -> list[Run]:
    threshold = now - window
    return [
        run for run in runs if run.completed and run.updated_at >= threshold
    ]


def newest(runs: Sequence[Run]) -> Run:
    return max(runs, key=lambda run: run.updated_at)


def wait_for_dependency(
    client: GitHub, repo: str, config: Config, warn: Callable[[str], None]
) -> Outcome:
    try:
        shipped = client.update_workflow(repo, config.workflows)
        ref = (
            client.default_branch(repo)
            if shipped is not None and shipped.enabled
            else ""
        )
    except GitHubError as error:
        return Outcome(
            repo,
            "unobserved",
            f"its workflows cannot be read: {error}",
            error.status,
        )
    if shipped is None:
        return Outcome(
            repo,
            "no-update-workflow",
            f"ships no {', '.join(config.workflows)}",
        )
    if not shipped.enabled:
        return Outcome(
            repo,
            "update-workflow-disabled",
            f"its {shipped.name} is {shipped.state}, so it runs no more",
        )

    deadline = time.monotonic() + config.timeout
    dispatches = 0
    started = False
    reason = (
        f"no completed run within {int(config.fresh_window.total_seconds())}s"
    )

    def outcome(state: str, detail: str, status: int | None = None) -> Outcome:
        # A wait that ended by starting the dependency did something to the fleet, and the
        # log has to say so: the dependency's own run is not attributable to this one.
        if not started:
            return Outcome(repo, state, detail, status)
        return Outcome(repo, state, f"{detail}; started by this run", status)

    while True:
        try:
            runs = client.runs(repo, shipped.name)
        except GitHubError as error:
            if error.status in UNOBSERVABLE:
                return outcome(
                    "unobserved",
                    f"its runs cannot be read: {error}",
                    error.status,
                )
            warn(f"{repo}: run list unavailable, retrying ({error})")
            reason = f"its runs stayed unreadable ({error})"
            if not pause(deadline, config.poll_interval):
                return outcome("timed-out", reason)
            continue

        recent = completed_within(
            runs, config.fresh_window, datetime.now(timezone.utc)
        )
        if any(run.succeeded for run in recent):
            run = newest([run for run in recent if run.succeeded])
            return outcome("updated", f"run {run.number} succeeded")
        if recent:
            run = newest(recent)
            reason = f"run {run.number} ended {run.conclusion}"
            warn(f"{repo}: {reason}; continuing without waiting")
            return outcome("dep-failed", reason)
        if any(run.inflight for run in runs):
            reason = "its update is already running"
        elif dispatches < config.max_dispatches:
            dispatches += 1
            try:
                client.dispatch(repo, shipped.name, ref)
                started = True
                reason = "its update did not finish in time"
            except GitHubError as error:
                if not error.transient:
                    # The dispatch is the only way this branch changes, and this reason
                    # will not clear, so the rest of the budget would prove nothing.
                    return outcome(
                        "cannot-start",
                        f"its update cannot be started: {error}",
                        error.status,
                    )
                reason = f"its update could not be started ({error})"
                dispatches = config.max_dispatches
        if not pause(deadline, config.poll_interval):
            return outcome("timed-out", reason)


def pause(deadline: float, interval: float) -> bool:
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        return False
    time.sleep(min(interval, remaining))
    return True


def parse_args(argv: Sequence[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=__doc__.splitlines()[0],
        argument_default=None,
    )
    parser.add_argument(
        "--flake-root",
        type=Path,
        help="repository whose flake.lock declares the inputs",
    )
    parser.add_argument(
        "--api", help=f"github API base URL (default {DEFAULT_API})"
    )
    parser.add_argument(
        "--workflow",
        action="append",
        dest="workflows",
        help="workflow file to treat as a dependency's update, most preferred first; repeatable",
    )
    parser.add_argument(
        "--fresh-window",
        type=float,
        help="seconds a finished run stays good for",
    )
    parser.add_argument(
        "--timeout", type=float, help="seconds to wait for one dependency"
    )
    parser.add_argument(
        "--poll-interval",
        type=float,
        help="seconds between reads of a dependency",
    )
    parser.add_argument(
        "--max-dispatches",
        type=int,
        help="times this run may start a dependency's update",
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    warn: Callable[[str], None] = lambda message: print(
        f"warning: {message}", file=sys.stderr
    )

    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN") or ""
    repository = os.environ.get("GITHUB_REPOSITORY", "")
    missing = []
    if not token:
        missing.append("no GITHUB_TOKEN")
    if "/" not in repository:
        missing.append("no GITHUB_REPOSITORY")
    if missing:
        warn(
            f"{' and '.join(missing)}, so a dependency's runs cannot be read: "
            "continuing without waiting"
        )
        return 0

    root = (
        Path(args.flake_root)
        if args.flake_root
        else Path(os.environ.get("FLAKE_ROOT", "."))
    )
    lock_path = root / "flake.lock"
    if not lock_path.is_file():
        warn(
            f"{lock_path} does not exist, so no dependency can be identified: continuing without waiting"
        )
        return 0

    owner, _, self_repo = repository.partition("/")
    dependencies = discover_dependencies(lock_path, owner, self_repo)
    if not dependencies:
        print(f"{self_repo} takes no input from {owner}: nothing to wait for")
        return 0

    config = Config(
        api=args.api or DEFAULT_API,
        workflows=tuple(args.workflows)
        if args.workflows
        else WORKFLOW_CANDIDATES,
        fresh_window=timedelta(seconds=args.fresh_window or 3600),
        timeout=args.timeout if args.timeout is not None else 5400.0,
        poll_interval=args.poll_interval
        if args.poll_interval is not None
        else 60.0,
        max_dispatches=args.max_dispatches
        if args.max_dispatches is not None
        else 1,
    )
    client = GitHub(config.api, token)

    def wait(repo: str) -> Outcome:
        return wait_for_dependency(client, repo, config, warn)

    # The wait's own log is the only place a consumer's operator can see what it is blocked
    # on, and one dependency can hold it for the whole budget, so the set being waited for is
    # stated before the first read and each dependency is reported as it settles. stdout is
    # buffered when it is a pipe, so these lines flush.
    print(
        f"waiting for {len(dependencies)} dependency updates, each for up to "
        f"{config.timeout:g}s: {', '.join(dependencies)}",
        flush=True,
    )
    outcomes: list[Outcome] = []
    with ThreadPoolExecutor(max_workers=len(dependencies)) as pool:
        waiting = [pool.submit(wait, repo) for repo in dependencies]
        for finished in as_completed(waiting):
            outcome = finished.result()
            outcomes.append(outcome)
            print(
                f"dep {outcome} [{len(outcomes)}/{len(dependencies)}]",
                flush=True,
            )

    refused = [outcome for outcome in outcomes if outcome.status in REFUSED]
    if not refused:
        return 0
    if len(refused) < len(outcomes):
        print(
            f"warning: the GitHub API refused the credential for {len(refused)} of "
            f"{len(outcomes)} dependency updates against {repository}: those updates were not "
            "started or waited for",
            file=sys.stderr,
        )
        return 0
    print(
        f"error: the GitHub API refused the credential for every one of the "
        f"{len(outcomes)} dependency updates against {repository}: none of them was started "
        "or waited for",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
