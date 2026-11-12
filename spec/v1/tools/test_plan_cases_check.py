#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Mutation tests for the performance-plan contract case checker.

Every test runs the checker on a temporary copy of spec/v1, so the real tree is never modified.
"""
from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SPEC_DIR = Path(__file__).resolve().parents[1]


def run_checker(spec_dir: Path) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(spec_dir / "tools" / "plan_cases_check.py"), "--spec-dir", str(spec_dir)],
        capture_output=True, text=True, check=False)


class PlanCasesTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.copy = Path(self.temp.name) / "v1"
        shutil.copytree(SPEC_DIR, self.copy, ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))

    def replace(self, relative: str, old: str, new: str) -> None:
        path = self.copy / relative
        text = path.read_text(encoding="utf-8")
        self.assertIn(old, text)
        path.write_text(text.replace(old, new, 1), encoding="utf-8")

    def mutate(self, relative: str, mutate) -> None:
        path = self.copy / relative
        doc = json.loads(path.read_text(encoding="utf-8"))
        mutate(doc)
        path.write_text(json.dumps(doc, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    def assert_fails(self, completed: subprocess.CompletedProcess, needle: str) -> None:
        self.assertNotEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        self.assertIn(needle, completed.stdout)

    def test_real_tree_passes(self) -> None:
        completed = run_checker(SPEC_DIR)
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        self.assertIn("0 error(s)", completed.stdout)
        self.assertIn("ok golden/plan/retention.json", completed.stdout)

    def test_target_number_is_rejected(self) -> None:
        self.replace("golden/plan/perf-targets.json",
                     '"light": "待基线", "typical": "待基线", "heavy": "待基线"',
                     '"light": 120, "typical": "待基线", "heavy": "待基线"')
        completed = run_checker(self.copy)
        self.assert_fails(completed, "must be '待基线'")

    def test_journal_pruned_before_durable_is_rejected(self) -> None:
        self.replace("golden/plan/retention.json",
                     '"durable": false, "referenced": false, "expected": "keep"',
                     '"durable": false, "referenced": false, "expected": "prune"')
        completed = run_checker(self.copy)
        self.assert_fails(completed, "expected prune")

    def test_storage_level_three_without_card_is_rejected(self) -> None:
        self.replace("golden/plan/storage-levels.json",
                     '"expectedLevel": 3,\n      "expectedActions"',
                     '"expectedLevel": 2,\n      "expectedActions"')
        completed = run_checker(self.copy)
        self.assert_fails(completed, "expectedLevel 2")

    def test_response_log_key_mismatch_is_rejected(self) -> None:
        self.replace("golden/plan/response-log-key.json",
                     "22a064a9434a3ee2baa6abb121b54d316408f4995cec87f588cd88472824400a",
                     "00" * 32)
        completed = run_checker(self.copy)
        self.assert_fails(completed, "does not match the recipe")

    def test_sixteen_kib_batch_is_rejected(self) -> None:
        self.replace("golden/plan/streaming.json",
                     '"coalesceMaxBytes": 4096, "coalesceMaxMs": 100',
                     '"coalesceMaxBytes": 16384, "coalesceMaxMs": 100')
        completed = run_checker(self.copy)
        self.assert_fails(completed, "coalesceMaxBytes")

    def test_referenced_blob_deleted_is_rejected(self) -> None:
        def mutate(doc):
            case = next(item for item in doc["valid"] if item["id"] == "referenced-blob-kept")
            case["deleted"] = ["aa"]
        self.mutate("golden/plan/single-copy.json", mutate)
        completed = run_checker(self.copy)
        self.assert_fails(completed, "referenced blob was deleted")

    def test_unversioned_route_made_cacheable_is_rejected(self) -> None:
        def mutate(doc):
            case = next(item for item in doc["valid"] if item["id"] == "cache-page-stays-no-store")
            case["header"] = "private, max-age=31536000, immutable"
        self.mutate("golden/plan/single-copy.json", mutate)
        completed = run_checker(self.copy)
        self.assert_fails(completed, "must stay no-store")

    def test_blob_below_threshold_is_rejected(self) -> None:
        def mutate(doc):
            case = next(item for item in doc["valid"] if item["id"] == "inline-below-threshold")
            case["expected"]["storedAs"] = "blob"
        self.mutate("golden/plan/single-copy.json", mutate)
        completed = run_checker(self.copy)
        self.assert_fails(completed, "the law gives 'inline'")

    def test_hardlink_materialization_is_rejected(self) -> None:
        def mutate(doc):
            case = next(item for item in doc["valid"] if item["id"] == "materialized-copy-without-clone")
            case["action"] = "hardlink"
        self.mutate("golden/plan/single-copy.json", mutate)
        completed = run_checker(self.copy)
        self.assert_fails(completed, "hard link")

    def test_blob_reference_across_handoff_is_rejected(self) -> None:
        def mutate(doc):
            case = next(item for item in doc["valid"] if item["id"] == "handoff-snapshot-at-closed-tail")
            case["blobRecordsInSegments"] = 1
        self.mutate("golden/plan/single-copy.json", mutate)
        completed = run_checker(self.copy)
        self.assert_fails(completed, "cross the handoff boundary")

    def test_missing_vector_is_rejected(self) -> None:
        (self.copy / "golden" / "plan" / "perf-targets.json").unlink()
        completed = run_checker(self.copy)
        self.assert_fails(completed, "missing vector 'perf-targets'")

    def test_unknown_vector_is_rejected(self) -> None:
        path = self.copy / "golden" / "plan" / "retention.json"
        doc = json.loads(path.read_text(encoding="utf-8"))
        doc["vector"] = "unknown-vector"
        path.write_text(json.dumps(doc, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        completed = run_checker(self.copy)
        self.assert_fails(completed, "not in enum")

    def test_high_water_record_pruned_is_rejected(self) -> None:
        self.replace("golden/plan/retention.json",
                     '"highWater": true, "expected": "keep", "lastJseqAfter": 7',
                     '"highWater": true, "expected": "prune", "lastJseqAfter": 7')
        completed = run_checker(self.copy)
        self.assert_fails(completed, "expected prune")

    def test_last_jseq_decrease_is_rejected(self) -> None:
        self.replace("golden/plan/retention.json",
                     '"lastJseqAfter": 7, "lastJseqBefore": 7',
                     '"lastJseqAfter": 6, "lastJseqBefore": 7')
        completed = run_checker(self.copy)
        self.assert_fails(completed, "last_jseq_decreased")

    def test_sampled_heap_marked_implemented_is_rejected(self) -> None:
        self.replace("golden/plan/memory-input.json",
                     '"sampledHeap": {"status": "target", "producer": "none", "injectionPoint": "reportEngineHeapBytes"}',
                     '"sampledHeap": {"status": "implemented", "producer": "PhoneDSHEngine", "injectionPoint": "reportEngineHeapBytes"}')
        completed = run_checker(self.copy)
        self.assert_fails(completed, "sampled_heap")

    def test_action_order_change_is_rejected(self) -> None:
        self.replace("golden/plan/memory-input.json",
                     '"actionOrder": ["clearTmp", "plannedRestart"]',
                     '"actionOrder": ["plannedRestart", "clearTmp"]')
        completed = run_checker(self.copy)
        self.assert_fails(completed, "action_order_changed")

    def test_missing_memory_input_vector_is_rejected(self) -> None:
        (self.copy / "golden" / "plan" / "memory-input.json").unlink()
        completed = run_checker(self.copy)
        self.assert_fails(completed, "missing vector 'memory-input'")


if __name__ == "__main__":
    unittest.main()
