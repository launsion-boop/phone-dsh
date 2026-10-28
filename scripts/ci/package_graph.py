#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Reject a test-target-to-test-target dependency in the SwiftPM target graph.

Xcode's package resolver rejects a test target that depends on another test
target, while the SwiftPM command line accepts the same graph.  That gap made
``PhoneDSHScenarioTests -> PhoneDSHSmokeTests`` green under ``swift test`` and
fatal under ``xcodebuild build-for-testing`` for the iOS probe project.  The
shared harness code now lives in the regular ``PhoneDSHHarness``
library target (G2-FIX-22); this checker states the invariant directly so the
defect fails fast and deterministically, without depending on the Xcode or
package cache that the full resolver uses.

The input is the JSON that ``swift package dump-package --disable-sandbox``
prints for ``Package.swift`` (manifest only: no dependency checkout, no
build).  ``xcode-resolve.sh`` produces it and calls this checker.

Usage: python3 scripts/ci/package_graph.py --manifest FILE.json
Exit:  0 accepted, 1 test-target edge found, 2 unreadable/invalid input.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Reject test-target-to-test-target dependencies in the SwiftPM graph")
    parser.add_argument("--manifest", required=True,
                        help="JSON output of `swift package dump-package`")
    return parser.parse_args()


def load_manifest(path: Path) -> dict:
    try:
        manifest = json.loads(path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise RuntimeError(f"cannot read {path}: {exc}") from None
    except ValueError as exc:
        raise RuntimeError(f"{path} is not valid JSON: {exc}") from None
    if not isinstance(manifest, dict) or not isinstance(manifest.get("targets"), list):
        raise RuntimeError(f"{path} has no SwiftPM target list")
    return manifest


def dependency_target(dependency: object) -> str | None:
    """Return the referenced target name for a ``.target(name:)`` dependency."""
    if not isinstance(dependency, dict):
        return None
    reference = dependency.get("target")
    if isinstance(reference, list):
        reference = reference[0] if reference else None
    return reference if isinstance(reference, str) else None


def find_violations(manifest: dict) -> list[tuple[str, str]]:
    types: dict[str, str] = {}
    for target in manifest["targets"]:
        if not isinstance(target, dict):
            continue
        name = target.get("name")
        if isinstance(name, str):
            types[name] = str(target.get("type", ""))
    violations: list[tuple[str, str]] = []
    for target in manifest["targets"]:
        if not isinstance(target, dict) or target.get("type") != "test":
            continue
        name = target.get("name")
        if not isinstance(name, str):
            continue
        dependencies = target.get("dependencies")
        if not isinstance(dependencies, list):
            continue
        for dependency in dependencies:
            referenced = dependency_target(dependency)
            if referenced is not None and types.get(referenced) == "test":
                violations.append((name, referenced))
    return violations


def main() -> int:
    args = parse_args()
    try:
        manifest = load_manifest(Path(args.manifest))
    except RuntimeError as exc:
        print(f"package-graph: FAIL: {exc}", file=sys.stderr)
        return 2
    violations = find_violations(manifest)
    if violations:
        for source, referenced in violations:
            print(f"package-graph: FAIL: test target {source!r} depends on "
                  f"test target {referenced!r}", file=sys.stderr)
        print("package-graph: a test target must not depend on another test target; "
              "move shared harness code into a regular target and link its "
              ".library product instead (see docs/architecture.md).", file=sys.stderr)
        return 1
    test_count = sum(1 for target in manifest["targets"]
                     if isinstance(target, dict) and target.get("type") == "test")
    print(f"package-graph: PASS ({test_count} test targets, no test-target dependency)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
