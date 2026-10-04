import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


MODEL_MANAGER = os.environ["MODEL_MANAGER"]


class HuggingFaceModelManagerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        self.model_directory = self.root / "model"
        self.sha256_file = b"sha256 fixture\n"
        self.git_blob_file = b"git blob fixture\n"
        self.model_directory.mkdir()
        (self.model_directory / "sha256.txt").write_bytes(self.sha256_file)
        (self.model_directory / "git-blob.txt").write_bytes(self.git_blob_file)

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def run_manager(self, action: str, succeeds: bool = True, environment: dict[str, str] | None = None) -> None:
        process_environment = os.environ.copy()
        for name in ("HF_XET_CACHE", "HF_HOME", "XDG_CACHE_HOME", "HF_TOKEN", "HF_TOKEN_PATH"):
            process_environment.pop(name, None)
        if environment is not None:
            process_environment.update(environment)
        completed = subprocess.run(
            [MODEL_MANAGER, action, str(self.model_directory)],
            capture_output=True,
            text=True,
            env=process_environment,
        )
        if succeeds:
            self.assertEqual(completed.returncode, 0, completed.stderr)
        else:
            self.assertNotEqual(completed.returncode, 0)

    def test_verify_check_corruption_and_stamp_invalidation(self) -> None:
        self.run_manager("verify")
        self.run_manager("check")
        (self.model_directory / "sha256.txt").write_bytes(b"sha256 corrupt\n")
        self.run_manager("verify", succeeds=False)
        self.run_manager("check", succeeds=False)
        (self.model_directory / "sha256.txt").write_bytes(self.sha256_file)
        self.run_manager("verify")
        (self.model_directory / ".huggingface-model-manager-verified.json").write_text("{}")
        self.run_manager("check", succeeds=False)

    def capture_download(self, environment: dict[str, str]) -> dict:
        fake_hub = self.root / "fake_hub_capture" / "huggingface_hub"
        fake_hub.mkdir(parents=True, exist_ok=True)
        capture_file = self.root / "captured.json"
        (fake_hub / "__init__.py").write_text(
            "import json, os\n"
            "from pathlib import Path\n"
            "from pkgutil import extend_path\n"
            "__path__ = extend_path(__path__, __name__)\n"
            "from . import constants\n"
            "if os.environ.get('WRITE_XET_FIXTURE') == '1':\n"
            "    staging = Path(constants.HF_XET_CACHE) / 'fixture-endpoint' / 'staging'\n"
            "    staging.mkdir(parents=True)\n"
            "    (staging / 'writable').touch()\n"
            "def snapshot_download(**kwargs):\n"
            "    with open(os.environ['CAPTURE_FILE'], 'w') as stream:\n"
            "        json.dump({'kwargs': kwargs, 'xet_cache': constants.HF_XET_CACHE,\n"
            "                   'hf_home': constants.HF_HOME, 'token_path': constants.HF_TOKEN_PATH,\n"
            "                   'cache_environment': {name: os.environ.get(name) for name in\n"
            "                       ('HF_XET_CACHE', 'HF_HOME', 'XDG_CACHE_HOME')}}, stream, default=str)\n"
        )
        self.run_manager("download", environment={
            **environment, "CAPTURE_FILE": str(capture_file), "PYTHONPATH": str(fake_hub.parent),
        })
        return json.loads(capture_file.read_text())

    def test_download_anonymous_without_token(self) -> None:
        self.run_manager("verify")
        capture = self.capture_download({})
        self.assertIs(capture["kwargs"]["token"], False)

    def test_download_uses_hf_token_environment(self) -> None:
        self.run_manager("verify")
        capture = self.capture_download({"HF_TOKEN": "test-token"})
        self.assertEqual(capture["kwargs"]["token"], "test-token")

    def test_download_uses_writable_destination_xet_cache_before_hub_import(self) -> None:
        capture = self.capture_download({"WRITE_XET_FIXTURE": "1"})
        expected_cache = self.model_directory / ".cache" / "huggingface" / "xet"
        self.assertEqual(capture["xet_cache"], str(expected_cache))
        self.assertTrue((expected_cache / "fixture-endpoint" / "staging" / "writable").is_file())
        self.assertEqual(capture["cache_environment"], {
            "HF_XET_CACHE": str(expected_cache), "HF_HOME": None, "XDG_CACHE_HOME": None,
        })
        self.assertEqual(capture["hf_home"], str(Path.home() / ".cache" / "huggingface"))
        self.assertEqual(capture["token_path"], str(Path.home() / ".cache" / "huggingface" / "token"))

    def test_download_preserves_explicit_cache_configuration(self) -> None:
        for name in ("HF_XET_CACHE", "HF_HOME", "XDG_CACHE_HOME"):
            for value in (str(self.root / "shared-cache"), ""):
                with self.subTest(name=name, value=value):
                    capture = self.capture_download({name: value})
                    self.assertEqual(capture["cache_environment"], {
                        variable: value if variable == name else None
                        for variable in ("HF_XET_CACHE", "HF_HOME", "XDG_CACHE_HOME")
                    })

    def test_failed_download_invalidates_stamp(self) -> None:
        self.run_manager("verify")
        fake_hub = self.root / "fake_hub"
        fake_hub.mkdir()
        (fake_hub / "huggingface_hub.py").write_text(
            "def snapshot_download(**kwargs):\n    raise RuntimeError('download failed')\n"
        )
        self.run_manager("download", succeeds=False, environment={"PYTHONPATH": str(fake_hub)})
        self.run_manager("check", succeeds=False)


if __name__ == "__main__":
    unittest.main()
