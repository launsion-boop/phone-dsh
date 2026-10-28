#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Reject any local patch, vendoring or redistribution of DSH sources.

The zero-patch rule keeps DSH a pinned dependency: no ``patches/`` directory
targeting ``@deepseek-ai``, no tracked ``node_modules/@deepseek-ai`` files, no
patch-package / pnpm patched dependencies in the plugin manifests, and no copy
of the ``webworker-runtime`` entry points.  Mentions in imports, re-exports
and comments are allowed; only definitions are reported.
"""

from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

import common

WATCHED_NAMES = (
    "createWorkerHost",
    "deferLazyArchives",
    "loadVfsImage",
    "startWorkerHost",
    "MemoryVfs",
    "packVfsImage",
)

_NAME_ALT = "|".join(sorted(WATCHED_NAMES, key=len, reverse=True))
DEFINITION_RE = re.compile(
    # Only a line that starts with the declaration counts as a definition:
    # imports, re-exports, strings and comments that merely mention a name are
    # allowed by the contract.
    r"^\s*"
    r"(?:(?:export|declare)\s+)*"
    r"(?:default\s+)?"
    r"(?:async\s+)?"
    r"(?:function\s*\*?|class|const|let|var)\s+"
    rf"({_NAME_ALT})\b"
)
METHOD_RE = re.compile(
    r"^\s*"
    r"(?:(?:public|private|protected|static|async|get|set|readonly)\s+)*"
    rf"({_NAME_ALT})\s*\([^)]*\)\s*(?::[^{{]+)?\{{"
)

DEFINITION_EXTENSIONS = {
    ".ts",
    ".mts",
    ".cts",
    ".tsx",
    ".js",
    ".mjs",
    ".cjs",
    ".jsx",
    ".swift",
}

SKIP_WALK_DIRS = {"node_modules", ".git", ".build", "dist", "__pycache__"}


def is_test_path(rel):
    parts = rel.split("/")
    if any(part in {"tests", "test", "__tests__"} for part in parts[:-1]):
        return True
    name = parts[-1]
    return ".test." in name or ".spec." in name


def comment_line(line):
    stripped = line.lstrip()
    return stripped.startswith(("//", "*", "/*", "#"))


def line_number(lines, needle):
    for number, line in enumerate(lines, start=1):
        if needle in line:
            return number
    return 1


def check_pin(root, findings):
    rel = "plugins/dsh-pin.json"
    path = Path(root) / rel
    if not path.is_file():
        print("WARN: plugins/dsh-pin.json is absent (W0 wave: warning only)")
        return
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        line = getattr(exc, "lineno", 1) or 1
        findings.append((rel, line, "dsh-pin", f"cannot parse dsh-pin.json: {exc}"))
        return
    problems = []
    if not isinstance(data, dict):
        problems.append("root value is not an object")
    else:
        repo = data.get("repo")
        commit = data.get("commit")
        version = data.get("version")
        if not isinstance(repo, str) or not repo.strip():
            problems.append("repo must be a non-empty string")
        if not isinstance(commit, str) or not re.fullmatch(r"[0-9a-f]{40}", commit):
            problems.append("commit must be a 40-character lowercase hex string")
        if not isinstance(version, str) or not version.strip():
            problems.append("version must be a non-empty string")
    if problems:
        findings.append((rel, 1, "dsh-pin", "; ".join(problems)))


def check_patches_dirs(root, findings):
    root = Path(root)
    for current, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(name for name in dirnames if name not in SKIP_WALK_DIRS)
        if Path(current).name != "patches":
            continue
        for name in sorted(filenames):
            path = Path(current) / name
            rel = path.relative_to(root).as_posix()
            if "@deepseek-ai" in name or "deepseek" in name.lower():
                findings.append((rel, 1, "dsh-patch", f"patch file targets DSH: {name}"))
                continue
            try:
                data = path.read_bytes()
            except OSError:
                continue
            if b"\0" in data[:8192]:
                continue
            for number, line in enumerate(data.decode("utf-8", "replace").splitlines(), start=1):
                if "@deepseek-ai" in line or "deepseek-harness" in line:
                    findings.append(
                        (rel, number, "dsh-patch", "_patches a DSH source file: " + line)
                    )
                    break


def check_tracked_dsh_modules(root, findings):
    for rel in common.git_cached_files(root):
        if rel.startswith("node_modules/@deepseek-ai/") or "/node_modules/@deepseek-ai/" in rel:
            findings.append(
                (rel, 1, "tracked-dsh-module", "tracked @deepseek-ai package under node_modules")
            )


def check_manifest(rel, text, findings):
    path = Path(rel)
    try:
        data = json.loads(text)
    except ValueError as exc:
        line = getattr(exc, "lineno", 1) or 1
        findings.append((rel, line, "manifest", f"cannot parse package.json: {exc}"))
        return
    if not isinstance(data, dict):
        return
    lines = text.splitlines()

    if "patchedDependencies" in text:
        value = data.get("pnpm", {}).get("patchedDependencies") if isinstance(data.get("pnpm"), dict) else None
        if value is None:
            value = data.get("patchedDependencies")
        if value:
            findings.append(
                (
                    rel,
                    line_number(lines, '"patchedDependencies"'),
                    "patched-dependencies",
                    "pnpm patchedDependencies is not allowed for DSH",
                )
            )

    patch_hits = []
    scripts = data.get("scripts")
    if isinstance(scripts, dict):
        for name, command in scripts.items():
            if isinstance(command, str) and "patch-package" in command:
                patch_hits.append(f"script {name}")
    for section in (
        "dependencies",
        "devDependencies",
        "optionalDependencies",
        "peerDependencies",
    ):
        value = data.get(section)
        if isinstance(value, dict) and "patch-package" in value:
            patch_hits.append(section)
    package_manager = data.get("packageManager")
    if isinstance(package_manager, str) and "patch-package" in package_manager:
        patch_hits.append("packageManager")
    if patch_hits:
        findings.append(
            (
                rel,
                line_number(lines, "patch-package"),
                "patch-package",
                "patch-package is not allowed: " + ", ".join(sorted(patch_hits)),
            )
        )


def check_manifests(root, findings):
    for rel in common.scan_files(root, ["plugins"]):
        if Path(rel).name != "package.json":
            continue
        try:
            text = (Path(root) / rel).read_text(encoding="utf-8")
        except OSError:
            continue
        check_manifest(rel, text, findings)


def check_definitions(root, findings):
    for rel in common.scan_files(root, ["plugins"]):
        if Path(rel).suffix.lower() not in DEFINITION_EXTENSIONS:
            continue
        if is_test_path(rel):
            continue
        lines = common.read_lines(root, rel)
        if lines is None:
            continue
        for number, line in enumerate(lines, start=1):
            if comment_line(line):
                continue
            match = DEFINITION_RE.search(line) or METHOD_RE.search(line)
            if match:
                findings.append((rel, number, "vendored-definition", line.strip()))


def run(root):
    findings = []
    check_pin(root, findings)
    check_patches_dirs(root, findings)
    check_tracked_dsh_modules(root, findings)
    check_manifests(root, findings)
    check_definitions(root, findings)
    for rel, line, rule, excerpt in sorted(findings):
        common.emit(rel, line, rule, excerpt)
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(
        common.main_guard(
            __file__,
            "reject DSH patches, vendoring and patched dependencies",
            run,
            ["plugins"],
        )
    )
