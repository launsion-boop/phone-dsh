#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Run the real P0 stage against an isolated page-inventory fixture.

Unrelated P0 tools are deliberately inert in this fixture. The actual extractor,
its actual mutation suite, the shared fixture and the actual stage dispatcher
are copied from the checkout; each mutation therefore tests the stage boundary.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GOLDEN = ROOT / "spec/ui/v1/golden/page-completeness"


class P0CompletenessTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.trace = self.root / "trace.txt"
        self.copy("scripts/ci/check.sh")
        self.copy("spec/ui/v1/tools/extract_ios_pages.py")
        self.copy("spec/ui/v1/tools/test_extract_ios_pages.py")
        self.copy("spec/ui/v1/tools/ui_check.py", "spec/ui/v1/tools/ui_check_real.py")
        self.copy("spec/v1/tools/spec_golden.py")
        self.copy("spec/platform/tools/platform_check.py", "spec/platform/tools/platform_lint_real.py")
        shutil.copytree(GOLDEN, self.root / "spec/ui/v1/golden/page-completeness")

        probe = self.root / "examples/probe-app/PhoneDSHProbe"
        probe.mkdir(parents=True)
        shutil.copyfile(GOLDEN / "FixturePage.swift", probe / "FixturePage.swift")
        (probe / "HomeDrawer.swift").write_text("struct HomeDrawer {}\n", encoding="utf-8")
        (probe / "HomeSpec.swift").write_text("struct HomeSpec {}\n", encoding="utf-8")
        pages = self.root / "spec/ui/v1/pages"
        pages.mkdir(parents=True)
        shutil.copyfile(GOLDEN / "fixture.json", pages / "fixture.json")
        (pages / "home-drawer.json").write_text(
            json.dumps({"page": "HomeDrawer", "handRegistered": {"reason": "fixture"}}), encoding="utf-8"
        )

        # Fake only the unrelated prerequisite and parity checkers. Each logs
        # its call and can fail independently, so the real stage must retain it.
        prerequisites = (
            "spec/v1/tools/catalog_check.py", "spec/v1/tools/bridge_check.py",
            "spec/v1/tools/gateway_check.py", "spec/v1/tools/fixture_check.py",
            "spec/host/v1/tools/host_check.py",
            "spec/v1/tools/trajectory_norm.py", "spec/ui/v1/tools/page_structure_check.py",
        )
        for path in prerequisites:
            self.write_stub(path, Path(path).stem)
        self.write(
            "spec/ui/v1/tools/ui_check.py",
            "from ui_check_real import *\n"
            "if __name__ == '__main__':\n"
            " import os,sys\n"
            " with open(os.environ['P0_TEST_TRACE'], 'a') as f: f.write('ui_check\\n')\n"
            " sys.exit(7 if os.environ.get('P0_TEST_FAIL') == 'ui_check' else 0)\n",
        )
        self.write(
            "spec/platform/tools/platform_check.py",
            "from platform_lint_real import lint_schema\n"
            "if __name__ == '__main__':\n"
            " import os,sys\n"
            " with open(os.environ['P0_TEST_TRACE'], 'a') as f: f.write('platform_check\\n')\n"
            " sys.exit(7 if os.environ.get('P0_TEST_FAIL') == 'platform_check' else 0)\n",
        )
        # The real extractor tests run unchanged; a small sentinel proves the
        # discovery call actually executed them and tests failure propagation.
        with (self.root / "spec/ui/v1/tools/test_extract_ios_pages.py").open("a", encoding="utf-8") as out:
            out.write(
                "\nclass P0StageSentinel(unittest.TestCase):\n"
                "    def test_extractor_suite_was_run(self):\n"
                "        import os\n"
                "        with open(os.environ['P0_TEST_TRACE'], 'a') as f: f.write('extractor_tests\\n')\n"
                "        self.assertNotEqual(os.environ.get('P0_TEST_FAIL'), 'extractor_tests')\n"
            )
        self.write(
            "spec/ui/v1/tools/test_page_structure_check.py",
            "import os,unittest\n"
            "class PageTests(unittest.TestCase):\n"
            " def test_page_checker_suite(self):\n"
            "  with open(os.environ['P0_TEST_TRACE'], 'a') as f: f.write('page_checker_tests\\n')\n"
            "  self.assertNotEqual(os.environ.get('P0_TEST_FAIL'), 'page_checker_tests')\n",
        )

    def write(self, path, content):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8")

    def copy(self, source, destination=None):
        target = self.root / (destination or source)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / source, target)

    def write_stub(self, path, label):
        self.write(
            path,
            "import os,sys\n"
            "with open(os.environ['P0_TEST_TRACE'], 'a') as f: f.write(%r + '\\n')\n"
            "sys.exit(7 if os.environ.get('P0_TEST_FAIL') == %r else 0)\n" % (label, label),
        )

    def run_stage(self, fail=None):
        env = dict(os.environ, PYTHON=sys.executable, CI_TMP=str(self.root / "ci-tmp"),
                   P0_TEST_TRACE=str(self.trace))
        env.pop("P0_TEST_FAIL", None)
        if fail:
            env["P0_TEST_FAIL"] = fail
        return subprocess.run(
            ["bash", str(self.root / "scripts/ci/check.sh"), "--only", "phone-p0-conformance"],
            cwd=self.root, env=env, capture_output=True, text=True,
        )

    def assert_fails(self, result, text):
        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, 1, output)
        self.assertIn("FAIL  phone-p0-conformance", output)
        self.assertIn(text, output)
        self.assertNotIn("CI GATE: PASS", output)

    def test_stage_runs_real_extractor_and_both_mutation_suites(self):
        result = self.run_stage()
        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, output)
        self.assertIn("contracts up to date", output)
        self.assertIn("CI GATE: PASS", output)
        self.assertEqual(self.trace.read_text().splitlines(), [
            "catalog_check", "bridge_check", "gateway_check", "fixture_check", "host_check",
            "platform_check", "ui_check", "trajectory_norm", "extractor_tests",
            "page_structure_check", "page_checker_tests",
        ])

    def test_missing_or_stale_page_contract_fails_the_actual_stage(self):
        contract = self.root / "spec/ui/v1/pages/fixture.json"
        contract.unlink()
        self.assert_fails(self.run_stage(), "stale contracts")

    def test_new_source_page_fails_the_actual_stage(self):
        self.write("examples/probe-app/PhoneDSHProbe/NewPage.swift",
                   "struct NewPage: View { var body: some View { Text(\"new\") } }\n")
        self.assert_fails(self.run_stage(), "stale contracts")

    def test_changed_source_fails_the_actual_stage(self):
        source = self.root / "examples/probe-app/PhoneDSHProbe/FixturePage.swift"
        source.write_text(source.read_text(encoding="utf-8").replace("Continue", "Changed"), encoding="utf-8")
        self.assert_fails(self.run_stage(), "stale contracts")

    def test_missing_hand_registered_chrome_fails_the_actual_stage(self):
        (self.root / "spec/ui/v1/pages/home-drawer.json").unlink()
        self.assert_fails(self.run_stage(), "home-drawer.json")

    def test_missing_extractor_fails_not_skips(self):
        (self.root / "spec/ui/v1/tools/extract_ios_pages.py").unlink()
        self.assert_fails(self.run_stage(), "missing page extractor")

    def test_missing_extractor_mutation_suite_fails_not_zero_tests(self):
        (self.root / "spec/ui/v1/tools/test_extract_ios_pages.py").unlink()
        self.assert_fails(self.run_stage(), "missing page extractor tests")

    def test_empty_extractor_mutation_suite_fails_not_zero_tests(self):
        self.write("spec/ui/v1/tools/test_extract_ios_pages.py", "import unittest\n")
        self.assert_fails(self.run_stage(), "PageSourceCompletenessTests")

    def test_extractor_mutation_suite_failure_propagates(self):
        self.assert_fails(self.run_stage("extractor_tests"), "test_extractor_suite_was_run")

    def test_existing_trajectory_failure_stays_fatal(self):
        self.assert_fails(self.run_stage("trajectory_norm"), "CI GATE: FAIL")

    def test_failed_precheck_does_not_hide_later_checks(self):
        result = self.run_stage("ui_check")
        self.assert_fails(result, "CI GATE: FAIL")
        output = result.stdout + result.stderr
        self.assertIn("contracts up to date", output)
        self.assertEqual(self.trace.read_text().splitlines(), [
            "catalog_check", "bridge_check", "gateway_check", "fixture_check", "host_check",
            "platform_check", "ui_check", "trajectory_norm", "extractor_tests",
            "page_structure_check", "page_checker_tests",
        ])

    def test_each_existing_precheck_failure_is_fatal(self):
        for label in ("catalog_check", "bridge_check", "gateway_check", "fixture_check",
                      "host_check", "platform_check", "ui_check", "trajectory_norm"):
            with self.subTest(checker=label):
                self.assert_fails(self.run_stage(label), "CI GATE: FAIL")

    def test_missing_existing_precheck_is_fatal(self):
        (self.root / "spec/v1/tools/catalog_check.py").unlink()
        result = self.run_stage()
        self.assert_fails(result, "missing catalog checker")
        self.assertIn("extractor_tests", self.trace.read_text().splitlines())

    def test_missing_existing_trajectory_is_fatal(self):
        (self.root / "spec/v1/tools/trajectory_norm.py").unlink()
        self.assert_fails(self.run_stage(), "trajectory_norm.py")

    def test_existing_parity_checker_failure_stays_fatal(self):
        self.assert_fails(self.run_stage("page_structure_check"), "CI GATE: FAIL")

    def test_existing_parity_mutation_suite_failure_stays_fatal(self):
        self.assert_fails(self.run_stage("page_checker_tests"), "test_page_checker_suite")

    def test_missing_existing_parity_mutation_suite_fails(self):
        (self.root / "spec/ui/v1/tools/test_page_structure_check.py").unlink()
        self.assert_fails(self.run_stage(), "missing page-structure tests")


if __name__ == "__main__":
    unittest.main()
