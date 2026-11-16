#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Independent aha scorer for the existing production-assembly eval runner.

This is NOT a second Bot runner. It reads the evidence the real runner at
``scripts/ci/bot-e2e`` already produced (report.json, transcript.jsonl,
bot-events.jsonl) and scores the aha dimensions declared in
``aha_dimensions.json``.

Guard rails:

* ``--upstream mock`` never produces a model PASS: mock answers are scripted.
* Every declared repeat is scored. A mismatch between the plan's repeat count
  and the report is a FAIL; a failing repeat is never skipped.
* The selected scenario set comes from the engine's ``.plan.json`` and the
  ``aha-run.json`` marker written by ``run.sh``; ``--only`` is bound to that
  set, and evidence older than the marker is rejected as stale.
* Reply assertions are recomputed from ``transcript.jsonl`` text and checked
  against the engine's assertion result. Each reply row must match its own
  sha256/chars and the report's action-reply record; missing text is NOT_RUN,
  a hash/recompute disagreement is FAIL.
* A plan/assertion index or type mismatch is a FAIL, never a silent skip.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import hashlib
import json
import re
import sys
from pathlib import Path

SCHEMA_VERSION = 1
RECORD_RE = re.compile(r"^record://(session/[A-Za-z0-9._-]{1,64}#(0|[1-9][0-9]*)|event/[1-9][0-9]*)$")
HASH_RE = re.compile(r"^[0-9a-f]{64}$")
TRUST_VALUES = {"user", "observation", "assistant", "import", "system"}
AUTHOR_KINDS = {
    "chat", "task", "routine", "team", "proactive", "watchdog",
    "maintainer", "ui", "migration", "system",
}
REPLY_TYPES = {"reply_contains", "reply_not_contains", "reply_regex", "reply_not_regex"}


class ScoreError(Exception):
    """A scoring input is missing or inconsistent; never upgrades to PASS."""


def load_json(path: Path) -> dict:
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def read_jsonl(path: Path) -> list:
    rows = []
    with open(path, "r", encoding="utf-8") as handle:
        for number, line in enumerate(handle, 1):
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError as error:
                raise ScoreError(f"{path}:{number}: invalid JSON: {error}") from error
    return rows


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_time(value: str | None) -> _dt.datetime | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        return _dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def event_of(row: dict) -> dict | None:
    if isinstance(row.get("event"), dict):
        return row["event"]
    if isinstance(row.get("type"), str):
        return row
    return None


def latest_memory_documents(events: list) -> list:
    """Reconstruct the live memory documents from durable write/delete events."""
    latest: dict[str, dict] = {}
    for row in events:
        event = event_of(row)
        if not event:
            continue
        kind = event.get("type")
        data = event.get("data")
        if not isinstance(data, dict):
            continue
        path = data.get("path")
        if not isinstance(path, str) or not path:
            continue
        version = data.get("version")
        version = version if isinstance(version, int) else 0
        if kind == "memory.document_deleted":
            previous = latest.get(path)
            if previous is None or version >= previous["_version"]:
                latest[path] = {"path": path, "deleted": True, "_version": version}
        elif kind == "memory.document_written":
            previous = latest.get(path)
            if previous is None or version >= previous["_version"]:
                latest[path] = {**data, "deleted": False, "_version": version}
    return [value for value in latest.values() if not value.get("deleted")]


def check_provenance(documents: list, config: dict, global_provenance: dict) -> dict:
    """P0 provenance (today's contract) and the planned P1 fields, separately."""
    required = bool(config.get("required"))
    # INDEX.md is the host-maintained per-root pointer, not a factual memory
    # document; its evidence/observation metadata is not the model's claim.
    documents = [document for document in documents
                 if str(document.get("path", "")).rsplit("/", 1)[-1] != "INDEX.md"]
    issues: list[str] = []
    for document in documents:
        path = document.get("path", "?")
        evidence = document.get("evidence")
        if not isinstance(evidence, list) or not evidence:
            issues.append(f"{path}: no evidence reference")
        else:
            for ref in evidence:
                if not isinstance(ref, str) or not RECORD_RE.match(ref):
                    issues.append(f"{path}: malformed evidence {ref!r}")
        author = document.get("author")
        if not isinstance(author, dict) or author.get("kind") not in AUTHOR_KINDS:
            issues.append(f"{path}: missing or unknown author.kind")
        trust = document.get("trust")
        if trust is not None and trust not in TRUST_VALUES:
            issues.append(f"{path}: unknown trust {trust!r}")
    extended_fields = global_provenance.get("extended_fields", [])
    require_extended = bool(
        global_provenance.get("require_extended", False) or config.get("require_extended", False))
    present = [name for name in extended_fields if documents and all(name in doc for doc in documents)]
    missing = [name for name in extended_fields if name not in present]
    if require_extended and documents and missing:
        issues.append("missing planned metadata: " + ", ".join(missing))
    if required and not documents:
        issues.append("required a memory write, but no live memory document was observed")
    p0_ok = not issues
    if not documents:
        extended_status = "NOT_RUN"
    elif missing:
        extended_status = "NOT_RUN" if not require_extended else "FAIL"
    else:
        extended_status = "PASS"
    return {
        "required": required,
        "documents": len(documents),
        "p0_ok": p0_ok,
        "issues": issues,
        "extended_fields": extended_fields,
        "extended_present": present,
        "extended_missing": missing,
        "extended_status": extended_status,
    }


def structural_denials(results: Path, scenario_id: str, repeat_count: int) -> dict:
    """Count eval-harness identity/approval denials per repeat.

    The base harness can deny bash/write with `structural approval gate … 身份登记`
    because the host cannot attribute the call. Such a denial is an environment
    defect, not model behaviour: when a scenario's dimensions depend on host
    tools the scenario must be NOT_RUN, never a fake PASS/FAIL.
    """
    counts: dict[int, int] = {index: 0 for index in range(1, repeat_count + 1)}
    for index in range(1, repeat_count + 1):
        run_dir = results / "runs" / f"{scenario_id}-{index}"
        if not run_dir.is_dir():
            continue
        for path in run_dir.rglob("session.v*.jsonl"):
            try:
                text = path.read_text(encoding="utf-8", errors="ignore")
            except OSError:
                continue
            counts[index] += text.count("structural approval gate")
    return counts


def reply_rows(transcript: list, repeat_index: int) -> list:
    rows = []
    for row in transcript:
        if row.get("type") != "assistant_message":
            continue
        if row.get("repeat") != repeat_index:
            continue
        rows.append(row)
    return rows


def select_reply(rows: list, bot: str | None, turn: int | None) -> dict | None:
    candidates = rows
    if bot and bot != "main":
        scoped = [row for row in candidates if row.get("bot") == bot]
        if scoped:
            candidates = scoped
    if turn is not None:
        matching = [row for row in candidates if row.get("turn") == turn]
        return matching[-1] if matching else None
    if not candidates:
        return None
    latest = max(row.get("turn", 0) for row in candidates)
    return [row for row in candidates if row.get("turn") == latest][-1]


def recompute_reply_assertion(assertion: dict, rows: list) -> bool | None:
    """Recompute a reply_* assertion from transcript text; None means unsupported."""
    kind = assertion.get("type")
    if kind not in REPLY_TYPES:
        return None
    row = select_reply(rows, assertion.get("bot"), assertion.get("turn"))
    if row is None:
        return False
    text = row.get("text")
    if not isinstance(text, str) or not text:
        return False
    value = assertion.get("value")
    if not isinstance(value, str):
        return False
    ignore_case = bool(assertion.get("ignore_case"))
    if kind in {"reply_contains", "reply_not_contains"}:
        found = (value.lower() in text.lower()) if ignore_case else (value in text)
        return found if kind == "reply_contains" else not found
    flags = re.IGNORECASE if ignore_case else 0
    try:
        found = re.search(value, text, flags) is not None
    except re.error:
        return None
    return found if kind == "reply_regex" else not found


def verify_transcripts(transcript: list, report_repeats: list,
                       planned_assertions: list, repeat_count: int) -> tuple[list[str], dict]:
    """Check hashes, report cross-links and reply recomputation for every repeat."""
    errors: list[str] = []
    recomputed: dict[tuple[int, int], bool] = {}
    rows_by_repeat: dict[int, list] = {}
    for index in range(1, repeat_count + 1):
        rows = reply_rows(transcript, index)
        rows_by_repeat[index] = rows
        if not rows and any(str(item.get("type", "")).startswith("reply_")
                            for item in planned_assertions):
            errors.append(f"repeat {index}: transcript has no assistant_message rows")
        seen: dict[tuple, int] = {}
        for row in rows:
            text = row.get("text")
            if not isinstance(text, str) or not text:
                errors.append(f"repeat {index}: assistant_message has no text (missing/empty transcript)")
                continue
            expected_hash = row.get("sha256")
            expected_chars = row.get("chars")
            if expected_hash != sha256_bytes(text.encode("utf-8")):
                errors.append(f"repeat {index}: assistant_message sha256 mismatch (tampered text)")
            if expected_chars != len(text):
                errors.append(f"repeat {index}: assistant_message chars mismatch")
            key = (row.get("bot"), row.get("turn"), row.get("chars"))
            seen[key] = seen.get(key, 0) + 1
        report_keys: dict[tuple, int] = {}
        if index - 1 < len(report_repeats):
            for action in report_repeats[index - 1].get("actions", []) or []:
                for reply in action.get("replies", []) or []:
                    key = (reply.get("bot"), reply.get("turn"), reply.get("chars"))
                    report_keys[key] = report_keys.get(key, 0) + 1
        for key, count in seen.items():
            if report_keys.get(key, 0) < count:
                errors.append(
                    f"repeat {index}: transcript reply {key} has no matching report action reply")
    for index in range(1, repeat_count + 1):
        engine_assertions = (report_repeats[index - 1].get("assertions", [])
                             if index - 1 < len(report_repeats) else [])
        for position, planned in enumerate(planned_assertions):
            if planned.get("type") not in REPLY_TYPES:
                continue
            if position >= len(engine_assertions):
                continue
            value = recompute_reply_assertion(planned, rows_by_repeat[index])
            if value is None:
                continue
            recomputed[(index, position)] = value
            observed = engine_assertions[position].get("ok") is True
            if value != observed:
                errors.append(
                    f"repeat {index}: reply assertion[{position}] recompute={value} "
                    f"but engine={observed} (evidence disagreement)")
    return errors, {"rows_by_repeat": rows_by_repeat, "recomputed": recomputed}


def check_scenario(scenario_id: str, config: dict, dimensions_doc: dict,
                   results: Path, upstream: str, marker: dict,
                   planned: dict, engine_exit: int | None) -> dict:
    directory = results / scenario_id
    report_path = directory / "report.json"
    transcript_path = directory / "transcript.jsonl"
    events_path = directory / "bot-events.jsonl"
    evidence = {
        "dir": str(directory),
        "report": str(report_path),
        "transcript": str(transcript_path),
        "bot_events": str(events_path),
    }
    record = {
        "id": scenario_id,
        "status": "NOT_RUN",
        "reason": None,
        "engine_status": None,
        "run_status": None,
        "upstream": None,
        "repeat": None,
        "keep_bodies": None,
        "validity": [],
        "dimensions": [],
        "provenance": None,
        "hard_ok": None,
        "soft_score": None,
        "evidence": evidence,
        "notes": [],
    }
    if not report_path.is_file():
        record["reason"] = "engine produced no report.json (not run or crashed)"
        if engine_exit == 3:
            record["reason"] = "engine returned NOT_RUN; no report.json was produced"
        return record

    report = load_json(report_path)
    record["engine_status"] = report.get("status")
    record["run_status"] = report.get("run_status")
    record["upstream"] = report.get("upstream")
    record["repeat"] = report.get("repeat")
    record["keep_bodies"] = bool(report.get("keep_bodies"))

    if report.get("id") != scenario_id:
        record["status"] = "FAIL"
        record["reason"] = f"report id {report.get('id')!r} does not match {scenario_id!r}"
        return record
    if report.get("upstream") != upstream:
        record["status"] = "FAIL"
        record["reason"] = (
            f"report upstream {report.get('upstream')!r} does not match requested {upstream!r}")
        return record

    plan_repeat = planned.get("repeat", marker.get("repeat", 1))
    if not isinstance(report.get("repeat"), int) or report["repeat"] != plan_repeat:
        record["status"] = "FAIL"
        record["reason"] = (
            f"report repeat {report.get('repeat')!r} != plan repeat {plan_repeat!r}")
        return record
    repeats = report.get("repeats") or []
    if len(repeats) != plan_repeat:
        record["status"] = "FAIL"
        record["reason"] = f"report declares {plan_repeat} repeat(s) but carries {len(repeats)}"
        return record

    started = parse_time(report.get("started_at"))
    marker_started = parse_time(marker.get("started_at"))
    if started is None or marker_started is None:
        record["status"] = "FAIL"
        record["reason"] = "report/run marker has no parseable started_at"
        return record
    if started < marker_started:
        record["status"] = "FAIL"
        record["reason"] = (
            f"stale evidence: report started {report.get('started_at')} "
            f"before this run {marker.get('started_at')}")
        return record

    if not transcript_path.is_file():
        record["status"] = "NOT_RUN"
        record["reason"] = "transcript.jsonl is missing; independent reply evidence is absent"
        return record
    if not events_path.is_file():
        record["status"] = "FAIL"
        record["reason"] = "bot-events.jsonl is missing"
        return record
    try:
        transcript = read_jsonl(transcript_path)
        events = [row for row in read_jsonl(events_path)
                  if row.get("repeat") is None or isinstance(row.get("repeat"), int)]
    except ScoreError as error:
        record["status"] = "FAIL"
        record["reason"] = str(error)
        return record

    plan_assertions = planned.get("assertions") or []
    mapping_errors: list[str] = []
    for index, repeat in enumerate(repeats):
        engine_assertions = repeat.get("assertions") or []
        if len(engine_assertions) != len(plan_assertions):
            mapping_errors.append(
                f"repeat {index + 1}: assertion count report={len(engine_assertions)} "
                f"plan={len(plan_assertions)}")

    def assertion_check(index: int, expected_type: str, repeat_position: int) -> dict:
        repeat = repeats[repeat_position]
        engine_assertions = repeat.get("assertions") or []
        if index >= len(engine_assertions):
            return {"index": index, "ok": False,
                    "detail": f"assertion index {index} is missing from repeat {repeat_position + 1}"}
        observed = engine_assertions[index]
        if observed.get("type") != expected_type:
            mapping_errors.append(
                f"repeat {repeat_position + 1}: assertion[{index}] type "
                f"{observed.get('type')!r} != expected {expected_type!r}")
        ok = observed.get("ok") is True and observed.get("expect_ok", True) is True
        return {"index": index, "ok": ok, "type": observed.get("type"),
                "detail": observed.get("detail")}

    def evaluate(entries: list) -> list:
        results: list[dict] = []
        for entry in entries:
            checks = [assertion_check(entry["assertion"], entry["type"], position)
                      for position in range(len(repeats))]
            results.append({
                "index": entry["assertion"],
                "type": entry["type"],
                "ok": all(check["ok"] for check in checks),
                "per_repeat": checks,
                "why": entry.get("why", ""),
            })
        return results

    record["validity"] = evaluate(config.get("validity", []))
    for dimension in config.get("dimensions", []):
        checks = evaluate(dimension.get("checks", []))
        record["dimensions"].append({
            "name": dimension["name"],
            "kind": dimension["kind"],
            "passed": bool(checks) and all(check["ok"] for check in checks),
            "checks": checks,
        })

    transcript_errors, _ = verify_transcripts(
        transcript, repeats, plan_assertions, plan_repeat)
    if (not record["keep_bodies"]) and transcript_errors:
        record["status"] = "NOT_RUN"
        record["reason"] = (
            "transcripts carry no reply text (start the engine with --keep-bodies); "
            "independent scoring is impossible")
        return record
    if transcript_errors:
        record["status"] = "FAIL"
        record["reason"] = "; ".join(transcript_errors[:4])
        return record
    reply_expected = any(str(assertion.get("type", "")).startswith("reply_")
                         for assertion in plan_assertions)
    if reply_expected and not record["keep_bodies"]:
        record["status"] = "NOT_RUN"
        record["reason"] = (
            "reply assertions were planned but transcripts carry no reply text; "
            "independent scoring is impossible")
        return record

    denial_counts = structural_denials(results, scenario_id, plan_repeat)
    record["environment_denials"] = denial_counts
    contamination_policy = config.get("host_tool_contamination", "block")
    total_denials = sum(denial_counts.values())
    if total_denials:
        record["notes"].append(
            f"eval harness denied host tool calls {total_denials} time(s): "
            + ", ".join(f"repeat {index}={count}" for index, count in denial_counts.items()))
        if contamination_policy == "block":
            record["status"] = "NOT_RUN"
            record["reason"] = (
                f"eval harness identity/approval gate denied host tools {total_denials} time(s); "
                "the scenario's behaviour cannot be attributed to the model")
            return record

    provenance_records = []
    provenance_ok = True
    for index in range(1, plan_repeat + 1):
        repeat_events = [row for row in events if row.get("repeat") in (None, index)]
        documents = latest_memory_documents(repeat_events)
        provenance = check_provenance(
            documents, config.get("provenance", {}), dimensions_doc.get("provenance", {}))
        provenance_records.append({"repeat": index, **provenance})
        provenance_ok = provenance_ok and provenance["p0_ok"]
    record["provenance"] = provenance_records[0] if len(provenance_records) == 1 else {
        "required": bool(config.get("provenance", {}).get("required")),
        "documents": sum(item["documents"] for item in provenance_records),
        "p0_ok": provenance_ok,
        "issues": [issue for item in provenance_records for issue in item["issues"]],
        "extended_fields": dimensions_doc.get("provenance", {}).get("extended_fields", []),
        "extended_present": sorted({name for item in provenance_records
                                    for name in item["extended_present"]}),
        "extended_missing": sorted({name for item in provenance_records
                                    for name in item["extended_missing"]}),
        "extended_status": ("PASS" if all(item["extended_status"] == "PASS"
                                          for item in provenance_records)
                            else "NOT_RUN"),
        "repeats": provenance_records,
    }
    if config.get("provenance", {}).get("required"):
        record["dimensions"].append({
            "name": "stored_with_provenance",
            "kind": "hard",
            "passed": provenance_ok,
            "checks": [],
            "detail": record["provenance"]["issues"],
        })

    hard = [d for d in record["dimensions"] if d["kind"] == "hard"]
    soft = [d for d in record["dimensions"] if d["kind"] == "soft"]
    record["hard_ok"] = all(d["passed"] for d in hard) if hard else True
    if soft:
        per_repeat_scores = []
        for position in range(plan_repeat):
            passed = 0
            for dimension in soft:
                if all(check["per_repeat"][position]["ok"] for check in dimension["checks"]):
                    passed += 1
            per_repeat_scores.append(passed / len(soft))
        record["soft_score"] = min(per_repeat_scores)
    else:
        record["soft_score"] = 1.0

    if mapping_errors:
        record["status"] = "FAIL"
        record["reason"] = "; ".join(mapping_errors)
        return record
    if upstream == "mock":
        record["status"] = "NOT_RUN"
        record["reason"] = (
            "mock upstream: scripted replies prove wiring only; they are not model evidence")
        return record
    for repeat in repeats:
        repeat_status = repeat.get("status")
        if repeat_status in ("ERROR", "NOT_RUN"):
            record["status"] = "NOT_RUN"
            record["reason"] = f"repeat {repeat.get('index')} status {repeat_status!r}"
            return record
        if repeat_status != "PASS":
            record["status"] = "FAIL"
            record["reason"] = f"repeat {repeat.get('index')} status {repeat_status!r}"
            return record
    if record["engine_status"] != "PASS":
        if record["run_status"] == "NOT_RUN":
            record["status"] = "NOT_RUN"
            record["reason"] = "engine run_status is NOT_RUN"
        else:
            record["status"] = "FAIL"
            record["reason"] = f"engine status {record['engine_status']!r}"
        return record
    if config.get("validity") and not all(item["ok"] for item in record["validity"]):
        record["status"] = "FAIL"
        record["reason"] = "validity precondition failed (the scenario did not exercise its target)"
        return record
    if not record["hard_ok"]:
        record["status"] = "FAIL"
        record["reason"] = "a hard dimension failed"
        return record
    threshold = float(dimensions_doc.get("pass_threshold", 0.8))
    if record["soft_score"] < threshold:
        record["status"] = "FAIL"
        record["reason"] = f"soft score {record['soft_score']:.2f} < {threshold:.2f}"
        return record
    record["status"] = "PASS"
    record["reason"] = "all hard dimensions passed and soft score met the threshold"
    return record


def render_markdown(report: dict) -> str:
    lines = [
        "# aha multi-turn evaluation report",
        "",
        f"- upstream: `{report['upstream']}`",
        f"- repeat: {report['repeat']}",
        f"- generated: {report['generated_at']}",
        f"- engine exit: {report['engine_exit']}",
        f"- overall: **{report['overall']}**",
        f"- reason: {report['reason']}",
        f"- catalog sha256: `{report['catalog_sha256']}`",
        f"- dimensions sha256: `{report['dimensions_sha256']}`",
        "",
        "| scenario | status | engine | hard | soft | provenance |",
        "| --- | --- | --- | --- | --- | --- |",
    ]
    for scenario in report["scenarios"]:
        provenance = scenario.get("provenance") or {}
        lines.append(
            "| {id} | {status} | {engine} | {hard} | {soft} | {prov} |".format(
                id=scenario["id"],
                status=scenario["status"],
                engine=scenario.get("engine_status") or "-",
                hard="pass" if scenario.get("hard_ok") else "fail",
                soft=f"{scenario['soft_score']:.2f}" if isinstance(scenario.get("soft_score"), (int, float)) else "-",
                prov=("p0=" + ("pass" if provenance.get("p0_ok") else "fail")
                      + f", docs={provenance.get('documents', 0)}")
                     if provenance else "-",
            ))
    lines += ["", "## Dimensions", ""]
    for scenario in report["scenarios"]:
        lines.append(f"### {scenario['id']} — {scenario['status']}")
        if scenario.get("reason"):
            lines.append(f"- reason: {scenario['reason']}")
        for dimension in scenario.get("dimensions", []):
            mark = "PASS" if dimension["passed"] else "FAIL"
            lines.append(f"- [{mark}] {dimension['name']} ({dimension['kind']})")
            for check in dimension.get("checks", []):
                failed = [str(item["index"]) for item in check.get("per_repeat", [])
                          if not item["ok"]]
                lines.append(
                    f"  - [{ 'ok' if check['ok'] else 'fail' }] assertion[{check['index']}] "
                    f"{check.get('type')}"
                    + (f" failed repeats: {', '.join(failed)}" if failed else ""))
        provenance = scenario.get("provenance")
        if provenance:
            lines.append(
                f"- provenance p0: {'pass' if provenance['p0_ok'] else 'fail'}, "
                f"planned extended fields: {provenance['extended_status']} "
                f"(missing: {', '.join(provenance['extended_missing']) or 'none'})")
        lines.append("")
    lines += [
        "Mock upstream never yields a model PASS. `NOT_RUN` means the evidence or",
        "prerequisite is missing; it is not a weaker pass.",
        "",
    ]
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--results", type=Path, required=True)
    parser.add_argument("--catalog", type=Path, required=True)
    parser.add_argument("--dimensions", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--upstream", choices=("mock", "real"), required=True)
    parser.add_argument("--only", default="")
    parser.add_argument("--engine-exit", type=int, default=None)
    args = parser.parse_args(argv)

    try:
        dimensions_doc = load_json(args.dimensions)
        catalog = load_json(args.catalog)
    except (OSError, json.JSONDecodeError) as error:
        print(f"aha-score: cannot read configuration: {error}", file=sys.stderr)
        return 3

    plan_path = args.results / ".plan.json"
    marker_path = args.results / "aha-run.json"
    if not plan_path.is_file():
        print("aha-score: NOT_RUN: .plan.json is missing; selected scenarios are unknown",
              file=sys.stderr)
        return 3
    if not marker_path.is_file():
        print("aha-score: NOT_RUN: aha-run.json is missing; evidence freshness cannot be proven",
              file=sys.stderr)
        return 3
    try:
        plan = load_json(plan_path)
        marker = load_json(marker_path)
    except (OSError, json.JSONDecodeError) as error:
        print(f"aha-score: NOT_RUN: cannot read plan/run marker: {error}", file=sys.stderr)
        return 3

    configured = dimensions_doc.get("scenarios", {})
    planned_by_id = {scenario.get("id"): scenario for scenario in plan.get("scenarios", [])}
    requested = [item.strip() for item in args.only.split(",") if item.strip()]
    if requested:
        unknown = [item for item in requested if item not in planned_by_id]
        if unknown:
            print(f"aha-score: FAIL: --only ids not in the engine plan: {unknown}",
                  file=sys.stderr)
            return 2
        selected_ids = requested
    else:
        selected_ids = list(planned_by_id)
    if not selected_ids:
        print("aha-score: NOT_RUN: the engine plan selected no scenarios", file=sys.stderr)
        return 3
    if len(set(selected_ids)) != len(selected_ids):
        print("aha-score: FAIL: duplicate selected scenario id", file=sys.stderr)
        return 2
    missing_config = [sid for sid in selected_ids if sid not in configured]
    if missing_config:
        print(f"aha-score: FAIL: scenarios have no dimension map: {missing_config}",
              file=sys.stderr)
        return 2

    marker_upstream = marker.get("upstream")
    if marker_upstream != args.upstream:
        print(
            f"aha-score: FAIL: run marker upstream {marker_upstream!r} != {args.upstream!r}",
            file=sys.stderr)
        return 2
    expected_catalog = sha256_file(args.catalog)
    expected_dimensions = sha256_file(args.dimensions)
    if marker.get("catalog_sha256") != expected_catalog:
        print("aha-score: FAIL: catalog hash changed after the run started", file=sys.stderr)
        return 2
    if marker.get("dimensions_sha256") != expected_dimensions:
        print("aha-score: FAIL: dimensions hash changed after the run started", file=sys.stderr)
        return 2
    if plan.get("catalog_sha256") != expected_catalog:
        print("aha-score: FAIL: plan catalog hash does not match the catalog", file=sys.stderr)
        return 2
    if plan.get("upstream") != args.upstream:
        print(
            f"aha-score: FAIL: plan upstream {plan.get('upstream')!r} != {args.upstream!r}",
            file=sys.stderr)
        return 2
    if parse_time(marker.get("started_at")) is None:
        print("aha-score: FAIL: run marker started_at is not parseable", file=sys.stderr)
        return 2
    plan_repeat = plan.get("repeat")
    if not isinstance(plan_repeat, int) or plan_repeat < 1 or marker.get("repeat") != plan_repeat:
        print("aha-score: FAIL: plan repeat and run marker repeat disagree", file=sys.stderr)
        return 2
    marker_only = [item for item in (marker.get("only") or []) if item]
    if marker_only and sorted(marker_only) != sorted(selected_ids):
        print(
            "aha-score: FAIL: --only selection differs from the run marker "
            f"({marker_only} vs {selected_ids})", file=sys.stderr)
        return 2

    scenarios = []
    for scenario_id in selected_ids:
        scenarios.append(check_scenario(
            scenario_id, configured[scenario_id], dimensions_doc,
            args.results, args.upstream, marker, planned_by_id[scenario_id],
            args.engine_exit))

    statuses = {scenario["status"] for scenario in scenarios}
    if "FAIL" in statuses:
        overall = "FAIL"
        reason = "at least one scenario failed its hard/soft conditions"
    elif statuses == {"PASS"}:
        overall = "PASS"
        reason = "every selected scenario passed under the real-model precondition"
    else:
        overall = "NOT_RUN"
        reason = "no model evidence: mock upstream or missing/incomplete engine evidence"

    now = _dt.datetime.now(_dt.timezone.utc).isoformat().replace("+00:00", "Z")
    report = {
        "schema_version": SCHEMA_VERSION,
        "generated_at": now,
        "upstream": args.upstream,
        "repeat": plan_repeat,
        "engine_exit": args.engine_exit,
        "overall": overall,
        "reason": reason,
        "selected": selected_ids,
        "catalog": str(args.catalog),
        "catalog_sha256": expected_catalog,
        "dimensions": str(args.dimensions),
        "dimensions_sha256": expected_dimensions,
        "results": str(args.results),
        "scenarios": scenarios,
    }
    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / "aha-report.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    (args.out / "aha-report.md").write_text(render_markdown(report), encoding="utf-8")
    print(f"aha-score: {overall}: {reason}")
    for scenario in scenarios:
        print(f"aha-score: {scenario['id']} {scenario['status']} — {scenario.get('reason')}")
    print(f"aha-score: report {args.out / 'aha-report.md'}")
    if overall == "PASS":
        return 0
    if overall == "FAIL":
        return 1
    return 3


if __name__ == "__main__":
    raise SystemExit(main())
