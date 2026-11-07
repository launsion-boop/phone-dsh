# SPDX-License-Identifier: MIT
"""Validate executable fixture shapes without treating them as runtime proof."""
import json
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


class LegacyIdentityPreferenceFixtureSchemaTest(unittest.TestCase):
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
