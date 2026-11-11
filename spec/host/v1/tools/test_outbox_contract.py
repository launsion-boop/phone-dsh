#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Negative cases for the host send outbox (P06/W1).

The schema is judged by the repository validator; the state machine and the attachment-reference
laws are judged here because a JSON schema cannot express transitions or cross-field references.
All use the same fixture so a schema relaxation and a law relaxation cannot land in different
files.
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


def attachment_problem(case):
    """Return the first attachment-reference law the case violates, or None."""
    attachments = case.get("attachments")
    if not isinstance(attachments, list):
        return None
    ids = [item.get("id") for item in attachments]
    if len(ids) != len(set(ids)):
        return "duplicate_attachment_id"
    prefix = "attachments/{}/".format(case.get("rpcId", ""))
    for item in attachments:
        if not str(item.get("storePath", "")).startswith(prefix):
            return "attachment_store_path_mismatch"
    if case.get("storeMissing") is True:
        return "attachment_store_missing"
    if case.get("digestMatches") is False:
        return "attachment_digest_mismatch"
    return None


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
            if case["schema"] or case.get("law") == "attachment":
                continue
            checked += 1
            pair = (case["case"]["from"], case["case"]["to"])
            self.assertNotIn(pair, ALLOWED, case["id"])
        self.assertGreater(checked, 0)

    def test_every_attachment_law_case_is_rejected(self) -> None:
        checked = 0
        for case in self.cases:
            if case.get("law") != "attachment":
                continue
            checked += 1
            self.assertEqual(attachment_problem(case["case"]), case["reason"], case["id"])
        self.assertGreater(checked, 0)

    def test_fixture_has_all_kinds(self) -> None:
        schema_cases = [case for case in self.cases if case["schema"]]
        transition_cases = [case for case in self.cases
                            if not case["schema"] and case.get("law") != "attachment"]
        attachment_cases = [case for case in self.cases if case.get("law") == "attachment"]
        self.assertTrue(schema_cases)
        self.assertTrue(transition_cases)
        self.assertTrue(attachment_cases)

    def test_positive_goldens_validate(self) -> None:
        for name in ("outbox-entry-queued.json",
                     "outbox-entry-outcome-unknown.json",
                     "outbox-entry-attachment.json",
                     "outbox-entry-attachments-multiple.json",
                     "outbox-entry-attachment-only.json",
                     "outbox-entry-attachments-20.json"):
            wrapper = load_json(CONTRACT / "golden" / name)
            validate_json(wrapper["instance"], self.schema, name)


if __name__ == "__main__":
    unittest.main()
