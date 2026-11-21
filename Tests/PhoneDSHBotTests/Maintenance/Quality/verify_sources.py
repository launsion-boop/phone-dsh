#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Independent source/timing check for the A06 real artifacts.

For every scenario repeat this reads the durable events, the cited session/event
records and (for the external-file sample) the materialized workspace file. It
answers:
  * is there exactly one committed maintenance batch and does it change the path?
  * do all evidence/review refs resolve independently?
  * is the old value only historical and the new value the current assertion?
  * for the stale sample, does the external workspace file actually contain the
    new value after the correction record?
It does not replace judge.py; it explains a judge pass/fail with raw sources.
"""
import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import judge  # noqa: E402

SAMPLES = {
    "M-E5-CONTRADICTION": ("agent/notes/wake.md", judge.CONTRADICTION_OLD,
                           judge.CONTRADICTION_NEW),
    "M-E5-STALE-EXTERNAL": ("agent/notes/launch.md", judge.STALE_OLD,
                            judge.STALE_NEW),
}


def load_events(path):
    events = {}
    if not os.path.exists(path):
        return events
    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            event = row.get("event")
            if isinstance(event, dict):
                events.setdefault(row.get("repeat", 1), []).append(event)
    return events


def session_lines(run_dir):
    root = os.path.join(run_dir, "host", "materialized", "home", "sessions")
    result = {}
    if not os.path.isdir(root):
        return result
    for directory, _, files in os.walk(root):
        if "session.v4.jsonl" not in files:
            continue
        session_id = os.path.basename(directory)
        lines = {}
        with open(os.path.join(directory, "session.v4.jsonl"),
                  "r", encoding="utf-8") as handle:
            for raw in handle:
                try:
                    row = json.loads(raw)
                except json.JSONDecodeError:
                    continue
                seq = row.get("seq")
                if isinstance(seq, int):
                    lines[seq] = raw.strip()
        result[session_id] = lines
    return result


def resolve_ref(ref, events, sessions):
    if not isinstance(ref, str) or not ref.startswith("record://"):
        return {"ref": ref, "resolved": False, "reason": "invalid-reference"}
    if ref.startswith("record://event/"):
        try:
            seq = int(ref.split("/")[-1])
        except ValueError:
            return {"ref": ref, "resolved": False, "reason": "invalid-reference"}
        for event in events:
            if event.get("commitSeq") == seq:
                text = json.dumps(event.get("data") or {}, ensure_ascii=False)
                return {"ref": ref, "resolved": True, "kind": "event",
                        "seq": seq, "text": text}
        return {"ref": ref, "resolved": False, "reason": "event-missing"}
    if ref.startswith("record://session/"):
        rest = ref[len("record://session/"):]
        if "#" not in rest:
            return {"ref": ref, "resolved": False, "reason": "invalid-reference"}
        session_id, raw_seq = rest.split("#", 1)
        try:
            seq = int(raw_seq)
        except ValueError:
            return {"ref": ref, "resolved": False, "reason": "invalid-reference"}
        line = (sessions.get(session_id) or {}).get(seq)
        if line is None:
            return {"ref": ref, "resolved": False, "reason": "session-line-missing"}
        return {"ref": ref, "resolved": True, "kind": "session",
                "seq": seq, "text": line}
    return {"ref": ref, "resolved": False, "reason": "unsupported-reference"}


def workspace_file(run_dir, name):
    for root in (os.path.join(run_dir, "workspaces"),
                 os.path.join(run_dir, "host", "materialized", "workspace")):
        if not os.path.isdir(root):
            continue
        for directory, _, files in os.walk(root):
            if name in files:
                path = os.path.join(directory, name)
                try:
                    return {"path": path,
                            "content": open(path, "r", encoding="utf-8").read()}
                except OSError:
                    return None
    return None


def user_message_timeline(events):
    timeline = []
    for event in sorted(events, key=lambda item: item.get("commitSeq") or 0):
        if event.get("type") != "conversation.user_message":
            continue
        data = event.get("data") or {}
        content = data.get("content")
        text = ""
        if isinstance(content, list):
            text = " ".join(
                block.get("text") or "" for block in content
                if isinstance(block, dict))
        elif isinstance(content, str):
            text = content
        timeline.append({
            "seq": event.get("commitSeq"),
            "text": text[:500],
        })
    return timeline


def annotation_for(text, old_value, new_value):
    return {
        "has_old": old_value in text,
        "has_new": new_value in text,
        "old": old_value,
        "new": new_value,
    }


def verify(args):
    catalog = json.load(open(args.catalog, "r", encoding="utf-8"))
    output = []
    for scenario in catalog.get("scenarios", []):
        scenario_id = scenario.get("id")
        path, old_value, new_value = SAMPLES.get(scenario_id, (None, None, None))
        if path is None:
            continue
        directory = os.path.join(args.results, scenario_id)
        all_events = load_events(os.path.join(directory, "bot-events.jsonl"))
        for repeat, events in sorted(all_events.items()):
            run_dir = os.path.join(args.results, "runs",
                                   "%s-%s" % (scenario_id, repeat))
            documents = judge.reconstruct_documents(events)
            document = documents.get(path)
            started, batches = judge.batch_facts(events, documents)
            batch = batches[0] if len(batches) == 1 else None
            sessions = session_lines(run_dir)
            entry = {
                "scenario": scenario_id,
                "repeat": repeat,
                "path": path,
                "batch": None,
                "refs": [],
                "user_messages": user_message_timeline(events),
                "timing": {},
                "workspace_file": None,
                "fact": None,
                "verdict": "invalid",
                "reasons": [],
            }
            if batch is None:
                entry["reasons"].append("batch-association-not-exactly-one")
            else:
                entry["batch"] = {
                    "batch_id": batch["batch_id"],
                    "status": batch["status"],
                    "changed_paths": batch["changed_paths"],
                    "checks_passed": batch["checks_passed"],
                    "false_verified_documents": batch["false_verified_documents"],
                    "tokens_used": batch["tokens_used"],
                }
                if batch["status"] != "committed":
                    entry["reasons"].append("batch-not-committed")
                if path not in batch["changed_paths"]:
                    entry["reasons"].append("sample-path-not-changed")
                start_seq = started.get(batch["batch_id"])
                finish_seq = next(
                    (event.get("commitSeq") for event in events
                     if event.get("type") == "memory.maintenance_finished"
                     and (event.get("data") or {}).get("batch_id") == batch["batch_id"]),
                    None)
                doc_write_seq = next(
                    (event.get("commitSeq") for event in events
                     if event.get("type") == "memory.document_written"
                     and (event.get("data") or {}).get("path") == path
                     and (event.get("data") or {}).get("author", {}).get("kind") == "maintainer"),
                    None)
                old_record_seqs = [
                    event.get("commitSeq") for event in events
                    if event.get("type") == "conversation.user_message"
                    and old_value in json.dumps(event.get("data") or {},
                                                ensure_ascii=False)]
                new_record_seqs = [
                    event.get("commitSeq") for event in events
                    if event.get("type") == "conversation.user_message"
                    and new_value in json.dumps(event.get("data") or {},
                                                ensure_ascii=False)]
                entry["timing"] = {
                    "old_user_message_seqs": old_record_seqs,
                    "new_user_message_seqs": new_record_seqs,
                    "maintenance_start_seq": start_seq,
                    "maintainer_document_write_seq": doc_write_seq,
                    "maintenance_finish_seq": finish_seq,
                }
                if not old_record_seqs:
                    entry["reasons"].append("old-record-not-found-in-timeline")
                if not new_record_seqs:
                    entry["reasons"].append("new-record-not-found-in-timeline")
                if old_record_seqs and new_record_seqs and not (
                        min(old_record_seqs) < min(new_record_seqs)):
                    entry["reasons"].append("old-record-not-before-new-record")
                if new_record_seqs and isinstance(start_seq, int) and not (
                        min(new_record_seqs) < start_seq):
                    entry["reasons"].append("correction-not-before-maintenance")
                if isinstance(start_seq, int) and isinstance(doc_write_seq, int) and not (
                        start_seq < doc_write_seq):
                    entry["reasons"].append("maintainer-write-before-batch-start")
                if isinstance(doc_write_seq, int) and isinstance(finish_seq, int) and not (
                        doc_write_seq < finish_seq):
                    entry["reasons"].append("maintainer-write-after-batch-finish")
            if document is None:
                entry["reasons"].append("final-document-missing")
                output.append(entry)
                continue
            verdict, detail = judge.fact_verdict(document, old_value, new_value)
            entry["fact"] = {
                "verdict": verdict,
                "detail": detail,
                "content": document.get("content"),
                "review_state": (document.get("review") or {}).get("state"),
                "review_basis": (document.get("review") or {}).get("basis"),
            }
            for ref in judge.refs_of(document):
                resolved = resolve_ref(ref, events, sessions)
                if resolved.get("resolved"):
                    resolved.update(annotation_for(
                        resolved.get("text") or "", old_value, new_value))
                    resolved["text"] = (resolved["text"] or "")[:500]
                entry["refs"].append(resolved)
            unresolved = [ref for ref in entry["refs"] if not ref["resolved"]]
            if unresolved:
                entry["reasons"].append("cited-ref-unresolved")
            if verdict not in ("corrected", "preserved"):
                entry["reasons"].append("current-fact-not-corrected:%s" % verdict)
            ref_newer = [
                ref for ref in entry["refs"]
                if ref.get("resolved") and ref.get("has_new")
                and isinstance(ref.get("seq"), int)
                and entry["timing"].get("old_user_message_seqs")
                and ref["seq"] > min(entry["timing"]["old_user_message_seqs"])]
            entry["freshness"] = {
                "cited_new_value_refs_after_old_record": len(ref_newer),
                "cited_old_value_refs": len([
                    ref for ref in entry["refs"]
                    if ref.get("resolved") and ref.get("has_old")]),
            }
            if scenario_id == "M-E5-CONTRADICTION":
                entry["freshness"]["classification"] = (
                    "verified_correction"
                    if verdict in ("corrected", "preserved")
                    else "current_fact_not_corrected")
            if scenario_id == "M-E5-STALE-EXTERNAL":
                source = workspace_file(run_dir, "launch.md")
                if source is not None:
                    source = {
                        "path": source["path"],
                        "content": source["content"][:500],
                        "has_old": old_value in source["content"],
                        "has_new": new_value in source["content"],
                    }
                entry["workspace_file"] = source
                if source is None:
                    entry["reasons"].append("external-file-missing")
                elif new_value not in source["content"]:
                    entry["reasons"].append("external-file-not-updated")
                entry["freshness"]["external_file_updated"] = bool(
                    source and new_value in source["content"])
                if source is not None and new_value not in source["content"]:
                    entry["freshness"]["classification"] = (
                        "real_freshness_not_rechecked")
                elif verdict in ("corrected", "preserved"):
                    entry["freshness"]["classification"] = (
                        "verified_external_update")
                else:
                    class_new = judge.classify_occurrences(document["content"],
                                                           new_value)
                    class_old = judge.classify_occurrences(document["content"],
                                                           old_value)
                    if any(item["kind"] == "current" for item in class_new) and not any(
                            item["kind"] == "current" for item in class_old):
                        entry["freshness"]["classification"] = (
                            "parser_false_negative")
                    else:
                        entry["freshness"]["classification"] = (
                            "current_fact_not_corrected")
            entry["verdict"] = "verified" if not entry["reasons"] else "fail"
            output.append(entry)
    return output


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--results", required=True)
    parser.add_argument("--catalog", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    entries = verify(args)
    with open(args.out, "w", encoding="utf-8") as handle:
        json.dump({"schema": "bot-maintenance-source-verification/v1",
                   "entries": entries}, handle, ensure_ascii=False, indent=2,
                  sort_keys=True)
        handle.write("\n")
    print(json.dumps({"out": args.out, "entries": [
        {"scenario": e["scenario"], "repeat": e["repeat"],
         "verdict": e["verdict"], "reasons": e["reasons"]}
        for e in entries]}, ensure_ascii=False))


if __name__ == "__main__":
    main()
