#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Offline regressions for the Bot eval catalog/plan/gate layer.

Stdlib-only, no Worker and no model. The live self-check is
``eval.sh --catalog selftest.json``; these tests make the mechanical gate
itself testable, including the "mutate one assertion and the gate must fail"
case.
"""

from __future__ import annotations

import copy
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import eval_catalog as catalog  # noqa: E402


def minimal_catalog(**overrides):
    document = {
        "version": 1,
        "scenarios": [
            {
                "id": "T-1",
                "title": "test",
                "budget": {"max_minutes": 2, "max_model_requests": 5},
                "actions": [{"type": "user_message", "text": "hello"}],
                "assertions": [{"type": "reply_contains", "value": "hi"}],
            }
        ],
    }
    document.update(overrides)
    return document


class CatalogValidationTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="bot-eval-catalog-"))
        self.fixtures = self.root / "fixtures"
        fixture = self.fixtures / "selftest/files"
        fixture.mkdir(parents=True)
        (fixture / "a.txt").write_text("fixture\n", encoding="utf-8")

    def tearDown(self):
        shutil.rmtree(self.root, ignore_errors=True)

    def test_minimal_catalog_is_valid(self):
        self.assertEqual(catalog.validate_catalog(minimal_catalog(), self.fixtures), [])

    def test_unknown_key_is_rejected(self):
        document = minimal_catalog()
        document["scenarios"][0]["typo"] = True
        self.assertTrue(catalog.validate_catalog(document, self.fixtures))

    def test_unknown_action_and_assertion_are_rejected(self):
        document = minimal_catalog()
        document["scenarios"][0]["actions"].append({"type": "teleport"})
        self.assertTrue(catalog.validate_catalog(document, self.fixtures))
        document = minimal_catalog()
        document["scenarios"][0]["assertions"].append({"type": "always_true"})
        self.assertTrue(catalog.validate_catalog(document, self.fixtures))

    def test_duplicate_id_is_rejected(self):
        document = minimal_catalog()
        document["scenarios"].append(copy.deepcopy(document["scenarios"][0]))
        self.assertTrue(catalog.validate_catalog(document, self.fixtures))

    def test_missing_budget_is_rejected_for_runnable_scenario(self):
        document = minimal_catalog()
        document["scenarios"][0].pop("budget")
        self.assertTrue(catalog.validate_catalog(document, self.fixtures))

    def test_workspace_escape_is_rejected(self):
        document = minimal_catalog()
        document["scenarios"][0]["workspace"] = {"files": {"../escape.txt": "x"}}
        self.assertTrue(catalog.validate_catalog(document, self.fixtures))

    def test_unknown_bot_alias_is_rejected(self):
        document = minimal_catalog()
        document["scenarios"][0]["actions"].append({"type": "user_message", "bot": "ghost", "text": "hi"})
        self.assertTrue(catalog.validate_catalog(document, self.fixtures))

    def test_fixture_must_exist(self):
        document = minimal_catalog()
        document["scenarios"][0]["workspace"] = {"fixture": "missing"}
        self.assertTrue(catalog.validate_catalog(document, self.fixtures))

    def test_selftest_only_fields(self):
        document = minimal_catalog()
        document["scenarios"][0]["expect"] = "fail"
        self.assertTrue(catalog.validate_catalog(document, self.fixtures, selftest=False))
        document["selftest"] = True
        self.assertEqual(catalog.validate_catalog(document, self.fixtures, selftest=True), [])

    def test_approval_count_needs_exactly_one_bound(self):
        document = minimal_catalog()
        document["scenarios"][0]["assertions"].append({"type": "approval_count"})
        self.assertTrue(catalog.validate_catalog(document, self.fixtures))
        document["scenarios"][0]["assertions"][-1] = {"type": "approval_count", "equals": 1, "max": 2}
        self.assertTrue(catalog.validate_catalog(document, self.fixtures))

    def test_tool_surface_needs_a_non_empty_direction(self):
        document = minimal_catalog()
        document["scenarios"][0]["assertions"] = [{"type": "tool_surface"}]
        self.assertTrue(catalog.validate_catalog(document, self.fixtures))
        document["scenarios"][0]["assertions"] = [
            {"type": "tool_surface", "present": [], "absent": []}]
        self.assertTrue(catalog.validate_catalog(document, self.fixtures))
        document["scenarios"][0]["assertions"] = [
            {"type": "tool_surface", "present": ["bash"], "absent": []}]
        self.assertTrue(catalog.validate_catalog(document, self.fixtures))
        document["scenarios"][0]["assertions"] = [
            {"type": "tool_surface", "present": ["bash"], "absent": ["subagent"]}]
        self.assertEqual(catalog.validate_catalog(document, self.fixtures), [])

    def test_tool_surface_session_and_exactly(self):
        document = minimal_catalog()
        document["scenarios"][0]["assertions"] = [{
            "type": "tool_surface", "session": "verifier",
            "exactly": ["bash", "glob", "grep", "read"],
        }]
        self.assertEqual(catalog.validate_catalog(document, self.fixtures), [])
        document["scenarios"][0]["assertions"] = [{
            "type": "tool_surface", "session": "unknown", "present": ["bash"],
        }]
        self.assertTrue(catalog.validate_catalog(document, self.fixtures))
        document["scenarios"][0]["assertions"] = [{
            "type": "tool_surface", "session": "verifier",
            "exactly": ["bash"], "present": ["bash"],
        }]
        self.assertTrue(catalog.validate_catalog(document, self.fixtures))
        document["scenarios"][0]["assertions"] = [{"type": "tool_surface", "exactly": []}]
        self.assertTrue(catalog.validate_catalog(document, self.fixtures))

    def test_memory_assertion_accepts_empty_value_with_a_filter(self):
        # The live assertion matcher contains("") for an empty value and then
        # applies scope/tier/source, so the catalog validator must agree.
        for kind in ("memory_contains", "memory_absent"):
            for filter_name, filter_value in (
                ("scope", "user"), ("tier", "profile"), ("source", "user-turn")
            ):
                document = minimal_catalog()
                document["scenarios"][0]["assertions"] = [{
                    "type": kind, "value": "", filter_name: filter_value,
                }]
                self.assertEqual(
                    catalog.validate_catalog(document, self.fixtures), [],
                    f"{kind} with empty value + {filter_name} must be valid")

    def test_memory_assertion_rejects_empty_value_without_a_filter(self):
        for kind in ("memory_contains", "memory_absent"):
            document = minimal_catalog()
            document["scenarios"][0]["assertions"] = [{"type": kind, "value": ""}]
            self.assertTrue(catalog.validate_catalog(document, self.fixtures))

    def test_memory_assertion_still_requires_value(self):
        for kind in ("memory_contains", "memory_absent"):
            document = minimal_catalog()
            document["scenarios"][0]["assertions"] = [{
                "type": kind, "source": "user-turn",
            }]
            self.assertTrue(catalog.validate_catalog(document, self.fixtures))


class PlanTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="bot-eval-plan-"))
        self.fixtures = self.root / "fixtures"
        fixture = self.fixtures / "selftest/files"
        fixture.mkdir(parents=True)
        (fixture / "a.txt").write_text("fixture\n", encoding="utf-8")

    def tearDown(self):
        shutil.rmtree(self.root, ignore_errors=True)

    def write(self, document):
        path = self.root / "catalog.json"
        path.write_text(json.dumps(document), encoding="utf-8")
        return path

    def test_turns_become_user_messages_and_perturbation_inserts_restart(self):
        document = minimal_catalog()
        document["scenarios"][0]["turns"] = [{"prompt": "one"}, {"prompt": "two"}]
        document["scenarios"][0]["actions"] = []
        document["scenarios"][0]["perturbations"] = [
            {"at": "after_turn:1", "kind": "planned_restart"}
        ]
        plan = catalog.build_plan(self.write(document), None, 1, "mock",
                                  self.root / "results", self.fixtures, False)
        actions = plan["scenarios"][0]["actions"]
        self.assertEqual([action["type"] for action in actions],
                         ["user_message", "restart_worker", "user_message"])
        self.assertTrue(all(action.get("bot") == "main" for action in actions if action["type"] == "user_message"))

    def test_unsupported_perturbation_marks_skip(self):
        document = minimal_catalog()
        document["scenarios"][0]["perturbations"] = [
            {"at": "minute:1", "kind": "park_resume"}
        ]
        plan = catalog.build_plan(self.write(document), None, 1, "mock",
                                  self.root / "results", self.fixtures, False)
        self.assertIn("perturbation", plan["scenarios"][0]["skip"])

    def test_only_selection_and_repeat_budget(self):
        document = minimal_catalog()
        document["scenarios"][0]["id"] = "T-1"
        document["scenarios"].append({
            "id": "T-2",
            "budget": {"max_minutes": 2, "max_model_requests": 5},
            "actions": [{"type": "user_message", "text": "two"}],
            "assertions": [{"type": "reply_contains", "value": "two"}],
        })
        plan = catalog.build_plan(self.write(document), "T-2", 3, "mock",
                                  self.root / "results", self.fixtures, False)
        self.assertEqual([scenario["id"] for scenario in plan["scenarios"]], ["T-2"])
        self.assertEqual(plan["batch_budget"]["max_minutes"], 6)
        self.assertEqual(plan["batch_budget"]["max_model_requests"], 15)
        with self.assertRaises(catalog.CatalogError):
            catalog.build_plan(self.write(document), "missing", 1, "mock",
                               self.root / "results", self.fixtures, False)

    def test_batch_ceiling_is_enforced(self):
        document = minimal_catalog(budget={"max_minutes": 1, "max_model_requests": 5})
        with self.assertRaises(catalog.CatalogError):
            catalog.build_plan(self.write(document), None, 1, "mock",
                               self.root / "results", self.fixtures, False)

    def test_selftest_defaults_expect_ok(self):
        document = minimal_catalog(selftest=True)
        plan = catalog.build_plan(self.write(document), None, 1, "mock",
                                  self.root / "results", self.fixtures, True)
        self.assertTrue(plan["scenarios"][0]["assertions"][0]["expect_ok"])


class GateTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="bot-eval-gate-"))
        self.fixtures = self.root / "fixtures"
        fixture = self.fixtures / "selftest/files"
        fixture.mkdir(parents=True)
        (fixture / "a.txt").write_text("fixture\n", encoding="utf-8")
        self.catalog_path = self.root / "catalog.json"

    def tearDown(self):
        shutil.rmtree(self.root, ignore_errors=True)

    def make_plan(self, document, selftest=False):
        self.catalog_path.write_text(json.dumps(document), encoding="utf-8")
        results = self.root / "results"
        plan = catalog.build_plan(self.catalog_path, None, 1, "mock",
                                  results, self.fixtures, selftest)
        return plan, results

    def write_evidence(self, results, plan, report_overrides=None,
                       assertion_override=None, skip_reason=None):
        for scenario in plan["scenarios"]:
            directory = results / scenario["id"]
            directory.mkdir(parents=True, exist_ok=True)
            for name in ("transcript.jsonl", "bot-events.jsonl"):
                (directory / name).write_text("", encoding="utf-8")
            (directory / "workspace.tar").write_text("x", encoding="utf-8")
            if scenario.get("skip") or skip_reason:
                report = {
                    "id": scenario["id"], "status": "SKIP", "run_status": "NOT_RUN",
                    "expectation_met": False, "upstream": "mock", "expect": scenario["expect"],
                    "repeat": plan["repeat"], "repeats": [],
                    "reason": skip_reason or scenario.get("skip") or "skipped",
                }
            else:
                expected_fail = scenario["expect"] == "fail"
                assertions = []
                for assertion in scenario["assertions"]:
                    ok = bool(assertion.get("expect_ok", True)) if not expected_fail else False
                    if assertion_override is not None:
                        ok = assertion_override(assertion, ok)
                    assertions.append({
                        "type": assertion["type"], "ok": ok,
                        "expect_ok": assertion.get("expect_ok", True),
                        "bot": assertion.get("bot", "main"), "detail": "synthetic",
                    })
                report = {
                    "id": scenario["id"],
                    "status": "PASS",
                    "run_status": "FAIL" if expected_fail else "PASS",
                    "expectation_met": True,
                    "upstream": "mock",
                    "expect": scenario["expect"],
                    "repeat": plan["repeat"],
                    "repeats": [{
                        "index": 1,
                        "status": "FAIL" if expected_fail else "PASS",
                        "actions": [
                            {"index": action.get("index", i), "type": action["type"],
                             "status": "ok"}
                            for i, action in enumerate(scenario["actions"])
                        ],
                        "assertions": assertions,
                        "usage": {"model_requests": 0, "wall_s": 0.0},
                    }],
                    "usage": {"model_requests": 0, "wall_s": 0.0},
                }
            if report_overrides:
                report.update(report_overrides)
            (directory / "report.json").write_text(json.dumps(report), encoding="utf-8")
        return plan

    def test_gate_passes_for_pass_and_controlled_fail(self):
        document = {
            "version": 1,
            "selftest": True,
            "scenarios": [
                {
                    "id": "T-PASS",
                    "budget": {"max_minutes": 2, "max_model_requests": 5},
                    "actions": [{"type": "user_message", "text": "hello"}],
                    "assertions": [{"type": "reply_contains", "value": "hi"}],
                },
                {
                    "id": "T-FAIL",
                    "expect": "fail",
                    "budget": {"max_minutes": 2, "max_model_requests": 5},
                    "actions": [{"type": "user_message", "text": "hello"}],
                    "assertions": [{"type": "reply_contains", "value": "nope", "expect_ok": False}],
                },
            ],
        }
        plan, results = self.make_plan(document, selftest=True)
        self.write_evidence(results, plan)
        summary = catalog.check_plan(plan, results)
        self.assertEqual(summary["gate"], "PASS", summary["errors"])

    def test_gate_rejects_a_mutated_assertion(self):
        document = {
            "version": 1,
            "scenarios": [{
                "id": "T-PASS",
                "budget": {"max_minutes": 2, "max_model_requests": 5},
                "actions": [{"type": "user_message", "text": "hello"}],
                "assertions": [{"type": "reply_contains", "value": "hi"}],
            }],
        }
        plan, results = self.make_plan(document)
        self.write_evidence(
            results, plan,
            assertion_override=lambda assertion, ok: False)
        summary = catalog.check_plan(plan, results)
        self.assertEqual(summary["gate"], "FAIL")
        self.assertTrue(any("reply_contains" in error for error in summary["errors"]))

    def test_product_skip_is_not_run_and_fails_the_gate(self):
        document = {
            "version": 1,
            "scenarios": [{
                "id": "T-SKIP",
                "skip": "missing seam",
                "budget": {"max_minutes": 1, "max_model_requests": 1},
                "actions": [{"type": "user_message", "text": "hello"}],
                "assertions": [{"type": "reply_contains", "value": "hi"}],
            }],
        }
        plan, results = self.make_plan(document)
        self.write_evidence(results, plan)
        summary = catalog.check_plan(plan, results)
        self.assertEqual(summary["gate"], "FAIL")
        self.assertTrue(any("NOT_RUN" in error for error in summary["errors"]))

    def test_selftest_skip_is_reported_but_does_not_fail_the_gate(self):
        document = {
            "version": 1,
            "selftest": True,
            "scenarios": [{
                "id": "T-SKIP",
                "skip": "reported seam",
                "budget": {"max_minutes": 1, "max_model_requests": 1},
                "actions": [{"type": "user_message", "text": "hello"}],
                "assertions": [{"type": "reply_contains", "value": "hi"}],
            }],
        }
        plan, results = self.make_plan(document, selftest=True)
        self.write_evidence(results, plan)
        summary = catalog.check_plan(plan, results)
        self.assertEqual(summary["gate"], "PASS", summary["errors"])
        self.assertEqual(summary["scenarios"][0]["gate"], "SKIP")

    def test_report_id_mismatch_fails(self):
        document = {
            "version": 1,
            "scenarios": [{
                "id": "T-PASS",
                "budget": {"max_minutes": 2, "max_model_requests": 5},
                "actions": [{"type": "user_message", "text": "hello"}],
                "assertions": [{"type": "reply_contains", "value": "hi"}],
            }],
        }
        plan, results = self.make_plan(document)
        self.write_evidence(results, plan, report_overrides={"id": "OTHER"})
        summary = catalog.check_plan(plan, results)
        self.assertEqual(summary["gate"], "FAIL")

    def test_shell_entry_has_no_syntax_errors(self):
        result = subprocess.run(
            ["bash", "-n", str(HERE / "eval.sh")],
            capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
