#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Mutation tests for spec/platform/tools/platform_check.py.

Each test builds a throw-away repository root that contains the real
``spec/platform`` tree, the real spec documents its ``spec_ref`` values point
at, and stub files for the Swift baselines, then damages exactly one thing.
The checker must fail on the damage and pass on the untouched tree.

Run::

    python3 -m unittest discover -s spec/platform/tools -p 'test_*.py' -v
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
TOOL = Path(__file__).resolve().with_name("platform_check.py")
PLATFORM = REPO / "spec/platform"
WHITELIST_REL = Path("spec/platform/whitelist.json")
GOLDEN_REL = Path("spec/platform/golden")

# Documents the whitelist cites. They are copied verbatim so that section
# resolution is exercised against the real headings, not against fixtures.
CITED_DOCS = (
    "spec/v1/wal.md",
    "spec/v1/budgets.md",
    "spec/v1/handoff.md",
    "spec/v1/channel.md",
    "spec/v1/render-media-v1.md",
    "spec/v1/bridge.md",
    "spec/ui/v1/README.md",
    "docs/design/phone-dsh-app/app-map.md",
)


def _copy_platform(destination: Path) -> None:
    shutil.copytree(
        PLATFORM,
        destination / "spec/platform",
        ignore=shutil.ignore_patterns("__pycache__"),
    )


def _copy_cited_docs(destination: Path) -> None:
    for relative in CITED_DOCS:
        source = REPO / relative
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)


def _stub_baselines(destination: Path) -> None:
    """Create empty files at every baseline path the tree references."""

    relatives = set()
    whitelist = json.loads((destination / WHITELIST_REL).read_text(encoding="utf-8"))
    for entry in whitelist:
        baseline = entry.get("baseline")
        if baseline and baseline != "not-applicable":
            relatives.add(baseline)
    for path in sorted((destination / GOLDEN_REL).glob("*.json")):
        document = json.loads(path.read_text(encoding="utf-8"))
        entry = document.get("entry", {})
        baseline = entry.get("baseline")
        if baseline and baseline != "not-applicable":
            relatives.add(baseline)
    for relative in relatives:
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text("# stub baseline for the mutation tests\n", encoding="utf-8")


class PlatformCheckTest(unittest.TestCase):
    def setUp(self) -> None:
        self.root = Path(tempfile.mkdtemp(prefix="platform-check-"))
        self.addCleanup(shutil.rmtree, self.root, True)
        _copy_platform(self.root)
        _copy_cited_docs(self.root)
        _stub_baselines(self.root)

    # -- helpers ---------------------------------------------------------

    def _entries(self) -> list:
        return json.loads((self.root / WHITELIST_REL).read_text(encoding="utf-8"))

    def _write_entries(self, entries: list) -> None:
        text = json.dumps(entries, ensure_ascii=False, indent=2) + "\n"
        (self.root / WHITELIST_REL).write_text(text, encoding="utf-8")

    def _entry(self, identifier: str) -> dict:
        for entry in self._entries():
            if entry.get("id") == identifier:
                return entry
        raise AssertionError(f"entry {identifier} is missing from the fixture tree")

    def _run(self) -> subprocess.CompletedProcess:
        return subprocess.run(
            [sys.executable, str(TOOL), "--root", str(self.root)],
            capture_output=True,
            text=True,
            cwd=str(self.root),
        )

    def _expect_failure(self, needle: str) -> str:
        result = self._run()
        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, 1, f"checker should fail\n{output}")
        self.assertIn(needle, output)
        return output

    # -- tests -----------------------------------------------------------

    def test_clean_tree_passes(self) -> None:
        result = self._run()
        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, output)
        self.assertIn("coverage: required primitives 13/13", output)
        self.assertIn("coverage: required extensions 6/6", output)
        self.assertIn("0 failures", output)

    def test_repository_tree_passes(self) -> None:
        result = subprocess.run(
            [sys.executable, str(TOOL), "--root", str(REPO)],
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_missing_rationale_is_rejected(self) -> None:
        entries = self._entries()
        for entry in entries:
            if entry["id"] == "platform.fsync-epoch-close":
                del entry["rationale"]
        self._write_entries(entries)
        self._expect_failure("rationale")

    def test_spec_ref_to_missing_file_is_rejected(self) -> None:
        entries = self._entries()
        for entry in entries:
            if entry["id"] == "platform.fsync-epoch-close":
                entry["spec_ref"] = "spec/v1/no-such-document.md §4"
        self._write_entries(entries)
        self._expect_failure("spec_ref file not found")

    def test_spec_ref_to_missing_section_is_rejected(self) -> None:
        entries = self._entries()
        for entry in entries:
            if entry["id"] == "platform.fsync-epoch-close":
                entry["spec_ref"] = "spec/v1/wal.md §99"
        self._write_entries(entries)
        self._expect_failure("not found as a heading")

    def test_not_applicable_without_exception_fields_is_rejected(self) -> None:
        entries = self._entries()
        for entry in entries:
            if entry["id"] == "platform.keystore-downgrade-chain":
                del entry["evidence"]
                del entry["approved_by"]
        self._write_entries(entries)
        output = self._expect_failure("baseline not-applicable requires")
        self.assertIn("evidence", output)
        self.assertIn("approved_by", output)

    def test_not_applicable_without_justification_class_is_rejected(self) -> None:
        entries = self._entries()
        for entry in entries:
            if entry["id"] == "platform.fgs-turn-notification":
                del entry["justification_class"]
        self._write_entries(entries)
        self._expect_failure("justification_class")

    def test_exception_fields_on_baseline_entry_are_rejected(self) -> None:
        entries = self._entries()
        for entry in entries:
            if entry["id"] == "platform.fsync-epoch-close":
                entry["justification_class"] = "os-mechanism-absent"
                entry["evidence"] = "this must not be needed for a baseline-backed entry"
                entry["approved_by"] = "P0-H2"
        self._write_entries(entries)
        self._expect_failure("only allowed with baseline")

    def test_duplicate_id_is_rejected(self) -> None:
        entries = self._entries()
        entries[1]["id"] = entries[0]["id"]
        self._write_entries(entries)
        self._expect_failure("duplicate id")

    def test_missing_required_primitive_is_rejected(self) -> None:
        entries = [e for e in self._entries() if e["id"] != "platform.fsync-epoch-close"]
        self._write_entries(entries)
        output = self._expect_failure("missing required primitive")
        self.assertIn("platform.fsync-epoch-close", output)

    def test_missing_mandated_extension_is_rejected(self) -> None:
        entries = [
            e for e in self._entries() if e["id"] != "platform.post-notifications-degraded"
        ]
        self._write_entries(entries)
        self._expect_failure("missing mandated extension")

    def test_os_forced_without_mechanism_is_rejected(self) -> None:
        entries = self._entries()
        for entry in entries:
            if entry["id"] == "platform.thermal-battery":
                del entry["android_mechanism"]
        self._write_entries(entries)
        output = self._expect_failure("os-forced entry requires android_mechanism")
        self.assertIn("platform.thermal-battery", output)

    def test_vague_mechanism_is_rejected(self) -> None:
        entries = self._entries()
        for entry in entries:
            if entry["id"] == "platform.nwpathmonitor":
                entry["android_mechanism"] = "平台相关"
        self._write_entries(entries)
        self._expect_failure("must name a concrete API")

    def test_illegal_divergence_class_is_rejected(self) -> None:
        entries = self._entries()
        for entry in entries:
            if entry["id"] == "platform.scene-phase":
                entry["divergence_class"] = "os-preferred"
        self._write_entries(entries)
        self._expect_failure("not in enum")

    def test_missing_baseline_file_is_rejected(self) -> None:
        entries = self._entries()
        for entry in entries:
            if entry["id"] == "platform.url-scheme-handler":
                entry["baseline"] = "Sources/PhoneDSHEngine/NotThere.swift"
        self._write_entries(entries)
        self._expect_failure("baseline file not found")

    def test_not_verified_without_explanation_is_rejected(self) -> None:
        entries = self._entries()
        for entry in entries:
            if entry["id"] == "platform.lockdown-report":
                entry["rationale"] = (
                    "This entry claims no source without saying what will be measured, "
                    "so the evidence level cannot be audited by anyone."
                )
        self._write_entries(entries)
        self._expect_failure("not-verified entry must say why")

    def test_spec_ref_into_platform_tree_is_rejected(self) -> None:
        entries = self._entries()
        for entry in entries:
            if entry["id"] == "platform.urlsession-http-client":
                entry["spec_ref"] = "spec/platform/README.md §1"
        self._write_entries(entries)
        self._expect_failure("must not point into spec/platform")


if __name__ == "__main__":
    unittest.main()
