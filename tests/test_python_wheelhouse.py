import hashlib
import json
import os
import shutil
import stat
import subprocess
import tempfile
import threading
import unittest
import functools
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

SCRIPT = Path(os.environ["WHEELHOUSE_PY"]).resolve()
DEPS_CORE = Path(os.environ["DEPS_CORE"]).resolve()

FAKE_WHEELS = {
    "fakepkg-1.0.0-py3-none-any.whl": b"fakepkg-wheel-bytes",
    "fakenative-2.1.0-cp313-cp313-manylinux_2_28_x86_64.whl": b"fakenative-wheel-bytes",
}
FIXTURE_LOCK = "fakepkg==1.0.0 --hash=sha256:aa\nfakenative==2.1.0 --hash=sha256:bb\n"


def write_executable(path: Path, body: str) -> None:
    path.write_text("#!" + os.environ["TEST_BASH"] + "/bin/bash\n" + body)
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class IndexHandler(SimpleHTTPRequestHandler):
    def do_GET(self) -> None:
        parts = self.path.strip("/").split("/")
        if len(parts) == 2 and parts[0] == "simple":
            self.path = f"/simple/{parts[1]}/index.json"
        super().do_GET()

    def log_message(self, format: str, *args) -> None:
        pass


def serve_index(directory: Path) -> object:
    handler = functools.partial(IndexHandler, directory=str(directory))
    server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def current_env() -> dict:
    return {
        "python": "3.13",
        "uvPythonVersion": "3.13",
        "uvPythonPlatform": "x86_64-manylinux_2_28",
        "pipPythonVersion": "313",
        "pipPlatforms": ["manylinux_2_28_x86_64", "manylinux_2_17_x86_64", "linux_x86_64"],
        "pipAbi": "cp313",
        "pipAbiLadder": ["cp313", "cp312", "cp311", "cp310", "cp39", "cp38", "abi3", "none"],
    }


def prepared_env(python: str) -> dict:
    return {
        "python": python,
        "uvPythonVersion": python,
        "uvPythonPlatform": "x86_64-manylinux_2_28",
        "pipPythonVersion": python.replace(".", ""),
        "pipPlatforms": ["manylinux_2_28_x86_64", "linux_x86_64"],
        "pipAbi": "cp" + python.replace(".", ""),
        "pipAbiLadder": ["cp" + python.replace(".", ""), "abi3", "none"],
    }


def invoke_hook(work: Path, index_url: str, spec: dict, extra_env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    spec = spec | {"indexUrl": index_url, "fingerprint": spec.get("fingerprint", "test-fingerprint")}
    return subprocess.run(
        ["python3", str(SCRIPT)],
        cwd=work,
        env={
            "PATH": f"{work / 'bin'}:{os.environ['PATH']}",
            "WHEELHOUSE_SPEC": json.dumps(spec),
            "DEPS_CORE": str(DEPS_CORE),
            "FLAKE_ROOT": str(work / "flake-root"),
            "NEW_REV": "abc123",
            "GH_OWNER": "acme",
            "GH_REPO": "widget",
            "HOME": str(work),
        }
        | extra_env,
        capture_output=True,
        text=True,
    )


def run_hook(work: Path, index_url: str, spec: dict, extra_env: dict[str, str]) -> tuple[str, Path]:
    result = invoke_hook(work, index_url, spec, extra_env)
    assert result.returncode == 0, result.stderr
    return result.stdout, work / "flake-root"


def aggregate_sha(environments: list[dict], root: Path, pattern: str) -> str:
    entries = [
        {"python": environment["python"], "sha256": sha256((root / pattern.format(python=environment["python"])).read_bytes())}
        for environment in environments
    ]
    encoded = json.dumps(entries, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()


CURRENT = current_env()
SECOND = prepared_env("3.14")
CURRENT_PY = CURRENT["python"]
SECOND_PY = SECOND["python"]


class PythonWheelhouseTests(unittest.TestCase):
    def setUp(self) -> None:
        self.work = Path(tempfile.mkdtemp(prefix="wheelhouse-test-"))
        self.addCleanup(shutil.rmtree, self.work)
        (self.work / "bin").mkdir()
        (self.work / "flake-root").mkdir()

        source = self.work / "source-fixture"
        (source / "reqs").mkdir(parents=True)
        (source / "pyproject.toml").write_text(
            "[project]\nname = 'widget'\ndependencies = ['fakepkg>=1.0']\n\n"
            "[project.optional-dependencies]\nstudio = ['fakenative==2.1.0']\n"
        )
        (source / "reqs" / "studio.txt").write_text(
            "fakepkg==1.0.0 # pinned\n"
        )
        lock = source / "lock.txt"
        lock.write_text(FIXTURE_LOCK)

        log = self.work / "commands.log"
        self.log = log

        write_executable(self.work / "bin" / "git", (
            'echo "git $*" >> ' + str(log) + '\n'
            'if [[ "$1" == clone ]]; then cp -r "$SOURCE_FIXTURE" "${@: -1}"; fi\n'
        ))
        write_executable(self.work / "bin" / "uv", (
            'echo "uv $*" >> ' + str(log) + '\n'
            'if [[ "$1 $2" == "pip compile" ]]; then\n'
            '  ARGS=("$@")\n'
            '  PY=""; OUT=""\n'
            '  for ((i = 0; i < ${#ARGS[@]}; i++)); do\n'
            '    if [[ "${ARGS[i]}" == "--python-version" ]]; then PY="${ARGS[i + 1]}"; fi\n'
            '    if [[ "${ARGS[i]}" == "--output-file" ]]; then OUT="${ARGS[i + 1]}"; fi\n'
            '  done\n'
            '  if [[ -n "${FAKE_UV_FAIL:-}" && "${PY}" == "${FAKE_UV_FAIL}" ]]; then\n'
            '    echo "error: no version satisfies fakenative for python ${PY}" >&2\n'
            '    exit 1\n'
            '  fi\n'
            '  cp "$FIXTURE_LOCK" "$OUT"\n'
            'fi\n'
        ))
        write_executable(self.work / "bin" / "pip", (
            'echo "pip $*" >> ' + str(log) + '\n'
            'ARGS=("$@")\n'
            'DEST=""; PY=""\n'
            'for ((i = 0; i < ${#ARGS[@]}; i++)); do\n'
            '  if [[ "${ARGS[i]}" == "--dest" ]]; then DEST="${ARGS[i + 1]}"; fi\n'
            '  if [[ "${ARGS[i]}" == "--python-version" ]]; then PY="${ARGS[i + 1]}"; fi\n'
            'done\n'
            'for wheel in "$FAKE_WHEELS_DIR"/*.whl; do cp "$wheel" "$DEST"; done\n'
            'if [[ -n "${FAKE_PIP_INDEX_FAIL:-}" && "${PY}" == "${FAKE_PIP_INDEX_FAIL}" ]]; then\n'
            '  cp "$FAKE_WHEELS_DIR/fakepkg-1.0.0-py3-none-any.whl" "$DEST/absentpkg-1.0.0-py3-none-any.whl"\n'
            'fi\n'
        ))

        wheelhouse_dir = self.work / "fake-wheels"
        wheelhouse_dir.mkdir()
        for filename, content in FAKE_WHEELS.items():
            (wheelhouse_dir / filename).write_bytes(content)

        simple = self.work / "simple"
        for project, filename in (
            ("fakepkg", "fakepkg-1.0.0-py3-none-any.whl"),
            ("fakenative", "fakenative-2.1.0-cp313-cp313-manylinux_2_28_x86_64.whl"),
        ):
            project_dir = simple / project
            project_dir.mkdir(parents=True)
            (project_dir / "index.json").write_text(json.dumps({
                "files": [{
                    "filename": filename,
                    "hashes": {"sha256": sha256(FAKE_WHEELS[filename])},
                    "url": "https://files.example.test/" + filename,
                }],
            }))

        server = serve_index(self.work)
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        self.index_url = f"http://127.0.0.1:{server.server_port}/simple"

        self.common_env = {
            "SOURCE_FIXTURE": str(source),
            "FIXTURE_LOCK": str(lock),
            "FAKE_WHEELS_DIR": str(wheelhouse_dir),
        }

    def spec_with(self, environments: list[dict]) -> dict:
        return {
            "sources": [
                {"kind": "source-pyproject", "groups": ["studio"]},
                {"kind": "source-file", "path": "reqs/studio.txt"},
            ],
            "extraRequirements": ["ninja", "fakepkg>=1.0"],
            "environments": environments,
        }

    def test_source_and_repo_mix(self) -> None:
        spec = self.spec_with([CURRENT, SECOND])
        stdout, root = run_hook(self.work, self.index_url, spec, self.common_env)

        requirements_in = (root / "requirements.in").read_text()
        self.assertIn("acme/widget@abc123", requirements_in)
        self.assertIn("fakepkg>=1.0", requirements_in)
        self.assertIn("fakenative==2.1.0", requirements_in)
        self.assertIn("ninja", requirements_in)
        self.assertNotIn("other.txt", requirements_in)
        self.assertEqual(requirements_in.count("fakepkg"), 2)
        self.assertIn("fakepkg==1.0.0", requirements_in)

        commands = self.log.read_text()
        self.assertIn("--generate-hashes", commands)
        self.assertIn("--python-platform x86_64-manylinux_2_28", commands)
        self.assertIn("--platform manylinux_2_28_x86_64", commands)
        self.assertIn("--platform linux_x86_64", commands)
        self.assertIn("--abi cp313", commands)
        self.assertIn("--require-hashes", commands)
        self.assertIn("--only-binary :all:", commands)
        self.assertIn("--abi cp313", commands)
        self.assertIn("--abi abi3", commands)
        self.assertIn("--abi none", commands)

        manifest = json.loads((root / f"wheels-{CURRENT_PY}.json").read_text())
        self.assertEqual([entry["name"] for entry in manifest], ["fakenative", "fakepkg"])
        self.assertEqual(manifest[1]["version"], "1.0.0")
        self.assertEqual(manifest[0]["url"], "https://files.example.test/fakenative-2.1.0-cp313-cp313-manylinux_2_28_x86_64.whl")
        self.assertEqual(manifest[1]["sha256"], sha256(FAKE_WHEELS["fakepkg-1.0.0-py3-none-any.whl"]))
        self.assertEqual(manifest[1]["size"], len(FAKE_WHEELS["fakepkg-1.0.0-py3-none-any.whl"]))

        self.assertIn("artifactFingerprint=test-fingerprint", stdout)
        self.assertIn("requirementsHash=" + aggregate_sha([CURRENT, SECOND], root, "requirements-{python}.lock"), stdout)
        self.assertIn("wheelManifestHash=" + aggregate_sha([CURRENT, SECOND], root, "wheels-{python}.json"), stdout)
        self.assertTrue((root / f"requirements-{SECOND_PY}.lock").exists())
        self.assertTrue((root / f"wheels-{SECOND_PY}.json").exists())
        self.assertFalse((root / "python-readiness.json").exists())

    def test_two_environment_set_is_vendored(self) -> None:
        spec = self.spec_with([CURRENT, SECOND])
        stdout, root = run_hook(self.work, self.index_url, spec, self.common_env)

        vendored = json.loads((root / f"wheels-{SECOND_PY}.json").read_text())
        self.assertEqual([entry["name"] for entry in vendored], ["fakenative", "fakepkg"])
        self.assertTrue((root / f"requirements-{SECOND_PY}.lock").exists())

    def test_environment_failure_preserves_last_known_good_set(self) -> None:
        root = self.work / "flake-root"
        preserved = {
            "requirements.in": "old input",
            f"requirements-{CURRENT_PY}.lock": "old current lock",
            f"wheels-{CURRENT_PY}.json": "old current manifest",
            f"requirements-{SECOND_PY}.lock": "old second lock",
            f"wheels-{SECOND_PY}.json": "old second manifest",
            "python-readiness.json": "old readiness",
        }
        for name, content in preserved.items():
            (root / name).write_text(content)
        spec = self.spec_with([CURRENT, SECOND])
        result = invoke_hook(self.work, self.index_url, spec, self.common_env | {"FAKE_UV_FAIL": SECOND_PY})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no version satisfies", result.stderr)
        for name, content in preserved.items():
            self.assertEqual((root / name).read_text(), content)

    def test_aggregate_hashes_cover_the_ordered_environment_set(self) -> None:
        one_stdout, root = run_hook(self.work, self.index_url, self.spec_with([CURRENT]), self.common_env)
        one_requirements = next(line for line in one_stdout.splitlines() if line.startswith("requirementsHash="))
        one_manifests = next(line for line in one_stdout.splitlines() if line.startswith("wheelManifestHash="))
        two_stdout, root = run_hook(self.work, self.index_url, self.spec_with([CURRENT, SECOND]), self.common_env)
        two_requirements = next(line for line in two_stdout.splitlines() if line.startswith("requirementsHash="))
        two_manifests = next(line for line in two_stdout.splitlines() if line.startswith("wheelManifestHash="))
        self.assertNotEqual(one_requirements, two_requirements)
        self.assertNotEqual(one_manifests, two_manifests)

    def test_index_failure_is_fatal(self) -> None:
        spec = self.spec_with([CURRENT, SECOND])
        result = invoke_hook(self.work, self.index_url, spec, self.common_env | {"FAKE_PIP_INDEX_FAIL": SECOND["pipPythonVersion"]})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("absentpkg", result.stderr)

    def test_removed_environment_artifacts_are_pruned(self) -> None:
        root = self.work / "flake-root"
        (root / "requirements-3.12.lock").write_text("stale")
        (root / "wheels-3.12.json").write_text("stale")
        (root / "python-readiness.json").write_text("{}")
        spec = self.spec_with([CURRENT])
        stdout, root = run_hook(self.work, self.index_url, spec, self.common_env)
        self.assertFalse((root / "requirements-3.12.lock").exists())
        self.assertFalse((root / "wheels-3.12.json").exists())
        self.assertFalse((root / "python-readiness.json").exists())

    def test_source_file_except_filter(self) -> None:
        spec = self.spec_with([CURRENT])
        spec["sources"] = [
            {"kind": "source-pyproject", "groups": ["studio"]},
            {"kind": "source-file", "path": "reqs/studio.txt", "except": ["fakepkg"]},
        ]
        spec["extraRequirements"] = []
        stdout, root = run_hook(self.work, self.index_url, spec, self.common_env)

        requirements_in = (root / "requirements.in").read_text()
        self.assertIn("fakenative==2.1.0", requirements_in)
        self.assertNotIn("fakepkg==1.0.0", requirements_in)

    def test_source_file_only_filter(self) -> None:
        spec = self.spec_with([CURRENT])
        spec["sources"] = [
            {"kind": "source-pyproject", "groups": ["studio"], "only": ["fakenative"]},
            {"kind": "source-file", "path": "reqs/studio.txt", "only": ["FAKEPKG"]},
        ]
        spec["extraRequirements"] = []
        stdout, root = run_hook(self.work, self.index_url, spec, self.common_env)

        requirements_in = (root / "requirements.in").read_text()
        self.assertIn("fakenative==2.1.0", requirements_in)
        self.assertEqual(requirements_in.count("fakepkg==1.0.0"), 1)
        self.assertNotIn("fakepkg>=1.0", requirements_in)

    def test_gitlab_checkout(self) -> None:
        spec = self.spec_with([CURRENT])
        stdout, root = run_hook(self.work, self.index_url, spec, self.common_env | {"SOURCE_TYPE": "gitlab"})
        self.assertIn("git clone", self.log.read_text())
        self.assertIn("https://gitlab.com/acme/widget.git", self.log.read_text())

    def test_source_file_only_filter_without_match(self) -> None:
        spec = self.spec_with([CURRENT])
        spec["sources"] = [{"kind": "source-file", "path": "reqs/studio.txt", "only": ["absent"]}]
        spec |= {"indexUrl": self.index_url, "fingerprint": "test-fingerprint"}
        result = subprocess.run(
            ["python3", str(SCRIPT)],
            cwd=self.work,
            env={
                "PATH": f"{self.work / 'bin'}:{os.environ['PATH']}",
                "WHEELHOUSE_SPEC": json.dumps(spec),
                "DEPS_CORE": str(DEPS_CORE),
                "FLAKE_ROOT": str(self.work / "flake-root"),
                "NEW_REV": "abc123",
                "GH_OWNER": "acme",
                "GH_REPO": "widget",
                "HOME": str(self.work),
            }
            | self.common_env,
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("matched nothing for: absent", result.stderr)

    def test_source_file_directive_is_rejected(self) -> None:
        (self.work / "source-fixture" / "reqs" / "studio.txt").write_text("-r other.txt\n")
        spec = self.spec_with([CURRENT]) | {"indexUrl": self.index_url, "fingerprint": "test-fingerprint"}
        result = subprocess.run(
            ["python3", str(SCRIPT)],
            cwd=self.work,
            env={
                "PATH": f"{self.work / 'bin'}:{os.environ['PATH']}",
                "WHEELHOUSE_SPEC": json.dumps(spec),
                "DEPS_CORE": str(DEPS_CORE),
                "FLAKE_ROOT": str(self.work / "flake-root"),
                "NEW_REV": "abc123",
                "GH_OWNER": "acme",
                "GH_REPO": "widget",
                "HOME": str(self.work),
            }
            | self.common_env,
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unsupported requirements-file directive", result.stderr)

    def test_repo_file_only_skips_checkout(self) -> None:
        (self.work / "flake-root" / "requirements.in").write_text(
            "# hand-maintained\nfakepkg>=1.0\n"
        )
        spec = {
            "sources": [{"kind": "repo-file", "path": "requirements.in"}],
            "extraRequirements": [],
            "environments": [CURRENT],
        }
        stdout, root = run_hook(self.work, self.index_url, spec, self.common_env)
        self.assertNotIn("git ", self.log.read_text())
        self.assertNotIn("@abc123", (root / "requirements.in").read_text())
        self.assertFalse((root / "python-readiness.json").exists())


if __name__ == "__main__":
    unittest.main()
