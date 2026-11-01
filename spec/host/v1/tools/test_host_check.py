#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Mutation tests for ``host_check.py``.

Every test copies the real contract tree to a temporary directory, mutates one
artifact and asserts that the checker reports the expected failure. A passing
copy of the unmutated tree is asserted first, so a mutation test cannot pass
merely because the checker rejects everything.

Run:
    python3 -m unittest discover -s spec/host/v1/tools -p 'test_*.py' -v
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import host_check  # noqa: E402

CONTRACT_DIR = os.path.dirname(HERE)
CHECKER = os.path.join(HERE, "host_check.py")
COPY_IGNORE = shutil.ignore_patterns("__pycache__", "test_*.py")


class ContractTreeCase(unittest.TestCase):
    """One throwaway copy of the contract tree per test."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="pdsh-host-check-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.contract = os.path.join(self.tmp, "v1")
        shutil.copytree(CONTRACT_DIR, self.contract, ignore=COPY_IGNORE)

    # -- helpers ---------------------------------------------------------

    def golden(self, name):
        return os.path.join(self.contract, "golden", name)

    def schema(self, name):
        return os.path.join(self.contract, "schema", name)

    def load(self, path):
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)

    def save(self, path, data):
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(data, handle, indent=2)
            handle.write("\n")

    def mutate(self, path, mutator):
        data = self.load(path)
        mutator(data)
        self.save(path, data)

    def failures(self, trajectory_dir=None):
        reporter = host_check.check_contract(
            self.contract, root=host_check.REPO_ROOT, trajectory_dir=trajectory_dir)
        return [message for messages in reporter.entries.values() for message in messages]

    def assert_reports(self, *needles):
        messages = self.failures()
        self.assertTrue(messages, "the mutated tree was accepted; expected a failure")
        joined = "\n".join(messages)
        for needle in needles:
            self.assertIn(needle, joined)


class PristineTreeTest(ContractTreeCase):
    def test_unmutated_copy_passes(self):
        self.assertEqual([], self.failures())


class SchemaMutationTest(ContractTreeCase):
    def test_missing_required_member_is_rejected(self):
        def drop_kind(wrapper):
            del wrapper["instance"]["kind"]

        self.mutate(self.golden("harness-command-prompt-device-origin.json"), drop_kind)
        self.assert_reports("missing required member 'kind'")

    def test_unknown_kind_is_rejected(self):
        def rename_kind(wrapper):
            wrapper["instance"]["kind"] = "prompt_v2"

        self.mutate(self.golden("harness-command-prompt-device-origin.json"), rename_kind)
        self.assert_reports("matches 0 oneOf variants")

    def test_extra_member_is_rejected(self):
        def add_member(wrapper):
            wrapper["instance"]["priority"] = 3

        self.mutate(self.golden("harness-session-resumed.json"), add_member)
        self.assert_reports("unexpected member 'priority'")

    def test_unsupported_schema_keyword_is_rejected(self):
        def add_ref(schema):
            schema["properties"]["cancel"] = {"$ref": "#/definitions/cancel"}

        self.mutate(self.schema("harness-capabilities.schema.json"), add_ref)
        self.assert_reports("unsupported keyword '$ref'")

    def test_open_oneof_variant_is_rejected(self):
        def open_variant(schema):
            schema["oneOf"][0].pop("additionalProperties")

        self.mutate(self.schema("device-receipt.schema.json"), open_variant)
        self.assert_reports("variant must be closed")


class CapabilityMutationTest(ContractTreeCase):
    def test_misspelled_device_capability_is_rejected(self):
        def misspell(wrapper):
            caps = wrapper["instance"]["capabilities"]
            caps["audio.ttss"] = caps.pop("audio.tts")

        self.mutate(self.golden("device-capabilities-esp32.json"), misspell)
        self.assert_reports("unknown capability name 'audio.ttss'")

    def test_unknown_harness_capability_is_rejected(self):
        def add_capability(wrapper):
            wrapper["instance"]["timeout"] = True

        self.mutate(self.golden("harness-capabilities-dsh-remote.json"), add_capability)
        self.assert_reports("unknown capability name 'timeout'")


class EventKindMappingTest(ContractTreeCase):
    def event_kinds(self):
        return os.path.join(self.contract, "event-kinds.md")

    def rewrite(self, old, new):
        self.rewrite_in(self.event_kinds(), old, new)

    def rewrite_in(self, path, old, new):
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
        self.assertIn(old, text)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(text.replace(old, new, 1))

    def test_mapping_table_misses_a_schema_kind(self):
        self.rewrite("| `tool_call` | `tool/call` | yes |", "")
        self.assert_reports("mapping table misses host kind 'tool_call'")

    def test_mapping_table_cannot_declare_a_kind_the_schema_lacks(self):
        # The failure that started this check: `turn-event` is a UiState node
        # kind (trajectory.md §7), and adding it here would make the crosswalk
        # claim a sixteenth host kind the schema never pins.
        self.rewrite(
            "| `usage` | `assistant/message` | folded | `AM:85-88` (`data.usage`) |",
            "| `usage` | `assistant/message` | folded | `AM:85-88` (`data.usage`) |\n"
            "| `turn-event` | — | none | `spec/v1/trajectory.md` §7 |",
        )
        self.assert_reports("mapping table declares unknown host kind 'turn-event'")

    def test_the_stated_kind_count_must_match_the_table(self):
        self.rewrite("exactly 15 snake_case values", "exactly 14 snake_case values")
        self.assert_reports("claims 14 host kinds, but the mapping table declares 15")

    def test_the_readme_kind_count_must_match_the_table(self):
        readme = os.path.join(self.contract, "README.md")
        self.rewrite_in(readme, "the 15 host kinds", "the 14 host kinds")
        self.assert_reports("claims 14 host kinds, but the mapping table declares 15")

    def test_projection_golden_column_must_match_the_fixture(self):
        self.rewrite("| `question/request` | no |", "| `question/request` | yes |")
        self.assert_reports(
            "projection type 'question/request' is marked golden but no expected fixture uses it")

    def test_expected_fixture_type_must_be_declared(self):
        trajectory = os.path.join(self.tmp, "trajectory")
        shutil.copytree(
            os.path.join(host_check.REPO_ROOT, "spec", "v1", "golden", "trajectory"),
            trajectory,
        )
        with open(os.path.join(trajectory, "chat-basic", "expected.jsonl"), "a",
                  encoding="utf-8") as handle:
            handle.write('{"type":"invented/event"}\n')
        messages = "\n".join(self.failures(trajectory_dir=trajectory))
        self.assertIn(
            "expected fixture type 'invented/event' is neither mapped, synthetic nor not-projected",
            messages,
        )

    def test_missing_crosswalk_document_is_rejected(self):
        os.remove(self.event_kinds())
        self.assert_reports("missing: the three event vocabularies need one crosswalk")


class CapabilityProvisionalTest(ContractTreeCase):
    def test_capability_without_golden_must_be_provisional(self):
        self.mutate(
            self.schema("device-capabilities.schema.json"),
            lambda schema: schema["properties"]["capabilities"]["properties"]["call.hfp"].pop(
                "provisional"),
        )
        self.assert_reports(
            "capability 'call.hfp' has no device golden and is not marked provisional")

    def test_stale_provisional_marker_is_rejected(self):
        self.mutate(
            self.schema("device-capabilities.schema.json"),
            lambda schema: schema["properties"]["capabilities"]["properties"]["audio.tts"].update(
                {"provisional": True}),
        )
        self.assert_reports("capability 'audio.tts' is marked provisional but a device golden uses it")


class GoldenWiringTest(ContractTreeCase):
    def test_golden_pointing_at_absent_schema_is_rejected(self):
        def repoint(wrapper):
            wrapper["schema"] = "schema/absent.schema.json"

        self.mutate(self.golden("harness-goal-blocked.json"), repoint)
        self.assert_reports("unknown schema 'schema/absent.schema.json'")

    def test_golden_escaping_the_tree_is_rejected(self):
        def escape(wrapper):
            wrapper["schema"] = "../../etc/passwd"

        self.mutate(self.golden("harness-goal-blocked.json"), escape)
        self.assert_reports("schema must be a path under schema/")

    def test_unreferenced_schema_is_rejected(self):
        os.remove(self.golden("device-receipt-applied.json"))
        os.remove(self.golden("device-receipt-failed-expired.json"))
        self.assert_reports("no golden instance references this schema")


class SequenceMutationTest(ContractTreeCase):
    def test_duplicate_seq_is_rejected(self):
        def duplicate(wrapper):
            wrapper["instance"][3]["seq"] = wrapper["instance"][2]["seq"]

        self.mutate(self.golden("event-sequence-session.json"), duplicate)
        self.assert_reports("duplicate durable seq 3")

    def test_dense_gap_is_rejected(self):
        def drop_event(wrapper):
            wrapper["instance"].pop(2)

        self.mutate(self.golden("event-sequence-session.json"), drop_event)
        self.assert_reports("dense sequence must step by 1 after seq 2, found 4")

    def test_missing_seq_on_durable_event_is_rejected(self):
        def drop_seq(wrapper):
            del wrapper["instance"][1]["seq"]

        self.mutate(self.golden("event-sequence-session.json"), drop_seq)
        self.assert_reports("matches 0 oneOf variants")

    def test_resume_expectation_is_checked(self):
        def lie(wrapper):
            wrapper["resume"]["expect_next_seq"] = 6

        self.mutate(self.golden("event-sequence-session.json"), lie)
        self.assert_reports("resume after seq 4 delivers seq 5, not 6")

    def test_envelope_direction_rule_is_checked(self):
        def wrong_origin(wrapper):
            wrapper["instance"]["origin"] = "phone"

        self.mutate(self.golden("device-envelope-uplink-voice.json"), wrong_origin)
        self.assert_reports("dir 'up' requires origin 'device'")


class CommandLineTest(unittest.TestCase):
    def run_checker(self, root):
        return subprocess.run(
            [sys.executable, CHECKER, "--root", root],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            universal_newlines=True,
            check=False,
        )

    def test_real_tree_exits_zero(self):
        result = self.run_checker(host_check.REPO_ROOT)
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertIn("files checked, 0 error(s)", result.stdout)

    def test_mutated_tree_exits_one(self):
        tmp = tempfile.mkdtemp(prefix="pdsh-host-check-cli-")
        self.addCleanup(shutil.rmtree, tmp, True)
        root = os.path.join(tmp, "repo")
        os.makedirs(os.path.join(root, "spec", "host"))
        shutil.copytree(CONTRACT_DIR, os.path.join(root, "spec", "host", "v1"), ignore=COPY_IGNORE)
        shutil.copytree(
            os.path.join(host_check.REPO_ROOT, "spec", "v1", "golden", "trajectory"),
            os.path.join(root, "spec", "v1", "golden", "trajectory"),
        )
        path = os.path.join(root, "spec", "host", "v1", "golden", "harness-command-cancel.json")
        with open(path, encoding="utf-8") as handle:
            wrapper = json.load(handle)
        del wrapper["instance"]["kind"]
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(wrapper, handle, indent=2)
        result = self.run_checker(root)
        self.assertEqual(1, result.returncode, result.stdout + result.stderr)
        self.assertIn("FAIL", result.stdout)


if __name__ == "__main__":
    unittest.main()
