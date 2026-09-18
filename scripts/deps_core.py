import re
import tomllib
from collections.abc import Iterable, Mapping
from typing import Any

from packaging.version import InvalidVersion, Version

TOKEN_PATTERN = re.compile(
    r"""\s*(?:
        (?P<lparen>\()
      | (?P<rparen>\))
      | (?P<operator>===|==|!=|<=|>=|<|>)
      | (?P<string>'[^']*'|"[^"]*")
      | (?P<word>[A-Za-z_][A-Za-z0-9_]*)
    )""",
    re.VERBOSE,
)

VERSION_VARIABLES = {"python_version", "python_full_version", "implementation_version"}

MIRRORED_OPERATORS = {"<": ">", "<=": ">=", ">": "<", ">=": "<="}

Tree = bool | tuple


def clean_requirement_lines(lines: Iterable[str]) -> list[str]:
    cleaned = []
    for line in lines:
        value = line.split(" #", 1)[0].strip()
        if value and not value.startswith(("#", "-")):
            cleaned.append(value)
    return cleaned


def requirements_file_requirements(text: str) -> list[str]:
    return clean_requirement_lines(text.splitlines())


def pyproject_requirements(document: str, optional_groups: Iterable[str]) -> list[str]:
    project = tomllib.loads(document).get("project", {})
    requirements = list(project.get("dependencies") or [])
    optional_dependencies = project.get("optional-dependencies") or {}
    for group in optional_groups:
        requirements.extend(optional_dependencies.get(group) or [])
    return requirements


def metadata_requires_dist(metadata: Mapping[str, Any]) -> list[str]:
    return list(metadata.get("info", {}).get("requires_dist") or [])


def compare_values(variable: str, observed: str, operator: str, literal: str) -> bool:
    if variable not in VERSION_VARIABLES:
        if operator in {"==", "==="}:
            return observed == literal
        if operator == "!=":
            return observed != literal
        raise ValueError(
            f"unsupported ordered comparison on non-version marker variable: {variable}"
        )
    if operator == "===":
        return observed == literal
    try:
        left = Version(observed)
        right = Version(literal)
    except InvalidVersion:
        if operator == "==":
            return observed == literal
        if operator == "!=":
            return observed != literal
        raise ValueError(
            f"uncomparable values for marker variable {variable}: {observed} {operator} {literal}"
        )
    difference = (left > right) - (left < right)
    return {
        "<": difference < 0,
        "<=": difference <= 0,
        ">": difference > 0,
        ">=": difference >= 0,
    }[operator]


def tokenize(expression: str) -> list[tuple[str, str]]:
    tokens = []
    position = 0
    while position < len(expression):
        match = TOKEN_PATTERN.match(expression, position)
        if match is None:
            raise ValueError(f"unsupported environment marker: {expression}")
        position = match.end()
        tokens.append((match.lastgroup, match.group(match.lastgroup)))
    return tokens


def fold(kind: str, children: list) -> Tree:
    if kind == "any" and True in children:
        return True
    if kind == "all" and False in children:
        return False
    remaining = [child for child in children if isinstance(child, tuple)]
    if not remaining:
        return kind == "all"
    if len(remaining) == 1:
        return remaining[0]
    return (kind, tuple(remaining))


def applicability(marker: str | None, bound: Mapping[str, str]) -> Tree:
    if marker is None:
        return True
    tokens = tokenize(marker)
    index = 0

    def parse_operand() -> tuple[str, str]:
        nonlocal index
        if index >= len(tokens):
            raise ValueError(f"unsupported environment marker: {marker}")
        kind, value = tokens[index]
        if kind not in {"word", "string"}:
            raise ValueError(f"unsupported environment marker: {marker}")
        index += 1
        return ("variable" if kind == "word" else "literal", value.strip("'\""))

    def parse_comparison() -> Tree:
        nonlocal index
        left_kind, left = parse_operand()
        if index >= len(tokens):
            raise ValueError(f"unsupported environment marker: {marker}")
        operator_kind, operator = tokens[index]
        if operator_kind != "operator":
            raise ValueError(f"unsupported environment marker: {marker}")
        index += 1
        right_kind, right = parse_operand()
        if left_kind == "literal" and right_kind == "literal":
            raise ValueError(f"unsupported environment marker: {marker}")
        if left_kind == "literal":
            operator = MIRRORED_OPERATORS.get(operator, operator)
            left, right = right, left
        if left in bound:
            return compare_values(left, bound[left], operator, right)
        return ("cmp", left, operator, right)

    def parse_atom() -> Tree:
        nonlocal index
        if tokens[index] == ("lparen", "("):
            index += 1
            node = parse_or()
            if index >= len(tokens) or tokens[index] != ("rparen", ")"):
                raise ValueError(f"unsupported environment marker: {marker}")
            index += 1
            return node
        return parse_comparison()

    def parse_and() -> Tree:
        nonlocal index
        children = [parse_atom()]
        while index < len(tokens) and tokens[index] == ("word", "and"):
            index += 1
            children.append(parse_atom())
        return fold("all", children)

    def parse_or() -> Tree:
        nonlocal index
        children = [parse_and()]
        while index < len(tokens) and tokens[index] == ("word", "or"):
            index += 1
            children.append(parse_and())
        return fold("any", children)

    result = parse_or()
    if index != len(tokens):
        raise ValueError(f"unsupported environment marker: {marker}")
    return result


def to_jsonable(tree: Tree) -> bool | dict:
    if isinstance(tree, bool):
        return tree
    kind = tree[0]
    if kind == "cmp":
        _, variable, operator, literal = tree
        return {
            "kind": "cmp",
            "variable": variable,
            "operator": operator,
            "literal": literal,
        }
    return {"kind": kind, "conditions": [to_jsonable(child) for child in tree[1]]}
