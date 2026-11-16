#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Validate the G-4 skill-change lineage contract and shared vectors.

Checks skill-change shape, monotonic revisions, content/previous hash rules,
derivation artifact matching, source/owner identity and the read-state cases:
no event -> unknown + no-skill-write-event, delete -> unavailable +
skill-deleted, no recheck -> unknown + refresh-not-performed, matching recheck
-> current, changed bytes -> changed. A skill identity is
(source, owner_bot_id?, name); legacy missing source is host. Project roots are
per-Bot and never merge by name. See spec/bot/v2/provenance.md §3.4.
"""
from __future__ import annotations
import json, sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(ROOT))
from spec.v1.tools.spec_golden import SpecError, validate_json

BOT = ROOT / "spec" / "bot" / "v2"
GOLDEN = BOT / "golden" / "skill-lineage.json"


def load(name): return json.loads((BOT / name).read_text())


def check(instance, name, where): validate_json(instance, load(name), where)


def rejects(instance, name, where):
    try: check(instance, name, where)
    except SpecError: return
    raise AssertionError(f"{where}: unexpectedly validates")


def validate_event(data):
    check(data, "skill-change.schema.json", "skill.change")
    skill = data["skill"]
    source = skill.get("source", "user-dsh")
    owner = skill.get("owner_bot_id")
    if source in ("project-dsh", "project-agents"):
        if not owner:
            raise AssertionError("project skill needs owner_bot_id")
        author_bot = (data.get("author") or {}).get("bot_id")
        if author_bot is not None and owner != author_bot:
            raise AssertionError("project skill owner must match author bot")
    elif owner is not None:
        raise AssertionError("global skill must not carry owner_bot_id")
    if "derivation" in data:
        check(data["derivation"], "derivation.schema.json", "skill.derivation")
        artifact = data["derivation"]["artifact"]
        if artifact["kind"] != "skill" or artifact["id"] != data["skill"]["name"] \
                or artifact.get("version") != data["skill"]["revision"]:
            raise AssertionError("derivation artifact does not match the skill change")
    return data


def validate_sequence(events):
    last = None
    for event in events:
        validate_event(event)
        skill = event["skill"]
        if event["action"] == "write":
            if skill.get("previous_sha256") is not None and last is not None \
                    and skill["previous_sha256"] != last:
                raise AssertionError("write previous_sha256 does not match")
            last = skill["content_sha256"]
        else:
            if last is None or skill["previous_sha256"] != last:
                raise AssertionError("delete previous_sha256 does not match")
            last = None
        if event["action"] == "delete" and "content_sha256" in skill:
            raise AssertionError("delete must not carry content_sha256")
    revisions = [event["skill"]["revision"] for event in events]
    if revisions != list(range(1, len(revisions) + 1)):
        raise AssertionError("revisions must be 1..N")
    return events


WORST = ("erased", "revoked", "changed", "unavailable", "unknown", "current")


def worst(states):
    for item in WORST:
        if item in states:
            return item
    return "current"


def evaluate(case):
    events = case.get("events", [])
    if not events:
        return {"state": "unknown", "reasons": ["no-skill-write-event"]}
    latest = events[-1]
    if latest["action"] == "delete":
        return {"state": "unavailable", "reasons": ["skill-deleted"]}
    content_roles = ("evidence", "basis", "creator")
    sources = latest.get("derivation", {}).get("sources", [])
    source_states = case.get("source_states", {})
    states = []
    reasons = set()
    for source in sources:
        if source.get("role", "basis") not in content_roles:
            continue
        status = source_states.get(source["record"])
        if status is not None:
            states.append(status["state"])
            reasons.update(status.get("reasons", []))
    for upstream in case.get("upstream_states", []):
        states.append(upstream["state"])
        if upstream["state"] != "current":
            reasons.add("upstream-invalidated")
    recheck = case.get("recheck")
    if recheck is None:
        states.append("unknown")
        reasons.add("refresh-not-performed")
    elif recheck != latest["skill"]["content_sha256"]:
        states.append("changed")
        reasons.add("source-changed")
    else:
        states.append("current")
    state = worst(states)
    if state == "current":
        reasons = set()
    return {"state": state, "reasons": sorted(reasons)}


def main():
    golden = json.loads(GOLDEN.read_text())
    for data in golden["valid"]["change"]:
        validate_event(data)
    for data in golden["invalid"]["change"]:
        rejected = False
        try: validate_event(data)
        except (SpecError, AssertionError): rejected = True
        if not rejected: raise AssertionError("invalid change accepted")
    for data in golden["valid"]["derivation"]:
        check(data, "derivation.schema.json", "derivation")
    for case in golden["cases"]:
        validate_sequence(case["events"])
        got = evaluate(case)
        if got != case["expected"]:
            raise AssertionError(f"{case['name']}: {got} != {case['expected']}")
    for case in golden["invalid_cases"]:
        try: validate_sequence(case["events"])
        except (SpecError, AssertionError): continue
        raise AssertionError(f"invalid case {case['name']} accepted")
    mutations = 0
    for case in golden["cases"]:
        mutated = dict(case); mutated["recheck"] = "sha256:" + "f" * 64
        if evaluate(mutated) != case["expected"]:
            mutations += 1
    if mutations < 2:
        raise AssertionError("mutation coverage too low")
    print(f"skill-lineage vectors: PASS (changes {len(golden['valid']['change'])}/"
          f"{len(golden['invalid']['change'])}, cases {len(golden['cases'])}, "
          f"invalid-cases {len(golden['invalid_cases'])}, mutations {mutations})")
    return 0


if __name__ == "__main__":
    try: sys.exit(main())
    except (SpecError, AssertionError) as error:
        print(f"skill-lineage vectors: FAIL: {error}", file=sys.stderr)
        sys.exit(1)
