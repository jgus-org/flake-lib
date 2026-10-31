import json
import os
import subprocess
import unittest


TAG = "cp312-cp312-manylinux_2_27_x86_64.manylinux_2_28_x86_64"


def wheel(tag, *, build="", name="example"):
    return {
        "filename": f"{name}-1.0{build}-{tag}.whl",
        "packagetype": "bdist_wheel",
        "url": f"https://example.test/{name}-{tag}{build}.whl",
    }


class ArtifactSelection(unittest.TestCase):
    def select(self, metadata, *, mode="artifact", tag=TAG, format="wheel"):
        return subprocess.run(
            [
                "jq",
                "-er",
                "--arg",
                "mode",
                mode,
                "--arg",
                "format",
                format,
                "--arg",
                "tag",
                tag,
                "-f",
                os.environ["PYPI_ARTIFACTS"],
            ],
            input=json.dumps(metadata),
            capture_output=True,
            text=True,
            check=False,
        )

    def test_exact_tags_ignore_other_interpreters_and_platforms(self):
        selected = wheel(TAG)
        result = self.select(
            {
                "urls": [
                    wheel("cp313-cp313-manylinux_2_28_x86_64"),
                    wheel("cp312-cp312-macosx_10_13_x86_64"),
                    wheel("cp312-cp312-manylinux_2_28_aarch64"),
                    wheel("py3-none-any"),
                    selected,
                ]
            }
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), selected["url"])

    def test_missing_exact_artifact_is_an_error(self):
        result = self.select({"urls": [wheel("py3-none-any")]})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no matching PyPI artifact", result.stderr)

    def test_ambiguous_builds_are_an_error(self):
        result = self.select({"urls": [wheel(TAG), wheel(TAG, build="-1")]})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("multiple matching PyPI artifacts", result.stderr)

    def test_default_still_prefers_universal_and_falls_back_to_first(self):
        native, universal = wheel(TAG), wheel("py3-none-any")
        for artifacts, expected in [
            ([native, universal], universal),
            ([native], native),
        ]:
            with self.subTest(artifacts=artifacts):
                result = self.select({"urls": artifacts}, tag="")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), expected["url"])

    def test_default_sdist_is_unchanged(self):
        sdist = {
            "packagetype": "sdist",
            "filename": "example.tar.gz",
            "url": "source",
        }
        result = self.select(
            {"urls": [wheel(TAG), sdist]}, tag="", format="sdist"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "source")

    def test_version_enumeration_uses_exact_selection(self):
        result = self.select(
            {
                "releases": {
                    "1.0": [wheel("py3-none-any")],
                    "2.0": [wheel(TAG)],
                    "3.0": [],
                }
            },
            mode="versions",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["2.0"])

    def test_version_enumeration_rejects_ambiguity(self):
        result = self.select(
            {
                "releases": {
                    "1.0": [wheel(TAG), wheel(TAG, build="-1")],
                }
            },
            mode="versions",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(
            "multiple matching PyPI artifacts for 1.0", result.stderr
        )

    def test_default_version_enumeration_remains_universal_only(self):
        result = self.select(
            {
                "releases": {
                    "1.0": [wheel(TAG)],
                    "2.0": [wheel("py3-none-any")],
                }
            },
            mode="versions",
            tag="",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["2.0"])


if __name__ == "__main__":
    unittest.main()
