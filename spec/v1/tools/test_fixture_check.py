#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Mutation tests for the fixture checker.

Every test runs the checker in process on a temporary copy of the two fixture families and their
schemas, mutates exactly one thing and requires a specific failure. The real tree is never modified.

The baseline tests also pin the deliverable: the number of fixtures, the verb coverage and the
coverage matrix output the checker prints.
"""

from __future__ import annotations

import importlib.util
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parent
SPEC_DIR = TOOLS_DIR.parent
FIXTURE_CHECK = TOOLS_DIR / "fixture_check.py"
PERTURBATIONS = ("golden", "perturbations")
UPSTREAM = ("golden", "upstream")

# The two families are independent: a mutation is applied to one file of one family at a time.
FAMILY_DIRS = ("golden/perturbations", "golden/upstream", "schema")


def load_checker():
    loader = importlib.util.spec_from_file_location("fixture_check_under_test", FIXTURE_CHECK)
    module = importlib.util.module_from_spec(loader)
    loader.loader.exec_module(module)
    return module


CHECKER = load_checker()


class FixtureCheckerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for relative in FAMILY_DIRS:
            shutil.copytree(
                SPEC_DIR / relative,
                self.root / "spec/v1" / relative,
                ignore=shutil.ignore_patterns("__pycache__", "*.pyc"),
            )

    # -- helpers ---------------------------------------------------------

    def fixture_path(self, *parts: str) -> Path:
        return self.root / "spec/v1" / "golden" / Path(*parts)

    def load(self, *parts: str):
        return json.loads(self.fixture_path(*parts).read_text(encoding="utf-8"))

    def write(self, document, *parts: str) -> None:
        self.fixture_path(*parts).write_text(
            json.dumps(document, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
        )

    def mutate(self, family: str, name: str, change) -> None:
        document = self.load(family, name)
        change(document)
        self.write(document, family, name)

    def result(self):
        return CHECKER.run(self.root)

    def assert_rejected(self, needle: str) -> None:
        result = self.result()
        self.assertTrue(result.errors, "the checker accepted a mutated tree")
        messages = "\n".join(message for _, message in result.errors)
        self.assertIn(needle, messages, "unexpected failure messages:\n" + messages)

    # -- baseline --------------------------------------------------------

    def test_clean_tree_passes_with_full_verb_coverage(self) -> None:
        result = self.result()
        self.assertEqual(result.errors, [], "the checked-in fixtures must validate")
        self.assertEqual(result.count, 23, "16 perturbation and 7 upstream fixtures are expected")
        for verb in CHECKER.REQUIRED_VERBS:
            self.assertEqual(result.verbs[verb] > 0, True, "verb {} is not covered".format(verb))

    def test_cli_prints_one_line_per_fixture_and_the_coverage_matrix(self) -> None:
        completed = subprocess.run(
            [sys.executable, str(FIXTURE_CHECK), "--root", str(self.root)],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        lines = completed.stdout.splitlines()
        fixture_lines = [line for line in lines if line.startswith("ok spec/v1/golden/")]
        self.assertEqual(len(fixture_lines), 23)
        self.assertIn("coverage matrix: perturbation verb x fixture count", lines)
        self.assertTrue(
            any("all 10 required verb(s) covered" in line for line in lines),
            "the coverage matrix must report full verb coverage",
        )
        self.assertTrue(any("23 fixture(s) checked, 0 error(s)" in line for line in lines))

    def test_cli_fails_with_exit_code_one_on_a_bad_fixture(self) -> None:
        self.mutate("perturbations", "kill-9-after-write.json", lambda doc: doc.update(verb="nope"))
        completed = subprocess.run(
            [sys.executable, str(FIXTURE_CHECK), "--root", str(self.root)],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(completed.returncode, 1)
        self.assertIn("FAIL spec/v1/golden/perturbations/kill-9-after-write.json", completed.stdout)

    # -- perturbation identity and vocabulary ----------------------------

    def test_duplicate_id_is_rejected(self) -> None:
        duplicate = self.load("perturbations", "kill-9-after-write.json")
        self.write(duplicate, "perturbations", "kill-9-after-write-copy.json")
        self.assert_rejected("is already used by")

    def test_file_name_must_equal_the_id(self) -> None:
        self.mutate("perturbations", "kill-9-after-write.json", lambda doc: doc.update(id="renamed"))
        self.assert_rejected("does not equal id")

    def test_unknown_verb_is_rejected(self) -> None:
        self.mutate("perturbations", "kill-9-after-write.json", lambda doc: doc.update(verb="kill_10"))
        self.assert_rejected("not in enum")

    def test_state_outside_the_nine_d14_states_is_rejected(self) -> None:
        self.mutate(
            "perturbations",
            "kill-9-after-write.json",
            lambda doc: doc["expected"].update(state="Stopped"),
        )
        self.assert_rejected("not in enum")

    def test_invalid_durability_level_is_rejected(self) -> None:
        self.mutate(
            "perturbations",
            "kill-9-after-write.json",
            lambda doc: doc["expected"].update(durability_level="level_3"),
        )
        self.assert_rejected("not in enum")

    # -- timeline --------------------------------------------------------

    def test_empty_timeline_is_rejected(self) -> None:
        self.mutate("perturbations", "kill-9-after-write.json", lambda doc: doc.update(timeline=[]))
        self.assert_rejected("fewer than 1 items")

    def test_timeline_step_without_at_is_rejected(self) -> None:
        def drop_at(doc):
            del doc["timeline"][1]["at"]

        self.mutate("perturbations", "kill-9-after-write.json", drop_at)
        self.assert_rejected("missing required member 'at'")

    def test_wall_clock_at_is_rejected(self) -> None:
        def wall_clock(doc):
            doc["timeline"][1]["at"] = 1767225600000

        self.mutate("perturbations", "kill-9-after-write.json", wall_clock)
        self.assert_rejected("above 3600000")

    def test_timeline_that_starts_late_is_rejected(self) -> None:
        def shift(doc):
            for step in doc["timeline"]:
                step["at"] += 100

        self.mutate("perturbations", "kill-9-after-write.json", shift)
        self.assert_rejected("instead of 0")

    # -- expected assertions ---------------------------------------------

    def test_expected_without_a_decidable_assertion_is_rejected(self) -> None:
        # Both schemas already require one decidable member (the perturbation state and the
        # upstream retry object), so this is the semantic backstop: a fixture that carries only
        # "unmeasured" members must fail even when a schema is relaxed.
        document = {
            "evidence_level": "swift-test",
            "expected": {
                "state": "unmeasured",
                "durability_level": "unmeasured",
                "wal_tail": "unmeasured",
                "journal_gap": "unmeasured",
                "surfaced_to_user": "unmeasured",
            },
        }
        problems = []
        CHECKER.check_evidence(document, CHECKER.PERTURBATION_ASSERTIONS, problems)
        self.assertIn("no machine-checkable assertion", "\n".join(problems))

    def test_asserted_member_without_evidence_is_rejected(self) -> None:
        def drop_evidence(doc):
            del doc["expected"]["field_evidence"]["wal_tail"]

        self.mutate("perturbations", "kill-9-after-write.json", drop_evidence)
        self.assert_rejected("has no field_evidence entry")

    def test_evidence_level_must_be_the_weakest_assertion(self) -> None:
        def weaken_one(doc):
            doc["expected"]["field_evidence"]["state"] = "NEW"
            doc["new_reason"] = "the mutation claims a weaker source for one member"

        self.mutate("perturbations", "kill-9-after-write.json", weaken_one)
        self.assert_rejected("is not the weakest asserted evidence")

    def test_unmeasured_member_cannot_carry_evidence(self) -> None:
        def unmeasured_with_evidence(doc):
            doc["expected"]["wal_tail"] = "unmeasured"

        self.mutate("perturbations", "kill-9-after-write.json", unmeasured_with_evidence)
        self.assert_rejected('is "unmeasured" but field_evidence claims')

    def test_new_without_a_reason_is_rejected(self) -> None:
        def drop_reason(doc):
            del doc["new_reason"]

        self.mutate("perturbations", "force-stop-zero-callback.json", drop_reason)
        self.assert_rejected("new_reason is missing")

    # -- cross-field laws ------------------------------------------------

    def test_journal_gap_and_settlement_reason_must_agree(self) -> None:
        def contradict(doc):
            doc["expected"]["settlement_reason"] = "absent"

        self.mutate("perturbations", "renderer-terminated-orphan-abandoned.json", contradict)
        self.assert_rejected("requires a settlement_reason")

    def test_torn_tail_marker_and_tail_shape_must_agree(self) -> None:
        def contradict(doc):
            doc["expected"]["wal_tail"] = "intact_open_epoch"

        self.mutate("perturbations", "power-loss-torn-tail.json", contradict)
        self.assert_rejected("requires wal_tail truncated_to_last_complete")

    def test_level_two_requires_a_closed_epoch(self) -> None:
        def contradict(doc):
            doc["expected"]["wal_tail"] = "intact_open_epoch"

        self.mutate("perturbations", "drain-deadline-20s.json", contradict)
        self.assert_rejected("requires wal_tail closed_epoch")

    def test_admission_open_outside_running_is_rejected(self) -> None:
        def contradict(doc):
            doc["expected"]["state"] = "Parked"
            doc["expected"]["state_path"] = ["Running", "Parked"]
            doc["expected"]["admission"] = "open"

        self.mutate("perturbations", "kill-9-after-write.json", contradict)
        self.assert_rejected("contradicts budgets.md section 1")

    def test_missing_required_verb_is_rejected(self) -> None:
        self.fixture_path("perturbations", "sigterm-runner-guard.json").unlink()
        self.assert_rejected("required verb 'sigterm' is not covered")

    # -- upstream --------------------------------------------------------

    def test_upstream_status_out_of_range_is_rejected(self) -> None:
        def bad_status(doc):
            doc["script"][0]["status"] = 999

        self.mutate("upstream", "sse-200-tool-use-stream.json", bad_status)
        self.assert_rejected("oneOf")

    def test_upstream_body_chunks_must_be_strings(self) -> None:
        def not_strings(doc):
            doc["script"][0]["body_chunks"] = [1, 2]

        self.mutate("upstream", "sse-200-tool-use-stream.json", not_strings)
        self.assert_rejected("expected ['string']")

    def test_upstream_declared_length_shorter_than_the_body_is_rejected(self) -> None:
        def short(doc):
            doc["script"][0]["declared_content_length"] = 5

        self.mutate("upstream", "connection-interrupted-mid-stream.json", short)
        self.assert_rejected("is shorter than the")

    def test_upstream_short_body_without_the_truncated_marker_is_rejected(self) -> None:
        def no_marker(doc):
            del doc["script"][0]["truncated"]

        self.mutate("upstream", "connection-interrupted-mid-stream.json", no_marker)
        self.assert_rejected("must be marked truncated")

    def test_upstream_retry_delays_must_match_the_attempts(self) -> None:
        def extra_delay(doc):
            doc["expected"]["retry"]["delays_ms"] = [1000, 2000]

        self.mutate("upstream", "retry-500-then-200.json", extra_delay)
        self.assert_rejected("expected 1")

    def test_upstream_stall_beyond_the_scripted_bytes_is_rejected(self) -> None:
        def too_far(doc):
            doc["script"][0]["stall_after_bytes"] = 100000

        self.mutate("upstream", "delivery-stall-timeout.json", too_far)
        self.assert_rejected("exceeds the")

    def test_upstream_call_visible_and_provider_error_must_agree(self) -> None:
        def contradict(doc):
            doc["expected"]["provider_error"] = "none"

        self.mutate("upstream", "connection-interrupted-mid-stream.json", contradict)
        self.assert_rejected("requires provider_error transport_failure")


if __name__ == "__main__":
    unittest.main()
