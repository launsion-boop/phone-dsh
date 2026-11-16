#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Deterministic negative/positive fixtures for judge.py.

Run:
  python3 -m unittest Tests/PhoneDSHBotTests/Maintenance/Quality/test_judge.py
"""
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import judge  # noqa: E402


def document(content, state=None, refs=None, basis="record-recheck"):
    review = None
    if state is not None:
        review = {"state": state, "basis": basis,
                  "refs": refs if refs is not None else []}
    return {"content": content, "evidence": [], "review": review}


class FactVerdictTests(unittest.TestCase):
    def test_reversed_correction_is_not_pass(self):
        verdict, _ = judge.fact_verdict(
            document("之前八点起床，现在七点起床。"),
            judge.CONTRADICTION_OLD, judge.CONTRADICTION_NEW)
        self.assertEqual(verdict, "reversed")

    def test_reversed_correction_with_history_after(self):
        verdict, _ = judge.fact_verdict(
            document("现在七点起床，之前八点起床。"),
            judge.CONTRADICTION_OLD, judge.CONTRADICTION_NEW)
        self.assertEqual(verdict, "reversed")

    def test_forward_correction(self):
        verdict, _ = judge.fact_verdict(
            document("之前七点起床，现在八点起床。"),
            judge.CONTRADICTION_OLD, judge.CONTRADICTION_NEW)
        self.assertEqual(verdict, "corrected")

    def test_plain_update(self):
        verdict, _ = judge.fact_verdict(
            document("用户每天早上八点起床。"),
            judge.CONTRADICTION_OLD, judge.CONTRADICTION_NEW)
        self.assertEqual(verdict, "corrected")

    def test_negation_does_not_assert_old(self):
        verdict, _ = judge.fact_verdict(
            document("不是七点起床，是八点起床。"),
            judge.CONTRADICTION_OLD, judge.CONTRADICTION_NEW)
        self.assertEqual(verdict, "corrected")

    def test_negation_after_value(self):
        verdict, _ = judge.fact_verdict(
            document("七点起床不是起床时间，八点起床才是。"),
            judge.CONTRADICTION_OLD, judge.CONTRADICTION_NEW)
        self.assertEqual(verdict, "corrected")

    def test_only_historical_old_value(self):
        verdict, _ = judge.fact_verdict(
            document("现在八点起床。旧值七点起床已作废。"),
            judge.CONTRADICTION_OLD, judge.CONTRADICTION_NEW)
        self.assertEqual(verdict, "corrected")

    def test_unrelated_retirement_marker_does_not_make_old_historical(self):
        # "作废" belongs to the old file, not to the claim; the old claim is
        # still presented as historical by "旧文件", so this is corrected.
        verdict, _ = judge.fact_verdict(
            document("作废的旧文件里写着七点起床。现在是八点起床。"),
            judge.CONTRADICTION_OLD, judge.CONTRADICTION_NEW)
        self.assertEqual(verdict, "corrected")

    def test_two_unmarked_values_are_ambiguous_not_pass(self):
        verdict, _ = judge.fact_verdict(
            document("七点起床。八点起床。"),
            judge.CONTRADICTION_OLD, judge.CONTRADICTION_NEW)
        self.assertEqual(verdict, "ambiguous")

    def test_two_current_values_with_disputed_review_are_preserved(self):
        verdict, _ = judge.fact_verdict(
            document("七点起床。八点起床。", state="disputed",
                     refs=["record://event/1", "record://event/2"]),
            judge.CONTRADICTION_OLD, judge.CONTRADICTION_NEW)
        self.assertEqual(verdict, "preserved")

    def test_stale_reverse(self):
        verdict, _ = judge.fact_verdict(
            document("之前 11 月 20 日，现在 11 月 18 日。"),
            judge.STALE_OLD, judge.STALE_NEW)
        self.assertEqual(verdict, "reversed")

    def test_correction_word_marks_old_side_historical(self):
        verdict, _ = judge.fact_verdict(
            document("发布会 11 月 20 日在 3 号厅（用户随后更正：日期由 11 月 18 日改为 11 月 20 日）"),
            judge.STALE_OLD, judge.STALE_NEW)
        self.assertEqual(verdict, "corrected")

    def test_stale_forward_with_retired_history(self):
        verdict, _ = judge.fact_verdict(
            document("发布会 11 月 20 日。原记 11 月 18 日，已作废。"),
            judge.STALE_OLD, judge.STALE_NEW)
        self.assertEqual(verdict, "corrected")

    def test_cancelled_batch_cannot_pass(self):
        result = judge._sample_status(
            ("corrected", "detail"), committed=False, expected_kind="contradiction")
        self.assertEqual(result["status"], "fail")
        self.assertFalse(result["corrected"])

    def _events(self, content, status="committed", review="verified"):
        return [
            {"type": "memory.maintenance_started", "commitSeq": 1,
             "data": {"batch_id": "mm-0123456789abcdef0123456789abcdef"}},
            {"type": "memory.document_written", "commitSeq": 2,
             "data": {"path": judge.CONTRADICTION_PATH, "content": content,
                      "evidence": ["record://event/9"],
                      "review": {"state": review, "basis": "record-recheck",
                                 "refs": ["record://event/9"]}}},
            {"type": "memory.maintenance_finished", "commitSeq": 3,
             "data": {"batch_id": "mm-0123456789abcdef0123456789abcdef",
                      "status": status,
                      "checks": {"references_resolve": True,
                                 "index_within_limit": True,
                                 "documents_not_longer_than_evidence": True,
                                 "change_budget_within_limit": True,
                                 "verification_rechecked": True},
                      "verification": {"checked": 1, "blocking": 0},
                      "changes": [{"path": judge.CONTRADICTION_PATH,
                                   "deleted": False}]}},
        ]

    def test_end_to_end_reversed_document_fails_and_is_false_verified(self):
        events = self._events("之前八点起床，现在七点起床。")
        documents = judge.reconstruct_documents(events)
        started, batches = judge.batch_facts(events, documents)
        self.assertEqual(len(batches), 1)
        sample = judge.contradiction_sample(1, events, batches[0], True)
        self.assertEqual(sample["status"], "fail")
        self.assertFalse(sample["corrected"])
        self.assertEqual(batches[0]["false_verified_documents"], 1,
                         "a verified reversed correction is independently false")

    def test_end_to_end_cancelled_batch_does_not_pass(self):
        events = self._events("用户每天早上八点起床。", status="cancelled")
        documents = judge.reconstruct_documents(events)
        _, batches = judge.batch_facts(events, documents)
        sample = judge.contradiction_sample(1, events, batches[0], False)
        self.assertEqual(sample["status"], "fail")
        self.assertFalse(sample["corrected"])
        self.assertTrue(sample["committed"] is False)

    def test_verified_reverse_is_independently_bad(self):
        # batch_facts' independent check uses the same semantic verdict.
        doc = document("之前八点起床，现在七点起床。", state="verified",
                       refs=["record://event/1"])
        verdict, _ = judge.fact_verdict(
            doc, judge.CONTRADICTION_OLD, judge.CONTRADICTION_NEW)
        self.assertNotIn(verdict, ("corrected", "preserved"))


if __name__ == "__main__":
    unittest.main()
