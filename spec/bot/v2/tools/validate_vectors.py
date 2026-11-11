#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Validate the phoneDSH-owned Bot v2 schemas and their shared vectors.

v2 owns memory (document tree), wake markers and proactive delivery. The v1
validator calls :func:`main`, so ``phone-spec`` covers both trees in one stage.
The memory reference implementation here mirrors the domain rules frozen in
``spec/bot/v2/README.md``: path grammar, version premise, single author,
evidence/trust, the 1,500-scalar INDEX limit and the one-time fact migration.
"""
from __future__ import annotations

import json
import re
import sys
from datetime import datetime, timezone
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


def load(name: str):
    return load_json(BOT / "golden" / f"{name}.json")


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
            trust = derive_trust(records, case.get("refs"), "bot-a")
        except Exception as exc:  # noqa: BLE001 - one actionable line
            raise AssertionError(f"evidence.valid[{index}] unexpectedly rejected: {exc}") from exc
        if trust != case.get("trust"):
            raise AssertionError(f"evidence.valid[{index}] trust {trust!r} != {case.get('trust')!r}")
        if (trust == "user") != bool(case.get("userBoundary")):
            raise AssertionError(f"evidence.valid[{index}] userBoundary mismatch")
    for index, case in enumerate(evidence["invalid"]):
        try:
            derive_trust(records, case.get("refs"), "bot-a")
        except Exception:
            continue
        raise AssertionError(f"evidence.invalid[{index}] unexpectedly accepted")
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
    held_valid, held_invalid = validate_wake_and_held()
    notifications_valid, notifications_invalid = validate_routine_notification()
    mutations = mutation_count_for_evidence()
    print("bot v2 vectors: PASS (memory documents, write/version/index/single-author, "
          "read, recall, injection, migration; wake/routine/held/notification; schema-positive "
          f"and negative vectors; documents {documents}; evidence {evidence_valid} valid / "
          f"{evidence_invalid} invalid / {boundary} boundary / {mutations} mutations; "
          f"writes {writes}; reads {reads}; recall {recall}; injection {injection}; "
          f"migration {migration} bots; held {held_valid} valid / {held_invalid} invalid; "
          f"notifications {notifications_valid} valid / {notifications_invalid} invalid)")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # noqa: BLE001 - one actionable gate line
        print(f"bot v2 vectors: FAIL: {exc}", file=sys.stderr)
        sys.exit(1)
