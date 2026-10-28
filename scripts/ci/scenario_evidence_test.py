#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Regressions for the scenario evidence lifecycle (G2-FIX-72/110/123/128)."""

from __future__ import annotations

import contextlib
import io
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import scenario_evidence as evidence  # noqa: E402


def write_json(path, document):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def write_file(path, content=""):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def make_tar(path, files=None, symlinks=None, dirs=None):
    """Write a tar with explicit members; no host filesystem walk."""

    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(path, "w") as archive:
        for name in sorted(dirs or []):
            info = tarfile.TarInfo(name)
            info.type = tarfile.DIRTYPE
            info.mode = 0o755
            archive.addfile(info)
        for name, content in sorted((files or {}).items()):
            data = content.encode("utf-8")
            info = tarfile.TarInfo(name)
            info.size = len(data)
            info.mode = 0o644
            archive.addfile(info, io.BytesIO(data))
        for name, target in sorted((symlinks or {}).items()):
            info = tarfile.TarInfo(name)
            info.type = tarfile.SYMTYPE
            info.linkname = target
            info.mode = 0o777
            archive.addfile(info)


def current_run(root, scenario_id, status="PASS", usage=None, judge=None,
                transcript="transcript\n", tar_files=None, host=True):
    directory = Path(root) / scenario_id
    directory.mkdir(parents=True, exist_ok=True)
    report = {
        "id": scenario_id,
        "status": status,
        "usage": usage or {"model_requests": 1, "wall_s": 2.0},
        "assertions": [{"type": "file_exists", "ok": True}],
        "turns": [],
        "perturbations": [],
        "console_errors": [],
        "host_states": [],
    }
    if judge is not None:
        report["judge"] = judge
    write_json(directory / "report.json", report)
    write_file(directory / "transcript.jsonl", transcript)
    make_tar(directory / "workspace.tar", files=tar_files or {"README.md": "payload\n"})
    write_json(directory / "scenario.json", {
        "id": scenario_id,
        "workspace": {"files": {"README.md": "payload\n"}},
    })
    if host:
        make_host_evidence(directory)
    return directory


def make_host_evidence(directory, status="pass"):
    directory = Path(directory)
    for relative in (
        "host/materialized/workspace",
        "host/wal",
        "host/response-log",
    ):
        (directory / relative).mkdir(parents=True, exist_ok=True)
    write_file(directory / "host/journal.xljournal", "journal\n")
    write_json(directory / "host/fence.json", {"owner": "phone", "generation": 1})
    make_tar(directory / "host/overlay-boot.tar", files={"vfs": "overlay\n"})
    if status == "pass":
        write_file(directory / "host/materialized/workspace/README.md", "payload\n")


def worker_command_receipt(assertion_index=0):
    """Minimal valid `pdsh-worker-command/1` receipt for a report fixture."""
    return {
        "protocol": evidence.WORKER_COMMAND_RECEIPT,
        "receipt_id": "wc-fixture",
        "location": {
            "kind": "worker",
            "carrier": "ordered-channel",
            "worker_vfs": True,
            "host_process": False,
            "fork": "memory-vfs",
        },
        "binding": {
            "scenario_id": "G2-X",
            "session_id": "session-1",
            "turn": 0,
            "assertion_index": assertion_index,
            "completion_watermark": 0,
        },
        "source": {
            "kind": "worker-vfs-fork",
            "fork": True,
            "missing_roots": [],
            "source_mseq_start": 4,
            "source_mseq_end": 4,
            "source_frozen": True,
            "missing_roots": [],
            "digest": "sha256:" + "0" * 64,
            "entries": 1,
            "bytes": 8,
        },
        "execution": {
            "program": "bash",
            "cwd": "/dsh/workspace",
            "budget_ms": 1000,
            "duration_ms": 5,
            "exit_code": 0,
            "timed_out": False,
            "cancelled": False,
            "stdout": "worker\n",
            "stderr": "",
            "stdout_bytes": 7,
            "stderr_bytes": 0,
            "stdout_truncated": False,
            "stderr_truncated": False,
        },
        "model_requests": 0,
        "live_workspace_unchanged": True,
        "side_effects": {"isolated": True, "live_workspace": False, "journal": False,
                         "changes": [], "changed": 0},
    }


def worker_command_assertion(assertion_index=0, **updates):
    assertion = {
        "type": "worker_command",
        "command": "printf worker",
        "program": "bash",
        "cwd": "/dsh/workspace",
        "timeout_ms": 1000,
        "ok": True,
        "detail": "worker exit 0",
        "worker_evaluated": True,
        "worker_receipt": worker_command_receipt(assertion_index),
    }
    assertion.update(updates)
    return assertion


def index_of(root, scenario_id):
    document = json.loads((Path(root) / evidence.INDEX_NAME).read_text(encoding="utf-8"))
    return document["scenarios"][scenario_id]


class AttemptHistoryTests(unittest.TestCase):
    def test_rerun_keeps_first_attempt_and_indexes_the_second(self):
        with tempfile.TemporaryDirectory(prefix="pdsh-evidence-history-") as temp:
            first_usage = {"model_requests": 3, "wall_s": 11.5}
            first_judge = {"verdict": "needs work", "score": 1}
            current_run(temp, "G2-X", status="FAIL", usage=first_usage, judge=first_judge)
            first = evidence.refresh_index(temp, "G2-X")
            self.assertEqual(first["attempt"], 1)
            archived = evidence.archive_attempt(temp, "G2-X")
            self.assertIsNotNone(archived)
            self.assertEqual(archived["attempt"], 1)
            self.assertEqual(archived["status"], "FAIL")

            second_usage = {"model_requests": 4, "wall_s": 12.5}
            current_run(temp, "G2-X", status="PASS", usage=second_usage)
            second = evidence.refresh_index(temp, "G2-X")
            self.assertEqual(second["attempt"], 2)

            scenario = index_of(temp, "G2-X")
            self.assertEqual(scenario["current"]["attempt"], 2)
            self.assertEqual(scenario["current"]["status"], "PASS")
            self.assertEqual(scenario["current"]["usage"], second_usage)
            self.assertEqual(len(scenario["attempts"]), 1)
            old = scenario["attempts"][0]
            self.assertEqual(old["attempt"], 1)
            self.assertEqual(old["status"], "FAIL")
            self.assertEqual(old["usage"], first_usage)
            self.assertEqual(old["judge"], first_judge)
            self.assertEqual(old["path"], "G2-X/history/a001")
            self.assertTrue((Path(temp) / "G2-X/history/a001/report.json").is_file())
            self.assertTrue((Path(temp) / "G2-X/history/a001/attempt.json").is_file())
            attempt_document = json.loads(
                (Path(temp) / "G2-X/history/a001/attempt.json").read_text(encoding="utf-8")
            )
            self.assertEqual(attempt_document["attempt"], 1)
            self.assertEqual(attempt_document["status"], "FAIL")
            self.assertEqual(attempt_document["usage"], first_usage)
            self.assertEqual(attempt_document["judge"], first_judge)
            self.assertIn("archived_at", attempt_document)
            self.assertEqual(
                attempt_document["paths"]["report"], "G2-X/history/a001/report.json"
            )
            self.assertEqual(
                attempt_document["paths"]["workspace_tar"],
                "G2-X/history/a001/workspace.tar",
            )

            report = json.loads((Path(temp) / "G2-X/report.json").read_text(encoding="utf-8"))
            self.assertEqual(report["attempt"], 2)
            self.assertEqual(report["attempt_snapshot"]["number"], 2)
            self.assertIn("G2-X/history/a001", report["attempt_snapshot"]["history"])

    def test_attempt_number_never_reuses_an_existing_archive(self):
        with tempfile.TemporaryDirectory(prefix="pdsh-evidence-number-") as temp:
            first = Path(temp) / "G2-X/history/a001"
            first.mkdir(parents=True)
            write_file(first / "report.json", "{}\n")
            current_run(temp, "G2-X")
            record = evidence.archive_attempt(temp, "G2-X")
            self.assertEqual(record["attempt"], 2)
            self.assertEqual(record["paths"]["directory"], "G2-X/history/a002")
            self.assertTrue((Path(temp) / "G2-X/history/a001/report.json").is_file())
            self.assertFalse((Path(temp) / "G2-X/history/a001/attempt.json").exists())

    def test_index_and_attempts_never_use_absolute_paths_and_are_redacted(self):
        with tempfile.TemporaryDirectory(prefix="pdsh-evidence-redact-") as temp:
            host_path = "/" + "Users" + "/demo/private/workspace"
            secret = "sk-" + "abc12345"
            current_run(temp, "G2-X", judge={"note": host_path + " " + secret})
            evidence.refresh_index(temp, "G2-X")
            text = (Path(temp) / evidence.INDEX_NAME).read_text(encoding="utf-8")
            self.assertNotIn(str(Path(temp).resolve()), text)
            self.assertNotIn(host_path, text)
            self.assertNotIn(secret, text)
            self.assertIn("<host-path>", text)

    def test_archive_moves_the_index_pointer_to_the_frozen_report(self):
        with tempfile.TemporaryDirectory(prefix="pdsh-evidence-archive-index-") as temp:
            current_run(temp, "G2-X", status="PASS")
            evidence.refresh_index(temp, "G2-X")
            record = evidence.archive_attempt(temp, "G2-X")
            self.assertIsNotNone(record)
            self.assertEqual(record["attempt"], 1)

            scenario = index_of(temp, "G2-X")
            current = scenario["current"]
            self.assertEqual(current["state"], evidence.CURRENT_STATE_ARCHIVED)
            self.assertEqual(current["attempt"], 1)
            self.assertEqual(
                current["paths"]["report"], "G2-X/history/a001/report.json"
            )
            self.assertTrue((Path(temp) / current["paths"]["report"]).is_file())
            self.assertFalse((Path(temp) / "G2-X/report.json").exists())
            self.assertEqual(scenario["next_attempt"], 2)

            # A runner that dies before writing a report must leave the index on
            # the frozen, existing report -- never on the moved-away current one.
            result = evidence.verify_scenario(temp, "G2-X")
            self.assertFalse(result["ok"])
            self.assertIn("report.json", result["missing"])
            scenario = index_of(temp, "G2-X")
            self.assertEqual(scenario["current"]["state"], evidence.CURRENT_STATE_ARCHIVED)
            self.assertTrue(
                (Path(temp) / scenario["current"]["paths"]["report"]).is_file()
            )

            # Recovery: the next successful attempt replaces current and keeps
            # the frozen attempt in history.
            current_run(temp, "G2-X", status="FAIL")
            info = evidence.refresh_index(temp, "G2-X")
            self.assertEqual(info["attempt"], 2)
            scenario = index_of(temp, "G2-X")
            self.assertEqual(scenario["current"]["state"], evidence.CURRENT_STATE_CURRENT)
            self.assertEqual(scenario["current"]["attempt"], 2)
            self.assertEqual(scenario["current"]["status"], "FAIL")
            self.assertEqual(
                scenario["current"]["paths"]["report"], "G2-X/report.json"
            )
            self.assertTrue((Path(temp) / "G2-X/report.json").is_file())
            self.assertEqual([item["attempt"] for item in scenario["attempts"]], [1])

    def test_clear_without_archive_never_leaves_a_dangling_report_path(self):
        with tempfile.TemporaryDirectory(prefix="pdsh-evidence-clear-index-") as temp:
            current_run(temp, "G2-X")
            evidence.refresh_index(temp, "G2-X")
            removed = evidence.clear_current(temp, "G2-X")
            self.assertIn("report.json", removed)

            scenario = index_of(temp, "G2-X")
            current = scenario["current"]
            self.assertEqual(current["state"], evidence.CURRENT_STATE_CLEARED)
            self.assertNotIn("report", current["paths"])
            self.assertFalse((Path(temp) / "G2-X/report.json").exists())
            result = evidence.verify_scenario(temp, "G2-X")
            self.assertFalse(result["ok"])
            self.assertIn("report.json", result["missing"])

            # Recovery after an early exit (for example a failed build that
            # never produced a new report) allocates the next number.
            current_run(temp, "G2-X", status="FAIL")
            info = evidence.refresh_index(temp, "G2-X")
            self.assertEqual(info["attempt"], 2)
            scenario = index_of(temp, "G2-X")
            self.assertEqual(scenario["current"]["state"], evidence.CURRENT_STATE_CURRENT)
            self.assertTrue(
                (Path(temp) / scenario["current"]["paths"]["report"]).is_file()
            )

    def test_archiving_partial_artifacts_without_report_does_not_publish_archived(self):
        with tempfile.TemporaryDirectory(prefix="pdsh-evidence-partial-archive-") as temp:
            directory = Path(temp) / "G2-X"
            write_file(directory / "transcript.jsonl", "partial runner output\n")

            record = evidence.archive_attempt(temp, "G2-X")

            self.assertIsNotNone(record)
            self.assertEqual(record["status"], "UNKNOWN")
            self.assertEqual(
                record["report_error"],
                "report.json is missing from archived attempt",
            )
            self.assertNotIn("report", record["paths"])
            self.assertTrue(
                (Path(temp) / "G2-X/history/a001/transcript.jsonl").is_file()
            )
            scenario = index_of(temp, "G2-X")
            self.assertEqual(scenario["current"]["state"], evidence.CURRENT_STATE_CLEARED)
            self.assertEqual(scenario["current"]["attempt"], 1)
            self.assertNotIn("report", scenario["current"]["paths"])
            self.assertEqual(scenario["next_attempt"], 2)

    def test_attempt_number_counter_survives_history_gc(self):
        with tempfile.TemporaryDirectory(prefix="pdsh-evidence-gc-") as temp:
            current_run(temp, "G2-X")
            self.assertEqual(evidence.refresh_index(temp, "G2-X")["attempt"], 1)
            self.assertEqual(evidence.archive_attempt(temp, "G2-X")["attempt"], 1)

            current_run(temp, "G2-X")
            self.assertEqual(evidence.refresh_index(temp, "G2-X")["attempt"], 2)
            self.assertEqual(evidence.archive_attempt(temp, "G2-X")["attempt"], 2)

            current_run(temp, "G2-X")
            self.assertEqual(evidence.refresh_index(temp, "G2-X")["attempt"], 3)
            history = Path(temp) / "G2-X/history"
            self.assertTrue(history.is_dir())
            shutil.rmtree(history)

            # GC removed every frozen directory, but the current attempt keeps
            # its own number and the persistent counter is still ahead of the
            # old sequence.
            self.assertEqual(evidence.archive_attempt(temp, "G2-X")["attempt"], 3)
            current_run(temp, "G2-X")
            self.assertEqual(evidence.refresh_index(temp, "G2-X")["attempt"], 4)
            scenario = index_of(temp, "G2-X")
            self.assertEqual(scenario["next_attempt"], 5)
            self.assertEqual([item["attempt"] for item in scenario["attempts"]], [3])

    def test_cli_lifecycle_keeps_index_safe_between_archive_and_finalize(self):
        with tempfile.TemporaryDirectory(prefix="pdsh-evidence-cli-life-") as temp:
            current_run(temp, "G2-X")
            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                self.assertEqual(
                    evidence.main(
                        ["finalize", "--results", temp, "--ids", "G2-X"]
                    ),
                    0,
                )
                self.assertEqual(
                    evidence.main(["archive", "--results", temp, "--ids", "G2-X"]),
                    0,
                )
            scenario = index_of(temp, "G2-X")
            self.assertEqual(scenario["current"]["state"], evidence.CURRENT_STATE_ARCHIVED)
            self.assertTrue(
                (Path(temp) / scenario["current"]["paths"]["report"]).is_file()
            )

            # Simulate an early exit: clear (no-op after archive) then verify
            # without a new report. The CLI fails, but the index must keep
            # pointing at the frozen report, not the moved current one.
            with contextlib.redirect_stdout(stdout):
                self.assertEqual(
                    evidence.main(
                        ["clear-current", "--results", temp, "--ids", "G2-X"]
                    ),
                    0,
                )
                self.assertEqual(
                    evidence.main(
                        ["verify", "--results", temp, "--ids", "G2-X"]
                    ),
                    1,
                )
            scenario = index_of(temp, "G2-X")
            self.assertEqual(scenario["current"]["state"], evidence.CURRENT_STATE_ARCHIVED)
            self.assertTrue(
                (Path(temp) / scenario["current"]["paths"]["report"]).is_file()
            )

            # Recovery: finalize the next report through the same CLI.
            current_run(temp, "G2-X", status="FAIL")
            with contextlib.redirect_stdout(stdout):
                self.assertEqual(
                    evidence.main(
                        ["finalize", "--results", temp, "--ids", "G2-X"]
                    ),
                    0,
                )
            scenario = index_of(temp, "G2-X")
            self.assertEqual(scenario["current"]["attempt"], 2)
            self.assertEqual(scenario["current"]["state"], evidence.CURRENT_STATE_CURRENT)
            self.assertTrue((Path(temp) / "G2-X/report.json").is_file())

    def test_finalize_after_archive_without_new_report_keeps_frozen_paths(self):
        with tempfile.TemporaryDirectory(prefix="pdsh-evidence-cli-arch-") as temp:
            current_run(temp, "G2-X", status="FAIL")
            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                self.assertEqual(
                    evidence.main(
                        ["finalize", "--results", temp, "--ids", "G2-X"]
                    ),
                    0,
                )
                self.assertEqual(
                    evidence.main(["archive", "--results", temp, "--ids", "G2-X"]),
                    0,
                )

            # ARCHIVED is self-describing: its directory is the frozen attempt.
            scenario = index_of(temp, "G2-X")
            self.assertEqual(scenario["current"]["state"], evidence.CURRENT_STATE_ARCHIVED)
            self.assertEqual(
                scenario["current"]["paths"]["directory"], "G2-X/history/a001"
            )

            # Simulate an index written by the old code, which kept the live
            # directory for ARCHIVED; the frozen report parent must still win.
            index_path = Path(temp) / evidence.INDEX_NAME
            index = json.loads(index_path.read_text(encoding="utf-8"))
            index["scenarios"]["G2-X"]["current"]["paths"]["directory"] = "G2-X"
            write_json(index_path, index)

            # A runner that dies before writing a new report can leave partial
            # live artifacts; finalize must not mix them into the frozen paths.
            write_file(Path(temp) / "G2-X/transcript.jsonl", "partial\n")
            make_host_evidence(Path(temp) / "G2-X")
            with contextlib.redirect_stdout(stdout):
                self.assertEqual(
                    evidence.main(
                        ["finalize", "--results", temp, "--ids", "G2-X"]
                    ),
                    0,
                )

            scenario = index_of(temp, "G2-X")
            current = scenario["current"]
            self.assertEqual(current["state"], evidence.CURRENT_STATE_ARCHIVED)
            self.assertEqual(
                current["paths"]["directory"], "G2-X/history/a001"
            )
            self.assertEqual(
                current["paths"]["report"], "G2-X/history/a001/report.json"
            )
            self.assertEqual(
                current["paths"]["transcript"],
                "G2-X/history/a001/transcript.jsonl",
            )
            self.assertEqual(current["paths"]["host"], "G2-X/history/a001/host")
            for key in ("report", "transcript", "host"):
                self.assertTrue((Path(temp) / current["paths"][key]).exists())

            # Recovery still allocates the next number for the new report.
            current_run(temp, "G2-X", status="PASS")
            with contextlib.redirect_stdout(stdout):
                self.assertEqual(
                    evidence.main(
                        ["finalize", "--results", temp, "--ids", "G2-X"]
                    ),
                    0,
                )
            scenario = index_of(temp, "G2-X")
            self.assertEqual(scenario["current"]["attempt"], 2)
            self.assertEqual(scenario["current"]["state"], evidence.CURRENT_STATE_CURRENT)
            self.assertEqual(
                scenario["current"]["paths"]["report"], "G2-X/report.json"
            )

    def test_clear_current_persists_safe_index_before_removing_artifacts(self):
        with tempfile.TemporaryDirectory(prefix="pdsh-evidence-clear-fail-") as temp:
            directory = current_run(temp, "G2-X")
            evidence.refresh_index(temp, "G2-X")
            self.assertTrue((directory / "report.json").is_file())

            # Fail while removing host/, after report.json was already unlinked.
            with mock.patch.object(
                evidence.shutil, "rmtree", side_effect=OSError("injected clear failure")
            ):
                with self.assertRaises(OSError):
                    evidence.clear_current(temp, "G2-X")

            scenario = index_of(temp, "G2-X")
            current = scenario["current"]
            self.assertEqual(current["state"], evidence.CURRENT_STATE_PENDING)
            self.assertNotIn("report", current["paths"])
            for key in evidence.ARTIFACT_KEYS.values():
                self.assertNotIn(key, current["paths"])
            self.assertFalse((directory / "report.json").exists())

            # Recovery removes the remaining artifacts and ends CLEARED.
            removed = evidence.clear_current(temp, "G2-X")
            self.assertIn("host", removed)
            scenario = index_of(temp, "G2-X")
            current = scenario["current"]
            self.assertEqual(current["state"], evidence.CURRENT_STATE_CLEARED)
            self.assertNotIn("report", current["paths"])
            self.assertFalse((directory / "host").exists())

    def test_clear_current_after_history_gc_drops_dangling_archived_paths(self):
        with tempfile.TemporaryDirectory(prefix="pdsh-evidence-clear-gc-") as temp:
            current_run(temp, "G2-X")
            evidence.refresh_index(temp, "G2-X")
            self.assertEqual(evidence.archive_attempt(temp, "G2-X")["attempt"], 1)
            scenario = index_of(temp, "G2-X")
            self.assertEqual(scenario["current"]["state"], evidence.CURRENT_STATE_ARCHIVED)
            frozen_report = Path(temp) / scenario["current"]["paths"]["report"]
            self.assertTrue(frozen_report.is_file())

            shutil.rmtree(Path(temp) / "G2-X/history")
            self.assertFalse(frozen_report.exists())
            evidence.clear_current(temp, "G2-X")

            scenario = index_of(temp, "G2-X")
            current = scenario["current"]
            self.assertEqual(current["state"], evidence.CURRENT_STATE_CLEARED)
            self.assertNotIn("report", current["paths"])
            for key in evidence.ARTIFACT_KEYS.values():
                self.assertNotIn(key, current["paths"])
            for value in current["paths"].values():
                if value.endswith("report.json"):
                    self.fail("dangling report path in index: {}".format(value))

            # GC still must not make the next attempt reuse number 1.
            current_run(temp, "G2-X")
            self.assertEqual(evidence.refresh_index(temp, "G2-X")["attempt"], 2)

    def test_clear_current_keeps_history_and_index(self):
        with tempfile.TemporaryDirectory(prefix="pdsh-evidence-clear-") as temp:
            current_run(temp, "G2-X")
            evidence.refresh_index(temp, "G2-X")
            record = evidence.archive_attempt(temp, "G2-X")
            self.assertIsNotNone(record)
            current_run(temp, "G2-X", status="FAIL")
            removed = evidence.clear_current(temp, "G2-X")
            self.assertIn("report.json", removed)
            self.assertFalse((Path(temp) / "G2-X/report.json").exists())
            self.assertTrue((Path(temp) / "G2-X/history/a001/report.json").is_file())
            self.assertTrue((Path(temp) / evidence.INDEX_NAME).is_file())


class GitRepairTests(unittest.TestCase):
    def test_tar_git_is_restored_without_overwriting_non_git_files(self):
        with tempfile.TemporaryDirectory(prefix="pdsh-evidence-git-") as temp:
            directory = current_run(
                temp, "G2-X", tar_files={"README.md": "from tar\n", ".git/config": "gitcfg\n"}
            )
            materialized = directory / "host/materialized/workspace"
            write_file(materialized / "README.md", "keep me\n")
            write_file(materialized / "other.txt", "present\n")
            check = directory / "check-workspace"
            write_file(check / "README.md", "check copy\n")

            repairs = evidence.reconcile_workspace_git(temp, "G2-X", require_git=True)
            self.assertEqual(len(repairs), 2)
            self.assertEqual(
                (materialized / ".git/config").read_text(encoding="utf-8"), "gitcfg\n"
            )
            self.assertEqual(
                (materialized / "README.md").read_text(encoding="utf-8"), "keep me\n"
            )
            self.assertEqual(
                (materialized / "other.txt").read_text(encoding="utf-8"), "present\n"
            )
            self.assertFalse((materialized / "from tar").exists())
            self.assertEqual((check / ".git/config").read_text(encoding="utf-8"), "gitcfg\n")
            self.assertEqual((check / "README.md").read_text(encoding="utf-8"), "check copy\n")
            self.assertIn("G2-FIX-110", repairs[0]["reason"])

    def test_missing_git_everywhere_fails_loud(self):
        with tempfile.TemporaryDirectory(prefix="pdsh-evidence-nogit-") as temp:
            directory = current_run(temp, "G2-X", tar_files={"README.md": "payload\n"})
            materialized = directory / "host/materialized/workspace"
            self.assertFalse((materialized / ".git").exists())
            with self.assertRaises(evidence.EvidenceError) as caught:
                evidence.reconcile_workspace_git(temp, "G2-X", require_git=True)
            self.assertEqual(caught.exception.code, "G2-FIX-110")
            self.assertIn("G2-FIX-110", str(caught.exception))
            self.assertFalse((materialized / ".git").exists())

    def test_post_host_finalize_keeps_repairs_and_updates_the_final_status(self):
        with tempfile.TemporaryDirectory(prefix="pdsh-evidence-host-") as temp:
            directory = current_run(
                temp, "G2-X", tar_files={"README.md": "payload\n", ".git/config": "cfg\n"}
            )
            first = evidence.refresh_index(
                temp, "G2-X",
                staging_repairs=evidence.reconcile_workspace_git(temp, "G2-X"),
            )
            self.assertEqual(first["attempt"], 1)
            self.assertEqual(len(first["staging_repairs"]), 1)

            # The host phase rewrites report.json through JSONSerialization; it
            # must still carry the attempt snapshot and staging repairs.
            report_path = directory / "report.json"
            report = json.loads(report_path.read_text(encoding="utf-8"))
            report["status"] = "FAIL"
            report_path.write_text(json.dumps(report) + "\n", encoding="utf-8")
            second = evidence.refresh_index(temp, "G2-X")
            self.assertEqual(second["attempt"], 1)
            self.assertEqual(index_of(temp, "G2-X")["current"]["status"], "FAIL")
            final_report = json.loads(report_path.read_text(encoding="utf-8"))
            self.assertEqual(final_report["attempt"], 1)
            self.assertNotIn("error", final_report["staging_repairs"][0])
            self.assertIn("G2-FIX-110", final_report["staging_repairs"][0]["reason"])

    def test_finalize_records_git_failure_and_still_refreshes_the_index(self):
        with tempfile.TemporaryDirectory(prefix="pdsh-evidence-gitfail-") as temp:
            directory = current_run(temp, "G2-X", tar_files={"README.md": "payload\n"})
            code = evidence.main(
                ["finalize", "--results", temp, "--ids", "G2-X", "--require-git"]
            )
            self.assertEqual(code, 1)
            scenario = index_of(temp, "G2-X")
            self.assertEqual(scenario["current"]["attempt"], 1)
            self.assertEqual(scenario["current"]["status"], "PASS")
            report = json.loads((directory / "report.json").read_text(encoding="utf-8"))
            self.assertEqual(report["staging_repairs"][0]["code"], "G2-FIX-110")
            self.assertFalse((directory / "host/materialized/workspace/.git").exists())

    def test_git_fixture_expectation_comes_from_the_scenario_definition(self):
        with tempfile.TemporaryDirectory(prefix="pdsh-evidence-fixture-") as temp:
            fixtures = Path(temp) / "fixtures"
            write_json(fixtures / "repo" / "fixture.json", {"name": "repo", "git": {}})
            directory = current_run(temp, "G2-X", tar_files={"README.md": "payload\n"})
            write_json(directory / "scenario.json", {
                "id": "G2-X",
                "workspace": {"fixture": "repo", "files": {}},
            })
            with self.assertRaises(evidence.EvidenceError):
                evidence.reconcile_workspace_git(
                    temp, "G2-X", fixtures_root=fixtures, require_git=None
                )

    def test_default_fixture_root_detects_git_fixture_for_verify_and_finalize(self):
        # Regression: the default fixtures root used to resolve to
        # ``scripts/scripts/ci/scenarios/fixtures``, so a git fixture was not
        # recognised and the fail-loud G2-FIX-110 check was silently disabled.
        with tempfile.TemporaryDirectory(prefix="pdsh-evidence-defaultfix-") as temp:
            directory = current_run(temp, "G2-X", tar_files={"README.md": "payload\n"})
            write_json(directory / "scenario.json", {
                "id": "G2-X",
                "workspace": {"fixture": "csv-pipeline", "files": {}},
            })
            self.assertFalse(
                (directory / "host/materialized/workspace/.git").exists()
            )
            code = evidence.main(["verify", "--results", temp, "--ids", "G2-X"])
            self.assertEqual(code, 1)
            missing = json.loads(
                (directory / "evidence_missing.json").read_text(encoding="utf-8")
            )
            self.assertFalse(missing["ok"])
            self.assertTrue(
                any("G2-FIX-110" in error for error in missing.get("errors", []))
            )
            self.assertFalse(
                (directory / "host/materialized/workspace/.git").exists()
            )

            code = evidence.main(["finalize", "--results", temp, "--ids", "G2-X"])
            self.assertEqual(code, 1)
            report = json.loads(
                (directory / "report.json").read_text(encoding="utf-8")
            )
            self.assertEqual(report["staging_repairs"][0]["code"], "G2-FIX-110")
            self.assertFalse(
                (directory / "host/materialized/workspace/.git").exists()
            )

    def test_unsafe_tar_members_are_rejected(self):
        with tempfile.TemporaryDirectory(prefix="pdsh-evidence-unsafe-") as temp:
            directory = current_run(temp, "G2-X", tar_files={".git/config": "ok\n"})
            unsafe_cases = [
                ({"../.git/config": "x\n"}, None),
                ({"/.git/config": "x\n"}, None),
                ({".git/link": ""}, {".git/link": "../../escape"}),
            ]
            for files, symlinks in unsafe_cases:
                if symlinks:
                    files = {}
                make_tar(directory / "workspace.tar", files=files, symlinks=symlinks)
                with self.assertRaises(evidence.EvidenceError) as caught:
                    evidence.reconcile_workspace_git(temp, "G2-X", require_git=True)
                self.assertEqual(caught.exception.code, "G2-FIX-110")
                self.assertFalse((directory / "host/materialized/workspace/.git").exists())


class VerificationTests(unittest.TestCase):
    def test_timeout_without_wal_or_journal_fails_and_lists_both(self):
        with tempfile.TemporaryDirectory(prefix="pdsh-evidence-timeout-") as temp:
            directory = current_run(temp, "G2-X", status="TIMEOUT", host=False)
            make_host_evidence(directory)
            # Remove the two artifacts a partial abort used to leave behind.
            (directory / "host/wal").rmdir()
            (directory / "host/journal.xljournal").unlink()

            result = evidence.verify_scenario(temp, "G2-X")
            self.assertFalse(result["ok"])
            self.assertIn("host/wal", result["missing"])
            self.assertIn("host/journal.xljournal", result["missing"])
            missing = json.loads(
                (directory / "evidence_missing.json").read_text(encoding="utf-8")
            )
            self.assertFalse(missing["ok"])
            self.assertEqual(missing["status"], "TIMEOUT")
            self.assertIn("host/wal", missing["missing"])
            self.assertIn("host/journal.xljournal", missing["missing"])

            (directory / "host/wal").mkdir()
            write_file(directory / "host/journal.xljournal", "journal\n")
            repaired = evidence.verify_scenario(temp, "G2-X")
            self.assertTrue(repaired["ok"])
            self.assertFalse((directory / "evidence_missing.json").exists())

    def test_skip_requires_only_definition_evidence_and_marks_host_not_applicable(self):
        with tempfile.TemporaryDirectory(prefix="pdsh-evidence-skip-") as temp:
            directory = Path(temp) / "G2-X"
            write_json(directory / "report.json", {
                "id": "G2-X",
                "status": "SKIP",
                "usage": {"wall_s": 0.0},
                "assertions": [],
                "turns": [],
                "perturbations": [],
                "console_errors": [],
                "host_states": [],
            })
            write_file(directory / "transcript.jsonl", "")
            write_json(directory / "scenario.json", {"id": "G2-X", "workspace": {"files": {}}})
            write_json(directory / "evidence_missing.json", {"stale": True})

            result = evidence.verify_scenario(temp, "G2-X")
            self.assertTrue(result["ok"], result)
            self.assertFalse((directory / "evidence_missing.json").exists())
            self.assertIn("host/wal", result["not_applicable"])
            self.assertNotIn("host/wal", result["required"])
            self.assertNotIn("workspace.tar", result["required"])

    def test_missing_report_is_never_a_silent_pass(self):
        with tempfile.TemporaryDirectory(prefix="pdsh-evidence-noreport-") as temp:
            (Path(temp) / "G2-X").mkdir()
            result = evidence.verify_scenario(temp, "G2-X")
            self.assertFalse(result["ok"])
            self.assertIn("report.json", result["missing"])
            self.assertTrue((Path(temp) / "G2-X/evidence_missing.json").is_file())

    def test_cli_verify_exits_nonzero_and_writes_missing(self):
        with tempfile.TemporaryDirectory(prefix="pdsh-evidence-cli-") as temp:
            current_run(temp, "G2-X", status="ERROR", host=False)
            code = evidence.main(
                ["verify", "--results", temp, "--ids", "G2-X", "--no-reconcile-git"]
            )
            self.assertEqual(code, 1)
            self.assertTrue((Path(temp) / "G2-X/evidence_missing.json").is_file())


    def test_non_object_reports_are_structure_failures_not_unknown_passes(self):
        for payload in ([], None, "PASS"):
            with self.subTest(payload=payload):
                with tempfile.TemporaryDirectory(prefix="pdsh-evidence-struct-") as temp:
                    directory = Path(temp) / "G2-X"
                    directory.mkdir(parents=True)
                    write_json(directory / "report.json", payload)
                    result = evidence.verify_scenario(
                        temp, "G2-X", reconcile=False
                    )
                    self.assertFalse(result["ok"], result)
                    self.assertEqual(result["code"], evidence.REPORT_STRUCTURE_CODE)
                    self.assertTrue(
                        any(
                            "not a JSON object" in error
                            for error in result.get("errors", [])
                        ),
                        result,
                    )
                    written = json.loads(
                        (directory / "evidence_missing.json").read_text(
                            encoding="utf-8"
                        )
                    )
                    self.assertFalse(written["ok"])
                    self.assertEqual(
                        written["code"], evidence.REPORT_STRUCTURE_CODE
                    )

    def test_unknown_status_and_missing_fields_fail_closed(self):
        with tempfile.TemporaryDirectory(prefix="pdsh-evidence-unknown-") as temp:
            directory = current_run(temp, "G2-X")
            report = json.loads(
                (directory / "report.json").read_text(encoding="utf-8")
            )
            report["status"] = "NOT_A_STATUS"
            write_json(directory / "report.json", report)
            result = evidence.verify_scenario(temp, "G2-X")
            self.assertFalse(result["ok"], result)
            self.assertEqual(result["code"], evidence.REPORT_STRUCTURE_CODE)
            self.assertTrue(
                any("unknown status" in error for error in result["errors"]),
                result,
            )

            write_json(directory / "report.json", {
                "id": "G2-X",
                "status": "PASS",
            })
            result = evidence.verify_scenario(temp, "G2-X")
            self.assertFalse(result["ok"], result)
            self.assertEqual(result["code"], evidence.REPORT_STRUCTURE_CODE)
            for field in ("assertions", "turns", "perturbations", "usage",
                          "console_errors", "host_states"):
                self.assertTrue(
                    any(field in error for error in result["errors"]),
                    (field, result),
                )

    def test_structure_failure_and_scenario_fail_have_distinct_report_check_codes(self):
        with tempfile.TemporaryDirectory(prefix="pdsh-evidence-reportcheck-") as temp:
            catalog = Path(temp) / "catalog.json"
            write_json(catalog, {
                "version": 1,
                "scenarios": [{"id": "G2-X", "tags": [], "target": "macos"}],
            })
            results = Path(temp) / "results"
            current_run(results, "G2-X", status="FAIL", host=False)

            # A real scenario verdict is exit 5 even when the host evidence is
            # incomplete (verify alone would say exit 1).
            self.assertFalse(
                evidence.verify_scenario(str(results), "G2-X")["ok"]
            )
            code, lines = evidence.check_reports(catalog, results)
            self.assertEqual(code, 5, lines)
            self.assertTrue(
                any("final status(es): G2-X=FAIL" in line for line in lines),
                lines,
            )

            directory = results / "G2-X"
            write_json(directory / "report.json", [])
            code, lines = evidence.check_reports(catalog, results)
            self.assertEqual(code, 4, lines)
            self.assertTrue(
                any("invalid report" in line for line in lines), lines
            )

            write_json(directory / "report.json", {
                "id": "G2-X",
                "status": "PASS",
            })
            code, lines = evidence.check_reports(catalog, results)
            self.assertEqual(code, 4, lines)
            self.assertTrue(
                any("missing required field" in line for line in lines), lines
            )

    def test_report_identity_must_match_its_scenario_directory(self):
        with tempfile.TemporaryDirectory(prefix="pdsh-evidence-report-id-") as temp:
            results = Path(temp) / "results"
            directory = current_run(results, "G2-Y", status="PASS")
            report = json.loads((directory / "report.json").read_text(encoding="utf-8"))
            report["id"] = "G2-X"
            write_json(directory / "report.json", report)

            verified = evidence.verify_scenario(
                results, "G2-Y", reconcile=False
            )
            self.assertFalse(verified["ok"], verified)
            self.assertEqual(verified["code"], evidence.REPORT_STRUCTURE_CODE)
            self.assertTrue(
                any("does not match scenario directory" in error
                    for error in verified["errors"]),
                verified,
            )

            catalog = Path(temp) / "catalog.json"
            write_json(catalog, {
                "version": 1,
                "scenarios": [{"id": "G2-X", "tags": [], "target": "macos"}],
            })
            report["id"] = "G2-Y"
            selected_slot = results / "G2-X" / "report.json"
            write_json(selected_slot, report)
            code, lines = evidence.check_reports(catalog, results)
            self.assertEqual(code, 4, lines)
            self.assertTrue(
                any("does not match scenario directory" in line for line in lines),
                lines,
            )

    def test_nested_report_shapes_fail_closed_without_report_check_traceback(self):
        malformed_fields = (
            ("assertions", [{"type": "file_exists", "ok": "yes"}], "PASS",
             "assertion 0 field 'ok' is not a boolean"),
            ("turns", ["malformed"], "PASS", "turns item 0 is not an object"),
            ("perturbations", ["malformed"], "INFRA",
             "perturbations item 0 is not an object"),
            ("console_errors", [7], "PASS",
             "console_errors item 0 is not a string"),
            ("host_states", [7], "PASS",
             "host_states item 0 is not a string"),
        )
        with tempfile.TemporaryDirectory(prefix="pdsh-evidence-nested-shape-") as temp:
            results = Path(temp) / "results"
            catalog = Path(temp) / "catalog.json"
            write_json(catalog, {
                "version": 1,
                "scenarios": [{"id": "G2-X", "tags": [], "target": "macos"}],
            })
            for field, value, status, message in malformed_fields:
                with self.subTest(field=field):
                    directory = current_run(
                        results, "G2-X", status=status, host=status != "INFRA"
                    )
                    report = json.loads(
                        (directory / "report.json").read_text(encoding="utf-8")
                    )
                    report[field] = value
                    write_json(directory / "report.json", report)

                    verified = evidence.verify_scenario(
                        results, "G2-X", reconcile=False
                    )
                    self.assertFalse(verified["ok"], verified)
                    self.assertEqual(
                        verified["code"], evidence.REPORT_STRUCTURE_CODE
                    )
                    self.assertTrue(
                        any(message in error for error in verified["errors"]),
                        verified,
                    )

                    code, lines = evidence.check_reports(
                        catalog, results, only="G2-X"
                    )
                    self.assertEqual(code, 4, lines)
                    self.assertTrue(any(message in line for line in lines), lines)

    def test_archive_does_not_index_malformed_report_as_pass(self):
        with tempfile.TemporaryDirectory(prefix="pdsh-evidence-archive-shape-") as temp:
            directory = current_run(temp, "G2-X", status="PASS")
            report = json.loads(
                (directory / "report.json").read_text(encoding="utf-8")
            )
            report["perturbations"] = ["malformed"]
            write_json(directory / "report.json", report)

            archived = evidence.archive_attempt(temp, "G2-X")
            self.assertIsNotNone(archived)
            self.assertEqual(archived["status"], "UNKNOWN")
            self.assertTrue(archived.get("report_errors"))
            scenario = index_of(temp, "G2-X")
            self.assertEqual(scenario["current"]["state"],
                             evidence.CURRENT_STATE_ARCHIVED)
            self.assertEqual(scenario["current"]["status"], "UNKNOWN")

    def test_report_check_exit_codes_and_cli(self):
        with tempfile.TemporaryDirectory(prefix="pdsh-evidence-reportcheck2-") as temp:
            catalog = Path(temp) / "catalog.json"
            write_json(catalog, {
                "version": 1,
                "scenarios": [
                    {"id": "G2-PASS", "tags": [], "target": "macos"},
                    {"id": "G2-SKIP", "tags": [], "target": "macos"},
                ],
            })
            results = Path(temp) / "results"
            current_run(results, "G2-PASS", status="PASS")
            current_run(results, "G2-SKIP", status="SKIP", host=False)
            code, lines = evidence.check_reports(catalog, results)
            self.assertEqual(code, 0, lines)

            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                code = evidence.main([
                    "report-check",
                    "--catalog", str(catalog),
                    "--results", str(results),
                ])
            self.assertEqual(code, 0)
            self.assertIn("scenarios: reports", stdout.getvalue())

            (results / "G2-PASS/report.json").unlink()
            code, lines = evidence.check_reports(catalog, results)
            self.assertEqual(code, 4, lines)
            self.assertTrue(
                any("wrote no report" in line for line in lines), lines
            )

    def test_unselected_reports_do_not_affect_the_selected_gate(self):
        with tempfile.TemporaryDirectory(prefix="pdsh-evidence-unselected-") as temp:
            catalog = Path(temp) / "catalog.json"
            write_json(catalog, {
                "version": 1,
                "scenarios": [{"id": "G2-SELECTED", "tags": [], "target": "macos"}],
            })
            results = Path(temp) / "results"
            current_run(results, "G2-SELECTED", status="PASS")
            # This old run is not in the selection. Its report must be ignored,
            # even when it is structurally invalid.
            current_run(results, "G2-OLD", status="UNKNOWN", host=False)
            code, lines = evidence.check_reports(catalog, results)
            self.assertEqual(code, 0, lines)
            self.assertFalse(any("G2-OLD" in line for line in lines), lines)

            write_json(results / "G2-OLD/report.json", [])
            code, lines = evidence.check_reports(catalog, results)
            self.assertEqual(code, 0, lines)
            self.assertFalse(any("G2-OLD" in line for line in lines), lines)

            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                code = evidence.main([
                    "report-check",
                    "--catalog", str(catalog),
                    "--results", str(results),
                ])
            self.assertEqual(code, 0)
            self.assertNotIn("G2-OLD", stdout.getvalue())

    def test_wrong_directory_or_id_cannot_impersonate_a_selected_report(self):
        with tempfile.TemporaryDirectory(prefix="pdsh-evidence-impersonate-") as temp:
            catalog = Path(temp) / "catalog.json"
            write_json(catalog, {
                "version": 1,
                "scenarios": [{"id": "G2-SELECTED", "tags": [], "target": "macos"}],
            })
            results = Path(temp) / "results"
            current_run(results, "G2-SELECTED", status="PASS")
            # Move the complete report to another directory. A report that
            # claims the selected id from the wrong directory is not the
            # selected scenario's report.
            shutil.move(str(results / "G2-SELECTED"), str(results / "G2-OTHER"))
            code, lines = evidence.check_reports(catalog, results)
            self.assertEqual(code, 4, lines)
            self.assertTrue(
                any("G2-SELECTED was selected but wrote no report" in line
                    for line in lines),
                lines,
            )

            # A report in the selected directory must also name that scenario.
            current_run(results, "G2-SELECTED", status="PASS")
            report_path = results / "G2-SELECTED/report.json"
            report = json.loads(report_path.read_text(encoding="utf-8"))
            report["id"] = "G2-OTHER"
            write_json(report_path, report)
            code, lines = evidence.check_reports(catalog, results)
            self.assertEqual(code, 4, lines)
            self.assertTrue(
                any("does not match scenario directory" in line for line in lines),
                lines,
            )

            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                code = evidence.main([
                    "report-check",
                    "--catalog", str(catalog),
                    "--results", str(results),
                ])
            self.assertEqual(code, 4)
            self.assertIn("does not match scenario directory", stdout.getvalue())

    def test_verify_rejects_a_report_written_for_another_scenario_id(self):
        with tempfile.TemporaryDirectory(prefix="pdsh-evidence-wrongid-") as temp:
            directory = current_run(temp, "G2-A")
            report_path = directory / "report.json"
            report = json.loads(report_path.read_text(encoding="utf-8"))
            report["id"] = "G2-B"
            write_json(report_path, report)

            result = evidence.verify_scenario(temp, "G2-A")
            self.assertFalse(result["ok"], result)
            self.assertEqual(result["code"], evidence.REPORT_STRUCTURE_CODE)
            self.assertTrue(
                any("does not match scenario directory" in error
                    for error in result["errors"]),
                result,
            )
            written = json.loads(
                (directory / "evidence_missing.json").read_text(encoding="utf-8")
            )
            self.assertFalse(written["ok"])
            self.assertEqual(written["code"], evidence.REPORT_STRUCTURE_CODE)

            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                code = evidence.main([
                    "verify", "--results", temp, "--ids", "G2-A",
                    "--no-reconcile-git",
                ])
            self.assertEqual(code, 1)
            self.assertIn("REPORT STRUCTURE INVALID", stdout.getvalue())
            self.assertNotIn("evidence complete", stdout.getvalue())

    def test_infra_report_has_its_own_report_check_exit(self):
        with tempfile.TemporaryDirectory(prefix="pdsh-evidence-infra-") as temp:
            catalog = Path(temp) / "catalog.json"
            write_json(catalog, {
                "version": 1,
                "scenarios": [{"id": "G2-X", "tags": [], "target": "macos"}],
            })
            results = Path(temp) / "results"
            current_run(results, "G2-X", status="INFRA", host=False)
            code, lines = evidence.check_reports(catalog, results)
            self.assertEqual(code, 6, lines)
            self.assertTrue(
                any("RUNNER-INFRA" in line for line in lines), lines
            )

    def test_checked_in_scenario_reports_match_the_validated_schema(self):
        root = HERE.parents[1]
        paths = sorted(
            list((root / "examples/probe-app/scenario-evidence").glob("*/report.json"))
            + list((root / "plugins/tests/scenario-evidence").glob("*/report.json"))
        )
        self.assertTrue(paths)
        for path in paths:
            report = json.loads(path.read_text(encoding="utf-8"))
            self.assertEqual(
                evidence.report_structure_errors(report), [], str(path)
            )


class WorkerCommandEvidenceTests(unittest.TestCase):
    """A Worker assertion is only valid with a real Worker receipt."""

    def _report(self, temp, assertion, status="PASS"):
        directory = current_run(temp, "G2-X", status=status)
        report = json.loads((directory / "report.json").read_text(encoding="utf-8"))
        report["assertions"] = [assertion]
        write_json(directory / "report.json", report)
        return evidence.verify_scenario(temp, "G2-X")

    def test_a_complete_worker_receipt_verifies(self):
        with tempfile.TemporaryDirectory(prefix="pdsh-evidence-worker-") as temp:
            result = self._report(temp, worker_command_assertion())
            self.assertTrue(result["ok"], result)

    def test_a_missing_worker_receipt_fails_closed(self):
        with tempfile.TemporaryDirectory(prefix="pdsh-evidence-worker-") as temp:
            assertion = worker_command_assertion()
            assertion.pop("worker_receipt")
            result = self._report(temp, assertion)
            self.assertFalse(result["ok"], result)
            self.assertEqual(result["code"], evidence.REPORT_STRUCTURE_CODE)
            self.assertTrue(any("worker_receipt" in error for error in result["errors"]), result)

    def test_a_host_or_model_claim_in_the_receipt_fails_closed(self):
        with tempfile.TemporaryDirectory(prefix="pdsh-evidence-worker-") as temp:
            assertion = worker_command_assertion()
            receipt = assertion["worker_receipt"]
            receipt["location"]["host_process"] = True
            result = self._report(temp, assertion)
            self.assertFalse(result["ok"], result)
            self.assertTrue(any("host_process" in error for error in result["errors"]), result)

            assertion = worker_command_assertion()
            assertion["worker_receipt"]["model_requests"] = 1
            result = self._report(temp, assertion)
            self.assertFalse(result["ok"], result)
            self.assertTrue(any("model_requests" in error for error in result["errors"]), result)

            assertion = worker_command_assertion()
            assertion["worker_receipt"]["binding"]["assertion_index"] = 9
            result = self._report(temp, assertion)
            self.assertFalse(result["ok"], result)
            self.assertTrue(any("assertion_index" in error for error in result["errors"]), result)

    def test_a_desktop_carrier_foreign_binding_or_moving_source_fails_closed(self):
        with tempfile.TemporaryDirectory(prefix="pdsh-evidence-worker-") as temp:
            assertion = worker_command_assertion()
            assertion["worker_receipt"]["location"]["carrier"] = "surface-process"
            result = self._report(temp, assertion)
            self.assertFalse(result["ok"], result)
            self.assertTrue(any("carrier" in error for error in result["errors"]), result)

            assertion = worker_command_assertion()
            assertion["worker_receipt"]["binding"]["scenario_id"] = "G2-OTHER"
            result = self._report(temp, assertion)
            self.assertFalse(result["ok"], result)
            self.assertTrue(any("scenario_id" in error for error in result["errors"]), result)

            assertion = worker_command_assertion()
            assertion["worker_receipt"]["source"]["source_mseq_end"] = 5
            result = self._report(temp, assertion)
            self.assertFalse(result["ok"], result)
            self.assertTrue(any("mseq" in error for error in result["errors"]), result)

            assertion = worker_command_assertion()
            assertion["worker_receipt"]["source"]["source_frozen"] = False
            result = self._report(temp, assertion)
            self.assertFalse(result["ok"], result)
            self.assertTrue(any("source_frozen" in error for error in result["errors"]), result)

            assertion = worker_command_assertion()
            assertion["worker_receipt"]["source"]["missing_roots"] = ["/dsh/workspace"]
            result = self._report(temp, assertion)
            self.assertFalse(result["ok"], result)
            self.assertTrue(any("missing_roots" in error for error in result["errors"]), result)

            assertion = worker_command_assertion()
            assertion["worker_receipt"]["source"].pop("missing_roots")
            result = self._report(temp, assertion)
            self.assertFalse(result["ok"], result)
            self.assertTrue(any("missing_roots" in error for error in result["errors"]), result)

            assertion = worker_command_assertion()
            assertion["worker_receipt"]["source"].pop("source_mseq_start")
            result = self._report(temp, assertion)
            self.assertFalse(result["ok"], result)
            self.assertTrue(any("source_mseq_start" in error for error in result["errors"]), result)

    def test_binding_watermark_missing_roots_and_side_effects_are_strict(self):
        with tempfile.TemporaryDirectory(prefix="pdsh-evidence-worker-") as temp:
            assertion = worker_command_assertion()
            assertion["worker_receipt"]["binding"].pop("completion_watermark")
            result = self._report(temp, assertion)
            self.assertFalse(result["ok"], result)
            self.assertTrue(any("completion_watermark" in error for error in result["errors"]), result)

            assertion = worker_command_assertion()
            assertion["worker_receipt"]["binding"]["completion_watermark"] = "0"
            result = self._report(temp, assertion)
            self.assertFalse(result["ok"], result)
            self.assertTrue(any("completion_watermark" in error for error in result["errors"]), result)

            assertion = worker_command_assertion()
            assertion["worker_receipt"]["source"].pop("missing_roots")
            result = self._report(temp, assertion)
            self.assertFalse(result["ok"], result)
            self.assertTrue(any("missing_roots" in error for error in result["errors"]), result)

            assertion = worker_command_assertion()
            assertion["worker_receipt"]["source"]["missing_roots"] = ["/dsh/home"]
            result = self._report(temp, assertion)
            self.assertFalse(result["ok"], result)
            self.assertTrue(any("missing_roots" in error for error in result["errors"]), result)

            assertion = worker_command_assertion()
            assertion["worker_receipt"]["source"]["missing_roots"] = [7]
            result = self._report(temp, assertion)
            self.assertFalse(result["ok"], result)
            self.assertTrue(any("missing_roots" in error for error in result["errors"]), result)

            for field in ("live_workspace", "journal"):
                assertion = worker_command_assertion()
                assertion["worker_receipt"]["side_effects"][field] = True
                result = self._report(temp, assertion)
                self.assertFalse(result["ok"], result)
                self.assertTrue(any(field in error for error in result["errors"]), (field, result))

                assertion = worker_command_assertion()
                assertion["worker_receipt"]["side_effects"].pop(field)
                result = self._report(temp, assertion)
                self.assertFalse(result["ok"], result)
                self.assertTrue(any(field in error for error in result["errors"]), (field, result))

    def test_execution_must_match_the_declared_request_and_report_a_failure(self):
        with tempfile.TemporaryDirectory(prefix="pdsh-evidence-worker-") as temp:
            cases = (
                ("program", "python3", "execution.program"),
                ("cwd", "/dsh/home", "execution.cwd"),
                ("timeout_ms", 2000, "execution.budget_ms"),
            )
            for field, value, needle in cases:
                with self.subTest(field=field):
                    assertion = worker_command_assertion()
                    assertion[field] = value
                    result = self._report(temp, assertion)
                    self.assertFalse(result["ok"], result)
                    self.assertTrue(
                        any(needle in error for error in result["errors"]),
                        (needle, result),
                    )

            assertion = worker_command_assertion()
            assertion["worker_receipt"]["execution"].update(
                exit_code=124, timed_out=True
            )
            result = self._report(temp, assertion)
            self.assertFalse(result["ok"], result)
            self.assertEqual(result["code"], evidence.REPORT_STRUCTURE_CODE)
            self.assertTrue(
                any("failed execution ok:true" in error for error in result["errors"]),
                result,
            )

            assertion = worker_command_assertion()
            assertion["worker_receipt"]["execution"]["cancelled"] = True
            result = self._report(temp, assertion)
            self.assertFalse(result["ok"], result)
            self.assertTrue(
                any("failed execution ok:true" in error for error in result["errors"]),
                result,
            )

    def test_redacted_request_and_receipt_still_match(self):
        # The Swift report redacts the top-level request facts and the whole
        # receipt with the same redactor. A secret in program/cwd therefore
        # becomes the same <redacted> text on both sides and must verify.
        with tempfile.TemporaryDirectory(prefix="pdsh-evidence-worker-") as temp:
            assertion = worker_command_assertion()
            assertion["program"] = "python3-<redacted>"
            assertion["cwd"] = "/dsh/workspace/<redacted>/<redacted>"
            assertion["worker_receipt"]["execution"].update(
                program=assertion["program"], cwd=assertion["cwd"]
            )
            result = self._report(temp, assertion)
            self.assertTrue(result["ok"], result)

    def test_expected_timeout_failure_keeps_complete_evidence(self):
        for status in ("FAIL", "TIMEOUT"):
            with self.subTest(status=status):
                with tempfile.TemporaryDirectory(prefix="pdsh-evidence-worker-") as temp:
                    directory = current_run(temp, "G2-X", status=status)
                    report = json.loads(
                        (directory / "report.json").read_text(encoding="utf-8")
                    )
                    assertion = worker_command_assertion()
                    assertion["ok"] = False
                    assertion["detail"] = "worker exit 124 (timed out)"
                    assertion["worker_receipt"]["execution"].update(
                        exit_code=124, timed_out=True
                    )
                    report["assertions"] = [assertion]
                    if status == "TIMEOUT":
                        report["run_completed"] = False
                        report["run_incomplete_reason"] = (
                            "the run ended with status TIMEOUT; "
                            "1 delivered turn(s) have no terminal end (ended is null)"
                        )
                    else:
                        report["run_completed"] = True
                    write_json(directory / "report.json", report)

                    result = evidence.verify_scenario(
                        temp, "G2-X", reconcile=False
                    )
                    self.assertTrue(result["ok"], result)
                    self.assertEqual(result["missing"], [])
                    self.assertFalse((directory / "evidence_missing.json").exists())

                    catalog = Path(temp) / "catalog.json"
                    write_json(catalog, {
                        "version": 1,
                        "scenarios": [{"id": "G2-X", "tags": [], "target": "macos"}],
                    })
                    code, lines = evidence.check_reports(catalog, temp)
                    self.assertEqual(code, 5, lines)
                    self.assertFalse(
                        any("run_completed" in line for line in lines), lines
                    )

                    record = evidence.archive_attempt(temp, "G2-X")
                    self.assertEqual(record["status"], status)
                    self.assertNotIn("report_error", record)
                    self.assertNotIn("report_errors", record)

    def test_not_executed_may_omit_the_receipt_on_a_non_pass_report(self):
        for status in ("FAIL", "TIMEOUT"):
            with self.subTest(status=status):
                with tempfile.TemporaryDirectory(prefix="pdsh-evidence-worker-") as temp:
                    result = self._report(temp, {
                        "type": "worker_command",
                        "ok": False,
                        "status": "NOT_EXECUTED",
                        "detail": "not executed: the scenario run did not complete",
                    }, status=status)
                    self.assertTrue(result["ok"], result)

    def test_a_pass_report_cannot_contain_a_not_executed_assertion(self):
        with tempfile.TemporaryDirectory(prefix="pdsh-evidence-worker-") as temp:
            result = self._report(temp, {
                "type": "worker_command",
                "ok": False,
                "status": "NOT_EXECUTED",
                "detail": "stale report: the run did not complete",
            }, status="PASS")
            self.assertFalse(result["ok"], result)
            self.assertEqual(result["code"], evidence.REPORT_STRUCTURE_CODE)
            self.assertTrue(
                any("NOT_EXECUTED is not a pass" in error
                    for error in result["errors"]),
                result,
            )

            catalog = Path(temp) / "catalog.json"
            write_json(catalog, {
                "version": 1,
                "scenarios": [{"id": "G2-X", "tags": [], "target": "macos"}],
            })
            code, lines = evidence.check_reports(catalog, temp)
            self.assertEqual(code, 4, lines)
            self.assertTrue(
                any("NOT_EXECUTED is not a pass" in line for line in lines),
                lines,
            )
            self.assertFalse(any("PASS         1/1 assertion" in line for line in lines), lines)

    def test_a_cached_worker_pass_cannot_hide_an_incomplete_run(self):
        with tempfile.TemporaryDirectory(prefix="pdsh-evidence-worker-") as temp:
            directory = current_run(temp, "G2-X", status="PASS")
            report = json.loads(
                (directory / "report.json").read_text(encoding="utf-8")
            )
            report["assertions"] = [worker_command_assertion()]
            report["run_completed"] = False
            report["run_incomplete_reason"] = (
                "host.stop() failed after the worker assertion passed"
            )
            write_json(directory / "report.json", report)

            result = evidence.verify_scenario(temp, "G2-X", reconcile=False)
            self.assertFalse(result["ok"], result)
            self.assertEqual(result["code"], evidence.REPORT_STRUCTURE_CODE)
            self.assertTrue(
                any("run_completed is false" in error for error in result["errors"]),
                result,
            )
            self.assertTrue(
                any("host.stop() failed" in error for error in result["errors"]),
                result,
            )
            self.assertEqual(evidence._effective_report_status(report), "FAIL")

            catalog = Path(temp) / "catalog.json"
            write_json(catalog, {
                "version": 1,
                "scenarios": [{"id": "G2-X", "tags": [], "target": "macos"}],
            })
            code, lines = evidence.check_reports(catalog, temp)
            self.assertEqual(code, 4, lines)
            self.assertTrue(
                any("run_completed is false" in line for line in lines), lines
            )
            self.assertFalse(any("PASS         1/1 assertion" in line for line in lines), lines)

            record = evidence.archive_attempt(temp, "G2-X")
            self.assertEqual(record["status"], "UNKNOWN")
            self.assertTrue(record.get("report_errors"))

    def test_a_pass_report_cannot_carry_an_incomplete_reason(self):
        with tempfile.TemporaryDirectory(prefix="pdsh-evidence-worker-") as temp:
            directory = current_run(temp, "G2-X", status="PASS")
            report = json.loads(
                (directory / "report.json").read_text(encoding="utf-8")
            )
            report["run_completed"] = True
            report["run_incomplete_reason"] = "the recorded run did not complete"
            write_json(directory / "report.json", report)

            result = evidence.verify_scenario(temp, "G2-X", reconcile=False)
            self.assertFalse(result["ok"], result)
            self.assertEqual(result["code"], evidence.REPORT_STRUCTURE_CODE)
            self.assertTrue(
                any("run_incomplete_reason" in error for error in result["errors"]),
                result,
            )

    def test_a_legacy_pass_is_reconstructed_from_its_turns(self):
        with tempfile.TemporaryDirectory(prefix="pdsh-evidence-worker-") as temp:
            directory = current_run(temp, "G2-X", status="PASS")
            report = json.loads(
                (directory / "report.json").read_text(encoding="utf-8")
            )
            report["turns"] = [{
                "delivered": True,
                "started": "2026-10-27T00:00:00Z",
                "ended": None,
            }]
            write_json(directory / "report.json", report)

            result = evidence.verify_scenario(temp, "G2-X", reconcile=False)
            self.assertFalse(result["ok"], result)
            self.assertEqual(result["code"], evidence.REPORT_STRUCTURE_CODE)
            self.assertTrue(
                any("no terminal turn/end" in error for error in result["errors"]),
                result,
            )

            catalog = Path(temp) / "catalog.json"
            write_json(catalog, {
                "version": 1,
                "scenarios": [{"id": "G2-X", "tags": [], "target": "macos"}],
            })
            code, lines = evidence.check_reports(catalog, temp)
            self.assertEqual(code, 4, lines)

            report["turns"][0]["ended"] = "2026-10-27T00:00:05Z"
            write_json(directory / "report.json", report)
            result = evidence.verify_scenario(temp, "G2-X", reconcile=False)
            self.assertTrue(result["ok"], result)

    def test_a_pass_report_cannot_contain_a_failed_assertion(self):
        with tempfile.TemporaryDirectory(prefix="pdsh-evidence-worker-") as temp:
            result = self._report(temp, {
                "type": "file_exists",
                "ok": False,
                "detail": "missing",
            }, status="PASS")
            self.assertFalse(result["ok"], result)
            self.assertEqual(result["code"], evidence.REPORT_STRUCTURE_CODE)
            self.assertTrue(
                any("assertion 0 not ok" in error for error in result["errors"]),
                result,
            )

    def test_not_executed_with_ok_true_is_a_structure_error(self):
        with tempfile.TemporaryDirectory(prefix="pdsh-evidence-worker-") as temp:
            result = self._report(temp, {
                "type": "worker_command",
                "ok": True,
                "status": "NOT_EXECUTED",
                "detail": "not executed: forged pass",
            }, status="FAIL")
            self.assertFalse(result["ok"], result)
            self.assertEqual(result["code"], evidence.REPORT_STRUCTURE_CODE)
            self.assertTrue(
                any("NOT_EXECUTED must be ok:false" in error
                    for error in result["errors"]),
                result,
            )

            catalog = Path(temp) / "catalog.json"
            write_json(catalog, {
                "version": 1,
                "scenarios": [{"id": "G2-X", "tags": [], "target": "macos"}],
            })
            code, lines = evidence.check_reports(catalog, temp)
            self.assertEqual(code, 4, lines)
            self.assertTrue(
                any("NOT_EXECUTED must be ok:false" in line for line in lines),
                lines,
            )

    def test_not_executed_cannot_retain_a_cached_worker_receipt(self):
        with tempfile.TemporaryDirectory(prefix="pdsh-evidence-worker-") as temp:
            assertion = {
                "type": "worker_command",
                "ok": False,
                "status": "NOT_EXECUTED",
                "detail": "not executed after host.stop() failed",
                "worker_evaluated": True,
                "worker_receipt": worker_command_receipt(),
            }
            result = self._report(temp, assertion, status="FAIL")
            self.assertFalse(result["ok"], result)
            self.assertEqual(result["code"], evidence.REPORT_STRUCTURE_CODE)
            self.assertTrue(
                any("NOT_EXECUTED must not be worker_evaluated" in error
                    for error in result["errors"]),
                result,
            )
            self.assertTrue(
                any("NOT_EXECUTED must not retain a worker_receipt" in error
                    for error in result["errors"]),
                result,
            )

            catalog = Path(temp) / "catalog.json"
            write_json(catalog, {
                "version": 1,
                "scenarios": [{"id": "G2-X", "tags": [], "target": "macos"}],
            })
            code, lines = evidence.check_reports(catalog, temp)
            self.assertEqual(code, 4, lines)
            self.assertFalse(any("1/1 assertion" in line for line in lines), lines)

    def test_not_executed_cannot_claim_worker_evaluated_without_a_receipt(self):
        with tempfile.TemporaryDirectory(prefix="pdsh-evidence-worker-") as temp:
            result = self._report(temp, {
                "type": "worker_command",
                "ok": False,
                "status": "NOT_EXECUTED",
                "detail": "not executed: the scenario run did not complete",
                "worker_evaluated": True,
            }, status="FAIL")
            self.assertFalse(result["ok"], result)
            self.assertEqual(result["code"], evidence.REPORT_STRUCTURE_CODE)
            self.assertTrue(
                any("NOT_EXECUTED must not be worker_evaluated" in error
                    for error in result["errors"]),
                result,
            )


class ScenarioExitCodeTests(unittest.TestCase):
    """Shell-level regressions for the report-check exit precedence."""

    @staticmethod
    def _function_source():
        script = (HERE / "scenarios.sh").read_text(encoding="utf-8")
        start = script.index("scenario_exit_code() {")
        end = script.index("\n}\n", start) + 3
        return script[start:end]

    def _exit_code(self, runner_rc, evidence_rc, report_rc, staging_rc=0):
        source = self._function_source() + (
            '\nscenario_exit_code "$1" "$2" "$3" "$4"\n'
        )
        result = subprocess.run(
            [
                "bash", "-c", source, "scenario-exit-code",
                str(runner_rc), str(evidence_rc), str(report_rc),
                str(staging_rc),
            ],
            cwd=HERE, text=True, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return int(result.stdout.strip())

    def test_real_runner_failure_is_never_replaced_by_report_check_4_or_5(self):
        for runner_rc in (1, 2, 3, 4, 124):
            for report_rc in (1, 4, 5):
                with self.subTest(runner_rc=runner_rc, report_rc=report_rc):
                    self.assertEqual(
                        self._exit_code(runner_rc, 1, report_rc), runner_rc
                    )

    def test_runner_infra_report_overrides_the_failed_slot_glue_test_exit(self):
        # Swift's slot glue calls XCTFail for a runner-INFRA scenario, so the
        # test process is non-zero even though report-check can classify the
        # run as INFRA with exit 6. The classification must not be lost.
        for runner_rc in (1, 2, 3, 4, 124):
            with self.subTest(runner_rc=runner_rc):
                self.assertEqual(self._exit_code(runner_rc, 1, 6), 6)

    def test_pre_host_finalize_failure_is_staging_and_loses_to_report_check(self):
        # The simulator's provisional finalize can fail on a malformed pulled
        # report before the host phase. That is an evidence/staging failure,
        # not an xcodebuild/test exit, so report-check 4/5 stays visible.
        for report_rc in (4, 5):
            with self.subTest(report_rc=report_rc):
                self.assertEqual(self._exit_code(0, 0, report_rc, 1), report_rc)
                self.assertEqual(self._exit_code(0, 1, report_rc, 1), report_rc)
        self.assertEqual(self._exit_code(0, 0, 0, 1), 1)
        self.assertEqual(self._exit_code(0, 0, 1, 1), 1)
        # A real test/xcodebuild failure still outranks report-check 4/5.
        self.assertEqual(self._exit_code(1, 0, 4, 1), 1)
        self.assertEqual(self._exit_code(1, 0, 5, 1), 1)
        self.assertEqual(self._exit_code(1, 0, 6, 1), 6)

    def test_run_on_sim_wires_pre_host_finalize_into_staging(self):
        script = (HERE / "scenarios.sh").read_text(encoding="utf-8")
        start = script.index("run_on_sim() {")
        end = script.index('\nset +e\nif [ "$RUN_ON" = "sim" ]', start)
        body = script[start:end]
        self.assertIn("local staging_rc=0", body)
        self.assertIn('staging_rc="$prepare_rc"', body)
        self.assertNotIn('runner_rc="$prepare_rc"', body)
        self.assertIn(
            'scenario_exit_code "$runner_rc" "$evidence_rc" "$rc_reports" '
            '"$staging_rc"',
            body,
        )

    def test_report_check_diagnostics_override_evidence_only_exit_one(self):
        for report_rc in (4, 5, 6):
            with self.subTest(report_rc=report_rc):
                self.assertEqual(self._exit_code(0, 0, report_rc), report_rc)
                self.assertEqual(self._exit_code(0, 1, report_rc), report_rc)

    def test_report_check_self_error_and_clean_runs_keep_their_codes(self):
        self.assertEqual(self._exit_code(0, 0, 0), 0)
        self.assertEqual(self._exit_code(0, 0, 1), 1)
        self.assertEqual(self._exit_code(0, 1, 1), 1)
        self.assertEqual(self._exit_code(0, 2, 0), 2)


class PathSafetyTests(unittest.TestCase):
    def test_path_traversal_scenario_ids_are_rejected(self):
        with tempfile.TemporaryDirectory(prefix="pdsh-evidence-ids-") as temp:
            for scenario_id in ("../escape", "a/b", "", ".", "..", "x" * 65):
                with self.assertRaises(ValueError):
                    evidence.archive_attempt(temp, scenario_id)
                with self.assertRaises(ValueError):
                    evidence.verify_scenario(temp, scenario_id)

    def test_cli_rejects_traversal_ids_with_a_clean_exit_code(self):
        with tempfile.TemporaryDirectory(prefix="pdsh-evidence-cliid-") as temp:
            for scenario_id in ("../escape", "a/b"):
                code = evidence.main(
                    ["verify", "--results", temp, "--ids", scenario_id]
                )
                self.assertEqual(code, 2)

    def test_attempt_directory_stays_inside_results(self):
        with tempfile.TemporaryDirectory(prefix="pdsh-evidence-safe-") as temp:
            record = evidence.archive_attempt(temp, "safe.id-1")
            self.assertIsNone(record)
            self.assertFalse((Path(temp).parent / "safe.id-1").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
