# SPDX-License-Identifier: MIT
"""Validate executable fixture shapes without treating them as runtime proof."""
import json
from pathlib import Path
import unittest

from jsonschema import Draft202012Validator


ROOT = Path(__file__).resolve().parents[1] / "device" / "v1"
SCHEMA = json.loads((ROOT / "schema/legacy-identity-preferences.schema.json").read_text())


class LegacyIdentityPreferenceFixtureSchemaTest(unittest.TestCase):
    def test_shared_cases_are_executable_property_lists(self):
        validator = Draft202012Validator(SCHEMA)
        lines = (ROOT / "golden/legacy-identity-preferences.jsonl").read_text().splitlines()
        rows = [json.loads(line) for line in lines if line]
        self.assertEqual(len({row["id"] for row in rows}), len(rows))
        for row in rows:
            with self.subTest(row=row["id"]):
                self.assertFalse(list(validator.iter_errors(row)))

    def test_inconsistent_presence_and_null_values_are_rejected(self):
        validator = Draft202012Validator(SCHEMA)
        base = {"id": "x", "present": False, "incoming": "a", "accepted": False, "expected": []}
        for mutation in (
            {**base, "present": True},
            {**base, "initial": []},
            {**base, "present": True, "initial": None},
            {**base, "expected": [None]},
        ):
            with self.subTest(row=mutation):
                self.assertTrue(list(validator.iter_errors(mutation)))


if __name__ == "__main__":
    unittest.main()
