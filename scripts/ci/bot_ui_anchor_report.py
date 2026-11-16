#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Report every strings.json source anchor for one worktree, without stopping
at the first mismatch, and record the complete anchor inventory.

`spec/ui/v1/bot/tools/check_bot_ui.py` is the authority for the anchor rule
(`source: File.swift:line` + `expect` must be on that line). Its normal run
stops at the first failure; a base/head comparison needs the full failure set,
the full anchor-id inventory (so a deleted entry is visible), and an explicit
list of malformed entries instead of silently skipping them.

Output JSON:
  {
    "worktree": "...",
    "anchors": ["<id>", ...],       # every entry with a well-formed source
    "failures": ["<id>", ...],      # anchor rule mismatch (incl. missing file)
    "invalid": ["<id>", ...]        # malformed/missing `source` (not silently skipped)
  }

A malformed source or a missing strings.json is reported through `invalid`
(and a non-zero exit for the missing file), never treated as green.

Usage:
    python3 scripts/ci/bot_ui_anchor_report.py <worktree> --json <out.json>
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import re
import sys
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
    module._ROOT = worktree  # probe-relative resolution target
    return module


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("worktree")
    parser.add_argument("--json", required=True)
    args = parser.parse_args()

    root = Path(args.worktree).resolve()
    checker = _load_checker(root)
    strings_path = root / "spec/ui/v1/bot/strings.json"
    if not strings_path.is_file():
        print(f"missing strings.json: {strings_path}", file=sys.stderr)
        return 2
    try:
        document = json.loads(strings_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        print(f"malformed strings.json: {error}", file=sys.stderr)
        return 2

    entries = document.get("strings")
    if not isinstance(entries, list):
        print("strings.json has no 'strings' list", file=sys.stderr)
        return 2
    probe_root = root / document.get("sourceRoot", "examples/probe-app/PhoneDSHProbe/Bot")
    if not probe_root.is_dir():
        print(f"missing sourceRoot: {probe_root}", file=sys.stderr)
        return 2

    anchors: list[str] = []
    failures: list[str] = []
    invalid: list[str] = []
    source_re = re.compile(r"^([A-Za-z0-9_./-]+\.swift):(\d+)$")
    for index, entry in enumerate(entries):
        entry_id = entry.get("id")
        if not isinstance(entry_id, str) or not entry_id:
            invalid.append(f"<entry-{index}-no-id>")
            continue
        source = entry.get("source")
        match = source_re.match(source or "")
        if match is None:
            invalid.append(entry_id)
            continue
        anchors.append(entry_id)
        relative, line = match.group(1), int(match.group(2))
        try:
            if "/" in relative:
                # Repo-relative owner (shared Bot module), same rule the checker
                # uses in check_strings().
                path = root / relative
                lines = path.read_text(encoding="utf-8").splitlines()
                expect = entry.get("expect", "")
                if not expect or not (1 <= line <= len(lines)) or expect not in lines[line - 1]:
                    failures.append(entry_id)
            else:
                checker.check_anchor(relative, line, entry.get("expect", ""), entry_id)
        except Exception:  # noqa: BLE001 - every mismatch is the same report row
            failures.append(entry_id)

    payload = {
        "worktree": str(root),
        "source_root": str(probe_root),
        "anchors": sorted(set(anchors)),
        "failures": sorted(set(failures)),
        "invalid": sorted(set(invalid)),
    }
    out = Path(args.json)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"anchors={len(payload['anchors'])} failures={len(payload['failures'])} "
          f"invalid={len(payload['invalid'])} -> {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
