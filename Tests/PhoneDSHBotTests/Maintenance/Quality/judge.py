#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Independent E5/A06 maintainer quality judge.

Reads only the evidence a real bot-e2e run wrote (durable bot events, scenario
report, materialized session logs) and reconstructs the final memory documents.
It never trusts the maintainer model's self-report.

Semantic rule: a value counts as the *current* fact only when the sentence /
clause that contains it presents it as the final value. A value introduced by
"之前 / 原先 / 原记 / 旧值 / 作废" is historical; a negated value ("不是七点")
is not asserted; a later "现在 / 目前 / 以…为准 / 改为" clause is current.
Both old and new current => ambiguous unless the document is explicitly
`review=disputed` with both sides cited. This is what stops a reversed
correction ("之前八点，现在七点") from counting as corrected.

Batch association is mandatory: a sample only counts when its repeat has
exactly one committed maintenance batch. `cancelled` is not committed.
`false_verified_documents` is an independent structural/semantic check, with
the product's own `verification.blocking` only as an additional signal.

Usage:
  python3 judge.py --results DIR --catalog PATH --out FILE [--memory-suite JSON]
"""
import argparse
import hashlib
import json
import os
import re
import sys
from datetime import datetime, timezone

CONTRADICTION_PATH = "agent/notes/wake.md"
STALE_PATH = "agent/notes/launch.md"
CONTRADICTION_OLD = "七点起床"
CONTRADICTION_NEW = "八点起床"
STALE_OLD = "11 月 18 日"
STALE_NEW = "11 月 20 日"

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

CLAUSE_SPLIT = re.compile(r"(?<=[。！？!?；;\n，,])")
CURRENT_RE = re.compile(
    r"(现在|目前|当前|现为|现是|已是|已经是|最终|为准|生效|以后|今后|从今|"
    r"改为|改成|更新为|调整为|确认是|最终是)")
HISTORY_RE = re.compile(
    r"(之前|原先|原来|最初|先前|以前|曾|过去|旧值|旧的是|原记|原为|原本|"
    r"早前|上一版|此前|先说的是|先说的|先说|旧文件|旧的|更正|纠正)")
RETIRE_RE = re.compile(
    r"(作废|失效|不再使用|不要再引用|已撤销|已删除|已被替换|过期|弃用|"
    r"已更正|更正为|被更正)")
NEGATION_RE = re.compile(r"(不是|并非|非|没有|不在|不再|未|并没有)\s*$")
SUFFIX_HISTORY = re.compile(
    r"^\s*(已作废|已失效|作废|失效|是旧值|是旧|已不再|已撤销|已过期|"
    r"不是|并非)")
SUFFIX_CURRENT = re.compile(r"^\s*(为准|生效|为当前|是当前|已生效|才是)")


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
    return sorted(set(refs))


def disputed(document):
    review = document.get("review") or {}
    return review.get("state") == "disputed" and len(refs_of(document)) >= 2


def _clauses(text):
    return [clause for clause in CLAUSE_SPLIT.split(text) if clause.strip()]


def _prefix_marker(prefix, expression):
    """Distance from the value to the last match, or None."""
    last = None
    for match in expression.finditer(prefix):
        last = match
    if last is None:
        return None
    return len(prefix) - last.end()


def classify_occurrences(text, value):
    """Classify every occurrence of value as current/historical/negated."""
    results = []
    needle = value.lower()
    for clause in _clauses(text):
        lower = clause.lower()
        start = 0
        while True:
            index = lower.find(needle, start)
            if index < 0:
                break
            prefix = clause[:index]
            suffix = clause[index + len(value):]
            negated = bool(NEGATION_RE.search(prefix[-12:]))
            if SUFFIX_HISTORY.match(suffix[:10]):
                negated = True
            history_distance = _prefix_marker(prefix[-32:], HISTORY_RE)
            retire_distance = _prefix_marker(prefix[-32:], RETIRE_RE)
            current_distance = _prefix_marker(prefix[-24:], CURRENT_RE)
            history = history_distance
            if retire_distance is not None:
                history = retire_distance if history is None else min(
                    history, retire_distance)
            if SUFFIX_HISTORY.match(suffix[:10]):
                history = 0 if history is None else min(history, 0)
            if SUFFIX_CURRENT.match(suffix[:10]):
                current_distance = 0
            if negated:
                kind = "negated"
            elif history is not None and (
                    current_distance is None or history < current_distance):
                kind = "historical"
            elif current_distance is not None and (
                    history is None or current_distance < history):
                kind = "current"
            elif history is not None and current_distance is not None:
                kind = "ambiguous"
            else:
                kind = "current"
            results.append({
                "value": value,
                "kind": kind,
                "clause": clause.strip(),
            })
            start = index + len(value)
    return results


def fact_verdict(document, old_value, new_value):
    """Return (verdict, detail) for a single-fact document.

    verdict: corrected | preserved | reversed | ambiguous | unresolved
    A reversed correction and an unmarked two-value document are never pass.
    """
    content = document.get("content") or ""
    old_occurrences = classify_occurrences(content, old_value)
    new_occurrences = classify_occurrences(content, new_value)
    old_current = any(item["kind"] == "current" for item in old_occurrences)
    new_current = any(item["kind"] == "current" for item in new_occurrences)
    ambiguous = any(
        item["kind"] == "ambiguous"
        for item in old_occurrences + new_occurrences)
    detail = (
        "old_current=%s new_current=%s ambiguous=%s old=%s new=%s"
        % (old_current, new_current, ambiguous,
           [(item["kind"], item["clause"]) for item in old_occurrences],
           [(item["kind"], item["clause"]) for item in new_occurrences]))
    if old_current and new_current:
        if disputed(document):
            return "preserved", detail
        return "ambiguous", detail
    if ambiguous:
        return "ambiguous", detail
    if new_current and not old_current:
        return "corrected", detail
    if old_current and not new_current:
        return "reversed", detail
    return "unresolved", detail


def batch_facts(events, documents):
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
            if status in ("rolled_back", "rollback_failed", "failed") \
                    and failure in MECHANICAL_FAILURES:
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
            independent_false = 0
            for change in data.get("changes") or []:
                path = change.get("path")
                if not isinstance(path, str) or change.get("deleted"):
                    continue
                document = documents.get(path)
                if document is None:
                    continue
                review = document.get("review") or {}
                if review.get("state") != "verified":
                    continue
                refs = refs_of(document)
                basis = review.get("basis")
                bad = False
                if not refs or basis == "model-inference":
                    bad = True
                if path == CONTRADICTION_PATH:
                    verdict, _ = fact_verdict(
                        document, CONTRADICTION_OLD, CONTRADICTION_NEW)
                    bad = bad or verdict not in ("corrected", "preserved")
                elif path == STALE_PATH:
                    verdict, _ = fact_verdict(
                        document, STALE_OLD, STALE_NEW)
                    bad = bad or verdict not in ("corrected", "preserved")
                if bad:
                    independent_false += 1
            product_blocking = int(verification.get("blocking") or 0)
            batches.append({
                "batch_id": data.get("batch_id"),
                "status": status,
                "checks_passed": mechanical_ok,
                # Independent structural/semantic check, plus the product's
                # own blocking count as an additional signal (never the only
                # source).
                "false_verified_documents": max(
                    independent_false, product_blocking),
                "product_blocking_documents": product_blocking,
                "mechanical_violations": violation,
                "tokens_used": int((data.get("budget") or {}).get("tokens_used") or 0),
                "model_requests": model_requests,
                "tool_calls": tool_calls,
                "max_tool_result_chars": max_result,
                "started_at_ms": data.get("started_at_ms"),
                "failure_code": failure,
                "changed_paths": [
                    change.get("path") for change in data.get("changes") or []
                    if isinstance(change.get("path"), str)
                ],
            })
    return started, batches


def documents_before_maintenance(events, started_seq):
    cutoff = started_seq if isinstance(started_seq, int) else 10 ** 9
    prior = [event for event in events if event_seq(event) < cutoff]
    return reconstruct_documents(prior)


def _sample_status(content_result, committed, expected_kind):
    verdict, detail = content_result
    passed = verdict in ("corrected", "preserved")
    if not committed:
        return {
            "status": "fail",
            "corrected": False,
            "preserved_both_sides": False,
            "stale_detected": False,
            "detail": "%s; batch not committed" % detail,
        }
    if verdict == "preserved":
        return {
            "status": "pass",
            "corrected": True,
            "preserved_both_sides": True,
            "stale_detected": str(expected_kind).startswith("stale"),
            "detail": detail,
        }
    return {
        "status": "pass" if passed else "fail",
        "corrected": passed,
        "preserved_both_sides": False,
        "stale_detected": passed and str(expected_kind).startswith("stale"),
        "detail": detail,
    }


def contradiction_sample(repeat, events, batch, committed):
    path = CONTRADICTION_PATH
    documents = reconstruct_documents(events)
    document = documents.get(path)
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
            "batch_status": batch.get("status") if batch else None,
        }
    verdict, detail = fact_verdict(document, CONTRADICTION_OLD, CONTRADICTION_NEW)
    result = _sample_status(
        (verdict, detail), committed, "contradiction")
    result.update({
        "id": "contradiction-%s" % repeat,
        "kind": "contradiction",
        "committed": committed,
        "batch_status": batch.get("status") if batch else None,
    })
    return result


def stale_sample(repeat, events, batch, committed):
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
            "batch_status": batch.get("status") if batch else None,
        }
    verdict, detail = fact_verdict(document, STALE_OLD, STALE_NEW)
    result = _sample_status((verdict, detail), committed, "stale-external")
    result.update({
        "id": "stale-%s" % repeat,
        "kind": "stale-external",
        "committed": committed,
        "batch_status": batch.get("status") if batch else None,
    })
    return result


def judge(args):
    catalog = read_json(args.catalog)
    scenarios = {scenario["id"]: scenario for scenario in catalog.get("scenarios", [])}
    samples = []
    batches = []
    upstream_real = True
    for scenario_id in scenarios:
        directory = os.path.join(args.results, scenario_id)
        report_path = os.path.join(directory, "report.json")
        if not os.path.exists(report_path):
            samples.append({
                "id": "%s-missing" % scenario_id,
                "kind": "contradiction" if "CONTRADICTION" in scenario_id
                        else "stale-external",
                "status": "invalid",
                "corrected": False,
                "preserved_both_sides": False,
                "stale_detected": False,
                "detail": "missing report.json; scenario did not run",
                "committed": False,
                "batch_status": None,
            })
            upstream_real = False
            continue
        report = read_json(report_path)
        if report.get("upstream") != "real":
            upstream_real = False
        events_by_repeat = read_events(os.path.join(directory, "bot-events.jsonl"))
        for repeat, events in sorted(events_by_repeat.items()):
            documents = reconstruct_documents(events)
            started, repeat_batches = batch_facts(events, documents)
            batches.extend(repeat_batches)
            if len(repeat_batches) != 1:
                samples.append({
                    "id": "%s-%s-batch-association" % (scenario_id, repeat),
                    "kind": "contradiction" if "CONTRADICTION" in scenario_id
                            else "stale-external",
                    "status": "invalid",
                    "corrected": False,
                    "preserved_both_sides": False,
                    "stale_detected": False,
                    "detail": "expected exactly one maintenance batch, found %d"
                              % len(repeat_batches),
                    "committed": False,
                    "batch_status": None,
                })
                continue
            batch = repeat_batches[0]
            committed = batch.get("status") == "committed"
            if "CONTRADICTION" in scenario_id:
                samples.append(contradiction_sample(
                    repeat, events, batch, committed))
            else:
                samples.append(stale_sample(
                    repeat, events, batch, committed))

    memory_suites = []
    if args.memory_suite:
        suite = read_json(args.memory_suite)
        memory_suites.append({
            "suite": suite.get("suite", "PhoneDSHBotTests.Memory"),
            "baseline_failures": int(suite.get("baseline_failures", 0)),
            "candidate_failures": int(suite.get("candidate_failures", 0)),
        })

    return {
        "schema": "bot-maintenance-quality-evidence/v1",
        "catalog_sha256": sha256_file(args.catalog),
        "upstream_real": bool(upstream_real),
        "real_batches": len(batches),
        "evaluated_at_ms": int(datetime.now(timezone.utc).timestamp() * 1000),
        "samples": samples,
        "batches": batches,
        "memory_suites": memory_suites,
    }


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
            "id": sample["id"],
            "status": sample["status"],
            "committed": sample.get("committed"),
        } for sample in result["samples"]],
    }, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
