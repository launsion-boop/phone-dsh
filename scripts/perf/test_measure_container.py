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
            "caches": 0,
            "app-support": 0,
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
        self.assertEqual(report["subdirectories"]["caches"], 0)

    def test_store_named_directories_inside_materialized_are_workspace_bytes(self) -> None:
        # Regression for docs/perf/baseline-fixtures-20261112.md §8.1: a real
        # user workspace may contain these directories, and they must never be
        # reported as store bytes.
        root = self.temp / "container"
        store_names = ("wal", "steps", "exec", "journal", "overlay",
                       "response-log", "transcript-snapshots")
        for name in store_names:
            _write(root / "Library" / "xl" / "perf" / "materialized" /
                   "workspace" / name / "asset.bin", 10)
        # A nested collision two levels deep must not escape either.
        _write(root / "Library" / "xl" / "perf" / "materialized" / "workspace" /
               "wal" / "steps" / "nested.bin", 5)

        report = measure.measure(root)
        self.assertEqual(report["total_bytes"], 75)
        self.assertEqual(report["categories"]["materialized"], 75)
        self.assertEqual(report["breakdown"]["workspace"], 75)
        self.assertEqual(report["breakdown"]["sessions"], 0)
        for name in store_names:
            self.assertEqual(report["categories"][name], 0, name)
        self.assertEqual(report["file_counts"]["materialized"], 8)
        self.assertEqual(sum(report["categories"].values()), report["total_bytes"])

    def test_store_paths_outside_materialized_still_classify_as_stores(self) -> None:
        root = self.temp / "container"
        base = root / "Library" / "xl" / "perf"
        _write(base / "wal" / "00000001.000000.xlwal", 101)
        _write(base / "steps" / "s.ndjson", 202)
        _write(base / "exec" / "ledger", 303)
        _write(base / "journal.xljournal", 404)
        _write(base / "response-log" / "key" / "body", 505)
        _write(base / "overlay-abc.tar", 606)
        _write(root / "Documents" / "transcript-snapshots" / "s.json", 707)

        report = measure.measure(root)
        self.assertEqual(report["categories"]["wal"], 101)
        self.assertEqual(report["categories"]["steps"], 202)
        self.assertEqual(report["categories"]["exec"], 303)
        self.assertEqual(report["categories"]["journal"], 404)
        self.assertEqual(report["categories"]["response-log"], 505)
        self.assertEqual(report["categories"]["overlay"], 606)
        self.assertEqual(report["categories"]["transcript-snapshots"], 707)
        self.assertEqual(report["categories"]["materialized"], 0)
        self.assertEqual(report["categories"]["caches"], 0)
        self.assertEqual(sum(report["categories"].values()), report["total_bytes"])

    def test_caches_bucket_is_separate_from_the_stores(self) -> None:
        # Library/Caches/pdsh/<workspace_id> is the W3 rebuildable tree
        # (WorkspacePaths.cacheRoot).  Its children are named after the stores,
        # but the system may purge it, so it is its own bucket.
        root = self.temp / "container"
        cache = root / "Library" / "Caches" / "pdsh" / "perf"
        _write(cache / "response-log" / "key" / "body", 300)
        _write(cache / "transcript-snapshots" / "s.json", 200)
        _write(cache / "overlay-cache.tar", 100)
        # The cache domain is `Library/Caches/**`, not only the pdsh subtree
        # (`defaultStagingRoot` in WebEngineDirectoryImport.swift uses
        # Library/Caches/PhoneDSHImport).
        _write(root / "Library" / "Caches" / "PhoneDSHImport" / "staging.bin", 25)
        # The authoritative (Documents) copy at the same relative names must
        # keep its own store buckets.
        durable = root / "Library" / "xl" / "perf"
        _write(durable / "response-log" / "key" / "body", 400)
        _write(durable / "overlay-cache.tar", 50)

        report = measure.measure(root)
        self.assertEqual(report["categories"]["caches"], 625)
        self.assertEqual(report["file_counts"]["caches"], 4)
        self.assertEqual(report["categories"]["response-log"], 400)
        self.assertEqual(report["categories"]["overlay"], 50)
        self.assertEqual(report["categories"]["transcript-snapshots"], 0)
        self.assertEqual(report["subdirectories"]["caches"], 625)
        self.assertEqual(sum(report["categories"].values()), report["total_bytes"])
        self.assertIn("caches", report["category_notes"])
        self.assertIn("Library/Caches/pdsh", report["category_notes"]["caches"])
        self.assertIn("not Documents authoritative", report["category_notes"]["caches"])

    def test_caches_anchor_requires_the_library_path(self) -> None:
        # A user directory that merely shares the name must stay in `other`;
        # only the app container's `Library/Caches` domain is system-reclaimable.
        root = self.temp / "container"
        _write(root / "Documents" / "Caches" / "asset.bin", 11)
        _write(root / "Caches" / "asset.bin", 13)

        report = measure.measure(root)
        self.assertEqual(report["categories"]["caches"], 0)
        self.assertEqual(report["categories"]["other"], 24)
        self.assertEqual(sum(report["categories"].values()), report["total_bytes"])

    def test_app_support_domain_is_its_own_bucket_not_wal(self) -> None:
        # Regression for docs/perf/sim-container-20261113.md finding 1:
        # Library/Application Support/PhoneDSHBot/domain.sqlite-wal used to fall
        # into `other`.  It is the Bot's SQLite domain, so it is attributable
        # but is neither a store bucket nor a rebuildable cache.
        root = self.temp / "container"
        support = root / "Library" / "Application Support" / "PhoneDSHBot"
        _write(support / "domain.sqlite", 4096)
        _write(support / "domain.sqlite-wal", 156592)
        _write(support / "domain.sqlite-shm", 32768)

        report = measure.measure(root)
        self.assertEqual(report["categories"]["app-support"], 193456)
        self.assertEqual(report["categories"]["other"], 0)
        self.assertEqual(report["categories"]["caches"], 0)
        # The suffix in `domain.sqlite-wal` is not the `wal` path component.
        self.assertEqual(report["categories"]["wal"], 0)
        self.assertEqual(report["file_counts"]["app-support"], 3)
        self.assertEqual(report["subdirectories"]["app-support"], 193456)
        self.assertEqual(sum(report["categories"].values()), report["total_bytes"])
        self.assertIn("app-support", report["category_notes"])
        note = report["category_notes"]["app-support"]
        self.assertIn("Library/Application Support", note)
        self.assertIn("PhoneDSHBot/domain.sqlite", note)
        self.assertIn("not a rebuildable cache", note)
        self.assertIn("does not purge", note)

    def test_app_support_children_named_after_stores_stay_app_support(self) -> None:
        # A directory called `wal` or `response-log` under the Bot's domain is
        # still Bot data, exactly like the Library/Caches rule.  The anchored
        # check must run before the store-name checks.
        root = self.temp / "container"
        support = root / "Library" / "Application Support" / "PhoneDSHBot"
        _write(support / "wal" / "x", 10)
        _write(support / "response-log" / "k" / "body", 20)
        _write(support / "nested" / "wal" / "x", 30)

        report = measure.measure(root)
        self.assertEqual(report["categories"]["app-support"], 60)
        self.assertEqual(report["categories"]["wal"], 0)
        self.assertEqual(report["categories"]["response-log"], 0)
        self.assertEqual(report["file_counts"]["app-support"], 3)
        self.assertEqual(sum(report["categories"].values()), report["total_bytes"])

    def test_app_support_anchor_requires_the_library_path(self) -> None:
        # Only the app container's Library/Application Support is the Bot
        # domain; the same names elsewhere (and the wrong case) are not.
        root = self.temp / "container"
        _write(root / "Application Support" / "PhoneDSHBot" / "domain.sqlite-wal", 11)
        _write(root / "Documents" / "Application Support" / "PhoneDSHBot" /
               "domain.sqlite-wal", 13)
        _write(root / "Library" / "application support" / "PhoneDSHBot" /
               "domain.sqlite-wal", 17)

        report = measure.measure(root)
        self.assertEqual(report["categories"]["app-support"], 0)
        self.assertEqual(report["categories"]["other"], 41)
        self.assertEqual(sum(report["categories"].values()), report["total_bytes"])

    def test_app_support_bucket_does_not_disturb_stores_or_caches(self) -> None:
        # The three domains coexist in the real simulator container: the
        # Documents store, the Library/Caches rebuildable tree and the Bot's
        # Library/Application Support domain must stay in separate buckets.
        root = self.temp / "container"
        _write(root / "Documents" / "chat-host" / "wal" / "00000003.000000.xlwal", 500)
        _write(root / "Library" / "Caches" / "pdsh" / "perf" / "response-log" /
               "k" / "body", 600)
        _write(root / "Library" / "Application Support" / "PhoneDSHBot" /
               "domain.sqlite-wal", 700)

        report = measure.measure(root)
        self.assertEqual(report["categories"]["wal"], 500)
        self.assertEqual(report["categories"]["caches"], 600)
        self.assertEqual(report["categories"]["app-support"], 700)
        self.assertEqual(report["categories"]["other"], 0)
        self.assertEqual(report["file_counts"]["wal"], 1)
        self.assertEqual(report["file_counts"]["caches"], 1)
        self.assertEqual(report["file_counts"]["app-support"], 1)
        self.assertEqual(report["subdirectories"]["wal"], 500)
        self.assertEqual(report["subdirectories"]["caches"], 600)
        self.assertEqual(report["subdirectories"]["app-support"], 700)
        self.assertEqual(sum(report["categories"].values()), report["total_bytes"])
        self.assertEqual(report["total_bytes"], 1800)

    def test_workspace_subdirectory_named_sessions_is_not_the_session_bucket(self) -> None:
        root = self.temp / "container"
        _write(root / "Library" / "xl" / "perf" / "materialized" / "workspace" /
               "sessions" / "s.v4.jsonl", 42)
        _write(root / "Library" / "xl" / "perf" / "materialized" / "home" /
               "sessions" / "p" / "s" / "session.v4.jsonl", 58)

        report = measure.measure(root)
        self.assertEqual(report["categories"]["materialized"], 100)
        self.assertEqual(report["breakdown"]["workspace"], 42)
        self.assertEqual(report["breakdown"]["sessions"], 58)
        self.assertEqual(report["subdirectories"]["workspace"], 42)
        self.assertEqual(report["subdirectories"]["sessions"], 58)

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

    def test_hard_link_into_the_cache_tree_is_counted_once(self) -> None:
        # W3 moves rebuildable bytes to Library/Caches with hard links; a link
        # there must not add bytes to either the store or the workspace.
        root = self.temp / "container"
        first = root / "Library" / "xl" / "perf" / "materialized" / "workspace" / "first.bin"
        second = root / "Library" / "Caches" / "pdsh" / "perf" / "response-log" / "k" / "body"
        _write(first, 1000)
        second.parent.mkdir(parents=True, exist_ok=True)
        os.link(first, second)

        report = measure.measure(root)
        self.assertEqual(report["total_bytes"], 1000)
        self.assertEqual(report["hardlinks_deduplicated"], 1)
        self.assertEqual(report["file_count"], 1)
        self.assertEqual(sum(report["categories"].values()), 1000)
        self.assertEqual(report["file_counts"]["materialized"]
                         + report["file_counts"]["caches"], 1)
        self.assertEqual(report["categories"]["materialized"]
                         + report["categories"]["caches"], 1000)

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
        self.assertEqual(report["categories"]["caches"], 0)
        self.assertIn("caches", report["category_notes"])
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
        self.assertEqual(report["categories"]["caches"], 0)
        self.assertIn("caches", report["category_notes"])
        self.assertEqual(report["total_bytes"], measure.measure(self.root)["total_bytes"])


if __name__ == "__main__":
    unittest.main()
