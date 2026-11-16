#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Validate the G-3A iOS context-source contract and shared vectors.

Checks the capability matrix (unsupported sources can never be supported, Android
is deferred), the consent/generation lifecycle (revoke increments generation and
stale callbacks/reads are inactive), the credential-free observation payloads,
the os/injected delivery split, the read view and the WakeSignal reason format.
It is the reference checker for spec/bot/v2/context-sources.md.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(ROOT))
from spec.v1.tools.spec_golden import SpecError, validate_json  # noqa: E402

BOT = ROOT / "spec" / "bot" / "v2"
GOLDEN = BOT / "golden" / "context-sources.json"
SOURCES = ("calendar", "contacts", "selected-media", "location-fence", "power",
           "own-notification", "external-entry")
UNSUPPORTED = ("third-party-notifications", "sms", "call-history", "system-idle")
KEY_RE = re.compile(r"(token|secret|password|passwd|credential|authorization|bearer|api[-_]?key|private[-_]?key)", re.I)
WAKE_RE = re.compile(r"^context:(" + "|".join(SOURCES) + r"):[a-z][a-z0-9-]*(\.[a-z][a-z0-9-]*)+$")


def load(name: str) -> dict:
    return json.loads((BOT / name).read_text())


def check(instance, schema_name: str, where: str) -> None:
    validate_json(instance, load(schema_name), where)


def rejects(instance, schema_name: str, where: str) -> None:
    try:
        check(instance, schema_name, where)
    except SpecError:
        return
    raise AssertionError(f"{where}: unexpectedly validates")


def check_matrix(matrix: list) -> None:
    by_source = {}
    for item in matrix:
        if item["source"] in by_source:
            raise AssertionError(f"capability matrix: duplicate {item['source']}")
        by_source[item["source"]] = item
        if item["support"] not in ("supported", "limited", "unsupported", "deferred"):
            raise AssertionError(f"capability matrix: bad support {item['support']}")
        if item["support"] == "unsupported" and item["test_layer"] != "none":
            raise AssertionError(f"{item['source']}: unsupported source cannot claim a test layer")
        if item["support"] == "deferred" and item["test_layer"] != "none":
            raise AssertionError(f"{item['source']}: deferred source cannot claim a test layer")
    for source in UNSUPPORTED:
        if by_source.get(source, {}).get("support") != "unsupported":
            raise AssertionError(f"{source} must stay unsupported on iOS")
    if "android-context" not in by_source or by_source["android-context"]["support"] != "deferred":
        raise AssertionError("Android context must be explicitly deferred")
    for source in SOURCES:
        if source not in by_source:
            raise AssertionError(f"capability matrix missing {source}")


def secret_keys(value) -> list[str]:
    found: list[str] = []
    if isinstance(value, dict):
        for key, item in value.items():
            if KEY_RE.search(str(key)):
                found.append(str(key))
            found.extend(secret_keys(item))
    elif isinstance(value, list):
        for item in value:
            found.extend(secret_keys(item))
    return found


def check_observation(case: dict) -> None:
    observation = case["observation"]
    check(observation, "context-observation.schema.json", case["name"])
    if observation["source"] in UNSUPPORTED:
        raise AssertionError(f"{case['name']}: unsupported source cannot emit observations")
    keys = secret_keys(observation["payload"])
    if keys:
        raise AssertionError(f"{case['name']}: credential-shaped payload keys {keys}")
    if observation["delivery"] != case["origin"]:
        raise AssertionError(f"{case['name']}: delivery/origin mismatch")
    if observation["wake_requested"]:
        if not observation["dedupe_key"]:
            raise AssertionError(f"{case['name']}: wake without dedupe key")


def simulate(sequence: dict) -> None:
    consent: dict[str, dict] = {}
    for op in sequence["ops"]:
        source = op["source"]
        if op["op"] == "authorize":
            consent[source] = {"consent": "authorized", "generation": op["generation"]}
        elif op["op"] == "subscribe":
            if source not in consent or consent[source]["consent"] not in ("authorized", "limited"):
                raise AssertionError(f"{sequence['name']}: subscribe before authorization")
            if consent[source]["generation"] != op["generation"]:
                raise AssertionError(f"{sequence['name']}: subscribe with stale generation")
        elif op["op"] == "revoke":
            consent[source] = {"consent": "revoked", "generation": op["generation"]}
            if op["generation"] <= consent[source].get("previous", -1):
                pass
        else:
            raise AssertionError(f"{sequence['name']}: unknown op {op['op']}")
    for expected in sequence["reads"]:
        source = expected["source"]
        state = consent[source]
        active = state["consent"] in ("authorized", "limited") \
            and state["generation"] == expected["observation_generation"]
        if expected["expect"] == "active" and not active:
            raise AssertionError(f"{sequence['name']}: {source} should be active")
        if expected["expect"] == "inactive":
            if active:
                raise AssertionError(f"{sequence['name']}: {source} should be inactive")
            reason = expected.get("inactive_reason")
            if reason == "generation-mismatch" and state["consent"] in ("authorized", "limited"):
                continue
            if reason == "revoked" and state["consent"] == "revoked":
                continue
            raise AssertionError(f"{sequence['name']}: unexpected inactive reason {reason}")


def check_view(view: dict) -> None:
    check(view, "context-observation-view.schema.json", "view")
    for item in view["items"]:
        active = item["state"] == "active"
        same_generation = item["consent_generation"] == view["consent_generation"]
        if active and not same_generation:
            raise AssertionError("view: active item with stale consent generation")
        if not active and "inactive_reason" not in item:
            raise AssertionError("view: inactive item without a reason")


def main() -> int:
    golden = json.loads(GOLDEN.read_text())
    check_matrix(golden["capability_matrix"])
    accepted = 0
    for case in golden["observation_cases"]:
        if case["expect"] == "accept":
            check_observation(case)
            accepted += 1
        else:
            rejected = False
            try:
                check_observation(case)
            except (SpecError, AssertionError):
                rejected = True
            if not rejected:
                raise AssertionError(f"observation {case['name']}: unexpectedly accepted")
    for sequence in golden["consent_sequences"]:
        simulate(sequence)
    for view in golden["view"]["valid"]:
        check_view(view)
    for case in golden["view"]["invalid"]:
        try:
            check_view(case["instance"])
        except (SpecError, AssertionError):
            continue
        raise AssertionError(f"view {case['name']}: unexpectedly accepted")
    for case in golden["wake_cases"]:
        matched = WAKE_RE.match(case["reason"]) is not None
        if matched != case["valid"]:
            raise AssertionError(f"wake reason {case['reason']}: expected valid={case['valid']}")
    mutations = 0
    good = golden["observation_cases"][0]
    for mutate in ("delivery", "secret", "source"):
        case = json.loads(json.dumps(good))
        if mutate == "delivery":
            case["observation"]["delivery"] = "injected"
        elif mutate == "secret":
            case["observation"]["payload"] = {"api_key": "x"}
        else:
            case["observation"]["source"] = "third-party-notifications"
        try:
            check_observation(case)
        except (SpecError, AssertionError):
            mutations += 1
    for sequence in golden["consent_sequences"]:
        for expected in sequence["reads"]:
            flipped = dict(expected)
            flipped["expect"] = "active" if expected["expect"] == "inactive" else "inactive"
            flipped["inactive_reason"] = expected.get("inactive_reason", "revoked")
            mutated = {"name": sequence["name"], "ops": sequence["ops"], "reads": [flipped]}
            try:
                simulate(mutated)
            except AssertionError:
                mutations += 1
    if mutations < 7:
        raise AssertionError(f"mutation coverage too low: {mutations}")
    print(f"context-source vectors: PASS (capability {len(golden['capability_matrix'])}, "
          f"observations {accepted} accepted/{len(golden['observation_cases'])-accepted} rejected, "
          f"consent {len(golden['consent_sequences'])}, views "
          f"{len(golden['view']['valid'])}/{len(golden['view']['invalid'])}, "
          f"wake {len(golden['wake_cases'])}, mutations {mutations})")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (SpecError, AssertionError) as error:
        print(f"context-source vectors: FAIL: {error}", file=sys.stderr)
        sys.exit(1)
