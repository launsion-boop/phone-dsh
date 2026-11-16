#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Compare structured results collected on the same runner for a fixed base
and the candidate head.

The contract of this helper: a gate may already be red at base. What must not
happen is a NEW failure on head. Each comparison reports the head-only
failures (new), the base-only failures (fixed) and the shared failures
(pre-existing), writes a JSON receipt, and exits non-zero when anything is new.

Kinds:
  junit   --base <dir> --head <dir>    JUnit XML trees (classname#name identity)
  stages  --base <json> --head <json>  {"stages": {"<name>": {"rc": <int>, ...}}}
  anchors --base <json> --head <json>  {"failures": ["<strings id>", ...]}

Usage:
    python3 scripts/ci/ci_baseline_diff.py junit --base /tmp/base --head . \
        --json out.json
"""
from __future__ import annotations

import argparse
import json
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


def _junit_failures(root: Path) -> set[str]:
    failures: set[str] = set()
    files = sorted(root.rglob("*.xml"))
    if not files:
        raise SystemExit(f"no JUnit XML under {root}")
    for path in files:
        try:
            document = ET.parse(path).getroot()
        except ET.ParseError:
            # A truncated XML is itself a failure of the harness; keep it
            # visible instead of silently treating the test as passing.
            failures.add(f"xml-parse-error:{path.name}")
            continue
        for case in document.iter("testcase"):
            if case.find("failure") is not None or case.find("error") is not None:
                failures.add(f"{case.get('classname', '')}#{case.get('name', '')}")
    return failures


def _stage_results(path: Path) -> dict[str, int]:
    document = json.loads(path.read_text(encoding="utf-8"))
    stages = document.get("stages")
    if not isinstance(stages, dict) or not stages:
        raise SystemExit(f"{path}: missing non-empty 'stages' map")
    result: dict[str, int] = {}
    for name, entry in stages.items():
        if not isinstance(entry, dict) or not isinstance(entry.get("rc"), int):
            raise SystemExit(f"{path}: stage {name!r} has no integer rc")
        result[name] = entry["rc"]
    return result


def _anchor_failures(path: Path) -> set[str]:
    document = json.loads(path.read_text(encoding="utf-8"))
    failures = document.get("failures")
    if not isinstance(failures, list) or not all(isinstance(item, str) for item in failures):
        raise SystemExit(f"{path}: 'failures' must be a list of strings")
    return set(failures)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("kind", choices=("junit", "stages", "anchors"))
    parser.add_argument("--base", required=True)
    parser.add_argument("--head", required=True)
    parser.add_argument("--json", required=True)
    args = parser.parse_args()

    if args.kind == "junit":
        base_fail = _junit_failures(Path(args.base))
        head_fail = _junit_failures(Path(args.head))
    elif args.kind == "anchors":
        base_fail = _anchor_failures(Path(args.base))
        head_fail = _anchor_failures(Path(args.head))
    else:
        base_stages = _stage_results(Path(args.base))
        head_stages = _stage_results(Path(args.head))
        missing = sorted(set(base_stages) ^ set(head_stages))
        if missing:
            raise SystemExit(f"stage sets differ (cannot compare): {missing}")
        base_fail = {name for name, rc in base_stages.items() if rc != 0}
        head_fail = {name for name, rc in head_stages.items() if rc != 0}

    new = sorted(head_fail - base_fail)
    fixed = sorted(base_fail - head_fail)
    shared = sorted(base_fail & head_fail)
    receipt = {
        "kind": args.kind,
        "base_failures": sorted(base_fail),
        "head_failures": sorted(head_fail),
        "new": new,
        "fixed": fixed,
        "pre_existing": shared,
        "verdict": "NEW_FAILURE" if new else "NO_NEW_FAILURE",
    }
    Path(args.json).write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + "\n",
                               encoding="utf-8")
    print(f"{args.kind}: new={len(new)} fixed={len(fixed)} "
          f"pre_existing={len(shared)}")
    for name in new:
        print(f"  NEW {name}")
    for name in fixed:
        print(f"  FIXED {name}")
    return 1 if new else 0


if __name__ == "__main__":
    sys.exit(main())
