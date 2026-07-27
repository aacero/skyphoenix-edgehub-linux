#!/usr/bin/env python3
"""Compare strict-runner rows with the signed audit contract without running suites."""

from __future__ import annotations

import argparse
import ast
import pathlib
import re
import shlex
import sys
from typing import Any


CONTRACT_NAMES = {
    "EXPECTED_PREFLIGHT_CHECKS",
    "EXPECTED_RELEASE_SUITES",
}


def contract_lists(path: pathlib.Path) -> dict[str, list[Any]]:
    module = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    values: dict[str, list[Any]] = {}
    for statement in module.body:
        if (
            isinstance(statement, ast.Assign)
            and len(statement.targets) == 1
            and isinstance(statement.targets[0], ast.Name)
            and statement.targets[0].id in CONTRACT_NAMES
        ):
            value = ast.literal_eval(statement.value)
            if not isinstance(value, list):
                raise ValueError(
                    f"{statement.targets[0].id} must be a literal list"
                )
            values[statement.targets[0].id] = value
    missing = CONTRACT_NAMES - values.keys()
    if missing:
        raise ValueError(f"audit contract lacks {sorted(missing)}")
    return values


def runner_preflight_checks(source: str) -> list[str | None]:
    events: list[tuple[int, list[str | None]]] = []

    all_ok_calls = list(re.finditer(r"\bpreflight_ok\s+", source))
    quoted_ok_calls = list(
        re.finditer(r'preflight_ok\s+"([^"\n]*)"', source)
    )
    if len(all_ok_calls) != len(quoted_ok_calls):
        raise ValueError("every preflight_ok call must use one quoted argument")
    dynamic_ok_labels: list[str] = []
    for match in quoted_ok_calls:
        label: str | None = match.group(1)
        if label == "live Wayland socket ($wayland_socket)":
            label = None
        elif "$" in label:
            dynamic_ok_labels.append(label)
            continue
        events.append((match.start(), [label]))
    if dynamic_ok_labels != ["$1", "$1"]:
        raise ValueError(
            "only the two command-helper preflight labels may be dynamic"
        )

    command_loop = re.search(
        r'for command_name in \\\n'
        r"(?P<body>.*?)\s*; do\n"
        r'\s*require_command "\$command_name"',
        source,
        flags=re.DOTALL,
    )
    if command_loop is None:
        raise ValueError("strict runner command preflight loop was not found")
    command_text = command_loop.group("body").replace("\\\n", " ")
    events.append((command_loop.start(), shlex.split(command_text)))

    for match in re.finditer(
        r'^\s*require_command\s+("[^"\n]+"|[^\s]+)',
        source,
        flags=re.MULTILINE,
    ):
        argument = match.group(1)
        if argument == '"$command_name"':
            continue
        values = shlex.split(argument)
        if len(values) != 1 or "$" in values[0]:
            raise ValueError("direct require_command argument is not literal")
        events.append((match.start(), values))

    for match in re.finditer(
        r"require_command_or_executable\s+([^\s\"']+)", source
    ):
        name = match.group(1)
        if name == "()" or "$" in name:
            continue
        events.append((match.start(), [name]))

    result: list[str | None] = []
    for _, labels in sorted(events):
        result.extend(labels)
    return result


def runner_release_suites(source: str) -> list[str]:
    tool_loop = re.search(
        r"for tool in (?P<tools>[^;\n]+); do"
        r"(?P<body>.*?)"
        r"^done$",
        source,
        flags=re.DOTALL | re.MULTILINE,
    )
    if tool_loop is None:
        raise ValueError("strict runner Rust-tool suite loop was not found")
    tools = shlex.split(tool_loop.group("tools"))
    loop_names = re.findall(
        r'^\s*run_release_suite\s+"([^"]+)"',
        tool_loop.group("body"),
        flags=re.MULTILINE,
    )
    if not loop_names or any(not name.startswith("$tool ") for name in loop_names):
        raise ValueError("strict runner Rust-tool suite loop is not understood")

    all_calls = list(
        re.finditer(r"^\s*run_release_suite\s+", source, flags=re.MULTILINE)
    )
    quoted_calls = list(
        re.finditer(
            r'^\s*run_release_suite\s+"([^"]+)"',
            source,
            flags=re.MULTILINE,
        )
    )
    if len(all_calls) != len(quoted_calls):
        raise ValueError("every run_release_suite call must use a quoted name")

    events: list[tuple[int, list[str]]] = []
    for match in quoted_calls:
        if tool_loop.start() <= match.start() < tool_loop.end():
            continue
        events.append((match.start(), [match.group(1)]))

    expanded = [
        tool + name.removeprefix("$tool")
        for tool in tools
        for name in loop_names
    ]
    events.append((tool_loop.start(), expanded))

    result: list[str] = []
    for _, names in sorted(events):
        result.extend(names)
    return result


def show_mismatch(
    label: str, actual: list[Any], expected: list[Any]
) -> None:
    print(f"ERROR: {label} differs from the signed audit contract", file=sys.stderr)
    limit = max(len(actual), len(expected))
    for index in range(limit):
        actual_item = actual[index] if index < len(actual) else "<missing>"
        expected_item = expected[index] if index < len(expected) else "<missing>"
        if actual_item != expected_item:
            print(
                f"  row {index + 1}: runner={actual_item!r}, "
                f"contract={expected_item!r}",
                file=sys.stderr,
            )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--repo",
        type=pathlib.Path,
        default=pathlib.Path(__file__).resolve().parent.parent,
    )
    arguments = parser.parse_args()
    repository = arguments.repo.resolve()
    runner_path = repository / "scripts/run_release_tests.sh"
    contract_path = repository / "scripts/lib/audit_artifact_contract.py"

    try:
        source = runner_path.read_text(encoding="utf-8")
        expected = contract_lists(contract_path)
        preflight = runner_preflight_checks(source)
        suites = runner_release_suites(source)
    except (OSError, UnicodeError, SyntaxError, ValueError) as error:
        print(f"ERROR: could not derive release manifests: {error}", file=sys.stderr)
        return 1

    passed = True
    expected_preflight = expected["EXPECTED_PREFLIGHT_CHECKS"]
    expected_suites = expected["EXPECTED_RELEASE_SUITES"]
    if preflight != expected_preflight:
        show_mismatch("preflight manifest", preflight, expected_preflight)
        passed = False
    if suites != expected_suites:
        show_mismatch("suite manifest", suites, expected_suites)
        passed = False
    if not passed:
        return 1

    print(
        "PASS: strict runner and signed audit contract contain "
        f"{len(preflight)} preflight rows and {len(suites)} suite rows"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
