#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Unit tests for the W0 container fixture generator."""

from __future__ import annotations

import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import generate_container as generator  # noqa: E402


def _tree_fingerprint(root: Path) -> dict:
    result = {}
    for path in sorted(root.rglob("*")):
        if path.is_file():
            relative = path.relative_to(root).as_posix()
            result[relative] = hashlib.sha256(path.read_bytes()).hexdigest()
    return result


class ProfileTableTests(unittest.TestCase):
    def test_profiles_match_plan_section_1_3(self) -> None:
        expected = {
            "light": (20, 50 * generator.MIB, 1 * generator.MIB),
            "typical": (150, 150 * generator.MIB, 7 * generator.MIB),
            "heavy": (500, 288 * generator.MIB, 20 * generator.MIB),
        }
        self.assertEqual(set(generator.PROFILES), set(expected))
        for name, (sessions, workspace, longest) in expected.items():
            profile = generator.PROFILES[name]
            self.assertEqual(profile.sessions, sessions)
            self.assertEqual(profile.workspace_bytes, workspace)
            self.assertEqual(profile.longest_session_bytes, longest)

    def test_resolve_profile_overrides(self) -> None:
        profile = generator.resolve_profile(
            "light", sessions=2, workspace_bytes=128 * 1024,
            longest_session_bytes=16 * 1024, short_session_bytes=8 * 1024)
        self.assertEqual(profile.sessions, 2)
        self.assertEqual(profile.workspace_bytes, 128 * 1024)
        self.assertEqual(profile.longest_session_bytes, 16 * 1024)
        self.assertEqual(profile.short_session_bytes, 8 * 1024)

    def test_unknown_profile_and_bad_sizes_are_rejected(self) -> None:
        with self.assertRaises(ValueError):
            generator.resolve_profile("nope")
        with self.assertRaises(ValueError):
            generator.resolve_profile("light", sessions=0)
        with self.assertRaises(ValueError):
            generator.resolve_profile("light", workspace_bytes=1024)
        with self.assertRaises(ValueError):
            generator.resolve_profile("light", longest_session_bytes=10)


class SessionFormatTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = Path(tempfile.mkdtemp(prefix="pdsh-perf-session-"))
        self.addCleanup(shutil.rmtree, self.temp, True)
        self.profile = generator.resolve_profile(
            "light", sessions=2, workspace_bytes=64 * 1024,
            longest_session_bytes=32 * 1024, short_session_bytes=8 * 1024)

    def _generate(self, name: str = "c", seed: int = 3) -> dict:
        return generator.generate_container(
            self.temp / name, self.profile, seed=seed, force=True)

    def test_session_journal_is_real_v4_jsonl_and_exactly_sized(self) -> None:
        manifest = self._generate()
        longest_id = manifest["sessions"]["longestSessionID"]
        root = self.temp / "c"
        path = (root / "Library" / "xl" / manifest["workspaceID"] / "materialized" /
                "home" / "sessions" / generator.PROJECT_KEY / longest_id /
                "session.v4.jsonl")
        self.assertEqual(path.stat().st_size, manifest["sessions"]["longestSessionBytes"])

        lines = [line for line in path.read_text(encoding="utf-8").splitlines() if line]
        header = json.loads(lines[0])
        self.assertEqual(header["type"], "session")
        self.assertEqual(header["version"], 4)
        self.assertEqual(header["id"], longest_id)
        self.assertEqual(header["cwd"], generator.SESSION_CWD)
        self.assertIs(header["isSeeded"], False)
        self.assertEqual(header["delegationDepth"], 0)
        self.assertIsInstance(header["createdAt"], int)

        events = [json.loads(line) for line in lines[1:]]
        self.assertGreater(len(events), 0)
        self.assertEqual([event["seq"] for event in events], list(range(len(events))))
        known = {
            "turn/start", "turn/end", "step/start", "step/end",
            "user/message", "assistant/message", "tool/call", "tool/result",
        }
        self.assertTrue({event["type"] for event in events} <= known)
        self.assertEqual(events[-1]["type"], "turn/end")
        self.assertEqual(events[-1]["data"]["reason"]["kind"], "completed")
        self.assertEqual(events[0]["type"], "turn/start")
        self.assertEqual(events[0]["data"]["turn"], 1)

        for event in events:
            self.assertIsInstance(event["seq"], int)
            self.assertIsInstance(event["time"], int)
            self.assertIsInstance(event["data"], dict)
            if event["type"] == "user/message":
                self.assertEqual(event["surfaceOp"], "append")
                self.assertEqual(event["data"]["message"]["role"], "user")
                self.assertEqual(event["data"]["source"]["kind"], "user")
                self.assertIn("rpcId", event["data"]["source"])
            if event["type"] == "assistant/message":
                self.assertEqual(event["data"]["message"]["role"], "assistant")
                self.assertIn("turn", event["data"])
                self.assertIn("step", event["data"])
            if event["type"] == "tool/call":
                self.assertIn("callId", event["data"])
                self.assertIn("arguments", event["data"])
                self.assertIsInstance(event["data"]["arguments"], str)
            if event["type"] == "tool/result":
                self.assertEqual(event["data"]["message"]["role"], "tool")
                self.assertEqual(event["data"]["source"]["kind"], "tool")

    def test_event_times_are_monotonic(self) -> None:
        manifest = self._generate(name="times", seed=9)
        path = (self.temp / "times" / "Library" / "xl" / manifest["workspaceID"] /
                "materialized" / "home" / "sessions" / generator.PROJECT_KEY /
                manifest["sessions"]["longestSessionID"] / "session.v4.jsonl")
        events = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()[1:]]
        times = [event["time"] for event in events]
        self.assertEqual(times, sorted(times))
        self.assertEqual(len(times), len(set(times)))


class DeterminismTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = Path(tempfile.mkdtemp(prefix="pdsh-perf-det-"))
        self.addCleanup(shutil.rmtree, self.temp, True)
        self.profile = generator.resolve_profile(
            "light", sessions=3, workspace_bytes=256 * 1024,
            longest_session_bytes=16 * 1024, short_session_bytes=8 * 1024)

    def test_same_seed_produces_identical_tree(self) -> None:
        generator.generate_container(self.temp / "a", self.profile, seed=11)
        generator.generate_container(self.temp / "b", self.profile, seed=11)
        self.assertEqual(_tree_fingerprint(self.temp / "a"),
                         _tree_fingerprint(self.temp / "b"))

    def test_different_seed_changes_content(self) -> None:
        generator.generate_container(self.temp / "a", self.profile, seed=11)
        generator.generate_container(self.temp / "b", self.profile, seed=12)
        self.assertNotEqual(_tree_fingerprint(self.temp / "a"),
                            _tree_fingerprint(self.temp / "b"))

    def test_force_is_required_to_replace_an_existing_directory(self) -> None:
        generator.generate_container(self.temp / "a", self.profile, seed=11)
        with self.assertRaises(FileExistsError):
            generator.generate_container(self.temp / "a", self.profile, seed=12)
        manifest = generator.generate_container(
            self.temp / "a", self.profile, seed=12, force=True)
        self.assertEqual(manifest["seed"], 12)


class WorkspaceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = Path(tempfile.mkdtemp(prefix="pdsh-perf-workspace-"))
        self.addCleanup(shutil.rmtree, self.temp, True)
        self.profile = generator.resolve_profile(
            "light", sessions=1, workspace_bytes=512 * 1024,
            longest_session_bytes=16 * 1024, short_session_bytes=8 * 1024)
        self.manifest = generator.generate_container(self.temp / "c", self.profile, seed=5)
        self.workspace = (self.temp / "c" / "Library" / "xl" /
                          self.manifest["workspaceID"] / "materialized" / "workspace")

    def test_workspace_size_is_exact(self) -> None:
        total = sum(path.stat().st_size for path in self.workspace.rglob("*") if path.is_file())
        self.assertEqual(total, self.profile.workspace_bytes)

    def test_workspace_is_a_git_repository_and_has_large_files(self) -> None:
        self.assertTrue((self.workspace / ".git" / "HEAD").is_file())
        self.assertTrue((self.workspace / ".git" / "index").is_file())
        self.assertTrue((self.workspace / "README.md").is_file())
        large = [path for path in (self.workspace / "assets").glob("*.bin")
                 if path.stat().st_size >= 16 * 1024]
        self.assertTrue(large, "the fixture must contain at least one large file")

    @unittest.skipUnless(shutil.which("git"), "git is not installed")
    def test_real_git_accepts_the_repository(self) -> None:
        log = subprocess.run(
            ["git", "-C", str(self.workspace), "log", "--format=%s", "-1"],
            check=True, capture_output=True, text=True)
        self.assertEqual(log.stdout.strip(), "Synthetic W0 fixture")
        status = subprocess.run(
            ["git", "-C", str(self.workspace), "status", "--porcelain"],
            check=True, capture_output=True, text=True)
        self.assertEqual(status.stdout.strip(), "",
                         "the generated repository must be clean")


class StoreStubTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = Path(tempfile.mkdtemp(prefix="pdsh-perf-stubs-"))
        self.addCleanup(shutil.rmtree, self.temp, True)
        profile = generator.resolve_profile(
            "light", sessions=2, workspace_bytes=128 * 1024,
            longest_session_bytes=16 * 1024, short_session_bytes=8 * 1024)
        self.manifest = generator.generate_container(
            self.temp / "c", profile, seed=2, store_stubs=True)
        self.workspace_root = (self.temp / "c" / "Library" / "xl" /
                               self.manifest["workspaceID"])

    def test_stub_layout_and_manifest_flag(self) -> None:
        self.assertTrue(self.manifest["storeStubs"])
        self.assertTrue(any((self.workspace_root / "wal").glob("*.xlwal")))
        self.assertTrue((self.workspace_root / "journal.xljournal").is_file())
        self.assertTrue(any((self.workspace_root / "steps").glob("*.ndjson")))
        self.assertTrue(any((self.workspace_root / "response-log").glob("*/body")))
        self.assertTrue((self.workspace_root / "overlay-cache.tar").is_file())
        self.assertTrue((self.temp / "c" / "Documents" / "transcript-snapshots").is_dir())

    def test_stubs_are_not_claimed_as_valid_protocol_data(self) -> None:
        manifest = json.loads((self.temp / "c" / "perf-fixture.json").read_text())
        self.assertIs(manifest["storeStubs"], True)


if __name__ == "__main__":
    unittest.main()
