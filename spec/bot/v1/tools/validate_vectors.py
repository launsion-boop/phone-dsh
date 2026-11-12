#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Validate Bot v1 schemas and the exported positive/negative conformance vectors."""
from __future__ import annotations

import base64
import copy
import hashlib
import json
import posixpath
import re
import sys
import unicodedata
from pathlib import Path
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(ROOT))

from spec.v1.tools.spec_golden import validate_json
from spec.tools.bot.golden_overlay import (
    METADATA_KEYS,
    assert_append_only,
    load_json,
    merged_fixture,
    overlay_name,
)

BOT = ROOT / "spec" / "bot" / "v1"
GOLDEN_GLOB = "*.json"
TURN_ORIGIN_VECTOR = "turn-origin.phone.json"
MCP_EGRESS_VECTOR = "mcp-egress.phone.json"
AUTHORITY_VECTOR = "authority.phone.json"
RECORD_REFERENCE_VECTOR = "record-reference.phone.json"
OBSERVATION_ENVELOPE_VECTOR = "observation-envelope.phone.json"
RECORD_QUERY_VECTOR = "record-query.phone.json"
ERASURE_EVENT_VECTOR = "erasure-event.phone.json"
VERIFICATION_VECTOR = "verification.phone.json"
STORE_VECTOR = "store.phone.json"
USER_ACTION_VECTOR = "user-action-transaction.phone.json"
SESSION_LIFECYCLE_VECTOR = "session-lifecycle.phone.json"
PROJECTION_VECTOR = "projection.phone.json"
# A phone-only vector has no dsh-bot upstream export to extend. Keep this list
# explicit; `check_golden.py` has the same registration.
PHONE_ONLY_VECTORS = frozenset({
    "tool-call-cases.phone.json",
    "identity-approval-cases.phone.json",
    "mcp-rpc-cases.phone.json",
    TURN_ORIGIN_VECTOR, MCP_EGRESS_VECTOR, AUTHORITY_VECTOR,
    RECORD_REFERENCE_VECTOR, OBSERVATION_ENVELOPE_VECTOR, RECORD_QUERY_VECTOR,
    ERASURE_EVENT_VECTOR,
    VERIFICATION_VECTOR,
    STORE_VECTOR,
    USER_ACTION_VECTOR,
    SESSION_LIFECYCLE_VECTOR,
    PROJECTION_VECTOR,
})

# P26/P27 turn-origin contract. Prefix matching is exact, ASCII
# case-sensitive and anchored at offset 0; the payload must contain at least
# one non-whitespace character. Unknown input is never hidden and never gets
# more trust than `agent-message`.
TURN_ORIGIN_PREFIXES = (
    ("user-action:", ("user", False, False, "user-turn")),
    ("card-answer:", ("user", False, False, "user-turn")),
    ("bot-", ("user", False, False, "user-turn")),
    ("held:", ("held", False, True, "agent-message")),
    ("agent:", ("agent", False, False, "agent-message")),
    ("routine:", ("routine", True, False, "routine")),
    ("task-turn:", ("task", True, False, "task")),
    ("task-settled:", ("task-wake", True, False, "hidden-wake")),
    ("task-interrupted:", ("task-wake", True, False, "hidden-wake")),
)
TURN_ORIGIN_UNKNOWN = ("unknown", False, False, "agent-message")
TURN_ORIGIN_FIELDS = ("origin", "hidden", "held", "memorySource")
TURN_ORIGIN_HIDDEN = frozenset({"routine", "task", "task-wake"})
TURN_ORIGIN_MEMORY = {
    "user": "user-turn",
    "held": "agent-message",
    "agent": "agent-message",
    "routine": "routine",
    "task": "task",
    "task-wake": "hidden-wake",
    "unknown": "agent-message",
}
TURN_ORIGIN_BOUNDARIES = frozenset({
    "empty",
    "prefix-only",
    "case",
    "embedded",
    "legacy-call-id",
    "missing",
    "whitespace",
    "unknown",
})
TURN_ORIGIN_ALLOWED_KEYS = frozenset({
    "name",
    "rpcId",
    "origin",
    "hidden",
    "held",
    "memorySource",
    "boundary",
    "reason",
})


MCP_EGRESS_HEADER = "x-pdsh-mcp-egress"
MCP_EGRESS_ERROR = "mcp_egress_forbidden"
MCP_EGRESS_SUITES = frozenset({"egress", "identity", "tools-call",
                               "egress-approval", "grant-directory"})
MCP_EGRESS_TOP_KEYS = frozenset({
    "schemaVersion",
    "license",
    "vector",
    "source",
    "upstream",
    "delta",
    "egressToken",
    "egressRoutes",
    "valid",
    "invalid",
})
MCP_EGRESS_CASE_KEYS = {
    "egress": frozenset({"suite", "name", "target", "headers", "expect", "boundary", "reason"}),
    "identity": frozenset({"suite", "name", "registry", "request", "expect", "boundary", "reason"}),
    "tools-call": frozenset({"suite", "name", "callerBotId", "mainBotId", "tool", "expect", "boundary", "reason"}),
    "egress-approval": frozenset({"suite", "name", "request", "expect", "boundary", "reason"}),
    "grant-directory": frozenset({"suite", "name", "request", "expect", "boundary", "reason"}),
}
MCP_EGRESS_VALID_BOUNDARIES = {
    "egress": frozenset({"correct", "query", "header-name-case", "non-mcp", "route-scope"}),
    "identity": frozenset({"correct", "rotated"}),
    "tools-call": frozenset({"correct"}),
    "egress-approval": frozenset({
        "ask-once", "ask-always", "grant-hit", "session-grant", "get-head",
        "model-endpoint", "not-bot", "tiebreak", "job-lifecycle", "same-bot",
        "single-bot-fallback", "single-bot-grant", "workbench-turn",
        "task-network-write", "chat-unaffected",
    }),
    "grant-directory": frozenset({"inside", "same-directory", "session-grant"}),
}
MCP_EGRESS_INVALID_BOUNDARIES = {
    "egress": frozenset({"missing", "wrong", "placeholder", "case", "empty", "query", "whitespace"}),
    "identity": frozenset({
        "missing", "empty", "foreign", "mismatch", "revoked", "expired", "unknown",
        "placeholder", "case", "rotated",
    }),
    "tools-call": frozenset({"hidden-team-tool", "prefix-strip", "unknown", "case", "empty"}),
    "egress-approval": frozenset({
        "deny", "timeout", "ambiguous", "unattributed", "wrong-method",
        "wrong-host", "put", "patch", "delete", "multi-bot", "no-bot",
        "task-network-write", "task-network-write-grant",
        "task-network-write-fallback",
    }),
    "grant-directory": frozenset({
        "outside-ask", "different-directory", "args-digest", "traversal",
        "different-tool", "deny", "missing-path",
    }),
}
# The real caller catalog is `BotToolCatalog.allDefinitions` (P0 + FishAction +
# BotVolatileContext + the two team tools); only CreateTeammate is scoped to the
# main Bot. This reference oracle mirrors that table; the Swift tests remain the
# runtime conformance evidence.
CALLER_CATALOG_TOOLS = frozenset({
    "ask_user", "show_next_steps", "show_attachment", "show_document", "show_progress",
    "show_checklist", "show_link", "UpdateMemory", "ReadMemory", "RecallMemory", "Task", "AwaitTask",
    "StopSubagent", "UpdateRoutine", "ListRoutines", "RequestApproval", "SendToUser",
    "BotVolatileContext", "FishAction", "SendToAgent", "CreateTeammate",
})
CALLER_MAIN_ONLY_TOOLS = frozenset({"CreateTeammate"})

# P26 additive (PC-20261111-bot-content-card-final): the five content-card
# tools accept an optional `final` control flag. It is not part of the card
# payload; it only tells the host/Worker to suppress the rest of the turn.
CONTENT_CARD_FINAL_TOOLS = (
    "show_attachment", "show_document", "show_progress", "show_checklist", "show_link",
)
CONTENT_CARD_FINAL_SCHEMA = {
    "type": "object",
    "required": ["type"],
    "properties": {
        "type": {"const": "boolean"},
        "default": {"const": False},
        "description": {"type": "string", "minLength": 1},
    },
    "additionalProperties": False,
}


def load(name: str):
    return json.loads((BOT / "golden" / name).read_text(encoding="utf-8"))


def load_merged(name: str):
    """Upstream batch plus its same-name `.phone.json` overlay."""
    upstream = load(name)
    overlay_path = BOT / "golden" / overlay_name(name)
    if not overlay_path.is_file():
        return upstream
    return merged_fixture(upstream, load(overlay_path.name))


def resolve_turn_origin(rpc_id):
    """Classify one `source.rpcId` exactly as the frozen prefix table says."""
    if not isinstance(rpc_id, str) or not rpc_id:
        return TURN_ORIGIN_UNKNOWN
    for prefix, expected in TURN_ORIGIN_PREFIXES:
        if not rpc_id.startswith(prefix):
            continue
        payload = rpc_id[len(prefix):]
        if payload and not payload.isspace():
            return expected
        return TURN_ORIGIN_UNKNOWN
    return TURN_ORIGIN_UNKNOWN


def _turn_origin_signature(case, where):
    for key in TURN_ORIGIN_FIELDS:
        if key not in case:
            raise AssertionError(f"{where}: missing {key}")
    origin, hidden, held, memory_source = (case[key] for key in TURN_ORIGIN_FIELDS)
    if origin not in TURN_ORIGIN_MEMORY:
        raise AssertionError(f"{where}: unknown origin {origin!r}")
    if not isinstance(hidden, bool) or not isinstance(held, bool):
        raise AssertionError(f"{where}: hidden/held must be booleans")
    if hidden != (origin in TURN_ORIGIN_HIDDEN):
        raise AssertionError(f"{where}: hidden does not match origin {origin!r}")
    if held != (origin == "held"):
        raise AssertionError(f"{where}: held does not match origin {origin!r}")
    if memory_source != TURN_ORIGIN_MEMORY[origin]:
        raise AssertionError(f"{where}: memorySource does not match origin {origin!r}")
    return (origin, hidden, held, memory_source)


def validate_turn_origin_fixture(fixture):
    """Validate the shared turn-origin vectors and prove the check can fail."""
    if fixture.get("schemaVersion") != 1:
        raise AssertionError("turn-origin: schemaVersion must be 1")
    if fixture.get("vector") != "turn-origin.phone":
        raise AssertionError("turn-origin: vector must be turn-origin.phone")
    if fixture.get("upstream") != []:
        raise AssertionError("turn-origin: phone-only vector must declare upstream: []")
    delta = fixture.get("delta")
    if not isinstance(delta, list) or not delta or not all(isinstance(item, str) and item for item in delta):
        raise AssertionError("turn-origin: delta must be a non-empty string array")
    valid = fixture.get("valid")
    invalid = fixture.get("invalid")
    if not isinstance(valid, list) or not valid:
        raise AssertionError("turn-origin: valid must be a non-empty array")
    if not isinstance(invalid, list) or not invalid:
        raise AssertionError("turn-origin: invalid must be a non-empty array")

    names = set()
    covered_prefixes = set()
    covered_boundaries = set()
    for section, cases, expect_unknown in (("valid", valid, False), ("invalid", invalid, True)):
        for index, case in enumerate(cases):
            where = f"turn-origin.{section}[{index}]"
            if not isinstance(case, dict):
                raise AssertionError(f"{where}: case must be an object")
            unexpected = set(case) - TURN_ORIGIN_ALLOWED_KEYS
            if unexpected:
                raise AssertionError(f"{where}: unexpected keys {sorted(unexpected)}")
            name = case.get("name")
            if not isinstance(name, str) or not name:
                raise AssertionError(f"{where}: name must be a non-empty string")
            if name in names:
                raise AssertionError(f"{where}: duplicate case name {name!r}")
            names.add(name)
            if "rpcId" in case and case["rpcId"] is not None and not isinstance(case["rpcId"], str):
                raise AssertionError(f"{where}: rpcId must be a string or null")
            expected = _turn_origin_signature(case, where)
            if expect_unknown:
                if expected != TURN_ORIGIN_UNKNOWN:
                    raise AssertionError(f"{where}: invalid cases must expect unknown/visible/agent-message")
                boundary = case.get("boundary")
                if boundary not in TURN_ORIGIN_BOUNDARIES:
                    raise AssertionError(f"{where}: invalid case needs a known boundary")
                if not isinstance(case.get("reason"), str) or not case["reason"].strip():
                    raise AssertionError(f"{where}: invalid case needs a reason")
                covered_boundaries.add(boundary)
            else:
                if expected[0] == "unknown":
                    raise AssertionError(f"{where}: valid cases must name a recognised origin")
                if not isinstance(case.get("rpcId"), str):
                    raise AssertionError(f"{where}: valid case needs a string rpcId")
                prefix = next((item[0] for item in TURN_ORIGIN_PREFIXES
                               if case["rpcId"].startswith(item[0])), None)
                if prefix is None:
                    raise AssertionError(f"{where}: valid case does not start with a prefix")
                covered_prefixes.add(prefix)
            actual = resolve_turn_origin(case.get("rpcId"))
            if actual != expected:
                raise AssertionError(
                    f"{where}: rpcId {case.get('rpcId')!r} resolves to {actual}, expected {expected}")

    missing_prefixes = {item[0] for item in TURN_ORIGIN_PREFIXES} - covered_prefixes
    if missing_prefixes:
        raise AssertionError(f"turn-origin: no valid case covers {sorted(missing_prefixes)}")
    missing_boundaries = TURN_ORIGIN_BOUNDARIES - covered_boundaries
    if missing_boundaries:
        raise AssertionError(f"turn-origin: no invalid case covers {sorted(missing_boundaries)}")

    # Mutation self-test: the same checker must reject deliberately corrupted
    # expectations. This keeps the vector from silently passing a broken
    # resolver (for example one that hides unknown ids).
    def clone():
        return json.loads(json.dumps(fixture))

    mutation_count = 0

    def expect_failure(label, mutate):
        nonlocal mutation_count
        mutated = clone()
        mutate(mutated)
        try:
            validate_turn_origin_fixture(mutated)
        except AssertionError:
            mutation_count += 1
            return
        raise AssertionError(f"turn-origin mutation {label!r} unexpectedly passed")

    routine_index = next(i for i, case in enumerate(valid) if case["rpcId"].startswith("routine:"))
    card_answer_index = next(i for i, case in enumerate(valid)
                             if case["rpcId"].startswith("card-answer:"))
    card_dismissed_index = next(i for i, case in enumerate(invalid)
                                if case["rpcId"].startswith("card-dismissed:"))
    expect_failure("routine-memory-source",
                   lambda value: value["valid"][routine_index].update(memorySource="agent-message"))
    expect_failure("routine-hidden",
                   lambda value: value["valid"][routine_index].update(hidden=False))
    expect_failure("card-answer-memory-source",
                   lambda value: value["valid"][card_answer_index].update(memorySource="agent-message"))
    expect_failure("card-answer-prefix-coverage",
                   lambda value: value.__setitem__(
                       "valid", [case for case in value["valid"]
                                 if not case["rpcId"].startswith("card-answer:")]))
    expect_failure("card-dismissed-known",
                   lambda value: value["invalid"][card_dismissed_index].update(
                       origin="user", memorySource="user-turn"))
    expect_failure("unknown-hidden",
                   lambda value: value["invalid"][0].update(hidden=True))
    expect_failure("valid-missing-rpc-id",
                   lambda value: value["valid"][0].pop("rpcId"))
    expect_failure("duplicate-name",
                   lambda value: value["valid"].append(dict(value["valid"][0])))
    expect_failure("prefix-coverage",
                   lambda value: value.__setitem__(
                       "valid", [case for case in value["valid"] if not case["rpcId"].startswith("task-")]))
    expect_failure("boundary-coverage",
                   lambda value: value.__setitem__(
                       "invalid", [case for case in value["invalid"] if case.get("boundary") != "case"]))
    return len(valid), len(invalid), mutation_count


def _normalized_path(raw_path):
    """Same normalization as `ModelGatewayCredentialRouting.normalizedPath`."""
    if not raw_path:
        return "/"
    path = raw_path if raw_path.startswith("/") else "/" + raw_path
    while "//" in path:
        path = path.replace("//", "/")
    segments = []
    for segment in path.split("/"):
        if segment in ("", "."):
            continue
        if segment == "..":
            if segments:
                segments.pop()
            continue
        segments.append(segment)
    return "/" if not segments else "/" + "/".join(segments)


def _mcp_route_key(raw):
    """Exact scheme/host/effective-port/normalized-path key, or None."""
    if not isinstance(raw, str):
        return None
    parts = urlsplit(raw)
    scheme = parts.scheme.lower()
    if scheme not in ("http", "https") or not parts.hostname:
        return None
    try:
        port = parts.port
    except ValueError:
        return None
    if port is None:
        port = 80 if scheme == "http" else 443
    return (scheme, parts.hostname.lower(), port, _normalized_path(parts.path))


def _mcp_header(headers, name):
    if not isinstance(headers, dict):
        raise AssertionError("headers must be an object")
    matches = [value for key, value in headers.items()
               if isinstance(key, str) and key.lower() == name]
    if len(matches) > 1:
        raise AssertionError(f"duplicate case-insensitive header {name!r}")
    if not matches:
        return None
    if not isinstance(matches[0], str):
        raise AssertionError(f"header {name!r} must be a string")
    return matches[0]


def _egress_admitted(case, token, routes):
    route = _mcp_route_key(case.get("target"))
    if route is None:
        raise AssertionError(f"invalid egress target {case.get('target')!r}")
    if route not in routes:
        return True
    value = _mcp_header(case.get("headers", {}), MCP_EGRESS_HEADER)
    return value is not None and value != "" and value == token


def _identity_registration_ok(case):
    registry = case.get("registry")
    request = case.get("request")
    if not isinstance(registry, list) or not isinstance(request, dict):
        raise AssertionError("identity case needs registry/request")
    token = request.get("sessionToken")
    if not isinstance(token, str) or token == "":
        return False
    for entry in registry:
        if not isinstance(entry, dict) or entry.get("token") != token:
            continue
        if entry.get("revoked") is True or entry.get("expired") is True:
            return False
        return entry.get("sessionId") == request.get("sessionId")
    return False


def _bare_tool_name(name):
    if not isinstance(name, str):
        return ""
    if not name.startswith("mcp__"):
        return name
    return name.split("__")[-1]


def _tools_call_ok(case):
    bare = _bare_tool_name(case.get("tool"))
    if bare not in CALLER_CATALOG_TOOLS:
        return False, "unknown_tool"
    if bare in CALLER_MAIN_ONLY_TOOLS and case.get("callerBotId") != case.get("mainBotId"):
        return False, "permission_denied"
    return True, None


def validate_approval_downgrade_fixture(fixture, upstream):
    """Validate the phone-only downgrade of upstream network approval patterns.

    Upstream keeps its curl/wget/python command patterns byte-identical. PhoneDSH
    deliberately stops treating them as an approval boundary; the host
    `/v1/http` exit owns network writes. The overlay must name every upstream
    network case and every additional WP3 spelling, and every entry must expect
    an empty match list. Destructive upstream cases may never be downgraded.
    """
    if fixture.get("vector") != "approval-patterns.phone":
        raise AssertionError("approval-patterns.phone: vector must be approval-patterns.phone")
    if fixture.get("upstream") != ["approval-patterns.json"]:
        raise AssertionError("approval-patterns.phone: upstream must name approval-patterns.json")
    if fixture.get("source", {}).get("checkout") != upstream.get("source", {}).get("checkout"):
        raise AssertionError("approval-patterns.phone: source.checkout differs from upstream")
    delta = fixture.get("delta")
    if not isinstance(delta, list) or not delta or not all(isinstance(item, str) and item for item in delta):
        raise AssertionError("approval-patterns.phone: delta must be a non-empty string array")
    downgraded = fixture.get("downgraded")
    if not isinstance(downgraded, list) or not downgraded:
        raise AssertionError("approval-patterns.phone: downgraded must be a non-empty array")
    upstream_cases = upstream["valid"] + upstream["invalid"]
    network_kinds = ("curl-post", "network-egress")
    upstream_by_command = {
        case["args"].get("command"): case for case in upstream_cases
        if isinstance(case.get("args"), dict)
    }
    seen = set()
    for index, case in enumerate(downgraded):
        where = f"approval-patterns.phone.downgraded[{index}]"
        if set(case) != {"tool", "args", "matches"}:
            raise AssertionError(f"{where}: needs exactly tool/args/matches")
        if case["tool"] != "bash" or not isinstance(case.get("args"), dict):
            raise AssertionError(f"{where}: only bash args are downgraded")
        command = case["args"].get("command")
        if not isinstance(command, str) or not command:
            raise AssertionError(f"{where}: command must be a non-empty string")
        if case.get("matches") != []:
            raise AssertionError(f"{where}: downgraded network patterns must expect []")
        if command in seen:
            raise AssertionError(f"{where}: duplicate downgraded command")
        seen.add(command)
        upstream_case = upstream_by_command.get(command)
        if upstream_case is not None:
            kinds = {match.get("kind") for match in upstream_case.get("matches", [])}
            if not kinds.intersection(network_kinds):
                raise AssertionError(
                    f"{where}: may not downgrade a non-network upstream case")
    for case in upstream_cases:
        kinds = {match.get("kind") for match in case.get("matches", [])}
        if kinds.intersection(network_kinds) and case["args"].get("command") not in seen:
            raise AssertionError(
                "approval-patterns.phone: an upstream network case is not downgraded: "
                + str(case["args"].get("command")))
    for case in upstream_cases:
        kinds = {match.get("kind") for match in case.get("matches", [])}
        if kinds.intersection({"rm-destructive", "git-destructive", "find-delete"}) \
                and case["args"].get("command") in seen:
            raise AssertionError("approval-patterns.phone: a destructive case may not be downgraded")


EGRESS_WRITE_METHODS = frozenset({"POST", "PUT", "PATCH", "DELETE"})


def _normalize_virtual_path(path: str) -> str:
    """The POSIX normalization both ends use on a virtual VFS path."""
    absolute = path.startswith("/")
    stack: list[str] = []
    for part in path.split("/"):
        if part in ("", "."):
            continue
        if part == "..":
            if stack:
                stack.pop()
            continue
        stack.append(part)
    joined = "/".join(stack)
    if absolute:
        return "/" + joined
    return joined or "."


def _resolve_virtual_path(path: str, workspace: str) -> str:
    joined = path if path.startswith("/") else workspace.rstrip("/") + "/" + path
    return _normalize_virtual_path(joined)


def _inside_workspace(path: str, workspace: str) -> bool:
    root = _normalize_virtual_path(workspace)
    if root == "/":
        return True
    target = _normalize_virtual_path(path)
    return target == root or target.startswith(root + "/")


def _url_host(url: str) -> str:
    return (urlsplit(url).hostname or "").lower()


def _egress_approval_decision(request: dict) -> dict:
    """Reference oracle for the host `/v1/http` Bot write approval.

    It mirrors `BotMCPRuntime.approveEgress` + `BotApprovalCoordinator`: the
    gateway only asks for POST/PUT/PATCH/DELETE. Live `bash` registrations
    attribute the write; several registrations of one Bot are one owner, while
    different Bots need the outer command's host text as a unique tie-breaker.
    With no live registration, a running workbench turn keeps the ordinary
    allow-list; otherwise one active Bot is the fallback owner and several (or
    none) fail closed. A
    `tool=egress&operation=egress.<method>&resource=host=<host>` standing Grant
    (until/session) is reusable. The vector check below is not runtime
    evidence; the Swift tests drive the real coordinator and registration.
    """
    method = str(request.get("method", "")).upper()
    url = str(request.get("url", ""))
    host = _url_host(url)
    if request.get("modelEndpoint") is True:
        return {"decision": "allow", "approvalRequests": 0, "grantScope": "none", "error": None}
    if method not in EGRESS_WRITE_METHODS:
        return {"decision": "allow", "approvalRequests": 0, "grantScope": "none", "error": None}
    session_kind = request.get("sessionKind", "chat")
    if session_kind not in ("chat", "task", "routine", "team", "proactive", "watchdog"):
        raise AssertionError(f"egress-approval: unknown sessionKind {session_kind!r}")
    capabilities = request.get("capabilities", [])
    if not isinstance(capabilities, list) \
            or any(not isinstance(capability, str) or not capability for capability in capabilities):
        raise AssertionError(f"egress-approval: capabilities must be a string list, got {capabilities!r}")
    active = int(request.get("activeBashCalls", 0))
    listed_bots = request.get("activeBots")
    if listed_bots is None:
        bots = ["bot-a"] * active if active > 0 else []
    elif not isinstance(listed_bots, list) or any(not isinstance(b, str) for b in listed_bots):
        raise AssertionError(f"egress-approval: activeBots must be a string list, got {listed_bots!r}")
    else:
        bots = list(listed_bots)
    if active > 0:
        if not bots:
            bots = ["bot-a"] * active
        if len(bots) != active:
            if len(set(bots)) == 1:
                bots = [bots[0]] * active
            else:
                raise AssertionError(
                    f"egress-approval: {active} live calls but activeBots={bots!r}")
        if request.get("sessionValid") is False:
            return {"decision": "deny", "approvalRequests": 0, "grantScope": "none",
                    "error": "bot_egress_unattributed"}
        if len(set(bots)) > 1:
            matches = int(request.get("matchingBashCalls", 0))
            if request.get("attributedHost") != host or matches != 1:
                return {"decision": "deny", "approvalRequests": 0, "grantScope": "none",
                        "error": "bot_egress_ambiguous"}
            # The unique host text is the tie-breaker; one Bot owns the card.
    else:
        if request.get("workbenchTurnActive", True) is True:
            return {"decision": "allow", "approvalRequests": 0, "grantScope": "none", "error": None}
        if request.get("sessionValid") is False:
            return {"decision": "deny", "approvalRequests": 0, "grantScope": "none",
                    "error": "bot_egress_unattributed"}
        unique = set(bots)
        if not unique:
            return {"decision": "deny", "approvalRequests": 0, "grantScope": "none",
                    "error": "bot_egress_unattributed"}
        if len(unique) > 1:
            return {"decision": "deny", "approvalRequests": 0, "grantScope": "none",
                    "error": "bot_egress_ambiguous"}
    # The host issued the Task subset at task creation; no command text, model
    # argument or standing Grant may widen it. The denial happens before the
    # coordinator presents a card.
    if session_kind == "task" and "task.network-write" not in capabilities:
        return {"decision": "deny", "approvalRequests": 0, "grantScope": "none",
                "error": "task_network_write_denied"}
    operation = "egress." + method.lower()
    resource = "host=" + host
    for grant in request.get("grants", []):
        if (grant.get("tool") == "egress" and grant.get("operation") == operation
                and grant.get("resource") == resource
                and grant.get("scope") in ("until", "session")):
            return {"decision": "allow", "approvalRequests": 0, "grantScope": "none", "error": None}
    decision = request.get("decision")
    if decision == "allow_once":
        return {"decision": "allow", "approvalRequests": 1, "grantScope": "once", "error": None}
    if decision == "always":
        return {"decision": "allow", "approvalRequests": 1, "grantScope": "until", "error": None}
    if decision in ("deny", "timeout"):
        return {"decision": "deny", "approvalRequests": 1, "grantScope": "none",
                "error": "egress_approval_denied"}
    raise AssertionError(f"egress-approval: unknown decision {decision!r}")


def _grant_directory_decision(request: dict) -> dict:
    """Reference oracle for `write`/`edit` workspace-root and directory Grants."""
    tool = request.get("tool")
    if tool not in ("write", "edit"):
        raise AssertionError(f"grant-directory: unknown tool {tool!r}")
    workspace = str(request.get("workspace", ""))
    raw = str(request.get("path", "")).strip()
    if raw == "":
        policy, resource, allowed = "ask", "unclassified", False
    else:
        target = _resolve_virtual_path(raw, workspace)
        if _inside_workspace(target, workspace):
            return {"policy": "auto", "resource": None, "decision": "allow",
                    "approvalRequests": 0, "grantScope": "none", "error": None}
        parent = posixpath.dirname(target) or "/"
        policy, resource, allowed = "ask", f"dir={parent}", False
        operation = "file.write" if tool == "write" else "file.edit"
        for grant in request.get("grants", []):
            if (grant.get("tool") == tool and grant.get("operation") == operation
                    and grant.get("resource") == resource
                    and grant.get("scope") in ("until", "session")):
                return {"policy": policy, "resource": resource, "decision": "allow",
                        "approvalRequests": 0, "grantScope": "none", "error": None}
    decision = request.get("decision")
    if decision == "allow_once":
        return {"policy": policy, "resource": resource, "decision": "allow",
                "approvalRequests": 1, "grantScope": "once", "error": None}
    if decision == "always":
        return {"policy": policy, "resource": resource, "decision": "allow",
                "approvalRequests": 1, "grantScope": "until", "error": None}
    if decision in ("deny", "timeout"):
        return {"policy": policy, "resource": resource, "decision": "deny",
                "approvalRequests": 1, "grantScope": "none", "error": "approval_denied"}
    raise AssertionError(f"grant-directory: unknown decision {decision!r}")


def validate_mcp_egress_fixture(fixture):
    """Validate the phone-only egress/identity/caller-catalog vectors."""
    if set(fixture) != MCP_EGRESS_TOP_KEYS:
        raise AssertionError(f"mcp-egress: unexpected top-level keys {sorted(set(fixture) - MCP_EGRESS_TOP_KEYS)}")
    if fixture.get("schemaVersion") != 1:
        raise AssertionError("mcp-egress: schemaVersion must be 1")
    if fixture.get("vector") != "mcp-egress.phone":
        raise AssertionError("mcp-egress: vector must be mcp-egress.phone")
    if fixture.get("upstream") != []:
        raise AssertionError("mcp-egress: phone-only vector must declare upstream: []")
    delta = fixture.get("delta")
    if not isinstance(delta, list) or not delta or not all(isinstance(item, str) and item for item in delta):
        raise AssertionError("mcp-egress: delta must be a non-empty string array")

    token = fixture.get("egressToken")
    if not isinstance(token, str) or len(token) < 16:
        raise AssertionError("mcp-egress: egressToken must be a non-empty fixture value")
    if token in ("phone-host-injects-bot-mcp-token", "phone-host-injects-mcp-key"):
        raise AssertionError("mcp-egress: egressToken must not be a Worker placeholder")

    raw_routes = fixture.get("egressRoutes")
    if not isinstance(raw_routes, list) or not raw_routes:
        raise AssertionError("mcp-egress: egressRoutes must be a non-empty array")
    routes = set()
    kinds = []
    for index, entry in enumerate(raw_routes):
        if not isinstance(entry, dict) or set(entry) != {"kind", "url"}:
            raise AssertionError(f"mcp-egress.egressRoutes[{index}]: needs only kind/url")
        if entry["kind"] not in ("bot", "user"):
            raise AssertionError(f"mcp-egress.egressRoutes[{index}]: unknown kind")
        key = _mcp_route_key(entry["url"])
        if key is None:
            raise AssertionError(f"mcp-egress.egressRoutes[{index}]: invalid URL")
        if key in routes:
            raise AssertionError(f"mcp-egress.egressRoutes[{index}]: duplicate route")
        routes.add(key)
        kinds.append(entry["kind"])
    for path in ("/mcp", "/identity/register", "/identity/cancel", "/approval"):
        if _mcp_route_key(f"http://127.0.0.1:8787{path}") not in routes:
            raise AssertionError(f"mcp-egress: missing Bot route {path}")
    if "user" not in kinds:
        raise AssertionError("mcp-egress: no user-configured connector route is covered")

    valid = fixture.get("valid")
    invalid = fixture.get("invalid")
    if not isinstance(valid, list) or not valid:
        raise AssertionError("mcp-egress: valid must be a non-empty array")
    if not isinstance(invalid, list) or not invalid:
        raise AssertionError("mcp-egress: invalid must be a non-empty array")

    names = set()
    covered = {
        "valid": {suite: set() for suite in MCP_EGRESS_SUITES},
        "invalid": {suite: set() for suite in MCP_EGRESS_SUITES},
    }
    for section, cases, accepted in (("valid", valid, True), ("invalid", invalid, False)):
        for index, case in enumerate(cases):
            where = f"mcp-egress.{section}[{index}]"
            if not isinstance(case, dict):
                raise AssertionError(f"{where}: case must be an object")
            suite = case.get("suite")
            if suite not in MCP_EGRESS_SUITES:
                raise AssertionError(f"{where}: unknown suite {suite!r}")
            unexpected = set(case) - MCP_EGRESS_CASE_KEYS[suite]
            if unexpected:
                raise AssertionError(f"{where}: unexpected keys {sorted(unexpected)}")
            name = case.get("name")
            if not isinstance(name, str) or not name:
                raise AssertionError(f"{where}: name must be a non-empty string")
            if name in names:
                raise AssertionError(f"{where}: duplicate case name {name!r}")
            names.add(name)
            boundary = case.get("boundary")
            allowed = (MCP_EGRESS_VALID_BOUNDARIES if accepted
                       else MCP_EGRESS_INVALID_BOUNDARIES)[suite]
            if boundary not in allowed:
                raise AssertionError(f"{where}: boundary {boundary!r} is not registered for {suite}")
            covered[section][suite].add(boundary)
            reason = case.get("reason")
            if not isinstance(reason, str) or not reason.strip():
                raise AssertionError(f"{where}: every case needs a reason")
            expect = case.get("expect")
            if not isinstance(expect, dict):
                raise AssertionError(f"{where}: expect must be an object")

            if suite == "egress":
                wanted = ({"admitted": True} if accepted else
                          {"admitted": False, "status": 403, "error": MCP_EGRESS_ERROR})
                if expect != wanted:
                    raise AssertionError(f"{where}: egress expect must be {wanted}")
                actual = _egress_admitted(case, token, routes)
            elif suite == "identity":
                wanted = ({"ok": True} if accepted else
                          {"ok": False, "error": "unauthorized"})
                if expect != wanted:
                    raise AssertionError(f"{where}: identity expect must be {wanted}")
                actual = _identity_registration_ok(case)
            elif suite == "tools-call":
                if accepted:
                    if expect != {"ok": True}:
                        raise AssertionError(f"{where}: accepted tools-call expect must be {{'ok': True}}")
                else:
                    error = expect.get("error")
                    if set(expect) != {"ok", "error"} or expect.get("ok") is not False \
                            or error not in ("permission_denied", "unknown_tool"):
                        raise AssertionError(f"{where}: rejected tools-call expects a known error")
                actual, actual_error = _tools_call_ok(case)
                if not accepted and actual_error != expect.get("error"):
                    raise AssertionError(
                        f"{where}: tools-call rejects with {actual_error}, expected {expect.get('error')}")
            elif suite == "egress-approval":
                actual = _egress_approval_decision(case["request"])
                if actual != expect:
                    raise AssertionError(f"{where}: egress-approval expected {expect}, got {actual}")
                actual = actual["decision"] == "allow"
            else:  # grant-directory
                actual = _grant_directory_decision(case["request"])
                if actual != expect:
                    raise AssertionError(f"{where}: grant-directory expected {expect}, got {actual}")
                # `valid` means the directory Grant hit (or the root made the
                # write auto); a miss is an approval card, not a security
                # failure, so the vector's `invalid` section is a miss check.
                actual = actual["approvalRequests"] == 0
            if actual != accepted:
                raise AssertionError(f"{where}: expected accepted={accepted}, got {actual}")

    for section, required_map in (
        ("valid", MCP_EGRESS_VALID_BOUNDARIES),
        ("invalid", MCP_EGRESS_INVALID_BOUNDARIES),
    ):
        for suite, required in required_map.items():
            missing = required - covered[section][suite]
            if missing:
                raise AssertionError(
                    f"mcp-egress: {section} {suite} misses boundaries {sorted(missing)}")

    def clone():
        return json.loads(json.dumps(fixture))

    mutation_count = 0

    def expect_failure(label, mutate):
        nonlocal mutation_count
        mutated = clone()
        mutate(mutated)
        try:
            validate_mcp_egress_fixture(mutated)
        except AssertionError:
            mutation_count += 1
            return
        raise AssertionError(f"mcp-egress mutation {label!r} unexpectedly passed")

    def find(value, section, name):
        return next(case for case in value[section] if case["name"] == name)

    expect_failure("egress-token",
                   lambda value: value.__setitem__("egressToken", "wpf0-fixture-mutated-token"))
    expect_failure("egress-placeholder-accepted",
                   lambda value: find(value, "invalid", "bot-mcp-bot-token-placeholder")[
                       "headers"].__setitem__(MCP_EGRESS_HEADER, value["egressToken"]))
    expect_failure("egress-route-removed",
                   lambda value: value.__setitem__(
                       "egressRoutes",
                       [route for route in value["egressRoutes"]
                        if route["url"] != "https://connector.example.test/mcp"]))
    expect_failure("identity-revoked-accepted",
                   lambda value: find(value, "invalid", "revoked-credential")
                       ["registry"][0].pop("revoked", None))
    expect_failure("identity-mismatch-accepted",
                   lambda value: find(value, "invalid", "mismatched-session-field")
                       ["request"].__setitem__("sessionId", "gb-main"))
    expect_failure("identity-case-folded",
                   lambda value: find(value, "invalid", "case-shifted-credential")
                       ["request"].__setitem__("sessionToken", "dshg_wpf0_fixture_main"))
    expect_failure("tools-call-hidden-accepted",
                   lambda value: find(value, "invalid", "non-main-create-teammate")
                       .__setitem__("callerBotId", "bot-a"))
    expect_failure("tools-call-unknown-renamed",
                   lambda value: find(value, "invalid", "unknown-tool")
                       .__setitem__("tool", "SendToAgent"))
    expect_failure("duplicate-name",
                   lambda value: value["valid"].append(dict(value["valid"][0])))
    expect_failure("valid-flipped",
                   lambda value: find(value, "valid", "bot-mcp-correct-token")
                       ["expect"].__setitem__("admitted", False))
    expect_failure("boundary-coverage",
                   lambda value: value.__setitem__(
                       "invalid",
                       [case for case in value["invalid"]
                        if not (case["suite"] == "identity" and case["boundary"] == "revoked")]))
    expect_failure("egress-approval-grant-hit-flipped",
                   lambda value: find(value, "valid", "post-standing-grant-hit")[
                       "expect"].__setitem__("approvalRequests", 1))
    expect_failure("egress-approval-model-endpoint-flipped",
                   lambda value: find(value, "valid", "model-endpoint-exempt")[
                       "expect"].__setitem__("decision", "deny"))
    expect_failure("grant-directory-args-digest-accepted",
                   lambda value: find(value, "invalid", "args-digest-resource")[
                       "expect"].__setitem__("resource", "dir=/dsh/workspace/shared&args=deadbeef"))
    expect_failure("grant-directory-inside-flipped",
                   lambda value: find(value, "valid", "inside-workspace-auto")[
                       "request"].__setitem__("path", "/dsh/workspace/outside.txt"))
    expect_failure("egress-approval-boundary-coverage",
                   lambda value: value.__setitem__(
                       "invalid",
                       [case for case in value["invalid"]
                        if not (case["suite"] == "egress-approval"
                                and case["boundary"] == "ambiguous")]))
    expect_failure("egress-approval-job-lifecycle-cancelled",
                   lambda value: find(value, "valid", "background-job-registration-live")[
                       "request"].__setitem__("activeBashCalls", 0))
    expect_failure("egress-approval-single-bot-flipped",
                   lambda value: find(value, "valid", "unattributed-single-bot-asks")[
                       "expect"].__setitem__("decision", "deny"))
    expect_failure("egress-approval-multi-bot-accepted",
                   lambda value: find(value, "invalid", "unattributed-several-bots")[
                       "request"].__setitem__("activeBots", ["bot-a"]))
    expect_failure("egress-approval-workbench-flipped",
                   lambda value: find(value, "valid", "unattributed-with-workbench-turn-is-workbench")[
                       "request"].__setitem__("workbenchTurnActive", False))
    expect_failure("egress-approval-task-network-write-accepted",
                   lambda value: find(value, "invalid", "task-without-network-write-denied")[
                       "request"].__setitem__(
                           "capabilities",
                           ["task.workspace:/dsh/workspace/.dshbot/agents/main",
                            "task.network-write"]))
    expect_failure("egress-approval-task-grant-bypass",
                   lambda value: find(value, "invalid",
                                      "task-without-network-write-ignores-standing-grant")[
                       "expect"].__setitem__("decision", "allow"))
    return len(valid), len(invalid), mutation_count


SAFE_INTEGER = 2**53 - 1
SESSION_ID_RE = re.compile(r"^[A-Za-z0-9._-]{1,64}$")
AT_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z$")
OBSERVATION_SOURCES = frozenset({
    "tool", "connector", "device", "device-task", "web", "subagent", "agent", "attachment",
})
OBSERVATION_ATTRIBUTES = ("source", "origin", "at", "owner", "ref")
OBSERVATION_OPEN_RE = re.compile(r'^<observation ((?:[a-z]+="[^"]*" ?){5})>\n([\s\S]*)\n</observation>$')


def parse_record_reference(raw):
    """Parse one record:// reference exactly as the frozen normalizer says."""
    if not isinstance(raw, str):
        return None
    value = raw.strip(" \t\r\n")
    if value[:9].lower() != "record://":
        return None
    rest = value[9:]
    kind, separator, tail = rest.partition("/")
    if separator != "/" or kind.lower() not in ("session", "event"):
        return None
    if kind.lower() == "event":
        if not tail or not all("0" <= char <= "9" for char in tail):
            return None
        number = int(tail)
        if number < 1 or number > SAFE_INTEGER:
            return None
        return {"kind": "event", "canonical": f"record://event/{number}", "commitSeq": number}
    if tail.count("#") != 1:
        return None
    identifier, _, fragment = tail.partition("#")
    if not fragment or not all("0" <= char <= "9" for char in fragment):
        return None
    number = int(fragment)
    if number > SAFE_INTEGER:
        return None
    if not SESSION_ID_RE.fullmatch(identifier) or identifier in (".", ".."):
        return None
    return {
        "kind": "session",
        "canonical": f"record://session/{identifier}#{number}",
        "sessionId": identifier,
        "seq": number,
    }


def record_reference_error(raw):
    """Classify one invalid reference into the golden's closed reason set."""
    if not isinstance(raw, str):
        return "syntax"
    value = raw.strip(" \t\r\n")
    if value[:9].lower() != "record://":
        return "syntax"
    rest = value[9:]
    kind, separator, tail = rest.partition("/")
    if separator != "/" or not kind:
        return "syntax"
    if kind.lower() not in ("session", "event"):
        return "authority"
    if kind.lower() == "event":
        if not tail or not all("0" <= char <= "9" for char in tail):
            return "decimal"
        return "range" if int(tail) > SAFE_INTEGER or int(tail) < 1 else "syntax"
    if tail.count("#") != 1:
        return "syntax"
    identifier, _, fragment = tail.partition("#")
    if not SESSION_ID_RE.fullmatch(identifier) or identifier in (".", ".."):
        return "session-id"
    if not fragment:
        return "syntax"
    if not all("0" <= char <= "9" for char in fragment):
        return "decimal"
    return "range" if int(fragment) > SAFE_INTEGER else "syntax"


def escape_observation_attribute(value):
    out = []
    for char in value:
        if char == "&":
            out.append("&amp;")
        elif char == '"':
            out.append("&quot;")
        elif char == "<":
            out.append("&lt;")
        elif char == ">":
            out.append("&gt;")
        elif char in "\n\r\t" or ord(char) < 0x20 or ord(char) == 0x7f:
            out.append("\\u%04x" % ord(char))
        else:
            out.append(char)
    return "".join(out)


def unescape_observation_attribute(value):
    return (value.replace("&lt;", "<").replace("&gt;", ">")
            .replace("&quot;", '"').replace("&amp;", "&"))


def escape_observation_body(text):
    return re.sub(r"<(?=\s*/?\s*observation\b)", lambda _match: "\\u003c", text, flags=re.IGNORECASE)


def unescape_observation_body(text):
    return re.sub(r"\\u003c(?=\s*/?\s*observation\b)", "<", text, flags=re.IGNORECASE)


def encode_observation_envelope(envelope):
    attributes = " ".join(
        f'{name}="{escape_observation_attribute(str(envelope[name]))}"'
        for name in OBSERVATION_ATTRIBUTES)
    return (f"<observation {attributes}>\n"
            f"{escape_observation_body(envelope['text'])}\n</observation>")


def decode_observation_envelope(encoded):
    match = OBSERVATION_OPEN_RE.fullmatch(encoded)
    if match is None:
        return None
    fields = re.findall(r'([a-z]+)="([^"]*)"', match.group(1))
    if [name for name, _ in fields] != list(OBSERVATION_ATTRIBUTES):
        return None
    envelope = {name: unescape_observation_attribute(value) for name, value in fields}
    envelope["text"] = unescape_observation_body(match.group(2))
    if envelope["source"] not in OBSERVATION_SOURCES:
        return None
    if not AT_RE.fullmatch(envelope["at"]):
        return None
    if parse_record_reference(envelope["ref"]) is None:
        return None
    if not envelope["origin"] or not envelope["owner"]:
        return None
    return envelope


def check_observation_envelope_shape(envelope, where):
    check(envelope, "observation-envelope.schema.json", where)
    if envelope.get("source") not in OBSERVATION_SOURCES:
        raise AssertionError(f"{where}: unknown observation source")
    if parse_record_reference(envelope.get("ref")) is None:
        raise AssertionError(f"{where}: envelope ref is not a canonical record reference")
    if not AT_RE.fullmatch(envelope.get("at", "")):
        raise AssertionError(f"{where}: envelope time is not UTC RFC3339 with milliseconds")


def validate_record_reference_fixture(fixture):
    valid = fixture.get("valid")
    invalid = fixture.get("invalid")
    if not isinstance(valid, list) or not valid:
        raise AssertionError("record-reference.phone: valid must be a non-empty array")
    if not isinstance(invalid, list) or not invalid:
        raise AssertionError("record-reference.phone: invalid must be a non-empty array")
    kinds = set()
    normalizations = set()
    for index, case in enumerate(valid):
        parsed = parse_record_reference(case.get("input"))
        if parsed is None:
            raise AssertionError(f"record-reference.valid[{index}] unexpectedly rejected")
        kind = case.get("kind")
        if parsed["kind"] != kind:
            raise AssertionError(f"record-reference.valid[{index}] kind mismatch")
        if parsed.get("sessionId") != case.get("sessionId") or parsed.get("seq") != case.get("seq"):
            raise AssertionError(f"record-reference.valid[{index}] session parse mismatch")
        if parsed.get("commitSeq") != case.get("commitSeq"):
            raise AssertionError(f"record-reference.valid[{index}] event parse mismatch")
        canonical = case.get("canonical")
        if parsed["canonical"] != canonical:
            raise AssertionError(f"record-reference.valid[{index}] canonical mismatch")
        check(canonical, "record-reference.schema.json", f"record-reference.valid[{index}]")
        kinds.add(kind)
        if case["input"].strip() != case["input"]:
            normalizations.add("whitespace")
        if case["input"].strip()[:9] != "record://":
            normalizations.add("case")
        if "#0" in case["input"][:-1] and "#00" in case["input"]:
            normalizations.add("leading-zero")
    for index, case in enumerate(invalid):
        if parse_record_reference(case.get("input")) is not None:
            raise AssertionError(f"record-reference.invalid[{index}] unexpectedly accepted")
        expected = case.get("reason")
        actual = record_reference_error(case.get("input"))
        if actual != expected:
            raise AssertionError(
                f"record-reference.invalid[{index}] reason {actual!r} != {expected!r}")
    if kinds != {"session", "event"}:
        raise AssertionError("record-reference.phone: both record kinds need a valid case")
    if not {"whitespace", "case", "leading-zero"}.issubset(normalizations):
        raise AssertionError(f"record-reference.phone: normalization coverage is incomplete: {normalizations}")
    reasons = {case.get("reason") for case in invalid}
    if not {"syntax", "session-id", "authority", "decimal", "range"}.issubset(reasons):
        raise AssertionError(f"record-reference.phone: invalid reason coverage is incomplete: {reasons}")
    return len(valid), len(invalid), 0


def validate_observation_envelope_fixture(fixture):
    valid = fixture.get("valid")
    invalid = fixture.get("invalid")
    decode_errors = fixture.get("decodeErrors")
    if not isinstance(valid, list) or not valid:
        raise AssertionError("observation-envelope.phone: valid must be a non-empty array")
    if not isinstance(invalid, list) or not invalid:
        raise AssertionError("observation-envelope.phone: invalid must be a non-empty array")
    if not isinstance(decode_errors, list) or not decode_errors:
        raise AssertionError("observation-envelope.phone: decodeErrors must be a non-empty array")
    sources = set()
    escaped_marker = False
    for index, case in enumerate(valid):
        envelope = case.get("envelope")
        check_observation_envelope_shape(envelope, f"observation-envelope.valid[{index}]")
        encoded = encode_observation_envelope(envelope)
        if encoded != case.get("encoded"):
            raise AssertionError(f"observation-envelope.valid[{index}] encoding mismatch")
        decoded = decode_observation_envelope(encoded)
        if decoded != envelope:
            raise AssertionError(f"observation-envelope.valid[{index}] round-trip mismatch")
        sources.add(envelope["source"])
        if "\\u003c" in encoded:
            escaped_marker = True
    for index, case in enumerate(invalid):
        try:
            check_observation_envelope_shape(case.get("envelope"), f"observation-envelope.invalid[{index}]")
        except Exception:
            continue
        raise AssertionError(f"observation-envelope.invalid[{index}] unexpectedly validated")
    for index, case in enumerate(decode_errors):
        if decode_observation_envelope(case.get("encoded", "")) is not None:
            raise AssertionError(f"observation-envelope.decodeErrors[{index}] unexpectedly decoded")
    if not escaped_marker:
        raise AssertionError("observation-envelope.phone: a valid case must exercise marker escaping")
    if not {"web", "connector", "device", "subagent", "attachment", "tool"}.issubset(sources):
        raise AssertionError(f"observation-envelope.phone: source coverage is incomplete: {sources}")
    return len(valid), len(invalid), len(decode_errors), 0


def validate_record_query_fixture(fixture):
    valid = fixture.get("valid")
    invalid = fixture.get("invalid")
    if not isinstance(valid, list) or not valid:
        raise AssertionError("record-query.phone: valid must be a non-empty array")
    if not isinstance(invalid, list) or not invalid:
        raise AssertionError("record-query.phone: invalid must be a non-empty array")
    for index, case in enumerate(valid):
        result = case.get("result")
        check(result, "record-query.schema.json", f"record-query.valid[{index}]")
        data = result.get("data", {})
        for hit in data.get("hits", []):
            if parse_record_reference(hit.get("ref")) is None:
                raise AssertionError(f"record-query.valid[{index}]: hit ref is invalid")
        for line in data.get("lines", []):
            if parse_record_reference(line.get("ref")) is None:
                raise AssertionError(f"record-query.valid[{index}]: line ref is invalid")
        replaced = data.get("replacedRange")
        if replaced is not None:
            if parse_record_reference(replaced.get("startRef")) is None \
                    or parse_record_reference(replaced.get("endRef")) is None:
                raise AssertionError(f"record-query.valid[{index}]: replacedRange ref is invalid")
    for index, case in enumerate(invalid):
        result = case.get("result")
        check(result, "record-query.schema.json", f"record-query.invalid[{index}]")
        if result.get("ok") is not False:
            raise AssertionError(f"record-query.invalid[{index}]: expected a failure result")
    erased = [case for case in invalid
              if (case.get("result", {}).get("error", {}).get("code") == "record_erased")]
    if not erased:
        raise AssertionError("record-query.phone: missing the record_erased failure vector")
    erased_error = erased[0]["result"]["error"]
    if erased_error.get("message") != "该记录已被抹除":
        raise AssertionError("record-query.phone: record_erased message must be 该记录已被抹除")
    recall = fixture.get("compactionRecall")
    if not isinstance(recall, dict):
        raise AssertionError("record-query.phone: compactionRecall is required")
    events = recall.get("events")
    if not isinstance(events, list) or not events:
        raise AssertionError("record-query.phone: compactionRecall.events is required")
    by_seq = {event.get("seq"): event for event in events}
    original = by_seq.get(3)
    checkpoint = by_seq.get(20)
    if original is None or checkpoint is None:
        raise AssertionError("record-query.phone: compactionRecall needs seq 3 and seq 20")
    if not (parse_record_reference(recall.get("originalRef"))
            and parse_record_reference(recall.get("checkpointRef"))):
        raise AssertionError("record-query.phone: compactionRecall refs are invalid")
    if recall.get("originalContains") not in json.dumps(original, ensure_ascii=False):
        raise AssertionError("record-query.phone: original line does not carry originalContains")
    op = checkpoint.get("surfaceOp") or {}
    if op.get("op") != "replace" or op.get("startSeq") != 3 or op.get("endSeq") != 9:
        raise AssertionError("record-query.phone: checkpoint surfaceOp is not the frozen replace range")
    if recall.get("checkpointRange") != {"start": 3, "end": 9}:
        raise AssertionError("record-query.phone: checkpointRange mismatch")
    if original.get("surfaceOp") != "append":
        raise AssertionError("record-query.phone: the original line must still be an append record")
    return len(valid), len(invalid), 0


def validate_erasure_event_fixture(fixture):
    if fixture.get("vector") != "erasure-event.phone":
        raise AssertionError("erasure-event.phone: vector must be erasure-event.phone")
    if fixture.get("upstream") != []:
        raise AssertionError("erasure-event.phone: phone-only vector must declare upstream: []")
    delta = fixture.get("delta")
    if not isinstance(delta, list) or not delta:
        raise AssertionError("erasure-event.phone: delta must be a non-empty array")
    valid = fixture.get("valid")
    invalid = fixture.get("invalid")
    if not isinstance(valid, list) or not valid:
        raise AssertionError("erasure-event.phone: valid must be a non-empty array")
    if not isinstance(invalid, list) or not invalid:
        raise AssertionError("erasure-event.phone: invalid must be a non-empty array")
    for index, case in enumerate(valid):
        where = f"erasure-event.valid[{index}]"
        data = case.get("data")
        check(data, "erasure-event.schema.json", where)
        events = data["erasedEvents"]
        records = [event["record"] for event in events]
        if len(records) != len(set(records)):
            raise AssertionError(f"{where}: erased event records must be unique")
        if sum(event["payloadBytes"] for event in events) != data["erasedBytes"]:
            raise AssertionError(f"{where}: erasedBytes must equal the payload byte sum")
        for range_case in data["memoryVersions"]:
            versions = range_case["versions"]
            if versions != sorted(set(versions)):
                raise AssertionError(f"{where}: versions must be sorted and unique")
        session_records = data.get("erasedSessionRecords", [])
        if len(session_records) != len({item["record"] for item in session_records}):
            raise AssertionError(f"{where}: erased session records must be unique")
        for item in session_records:
            match = re.fullmatch(r"record://session/([A-Za-z0-9._-]{1,64})#(0|[1-9][0-9]*)",
                                 item["record"], re.ASCII)
            if match is None or match.group(1) != item["sessionId"] \
                    or int(match.group(2)) != item["seq"]:
                raise AssertionError(f"{where}: erased session record must match sessionId and seq")
        for epoch in data.get("sessionEpochs", []):
            if epoch["fromSessionId"] == epoch["toSessionId"]:
                raise AssertionError(f"{where}: a session epoch must switch to a new session id")
    for index, case in enumerate(invalid):
        rejects(case.get("data"), "erasure-event.schema.json",
                f"erasure-event.invalid[{index}]")

    count = 0

    def expect_failure(label, mutate):
        nonlocal count
        mutated = json.loads(json.dumps(fixture))
        mutate(mutated)
        try:
            validate_erasure_event_fixture(mutated)
        except Exception:  # noqa: BLE001 - SpecError is not an AssertionError
            count += 1
            return
        raise AssertionError(f"erasure-event mutation {label!r} unexpectedly passed")

    expect_failure("targets-empty",
                   lambda value: value["valid"][0]["data"].__setitem__("targets", []))
    expect_failure("record-zero",
                   lambda value: value["valid"][0]["data"]["erasedEvents"][0]
                   .__setitem__("record", "record://event/0"))
    expect_failure("byte-sum",
                   lambda value: value["valid"][0]["data"].__setitem__("erasedBytes", 1))
    expect_failure("session-seq",
                   lambda value: value["valid"][0]["data"]["erasedSessionRecords"][0]
                   .__setitem__("seq", 9))
    expect_failure("session-epoch-identity",
                   lambda value: value["valid"][0]["data"]["sessionEpochs"][0]
                   .__setitem__("toSessionId", "gb-main"))
    return len(valid), len(invalid), count


def mutation_count_for_record_contracts(reference_fixture, envelope_fixture, query_fixture):
    """Each mutation must make the corresponding reference validator reject."""
    count = 0

    def expect_failure(label, action):
        nonlocal count
        try:
            action()
        except Exception:
            count += 1
            return
        raise AssertionError(f"record-contract mutation {label!r} unexpectedly passed")

    mutated = json.loads(json.dumps(reference_fixture))
    mutated["valid"][0]["canonical"] = "record://session/gb-main#+1"
    expect_failure("reference-canonical", lambda: validate_record_reference_fixture(mutated))

    mutated = json.loads(json.dumps(reference_fixture))
    mutated["valid"][5]["input"] = "record://event/0"
    expect_failure("reference-event-zero", lambda: validate_record_reference_fixture(mutated))

    mutated = json.loads(json.dumps(envelope_fixture))
    mutated["valid"][0]["encoded"] = mutated["valid"][0]["encoded"].replace("</observation>", "")
    expect_failure("envelope-close", lambda: validate_observation_envelope_fixture(mutated))

    mutated = json.loads(json.dumps(envelope_fixture))
    mutated["valid"][5]["encoded"] = mutated["valid"][5]["envelope"]["text"]
    expect_failure("envelope-escape", lambda: validate_observation_envelope_fixture(mutated))

    mutated = json.loads(json.dumps(query_fixture))
    mutated["valid"][0]["result"]["scope"] = "all"
    expect_failure("record-query-scope", lambda: validate_record_query_fixture(mutated))

    mutated = json.loads(json.dumps(query_fixture))
    mutated["compactionRecall"]["events"] = [
        event for event in mutated["compactionRecall"]["events"] if event.get("seq") != 3]
    expect_failure("compaction-original", lambda: validate_record_query_fixture(mutated))
    return count


def check_overlays():
    manifest = load_json(BOT / "export-manifest.json")
    for overlay_path in sorted((BOT / "golden").glob("*.phone.json")):
        overlay = load_json(overlay_path)
        base_name = overlay_path.name[:-len(".phone.json")] + ".json"
        source = overlay.get("source", {})
        declared = overlay.get("upstream")
        if isinstance(declared, str):
            declared = [declared]
        elif isinstance(declared, dict):
            declared = list(declared.values())
        elif declared is None:
            declared = [base_name]
        elif isinstance(declared, list):
            if any(not isinstance(item, str) for item in declared):
                raise AssertionError(f"{overlay_path.name}: invalid upstream reference")
        else:
            raise AssertionError(f"{overlay_path.name}: invalid upstream reference")
        if declared == []:
            # A phone-only vector has no upstream counterpart. Only the
            # explicitly registered phone-only files are allowed to use this
            # form; every other phone delta still extends a named upstream
            # export.
            if overlay_path.name not in PHONE_ONLY_VECTORS:
                raise AssertionError(f"{overlay_path.name}: phone-only vectors are not registered")
            if base_name in manifest.get("upstream", []):
                raise AssertionError(f"{overlay_path.name}: phone-only vector shadows upstream {base_name}")
            if source.get("checkout") != manifest.get("source", {}).get("checkout"):
                raise AssertionError(f"{overlay_path.name}: source.checkout differs from export-manifest.json")
            if overlay.get("vector") != overlay_path.name[:-5]:
                raise AssertionError(f"{overlay_path.name}: vector must be {overlay_path.name[:-5]!r}")
            continue
        upstream = load(base_name)
        # Most exports carry a `checkout`; the attachment export carries the
        # same pinned SHA under `commit`. Compare the provenance the upstream
        # file actually records instead of inventing a second source field.
        upstream_source = upstream.get("source", {})
        upstream_provenance = upstream_source.get("checkout", upstream_source.get("commit"))
        if source.get("checkout") != upstream_provenance:
            raise AssertionError(f"{overlay_path.name}: source.checkout differs from {base_name}")
        if base_name not in declared:
            raise AssertionError(f"{overlay_path.name}: upstream must include {base_name}")
        assert_append_only(upstream, overlay, overlay_path.name)
        # The overlay's own case containers must be mergeable; the merged
        # fixture is validated by the per-vector checks below.
        for key in overlay:
            if key in METADATA_KEYS:
                continue
            if not isinstance(overlay[key], (dict, list, str)):
                raise AssertionError(f"{overlay_path.name}.{key}: overlay content must be an object, array or note string")


def schema(name: str):
    path = BOT / name
    if not path.is_file():
        # Memory/wake/routine schemas moved to the phoneDSH-owned v2 tree at
        # the 2026-11-10 handover. v1 vectors that exercise the shared routine
        # shape (authority.phone.json) must validate against that owner.
        path = ROOT / "spec" / "bot" / "v2" / name
    return json.loads(path.read_text(encoding="utf-8"))


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


GRANT_SNAPSHOT_TYPE = "authz.grant_snapshot"


def check_event(instance, schema_name: str, where: str) -> None:
    """Validate an envelope plus the type-specific `data` shape it names."""
    check(instance, schema_name, where)
    if schema_name == "event-envelope.schema.json" and instance.get("type") == GRANT_SNAPSHOT_TYPE:
        check(instance.get("data"), "authz-grant-snapshot.schema.json", f"{where}.data")


def rejects_event(instance, schema_name: str, where: str) -> None:
    try:
        check_event(instance, schema_name, where)
    except Exception:
        return
    raise AssertionError(f"{where}: negative fixture unexpectedly validates")


def expect_rule_violation(label: str, predicate) -> None:
    """Mutation self-check: the predicate must raise for a deliberately wrong case."""
    try:
        predicate()
    except AssertionError:
        return
    raise AssertionError(f"authority mutation {label!r} unexpectedly passed")


def resolve_task_authorization(workspace_root: str, requested) -> dict:
    """Reference oracle for `spec/bot/v1/README.md` §2.5.

    The Swift `BotTaskAuthorization.resolve` must produce exactly this shape:
    relative entries join the workspace root, `.`/`..` normalize, duplicates
    collapse, and any directory outside the workspace sets the explicit
    outside-workspace flag. Empty values and more than 32 entries are rejected.
    Network write and task delegation are always false for a child in this
    revision (there is no Task argument that raises them).
    """
    if not isinstance(requested, list):
        raise AssertionError("allowed_write_directories must be an array")
    if len(requested) > 32:
        raise AssertionError("at most 32 allowed_write_directories entries are accepted")
    root = posixpath.normpath(workspace_root)
    directories: list[str] = []
    for entry in requested:
        if not isinstance(entry, str) or not entry.strip():
            raise AssertionError("allowed_write_directories entries must be non-empty strings")
        value = entry.strip()
        if value == "~" or value.startswith("~/"):
            raise AssertionError("the vector oracle cannot expand ~; fixtures stay absolute or relative")
        if not value.startswith("/"):
            value = posixpath.join(root, value)
        value = posixpath.normpath(value)
        if value not in directories:
            directories.append(value)
    if not directories:
        directories = [root]
    outside = any(directory != root and not directory.startswith(root + "/")
                  for directory in directories)
    return {
        "allowedWriteDirectories": directories,
        "canWriteOutsideWorkspace": outside,
        "canNetworkWrite": False,
        "canDelegateTasks": False,
    }


def assert_creator_expectation(case: dict) -> None:
    expected = case["expected"]
    creator = case["creator"]
    if expected["creatorOrigin"] != creator["origin"]:
        raise AssertionError("expected.creatorOrigin disagrees with the creator")
    if expected["creatorAuthorization"] != creator["authorization"]:
        raise AssertionError("expected.creatorAuthorization disagrees with the creator")
    needs = creator["origin"] != "user"
    if expected["creationNeedsConfirmation"] != needs:
        raise AssertionError("creationNeedsConfirmation disagrees with the frozen rule")


def assert_change_expectation(case: dict) -> bool:
    expected = case["expectedConfirmation"]
    current, patch = case["current"], case["patch"]
    boundary = case["boundary"]
    if boundary == "delivery":
        derived = patch.get("delivery") == "interrupt" and current.get("delivery") != "interrupt"
    elif boundary == "urgent":
        derived = patch.get("urgent") is True and current.get("urgent") is not True
    elif boundary == "enable":
        derived = case["action"] == "resume" and patch.get("enabled") is True
    elif boundary == "schedule-frequency":
        old, new = current.get("schedule", {}), patch.get("schedule", {})
        if old.get("kind") == new.get("kind") == "interval":
            derived = new.get("everyMinutes", 0) < old.get("everyMinutes", 0)
        elif old.get("kind") == new.get("kind") and old.get("kind") in {"daily", "weekly"}:
            derived = False
        else:
            return False
    else:
        raise AssertionError(f"unregistered boundary {boundary!r}")
    if derived != expected:
        raise AssertionError("expectedConfirmation disagrees with the frequency/delivery rule")
    return True


def assert_task_expectation(case: dict) -> None:
    actual = resolve_task_authorization(case["workspaceRoot"], case["requested"])
    if actual != case["expected"]:
        raise AssertionError(f"resolved authorization disagrees with expected: {actual}")
    if actual["canNetworkWrite"] or actual["canDelegateTasks"]:
        raise AssertionError("a Task child may not gain network-write or delegation")
    outside = actual["canWriteOutsideWorkspace"]
    if outside != case["expected"]["canWriteOutsideWorkspace"]:
        raise AssertionError("canWriteOutsideWorkspace disagrees with the resolved directories")


def assert_teammate_author_expectation(case: dict) -> None:
    authority, expected = case["authority"], case["expected"]
    if authority.get("isUserTurn"):
        authorization = "user-turn"
        approval = None
    else:
        authorization = "user-confirmed"
        approval = authority.get("approvalID")
        if not approval:
            raise AssertionError("a non-user author needs an approvalID")
    if authorization != expected["authorization"] or approval != expected["approvalID"]:
        raise AssertionError("author expectation disagrees with the frozen rule")


def validate_authority_fixture(fixture) -> tuple[int, int, int]:
    if fixture.get("schemaVersion") != 1:
        raise AssertionError("authority: schemaVersion must be 1")
    if fixture.get("vector") != "authority.phone":
        raise AssertionError("authority: vector must be authority.phone")
    if fixture.get("upstream") != []:
        raise AssertionError("authority: phone-only vector must declare upstream: []")
    delta = fixture.get("delta")
    if not isinstance(delta, list) or not delta or not all(isinstance(item, str) for item in delta):
        raise AssertionError("authority: delta must be a non-empty string array")
    valid = fixture.get("valid")
    invalid = fixture.get("invalid")
    if not isinstance(valid, dict) or not isinstance(invalid, list) or not invalid:
        raise AssertionError("authority: valid must be an object and invalid a non-empty array")

    template = valid.get("routineTemplate")
    if not isinstance(template, dict):
        raise AssertionError("authority: routineTemplate must be an object")
    check(template, "routine.schema.json", "authority.routineTemplate")
    if not template.get("completion_criteria") or not template.get("constraints"):
        raise AssertionError("authority: routineTemplate must carry completion_criteria and constraints")

    mutations = 0
    creator_cases = valid.get("routineCreators")
    if not isinstance(creator_cases, list) or not creator_cases:
        raise AssertionError("authority: routineCreators must be a non-empty array")
    for index, case in enumerate(creator_cases):
        where = f"authority.routineCreators[{index}]"
        routine = dict(template)
        routine["creator"] = case["creator"]
        check(routine, "routine.schema.json", where)
        assert_creator_expectation(case)
        mutated = json.loads(json.dumps(case))
        mutated["expected"]["creationNeedsConfirmation"] = not mutated["expected"]["creationNeedsConfirmation"]
        expect_rule_violation(f"{where}/flip-confirmation",
                              lambda mutated=mutated: assert_creator_expectation(mutated))
        mutations += 1

    change_cases = valid.get("routineChanges")
    if not isinstance(change_cases, list) or not change_cases:
        raise AssertionError("authority: routineChanges must be a non-empty array")
    for index, case in enumerate(change_cases):
        where = f"authority.routineChanges[{index}]"
        if not isinstance(case.get("expectedConfirmation"), bool):
            raise AssertionError(f"{where}: expectedConfirmation must be a boolean")
        derived = assert_change_expectation(case)
        if derived:
            mutated = json.loads(json.dumps(case))
            mutated["expectedConfirmation"] = not mutated["expectedConfirmation"]
            expect_rule_violation(f"{where}/flip-confirmation",
                                  lambda mutated=mutated: assert_change_expectation(mutated))
            mutations += 1

    task_cases = valid.get("taskAuthorizations")
    if not isinstance(task_cases, list) or not task_cases:
        raise AssertionError("authority: taskAuthorizations must be a non-empty array")
    for index, case in enumerate(task_cases):
        where = f"authority.taskAuthorizations[{index}]"
        assert_task_expectation(case)
        mutated = json.loads(json.dumps(case))
        mutated["expected"]["canWriteOutsideWorkspace"] = not case["expected"]["canWriteOutsideWorkspace"]
        expect_rule_violation(f"{where}/flip-outside",
                              lambda mutated=mutated: assert_task_expectation(mutated))
        mutations += 1

    author_cases = valid.get("teammateAuthors")
    if not isinstance(author_cases, list) or not author_cases:
        raise AssertionError("authority: teammateAuthors must be a non-empty array")
    for index, case in enumerate(author_cases):
        where = f"authority.teammateAuthors[{index}]"
        assert_teammate_author_expectation(case)
        mutated = json.loads(json.dumps(case))
        if case["authority"].get("isUserTurn"):
            mutated["expected"]["authorization"] = "user-confirmed"
            mutated["expected"]["approvalID"] = "approval-mutated"
        else:
            mutated["authority"]["approvalID"] = None
            mutated["expected"]["approvalID"] = None
            mutated["expected"]["authorization"] = "user-turn"
        expect_rule_violation(f"{where}/flip-authorization",
                              lambda mutated=mutated: assert_teammate_author_expectation(mutated))
        mutations += 1

    invalid_creators = [case for case in invalid if case.get("suite") == "routine-schema"]
    if not invalid_creators:
        raise AssertionError("authority: no invalid routine creator fixture")
    for index, case in enumerate(invalid_creators):
        routine = dict(template)
        routine["creator"] = case["creator"]
        rejects(routine, "routine.schema.json", f"authority.invalid[{index}]")
    task_invalid = [case for case in invalid if case.get("suite") == "task-authorization"]
    if not task_invalid:
        raise AssertionError("authority: no invalid Task authorization fixture")
    for index, case in enumerate(task_invalid):
        try:
            resolve_task_authorization(case["workspaceRoot"], case["requested"])
        except AssertionError:
            continue
        raise AssertionError(f"authority.invalid[{index}]: negative Task authorization unexpectedly passed")
    teammate_invalid = [case for case in invalid if case.get("suite") == "teammate-author"]
    if not teammate_invalid:
        raise AssertionError("authority: no invalid CreateTeammate author fixture")
    for index, case in enumerate(teammate_invalid):
        try:
            assert_teammate_author_expectation({
                "authority": case["authority"],
                "expected": {"authorization": "user-confirmed",
                             "approvalID": case["authority"].get("approvalID")},
            })
        except AssertionError:
            continue
        raise AssertionError(f"authority.invalid[{index}]: negative teammate author unexpectedly passed")
    return (len(creator_cases), len(change_cases), len(task_cases), mutations)


def _content_card_entries(catalog):
    p0 = catalog.get("p0")
    if not isinstance(p0, list):
        raise AssertionError("tool-catalog.phone: p0 must be an array")
    entries = {}
    for item in p0:
        if not isinstance(item, dict):
            continue
        name = item.get("name")
        if name in CONTENT_CARD_FINAL_TOOLS:
            if name in entries:
                raise AssertionError(f"tool-catalog.phone: duplicate p0 tool {name!r}")
            entries[name] = item
    return entries


def validate_content_card_final(catalog):
    """Require the five content-card tools to advertise optional final:false.

    The flag is control metadata, not card content: it must be a boolean whose
    default is false and must never be required, so omitted/false keeps the
    previous mid-task behaviour. The semantic suppression itself is proven by
    the Swift and TS runtime tests.
    """
    entries = _content_card_entries(catalog)
    if sorted(entries) != sorted(CONTENT_CARD_FINAL_TOOLS):
        missing = sorted(set(CONTENT_CARD_FINAL_TOOLS) - set(entries))
        raise AssertionError(f"tool-catalog.phone: missing content-card tools {missing}")
    for name in CONTENT_CARD_FINAL_TOOLS:
        schema = entries[name].get("inputSchema")
        if not isinstance(schema, dict):
            raise AssertionError(f"tool-catalog.phone.{name}: inputSchema must be an object")
        properties = schema.get("properties")
        if not isinstance(properties, dict) or "final" not in properties:
            raise AssertionError(f"tool-catalog.phone.{name}: inputSchema must declare final")
        validate_json(properties["final"], CONTENT_CARD_FINAL_SCHEMA,
                      f"tool-catalog.phone.{name}.final")
        required = schema.get("required", [])
        if not isinstance(required, list):
            raise AssertionError(f"tool-catalog.phone.{name}: required must be an array")
        if "final" in required:
            raise AssertionError(f"tool-catalog.phone.{name}: final must stay optional")
    return len(CONTENT_CARD_FINAL_TOOLS)


def content_card_final_mutations(catalog):
    """Mutation self-check: each wrong final declaration must be rejected."""
    count = 0

    def expect_failure(label, mutate):
        nonlocal count
        mutated = copy.deepcopy(catalog)
        entries = _content_card_entries(mutated)
        mutate(entries["show_progress"])
        try:
            validate_content_card_final(mutated)
        except Exception:
            count += 1
            return
        raise AssertionError(f"content-card-final mutation {label!r} unexpectedly passed")

    expect_failure("missing",
                   lambda entry: entry["inputSchema"]["properties"].pop("final"))
    expect_failure("wrong-type",
                   lambda entry: entry["inputSchema"]["properties"].__setitem__(
                       "final", {"type": "string", "default": False, "description": "x"}))
    expect_failure("default-true",
                   lambda entry: entry["inputSchema"]["properties"]["final"].__setitem__(
                       "default", True))
    expect_failure("required",
                   lambda entry: entry["inputSchema"].setdefault("required", []).append("final"))
    return count


# --- P25 store / user-action transaction vectors (phone-owned) -----------------

STORE_ERRORS = frozenset({
    "INVALID_EVENT", "SCHEMA_TOO_NEW", "EPHEMERAL_HAS_COMMIT_SEQ", "UNKNOWN_REQUIRED_EVENT",
    "COMMIT_SEQ_ASSIGNED_BY_STORE", "MISSING_COMMIT_SEQ",
    "invalidTransition", "invalidCursor", "invalidConfiguration", "corrupted",
    "staleLease", "unknownEffect", "schemaTooNew:4", "commitGap:2:3",
    "simulatedCrash:abort-before-commit", "simulatedCrash:abort-after-commit",
})
TERMINAL_EFFECT_STATES = frozenset({"acked", "dead_letter", "canceled"})
EFFECT_STATES = frozenset({
    "pending", "leased", "failed", "acked", "dead_letter", "needs_reconciliation",
    "cancel_requested", "canceled",
})
RECONCILIATION_REASONS = frozenset({
    "unknown-outcome", "generation-conflict", "receiver-mismatch",
})


def _store_source(value, where):
    if not isinstance(value, str) or not re.fullmatch(
            r"(Tests|Sources|examples)/[^:\s]+:\d+(-\d+)?", value):
        raise AssertionError(f"{where}: source must be a file:line reference")


def _store_canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def _store_digest(value):
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def _json_equal(expected, actual):
    if expected is None or actual is None:
        return expected is None and actual is None
    if isinstance(expected, bool) or isinstance(actual, bool):
        return isinstance(expected, bool) and isinstance(actual, bool) and expected == actual
    if isinstance(expected, (int, float)) and isinstance(actual, (int, float)):
        return expected == actual
    if isinstance(expected, str) and isinstance(actual, str):
        return expected == actual
    if isinstance(expected, list) and isinstance(actual, list):
        return len(expected) == len(actual) and all(
            _json_equal(left, right) for left, right in zip(expected, actual))
    if isinstance(expected, dict) and isinstance(actual, dict):
        return all(key in actual and _json_equal(value, actual[key])
                   for key, value in expected.items())
    return False


def _expect_store(expect, observation, where):
    if expect is None:
        return
    if not isinstance(expect, dict):
        raise AssertionError(f"{where}: expect must be an object or null")
    for key, value in expect.items():
        if key == "lastErrorContains":
            text = observation.get("lastError") or ""
            if not isinstance(text, str) or value not in text:
                raise AssertionError(f"{where}: lastError does not contain {value!r}")
            continue
        if key == "lastErrorNotContains":
            text = observation.get("lastError") or ""
            if isinstance(text, str) and value in text:
                raise AssertionError(f"{where}: lastError unexpectedly contains {value!r}")
            continue
        actual = observation.get(key)
        if not _json_equal(value, actual):
            raise AssertionError(f"{where}.{key}: expected {value!r}, got {actual!r}")


def _default_max_attempts(policy, idempotent):
    if policy == "network-idempotent":
        return 5
    if policy == "local-idempotent":
        return 2
    if policy in ("local-nonidempotent", "network-nonidempotent"):
        return 1
    return 2 if idempotent else 1


def _retry_delay(policy, attempt):
    if policy != "network-idempotent":
        return 0
    exponent = max(0, min(8, attempt - 1))
    return min(1000 * (1 << exponent), 300_000)


def _safe_error(text):
    import re as _re
    text = _re.sub(r"\bsk-[A-Za-z0-9_-]{8,}\b", "[redacted]", text)
    text = _re.sub(r"(?i)\bBearer\s+[A-Za-z0-9._~+/-]+=*", "[redacted]", text)
    return text[:500]


class _StoreModelError(Exception):
    def __init__(self, code):
        super().__init__(code)
        self.code = code


class _StoreModel:
    def __init__(self, case, open_failed=False):
        self.clock = case.get("clock", 1000)
        self.lease_ttl = case.get("leaseTTLms", 30_000)
        self.ephemeral_capacity = case.get("ephemeralCapacity", 256)
        self.head = 0
        self.events = {}
        self.ids = {}
        self.effects = {}
        self.nonces = {}
        self.leases = {}
        self.inbox = {}
        self.inbox_executions = {}
        self.crash_point = None
        self.closed = False
        self.version = 3
        self.migrated_from = 0
        self.open_failed = open_failed
        self.ephemeral = []
        self.dropped = 0
        self.effect_event_ids = 0
        setup = case.get("setup")
        user_version = 2
        if setup:
            user_version = int(setup.get("userVersion", 2))
            self.migrated_from = user_version
            for event in setup.get("events", []):
                seq = event["commitSeq"]
                self.events[seq] = event
                self.ids[event["eventId"]] = seq
                self.head = max(self.head, seq)
            for nonce in setup.get("nonces", []):
                self.nonces[(nonce["botId"], nonce["nonce"])] = nonce["eventId"]
        # A refused migration rolls back: the file keeps its old version and
        # the old rows. Successful cases (and fresh databases) are v3.
        self.version = user_version if open_failed else 3

    def open_failure_detail(self):
        """The detail that names the first migration gap, or None."""
        for index, seq in enumerate(sorted(self.events), start=1):
            if seq != index:
                return f"commit_seq gap: expected {index}, found {seq}"
        if self.version > 3:
            return f"schemaTooNew:{self.version}"
        return None

    # -- helpers ---------------------------------------------------------
    def _append_event(self, event, effect_event=False):
        if effect_event:
            self.effect_event_ids += 1
            event_id = f"evt:vector-{self.effect_event_ids}"
        else:
            event_id = event["eventId"]
        self.head += 1
        stored = dict(event)
        stored["commitSeq"] = self.head
        self.events[self.head] = stored
        self.ids[event_id] = self.head
        return self.head

    def _is_ephemeral(self, event_type):
        return event_type in {
            "model.delta", "model.started", "model.settled", "tool.progress", "agent.status",
            "fish.action", "runtime.stderr", "runtime.notification", "projection.invalidated",
            "journal.backpressure", "approval.card_available",
        }

    def _effect_event(self, event_type="effect.enqueued"):
        return {"type": event_type, "eventId": "evt:placeholder"}

    def _append_effect_events(self, event_types):
        if len(event_types) == 1:
            self._append_event(self._effect_event(event_types[0]), effect_event=True)
            return
        batch_id = f"batch:vector-{self.head + 1}"
        for index, event_type in enumerate(event_types):
            event = self._effect_event(event_type)
            event["batch"] = {"id": batch_id, "index": index, "total": len(event_types)}
            self._append_event(event, effect_event=True)

    # -- operations ------------------------------------------------------
    def step(self, step):
        op = step.get("op")
        fn = getattr(self, f"_op_{op}", None)
        if fn is None:
            raise AssertionError(f"unknown store op {op!r}")
        if self.crash_point is not None and op not in ("armCrash",):
            point = self.crash_point
            self.crash_point = None
            self.closed = True
            if point == "abort-after-commit":
                fn(step)
            raise _StoreModelError(f"simulatedCrash:{point}")
        return fn(step)

    def _op_armCrash(self, step):
        self.crash_point = step.get("point", "")
        return {}

    def _op_head(self, step):
        return {"head": self.head}

    def _op_append(self, step):
        event = step["event"]
        if "commitSeq" in event:
            if self._is_ephemeral(event["type"]):
                raise _StoreModelError("EPHEMERAL_HAS_COMMIT_SEQ")
            raise _StoreModelError("COMMIT_SEQ_ASSIGNED_BY_STORE")
        if event["eventId"] in self.ids:
            return {"sequence": self.ids[event["eventId"]]}
        seq = self._append_event(event)
        return {"sequence": seq}

    def _op_appendBatch(self, step):
        events = step["events"]
        if any(self._is_ephemeral(event["type"]) for event in events):
            raise _StoreModelError("invalidTransition")
        if any("commitSeq" in event for event in events):
            raise _StoreModelError("COMMIT_SEQ_ASSIGNED_BY_STORE")
        if len({event["eventId"] for event in events}) != len(events):
            raise _StoreModelError("invalidTransition")
        if any(event["eventId"] in self.ids for event in events):
            raise _StoreModelError("invalidTransition")
        if len(events) > 1 and all("batch" not in event for event in events):
            batch_id = "batch:vector"
            for index, event in enumerate(events):
                event = dict(event)
                event["batch"] = {"id": batch_id, "index": index, "total": len(events)}
                events[index] = event
        sequences = [self._append_event(event) for event in events]
        return {"sequences": sequences}

    def _op_events(self, step):
        after = step.get("after", 0)
        limit = step.get("limit", 256)
        selected = [self.events[seq] for seq in sorted(self.events) if seq > after][:limit]
        return {
            "sequences": [event["commitSeq"] for event in selected],
            "eventIds": [event["eventId"] for event in selected],
            "types": [event["type"] for event in selected],
            "batchIndices": [event.get("batch", {}).get("index") for event in selected],
            "batchTotal": selected[0].get("batch", {}).get("total") if selected else None,
            "batchIdsEqual": len({event.get("batch", {}).get("id") for event in selected}) <= 1,
        }

    def _op_payload(self, step):
        data = step["data"]
        if not isinstance(data, dict):
            raise _StoreModelError("INVALID_EVENT")
        text = _store_canonical(data)
        return {"canonical": text, "sha256": _store_digest(text), "size": len(text.encode())}

    def _op_ephemeralAppend(self, step):
        sequences = []
        for event in step["events"]:
            if len(self.ephemeral) == self.ephemeral_capacity:
                self.ephemeral.pop(0)
                self.dropped += 1
            self.ephemeral.append(event["eventId"])
            sequences.append(0)
        return {"sequences": sequences, "buffer": list(self.ephemeral),
                "dropped": self.dropped, "head": self.head}

    def _op_reopen(self, step):
        if self.version > 3:
            raise _StoreModelError(f"schemaTooNew:{self.version}")
        expected = sorted(self.events)
        if expected != list(range(1, len(expected) + 1)):
            for index, seq in enumerate(expected, start=1):
                if seq != index:
                    raise _StoreModelError(f"commitGap:{index}:{seq}")
        return {"head": self.head}

    def _op_sql(self, step):
        statement = step.get("statement", "")
        match = re.search(r"PRAGMA user_version\s*=\s*(\d+)", statement)
        if match:
            self.version = int(match.group(1))
        match = re.search(r"DELETE FROM bot_event_headers WHERE commit_seq\s*=\s*(\d+)", statement)
        if match:
            seq = int(match.group(1))
            self.events.pop(seq, None)
            for event_id, stored_seq in list(self.ids.items()):
                if stored_seq == seq:
                    self.ids.pop(event_id)
        return {"ok": True}

    def _op_raw(self, step):
        query = step.get("query", "")
        if query.startswith("PRAGMA user_version"):
            return {"rows": [[str(self.version)]]}
        if "sqlite_master WHERE name = 'bot_events'" in query:
            if self.migrated_from and self.version == 3:
                return {"rows": [["view"]]}
            return {"rows": [["table"]]}
        if query == "SELECT COUNT(*) FROM bot_event_headers":
            return {"rows": [[str(len(self.events))]]}
        if query == "SELECT COUNT(*) FROM bot_events":
            return {"rows": [[str(len(self.events))]]}
        if query == "SELECT COUNT(*) FROM bot_event_payloads":
            return {"rows": [[str(len(self.events))]]}
        if query.startswith("SELECT commit_seq, event_id, event_type, payload_size, payload_digest"):
            rows = []
            for seq in sorted(self.events):
                event = self.events[seq]
                data = _store_canonical(event.get("data", {}))
                rows.append([str(seq), event["eventId"], event["type"],
                             str(len(data.encode())), _store_digest(data)])
            return {"rows": rows}
        if query.startswith("SELECT CAST(payload AS TEXT)"):
            match = re.search(r"commit_seq\s*=\s*(\d+)", query)
            seq = int(match.group(1)) if match else 1
            event = self.events.get(seq)
            if event is None:
                return {"rows": []}
            return {"rows": [[_store_canonical(event.get("data", {}))]]}
        if query.startswith("SELECT event_id FROM bot_user_action_nonces"):
            match = re.search(r"bot_id = '([^']+)' AND nonce = '([^']+)'", query)
            if not match:
                return {"rows": []}
            event_id = self.nonces.get((match.group(1), match.group(2)))
            return {"rows": [[event_id]] if event_id else []}
        if "name = 'bot_user_action_nonces'" in query:
            return {"rows": [["bot_user_action_nonces"]]}
        if query.startswith("SELECT name FROM pragma_table_info('bot_user_action_nonces')"):
            return {"rows": [["bot_id"], ["nonce"], ["event_id"], ["created_commit_seq"]]}
        return {"rows": []}

    def _op_event(self, step):
        event_id = step.get("eventId", "")
        seq = self.ids.get(event_id)
        if seq is None:
            return {"exists": False}
        event = self.events[seq]
        return {"exists": True, "commitSeq": seq, "type": event["type"]}

    def _op_eventData(self, step):
        seq = step.get("commitSeq")
        event = self.events.get(seq)
        if event is None:
            return {"exists": False}
        return {"exists": True, "value": event.get("data", {}).get(step.get("dataKey"))}

    # -- effects ---------------------------------------------------------
    def _effect(self, key):
        return self.effects.get(key)

    def _op_effectEnqueue(self, step):
        effect = dict(step["effect"])
        key = effect["effectKey"]
        generation = effect.get("generation", 1)
        existing = self._effect(key)
        if existing is not None and generation <= existing["generation"]:
            return {"effectKey": key, "head": self.head}
        retry = effect.get("retryPolicy") or (
            "local-idempotent" if effect.get("idempotent") else "local-nonidempotent")
        max_attempts = effect.get("maxAttempts") or _default_max_attempts(
            retry, bool(effect.get("idempotent")))
        not_before = effect.get("notBefore", self.clock)
        self._append_event(self._effect_event("effect.enqueued"), effect_event=True)
        self.effects[key] = {
            "effectKey": key, "kind": effect.get("kind", "generic"),
            "operation": effect.get("operation", ""), "idempotent": bool(effect.get("idempotent")),
            "retryPolicy": retry, "maxAttempts": max_attempts, "generation": generation,
            "notBefore": not_before, "state": "pending", "attempt": 0, "attempts": 0,
            "enqueuedCommitSeq": self.head, "leaseOwner": None, "leaseExpiresAt": None,
            "lastError": None, "errorClass": None, "resultRef": None,
            "reconciliationReason": None,
        }
        return {"effectKey": key, "head": self.head}

    def _lease(self, step, explicit_ttl):
        owner = step.get("owner", "")
        now = step.get("now", self.clock)
        ttl = step.get("ttlMs", explicit_ttl or self.lease_ttl)
        candidates = []
        for key, effect in self.effects.items():
            if effect["state"] in ("pending", "failed") and (
                    effect["notBefore"] is None or effect["notBefore"] <= now):
                candidates.append(effect)
            elif effect["state"] in ("leased", "cancel_requested") and (
                    effect["leaseExpiresAt"] is not None and effect["leaseExpiresAt"] <= now):
                candidates.append(effect)
        candidates.sort(key=lambda effect: (
            effect["notBefore"] if effect["notBefore"] is not None else 0,
            effect["enqueuedCommitSeq"], effect["effectKey"]))
        for effect in candidates:
            if effect["state"] == "cancel_requested":
                self._append_event(self._effect_event("effect.reconciliation_required"), effect_event=True)
                effect.update({"state": "needs_reconciliation", "reconciliationReason": "unknown-outcome",
                               "leaseOwner": None, "leaseExpiresAt": None, "notBefore": None})
                continue
            if effect["state"] == "leased":
                if effect["attempts"] >= effect["maxAttempts"]:
                    self._append_event(self._effect_event("effect.reconciliation_required"), effect_event=True)
                    effect.update({"state": "needs_reconciliation",
                                   "reconciliationReason": "unknown-outcome",
                                   "leaseOwner": None, "leaseExpiresAt": None, "notBefore": None})
                    continue
                attempt = effect["attempt"] + 1
                generation = effect["generation"] + 1
            else:
                if effect["attempts"] >= effect["maxAttempts"]:
                    self._append_event(self._effect_event("effect.dead_lettered"), effect_event=True)
                    effect.update({"state": "dead_letter", "leaseOwner": None,
                                   "leaseExpiresAt": None})
                    continue
                attempt = effect["attempt"] + 1
                generation = effect["generation"]
            self._append_event(self._effect_event("effect.attempted"), effect_event=True)
            effect.update({
                "state": "leased", "attempt": attempt, "generation": generation,
                "attempts": max(effect["attempts"], attempt), "leaseOwner": owner,
                "leaseExpiresAt": now + ttl, "notBefore": None,
                "reconciliationReason": None,
            })
            lease = {"effectKey": effect["effectKey"], "attempt": attempt,
                     "generation": generation, "leaseOwner": owner,
                     "leaseExpiresAt": now + ttl}
            self.leases[effect["effectKey"]] = lease
            return dict(lease)
        return {"lease": None}

    def _op_effectLease(self, step):
        return self._lease(step, None)

    def _op_effectLeaseNext(self, step):
        observation = self._lease(step, None)
        if "lease" not in observation and step.get("effectKey"):
            if observation.get("effectKey") != step["effectKey"]:
                raise AssertionError("leaseNext selected another effect")
        return observation

    def _step_lease(self, step):
        key = step.get("effectKey", "")
        if "lease" in step:
            return step["lease"]
        lease = self.leases.get(key)
        if lease is None:
            raise AssertionError(f"no lease recorded for {key}")
        return lease

    def _op_effectRenew(self, step):
        lease = self._step_lease(step)
        effect = self._effect(lease["effectKey"])
        if effect is None:
            raise _StoreModelError("unknownEffect")
        if (effect["state"] != "leased" or lease["generation"] != effect["generation"]
                or lease["attempt"] != effect["attempt"]
                or lease["leaseOwner"] != effect["leaseOwner"]):
            raise _StoreModelError("staleLease")
        now = step.get("now", self.clock)
        ttl = step.get("ttlMs", self.lease_ttl)
        self._append_event(self._effect_event("effect.attempted"), effect_event=True)
        effect["leaseExpiresAt"] = now + ttl
        lease["leaseExpiresAt"] = now + ttl
        return {"attempt": lease["attempt"], "generation": lease["generation"],
                "leaseExpiresAt": lease["leaseExpiresAt"], "leaseOwner": lease["leaseOwner"]}

    def _check_lease(self, step, states):
        lease = self._step_lease(step)
        effect = self._effect(lease["effectKey"])
        if effect is None:
            raise _StoreModelError("unknownEffect")
        if (lease["generation"] != effect["generation"]
                or lease["attempt"] != effect["attempt"]
                or lease["leaseOwner"] != effect["leaseOwner"]):
            raise _StoreModelError("staleLease")
        if effect["state"] not in states:
            raise _StoreModelError("invalidTransition")
        return lease, effect

    def _op_effectAck(self, step):
        lease = self._step_lease(step)
        effect = self._effect(lease["effectKey"])
        if effect is not None and effect["state"] == "acked" and (
                effect["generation"] == lease["generation"]
                and effect["attempt"] == lease["attempt"]):
            return {"state": "acked", "head": self.head}
        lease, effect = self._check_lease(step, {"leased", "cancel_requested"})
        sequence = self._append_event(self._effect_event("effect.acked"), effect_event=True)
        self.events[sequence]["data"] = {"reconciled": True}
        effect.update({"state": "acked", "resultRef": step.get("resultRef"),
                       "leaseOwner": None, "leaseExpiresAt": None, "notBefore": None,
                       "reconciliationReason": None})
        return {"state": "acked", "head": self.head}

    def _op_effectFail(self, step):
        error_class = step.get("errorClass")
        if error_class not in ("transient", "permanent", "unknown"):
            raise _StoreModelError("invalidTransition")
        lease = self._step_lease(step)
        effect = self._effect(lease["effectKey"])
        if effect is None:
            raise _StoreModelError("unknownEffect")
        if (effect["state"] not in ("leased", "cancel_requested")
                or lease["generation"] != effect["generation"]
                or lease["attempt"] != effect["attempt"]
                or lease["leaseOwner"] != effect["leaseOwner"]):
            raise _StoreModelError("staleLease")
        now = self.clock
        safe = _safe_error(step.get("reason", ""))
        dead = error_class == "permanent" or effect["attempts"] >= effect["maxAttempts"]
        if error_class == "unknown":
            self._append_effect_events(["effect.failed", "effect.reconciliation_required"])
            effect.update({"state": "needs_reconciliation", "lastError": safe,
                           "errorClass": error_class,
                           "reconciliationReason": "unknown-outcome",
                           "leaseOwner": None, "leaseExpiresAt": None, "notBefore": None})
        elif dead:
            self._append_effect_events(["effect.failed", "effect.dead_lettered"])
            effect.update({"state": "dead_letter", "lastError": safe,
                           "errorClass": error_class, "leaseOwner": None,
                           "leaseExpiresAt": None, "notBefore": None})
        else:
            self._append_event(self._effect_event("effect.failed"), effect_event=True)
            effect.update({"state": "failed", "lastError": safe, "errorClass": error_class,
                           "notBefore": now + _retry_delay(effect["retryPolicy"], lease["attempt"]),
                           "leaseOwner": None, "leaseExpiresAt": None})
        lease["leaseExpiresAt"] = None
        return {"state": effect["state"], "head": self.head, "attempt": effect["attempt"],
                "attempts": effect["attempts"], "notBefore": effect["notBefore"]}

    def _op_effectRelease(self, step):
        """Known kind without a registered executor: back to pending, no event."""
        lease = self._step_lease(step)
        effect = self._effect(lease["effectKey"])
        if effect is None:
            raise _StoreModelError("unknownEffect")
        if (lease["generation"] != effect["generation"]
                or lease["attempt"] != effect["attempt"]
                or lease["leaseOwner"] != effect["leaseOwner"]):
            raise _StoreModelError("staleLease")
        if effect["state"] != "leased":
            raise _StoreModelError("invalidTransition")
        now = self.clock
        effect.update({
            "state": "pending",
            "notBefore": now + _retry_delay(effect["retryPolicy"], lease["attempt"]),
            "lastError": "no registered executor",
            "leaseOwner": None,
            "leaseExpiresAt": None,
        })
        lease["leaseExpiresAt"] = None
        return {"state": effect["state"], "head": self.head, "attempt": effect["attempt"],
                "attempts": effect["attempts"], "notBefore": effect["notBefore"]}

    def _op_effectMarkReconciliation(self, step):
        reason = step.get("reason")
        if reason not in RECONCILIATION_REASONS:
            raise _StoreModelError("invalidTransition")
        effect = self._effect(step.get("effectKey", ""))
        if effect is None:
            raise _StoreModelError("unknownEffect")
        if effect["state"] == "needs_reconciliation":
            return {"state": effect["state"], "head": self.head}
        if effect["state"] in TERMINAL_EFFECT_STATES:
            raise _StoreModelError("invalidTransition")
        self._append_event(self._effect_event("effect.reconciliation_required"), effect_event=True)
        effect.update({"state": "needs_reconciliation", "reconciliationReason": reason,
                       "leaseOwner": None, "leaseExpiresAt": None, "notBefore": None})
        return {"state": effect["state"], "head": self.head}

    def _op_effectAckReconciled(self, step):
        effect = self._effect(step.get("effectKey", ""))
        if effect is None:
            raise _StoreModelError("unknownEffect")
        if (effect["state"] != "needs_reconciliation"
                or effect["generation"] != step.get("generation")
                or effect["attempt"] != step.get("attempt")):
            raise _StoreModelError("invalidTransition")
        sequence = self._append_event(self._effect_event("effect.acked"), effect_event=True)
        self.events[sequence]["data"] = {"reconciled": True}
        effect.update({"state": "acked", "resultRef": step.get("resultRef"),
                       "leaseOwner": None, "leaseExpiresAt": None, "notBefore": None,
                       "reconciliationReason": None})
        return {"state": "acked", "head": self.head}

    def _op_effectCancel(self, step):
        effect = self._effect(step.get("effectKey", ""))
        if effect is None:
            raise _StoreModelError("unknownEffect")
        if effect["state"] in TERMINAL_EFFECT_STATES or effect["state"] == "cancel_requested":
            return {"state": effect["state"], "head": self.head}
        if effect["state"] == "needs_reconciliation":
            raise _StoreModelError("invalidTransition")
        if effect["state"] == "leased":
            self._append_event(self._effect_event("effect.cancel_requested"), effect_event=True)
            effect["state"] = "cancel_requested"
        else:
            self._append_event(self._effect_event("effect.canceled"), effect_event=True)
            effect.update({"state": "canceled", "lastError": step.get("reason"),
                           "leaseOwner": None, "leaseExpiresAt": None, "notBefore": None})
        return {"state": effect["state"], "head": self.head}

    def _op_effectConfirmCancel(self, step):
        lease, effect = self._check_lease(step, {"cancel_requested"})
        self._append_event(self._effect_event("effect.canceled"), effect_event=True)
        effect.update({"state": "canceled", "lastError": step.get("reason"),
                       "leaseOwner": None, "leaseExpiresAt": None, "notBefore": None})
        return {"state": effect["state"], "head": self.head}

    def _op_effectRecord(self, step):
        effect = self._effect(step.get("effectKey", ""))
        if effect is None:
            return {"exists": False}
        observation = {"exists": True, **{key: effect.get(key) for key in (
            "state", "attempt", "attempts", "generation", "enqueuedCommitSeq",
            "leaseOwner", "resultRef", "reconciliationReason", "lastError",
            "notBefore", "errorClass")}}
        return observation

    _op_effect = _op_effectRecord

    def _op_effects(self, step):
        ordered = sorted(self.effects.values(), key=lambda effect: (
            effect["enqueuedCommitSeq"], effect["effectKey"]))
        return {"keys": [effect["effectKey"] for effect in ordered],
                "states": [effect["state"] for effect in ordered],
                "enqueuedCommitSeq": [effect["enqueuedCommitSeq"] for effect in ordered]}

    def _op_effectInbox(self, step):
        receiver = step.get("receiver")
        key = step.get("effectKey")
        lease = self._step_lease(step)
        repeat = step.get("repeat", 1)
        deduped = 0
        executions = self.inbox_executions.get((receiver, key), 0)
        result_ref = None
        for _ in range(repeat):
            existing = self.inbox.get((receiver, key))
            if existing is not None and existing["generation"] >= lease["generation"]:
                deduped += 1
                result_ref = existing["resultRef"]
                continue
            effect = self._effect(key)
            if (effect is None or effect["state"] not in ("leased", "cancel_requested")
                    or lease["generation"] != effect["generation"]
                    or lease["attempt"] != effect["attempt"]
                    or lease["leaseOwner"] != effect["leaseOwner"]):
                raise _StoreModelError("staleLease")
            executions += 1
            result_ref = step.get("resultRef")
            self.inbox[(receiver, key)] = {"generation": lease["generation"],
                                           "resultRef": result_ref}
            self.inbox_executions[(receiver, key)] = executions
        return {"dedupedCount": deduped, "executions": executions, "resultRef": result_ref}

    def _op_action(self, step):
        action = step["action"]
        plan = step["plan"]
        key = (action["botID"], action["nonce"])
        if key in self.nonces:
            return {"status": "duplicate", "eventID": self.nonces[key], "head": self.head}
        reason = _validate_action(action)
        if reason is not None:
            status, value = reason
            return {"status": status, "reason": value, "head": self.head}
        event = plan["event"]
        effects = plan.get("effects", [])
        if self._is_ephemeral(event["type"]) or event["principal"]["botId"] != action["botID"]:
            raise _StoreModelError("invalidTransition")
        if event["eventId"] in self.ids:
            raise _StoreModelError("invalidTransition")
        effect_keys = [effect["effectKey"] for effect in effects]
        if len(set(effect_keys)) != len(effect_keys):
            raise _StoreModelError("invalidTransition")
        if any(effect_key in self.effects for effect_key in effect_keys):
            raise _StoreModelError("invalidTransition")
        self._append_event(event)
        event_types = [event["type"]]
        sequences = [self.head]
        for effect in effects:
            enqueue = self._op_effectEnqueue({"effect": effect, "expect": None})
            event_types.append("effect.enqueued")
            sequences.append(enqueue["head"])
        self.nonces[key] = event["eventId"]
        return {"status": "accepted", "eventID": event["eventId"], "head": self.head,
                "eventTypes": event_types, "sequences": sequences}

    def _op_nonce(self, step):
        event_id = self.nonces.get((step.get("botID"), step.get("nonce")))
        if event_id is None:
            return {"exists": False}
        return {"eventID": event_id}


def _validate_action(action):
    if not action.get("nonce") or not action.get("botID"):
        return "rejected", "invalid_action"
    kind = action.get("kind")
    if kind != "chat" and "attachments" in action:
        return "rejected", "unexpected_attachments"
    if kind == "chat":
        attachments = action.get("attachments") or []
        if not (action.get("text") or "").strip() and not attachments:
            return "rejected", "missing_text"
    elif kind == "cardAnswer":
        if not action.get("cardID"):
            return "rejected", "missing_card_id"
        if "text" in action:
            return "rejected", "unexpected_card_answer_field"
        if not action.get("optionID"):
            return "rejected", "missing_card_answer"
    elif kind == "cardDismiss":
        if not action.get("cardID"):
            return "rejected", "missing_card_id"
    elif kind == "approval":
        if not action.get("approvalID") or action.get("decision") is None:
            return "rejected", "invalid_approval"
        if not action.get("digest"):
            return "stale", "digest_mismatch"
    elif kind == "stopTask":
        if not action.get("threadID"):
            return "rejected", "missing_thread_id"
    return None


def _run_store_step(model, step, where):
    expect = step.get("expect")
    try:
        observation = model.step(step)
    except _StoreModelError as error:
        if not isinstance(expect, dict) or "error" not in expect:
            raise AssertionError(f"{where}: unexpected model error {error.code}") from None
        if expect["error"] != error.code:
            raise AssertionError(
                f"{where}: expected error {expect['error']!r}, got {error.code!r}") from None
        return
    if isinstance(expect, dict) and "error" in expect:
        raise AssertionError(f"{where}: expected error {expect['error']!r}, got success")
    _expect_store(expect, observation, where)


def _walk_store_case(case, vector_name):
    name = case.get("name")
    if not isinstance(name, str) or not name:
        raise AssertionError(f"{vector_name}: case without name")
    _store_source(case.get("source"), f"{vector_name}.{name}")
    steps = case.get("steps")
    if not isinstance(steps, list):
        raise AssertionError(f"{vector_name}.{name}: steps must be an array")
    open_error = case.get("openError")
    if open_error is not None:
        if open_error not in STORE_ERRORS:
            raise AssertionError(f"{vector_name}.{name}: unknown openError {open_error!r}")
        # A refused open may still be inspected on disk (for example
        # `PRAGMA user_version` after a rolled-back migration). No other step
        # makes sense because the model never opened.
        model = _StoreModel(case, open_failed=True)
        expected_detail = case.get("openErrorContains")
        if expected_detail is not None:
            if not isinstance(expected_detail, str) or not expected_detail:
                raise AssertionError(
                    f"{vector_name}.{name}: openErrorContains must be a non-empty string")
            actual_detail = model.open_failure_detail()
            if actual_detail is None:
                raise AssertionError(
                    f"{vector_name}.{name}: openError case models no failure detail")
            if expected_detail not in actual_detail:
                raise AssertionError(
                    f"{vector_name}.{name}: openErrorContains {expected_detail!r} not in "
                    f"{actual_detail!r}")
        for index, step in enumerate(steps):
            where = f"{vector_name}.{name}.steps[{index}]"
            if step.get("op") not in ("raw", "sql"):
                raise AssertionError(
                    f"{where}: only raw/sql steps may follow a failed open")
            _run_store_step(model, step, where)
        return len(steps)
    if not steps:
        raise AssertionError(f"{vector_name}.{name}: case without steps")
    model = _StoreModel(case)
    for index, step in enumerate(steps):
        where = f"{vector_name}.{name}.steps[{index}]"
        _run_store_step(model, step, where)
    return len(steps)


def validate_store_fixture(fixture):
    if fixture.get("vector") != "store.phone":
        raise AssertionError("store.phone: vector must be store.phone")
    if fixture.get("upstream") != []:
        raise AssertionError("store.phone: phone-only vector must declare upstream: []")
    if not isinstance(fixture.get("delta"), list) or not fixture["delta"]:
        raise AssertionError("store.phone: delta must be a non-empty array")
    valid = fixture.get("valid")
    invalid = fixture.get("invalid")
    if not isinstance(valid, list) or not valid:
        raise AssertionError("store.phone: valid must be a non-empty array")
    if not isinstance(invalid, list) or not invalid:
        raise AssertionError("store.phone: invalid must be a non-empty array")
    names = set()
    count = 0
    for case in valid + invalid:
        if case.get("name") in names:
            raise AssertionError(f"store.phone: duplicate case name {case.get('name')!r}")
        names.add(case.get("name"))
        count += _walk_store_case(case, "store.phone")
    # Mutation self-check: the expected sequence is part of the contract, not a comment.
    mutated = copy.deepcopy(valid[0])
    mutated["steps"][0]["expect"]["sequence"] = 2
    expect_rule_violation("store-sequence", lambda: _walk_store_case(mutated, "store.phone"))
    mutated = copy.deepcopy(next(case for case in valid if case["name"] ==
                                 "payload-canonical-bytes-and-digest"))
    mutated["steps"][0]["expect"]["sha256"] = "0" * 64
    expect_rule_violation("store-payload-digest", lambda: _walk_store_case(mutated, "store.phone"))
    mutated = copy.deepcopy(next(case for case in valid if case["name"] ==
                                 "outbox-transient-exhaustion-dead-letters-atomically"))
    for step in mutated["steps"]:
        if step["op"] == "effectFail":
            step["expect"]["state"] = "acked"
            break
    expect_rule_violation("store-effect-state", lambda: _walk_store_case(mutated, "store.phone"))
    mutated = copy.deepcopy(next(case for case in valid if case["name"] ==
                                 "outbox-network-idempotent-backoff"))
    for step in mutated["steps"]:
        if step["op"] == "effectLease" and step.get("now") == 1999:
            step["expect"] = {
                "attempt": 2, "generation": 1,
                "leaseOwner": "owner", "leaseExpiresAt": 31999}
            break
    expect_rule_violation("store-backoff", lambda: _walk_store_case(mutated, "store.phone"))
    # A known kind without an executor MUST be released to `pending` with the
    # store's retry delay, not failed or dead-lettered.
    mutated = copy.deepcopy(next(case for case in valid if case["name"] ==
                                 "outbox-known-kind-without-executor-releases-to-pending"))
    for step in mutated["steps"]:
        if step["op"] == "effectRelease":
            step["expect"]["state"] = "failed"
            break
    expect_rule_violation("store-release-state", lambda: _walk_store_case(mutated, "store.phone"))
    mutated = copy.deepcopy(next(case for case in valid if case["name"] ==
                                 "outbox-known-kind-without-executor-releases-to-pending"))
    for step in mutated["steps"]:
        if step["op"] == "effectRelease":
            step["expect"]["notBefore"] = 1001
            break
    expect_rule_violation("store-release-delay", lambda: _walk_store_case(mutated, "store.phone"))
    # A migration gap MUST roll back, so the file still reports user_version 2.
    mutated = copy.deepcopy(next(case for case in invalid if case["name"] ==
                                 "v2-gap-rolls-back-and-stays-v2"))
    for step in mutated["steps"]:
        if step["op"] == "raw" and step.get("query") == "PRAGMA user_version":
            step["expect"]["rows"] = [["3"]]
            break
    expect_rule_violation("store-migration-rollback",
                          lambda: _walk_store_case(mutated, "store.phone"))
    # The no-executor release is not the unknown-kind path: the latter is a
    # permanent failure whose stored code is exactly `unknown_effect_kind`.
    mutated = copy.deepcopy(next(case for case in valid if case["name"] ==
                                 "unknown-effect-kind-is-permanent"))
    for step in mutated["steps"]:
        if step["op"] == "effectRecord":
            step["expect"]["lastErrorContains"] = "not_the_code"
            break
    expect_rule_violation("store-unknown-effect-kind",
                          lambda: _walk_store_case(mutated, "store.phone"))
    return count


def validate_user_action_fixture(fixture):
    if fixture.get("vector") != "user-action-transaction.phone":
        raise AssertionError("user-action-transaction.phone: vector must be "
                             "user-action-transaction.phone")
    if fixture.get("upstream") != []:
        raise AssertionError("user-action-transaction.phone: phone-only vector must "
                             "declare upstream: []")
    if not isinstance(fixture.get("delta"), list) or not fixture["delta"]:
        raise AssertionError("user-action-transaction.phone: delta must be a non-empty array")
    valid = fixture.get("valid")
    invalid = fixture.get("invalid")
    if not isinstance(valid, list) or not valid:
        raise AssertionError("user-action-transaction.phone: valid must be a non-empty array")
    if not isinstance(invalid, list) or not invalid:
        raise AssertionError("user-action-transaction.phone: invalid must be a non-empty array")
    names = set()
    count = 0
    for case in valid + invalid:
        if case.get("name") in names:
            raise AssertionError(f"user-action-transaction.phone: duplicate case name "
                                 f"{case.get('name')!r}")
        names.add(case.get("name"))
        if not isinstance(case.get("steps"), list):
            raise AssertionError(f"user-action-transaction.phone.{case.get('name')}: "
                                 f"steps must be an array")
        count += _walk_store_case(case, "user-action-transaction.phone")
    mutated = copy.deepcopy(next(case for case in valid if case["name"] ==
                                 "action-duplicate-survives-reopen"))
    for step in mutated["steps"]:
        if step["op"] == "action" and step["expect"].get("status") == "duplicate":
            step["expect"]["status"] = "accepted"
            break
    expect_rule_violation("action-duplicate",
                   lambda: _walk_store_case(mutated, "user-action-transaction.phone"))
    mutated = copy.deepcopy(next(case for case in valid if case["name"] ==
                                 "action-event-effects-and-nonce-commit-atomically"))
    mutated["steps"][0]["expect"]["head"] = 4
    expect_rule_violation("action-head",
                   lambda: _walk_store_case(mutated, "user-action-transaction.phone"))
    mutated = copy.deepcopy(next(case for case in invalid if case["name"] ==
                                 "action-event-id-conflict-fails-closed-without-consuming-nonce"))
    for step in mutated["steps"]:
        if step["op"] == "nonce" and step["expect"].get("eventID") == "evt-shared":
            step["expect"]["eventID"] = "evt-wrong"
            break
    expect_rule_violation("action-nonce",
                   lambda: _walk_store_case(mutated, "user-action-transaction.phone"))
    return count


# ---------------------------------------------------------------------------
# P27 B7a: session lifecycle and row projection (phone-only vectors).
#
# These validators are reference oracles, not runtime conformance. They prove
# that the shared fixtures are internally consistent with the normative text:
# id/entrySeq arithmetic, the token-registry model, the JSONL decoder
# diagnostics, watch/reset semantics and the 10 Hz limiter. The Swift tests in
# Tests/PhoneDSHBotTests/{MCP,Rows} drive the real code over the same files.
# ---------------------------------------------------------------------------

SESSION_LIFECYCLE_VECTOR = "session-lifecycle.phone.json"
PROJECTION_VECTOR = "projection.phone.json"

_ROW_WIRE_KINDS = {"message", "send-message", "event"}
_ROW_BODY_TYPES = {"text", "widget", "attachment", "approval", "automation", "notice", "deleted"}
_ROW_CARD_TYPES = {"question", "steps", "task", "document", "progress", "checklist", "link",
                   "table", "callout", "info", "payload", "library"}
_ROW_TRUST = {"owner_direct", "model", "projector"}
_TOKEN_RE = re.compile(r"^dshg_[A-Za-z0-9_-]{43}$")
_INCARNATION_RE = re.compile(r"^[0-9a-f]{32}$")
_BOT_REQUEST_ID_RE = re.compile(
    r"^bot-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
_REBUILT_ID_RE = re.compile(
    r"^gb-main-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
_FROZEN_REQUEST_PREFIXES = (
    "user-action:", "card-answer:", "held:", "agent:", "routine:", "task-turn:",
    "task-settled:", "task-interrupted:", "maintenance:",
)
_DEFAULT_BOT_ROOT = "/dsh/workspace/.dshbot/agents/main"


def _family(fixture, group, name, label):
    section = fixture.get(group)
    if not isinstance(section, dict):
        raise AssertionError(f"{label}: {group} must be an object")
    value = section.get(name)
    if not isinstance(value, list) or not value:
        raise AssertionError(f"{label}: {group}.{name} must be a non-empty array")
    return value


def _expect_phone_vector(fixture, vector_name):
    if fixture.get("vector") != vector_name:
        raise AssertionError(f"{vector_name}: vector must be {vector_name!r}")
    if fixture.get("upstream") != []:
        raise AssertionError(f"{vector_name}: phone-only vector must declare upstream: []")
    delta = fixture.get("delta")
    if not isinstance(delta, list) or not delta:
        raise AssertionError(f"{vector_name}: phone-only vector needs a non-empty delta")
    if not isinstance(fixture.get("valid"), dict):
        raise AssertionError(f"{vector_name}: valid must be an object")
    if not isinstance(fixture.get("invalid"), (dict, list)):
        raise AssertionError(f"{vector_name}: invalid must be an object or an array")
    for group in ("valid", "invalid"):
        section = fixture[group]
        if isinstance(section, list):
            if not section:
                raise AssertionError(f"{vector_name}: {group} must not be empty")
            continue
        for key, value in section.items():
            if not value:
                raise AssertionError(f"{vector_name}: {group}.{key} must not be empty")


def _graphemes(text):
    """Approximate extended grapheme clusters for the sanitized alphabet.

    §2.1 replaces every scalar outside L*/M*/N*/`._-` with `_` *before*
    truncating, so emoji ZWJ sequences, flags and modifiers never reach this
    loop; only a combining mark can extend a cluster here. The Kotlin runtime's
    shared helper also implements GB11/GB12/GB13 for callers that truncate raw
    text, and the `grapheme-truncation` / `grapheme-truncation-zwj-and-flag`
    vectors pin the sanitize-then-truncate order.
    """
    clusters = []
    for character in text:
        if clusters and unicodedata.category(character).startswith("M"):
            clusters[-1] += character
        else:
            clusters.append(character)
    return clusters


def _safe_path_component(raw):
    allowed_extra = "._-"
    output = []
    for character in raw:
        category = unicodedata.category(character)
        if category[0] in ("L", "M", "N") or character in allowed_extra:
            output.append(character)
        else:
            output.append("_")
    value = "".join(output)
    if value in ("", ".", ".."):
        value = "bot"
    return "".join(_graphemes(value)[:64])


_SESSION_FOLLOW_SNAPSHOT_ERROR = "session/follow ended before its snapshot"


def _follow_wait_outcome(frames):
    """Model `waitForSnapshot` (`BotDSHRemoteRuntime.swift:2214-2230`).

    Returns ``(True, None)`` once the `snapshot` arrives, otherwise
    ``(False, message)`` for an `error` frame, an `end` value or a closed
    socket. A `follow` item whose `value.type` is neither `snapshot` nor `end`
    is skipped. Foreign stream ids and non-item frames are ignored.
    """
    for frame in frames or []:
        if not isinstance(frame, dict):
            continue
        if frame.get("__awaitCancel") is True:
            continue
        if frame.get("type") == "error":
            error = frame.get("error")
            message = error.get("message") if isinstance(error, dict) else None
            return False, message or "session/follow failed"
        if frame.get("type") != "item" or frame.get("streamId") != "follow":
            continue
        value = frame.get("value")
        value_type = value.get("type") if isinstance(value, dict) else None
        if value_type == "snapshot":
            return True, None
        if value_type == "end":
            return False, _SESSION_FOLLOW_SNAPSHOT_ERROR
    return False, _SESSION_FOLLOW_SNAPSHOT_ERROR


def _session_turns(case):
    transport = case.get("transport")
    if not isinstance(transport, dict):
        return []
    turns = transport.get("turns")
    return turns if isinstance(turns, list) else []


def _validate_session_workspace(fixture):
    workspace = _family(fixture, "valid", "workspace", "session-lifecycle")
    for case in workspace:
        if not isinstance(case.get("source"), str):
            raise AssertionError("session-lifecycle.workspace: source")
        safe = _safe_path_component(case["botId"])
        if safe != case["safe"]:
            raise AssertionError(f"workspace {case['name']}: safe {safe!r} != {case['safe']!r}")
        directory = case.get("dataDirectory", "/dsh/workspace/.dshbot")
        while len(directory) > 1 and directory.endswith("/"):
            directory = directory[:-1]
        root = f"{directory}/agents/{safe}"
        if root != case["root"]:
            raise AssertionError(f"workspace {case['name']}: root {root!r} != {case['root']!r}")
    invalid = _family(fixture, "invalid", "workspace", "session-lifecycle")
    for case in invalid:
        if not isinstance(case.get("why"), str) or not case["why"]:
            raise AssertionError("session-lifecycle.workspace invalid: why")
        if _safe_path_component(case["botId"]) != case["safe"]:
            raise AssertionError(f"workspace {case['name']}: fallback")
    return workspace, invalid


def validate_session_snapshot_wait_vectors(fixture):
    """Check the §6.2 snapshot-wait transcript model and its mutations.

    The valid fixture must contain a `follow` item before the snapshot and the
    turn must still proceed. The invalid fixture must contain a skipped item
    followed by `end`, which fails with the frozen message before
    `session/prompt`.
    """
    skipped_before_snapshot = 0
    ended_after_skip = 0
    for group, cases in (("valid", fixture["valid"]["sessions"]),
                         ("invalid", fixture["invalid"]["sessions"])):
        for case in cases:
            label = f"session-lifecycle.{group}.{case.get('name')}"
            expect = case.get("expect") or {}
            expect_error = " ".join(expect.get("errorContains") or [])
            turns = _session_turns(case)
            if not turns:
                continue
            for index, frames in enumerate(turns):
                where = f"{label}.transport.turns[{index}]"
                ok, message = _follow_wait_outcome(frames)
                if ok:
                    if "ended before its snapshot" in expect_error:
                        raise AssertionError(
                            f"{where}: snapshot wait passed but the case expects an end failure")
                    first_follow = next(
                        (item for item in frames or []
                         if isinstance(item, dict) and item.get("type") == "item"
                         and item.get("streamId") == "follow"), None)
                    if first_follow is not None and (
                            first_follow.get("value") or {}).get("type") != "snapshot":
                        skipped_before_snapshot += 1
                        if not expect.get("promptRequests"):
                            raise AssertionError(
                                f"{where}: a skipped pre-snapshot item must still prompt")
                elif "ended before its snapshot" in expect_error:
                    saw_skip = any(
                        isinstance(item, dict) and item.get("type") == "item"
                        and item.get("streamId") == "follow"
                        and isinstance(item.get("value"), dict)
                        and item["value"].get("type") not in ("snapshot", "end")
                        for item in frames or [])
                    if saw_skip:
                        ended_after_skip += 1
            if "ended before its snapshot" in expect_error:
                ok, message = _follow_wait_outcome(turns[0])
                if ok or message != _SESSION_FOLLOW_SNAPSHOT_ERROR:
                    raise AssertionError(
                        f"{label}: end before snapshot must fail with "
                        f"{_SESSION_FOLLOW_SNAPSHOT_ERROR!r}")
                if expect.get("promptRequests") != []:
                    raise AssertionError(f"{label}: an end before snapshot must not prompt")
    if skipped_before_snapshot == 0:
        raise AssertionError(
            "session-lifecycle: no valid vector covers a skipped item before the snapshot")
    if ended_after_skip == 0:
        raise AssertionError(
            "session-lifecycle: no invalid vector covers a skipped item followed by end")

    def mutated_skip_to_end():
        mutated = copy.deepcopy(fixture)
        case = next(c for c in mutated["valid"]["sessions"]
                    if c["name"] == "follow-skips-item-before-snapshot")
        frames = case["transport"]["turns"][0]
        for index, frame in enumerate(frames):
            value = frame.get("value") if isinstance(frame, dict) else None
            if (frame.get("type") == "item" and frame.get("streamId") == "follow"
                    and isinstance(value, dict)
                    and value.get("type") not in ("snapshot", "end")):
                frames[index] = {"type": "item", "streamId": "follow",
                                 "value": {"type": "end"}}
                break
        validate_session_snapshot_wait_vectors(mutated)

    _expect_contract_failure("session follow snapshot skip", mutated_skip_to_end)

    def mutated_end_to_snapshot():
        mutated = copy.deepcopy(fixture)
        case = next(c for c in mutated["invalid"]["sessions"]
                    if c["name"] == "follow-skips-item-then-ends-before-snapshot")
        frames = case["transport"]["turns"][0]
        for index, frame in enumerate(frames):
            value = frame.get("value") if isinstance(frame, dict) else None
            if (frame.get("type") == "item" and frame.get("streamId") == "follow"
                    and isinstance(value, dict) and value.get("type") == "end"):
                frames[index] = {"type": "item", "streamId": "follow",
                                 "value": {"type": "snapshot", "cursor": 0}}
                break
        validate_session_snapshot_wait_vectors(mutated)

    _expect_contract_failure("session follow snapshot end", mutated_end_to_snapshot)


def _entry_seq(time_value, source_seq):
    positive_source = max(0, int(source_seq)) % 1000
    milliseconds = int(time_value) * 1000
    if milliseconds < -(2 ** 63) or milliseconds > 2 ** 63 - 1:
        return -(2 ** 63) if int(time_value) < 0 else 2 ** 63 - 1
    result = milliseconds + positive_source
    if result > 2 ** 63 - 1 or result < -(2 ** 63):
        return 2 ** 63 - 1
    return result


def _parse_session_records(records):
    events = []
    skipped = []
    first = True
    for line_number, raw in enumerate(records, start=1):
        line = raw.lstrip(" \t\r")
        if not line.strip():
            continue
        if first:
            first = False
            try:
                candidate = json.loads(line)
            except ValueError:
                candidate = None
            if (isinstance(candidate, dict) and candidate.get("type") == "session"
                    and candidate.get("version") == 4
                    and all(key in candidate for key in
                            ("id", "createdAt", "isSeeded", "delegationDepth"))):
                continue
        try:
            event = json.loads(line)
            _check_session_event(event)
            events.append(event)
        except (ValueError, AssertionError):
            seq = None
            try:
                candidate = json.loads(line)
                value = candidate.get("seq") if isinstance(candidate, dict) else None
                if isinstance(value, int) and not isinstance(value, bool):
                    seq = value
            except ValueError:
                seq = None
            skipped.append({"lineNumber": line_number, "seq": seq})
    return events, skipped


def _check_session_event(event):
    if not isinstance(event, dict):
        raise AssertionError("session record must be an object")
    if not isinstance(event.get("type"), str):
        raise AssertionError("session record type")
    for key in ("seq", "time"):
        value = event.get(key)
        if not isinstance(value, int) or isinstance(value, bool):
            raise AssertionError(f"session record {key}")
    if not isinstance(event.get("data"), dict):
        raise AssertionError("session record data")
    if "eventId" in event and not isinstance(event["eventId"], str):
        raise AssertionError("session record eventId")
    surface_op = event.get("surfaceOp")
    if surface_op is None:
        return
    if surface_op == "append":
        return
    if not isinstance(surface_op, dict) or set(surface_op) != {"op", "startSeq", "endSeq"}:
        raise AssertionError("surfaceOp shape")
    if surface_op["op"] != "replace":
        raise AssertionError("surfaceOp op")
    start = surface_op["startSeq"]
    end = surface_op["endSeq"]
    for value in (start, end):
        if not isinstance(value, int) or isinstance(value, bool):
            raise AssertionError("surfaceOp range")
    if start < 0 or end < start:
        raise AssertionError("surfaceOp range order")


def _flatten_ui_payload(event):
    data = event.get("data")
    if not isinstance(data, dict):
        return {}
    payload = dict(data)
    for key in ("row", "entry", "message", "body", "card", "task", "automation",
                "routine", "run", "notice"):
        nested = data.get(key)
        if isinstance(nested, dict):
            payload.update(nested)
    return payload


def _validate_row(row, where):
    check(row, "row.schema.json", where)
    if row["body"]["type"] not in _ROW_BODY_TYPES:
        raise AssertionError(f"{where}: body type")
    if row["body"].get("cardType") is not None and row["body"]["cardType"] not in _ROW_CARD_TYPES:
        raise AssertionError(f"{where}: cardType")
    if row["provenance"]["trust"] not in _ROW_TRUST:
        raise AssertionError(f"{where}: trust")
    if row["updatedSeq"] < 1:
        raise AssertionError(f"{where}: updatedSeq must be positive")


def _find_record(case, origin):
    if "epochs" in case:
        for epoch in case["epochs"]:
            if epoch["sessionID"] == origin.get("sessionID", "gb-main"):
                for record in epoch["records"]:
                    event, _ = _parse_session_records([record])
                    if event and event[0]["seq"] == origin["seq"]:
                        return event[0], epoch["sessionID"]
        raise AssertionError(f"{case['name']}: epoch record {origin} not found")
    for record in case["records"]:
        event, _ = _parse_session_records([record])
        if event and event[0]["seq"] == origin["seq"]:
            return event[0], case.get("sessionID", "gb-main")
    raise AssertionError(f"{case['name']}: record {origin} not found")


def _validate_expected_rows(case, session_id, label):
    expected = case["expected"]
    rows = expected.get("rows")
    tombstones = expected.get("tombstones")
    if not isinstance(rows, list) or not isinstance(tombstones, list):
        raise AssertionError(f"{label}: rows/tombstones must be arrays")
    cursor = expected.get("cursor")
    if not isinstance(cursor, int) or cursor < 0:
        raise AssertionError(f"{label}: cursor")
    ids = set()
    updated = []
    for side, values in (("row", rows), ("tombstone", tombstones)):
        for index, row in enumerate(values):
            where = f"{label}.{side}[{index}]"
            _validate_row(row, where)
            if row["id"] in ids:
                raise AssertionError(f"{where}: duplicate id {row['id']}")
            ids.add(row["id"])
            updated.append(row["updatedSeq"])
            if side == "tombstone" and row["body"]["type"] != "deleted":
                raise AssertionError(f"{where}: tombstone body must be deleted")
            origin = expected.get("origins", {}).get(row["id"])
            if origin is None:
                raise AssertionError(f"{where}: missing origin")
            event, origin_session = _find_record(case, origin) if origin.get("kind") == "dsh" else (None, None)
            if origin.get("kind") == "dsh":
                wanted_id = f"e-{origin_session}-{origin['seq']}"
                if event.get("type") == "tool/call" and row["id"].endswith("-approval"):
                    wanted_id += "-approval"
                if row["id"] != wanted_id:
                    raise AssertionError(f"{where}: row id {row['id']} != {wanted_id}")
                wanted_seq = _entry_seq(event["time"], event["seq"])
                if row["seq"] != wanted_seq:
                    raise AssertionError(f"{where}: entrySeq {row['seq']} != {wanted_seq}")
                if row["createdAt"] != event["time"]:
                    raise AssertionError(f"{where}: createdAt")
            elif origin.get("kind") == "ui":
                events = case.get("uiEvents", [])
                event = next((item for item in events if item.get("eventId") == origin.get("eventId")), None)
                if event is None:
                    raise AssertionError(f"{where}: ui event not found")
                wanted_seq = _entry_seq(event["time"], event.get("commitSeq") or 0)
                if row["seq"] != wanted_seq:
                    raise AssertionError(f"{where}: ui entrySeq {row['seq']} != {wanted_seq}")
                payload = _flatten_ui_payload(event)
                event_type = event.get("type", "")
                if row["id"].startswith("e-ui-"):
                    wanted_id = "e-ui-" + event["eventId"]
                elif event_type in ("approval.requested", "approval.decided"):
                    approval_id = (payload.get("approvalID") or payload.get("approvalId")
                                   or payload.get("requestId") or payload.get("requestID"))
                    wanted_id = payload.get("id") or f"e-main-approval-{approval_id}"
                elif event_type == "verification.reported":
                    task_id = payload.get("task_id") or payload.get("subjectId") or payload.get("subjectID")
                    wanted_id = f"e-main-task-{task_id}"
                elif event_type.startswith("task."):
                    task_id = (payload.get("task_id") or payload.get("taskID") or payload.get("taskId")
                               or payload.get("threadID"))
                    wanted_id = (f"e-main-task-{task_id}" if payload.get("task_id")
                                 else payload.get("id") or f"e-main-task-{task_id}")
                elif event_type == "conversation.automation_run" or event_type.startswith("routine.run_"):
                    run_id = payload.get("runID") or payload.get("runId") or event.get("runId")
                    wanted_id = payload.get("id") or f"e-main-automation-{run_id}"
                else:
                    wanted_id = payload.get("id") or payload.get("rowID") or ("e-ui-" + event["eventId"])
                if row["id"] != wanted_id:
                    raise AssertionError(f"{where}: ui row id {row['id']} != {wanted_id}")
            else:
                raise AssertionError(f"{where}: origin kind")
    if cursor < len(rows) + len(tombstones):
        raise AssertionError(f"{label}: cursor smaller than applied rows")
    if updated and cursor < max(updated):
        raise AssertionError(f"{label}: cursor smaller than updatedSeq")
    nonces = expected.get("chatActionNonces", {})
    if not isinstance(nonces, dict):
        raise AssertionError(f"{label}: chatActionNonces must be an object")
    row_by_id = {row["id"]: row for row in rows}
    for row_id, nonce in nonces.items():
        if row_id not in row_by_id:
            raise AssertionError(f"{label}: nonce for unknown row {row_id}")
        if row_by_id[row_id].get("role") != "user":
            raise AssertionError(f"{label}: nonce on non-user row {row_id}")
        if not isinstance(nonce, str) or not nonce:
            raise AssertionError(f"{label}: nonce must be a non-empty string")
    displays = expected.get("display")
    if not isinstance(displays, dict) or set(displays) != set(row_by_id):
        raise AssertionError(f"{label}: display must cover exactly the live rows")
    for row_id, display in displays.items():
        if not isinstance(display, dict) or set(display) != {"surface", "renderable", "wire"}:
            raise AssertionError(f"{label}: display shape for {row_id}")
        if not isinstance(display["surface"], str) or not display["surface"]:
            raise AssertionError(f"{label}: display surface for {row_id}")
        if not isinstance(display["renderable"], bool):
            raise AssertionError(f"{label}: display renderable for {row_id}")
        wire = display["wire"]
        if (not isinstance(wire, dict) or set(wire) != {"kind", "type"}
                or wire["kind"] not in _ROW_WIRE_KINDS or not isinstance(wire["type"], str)):
            raise AssertionError(f"{label}: display wire for {row_id}")


def validate_projection_fixture(fixture):
    _expect_phone_vector(fixture, "projection.phone")
    valid_count = 0
    invalid_count = 0
    for case in _family(fixture, "valid", "dshMapping", "projection"):
        name = case.get("name")
        if not isinstance(name, str) or not name:
            raise AssertionError("projection.dshMapping: name")
        if not isinstance(case.get("source"), str):
            raise AssertionError(f"projection {name}: missing source")
        records = case.get("records") if "epochs" not in case else [
            record for epoch in case["epochs"] for record in epoch["records"]]
        if not isinstance(records, list):
            raise AssertionError(f"projection {name}: records")
        events, skipped = _parse_session_records(records)
        if skipped:
            raise AssertionError(f"projection {name}: valid case skipped records {skipped}")
        _validate_expected_rows(case, case.get("sessionID", "gb-main"), f"projection.{name}")
        valid_count += 1
    for case in _family(fixture, "valid", "uiMapping", "projection"):
        name = case.get("name")
        if not isinstance(name, str) or not name:
            raise AssertionError("projection.uiMapping: name")
        if not isinstance(case.get("source"), str):
            raise AssertionError(f"projection {name}: missing source")
        _validate_expected_rows(case, case.get("sessionID", "gb-main"), f"projection.{name}")
        valid_count += 1
    invalid_records = fixture["invalid"]
    if not isinstance(invalid_records, list) or not invalid_records:
        raise AssertionError("projection: invalid must be a non-empty array")
    for case in invalid_records:
        name = case.get("name")
        if not isinstance(name, str) or not name:
            raise AssertionError("projection.invalid: name")
        if not isinstance(case.get("source"), str):
            raise AssertionError(f"projection invalid {name}: missing source")
        events, skipped = _parse_session_records(case.get("records", []))
        expected = case.get("expected")
        if not isinstance(expected, dict):
            raise AssertionError(f"projection invalid {name}: expected")
        wanted_events = [int(item) for item in expected.get("eventSeqs", [])]
        if [event["seq"] for event in events] != wanted_events:
            raise AssertionError(f"projection invalid {name}: event seqs")
        wanted_skipped = expected.get("skipped", [])
        if len(skipped) != len(wanted_skipped):
            raise AssertionError(f"projection invalid {name}: skipped count")
        for actual, wanted in zip(skipped, wanted_skipped):
            if actual["lineNumber"] != wanted.get("lineNumber") or actual["seq"] != wanted.get("seq"):
                raise AssertionError(f"projection invalid {name}: skipped entry {actual} != {wanted}")
        invalid_count += 1
    head = 0
    reset_state = None
    history_count = 0
    for case in _family(fixture, "valid", "history", "projection"):
        name = case.get("name")
        steps = case.get("steps")
        if not isinstance(steps, list) or not steps:
            raise AssertionError(f"projection.history {name}: steps")
        head = 0
        reset_state = None
        for index, step in enumerate(steps):
            where = f"projection.history.{name}[{index}]"
            if "rebuild" in step:
                expected = step.get("expectBatch")
                if not isinstance(expected, dict) or expected.get("reset") is not True:
                    raise AssertionError(f"{where}: rebuild must return a reset batch")
                _validate_batch_rows(expected, where)
                head = expected["cursor"]
                if head < len(expected.get("rows", [])) + len(expected.get("tombstones", [])):
                    raise AssertionError(f"{where}: cursor")
                reset_state = copy.deepcopy(expected)
            elif "watchAfter" in step:
                cursor = step["watchAfter"]
                expected = step.get("expectBatch")
                if not isinstance(expected, dict):
                    raise AssertionError(f"{where}: missing batch")
                if cursor <= 0 or cursor > head:
                    if expected.get("reset") is not True or reset_state is None:
                        raise AssertionError(f"{where}: out-of-range cursor must reset")
                    if expected != reset_state:
                        raise AssertionError(f"{where}: reset batch must equal the last reset")
                else:
                    if expected.get("reset") is not False:
                        raise AssertionError(f"{where}: in-range cursor must not reset")
                    _validate_batch_rows(expected, where)
                    for row in expected.get("rows", []):
                        if row["updatedSeq"] <= cursor:
                            raise AssertionError(f"{where}: row at or before cursor")
                    if expected.get("cursor") != head:
                        raise AssertionError(f"{where}: batch cursor must be the head")
                history_count += 1
            else:
                raise AssertionError(f"{where}: unknown step")
    streaming_count = 0
    for case in _family(fixture, "valid", "streaming", "projection"):
        streaming_count += 1
        _run_streaming_case(case)
    if valid_count == 0 or invalid_count == 0 or history_count == 0 or streaming_count == 0:
        raise AssertionError("projection: missing a vector family")
    # Mutation self-checks: the arithmetic must reject a shifted id/seq and a
    # wrong streaming expectation instead of merely echoing the fixture.
    def mutated_origin():
        mutated = copy.deepcopy(fixture)
        case = mutated["valid"]["dshMapping"][0]
        row = case["expected"]["rows"][0]
        row["seq"] += 1
        _validate_projection_fixture_inner(mutated)

    _expect_contract_failure("projection entrySeq", mutated_origin)

    def mutated_stream():
        mutated = copy.deepcopy(fixture)
        step = mutated["valid"]["streaming"][0]["steps"][0]
        step["expectEmitted"]["body"]["text"] = "wrong"
        _run_streaming_case(mutated["valid"]["streaming"][0])

    _expect_contract_failure("streaming coalescing", mutated_stream)
    return valid_count, invalid_count, history_count, streaming_count


def _validate_projection_fixture_inner(fixture):
    for case in _family(fixture, "valid", "dshMapping", "projection"):
        _validate_expected_rows(case, case.get("sessionID", "gb-main"), f"projection.{case.get('name')}")


def _validate_batch_rows(batch, where):
    rows = batch.get("rows")
    deletes = batch.get("deletes")
    if not isinstance(rows, list) or not isinstance(deletes, list):
        raise AssertionError(f"{where}: batch rows/deletes")
    ids = set()
    for index, row in enumerate(rows):
        _validate_row(row, f"{where}.rows[{index}]")
        if row["id"] in ids:
            raise AssertionError(f"{where}: duplicate batch row")
        ids.add(row["id"])
    if len(set(deletes)) != len(deletes):
        raise AssertionError(f"{where}: duplicate deletes")
    for index, row_id in enumerate(deletes):
        if not isinstance(row_id, str) or not row_id:
            raise AssertionError(f"{where}.deletes[{index}]")
    cursor = batch.get("cursor")
    if not isinstance(cursor, int) or cursor < 0:
        raise AssertionError(f"{where}: batch cursor")
    for row in rows:
        if row["updatedSeq"] > cursor:
            raise AssertionError(f"{where}: row updatedSeq beyond cursor")


class _StreamingModel:
    maximum = 10

    def __init__(self):
        self.visible = {}
        self.pending = {}
        self.order = {}
        self.counter = 0
        self.emissions = []
        self.last_now = 0.0

    def _clock(self, now):
        self.last_now = max(self.last_now, float(now))
        return self.last_now

    def _prune(self, now):
        self.emissions = [value for value in self.emissions if value > now - 1]

    def _emit(self, row_id, now):
        row = self.pending.pop(row_id)
        self.order.pop(row_id, None)
        self.visible[row_id] = row
        self.emissions.append(now)
        return row

    def submit(self, row, now):
        now = self._clock(now)
        self._prune(now)
        row = copy.deepcopy(row)
        if row["id"] not in self.pending:
            self.order[row["id"]] = self.counter
            self.counter += 1
        row["streaming"] = True
        self.pending[row["id"]] = row
        if len(self.emissions) < self.maximum:
            return self._emit(row["id"], now)
        return None

    def flush(self, now):
        now = self._clock(now)
        self._prune(now)
        output = []
        while len(self.emissions) < self.maximum and self.pending:
            row_id = min(self.pending, key=lambda key: self.order[key])
            output.append(self._emit(row_id, now))
        return output

    def next_flush_at(self):
        if not self.pending or not self.emissions:
            return None
        return min(self.emissions) + 1


def _run_streaming_case(case):
    model = _StreamingModel()
    for index, step in enumerate(case["steps"]):
        where = f"projection.streaming.{case['name']}[{index}]"
        if "submit" in step:
            row = step["submit"]["row"]
            if row["body"]["type"] not in _ROW_BODY_TYPES:
                raise AssertionError(f"{where}: row body")
            emitted = model.submit(row, step["submit"]["now"])
            wanted = step.get("expectEmitted")
            if wanted is None:
                if emitted is not None:
                    raise AssertionError(f"{where}: expected no emission")
            elif emitted != wanted:
                raise AssertionError(f"{where}: emitted {emitted} != {wanted}")
            if "expectFlush" in step:
                if model.flush(step["submit"]["now"]) != step["expectFlush"]:
                    raise AssertionError(f"{where}: inline flush")
        elif "flush" in step:
            flushed = model.flush(step["flush"]["now"])
            if flushed != step.get("expectRows", []):
                raise AssertionError(f"{where}: flush {flushed} != {step.get('expectRows')}")
        elif "state" in step:
            state = step["state"]
            if state.get("pendingCount") != len(model.pending):
                raise AssertionError(f"{where}: pendingCount")
            if state.get("rowCount") != len(model.visible):
                raise AssertionError(f"{where}: rowCount")
            if state.get("nextFlushAt") != model.next_flush_at():
                raise AssertionError(f"{where}: nextFlushAt")
        else:
            raise AssertionError(f"{where}: unknown streaming step")


class _TokenModel:
    def __init__(self, now=0, default_ttl=43200000, maximum=4096):
        self.now = int(now)
        self.default_ttl = int(default_ttl)
        self.maximum = int(maximum)
        self.records = {}
        self.current = {}
        self.counter = 0
        self.tokens = []

    @staticmethod
    def _identifier(value, name):
        if not isinstance(value, str):
            raise AssertionError(f"invalidInput:{name}")
        text = value.strip()
        if not text or len(text) > 256:
            raise AssertionError(f"invalidInput:{name}")
        return text

    @staticmethod
    def _capabilities(values):
        if not isinstance(values, list) or len(values) > 64:
            raise AssertionError("invalidInput:capabilities")
        result = []
        for value in values:
            if not isinstance(value, str):
                raise AssertionError("invalidInput:capabilities")
            text = value.strip()
            if not text or len(text) > 128:
                raise AssertionError("invalidInput:capabilities")
            if text not in result:
                result.append(text)
        return result

    def _remove(self, token):
        principal = self.records.pop(token, None)
        if principal is not None and self.current.get(principal["sessionId"]) == principal["incarnation"]:
            self.current.pop(principal["sessionId"], None)

    def _revoke_where(self, predicate):
        removed = [token for token, principal in self.records.items() if predicate(principal)]
        for token in removed:
            self._remove(token)
        return len(removed)

    def prune(self):
        return self._revoke_where(lambda principal: principal["expiresAt"] <= self.now)

    def issue(self, bot_id, session_id, kind, capabilities=None, expires_at=None, ttl=None):
        bot = self._identifier(bot_id, "botId")
        session = self._identifier(session_id, "sessionId")
        caps = self._capabilities(capabilities or [])
        if expires_at is not None:
            expiry = int(expires_at)
        else:
            ttl_value = self.default_ttl if ttl is None else int(ttl)
            if ttl_value <= 0:
                raise AssertionError("invalidInput:ttlMilliseconds")
            expiry = self.now + ttl_value
            if expiry > 2 ** 63 - 1 or expiry < -(2 ** 63):
                raise AssertionError("invalidInput:expiresAt")
        if expiry <= self.now:
            raise AssertionError("invalidInput:expiresAt")
        self.prune()
        if len(self.records) >= self.maximum:
            raise AssertionError("registryFull")
        self.counter += 1
        digest = hashlib.sha256(f"token-{self.counter}".encode()).digest()
        token = "dshg_" + base64.urlsafe_b64encode(digest).decode().rstrip("=")[:43]
        incarnation = hashlib.sha256(f"incarnation-{self.counter}".encode()).hexdigest()[:32]
        principal = {"botId": bot, "sessionId": session, "kind": kind,
                     "capabilities": caps, "expiresAt": expiry, "incarnation": incarnation}
        self.records[token] = principal
        self.current[session] = incarnation
        issued = {"token": token, "principal": principal}
        self.tokens.append(issued)
        return issued

    def issue_session(self, bot_id, session_id, kind, capabilities=None, expires_at=None, ttl=None):
        session = self._identifier(session_id, "sessionId")
        self.revoke_session(session)
        return self.issue(bot_id, session, kind, capabilities, expires_at, ttl)

    def lookup(self, token):
        if not isinstance(token, str) or not token or len(token) > 512:
            return None
        principal = self.records.get(token)
        if principal is None:
            return None
        if principal["expiresAt"] <= self.now:
            self._remove(token)
            return None
        return principal

    def lookup_session(self, session_id):
        if not isinstance(session_id, str):
            return None
        target = session_id.strip()
        incarnation = self.current.get(target)
        if not incarnation:
            return None
        for token, principal in self.records.items():
            if principal["sessionId"] == target and principal["incarnation"] == incarnation:
                if principal["expiresAt"] <= self.now:
                    self._remove(token)
                    return None
                return principal
        self.current.pop(target, None)
        return None

    def lookup_bearer(self, header):
        if not isinstance(header, str):
            return None
        parts = header.strip().split()
        if len(parts) != 2 or parts[0].lower() != "bearer":
            return None
        return self.lookup(parts[1])

    def revoke(self, token):
        if not isinstance(token, str) or not token or len(token) > 512:
            return False
        if token not in self.records:
            return False
        self._remove(token)
        return True

    def revoke_session(self, session_id):
        target = session_id.strip()
        return self._revoke_where(lambda principal: principal["sessionId"] == target)

    def revoke_bot(self, bot_id):
        target = bot_id.strip()
        return self._revoke_where(lambda principal: principal["botId"] == target)

    def rotate(self, token, capabilities=None, expires_at=None, ttl=None):
        if not isinstance(token, str) or not token or len(token) > 512:
            return None
        principal = self.records.get(token)
        if principal is None:
            return None
        if principal["expiresAt"] <= self.now:
            self._remove(token)
            return None
        new_caps = principal["capabilities"] if capabilities is None else capabilities
        if expires_at is not None:
            new_expiry = int(expires_at)
        elif ttl is not None:
            new_expiry = self.now + int(ttl)
        else:
            new_expiry = principal["expiresAt"]
        issued = self.issue(principal["botId"], principal["sessionId"], principal["kind"],
                            new_caps, new_expiry, None)
        self._remove(token)
        return issued

    def count(self):
        self.prune()
        return len(self.records)


def _expect_contract_failure(label, operation):
    try:
        operation()
    except AssertionError:
        return
    raise AssertionError(f"mutation {label!r} unexpectedly passed")


def _check_token_expect(issued, expect, label):
    principal = issued["principal"]
    expect = expect or {}
    if expect.get("tokenIndex") != _token_counter[0] - 1:
        raise AssertionError(f"{label}: token index")
    if "expiresAt" in expect and principal["expiresAt"] != expect["expiresAt"]:
        raise AssertionError(f"{label}: expiresAt")
    if "tokenPattern" in expect and not re.fullmatch(expect["tokenPattern"].removeprefix("re:"), issued["token"]):
        raise AssertionError(f"{label}: token pattern")
    if "incarnationPattern" in expect and not re.fullmatch(
            expect["incarnationPattern"].removeprefix("re:"), principal["incarnation"]):
        raise AssertionError(f"{label}: incarnation pattern")
    wanted = expect.get("principal", {})
    for key in ("botId", "sessionId", "kind", "capabilities"):
        if key in wanted and principal[key] != wanted[key]:
            raise AssertionError(f"{label}: principal {key}")


_token_counter = [0]


def _run_token_case(model, vector):
    tokens = []
    for index, step in enumerate(vector["steps"]):
        label = f"token.{vector['name']}[{index}]"
        operation = step.get("op")
        expect = step.get("expect")
        if expect is None:
            expect = {}
        if operation == "setClock":
            model.now = int(step["clock"])
        elif operation in ("issue", "issueSession"):
            try:
                if operation == "issueSession":
                    issued = model.issue_session(
                        step["botId"], step["sessionId"], step["kind"],
                        step.get("capabilities"), step.get("expiresAt"), step.get("ttlMilliseconds"))
                else:
                    issued = model.issue(
                        step["botId"], step["sessionId"], step["kind"],
                        step.get("capabilities"), step.get("expiresAt"), step.get("ttlMilliseconds"))
            except AssertionError as error:
                if step.get("expectError") == str(error):
                    continue
                raise
            _token_counter[0] = len(tokens) + 1
            if expect.get("tokenIndex") != len(tokens):
                raise AssertionError(f"{label}: token index")
            _check_token_expect(issued, expect, label)
            tokens.append(issued)
        elif operation == "lookup":
            resolved = model.lookup(tokens[step["tokenIndex"]]["token"])
            if (resolved is not None) != bool(expect.get("resolves")):
                raise AssertionError(f"{label}: lookup")
        elif operation == "lookupRaw":
            if (model.lookup(step["token"]) is not None) != bool(expect.get("resolves")):
                raise AssertionError(f"{label}: lookupRaw")
        elif operation == "lookupSession":
            resolved = model.lookup_session(step["sessionId"])
            if (resolved is not None) != bool(expect.get("resolves")):
                raise AssertionError(f"{label}: lookupSession")
            if "tokenIndex" in expect and resolved is not None:
                wanted = tokens[expect["tokenIndex"]]["principal"]
                if resolved["incarnation"] != wanted["incarnation"]:
                    raise AssertionError(f"{label}: lookupSession incarnation")
        elif operation == "lookupBearer":
            header = f"{step.get('scheme', 'Bearer')} {tokens[step['tokenIndex']]['token']}"
            if (model.lookup_bearer(header) is not None) != bool(expect.get("resolves")):
                raise AssertionError(f"{label}: lookupBearer")
        elif operation == "lookupBearerRaw":
            if (model.lookup_bearer(step.get("header")) is not None) != bool(expect.get("resolves")):
                raise AssertionError(f"{label}: lookupBearerRaw")
        elif operation in ("rotate", "rotateRaw"):
            old = tokens[step["tokenIndex"]]["token"] if operation == "rotate" else step.get("token")
            try:
                issued = model.rotate(old, step.get("capabilities"), step.get("expiresAt"),
                                      step.get("ttlMilliseconds"))
            except AssertionError as error:
                if step.get("expectError") == str(error):
                    continue
                raise
            expected_resolves = bool(expect.get("resolves", True))
            if (issued is not None) != expected_resolves:
                raise AssertionError(f"{label}: rotate result")
            if "tokenIndex" in expect:
                if issued is None or expect["tokenIndex"] != len(tokens):
                    raise AssertionError(f"{label}: rotate token index")
                tokens.append(issued)
                _token_counter[0] = len(tokens)
                _check_token_expect(issued, expect, label)
                if expect.get("sameSession") and issued["principal"]["sessionId"] != tokens[0]["principal"]["sessionId"]:
                    raise AssertionError(f"{label}: rotate session")
        elif operation == "revoke":
            if model.revoke(tokens[step["tokenIndex"]]["token"]) != bool(expect.get("removed")):
                raise AssertionError(f"{label}: revoke")
        elif operation == "revokeRaw":
            if model.revoke(step.get("token")) != bool(expect.get("removed")):
                raise AssertionError(f"{label}: revokeRaw")
        elif operation == "revokeSession":
            if model.revoke_session(step["sessionId"]) != expect.get("removed"):
                raise AssertionError(f"{label}: revokeSession")
        elif operation == "revokeBot":
            if model.revoke_bot(step["botId"]) != expect.get("removed"):
                raise AssertionError(f"{label}: revokeBot")
        elif operation == "count":
            if model.count() != expect:
                raise AssertionError(f"{label}: count {model.count()} != {expect}")
        else:
            raise AssertionError(f"{label}: unknown op {operation}")
    return tokens


def validate_session_lifecycle_fixture(fixture):
    _expect_phone_vector(fixture, "session-lifecycle.phone")
    workspace, invalid_workspace = _validate_session_workspace(fixture)
    registry = (fixture["valid"].get("tokenRegistry") or {})
    defaults = registry.get("defaults") or {}
    if defaults.get("defaultTTLMilliseconds") != 43200000:
        raise AssertionError("tokenRegistry: default TTL")
    if defaults.get("defaultMaximumTokens") != 4096:
        raise AssertionError("tokenRegistry: default maximum")
    if defaults.get("chatTTLMilliseconds") != 30 * 24 * 60 * 60 * 1000:
        raise AssertionError("tokenRegistry: chat TTL")
    if defaults.get("ephemeralTTLMilliseconds") != 12 * 60 * 60 * 1000:
        raise AssertionError("tokenRegistry: ephemeral TTL")
    token_cases = registry.get("cases") or []
    if not token_cases:
        raise AssertionError("tokenRegistry: no cases")
    for vector in token_cases:
        if not isinstance(vector.get("source"), str):
            raise AssertionError("tokenRegistry: source")
        model = _TokenModel(vector.get("clock", 0),
                            maximum=vector.get("maximumTokens", 4096))
        _run_token_case(model, vector)
    for vector in _family(fixture, "invalid", "tokenRegistry", "session-lifecycle"):
        if not isinstance(vector.get("source"), str):
            raise AssertionError("tokenRegistry invalid: source")
        model = _TokenModel(vector.get("clock", 0))
        operation = vector.get("op")
        try:
            if operation == "issue":
                model.issue(vector.get("botId", ""), vector.get("sessionId", ""),
                            vector.get("kind", "chat"), vector.get("capabilities"),
                            vector.get("expiresAt"), vector.get("ttlMilliseconds"))
            elif operation == "lookupRaw":
                if (model.lookup(vector.get("token")) is not None) != bool(
                        (vector.get("expect") or {}).get("resolves")):
                    raise AssertionError("invalid lookup")
                continue
            elif operation == "revokeRaw":
                if model.revoke(vector.get("token")) != bool(
                        (vector.get("expect") or {}).get("removed")):
                    raise AssertionError("invalid revoke")
                continue
            elif operation == "rotateRaw":
                issued = model.rotate(vector.get("token"))
                if (issued is not None) != bool((vector.get("expect") or {}).get("resolves")):
                    raise AssertionError("invalid rotate")
                continue
            else:
                raise AssertionError(f"unknown invalid token op {operation}")
        except AssertionError as error:
            if str(error) == vector.get("expectError"):
                continue
            raise
        raise AssertionError(f"token invalid {vector['name']}: expected {vector.get('expectError')}")
    sessions = _family(fixture, "valid", "sessions", "session-lifecycle")
    coverage = {"create": 0, "recover": 0, "rebuild": 0, "erase": 0, "prompt": 0,
                "cancel": 0, "claim": 0, "page": 0, "list": 0}
    allowed_actions = {"startMainSession", "sendUserMessage", "sendHiddenInteraction",
                       "sendTwoMessages", "switchMainSessionForErasure", "cancelDuringTurn"}
    allowed_presets = {"phone-bot", "pdsh-verifier", "phone-bot-maintainer"}
    for case in sessions:
        label = f"session-lifecycle.{case.get('name')}"
        if not isinstance(case.get("name"), str) or not isinstance(case.get("source"), str):
            raise AssertionError(f"{label}: name/source")
        if case.get("action") not in allowed_actions:
            raise AssertionError(f"{label}: action")
        expect = case.get("expect") or {}
        if "errorContains" in expect:
            raise AssertionError(f"{label}: valid case must not expect an error")
        if "result" not in expect and "results" not in expect:
            raise AssertionError(f"{label}: missing result")
        for seed in case.get("seedEvents", []) or []:
            if seed.get("type") != "runtime.started":
                raise AssertionError(f"{label}: seed type")
            principal = seed.get("principal") or {}
            if principal.get("kind") != "chat" or principal.get("botId") != "main":
                raise AssertionError(f"{label}: seed principal")
            data = seed.get("data") or {}
            if not set(data).issubset({"sessionId", "botId", "cwd"}):
                raise AssertionError(f"{label}: seed data members")
        for request in expect.get("createRequests", []):
            if set(request) != {"request"}:
                raise AssertionError(f"{label}: create request shape")
            payload = request["request"]
            if set(payload) != {"sessionId", "cwd", "agentPreset"}:
                raise AssertionError(f"{label}: create request members")
            if payload["agentPreset"] not in allowed_presets:
                raise AssertionError(f"{label}: create preset")
            if payload["cwd"] != _DEFAULT_BOT_ROOT:
                raise AssertionError(f"{label}: create cwd")
            session_id = payload["sessionId"]
            if not (session_id == "gb-main" or _REBUILT_ID_RE.fullmatch(session_id)
                    or (isinstance(session_id, str) and session_id.startswith("re:"))):
                raise AssertionError(f"{label}: create session id")
            coverage["create"] += 1
        if not expect.get("createRequests"):
            coverage["recover"] += 1
        if expect.get("archive"):
            coverage["rebuild"] += 1
        if expect.get("pageRequests") or "pageRequestCount" in expect:
            coverage["page"] += 1
        if expect.get("listRequests"):
            coverage["list"] += 1
        for request in expect.get("claimRequests", []):
            if set(request) != {"request"}:
                raise AssertionError(f"{label}: claim shape")
            payload = request["request"]
            if not set(payload).issubset({"sessionId", "sessionToken"}):
                raise AssertionError(f"{label}: claim members")
            if not payload.get("sessionId"):
                raise AssertionError(f"{label}: claim session")
            if "sessionToken" in payload:
                token = payload["sessionToken"]
                if not (isinstance(token, str) and (token.startswith("re:") or _TOKEN_RE.fullmatch(token))):
                    raise AssertionError(f"{label}: claim token")
            coverage["claim"] += 1
        for request in expect.get("promptRequests", []):
            if set(request) != {"request"}:
                raise AssertionError(f"{label}: prompt shape")
            payload = request["request"]
            if set(payload) != {"requestId", "sessionId", "mode", "content"}:
                raise AssertionError(f"{label}: prompt members")
            if payload["mode"] not in ("queue", "steer"):
                raise AssertionError(f"{label}: prompt mode")
            request_id = payload["requestId"]
            if not (isinstance(request_id, str) and (
                    _BOT_REQUEST_ID_RE.fullmatch(request_id)
                    or (request_id.startswith("re:") and "bot-" in request_id)
                    or request_id.startswith(_FROZEN_REQUEST_PREFIXES))):
                raise AssertionError(f"{label}: prompt requestId {request_id}")
            content = payload["content"]
            if (not isinstance(content, list) or len(content) != 1
                    or content[0].get("type") != "text" or not isinstance(content[0].get("text"), str)):
                raise AssertionError(f"{label}: prompt content")
            coverage["prompt"] += 1
        for request in expect.get("cancelRequests", []):
            payload = request["request"]
            if set(payload) != {"sessionId", "cause"} or payload["cause"] != {"kind": "user"}:
                raise AssertionError(f"{label}: cancel shape")
            coverage["cancel"] += 1
        for event in expect.get("events", []):
            if event["type"] == "runtime.started":
                if set(event["data"]) != {"sessionId", "botId", "cwd"}:
                    raise AssertionError(f"{label}: started data members")
                if event["data"]["botId"] != "main" or event["data"]["cwd"] != _DEFAULT_BOT_ROOT:
                    raise AssertionError(f"{label}: started data")
                if event["principal"].get("kind") != "chat":
                    raise AssertionError(f"{label}: started principal")
            elif event["type"] == "runtime.exited":
                if set(event["data"]) != {"sessionId", "reason", "replacedBy", "erasureId", "erasedRecords"}:
                    raise AssertionError(f"{label}: exited data members")
                if event["data"]["reason"] != "session-erased":
                    raise AssertionError(f"{label}: exited reason")
                if not isinstance(event["data"]["erasedRecords"], list):
                    raise AssertionError(f"{label}: erasedRecords")
                coverage["erase"] += 1
            else:
                raise AssertionError(f"{label}: lifecycle event type")
    for case in _family(fixture, "invalid", "sessions", "session-lifecycle"):
        expect = case.get("expect") or {}
        if not expect.get("errorContains"):
            raise AssertionError(f"session-lifecycle invalid {case.get('name')}: errorContains")
        if "result" in expect or "results" in expect:
            raise AssertionError(f"session-lifecycle invalid {case.get('name')}: must not expect a result")
    missing = [name for name, count in coverage.items() if count == 0]
    if missing:
        raise AssertionError(f"session-lifecycle: missing coverage {missing}")

    def mutated_preset():
        mutated = copy.deepcopy(fixture)
        mutated["valid"]["sessions"][0]["expect"]["createRequests"][0]["request"]["agentPreset"] = "standard"
        validate_session_lifecycle_fixture_inner(mutated)

    _expect_contract_failure("session create preset", mutated_preset)

    def mutated_started():
        mutated = copy.deepcopy(fixture)
        mutated["valid"]["sessions"][0]["expect"]["events"][0]["data"]["extra"] = True
        validate_session_lifecycle_fixture_inner(mutated)

    _expect_contract_failure("runtime.started members", mutated_started)

    def mutated_token():
        mutated = copy.deepcopy(fixture)
        mutated["valid"]["tokenRegistry"]["cases"][0]["steps"][1]["expect"]["resolves"] = False
        model = _TokenModel(mutated["valid"]["tokenRegistry"]["cases"][0].get("clock", 0))
        _run_token_case(model, mutated["valid"]["tokenRegistry"]["cases"][0])

    _expect_contract_failure("token lookup", mutated_token)

    def mutated_grapheme():
        mutated = copy.deepcopy(fixture)
        case = next(c for c in mutated["valid"]["workspace"]
                    if c["name"] == "grapheme-truncation")
        case["safe"] = case["safe"][:-1]
        _validate_session_workspace(mutated)

    _expect_contract_failure("grapheme truncation", mutated_grapheme)

    validate_session_snapshot_wait_vectors(fixture)
    return (len(workspace) + len(invalid_workspace),
            len(token_cases) + len(_family(fixture, "invalid", "tokenRegistry", "session-lifecycle")),
            len(sessions) + len(_family(fixture, "invalid", "sessions", "session-lifecycle")))


def validate_session_lifecycle_fixture_inner(fixture):
    allowed_presets = {"phone-bot", "pdsh-verifier", "phone-bot-maintainer"}
    for case in fixture["valid"]["sessions"]:
        for request in (case.get("expect") or {}).get("createRequests", []):
            if request["request"]["agentPreset"] not in allowed_presets:
                raise AssertionError("create preset")
        for event in (case.get("expect") or {}).get("events", []):
            if event["type"] == "runtime.started" and set(event["data"]) != {"sessionId", "botId", "cwd"}:
                raise AssertionError("runtime.started members")


MCP_RPC_VECTOR = "mcp-rpc-cases.phone.json"
IDENTITY_APPROVAL_VECTOR = "identity-approval-cases.phone.json"
TOOL_CALL_VECTOR = "tool-call-cases.phone.json"
VOLATILE_PHONE_VECTOR = "volatile-context.phone.json"

MCP_RPC_TRANSPORTS = frozenset({"single", "batch", "notification"})
MCP_RPC_INVALID_TRANSPORTS = frozenset({"single", "batch", "http"})
MCP_RPC_ERROR_CODES = frozenset({-32601, -32602, -32603})
MCP_RPC_HTTP_ERRORS = frozenset({
    "invalid request target", "not found", "origin mismatch", "unauthorized",
    "invalid JSON", "invalid JSON-RPC message", "request too large", "method not allowed",
})
MCP_RPC_REQUIRED_VALID = frozenset({
    "initialize-echo-2025-06-18", "initialize-echo-2025-11-25", "initialize-echo-2025-03-26",
    "initialize-fallback-unknown-version", "initialize-missing-version", "ping",
    "tools-list-static-with-native-merge", "tools-list-per-caller-hides-create-teammate",
    "tools-call-success", "tools-call-server-prefix", "tools-call-native-forward",
    "tools-call-unknown-tool-result", "unknown-method", "unknown-method-forwarded-native",
    "batch-mixed", "batch-single-request", "notification-only", "batch-notifications-only",
})
MCP_RPC_REQUIRED_INVALID = frozenset({
    "tools-call-missing-name", "tools-call-arguments-not-object", "batch-element-not-object",
    "batch-element-missing-method", "http-get", "http-delete", "http-query-string",
    "http-dotdot-segment", "http-trailing-slash", "http-different-case", "http-unknown-path",
    "http-origin-mismatch", "http-missing-bearer", "http-wrong-bearer", "http-invalid-json",
    "http-body-too-large",
})

IDENTITY_APPROVAL_ERRORS = frozenset({
    "invalid identity registration", "unauthorized", "argument digest mismatch", "unknown_tool",
    "invalid_request", "unattributed", "cross_session_denied", "timeout", "unavailable",
    "identity registration refused",
})
IDENTITY_TOKEN_MODES = frozenset({"current", "none", "wrong", "revoked", "foreign"})
APPROVAL_SCOPES = frozenset({"until", "session", "none"})
APPROVAL_DECISIONS = frozenset({"allowOnce", "always", "deny"})
IDENTITY_REQUIRED_VALID = frozenset({
    "register-success", "register-prefixed-name", "cancel-success", "cancel-twice",
    "approval-allow-once", "approval-always-until", "approval-always-session",
    "approval-sandbox-escalation", "approval-cancel-cascade", "approval-pending-durable",
})
IDENTITY_REQUIRED_INVALID = frozenset({
    "register-unauthorized-missing-token", "register-unauthorized-wrong-token",
    "register-unauthorized-revoked-token", "register-unauthorized-foreign-session",
    "register-digest-mismatch", "register-invalid-body", "register-unknown-tool",
    "cancel-invalid", "approval-deny", "approval-timeout-interactive",
    "approval-scope-mismatch", "approval-digest-mismatch", "approval-bash-command-mismatch",
    "approval-unattributed", "approval-invalid-body", "approval-sandbox-wrong-scope",
    "approval-pending-expired",
})

TOOL_ERROR_CODES = frozenset({
    "invalid_arguments", "unknown_tool", "unattributed", "cross_session_read_denied",
    "permission_denied", "timeout", "unavailable", "execution_failed", "memory_unavailable",
    "memory-evidence-invalid", "record_erased",
})
TOOL_NAMES = (
    "ask_user", "show_next_steps", "show_attachment", "show_document", "show_progress",
    "show_checklist", "show_link", "UpdateMemory", "ReadMemory", "RecallMemory", "Task",
    "AwaitTask", "StopSubagent", "UpdateRoutine", "ListRoutines", "RequestApproval", "SendToUser",
)


def _canonical_digest(arguments):
    payload = json.dumps(arguments, ensure_ascii=False, sort_keys=True,
                         separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def _require(condition, message):
    if not condition:
        raise AssertionError(message)


def _unique_names(cases, where):
    names = [case.get("name") for case in cases]
    _require(all(isinstance(name, str) and name for name in names), f"{where}: every case needs a name")
    _require(len(names) == len(set(names)), f"{where}: duplicate case name")


def _cases_by_name(cases):
    return {case["name"]: case for case in cases}


def validate_mcp_rpc_fixture(fixture):
    _require(fixture.get("schemaVersion") == 1, "mcp-rpc-cases.phone: schemaVersion must be 1")
    _require(fixture.get("vector") == "mcp-rpc-cases.phone", "mcp-rpc-cases.phone: vector")
    _require(fixture.get("upstream") == [], "mcp-rpc-cases.phone: upstream must be []")
    _require(fixture.get("protocolVersions") == ["2025-11-25", "2025-06-18", "2025-03-26"],
             "mcp-rpc-cases.phone: protocolVersions")
    _require(fixture.get("maximumBodyBytes") == 1_048_576,
             "mcp-rpc-cases.phone: maximumBodyBytes must be 1048576")
    native = fixture.get("native")
    _require(isinstance(native, dict) and isinstance(native.get("instructions"), str)
             and native["instructions"], "mcp-rpc-cases.phone: native.instructions")
    native_tools = native.get("tools")
    _require(isinstance(native_tools, list) and native_tools, "mcp-rpc-cases.phone: native.tools")
    for index, tool in enumerate(native_tools):
        _require(isinstance(tool, dict) and isinstance(tool.get("name"), str)
                 and isinstance(tool.get("inputSchema"), dict),
                 f"mcp-rpc-cases.phone.native.tools[{index}]")
    _require(any(tool["name"] == "ask_user" for tool in native_tools),
             "mcp-rpc-cases.phone: native collision case needs a native ask_user")
    _require(len({tool["name"] for tool in native_tools}) == len(native_tools),
             "mcp-rpc-cases.phone: duplicate native tool name")

    valid = fixture.get("valid")
    invalid = fixture.get("invalid")
    _require(isinstance(valid, list) and valid, "mcp-rpc-cases.phone: valid")
    _require(isinstance(invalid, list) and invalid, "mcp-rpc-cases.phone: invalid")
    _unique_names(valid, "mcp-rpc-cases.phone.valid")
    _unique_names(invalid, "mcp-rpc-cases.phone.invalid")
    _require(MCP_RPC_REQUIRED_VALID <= set(_cases_by_name(valid)),
             "mcp-rpc-cases.phone: missing frozen valid case")
    _require(MCP_RPC_REQUIRED_INVALID <= set(_cases_by_name(invalid)),
             "mcp-rpc-cases.phone: missing frozen invalid case")

    for case in valid:
        transport = case.get("transport")
        _require(transport in MCP_RPC_TRANSPORTS, f"{case['name']}: transport")
        expect = case.get("expect")
        _require(isinstance(expect, dict) and expect, f"{case['name']}: expect")
        if transport == "single":
            request = case.get("request")
            _require(isinstance(request, dict) and isinstance(request.get("method"), str),
                     f"{case['name']}: request.method")
            kinds = [key for key in ("result", "error", "toolList") if key in expect]
            _require(len(kinds) == 1, f"{case['name']}: expect exactly one outcome")
            if "error" in expect:
                _require(expect["error"].get("code") in MCP_RPC_ERROR_CODES,
                         f"{case['name']}: error code")
            if "toolList" in expect:
                listed = expect["toolList"]
                names = listed.get("names")
                if names is not None:
                    _require(names.count("ask_user") == 1 and names[-1] == "native_echo",
                             f"{case['name']}: static list must append native once and keep the Bot collision")
                    _require(len(names) == listed.get("count"),
                             f"{case['name']}: count must equal names length")
        elif transport == "batch":
            _require(isinstance(case.get("messages"), list), f"{case['name']}: messages")
            _require(expect.get("status") in {200, 202, 400}, f"{case['name']}: batch status")
            if expect["status"] == 200:
                requests = [m for m in case["messages"]
                            if isinstance(m, dict) and "id" in m]
                _require(expect.get("replyCount") == len(requests),
                         f"{case['name']}: replyCount must equal request count")
                _require(expect.get("ids") == [m["id"] for m in requests],
                         f"{case['name']}: ids must preserve request order")
            else:
                _require(expect.get("empty") is True or expect.get("error") == "invalid JSON-RPC message",
                         f"{case['name']}: terminal batch form")
        else:
            _require(isinstance(case.get("message"), dict), f"{case['name']}: message")
            _require(expect.get("status") == 202 and expect.get("empty") is True,
                     f"{case['name']}: notification must be 202 empty")

    for case in invalid:
        transport = case.get("transport")
        _require(transport in MCP_RPC_INVALID_TRANSPORTS, f"{case['name']}: transport")
        expect = case.get("expect")
        _require(isinstance(expect, dict), f"{case['name']}: expect")
        if transport == "single":
            _require(expect.get("error", {}).get("code") in MCP_RPC_ERROR_CODES,
                     f"{case['name']}: error code")
        elif transport == "batch":
            _require(expect.get("status") == 400
                     and expect.get("error") == "invalid JSON-RPC message",
                     f"{case['name']}: invalid batch frame")
        else:
            _require(expect.get("status") in {400, 401, 403, 404, 405, 413},
                     f"{case['name']}: http status")
            _require(expect.get("error") in MCP_RPC_HTTP_ERRORS,
                     f"{case['name']}: http error body")
    return len(valid), len(invalid)


def mcp_rpc_mutations(fixture):
    def expect_failure(label, mutate):
        copy = json.loads(json.dumps(fixture))
        mutate(copy)
        try:
            validate_mcp_rpc_fixture(copy)
        except AssertionError:
            return
        raise AssertionError(f"mcp-rpc mutation not detected: {label}")

    expect_failure("drop-protocol-version", lambda f: f["protocolVersions"].pop())
    expect_failure("wrong-max-body", lambda f: f.update({"maximumBodyBytes": 1_048_577}))
    expect_failure("duplicate-case", lambda f: f["valid"].append(json.loads(json.dumps(f["valid"][0]))))
    expect_failure("bad-batch-count", lambda f: next(
        c for c in f["valid"] if c["name"] == "batch-mixed")["expect"].update({"replyCount": 3}))
    expect_failure("unknown-http-body", lambda f: next(
        c for c in f["invalid"] if c["name"] == "http-get")["expect"].update({"error": "nope"}))
    return 5


def validate_identity_approval_fixture(fixture):
    _require(fixture.get("schemaVersion") == 1, "identity-approval-cases.phone: schemaVersion")
    _require(fixture.get("vector") == "identity-approval-cases.phone", "identity-approval-cases.phone: vector")
    _require(fixture.get("upstream") == [], "identity-approval-cases.phone: upstream must be []")
    defaults = fixture.get("defaults")
    _require(defaults == {"approvalTimeoutMs": 300_000, "approvalExpiryMs": 86_400_000},
             "identity-approval-cases.phone: defaults")
    credential = fixture.get("credentialContract")
    _require(credential == {
        "tokenPrefix": "dshg_",
        "tokenLength": 48,
        "tokenURLSafeAlphabet": "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_",
        "incarnationHexLength": 32,
        "defaultTTLMilliseconds": 43_200_000,
        "maximumTokens": 4_096,
        "attributionTTLMilliseconds": 330_000,
        "attributionMaximumEntries": 4_096,
    }, "identity-approval-cases.phone: credentialContract")
    valid = fixture.get("valid")
    invalid = fixture.get("invalid")
    _require(isinstance(valid, list) and valid, "identity-approval-cases.phone: valid")
    _require(isinstance(invalid, list) and invalid, "identity-approval-cases.phone: invalid")
    _unique_names(valid, "identity-approval-cases.phone.valid")
    _unique_names(invalid, "identity-approval-cases.phone.invalid")
    _require(IDENTITY_REQUIRED_VALID <= set(_cases_by_name(valid)),
             "identity-approval-cases.phone: missing valid case")
    _require(IDENTITY_REQUIRED_INVALID <= set(_cases_by_name(invalid)),
             "identity-approval-cases.phone: missing invalid case")

    for where, cases in (("valid", valid), ("invalid", invalid)):
        for case in cases:
            name = case["name"]
            setup = case.get("setup")
            _require(isinstance(setup, dict) and isinstance(setup.get("botId"), str)
                     and isinstance(setup.get("sessionId"), str)
                     and setup.get("kind") in {"chat", "task", "routine"},
                     f"{name}: setup")
            kind = case.get("kind")
            _require(kind in {"register", "cancel", "approval"}, f"{name}: kind")
            expect = case.get("expect")
            _require(isinstance(expect, dict) and expect, f"{name}: expect")
            if kind == "register":
                registration = case.get("registration")
                _require(isinstance(registration, dict)
                         and isinstance(registration.get("callId"), str)
                         and isinstance(registration.get("tool"), str)
                         and isinstance(registration.get("arguments"), dict),
                         f"{name}: registration")
                _require(case.get("token", "current") in IDENTITY_TOKEN_MODES, f"{name}: token mode")
                _require(case.get("argsDigest", "computed") in {"computed", "mismatch"},
                         f"{name}: digest mode")
                if expect.get("ok") is True:
                    _require(where == "valid", f"{name}: success in invalid list")
                else:
                    _require(expect.get("error") in IDENTITY_APPROVAL_ERRORS
                             or expect.get("error") in {"argument digest mismatch"},
                             f"{name}: exact register error")
            elif kind == "cancel":
                if "body" not in case:
                    _require(isinstance(case.get("registration"), dict), f"{name}: registration")
                _require(isinstance(expect.get("ok"), bool) or isinstance(expect.get("first"), bool),
                         f"{name}: cancel outcome")
            else:
                registration = case.get("registration")
                _require(isinstance(registration, dict)
                         and isinstance(registration.get("callId"), str)
                         and isinstance(registration.get("tool"), str)
                         and isinstance(registration.get("arguments"), dict),
                         f"{name}: registration")
                approval = case.get("approval")
                _require(isinstance(approval, dict), f"{name}: approval")
                if "alwaysScope" in approval:
                    _require(approval["alwaysScope"] in APPROVAL_SCOPES, f"{name}: alwaysScope")
                if case.get("argsDigest") not in (None, "0" * 64):
                    _require(re.fullmatch(r"[0-9a-f]{64}", case["argsDigest"]) is not None,
                             f"{name}: argsDigest shape")
                    _require(case["argsDigest"] == _canonical_digest(registration["arguments"]),
                             f"{name}: argsDigest must be SHA-256 of the canonical arguments")
                if "decision" in case:
                    _require(case["decision"] in APPROVAL_DECISIONS, f"{name}: decision")
                for key in ("approvalTimeoutMs", "approvalExpiryMs", "expireAfterMs"):
                    if key in case:
                        _require(isinstance(case[key], int) and not isinstance(case[key], bool)
                                 and case[key] > 0, f"{name}: {key}")
    return len(valid), len(invalid)


def identity_approval_mutations(fixture):
    def expect_failure(label, mutate):
        copy = json.loads(json.dumps(fixture))
        mutate(copy)
        try:
            validate_identity_approval_fixture(copy)
        except AssertionError:
            return
        raise AssertionError(f"identity-approval mutation not detected: {label}")

    expect_failure("wrong-timeout", lambda f: f["defaults"].update({"approvalTimeoutMs": 300_001}))
    expect_failure("bad-digest", lambda f: next(
        c for c in f["valid"] if c["name"] == "approval-allow-once").update({"argsDigest": "a" * 64}))
    expect_failure("unknown-register-error", lambda f: next(
        c for c in f["invalid"] if c["name"] == "register-unauthorized-wrong-token"
    )["expect"].update({"error": "nope"}))
    expect_failure("duplicate-name", lambda f: f["valid"].append(json.loads(json.dumps(f["valid"][0]))))
    expect_failure("bad-scope", lambda f: next(
        c for c in f["valid"] if c["name"] == "approval-always-until"
    )["approval"].update({"alwaysScope": "forever"}))
    expect_failure("wrong-token-length", lambda f: f["credentialContract"].update({"tokenLength": 47}))
    return 6


def validate_tool_call_fixture(fixture):
    _require(fixture.get("schemaVersion") == 1, "tool-call-cases.phone: schemaVersion")
    _require(fixture.get("vector") == "tool-call-cases.phone", "tool-call-cases.phone: vector")
    _require(fixture.get("upstream") == [], "tool-call-cases.phone: upstream must be []")
    tools = fixture.get("tools")
    _require(tools == list(TOOL_NAMES), "tool-call-cases.phone: tools must list every P0 name")
    for key in ("valid", "invalid", "denials", "unknown"):
        _require(isinstance(fixture.get(key), list) and fixture[key],
                 f"tool-call-cases.phone: {key}")
        _unique_names(fixture[key], f"tool-call-cases.phone.{key}")

    valid = fixture["valid"]
    invalid = fixture["invalid"]
    denials = fixture["denials"]
    unknowns = fixture["unknown"]
    _require(set(case.get("tool") for case in valid) == set(tools),
             "tool-call-cases.phone: every tool needs a valid case")
    _require(set(case.get("tool") for case in denials) == set(tools),
             "tool-call-cases.phone: every tool needs a per-caller denial")
    for tool in tools:
        if tool == "ListRoutines":
            continue
        _require(any(case.get("tool") == tool for case in invalid),
                 f"tool-call-cases.phone: {tool} needs an invalid-arguments case")

    for where, cases in (("valid", valid), ("invalid", invalid),
                         ("denials", denials), ("unknown", unknowns)):
        for case in cases:
            name = case["name"]
            _require(case.get("tool") in set(tools) | {"show_table", "show_info", "no_such_tool"},
                     f"{name}: tool")
            _require(isinstance(case.get("setup"), dict), f"{name}: setup")
            _require("arguments" in case, f"{name}: arguments")
            expect = case.get("expect")
            _require(isinstance(expect, dict), f"{name}: expect")
            if case.get("layer") == "rpc":
                _require(expect.get("rpcError") == -32602, f"{name}: rpc error")
                continue
            _require(isinstance(expect.get("isError"), bool), f"{name}: expect.isError")
            if expect["isError"]:
                _require(expect.get("errorCode") in TOOL_ERROR_CODES, f"{name}: errorCode")
            else:
                _require(isinstance(expect.get("structured"), dict), f"{name}: structured")
    for case in denials:
        _require(case["expect"]["errorCode"] == "permission_denied", f"{case['name']}: denial code")
    for case in unknowns:
        _require(case["expect"]["errorCode"] == "unknown_tool", f"{case['name']}: unknown code")
        _require(case.get("skipRegistration") is True, f"{case['name']}: skipRegistration")
    return len(valid), len(invalid), len(denials), len(unknowns)


def tool_call_mutations(fixture):
    def expect_failure(label, mutate):
        copy = json.loads(json.dumps(fixture))
        mutate(copy)
        try:
            validate_tool_call_fixture(copy)
        except AssertionError:
            return
        raise AssertionError(f"tool-call mutation not detected: {label}")

    expect_failure("drop-tool-valid", lambda f: f.update({"valid": [c for c in f["valid"] if c["tool"] != "ReadMemory"]}))
    expect_failure("drop-tool-denial", lambda f: f["denials"].pop(0))
    expect_failure("bad-denial-code", lambda f: f["denials"][0]["expect"].update({"errorCode": "unknown_tool"}))
    expect_failure("duplicate-name", lambda f: f["valid"].append(json.loads(json.dumps(f["valid"][0]))))
    expect_failure("missing-invalid", lambda f: f.update({"invalid": [c for c in f["invalid"] if c["tool"] != "ReadMemory"]}))
    return 5


def validate_volatile_phone_fixture(upstream, overlay):
    _require(overlay.get("schemaVersion") == 1, "volatile-context.phone: schemaVersion")
    _require(overlay.get("vector") == "volatile-context.phone", "volatile-context.phone: vector")
    _require(overlay.get("upstream") == "volatile-context.json", "volatile-context.phone: upstream")
    assembly = overlay.get("assemblyCases")
    producer = overlay.get("producerCases")
    _require(isinstance(assembly, list) and assembly, "volatile-context.phone: assemblyCases")
    _require(isinstance(producer, list) and producer, "volatile-context.phone: producerCases")
    _unique_names(assembly, "volatile-context.phone.assemblyCases")
    _unique_names(producer, "volatile-context.phone.producerCases")
    for case in assembly:
        input_data = case.get("input")
        _require(isinstance(input_data, dict), f"{case['name']}: input")
        _require(input_data.get("kind") in {"chat", "task", "routine"}, f"{case['name']}: kind")
        _require(isinstance(case.get("expect"), dict) and case["expect"], f"{case['name']}: expect")
    for case in producer:
        principal = case.get("principal")
        _require(isinstance(principal, dict) and principal.get("kind") == "chat",
                 f"{case['name']}: principal")
        request = case.get("request")
        _require(isinstance(request, dict), f"{case['name']}: request")
        if case["name"] != "request-extra-key":
            _require(set(request) == {"sessionId"},
                     f"{case['name']}: request must contain only sessionId")
        else:
            _require(set(request) == {"sessionId", "botID"},
                     f"{case['name']}: extra-key case shape")
        _require(isinstance(case.get("provider"), dict), f"{case['name']}: provider")
        expect = case.get("expect")
        _require(isinstance(expect, dict) and ("error" in expect) != ("response" in expect),
                 f"{case['name']}: expect exactly one of error/response")
        if "error" in expect:
            _require(expect["error"] in {"invalid_arguments", "cross_session_read_denied",
                                         "timeout", "unavailable"},
                     f"{case['name']}: producer error")
    names = set(_cases_by_name(producer))
    for required in ("caps-variant-overflow", "caps-persona-overflow", "caps-memory-overflow",
                     "caps-automation-overflow", "caps-total-overflow", "credential-shaped-content",
                     "provider-timeout", "no-stale-after-failure", "snapshot-valid-blocks"):
        _require(required in names, f"volatile-context.phone: missing producer case {required}")
    merged = merged_fixture(upstream, overlay)
    _require(merged.get("valid") is not None and merged.get("invalid") is not None,
             "volatile-context.phone: upstream cases must survive the merge")
    return len(assembly), len(producer)


def volatile_phone_mutations(upstream, fixture):
    def expect_failure(label, mutate):
        copy = json.loads(json.dumps(fixture))
        mutate(copy)
        try:
            validate_volatile_phone_fixture(upstream, copy)
        except AssertionError:
            return
        raise AssertionError(f"volatile-context mutation not detected: {label}")

    expect_failure("drop-caps", lambda f: f["producerCases"].pop(0))
    expect_failure("extra-request-key", lambda f: next(
        c for c in f["producerCases"] if c["name"] == "snapshot-valid-blocks"
    )["request"].update({"botID": "other"}))
    expect_failure("ambiguous-expect", lambda f: next(
        c for c in f["producerCases"] if c["name"] == "snapshot-valid-blocks"
    )["expect"].update({"error": "unavailable"}))
    expect_failure("duplicate-assembly", lambda f: f["assemblyCases"].append(
        json.loads(json.dumps(f["assemblyCases"][0]))))
    return 4


def main() -> int:
    check_overlays()
    rpc_valid, rpc_invalid = validate_mcp_rpc_fixture(load(MCP_RPC_VECTOR))
    rpc_mutations = mcp_rpc_mutations(load(MCP_RPC_VECTOR))
    identity_valid, identity_invalid = validate_identity_approval_fixture(load(IDENTITY_APPROVAL_VECTOR))
    identity_mutations = identity_approval_mutations(load(IDENTITY_APPROVAL_VECTOR))
    tool_valid, tool_invalid, tool_denials, tool_unknowns = validate_tool_call_fixture(load(TOOL_CALL_VECTOR))
    tool_mutations = tool_call_mutations(load(TOOL_CALL_VECTOR))
    volatile_assembly, volatile_producer = validate_volatile_phone_fixture(
        load("volatile-context.json"), load(VOLATILE_PHONE_VECTOR))
    volatile_mutations = volatile_phone_mutations(
        load("volatile-context.json"), load(VOLATILE_PHONE_VECTOR))
    check_event(load("event-envelope.json")["valid"]["event"],
                "event-envelope.schema.json", "event")
    for index, case in enumerate(load("event-envelope.json")["invalid"]):
        rejects_event(case["event"], "event-envelope.schema.json", f"event.invalid[{index}]")

    # phoneDSH P25 additive cases live in the append-only overlay so a fresh
    # upstream export stays byte-identical: `agent.comm`, the absent/null
    # presence pairs (CCR-1), `authz.grant_snapshot` (CCR-2), and the separate
    # ephemeral envelope (no commitSeq, never durable).
    phone_envelope = load("event-envelope.phone.json")
    if phone_envelope.get("vector") != "event-envelope.phone":
        raise AssertionError("event-envelope.phone: vector must be event-envelope.phone")
    valid_phone_events = phone_envelope.get("validCases")
    if not isinstance(valid_phone_events, list) or not valid_phone_events:
        raise AssertionError("event-envelope.phone: validCases must be a non-empty array")
    for index, case in enumerate(valid_phone_events):
        where = f"event-envelope.phone.validCases[{index}]"
        check_event(case["event"], "event-envelope.schema.json", where)
        if case["event"].get("type") == GRANT_SNAPSHOT_TYPE:
            if not isinstance(case.get("provenance"), str) or "Swift" not in case["provenance"]:
                raise AssertionError(f"{where}: grant snapshot vector must name its Swift provenance")
        if case.get("validation", {}).get("valid") is not True:
            raise AssertionError(f"{where}: validation.valid must be true")
        if case["event"].get("type") == "erasure":
            check(case["event"].get("data"), "erasure-event.schema.json", f"{where}.data")
    invalid_phone_events = phone_envelope.get("invalidCases")
    if not isinstance(invalid_phone_events, list) or not invalid_phone_events:
        raise AssertionError("event-envelope.phone: invalidCases must be a non-empty array")
    for index, case in enumerate(invalid_phone_events):
        rejects_event(case["event"], "event-envelope.schema.json",
                      f"event-envelope.phone.invalidCases[{index}]")

    ephemeral_valid = phone_envelope.get("ephemeralValidCases")
    if not isinstance(ephemeral_valid, list) or not ephemeral_valid:
        raise AssertionError("event-envelope.phone: ephemeralValidCases must be a non-empty array")
    for index, case in enumerate(ephemeral_valid):
        where = f"event-envelope.phone.ephemeralValidCases[{index}]"
        check(case["event"], "event-envelope.ephemeral.schema.json", where)
        if "commitSeq" in case["event"]:
            raise AssertionError(f"{where}: ephemeral events must not carry commitSeq")
        if case.get("validation", {}).get("valid") is not True:
            raise AssertionError(f"{where}: validation.valid must be true")
    ephemeral_invalid = phone_envelope.get("ephemeralInvalidCases")
    if not isinstance(ephemeral_invalid, list) or not ephemeral_invalid:
        raise AssertionError("event-envelope.phone: ephemeralInvalidCases must be a non-empty array")
    for index, case in enumerate(ephemeral_invalid):
        rejects(case["event"], "event-envelope.ephemeral.schema.json",
                f"event-envelope.phone.ephemeralInvalidCases[{index}]")
    if not any("commitSeq" in case["event"] for case in ephemeral_invalid):
        raise AssertionError("event-envelope.phone: ephemeral negative vectors must cover commitSeq")

    store_steps = validate_store_fixture(load(STORE_VECTOR))
    action_steps = validate_user_action_fixture(load(USER_ACTION_VECTOR))
    check(load("tool-catalog.json")["valid"], "tool-catalog.schema.json", "tool-catalog")
    # phoneDSH P26 additive: the content-card `final` flag lives in the
    # append-only overlay, so the runtime view is the merged p0/p1 catalog.
    phone_catalog = load_merged("tool-catalog.json")["valid"]
    check({"p0": phone_catalog["p0"], "p1": phone_catalog["p1"]},
          "tool-catalog.schema.json", "tool-catalog.phone")
    content_cards = validate_content_card_final(phone_catalog)
    content_card_mutations = content_card_final_mutations(phone_catalog)
    check(load("volatile-context.json")["valid"], "volatile-context.schema.json", "volatile-context")
    check(load("card-payload.json")["valid"], "card-payload.schema.json", "card-payload")
    for index, case in enumerate(load("card-payload.json")["invalid"]):
        if case["result"].get("ok") is not False:
            raise AssertionError(f"card-payload.invalid[{index}]: expected fail-closed result")
    # `card-payload.json` is the untouched output of export-vectors.mjs. The
    # phoneDSH delta (host option ids, recommended-first, negative fixtures)
    # lives in `card-payload.phone.json`; mixing it into the upstream file would
    # make a re-export produce a diff.
    choice_tools = ("ask_user", "show_next_steps")
    for index, case in enumerate(load("card-payload.json")["valid"]):
        if case["tool"] not in choice_tools:
            continue
        card = case["result"].get("card", {})
        for key in ("options", "steps"):
            for option in card.get(key, []):
                if isinstance(option, dict) and "id" in option:
                    raise AssertionError(
                        f"card-payload.valid[{index}].{key}: upstream export must not carry "
                        "phone-assigned option ids; put phone deltas in card-payload.phone.json")
    phone = load("card-payload.phone.json")
    check(phone["valid"], "card-payload.schema.json", "card-payload.phone")
    for index, case in enumerate(phone["valid"]):
        if case["tool"] not in choice_tools:
            continue
        card = case["result"].get("card", {})
        for key in ("options", "steps"):
            for option in card.get(key, []):
                if isinstance(option, dict) and "id" not in option:
                    raise AssertionError(
                        f"card-payload.phone.valid[{index}].{key}: phone cards must carry option ids")
    for index, case in enumerate(phone["invalid"]):
        if case["result"].get("ok") is not False:
            raise AssertionError(f"card-payload.phone.invalid[{index}]: expected fail-closed result")
    check(load("llm-ledger.json")["valid"], "llm-ledger.schema.json", "llm-ledger")
    ledger_phone = load("llm-ledger.phone.json")
    check(ledger_phone["valid"], "llm-ledger.schema.json", "llm-ledger.phone")
    if ledger_phone["valid"]["purpose"] != "memory-maintenance":
        raise AssertionError("llm-ledger.phone: the phone-only purpose must be memory-maintenance")
    check(load("model-purpose-policy.json")["valid"], "model-purpose-policy.schema.json", "model-purpose-policy")
    check(load("watchdog.json")["valid"], "watchdog.schema.json", "watchdog")
    check(load("fish-director.json")["valid"], "fish-director.schema.json", "fish-director")
    check(load("context-profiles.json")["valid"], "context-profiles.schema.json", "context-profiles")
    check(load("context-lint.json")["valid"], "context-lint.schema.json", "context-lint")
    effects = load_merged("tool-effects.json")
    check_many(effects["valid"], "tool-effects.schema.json", "tool-effects")
    check_many(effects["invalid"], "tool-effects.schema.json", "tool-effects.invalid")
    # phoneDSH-native MCP tools from PR59 (BLE) are classified by the same
    # shared table. They are not part of the upstream exporter batch, so they
    # live in tool-effects.phone.json and are validated with the same schema.
    check_many(effects.get("nativeMcp", []),
               "tool-effects.schema.json", "tool-effects.nativeMcp")
    approval_upstream = load("approval-patterns.json")
    check_many(approval_upstream["valid"], "approval-patterns.schema.json", "approval-patterns")
    check_many(approval_upstream["invalid"], "approval-patterns.schema.json", "approval-patterns.invalid")
    validate_approval_downgrade_fixture(load("approval-patterns.phone.json"), approval_upstream)
    # Memory, wake-marker and proactive vectors moved to spec/bot/v2 at the
    # ownership handover. Run that validator from here so the existing
    # `phone-spec` stage keeps covering both trees.
    reference_valid, reference_invalid, _ = validate_record_reference_fixture(
        load(RECORD_REFERENCE_VECTOR))
    envelope_valid, envelope_invalid, envelope_decode_errors, _ = validate_observation_envelope_fixture(
        load(OBSERVATION_ENVELOPE_VECTOR))
    query_valid, query_invalid, _ = validate_record_query_fixture(load(RECORD_QUERY_VECTOR))
    erasure_valid, erasure_invalid, erasure_mutations = validate_erasure_event_fixture(
        load(ERASURE_EVENT_VECTOR))
    record_mutations = mutation_count_for_record_contracts(
        load(RECORD_REFERENCE_VECTOR), load(OBSERVATION_ENVELOPE_VECTOR), load(RECORD_QUERY_VECTOR))
    verify_valid_outputs, verify_invalid_outputs, verify_budget_valid, verify_budget_invalid, \
        verify_valid_reports, verify_invalid_reports, verify_mutations = (
            validate_verification_fixture(load(VERIFICATION_VECTOR)))
    check_v2_tree()
    check_many(load("row-projection.json")["valid"], "row-projection.schema.json", "row-projection")
    row_fixture = load_merged("row-protocol.json")
    receipts = row_fixture.get("approvalReceipts")
    if not isinstance(receipts, list) or not receipts:
        raise AssertionError("row-protocol.phone: approvalReceipts must be a non-empty array")
    receipt_statuses = set()
    for index, case in enumerate(receipts):
        if not isinstance(case, dict):
            raise AssertionError(f"row-protocol.phone.approvalReceipts[{index}] must be an object")
        if set(case) != {"name", "status", "scope", "label"}:
            raise AssertionError(
                f"row-protocol.phone.approvalReceipts[{index}] must contain exactly name/status/scope/label")
        for key in ("name", "status", "scope", "label"):
            if not isinstance(case[key], str) or not case[key]:
                raise AssertionError(
                    f"row-protocol.phone.approvalReceipts[{index}].{key} must be a non-empty string")
        if case["status"] in receipt_statuses:
            raise AssertionError(
                f"row-protocol.phone.approvalReceipts: duplicate status {case['status']}")
        receipt_statuses.add(case["status"])
    protocol = row_fixture["valid"]
    check(protocol["row"], "row.schema.json", "row")
    check(protocol["widgetRow"], "row.schema.json", "widgetRow")
    check(protocol["batch"], "row-batch.schema.json", "row-batch")
    check(protocol["action"], "user-action.schema.json", "user-action")
    check(protocol["cardAnswer"], "user-action.schema.json", "user-action.cardAnswer")
    for index, case in enumerate(row_fixture["invalidActions"]):
        rejects(case["action"], "user-action.schema.json", f"user-action.invalid[{index}]")
    check(protocol["result"], "action-result.schema.json", "action-result")
    for index, case in enumerate(row_fixture["invalid"]):
        check(case["result"], "action-result.schema.json", f"action-result.invalid[{index}]")
    valid_origins, invalid_origins, mutations = validate_turn_origin_fixture(load(TURN_ORIGIN_VECTOR))
    valid_egress, invalid_egress, egress_mutations = validate_mcp_egress_fixture(load(MCP_EGRESS_VECTOR))
    valid_authority, authority_changes, authority_task, authority_mutations = (
        validate_authority_fixture(load(AUTHORITY_VECTOR)))
    lifecycle_workspace, lifecycle_tokens, lifecycle_sessions = (
        validate_session_lifecycle_fixture(load(SESSION_LIFECYCLE_VECTOR)))
    projection_valid, projection_invalid, projection_history, projection_streaming = (
        validate_projection_fixture(load(PROJECTION_VECTOR)))
    print("bot vectors: PASS (schemas, positive vectors, negative vectors; "
          f"turn-origin {valid_origins} valid / {invalid_origins} invalid, "
          f"{mutations} mutation checks; "
          f"mcp-egress {valid_egress} valid / {invalid_egress} invalid, "
          f"{egress_mutations} mutation checks; "
          f"authority {valid_authority} creators / {authority_changes} changes / "
          f"{authority_task} task subsets, {authority_mutations} mutation checks; "
          f"session-lifecycle {lifecycle_workspace} workspace / {lifecycle_tokens} token / "
          f"{lifecycle_sessions} session vectors, "
          f"projection {projection_valid} valid / {projection_invalid} invalid / "
          f"{projection_history} history / {projection_streaming} streaming vectors, "
          f"record-reference {reference_valid} valid / {reference_invalid} invalid, "
          f"observation-envelope {envelope_valid} valid / {envelope_invalid} invalid / "
          f"{envelope_decode_errors} decode errors, "
          f"record-query {query_valid} valid / {query_invalid} invalid, "
          f"erasure-event {erasure_valid} valid / {erasure_invalid} invalid / "
          f"{erasure_mutations} mutations, "
          f"{record_mutations} mutation checks; "
          f"verification {verify_valid_outputs} valid / {verify_invalid_outputs} invalid outputs, "
          f"{verify_budget_valid} valid / {verify_budget_invalid} invalid budgets, "
          f"{verify_valid_reports} valid / {verify_invalid_reports} invalid reports, "
          f"{verify_mutations} mutation checks; "
          f"mcp-rpc {rpc_valid} valid / {rpc_invalid} invalid, {rpc_mutations} mutation checks; "
          f"identity-approval {identity_valid} valid / {identity_invalid} invalid, "
          f"{identity_mutations} mutation checks; "
          f"tool-call {tool_valid} valid / {tool_invalid} invalid / {tool_denials} denials / "
          f"{tool_unknowns} unknown, {tool_mutations} mutation checks; "
          f"volatile-phone {volatile_assembly} assembly / {volatile_producer} producer, "
          f"{volatile_mutations} mutation checks; "
          f"content-card-final {content_cards} tools / {content_card_mutations} mutation checks; "
          f"store {store_steps} steps, user-action {action_steps} steps)")
    return 0


VERIFICATION_RATIO = 0.3
VERIFICATION_TOOLS = ("read", "grep", "glob", "bash")
VERIFICATION_VERDICTS = ("passed", "failed", "uncertain")
VERIFICATION_SUBJECTS = ("task", "routine")
VERIFICATION_OUTPUT_STATES = ("valid", "invalid", "budget_exceeded", "unavailable")


def verifier_budget_limit_ms(budget_ms):
    """Reference implementation of P26 §2.8: floor(task budget × 30%)."""
    if not isinstance(budget_ms, int) or isinstance(budget_ms, bool):
        raise AssertionError("verifier budget: budgetMs must be an integer")
    if budget_ms < 0:
        raise AssertionError("verifier budget: budgetMs must be non-negative")
    return budget_ms * 3 // 10


def _canonical_verification_ref(raw):
    parsed = parse_record_reference(raw)
    return parsed is not None and parsed["canonical"] == raw


def _verification_output_semantics(output, require_refs=True):
    """Rules the JSON schema cannot express: passed => nothing unverified."""
    if not isinstance(output, dict):
        return "output must be an object"
    verdict = output.get("verdict")
    if verdict not in VERIFICATION_VERDICTS:
        return "unknown verdict"
    refs = output.get("refs")
    if not isinstance(refs, list) or (require_refs and not refs):
        return "refs must be a non-empty array"
    for ref in refs:
        if not _canonical_verification_ref(ref):
            return f"reference is not canonical: {ref!r}"
    unverified = output.get("unverified")
    if not isinstance(unverified, list):
        return "unverified must be an array"
    if verdict == "passed" and unverified:
        return "a passed verdict requires an empty unverified array"
    return None


def _verification_report_semantics(report):
    if not isinstance(report, dict):
        return "report must be an object"
    subject_kind = report.get("subjectKind")
    if subject_kind not in VERIFICATION_SUBJECTS:
        return "unknown subjectKind"
    subject_id = report.get("subjectId")
    if subject_kind == "task":
        if report.get("task_id") != subject_id:
            return "task report must carry the identical task_id"
    else:
        if report.get("routine_id") != subject_id:
            return "routine report must carry the identical routine_id"
        if not isinstance(report.get("runId"), str) or not report["runId"]:
            return "routine report must carry runId"
    verification = report.get("verification")
    if not isinstance(verification, dict):
        return "verification must be an object"
    budget = verification.get("budget")
    if not isinstance(budget, dict):
        return "budget must be an object"
    if budget.get("ratio") != VERIFICATION_RATIO:
        return "budget ratio must be 0.3"
    limit = budget.get("limitMs")
    used = budget.get("usedMs")
    exceeded = budget.get("exceeded")
    if not isinstance(limit, int) or isinstance(limit, bool) or limit < 0:
        return "limitMs must be a non-negative integer"
    if not isinstance(used, int) or isinstance(used, bool) or used < 0:
        return "usedMs must be a non-negative integer"
    if exceeded is not (used > limit):
        return "exceeded must be true exactly when usedMs > limitMs"
    if verification.get("output") not in VERIFICATION_OUTPUT_STATES:
        return "unknown output state"
    output_state = verification.get("output")
    if output_state != "valid" and verification.get("verdict") != "uncertain":
        return "a non-valid host output must be uncertain"
    raw = {key: verification[key] for key in ("verdict", "summary", "refs", "unverified")}
    return _verification_output_semantics(raw, require_refs=output_state == "valid")


def validate_verification_fixture(fixture):
    """Validate P26 §2.8 verifier policy, output, report and budget vectors."""
    if fixture.get("schemaVersion") != 1:
        raise AssertionError("verification: schemaVersion must be 1")
    if fixture.get("vector") != "verification.phone":
        raise AssertionError("verification: vector must be verification.phone")
    if fixture.get("upstream") != []:
        raise AssertionError("verification: phone-only vector must declare upstream: []")
    delta = fixture.get("delta")
    if not isinstance(delta, list) or not delta:
        raise AssertionError("verification: delta must be a non-empty string array")
    policy = fixture.get("policy")
    if not isinstance(policy, dict):
        raise AssertionError("verification: policy must be an object")
    if policy.get("presetId") != "pdsh-verifier":
        raise AssertionError("verification: the verifier preset is pdsh-verifier")
    if policy.get("principalKind") != "verifier":
        raise AssertionError("verification: the principal kind is verifier")
    if policy.get("budgetRatio") != VERIFICATION_RATIO:
        raise AssertionError("verification: budgetRatio must be 0.3")
    if tuple(policy.get("tools", [])) != VERIFICATION_TOOLS:
        raise AssertionError(f"verification: tool whitelist must be {VERIFICATION_TOOLS}")
    denied = policy.get("deniedTools")
    if not isinstance(denied, list) or not denied:
        raise AssertionError("verification: deniedTools must be a non-empty array")
    if set(policy["tools"]) & set(denied):
        raise AssertionError("verification: a tool cannot be both allowed and denied")
    for required in ("write", "edit", "SendToUser", "SendToAgent", "Task",
                     "UpdateMemory", "web_fetch"):
        if required not in denied:
            raise AssertionError(f"verification: {required} must be denied")
    if policy.get("hiddenGlobalTools") is not True:
        raise AssertionError("verification: inherited global tools must be hidden")
    bash = policy.get("bash")
    if not isinstance(bash, dict) or not bash.get("allowed") or not bash.get("denied"):
        raise AssertionError("verification: bash allow/deny vectors must be non-empty")
    for command in bash["allowed"]:
        if not isinstance(command, str) or not (
                command.startswith("phone record search ")
                or command.startswith("phone record read ")
                or command.split(" ", 1)[0] in {
                    "cat", "ls", "grep", "rg", "head", "tail", "wc", "pwd",
                    "stat", "file", "diff", "git", "od",
                }):
            raise AssertionError(f"verification: unexpected read-only command {command!r}")
    for command in bash["denied"]:
        if command in bash["allowed"]:
            raise AssertionError(f"verification: command both allowed and denied: {command!r}")

    valid_outputs = fixture.get("valid")
    invalid_outputs = fixture.get("invalid")
    if not isinstance(valid_outputs, list) or not valid_outputs:
        raise AssertionError("verification: valid outputs must be non-empty")
    if not isinstance(invalid_outputs, list) or not invalid_outputs:
        raise AssertionError("verification: invalid outputs must be non-empty")
    covered_verdicts = set()
    for index, case in enumerate(valid_outputs):
        where = f"verification.valid[{index}]"
        check(case.get("output"), "verifier-output.schema.json", where)
        reason = _verification_output_semantics(case.get("output"))
        if reason is not None:
            raise AssertionError(f"{where}: {reason}")
        covered_verdicts.add(case["output"]["verdict"])
    if covered_verdicts != set(VERIFICATION_VERDICTS):
        raise AssertionError("verification: valid outputs must cover passed/failed/uncertain")
    invalid_reasons = set()
    for index, case in enumerate(invalid_outputs):
        where = f"verification.invalid[{index}]"
        reason = case.get("reason")
        if not isinstance(reason, str) or not reason:
            raise AssertionError(f"{where}: invalid case needs a reason")
        invalid_reasons.add(reason)
        accepted = True
        try:
            check(case.get("output"), "verifier-output.schema.json", where)
        except Exception:
            accepted = False
        if accepted and _verification_output_semantics(case.get("output")) is None:
            raise AssertionError(f"{where}: negative fixture unexpectedly validates")
    for reason in ("verdict", "required", "minItems", "maxItems", "session-id",
                   "passed-requires-empty-unverified", "minLength", "additionalProperties"):
        if reason not in invalid_reasons:
            raise AssertionError(f"verification: missing output negative {reason!r}")

    budgets = fixture.get("budgets")
    if not isinstance(budgets, dict):
        raise AssertionError("verification: budgets must be an object")
    for case in budgets.get("valid", []):
        expected = verifier_budget_limit_ms(case["budgetMs"])
        if case.get("limitMs") != expected:
            raise AssertionError(f"verification.budgets.valid[{case.get('name')}]: "
                                 f"limit {case.get('limitMs')} != {expected}")
        if "usedMs" in case and case.get("exceeded") is not (case["usedMs"] > expected):
            raise AssertionError(f"verification.budgets.valid[{case.get('name')}]: exceeded mismatch")
    if not any(case.get("exceeded") is True for case in budgets.get("valid", [])):
        raise AssertionError("verification: budget vectors must cover the over-limit case")
    for case in budgets.get("invalid", []):
        accepted = True
        try:
            if case.get("limitMs") != verifier_budget_limit_ms(case["budgetMs"]):
                raise AssertionError("wrong limit")
        except AssertionError:
            accepted = False
        if accepted:
            raise AssertionError(f"verification.budgets.invalid[{case.get('name')}]: "
                                 "negative fixture unexpectedly validates")

    reports = fixture.get("reports")
    if not isinstance(reports, dict):
        raise AssertionError("verification: reports must be an object")
    valid_reports = reports.get("valid")
    invalid_reports = reports.get("invalid")
    if not isinstance(valid_reports, list) or not valid_reports:
        raise AssertionError("verification: reports.valid must be non-empty")
    if not isinstance(invalid_reports, list) or not invalid_reports:
        raise AssertionError("verification: reports.invalid must be non-empty")
    subjects = set()
    for index, case in enumerate(valid_reports):
        where = f"verification.reports.valid[{index}]"
        check(case.get("report"), "verification-report.schema.json", where)
        reason = _verification_report_semantics(case.get("report"))
        if reason is not None:
            raise AssertionError(f"{where}: {reason}")
        subjects.add(case["report"]["subjectKind"])
    if subjects != set(VERIFICATION_SUBJECTS):
        raise AssertionError("verification: valid reports must cover task and routine")
    for index, case in enumerate(invalid_reports):
        where = f"verification.reports.invalid[{index}]"
        if not case.get("reason"):
            raise AssertionError(f"{where}: invalid case needs a reason")
        accepted = True
        try:
            check(case.get("report"), "verification-report.schema.json", where)
        except Exception:
            accepted = False
        if accepted and _verification_report_semantics(case.get("report")) is None:
            raise AssertionError(f"{where}: negative fixture unexpectedly validates")

    mutations = 0

    def expect_failure(label, mutate):
        nonlocal mutations
        mutated = json.loads(json.dumps(fixture))
        mutate(mutated)
        try:
            validate_verification_fixture(mutated)
        except AssertionError:
            mutations += 1
            return
        raise AssertionError(f"verification mutation {label!r} unexpectedly passed")

    expect_failure("passed-with-unverified", lambda value: value["valid"][0]["output"]
                   .__setitem__("unverified", ["not checked"]))
    expect_failure("budget-ratio", lambda value: value["policy"].__setitem__("budgetRatio", 0.5))
    expect_failure("tool-widened", lambda value: value["policy"]["tools"].append("write"))
    expect_failure("task-id-mismatch", lambda value: value["reports"]["valid"][0]["report"]
                   .__setitem__("task_id", "task-other"))
    expect_failure("budget-exceeded", lambda value: value["reports"]["valid"][0]["report"]["verification"]["budget"]
                   .__setitem__("exceeded", True))
    return (len(valid_outputs), len(invalid_outputs), len(budgets.get("valid", [])),
            len(budgets.get("invalid", [])), len(valid_reports), len(invalid_reports), mutations)


def check_v2_tree() -> None:
    """Invoke the phoneDSH-owned v2 validator without a second CI stage."""
    import importlib.util

    path = ROOT / "spec" / "bot" / "v2" / "tools" / "validate_vectors.py"
    spec = importlib.util.spec_from_file_location("bot_v2_validate_vectors", path)
    if spec is None or spec.loader is None:
        raise AssertionError(f"cannot load {path.relative_to(ROOT)}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    if module.main() != 0:
        raise AssertionError("spec/bot/v2 validation failed")


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        print(f"bot vectors: FAIL: {exc}", file=sys.stderr)
        sys.exit(1)
