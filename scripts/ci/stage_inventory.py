#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Turn one `check.sh --only <stage>` log into a comparable inventory.

The baseline comparison must not stop at a stage's exit code: a stage that is
already red can hide a second, new failing sub-check. This parser extracts:

  parsed:    whether a coverage figure was found at all
  coverage:  the largest declared count (files checked, tests executed, ...)
  checks:    number of `ok`/`PASS` lines
  failures:  normalized failing lines (identity = the line text)

If no coverage figure can be found, `parsed` is false and the comparison must
treat the stage as INCOMPLETE rather than "no new failure".

Usage:
    python3 scripts/ci/stage_inventory.py <log> [--json <out>]
"""
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

FAIL_RE = re.compile(r"\bFAIL(?:ED|URE|URES)?\b")
OK_RE = re.compile(r"^\s*(?:ok\b|PASS\b)")
COVERAGE_PATTERNS = (
    re.compile(r"(\d+)\s+files?\s+checked", re.IGNORECASE),
    re.compile(r"Executed\s+(\d+)\s+tests?", re.IGNORECASE),
    re.compile(r"(\d+)\s+tests?\s+(?:passed|run|executed)", re.IGNORECASE),
    re.compile(r"(\d+)\s+checks?", re.IGNORECASE),
)
BENIGN = (
    re.compile(r"\b0\s+(?:failures?|failed)\b", re.IGNORECASE),
    re.compile(r"\bno\s+failures?\b", re.IGNORECASE),
)


def parse_log(path: Path) -> dict:
    failures: list[str] = []
    checks = 0
    coverage: int | None = None
    text = path.read_text(encoding="utf-8", errors="replace")
    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            continue
        if any(pattern.search(line) for pattern in BENIGN):
            continue
        if FAIL_RE.search(line) or line.startswith("not ok") or "✗" in line:
            failures.append(re.sub(r"\s+", " ", line))
        if OK_RE.match(line) or " PASS " in line:
            checks += 1
        for pattern in COVERAGE_PATTERNS:
            for match in pattern.finditer(line):
                value = int(match.group(1))
                coverage = value if coverage is None else max(coverage, value)
    if coverage is None and (checks or failures):
        coverage = checks + len(failures)
    return {
        "log": str(path),
        "parsed": coverage is not None,
        "coverage": coverage,
        "checks": checks,
        "failures": failures,
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
