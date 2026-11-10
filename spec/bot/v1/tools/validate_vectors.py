#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Validate Bot v1 schemas and the exported positive/negative conformance vectors."""
from __future__ import annotations

import json
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
PHONE_ONLY_VECTORS = frozenset({TURN_ORIGIN_VECTOR, MCP_EGRESS_VECTOR})

# P26/P27 turn-origin contract. Prefix matching is exact, ASCII
# case-sensitive and anchored at offset 0; the payload must contain at least
# one non-whitespace character. Unknown input is never hidden and never gets
# more trust than `agent-message`.
TURN_ORIGIN_PREFIXES = (
    ("user-action:", ("user", False, False, "user-turn")),
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
    "show_checklist", "show_link", "UpdateMemory", "RecallMemory", "Task", "AwaitTask",
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
    expect_failure("routine-memory-source",
                   lambda value: value["valid"][routine_index].update(memorySource="agent-message"))
    expect_failure("routine-hidden",
                   lambda value: value["valid"][routine_index].update(hidden=False))
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
    check(load("memory-policy.json")["valid"], "memory-policy.schema.json", "memory-policy")
    check_many(load("memory-policy.json")["invalid"], "memory-policy.schema.json", "memory-policy.invalid")
    check_many(load("memory-fact.json")["valid"], "memory-fact.schema.json", "memory-fact")
    check(load("memory-injection.json")["valid"], "memory-injection.schema.json", "memory-injection")
    check_many(load("memory-recall.json")["valid"], "memory-recall.schema.json", "memory-recall")
    check_many(load("memory-recall.json")["invalid"], "memory-recall.schema.json", "memory-recall.invalid")
    check(load("wake-routine.json")["valid"], "wake-routine.schema.json", "wake-routine")
    check(load("wake-routine.json")["valid"]["quietDefer"], "routine.schema.json", "routine")
    held_fixture = load_merged("held-inbox.json")
    held = held_fixture["valid"]
    check(held["enqueued"]["item"], "held-inbox-item.schema.json", "held-item")
    check(held["deviceTaskResult"], "held-inbox-item.schema.json", "held-device-task-result")
    check(held["agentHeld"], "held-inbox-item.schema.json", "held-agent-held")
    check_many(held["staged"]["items"], "held-inbox-item.schema.json", "held-staged")
    for index, case in enumerate(held_fixture["invalid"]):
        rejects(case, "held-inbox-item.schema.json", f"held.invalid[{index}]")
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
          f"{egress_mutations} mutation checks)")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        print(f"bot vectors: FAIL: {exc}", file=sys.stderr)
        sys.exit(1)
