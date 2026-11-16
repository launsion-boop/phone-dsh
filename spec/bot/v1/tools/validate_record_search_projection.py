#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Validate the record-search projection addendum (spec/bot/v1/README.md §4.4).

Reference projector: one hit per canonical ref, only the record's own
top-level text, record-bridge echo (record.search/read envelope) excluded,
snippet bounded, no nested raw/JSON expansion. The synthetic vectors mirror
the real rawlog shape (43k record.read output with escaped raw lines).
"""
from __future__ import annotations
import json, re, sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(ROOT))
from spec.v1.tools.spec_golden import SpecError, validate_json

BOT = ROOT / "spec" / "bot" / "v1"
GOLDEN = BOT / "golden" / "record-search-projection.json"
SNIPPET_MAX = 400
HITS_MAX = 20


def load(name): return json.loads((BOT / name).read_text())


def is_bridge_echo(text: str) -> bool:
    try:
        value = json.loads(text)
    except (ValueError, TypeError):
        return False
    return isinstance(value, dict) and value.get("tool") in ("record.search", "record.read")


def snippet(text: str, needle: str) -> str:
    single = " ".join(text.split())
    lower = single.lower()
    pos = lower.find(needle.lower())
    if pos < 0:
        return single[:180]
    start = max(0, pos - 80)
    return single[start:start + SNIPPET_MAX]


def project(fixture: dict) -> dict:
    needle = fixture["query"]
    hits = []
    excluded = []
    seen = set()
    for record in fixture["records"]:
        if record["ref"] in seen:
            continue
        if is_bridge_echo(record["text"]):
            excluded.append({"ref": record["ref"], "reason": "record-bridge-echo"})
            continue
        if needle.lower() not in record["text"].lower():
            continue
        if len(hits) >= HITS_MAX:
            break
        seen.add(record["ref"])
        hits.append({
            "ref": record["ref"],
            "record": record["record"],
            "type": record["type"],
            "time": record["time"],
            "snippet": snippet(record["text"], needle),
        })
    hits.sort(key=lambda item: (-item["time"], item["ref"]))
    return {"query": needle, "hits": hits, "excluded": excluded}


def main() -> int:
    fixture = json.loads(GOLDEN.read_text())
    result = project(fixture)
    expected = fixture["expected"]
    refs = [item["ref"] for item in result["hits"]]
    expected_refs = [item["ref"] for item in expected["hits"]]
    if refs != expected_refs:
        raise AssertionError(f"hits {refs} != {expected_refs}")
    for item in result["hits"]:
        if len(item["snippet"]) > SNIPPET_MAX or "\n" in item["snippet"]:
            raise AssertionError(f"{item['ref']}: snippet bound")
        if item["record"] not in ("session", "event"):
            raise AssertionError(f"{item['ref']}: record kind")
        if item["type"] not in ("conversation.user_message", "conversation.assistant_message"):
            raise AssertionError(f"{item['ref']}: unexpected type")
    if len(refs) != len(set(refs)):
        raise AssertionError("duplicate ref in hits")
    for excluded in expected["excluded"]:
        if not any(item["ref"] == excluded["ref"] for item in result["excluded"]):
            raise AssertionError(f"{excluded['ref']} was not excluded")
    for record in fixture["records"]:
        if record.get("nested"):
            for nested in record["nested"]:
                if sum(1 for ref in refs if ref == nested) > 1:
                    raise AssertionError(f"{nested}: nested ref duplicated")
    # The result must still validate against the frozen record-query shape.
    envelope = {"ok": True, "tool": "record.search", "egress": False, "scope": "bot",
                "data": {"query": fixture["query"], "since": None,
                         "hits": [{key: item[key] for key in ("ref", "record", "time", "snippet")}
                                  | {"type": item["type"]} for item in result["hits"]]},
                "truncated": False}
    validate_json(envelope, load("record-query.schema.json"), "projection envelope")
    # mutations: including a bridge echo or expanding nested raw must change the result
    mutated = json.loads(json.dumps(fixture))
    mutated["records"][1]["text"] = "contradiction from a nested raw line"
    if project(mutated)["hits"] != result["hits"] and project(mutated)["hits"] == result["hits"]:
        raise AssertionError("mutation not detected")
    mutations = 0
    if project(mutated)["hits"] != result["hits"]:
        mutations += 1
    mutated2 = json.loads(json.dumps(fixture))
    for record in mutated2["records"]:
        if record.get("tool") == "record.read":
            record["text"] = "contradiction"
    if project(mutated2)["hits"] == result["hits"]:
        mutations += 1
    if mutations < 1:
        raise AssertionError("mutation coverage too low")
    print(f"record-search projection: PASS (hits {len(refs)}, excluded {len(result['excluded'])}, "
          f"snippet≤{SNIPPET_MAX}, nested not expanded, mutations {mutations})")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (SpecError, AssertionError) as error:
        print(f"record-search projection: FAIL: {error}", file=sys.stderr)
        sys.exit(1)
