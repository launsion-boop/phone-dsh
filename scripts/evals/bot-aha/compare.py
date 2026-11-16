#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Compare a baseline and a candidate aha score without mixing evidence.

Both reports must be real-model runs of the same catalog and dimension map,
with non-empty valid configuration hashes, the same non-empty scenario set and
a unique non-empty dimension set per scenario. Anything else is INCOMPARABLE
and exits 2. A missing/NOT_RUN side is NOT_RUN, never a quiet PASS. The
comparison never invents a model score: it only diffs two already-scored
real-model runs.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

HASH_RE = re.compile(r"^[0-9a-f]{64}$")
STATUSES = {"PASS", "FAIL", "NOT_RUN"}


def load(path: Path) -> dict:
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def validate_report(report: dict, label: str) -> list[str]:
    errors: list[str] = []
    if report.get("upstream") != "real":
        errors.append(f"{label}: upstream is {report.get('upstream')!r}, not 'real'")
    for field in ("catalog_sha256", "dimensions_sha256"):
        value = report.get(field)
        if not isinstance(value, str) or not HASH_RE.match(value):
            errors.append(f"{label}: {field} is not a 64-hex digest ({value!r})")
    if report.get("overall") not in STATUSES:
        errors.append(f"{label}: overall status {report.get('overall')!r} is invalid")
    repeat = report.get("repeat")
    if not isinstance(repeat, int) or repeat < 1:
        errors.append(f"{label}: repeat {repeat!r} is not a positive integer")
    engine_exit = report.get("engine_exit")
    if not isinstance(engine_exit, int):
        errors.append(f"{label}: engine_exit {engine_exit!r} is not an integer")
    if not isinstance(report.get("keep_bodies"), bool):
        errors.append(f"{label}: keep_bodies {report.get('keep_bodies')!r} is not a boolean")
    scenarios = report.get("scenarios") or []
    if not scenarios:
        errors.append(f"{label}: no scenarios")
        return errors
    seen: set[str] = set()
    for scenario in scenarios:
        scenario_id = scenario.get("id")
        if not isinstance(scenario_id, str) or not scenario_id:
            errors.append(f"{label}: scenario with an empty id")
            continue
        if scenario_id in seen:
            errors.append(f"{label}: duplicate scenario {scenario_id!r}")
        seen.add(scenario_id)
        if scenario.get("status") not in STATUSES:
            errors.append(f"{label}: {scenario_id}: invalid status {scenario.get('status')!r}")
        dimensions = scenario.get("dimensions") or []
        if not dimensions:
            errors.append(f"{label}: {scenario_id}: empty dimension set")
            continue
        names: set[str] = set()
        for dimension in dimensions:
            name = dimension.get("name")
            if not isinstance(name, str) or not name:
                errors.append(f"{label}: {scenario_id}: dimension with an empty name")
                continue
            if name in names:
                errors.append(f"{label}: {scenario_id}: duplicate dimension {name!r}")
            names.add(name)
            if not isinstance(dimension.get("passed"), bool):
                errors.append(f"{label}: {scenario_id}:{name}: passed is not a boolean")
    return errors


def dimension_names(scenario: dict) -> set[str]:
    return {dimension.get("name") for dimension in scenario.get("dimensions", [])}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--baseline-label", default="baseline")
    parser.add_argument("--candidate-label", default="candidate")
    args = parser.parse_args(argv)

    try:
        baseline = load(args.baseline)
        candidate = load(args.candidate)
    except (OSError, json.JSONDecodeError) as error:
        print(f"aha-compare: cannot read report: {error}", file=sys.stderr)
        return 2

    errors = validate_report(baseline, args.baseline_label) + \
        validate_report(candidate, args.candidate_label)
    for field in ("catalog_sha256", "dimensions_sha256", "upstream",
                  "repeat", "engine_exit", "keep_bodies"):
        if baseline.get(field) != candidate.get(field):
            errors.append(
                f"{field} differs ({baseline.get(field)!r} vs {candidate.get(field)!r})")
    if errors:
        for error in errors:
            print(f"aha-compare: INCOMPARABLE: {error}", file=sys.stderr)
        return 2

    baseline_scenarios = {scenario["id"]: scenario for scenario in baseline["scenarios"]}
    candidate_scenarios = {scenario["id"]: scenario for scenario in candidate["scenarios"]}
    if set(baseline_scenarios) != set(candidate_scenarios):
        print("aha-compare: INCOMPARABLE: scenario sets differ", file=sys.stderr)
        return 2
    for scenario_id in candidate_scenarios:
        before = dimension_names(baseline_scenarios[scenario_id])
        after = dimension_names(candidate_scenarios[scenario_id])
        if before != after:
            print(
                f"aha-compare: INCOMPARABLE: {scenario_id}: dimension sets differ "
                f"({sorted(before)} vs {sorted(after)})", file=sys.stderr)
            return 2

    rows = []
    regressions = []
    improvements = []
    for scenario_id in candidate_scenarios:
        before_status = baseline_scenarios[scenario_id]["status"]
        after_status = candidate_scenarios[scenario_id]["status"]
        before_dims = {dimension["name"]: dimension["passed"]
                       for dimension in baseline_scenarios[scenario_id]["dimensions"]}
        after_dims = {dimension["name"]: dimension["passed"]
                      for dimension in candidate_scenarios[scenario_id]["dimensions"]}
        changed = []
        for name in sorted(before_dims):
            was = before_dims[name]
            now = after_dims[name]
            if was != now:
                changed.append(f"{name}: {'pass' if was else 'fail'} -> {'pass' if now else 'fail'}")
                if was is True and now is False:
                    regressions.append((scenario_id, name))
        if before_status != "PASS" and after_status == "PASS":
            improvements.append(scenario_id)
        rows.append((scenario_id, before_status, after_status, changed))

    candidate_statuses = {scenario["status"] for scenario in candidate["scenarios"]}
    baseline_statuses = {scenario["status"] for scenario in baseline["scenarios"]}
    if "FAIL" in candidate_statuses:
        verdict = "FAIL"
        reason = "the candidate run still has FAIL scenarios"
    elif regressions:
        verdict = "FAIL"
        reason = "a dimension that passed on the baseline regressed on the candidate"
    elif "NOT_RUN" in candidate_statuses or "NOT_RUN" in baseline_statuses:
        verdict = "NOT_RUN"
        reason = "at least one side has NOT_RUN scenarios, so no model comparison exists"
    elif candidate.get("overall") == "NOT_RUN" or baseline.get("overall") == "NOT_RUN":
        verdict = "NOT_RUN"
        reason = "at least one side has no real-model evidence"
    elif baseline.get("overall") == "PASS" and candidate.get("overall") == "PASS":
        verdict = "PASS"
        reason = "both sides pass; no regression"
    elif candidate.get("overall") == "PASS":
        verdict = "PASS"
        reason = "the candidate passes and the baseline does not"
    else:
        verdict = "FAIL"
        reason = "the candidate does not pass"

    lines = [
        "# aha baseline/candidate comparison",
        "",
        f"- {args.baseline_label}: **{baseline.get('overall')}**",
        f"- {args.candidate_label}: **{candidate.get('overall')}**",
        f"- verdict: **{verdict}** — {reason}",
        f"- catalog sha256: `{baseline.get('catalog_sha256')}`",
        "",
        "| scenario | baseline | candidate | dimension changes |",
        "| --- | --- | --- | --- |",
    ]
    for scenario_id, before, after, changed in rows:
        lines.append(
            f"| {scenario_id} | {before} | {after} | {'; '.join(changed) or '-'} |")
    if improvements:
        lines += ["", "## Newly passing", ""] + [f"- {item}" for item in improvements]
    if regressions:
        lines += ["", "## Regressions", ""] + [f"- {sid}: {name}" for sid, name in regressions]
    lines += [
        "",
        "A NOT_RUN side is not compared as a pass. Mock upstream reports are not model evidence.",
        "",
    ]

    args.out.mkdir(parents=True, exist_ok=True)
    document = {
        "schema_version": 1,
        "baseline": str(args.baseline),
        "candidate": str(args.candidate),
        "baseline_overall": baseline.get("overall"),
        "candidate_overall": candidate.get("overall"),
        "verdict": verdict,
        "reason": reason,
        "catalog_sha256": baseline.get("catalog_sha256"),
        "dimensions_sha256": baseline.get("dimensions_sha256"),
        "upstream": baseline.get("upstream"),
        "scenarios": [
            {"id": sid, "baseline": before, "candidate": after, "changes": changed}
            for sid, before, after, changed in rows
        ],
        "regressions": [{"scenario": sid, "dimension": name} for sid, name in regressions],
        "newly_passing": improvements,
    }
    (args.out / "aha-compare.json").write_text(
        json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8")
    (args.out / "aha-compare.md").write_text("\n".join(lines), encoding="utf-8")
    print(f"aha-compare: {verdict}: {reason}")
    print(f"aha-compare: report {args.out / 'aha-compare.md'}")
    if verdict == "PASS":
        return 0
    if verdict == "FAIL":
        return 1
    return 3


if __name__ == "__main__":
    raise SystemExit(main())
