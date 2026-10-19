"""Judges the fleet sweep against a scripted stand-in for the GitHub API.

The stand-in answers the reads a sweep makes -- the organisation's repositories, one run list
per producer, and the tracking issue's endpoint group -- and records every write it is asked
for, so a test says what the sweep concluded and what it did about it. The synthetic run
histories are the shapes the fleet really has: a schedule red under a workflow file that has
since been renamed, a manual dispatch sitting on top of failing schedules, a run that has not
finished, and a producer that was never scheduled at all.

Every stamp comes from one captured instant, so the served data and the expected strings are
the same dates, and every fixture that must sit on one side of a threshold sits far from it
rather than near it.
"""

from __future__ import annotations

import importlib.util
import json
import os
import sys
import threading
import unittest
from collections.abc import Sequence
from contextlib import redirect_stderr, redirect_stdout
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from io import StringIO
from pathlib import Path
from tempfile import TemporaryDirectory
from typing import Any
from unittest import mock
from urllib.parse import parse_qs, unquote, urlsplit

MODULE_SPEC = importlib.util.spec_from_file_location(
    "updater_health", Path(os.environ["UPDATER_HEALTH"])
)
assert MODULE_SPEC is not None
assert MODULE_SPEC.loader is not None
SWEEP = importlib.util.module_from_spec(MODULE_SPEC)
# The module must be registered before its body runs: its dataclasses resolve their
# annotations through sys.modules[__name__].
sys.modules[MODULE_SPEC.name] = SWEEP
MODULE_SPEC.loader.exec_module(SWEEP)

ORG = "jgus-org"
SELF = "flake-lib"
REPOSITORY = f"{ORG}/{SELF}"
BRANCHES = "update-branches.yml"
VERSION = "update-version.yml"
LEGACY = "update.yml"
# Comfortably on one side of the sweep's default three-day staleness window in each
# direction, so no fixture can drift across the boundary.
FRESH = 3600.0
STALE = 10 * 86400.0
# Three failed scheduled runs: over the default bar of two, so the tests that set their own
# bar can raise it past these.
LONG_STREAK = (4, 3, 2)

NOW = datetime.now(timezone.utc)


def stamp(age: float) -> str:
    return (NOW - timedelta(seconds=age)).strftime("%Y-%m-%dT%H:%M:%SZ")


def date_of(age: float) -> str:
    return (NOW - timedelta(seconds=age)).strftime("%Y-%m-%d")


def run_item(
    number: int,
    *,
    workflow: str = BRANCHES,
    event: str = "schedule",
    status: str = "completed",
    conclusion: str | None = "success",
    age: float = FRESH,
) -> dict[str, Any]:
    return {
        "run_number": number,
        "name": "Update branches",
        "path": f".github/workflows/{workflow}",
        "event": event,
        "status": status,
        "conclusion": conclusion,
        "created_at": stamp(age),
        "html_url": f"https://github.com/{ORG}/example-flake/actions/runs/{number}",
    }


def success(number: int, age: float = FRESH, **changes: Any) -> dict[str, Any]:
    return run_item(number, age=age, **changes)


def failure(number: int, age: float = FRESH, **changes: Any) -> dict[str, Any]:
    return run_item(number, conclusion="failure", age=age, **changes)


def inflight(number: int, age: float = FRESH, **changes: Any) -> dict[str, Any]:
    return run_item(number, status="in_progress", conclusion=None, age=age, **changes)


def failing_streak(workflow: str = LEGACY) -> list[dict[str, Any]]:
    # Newest first, as a run list serves it: run 4 is the most recent failure.
    return [
        failure(number, workflow=workflow, age=3600 * (LONG_STREAK[0] - number + 1))
        for number in LONG_STREAK
    ]


@dataclass
class Producer:
    # A list of runs is what the producer's run list answers with; an int is the status the
    # read is refused with instead.
    runs: list[dict[str, Any]] | int = field(default_factory=list)
    archived: bool = False
    reads: int = 0

    def __post_init__(self) -> None:
        # The sweep reads the order of a producer's history from the order the run list serves
        # it, newest first. Stamps may tie -- flake-lib's two templates both fire at the same
        # cron minute -- but a fixture that runs backwards cannot conclude anything, so it is
        # refused where it is written rather than diagnosed later.
        if isinstance(self.runs, list):
            stamps = [item["created_at"] for item in self.runs]
            paired = zip(stamps, stamps[1:], strict=False)
            assert all(one >= two for one, two in paired), self.runs


@dataclass
class Tracked:
    number: int = 7
    state: str = "open"
    title: str = "an earlier title"
    attention: tuple[str, ...] = ("old-flake",)
    body: str | None = None

    def as_item(self) -> dict[str, Any]:
        body = self.body
        if body is None:
            recorded = json.dumps(list(self.attention))
            body = f"<!-- {SWEEP.ISSUE_MARKER} {recorded} -->\n\nearlier report"
        return {"number": self.number, "state": self.state, "title": self.title, "body": body}


class Api:
    def __init__(
        self,
        producers: dict[str, Producer],
        tracked: Sequence[Tracked | dict[str, Any]] = (),
        foreign: Sequence[str] = ("nix", "nixpkgs-fork"),
        refuse_runs: dict[str, int] | None = None,
        unparseable_runs: Sequence[str] = (),
        refuse_write: int | None = None,
        refuse_org: int | None = None,
    ) -> None:
        self.producers = producers
        self.tracked = [item.as_item() if isinstance(item, Tracked) else dict(item) for item in tracked]
        self.foreign = list(foreign)
        self.refuse_runs = refuse_runs or {}
        self.unparseable_runs = set(unparseable_runs)
        self.refuse_write = refuse_write
        self.refuse_org = refuse_org
        self.requests: list[str] = []
        self.created: list[dict[str, Any]] = []
        self.edits: list[tuple[int, dict[str, Any]]] = []
        self.comments: list[tuple[int, str]] = []
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), self._handler())
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    @property
    def base_url(self) -> str:
        return f"http://127.0.0.1:{self.server.server_address[1]}"

    def stop(self) -> None:
        self.server.shutdown()
        self.server.server_close()

    def writes(self) -> tuple[list[dict[str, Any]], list[tuple[int, dict[str, Any]]], list[tuple[int, str]]]:
        return self.created, self.edits, self.comments

    def listed(self) -> list[dict[str, Any]]:
        entries = [{"name": name, "archived": producer.archived} for name, producer in self.producers.items()]
        entries += [{"name": name, "archived": False} for name in self.foreign]
        return sorted(entries, key=lambda entry: entry["name"])

    def _handler(self) -> type[BaseHTTPRequestHandler]:
        api = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self) -> None:
                api._route(self, "GET", self.path)

            def do_POST(self) -> None:
                api._route(self, "POST", self.path, api._body(self))

            def do_PATCH(self) -> None:
                api._route(self, "PATCH", self.path, api._body(self))

            def log_message(self, *args: object) -> None:
                pass

        return Handler

    @staticmethod
    def _body(handler: BaseHTTPRequestHandler) -> dict[str, Any]:
        length = int(handler.headers.get("Content-Length", "0"))
        raw = handler.rfile.read(length) if length else b"{}"
        return json.loads(raw)

    def _route(self, handler: BaseHTTPRequestHandler, method: str, path: str, body: dict | None = None) -> None:
        split = urlsplit(path)
        segments = [unquote(part) for part in split.path.strip("/").split("/")]
        query = parse_qs(split.query)
        self.requests.append(f"{method} {split.path}")
        if segments[:2] == ["orgs", ORG]:
            if self.refuse_org is not None or segments[2:] != ["repos"]:
                self._refuse(handler, self.refuse_org or 404)
                return
            self._page(handler, self.listed(), query)
            return
        if segments[:2] != ["repos", ORG]:
            self._refuse(handler, 404)
            return
        name = segments[2]
        rest = segments[3:]
        if rest == ["actions", "runs"]:
            self._runs(handler, name)
            return
        if rest[:1] == ["issues"]:
            self._issues(handler, method, rest, body, query)
            return
        self._refuse(handler, 404)

    def _runs(self, handler: BaseHTTPRequestHandler, name: str) -> None:
        producer = self.producers.get(name)
        if producer is None:
            self._refuse(handler, 404)
            return
        if name in self.refuse_runs:
            self._refuse(handler, self.refuse_runs[name])
            return
        producer.reads += 1
        if name in self.unparseable_runs:
            self._reply(handler, 200, "<html>a login page, not JSON</html>", raw=True)
            return
        if isinstance(producer.runs, int):
            self._refuse(handler, producer.runs)
            return
        self._reply(handler, 200, {"workflow_runs": producer.runs, "total_count": len(producer.runs)})

    def _issues(
        self,
        handler: BaseHTTPRequestHandler,
        method: str,
        rest: list[str],
        body: dict | None,
        query: dict[str, list[str]],
    ) -> None:
        if len(rest) == 1 and method == "GET":
            self._page(handler, self.tracked, query)
            return
        if self.refuse_write is not None:
            self._refuse(handler, self.refuse_write)
            return
        if len(rest) == 1 and method == "POST" and body is not None:
            number = 1 + max([issue["number"] for issue in self.tracked] or [0])
            self.created.append({**body, "number": number})
            self._reply(handler, 201, {"number": number})
            return
        number = int(rest[1]) if len(rest) > 1 and rest[1].isdigit() else 0
        if len(rest) == 2 and method == "PATCH":
            self.edits.append((number, body or {}))
            for issue in self.tracked:
                if issue["number"] == number:
                    issue.update(body or {})
            self._reply(handler, 200, {"number": number})
            return
        if len(rest) == 3 and rest[2] == "comments" and method == "POST":
            self.comments.append((number, (body or {}).get("body", "")))
            self._reply(handler, 201, {"body": (body or {}).get("body", "")})
            return
        self._refuse(handler, 404)

    def _page(self, handler: BaseHTTPRequestHandler, items: list[dict[str, Any]], query: dict[str, list[str]]) -> None:
        per_page = int(query.get("per_page", [str(len(items))])[0])
        page = int(query.get("page", ["1"])[0])
        start = (page - 1) * per_page
        self._reply(handler, 200, items[start : start + per_page])

    @staticmethod
    def _refuse(handler: BaseHTTPRequestHandler, status: int) -> None:
        Api._reply(handler, status, {"message": "fixture refusal"})

    @staticmethod
    def _reply(handler: BaseHTTPRequestHandler, status: int, payload: Any, raw: bool = False) -> None:
        body = payload.encode() if raw else json.dumps(payload).encode()
        handler.send_response(status)
        handler.send_header("Content-Type", "text/html" if raw else "application/json")
        handler.send_header("Content-Length", str(len(body)))
        handler.end_headers()
        handler.wfile.write(body)


@dataclass(frozen=True)
class Report:
    status: int
    lines: list[str]
    stderr: str
    api: Api

    def verdicts(self) -> dict[str, str]:
        found = {}
        for line in self.lines:
            if not line.startswith("- `"):
                continue
            producer, _, remainder = line[len("- `") :].partition("`: ")
            found[producer] = remainder.partition(" -- ")[0]
        return found

    def order(self) -> list[str]:
        return [line.split("`")[1] for line in self.lines if line.startswith("- `")]

    def line_for(self, producer: str) -> str:
        matches = [line for line in self.lines if line.startswith(f"- `{producer}`")]
        assert len(matches) == 1, f"expected one report line for {producer}, got {matches}"
        return matches[0]


class SweepTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = TemporaryDirectory()
        self.summary = Path(self.temporary.name) / "summary.md"

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def run_sweep(
        self,
        api: Api,
        arguments: Sequence[str] = (),
        environment: dict[str, str] | None = None,
    ) -> Report:
        stdout, stderr = StringIO(), StringIO()
        overrides = environment if environment is not None else {
            "GITHUB_TOKEN": "fixture",
            "GITHUB_REPOSITORY": REPOSITORY,
        }
        try:
            # The ambient environment carries a real token and real action identifiers, so
            # nothing but what a test names is allowed to reach the sweep.
            with (
                mock.patch.dict(os.environ, overrides, clear=True),
                redirect_stdout(stdout),
                redirect_stderr(stderr),
            ):
                status = SWEEP.main(["--api", api.base_url, *arguments])
        finally:
            api.stop()
        return Report(status, stdout.getvalue().splitlines(), stderr.getvalue(), api)

    def sweep(
        self,
        producers: dict[str, Producer],
        arguments: Sequence[str] = (),
        environment: dict[str, str] | None = None,
        **api: Any,
    ) -> Report:
        return self.run_sweep(Api(producers, **api), arguments, environment)

    # -- what the sweep concludes -------------------------------------------------------

    def test_consecutive_failed_scheduled_runs_are_red(self) -> None:
        report = self.sweep(
            {
                "bun-flake": Producer(runs=[failure(4, age=3600), failure(3, age=86400), success(2, age=172800)]),
                "ms-marco-flake": Producer(runs=[success(9), failure(8, age=172800)]),
            }
        )
        self.assertEqual(report.status, 0)
        self.assertEqual(report.verdicts(), {"bun-flake": "red", "ms-marco-flake": "healthy"})
        self.assertIn("2 scheduled runs in a row failed (failure)", report.line_for("bun-flake"))
        self.assertIn(f"last success {date_of(172800)}", report.line_for("bun-flake"))
        self.assertIn("run 4", report.line_for("bun-flake"))

    def test_the_report_leads_with_the_worst_streak(self) -> None:
        report = self.sweep(
            {
                "bun-flake": Producer(runs=[failure(4, age=3600), success(3, age=86400)]),
                "caddy-flake": Producer(runs=failing_streak()),
                "tidarr-flake": Producer(runs=[success(1)]),
            }
        )
        self.assertEqual(report.order(), ["caddy-flake", "bun-flake", "tidarr-flake"])

    def test_one_failed_scheduled_run_is_not_yet_a_standing_condition(self) -> None:
        report = self.sweep({"bun-flake": Producer(runs=[failure(4), success(3, age=86400)])})
        self.assertEqual(report.verdicts(), {"bun-flake": "first-failure"})
        self.assertEqual(report.status, 0)

    def test_the_streak_bar_is_a_knob(self) -> None:
        runs = [failure(4, age=3600), failure(3, age=86400), success(2, age=172800)]
        self.assertEqual(self.sweep({"bun-flake": Producer(runs=runs)}).verdicts(), {"bun-flake": "red"})
        raised = self.sweep({"bun-flake": Producer(runs=runs)}, ["--fail-streak", "3"])
        self.assertEqual(raised.verdicts(), {"bun-flake": "first-failure"})

    def test_a_manual_success_does_not_mask_a_red_schedule(self) -> None:
        report = self.sweep(
            {
                "slssteam-flake": Producer(
                    runs=[
                        success(5, event="workflow_dispatch", age=1800),
                        failure(4, age=3600),
                        failure(3, age=86400),
                        success(2, age=172800),
                    ]
                )
            }
        )
        self.assertEqual(report.verdicts(), {"slssteam-flake": "red"})

    def test_history_under_a_renamed_workflow_file_still_counts(self) -> None:
        # The fleet's real shape: the failing runs belong to a workflow file the producer has
        # since replaced, so the live file's one manual dispatch must not answer for the streak
        # the deleted file left behind.
        report = self.sweep(
            {
                "caddy-flake": Producer(
                    runs=[success(1, workflow=VERSION, event="workflow_dispatch", age=1800), *failing_streak()]
                )
            }
        )
        self.assertEqual(
            report.verdicts(),
            {"caddy-flake update.yml": "red", "caddy-flake update-version.yml": "pending"},
        )
        self.assertIn("no scheduled run has ever succeeded", report.line_for("caddy-flake update.yml"))

    def test_the_workflow_names_a_run_looks_for_are_knobs(self) -> None:
        report = self.sweep({"caddy-flake": Producer(runs=failing_streak())}, ["--workflow", VERSION])
        self.assertEqual(report.verdicts(), {"caddy-flake": "no-updater"})

    def test_a_run_that_has_not_finished_has_no_conclusion(self) -> None:
        # The in-flight run is neither a success that breaks the streak nor a failure that
        # joins it: the streak stays two.
        report = self.sweep(
            {
                "codex-flake": Producer(
                    runs=[
                        inflight(6, age=1800),
                        failure(5, age=3600),
                        failure(4, age=86400),
                        success(3, age=172800),
                    ]
                )
            }
        )
        self.assertEqual(report.verdicts(), {"codex-flake": "red"})
        self.assertIn("2 scheduled runs in a row failed", report.line_for("codex-flake"))

    def test_a_producer_with_no_updater_runs_is_reported_without_alerting(self) -> None:
        report = self.sweep({"vscode-sops-flake": Producer(runs=[success(1, workflow="publish.yml")])})
        self.assertEqual(report.verdicts(), {"vscode-sops-flake": "no-updater"})
        self.assertIn(
            "none of its 100 newest runs came from update-branches.yml", report.line_for("vscode-sops-flake")
        )

    def test_an_updater_that_was_never_scheduled_is_pending(self) -> None:
        report = self.sweep({"lazylibrarian-flake": Producer(runs=[failure(1, event="workflow_dispatch")])})
        self.assertEqual(report.verdicts(), {"lazylibrarian-flake": "pending"})
        self.assertIn("was a workflow_dispatch, not a schedule", report.line_for("lazylibrarian-flake"))

    def test_a_silence_longer_than_the_schedule_is_stale(self) -> None:
        report = self.sweep({"gone-flake": Producer(runs=[success(2, age=STALE)])})
        self.assertEqual(report.verdicts(), {"gone-flake": "stale"})
        self.assertIn(f"no scheduled run has finished since {date_of(STALE)}", report.line_for("gone-flake"))

    def test_the_staleness_window_is_a_knob(self) -> None:
        producers = {"gone-flake": Producer(runs=[success(2, age=STALE)])}
        self.assertEqual(self.sweep(producers, ["--stale-after", "3600"]).verdicts(), {"gone-flake": "stale"})
        self.assertEqual(
            self.sweep(producers, ["--stale-after", "315576000"]).verdicts(), {"gone-flake": "healthy"}
        )

    def test_a_producer_whose_runs_cannot_be_read_is_reported_not_dropped(self) -> None:
        producers = {
            "kapowarr-flake": Producer(),
            "live-flake": Producer(runs=[success(1)]),
        }
        report = self.sweep(producers, refuse_runs={"kapowarr-flake": 403})
        self.assertEqual(report.verdicts(), {"kapowarr-flake": "unobserved", "live-flake": "healthy"})
        self.assertEqual(report.status, 0)
        self.assertIn("HTTP 403", report.line_for("kapowarr-flake"))

    def test_each_updater_workflow_of_a_producer_is_judged_on_its_own(self) -> None:
        # flake-lib ships two updater templates and an author may install both, and they fire on
        # the same cron minute: a green updater must not answer for the red one beside it.
        producers = {
            "bun-flake": Producer(
                runs=[
                    success(20, workflow=BRANCHES, age=1800),
                    failure(19, workflow=VERSION, age=1800),
                    failure(18, workflow=VERSION, age=86400),
                    success(17, workflow=BRANCHES, age=86400),
                ]
            )
        }
        report = self.sweep(producers, ["--report-issue"])
        self.assertEqual(
            report.verdicts(),
            {"bun-flake update-version.yml": "red", "bun-flake update-branches.yml": "healthy"},
        )
        self.assertEqual(report.api.created[0]["title"], "1 producer updater not publishing")
        self.assertIn("| `bun-flake update-version.yml` | red | 2 |", report.api.created[0]["body"])

    def test_runs_that_never_finish_age_into_stale(self) -> None:
        report = self.sweep(
            {"stuck-flake": Producer(runs=[inflight(3, age=STALE), inflight(2, age=STALE + 3600)])}
        )
        self.assertEqual(report.verdicts(), {"stuck-flake": "stale"})

    def test_a_schedule_that_was_removed_ages_into_stale(self) -> None:
        report = self.sweep({"hand-flake": Producer(runs=[failure(3, event="workflow_dispatch", age=STALE)])})
        self.assertEqual(report.verdicts(), {"hand-flake": "stale"})
        self.assertIn("nothing has run on a schedule", report.line_for("hand-flake"))

    def test_a_silent_updater_file_is_not_reported_beside_the_one_that_replaced_it(self) -> None:
        # flake-lib's own template rename, which the fleet went through as a whole: the old
        # file stopped running when its successor took over, and that is not a producer waiting
        # to publish. What is reported is the successor failing.
        producers = {
            "bun-flake": Producer(
                runs=[
                    failure(9, workflow=BRANCHES),
                    failure(8, workflow=BRANCHES, age=86400),
                    success(7, workflow=LEGACY, age=STALE),
                    success(6, workflow=LEGACY, age=STALE + 3600),
                ]
            )
        }
        self.assertEqual(self.sweep(producers).verdicts(), {"bun-flake": "red"})

    def test_a_producer_whose_updaters_have_all_gone_quiet_is_stale(self) -> None:
        producers = {
            "gone-flake": Producer(
                runs=[
                    success(4, workflow=BRANCHES, event="workflow_dispatch", age=STALE),
                    success(3, workflow=LEGACY, age=STALE + 3600),
                ]
            )
        }
        report = self.sweep(producers)
        self.assertEqual(report.verdicts(), {"gone-flake": "stale"})
        self.assertIn(f"no scheduled run has finished since {date_of(STALE + 3600)}", report.line_for("gone-flake"))

    def test_a_run_list_that_is_not_json_blinds_one_producer_not_the_sweep(self) -> None:
        producers = {"broken-flake": Producer(), "live-flake": Producer(runs=[success(1)])}
        report = self.sweep(producers, unparseable_runs=["broken-flake"])
        self.assertEqual(report.status, 0)
        self.assertEqual(report.verdicts(), {"broken-flake": "unobserved", "live-flake": "healthy"})

    def test_a_run_record_with_a_null_field_is_dropped_not_fatal(self) -> None:
        broken = dict(run_item(9), path=None, name=None, html_url=None)
        report = self.sweep({"broken-flake": Producer(runs=[broken, success(1, age=3600)])})
        self.assertEqual(report.verdicts(), {"broken-flake": "healthy"})

    def test_a_fleet_that_cannot_be_read_at_all_fails_instead_of_reporting_green(self) -> None:
        producers = {"a-flake": Producer(), "b-flake": Producer()}
        report = self.sweep(producers, ["--report-issue"], refuse_runs={"a-flake": 403, "b-flake": 403})
        self.assertEqual(report.status, 1)
        self.assertIn("the fleet's state is unknown", report.stderr)
        self.assertEqual(report.api.writes(), ([], [], []))

    def test_an_empty_fleet_is_a_failure_and_not_a_green_report(self) -> None:
        report = self.sweep({}, ["--report-issue"])
        self.assertEqual(report.status, 1)
        self.assertIn("nothing was swept", report.stderr)
        self.assertEqual(report.api.writes(), ([], [], []))

    def test_archived_and_foreign_repositories_are_not_swept(self) -> None:
        producers = {
            "live-flake": Producer(runs=[success(1)]),
            "dead-flake": Producer(runs=failing_streak(), archived=True),
        }
        report = self.sweep(producers)
        self.assertEqual(report.order(), ["live-flake"])
        self.assertEqual(producers["dead-flake"].reads, 0)

    def test_the_producer_name_suffix_is_a_knob(self) -> None:
        # argparse reads a value that starts with "-" only in the attached form.
        report = self.sweep({"live-flake": Producer(runs=[success(1)])}, ["--suffix=-library"])
        self.assertEqual(report.lines[0], "0 -library repositories swept in jgus-org")
        self.assertEqual(report.order(), [])

    def test_the_organisation_is_listed_through_every_page(self) -> None:
        producers = {f"p{n}-flake": Producer(runs=[success(n)]) for n in (1, 2, 3)}
        with mock.patch.object(SWEEP, "PAGE_SIZE", 2):
            report = self.sweep(producers)
        self.assertEqual(len(report.order()), 3)
        self.assertTrue(all(producer.reads == 1 for producer in producers.values()))

    def test_an_organisation_that_cannot_be_listed_fails_the_sweep(self) -> None:
        producers = {"bun-flake": Producer()}
        report = self.sweep(producers, refuse_org=500)
        self.assertEqual(report.status, 1)
        self.assertIn("cannot be listed", report.stderr)
        self.assertEqual(producers["bun-flake"].reads, 0)

    def test_without_a_token_nothing_is_read(self) -> None:
        producers = {"bun-flake": Producer()}
        report = self.run_sweep(Api(producers), environment={})
        self.assertEqual(report.status, 1)
        self.assertIn("no GH_TOKEN or GITHUB_TOKEN", report.stderr)
        self.assertIn("no GITHUB_REPOSITORY", report.stderr)
        self.assertEqual(report.api.requests, [])
        self.assertEqual(producers["bun-flake"].reads, 0)

    def test_the_report_is_deterministic(self) -> None:
        runs = [failure(4, age=3600), failure(3, age=86400), success(2, age=172800)]
        first = self.sweep({"bun-flake": Producer(runs=runs), "tidarr-flake": Producer(runs=[success(1)])})
        second = self.sweep({"bun-flake": Producer(runs=runs), "tidarr-flake": Producer(runs=[success(1)])})
        self.assertEqual(first.lines, second.lines)

    # -- what the sweep writes -----------------------------------------------------------

    def test_printing_the_report_writes_nothing(self) -> None:
        producers = {"bun-flake": Producer(runs=[failure(4, age=3600), failure(3, age=86400)])}
        report = self.sweep(producers)
        self.assertEqual(report.status, 0)
        self.assertIn("--report-issue", report.lines[-1])
        self.assertEqual(report.api.writes(), ([], [], []))

    def test_a_red_fleet_opens_the_tracking_issue(self) -> None:
        producers = {"bun-flake": Producer(runs=[failure(4, age=3600), failure(3, age=86400)])}
        report = self.sweep(producers, ["--report-issue"])
        self.assertEqual(report.status, 0)
        created, edits, comments = report.api.writes()
        self.assertEqual((edits, comments), ([], []))
        self.assertEqual(len(created), 1)
        self.assertEqual(created[0]["title"], "1 producer updater not publishing")
        body = created[0]["body"]
        self.assertEqual(body.splitlines()[0], SWEEP.marker(["bun-flake"]))
        self.assertIn("| `bun-flake` | red | 2 |", body)

    def test_a_green_fleet_with_no_issue_writes_nothing(self) -> None:
        producers = {"bun-flake": Producer(runs=[success(1)]), "dead-flake": Producer(runs=[])}
        report = self.sweep(producers, ["--report-issue"])
        self.assertEqual(report.status, 0)
        self.assertIn("nothing to report", report.lines[-1])
        self.assertEqual(report.api.writes(), ([], [], []))

    def test_a_green_fleet_with_a_closed_issue_writes_nothing(self) -> None:
        producers = {"bun-flake": Producer(runs=[success(1)]), "dead-flake": Producer(runs=[])}
        report = self.sweep(producers, ["--report-issue"], tracked=[Tracked(state="closed")])
        self.assertEqual(report.status, 0)
        self.assertIn("nothing to report", report.lines[-1])
        self.assertEqual(report.api.writes(), ([], [], []))

    def test_an_unchanged_fleet_edits_the_issue_nothing(self) -> None:
        producers = {"bun-flake": Producer(runs=[failure(4, age=3600), failure(3, age=86400)])}
        opened = self.sweep(producers, ["--report-issue"]).api.created[0]
        api = Api(producers, tracked=[Tracked(title=opened["title"], body=opened["body"])])
        report = self.run_sweep(api, ["--report-issue"])
        self.assertEqual(report.status, 0)
        self.assertEqual(api.writes(), ([], [], []))

    def test_the_link_to_the_sweep_run_does_not_make_every_run_a_change(self) -> None:
        # Under Actions every sweep has a different run id: the link belongs in the comment a
        # change produces, never in the body that is compared for a change.
        producers = {"bun-flake": Producer(runs=[failure(4, age=3600), failure(3, age=86400)])}
        opened = self.sweep(producers, ["--report-issue"]).api.created[0]
        api = Api(producers, tracked=[Tracked(title=opened["title"], body=opened["body"])])
        report = self.sweep(
            producers,
            ["--report-issue"],
            environment={
                "GITHUB_TOKEN": "fixture",
                "GITHUB_REPOSITORY": REPOSITORY,
                "GITHUB_SERVER_URL": "https://github.com",
                "GITHUB_RUN_ID": "98765",
            },
            tracked=api.tracked,
        )
        self.assertEqual(report.status, 0)
        self.assertEqual(report.api.writes(), ([], [], []))

    def test_a_changed_set_of_red_producers_is_commented_on(self) -> None:
        producers = {
            "bun-flake": Producer(runs=[failure(4, age=3600), failure(3, age=86400)]),
            "tidarr-flake": Producer(runs=[success(1)]),
        }
        report = self.sweep(producers, ["--report-issue"], tracked=[Tracked(attention=("tidarr-flake",))])
        self.assertEqual(report.status, 0)
        comments = report.api.comments
        self.assertEqual([number for number, _ in comments], [7])
        self.assertIn("1 producer updater not publishing", comments[0][1])
        self.assertIn("newly not publishing: bun-flake", comments[0][1])
        self.assertIn("recovered: tidarr-flake", comments[0][1])
        self.assertEqual([number for number, changes in report.api.edits if "body" in changes], [7])

    def test_a_recovered_fleet_closes_the_issue(self) -> None:
        producers = {"bun-flake": Producer(runs=[success(1)])}
        report = self.sweep(producers, ["--report-issue"], tracked=[Tracked()])
        self.assertEqual(report.status, 0)
        self.assertIn("green again", report.api.comments[0][1])
        self.assertEqual(report.api.edits, [(7, {"state": "closed"})])
        self.assertIn(f"closed {REPOSITORY}#7", report.lines[-1])

    def test_a_red_fleet_reopens_a_closed_issue(self) -> None:
        producers = {"bun-flake": Producer(runs=[failure(4, age=3600), failure(3, age=86400)])}
        report = self.sweep(producers, ["--report-issue"], tracked=[Tracked(state="closed")])
        self.assertEqual(report.status, 0)
        number, changes = report.api.edits[0]
        self.assertEqual((number, changes["state"]), (7, "open"))
        self.assertEqual(changes["title"], "1 producer updater not publishing")

    def test_a_refused_write_fails_the_run_and_not_the_report(self) -> None:
        producers = {"bun-flake": Producer(runs=[failure(4, age=3600), failure(3, age=86400)])}
        printed = self.sweep(producers)
        blocked = self.sweep(producers, ["--report-issue"], refuse_write=403)
        self.assertEqual(blocked.status, 1)
        self.assertIn("could not be written", blocked.stderr)
        self.assertEqual(blocked.lines, printed.lines[:-1])

    def test_the_newest_marked_issue_is_the_one_that_is_used(self) -> None:
        producers = {"bun-flake": Producer(runs=[success(1)])}
        report = self.sweep(
            producers,
            ["--report-issue"],
            tracked=[Tracked(number=3), Tracked(number=9, attention=())],
        )
        self.assertIn("carries 2 issues with the sweep's marker", report.stderr)
        self.assertIn("#9 is used", report.stderr)
        self.assertEqual(report.lines[-1], f"closed {REPOSITORY}#9: every producer is green")

    def test_a_pull_request_carrying_the_marker_is_not_the_tracking_issue(self) -> None:
        producers = {"bun-flake": Producer(runs=[success(1)])}
        pull_request = {
            "number": 80,
            "state": "open",
            "title": "a pull request",
            "body": f"<!-- {SWEEP.ISSUE_MARKER} [] -->",
            "pull_request": {"html_url": "https://github.com/pull/80"},
        }
        report = self.sweep(producers, ["--report-issue"], tracked=[pull_request])
        self.assertEqual(report.status, 0)
        self.assertEqual(report.api.writes(), ([], [], []))

    def test_an_unreadable_marker_counts_as_a_change(self) -> None:
        producers = {"bun-flake": Producer(runs=[failure(4, age=3600), failure(3, age=86400)])}
        report = self.sweep(
            producers, ["--report-issue"], tracked=[Tracked(body=f"<!-- {SWEEP.ISSUE_MARKER} not json -->")]
        )
        self.assertEqual(report.status, 0)
        self.assertEqual(len(report.api.comments), 1)

    def test_the_step_summary_carries_the_report(self) -> None:
        producers = {"bun-flake": Producer(runs=[failure(4, age=3600), failure(3, age=86400)])}
        report = self.sweep(
            producers,
            environment={
                "GITHUB_TOKEN": "fixture",
                "GITHUB_REPOSITORY": REPOSITORY,
                "GITHUB_STEP_SUMMARY": str(self.summary),
            },
        )
        written = self.summary.read_text()
        self.assertIn("## Producer updater health", written)
        self.assertIn(report.line_for("bun-flake"), written)
        self.assertIn("1 red", written)


class RenderingTests(unittest.TestCase):
    def test_the_link_to_the_sweep_run_appears_only_under_actions(self) -> None:
        self.assertEqual(SWEEP.run_link(), "")
        with mock.patch.dict(
            os.environ,
            {
                "GITHUB_SERVER_URL": "https://github.com",
                "GITHUB_REPOSITORY": REPOSITORY,
                "GITHUB_RUN_ID": "42",
            },
            clear=True,
        ):
            self.assertEqual(SWEEP.run_link(), f"https://github.com/{REPOSITORY}/actions/runs/42")

    def test_a_run_record_without_its_required_fields_is_ignored(self) -> None:
        self.assertIsNone(SWEEP.parse_run({"run_number": 1}))

    def test_the_marker_round_trips_through_a_body(self) -> None:
        self.assertEqual(SWEEP.tracked_attention(SWEEP.marker(["a-flake", "b-flake"])), ("a-flake", "b-flake"))

    def test_a_marker_that_is_not_a_list_of_names_is_empty(self) -> None:
        self.assertEqual(SWEEP.tracked_attention(f"<!-- {SWEEP.ISSUE_MARKER} {{}} -->"), ())
        self.assertEqual(SWEEP.tracked_attention(f"<!-- {SWEEP.ISSUE_MARKER} [1, \"a\"] -->"), ("a",))


if __name__ == "__main__":
    unittest.main()
