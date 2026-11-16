#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Negative-case tests for the baseline-diff CI tools.

Each case starts from a deliberately red base and asserts that the comparison
is not satisfied by a same-name red: a new sub-check, a coverage drop, an
unparsable log, a removed anchor without evidence, a malformed anchor or a
compile/short-run JUnit set must all leave the verdict non-zero.

Run: python3 scripts/ci/test_ci_tools.py
"""
from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
DIFF = HERE / "ci_baseline_diff.py"
ANCHORS = HERE / "bot_ui_anchor_report.py"


def run(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, *args], capture_output=True, text=True)


def write_json(path: Path, value) -> None:
    path.write_text(json.dumps(value, ensure_ascii=False) + "\n", encoding="utf-8")


def stage(rc: int, failures: list[str], coverage: int, parsed: bool = True) -> dict:
    return {"rc": rc, "inventory": {"parsed": parsed, "coverage": coverage,
                                    "failures": failures}}


def junit_xml(path: Path, cases: list[tuple[str, str, str]]) -> None:
    rows = []
    for classname, name, status in cases:
        child = ""
        if status == "failure":
            child = "<failure message=\"boom\"/>"
        elif status == "skipped":
            child = "<skipped/>"
        rows.append(f"<testcase classname=\"{classname}\" name=\"{name}\">{child}</testcase>")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("<testsuite>" + "".join(rows) + "</testsuite>", encoding="utf-8")


class AnchorCases(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def compare(self, base: dict, head: dict, allow: dict | None = None) -> subprocess.CompletedProcess:
        write_json(self.dir / "base.json", base)
        write_json(self.dir / "head.json", head)
        args = [str(DIFF), "anchors", "--base", str(self.dir / "base.json"),
                "--head", str(self.dir / "head.json"), "--json", str(self.dir / "diff.json")]
        if allow is not None:
            write_json(self.dir / "allow.json", allow)
            args += ["--allow-removals", str(self.dir / "allow.json")]
        return run(*args)

    def test_new_anchor_failure_fails(self) -> None:
        proc = self.compare(
            {"anchors": ["a", "b"], "failures": ["b"], "invalid": []},
            {"anchors": ["a", "b"], "failures": ["b", "c"], "invalid": []})
        self.assertNotEqual(proc.returncode, 0, proc.stdout)
        self.assertIn("NEW_FAILURE", (self.dir / "diff.json").read_text())

    def test_same_failure_set_passes(self) -> None:
        proc = self.compare(
            {"anchors": ["a", "b"], "failures": ["b"], "invalid": []},
            {"anchors": ["a", "b"], "failures": ["b"], "invalid": []})
        self.assertEqual(proc.returncode, 0, proc.stdout)

    def test_removed_anchor_without_evidence_fails(self) -> None:
        proc = self.compare(
            {"anchors": ["a", "b"], "failures": [], "invalid": []},
            {"anchors": ["a"], "failures": [], "invalid": []})
        self.assertNotEqual(proc.returncode, 0, proc.stdout)
        self.assertIn("removed without evidence", (self.dir / "diff.json").read_text())

    def test_removed_anchor_with_evidence_passes(self) -> None:
        proc = self.compare(
            {"anchors": ["a", "b"], "failures": [], "invalid": []},
            {"anchors": ["a"], "failures": [], "invalid": []},
            {"removals": [{"id": "b", "reason": "dead label", "evidence": "grep 0"}]})
        self.assertEqual(proc.returncode, 0, proc.stdout)

    def test_malformed_anchor_fails(self) -> None:
        proc = self.compare(
            {"anchors": ["a"], "failures": [], "invalid": []},
            {"anchors": ["a"], "failures": [], "invalid": ["bad"]})
        self.assertNotEqual(proc.returncode, 0, proc.stdout)


class StageCases(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def compare(self, base: dict, head: dict) -> subprocess.CompletedProcess:
        write_json(self.dir / "base.json", {"stages": base})
        write_json(self.dir / "head.json", {"stages": head})
        return run(str(DIFF), "stages", "--base", str(self.dir / "base.json"),
                   "--head", str(self.dir / "head.json"),
                   "--json", str(self.dir / "diff.json"))

    def test_second_failure_in_same_red_stage_fails(self) -> None:
        proc = self.compare({"s": stage(1, ["old"], 5)},
                            {"s": stage(1, ["old", "new"], 5)})
        self.assertNotEqual(proc.returncode, 0, proc.stdout)
        self.assertIn("NEW_FAILURE", (self.dir / "diff.json").read_text())

    def test_same_red_stage_passes(self) -> None:
        proc = self.compare({"s": stage(1, ["old"], 5)},
                            {"s": stage(1, ["old"], 5)})
        self.assertEqual(proc.returncode, 0, proc.stdout)

    def test_coverage_drop_is_incomplete(self) -> None:
        proc = self.compare({"s": stage(1, ["old"], 5)},
                            {"s": stage(1, ["old"], 4)})
        self.assertNotEqual(proc.returncode, 0, proc.stdout)
        self.assertIn("INCOMPLETE", (self.dir / "diff.json").read_text())

    def test_unparsable_stage_is_incomplete(self) -> None:
        proc = self.compare({"s": stage(1, ["old"], 5)},
                            {"s": stage(1, ["old"], 5, parsed=False)})
        self.assertNotEqual(proc.returncode, 0, proc.stdout)
        self.assertIn("INCOMPLETE", (self.dir / "diff.json").read_text())

    def test_optional_android_packaging_is_diagnostic_only(self) -> None:
        base = stage(0, [], 5)
        head = stage(1, ["NEW diagnostic"], 5)
        for entry in (base, head):
            entry["scope"] = "optional_android_packaging"
        proc = self.compare({"x": base}, {"x": head})
        self.assertEqual(proc.returncode, 0, proc.stdout)
        receipt = json.loads((self.dir / "diff.json").read_text())
        self.assertEqual(receipt["verdict"], "NO_NEW_FAILURE")
        self.assertEqual(receipt["diagnostic"]["x"]["status"], "NEW_FAILURE")

    def test_timed_out_optional_stage_is_diagnostic_only(self) -> None:
        base = stage(0, [], 5)
        head = stage(124, [], 5)
        head["timed_out"] = True
        for entry in (base, head):
            entry["scope"] = "optional_android_packaging"
        proc = self.compare({"x": base}, {"x": head})
        self.assertEqual(proc.returncode, 0, proc.stdout)
        receipt = json.loads((self.dir / "diff.json").read_text())
        self.assertEqual(receipt["diagnostic"]["x"]["status"], "INCOMPLETE")

    def test_timed_out_stage_is_incomplete(self) -> None:
        timed = stage(124, [], 5)
        timed["timed_out"] = True
        proc = self.compare({"s": stage(0, [], 5)}, {"s": timed})
        self.assertNotEqual(proc.returncode, 0, proc.stdout)
        self.assertIn("timed out", (self.dir / "diff.json").read_text())

    def test_failing_stage_without_failure_lines_never_passes(self) -> None:
        # Base passed and head failed without a parsed failure line: that is a
        # new stage-level failure (or at best INCOMPLETE), never a pass.
        proc = self.compare({"s": stage(0, [], 5)},
                            {"s": stage(1, [], 5)})
        self.assertNotEqual(proc.returncode, 0, proc.stdout)
        verdict = json.loads((self.dir / "diff.json").read_text())["verdict"]
        self.assertIn(verdict, ("NEW_FAILURE", "INCOMPLETE"))

    def test_fixed_stage_passes(self) -> None:
        proc = self.compare({"s": stage(1, ["old"], 5)},
                            {"s": stage(0, [], 5)})
        self.assertEqual(proc.returncode, 0, proc.stdout)


class JUnitCases(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def compare(self) -> subprocess.CompletedProcess:
        return run(str(DIFF), "junit", "--base", str(self.dir / "base"),
                   "--head", str(self.dir / "head"), "--json", str(self.dir / "diff.json"))

    def test_new_junit_failure_fails(self) -> None:
        junit_xml(self.dir / "base" / "T.xml",
                  [("C", "old", "failure"), ("C", "ok", "pass")])
        junit_xml(self.dir / "head" / "T.xml",
                  [("C", "old", "failure"), ("C", "ok", "failure")])
        proc = self.compare()
        self.assertNotEqual(proc.returncode, 0, proc.stdout)
        self.assertIn("NEW_FAILURE", (self.dir / "diff.json").read_text())

    def test_short_run_is_incomplete(self) -> None:
        junit_xml(self.dir / "base" / "T.xml",
                  [("C", "a", "pass"), ("C", "b", "pass")])
        junit_xml(self.dir / "head" / "T.xml", [("C", "a", "pass")])
        proc = self.compare()
        self.assertNotEqual(proc.returncode, 0, proc.stdout)
        self.assertIn("INCOMPLETE", (self.dir / "diff.json").read_text())

    def test_missing_xml_is_incomplete(self) -> None:
        junit_xml(self.dir / "base" / "T.xml", [("C", "a", "pass")])
        proc = self.compare()
        self.assertNotEqual(proc.returncode, 0, proc.stdout)
        self.assertIn("INCOMPLETE", (self.dir / "diff.json").read_text())

    def test_more_skips_is_incomplete(self) -> None:
        junit_xml(self.dir / "base" / "T.xml",
                  [("C", "a", "pass"), ("C", "b", "pass")])
        junit_xml(self.dir / "head" / "T.xml",
                  [("C", "a", "pass"), ("C", "b", "skipped")])
        proc = self.compare()
        self.assertNotEqual(proc.returncode, 0, proc.stdout)
        self.assertIn("INCOMPLETE", (self.dir / "diff.json").read_text())


if __name__ == "__main__":
    unittest.main(verbosity=2)
