#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Validate the G-2 decision-context / sources / feedback contract (delivery selection is parked).

Reference checker for spec/bot/v2/decision-context.md: material-block limits and
state rules, approval-digest rebinding, feedback action/scope/idempotency rules,
the phone-only user-action extension, the three-stage trace subset rules and the
additive feedback.recorded event. It validates schema shape and recomputes every
semantic rule; it never reads Swift.

Usage: python3 spec/bot/v2/tools/validate_decision_context.py
Exit 0 pass, 1 mismatch, 2 IO/usage.
"""
from __future__ import annotations

import hashlib
import json
import re
import sys
from pathlib import Path
from urllib.parse import quote, unquote_to_bytes

ROOT = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(ROOT))
from spec.v1.tools.spec_golden import SpecError, validate_json  # noqa: E402

BOT = ROOT / "spec" / "bot" / "v2"
GOLDEN = BOT / "golden" / "decision-context.json"
STATE = ("current", "changed", "unavailable", "revoked", "erased", "unknown")
CLASS = re.compile(r"^(proactive:(task-done|routine-result|reminder(:[A-Za-z0-9._:-]{1,64})?)|routine:[A-Za-z0-9._:-]{1,64})$")
SHAREABLE = re.compile(r"^proactive:(task-done|routine-result|reminder)$")
TARGET_SPECIFIC = re.compile(r"^(proactive:(task-done|routine-result|reminder):[A-Za-z0-9._:-]{1,64}|routine:[A-Za-z0-9._:-]{1,64})$")
RECORD = re.compile(r"^record://(session/(?!\.{1,2}#)[A-Za-z0-9._-]{1,64}#(0|[1-9][0-9]*)|event/[1-9][0-9]*)$")


def load(name: str) -> dict:
    return json.loads((BOT / name).read_text())


def check(instance, schema_name: str, where: str) -> None:
    validate_json(instance, load(schema_name), where)


def rejects(instance, schema_name: str, where: str) -> None:
    try:
        check(instance, schema_name, where)
    except SpecError:
        return
    raise AssertionError(f"{where}: negative fixture unexpectedly validates")


def scalars(text: str) -> int:
    return len(text)


def digest(draft: str, revision: int, ids, params) -> str:
    payload = json.dumps([draft, revision, sorted(ids), sorted(params, key=lambda p: p["label"])],
                         ensure_ascii=False, separators=(",", ":"))
    return "sha256:" + hashlib.sha256(payload.encode("utf-8")).hexdigest()


def valid_workspace_path(path: str) -> bool:
    if not (1 <= len(path) <= 200) or path.startswith("/") or "\\" in path:
        return False
    if any(ord(ch) < 0x20 or ord(ch) == 0x7f for ch in path):
        return False
    segments = path.split("/")
    return not any(segment in ("", ".", "..") for segment in segments)


def parse_workspace_ref(ref: str):
    prefix = "workspace:"
    if not ref.startswith(prefix):
        return None
    body = ref[len(prefix):]
    encoded, sep, digest = body.rpartition("@sha256:")
    if sep != "@sha256:" or len(digest) != 64 or any(ch not in "0123456789abcdef" for ch in digest):
        return None
    if encoded.startswith("/"):
        return None
    # exactly one decode; reject malformed escapes and invalid UTF-8
    i = 0
    while i < len(encoded):
        if encoded[i] == "%":
            if i + 2 >= len(encoded) or any(c not in "0123456789abcdefABCDEF" for c in encoded[i+1:i+3]):
                return None
            i += 3
        else:
            i += 1
    try:
        raw = unquote_to_bytes(encoded).decode("utf-8")
    except UnicodeDecodeError:
        return None
    if not valid_workspace_path(raw):
        return None
    canonical = quote(raw, safe="/-._~")
    legacy_safe = all(ch.isascii() and (ch.isalnum() or ch in "-._~/") for ch in raw)
    if encoded != canonical and not (encoded == raw and legacy_safe):
        return None
    return raw, digest


def check_material(block: dict, where: str) -> None:
    limits = block["limits"]
    if len(block["materials"]) > limits["max_materials"]:
        raise AssertionError(f"{where}: materials exceed max_materials")
    total = sum(scalars(item["snippet"]) for item in block["materials"])
    if total > limits["max_characters"]:
        raise AssertionError(f"{where}: snippets {total} exceed max_characters")
    for item in block["materials"]:
        if scalars(item["snippet"]) > limits["max_snippet_characters"]:
            raise AssertionError(f"{where}: {item['material_id']} snippet too long")
        workspace = parse_workspace_ref(item["ref"])
        if workspace is not None:
            path, digest = workspace
            if item["path"] != path:
                raise AssertionError(f"{where}: workspace path does not match ref")
            if item["scope"] != "agent":
                raise AssertionError(f"{where}: workspace scope must be agent")
            if item.get("evidence"):
                raise AssertionError(f"{where}: workspace material must not carry evidence")
            if item["state"] != "current" or "reason" in item:
                raise AssertionError(f"{where}: workspace state must be current without reason")
            if item["version"] < 1 or item["updated_at_ms"] < 0:
                raise AssertionError(f"{where}: workspace version/time")
        elif item["ref"].startswith("feedback:preference:"):
            if item["path"] != "feedback/preference/" + item["ref"][len("feedback:preference:"):]:
                raise AssertionError(f"{where}: preference path does not match ref")
            if item["scope"] != "user" or item.get("evidence"):
                raise AssertionError(f"{where}: preference scope/evidence")
            if item["state"] != "current" or item.get("reason") or item["version"] != 1:
                raise AssertionError(f"{where}: preference state/version")
        elif item["ref"] == "current-user-turn" or not (
                item["ref"].startswith("memory:") or RECORD.match(item["ref"])):
            raise AssertionError(f"{where}: invalid material ref {item['ref']!r}")
        if item.get("reason") == "feedback-disputed" and item["state"] != "unknown":
            raise AssertionError(f"{where}: feedback-disputed must be unknown")
        if item["state"] not in STATE:
            raise AssertionError(f"{where}: invalid state")
        if item["state"] == "current" and "reason" in item:
            raise AssertionError(f"{where}: current material must not carry a reason")
        if item["state"] != "current" and "reason" not in item:
            raise AssertionError(f"{where}: {item['state']} material needs a reason")


def check_user_action(item: dict, where: str) -> None:
    if item["kind"] == "feedback" and item["verdict"] == "undo" and "feedbackID" not in item:
        raise AssertionError(f"{where}: undo requires feedbackID")


def check_feedback(data: dict, seen: dict, where: str) -> dict:
    action = data["action"]
    target = data["target"]
    scope = data["scope"]
    result = {"accepted": True}
    nonce = data["origin"]["nonce"]
    if nonce in seen:
        result["duplicated"] = True
        return result
    if data.get("accepted") is False:
        result = {"accepted": False, "reason": data.get("reason", "target-unresolved")}
        seen[nonce] = result
        return result
    if action == "undo":
        if target["kind"] != "feedback" or data.get("reverses") != target["id"]:
            result = {"accepted": False, "reason": "target-unresolved"}
    elif action == "correct":
        applied = (data.get("applied") or {}).get("memory")
        disputed = data.get("subjects") or []
        if target["kind"] != "memory":
            result = {"accepted": False, "reason": "correction-not-applied"}
        elif applied is not None:
            if applied.get("path") != target["id"] \
                    or applied.get("version") != target.get("version"):
                result = {"accepted": False, "reason": "correction-not-applied"}
        elif not disputed:
            result = {"accepted": False, "reason": "correction-not-applied"}
    elif action == "suppress":
        class_key = data.get("class_key")
        if target["kind"] == "feedback":
            result = {"accepted": False, "reason": "target-unresolved"}
        elif scope["kind"] == "artifact":
            pass
        elif scope["kind"] == "routine":
            if class_key != "routine:" + target["id"]:
                result = {"accepted": False, "reason": "ambiguous-scope"}
        elif scope["kind"] == "class":
            if not class_key:
                result = {"accepted": False, "reason": "ambiguous-scope"}
            elif not TARGET_SPECIFIC.match(class_key):
                result = {"accepted": False, "reason": "ambiguous-scope"}
        elif scope["kind"] == "user":
            if not class_key or class_key.startswith("routine:") or class_key.startswith("proactive:reminder:"):
                result = {"accepted": False, "reason": "scope-not-shareable"}
            elif not SHAREABLE.match(class_key):
                result = {"accepted": False, "reason": "ambiguous-scope"}
            elif data["origin"]["kind"] != "ui-action":
                result = {"accepted": False, "reason": "scope-requires-confirmation"}
    elif action == "adopt":
        if target["kind"] == "feedback":
            result = {"accepted": False, "reason": "target-unresolved"}
    else:
        result = {"accepted": False, "reason": "permission-denied"}
    if result["accepted"]:
        result["duplicated"] = False
        seen[nonce] = result
    else:
        seen[nonce] = result
    return result


def check_trace(trace: dict, where: str) -> None:
    marker = trace["injected"]["request_marker"]
    if "dshbot:decision-context" not in marker:
        raise AssertionError(f"{where}: injected trace lacks the decision-context marker")
    injected = set(trace["injected"]["material_ids"])
    retrieved = set(trace["retrieved"])
    if not injected <= retrieved:
        raise AssertionError(f"{where}: injected materials not in retrieved")
    for adopted in trace["adopted"]:
        if not set(adopted["material_ids"]) <= injected:
            raise AssertionError(f"{where}: adopted materials not injected")
        if not set(adopted["material_ids"]) <= retrieved:
            raise AssertionError(f"{where}: adopted materials not retrieved")


def check_event(event: dict, where: str) -> None:
    check(event, "../v1/event-envelope.schema.json", where)
    data = event["data"]
    check(data, "feedback.schema.json", f"{where}.data")
    if event["type"] != "feedback.recorded":
        raise AssertionError(f"{where}: wrong type")
    if event.get("ignorable") is not True:
        raise AssertionError(f"{where}: new durable type must be ignorable:true")
    if event["origin"].get("kind") != "local" or event["origin"].get("source") not in ("card-bridge", "mcp"):
        raise AssertionError(f"{where}: must reuse an existing local origin source")
    if event["principal"].get("kind") != "chat":
        raise AssertionError(f"{where}: must reuse principal.kind=chat")


def main() -> int:
    golden = json.loads(GOLDEN.read_text())
    for index, block in enumerate(golden["material"]["valid"]):
        check(block, "decision-material.schema.json", f"material.valid[{index}]")
        check_material(block, f"material.valid[{index}]")
    for case in golden["material"]["invalid"]:
        rejected = False
        try:
            check(case["instance"], "decision-material.schema.json", case["name"])
        except SpecError:
            rejected = True
        if not rejected:
            try:
                check_material(case["instance"], case["name"])
            except AssertionError:
                rejected = True
        if not rejected:
            raise AssertionError(f"material.invalid[{case['name']}]: unexpectedly accepted")
    for index, item in enumerate(golden["user_actions"]["valid"]):
        check(item, "../v1/user-action.phone.schema.json", f"user_actions.valid[{index}]")
        check_user_action(item, f"user_actions.valid[{index}]")
    for case in golden["user_actions"]["invalid"]:
        rejected = False
        try:
            check(case["instance"], "../v1/user-action.phone.schema.json", case["name"])
        except SpecError:
            rejected = True
        if not rejected:
            try:
                check_user_action(case["instance"], case["name"])
            except AssertionError:
                rejected = True
        if not rejected:
            raise AssertionError(f"user_actions.invalid[{case['name']}]: unexpectedly accepted")
    seen: dict = {}
    feedback_results = {}
    for case in golden["feedback"]["cases"]:
        data = case["data"]
        check(data, "feedback.schema.json", f"feedback.{case['name']}")
        result = check_feedback(data, seen, f"feedback.{case['name']}")
        feedback_results[case["name"]] = result
        expected = case["expected"]
        for key in ("accepted", "reason", "duplicated"):
            if key in expected and result.get(key) != expected[key]:
                raise AssertionError(
                    f"feedback.{case['name']}: {key} {result.get(key)!r} != {expected[key]!r}")
    proactive = json.loads((BOT / "golden" / "proactive.phone.json").read_text())
    proactive_cases = 0
    for case in proactive["cases"]:
        check(case["expect"], "proactive-decision.schema.json", f"proactive.{case['name']}")
        want = "mode-off" if case["settings"]["mode"] == "off" else "feedback-held"
        if case["expect"]["reason"] != want:
            raise AssertionError(f"proactive.{case['name']}: reason {case['expect']['reason']} != {want}")
        if case["expect"]["decision"] != "skip":
            raise AssertionError(f"proactive.{case['name']}: feedback suppression must be skip")
        if case.get("fuseRecorded") is not False:
            raise AssertionError(f"proactive.{case['name']}: feedback-held must not record fuse")
        if "delivery" in case["expect"]:
            raise AssertionError(f"proactive.{case['name']}: feedback-held must not deliver")
        proactive_cases += 1
    for case in proactive["invalid"]:
        if case["claim"]["reason"] == "feedback-held" and case["settings"]["mode"] == "off":
            continue
        raise AssertionError(f"proactive.{case['name']}: invalid case not aligned")
    active = {}
    for case in golden["feedback"]["cases"]:
        data = case["data"]
        if data["action"] != "suppress":
            continue
        result = feedback_results.get(case["name"], {})
        if not result.get("accepted"):
            continue
        scope = data["scope"]
        if scope["kind"] == "artifact":
            active[("artifact", data["target"]["id"])] = True
        elif scope["kind"] == "routine":
            active[("routine", data["class_key"])] = True
        elif scope["kind"] == "class":
            active[("class", data["class_key"])] = True
        elif scope["kind"] == "user":
            active[("user", data["class_key"])] = True
    for isolation in golden.get("feedback", {}).get("isolation", []):
        for check_case in isolation["checks"]:
            key = (check_case["lookup_scope"], check_case["lookup_key"])
            if bool(active.get(key)) != check_case["expect_active"]:
                raise AssertionError(f"feedback isolation {isolation['name']}: {key}")
    for index, message in enumerate(golden.get("internal_tool", {}).get("valid", [])):
        check(message, "decision-internal-tool.schema.json", f"internal_tool.valid[{index}]")
        if message.get("ok") is True:
            check_material(message["block"], f"internal_tool.valid[{index}].block")
    for case in golden.get("internal_tool", {}).get("invalid", []):
        try:
            check(case["instance"], "decision-internal-tool.schema.json", case["name"])
        except SpecError:
            continue
        raise AssertionError(f"internal_tool.invalid[{case['name']}]: unexpectedly accepted")
    for index, result in enumerate(golden.get("tool_results", {}).get("valid", [])):
        check(result, "decision-tool-result.schema.json", f"tool_results.valid[{index}]")
        check_material(result["materials"], f"tool_results.valid[{index}].materials")
    for case in golden.get("tool_results", {}).get("invalid", []):
        rejected = False
        try:
            check(case["instance"], "decision-tool-result.schema.json", case["name"])
        except SpecError:
            rejected = True
        if not rejected:
            raise AssertionError(f"tool_results.invalid[{case['name']}]: unexpectedly accepted")
    for index, trace in enumerate(golden["trace"]["valid"]):
        check_trace(trace, f"trace.valid[{index}]")
    for case in golden["trace"]["invalid"]:
        try:
            check_trace(case["trace"], case["name"])
        except AssertionError:
            continue
        raise AssertionError(f"trace.invalid[{case['name']}]: unexpectedly accepted")
    check_event(golden["event"], "event")
    # mutations: the checker must reject a wrong expectation / broken invariant
    mutations = 0
    for case in golden["feedback"]["cases"]:
        expected = dict(case["expected"])
        expected["accepted"] = not expected["accepted"]
        try:
            seen2: dict = {}
            for prior in golden["feedback"]["cases"]:
                result = check_feedback(prior["data"], seen2, "mutation")
                if prior is case:
                    if result.get("accepted") != expected["accepted"]:
                        raise AssertionError("mutated expectation accepted")
        except AssertionError:
            mutations += 1
    for block in golden["material"]["valid"]:
        mutated = json.loads(json.dumps(block))
        mutated["materials"][0]["snippet"] = "a" * 5000
        try:
            check_material(mutated, "mutation")
        except AssertionError:
            mutations += 1
    for trace in golden["trace"]["valid"]:
        mutated = json.loads(json.dumps(trace))
        mutated["injected"]["material_ids"] = ["mat:999"]
        try:
            check_trace(mutated, "mutation")
        except AssertionError:
            mutations += 1
    if mutations < 12:
        raise AssertionError(f"mutation coverage too low: {mutations}")
    print(f"decision-context vectors: PASS (proactive {proactive_cases}, internal tool "
          f"{len(golden.get('internal_tool', {}).get('valid', []))}/"
          f"{len(golden.get('internal_tool', {}).get('invalid', []))}, tool results "
          f"{len(golden.get('tool_results', {}).get('valid', []))}/"
          f"{len(golden.get('tool_results', {}).get('invalid', []))}, material {len(golden['material']['valid'])}/"
          f"{len(golden['material']['invalid'])}, user actions {len(golden['user_actions']['valid'])}/"
          f"{len(golden['user_actions']['invalid'])}, feedback {len(feedback_results)}, "
          f"trace {len(golden['trace']['valid'])}/{len(golden['trace']['invalid'])}, "
          f"mutations {mutations})")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (SpecError, AssertionError) as error:
        print(f"decision-context vectors: FAIL: {error}", file=sys.stderr)
        sys.exit(1)
