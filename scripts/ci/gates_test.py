#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Behavioral regression checks for the local and simulator gates."""

from __future__ import annotations

import copy
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
SPEC = importlib.util.spec_from_file_location("sim_gate", HERE / "sim_gate.py")
sim_gate = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = sim_gate
SPEC.loader.exec_module(sim_gate)


def documents():
    return {name: sim_gate._suite(name) for name in sim_gate.REPORTS}


def recalculate_summary(report):
    rows = report["rows"]
    summary = report["summary"]
    summary["pass"] = sum(row["status"] == "PASS" for row in rows)
    summary["fail"] = sum(row["status"] == "FAIL" for row in rows)
    summary["info"] = sum(row["status"] == "INFO" for row in rows)
    summary["gate_passed"] = not any(
        row["gating"] and row["status"] == "FAIL" for row in rows
    )


class GateContracts(unittest.TestCase):
    def test_simulator_failure_replays_log_without_appending_it_to_itself(self):
        source = (HERE / "sim.sh").read_text(encoding="utf-8")
        setup = source[source.index("exec 3>&1"):source.index("sim_require_tools ||")]
        failure = source[source.index('if [ "$TEST_RC" -ne 0 ]; then'):
                         source.index('if [ "$KILL_ATTEMPT_RC" -ne 0 ]; then')]
        # Run the production redirection, EXIT trap and failed-test branch.
        # Bound the file size so the old self-feeding tail cannot fill disk.
        fixture = "".join(f"fixture-{i:03d}: {'diagnostic ' * 16}\n" for i in range(100))
        with tempfile.TemporaryDirectory(prefix="pdsh-sim-log-") as temp:
            log = Path(temp) / "sim.log"
            for status in (7, 124):
                with self.subTest(exit_status=status):
                    log.write_text(fixture, encoding="utf-8")
                    run = subprocess.run(
                        ["bash", "-c", 'set -euo pipefail\nulimit -f 256\n'
                         'LOG="$1"\nTEST_RC="$2"\n' + setup + failure,
                         "sim-log-test", str(log), str(status)],
                        cwd=ROOT, text=True, stdout=subprocess.PIPE,
                        stderr=subprocess.STDOUT, timeout=5, check=False,
                    )
                    self.assertEqual(run.returncode, status, run.stdout)
                    self.assertLess(log.stat().st_size, len(fixture.encode()) + 1024)
                    self.assertTrue(log.read_text(encoding="utf-8").startswith(fixture))
                    self.assertNotIn("tail:", run.stdout)
                    self.assertIn("fixture-099:", run.stdout)
                    self.assertIn(f"sim: the test process exited {status}", run.stdout)

    def gate(self, reports):
        with tempfile.TemporaryDirectory(prefix="pdsh-gate-contracts-") as temp:
            for name, report in reports.items():
                (Path(temp) / name).write_text(json.dumps(report), encoding="utf-8")
            return sim_gate.gate(temp, echo=False)

    def test_complete_versioned_reports_pass(self):
        self.assertEqual(self.gate(documents()), 0)

    def test_slow_checkpoint_requires_correctness_evidence_even_when_timing_is_info(self):
        reports = documents()
        report = reports["probe-report.json"]
        row = next(row for row in report["rows"] if row["probe"] == "log.checkpoint-100-files")
        row["status"] = "INFO"
        row["threshold"]["gating"] = False
        row["threshold"]["met"] = False
        row["metrics"] = {"files": 100, "materialized_upto_mseq": 100,
                          "acked_mseq": 100, "durable_mseq": 100}
        recalculate_summary(report)
        self.assertEqual(self.gate(reports), 0)
        row["metrics"]["durable_mseq"] = 99
        self.assertEqual(self.gate(reports), 1)

    def test_missing_required_probe_fails_even_when_remaining_rows_pass(self):
        reports = documents()
        report = reports["probe-report.json"]
        report["rows"] = [row for row in report["rows"]
                          if row["probe"] != "channel.ws-echo-1000"]
        recalculate_summary(report)
        self.assertEqual(self.gate(reports), 1)

    def test_duplicate_required_probe_fails(self):
        reports = documents()
        report = reports["smoke-report.json"]
        report["rows"].append(copy.deepcopy(report["rows"][0]))
        recalculate_summary(report)
        self.assertEqual(self.gate(reports), 1)

    def test_kill_rows_follow_requested_iteration_count(self):
        reports = documents()
        report = reports["kill-report.json"]
        report["iterations_requested"] = 5
        report["iterations"] = 4
        self.assertEqual(self.gate(reports), 1)

    def test_all_pass_kills_with_duplicate_coverage_do_not_certify_the_matrix(self):
        reports = documents()
        report = reports["kill-report.json"]
        # Keep the number, unique indices and PASS counts valid, but replace
        # one matrix cell with a repeat of another kind/timing combination.
        rows = [row for row in report["rows"] if row["gating"]]
        first, last = rows[0], rows[-1]
        last["metrics"] = copy.deepcopy(first["metrics"])
        index = last["probe"].split(".")[1]
        last["probe"] = f"kill.{index}.{first['metrics']['kind']}.{first['metrics']['timing']}"
        self.assertEqual(self.gate(reports), 1)

    def test_bulk_host_evaluation_passes_separate_path_safe_ids(self):
        # Drive the real shell producer across its subprocess boundary. A
        # single pending ID hid the newline/comma mismatch in the first G2 run.
        source = (ROOT / "scripts/ci/scenarios.sh").read_text(encoding="utf-8")
        start = source.index("host_finalize_workspace_commands() {")
        end = source.index("# 4a. macOS path", start)
        function = source[start:end]
        with tempfile.TemporaryDirectory(prefix="pdsh-host-ids-") as temp:
            temp = Path(temp)
            results, binary, repo = temp / "results", temp / "bin", temp / "repo"
            for directory in (results, binary, repo):
                directory.mkdir()
            for identifier, pending in (("G2-A02", True), ("G2-A03", True),
                                        ("G2-C04", False), ("G2-OTHER", True)):
                directory = results / identifier
                directory.mkdir()
                (directory / "report.json").write_text(json.dumps({
                    "id": identifier,
                    "assertions": [{"status": "pending_host"}] if pending else [],
                }), encoding="utf-8")
            capture = temp / "ids.txt"
            fake_swift = binary / "swift"
            fake_swift.write_text(
                "#!/usr/bin/env python3\nimport os,re,sys\nfrom pathlib import Path\n"
                "ids=os.environ['PDSH_SCENARIO_HOST_EVAL_IDS']\n"
                "Path(os.environ['PDSH_TEST_CAPTURE']).write_text(ids)\n"
                "assert all(re.fullmatch(r'G2-[A-Za-z0-9-]+',i) for i in ids.split(','))\n"
                "print('Executed 1 test')\n", encoding="utf-8")
            fake_swift.chmod(0o755)
            env = os.environ.copy()
            env.update(RESULTS=str(results), ROOT=str(repo),
                       PDSH_TEST_CAPTURE=str(capture),
                       PATH=str(binary) + os.pathsep + env.get("PATH", ""))
            run = subprocess.run(
                ["bash", "-c", "set -eu\n" + function +
                 '\nhost_finalize_workspace_commands "G2-A02,G2-A03,G2-C04"\n'],
                cwd=ROOT, env=env, text=True, stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT, check=False)
            self.assertEqual(run.returncode, 0, run.stdout)
            self.assertEqual(capture.read_text(), "G2-A02,G2-A03")

    def test_empty_stage_selection_is_rejected(self):
        for selection in ("", ",,,"):
            result = subprocess.run(
                ["bash", str(ROOT / "scripts/ci/check.sh"), "--only", selection],
                cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                check=False,
            )
            self.assertEqual(result.returncode, 2, result.stdout)
            self.assertNotIn("CI GATE: PASS", result.stdout)

    def test_unavailable_optional_stage_is_incomplete_not_pass(self):
        with tempfile.TemporaryDirectory(prefix="pdsh-gate-stage-") as temp:
            env = os.environ.copy()
            env["PATH"] = "/usr/bin:/bin"
            env["CI_TMP"] = str(Path(temp) / "ci")
            result = subprocess.run(
                ["bash", str(ROOT / "scripts/ci/check.sh"), "--only", "phone-xcode-resolve"],
                cwd=ROOT, env=env, text=True, stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT, check=False,
            )
            self.assertEqual(result.returncode, 2, result.stdout)
            self.assertIn("SKIP: phone-xcode-resolve", result.stdout)
            self.assertIn("CI GATE: INCOMPLETE", result.stdout)
            self.assertNotIn("CI GATE: PASS", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
