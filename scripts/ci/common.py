#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Shared helpers for the phone-DSH static checkers.

Every checker is usable on its own (``python3 scripts/ci/<name>.py
--root DIR``) and from ``scripts/ci/check.sh``.  They share one definition of
the scanned file set: ``git ls-files --cached --others --exclude-standard``
under the explicit wave-owned scan roots.  Build trees, package-manager
directories, lockfiles, the checker sources, the hygiene allow-list and the
fixtures tree are never part of a production scan.
"""

from __future__ import annotations

import argparse
import fnmatch
import subprocess
import sys
from pathlib import Path

# The wave-owned directories, listed explicitly (no glob that could match a
# pre-existing module such as XiaozhiLinkPhoneUse).
SOURCE_ROOTS = [
    "spec/v1",
    "plugins",
    "shell",
    "Sources/PhoneDSHAgentCore",
    "Sources/PhoneDSHWire",
    "Sources/PhoneDSHLog",
    "Sources/PhoneDSHLoopback",
    "Sources/PhoneDSHGateway",
    "Sources/PhoneDSHController",
    "Sources/PhoneDSHEngine",
    "Sources/PhoneDSH",
    "Sources/PhoneDSHShell",
    # G2-FIX-22: reusable test-harness support (regular target, includes the
    # shared probe-site fixture). Scanned like every other phone source root.
    "Sources/PhoneDSHHarness",
    "Sources/PhoneDSHScenario",
]

TEST_ROOTS = [
    "Tests/PhoneDSHWireTests",
    "Tests/PhoneDSHAgentCoreTests",
    "Tests/PhoneDSHLogTests",
    "Tests/PhoneDSHLoopbackTests",
    "Tests/PhoneDSHGatewayTests",
    "Tests/PhoneDSHControllerTests",
    "Tests/PhoneDSHEngineTests",
    "Tests/PhoneDSHKillTests",
    "Tests/PhoneDSHProbeTests",
    "Tests/PhoneDSHScenarioTests",
    "Tests/PhoneDSHSmokeTests",
    "Tests/PhoneDSHTests",
    "Tests/PhoneDSHShellTests",
]

SCAN_ROOTS = SOURCE_ROOTS + TEST_ROOTS + [
    "scripts/ci/*.py",
    "scripts/ci/*.sh",
    "docs",
]

MODULE_ROOTS = [
    "Sources/PhoneDSHWire",
    "Sources/PhoneDSHLog",
    "Sources/PhoneDSHLoopback",
    "Sources/PhoneDSHGateway",
    "Sources/PhoneDSHController",
    "Sources/PhoneDSHEngine",
    "Sources/PhoneDSH",
    "Sources/PhoneDSHShell",
]

# Never scanned, independent of the roots.
IGNORED_DIRS = {"node_modules", ".build", "dist", "__pycache__", ".git"}
IGNORED_SUFFIXES = (".lock",)
IGNORED_NAMES = {"package-lock.json"}

ALLOW_LIST = "scripts/ci/hygiene-allow.txt"
FIXTURES_DIR = "scripts/ci/fixtures/"
CHECKER_DIR = "scripts/ci/"
CHECKER_SOURCES = {
    CHECKER_DIR + name
    for name in (
        "common.py",
        "hygiene.py",
        "license.py",
        "modules.py",
        "no_dsh_patch.py",
        "selftest.py",
        "gates_test.py",
    )
}


def repo_root(script_file):
    """Return the repository root that contains scripts/ci/<script>."""
    return Path(script_file).resolve().parents[2]


def git_files(root):
    """Return the tracked plus unignored-untracked files, repo-relative."""
    return _git_ls_files(root, ["--cached", "--others", "--exclude-standard"])


def git_cached_files(root):
    """Return only the files recorded in the git index, repo-relative."""
    return _git_ls_files(root, ["--cached"])


def _git_ls_files(root, options):
    try:
        proc = subprocess.run(
            ["git", "-C", str(root), "ls-files", *options, "-z"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
    except FileNotFoundError as exc:  # pragma: no cover - environment issue
        raise RuntimeError("git is required to enumerate the file set") from exc
    if proc.returncode != 0:
        message = proc.stderr.decode("utf-8", "replace").strip()
        raise RuntimeError(f"git ls-files failed in {root}: {message}")
    return [item for item in proc.stdout.decode("utf-8", "replace").split("\0") if item]


def ignored(rel):
    """True for paths the contract never scans."""
    parts = rel.split("/")
    if any(part in IGNORED_DIRS for part in parts):
        return True
    name = parts[-1]
    if name in IGNORED_NAMES or name.endswith(IGNORED_SUFFIXES):
        return True
    return False


def production_excluded(rel):
    """Files that a production scan must never descend into or report.

    The checker sources are excluded so that the patterns they search for
    cannot flag the checkers themselves.  The allow-list and fixture trees are
    excluded in the same way.
    """
    if rel == ALLOW_LIST or rel.startswith(FIXTURES_DIR) or rel in CHECKER_SOURCES:
        return True
    return False


def _root_exists(root, pattern):
    if any(char in pattern for char in "*?["):
        return any(Path(root).glob(pattern))
    return (Path(root) / pattern).exists()


def _matches(rel, pattern):
    if any(char in pattern for char in "*?["):
        if pattern.startswith("scripts/ci/"):
            return Path(rel).parent.as_posix() == "scripts/ci" and fnmatch.fnmatchcase(
                Path(rel).name, pattern.split("/")[-1]
            )
        return fnmatch.fnmatchcase(rel, pattern)
    prefix = pattern.rstrip("/")
    return rel == prefix or rel.startswith(prefix + "/")


def scan_files(root, roots=None, exclude_production=True):
    """Sorted repo-relative files under ``roots`` using the git file set."""
    root = Path(root)
    roots = list(SCAN_ROOTS if roots is None else roots)
    active = [pattern for pattern in roots if _root_exists(root, pattern)]
    selected = []
    for rel in git_files(root):
        if ignored(rel):
            continue
        if not any(_matches(rel, pattern) for pattern in active):
            continue
        if exclude_production and production_excluded(rel):
            continue
        selected.append(rel)
    return sorted(selected)


def read_lines(root, rel):
    """Text lines of a scanned file, or None for binary/unreadable files."""
    try:
        data = (Path(root) / rel).read_bytes()
    except OSError:
        return None
    if b"\0" in data[:8192]:
        return None
    return data.decode("utf-8", "replace").splitlines()


def emit(rel, line, rule, excerpt):
    """Print one finding in the fixed ``file:line: rule: excerpt`` format."""
    text = " ".join(str(excerpt).split())
    if len(text) > 200:
        text = text[:197] + "..."
    print(f"{rel}:{line}: {rule}: {text}")


def parse_args(script_file, description):
    """Parse ``--root`` (default: repo root from the script location)."""
    parser = argparse.ArgumentParser(description=description)
    parser.add_argument(
        "--root",
        metavar="DIR",
        default=None,
        help="repository root (default: found from this script's location)",
    )
    parser.add_argument(
        "--list-files",
        action="store_true",
        help="print the production file set and exit (debugging)",
    )
    args = parser.parse_args()
    root = Path(args.root).expanduser().resolve() if args.root else repo_root(script_file)
    if not root.is_dir():
        parser.error(f"--root is not a directory: {root}")
    return args, root


def main_guard(script_file, description, run, roots=None):
    """Run ``run(root)`` with the shared CLI and return the exit code."""
    args, root = parse_args(script_file, description)
    try:
        if args.list_files:
            for rel in scan_files(root, roots):
                print(rel)
            return 0
        return run(root)
    except RuntimeError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
