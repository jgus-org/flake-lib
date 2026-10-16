"""Exercises the dependency ordering gate against a scripted GitHub Actions API.

The stand-in serves the reads the gate makes per dependency (its workflows, its default
branch, its update runs) plus the dispatch that starts one, and it advances a dependency one
page per run-list read so that a wait can be observed: what the gate decided, how many times
it started anything, and whether it waited on several dependencies at the same time.
"""

from __future__ import annotations

import importlib.util
import json
import os
import sys
import threading
import time
import unittest
from contextlib import redirect_stderr, redirect_stdout
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from io import StringIO
from pathlib import Path
from tempfile import TemporaryDirectory
from typing import Any
from unittest import mock
from urllib.parse import unquote, urlsplit

MODULE_SPEC = importlib.util.spec_from_file_location(
    "wait_for_deps", Path(os.environ["WAIT_FOR_DEPS"])
)
assert MODULE_SPEC is not None
assert MODULE_SPEC.loader is not None
GATE = importlib.util.module_from_spec(MODULE_SPEC)
# The module must be registered before its body runs: its dataclasses resolve their
# annotations through sys.modules[__name__].
sys.modules[MODULE_SPEC.name] = GATE
MODULE_SPEC.loader.exec_module(GATE)

OWNER = "jgus-org"
SELF = "nix"
WORKFLOW = "update-branches.yml"
FRESH_WINDOW = 60.0
POLL_INTERVAL = 0.02
TIMEOUT = 0.5
# A success older than the freshness window: the dependency updated, but not for this run.
STALE = 7200.0


def stamp(age: float) -> str:
    return (datetime.now(timezone.utc) - timedelta(seconds=age)).strftime("%Y-%m-%dT%H:%M:%SZ")


def run(number: int, status: str, conclusion: str | None, age: float) -> dict[str, Any]:
    return {
        "run_number": number,
        "status": status,
        "conclusion": conclusion,
        "updated_at": stamp(age),
    }


def succeeded(age: float = 10.0) -> list[dict[str, Any]]:
    return [run(7, "completed", "success", age)]


def failed(age: float = 10.0) -> list[dict[str, Any]]:
    return [run(8, "completed", "failure", age)]


def in_flight() -> list[dict[str, Any]]:
    return [run(9, "in_progress", None, 0.0), run(7, "completed", "success", STALE)]


@dataclass
class Dependency:
    # One entry per read of the run list: a status code stands for a refused read, a list of
    # runs for a page. The last entry repeats, so a dependency can hold a state forever.
    reads: list[Any] = field(default_factory=lambda: [[]])
    workflow: str | None = WORKFLOW
    dispatch_status: int = 204
    delay: float = 0.0
    reads_taken: int = 0
    dispatches: int = 0


class Api:
    def __init__(self, dependencies: dict[str, Dependency]) -> None:
        self.dependencies = dependencies
        self.requests: list[str] = []
        self.active = 0
        self.peak = 0
        self._gate = threading.Lock()
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), self._handler())
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    @property
    def base_url(self) -> str:
        return f"http://127.0.0.1:{self.server.server_address[1]}"

    def stop(self) -> None:
        self.server.shutdown()
        self.server.server_close()

    def was_requested(self, method: str, suffix: str) -> bool:
        with self._gate:
            return any(
                line.startswith(f"{method} ") and line.endswith(suffix) for line in self.requests
            )

    def _handler(self) -> type[BaseHTTPRequestHandler]:
        api = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self) -> None:
                api._dispatch_request(self, "GET")

            def do_POST(self) -> None:
                api._dispatch_request(self, "POST")

            def log_message(self, *args: object) -> None:
                pass

        return Handler

    def _dispatch_request(self, handler: BaseHTTPRequestHandler, method: str) -> None:
        with self._gate:
            self.active += 1
            self.peak = max(self.peak, self.active)
        try:
            self._route(handler, method)
        finally:
            with self._gate:
                self.active -= 1

    def _route(self, handler: BaseHTTPRequestHandler, method: str) -> None:
        path = urlsplit(handler.path).path
        segments = [unquote(part) for part in path.strip("/").split("/")]
        with self._gate:
            self.requests.append(f"{method} {path}")
        if segments[:2] != ["repos", OWNER] or len(segments) < 3:
            self._refuse(handler, 404)
            return
        dependency = self.dependencies.get(segments[2])
        if dependency is None:
            self._refuse(handler, 404)
            return
        rest = segments[3:]
        if not rest:
            self._reply(handler, 200, {"default_branch": "main"})
            return
        if rest == ["actions", "workflows"]:
            workflows = (
                []
                if dependency.workflow is None
                else [
                    {
                        "path": f".github/workflows/{dependency.workflow}",
                        "name": "Update branches",
                        "state": "active",
                    }
                ]
            )
            self._reply(handler, 200, {"workflows": workflows, "total_count": len(workflows)})
            return
        if len(rest) != 4 or rest[2] != dependency.workflow:
            self._refuse(handler, 404)
            return
        if rest[3] == "runs" and method == "GET":
            page = dependency.reads[min(dependency.reads_taken, len(dependency.reads) - 1)]
            dependency.reads_taken += 1
            if dependency.delay:
                time.sleep(dependency.delay)
            if isinstance(page, int):
                self._refuse(handler, page)
            else:
                self._reply(handler, 200, {"workflow_runs": page, "total_count": len(page)})
            return
        if rest[3] == "dispatches" and method == "POST":
            dependency.dispatches += 1
            if dependency.dispatch_status < 300:
                handler.send_response(dependency.dispatch_status)
                handler.end_headers()
            else:
                self._refuse(handler, dependency.dispatch_status)
            return
        self._refuse(handler, 404)

    @staticmethod
    def _refuse(handler: BaseHTTPRequestHandler, status: int) -> None:
        Api._reply(handler, status, {"message": "fixture refusal"})

    @staticmethod
    def _reply(handler: BaseHTTPRequestHandler, status: int, payload: dict[str, Any]) -> None:
        body = json.dumps(payload).encode()
        handler.send_response(status)
        handler.send_header("Content-Type", "application/json")
        handler.send_header("Content-Length", str(len(body)))
        handler.end_headers()
        handler.wfile.write(body)


@dataclass(frozen=True)
class Report:
    status: int
    states: dict[str, str]
    lines: list[str]
    stderr: str
    api: Api

    def line_for(self, repo: str) -> str:
        matches = [line for line in self.lines if line.startswith(f"dep {OWNER}/{repo}:")]
        assert len(matches) == 1, f"expected one report line for {repo}, got {self.lines}"
        return matches[0]


class WaitForDepsTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = TemporaryDirectory()
        self.root = Path(self.temporary.name)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write_lock(self, dependencies: list[str], foreign: list[str] = ()) -> None:
        nodes: dict[str, Any] = {"root": {"inputs": {}}}
        for repo in ["flake-lib", SELF, *dependencies, *foreign]:
            owner = "NixOS" if repo in foreign else OWNER
            nodes[repo] = {
                "locked": {"type": "github", "owner": owner, "repo": repo, "rev": "0" * 40}
            }
            nodes["root"]["inputs"][repo] = repo
        (self.root / "flake.lock").write_text(json.dumps({"nodes": nodes}))

    def run_gate(
        self,
        dependencies: dict[str, Dependency],
        arguments: list[str] | None = None,
        environment: dict[str, str] | None = None,
    ) -> Report:
        self.write_lock(sorted(dependencies), foreign=["nixpkgs"])
        api = Api(dependencies)
        stdout, stderr = StringIO(), StringIO()
        overrides = environment if environment is not None else {
            "GITHUB_TOKEN": "fixture",
            "GITHUB_REPOSITORY": f"{OWNER}/{SELF}",
        }
        try:
            with (
                mock.patch.dict(os.environ, overrides),
                redirect_stdout(stdout),
                redirect_stderr(stderr),
            ):
                status = GATE.main(
                    [
                        "--api",
                        api.base_url,
                        "--flake-root",
                        str(self.root),
                        "--fresh-window",
                        str(FRESH_WINDOW),
                        "--poll-interval",
                        str(POLL_INTERVAL),
                        "--timeout",
                        str(TIMEOUT),
                        *(arguments or []),
                    ]
                )
        finally:
            api.stop()
        lines = stdout.getvalue().splitlines()
        states = {}
        for line in lines:
            if line.startswith("dep "):
                identity, _, remainder = line[len("dep ") :].partition(": ")
                states[identity] = remainder.partition(" (")[0]
        return Report(status, states, lines, stderr.getvalue(), api)

    def test_recent_success_is_not_waited_for(self) -> None:
        report = self.run_gate({"click-flake": Dependency(reads=[succeeded()])})
        self.assertEqual(report.status, 0)
        self.assertEqual(report.states, {f"{OWNER}/click-flake": "updated"})
        self.assertEqual(report.stderr, "")
        self.assertEqual(report.api.dependencies["click-flake"].dispatches, 0)
        self.assertEqual(report.api.dependencies["click-flake"].reads_taken, 1)

    def test_recent_failure_is_reported_and_not_waited_for(self) -> None:
        report = self.run_gate({"pydantic-flake": Dependency(reads=[failed()])})
        self.assertEqual(report.status, 0)
        self.assertEqual(report.states, {f"{OWNER}/pydantic-flake": "dep-failed"})
        self.assertIn("run 8 ended failure; continuing without waiting", report.stderr)
        self.assertEqual(report.api.dependencies["pydantic-flake"].dispatches, 0)

    def test_running_dependency_is_waited_for_without_dispatch(self) -> None:
        dependency = Dependency(reads=[in_flight(), in_flight(), succeeded()])
        report = self.run_gate({"huggingface-hub-flake": dependency})
        self.assertEqual(report.status, 0)
        self.assertEqual(report.states, {f"{OWNER}/huggingface-hub-flake": "updated"})
        self.assertEqual(dependency.dispatches, 0)
        self.assertEqual(dependency.reads_taken, 3)
        self.assertEqual(report.stderr, "")

    def test_stale_dependency_is_started_once(self) -> None:
        dependency = Dependency(reads=[succeeded(STALE), in_flight(), succeeded()])
        report = self.run_gate({"pydantic-core-flake": dependency})
        self.assertEqual(report.status, 0)
        self.assertEqual(report.states, {f"{OWNER}/pydantic-core-flake": "updated"})
        self.assertEqual(dependency.dispatches, 1)
        self.assertTrue(
            report.api.was_requested(
                "POST", "/actions/workflows/update-branches.yml/dispatches"
            )
        )
        self.assertIn("run 7 succeeded", report.line_for("pydantic-core-flake"))
        self.assertIn("started by this run", report.line_for("pydantic-core-flake"))

    def test_a_dependency_with_no_runs_at_all_is_started(self) -> None:
        dependency = Dependency(reads=[[]])
        report = self.run_gate({"tokenizers-flake": dependency})
        self.assertEqual(report.status, 0)
        self.assertEqual(report.states, {f"{OWNER}/tokenizers-flake": "timed-out"})
        self.assertEqual(dependency.dispatches, 1)
        self.assertIn(
            "its update did not finish in time; started by this run",
            report.line_for("tokenizers-flake"),
        )

    def test_refused_dispatch_is_not_retried(self) -> None:
        dependency = Dependency(reads=[succeeded(STALE)], dispatch_status=403)
        report = self.run_gate({"unsloth-zoo-flake": dependency})
        self.assertEqual(report.status, 0)
        self.assertEqual(report.states, {f"{OWNER}/unsloth-zoo-flake": "timed-out"})
        self.assertEqual(dependency.dispatches, 1)
        self.assertIn("its update could not be started", report.line_for("unsloth-zoo-flake"))

    def test_dependency_without_an_update_workflow_is_reported(self) -> None:
        dependency = Dependency(reads=[succeeded()], workflow=None)
        report = self.run_gate({"caddy-flake": dependency})
        self.assertEqual(report.status, 0)
        self.assertEqual(report.states, {f"{OWNER}/caddy-flake": "no-update-workflow"})
        self.assertEqual(dependency.reads_taken, 0)
        self.assertIn("ships no", report.line_for("caddy-flake"))

    def test_unreadable_dependency_is_reported_once(self) -> None:
        dependency = Dependency(reads=[403])
        report = self.run_gate({"private-flake": dependency})
        self.assertEqual(report.status, 0)
        self.assertEqual(report.states, {f"{OWNER}/private-flake": "unobserved"})
        self.assertEqual(dependency.reads_taken, 1)

    def test_transient_read_failure_is_retried(self) -> None:
        dependency = Dependency(reads=[500, succeeded()])
        report = self.run_gate({"click-flake": dependency})
        self.assertEqual(report.status, 0)
        self.assertEqual(report.states, {f"{OWNER}/click-flake": "updated"})
        self.assertEqual(dependency.reads_taken, 2)
        self.assertIn("run list unavailable, retrying", report.stderr)

    def test_dependency_that_never_finishes_times_out_and_continues(self) -> None:
        dependency = Dependency(reads=[in_flight()])
        report = self.run_gate({"freeimage-for-es-de-flake": dependency})
        self.assertEqual(report.status, 0)
        self.assertEqual(report.states, {f"{OWNER}/freeimage-for-es-de-flake": "timed-out"})
        self.assertEqual(dependency.dispatches, 0)

    def test_dependencies_are_waited_for_at_once(self) -> None:
        # Each dependency holds its read open, so both can only be observed together if the
        # waits run concurrently rather than one after the other.
        dependencies = {
            "click-flake": Dependency(reads=[in_flight(), succeeded()], delay=0.3),
            "hf-xet-flake": Dependency(reads=[in_flight(), succeeded()], delay=0.3),
        }
        report = self.run_gate(dependencies, ["--timeout", "10"])
        self.assertEqual(report.status, 0)
        self.assertEqual(set(report.states.values()), {"updated"})
        self.assertGreater(report.api.peak, 1)

    def test_a_leaf_producer_reports_nothing_to_wait_for(self) -> None:
        report = self.run_gate({})
        self.assertEqual(report.status, 0)
        self.assertEqual(report.states, {})
        self.assertIn("nothing to wait for", "\n".join(report.lines))
        self.assertEqual(report.api.requests, [])

    def test_missing_token_continues_without_reading_anything(self) -> None:
        self.write_lock(["click-flake"])
        stdout, stderr = StringIO(), StringIO()
        with (
            mock.patch.dict(os.environ, {"GITHUB_REPOSITORY": f"{OWNER}/{SELF}"}, clear=True),
            redirect_stdout(stdout),
            redirect_stderr(stderr),
        ):
            status = GATE.main(["--flake-root", str(self.root)])
        self.assertEqual(status, 0)
        self.assertIn("no GITHUB_TOKEN", stderr.getvalue())
        self.assertNotIn("GITHUB_REPOSITORY", stderr.getvalue())
        self.assertIn("continuing without waiting", stderr.getvalue())
        self.assertEqual(stdout.getvalue(), "")

    def test_missing_repository_names_only_that_gap(self) -> None:
        self.write_lock(["click-flake"])
        stdout, stderr = StringIO(), StringIO()
        with (
            mock.patch.dict(os.environ, {"GITHUB_TOKEN": "fixture"}, clear=True),
            redirect_stdout(stdout),
            redirect_stderr(stderr),
        ):
            status = GATE.main(["--flake-root", str(self.root)])
        self.assertEqual(status, 0)
        self.assertIn("no GITHUB_REPOSITORY", stderr.getvalue())
        self.assertNotIn("GITHUB_TOKEN", stderr.getvalue())
        self.assertEqual(stdout.getvalue(), "")

    def test_discovery_keeps_only_same_owner_inputs(self) -> None:
        self.write_lock(["click-flake", "pydantic-core-flake"], foreign=["nixpkgs"])
        self.assertEqual(
            GATE.discover_dependencies(self.root / "flake.lock", OWNER, SELF),
            [f"{OWNER}/click-flake", f"{OWNER}/pydantic-core-flake"],
        )

    def test_unparsable_run_is_skipped(self) -> None:
        self.assertIsNone(GATE.parse_run({"run_number": 1, "status": "completed"}))
        self.assertEqual(
            GATE.parse_run({"run_number": 1, "status": "completed", "updated_at": stamp(5)}).number,
            1,
        )


if __name__ == "__main__":
    unittest.main()
