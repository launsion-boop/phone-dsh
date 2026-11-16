#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Compare structured results from a fixed base and the candidate head.

The contract: a gate may already be red at base, but the comparison must be
able to prove that the head added no failure and ran no less coverage. A
same-named stage that is red on both sides is NOT proof by itself; each kind
compares real identities and inventories, and falls back to INCOMPLETE when it
cannot enumerate them reliably.

Kinds and contracts:
  junit    --base <dir> --head <dir>
           JUnit XML trees. Compares failure ids (classname#name), test-id
           coverage (a base test missing at head is INCOMPLETE), skipped
           counts, parse errors and missing XML.
  stages   --base <json> --head <json>
           {"stages": {"<name>": {"rc": int, "inventory": {
                "parsed": bool, "coverage": int, "failures": [str]}}}}
           Compares per-stage failure lines and coverage; unparsed or
           coverage-dropping stages are INCOMPLETE.
  anchors  --base <json> --head <json> [--allow-removals <json>]
           {"anchors": [id], "failures": [id], "invalid": [id]}
           Compares failures plus the anchor-id inventory. A removed anchor
           needs an entry in the removal allowlist (id/reason/evidence);
           malformed entries are INCOMPLETE.

Verdicts: NO_NEW_FAILURE (exit 0), NEW_FAILURE / INCOMPLETE (exit 1).

Usage:
    python3 scripts/ci/ci_baseline_diff.py junit --base ... --head ... --json out.json
"""
from __future__ import annotations

import argparse
import json
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


def _load_json(path: Path) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise SystemExit(f"cannot read {path}: {error}") from error
    if not isinstance(value, dict):
        raise SystemExit(f"{path}: top level must be an object")
    return value


def _string_list(value, where: str) -> list[str]:
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        raise SystemExit(f"{where}: expected a list of strings")
    return value


def _junit_inventory(root: Path) -> dict:
    files = sorted(root.rglob("*.xml"))
    parsed_errors = 0
    tests = 0
    skipped = 0
    failures: set[str] = set()
    ids: set[str] = set()
    if not files:
        return {"files": 0, "parse_errors": 1, "tests": 0, "skipped": 0,
                "failures": set(), "ids": set()}
    for path in files:
        try:
            document = ET.parse(path).getroot()
        except ET.ParseError:
            parsed_errors += 1
            continue
        for case in document.iter("testcase"):
            tests += 1
            identity = f"{case.get('classname', '')}#{case.get('name', '')}"
            ids.add(identity)
            if case.find("skipped") is not None:
                skipped += 1
            if case.find("failure") is not None or case.find("error") is not None:
                failures.add(identity)
    return {"files": len(files), "parse_errors": parsed_errors, "tests": tests,
            "skipped": skipped, "failures": failures, "ids": ids}


def _stage_inventory(entry, side: str, name: str) -> tuple[int, dict | None]:
    if not isinstance(entry, dict):
        raise SystemExit(f"{side}.{name}: stage entry must be an object")
    rc = entry.get("rc")
    if not isinstance(rc, int) or isinstance(rc, bool):
        raise SystemExit(f"{side}.{name}: rc must be an integer")
    inventory = entry.get("inventory")
    if not isinstance(inventory, dict):
        return rc, None
    parsed = inventory.get("parsed")
    coverage = inventory.get("coverage")
    failures = inventory.get("failure_counts")
    if failures is None:
        legacy = inventory.get("failures")
        if isinstance(legacy, list) and all(isinstance(item, str) for item in legacy):
            failures = {}
            for item in legacy:
                failures[item] = failures.get(item, 0) + 1
    if not isinstance(parsed, bool):
        return rc, None
    if coverage is not None and (not isinstance(coverage, int) or isinstance(coverage, bool)):
        return rc, None
    if not isinstance(failures, dict) or not all(
            isinstance(k, str) and isinstance(v, int) and not isinstance(v, bool)
            for k, v in failures.items()):
        return rc, None
    return rc, {"parsed": parsed, "coverage": coverage,
                "failure_counts": failures, "timed_out": bool(entry.get("timed_out"))}


def compare_junit(base_dir: str, head_dir: str) -> dict:
    base = _junit_inventory(Path(base_dir))
    head = _junit_inventory(Path(head_dir))
    incomplete: list[str] = []
    for side, inv in (("base", base), ("head", head)):
        if inv["files"] == 0:
            incomplete.append(f"{side}: no JUnit XML")
        if inv["parse_errors"]:
            incomplete.append(f"{side}: {inv['parse_errors']} unparsable JUnit file(s)")
    new = sorted(head["failures"] - base["failures"]) if not incomplete else []
    fixed = sorted(base["failures"] - head["failures"])
    pre = sorted(base["failures"] & head["failures"])
    if not incomplete:
        missing_tests = sorted(base["ids"] - head["ids"])
        if missing_tests:
            incomplete.append(f"head: {len(missing_tests)} base test id(s) did not run "
                              f"(e.g. {missing_tests[:3]})")
        if head["tests"] < base["tests"]:
            incomplete.append(f"coverage drop: tests {base['tests']} -> {head['tests']}")
        if head["skipped"] > base["skipped"]:
            incomplete.append(f"coverage drop: skipped {base['skipped']} -> {head['skipped']}")
    return {
        "kind": "junit",
        "base_inventory": {k: (sorted(v) if isinstance(v, set) else v)
                           for k, v in base.items() if k != "ids"},
        "head_inventory": {k: (sorted(v) if isinstance(v, set) else v)
                           for k, v in head.items() if k != "ids"},
        "new": new, "fixed": fixed, "pre_existing": pre, "incomplete": incomplete,
    }


def compare_stages(base_path: Path, head_path: Path) -> dict:
    base = _load_json(base_path).get("stages")
    head = _load_json(head_path).get("stages")
    if not isinstance(base, dict) or not isinstance(head, dict):
        raise SystemExit("stages JSON must contain a 'stages' object")
    new: list[str] = []
    fixed: list[str] = []
    pre: list[str] = []
    incomplete: list[str] = []
    if set(base) != set(head):
        incomplete.append(f"stage sets differ: {sorted(set(base) ^ set(head))}")
    for name in sorted(set(base) & set(head)):
        base_rc, base_inv = _stage_inventory(base[name], "base", name)
        head_rc, head_inv = _stage_inventory(head[name], "head", name)
        if base_inv is None or head_inv is None:
            if base_rc == 0 and head_rc == 0:
                # A pass-only stage (license) has no countable inventory.
                continue
            incomplete.append(f"{name}: stage inventory missing/unusable")
            continue
        if base_inv.get("timed_out") or head_inv.get("timed_out"):
            incomplete.append(f"{name}: stage timed out (rc={head_rc})")
            continue
        if not base_inv["parsed"] or not head_inv["parsed"]:
            if base_rc == 0 and head_rc == 0:
                continue
            incomplete.append(f"{name}: coverage not parseable")
            continue
        base_cov, head_cov = base_inv["coverage"], head_inv["coverage"]
        if base_cov is not None and head_cov is not None and head_cov < base_cov:
            incomplete.append(f"{name}: coverage drop {base_cov} -> {head_cov}")
            continue
        base_counts = base_inv["failure_counts"]
        head_counts = head_inv["failure_counts"]
        for identity in sorted(head_counts):
            delta = head_counts[identity] - base_counts.get(identity, 0)
            if delta > 0:
                new.append(f"{name}: {identity} (x{delta})")
        if head_rc == 0:
            if base_rc != 0:
                fixed.append(name)
            if head_counts:
                incomplete.append(f"{name}: rc=0 but inventory reports failures")
            continue
        # head is failing
        if not head_counts:
            incomplete.append(f"{name}: failing without a parsed failure "
                              f"(cannot prove no new failure)")
        elif base_rc == 0:
            # Every head failure is new, but keep the explicit stage signal.
            if not any(item.startswith(f"{name}: ") for item in new):
                new.append(f"{name}: stage failed (base passed)")
        else:
            for identity in sorted(base_counts):
                if head_counts.get(identity, 0) < base_counts[identity]:
                    incomplete.append(
                        f"{name}: failure disappeared without a green result: {identity}")
            if head_counts and all(
                    head_counts.get(identity, 0) <= base_counts.get(identity, 0)
                    for identity in head_counts):
                pre.append(name)
    return {
        "kind": "stages", "new": new, "fixed": fixed, "pre_existing": pre,
        "incomplete": incomplete,
        "base_inventory": base, "head_inventory": head,
    }


def _allowed_removals(path: Path | None) -> set[str]:
    if path is None:
        return set()
    document = _load_json(path)
    removals = document.get("removals")
    if not isinstance(removals, list):
        raise SystemExit(f"{path}: 'removals' must be a list")
    allowed: set[str] = set()
    for index, item in enumerate(removals):
        if not isinstance(item, dict) or not isinstance(item.get("id"), str):
            raise SystemExit(f"{path}: removals[{index}] needs an id")
        reason = item.get("reason")
        evidence = item.get("evidence")
        if not isinstance(reason, str) or not reason.strip() or not isinstance(evidence, str) \
                or not evidence.strip():
            raise SystemExit(f"{path}: removals[{index}] needs reason and evidence")
        allowed.add(item["id"])
    return allowed


def compare_anchors(base_path: Path, head_path: Path, allow_path: Path | None) -> dict:
    base = _load_json(base_path)
    head = _load_json(head_path)
    incomplete: list[str] = []
    for side, document in (("base", base), ("head", head)):
        if "anchors" not in document:
            incomplete.append(f"{side}: no anchor inventory")
        if not isinstance(document.get("anchors"), list):
            incomplete.append(f"{side}: 'anchors' must be a list")
            continue
        _string_list(document.get("anchors"), f"{side}.anchors")
        _string_list(document.get("failures"), f"{side}.failures")
        _string_list(document.get("invalid"), f"{side}.invalid")
        if document["invalid"]:
            incomplete.append(f"{side}: malformed source entries {document['invalid']}")
    if incomplete:
        return {"kind": "anchors", "new": [], "fixed": [], "pre_existing": [],
                "removed_without_evidence": [], "incomplete": incomplete,
                "base_inventory": base, "head_inventory": head}
    base_anchors = set(base["anchors"])
    head_anchors = set(head["anchors"])
    removed = sorted(base_anchors - head_anchors)
    allowed = _allowed_removals(allow_path)
    unallowed = [item for item in removed if item not in allowed]
    if unallowed:
        incomplete.append(f"anchors removed without evidence: {unallowed}")
    base_fail = set(base["failures"])
    head_fail = set(head["failures"])
    new = sorted(head_fail - base_fail)
    fixed = sorted(base_fail - head_fail)
    pre = sorted(base_fail & head_fail)
    return {
        "kind": "anchors", "new": new, "fixed": fixed, "pre_existing": pre,
        "removed_without_evidence": unallowed,
        "removed_with_evidence": [item for item in removed if item in allowed],
        "incomplete": incomplete,
        "base_inventory": base, "head_inventory": head,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("kind", choices=("junit", "stages", "anchors"))
    parser.add_argument("--base", required=True)
    parser.add_argument("--head", required=True)
    parser.add_argument("--json", required=True)
    parser.add_argument("--allow-removals")
    args = parser.parse_args()

    if args.kind == "junit":
        receipt = compare_junit(args.base, args.head)
    elif args.kind == "stages":
        receipt = compare_stages(Path(args.base), Path(args.head))
    else:
        receipt = compare_anchors(Path(args.base), Path(args.head),
                                  Path(args.allow_removals) if args.allow_removals else None)

    new = receipt["new"]
    incomplete = receipt["incomplete"]
    if new:
        verdict = "NEW_FAILURE"
    elif incomplete:
        verdict = "INCOMPLETE"
    else:
        verdict = "NO_NEW_FAILURE"
    receipt["verdict"] = verdict
    Path(args.json).write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + "\n",
                               encoding="utf-8")
    print(f"{args.kind}: verdict={verdict} new={len(new)} "
          f"fixed={len(receipt['fixed'])} pre_existing={len(receipt['pre_existing'])} "
          f"incomplete={len(incomplete)}")
    for item in new:
        print(f"  NEW {item}")
    for item in incomplete:
        print(f"  INCOMPLETE {item}")
    return 0 if verdict == "NO_NEW_FAILURE" else 1


if __name__ == "__main__":
    sys.exit(main())
