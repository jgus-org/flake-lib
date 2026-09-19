import functools
import importlib.util
import hashlib
import json
import os
import shutil
import stat
import subprocess
import tempfile
import threading
import unittest
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


def run_hook(work: Path, index_url: str, spec: dict, extra_env: dict[str, str]) -> tuple[str, Path]:
    result = subprocess.run(
        ["python3", str(SCRIPT)],
        cwd=work,
        env={
            "PATH": f"{work / 'bin'}:{os.environ['PATH']}",
            "WHEELHOUSE_SPEC": json.dumps(spec),
            "DEPS_CORE": str(DEPS_CORE),
            "INDEX_URL": index_url,
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
    assert result.returncode == 0, result.stderr
    return result.stdout, work / "flake-root"


class IndexHandler(SimpleHTTPRequestHandler):
    def do_GET(self) -> None:
        parts = self.path.strip("/").split("/")
        if len(parts) == 2 and parts[0] == "simple":
            self.path = f"/simple/{parts[1]}/index.json"
        super().do_GET()

    def log_message(self, format: str, *args) -> None:
        pass


def serve_index(directory: Path) -> str:
    handler = functools.partial(IndexHandler, directory=str(directory))
    server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


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
            "fakepkg==1.0.0 # pinned\n-r other.txt\n"
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
            '  for ((i = 0; i < ${#ARGS[@]}; i++)); do\n'
            '    if [[ "${ARGS[i]}" == "--output-file" ]]; then OUT="${ARGS[i + 1]}"; fi\n'
            '  done\n'
            '  cp "$FIXTURE_LOCK" "$OUT"\n'
            'fi\n'
        ))
        write_executable(self.work / "bin" / "pip", (
            'echo "pip $*" >> ' + str(log) + '\n'
            'ARGS=("$@")\n'
            'for ((i = 0; i < ${#ARGS[@]}; i++)); do\n'
            '  if [[ "${ARGS[i]}" == "--dest" ]]; then DEST="${ARGS[i + 1]}"; fi\n'
            'done\n'
            'for wheel in "$FAKE_WHEELS_DIR"/*.whl; do cp "$wheel" "$DEST"; done\n'
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

    def test_source_and_repo_mix(self) -> None:
        spec = {
            "uvPythonVersion": "3.13",
            "uvPythonPlatform": "x86_64-manylinux_2_28",
            "pipPythonVersion": "313",
            "pipPlatforms": ["manylinux_2_28_x86_64", "manylinux_2_17_x86_64", "linux_x86_64"],
            "pipAbi": "cp313",
            "sources": [
                {"kind": "source-pyproject", "groups": ["studio"]},
                {"kind": "source-file", "path": "reqs/studio.txt"},
            ],
            "extraRequirements": ["ninja", "fakepkg>=1.0"],
        }
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

        manifest = json.loads((root / "wheels.json").read_text())
        self.assertEqual([entry["name"] for entry in manifest], ["fakenative", "fakepkg"])
        self.assertEqual(manifest[1]["version"], "1.0.0")
        self.assertEqual(manifest[0]["version"], "2.1.0")
        self.assertEqual(manifest[1]["url"], "https://files.example.test/fakepkg-1.0.0-py3-none-any.whl")
        self.assertEqual(manifest[1]["sha256"], sha256(FAKE_WHEELS["fakepkg-1.0.0-py3-none-any.whl"]))
        self.assertEqual(manifest[1]["size"], len(FAKE_WHEELS["fakepkg-1.0.0-py3-none-any.whl"]))

        self.assertIn("requirementsHash=" + hashlib.sha256(FIXTURE_LOCK.encode()).hexdigest(), stdout)
        wheels_hash = hashlib.sha256((root / "wheels.json").read_bytes()).hexdigest()
        self.assertIn("wheelManifestHash=" + wheels_hash, stdout)

    def test_repo_file_only_skips_checkout(self) -> None:
        (self.work / "flake-root" / "requirements.in").write_text(
            "# hand-maintained\nfakepkg>=1.0\n"
        )
        spec = {
            "uvPythonVersion": "3.13",
            "uvPythonPlatform": "x86_64-linux",
            "pipPythonVersion": "313",
            "pipPlatforms": ["linux_x86_64"],
            "pipAbi": "cp313",
            "sources": [{"kind": "repo-file", "path": "requirements.in"}],
        }
        stdout, root = run_hook(self.work, self.index_url, spec, self.common_env)
        self.assertNotIn("git ", self.log.read_text())
        self.assertNotIn("@abc123", (root / "requirements.in").read_text())


if __name__ == "__main__":
    unittest.main()
