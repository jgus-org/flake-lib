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

    def capture_download_kwargs(self, environment: dict[str, str]) -> dict:
        fake_hub = self.root / "fake_hub_capture"
        if not fake_hub.exists():
            fake_hub.mkdir()
        capture_file = self.root / "captured.json"
        (fake_hub / "huggingface_hub.py").write_text(
            "import json, os\n"
            "def snapshot_download(**kwargs):\n"
            "    with open(os.environ['CAPTURE_FILE'], 'w') as stream:\n"
            "        json.dump(kwargs, stream, default=str)\n"
        )
        self.run_manager("download", environment={**environment, "CAPTURE_FILE": str(capture_file)})
        return __import__("json").loads(capture_file.read_text())

    def test_download_anonymous_without_token(self) -> None:
        self.run_manager("verify")
        kwargs = self.capture_download_kwargs({"PYTHONPATH": str(self.root / "fake_hub_capture")})
        self.assertIs(kwargs["token"], False)

    def test_download_uses_hf_token_environment(self) -> None:
        self.run_manager("verify")
        kwargs = self.capture_download_kwargs(
            {"PYTHONPATH": str(self.root / "fake_hub_capture"), "HF_TOKEN": "test-token"}
        )
        self.assertEqual(kwargs["token"], "test-token")

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
