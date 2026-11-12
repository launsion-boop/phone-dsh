#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Unit tests for the W0 container measurement script."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import generate_container as generator  # noqa: E402
import measure_container as measure  # noqa: E402


def _write(path: Path, size: int, byte: bytes = b"x") -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(byte * size)


class ClassificationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = Path(tempfile.mkdtemp(prefix="pdsh-measure-"))
        self.addCleanup(shutil.rmtree, self.temp, True)

    def test_categories_are_mutually_exclusive_and_add_up(self) -> None:
        root = self.temp / "container"
        _write(root / "Library" / "xl" / "w" / "wal" / "00000001.000000.xlwal", 101)
        _write(root / "Library" / "xl" / "w" / "materialized" / "workspace" / "a.bin", 202)
        _write(root / "Library" / "xl" / "w" / "materialized" / "home" /
               "sessions" / "--dsh-workspace--" / "s" / "session.v4.jsonl", 303)
        _write(root / "Library" / "xl" / "w" / "response-log" / "k" / "body", 404)
        _write(root / "Library" / "xl" / "w" / "steps" / "s.ndjson", 505)
        _write(root / "Library" / "xl" / "w" / "exec" / "ledger", 606)
        _write(root / "Library" / "xl" / "w" / "journal.xljournal", 707)
        _write(root / "Library" / "xl" / "w" / "overlay-cache.tar", 808)
        _write(root / "Library" / "xl" / "w" / "overlay-abc.tar", 909)
        _write(root / "Documents" / "transcript-snapshots" / "s.json", 111)
        _write(root / "other.bin", 222)

        report = measure.measure(root)
        expected = {
            "wal": 101,
            "materialized": 505,       # workspace 202 + session log 303
            "response-log": 404,
            "overlay": 1717,           # 808 + 909
            "journal": 707,
            "steps": 505,
            "exec": 606,
            "transcript-snapshots": 111,
            "other": 222,
        }
        self.assertEqual(report["categories"], expected)
        self.assertEqual(report["total_bytes"], sum(expected.values()))
        self.assertEqual(sum(report["categories"].values()), report["total_bytes"])
        self.assertEqual(report["breakdown"]["sessions"], 303)
        self.assertEqual(report["breakdown"]["workspace"], 202)
        self.assertEqual(report["breakdown"]["materialized_other"], 0)
        self.assertEqual(report["breakdown"]["other"], 222)
        self.assertEqual(report["subdirectories"]["sessions"], 303)
        self.assertEqual(report["subdirectories"]["workspace"], 202)
        self.assertEqual(report["subdirectories"]["wal"], 101)

    def test_hard_links_are_counted_once(self) -> None:
        root = self.temp / "container"
        first = root / "Library" / "xl" / "w" / "materialized" / "workspace" / "first.bin"
        second = root / "Library" / "xl" / "w" / "response-log" / "k" / "body"
        _write(first, 1000)
        second.parent.mkdir(parents=True, exist_ok=True)
        os.link(first, second)

        report = measure.measure(root)
        self.assertEqual(report["total_bytes"], 1000)
        self.assertEqual(report["hardlinks_deduplicated"], 1)
        self.assertEqual(report["file_count"], 1)
        self.assertEqual(sum(report["categories"].values()), 1000)

    def test_symlinks_are_not_followed(self) -> None:
        root = self.temp / "container"
        _write(root / "Library" / "xl" / "w" / "wal" / "segment", 10)
        (root / "Library" / "xl" / "w" / "materialized").mkdir(parents=True)
        target = root / "Library" / "xl" / "w" / "materialized" / "workspace"
        target.mkdir(parents=True)
        try:
            (target / "link.bin").symlink_to(root / "Library" / "xl" / "w" / "wal" / "segment")
        except OSError:
            self.skipTest("symlinks are not supported here")
        report = measure.measure(root)
        self.assertEqual(report["total_bytes"], 10)

    def test_missing_root_is_an_error(self) -> None:
        with self.assertRaises(NotADirectoryError):
            measure.measure(self.temp / "missing")


class GeneratedContainerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = Path(tempfile.mkdtemp(prefix="pdsh-measure-gen-"))
        self.addCleanup(shutil.rmtree, self.temp, True)
        profile = generator.resolve_profile(
            "light", sessions=3, workspace_bytes=256 * 1024,
            longest_session_bytes=16 * 1024, short_session_bytes=8 * 1024)
        self.manifest = generator.generate_container(
            self.temp / "c", profile, seed=4, store_stubs=True)
        self.root = self.temp / "c"

    def test_generated_container_measures_the_expected_pieces(self) -> None:
        report = measure.measure(self.root)
        self.assertGreater(report["total_bytes"], self.manifest["workspaceBytes"])
        self.assertEqual(report["breakdown"]["sessions"],
                         self.manifest["sessions"]["totalBytes"])
        self.assertEqual(report["breakdown"]["workspace"],
                         self.manifest["workspaceBytes"])
        self.assertGreater(report["categories"]["wal"], 0)
        self.assertGreater(report["categories"]["steps"], 0)
        self.assertGreater(report["categories"]["response-log"], 0)
        self.assertGreater(report["categories"]["overlay"], 0)
        self.assertGreater(report["categories"]["journal"], 0)
        self.assertGreater(report["categories"]["transcript-snapshots"], 0)
        self.assertEqual(sum(report["categories"].values()), report["total_bytes"])

    def test_largest_files_are_sorted(self) -> None:
        report = measure.measure(self.root)
        sizes = [item["bytes"] for item in report["largest_files"]]
        self.assertEqual(sizes, sorted(sizes, reverse=True))

    def test_cli_writes_a_json_report(self) -> None:
        output = self.temp / "report.json"
        result = subprocess.run(
            [sys.executable, str(Path(__file__).with_name("measure_container.py")),
             str(self.root), "--output", str(output), "--pretty"],
            capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(output.read_text(encoding="utf-8"))
        self.assertEqual(report["schemaVersion"], 1)
        self.assertEqual(report["total_bytes"], measure.measure(self.root)["total_bytes"])


if __name__ == "__main__":
    unittest.main()
