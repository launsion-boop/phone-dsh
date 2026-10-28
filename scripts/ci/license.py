#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""License gate for the phone-DSH roots.

Every source file carries ``SPDX-License-Identifier: MIT`` within its first
three lines, and every plugin package manifest declares the MIT license.
Markdown and JSON files are not expected to carry a header (the plugin
manifests are checked through their ``license`` field instead).

The Rust accelerator workspace must also stay MIT: the ``[workspace.package]``
licence and every workspace member's ``Cargo.toml`` licence field are read from
the manifests (the lockfile only pins versions, so the declarations are the
authority). Finally, no ``PhoneDSH*`` / ``PhoneDSHShell`` target
may link the copyleft ``XiaozhiLinkToolbox*`` modules: ``Package.swift``
is parsed as text and every dependency edge of those targets is checked.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

import common
import modules

SOURCE_EXTENSIONS = {
    ".swift",
    ".ts",
    ".mts",
    ".mjs",
    ".js",
    ".py",
    ".rs",
    ".sh",
    ".yml",
    ".yaml",
}

SPDX_RE = re.compile(r"SPDX-License-Identifier:\s*MIT\s*(?:\*/)?\s*$")

PACKAGE_REL = "Package.swift"
CARGO_WORKSPACE_REL = "shell/Cargo.toml"
TOOLBOX_PREFIX = "XiaozhiLinkToolbox"
PHONE_MODULE_PREFIXES = ("PhoneDSH", "PhoneDSHShell")


def plugin_manifests(root):
    for rel in common.scan_files(root, ["plugins"]):
        if Path(rel).name != "package.json":
            continue
        parts = rel.split("/")
        if rel == "plugins/package.json" or (
            len(parts) >= 3 and parts[0] == "plugins"
        ):
            yield rel


def check_package_license(root, rel, findings):
    try:
        data = json.loads((Path(root) / rel).read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        findings.append((rel, 1, "package-license", f"cannot parse package.json: {exc}"))
        return
    license_id = data.get("license") if isinstance(data, dict) else None
    if license_id != "MIT":
        findings.append(
            (rel, 1, "package-license", f"license is {license_id!r}, expected 'MIT'")
        )


def section_lines(text, name):
    """Return ``(line_number, line)`` pairs inside the ``[name]`` TOML table."""
    current = None
    selected = []
    for number, line in enumerate(text.splitlines(), start=1):
        header = re.match(r"\s*\[([^\]]+)\]\s*(?:#.*)?$", line)
        if header:
            current = header.group(1).strip()
            continue
        if current == name:
            selected.append((number, line))
    return selected


def array_entries(lines, key):
    """Return ``(value, line_number)`` for the quoted entries of ``key = [...]``."""
    entries = []
    collecting = False
    for number, line in lines:
        code = line.split("#", 1)[0]
        if not collecting:
            match = re.search(r"(?<![\w.])" + re.escape(key) + r"\s*=\s*\[(.*)$", code)
            if not match:
                continue
            collecting = True
            content = match.group(1)
        else:
            content = code
        for string in re.finditer(r'"([^"]+)"', content):
            entries.append((string.group(1), number))
        if "]" in content:
            break
    return entries


def declared_license(lines):
    """Return ``(license, line_number)`` declared by a ``[package]`` table."""
    for number, line in lines:
        code = line.split("#", 1)[0].strip()
        if not code:
            continue
        dotted = re.match(r"^license\.workspace\s*=\s*true\b", code)
        if dotted:
            return "MIT", number
        table = re.match(r'^license\s*=\s*\{([^}]*)\}', code)
        if table and re.search(r"workspace\s*=\s*true", table.group(1)):
            return "MIT", number
        literal = re.match(r'^license\s*=\s*"([^"]+)"', code)
        if literal:
            return literal.group(1), number
    return None, 1


def check_cargo_licenses(root, findings):
    """Check the MIT licence fields of the pdsh-shell Cargo workspace."""
    path = Path(root) / CARGO_WORKSPACE_REL
    if not path.is_file():
        return
    text = path.read_text(encoding="utf-8")
    workspace = section_lines(text, "workspace")
    package_table = section_lines(text, "workspace.package")
    license_id, license_line = declared_license(package_table)
    if license_id != "MIT":
        findings.append(
            (
                CARGO_WORKSPACE_REL,
                license_line,
                "cargo-license",
                f"[workspace.package] license is {license_id!r}, expected 'MIT'",
            )
        )
    members = array_entries(workspace, "members")
    if not members:
        findings.append(
            (
                CARGO_WORKSPACE_REL,
                1,
                "cargo-workspace",
                "[workspace] has no members array",
            )
        )
    for member, member_line in members:
        if any(char in member for char in "*?["):
            continue
        rel = f"shell/{member.strip('/')}/Cargo.toml"
        member_path = Path(root) / rel
        if not member_path.is_file():
            findings.append(
                (
                    CARGO_WORKSPACE_REL,
                    member_line,
                    "cargo-workspace",
                    f"workspace member {member!r} has no Cargo.toml",
                )
            )
            continue
        member_license, number = declared_license(
            section_lines(member_path.read_text(encoding="utf-8"), "package")
        )
        if member_license != "MIT":
            findings.append(
                (
                    rel,
                    number,
                    "cargo-license",
                    f"[package] license is {member_license!r}, expected 'MIT'",
                )
            )


def is_phone_module(name):
    return any(name.startswith(prefix) for prefix in PHONE_MODULE_PREFIXES)


def report_toolbox_links(rel, target, dependencies, findings):
    for dependency, line in dependencies:
        if dependency.startswith(TOOLBOX_PREFIX):
            findings.append(
                (
                    rel,
                    line,
                    "forbidden-toolbox-link",
                    f"{target} may not link the copyleft {dependency} module",
                )
            )


def target_dependencies(text, inner, inner_start):
    dependencies = []
    for key in ("dependencies", "testDependencies"):
        array, offset = modules.find_array(inner, key)
        if array is not None:
            for dependency, at in modules.parse_array(array, inner_start + offset):
                dependencies.append((dependency, modules.line_at(text, at)))
    return dependencies


def check_manifest_no_toolbox(root, findings):
    """Assert no new phone module links the copyleft toolbox in Package.swift."""
    path = Path(root) / PACKAGE_REL
    if not path.is_file():
        return
    text = path.read_text(encoding="utf-8")
    for _start, inner_start, _end, inner in modules.find_calls(text, "Module"):
        name = re.search(r"\bname\s*:\s*\"([^\"]+)\"", inner)
        if not name or not is_phone_module(name.group(1)):
            continue
        report_toolbox_links(
            PACKAGE_REL,
            name.group(1),
            target_dependencies(text, inner, inner_start),
            findings,
        )
    for call in ("target", "testTarget", "executableTarget"):
        for _start, inner_start, _end, inner in modules.find_calls(text, call):
            name = re.search(r"\bname\s*:\s*\"([^\"]+)\"", inner)
            if not name or not is_phone_module(name.group(1)):
                continue
            report_toolbox_links(
                PACKAGE_REL,
                name.group(1),
                target_dependencies(text, inner, inner_start),
                findings,
            )


def run(root):
    findings = []
    for rel in common.scan_files(root):
        if Path(rel).suffix.lower() not in SOURCE_EXTENSIONS:
            continue
        lines = common.read_lines(root, rel)
        if lines is None:
            continue
        header = lines[:3]
        if not any(SPDX_RE.search(line) for line in header):
            findings.append(
                (
                    rel,
                    1,
                    "license",
                    "missing SPDX-License-Identifier: MIT in the first 3 lines",
                )
            )
    for rel in plugin_manifests(root):
        check_package_license(root, rel, findings)
    check_cargo_licenses(root, findings)
    check_manifest_no_toolbox(root, findings)
    for rel, line, rule, excerpt in sorted(findings):
        common.emit(rel, line, rule, excerpt)
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(
        common.main_guard(
            __file__,
            "SPDX MIT headers, plugin/Cargo licences and toolbox link boundaries",
            run,
        )
    )
