#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Turn one `check.sh --only <stage>` log into a comparable inventory.

The stage's exit code is not evidence: a red stage can hide a new diagnostic
and two runs can differ only in wrapper durations. This parser extracts stable
identities and a complete run inventory, and explicitly declines to certify
logs it cannot enumerate (wrapper-only/truncated logs).

Forms recognised:
  * unittest: `Ran N tests in ...` (summed across every suite), `FAIL:` /
    `ERROR:` test lines (`ERROR: setUpClass (...)` included), `FAILED (...)`
    summaries. Identity is the test id; a `path:line: rule: value` diagnostic
    printed by the test is kept as an additional identity.
  * diagnostics: `path:line: rule: value` lines (hygiene/modules). Counts are
    preserved, so the same file/rule line twice is two entries.
  * file checks: `N files checked`, `ok` lines (phone-spec).

Wrapper lines (`== FAIL: <stage> (17s)`, `FAIL <stage> 17s exit 1`,
`== summary`, `== CI GATE:`) and durations are never failure identities.

Output:
  {"parsed": bool, "kind": "unittest|diagnostics|files|none",
   "coverage": int|null, "checks": int,
   "failure_counts": {identity: count}, "failures": [identity, ...],
   "tests": int, "suites": int, "diagnostics": int}

Usage:
    python3 scripts/ci/stage_inventory.py <log> [--json <out>]
"""
from __future__ import annotations

import argparse
import json
import re
from collections import Counter
from pathlib import Path

RAN = re.compile(r"^Ran (\d+) tests? in ")
FAILED_SUMMARY = re.compile(r"^(FAILED|OK)\b")
TEST_FAIL = re.compile(r"^(FAIL|ERROR): (.+?) \((.+)\)\s*$")
ERROR_LINE = re.compile(r"^ERROR: (.+)$")
DIAGNOSTIC = re.compile(
    r"^(?P<path>[^:\s][^:]*):(?P<line>\d+):\s*(?P<rule>[a-z][a-z0-9-]*):\s*(?P<value>.+)$"
)
FILES_CHECKED = re.compile(r"(\d+)\s+files?\s+checked")
CHECKS = re.compile(r"(\d+)\s+checks?")
OK_LINE = re.compile(r"^\s*(?:ok\b|PASS\b)")
WRAPPER = (
    re.compile(r"^==\s*(?:FAIL|PASS|summary|CI GATE)"),
    re.compile(r"^(?:FAIL|PASS)\s+\S+\s+\d+(?:\.\d+)?s\b"),
    re.compile(r"^====+"),
)


def _is_wrapper(line: str) -> bool:
    return any(pattern.search(line) for pattern in WRAPPER)


def parse_log(path: Path) -> dict:
    ran: list[int] = []
    suites = 0
    failure_counts: Counter[str] = Counter()
    diagnostics: Counter[str] = Counter()
    ok_lines = 0
    files_checked: int | None = None
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if not line or _is_wrapper(line):
            continue
        match = RAN.match(line)
        if match:
            ran.append(int(match.group(1)))
            suites += 1
            continue
        if FAILED_SUMMARY.match(line):
            # Summary counts only; the individual FAIL/ERROR lines carry identities.
            continue
        match = TEST_FAIL.match(line)
        if match:
            failure_counts[f"{match.group(1)} {match.group(3)}"] += 1
            continue
        match = DIAGNOSTIC.match(line)
        if match:
            identity = (f"{match.group('path')}:{match.group('line')}: "
                        f"{match.group('rule')}: {match.group('value')}")
            diagnostics[identity] += 1
            continue
        match = ERROR_LINE.match(line)
        if match:
            # An ERROR line without a test id is still a real failure signal.
            failure_counts[f"ERROR-MESSAGE {match.group(1).strip()}"] += 1
            continue
        if FILES_CHECKED.search(line):
            files_checked = int(FILES_CHECKED.search(line).group(1))
        if CHECKS.search(line) and files_checked is None:
            # e.g. "111 checks" summary, only used when no file count exists.
            pass
        if OK_LINE.match(line):
            ok_lines += 1

    if ran or failure_counts:
        if not ran:
            # FAIL/ERROR lines without any Ran summary: truncated or killed run.
            return {
                "log": str(path), "parsed": False, "kind": "unittest",
                "coverage": None, "checks": 0, "failure_counts": {},
                "failures": [], "tests": 0, "suites": 0, "diagnostics": 0,
            }
        # A unittest log may also print path:line diagnostics (production scan).
        for identity, count in diagnostics.items():
            failure_counts[identity] += count
        return {
            "log": str(path), "parsed": True, "kind": "unittest",
            "coverage": sum(ran), "checks": sum(ran),
            "failure_counts": dict(failure_counts),
            "failures": list(failure_counts.elements()),
            "tests": sum(ran), "suites": suites,
            "diagnostics": sum(diagnostics.values()),
        }

    if diagnostics:
        return {
            "log": str(path), "parsed": True, "kind": "diagnostics",
            "coverage": sum(diagnostics.values()), "checks": sum(diagnostics.values()),
            "failure_counts": dict(diagnostics),
            "failures": list(diagnostics.elements()),
            "tests": 0, "suites": 0, "diagnostics": sum(diagnostics.values()),
        }

    if files_checked is not None:
        return {
            "log": str(path), "parsed": True, "kind": "files",
            "coverage": files_checked, "checks": max(ok_lines, files_checked),
            "failure_counts": {}, "failures": [],
            "tests": 0, "suites": 0, "diagnostics": 0,
        }

    # Pass-only stages (license) have no countable inventory; the caller may
    # still compare rc=0 on both sides, but a failing stage with this shape is
    # INCOMPLETE (there is nothing to certify).
    return {
        "log": str(path), "parsed": False, "kind": "none",
        "coverage": None, "checks": ok_lines, "failure_counts": {},
        "failures": [], "tests": 0, "suites": 0, "diagnostics": 0,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("log")
    parser.add_argument("--json")
    args = parser.parse_args()
    payload = parse_log(Path(args.log))
    if args.json:
        Path(args.json).write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
                                   encoding="utf-8")
    else:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
