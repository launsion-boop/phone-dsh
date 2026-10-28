#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Mutation tests for the handoff schemas, the budget caps and the D14-D16 references.

Every test runs the checker on a temporary copy of the specification tree, so the real tree is never
modified.
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

SPEC_DIR = Path(__file__).resolve().parents[1]


def run_checker(spec_dir: Path, full: bool = False) -> subprocess.CompletedProcess:
    command = [sys.executable, str(spec_dir / "tools" / "spec_golden.py")]
    if full:
        command.append("--full")
    else:
        command.extend(["--spec-dir", str(spec_dir)])
    return subprocess.run(command, capture_output=True, text=True, check=False)


def load_checker(spec_dir: Path):
    loader = importlib.util.spec_from_file_location(
        "spec_golden_handoff_copy", spec_dir / "tools" / "spec_golden.py"
    )
    module = importlib.util.module_from_spec(loader)
    loader.loader.exec_module(module)
    return module


class HandoffBudgetTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.copy = Path(self.temp.name) / "phone-dsh-v1"
        shutil.copytree(
            SPEC_DIR, self.copy, ignore=shutil.ignore_patterns("__pycache__", "*.pyc")
        )

    def write_json(self, relative: str, value) -> None:
        path = self.copy / relative
        path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    def assert_fails(self, completed: subprocess.CompletedProcess, needle: str) -> None:
        self.assertNotEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        self.assertIn(needle, completed.stdout)

    def replace(self, relative: str, old: str, new: str) -> None:
        path = self.copy / relative
        text = path.read_text(encoding="utf-8")
        self.assertIn(old, text)
        path.write_text(text.replace(old, new, 1), encoding="utf-8")

    def test_full_real_tree_passes_with_handoff_documents(self) -> None:
        completed = run_checker(SPEC_DIR, full=True)
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        self.assertIn("0 error(s)", completed.stdout)
        for line in (
            "ok handoff.md",
            "ok budgets.md",
            "ok schema/handoff-fence-request.schema.json",
            "ok schema/handoff-reclaim-response.schema.json",
        ):
            self.assertIn(line, completed.stdout)

    def test_missing_handoff_schema_fails(self) -> None:
        (self.copy / "schema" / "handoff-snapshot-request.schema.json").unlink()
        completed = run_checker(self.copy)
        self.assert_fails(completed, "handoff schema is required but missing")

    def test_unexpected_handoff_schema_fails(self) -> None:
        self.write_json(
            "schema/handoff-extra.schema.json",
            {
                "$schema": "https://json-schema.org/draft/2020-12/schema",
                "title": "extra",
                "type": "object",
                "additionalProperties": False,
            },
        )
        completed = run_checker(self.copy)
        self.assert_fails(completed, "unexpected handoff schema file")

    def test_handoff_line_cap_enforced(self) -> None:
        path = self.copy / "handoff.md"
        original = path.read_text(encoding="utf-8")
        self.assertLessEqual(len(original.splitlines()), 200)
        path.write_text(original + ("\n" * 50), encoding="utf-8")
        completed = run_checker(self.copy)
        self.assert_fails(completed, "D16 cap")

    def test_budgets_line_cap_enforced(self) -> None:
        path = self.copy / "budgets.md"
        original = path.read_text(encoding="utf-8")
        self.assertLessEqual(len(original.splitlines()), 200)
        path.write_text(original + ("\n" * 100), encoding="utf-8")
        completed = run_checker(self.copy)
        self.assert_fails(completed, "D16 cap")

    def test_full_requires_handoff_and_budgets_documents(self) -> None:
        for name in ("handoff.md", "budgets.md"):
            (self.copy / name).unlink()
        completed = run_checker(self.copy, full=True)
        self.assert_fails(completed, "required by --full but missing")

    def test_d14_points_at_real_budgets_sections(self) -> None:
        self.replace("budgets.md", "## 1. States", "## One. States")
        completed = run_checker(self.copy)
        self.assert_fails(completed, "decision D14 points at budgets.md §1")

    def test_d15_points_at_real_handoff_sections(self) -> None:
        self.replace("handoff.md", "## 3. ", "## Three. ")
        completed = run_checker(self.copy)
        self.assert_fails(completed, "decision D15 points at handoff.md §3")

    def test_d16_points_at_real_readme_section(self) -> None:
        self.replace("README.md", "## 4. Decisions", "## Four. Decisions")
        completed = run_checker(self.copy)
        self.assert_fails(completed, "decision D16 points at README.md §4")

    def test_d14_missing_budgets_reference_fails(self) -> None:
        path = self.copy / "README.md"
        text = path.read_text(encoding="utf-8")
        self.assertIn("budgets.md §1, §2", text)
        path.write_text(text.replace("budgets.md §1, §2", "README §4", 1), encoding="utf-8")
        completed = run_checker(self.copy)
        self.assert_fails(completed, "decision D14 does not point at budgets.md")

    def test_fence_response_requires_reclaim_token(self) -> None:
        path = self.copy / "schema" / "handoff-fence-response.schema.json"
        doc = json.loads(path.read_text(encoding="utf-8"))
        doc["required"].remove("reclaim_token")
        del doc["properties"]["reclaim_token"]
        self.write_json("schema/handoff-fence-response.schema.json", doc)
        completed = run_checker(self.copy)
        self.assert_fails(completed, "required members must be exactly")

    def test_reclaim_response_requires_phone_owner(self) -> None:
        path = self.copy / "schema" / "handoff-reclaim-response.schema.json"
        doc = json.loads(path.read_text(encoding="utf-8"))
        doc["properties"]["fence"]["properties"]["owner"]["const"] = "remote"
        self.write_json("schema/handoff-reclaim-response.schema.json", doc)
        completed = run_checker(self.copy)
        self.assert_fails(completed, 'owner must be const "phone"')

    def test_segments_request_requires_wal_file_names(self) -> None:
        path = self.copy / "schema" / "handoff-segments-request.schema.json"
        doc = json.loads(path.read_text(encoding="utf-8"))
        doc["properties"]["segments"]["items"]["properties"]["file"]["pattern"] = "^wal/.*$"
        self.write_json("schema/handoff-segments-request.schema.json", doc)
        completed = run_checker(self.copy)
        self.assert_fails(completed, "file pattern does not match the WAL segment name")

    def test_handoff_document_requires_reclaim_cache_rule(self) -> None:
        self.replace("handoff.md", "for 24 h", "for a day")
        completed = run_checker(self.copy, full=True)
        self.assert_fails(completed, "lacks required contract text")

    def test_budgets_document_requires_wal_quota(self) -> None:
        self.replace("budgets.md", "| WAL segments | 256 MiB |", "| WAL segments | 256 MB |")
        completed = run_checker(self.copy, full=True)
        self.assert_fails(completed, "lacks required contract text")

    def test_handoff_document_documents_every_endpoint(self) -> None:
        self.replace("handoff.md", "`POST /v1/handoff/reclaim`", "`POST /v1/handoff/return`")
        completed = run_checker(self.copy)
        self.assert_fails(completed, "does not document /v1/handoff/reclaim")

    def test_schema_validation_accepts_documented_samples(self) -> None:
        checker = load_checker(self.copy)
        schemas = {
            path.name: checker.load_json(path)
            for path in (self.copy / "schema").glob("handoff-*.schema.json")
        }
        valid, _ = checker._handoff_samples()
        self.assertEqual(set(schemas), set(checker.HANDOFF_SCHEMAS))
        for name, samples in valid.items():
            for sample in samples:
                checker.validate_json(sample, schemas[name], "schema/" + name)

    def test_schema_validation_rejects_undocumented_variants(self) -> None:
        checker = load_checker(self.copy)
        schemas = {
            path.name: checker.load_json(path)
            for path in (self.copy / "schema").glob("handoff-*.schema.json")
        }
        _, invalid = checker._handoff_samples()
        for name, samples in invalid.items():
            for label, sample in samples:
                with self.assertRaises(checker.SpecError, msg="{}: {}".format(name, label)):
                    checker.validate_json(sample, schemas[name], "schema/" + name)


if __name__ == "__main__":
    unittest.main()
