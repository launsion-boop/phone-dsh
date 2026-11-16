#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Independent E5/A06 maintainer quality judge.

Reads the evidence a real bot-e2e run already wrote (durable bot events and the
scenario report), never the maintainer model's self-report. It reconstructs the
final memory documents from `memory.document_written`/`memory.document_deleted`
events, locates the maintenance batch events, and decides for each planted
sample whether the contradiction was corrected (or kept as uncertain with both
sides cited) and whether the stale external fact was updated.

This judge does not compute a PASS for E5 by itself. It emits per-sample and
per-batch facts; the frozen quality gate (G-1 maintenance-quality-gate.json)
decides thresholds. Missing prerequisites are `not_run`/`invalid`, never pass.

Usage:
  python3 judge.py --results DIR --catalog PATH --out FILE \
      [--memory-suite JSON]
"""
import argparse
import hashlib
import json
import os
import sys
from datetime import datetime, timezone

CONTRADICTION_PATH = "agent/notes/wake.md"
STALE_PATH = "agent/notes/launch.md"
# Mechanical checks (spec/bot/v2 §4.4). Budget/usage failures are reported as
# budget facts, not as mechanical-check violations.
MECHANICAL_FAILURES = {
    "maintenance-evidence-unresolved",
    "maintenance-index-too-long",
    "maintenance-document-longer-than-evidence",
    "maintenance-change-budget-exceeded",
    "maintenance-verification-unrechecked",
    "maintenance-conflict-not-preserved",
    "maintenance-user-scope-evidence",
    "maintenance-rollback-conflict",
}
RETIRED_MARKERS = ("作废", "旧值", "改成", "改为", "不要再引用", "初次写入", "原先记的", "之前")


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def read_json(path):
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def read_events(path):
    """Return {repeat: [event, ...]} from bot-events.jsonl."""
    result = {}
    if not os.path.exists(path):
        return result
    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            event = row.get("event")
            if not isinstance(event, dict):
                continue
            result.setdefault(row.get("repeat", 1), []).append(event)
    return result


def event_seq(event):
    value = event.get("commitSeq")
    return value if isinstance(value, int) else 0


def reconstruct_documents(events):
    documents = {}
    for event in sorted(events, key=event_seq):
        data = event.get("data") or {}
        path = data.get("path")
        if not isinstance(path, str):
            continue
        if event.get("type") == "memory.document_written":
            documents[path] = {
                "content": data.get("content") or "",
                "evidence": data.get("evidence") or [],
                "review": data.get("review"),
                "version": data.get("version"),
            }
        elif event.get("type") == "memory.document_deleted":
            documents.pop(path, None)
    return documents


def refs_of(document):
    refs = []
    if not document:
        return refs
    for ref in document.get("evidence") or []:
        if isinstance(ref, str):
            refs.append(ref)
    review = document.get("review") or {}
    for ref in review.get("refs") or []:
        if isinstance(ref, str):
            refs.append(ref)
    return refs


def disputed(document):
    review = document.get("review") or {}
    return review.get("state") == "disputed" and len(refs_of(document)) >= 2


def batch_facts(events):
    started = {}
    batches = []
    for event in sorted(events, key=event_seq):
        kind = event.get("type")
        data = event.get("data") or {}
        if kind == "memory.maintenance_started":
            started[data.get("batch_id")] = event_seq(event)
        elif kind == "memory.maintenance_finished":
            checks = data.get("checks") or {}
            values = [
                checks.get("references_resolve"),
                checks.get("index_within_limit"),
                checks.get("documents_not_longer_than_evidence"),
                checks.get("change_budget_within_limit"),
            ]
            if "verification_rechecked" in checks:
                values.append(checks["verification_rechecked"])
            mechanical_ok = all(value is True for value in values)
            verification = data.get("verification") or {}
            status = data.get("status")
            failure = data.get("failure_code")
            violation = 0
            if status in ("committed", "cancelled") and not mechanical_ok:
                violation = 1
            if status in ("rolled_back", "rollback_failed", "failed") and failure in MECHANICAL_FAILURES:
                violation = 1
            start_seq = started.get(data.get("batch_id")) or 0
            window = [item for item in events if event_seq(item) >= start_seq]
            model_requests = sum(
                1 for item in window
                if item.get("type") == "ledger.usage_recorded"
                and (item.get("data") or {}).get("purpose") == "memory-maintenance")
            tool_calls = sum(
                1 for item in window
                if item.get("type") == "conversation.tool_call")
            max_result = max(
                [len(json.dumps(item.get("data") or {}, ensure_ascii=False))
                 for item in window
                 if item.get("type") == "conversation.tool_result"] or [0])
            batches.append({
                "batch_id": data.get("batch_id"),
                "status": status,
                "checks_passed": mechanical_ok,
                "false_verified_documents": int(
                    verification.get("blocking") or 0) if status == "committed" else 0,
                "mechanical_violations": violation,
                "tokens_used": int((data.get("budget") or {}).get("tokens_used") or 0),
                "model_requests": model_requests,
                "tool_calls": tool_calls,
                "max_tool_result_chars": max_result,
                "started_at_ms": data.get("started_at_ms"),
                "failure_code": failure,
            })
    return started, batches


def documents_before_maintenance(events, started_seq):
    cutoff = started_seq if isinstance(started_seq, int) else 10 ** 9
    prior = [event for event in events if event_seq(event) < cutoff]
    return reconstruct_documents(prior)


def contradiction_sample(repeat, events, start_seq, committed):
    path = CONTRADICTION_PATH
    documents = reconstruct_documents(events)
    document = documents.get(path)
    details = []
    if document is None:
        return {
            "id": "contradiction-%s" % repeat,
            "kind": "contradiction",
            "status": "invalid",
            "corrected": False,
            "preserved_both_sides": False,
            "stale_detected": False,
            "detail": "no final document at %s" % path,
            "committed": committed,
        }
    content = document["content"]
    old_claim = "七点起床"
    new_claim = "八点起床"
    has_old = old_claim in content
    has_new = new_claim in content
    before = documents_before_maintenance(events, start_seq)
    before_document = before.get(path)
    if before_document and new_claim in before_document.get("content", "") and old_claim not in before_document.get("content", ""):
        details.append("main turn already corrected before maintenance")
        return {
            "id": "contradiction-%s" % repeat,
            "kind": "contradiction",
            "status": "invalid",
            "corrected": False,
            "preserved_both_sides": False,
            "stale_detected": False,
            "detail": "; ".join(details),
            "committed": committed,
        }
    retired_old = has_old and any(marker in content for marker in RETIRED_MARKERS)
    corrected = has_new and (not has_old or retired_old)
    preserved = has_old and has_new and disputed(document) and len(refs_of(document)) >= 2
    if corrected:
        details.append("old claim replaced by the correcting record")
    elif preserved:
        details.append("both claims kept with >=2 refs and review=disputed")
    else:
        details.append("final content has_old=%s has_new=%s disputed=%s refs=%d"
                       % (has_old, has_new, disputed(document), len(refs_of(document))))
    return {
        "id": "contradiction-%s" % repeat,
        "kind": "contradiction",
        "status": "pass" if (corrected or preserved) else "fail",
        "corrected": bool(corrected or preserved),
        "preserved_both_sides": bool(preserved),
        "stale_detected": False,
        "detail": "; ".join(details),
            "committed": committed,
    }


def stale_sample(repeat, events, start_seq, committed):
    path = STALE_PATH
    documents = reconstruct_documents(events)
    document = documents.get(path)
    if document is None:
        return {
            "id": "stale-%s" % repeat,
            "kind": "stale-external",
            "status": "invalid",
            "corrected": False,
            "preserved_both_sides": False,
            "stale_detected": False,
            "detail": "no final document at %s" % path,
            "committed": committed,
        }
    content = document["content"]
    old_claim = "11 月 18 日"
    new_claim = "11 月 20 日"
    has_old = old_claim in content
    has_new = new_claim in content
    before = documents_before_maintenance(events, start_seq)
    before_document = before.get(path)
    if before_document and new_claim in before_document.get("content", "") and old_claim not in before_document.get("content", ""):
        return {
            "id": "stale-%s" % repeat,
            "kind": "stale-external",
            "status": "invalid",
            "corrected": False,
            "preserved_both_sides": False,
            "stale_detected": False,
            "detail": "main turn already updated the memory before maintenance",
            "committed": committed,
        }
    retired_old = has_old and any(marker in content for marker in RETIRED_MARKERS)
    updated = has_new and (not has_old or retired_old)
    preserved = has_old and has_new and disputed(document) and len(refs_of(document)) >= 2
    return {
        "id": "stale-%s" % repeat,
        "kind": "stale-external",
        "status": "pass" if (updated or preserved) else "fail",
        "corrected": bool(updated or preserved),
        "preserved_both_sides": bool(preserved),
        "stale_detected": bool(updated or preserved),
        "detail": "final content has_old=%s has_new=%s disputed=%s refs=%d"
                  % (has_old, has_new, disputed(document), len(refs_of(document))),
        "committed": committed,
    }


def judge(args):
    catalog = read_json(args.catalog)
    scenarios = {scenario["id"]: scenario for scenario in catalog.get("scenarios", [])}
    samples = []
    batches = []
    real = True
    seen_batches = 0
    for scenario_id in scenarios:
        directory = os.path.join(args.results, scenario_id)
        report_path = os.path.join(directory, "report.json")
        if not os.path.exists(report_path):
            samples.append({
                "id": "%s-missing" % scenario_id,
                "kind": "contradiction" if "CONTRADICTION" in scenario_id else "stale-external",
                "status": "invalid",
                "corrected": False,
                "preserved_both_sides": False,
                "stale_detected": False,
                "detail": "missing report.json; scenario did not run",
            })
            real = False
            continue
        report = read_json(report_path)
        if report.get("upstream") != "real":
            real = False
        events_by_repeat = read_events(os.path.join(directory, "bot-events.jsonl"))
        for repeat, events in sorted(events_by_repeat.items()):
            started, repeat_batches = batch_facts(events)
            batches.extend(repeat_batches)
            seen_batches += len(repeat_batches)
            if not repeat_batches:
                samples.append({
                    "id": "%s-%s-nobatch" % (scenario_id, repeat),
                    "kind": "contradiction" if "CONTRADICTION" in scenario_id else "stale-external",
                    "status": "invalid",
                    "corrected": False,
                    "preserved_both_sides": False,
                    "stale_detected": False,
                    "detail": "no memory.maintenance_finished event",
                })
                continue
            committed = any(
                item.get("status") in ("committed", "cancelled")
                for item in repeat_batches)
            first_batch = repeat_batches[0].get("batch_id")
            start_seq = started.get(first_batch)
            if "CONTRADICTION" in scenario_id:
                samples.append(contradiction_sample(
                    repeat, events, start_seq, committed))
            else:
                samples.append(stale_sample(repeat, events, start_seq, committed))

    memory_suites = []
    if args.memory_suite:
        suite = read_json(args.memory_suite)
        memory_suites.append({
            "suite": suite.get("suite", "PhoneDSHBotTests.Memory"),
            "baseline_failures": int(suite.get("baseline_failures", 0)),
            "candidate_failures": int(suite.get("candidate_failures", 0)),
        })

    output = {
        "schema": "bot-maintenance-quality-evidence/v1",
        "catalog_sha256": sha256_file(args.catalog),
        "upstream_real": bool(real),
        "real_batches": seen_batches,
        "evaluated_at_ms": int(datetime.now(timezone.utc).timestamp() * 1000),
        "samples": samples,
        "batches": batches,
        "memory_suites": memory_suites,
    }
    return output


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--results", required=True)
    parser.add_argument("--catalog", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--memory-suite")
    args = parser.parse_args()
    result = judge(args)
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as handle:
        json.dump(result, handle, ensure_ascii=False, indent=2, sort_keys=True)
        handle.write("\n")
    print(json.dumps({
        "out": args.out,
        "catalog_sha256": result["catalog_sha256"],
        "real_batches": result["real_batches"],
        "samples": [{
            "id": sample["id"], "status": sample["status"],
        } for sample in result["samples"]],
    }, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
