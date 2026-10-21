"""Report the producers whose scheduled update has stopped publishing.

A producer's published tree is frozen at the lock of its last green update run, so
`nix build` on its `main` keeps passing while its updater has been red for weeks: the
repository looks maintained and publishes nothing. Nothing joins those two facts today --
producers have no pull-request CI, and a red scheduled run notifies nobody.

This reads the fleet's run history and says which producers are in that state. Each updater
workflow a producer has is judged on its own, because a green updater says nothing about the
one beside it. An update run is read from the repository's own run list rather than from the
workflow files it has now, because a run records the workflow path it had when it ran: an
updater that is renamed or rewritten keeps its history, which the current-files view loses
completely. Only the schedule trigger is counted as a success or a failure, since a manual
dispatch that succeeds says nothing about a schedule that fails every night, and a run that
has not finished has no conclusion. Silence is judged for the producer rather than for one of
its workflow files: when none of its updaters has finished a scheduled run recently the
producer is `stale`, which covers a schedule that was removed and runs that never finish, and
leaves a file that flake-lib's own templates replaced out of the report.

A run's conclusion is not evidence about the producer, so every failure the report would print is
asked what it failed on: its log is read for a build error or a refused push, and for an endpoint
or substituter that would not answer. A failure that names an endpoint is `infra` rather than `red`,
because a binary cache that is unreachable for ten minutes puts every producer in the fleet red
at once while not one of them is broken, and a report of five broken producers where none is
broken is a report that gets muted -- which is how caddy comes back. Only the positive answer
spares a producer: a log that cannot be read, or that matches nothing, stays red. The producer's
own schedule is the retry, so nothing in another repository is re-dispatched to ask twice. An
endpoint that answers and refuses (401, 403) is `denied`, which no retry clears and which is
therefore a standing condition the first night rather than the third.

A run that succeeds is not evidence about what the producer published, either. The version on the
default branch is read against the repository's release branches, and a producer whose aggregate
names an older release than the newest branch it holds is `behind` and leads the report, because
its jobs are green and its consumers still have the older release. A branch is a release only
when its own pin is the version in its name, so a moving `v0.8` is not one, and a prerelease is
not one either.

The report is one tracking issue in the repository that runs the sweep. The condition is
standing rather than momentary, so it has to stay visible until it is fixed: the issue is
updated in place, commented on only when the set of producers that are not publishing changes,
and closed when the fleet is green. The sweep's own exit status means the sweep is broken and
never that a producer is red -- a monitor that is red because the thing it watches is red gets
muted, and then it is not a monitor. Losing sight of the fleet is therefore a broken sweep,
not a green fleet.
"""

from __future__ import annotations

import argparse
import base64
import io
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from collections import Counter
from collections.abc import Callable, Iterator, Mapping, Sequence
from dataclasses import dataclass, replace
from datetime import datetime, timedelta, timezone
from typing import Any

DEFAULT_API = "https://api.github.com"
USER_AGENT = "flake-lib-updater-health"
REQUEST_TIMEOUT_S = 30.0
PAGE_SIZE = 100
# The workflow files flake-lib's templates install, then the one producers wrote by hand
# before flake-lib shipped templates. A producer that renames its updater out of this set is
# invisible to the sweep, which is what --workflow is for.
UPDATER_WORKFLOWS = ("update-branches.yml", "update-version.yml", "update.yml")
# flake-lib's own README names the fleet: the producers are `jgus-org/*-flake`. Archived
# repositories are skipped, because GitHub stops their schedules and their silence is not a
# signal.
PRODUCER_SUFFIX = "-flake"
# One tracking issue per repository that runs the sweep, found by its marker rather than by
# a title a human might edit.
ISSUE_MARKER = "flake-lib:updater-health"
DATE_FORMAT = "%Y-%m-%d"

RED = "red"
INFRA = "infra"
DENIED = "denied"
BEHIND = "behind"
STALE = "stale"
FIRST_FAILURE = "first-failure"
PENDING = "pending"
NO_UPDATER = "no-updater"
UNOBSERVED = "unobserved"
HEALTHY = "healthy"
# The states the tracking issue is opened for. The rest are reported but do not open or
# reopen anything: one failed night is not a standing condition, and a producer whose newest
# run is recent but off-schedule may simply be a fresh install. A producer with no updater
# history at all has no publication to judge rather than a broken one, and it is a third of the
# fleet -- most of them publish by hand and have no schedule to be late for -- so alerting on
# it would mute the real signal. A refused read is attention on its own first night, because
# unlike an outage it does not clear itself. A behind aggregate leads the report because it
# outranks the run that produced it: an updater that publishes an older release than the newest
# branch it holds is green, and the consumer is still wrong.
ATTENTION_STATES = (BEHIND, RED, STALE, DENIED)
WATCH_STATES = (FIRST_FAILURE, PENDING, UNOBSERVED)
# The verdicts whose failure is worth asking about. A first failure is asked too: the same
# endpoint that ends a long streak at fourteen takes its first night's run with it, and a report
# that calls that "its new updater failed" sends a reader to blame the template that was never
# reached.
FAILED_STATES = (RED, FIRST_FAILURE)
INFRA_DETAIL = "its newest failure named infrastructure, not the producer"
DENIED_DETAIL = "its newest failure was refused by an endpoint, which is a credential or access problem rather than an outage"
PRODUCER = "producer"
UNKNOWN = "unknown"
# What a failed run's log has to say for the failure not to be the producer's. A retryable
# failure names an endpoint or a substituter; a build error, a hash mismatch, or a refused
# push names the producer's own work, and those are checked first so a red build sitting
# beside a download warning stays red.
PRODUCER_SIGNS = (
    "remote rejected",
    "refusing to allow",
    "failed to push some refs",
    "error: builder for",
    "failed with exit code",
    "error: build of",
    "hash mismatch",
    "output has been tampered",
    "error: cannot build",
    "error: status 409",
    "patch does not apply",
    "unresponding configuration",
)
INFRA_SIGNS = (
    "unable to download",
    "no substituter that can build it",
    "curl: (7)",
    "curl: (28)",
    "curl: (35)",
    "curl: (52)",
    "curl: (56)",
    "ssl connect error",
    "tls connect error",
    "failed to connect",
    "could not connect",
    "could not resolve host",
    "connection timed out",
    "connection reset by peer",
    "unexpected eof",
    "broken pipe",
    "http error 5",
    "timeout was reached",
    "send failure",
)
# An endpoint that answers and refuses is a different problem from one that does not answer. A
# 401 or 403 from the cache means a credential or an access list changed, which no retry clears
# and which pages the operator rather than waiting out an outage.
DENIED_SIGNS = (
    "http error 401",
    "http error 403",
    "error: status 401",
    "error: status 403",
    "the requested url returned error: 401",
    "the requested url returned error: 403",
    "401 unauthorized",
    "403 forbidden",
)
EVIDENCE_LIMIT = 40
EVIDENCE_LINE_LIMIT = 240
LOG_LIMIT = 4_000_000
# The two causes that spare a producer, each with the words the report uses when the failure
# before it still blames the producer, and the sentence it leads with when nothing does.
EXCUSING = (INFRA, DENIED)
EXCUSING_DETAIL = {
    INFRA: ("named infrastructure", INFRA_DETAIL),
    DENIED: ("was refused by an endpoint", DENIED_DETAIL),
}
# Two probes because one answer is not enough to spare a producer: the newest failure being
# infrastructure says the last attempt was unlucky, and only the attempt before it says whether
# the producer was publishing beforehand.
CAUSE_PROBES = 2
# The fleet's updaters run daily, so this is roughly three days of the same outage before the
# infrastructure itself is stood up in the issue rather than excused as a passing bad night.
INFRA_STREAK = 3
TRACE_TIMESTAMP = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+Z\s+")
# Whether a producer published what it has. A run that succeeds says the updater worked, not
# that the aggregate it wrote names the newest release the repository holds, so the version on
# the default branch is compared against the release branches: `v0.8.8` whose own pin is 0.8.8
# is a release, while `v0.8` whose pin is 0.8.7 is a moving branch and `v0.8.8-rc3` is a
# prerelease, exact as its pin is. The two pages and four pins are the cost ceiling: the newest
# release branch is what is being looked for, and a producer with a long history of old ones
# should not cost the sweep a page per year of releases.
PIN_FILE = "pin.nix"
PIN_VERSION = re.compile(r'^\s*version\s*=\s*"([^"]+)"', re.MULTILINE)
RELEASE_BRANCH = re.compile(r"^v(\d[0-9A-Za-z.+-]*)$")
PRERELEASE = re.compile(r"[-+](?:rc|pre|alpha|beta|dev|nightly|snapshot|preview|next|canary)", re.IGNORECASE)
VERSION_PARTS = re.compile(r"\d+|\D+")
BRANCH_PAGES = 2
BRANCH_PROBES = 4


class GitHubError(RuntimeError):
    def __init__(self, status: int, detail: str) -> None:
        super().__init__(f"HTTP {status}: {detail}" if status else f"no response: {detail}")
        self.status = status


@dataclass(frozen=True)
class Run:
    identifier: int
    number: int
    workflow: str
    event: str
    status: str
    conclusion: str | None
    created_at: datetime
    url: str

    @property
    def scheduled(self) -> bool:
        return self.event == "schedule"

    @property
    def completed(self) -> bool:
        return self.status == "completed"

    @property
    def succeeded(self) -> bool:
        return self.completed and self.conclusion == "success"


@dataclass(frozen=True)
class Config:
    api: str
    org: str
    repository: str
    workflows: tuple[str, ...]
    suffix: str
    fail_streak: int
    stale_after: timedelta
    report_issue: bool
    cause_probes: int
    infra_streak: int


@dataclass(frozen=True)
class Verdict:
    repo: str
    updater: str
    state: str
    detail: str
    streak: int = 0
    failure: Run | None = None
    failed: tuple[Run, ...] = ()
    attention: bool | None = None

    @property
    def producer(self) -> str:
        return self.repo.partition("/")[2]

    @property
    def needs_attention(self) -> bool:
        # `attention` overrides the state's default so an infrastructure failure can be made to
        # stand up the issue once it has stopped looking like a passing outage.
        if self.attention is not None:
            return self.attention
        return self.state in ATTENTION_STATES


@dataclass(frozen=True)
class Issue:
    number: int
    state: str
    title: str
    body: str
    attention: tuple[str, ...]


class _StopRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, newurl):
        return None


class GitHub:
    def __init__(self, api: str, token: str) -> None:
        self.api = api.rstrip("/")
        self.token = token
        self.opener = urllib.request.build_opener(_StopRedirect)

    def _call(self, method: str, path: str, body: Mapping[str, Any] | None = None) -> Any:
        request = urllib.request.Request(
            f"{self.api}{path}",
            method=method,
            data=None if body is None else json.dumps(body).encode(),
            headers={
                "Accept": "application/vnd.github+json",
                "Authorization": f"Bearer {self.token}",
                "Content-Type": "application/json",
                "User-Agent": USER_AGENT,
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=REQUEST_TIMEOUT_S) as response:
                payload = response.read()
        except urllib.error.HTTPError as error:
            detail = error.read().decode(errors="replace").strip()[:200]
            raise GitHubError(error.code, detail or error.reason) from error
        except urllib.error.URLError as error:
            raise GitHubError(0, str(error.reason)) from error
        if not payload:
            return None
        try:
            return json.loads(payload)
        except ValueError as error:
            raise GitHubError(0, f"the response to {path} was not JSON ({error})") from error

    def get(self, path: str, query: Mapping[str, str] | None = None) -> Any:
        return self._call("GET", f"{path}?{urllib.parse.urlencode(query or {})}")

    def pages(self, path: str, query: Mapping[str, str] | None = None) -> Iterator[list[Any]]:
        page = 1
        while True:
            batch = self.get(path, {**(query or {}), "per_page": str(PAGE_SIZE), "page": str(page)})
            if not isinstance(batch, list):
                raise GitHubError(0, f"{path} answered with something other than a list")
            yield batch
            if len(batch) < PAGE_SIZE:
                return
            page += 1

    def repositories(self, org: str) -> Iterator[list[Any]]:
        return self.pages(f"/orgs/{org}/repos")

    def runs(self, repo: str) -> list[dict[str, Any]]:
        # One page of the newest runs, whatever produced them: the judgement is about the recent
        # tail. A producer whose other workflows outrun that page is reported as `no-updater`,
        # which is why the state says what was seen rather than what the repository has.
        page = self.get(f"/repos/{repo}/actions/runs", {"per_page": str(PAGE_SIZE)})
        runs = page.get("workflow_runs", []) if isinstance(page, dict) else []
        return [item for item in runs if isinstance(item, dict)]

    def issues(self, repository: str) -> Iterator[list[Any]]:
        return self.pages(f"/repos/{repository}/issues", {"state": "all"})

    def published_version(self, repo: str, ref: str = "") -> str | None:
        # The default branch answers when no ref is named, so the sweep never has to assume the
        # branch is called main. A repository with no pin has no aggregate to be behind.
        try:
            item = self.get(f"/repos/{repo}/contents/{PIN_FILE}", {"ref": ref} if ref else None)
        except GitHubError as error:
            if error.status == 404:
                return None
            raise
        encoded = item.get("content") if isinstance(item, dict) else None
        if not isinstance(encoded, str):
            return None
        found = PIN_VERSION.search(base64.b64decode(encoded).decode(errors="replace"))
        return found.group(1) if found else None

    def release_branches(self, repo: str) -> list[str]:
        # Version-named branches, newest first. The names are all that is read here; whether one
        # is exact about the version it names is answered by the pin on the branch itself.
        names: list[str] = []
        for page, batch in enumerate(self.pages(f"/repos/{repo}/branches"), 1):
            names += [name for item in batch if isinstance(name := item.get("name"), str) if RELEASE_BRANCH.match(name)]
            if page >= BRANCH_PAGES:
                break
        return sorted(names, key=lambda name: version_key(name[1:]), reverse=True)

    def create_issue(self, repository: str, title: str, body: str) -> int:
        created = self._call("POST", f"/repos/{repository}/issues", {"title": title, "body": body})
        number = created.get("number") if isinstance(created, dict) else None
        return number if isinstance(number, int) else 0

    def edit_issue(self, repository: str, number: int, changes: Mapping[str, Any]) -> None:
        self._call("PATCH", f"/repos/{repository}/issues/{number}", changes)

    def comment(self, repository: str, number: int, body: str) -> None:
        self._call("POST", f"/repos/{repository}/issues/{number}/comments", {"body": body})

    def run_log(self, repo: str, identifier: int) -> str:
        # The log endpoint answers with a signed URL on another host, so the redirect is taken
        # by hand and the archive is fetched without the token: an organisation token must not
        # travel to a host the API names at redirect time.
        return log_text(self._fetch(self._signed_log_url(repo, identifier)))

    def _signed_log_url(self, repo: str, identifier: int) -> str:
        path = f"/repos/{repo}/actions/runs/{identifier}/logs"
        request = urllib.request.Request(
            f"{self.api}{path}",
            headers={
                "Accept": "application/vnd.github+json",
                "Authorization": f"Bearer {self.token}",
                "User-Agent": USER_AGENT,
            },
        )
        try:
            with self.opener.open(request, timeout=REQUEST_TIMEOUT_S) as response:
                status, location = getattr(response, "status", 200), response.headers.get("Location", "")
        except urllib.error.HTTPError as error:
            if error.code not in (301, 302, 303, 307, 308):
                detail = error.read().decode(errors="replace").strip()[:200]
                raise GitHubError(error.code, detail or error.reason) from error
            location = error.headers.get("Location", "")
            status = error.code
        except urllib.error.URLError as error:
            raise GitHubError(0, str(error.reason)) from error
        if not location:
            raise GitHubError(0, f"{path} answered {status} without naming a log archive")
        return urllib.parse.urljoin(f"{self.api}{path}", location)

    def _fetch(self, url: str) -> bytes:
        request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
        try:
            with urllib.request.urlopen(request, timeout=REQUEST_TIMEOUT_S) as response:
                return response.read()
        except urllib.error.HTTPError as error:
            raise GitHubError(error.code, f"the log archive answered {error.code}") from error
        except urllib.error.URLError as error:
            raise GitHubError(0, f"the log archive could not be fetched ({error.reason})") from error


def parse_run(item: Mapping[str, Any]) -> Run | None:
    # A run record is whatever the API answered with, and one unusable record must not cost the
    # fleet its report, so anything that does not parse is dropped here.
    try:
        return Run(
            identifier=item.get("id") or 0,
            number=item["run_number"],
            workflow=item["path"].rpartition("/")[2],
            event=item["event"],
            status=item["status"],
            conclusion=item.get("conclusion"),
            created_at=datetime.fromisoformat(item["created_at"].replace("Z", "+00:00")),
            url=item["html_url"],
        )
    except (AttributeError, KeyError, TypeError, ValueError):
        return None


def date_of(moment: datetime) -> str:
    return moment.strftime(DATE_FORMAT)


def version_key(version: str) -> tuple[tuple[int, int, str], ...]:
    """Order version strings, so 0.8.10 outranks 0.8.9 and a later datestamp outranks an earlier one.

    A string compare gets both shapes wrong in opposite directions: "0.8.10" sorts under "0.8.9",
    and the fleet's version-less producers use 14-digit timestamps where that happens to work
    only until the year turns.
    """
    return tuple(
        (0, int(part), "") if part.isdigit() else (1, 0, part.lower()) for part in VERSION_PARTS.findall(version)
    )


def behind_the_newest_release(published: str, branches: Sequence[str], pinned: Callable[[str], str | None]) -> str:
    """Name the newest release branch whose version the aggregate does not name, or nothing.

    A branch counts only when the version in its name is the version in its own pin, which is
    what separates a release from a moving branch like `v0.8` sitting at 0.8.7. A prerelease is
    exact and still not what an aggregate should have moved to, so it is passed over without
    being read.
    """
    probes = 0
    for name in branches:
        version = name[1:]
        if version_key(version) <= version_key(published):
            return ""
        if PRERELEASE.search(version) or probes >= BRANCH_PROBES:
            continue
        probes += 1
        if pinned(name) == version:
            return name
    return ""


def newest(runs: Sequence[Run]) -> Run:
    return max(runs, key=lambda run: run.created_at)


def discover_producers(client: GitHub, config: Config) -> list[str]:
    producers: list[str] = []
    for page in client.repositories(config.org):
        for item in page:
            name = item.get("name")
            if not isinstance(name, str) or not name.endswith(config.suffix) or item.get("archived"):
                continue
            producers.append(f"{config.org}/{name}")
    return sorted(producers)


def failed_streak(scheduled: Sequence[Run]) -> tuple[Run, ...]:
    """The failed scheduled runs since the last one that succeeded, newest first."""
    failed: list[Run] = []
    for run in scheduled:
        if not run.completed:
            continue
        if run.succeeded:
            break
        failed.append(run)
    return tuple(failed)


def log_text(payload: bytes) -> str:
    """The text inside the archive a run's log endpoint points at."""
    try:
        with zipfile.ZipFile(io.BytesIO(payload)) as archive:
            text = "".join(
                archive.read(name).decode("utf-8", "replace") for name in sorted(archive.namelist())
            )
    except (OSError, ValueError, zipfile.BadZipFile) as error:
        raise GitHubError(0, f"the log archive was not readable ({error})") from error
    return text[: LOG_LIMIT]


def clean_line(line: str) -> str:
    """A log line without the timestamp Actions prefixes each one with, shortened."""
    return re.sub(TRACE_TIMESTAMP, "", line.strip(), count=1)[:EVIDENCE_LINE_LIMIT]


def evidence_of(text: str) -> tuple[str, str]:
    """Say whether a failed run's log blames the infrastructure or the producer.

    A producer signature wins wherever it appears: a build error sitting among download
    warnings is still a build error, and the download warning is what the retry will clear.
    Between the two ways an endpoint can fail, a refusal outranks silence, because a credential
    or an access list that changed is the one that will still be broken tomorrow.
    """
    infra: list[str] = []
    denied = ""
    for line in text.splitlines():
        lowered = line.lower()
        if any(sign in lowered for sign in PRODUCER_SIGNS):
            return PRODUCER, clean_line(line)
        if any(sign in lowered for sign in DENIED_SIGNS):
            denied = denied or clean_line(line)
        elif any(sign in lowered for sign in INFRA_SIGNS) and len(infra) < EVIDENCE_LIMIT:
            infra.append(clean_line(line))
    if denied:
        return DENIED, denied
    return (INFRA, infra[0]) if infra else (UNKNOWN, "")


def classify(repo: str, updater: str, group: Sequence[Run], config: Config, now: datetime) -> Verdict | None:
    """Judge one updater workflow's own runs, or nothing when it has gone quiet.

    A quiet updater is not reported beside its producer: flake-lib's own template rename makes
    an updater file stop running while its replacement takes over, and a report that said so
    for every renamed file would bury the updaters that are actually red. Silence belongs to
    the producer, which is where `classify_producer` reports it.
    """
    scheduled = sorted((run for run in group if run.scheduled), key=lambda run: run.created_at, reverse=True)
    finished = [run for run in scheduled if run.completed]
    # A schedule that stopped firing is the condition this sweep is for, so silence is measured
    # against the finished schedules when there are any, and against the newest run of any
    # trigger otherwise: a producer whose runs all hang, or whose cron was deleted while
    # someone kept dispatching it by hand, has published nothing either.
    reference = newest(finished) if finished else newest(scheduled or list(group))

    if reference.created_at < now - config.stale_after:
        return None
    if not scheduled:
        return Verdict(
            repo,
            updater,
            PENDING,
            f"its newest run (run {reference.number}) was a {reference.event}, not a schedule",
        )

    failed = failed_streak(scheduled)
    streak, failure = len(failed), (failed[0] if failed else None)
    succeeded_on = next((run.created_at for run in scheduled if run.succeeded), None)
    since = f"last success {date_of(succeeded_on)}" if succeeded_on else "no scheduled run has ever succeeded"
    if failure is not None and streak >= config.fail_streak:
        return Verdict(
            repo,
            updater,
            RED,
            f"{streak} scheduled runs in a row failed ({failure.conclusion}); {since}",
            streak=streak,
            failure=failure,
            failed=failed,
        )
    if failure is not None:
        return Verdict(
            repo,
            updater,
            FIRST_FAILURE,
            f"its most recent scheduled run failed ({failure.conclusion}); {since}",
            streak=streak,
            failure=failure,
            failed=failed,
        )
    return Verdict(repo, updater, HEALTHY, f"its last scheduled run succeeded {date_of(reference.created_at)}")


def silent(repo: str, groups: Mapping[str, Sequence[Run]]) -> Verdict:
    # Every updater the producer has has stopped running: nothing failed and nothing published,
    # which is the same frozen tree a red updater leaves and is invisible to a green build.
    runs = [run for group in groups.values() for run in group]
    finished = [run for run in runs if run.scheduled and run.completed]
    last = newest(finished) if finished else newest(runs)
    if finished:
        detail = f"no scheduled run has finished since {date_of(last.created_at)}"
    else:
        detail = (
            f"nothing has run on a schedule; its newest run (run {last.number}) was a "
            f"{last.event} on {date_of(last.created_at)}"
        )
    return Verdict(repo, "", STALE, detail)


def classify_producer(repo: str, runs: Sequence[Run], config: Config, now: datetime) -> list[Verdict]:
    # Every updater workflow the producer has runs is judged on its own: a producer may install
    # both templates, and one publishing successfully says nothing about the other failing
    # every night.
    groups: dict[str, list[Run]] = {}
    for run in runs:
        if run.workflow in config.workflows:
            groups.setdefault(run.workflow, []).append(run)
    if not groups:
        seen = " or ".join(config.workflows)
        # A producer with a schedule the sweep does not recognise has an updater under another
        # name, and naming it here is what lets the next sweep be pointed at it with --workflow
        # rather than leaving a failing producer reported as though it published nothing.
        scheduled = sorted({run.workflow for run in runs if run.scheduled})
        named = f"; its scheduled runs come from {' and '.join(scheduled)}" if scheduled else ""
        return [Verdict(repo, "", NO_UPDATER, f"none of its {PAGE_SIZE} newest runs came from {seen}{named}")]
    verdicts = [
        verdict
        for updater, group in groups.items()
        if (verdict := classify(repo, updater, group, config, now)) is not None
    ]
    if verdicts:
        return sorted(verdicts, key=lambda verdict: verdict.updater)
    return [silent(repo, groups)]


def explain(client: GitHub, verdict: Verdict, config: Config) -> Verdict:
    """Ask the failed runs' own logs whether the producer is what broke.

    A scheduled run goes red for reasons the producer has no part in: a substituter that answers
    502 once ends with the same conclusion as a build that does not compile. Five of those in one
    report is how a monitor gets muted and caddy comes back, so a failure whose log names an
    endpoint is not reported as a broken producer. Only that positive answer spares the producer:
    text that cannot be read, or that matches nothing, stays red, because an unexplained failure
    is the condition this sweep exists for. The producer's own schedule is the retry, so the
    sweep re-dispatches nothing in someone else's repository.
    """
    if verdict.state not in FAILED_STATES or config.cause_probes <= 0 or not verdict.failed:
        return verdict
    probes: list[tuple[Run, str, str]] = []
    for run in verdict.failed[: config.cause_probes]:
        try:
            cause, evidence = evidence_of(client.run_log(verdict.repo, run.identifier))
        except GitHubError as error:
            cause, evidence = UNKNOWN, f"run {run.number}'s log could not be read ({error})"
        probes.append((run, cause, evidence))
        if cause not in EXCUSING:
            break
    _, cause, evidence = probes[0]
    if cause not in EXCUSING:
        return verdict
    said, detail = EXCUSING_DETAIL[cause]
    if probes[-1][1] not in EXCUSING:
        older, older_cause, _ = probes[-1]
        blamed = "failed for the producer" if older_cause == PRODUCER else "was unexplained"
        excused = f"its newest failure {said}, and run {older.number} before it {blamed}"
        return replace(verdict, detail=f"{verdict.detail}; {excused}")
    # An outage that repeats is the fleet's problem and stands up the issue on its own after
    # --infra-streak. A refusal is not waiting to be repeated: it is broken until somebody
    # changes the credential or the access list back.
    attention = None if cause == DENIED else verdict.streak >= config.infra_streak
    return replace(verdict, state=cause, detail=f"{detail}: {evidence}", attention=attention)


def behind_aggregate(client: GitHub, repo: str) -> Verdict | None:
    """Report a producer whose aggregate names an older release than the newest branch it holds.

    A scheduled run that succeeds proves the updater ran, not that it published the newest
    release the repository has: the fleet's aggregate can sit a release behind a branch the same
    producer pushed and green-lit, and a consumer of that aggregate is wrong while every job is
    green. A repository with no pin has no aggregate, so nothing is said about it; a release
    history that cannot be read is not evidence of a producer being behind either.
    """
    try:
        published = client.published_version(repo)
        if published is None:
            return None
        behind = behind_the_newest_release(
            published, client.release_branches(repo), lambda name: client.published_version(repo, name)
        )
    except GitHubError as error:
        print(f"warning: {repo}'s releases cannot be read, so its aggregate is not judged ({error})", file=sys.stderr)
        return None
    if not behind:
        return None
    return Verdict(repo, "", BEHIND, f"its aggregate names {published} while {behind} pins {behind[1:]}")


def sweep(client: GitHub, config: Config, now: datetime) -> list[Verdict] | None:
    try:
        producers = discover_producers(client, config)
    except GitHubError as error:
        print(f"error: {config.org}'s repositories cannot be listed ({error})", file=sys.stderr)
        return None

    verdicts: list[Verdict] = []
    for repo in producers:
        try:
            runs = [run for item in client.runs(repo) if (run := parse_run(item)) is not None]
        except GitHubError as error:
            # A producer whose history cannot be read is reported as such: dropping it would
            # turn a hole in the sweep's sight into a silent absence.
            verdicts.append(Verdict(repo, "", UNOBSERVED, f"its runs cannot be read ({error})"))
            continue
        verdicts += [explain(client, verdict, config) for verdict in classify_producer(repo, runs, config, now)]
        if (lagging := behind_aggregate(client, repo)) is not None:
            verdicts.append(lagging)
    print(f"{len(producers)} {config.suffix} repositories swept in {config.org}")
    return verdicts


def shared_producers(verdicts: Sequence[Verdict]) -> frozenset[str]:
    return frozenset(repo for repo, count in Counter(v.repo for v in verdicts).items() if count > 1)


def name_of(verdict: Verdict, shared: frozenset[str]) -> str:
    if verdict.updater and verdict.repo in shared:
        return f"{verdict.producer} {verdict.updater}"
    return verdict.producer


def order(verdicts: Sequence[Verdict]) -> list[Verdict]:
    states = (*ATTENTION_STATES, INFRA, *WATCH_STATES, NO_UPDATER, HEALTHY)
    rank = {state: index for index, state in enumerate(states)}
    return sorted(
        verdicts,
        key=lambda verdict: (rank[verdict.state], -verdict.streak, verdict.producer, verdict.updater),
    )


def counts(verdicts: Sequence[Verdict]) -> str:
    by_state: dict[str, int] = {}
    for verdict in verdicts:
        by_state[verdict.state] = by_state.get(verdict.state, 0) + 1
    return ", ".join(f"{by_state[state]} {state}" for state in sorted(by_state))


def render_lines(verdicts: Sequence[Verdict]) -> list[str]:
    shared = shared_producers(verdicts)
    lines = []
    for verdict in order(verdicts):
        link = f"; run {verdict.failure.number} {verdict.failure.url}" if verdict.failure else ""
        lines.append(f"- `{name_of(verdict, shared)}`: {verdict.state} -- {verdict.detail}{link}")
    return lines


def attention_of(verdicts: Sequence[Verdict]) -> tuple[str, ...]:
    shared = shared_producers(verdicts)
    return tuple(sorted(name_of(verdict, shared) for verdict in verdicts if verdict.needs_attention))


def issue_title(count: int) -> str:
    # The title names the consequence rather than the state: a silent updater belongs in the
    # same table as a red one and as one that publishes an older release, and the frozen tree is
    # what the maintainer has to act on.
    return f"{count} producer {'updater' if count == 1 else 'updaters'} not publishing their newest release"


def marker(attention: Sequence[str]) -> str:
    return f"<!-- {ISSUE_MARKER} {json.dumps(list(attention), separators=(',', ':'))} -->"


def tracked_attention(body: str) -> tuple[str, ...]:
    start = body.find(ISSUE_MARKER) + len(ISSUE_MARKER)
    payload = body[start : body.find("-->", start)]
    try:
        recorded = json.loads(payload)
    except ValueError:
        return ()
    if not isinstance(recorded, list):
        return ()
    return tuple(name for name in recorded if isinstance(name, str))


def issue_body(verdicts: Sequence[Verdict], attention: Sequence[str]) -> str:
    shared = shared_producers(verdicts)
    ranked = order(verdicts)
    failing = [verdict for verdict in ranked if verdict.needs_attention]
    watched = [verdict for verdict in ranked if verdict.state in WATCH_STATES]
    unrecognised = [verdict for verdict in ranked if verdict.state == NO_UPDATER]
    parts = [
        marker(attention),
        "",
        f"{len(attention)} producers' scheduled update has stopped publishing, or publishes an "
        "older release than the newest their own repository holds. A producer publishes the tree "
        "its last green run built, so its `main` keeps passing `nix build` while no new version "
        "is published.",
        "",
        "| updater | state | failed runs | what the sweep saw | latest run |",
        "| --- | --- | --- | --- | --- |",
    ]
    for verdict in failing:
        run = f"[run {verdict.failure.number}]({verdict.failure.url})" if verdict.failure else "-"
        columns = (
            "",
            f"`{name_of(verdict, shared)}`",
            verdict.state,
            str(verdict.streak or "-"),
            verdict.detail,
            run,
            "",
        )
        parts.append(" | ".join(columns))
    for heading, group in (
        ("Watching", watched),
        ("Producers with no updater the sweep recognises", unrecognised),
    ):
        if not group:
            continue
        entries = [
            f"- `{name_of(verdict, shared)}`"
            + (f": {verdict.state} -- {verdict.detail}" if group is watched else "")
            for verdict in group
        ]
        parts += ["", f"<details><summary>{heading} ({len(group)})</summary>", "", *entries, "</details>"]

    parts += ["", "Refreshed in place by flake-lib's `Producer updater health` workflow."]
    return "\n".join(parts)


def run_link() -> str:
    server = os.environ.get("GITHUB_SERVER_URL", "")
    repository = os.environ.get("GITHUB_REPOSITORY", "")
    run_id = os.environ.get("GITHUB_RUN_ID", "")
    if not (server and repository and run_id):
        return ""
    return f"{server.rstrip('/')}/{repository}/actions/runs/{run_id}"


def change_comment(before: Sequence[str], after: Sequence[str], link: str) -> str:
    newly = sorted(set(after) - set(before))
    recovered = sorted(set(before) - set(after))
    words = [f"{len(after)} producer {'updater' if len(after) == 1 else 'updaters'} not publishing their newest release"]
    if before and len(before) != len(after):
        words.append(f"was {len(before)}")
    if newly:
        words.append(f"newly not publishing: {', '.join(newly)}")
    if recovered:
        words.append(f"recovered: {', '.join(recovered)}")
    if link:
        words.append(f"[sweep run]({link})")
    return "; ".join(words) + "."


def find_issue(client: GitHub, repository: str) -> Issue | None:
    found: list[Issue] = []
    for page in client.issues(repository):
        for item in page:
            body = item.get("body")
            if "pull_request" in item or not isinstance(body, str) or ISSUE_MARKER not in body:
                continue
            found.append(
                Issue(
                    number=item["number"],
                    state=item["state"],
                    title=item["title"],
                    body=body,
                    attention=tracked_attention(body),
                )
            )
    if not found:
        return None
    current = max(found, key=lambda issue: issue.number)
    if len(found) > 1:
        numbers = ", ".join(f"#{issue.number}" for issue in sorted(found, key=lambda issue: issue.number))
        print(
            f"warning: {repository} carries {len(found)} issues with the sweep's marker ({numbers}); "
            f"#{current.number} is used",
            file=sys.stderr,
        )
    return current


def deliver(client: GitHub, config: Config, verdicts: Sequence[Verdict]) -> bool:
    """Bring the tracking issue to the fleet's current state; False if that failed."""
    attention = attention_of(verdicts)
    try:
        existing = find_issue(client, config.repository)
        if not attention:
            if existing is None or existing.state == "closed":
                print("every producer is green; there is nothing to report")
                return True
            link = run_link()
            client.comment(
                config.repository,
                existing.number,
                "Every producer's scheduled update is green again." + (f" [sweep run]({link})" if link else ""),
            )
            client.edit_issue(config.repository, existing.number, {"state": "closed"})
            print(f"closed {config.repository}#{existing.number}: every producer is green")
            return True

        body = issue_body(verdicts, attention)
        title = issue_title(len(attention))
        if existing is None:
            number = client.create_issue(config.repository, title, body)
            print(f"opened {config.repository}#{number} for {len(attention)} producers")
            return True

        changes: dict[str, Any] = {}
        if existing.state == "closed":
            changes["state"] = "open"
        if title != existing.title:
            changes["title"] = title
        if body != existing.body:
            changes["body"] = body
        if changes:
            client.edit_issue(config.repository, existing.number, changes)
        if attention != existing.attention:
            client.comment(
                config.repository, existing.number, change_comment(existing.attention, attention, run_link())
            )
        print(f"refreshed {config.repository}#{existing.number}")
        return True
    except GitHubError as error:
        print(f"error: the tracking issue could not be written ({error})", file=sys.stderr)
        return False


def parse_args(argv: Sequence[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0], argument_default=None)
    parser.add_argument("--api", help=f"github API base URL (default {DEFAULT_API})")
    parser.add_argument(
        "--org", help="organisation whose producers are swept (default: this repository's owner)"
    )
    parser.add_argument(
        "--workflow",
        action="append",
        dest="workflows",
        help="workflow file that counts as a producer's updater; repeatable, default the template files",
    )
    parser.add_argument(
        "--suffix", help=f"repository-name suffix that names a producer (default {PRODUCER_SUFFIX})"
    )
    parser.add_argument(
        "--fail-streak", type=int, help="consecutive failed scheduled runs that make an updater red"
    )
    parser.add_argument(
        "--cause-probes",
        type=int,
        help=f"failed runs whose logs are read to blame infrastructure rather than the producer;"
        f" 0 reads none (default {CAUSE_PROBES})",
    )
    parser.add_argument(
        "--infra-streak",
        type=int,
        help=f"consecutive infrastructure failures that stand up the issue themselves "
        f"(default {INFRA_STREAK})",
    )
    parser.add_argument(
        "--stale-after",
        type=float,
        help="seconds without a finished scheduled run that make a producer stale; at least the fleet's slowest schedule",
    )
    parser.add_argument(
        "--report-issue",
        action="store_true",
        help="write the report into a tracking issue in this repository; by default it is only printed",
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    repository = os.environ.get("GITHUB_REPOSITORY", "")
    # Reads prefer the organisation token, which sees the fleet's private producers; the
    # tracking issue is written with the token that owns this repository.
    read_token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN") or ""
    report_token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN") or ""
    problems = []
    if not read_token:
        problems.append("no GH_TOKEN or GITHUB_TOKEN, so no run history can be read")
    if not (args.org or "/" in repository):
        problems.append("no --org, and no GITHUB_REPOSITORY to take the organisation from")
    if args.report_issue and "/" not in repository:
        problems.append("--report-issue needs GITHUB_REPOSITORY, the repository whose issue is written")
    if problems:
        for problem in problems:
            print(f"error: {problem}", file=sys.stderr)
        return 1

    config = Config(
        api=args.api or DEFAULT_API,
        org=args.org or repository.partition("/")[0],
        repository=repository,
        workflows=tuple(args.workflows) if args.workflows else UPDATER_WORKFLOWS,
        suffix=args.suffix or PRODUCER_SUFFIX,
        fail_streak=args.fail_streak if args.fail_streak is not None else 2,
        stale_after=timedelta(seconds=args.stale_after if args.stale_after is not None else 3 * 86400),
        report_issue=args.report_issue,
        cause_probes=args.cause_probes if args.cause_probes is not None else CAUSE_PROBES,
        infra_streak=args.infra_streak if args.infra_streak is not None else INFRA_STREAK,
    )

    verdicts = sweep(GitHub(config.api, read_token), config, datetime.now(timezone.utc))
    if verdicts is None:
        return 1
    for line in render_lines(verdicts):
        print(line)
    summary = counts(verdicts)
    print(f"summary: {summary}")
    if step_summary := os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(step_summary, "a", encoding="utf-8") as summary_file:
            summary_file.write(
                "\n".join(("## Producer updater health", "", *render_lines(verdicts), "", summary, ""))
            )

    if not verdicts:
        print(f"error: {config.org} has no {config.suffix} repository to read: nothing was swept", file=sys.stderr)
        return 1
    if all(verdict.state == UNOBSERVED for verdict in verdicts):
        print(
            f"error: none of the {len({verdict.repo for verdict in verdicts})} repositories swept could be "
            "read, so the fleet's state is unknown and no report was written",
            file=sys.stderr,
        )
        return 1
    if not config.report_issue:
        print("the report was printed only; pass --report-issue to write the tracking issue")
        return 0
    return 0 if deliver(GitHub(config.api, report_token), config, verdicts) else 1


if __name__ == "__main__":
    raise SystemExit(main())
