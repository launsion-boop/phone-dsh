#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Semantic checker for the W0/W2/W3/W4/W7 contract cases.

The envelope and JSON shape are checked by ``plan-cases.schema.json`` with the repository
validator. This tool judges the laws a schema cannot express: a target row must still say
``待基线``; a journal or step record may be pruned only under the frozen conditions; a storage
level follows the five-level table; the append-only formats keep one result copy and an old read
path; the response-log key is recomputed from its preimage; and streaming forwards the first
frame on arrival within the fixed bounds.

Usage:
    python3 spec/v1/tools/plan_cases_check.py [--spec-dir DIR]

Exit 0 on success, 1 on any failure, 2 on a usage or I/O error.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parent
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

from spec_golden import SpecError, load_json, validate_json  # noqa: E402

PLAN_DIR = Path("golden") / "plan"
PLAN_SCHEMA = Path("schema") / "plan-cases.schema.json"
VECTORS = (
    "perf-targets",
    "retention",
    "storage-levels",
    "append-records",
    "response-log-key",
    "streaming",
    "memory-input",
)
BASELINE_PENDING = "待基线"
MIB = 1_048_576
GIB = 1024 * MIB
LEVEL3_RATIO = 0.90
LEVEL2_FLOOR = 512 * MIB
LEVEL2_VOLUME_RATIO = 0.10
LEVEL1_RATIO = 1.3
COALESCE_MAX_BYTES = 4096
COALESCE_MAX_MS = 100
DELTA_MAX_BYTES = 32 * 1024


def fail(errors, where, message):
    errors.append((where, message))


# ---------------------------------------------------------------------------
# Per-vector laws.
# ---------------------------------------------------------------------------


def check_perf_targets(doc, errors) -> None:
    for index, case in enumerate(doc["valid"]):
        where = "valid[{}]".format(index)
        for member in ("metric", "light", "typical", "heavy"):
            if member not in case:
                fail(errors, where, "missing {}".format(member))
        for member in ("light", "typical", "heavy"):
            if case.get(member) != BASELINE_PENDING:
                fail(errors, where, "{} must be {!r}, not a number".format(member, BASELINE_PENDING))
        if case.get("status") != "target":
            fail(errors, where, "status must be target")
    for index, case in enumerate(doc["invalid"]):
        payload = case["case"]
        where = "invalid[{}]".format(index)
        numeric = any(isinstance(payload.get(member), (int, float)) for member in
                      ("light", "typical", "heavy"))
        missing_status = payload.get("status") != "target"
        if not (numeric or missing_status):
            fail(errors, where, "negative case is not a numeric value or a missing target status")


def retention_prunable(case) -> bool:
    if case.get("referenced") is True:
        return False
    if case.get("highWater") is True:
        return False
    if case.get("kind") == "journal":
        return case.get("journaled") is True and case.get("durable") is True
    if case.get("kind") == "step":
        if case.get("terminal") is not True:
            return False
        if case.get("journaled") is True:
            return case.get("durable") is True
        if case.get("abandoned") is True:
            return case.get("abandonedDurable") is True
        return False
    return False


def retention_last_jseq_problem(case) -> str:
    before = case.get("lastJseqBefore")
    after = case.get("lastJseqAfter")
    if isinstance(before, int) and isinstance(after, int) and after < before:
        return "last_jseq_decreased"
    return ""


def check_retention(doc, errors) -> None:
    for index, case in enumerate(doc["valid"]):
        where = "valid[{}]".format(index)
        expected = "prune" if retention_prunable(case) else "keep"
        if case.get("expected") != expected:
            fail(errors, where, "expected {} but the frozen conditions give {}".format(
                case.get("expected"), expected))
        if case.get("kind") not in ("journal", "step"):
            fail(errors, where, "kind must be journal or step")
        problem = retention_last_jseq_problem(case)
        if problem:
            fail(errors, where, problem)
    for index, case in enumerate(doc["invalid"]):
        payload = case["case"]
        where = "invalid[{}]".format(index)
        computed = "prune" if retention_prunable(payload) else "keep"
        problem = retention_last_jseq_problem(payload)
        if case["reason"] == "last_jseq_decreased":
            if problem != "last_jseq_decreased":
                fail(errors, where, "negative case does not decrease lastJseq")
            continue
        if payload.get("expected") == computed:
            fail(errors, where, "negative case does not violate the frozen condition")


def storage_level(case) -> int:
    if case.get("writeWouldFail") is True:
        return 4
    quota = case.get("workspaceQuotaBytes", 0)
    if quota > 0 and case.get("workspaceBytes", 0) >= LEVEL3_RATIO * quota:
        return 3
    available = case.get("availableImportantBytes", 0)
    volume = case.get("volumeBytes", 0)
    if available < max(LEVEL2_FLOOR, LEVEL2_VOLUME_RATIO * volume):
        return 2
    if case.get("internalBytes", 0) > LEVEL1_RATIO * case.get("workspaceBytes", 0):
        return 1
    return 0


def expected_actions(level) -> list:
    actions = []
    if level >= 0:
        actions.append("reclaim_droppable")
    if level >= 1:
        actions.append("prune_caches")
    if level >= 2:
        actions.append("stop_new_caches")
    if level >= 3:
        actions.append("emit_storage_signal")
    if level >= 4:
        actions.append("fail_write")
    return actions


def check_storage_levels(doc, errors) -> None:
    for index, case in enumerate(doc["valid"]):
        where = "valid[{}]".format(index)
        level = storage_level(case)
        if case.get("expectedLevel") != level:
            fail(errors, where, "expectedLevel {} but the table gives {}".format(
                case.get("expectedLevel"), level))
        if case.get("expectedActions") != expected_actions(level):
            fail(errors, where, "actions {} do not match level {}".format(
                case.get("expectedActions"), level))
        surface = case.get("userSurface")
        wanted = "none" if level <= 2 else ("card" if level == 3 else "error")
        if surface != wanted:
            fail(errors, where, "userSurface must be {} at level {}".format(wanted, level))
        for forbidden in case.get("neverDelete", []):
            if forbidden in case.get("deleted", []):
                fail(errors, where, "auto-deletion removed {}".format(forbidden))
    for index, case in enumerate(doc["invalid"]):
        payload = case["case"]
        where = "invalid[{}]".format(index)
        level = storage_level(payload)
        wrong_level = payload.get("expectedLevel") != level
        wrong_surface = payload.get("userSurface") != (
            "none" if level <= 2 else ("card" if level == 3 else "error"))
        bad_delete = bool(set(payload.get("neverDelete", [])) & set(payload.get("deleted", [])))
        if not (wrong_level or wrong_surface or bad_delete):
            fail(errors, where, "negative case does not violate the level table")


def check_append_records(doc, errors) -> None:
    for index, case in enumerate(doc["valid"]):
        where = "valid[{}]".format(index)
        if case.get("format") not in ("exec-ledger", "step-record", "tool-journal"):
            fail(errors, where, "unknown format")
        if case.get("appendOnly") is not True:
            fail(errors, where, "appendOnly must be true")
        if case.get("oldFormatReadable") is not True:
            fail(errors, where, "oldFormatReadable must be true")
        if case.get("resultCopies") not in (0, 1):
            fail(errors, where, "a result is stored at most once")
        if not isinstance(case.get("lines"), list) or not case["lines"]:
            fail(errors, where, "lines must be a non-empty array")
        for line_index, line in enumerate(case["lines"]):
            if not isinstance(line, dict):
                fail(errors, where, "lines[{}] is not an object".format(line_index))
    for index, case in enumerate(doc["invalid"]):
        payload = case["case"]
        where = "invalid[{}]".format(index)
        broken = (
            payload.get("appendOnly") is False
            or payload.get("oldFormatReadable") is False
            or payload.get("resultCopies", 0) > 1
            or payload.get("startAwaited") is False
            or payload.get("rewritesInPlace") is True
        )
        if not broken:
            fail(errors, where, "negative case does not violate an append-only law")


# ---------------------------------------------------------------------------
# Response-log key and streaming laws.
# ---------------------------------------------------------------------------


def canonical_body(body) -> bytes:
    if isinstance(body, str):
        try:
            parsed = json.loads(body)
        except ValueError:
            return body.encode("utf-8")
        return json.dumps(parsed, ensure_ascii=False, sort_keys=True,
                          separators=(",", ":")).encode("utf-8")
    if body is None:
        return b""
    raise SpecError("body must be text or null")


def key_preimage(case) -> bytes:
    selected = sorted(
        (name.lower(), value.strip(" \t"))
        for name, value in case.get("headers", {}).items()
        if name.lower() in {item.lower() for item in case.get("allowList", [])}
    )
    buffer = bytearray()
    buffer += case["method"].upper().encode("ascii") + b"\n"
    buffer += case["url"].split("#", 1)[0].encode("utf-8") + b"\n"
    for name, value in selected:
        buffer += "{}:{}\n".format(name, value).encode("utf-8")
    buffer += b"\n"
    buffer += canonical_body(case.get("body"))
    return bytes(buffer)


def key_for(case) -> str:
    return hashlib.sha256(key_preimage(case)).hexdigest()


def mutated_key(case) -> str:
    mutation = case["mutation"]
    selected = sorted(
        (name.lower(), value.strip(" \t"))
        for name, value in case.get("headers", {}).items()
        if name.lower() in {item.lower() for item in case.get("allowList", [])}
    )
    body = canonical_body(case.get("body"))
    prefix = case["method"].upper().encode("ascii") + b"\n"
    url = case["url"].encode("utf-8") + b"\n"
    suffix = b"\n" + body
    if mutation == "lowercase_method":
        prefix = case["method"].lower().encode("ascii") + b"\n"
    elif mutation == "volatile_header":
        selected = selected + [("authorization", "Bearer secret")]
    elif mutation == "unsorted_headers":
        selected = sorted(selected, reverse=True)
    elif mutation == "no_header_terminator":
        selected = [(name, value) for name, value in selected]
        suffix = b"" + body
    elif mutation == "no_blank_separator":
        suffix = body
    else:
        raise SpecError("unknown mutation " + mutation)
    buffer = bytearray(prefix + url)
    for name, value in selected:
        buffer += "{}:{}\n".format(name, value).encode("utf-8")
    buffer += suffix
    return hashlib.sha256(bytes(buffer)).hexdigest()


def check_response_log_key(doc, errors) -> None:
    for index, case in enumerate(doc["valid"]):
        where = "valid[{}]".format(index)
        try:
            actual = key_for(case)
        except (SpecError, KeyError) as exc:
            fail(errors, where, str(exc))
            continue
        if actual != case.get("expectedKey"):
            fail(errors, where, "key {} does not match the recipe".format(actual))
        if not re.fullmatch(r"[0-9a-f]{64}", case.get("expectedKey", "")):
            fail(errors, where, "key must be 64 lowercase hex")
    for index, case in enumerate(doc["invalid"]):
        payload = case["case"]
        where = "invalid[{}]".format(index)
        try:
            canonical = key_for(dict(payload, mutation="none"))
        except (SpecError, KeyError, TypeError):
            canonical = None
        # The invalid case carries a mutated recipe; a mutation must change the key.
        canonical_case = {key: payload[key] for key in
                          ("method", "url", "headers", "allowList", "body") if key in payload}
        try:
            canonical = key_for(canonical_case)
            mutated = mutated_key(payload)
        except (SpecError, KeyError, TypeError) as exc:
            fail(errors, where, str(exc))
            continue
        if canonical == mutated:
            fail(errors, where, "mutation {} does not change the key".format(payload["mutation"]))


def check_streaming(doc, errors) -> None:
    for index, case in enumerate(doc["valid"]):
        where = "valid[{}]".format(index)
        policy = case.get("policy", {})
        if policy.get("coalesceMaxBytes") != COALESCE_MAX_BYTES:
            fail(errors, where, "coalesceMaxBytes must be {}".format(COALESCE_MAX_BYTES))
        if policy.get("coalesceMaxMs") != COALESCE_MAX_MS:
            fail(errors, where, "coalesceMaxMs must be {}".format(COALESCE_MAX_MS))
        if policy.get("deltaMaxBytes") != DELTA_MAX_BYTES:
            fail(errors, where, "deltaMaxBytes must be {}".format(DELTA_MAX_BYTES))
        frames = case.get("frames", [])
        if not frames:
            fail(errors, where, "frames is empty")
            continue
        first = frames[0]
        if case.get("firstForwardAtMs") != first.get("atMs"):
            fail(errors, where, "the first frame must be forwarded on arrival")
        if case.get("maxBatchBytes", 0) > COALESCE_MAX_BYTES:
            fail(errors, where, "a batch exceeds the coalescing bound")
        if case.get("mergedDeltaBytes", 0) > DELTA_MAX_BYTES:
            fail(errors, where, "a merged delta exceeds the bound")
        if case.get("crossesEventBoundary") is True:
            fail(errors, where, "a batch crosses an event boundary")
    for index, case in enumerate(doc["invalid"]):
        payload = case["case"]
        where = "invalid[{}]".format(index)
        broken = (
            payload.get("coalesceMaxBytes", 0) > COALESCE_MAX_BYTES
            or payload.get("coalesceMaxMs", 0) > COALESCE_MAX_MS
            or payload.get("deltaMaxBytes", 0) > DELTA_MAX_BYTES
            or payload.get("crossesEventBoundary") is True
            or (payload.get("frames") and payload.get("firstForwardAtMs") != payload["frames"][0].get("atMs"))
        )
        if not broken:
            fail(errors, where, "negative case does not violate a streaming bound")


def memory_input_problem(case) -> str:
    """Return the first W2 rev 2 memory-input law the case violates, or ''."""
    if case.get("productionInputs") != ["system-memory-warning"]:
        if not case.get("productionInputs"):
            return "no_production_input"
        return "sampled_heap_not_available"
    sampled = case.get("sampledHeap", {})
    if sampled.get("status") != "target":
        return "sampled_heap_falsely_implemented"
    if sampled.get("producer") != "none":
        return "sampled_heap_not_available"
    if sampled.get("injectionPoint") != "reportEngineHeapBytes":
        return "wrong_injection_point"
    if case.get("actionOrder") != ["clearTmp", "plannedRestart"]:
        return "action_order_changed"
    if case.get("userVisible") is not False:
        return "new_user_prompt"
    if case.get("budgetNumbersChanged") is not False:
        return "budget_number_changed"
    return ""


def check_memory_input(doc, errors) -> None:
    for index, case in enumerate(doc["valid"]):
        where = "valid[{}]".format(index)
        problem = memory_input_problem(case)
        if problem:
            fail(errors, where, problem)
    for index, case in enumerate(doc["invalid"]):
        payload = case["case"]
        where = "invalid[{}]".format(index)
        problem = memory_input_problem(payload)
        if not problem or problem != case["reason"]:
            fail(errors, where, "expected {} but the law gives {!r}".format(
                case["reason"], problem))


CHECKS = {
    "perf-targets": check_perf_targets,
    "retention": check_retention,
    "storage-levels": check_storage_levels,
    "append-records": check_append_records,
    "response-log-key": check_response_log_key,
    "streaming": check_streaming,
    "memory-input": check_memory_input,
}


# ---------------------------------------------------------------------------
# Entry point.
# ---------------------------------------------------------------------------


def run(spec_dir: Path) -> list:
    spec_dir = Path(spec_dir)
    errors = []
    try:
        schema = load_json(spec_dir / PLAN_SCHEMA)
    except SpecError as exc:
        return [("schema/plan-cases.schema.json", str(exc))]
    plan_dir = spec_dir / PLAN_DIR
    paths = sorted(plan_dir.glob("*.json")) if plan_dir.is_dir() else []
    if not paths:
        return [(str(PLAN_DIR), "no plan case file")]
    seen = set()
    for path in paths:
        rel = str(path.relative_to(spec_dir))
        try:
            doc = load_json(path)
        except SpecError as exc:
            errors.append((rel, str(exc)))
            continue
        try:
            validate_json(doc, schema, rel)
        except SpecError as exc:
            errors.append((rel, str(exc)))
            continue
        vector = doc.get("vector")
        if vector not in VECTORS:
            errors.append((rel, "unknown vector {!r}".format(vector)))
            continue
        if vector in seen:
            errors.append((rel, "duplicate vector {!r}".format(vector)))
            continue
        seen.add(vector)
        if path.stem != vector:
            errors.append((rel, "file name must equal the vector name"))
        before = len(errors)
        CHECKS[vector](doc, errors)
        if len(errors) == before:
            errors.append((rel, "ok"))
    for vector in VECTORS:
        if vector not in seen:
            errors.append((str(PLAN_DIR), "missing vector {!r}".format(vector)))
    return errors


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="performance-plan contract case checker")
    parser.add_argument("--spec-dir", type=Path, default=TOOLS_DIR.parent,
                        help="spec/v1 directory (default: the directory containing this script)")
    args = parser.parse_args(argv)
    try:
        errors = run(args.spec_dir.resolve())
    except SpecError as exc:
        print("plan cases: FAIL: {}".format(exc), file=sys.stderr)
        return 2
    failed = [item for item in errors if item[1] != "ok"]
    checked = [item for item in errors if item[1] == "ok"]
    for rel, message in failed:
        print("FAIL {}: {}".format(rel, message))
    for rel, _ in checked:
        print("ok {}".format(rel))
    print("{} plan case file(s) checked, {} error(s)".format(len(checked) + len(failed), len(failed)))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
