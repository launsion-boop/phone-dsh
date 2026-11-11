#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Validate the phoneDSH-owned Bot v2 schemas and their shared vectors.

The v2 tree owns memory, wake markers and proactive delivery. Its schema and
golden files were copied byte-for-byte from ``spec/bot/v1`` at the ownership
handover; ``spec/tools/bot/export-vectors.mjs`` no longer writes them. The v1
validator calls :func:`main` as well, so the existing ``phone-spec`` stage
covers both trees without a second CI stage.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(ROOT))

from spec.v1.tools.spec_golden import validate_json  # noqa: E402
from spec.tools.bot.golden_overlay import (  # noqa: E402
    assert_append_only,
    load_json,
    merged_fixture,
)

BOT = ROOT / "spec" / "bot" / "v2"
GOLDEN_GLOB = "*.json"


def load(name: str):
    return load_json(BOT / "golden" / f"{name}.json")


def load_merged(name: str):
    return merged_fixture(load(name), load_json(BOT / "golden" / f"{name}.phone.json"))


def check_overlays() -> None:
    """Every v2 overlay extends its named upstream and never deletes a case."""
    for overlay_path in sorted((BOT / "golden").glob("*.phone.json")):
        overlay = load_json(overlay_path)
        base_name = overlay_path.name[:-len(".phone.json")] + ".json"
        declared = overlay.get("upstream")
        if isinstance(declared, str):
            declared_names = [declared]
        elif isinstance(declared, dict):
            declared_names = list(declared.values())
        elif isinstance(declared, list) and all(isinstance(item, str) for item in declared):
            declared_names = declared
        else:
            raise AssertionError(f"{overlay_path.name}: invalid upstream reference")
        if declared_names != [base_name]:
            raise AssertionError(f"{overlay_path.name}: upstream must be [{base_name!r}]")
        if overlay.get("vector") != overlay_path.name[:-5]:
            raise AssertionError(f"{overlay_path.name}: vector must be {overlay_path.name[:-5]!r}")
        upstream = load(base_name[:-len(".json")])
        if overlay.get("source", {}).get("checkout") != upstream.get("source", {}).get("checkout"):
            raise AssertionError(f"{overlay_path.name}: source.checkout differs from {base_name}")
        assert_append_only(upstream, overlay, overlay_path.name)
        if not merged_fixture(upstream, overlay):
            raise AssertionError(f"{overlay_path.name}: merged fixture is empty")


def schema(name: str):
    return load_json(BOT / name)


def check(instance, schema_name: str, where: str) -> None:
    validate_json(instance, schema(schema_name), where)


def check_many(instances, schema_name: str, where: str) -> None:
    for index, instance in enumerate(instances):
        check(instance, schema_name, f"{where}[{index}]")


def rejects(instance, schema_name: str, where: str) -> None:
    try:
        check(instance, schema_name, where)
    except Exception:
        return
    raise AssertionError(f"{where}: negative fixture unexpectedly validates")



USER_RPC_PREFIXES = ("bot-", "user-action:", "card-answer:")
NON_USER_RPC_PREFIXES = ("held:", "agent:", "routine:", "task-turn:", "task-settled:", "task-interrupted:")
OBSERVATION_TOOLS = frozenset({"web_fetch", "web_search", "Task", "AwaitTask", "StopSubagent"})


def record_parser():
    """Use the v1 reference parser instead of keeping a second grammar."""
    from spec.bot.v1.tools.validate_vectors import parse_record_reference
    return parse_record_reference


def is_user_statement_rpc(rpc_id):
    if rpc_id is None:
        return True
    if not isinstance(rpc_id, str) or not rpc_id:
        return False
    if rpc_id.startswith(NON_USER_RPC_PREFIXES):
        return False
    if rpc_id.startswith(USER_RPC_PREFIXES):
        return True
    return False


def external_source(record):
    if record.get("kind") == "event":
        return record.get("type") in ("conversation.tool_call", "conversation.tool_result") \
            and is_external_tool(record.get("tool"))
    if record.get("type") == "tool/call":
        return is_external_tool(record.get("tool"))
    return False


def is_external_tool(tool):
    if not isinstance(tool, str):
        return False
    if tool in OBSERVATION_TOOLS:
        return True
    if tool.startswith("mcp__phone__android_") or tool.startswith("mcp__phone__ble_"):
        return True
    if tool.startswith("mcp__phone__"):
        return False
    return tool.startswith("mcp__")


def derive_trust(records, refs, caller_bot_id):
    parse = record_parser()
    if not isinstance(refs, list) or len(refs) > 8:
        raise AssertionError("evidence must be a list of at most 8 references")
    trust = "assistant"
    for raw in refs:
        parsed = parse(raw)
        if parsed is None:
            raise AssertionError("malformed reference")
        record = records.get(parsed["canonical"])
        if record is None or record.get("botId") != caller_bot_id:
            raise AssertionError("reference does not exist for this Bot")
        user_record = (
            (record.get("kind") == "session" and record.get("type") == "user/message")
            or (record.get("kind") == "event" and record.get("type") == "conversation.user_message")
        )
        if user_record and is_user_statement_rpc(record.get("rpcId")):
            trust = "user"
        elif external_source(record):
            if trust != "user":
                trust = "observation"
    return trust


def boundary_result(source_kind, trust, scope, tier):
    if source_kind != "user-turn" and (scope == "user" or tier == "profile"):
        return "memory-source-boundary"
    if (scope == "user" or tier == "profile") and trust != "user":
        return "memory-evidence-required"
    return None


def validate_evidence_cases(fact_fixture):
    cases = fact_fixture.get("evidenceCases")
    if not isinstance(cases, dict):
        raise AssertionError("memory-fact.evidenceCases is required")
    records = cases.get("records")
    if not isinstance(records, dict) or not records:
        raise AssertionError("memory-fact.evidenceCases.records is required")
    valid = cases.get("valid")
    invalid = cases.get("invalid")
    boundary = cases.get("boundary")
    if not isinstance(valid, list) or not valid:
        raise AssertionError("memory-fact.evidenceCases.valid is required")
    if not isinstance(invalid, list) or not invalid:
        raise AssertionError("memory-fact.evidenceCases.invalid is required")
    if not isinstance(boundary, list) or not boundary:
        raise AssertionError("memory-fact.evidenceCases.boundary is required")
    for index, case in enumerate(valid):
        try:
            derived = derive_trust(records, case.get("refs"), "bot-a")
        except Exception as exc:
            raise AssertionError(f"evidence.valid[{index}] unexpectedly rejected: {exc}") from exc
        if derived != case.get("trust"):
            raise AssertionError(
                f"evidence.valid[{index}] trust {derived!r} != {case.get('trust')!r}")
        if (derived == "user") != bool(case.get("userBoundary")):
            raise AssertionError(f"evidence.valid[{index}] userBoundary mismatch")
    for index, case in enumerate(invalid):
        try:
            derive_trust(records, case.get("refs"), "bot-a")
        except Exception:
            continue
        raise AssertionError(f"evidence.invalid[{index}] unexpectedly accepted")
    for index, case in enumerate(boundary):
        actual = boundary_result(case.get("sourceKind"), case.get("trust"),
                                 case.get("scope"), case.get("tier"))
        expected = None if case.get("ok") else case.get("error")
        if actual != expected:
            raise AssertionError(
                f"evidence.boundary[{index}] {actual!r} != {expected!r}")
    return len(valid), len(invalid), len(boundary)


def mutation_count_for_evidence(fact_fixture):
    count = 0
    import copy

    def expect_failure(label, action):
        nonlocal count
        try:
            action()
        except Exception:
            count += 1
            return
        raise AssertionError(f"evidence mutation {label!r} unexpectedly passed")

    mutated = copy.deepcopy(fact_fixture)
    for record in mutated["evidenceCases"]["records"].values():
        if record.get("type") == "tool/call" and record.get("tool") == "web_fetch":
            record["botId"] = "bot-b"
    expect_failure("foreign-record", lambda: validate_evidence_cases(mutated))

    mutated = copy.deepcopy(fact_fixture)
    mutated["evidenceCases"]["records"]["record://session/gb-main#4"]["tool"] = "bash"
    expect_failure("observation-downgrade", lambda: validate_evidence_cases(mutated))

    mutated = copy.deepcopy(fact_fixture)
    mutated["evidenceCases"]["boundary"][0]["sourceKind"] = "agent-message"
    expect_failure("boundary", lambda: validate_evidence_cases(mutated))
    return count


def main() -> int:
    check_overlays()

    fact_fixture = load("memory-fact")
    check_many(fact_fixture["valid"], "memory-fact.schema.json", "memory-fact")
    evidence_valid, evidence_invalid, evidence_boundary = validate_evidence_cases(fact_fixture)
    evidence_mutations = mutation_count_for_evidence(fact_fixture)
    check(load("memory-injection")["valid"], "memory-injection.schema.json", "memory-injection")
    recall = load("memory-recall")
    check_many(recall["valid"], "memory-recall.schema.json", "memory-recall")
    check_many(recall["invalid"], "memory-recall.schema.json", "memory-recall.invalid")

    check(load("wake-routine")["valid"], "wake-routine.schema.json", "wake-routine")
    check(load("wake-routine")["valid"]["quietDefer"], "routine.schema.json", "routine")

    held_fixture = load_merged("held-inbox")
    held = held_fixture["valid"]
    check(held["enqueued"]["item"], "held-inbox-item.schema.json", "held-item")
    check(held["deviceTaskResult"], "held-inbox-item.schema.json", "held-device-task-result")
    check(held["agentHeld"], "held-inbox-item.schema.json", "held-agent-held")
    check_many(held["staged"]["items"], "held-inbox-item.schema.json", "held-staged")
    for index, case in enumerate(held_fixture["invalid"]):
        rejects(case, "held-inbox-item.schema.json", f"held.invalid[{index}]")

    print("bot v2 vectors: PASS (memory, wake, routine delivery, held inbox; "
          "schema-positive and negative vectors; "
          f"memory-evidence {evidence_valid} valid / {evidence_invalid} invalid / "
          f"{evidence_boundary} boundary, {evidence_mutations} mutation checks)")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # noqa: BLE001 - one actionable gate line
        print(f"bot v2 vectors: FAIL: {exc}", file=sys.stderr)
        sys.exit(1)
