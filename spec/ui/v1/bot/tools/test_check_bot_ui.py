# SPDX-License-Identifier: MIT
"""Mutation/rule tests for check_bot_ui.py."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

TOOLS = Path(__file__).resolve().parent
ROOT = TOOLS.parents[4]
sys.path.insert(0, str(TOOLS))

import check_bot_ui as checker  # noqa: E402


class BotUICheckerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        checker.configure(ROOT)

    def test_repository_check_passes(self):
        self.assertEqual(checker.main(["--root", str(ROOT)]), 0)

    def test_bad_string_anchor_is_rejected(self):
        with self.assertRaises(checker.CheckError):
            checker.check_anchor("BotChatModel.swift", 446, "not on that line", "test")
        # The real anchor still resolves.
        checker.check_anchor("BotChatModel.swift", 446, "已关闭", "test")

    def test_bad_source_expression_is_rejected(self):
        with self.assertRaises(checker.CheckError):
            checker.check_source_expression("BotChatModel.swift:999999", "test")
        checker.check_source_expression("BotChatModel.swift:425-459", "test")

    def test_row_schema_rejects_missing_provenance(self):
        row = {
            "id": "r", "botID": "main", "seq": 1, "updatedSeq": 1, "kind": "message",
            "body": {"type": "text", "text": "x"}, "streaming": False,
            "createdAt": 1760000000000,
        }
        with self.assertRaises(checker.CheckError):
            checker.validate(row, checker._schema("row"), "test")
        row["provenance"] = {"eventIDs": [], "trust": "model", "tainted": False}
        checker.validate(row, checker._schema("row"), "test")

    def test_unknown_card_type_is_not_coerced(self):
        self.assertIsNone(checker.card_parse({"body": {"type": "widget", "cardType": "unknown"}}))
        self.assertIsNone(checker.card_parse({"body": {"type": "widget", "cardType": "table"}}))

    def test_name_cap_counts_utf16_units(self):
        self.assertIsNone(checker.name_problem("a" * 60)[0])
        self.assertIsNotNone(checker.name_problem("a" * 61)[0])
        self.assertIsNotNone(checker.name_problem("   ")[0])
        # 58 ASCII + one non-BMP emoji (2 UTF-16 units) = 60, kept whole.
        self.assertEqual(checker.name_capped("a" * 58 + "😀"), "a" * 58 + "😀")
        # 59 ASCII + emoji would exceed 60, so the emoji is dropped, not split.
        self.assertEqual(checker.name_capped("a" * 59 + "😀"), "a" * 59)

    def test_deep_link_grammar(self):
        self.assertEqual(checker.parse_deep_link("phonedsh://bot/main/row/r1"),
                         {"botID": "main", "destination": {"kind": "row", "id": "r1"}})
        self.assertEqual(checker.parse_deep_link("phonedsh://bot/main/routine/rt-1")["destination"]["kind"],
                         "routine")
        for bad in ("https://bot/main/row/r1", "phonedsh://chat/main/row/r1",
                    "phonedsh://bot/main/row", "phonedsh://bot/main/row/r1/x",
                    "phonedsh://bot/main/message/r1", "phonedsh://bot/main/row/"):
            self.assertIsNone(checker.parse_deep_link(bad), bad)

    def test_activity_text_policy(self):
        self.assertEqual(checker.tool_activity("mcp__phone__ReadMemory", {"path": "user/a.md"}),
                         {"category": "memory", "text": "在翻记忆 · a.md"})
        self.assertEqual(checker.tool_activity("mystery", {}), {"category": "generic", "text": ""})
        self.assertEqual(checker.cleaned_model_text("运行构建。"), "运行构建")
        self.assertEqual(checker.cleaned_model_text("一" * 21), "一" * 19 + "…")
        self.assertEqual(checker.short_target("a" * 43), "a" * 39 + "…")

    def test_settlement_beats_attention(self):
        question = {"id": "q", "role": None, "body": {"type": "widget", "cardType": "question",
                    "question": "选一个", "options": ["a", "b"]}}
        user = {"id": "u", "kind": "sendMessage", "role": "user", "body": {"type": "text", "text": "继续"}}
        state = {"rows": [question, user], "actionStates": {}, "dismissedCardIDs": [],
                 "autoDeclinedApprovalIDs": [], "answeredOptionIDs": {}, "checklistProgress": {}}
        self.assertEqual(checker.muted_ids(state, checker.visible_rows(state)), ["q"])

    def test_fixture_cases_are_accounted_for(self):
        cases = checker._fixture_cases()
        self.assertIn("question", cases)
        self.assertIn("infoPresence", cases)
        doc = checker.load_json(ROOT / checker.BOT_REL / "golden" / "fixtures.json")
        seen = {entry["scenario"] for entry in doc["exported"]} | {
            entry["scenario"] for entry in doc["skipped"]}
        self.assertEqual(seen, set(cases))


if __name__ == "__main__":
    unittest.main()
