#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Reference oracle for the external admission journal (P06, external-admission.md).

The schema is judged by the repository validator; identity derivation, the admission decision,
the stage machine, retry, sweep and dispatch order are judged here because a JSON schema cannot
express them. Every end's real implementation must agree with the same fixture.
"""
from __future__ import annotations

import hashlib
import json
import sys
import unittest
from pathlib import Path

TOOLS = Path(__file__).resolve().parent
V1_TOOLS = TOOLS.parents[2] / "v1" / "tools"
sys.path.insert(0, str(V1_TOOLS))

from spec_golden import SpecError, load_json, validate_json  # noqa: E402

CONTRACT = TOOLS.parent
SCHEMA = CONTRACT / "schema" / "admission-record.schema.json"
FIXTURE = CONTRACT / "fixtures" / "external-admission-v1.json"
GOLDENS = ("admission-record-admitted.json", "admission-record-dispatching-retry.json",
           "admission-record-linked.json", "admission-record-completed.json",
           "admission-record-expired-bot.json")

MAX_TEXT_BYTES = 16384
MIN_TTL_MS = 1000
MAX_TTL_MS = 604800000
MAX_PENDING = 256
MAX_ENTRIES = 2048
MAX_ATTEMPTS = 12
TOMBSTONE_MS = 86400000
LINKED_TIMEOUT_MS = 1209600000
PASS_LIMIT = 16
PENDING = ("admitted", "dispatching")
TERMINAL = ("completed", "failed", "expired", "cancelled", "unknown")
STAGES = PENDING + ("linked",) + TERMINAL

ALLOWED = {
    ("admitted", "dispatching"),
    ("dispatching", "linked"),
    ("dispatching", "admitted"),
    ("admitted", "expired"),
    ("admitted", "cancelled"),
    ("admitted", "failed"),
    ("dispatching", "failed"),
    ("linked", "completed"),
    ("linked", "failed"),
    ("linked", "unknown"),
}


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def admission_id(principal: str, source: dict, source_request_id: str) -> str:
    parts = (principal, source["kind"], source["id"], source_request_id)
    return sha256_hex(b"\x00".join(part.encode("utf-8") for part in parts))


def request_text(request: dict) -> str:
    if "textRepeat" in request:
        return request["textRepeat"]["unit"] * request["textRepeat"]["count"]
    return request["text"]


def candidate(request: dict, now: int) -> dict:
    text = request_text(request)
    return {
        "v": 1,
        "admissionId": admission_id(request["principal"], request["source"],
                                    request["sourceRequestId"]),
        "principal": request["principal"],
        "source": request["source"],
        "sourceRequestId": request["sourceRequestId"],
        "target": request["target"],
        "contentSha256": sha256_hex(text.encode("utf-8")),
        "text": text,
        "downstreamId": request["downstreamId"],
        "admittedAtMs": now,
        "expiresAtMs": request["expiresAtMs"],
        "stage": "admitted",
        "attempts": 0,
    }


def decide_admit(case: dict, schema: dict) -> str:
    now = case["now"]
    request = case["request"]
    try:
        record = candidate(request, now)
        validate_json(record, schema, case["id"])
    except (SpecError, KeyError, TypeError, AttributeError):
        return "invalid"
    if len(record["text"].encode("utf-8")) > MAX_TEXT_BYTES:
        return "invalid"
    ttl = record["expiresAtMs"] - now
    if ttl < MIN_TTL_MS or ttl > MAX_TTL_MS:
        return "invalid"
    if case.get("undecodableOwnFile"):
        return "storage"
    for existing in case.get("existing", []):
        if existing["admissionId"] != record["admissionId"]:
            continue
        same = (existing["target"] == record["target"]
                and existing["contentSha256"] == record["contentSha256"])
        return "duplicate" if same else "conflict"
    existing = case.get("existing", [])
    pending = case.get("pendingCount",
                       sum(1 for item in existing if item["stage"] in PENDING))
    entries = case.get("directoryEntries", len(existing))
    if pending >= MAX_PENDING or entries >= MAX_ENTRIES:
        return "capacity"
    return "admitted"


def retry(attempts: int, now: int) -> dict:
    attempts += 1
    if attempts > MAX_ATTEMPTS:
        return {"stage": "failed", "reason": "retry_exhausted"}
    delay = min(3000 * (2 ** (attempts - 1)), 300000)
    return {"stage": "admitted", "attempts": attempts, "nextAttemptAtMs": now + delay}


def sweep(record: dict, now: int) -> str:
    stage = record["stage"]
    if stage == "admitted":
        return "expire" if now >= record["expiresAtMs"] else "keep"
    if stage == "linked":
        return "unknown" if now >= record["admittedAtMs"] + LINKED_TIMEOUT_MS else "keep"
    if stage in TERMINAL:
        limit = max(record["expiresAtMs"], record["settledAtMs"] + TOMBSTONE_MS)
        return "delete" if now >= limit else "keep"
    return "keep"


def dispatch_order(records: list, now: int) -> list:
    ready = [item for item in records
             if item["stage"] in PENDING
             and not (item["stage"] == "admitted" and now >= item["expiresAtMs"])
             and item.get("nextAttemptAtMs", 0) <= now
             and not item.get("waiting", False)]
    ready.sort(key=lambda item: (item["admittedAtMs"], item["admissionId"]))
    return [item["admissionId"] for item in ready[:PASS_LIMIT]]


class ExternalAdmissionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.schema = json.loads(SCHEMA.read_text(encoding="utf-8"))
        self.fixture = json.loads(FIXTURE.read_text(encoding="utf-8"))

    def test_limits_match_the_contract(self) -> None:
        self.assertEqual(self.fixture["limits"], {
            "maxTextBytes": MAX_TEXT_BYTES, "minTtlMs": MIN_TTL_MS, "maxTtlMs": MAX_TTL_MS,
            "maxPending": MAX_PENDING, "maxEntries": MAX_ENTRIES, "maxAttempts": MAX_ATTEMPTS,
            "tombstoneMs": TOMBSTONE_MS, "linkedTimeoutMs": LINKED_TIMEOUT_MS,
            "passLimit": PASS_LIMIT})

    def test_identity_vectors(self) -> None:
        self.assertGreaterEqual(len(self.fixture["ids"]), 4)
        for case in self.fixture["ids"]:
            self.assertEqual(
                admission_id(case["principal"], case["source"], case["sourceRequestId"]),
                case["admissionId"], case)
        for case in self.fixture["content"]:
            self.assertEqual(sha256_hex(case["text"].encode("utf-8")), case["contentSha256"])

    def test_valid_records_and_goldens_validate(self) -> None:
        self.assertTrue(self.fixture["records"]["valid"])
        for case in self.fixture["records"]["valid"]:
            validate_json(case["record"], self.schema, case["id"])
            record = case["record"]
            self.assertEqual(
                admission_id(record["principal"], record["source"], record["sourceRequestId"]),
                record["admissionId"], case["id"])
        for name in GOLDENS:
            wrapper = load_json(CONTRACT / "golden" / name)
            validate_json(wrapper["instance"], self.schema, name)

    def test_invalid_records_are_rejected(self) -> None:
        kinds = set()
        for case in self.fixture["records"]["invalid"]:
            kinds.add(case["by"])
            if case["by"] == "schema":
                with self.assertRaises(SpecError, msg=case["id"]):
                    validate_json(case["record"], self.schema, case["id"])
            elif case["by"] == "identity":
                validate_json(case["record"], self.schema, case["id"])
                record = case["record"]
                self.assertNotEqual(
                    admission_id(record["principal"], record["source"],
                                 record["sourceRequestId"]),
                    record["admissionId"], case["id"])
            else:
                self.fail("unknown invalid kind in " + case["id"])
        self.assertEqual(kinds, {"schema", "identity"})

    def test_admission_decisions(self) -> None:
        seen = set()
        for case in self.fixture["admit"]:
            seen.add(case["result"])
            self.assertEqual(decide_admit(case, self.schema), case["result"], case["id"])
        self.assertEqual(seen, {"admitted", "duplicate", "conflict", "capacity", "invalid",
                                "storage"})

    def test_transition_table_is_total(self) -> None:
        pairs = {(case["from"], case["to"]): case["allowed"]
                 for case in self.fixture["transitions"]}
        self.assertEqual(len(pairs), len(STAGES) * len(STAGES))
        for origin in STAGES:
            for destination in STAGES:
                self.assertEqual(pairs[(origin, destination)],
                                 (origin, destination) in ALLOWED, (origin, destination))

    def test_retry_vectors(self) -> None:
        results = set()
        for case in self.fixture["retry"]:
            outcome = retry(case["attempts"], case["now"])
            results.add(outcome["stage"])
            self.assertEqual(outcome, case["result"], case)
        self.assertEqual(results, {"admitted", "failed"})

    def test_sweep_vectors(self) -> None:
        actions = set()
        for case in self.fixture["sweep"]:
            validate_json(case["record"], self.schema, case["id"])
            actions.add(case["action"])
            self.assertEqual(sweep(case["record"], case["now"]), case["action"], case["id"])
        self.assertEqual(actions, {"keep", "expire", "delete", "unknown"})

    def test_dispatch_order_vectors(self) -> None:
        self.assertTrue(self.fixture["order"])
        for case in self.fixture["order"]:
            self.assertEqual(dispatch_order(case["records"], case["now"]), case["dispatch"],
                             case["id"])


if __name__ == "__main__":
    unittest.main()
