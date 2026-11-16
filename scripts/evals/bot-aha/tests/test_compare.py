#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Mutation tests for the baseline/candidate comparison."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
COMPARE = HERE.parent / "compare.py"
HASH = "a" * 64
HASH_B = "b" * 64


def make_report(overall: str, scenarios: dict, *, catalog: str = HASH,
                dimensions: str = HASH_B, upstream: str = "real") -> dict:
    return {
        "schema_version": 1,
        "overall": overall,
        "catalog_sha256": catalog,
        "dimensions_sha256": dimensions,
        "upstream": upstream,
        "scenarios": [
            {
                "id": scenario_id,
                "status": status,
                "dimensions": [
                    {"name": name, "kind": "hard", "passed": passed}
                    for name, passed in dims.items()
                ],
            }
            for scenario_id, (status, dims) in scenarios.items()
        ],
    }


class CompareTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def run_compare(self, baseline: dict, candidate: dict) -> tuple[int, dict]:
        baseline_path = self.root / "baseline.json"
        candidate_path = self.root / "candidate.json"
        baseline_path.write_text(json.dumps(baseline), encoding="utf-8")
        candidate_path.write_text(json.dumps(candidate), encoding="utf-8")
        out = self.root / "out"
        completed = subprocess.run([
            sys.executable, str(COMPARE),
            "--baseline", str(baseline_path),
            "--candidate", str(candidate_path),
            "--out", str(out),
        ], capture_output=True, text=True)
        report = out / "aha-compare.json"
        return completed.returncode, (
            json.loads(report.read_text(encoding="utf-8")) if report.is_file() else {})

    def test_candidate_improves_to_pass(self) -> None:
        baseline = make_report("FAIL", {"A": ("FAIL", {"boundary": False})})
        candidate = make_report("PASS", {"A": ("PASS", {"boundary": True})})
        code, report = self.run_compare(baseline, candidate)
        self.assertEqual(code, 0)
        self.assertEqual(report["verdict"], "PASS")
        self.assertEqual(report["newly_passing"], ["A"])

    def test_regression_fails(self) -> None:
        baseline = make_report("PASS", {"A": ("PASS", {"boundary": True})})
        candidate = make_report("PASS", {"A": ("PASS", {"boundary": False})})
        code, report = self.run_compare(baseline, candidate)
        self.assertEqual(code, 1)
        self.assertEqual(report["verdict"], "FAIL")
        self.assertEqual(report["regressions"][0]["dimension"], "boundary")

    def test_different_catalog_is_incomparable(self) -> None:
        baseline = make_report("PASS", {"A": ("PASS", {"boundary": True})})
        candidate = make_report("PASS", {"A": ("PASS", {"boundary": True})}, catalog="cat-2")
        code, _ = self.run_compare(baseline, candidate)
        self.assertEqual(code, 2)

    def test_not_run_side_is_not_pass(self) -> None:
        baseline = make_report("NOT_RUN", {"A": ("NOT_RUN", {"boundary": True})})
        candidate = make_report("PASS", {"A": ("PASS", {"boundary": True})})
        code, report = self.run_compare(baseline, candidate)
        self.assertEqual(code, 3)
        self.assertEqual(report["verdict"], "NOT_RUN")

    def test_mock_reports_are_incomparable(self) -> None:
        baseline = make_report("PASS", {"A": ("PASS", {"boundary": True})}, upstream="mock")
        candidate = make_report("PASS", {"A": ("PASS", {"boundary": True})}, upstream="mock")
        code, _ = self.run_compare(baseline, candidate)
        self.assertEqual(code, 2)

    def test_empty_dimension_set_is_incomparable(self) -> None:
        baseline = make_report("PASS", {"A": ("PASS", {})})
        candidate = make_report("PASS", {"A": ("PASS", {"boundary": True})})
        code, _ = self.run_compare(baseline, candidate)
        self.assertEqual(code, 2)

    def test_duplicate_dimension_names_are_incomparable(self) -> None:
        baseline = make_report("PASS", {"A": ("PASS", {"boundary": True})})
        candidate = make_report("PASS", {"A": ("PASS", {"boundary": True})})
        candidate["scenarios"][0]["dimensions"].append(
            {"name": "boundary", "kind": "hard", "passed": True})
        code, _ = self.run_compare(baseline, candidate)
        self.assertEqual(code, 2)

    def test_missing_hash_is_incomparable(self) -> None:
        baseline = make_report("PASS", {"A": ("PASS", {"boundary": True})}, catalog="")
        candidate = make_report("PASS", {"A": ("PASS", {"boundary": True})}, catalog="")
        code, _ = self.run_compare(baseline, candidate)
        self.assertEqual(code, 2)

    def test_dimension_set_drift_is_incomparable(self) -> None:
        baseline = make_report("PASS", {"A": ("PASS", {"boundary": True})})
        candidate = make_report("PASS", {"A": ("PASS", {"boundary": True, "restraint": True})})
        code, _ = self.run_compare(baseline, candidate)
        self.assertEqual(code, 2)


if __name__ == "__main__":
    unittest.main()
