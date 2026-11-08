# SPDX-License-Identifier: MIT
"""Validate executable fixture shapes without treating them as runtime proof."""
import json
import hashlib
from pathlib import Path
import runpy
import unittest

SPEC = Path(__file__).resolve().parents[1]
ROOT = SPEC / "device" / "v1"
VALIDATOR = runpy.run_path(str(SPEC / "v1/tools/spec_golden.py"))
validate_json = VALIDATOR["validate_json"]
SpecError = VALIDATOR["SpecError"]
SCHEMA = json.loads((ROOT / "schema/legacy-identity-preferences.schema.json").read_text())
REENTRANT_SCHEMA = json.loads((ROOT / "schema/legacy-identity-reentrant.schema.json").read_text())
CONFIRMATION_SCHEMA = json.loads((ROOT / "schema/legacy-identity-confirmation.schema.json").read_text())
OBSERVATION_SCHEMA = json.loads((ROOT / "schema/legacy-identity-observation.schema.json").read_text())


class LegacyIdentityPreferenceFixtureSchemaTest(unittest.TestCase):
    def test_observation_scenarios_and_mutations(self):
        rows = [json.loads(line) for line in (ROOT / "golden/legacy-identity-observation.jsonl").read_text().splitlines()]
        self.assertEqual(len(rows), 40)
        self.assertEqual(len(rows), len({row["id"] for row in rows}))
        for row in rows:
            validate_json(row, OBSERVATION_SCHEMA, row["id"])
        def digest(values):
            text = "\n".join(json.dumps(row, sort_keys=True, ensure_ascii=False, separators=(",", ":")) for row in values)
            return hashlib.sha256(text.encode()).hexdigest()
        frozen = "e096eb49ca0a81fb7abfd3f3ef6df37cbcae89e18f0b7f8a5cec88bec1c02978"
        self.assertEqual(digest(rows), frozen)
        by = {row["id"]: row for row in rows}
        for name in ("pre-set-disconnect", "pre-set-replace-channel", "pre-set-reinstall-client", "pre-set-pending-aba", "pre-set-pending-nfd"):
            self.assertEqual((by[name]["result"], by[name]["set_calls"]), ("stale", 0), name)
        for name in ("inside-set-disconnect", "after-set-disconnect", "readback-client-replaced"):
            self.assertEqual((by[name]["result"], by[name]["set_calls"], len(by[name]["expected_preference"])), ("stale", 1, 2), name)
        self.assertNotEqual(by["pre-set-pending-nfd"]["a_pending"], by["pre-set-pending-nfd"]["pending"])
        self.assertEqual(by["nested-storage-confirm"]["b_pending"], "ble:device-b")
        self.assertEqual((by["nested-storage-confirm"]["b_error"], by["nested-storage-confirm"]["read_calls"]), ("", 2))
        self.assertEqual((by["nested-storage-explicit-retry"]["set_calls"], by["nested-storage-explicit-retry"]["b_recorded"]), (2, "ble:device-b"))
        for row in rows:
            self.assertFalse(row["task_grant"], row["id"])
            if row["id"] != "pre-set-radio-off":
                self.assertEqual(row["status_before"], row["status_after"], row["id"])
                self.assertEqual(row["status_notifications"], 0, row["id"])
            else:
                self.assertEqual(row["status_notifications"], 1)
            if row["action"] == "pending-aba":
                self.assertEqual((row["lifecycle_actions"], row["lifecycle_transitions"]), (1, 2), row["id"])
            if row["proof_result"]:
                self.assertRegex(row["proof_result"], r"^ble:[0-9a-f]{64}$")
        for name in ("proof-stale-disconnect", "proof-stale-client-aba", "proof-stale-channel", "proof-stale-pending-aba"):
            self.assertEqual((by[name]["result"], by[name]["set_calls"]), ("stale", 0), name)
        altered = [{**r} for r in rows]
        altered[0]["set_calls"] = 0
        self.assertNotEqual(digest(altered), frozen)
        for mutation in ({**rows[0], "hook": "invented"}, {**rows[0], "task_grant": True}, {**rows[0], "extra": 1}):
            with self.assertRaises(SpecError):
                validate_json(mutation, OBSERVATION_SCHEMA, "mutation")

    def test_shared_cases_are_executable_property_lists(self):
        lines = (ROOT / "golden/legacy-identity-preferences.jsonl").read_text().splitlines()
        rows = [json.loads(line) for line in lines if line]
        self.assertEqual(len({row["id"] for row in rows}), len(rows))
        for row in rows:
            with self.subTest(row=row["id"]):
                validate_json(row, SCHEMA, row["id"])
        lines = (ROOT / "golden/legacy-identity-reentrant.jsonl").read_text().splitlines()
        for row in (json.loads(line) for line in lines if line):
            with self.subTest(row=row["id"]):
                validate_json(row, REENTRANT_SCHEMA, row["id"])
        lines = (ROOT / "golden/legacy-identity-confirmation.jsonl").read_text().splitlines()
        for row in (json.loads(line) for line in lines if line):
            with self.subTest(row=row["id"]):
                validate_json(row, CONFIRMATION_SCHEMA, row["id"])
                self.assertEqual("write_result" not in row, row["interruption"] == "stale-proof")

    def test_inconsistent_presence_and_null_values_are_rejected(self):
        base = {"id": "x", "present": False, "incoming": "a", "accepted": False, "expected": []}
        for mutation in (
            {**base, "present": True},
            {**base, "initial": []},
            {**base, "present": True, "initial": None},
            {**base, "expected": [None]},
        ):
            with self.subTest(row=mutation):
                with self.assertRaises(SpecError):
                    validate_json(mutation, SCHEMA, "invalid")
        with self.assertRaises(SpecError):
            validate_json({"id": "x", "write_result": True, "interruption": "unknown",
                           "update_current": True, "report_failure": False}, CONFIRMATION_SCHEMA, "invalid")


if __name__ == "__main__":
    unittest.main()
