#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Validate the phoneDSH-owned Bot v2 schemas and their shared vectors.

v2 owns memory (document tree), wake markers and proactive delivery. The v1
validator calls :func:`main`, so ``phone-spec`` covers both trees in one stage.
The memory reference implementation here mirrors the domain rules frozen in
``spec/bot/v2/README.md``: path grammar, version premise, single author,
evidence/trust, the 1,500-scalar INDEX limit and the one-time fact migration.
The proactive reference evaluator mirrors §3's decision order, fuse accounting,
deliveryKinds filtering, dedupeKey derivation and notification copy; it is
validated by mutations and independently by the Swift vector test.
"""
from __future__ import annotations

import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import quote
from zoneinfo import ZoneInfo

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
INDEX_LIMIT = 1500
INJECTION_TOTAL_LIMIT = 4000
MAX_PATH_SCALARS = 200
MAX_SEGMENT_SCALARS = 64
ROOTS = ("user", "agent")
INDEX_PATHS = ("user/INDEX.md", "agent/INDEX.md")
INBOX_PREFIX = "agent/inbox/"
WRITE_ACTIONS = ("write", "append", "replace", "move", "delete", "restore")
INBOX_ONLY_KINDS = frozenset({"task", "routine", "team", "proactive", "watchdog"})
RECORD_RE = re.compile(r"^record://(session/(?!\.{1,2}#)[A-Za-z0-9._-]{1,64}#(0|[1-9][0-9]*)|event/[1-9][0-9]*)$")
CURRENT_USER_TURN_EVIDENCE = "current-user-turn"

# Proactive settings/decision reference rules (spec/bot/v2/README.md §3).
PROACTIVE_SETTINGS_FIELDS = (
    "mode", "dnd", "quietStart", "quietEnd", "routineQuietWeekends", "timeZone",
    "fuseWindowMs", "fuseMaxWakeups", "deliveryKinds",
)
PROACTIVE_MODES = ("off", "would", "on")
PROACTIVE_KINDS = ("task-done", "routine-result", "reminder")
PROACTIVE_DECISIONS = ("did", "would", "skip")
PROACTIVE_REASONS = (
    "delivered", "would-mode", "would-only-kind", "mode-off", "fuse", "dnd",
    "quiet-hours", "missing-bot", "delivery-failed", "delivery-unavailable",
    "routine-held", "routine-quiet",
)
PROACTIVE_CANDIDATE_FIELDS = (
    "id", "kind", "botId", "dedupeKey", "trigger", "sourceEventId", "createdAt",
    "channel", "title", "body", "taskId", "taskTitle", "summary", "status",
    "routineId", "runId", "attempt", "delivery", "quiet", "resultExcerpt",
    "deliveryKey", "rowId", "reminderId", "allowDuringDnd",
)
PROACTIVE_CANDIDATE_REQUIRED = ("kind", "botId", "createdAt")
PROACTIVE_CLOCK_PATTERN = r"^\s*(\+?[0-9]|0[0-9]|1[0-9]|2[0-3]):[0-5][0-9]\s*$"
PROACTIVE_CLOCK_RE = re.compile(PROACTIVE_CLOCK_PATTERN)



def load(name: str):
    return load_json(BOT / "golden" / f"{name}.json")


def schema(name: str):
    return load_json(BOT / name)


def check(instance, schema_name: str, where: str) -> None:
    validate_json(instance, schema(schema_name), where)


def check_many(instances, schema_name: str, where: str) -> None:
    for index, instance in enumerate(instances):
        check(instance, schema_name, f"{where}[{index}]")


def check_schema(instance, schema_object: dict, where: str) -> None:
    validate_json(instance, schema_object, where)


def rejects_schema(instance, schema_object: dict, where: str) -> None:
    try:
        check_schema(instance, schema_object, where)
    except Exception:
        return
    raise AssertionError(f"{where}: negative fixture unexpectedly validates")


def rejects(instance, schema_name: str, where: str) -> None:
    try:
        check(instance, schema_name, where)
    except Exception:
        return
    raise AssertionError(f"{where}: negative fixture unexpectedly validates")


def check_overlays() -> None:
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


# ── memory path / version / permission reference ───────────────────────────


def parse_path(path, allow_root: bool = False):
    if not isinstance(path, str) or not path:
        return None
    if len(path) > MAX_PATH_SCALARS or path.startswith("/") or path.endswith("/"):
        return None
    parts = path.split("/")
    if parts[0] not in ROOTS:
        return None
    if len(parts) == 1:
        return parts if allow_root else None
    for segment in parts:
        if not segment or segment in (".", ".."):
            return None
        if len(segment) > MAX_SEGMENT_SCALARS:
            return None
        if segment != segment.strip():
            return None
        if any(ord(ch) < 0x20 or ord(ch) == 0x7F or ch in "\\" for ch in segment):
            return None
    return parts


def scope_of(path):
    parsed = parse_path(path, allow_root=True)
    return parsed[0] if parsed else None


def is_index(path):
    return path in INDEX_PATHS


def inbox_prefix(session_id):
    return f"{INBOX_PREFIX}{session_id}/"


def permission_error(author, path):
    kind = author.get("kind")
    session_id = author.get("session_id")
    if kind not in ("chat", "ui", "migration", "system") and kind in INBOX_ONLY_KINDS:
        if not isinstance(session_id, str) or not session_id:
            return "memory-scope-denied"
        prefix = inbox_prefix(session_id)
        if not (path.startswith(prefix) and len(path) > len(prefix)):
            return "memory-scope-denied"
    if kind == "migration" and scope_of(path) == "user":
        return None
    return None


def boundary_error(source_kind, trust, path):
    if scope_of(path) != "user":
        return None
    if source_kind == "maintenance":
        # The maintainer has no user turn; its user/ boundary is the evidence.
        return None if trust == "user" else "memory-evidence-required"
    if source_kind != "user-turn":
        return "memory-source-boundary"
    if trust != "user":
        return "memory-evidence-required"
    return None


def state_current_version(state, path):
    for document in state.get("documents", []):
        if document.get("path") == path:
            return document.get("version", 0)
    return 0


def state_document(state, path):
    for document in state.get("documents", []):
        if document.get("path") == path:
            return document
    return None


def state_history(state, path):
    return state.get("history", {}).get(path, [])


def result_for_case(case):
    request = case["request"]
    author = case["author"]
    state = case.get("state", {})
    action = request.get("action")
    path = request.get("path")
    to = request.get("to")

    if parse_path(path) is None:
        return {"ok": False, "code": "memory-path-invalid", "error": "invalid path"}
    if action == "move" and parse_path(to) is None:
        return {"ok": False, "code": "memory-path-invalid", "error": "invalid destination"}

    permission = permission_error(author, path)
    if permission:
        return {"ok": False, "code": permission, "error": "path not allowed for this session"}
    if action == "move":
        destination_permission = permission_error(author, to)
        if destination_permission:
            return {"ok": False, "code": destination_permission, "error": "destination not allowed"}

    boundary = boundary_error(case.get("sourceKind"), case.get("trust"), path)
    if boundary:
        return {"ok": False, "code": boundary, "error": "source boundary"}
    if action == "move":
        destination_boundary = boundary_error(case.get("sourceKind"), case.get("trust"), to)
        if destination_boundary:
            return {"ok": False, "code": destination_boundary, "error": "source boundary"}

    current = state_current_version(state, path)
    expected = request.get("expected_version")
    if expected != current:
        return {
            "ok": False,
            "code": "memory-version-conflict",
            "error": "version conflict",
            "current_version": current,
        }

    document = state_document(state, path)
    if action in ("append", "replace", "delete") and document is None:
        return {"ok": False, "code": "memory-not-found", "error": "document is missing"}
    if action == "move":
        if document is None:
            return {"ok": False, "code": "memory-not-found", "error": "document is missing"}
        if state_document(state, to) is not None:
            return {"ok": False, "code": "memory-path-exists", "error": "destination exists"}
    if action == "restore":
        versions = {entry.get("version"): entry for entry in state_history(state, path)}
        source = versions.get(request.get("restore_version"))
        if source is None or source.get("deleted"):
            return {"ok": False, "code": "memory-version-not-found", "error": "version missing"}
        content = source.get("content") or ""
    elif action == "write":
        content = request.get("content", "")
    elif action == "append":
        content = (document.get("content") or "") + request.get("content", "")
    elif action == "replace":
        find = request.get("find", "")
        if find not in (document.get("content") or ""):
            return {"ok": False, "code": "memory-replace-not-found", "error": "text missing"}
        content = (document.get("content") or "").replace(find, request.get("replace", ""))
    elif action == "delete":
        content = ""
    elif action == "move":
        content = document.get("content") or ""
    else:
        raise AssertionError(f"unknown action {action!r}")

    if action != "delete" and is_index(path) and len(content) > INDEX_LIMIT:
        return {
            "ok": False,
            "code": "memory-index-too-long",
            "error": "index over limit",
            "limit": INDEX_LIMIT,
            "actual": len(content),
        }
    target_path = to if action == "move" else path
    target_version = 1 if action == "move" else current + 1
    result = {
        "ok": True,
        "action": action,
        "path": target_path,
        "scope": scope_of(target_path),
        "version": target_version,
        "previous_version": current,
    }
    if action == "replace":
        result["replaced"] = (document.get("content") or "").count(request.get("find", ""))
    return result


def validate_write_vectors(fixture=None) -> tuple[int, int, int, int]:
    fixture = fixture if fixture is not None else load("memory-write")
    records = fixture["records"]
    evidence = fixture["evidenceCases"]
    for index, case in enumerate(evidence["valid"]):
        try:
            trust = derive_trust(
                records, case.get("refs"), "bot-a",
                current_user_turn_ref=case.get("currentUserTurn"),
                turn=case.get("turn", "user-turn"))
        except Exception as exc:  # noqa: BLE001 - one actionable line
            raise AssertionError(f"evidence.valid[{index}] unexpectedly rejected: {exc}") from exc
        if trust != case.get("trust"):
            raise AssertionError(f"evidence.valid[{index}] trust {trust!r} != {case.get('trust')!r}")
        if (trust == "user") != bool(case.get("userBoundary")):
            raise AssertionError(f"evidence.valid[{index}] userBoundary mismatch")
    for index, case in enumerate(evidence["invalid"]):
        try:
            derive_trust(
                records, case.get("refs"), "bot-a",
                current_user_turn_ref=case.get("currentUserTurn"),
                turn=case.get("turn", "user-turn"))
        except Exception:
            continue
        raise AssertionError(f"evidence.invalid[{index}] unexpectedly accepted")
    for index, value in enumerate([
        "current_user_turn", "current-user-turn ", "CURRENT-USER-TURN",
        "current-user-turn\n", "record://session/gb-main#3 current-user-turn",
    ]):
        rejects(
            {"action": "write", "path": "user/preferences/drinks.md",
             "content": "x", "expected_version": 0, "evidence": [value]},
            "memory-write-request.schema.json",
            f"write.evidenceReservedInvalid[{index}]")
    for index, case in enumerate(fixture["boundaryCases"]):
        actual = boundary_error(case.get("sourceKind"), case.get("trust"), case.get("path"))
        permission = permission_error(
            {"kind": case.get("sourceKind"), "session_id": case.get("sessionId")},
            case.get("path"))
        actual = actual or permission
        expected = None if case.get("ok") else case.get("error")
        if actual != expected:
            raise AssertionError(f"boundaryCases[{index}] {actual!r} != {expected!r}")
    for index, case in enumerate(fixture["cases"]):
        check(case["request"], "memory-write-request.schema.json", f"write.cases[{index}].request")
        actual = result_for_case(case)
        check(actual, "memory-write-result.schema.json", f"write.cases[{index}].result")
        expected = case["expect"]
        for key, value in expected.items():
            if actual.get(key) != value:
                raise AssertionError(
                    f"write.cases[{index}] {case['name']}.{key} {actual.get(key)!r} != {value!r}")
    for index, case in enumerate(fixture.get("visibilityCases", [])):
        reader = case["reader"]
        visible = sorted(
            document["path"] for document in case["documents"]
            if scope_of(document["path"]) == "user" or document.get("botId") == reader)
        if visible != case["visible"]:
            raise AssertionError(
                f"visibilityCases[{index}] {case['name']} {visible!r} != {case['visible']!r}")
    return (len(evidence["valid"]), len(evidence["invalid"]),
            len(fixture["boundaryCases"]), len(fixture["cases"]))


def mutation_count_for_evidence() -> int:
    """Mutate the shared write vectors and require each validation to fail.

    These are the S1 checks ported to the document model: a foreign record, a
    downgraded observation source and a boundary case must each make the
    fixture-invariant validation fail instead of silently passing.
    """
    import copy

    count = 0

    def expect_failure(label, action):
        nonlocal count
        try:
            action()
        except Exception:
            count += 1
            return
        raise AssertionError(f"evidence mutation {label!r} unexpectedly passed")

    mutated = copy.deepcopy(load("memory-write"))
    for record in mutated["records"].values():
        if record.get("type") == "tool/call" and record.get("tool") == "web_fetch":
            record["botId"] = "bot-b"
    expect_failure("foreign-record", lambda: validate_write_vectors(mutated))

    mutated = copy.deepcopy(load("memory-write"))
    mutated["records"]["record://session/gb-main#4"]["tool"] = "bash"
    expect_failure("observation-downgrade", lambda: validate_write_vectors(mutated))

    mutated = copy.deepcopy(load("memory-write"))
    mutated["boundaryCases"][0]["sourceKind"] = "agent-message"
    expect_failure("boundary", lambda: validate_write_vectors(mutated))

    mutated = copy.deepcopy(load("memory-write"))
    for case in mutated["evidenceCases"]["valid"]:
        if case.get("name") == "current-user-turn":
            case["turn"] = "hidden"
    expect_failure("current-user-turn-hidden", lambda: validate_write_vectors(mutated))

    mutated = copy.deepcopy(load("memory-write"))
    for case in mutated["evidenceCases"]["valid"]:
        if case.get("name") == "current-user-turn":
            case["currentUserTurn"] = "record://event/99"
    expect_failure("current-user-turn-unresolved", lambda: validate_write_vectors(mutated))
    return count


# ── evidence trust reference (same rules as v1 §4.2 / v2 §1.5) ─────────────

USER_RPC_PREFIXES = ("bot-", "user-action:", "card-answer:")
NON_USER_RPC_PREFIXES = ("held:", "agent:", "routine:", "task-turn:", "task-settled:", "task-interrupted:")
OBSERVATION_TOOLS = frozenset({"web_fetch", "web_search", "Task", "AwaitTask", "StopSubagent"})


def record_parser():
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


def external_source(record):
    if record.get("kind") == "event":
        # S5's durable device-task terminal record is the verifiable
        # observation record named by the trust table; its ack stays assistant.
        if record.get("type") == "comm.inbound" and isinstance(record.get("deviceTaskResult"), dict):
            return True
        return record.get("type") in ("conversation.tool_call", "conversation.tool_result") \
            and is_external_tool(record.get("tool"))
    if record.get("type") == "tool/call":
        return is_external_tool(record.get("tool"))
    return False


def resolve_evidence_refs(refs, current_user_turn_ref=None, turn="user-turn"):
    """Resolve the reserved current-turn value to a host-owned reference.

    The reference implementation mirrors the host rule: the reserved literal is
    valid only in a real user turn, and its target is chosen by the host, never
    by the model. Every resolved reference still goes through the normal
    existence/ownership/trust checks in :func:`derive_trust`.
    """
    parse = record_parser()
    if not isinstance(refs, list) or len(refs) > 8:
        raise AssertionError("evidence must be a list of at most 8 references")
    resolved = []
    for raw in refs:
        if raw == CURRENT_USER_TURN_EVIDENCE:
            if turn != "user-turn" or not isinstance(current_user_turn_ref, str):
                raise AssertionError("current-user-turn is unavailable in this turn")
            parsed = parse(current_user_turn_ref)
            if parsed is None:
                raise AssertionError("host current-turn reference is malformed")
            resolved.append(parsed["canonical"])
            continue
        parsed = parse(raw)
        if parsed is None:
            raise AssertionError("malformed reference")
        resolved.append(parsed["canonical"])
    return resolved


def derive_trust(records, refs, caller_bot_id, current_user_turn_ref=None,
                 turn="user-turn"):
    trust = "assistant"
    for canonical in resolve_evidence_refs(refs, current_user_turn_ref, turn):
        record = records.get(canonical)
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


# ── document / read / recall ───────────────────────────────────────────────


def validate_document_vectors() -> int:
    fixture = load("memory-document")
    check_many(fixture["valid"], "memory-document.schema.json", "memory-document")
    for index, case in enumerate(fixture["invalid"]):
        rejects(case["document"], "memory-document.schema.json",
                f"memory-document.invalid[{index}]")
    return len(fixture["valid"]) + len(fixture["invalid"])


def directory_entries(state, path):
    prefix = path + "/"
    entries = {}
    for document in state.get("documents", []):
        document_path = document.get("path", "")
        if not document_path.startswith(prefix):
            continue
        remainder = document_path[len(prefix):]
        head, separator, _tail = remainder.partition("/")
        child = prefix + head
        if separator:
            entries[child] = {"path": child, "name": head, "kind": "directory"}
        else:
            entries[child] = {
                "path": child,
                "name": head,
                "kind": "document",
                "version": document.get("version"),
                "updated_at_ms": document.get("updated_at_ms"),
            }
    return [entries[key] for key in sorted(entries)]


def read_result(case):
    state = case["state"] if "state" in case else None
    request = case["request"]
    if state is None:
        return {"ok": False, "code": "memory-not-found", "error": "not found"}
    path = request.get("path")
    if parse_path(path, allow_root=True) is None:
        return {"ok": False, "code": "memory-path-invalid", "error": "invalid path"}
    if "version" in request:
        entry = next(
            (item for item in state.get("history", {}).get(path, [])
             if item.get("version") == request["version"]),
            None,
        )
        if entry is None:
            return {"ok": False, "code": "memory-version-not-found", "error": "version missing"}
        live = state_document(state, path)
        author = live.get("author") if live else {"kind": "migration"}
        evidence = live.get("evidence", []) if live else []
        result = {
            "ok": True,
            "kind": "document",
            "path": path,
            "scope": scope_of(path),
            "version": entry["version"],
            "content": entry.get("content") or "",
            "updated_at_ms": live.get("updated_at_ms", 0) if live else 0,
            "author": author,
            "evidence": evidence,
        }
        if entry.get("deleted"):
            result["deleted"] = True
            result["deletion_reason"] = entry.get("deletion_reason", "forget")
        return result
    document = state_document(state, path)
    if document is not None:
        return {
            "ok": True,
            "kind": "document",
            "path": path,
            "scope": document["scope"],
            "version": document["version"],
            "content": document["content"],
            "updated_at_ms": document["updated_at_ms"],
            "author": document["author"],
            "evidence": document.get("evidence", []),
            **({"trust": document["trust"]} if "trust" in document else {}),
        }
    entries = directory_entries(state, path)
    if entries or path in ROOTS:
        return {
            "ok": True,
            "kind": "directory",
            "path": path,
            "scope": scope_of(path),
            "entries": entries,
        }
    return {"ok": False, "code": "memory-not-found", "error": "not found"}


def validate_read_vectors() -> int:
    fixture = load("memory-read")
    state = fixture["state"]
    for document in state["documents"]:
        check(document, "memory-document.schema.json", "memory-read.state")
    for index, case in enumerate(fixture["cases"]):
        case_state = dict(state)
        case["state"] = case_state
        actual = read_result(case)
        check(actual, "memory-read-result.schema.json", f"memory-read.cases[{index}]")
        expected = case["expect"]
        if actual.get("ok") != expected.get("ok"):
            raise AssertionError(f"memory-read.cases[{index}] ok mismatch: {actual!r}")
        if expected.get("ok"):
            if actual.get("kind") != expected.get("kind"):
                raise AssertionError(f"memory-read.cases[{index}] kind mismatch")
            if "version" in expected and actual.get("version") != expected["version"]:
                raise AssertionError(f"memory-read.cases[{index}] version mismatch")
            if "contentContains" in expected and expected["contentContains"] not in actual.get("content", ""):
                raise AssertionError(f"memory-read.cases[{index}] content missing")
            if "contentExcludes" in expected and expected["contentExcludes"] in actual.get("content", ""):
                raise AssertionError(f"memory-read.cases[{index}] content unexpectedly present")
            if expected.get("deleted") is not None and actual.get("deleted") != expected["deleted"]:
                raise AssertionError(f"memory-read.cases[{index}] deleted mismatch")
            if "entries" in expected:
                paths = [entry["path"] for entry in actual.get("entries", [])]
                if paths != expected["entries"]:
                    raise AssertionError(
                        f"memory-read.cases[{index}] entries {paths!r} != {expected['entries']!r}")
        elif actual.get("code") != expected.get("code"):
            raise AssertionError(f"memory-read.cases[{index}] code mismatch")
    return len(fixture["cases"])


def validate_recall_vectors() -> int:
    fixture = load("memory-recall")
    check_many(fixture["hits"], "memory-recall.schema.json", "memory-recall.hits")
    for index, case in enumerate(fixture["invalid"]):
        rejects(case["hit"], "memory-recall.schema.json", f"memory-recall.invalid[{index}]")
    live_paths = {document["path"] for document in fixture["documents"]}
    for index, query in enumerate(fixture["queries"]):
        for path in query.get("expectedPaths", []):
            if path not in live_paths:
                raise AssertionError(f"recall.queries[{index}] expects unknown path {path!r}")
        if query.get("scope") not in ("agent", "user", "all"):
            raise AssertionError(f"recall.queries[{index}] invalid scope")
        if not (1 <= query.get("limit", 0) <= 50):
            raise AssertionError(f"recall.queries[{index}] invalid limit")
    return len(fixture["hits"]) + len(fixture["invalid"])


# ── injection ──────────────────────────────────────────────────────────────

HEADER_MARKERS = ("## 记忆", "`user/`", "`agent/`", "可以不记", "ReadMemory", "RecallMemory")


def validate_injection_vectors() -> int:
    fixture = load("memory-injection")
    for key in ("valid", "emptyIndex"):
        value = fixture[key]
        check(value, "memory-injection.schema.json", f"memory-injection.{key}")
        for marker in HEADER_MARKERS:
            if marker not in value["text"]:
                raise AssertionError(f"memory-injection.{key}: missing {marker!r}")
        if "user/INDEX.md" not in value["text"] or "agent/INDEX.md" not in value["text"]:
            raise AssertionError(f"memory-injection.{key}: index paths missing")
        if value["text"].count("### user/INDEX.md") != 1 or value["text"].count("### agent/INDEX.md") != 1:
            raise AssertionError(f"memory-injection.{key}: only the two root indexes may be injected")
    if fixture["valid"]["text"].count(fixture["indexes"]["user"]["content"]) != 1:
        raise AssertionError("memory-injection.valid: user index content missing")
    if fixture["valid"]["text"].count(fixture["indexes"]["agent"]["content"]) != 1:
        raise AssertionError("memory-injection.valid: agent index content missing")
    for index, case in enumerate(fixture["invalid"]):
        rejects(case["value"], "memory-injection.schema.json", f"memory-injection.invalid[{index}]")
    return 2 + len(fixture["invalid"])


# ── migration ──────────────────────────────────────────────────────────────


def sanitized_slug(key):
    text = (key or "").strip().lower()
    text = re.sub(r"[^a-z0-9._-]+", "-", text)
    text = re.sub(r"-{2,}", "-", text).strip("-._")
    return text or "note"


def fact_month(ms):
    return datetime.fromtimestamp(ms / 1000, timezone.utc).strftime("%Y-%m")


def migration_target(fact):
    scope = fact["scope"]
    tier = fact["tier"]
    if tier == "profile":
        return f"{scope}/profile.md"
    if tier == "note":
        return f"{scope}/notes/{sanitized_slug(fact.get('key'))}.md"
    if tier == "log":
        return f"{scope}/log/{fact_month(fact['learned_at_ms'])}.md"
    raise AssertionError(f"unknown legacy tier {tier!r}")


def migrate(bot_id, facts):
    sources = [
        fact for fact in facts
        if fact.get("owner") in (bot_id, "shared")
        and (fact.get("owner") != "shared" or fact.get("scope") == "user")
    ]
    documents = {}
    evidence = {}
    for fact in sorted(sources, key=lambda item: (item["learned_at_ms"], item["fact_id"])):
        path = migration_target(fact)
        if path in documents:
            documents[path] += "\n- " + fact["text"]
        elif fact["tier"] == "profile":
            documents[path] = "# Profile\n\n- " + fact["text"]
        elif fact["tier"] == "note":
            documents[path] = f"# {fact.get('key')}\n\n- " + fact["text"]
        elif fact["tier"] == "log":
            documents[path] = f"# {fact_month(fact['learned_at_ms'])}\n\n- " + fact["text"]
        if fact.get("evidence"):
            evidence[path] = sorted(set(fact["evidence"]))[:8]
    for scope in ROOTS:
        index_path = f"{scope}/INDEX.md"
        paths = sorted(path for path in documents if path.startswith(scope + "/"))
        if not paths:
            continue
        documents[index_path] = "# Index\n\n" + "\n".join(f"- {path}" for path in paths)
    if not documents:
        for scope in ROOTS:
            documents[f"{scope}/INDEX.md"] = "# Index"
    return documents, evidence


def validate_migration_vectors() -> int:
    fixture = load("memory-migration")
    for bot_id in fixture["bots"]:
        documents, evidence = migrate(bot_id, fixture["facts"])
        expected = fixture["expected"][bot_id]
        if documents != expected["documents"]:
            missing = set(expected["documents"]) - set(documents)
            extra = set(documents) - set(expected["documents"])
            changed = [
                path for path in set(documents) & set(expected["documents"])
                if documents[path] != expected["documents"][path]
            ]
            raise AssertionError(
                f"migration[{bot_id}] documents differ: missing={sorted(missing)} "
                f"extra={sorted(extra)} changed={sorted(changed)}")
        if evidence != expected["evidence"]:
            raise AssertionError(f"migration[{bot_id}] evidence differs: {evidence!r}")
        for path in documents:
            if path.endswith("INDEX.md"):
                if len(documents[path]) > INDEX_LIMIT:
                    raise AssertionError(f"migration[{bot_id}] index {path} over limit")
            if parse_path(path) is None:
                raise AssertionError(f"migration[{bot_id}] invalid path {path!r}")
        for fact in fixture["facts"]:
            if fact.get("owner") not in (bot_id, "shared"):
                continue
            if fact.get("owner") == "shared" and fact.get("scope") != "user":
                continue
            if not any(fact["text"] in content for content in documents.values()):
                raise AssertionError(f"migration[{bot_id}] lost fact ${fact['fact_id']}")
        again, _ = migrate(bot_id, fixture["facts"])
        if again != documents:
            raise AssertionError(f"migration[{bot_id}] is not idempotent")
    return len(fixture["bots"])


# ── physical memory erasure (S6) ──────────────────────────────────────────


def erasure_needles(content):
    result = set()
    stripped = content.strip()
    if len(stripped) >= 8:
        result.add(stripped)
    for line in content.split("\n"):
        value = line.strip()
        if len(value) >= 8:
            result.add(value)
    separators = set(",;:!?()[]{}<>\"'")
    for token in re.split(r"[\s" + re.escape("".join(separators)) + r"]+", content):
        if len(token) >= 8 and ("_" in token or any(ch.isdigit() for ch in token)):
            result.add(token)
    return result


def erasure_plan(case):
    target = case.get("target") or {}
    scope = target.get("scope")
    path = target.get("path")
    if scope not in ROOTS:
        return None, "memory-path-invalid"
    if path is not None:
        if parse_path(path) is None or scope_of(path) != scope:
            return None, "memory-path-invalid"
    bot_id = case.get("botID", "main")
    state = case.get("state", {})
    documents = state.get("documents", [])
    selected = []
    for document in documents:
        if document.get("scope") != scope:
            continue
        if scope == "agent" and document.get("botId") != bot_id:
            continue
        if path is not None and document.get("path") != path:
            continue
        selected.append(document)
    paths = sorted({document["path"] for document in selected})
    needles = set()
    for document in selected:
        for version in document.get("versions", []):
            if not version.get("deleted"):
                needles |= erasure_needles(version.get("content") or "")
    events = state.get("events", [])
    erased = set()
    for event in events:
        if event.get("botId") not in (None, bot_id) and scope != "user":
            continue
        if event.get("path") in paths and str(event.get("type", "")).startswith("memory."):
            erased.add(event["seq"])
        text = event.get("text")
        if isinstance(text, str) and any(needle in text for needle in needles):
            erased.add(event["seq"])
    erased_refs = {f"record://event/{seq}" for seq in erased}
    if erased_refs:
        for event in events:
            if event.get("seq") in erased:
                continue
            if str(event.get("type", "")).startswith("memory."):
                continue
            if event.get("botId") not in (None, bot_id) and scope != "user":
                continue
            if erased_refs.intersection(event.get("refs", [])):
                erased.add(event["seq"])
    path_bots = {}
    for document in documents:
        key = (document.get("path"), document.get("scope"))
        path_bots.setdefault(key, set()).add(document.get("botId"))
    surviving = []
    for document in documents:
        if document in selected:
            continue
        marker = document["path"]
        if document.get("scope") == "agent" and len(path_bots[(document["path"], "agent")]) > 1:
            marker += "#" + str(document.get("botId"))
        surviving.append(marker)
    uncovered = set()
    for document in selected:
        for raw in document.get("evidence", []):
            if raw.startswith("record://session/"):
                uncovered.add(raw)
    live = sum(1 for document in selected if document.get("live"))
    versions = sum(len(document.get("versions", [])) for document in selected)
    return {
        "ok": True,
        "scope": scope,
        "paths": paths,
        "removedDocuments": live,
        "removedVersions": versions,
        "erasedEvents": sorted(erased),
        "survivingPaths": sorted(surviving),
        "uncoveredRecords": sorted(uncovered),
        "legacyFactIDs": [],
    }, None


def validate_erasure_vectors() -> tuple[int, int, int]:
    fixture = load("memory-erasure")
    if fixture.get("vector") != "memory-erasure":
        raise AssertionError("memory-erasure: vector must be memory-erasure")
    if fixture.get("upstream") != []:
        raise AssertionError("memory-erasure: phone-only vector must declare upstream: []")
    cases = fixture.get("cases")
    invalid = fixture.get("invalid")
    if not isinstance(cases, list) or not cases:
        raise AssertionError("memory-erasure: cases must be non-empty")
    if not isinstance(invalid, list) or not invalid:
        raise AssertionError("memory-erasure: invalid must be non-empty")
    for index, case in enumerate(cases):
        plan, error = erasure_plan(case)
        if error is not None:
            raise AssertionError(f"memory-erasure.cases[{index}] {case.get('name')}: {error}")
        expect = case["expect"]
        for key, value in expect.items():
            if plan.get(key) != value:
                raise AssertionError(
                    f"memory-erasure.cases[{index}] {case.get('name')}.{key} "
                    f"{plan.get(key)!r} != {value!r}")
    for index, case in enumerate(invalid):
        plan, error = erasure_plan(case)
        if plan is not None or error != case.get("error"):
            raise AssertionError(
                f"memory-erasure.invalid[{index}] {case.get('name')}: "
                f"{error!r} != {case.get('error')!r}")

    mutations = 0

    def expect_failure(label, mutate):
        nonlocal mutations
        mutated = json.loads(json.dumps(fixture))
        mutate(mutated)
        try:
            validate_erasure_vectors_from(mutated)
        except AssertionError:
            mutations += 1
            return
        raise AssertionError(f"memory-erasure mutation {label!r} unexpectedly passed")

    expect_failure("version-count",
                   lambda value: value["cases"][0]["expect"].__setitem__("removedVersions", 1))
    expect_failure("agent-isolation",
                   lambda value: value["cases"][1].__setitem__("botID", "bot-b"))
    expect_failure("uncovered-session",
                   lambda value: value["cases"][0]["expect"].__setitem__("uncoveredRecords", []))
    return len(cases), len(invalid), mutations


def validate_erasure_vectors_from(fixture) -> None:
    """Same body as validate_erasure_vectors without the mutation recursion."""
    cases = fixture["cases"]
    for case in cases:
        plan, error = erasure_plan(case)
        if error is not None:
            raise AssertionError(f"{case.get('name')}: {error}")
        for key, value in case["expect"].items():
            if plan.get(key) != value:
                raise AssertionError(f"{case.get('name')}.{key} {plan.get(key)!r} != {value!r}")
    for case in fixture["invalid"]:
        plan, error = erasure_plan(case)
        if plan is not None or error != case.get("error"):
            raise AssertionError(f"{case.get('name')}: {error!r} != {case.get('error')!r}")


# ── maintenance (S3: host-only batch checks) ──────────────────────────────

MAINTENANCE_MAX_CANDIDATES = 12
MAINTENANCE_MAX_CHANGED_DOCUMENTS = 12
MAINTENANCE_MAX_CHANGED_SCALARS = 24_000
MAINTENANCE_INDEX_TRIGGER = 1_350
INDEX_LIMIT_SCALARS = INDEX_LIMIT


def scalar_count(text):
    return len(text)


def maintenance_check(case):
    """Reference implementation of the four host-only batch checks.

    Returns the failure code, or ``None`` when every check passes. The order is
    the one in ``spec/bot/v2/README.md`` §4.4 and the same order the Swift
    controller uses, so one shared vector can drive both ends.
    """
    records = case.get("records", {})
    bot_id = case.get("botId")
    is_main_bot = case.get("isMainBot", True)
    for document in case.get("documents", []):
        path = document["path"]
        evidence = document.get("evidence", [])
        parsed = []
        for raw in evidence:
            parsed_ref = record_parser()(raw)
            if parsed_ref is None:
                return "maintenance-evidence-unresolved"
            record = records.get(parsed_ref["canonical"])
            if record is None or record.get("botId") != bot_id:
                return "maintenance-evidence-unresolved"
            parsed.append((parsed_ref, record))
        if scope_of(path) == "user":
            if not is_main_bot:
                return "memory-scope-denied"
            if not any(record.get("trust") == "user" for _, record in parsed):
                return "memory-evidence-required"
        if is_index(path):
            actual = case.get("indexOverrides", {}).get(path, scalar_count(document.get("content", "")))
            if actual > INDEX_LIMIT_SCALARS:
                return "maintenance-index-too-long"
        if evidence:
            original = sum(scalar_count(record.get("text", "")) for _, record in parsed)
            if scalar_count(document.get("content", "")) > original:
                return "maintenance-document-longer-than-evidence"
    if (case.get("changedDocuments", 0) > MAINTENANCE_MAX_CHANGED_DOCUMENTS
            or case.get("changedScalars", 0) > MAINTENANCE_MAX_CHANGED_SCALARS):
        return "maintenance-change-budget-exceeded"
    return None


def validate_maintenance_vectors(fixture=None) -> tuple[int, int, int]:
    fixture = fixture if fixture is not None else load("memory-maintenance")
    start = fixture["valid"]["start"]
    for name in ("committed", "cancelled", "rolledBack"):
        check(fixture["valid"][name], "memory-maintenance.schema.json",
              f"maintenance.valid.{name}")
    check(start, "memory-maintenance-start.schema.json", "maintenance.valid.start")
    check(fixture["valid"]["rollback"], "memory-maintenance-rollback.schema.json",
          "maintenance.valid.rollback")

    schema_by_case = {
        "startTooManyCandidates": "memory-maintenance-start.schema.json",
        "startUnknownTrigger": "memory-maintenance-start.schema.json",
        "startWrongSessionKind": "memory-maintenance-start.schema.json",
        "finishedRunningStatus": "memory-maintenance.schema.json",
        "finishedMissingCheck": "memory-maintenance.schema.json",
        "finishedUnknownFailure": "memory-maintenance.schema.json",
        "rollbackEmptyBatch": "memory-maintenance-rollback.schema.json",
    }
    for name, case in fixture["invalid"].items():
        rejects(case, schema_by_case[name], f"maintenance.invalid.{name}")

    for index, case in enumerate(fixture["checkCases"]):
        actual = maintenance_check(case)
        if actual != case["expected"]:
            raise AssertionError(
                f"maintenance.checkCases[{index}] {case['name']} "
                f"{actual!r} != {case['expected']!r}")

    for index, case in enumerate(fixture["rollbackCases"]):
        batch = fixture["valid"][case["batch"]]
        rollback = case["rollback"]
        actual = None
        if rollback["batch_id"] != batch["batch_id"] or rollback["bot_id"] != batch["bot_id"]:
            actual = "maintenance-rollback-conflict"
        else:
            after = {change["path"]: change["after_version"] for change in batch["changes"]}
            for item in rollback["restored"]:
                if after.get(item["path"]) != item["from_version"] or item["to_version"] <= item["from_version"]:
                    actual = "maintenance-rollback-conflict"
                    break
        if actual != case["expected"]:
            raise AssertionError(
                f"maintenance.rollbackCases[{index}] {case['name']} "
                f"{actual!r} != {case['expected']!r}")
    return len(fixture["valid"]) - 2, len(fixture["invalid"]), len(fixture["checkCases"])


def mutation_count_for_maintenance() -> int:
    """Mutate the shared maintenance fixture and require each check to fail."""
    import copy

    def expect_failure(label, action):
        try:
            action()
        except Exception:
            return 1
        raise AssertionError(f"maintenance mutation {label!r} unexpectedly passed")

    count = 0
    mutated = copy.deepcopy(load("memory-maintenance"))
    for record in mutated["checkCases"][0]["records"].values():
        record["botId"] = "bot-b"
    count += expect_failure(
        "foreign-record",
        lambda: validate_maintenance_fixture(mutated))

    mutated = copy.deepcopy(load("memory-maintenance"))
    mutated["checkCases"][0]["records"]["record://session/gb-main#3"]["text"] = "短。"
    count += expect_failure(
        "document-longer-than-evidence",
        lambda: validate_maintenance_fixture(mutated))

    mutated = copy.deepcopy(load("memory-maintenance"))
    mutated["valid"]["committed"]["changes"] = [
        {"path": f"agent/notes/{index}.md", "scope": "agent",
         "before_version": 0, "after_version": 1, "deleted": False}
        for index in range(13)
    ]
    count += expect_failure(
        "rollback-version-mismatch",
        lambda: validate_maintenance_fixture(mutated))
    mutated = copy.deepcopy(load("memory-maintenance"))
    mutated["checkCases"][4]["isMainBot"] = True
    count += expect_failure(
        "non-main-user-write",
        lambda: validate_maintenance_fixture(mutated))
    return count


def validate_maintenance_fixture(fixture) -> None:
    for index, case in enumerate(fixture["checkCases"]):
        if maintenance_check(case) != case["expected"]:
            raise AssertionError(f"checkCases[{index}]")
    for index, case in enumerate(fixture["rollbackCases"]):
        batch = fixture["valid"][case["batch"]]
        rollback = case["rollback"]
        actual = None
        if rollback["batch_id"] != batch["batch_id"] or rollback["bot_id"] != batch["bot_id"]:
            actual = "maintenance-rollback-conflict"
        else:
            after = {change["path"]: change["after_version"] for change in batch["changes"]}
            for item in rollback["restored"]:
                if after.get(item["path"]) != item["from_version"] or item["to_version"] <= item["from_version"]:
                    actual = "maintenance-rollback-conflict"
                    break
        if actual != case["expected"]:
            raise AssertionError(f"rollbackCases[{index}]")


# ── wake / held fixtures (ownership moved to v2) ──────────────────────────

def validate_wake_and_held() -> tuple[int, int]:
    check(load("wake-routine")["valid"], "wake-routine.schema.json", "wake-routine")
    check(load("wake-routine")["valid"]["quietDefer"], "routine.schema.json", "routine")
    held_fixture = merged_fixture(load("held-inbox"), load_json(BOT / "golden" / "held-inbox.phone.json"))
    held = held_fixture["valid"]
    check(held["enqueued"]["item"], "held-inbox-item.schema.json", "held-item")
    check(held["deviceTaskResult"], "held-inbox-item.schema.json", "held-device-task-result")
    check(held["agentHeld"], "held-inbox-item.schema.json", "held-agent-held")
    check_many(held["staged"]["items"], "held-inbox-item.schema.json", "held-staged")
    for index, case in enumerate(held_fixture["invalid"]):
        rejects(case, "held-inbox-item.schema.json", f"held.invalid[{index}]")
    return len(held["staged"]["items"]), len(held_fixture["invalid"])


def validate_routine_document() -> tuple[int, int]:
    # CCR-7 routine snapshots: the outer wrapper is routine-document.schema.json;
    # each routine and delivery is validated with its own frozen schema. The
    # repository JSON-Schema subset does not resolve $ref, so the checker must
    # perform the two nested checks explicitly.
    documents = load("routine-document")
    if documents.get("vector") != "routine-document":
        raise AssertionError("routine-document: vector must be routine-document")
    for index, case in enumerate(documents.get("valid", [])):
        where = f"routine-document.valid[{index}]"
        check(case["data"], "routine-document.schema.json", where)
        document = case["data"]["document"]
        check_many(document["routines"], "routine.schema.json", f"{where}.routines")
        for key, delivery in sorted(document["deliveries"].items()):
            check(delivery, "routine-delivery.schema.json", f"{where}.deliveries[{key}]")
    for index, case in enumerate(documents.get("invalid", [])):
        rejects(case["data"], "routine-document.schema.json",
                f"routine-document.invalid[{index}]")
    return len(documents.get("valid", [])), len(documents.get("invalid", []))


# ── proactive (S5: settings, decision chain, routine-due separation) ─────


def proactive_minutes(value):
    """Swift QuietClock.minutes: trimmed HH:MM, one-digit hour allowed."""
    if not isinstance(value, str):
        return None
    pieces = value.strip().split(":")
    if len(pieces) != 2 or len(pieces[0]) > 2 or len(pieces[1]) != 2:
        return None
    if pieces[0] != pieces[0].strip() or pieces[1] != pieces[1].strip():
        return None
    try:
        hour = int(pieces[0])
        minute = int(pieces[1])
    except ValueError:
        return None
    if not 0 <= hour <= 23 or not 0 <= minute <= 59:
        return None
    return hour * 60 + minute


def proactive_timezone_known(value):
    if not isinstance(value, str) or not value:
        return False
    try:
        ZoneInfo(value)
        return True
    except Exception:  # noqa: BLE001 - ZoneInfo raises several lookup errors
        return False


def proactive_normalize_settings(value):
    """Swift ProactiveSettings.normalized; <current> stands for TimeZone.current."""
    normalized = dict(value)
    if proactive_minutes(normalized.get("quietStart")) is None:
        normalized["quietStart"] = "23:00"
    if proactive_minutes(normalized.get("quietEnd")) is None:
        normalized["quietEnd"] = "08:00"
    if not proactive_timezone_known(normalized.get("timeZone")):
        normalized["timeZone"] = "<current>"
    return normalized


def proactive_settings_error(value):
    """First contract violation as (code, JSON path), or None."""
    if not isinstance(value, dict):
        return ("proactive-settings-type", "$")
    unknown = sorted(set(value) - set(PROACTIVE_SETTINGS_FIELDS))
    if unknown:
        return ("proactive-settings-unknown-field", "$." + unknown[0])
    for field in PROACTIVE_SETTINGS_FIELDS:
        if field not in value:
            return ("proactive-settings-missing-field", "$." + field)
    if not isinstance(value["mode"], str):
        return ("proactive-settings-type", "$.mode")
    if value["mode"] not in PROACTIVE_MODES:
        return ("proactive-settings-unknown-enum", "$.mode")
    for field in ("dnd", "routineQuietWeekends"):
        if not isinstance(value[field], bool):
            return ("proactive-settings-type", "$." + field)
    for field in ("quietStart", "quietEnd"):
        if not isinstance(value[field], str):
            return ("proactive-settings-type", "$." + field)
        if PROACTIVE_CLOCK_RE.fullmatch(value[field]) is None:
            return ("proactive-settings-time-format", "$." + field)
    if not isinstance(value["timeZone"], str):
        return ("proactive-settings-type", "$.timeZone")
    if not value["timeZone"].strip():
        return ("proactive-settings-timezone", "$.timeZone")
    for field in ("fuseWindowMs", "fuseMaxWakeups"):
        if isinstance(value[field], bool) or not isinstance(value[field], int):
            return ("proactive-settings-type", "$." + field)
        if value[field] < 1:
            return ("proactive-settings-range", "$." + field)
    kinds = value["deliveryKinds"]
    if not isinstance(kinds, list):
        return ("proactive-settings-type", "$.deliveryKinds")
    seen = set()
    for index, kind in enumerate(kinds):
        path = "$.deliveryKinds[{}]".format(index)
        if not isinstance(kind, str):
            return ("proactive-settings-type", path)
        if kind not in PROACTIVE_KINDS:
            return ("proactive-settings-unknown-enum", path)
        if kind in seen:
            return ("proactive-settings-duplicate-delivery-kind", path)
        seen.add(kind)
    return None


def proactive_candidate_error(value):
    """First candidate contract violation as (code, JSON path), or None."""
    if not isinstance(value, dict):
        return ("proactive-candidate-type", "$")
    unknown = sorted(set(value) - set(PROACTIVE_CANDIDATE_FIELDS))
    if unknown:
        return ("proactive-candidate-unknown-field", "$." + unknown[0])
    for field in PROACTIVE_CANDIDATE_REQUIRED:
        if field not in value:
            return ("proactive-candidate-missing-field", "$." + field)
    if not isinstance(value["kind"], str):
        return ("proactive-candidate-type", "$.kind")
    if value["kind"] not in PROACTIVE_KINDS:
        return ("proactive-candidate-unknown-enum", "$.kind")
    if not isinstance(value["botId"], str):
        return ("proactive-candidate-type", "$.botId")
    if not value["botId"]:
        return ("proactive-candidate-min-length", "$.botId")
    if isinstance(value["createdAt"], bool) or not isinstance(value["createdAt"], int):
        return ("proactive-candidate-type", "$.createdAt")
    if value["createdAt"] < 0:
        return ("proactive-candidate-range", "$.createdAt")
    for field in (
        "id", "dedupeKey", "trigger", "sourceEventId", "channel", "title", "body",
        "taskId", "taskTitle", "summary", "status", "routineId", "runId",
        "resultExcerpt", "deliveryKey", "reminderId",
    ):
        if field in value and not isinstance(value[field], str):
            return ("proactive-candidate-type", "$." + field)
    if "channel" in value and not value["channel"]:
        return ("proactive-candidate-min-length", "$.channel")
    if "delivery" in value:
        if not isinstance(value["delivery"], str):
            return ("proactive-candidate-type", "$.delivery")
        if value["delivery"] not in ("held", "interrupt"):
            return ("proactive-candidate-unknown-enum", "$.delivery")
    if "attempt" in value:
        if isinstance(value["attempt"], bool) or not isinstance(value["attempt"], int):
            return ("proactive-candidate-type", "$.attempt")
        if value["attempt"] < 0:
            return ("proactive-candidate-range", "$.attempt")
    for field in ("quiet", "allowDuringDnd"):
        if field in value and not isinstance(value[field], bool):
            return ("proactive-candidate-type", "$." + field)
    if "rowId" in value:
        if not isinstance(value["rowId"], str):
            return ("proactive-candidate-type", "$.rowId")
        if not value["rowId"]:
            return ("proactive-candidate-min-length", "$.rowId")
    return None


def proactive_status_label(status):
    if status is None:
        return "已结束"
    lowered = status.lower()
    if lowered in ("completed", "succeeded", "ok", "sent"):
        return "已完成"
    if lowered in ("stopped", "canceled", "cancelled"):
        return "已停止"
    if lowered in ("timed_out", "timeout", "timed-out"):
        return "超时"
    if lowered in ("error", "failed", "failure"):
        return "失败"
    return status


def proactive_summarize(value, maximum=100):
    """Swift RoutineScheduleMath.summarize: first sentence, cap 100 by default."""
    text = re.sub(r"\s+", " ", value).strip()
    if not text:
        return ""
    sentence_end = None
    for index, character in enumerate(text):
        if character in "。！？":
            sentence_end = index + 1
            break
        if character in ".!?":
            following = index + 1
            if following == len(text) or text[following].isspace():
                sentence_end = following
                break
    sentence = text[:sentence_end] if sentence_end is not None else text
    return sentence[:max(1, maximum)].strip()


def proactive_deep_link(bot_id, row_id):
    safe = "!$&'()*+,-.:=@_~"
    return "phonedsh://bot/{}/row/{}".format(quote(bot_id, safe=safe), quote(row_id, safe=safe))


def proactive_delivery_key(candidate, at):
    explicit = candidate.get("dedupeKey")
    if isinstance(explicit, str):
        trimmed = explicit.strip()
        if trimmed:
            return trimmed
    payload = ""
    for field in ("taskId", "runId", "reminderId", "id"):
        if candidate.get(field) is not None:
            payload = candidate[field]
            break
    return "{}:{}:{}".format(candidate["kind"], candidate["botId"], payload if payload else at)


def proactive_notification(candidate, dedupe_key):
    kind = candidate["kind"]
    bot_id = candidate["botId"]
    explicit_title = candidate.get("title")
    title = explicit_title.strip() if isinstance(explicit_title, str) else ""
    if not title:
        title = {
            "task-done": "DSH Bot · 后台任务",
            "routine-result": "DSH Bot · 定时执行",
            "reminder": "DSH Bot · 提醒",
        }[kind]
    explicit_body = candidate.get("body")
    body = explicit_body.strip() if isinstance(explicit_body, str) else ""
    if not body:
        if kind == "task-done":
            if candidate.get("summary") is not None:
                body = candidate["summary"]
            elif candidate.get("taskTitle") is not None:
                body = candidate["taskTitle"]
            else:
                body = "任务 {} {}".format(
                    candidate.get("taskId") or "", proactive_status_label(candidate.get("status")))
        elif kind == "routine-result":
            if candidate.get("resultExcerpt") is not None:
                body = proactive_summarize(candidate["resultExcerpt"])
            else:
                body = "例行任务 {} {}".format(
                    candidate.get("routineId") or "", proactive_status_label(candidate.get("status")))
        else:
            body = "提醒时间到了"
    notification = {
        "title": title[:120],
        "body": body[:500],
        "kind": kind,
        "botId": bot_id,
        "dedupeKey": dedupe_key,
        "channel": candidate.get("channel", "system-notification"),
    }
    if candidate.get("rowId") is not None:
        notification["rowId"] = candidate["rowId"]
        notification["deepLink"] = proactive_deep_link(bot_id, candidate["rowId"])
    return notification


def proactive_local_minute(now_ms, timezone_name):
    try:
        zone = ZoneInfo(timezone_name)
    except Exception:  # noqa: BLE001 - normalized settings always resolve; fail open to UTC
        zone = timezone.utc
    moment = datetime.fromtimestamp(now_ms / 1000, tz=zone)
    return moment.hour * 60 + moment.minute


def proactive_within_quiet(now_ms, start, end, timezone_name):
    first = proactive_minutes(start)
    last = proactive_minutes(end)
    if first is None or last is None or first == last:
        return False
    current = proactive_local_minute(now_ms, timezone_name)
    if first < last:
        return first <= current < last
    return current >= first or current < last


def proactive_fuse_tripped(accepted, bot_id, at, settings):
    count = sum(
        1 for entry in accepted
        if entry["fuseRecorded"] and entry["botId"] == bot_id
        and at - entry["at"] < settings["fuseWindowMs"]
    )
    return count >= settings["fuseMaxWakeups"]


def proactive_decision_actual(case, step, sequence, accepted):
    """Reference ProactiveEngine.perform/finish for one golden step."""
    settings = case["settings"]
    candidate = step["candidate"]
    at = step["at"]
    mode = settings["mode"]
    dedupe_key = proactive_delivery_key(candidate, at)
    notification = proactive_notification(candidate, dedupe_key)

    def make(choice, reason, delivery=None):
        record = {
            "id": "proactive:{}:{}".format(at, sequence),
            "at": at,
            "decision": choice,
            "reason": reason,
            "kind": candidate["kind"],
            "botId": candidate["botId"],
            "dedupeKey": dedupe_key,
            "mode": mode,
            "channel": candidate.get("channel", "system-notification"),
            "notification": notification,
        }
        if delivery is not None:
            record["delivery"] = delivery
        if choice in ("did", "would"):
            accepted.append({
                "at": at,
                "botId": candidate["botId"],
                "fuseRecorded": choice == "did" or mode == "would",
            })
        return record

    def skip(reason, delivery=None):
        return make("skip", reason, delivery)

    if candidate["kind"] == "routine-result":
        if candidate.get("delivery") != "interrupt":
            return skip("routine-held"), accepted
        if candidate.get("quiet") is True:
            return skip("routine-quiet"), accepted
    if mode == "off":
        return skip("mode-off"), accepted
    deliverable = mode == "on" and candidate["kind"] in settings["deliveryKinds"]
    if not candidate["botId"].strip():
        return skip("missing-bot"), accepted
    explicit_reminder = (
        candidate["kind"] == "reminder"
        and candidate.get("allowDuringDnd") is True
        and bool(candidate.get("reminderId"))
    )
    if settings["dnd"] and not explicit_reminder:
        return skip("dnd"), accepted
    if not explicit_reminder and proactive_within_quiet(
            at, settings["quietStart"], settings["quietEnd"], settings["timeZone"]):
        return skip("quiet-hours"), accepted
    fuse_applies = mode == "would" or deliverable
    if fuse_applies and proactive_fuse_tripped(accepted, candidate["botId"], at, settings):
        return skip("fuse"), accepted

    if deliverable:
        config = step.get("deliverer", case.get("deliverer", "ok"))
        if config == "none":
            return skip("delivery-unavailable"), accepted
        if isinstance(config, dict) and "throw" in config:
            return skip("delivery-failed", {
                "delivered": False,
                "channel": "system-notification",
                "error": config["throw"],
            }), accepted
        if isinstance(config, dict) and config.get("delivered") is not True:
            result = {
                "delivered": False,
                "channel": config.get("channel", "system-notification"),
            }
            if config.get("error") is not None:
                result["error"] = config["error"]
            return skip("delivery-failed", result), accepted
        choice = "did"
        delivery = {"delivered": True, "channel": notification["channel"]}
    else:
        choice = "would"
        delivery = None
    reason = "delivered" if choice == "did" else (
        "would-mode" if mode == "would" else "would-only-kind")
    return make(choice, reason, delivery), accepted


def proactive_routine_due(input_value):
    """Reference RoutineScheduledNotification for a routine-due local notification."""
    title = "例行任务到期"
    routine_title = input_value["routineTitle"][:120]
    body = ("「{}」到点，点开运行。".format(routine_title))[:200]
    return {
        "identifier": "routine-due:{}:{}:{}".format(
            input_value["botId"], input_value["routineId"], input_value["fireAt"]),
        "botId": input_value["botId"],
        "routineId": input_value["routineId"],
        "title": title,
        "body": body,
        "fireAt": input_value["fireAt"],
        "deepLink": "phonedsh://bot/{}/routine/{}".format(
            input_value["botId"], input_value["routineId"]),
    }


def proactive_mismatch(where, actual, expected):
    if actual == expected:
        return
    raise AssertionError(
        "{}: {} != {}".format(
            where,
            json.dumps(actual, ensure_ascii=False, sort_keys=True),
            json.dumps(expected, ensure_ascii=False, sort_keys=True)))


def validate_proactive_fixture(fixture):
    if fixture.get("vector") != "proactive":
        raise AssertionError("proactive: vector must be proactive")
    if fixture.get("upstream") != []:
        raise AssertionError("proactive: phone-only vector must declare upstream: []")
    settings_fixture = fixture["settings"]
    valid_settings = settings_fixture["valid"]
    invalid_settings = settings_fixture["invalid"]
    if not valid_settings or not invalid_settings:
        raise AssertionError("proactive: settings valid/invalid must be non-empty")
    for name, document in valid_settings.items():
        where = "proactive.settings.valid.{}".format(name)
        check(document, "proactive-settings.schema.json", where)
        error = proactive_settings_error(document)
        if error is not None:
            raise AssertionError("{}: reference rejected {}".format(where, error))
    for index, case in enumerate(invalid_settings):
        where = "proactive.settings.invalid[{}]".format(index)
        rejects(case["settings"], "proactive-settings.schema.json", where)
        proactive_mismatch(where, proactive_settings_error(case["settings"]),
                           (case["error"], case["path"]))
        if case.get("recovery") not in (
                "decode-fails", "normalize", "contract-only", "decode-ignores"):
            raise AssertionError("{}: invalid recovery {!r}".format(where, case.get("recovery")))
        if case["recovery"] == "normalize" and not case.get("normalized"):
            raise AssertionError("{}: normalize recovery needs normalized".format(where))
    for index, case in enumerate(settings_fixture.get("normalization", [])):
        where = "proactive.settings.normalization[{}]".format(index)
        normalized = proactive_normalize_settings(case["input"])
        for field, expected in case["expect"].items():
            actual = normalized.get(field)
            if expected == "<current>":
                if actual == case["input"].get(field) or not actual:
                    raise AssertionError("{}: {} did not fall back".format(where, field))
            elif actual != expected:
                raise AssertionError("{}: {} {!r} != {!r}".format(where, field, actual, expected))

    settings_schema = schema("proactive-settings.schema.json")
    if tuple(settings_schema["required"]) != PROACTIVE_SETTINGS_FIELDS:
        raise AssertionError("proactive: settings required fields drifted")
    if tuple(settings_schema["properties"]["mode"]["enum"]) != PROACTIVE_MODES:
        raise AssertionError("proactive: settings mode enum drifted")
    if tuple(settings_schema["properties"]["deliveryKinds"]["items"]["enum"]) != PROACTIVE_KINDS:
        raise AssertionError("proactive: settings deliveryKinds enum drifted")
    for field in ("quietStart", "quietEnd"):
        if settings_schema["properties"][field]["pattern"] != PROACTIVE_CLOCK_PATTERN:
            raise AssertionError("proactive: {} time pattern drifted".format(field))
    decision_schema = schema("proactive-decision.schema.json")
    if tuple(decision_schema["properties"]["decision"]["enum"]) != PROACTIVE_DECISIONS:
        raise AssertionError("proactive: decision enum drifted")
    if tuple(decision_schema["properties"]["reason"]["enum"]) != PROACTIVE_REASONS:
        raise AssertionError("proactive: reason enum drifted")
    if tuple(decision_schema["properties"]["kind"]["enum"]) != PROACTIVE_KINDS:
        raise AssertionError("proactive: decision kind enum drifted")
    candidate_schema = decision_schema["$defs"]["proactiveCandidate"]
    if tuple(candidate_schema["required"]) != PROACTIVE_CANDIDATE_REQUIRED:
        raise AssertionError("proactive: candidate required fields drifted")
    if tuple(candidate_schema["properties"]) != PROACTIVE_CANDIDATE_FIELDS:
        raise AssertionError("proactive: candidate field list drifted")
    decisions = fixture["decisions"]
    if not decisions["valid"] or not decisions["invalid"]:
        raise AssertionError("proactive: decisions valid/invalid must be non-empty")
    steps = 0
    for index, case in enumerate(decisions["valid"]):
        where = "proactive.decisions.valid[{}] {}".format(index, case["name"])
        check(case["settings"], "proactive-settings.schema.json", where + ".settings")
        accepted = []
        for step_index, step in enumerate(case["steps"]):
            step_where = "{} step {}".format(where, step_index + 1)
            check_schema(step["candidate"], candidate_schema, step_where + ".candidate")
            candidate_error = proactive_candidate_error(step["candidate"])
            if candidate_error is not None:
                raise AssertionError("{}: reference rejected {}".format(step_where, candidate_error))
            actual, accepted = proactive_decision_actual(case, step, step_index + 1, accepted)
            check(actual, "proactive-decision.schema.json", step_where + ".expect")
            proactive_mismatch(step_where, actual, step["expect"])
            steps += 1
    for index, case in enumerate(decisions["invalid"]):
        where = "proactive.decisions.invalid[{}]".format(index)
        check(case["settings"], "proactive-settings.schema.json", where + ".settings")
        rejects_schema(case["candidate"], candidate_schema, where + ".candidate")
        proactive_mismatch(where, proactive_candidate_error(case["candidate"]),
                           (case["error"], case["path"]))

    routine_cases = fixture["routineDue"]["cases"]
    if not routine_cases:
        raise AssertionError("proactive: routineDue.cases must be non-empty")
    for index, case in enumerate(routine_cases):
        where = "proactive.routineDue.cases[{}]".format(index)
        check(case["expect"], "routine-notification.schema.json", where + ".expect")
        proactive_mismatch(where, proactive_routine_due(case["input"]), case["expect"])
        if case.get("proactive") is not False or case.get("consumesFuse") is not False:
            raise AssertionError("{}: routine-due must be non-proactive and fuse-free".format(where))

    return (len(valid_settings), len(invalid_settings), len(decisions["valid"]),
            steps, len(decisions["invalid"]), len(routine_cases))


def validate_proactive_vectors():
    fixture = load("proactive")
    counts = validate_proactive_fixture(fixture)
    return counts + (mutation_count_for_proactive(),)


def mutation_count_for_proactive():
    import copy

    fixture = load("proactive")
    names = [case["name"] for case in fixture["decisions"]["valid"]]

    def index_of(name):
        return names.index(name)

    mutations = 0

    def expect_failure(label, mutate):
        nonlocal mutations
        mutated = copy.deepcopy(fixture)
        mutate(mutated)
        try:
            validate_proactive_fixture(mutated)
        except Exception:  # noqa: BLE001 - schema and reference failures both count
            mutations += 1
            return
        raise AssertionError("proactive mutation {!r} unexpectedly passed".format(label))

    expect_failure(
        "decision-flip",
        lambda value: value["decisions"]["valid"][0]["steps"][0]["expect"].__setitem__(
            "decision", "did"))
    expect_failure(
        "fuse-max",
        lambda value: value["decisions"]["valid"][index_of("fuse-allows-fourth-and-blocks-fifth")]
        ["settings"].__setitem__("fuseMaxWakeups", 5))
    expect_failure(
        "delivery-kinds",
        lambda value: value["decisions"]["valid"][
            index_of("delivery-kinds-filter-records-would-only-kind")]["settings"]
        ["deliveryKinds"].append("task-done"))
    expect_failure(
        "delivery-failure-result",
        lambda value: value["decisions"]["valid"][
            index_of("delivery-failure-does-not-consume-fuse")]["steps"][0]["deliverer"]
        .__setitem__("delivered", True))
    expect_failure(
        "dedupe-key",
        lambda value: value["decisions"]["valid"][
            index_of("dedupe-key-replaces-and-does-not-suppress")]["steps"][0]["expect"]
        .__setitem__("dedupeKey", "replaced"))
    expect_failure(
        "notification-title",
        lambda value: value["decisions"]["valid"][0]["steps"][0]["expect"]["notification"]
        .__setitem__("title", "X"))
    expect_failure(
        "settings-enum",
        lambda value: value["settings"]["valid"]["production-default"].__setitem__(
            "mode", "always"))
    expect_failure(
        "settings-invalid-path",
        lambda value: value["settings"]["invalid"][0].__setitem__(
            "path", "$.deliveryKinds"))
    expect_failure(
        "decision-invalid-error",
        lambda value: value["decisions"]["invalid"][0].__setitem__(
            "error", "proactive-candidate-type"))
    expect_failure(
        "routine-due-body",
        lambda value: value["routineDue"]["cases"][0]["expect"].__setitem__("body", "due"))
    return mutations


def validate_routine_notification() -> tuple[int, int]:
    fixture = load("routine-notification")
    for name, case in fixture["valid"].items():
        check(case, "routine-notification.schema.json", f"routine-notification.{name}")
    for index, case in enumerate(fixture["invalid"]):
        rejects(case, "routine-notification.schema.json", f"routine-notification.invalid[{index}]")
    return len(fixture["valid"]), len(fixture["invalid"])


def main() -> int:
    check_overlays()
    documents = validate_document_vectors()
    evidence_valid, evidence_invalid, boundary, writes = validate_write_vectors()
    reads = validate_read_vectors()
    recall = validate_recall_vectors()
    injection = validate_injection_vectors()
    migration = validate_migration_vectors()
    erasure_cases, erasure_invalid, erasure_mutations = validate_erasure_vectors()
    held_valid, held_invalid = validate_wake_and_held()
    notifications_valid, notifications_invalid = validate_routine_notification()
    routine_docs_valid, routine_docs_invalid = validate_routine_document()
    (proactive_settings_valid, proactive_settings_invalid,
     proactive_valid, proactive_steps, proactive_invalid,
     proactive_routine, proactive_mutations) = validate_proactive_vectors()
    maintenance_valid, maintenance_invalid, maintenance_checks = validate_maintenance_vectors()
    maintenance_mutations = mutation_count_for_maintenance()
    mutations = mutation_count_for_evidence()
    print("bot v2 vectors: PASS (memory documents, write/version/index/single-author, "
          "read, recall, injection, migration, maintenance; wake/routine/routine document/held/notification; proactive settings/decisions/routine-due; schema-positive "
          f"and negative vectors; documents {documents}; evidence {evidence_valid} valid / "
          f"{evidence_invalid} invalid / {boundary} boundary / {mutations} mutations; "
          f"writes {writes}; reads {reads}; recall {recall}; injection {injection}; "
          f"migration {migration} bots; erasure {erasure_cases} valid / "
          f"{erasure_invalid} invalid / {erasure_mutations} mutations; "
          f"held {held_valid} valid / {held_invalid} invalid; "
          f"notifications {notifications_valid} valid / {notifications_invalid} invalid; "
          f"routine documents {routine_docs_valid} valid / {routine_docs_invalid} invalid; "
          f"proactive settings {proactive_settings_valid} valid / {proactive_settings_invalid} invalid; "
          f"proactive decisions {proactive_valid} cases / {proactive_steps} steps / "
          f"{proactive_invalid} invalid / {proactive_routine} routine-due / "
          f"{proactive_mutations} mutations; "
          f"maintenance {maintenance_valid} batches / {maintenance_invalid} invalid / "
          f"{maintenance_checks} checks / {maintenance_mutations} mutations)")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # noqa: BLE001 - one actionable gate line
        print(f"bot v2 vectors: FAIL: {exc}", file=sys.stderr)
        sys.exit(1)
