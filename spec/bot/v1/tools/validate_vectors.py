#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Validate Bot v1 schemas and the exported positive/negative conformance vectors."""
from __future__ import annotations

import json
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
# A phone-only vector has no dsh-bot upstream export to extend. Keep this list
# explicit; `check_golden.py` has the same registration.
RECORD_REFERENCE_VECTOR = "record-reference.phone.json"
OBSERVATION_ENVELOPE_VECTOR = "observation-envelope.phone.json"
RECORD_QUERY_VECTOR = "record-query.phone.json"
# A phone-only vector has no dsh-bot upstream export to extend. Keep this list
# explicit; `check_golden.py` has the same registration.
PHONE_ONLY_VECTORS = frozenset({
    TURN_ORIGIN_VECTOR, MCP_EGRESS_VECTOR,
    RECORD_REFERENCE_VECTOR, OBSERVATION_ENVELOPE_VECTOR, RECORD_QUERY_VECTOR,
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
MCP_EGRESS_SUITES = frozenset({"egress", "identity", "tools-call"})
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
}
MCP_EGRESS_VALID_BOUNDARIES = {
    "egress": frozenset({"correct", "query", "header-name-case", "non-mcp", "route-scope"}),
    "identity": frozenset({"correct", "rotated"}),
    "tools-call": frozenset({"correct"}),
}
MCP_EGRESS_INVALID_BOUNDARIES = {
    "egress": frozenset({"missing", "wrong", "placeholder", "case", "empty", "query", "whitespace"}),
    "identity": frozenset({
        "missing", "empty", "foreign", "mismatch", "revoked", "expired", "unknown",
        "placeholder", "case", "rotated",
    }),
    "tools-call": frozenset({"hidden-team-tool", "prefix-strip", "unknown", "case", "empty"}),
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
            else:
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
    return json.loads((BOT / name).read_text(encoding="utf-8"))


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
    invalid_phone_events = phone_envelope.get("invalidCases")
    if not isinstance(invalid_phone_events, list) or not invalid_phone_events:
        raise AssertionError("event-envelope.phone: invalidCases must be a non-empty array")
    for index, case in enumerate(invalid_phone_events):
        rejects(case["event"], "event-envelope.schema.json",
                f"event-envelope.phone.invalidCases[{index}]")

    check(load("tool-catalog.json")["valid"], "tool-catalog.schema.json", "tool-catalog")
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
    check_many(load("approval-patterns.json")["valid"], "approval-patterns.schema.json", "approval-patterns")
    check_many(load("approval-patterns.json")["invalid"], "approval-patterns.schema.json", "approval-patterns.invalid")
    # Memory, wake-marker and proactive vectors moved to spec/bot/v2 at the
    # ownership handover. Run that validator from here so the existing
    # `phone-spec` stage keeps covering both trees.
    reference_valid, reference_invalid, _ = validate_record_reference_fixture(
        load(RECORD_REFERENCE_VECTOR))
    envelope_valid, envelope_invalid, envelope_decode_errors, _ = validate_observation_envelope_fixture(
        load(OBSERVATION_ENVELOPE_VECTOR))
    query_valid, query_invalid, _ = validate_record_query_fixture(load(RECORD_QUERY_VECTOR))
    record_mutations = mutation_count_for_record_contracts(
        load(RECORD_REFERENCE_VECTOR), load(OBSERVATION_ENVELOPE_VECTOR), load(RECORD_QUERY_VECTOR))
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
    print("bot vectors: PASS (schemas, positive vectors, negative vectors; "
          f"turn-origin {valid_origins} valid / {invalid_origins} invalid, "
          f"{mutations} mutation checks; "
          f"mcp-egress {valid_egress} valid / {invalid_egress} invalid, "
          f"{egress_mutations} mutation checks; "
          f"record-reference {reference_valid} valid / {reference_invalid} invalid, "
          f"observation-envelope {envelope_valid} valid / {envelope_invalid} invalid / "
          f"{envelope_decode_errors} decode errors, "
          f"record-query {query_valid} valid / {query_invalid} invalid, "
          f"{record_mutations} mutation checks)")
    return 0


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
