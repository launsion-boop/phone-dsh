#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Report every strings.json source anchor for one worktree, without stopping
at the first mismatch.

`spec/ui/v1/bot/tools/check_bot_ui.py` is the authority for the anchor rule
(`source: File.swift:line` + `expect` must be on that line). Its normal run
stops at the first failure, which is enough for a gate but not for a base/head
comparison: a new regression behind an old first error would be invisible.
This helper imports that checker, points it at the given worktree, and records
the full failure set by anchor id.

Usage:
    python3 scripts/ci/bot_ui_anchor_report.py <worktree> --json <out.json>
"""
from __future__ import annotations

import argparse
import importlib.util
import json
from pathlib import Path


def _load_checker(worktree: Path):
    path = worktree / "spec/ui/v1/bot/tools/check_bot_ui.py"
    if not path.is_file():
        raise SystemExit(f"missing checker: {path}")
    spec = importlib.util.spec_from_file_location("check_bot_ui_for_report", path)
    if spec is None or spec.loader is None:
        raise SystemExit(f"cannot load checker: {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    # The checker resolves probe-relative sources against this module global.
    module._ROOT = worktree
    return module


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("worktree")
    parser.add_argument("--json", required=True)
    args = parser.parse_args()

    root = Path(args.worktree).resolve()
    checker = _load_checker(root)
    strings_path = root / "spec/ui/v1/bot/strings.json"
    document = json.loads(strings_path.read_text(encoding="utf-8"))
    probe_root = root / document.get("sourceRoot", "examples/probe-app/PhoneDSHProbe/Bot")

    checked = 0
    failures: list[str] = []
    for entry in document.get("strings", []):
        source = entry.get("source", "")
        match = checker.SOURCE_RE.match(source or "")
        if match is None:
            continue
        relative, line = match.group(1), int(match.group(2))
        checked += 1
        try:
            if "/" in relative:
                # Repo-relative owner (shared Bot module), same rule the checker
                # uses in check_strings().
                path = root / relative
                lines = path.read_text(encoding="utf-8").splitlines()
                expect = entry.get("expect", "")
                if not expect or not (1 <= line <= len(lines)) or expect not in lines[line - 1]:
                    failures.append(entry["id"])
            else:
                checker.check_anchor(relative, line, entry.get("expect", ""), entry["id"])
        except Exception:  # noqa: BLE001 - every mismatch is the same report row
            failures.append(entry["id"])

    payload = {
        "worktree": str(root),
        "anchors": checked,
        "failures": sorted(set(failures)),
    }
    out = Path(args.json)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"anchors={checked} failures={len(payload['failures'])} -> {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
