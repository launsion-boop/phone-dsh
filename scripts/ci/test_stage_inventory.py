#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Replay tests for the stage-log inventory and comparison.

Real CI showed the old parser treating wrapper durations as failures while
missing the actual `path:line: rule: value` diagnostics and unittest ids.
These cases pin the three required behaviours:

  * same diagnostics/tests, only wrapper duration differs -> no new failure;
  * a real new diagnostic (or a second occurrence of an existing one) fails;
  * wrapper-only or truncated logs -> INCOMPLETE, never "no new failure".
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
DIFF = HERE / "ci_baseline_diff.py"
sys.path.insert(0, str(HERE))
from stage_inventory import parse_log  # noqa: E402

UNITTEST = """================================================================
== stage: phone-gate-contracts
test_alpha (__main__.Suite.test_alpha) ... ok
test_beta (__main__.Suite.test_beta) ... FAIL
FAIL: test_beta (__main__.Suite.test_beta)
----------------------------------------------------------------------
Ran 2 tests in 1.234s
FAILED (failures=1)
== FAIL: phone-gate-contracts (35s) — exit 1

== summary
  FAIL  phone-gate-contracts      35s  exit 1
== CI GATE: FAIL
"""

DIAGNOSTICS = """Sources/PhoneDSHBot/MCP/A.swift:56: main-actor: @MainActor
Sources/PhoneDSHBot/MCP/A.swift:56: main-actor: @MainActor
== FAIL: phone-modules (0s) — exit 1
== summary
  FAIL  phone-modules  0s  exit 1
== CI GATE: FAIL
"""

WRAPPER_ONLY = """== FAIL: phone-hygiene (17s) — exit 1
== summary
  FAIL  phone-hygiene  17s  exit 1
== CI GATE: FAIL
"""


def parse(text: str) -> dict:
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "stage.log"
        path.write_text(text, encoding="utf-8")
        return parse_log(path)


def write_stage(path: Path, rc: int, inventory: dict) -> None:
    path.write_text(json.dumps({"stages": {"x": {"rc": rc, "inventory": inventory}}}),
                    encoding="utf-8")


class ParseCases(unittest.TestCase):
    def test_unittest_suites_and_failure_id(self) -> None:
        inv = parse(UNITTEST)
        self.assertTrue(inv["parsed"])
        self.assertEqual(inv["kind"], "unittest")
        self.assertEqual(inv["tests"], 2)
        self.assertEqual(inv["suites"], 1)
        self.assertEqual(inv["failure_counts"], {"FAIL __main__.Suite.test_beta": 1})

    def test_wrapper_duration_is_not_an_identity(self) -> None:
        inv = parse(UNITTEST)
        self.assertNotIn("FAIL", inv["failure_counts"])
        self.assertFalse(any("35s" in key for key in inv["failure_counts"]))

    def test_duplicate_diagnostics_keep_count(self) -> None:
        inv = parse(DIAGNOSTICS)
        self.assertTrue(inv["parsed"])
        self.assertEqual(inv["kind"], "diagnostics")
        self.assertEqual(inv["coverage"], 2)
        self.assertEqual(
            inv["failure_counts"],
            {"Sources/PhoneDSHBot/MCP/A.swift:56: main-actor: @MainActor": 2})

    def test_wrapper_only_is_unparsed(self) -> None:
        inv = parse(WRAPPER_ONLY)
        self.assertFalse(inv["parsed"])

    def test_truncated_unittest_is_unparsed(self) -> None:
        inv = parse("FAIL: test_beta (__main__.Suite.test_beta)\nFAILED (failures=1)\n")
        self.assertFalse(inv["parsed"])


class CompareCases(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def compare(self, base: dict, head: dict) -> subprocess.CompletedProcess:
        write_stage(self.dir / "base.json", 1, base)
        write_stage(self.dir / "head.json", 1, head)
        return subprocess.run(
            [sys.executable, str(DIFF), "stages", "--base", str(self.dir / "base.json"),
             "--head", str(self.dir / "head.json"), "--json", str(self.dir / "diff.json")],
            capture_output=True, text=True)

    def test_same_failures_only_duration_differs_passes(self) -> None:
        base = parse(UNITTEST)
        head = parse(UNITTEST.replace("35s", "99s").replace("1.234s", "9.999s"))
        proc = self.compare(base, head)
        self.assertEqual(proc.returncode, 0, proc.stdout)
        self.assertEqual(json.loads((self.dir / "diff.json").read_text())["verdict"],
                         "NO_NEW_FAILURE")

    def test_new_diagnostic_fails(self) -> None:
        base = parse(DIAGNOSTICS)
        head = parse(DIAGNOSTICS + "Sources/PhoneDSHBot/MCP/B.swift:1: banned-word: tonoai\n")
        proc = self.compare(base, head)
        self.assertNotEqual(proc.returncode, 0, proc.stdout)
        self.assertIn("NEW_FAILURE", (self.dir / "diff.json").read_text())

    def test_extra_occurrence_of_same_diagnostic_fails(self) -> None:
        base = parse(DIAGNOSTICS)
        head = parse(DIAGNOSTICS.replace("A.swift:56: main-actor: @MainActor\n",
                                         "A.swift:56: main-actor: @MainActor\n"
                                         "A.swift:56: main-actor: @MainActor\n", 1))
        proc = self.compare(base, head)
        self.assertNotEqual(proc.returncode, 0, proc.stdout)
        receipt = json.loads((self.dir / "diff.json").read_text())
        self.assertTrue(any("(x1)" in item for item in receipt["new"]), receipt["new"])

    def test_wrapper_only_is_incomplete(self) -> None:
        base = parse(WRAPPER_ONLY)
        head = parse(WRAPPER_ONLY.replace("17s", "99s"))
        proc = self.compare(base, head)
        self.assertNotEqual(proc.returncode, 0, proc.stdout)
        self.assertIn("INCOMPLETE", (self.dir / "diff.json").read_text())

    def test_coverage_drop_is_incomplete(self) -> None:
        base = parse(UNITTEST)
        head = parse(UNITTEST.replace("Ran 2 tests", "Ran 1 tests"))
        proc = self.compare(base, head)
        self.assertNotEqual(proc.returncode, 0, proc.stdout)
        self.assertIn("INCOMPLETE", (self.dir / "diff.json").read_text())


@unittest.skipUnless(os.environ.get("PDSH_CI_EVIDENCE"), "real evidence not provided")
class RealLogReplay(unittest.TestCase):
    """Replay run 43903927538's raw base/head logs when the evidence dir is set."""

    def test_real_logs(self) -> None:
        evidence = Path(os.environ["PDSH_CI_EVIDENCE"])
        base = json.loads((evidence / "base.json").read_text())["stages"]
        head = json.loads((evidence / "head.json").read_text())["stages"]
        for stage, entry in base.items():
            entry["inventory"] = parse_log(evidence / Path(entry["log"]).name)
        for stage, entry in head.items():
            entry["inventory"] = parse_log(evidence / Path(entry["log"]).name)
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "base.json").write_text(json.dumps({"stages": base}))
            (Path(tmp) / "head.json").write_text(json.dumps({"stages": head}))
            proc = subprocess.run(
                [sys.executable, str(DIFF), "stages",
                 "--base", str(Path(tmp) / "base.json"),
                 "--head", str(Path(tmp) / "head.json"),
                 "--json", str(Path(tmp) / "diff.json")],
                capture_output=True, text=True)
            receipt = json.loads((Path(tmp) / "diff.json").read_text())
        self.assertNotEqual(proc.returncode, 0)
        self.assertEqual(receipt["verdict"], "NEW_FAILURE")
        self.assertTrue(any("email: a@b.md" in item for item in receipt["new"]))


if __name__ == "__main__":
    unittest.main(verbosity=2)
