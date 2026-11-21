# SPDX-License-Identifier: MIT
"""Mutation/rule tests for check_bot_ui.py."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

TOOLS = Path(__file__).resolve().parent
ROOT = TOOLS.parents[4]
CHECK = TOOLS / "check_bot_ui.py"
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
            checker.check_anchor("BotChatModel.swift", 487, "not on that line", "test")
        # The real anchor still resolves.
        checker.check_anchor("BotChatModel.swift", 487, "已关闭", "test")

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

    def test_only_checklists_are_muted(self):
        question = {"id": "q", "role": None, "body": {"type": "widget", "cardType": "question",
                    "question": "选一个", "options": ["a", "b"]}}
        checklist = {"id": "c", "role": None, "body": {"type": "widget", "cardType": "checklist",
                     "title": "检查", "items": ["a", "b"]}}
        user = {"id": "u", "kind": "sendMessage", "role": "user", "body": {"type": "text", "text": "继续"}}
        state = {"rows": [question, checklist, user], "actionStates": {}, "dismissedCardIDs": [],
                 "autoDeclinedApprovalIDs": [], "answeredOptionIDs": {}, "checklistProgress": {}}
        # Question/steps staleness is the durable P27 status, never this heuristic.
        self.assertEqual(checker.muted_ids(state, checker.visible_rows(state)), ["c"])

    def test_superseded_card_settles_even_with_a_pending_tap(self):
        question = {"id": "q", "role": None,
                    "body": {"type": "widget", "cardType": "question", "question": "选一个",
                             "options": ["a", "b"], "status": "superseded",
                             "supersededBy": "q2"}}
        state = {"rows": [question], "actionStates": {"card:q": "pending"},
                 "dismissedCardIDs": [], "autoDeclinedApprovalIDs": [],
                 "answeredOptionIDs": {}, "checklistProgress": {}}
        self.assertEqual(checker.settlement(state, question),
                         checker.settle("minus.circle", "已过期，用最新那张", "选一个"))
        # A pending tap without a durable terminal status keeps the full card.
        question["body"] = {"type": "widget", "cardType": "question",
                            "question": "选一个", "options": ["a", "b"]}
        self.assertIsNone(checker.settlement(state, question))

    def test_fixture_cases_are_accounted_for(self):
        cases = checker._fixture_cases()
        self.assertIn("question", cases)
        self.assertIn("infoPresence", cases)
        doc = checker.load_json(ROOT / checker.BOT_REL / "golden" / "fixtures.json")
        seen = {entry["scenario"] for entry in doc["exported"]} | {
            entry["scenario"] for entry in doc["skipped"]}
        self.assertEqual(seen, set(cases))


class BotUICheckerMutationTests(unittest.TestCase):
    """A throw-away root proves the checker rejects a mutated projection or
    retry expectation instead of trusting the golden."""

    def setUp(self) -> None:
        self.temp = Path(tempfile.mkdtemp(prefix="bot-ui-check-test-"))
        target = self.temp / checker.BOT_REL
        target.parent.mkdir(parents=True)
        shutil.copytree(ROOT / checker.BOT_REL, target)
        for name in ("spec/v1", "spec/bot", "examples", "Sources"):
            os.symlink(ROOT / name, self.temp / name)

    def tearDown(self) -> None:
        shutil.rmtree(self.temp, ignore_errors=True)

    def run_check(self) -> subprocess.CompletedProcess:
        return subprocess.run(
            [sys.executable, str(CHECK), "--root", str(self.temp)],
            capture_output=True, text=True, timeout=180)

    def load_vectors(self) -> dict:
        path = self.temp / checker.BOT_REL / "golden" / "ui-state-vectors.json"
        return json.loads(path.read_text(encoding="utf-8"))

    def save_vectors(self, value: dict) -> None:
        path = self.temp / checker.BOT_REL / "golden" / "ui-state-vectors.json"
        path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n",
                        encoding="utf-8")

    def assert_fails(self, *needles: str) -> None:
        result = self.run_check()
        self.assertNotEqual(result.returncode, 0,
                            f"checker unexpectedly passed:\n{result.stdout}")
        for needle in needles:
            self.assertIn(needle, result.stderr,
                          f"missing diagnostic {needle!r}:\n{result.stderr}")

    def test_fresh_copy_passes(self) -> None:
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_projection_expectation_mutation_fails(self) -> None:
        doc = self.load_vectors()
        case = next(c for c in doc["cases"] if c["id"] == "priority-oneshot-unexpired")
        case["expected"]["fishState"] = "idle"
        self.save_vectors(doc)
        self.assert_fails("fishState")

    def test_priority_coverage_mutation_fails(self) -> None:
        doc = self.load_vectors()
        for case in doc["cases"]:
            case["covers"] = [c for c in case.get("covers", [])
                              if c != "priority.one-shot"]
        self.save_vectors(doc)
        self.assert_fails("projection priority coverage", "priority.one-shot")

    def test_dismiss_retry_mutation_fails(self) -> None:
        doc = self.load_vectors()
        case = next(c for c in doc["intentCases"] if c["id"] == "dismiss-failed-retry")
        case["accepted"] = False
        self.save_vectors(doc)
        self.assert_fails("must be accepted")

    def test_retry_policy_mutation_fails(self) -> None:
        doc = self.load_vectors()
        case = next(c for c in doc["intentCases"] if c["id"] == "dismiss-pending-ignored")
        case["accepted"] = True
        self.save_vectors(doc)
        self.assert_fails("must be rejected")


if __name__ == "__main__":
    unittest.main()
