#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Validate Bot v1 schemas and the exported positive/negative conformance vectors."""
from __future__ import annotations

import copy
import json
import posixpath
import re
import sys
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
# A phone-only vector has no dsh-bot upstream export to extend. Keep this list
# explicit; `check_golden.py` has the same registration.
PHONE_ONLY_VECTORS = frozenset({
    TURN_ORIGIN_VECTOR, MCP_EGRESS_VECTOR, AUTHORITY_VECTOR,
    RECORD_REFERENCE_VECTOR, OBSERVATION_ENVELOPE_VECTOR, RECORD_QUERY_VECTOR,
    ERASURE_EVENT_VECTOR,
    VERIFICATION_VECTOR,
    "tool-catalog-tiers.phone.json",
    "volatile-context-time.phone.json",
    "model-purpose-enforcement.phone.json",
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
        if source.get("checkout") != upstream.get("source", {}).get("checkout"):
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


W5_TIER_CLASSES = frozenset({"adb", "ble", "venus", "ssh"})


def w5_tier_problem(case):
    """Return the first tiering law a W5 tool-catalog case violates, or None."""
    catalog = case.get("catalog", {})
    tiers = catalog.get("tiers", {})
    p0 = [item.get("name") for item in catalog.get("p0", [])]
    p1 = [item.get("name") for item in catalog.get("p1", [])]
    known = set(p0) | set(p1)
    requires = {item.get("name"): item.get("requires") for item in catalog.get("p0", []) + catalog.get("p1", [])
                if item.get("requires") is not None}
    core, device, discoverable = tiers.get("core", []), tiers.get("device", []), tiers.get("discoverable", [])
    names = list(core) + list(discoverable)
    for entry in device:
        if entry.get("class") not in W5_TIER_CLASSES:
            return "unknown_device_class"
        names.extend(entry.get("tools", []))
    seen = set()
    for name in names:
        if name in seen:
            return "tool_in_two_tiers"
        seen.add(name)
    for name in core:
        if name not in known:
            return "core_tool_missing_from_p0"
    if any(requires.get(name) is not None for name in core):
        return "device_tool_in_core"
    device_names = {tool for entry in device for tool in entry.get("tools", [])}
    if set(core) & device_names:
        return "device_tool_in_core"
    connection = case.get("connection")
    listed = case.get("listed")
    if connection is not None and listed is not None:
        expected = set(core) | set(discoverable)
        for entry in device:
            if connection.get(entry.get("class")) is True:
                expected |= set(entry.get("tools", []))
        if set(listed) != expected:
            if set(listed) & device_names and any(
                    connection.get(entry.get("class")) is False
                    and set(listed) & set(entry.get("tools", [])) for entry in device):
                return "stale_device_listing"
            return "listing_mismatch"
        not_listed = case.get("notListed")
        if not_listed is not None and set(not_listed) & set(listed):
            return "listing_mismatch"
    return None


def w5_hour_problem(case):
    import re
    current = case.get("current", "")
    if case.get("precision") != "hour":
        return "minute_precision"
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2} \d{2}:00 \([^()]+\)", current):
        if re.fullmatch(r"\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} \([^()]+\)", current):
            return "seconds_in_hour_bucket"
        return "not_a_local_hour_bucket"
    if not current.split(" ", 1)[1].split(":", 1)[1].startswith("00 "):
        return "minute_precision"
    return None


W5_SMALL = "deepseek-flash"
W5_LARGE = {"deepseek-v4-pro", "deepseek-pro", "deepseek-reasoner", "deepseek-chat"}
W5_SMALL_PURPOSES = frozenset({
    "triage", "memory-extract", "reflect", "compact", "watchdog",
    "completion-check", "memory-maintenance",
})


def w5_model_allowed(purpose, model):
    normalized = (model or "").strip().lower()
    if not normalized:
        return False, "EPURPOSE_MODEL_REQUIRED"
    if purpose in {"front-turn", "worker-turn"}:
        return True, None
    if purpose not in W5_SMALL_PURPOSES:
        return False, "EPURPOSE_MODEL_DENIED"
    if normalized == W5_SMALL or normalized.startswith(W5_SMALL + "-"):
        return True, None
    return False, "EPURPOSE_MODEL_DENIED"


def validate_w5_fixtures(load, check, rejects, check_many):
    tiers = load("tool-catalog-tiers.phone.json")
    check(tiers["valid"]["catalog"], "tool-catalog.schema.json", "tool-catalog-tiers.valid.catalog")
    problem = w5_tier_problem(tiers["valid"])
    if problem is not None:
        raise AssertionError(f"tool-catalog-tiers.valid: {problem}")
    for index, case in enumerate(tiers["invalid"]):
        payload = case["case"]
        if w5_tier_problem(payload) != case["reason"]:
            raise AssertionError(
                f"tool-catalog-tiers.invalid[{index}]: expected {case['reason']}, "
                f"got {w5_tier_problem(payload)}")
        if case["reason"] == "unknown_device_class":
            rejects(payload.get("catalog"), "tool-catalog.schema.json",
                    f"tool-catalog-tiers.invalid[{index}].catalog")
        # The other negative cases are schema-valid by design; the tier law rejects them.

    volatile = load("volatile-context-time.phone.json")
    if w5_hour_problem(volatile["valid"]["timeBlock"]) is not None:
        raise AssertionError("volatile-context-time.valid: time block is not hour precision")
    if volatile["valid"]["rendered"].count("Current local time:") != 1:
        raise AssertionError("volatile-context-time.valid: time block must render exactly once")
    if volatile["valid"]["timeBlock"]["current"] not in volatile["valid"]["rendered"]:
        raise AssertionError("volatile-context-time.valid: rendered text must carry the hour bucket")
    for index, case in enumerate(volatile["invalid"]):
        if w5_hour_problem(case["case"]) != case["reason"]:
            raise AssertionError(
                f"volatile-context-time.invalid[{index}]: expected {case['reason']}, "
                f"got {w5_hour_problem(case['case'])}")

    purpose = load("model-purpose-enforcement.phone.json")
    for index, case in enumerate(purpose["valid"]):
        allowed, code = w5_model_allowed(case["purpose"], case["model"])
        if allowed is not case["allowed"] or code is not None:
            raise AssertionError(f"model-purpose-enforcement.valid[{index}]: unexpected decision")
    for index, case in enumerate(purpose["invalid"]):
        allowed, code = w5_model_allowed(case["purpose"], case["model"])
        if allowed or code != case["code"]:
            raise AssertionError(
                f"model-purpose-enforcement.invalid[{index}]: expected {case['code']}, got {code}")
    return len(tiers["valid"].get("listed", [])), len(volatile["invalid"]), len(purpose["invalid"])


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


def main() -> int:
    check_overlays()
    check(load("event-envelope.json")["valid"]["event"], "event-envelope.schema.json", "event")
    for index, case in enumerate(load("event-envelope.json")["invalid"]):
        rejects(case["event"], "event-envelope.schema.json", f"event.invalid[{index}]")

    # phoneDSH P25 additive: `agent.comm` is a durable event type carried in
    # the unchanged envelope. Its phone cases live in the append-only overlay
    # so a fresh upstream export stays byte-identical.
    phone_envelope = load("event-envelope.phone.json")
    if phone_envelope.get("vector") != "event-envelope.phone":
        raise AssertionError("event-envelope.phone: vector must be event-envelope.phone")
    valid_phone_events = phone_envelope.get("validCases")
    if not isinstance(valid_phone_events, list) or not valid_phone_events:
        raise AssertionError("event-envelope.phone: validCases must be a non-empty array")
    for index, case in enumerate(valid_phone_events):
        where = f"event-envelope.phone.validCases[{index}]"
        check(case["event"], "event-envelope.schema.json", where)
        if case.get("validation", {}).get("valid") is not True:
            raise AssertionError(f"{where}: validation.valid must be true")
        if case["event"].get("type") == "erasure":
            check(case["event"].get("data"), "erasure-event.schema.json", f"{where}.data")
    invalid_phone_events = phone_envelope.get("invalidCases")
    if not isinstance(invalid_phone_events, list) or not invalid_phone_events:
        raise AssertionError("event-envelope.phone: invalidCases must be a non-empty array")
    for index, case in enumerate(invalid_phone_events):
        rejects(case["event"], "event-envelope.schema.json",
                f"event-envelope.phone.invalidCases[{index}]")

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
    validate_w5_fixtures(load, check, rejects, check_many)
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
    print("bot vectors: PASS (schemas, positive vectors, negative vectors; "
          f"turn-origin {valid_origins} valid / {invalid_origins} invalid, "
          f"{mutations} mutation checks; "
          f"mcp-egress {valid_egress} valid / {invalid_egress} invalid, "
          f"{egress_mutations} mutation checks; "
          f"authority {valid_authority} creators / {authority_changes} changes / "
          f"{authority_task} task subsets, {authority_mutations} mutation checks; "
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
          f"content-card-final {content_cards} tools / {content_card_mutations} mutation checks)")
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
                    "stat", "file", "diff", "git",
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
