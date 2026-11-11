#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Negative cases for the host send outbox (P06/W1).

The schema is judged by the repository validator; the state machine is judged here because a
JSON schema cannot express transitions. Both use the same fixture so a schema relaxation and a
transition relaxation cannot land in different files.
"""
from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path

TOOLS = Path(__file__).resolve().parent
V1_TOOLS = TOOLS.parents[2] / "v1" / "tools"
sys.path.insert(0, str(V1_TOOLS))

from spec_golden import SpecError, load_json, validate_json  # noqa: E402

CONTRACT = TOOLS.parent
SCHEMA = CONTRACT / "schema" / "outbox-entry.schema.json"
CASES = TOOLS / "outbox_invalid_cases.json"

ALLOWED = {
    ("queued", "submitting"),
    ("submitting", "accepted"),
    ("submitting", "outcomeUnknown"),
    ("accepted", "durable"),
    ("outcomeUnknown", "accepted"),
    ("outcomeUnknown", "queued"),  # only after a read-back proves the message absent
}


class OutboxContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.schema = json.loads(SCHEMA.read_text(encoding="utf-8"))
        self.cases = json.loads(CASES.read_text(encoding="utf-8"))["invalid"]

    def test_every_schema_invalid_case_is_rejected(self) -> None:
        checked = 0
        for case in self.cases:
            if not case["schema"]:
                continue
            checked += 1
            with self.assertRaises(SpecError, msg=case["id"]):
                validate_json(case["case"], self.schema, case["id"])
        self.assertGreater(checked, 0)

    def test_every_illegal_transition_is_rejected(self) -> None:
        checked = 0
        for case in self.cases:
            if case["schema"]:
                continue
            checked += 1
            pair = (case["case"]["from"], case["case"]["to"])
            self.assertNotIn(pair, ALLOWED, case["id"])
        self.assertGreater(checked, 0)

    def test_fixture_has_both_kinds(self) -> None:
        schema_cases = [case for case in self.cases if case["schema"]]
        transition_cases = [case for case in self.cases if not case["schema"]]
        self.assertTrue(schema_cases)
        self.assertTrue(transition_cases)

    def test_positive_goldens_validate(self) -> None:
        for name in ("outbox-entry-queued.json", "outbox-entry-outcome-unknown.json"):
            wrapper = load_json(CONTRACT / "golden" / name)
            validate_json(wrapper["instance"], self.schema, name)


if __name__ == "__main__":
    unittest.main()
