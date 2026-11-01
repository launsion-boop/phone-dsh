#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Mutation tests for the normative scenario-catalog checker.

Every test mutates a deep copy of the real catalog in memory; the checked-in
data is never written. The tests pin both directions of the contract: the
current catalog and selftest must pass, and each named mutation must be
rejected with a diagnostic that names the defect.
"""

from __future__ import annotations

import copy
import subprocess
import sys
import unittest
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parent
ROOT = TOOLS_DIR.parents[2]
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

import catalog_check  # noqa: E402 - the tool lives beside this test


class CatalogCheckTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.spec_golden = catalog_check.spec_module(ROOT)
        cls.catalog_schema = cls.spec_golden.load_json(
            ROOT / catalog_check.CATALOG_SCHEMA_REL
        )
        cls.assertion_schema = cls.spec_golden.load_json(
            ROOT / catalog_check.ASSERTION_SCHEMA_REL
        )
        cls.catalog = cls.spec_golden.load_json(ROOT / catalog_check.CATALOG_REL)
        cls.selftest = cls.spec_golden.load_json(ROOT / catalog_check.SELFTEST_REL)
        cls.runner_types, runner_findings = catalog_check.runner_dispatch_types(ROOT)
        assert not runner_findings, runner_findings

    def findings_for(self, mutate):
        document = copy.deepcopy(self.catalog)
        mutate(document)
        return catalog_check.check_catalog(
            document,
            self.catalog_schema,
            self.assertion_schema,
            self.spec_golden,
        )

    def assert_rejected(self, mutate, needle):
        findings = self.findings_for(mutate)
        self.assertTrue(findings, "mutation was accepted")
        joined = "\n".join(findings)
        self.assertIn(needle, joined)

    def test_current_catalog_passes(self):
        findings = catalog_check.check_catalog(
            self.catalog,
            self.catalog_schema,
            self.assertion_schema,
            self.spec_golden,
        )
        self.assertEqual([], findings)

    def test_current_selftest_passes(self):
        findings = catalog_check.check_selftest(
            self.selftest,
            self.catalog_schema,
            self.spec_golden,
            self.assertion_schema,
            self.runner_types,
        )
        self.assertEqual([], findings)

    def test_selftest_unknown_assertion_type_is_rejected(self):
        document = copy.deepcopy(self.selftest)
        document["scenarios"][0]["assertions"].append(
            {"type": "not_a_runner_type"}
        )
        findings = catalog_check.check_selftest(
            document,
            self.catalog_schema,
            self.spec_golden,
            self.assertion_schema,
            self.runner_types,
        )
        self.assertTrue(findings)
        self.assertIn("unknown runner assertion type", "\n".join(findings))

    def test_duplicate_scenario_id_is_rejected(self):
        def mutate(document):
            document["scenarios"][1]["id"] = document["scenarios"][0]["id"]

        self.assert_rejected(mutate, "duplicate scenario id")

    def test_unknown_assertion_type_is_rejected(self):
        def mutate(document):
            document["scenarios"][0]["assertions"][0]["type"] = "not_a_type"

        self.assert_rejected(mutate, "unknown assertion type")

    def test_absolute_workspace_path_is_rejected(self):
        def mutate(document):
            document["scenarios"][0]["workspace"]["files"]["/tmp/escape.txt"] = "x"

        self.assert_rejected(mutate, "absolute path")

    def test_parent_segment_workspace_path_is_rejected(self):
        def mutate(document):
            document["scenarios"][0]["workspace"]["files"]["../escape.txt"] = "x"

        self.assert_rejected(mutate, "must not contain '..'")

    def test_empty_turns_is_rejected(self):
        def mutate(document):
            document["scenarios"][0]["turns"] = []

        self.assert_rejected(mutate, "fewer than 1")

    def test_negative_turn_count_bound_is_rejected(self):
        def mutate(document):
            for scenario in document["scenarios"]:
                for assertion in scenario["assertions"]:
                    if assertion["type"] == "turn_count_lte":
                        assertion["max"] = -1
                        return
            self.fail("catalog has no turn_count_lte assertion")

        self.assert_rejected(mutate, "below 0")

    def test_missing_required_scenario_member_is_rejected(self):
        def mutate(document):
            del document["scenarios"][0]["title"]

        self.assert_rejected(mutate, "missing required member 'title'")

    def test_missing_required_run_plan_member_is_rejected(self):
        def mutate(document):
            del document["run_plan"]["lane_plan"]

        self.assert_rejected(mutate, "missing required member 'lane_plan'")

    def test_missing_required_assertion_member_is_rejected(self):
        def mutate(document):
            for scenario in document["scenarios"]:
                for assertion in scenario["assertions"]:
                    if assertion["type"] == "file_contains":
                        del assertion["value"]
                        return
            self.fail("catalog has no file_contains assertion")

        self.assert_rejected(mutate, "missing required member 'value'")

    def test_lane_plan_omission_is_rejected(self):
        def mutate(document):
            document["run_plan"]["lane_plan"][0]["scenario_ids"].pop()

        self.assert_rejected(mutate, "run_plan.lane_plan omits scenario id")

    def test_budget_sum_drift_is_rejected(self):
        def mutate(document):
            document["run_plan"]["budget"]["serial_max_minutes"] += 1

        self.assert_rejected(mutate, "run_plan.budget.serial_max_minutes")

    def test_unknown_optional_scenario_member_is_accepted(self):
        def mutate(document):
            document["scenarios"][0]["future_optional"] = {"note": "additive"}

        self.assertEqual([], self.findings_for(mutate))

    def test_unknown_assertion_member_is_rejected(self):
        def mutate(document):
            document["scenarios"][0]["assertions"][0]["future_optional"] = True

        self.assert_rejected(mutate, "unexpected member")

    def test_assertion_schema_declares_the_eight_catalog_types(self):
        expected = (
            "file_contains",
            "file_exists",
            "file_regex",
            "no_console_error",
            "no_file",
            "restart_recovered",
            "turn_count_lte",
            "workspace_command",
        )
        self.assertEqual(expected, catalog_check.assertion_types(self.assertion_schema))
        variants = catalog_check.assertion_variants(self.assertion_schema)
        required_by_type = {
            "file_contains": {"type", "path", "value"},
            "file_exists": {"type", "path"},
            "file_regex": {"type", "path", "value"},
            "no_console_error": {"type"},
            "no_file": {"type", "path"},
            "restart_recovered": {"type"},
            "turn_count_lte": {"type", "max"},
            "workspace_command": {"type", "command"},
        }
        for name, variant in variants.items():
            self.assertEqual(required_by_type[name], set(variant["required"]))
            self.assertIs(False, variant["additionalProperties"])

    def test_schemas_stay_inside_the_supported_keyword_subset(self):
        for label, schema in (
            (catalog_check.CATALOG_SCHEMA_REL, self.catalog_schema),
            (catalog_check.ASSERTION_SCHEMA_REL, self.assertion_schema),
        ):
            findings = catalog_check.schema_keyword_findings(schema, str(label))
            self.assertEqual([], findings)

    def test_runner_handler_cross_check_passes(self):
        findings, detail = catalog_check.check_handlers(
            ROOT, catalog_check.assertion_types(self.assertion_schema)
        )
        self.assertEqual([], findings)
        self.assertIn("ScenarioAssertionGate.swift", detail)

    def test_runner_handler_cross_check_rejects_unknown_type(self):
        findings, _ = catalog_check.check_handlers(ROOT, {"not_a_runner_type"})
        self.assertTrue(findings)

    def test_cli_exits_zero_and_prints_statistics(self):
        completed = subprocess.run(
            [
                sys.executable,
                str(TOOLS_DIR / "catalog_check.py"),
                "--root",
                str(ROOT),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=180,
        )
        self.assertEqual(
            0,
            completed.returncode,
            "stdout:\n{}\nstderr:\n{}".format(
                completed.stdout, completed.stderr
            ),
        )
        self.assertIn("scenarios=56", completed.stdout)
        self.assertIn("assertions (catalog):", completed.stdout)
        self.assertIn("total=475", completed.stdout)
        self.assertIn("catalog_check: PASS", completed.stdout)


if __name__ == "__main__":
    unittest.main()
