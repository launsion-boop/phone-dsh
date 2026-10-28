#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Static check of the eight phone-DSH modules in ``Package.swift``.

The checker reads ``Package.swift`` as text (it is a Swift manifest, not a
Python module), reconstructs the ``Module(...)`` entries, and asserts the
dependency map of PLAN 2.1 exactly: PhoneWire has no dependencies, every other
module has exactly the listed edges, and PhoneDSH is a superset that also
contains AgentCore.  ``PhoneDSHAgentCore`` is the extraction boundary: it
must stay Foundation-only, and no phone module may depend on
XiaozhiLinkProviders / XiaozhiLinkAgent / XiaozhiLinkExecBridge again.  That
also holds for the phone test targets, which build the exec-bridge seam from
in-test doubles instead of linking the real modules.  The checker also requires
a test target per module, forbids PhoneDSH / XiaozhiLinkToolbox edges, and
rejects ``@MainActor`` in the eight new module directories.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

import common

PHONE_MODULES = [
    "PhoneDSHWire",
    "PhoneDSHLog",
    "PhoneDSHLoopback",
    "PhoneDSHGateway",
    "PhoneDSHController",
    "PhoneDSHEngine",
    "PhoneDSHShell",
    "PhoneDSH",
]

SHORT_NAMES = {
    "PhoneDSHWire": "PhoneWire",
    "PhoneDSHLog": "PhoneLog",
    "PhoneDSHLoopback": "PhoneLoopback",
    "PhoneDSHGateway": "PhoneGateway",
    "PhoneDSHController": "PhoneController",
    "PhoneDSHEngine": "PhoneEngine",
    "PhoneDSHShell": "PDSHShell",
    "PhoneDSH": "PhoneDSH",
    "PhoneDSHAgentCore": "AgentCore",
    "XiaozhiLinkProviders": "Providers",
    "XiaozhiLinkExecBridge": "ExecBridge",
    "XiaozhiLinkAgent": "Agent",
    # The PLAN 2.1 table uses the short names for dependencies.
    "Wire": "PhoneWire",
    "Log": "PhoneLog",
    "Loopback": "PhoneLoopback",
    "Gateway": "PhoneGateway",
    "Controller": "PhoneController",
    "Engine": "PhoneEngine",
    "PDSHShell": "PDSHShell",
    "AgentCore": "AgentCore",
    "Providers": "Providers",
    "ExecBridge": "ExecBridge",
    "Agent": "Agent",
}

EXPECTED = {
    "PhoneDSHWire": set(),
    "PhoneDSHLog": {"PhoneWire"},
    "PhoneDSHLoopback": {"PhoneWire", "AgentCore"},
    "PhoneDSHGateway": {"AgentCore"},
    "PhoneDSHController": {"PhoneWire", "PhoneLog"},
    "PhoneDSHEngine": {"PhoneLoopback"},
    "PhoneDSHShell": {"AgentCore"},
    "PhoneDSH": {
        "PhoneWire",
        "PhoneLog",
        "PhoneLoopback",
        "PhoneGateway",
        "PhoneController",
        "PhoneEngine",
        "PDSHShell",
        "AgentCore",
    },
}
SUPERSET_MODULES = {"PhoneDSH"}

# The boundary introduced for the open-source extraction. Its contracts are
# re-exported by these modules, so a phone target that imports one of them again
# would silently reintroduce the dependency the boundary exists to remove.
CORE_MODULE = "PhoneDSHAgentCore"
REPLACED_BY_CORE = {
    "XiaozhiLinkProviders",
    "XiaozhiLinkAgent",
    "XiaozhiLinkExecBridge",
}

PACKAGE_REL = "Package.swift"


def canonical(dep):
    return SHORT_NAMES.get(dep, dep)


def find_calls(text, call_name):
    """Yield ``(call_start, inner_start, inner_end, inner)`` for ``Name(...)``."""
    pattern = re.compile(r"\b" + re.escape(call_name) + r"\s*\(")
    for match in pattern.finditer(text):
        start = match.end()
        depth = 1
        index = start
        quote = None
        escaped = False
        while index < len(text):
            char = text[index]
            if quote is not None:
                if escaped:
                    escaped = False
                elif char == "\\":
                    escaped = True
                elif char == quote:
                    quote = None
            else:
                if char in "\"'":
                    quote = char
                elif char == "(":
                    depth += 1
                elif char == ")":
                    depth -= 1
                    if depth == 0:
                        yield match.start(), start, index, text[start:index]
                        break
            index += 1


def find_array(inner, arg_name):
    """Return ``(array_text, offset_in_inner)`` for ``arg_name: [...]``."""
    match = re.search(r"(?<![\w])" + re.escape(arg_name) + r"\s*:\s*\[", inner)
    if not match:
        return None, None
    start = inner.index("[", match.start())
    depth = 0
    index = start
    quote = None
    escaped = False
    while index < len(inner):
        char = inner[index]
        if quote is not None:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == quote:
                quote = None
        else:
            if char in "\"'":
                quote = char
            elif char == "[":
                depth += 1
            elif char == "]":
                depth -= 1
                if depth == 0:
                    return inner[start : index + 1], start
        index += 1
    return None, None


def parse_array(array, base_offset):
    """Return ``[(dependency, line_offset)]`` for a Swift array literal."""
    products = [
        (match.group(1), base_offset + match.start(1))
        for match in re.finditer(
            r"\.product\s*\(\s*name\s*:\s*\"([^\"]+)\"\s*,\s*package\s*:\s*\"[^\"]+\"\s*\)",
            array,
        )
    ]
    stripped = re.sub(r"\.product\s*\([^)]*\)", lambda m: " " * len(m.group(0)), array)
    strings = [
        (match.group(1), base_offset + match.start(1))
        for match in re.finditer(r"\"([^\"]+)\"", stripped)
    ]
    return products + strings


def line_at(text, offset):
    return text.count("\n", 0, offset) + 1


def parse_manifest(text):
    entries = {}
    for call_start, inner_start, _inner_end, inner in find_calls(text, "Module"):
        name_match = re.search(r"\bname\s*:\s*\"([^\"]+)\"", inner)
        if not name_match:
            continue
        name = name_match.group(1)
        dependencies = []
        deps_line = line_at(text, call_start)
        array, offset = find_array(inner, "dependencies")
        if array is not None:
            for dep, dep_offset in parse_array(array, inner_start + offset):
                dependencies.append((dep, line_at(text, dep_offset)))
            deps_line = line_at(text, inner_start + offset)
        test_dependencies = []
        test_array, test_offset = find_array(inner, "testDependencies")
        if test_array is not None:
            for dep, dep_offset in parse_array(test_array, inner_start + test_offset):
                test_dependencies.append((dep, line_at(text, dep_offset)))
        entries[name] = {
            "line": line_at(text, call_start),
            "deps_line": deps_line,
            "dependencies": dependencies,
            "test_dependencies": test_dependencies,
            "has_tests": not re.search(r"\bhasTests\s*:\s*false\b", inner),
        }
    return entries


def test_target_info(text):
    literal = set(
        match.group(1)
        for match in re.finditer(
            r"\.testTarget\s*\(\s*name\s*:\s*\"([^\"]+)\"", text
        )
    )
    template = bool(
        re.search(
            r"\.testTarget\s*\(\s*name\s*:\s*\"\\\(m\.name\)Tests\"", text
        )
    )
    return literal, template


def check_dependencies(entries, findings):
    for module in PHONE_MODULES:
        entry = entries.get(module)
        if entry is None:
            findings.append((PACKAGE_REL, 1, "module-missing", f"{module} Module entry not found"))
            continue
        actual = {canonical(dep) for dep, _line in entry["dependencies"]}
        expected = EXPECTED[module]
        if module in SUPERSET_MODULES:
            missing = sorted(expected - actual)
            if missing:
                findings.append(
                    (
                        PACKAGE_REL,
                        entry["deps_line"],
                        "module-dependency",
                        "missing required dependencies: " + ", ".join(missing),
                    )
                )
        elif actual != expected:
            missing = sorted(expected - actual)
            extra = sorted(actual - expected)
            detail = []
            if missing:
                detail.append("missing " + ", ".join(missing))
            if extra:
                detail.append("unexpected " + ", ".join(extra))
            findings.append(
                (PACKAGE_REL, entry["deps_line"], "module-dependency", "; ".join(detail))
            )
        for dep, dep_line in entry["dependencies"] + entry["test_dependencies"]:
            if dep.startswith("XiaozhiLinkToolbox") or dep == "PhoneDSH":
                findings.append(
                    (
                        PACKAGE_REL,
                        dep_line,
                        "forbidden-dependency",
                        f"{module} may not depend on {dep}",
                    )
                )


def check_agent_core(entries, text, findings):
    """The extraction boundary: Foundation-only, tested, and re-exported."""
    entry = entries.get(CORE_MODULE)
    if entry is None:
        findings.append((PACKAGE_REL, 1, "module-missing", f"{CORE_MODULE} Module entry not found"))
        return
    if entry["dependencies"]:
        names = ", ".join(dep for dep, _line in entry["dependencies"])
        findings.append(
            (
                PACKAGE_REL,
                entry["deps_line"],
                "core-dependency",
                f"{CORE_MODULE} must depend on Foundation only; got {names}",
            )
        )
    for module in PHONE_MODULES:
        phone = entries.get(module)
        if phone is None:
            continue
        for dep, dep_line in phone["dependencies"] + phone["test_dependencies"]:
            if dep in REPLACED_BY_CORE:
                findings.append(
                    (
                        PACKAGE_REL,
                        dep_line,
                        "agentcore-boundary",
                        f"{module} and its tests must depend on {CORE_MODULE}, not {dep}",
                    )
                )
    literal, template = test_target_info(text)
    if f"{CORE_MODULE}Tests" not in literal and not (template and entry["has_tests"]):
        findings.append(
            (
                PACKAGE_REL,
                entry["line"],
                "test-target",
                f"no test target for {CORE_MODULE}",
            )
        )


def check_test_targets(text, entries, findings):
    literal, template = test_target_info(text)
    for module in PHONE_MODULES:
        entry = entries.get(module)
        if entry is None:
            continue
        if f"{module}Tests" in literal:
            continue
        if template and entry["has_tests"]:
            continue
        findings.append(
            (
                PACKAGE_REL,
                entry["line"],
                "test-target",
                f"no test target for {module}",
            )
        )


def check_main_actor(root, findings):
    for module in PHONE_MODULES:
        rel_root = f"Sources/{module}"
        for rel in common.scan_files(root, [rel_root]):
            lines = common.read_lines(root, rel)
            if lines is None:
                continue
            for number, line in enumerate(lines, start=1):
                if "@MainActor" in line:
                    findings.append((rel, number, "main-actor", line.strip()))


def run(root):
    wire_dir = Path(root) / "Sources/PhoneDSHWire"
    if not wire_dir.is_dir():
        print("SKIP: Sources/PhoneDSHWire is absent")
        return 0
    package = Path(root) / PACKAGE_REL
    if not package.is_file():
        common.emit(PACKAGE_REL, 1, "package-swift", "Package.swift is missing")
        return 1
    text = package.read_text(encoding="utf-8")
    entries = parse_manifest(text)
    findings = []
    check_dependencies(entries, findings)
    check_agent_core(entries, text, findings)
    check_test_targets(text, entries, findings)
    check_main_actor(root, findings)
    for rel, line, rule, excerpt in sorted(findings):
        common.emit(rel, line, rule, excerpt)
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(
        common.main_guard(
            __file__,
            "dependency map and test targets of the eight phone-DSH modules",
            run,
            common.MODULE_ROOTS,
        )
    )
