import importlib.util
import os
import unittest
from pathlib import Path

MODULE_SPEC = importlib.util.spec_from_file_location(
    "deps_core", Path(os.environ["DEPS_CORE"])
)
assert MODULE_SPEC is not None
assert MODULE_SPEC.loader is not None
DEPS = importlib.util.module_from_spec(MODULE_SPEC)
MODULE_SPEC.loader.exec_module(DEPS)

LINUX_BOUND = {
    "implementation_name": "cpython",
    "implementation_version": "3.13.5",
    "os_name": "posix",
    "platform_machine": "x86_64",
    "platform_release": "",
    "platform_system": "Linux",
    "platform_version": "",
    "platform_python_implementation": "CPython",
    "python_full_version": "3.13.5",
    "python_version": "3.13",
    "sys_platform": "linux",
    "sys_version": "",
    "extra": "",
}


class ReaderTests(unittest.TestCase):
    def test_requirements_file_strips_comments_and_options(self) -> None:
        text = "\n".join(
            [
                "requests>=2.0",
                "# full-line comment",
                "rich # trailing comment",
                "",
                "-r other.txt",
                "  typer==0.27.1  ",
            ]
        )
        self.assertEqual(
            DEPS.requirements_file_requirements(text),
            ["requests>=2.0", "rich", "typer==0.27.1"],
        )

    def test_pyproject_reads_dependencies_and_selected_groups(self) -> None:
        document = """
[project]
dependencies = ["typer>=0.12"]

[project.optional-dependencies]
studio = ["fastapi==0.141.1"]
other = ["ignored"]
"""
        self.assertEqual(
            DEPS.pyproject_requirements(document, ["studio"]),
            ["typer>=0.12", "fastapi==0.141.1"],
        )

    def test_metadata_reads_requires_dist(self) -> None:
        metadata = {"info": {"requires_dist": ["a==1", "b; python_version >= '3.10'"]}}
        self.assertEqual(DEPS.metadata_requires_dist(metadata), ["a==1", "b; python_version >= '3.10'"])

    def test_metadata_without_info_yields_empty(self) -> None:
        self.assertEqual(DEPS.metadata_requires_dist({}), [])


class ApplicabilityTests(unittest.TestCase):
    def test_no_marker_is_applicable(self) -> None:
        self.assertIs(DEPS.applicability(None, LINUX_BOUND), True)

    def test_fully_bound_marker_resolves_to_bool(self) -> None:
        self.assertIs(
            DEPS.applicability('python_version >= "3.10"', LINUX_BOUND), True
        )
        self.assertIs(
            DEPS.applicability('python_version < "3.10"', LINUX_BOUND), False
        )

    def test_unbound_variable_stays_symbolic(self) -> None:
        self.assertEqual(
            DEPS.applicability('python_version >= "3.10"', {}),
            ("cmp", "python_version", ">=", "3.10"),
        )

    def test_platform_clauses_fold_under_linux_binding(self) -> None:
        self.assertIs(
            DEPS.applicability(
                'sys_platform != "win32" or platform_machine != "ARM64" or python_version < "3.11"',
                {"sys_platform": "linux"},
            ),
            True,
        )
        self.assertIs(
            DEPS.applicability(
                '(sys_platform == "win32") and platform_machine == "ARM64"',
                {"sys_platform": "linux"},
            ),
            False,
        )

    def test_symbolic_trees_preserve_structure_and_fold(self) -> None:
        self.assertEqual(
            DEPS.applicability(
                'python_version >= "3.9" and python_version < "3.12"', {}
            ),
            (
                "all",
                (
                    ("cmp", "python_version", ">=", "3.9"),
                    ("cmp", "python_version", "<", "3.12"),
                ),
            ),
        )
        self.assertEqual(
            DEPS.applicability('python_version < "3.11" or python_version >= "3.12"', {}),
            (
                "any",
                (
                    ("cmp", "python_version", "<", "3.11"),
                    ("cmp", "python_version", ">=", "3.12"),
                ),
            ),
        )
        self.assertEqual(
            DEPS.applicability('python_version < "3.11" or sys_platform == "win32"', {"sys_platform": "linux"}),
            ("cmp", "python_version", "<", "3.11"),
        )
        self.assertEqual(
            DEPS.applicability('python_version < "3.11" or python_version > "3.10"', {}),
            (
                "any",
                (
                    ("cmp", "python_version", "<", "3.11"),
                    ("cmp", "python_version", ">", "3.10"),
                ),
            ),
        )

    def test_literal_on_left_mirrors_operator(self) -> None:
        self.assertIs(
            DEPS.applicability('"3.11" <= python_version', LINUX_BOUND), True
        )
        self.assertEqual(
            DEPS.applicability('"3.11" <= python_version', {}),
            ("cmp", "python_version", ">=", "3.11"),
        )

    def test_version_comparison_uses_version_ordering(self) -> None:
        self.assertIs(
            DEPS.applicability('python_version >= "3.10"', {"python_version": "3.9"}), False
        )
        self.assertIs(
            DEPS.applicability('python_version > "3.9"', {"python_version": "3.9.1"}), True
        )

    def test_version_variable_equality_ignores_trailing_zeros(self) -> None:
        self.assertIs(
            DEPS.applicability('python_full_version == "3.13"', {"python_full_version": "3.13.0"}),
            True,
        )
        self.assertIs(
            DEPS.applicability('python_full_version != "3.13"', {"python_full_version": "3.13.0"}),
            False,
        )

    def test_arbitrary_equality_is_exact_string_match(self) -> None:
        self.assertIs(
            DEPS.applicability('python_full_version === "3.13"', {"python_full_version": "3.13.0"}),
            False,
        )
        self.assertIs(
            DEPS.applicability('python_full_version === "3.13.0"', {"python_full_version": "3.13.0"}),
            True,
        )

    def test_ordered_non_version_variable_is_unsupported(self) -> None:
        with self.assertRaises(ValueError):
            DEPS.applicability('sys_platform < "win32"', {"sys_platform": "linux"})

    def test_unparseable_version_literal_in_ordering_is_unsupported(self) -> None:
        with self.assertRaises(ValueError):
            DEPS.applicability('python_version < "3.x"', {"python_version": "3.13"})

    def test_equality_falls_back_to_string_match_on_invalid_versions(self) -> None:
        self.assertIs(
            DEPS.applicability('python_version == "3.x"', {"python_version": "3.x"}), True
        )

    def test_in_and_not_in_are_unsupported(self) -> None:
        with self.assertRaises(ValueError):
            DEPS.applicability("'linux' in sys_platform", {})
        with self.assertRaises(ValueError):
            DEPS.applicability('sys_platform not in "win32"', {})

    def test_literal_literal_is_unsupported(self) -> None:
        with self.assertRaises(ValueError):
            DEPS.applicability('"3.10" < "3.11"', {})

    def test_garbage_is_unsupported(self) -> None:
        with self.assertRaises(ValueError):
            DEPS.applicability("python_version ==", LINUX_BOUND)
        with self.assertRaises(ValueError):
            DEPS.applicability('python_version >= "3.10" extra', LINUX_BOUND)


class ToJsonableTests(unittest.TestCase):
    def test_bools_pass_through(self) -> None:
        self.assertIs(DEPS.to_jsonable(True), True)
        self.assertIs(DEPS.to_jsonable(False), False)

    def test_comparison_becomes_dict(self) -> None:
        self.assertEqual(
            DEPS.to_jsonable(("cmp", "python_version", "<", "3.11")),
            {
                "kind": "cmp",
                "variable": "python_version",
                "operator": "<",
                "literal": "3.11",
            },
        )

    def test_nested_groups_become_dicts(self) -> None:
        self.assertEqual(
            DEPS.to_jsonable(
                (
                    "all",
                    (
                        ("cmp", "python_version", ">=", "3.9"),
                        (
                            "any",
                            (
                                ("cmp", "sys_platform", "==", "linux"),
                                ("cmp", "sys_platform", "==", "darwin"),
                            ),
                        ),
                    ),
                )
            ),
            {
                "kind": "all",
                "conditions": [
                    {
                        "kind": "cmp",
                        "variable": "python_version",
                        "operator": ">=",
                        "literal": "3.9",
                    },
                    {
                        "kind": "any",
                        "conditions": [
                            {
                                "kind": "cmp",
                                "variable": "sys_platform",
                                "operator": "==",
                                "literal": "linux",
                            },
                            {
                                "kind": "cmp",
                                "variable": "sys_platform",
                                "operator": "==",
                                "literal": "darwin",
                            },
                        ],
                    },
                ],
            },
        )


if __name__ == "__main__":
    unittest.main()
