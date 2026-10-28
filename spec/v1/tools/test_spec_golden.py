#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Mutation tests for the phone-dsh-v1 golden checker.

Every test runs the checker through its command-line interface on a temporary copy of the
specification tree, so the real tree is never modified.
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
        "spec_golden_copy", spec_dir / "tools" / "spec_golden.py"
    )
    module = importlib.util.module_from_spec(loader)
    loader.loader.exec_module(module)
    return module


class GoldenCheckerTests(unittest.TestCase):
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

    def rewrite_wal(self, relative: str, mutate=None) -> None:
        """Rewrite one WAL vector, re-encoding every record from its fields."""

        checker = load_checker(self.copy)
        path = self.copy / relative
        doc = json.loads(path.read_text(encoding="utf-8"))
        if mutate is not None:
            mutate(doc)
        header = doc["header"]
        header_crc, header_bytes = checker.encode_wal_header(
            header["format"],
            header["reserved"],
            header["first_mseq"],
            bytes.fromhex(header["boot_id_hex"]),
        )
        header["header_crc32c"] = header_crc
        header["header_hex"] = header_bytes.hex()
        blob = header_bytes
        for record in doc["records"]:
            if record["kind"] == "mutation":
                body = checker.encode_mutation_body(record["fields"], "test")
                mseq = record["fields"]["mseq"]
            else:
                mseq, body = checker.encode_epoch_close_body(record["fields"], "test")
            crc, record_bytes = checker.encode_wal_record(mseq, body, "test")
            record["crc32c"] = crc
            record["record_hex"] = record_bytes.hex()
            blob += record_bytes
        doc["file_hex"] = blob.hex()
        self.write_json(relative, doc)

    def assert_fails(self, completed: subprocess.CompletedProcess, needle: str = "FAIL") -> None:
        self.assertNotEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        self.assertIn(needle, completed.stdout)

    def test_real_tree_passes_and_prints_one_line_per_file(self) -> None:
        completed = run_checker(SPEC_DIR)
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        lines = completed.stdout.splitlines()
        file_lines = [line for line in lines if line.startswith(("ok ", "FAIL "))]
        summaries = [line for line in lines if line.endswith("files checked, 0 error(s)")]
        self.assertEqual(len(summaries), 1, completed.stdout)
        declared = int(summaries[0].split(" files checked", 1)[0])
        self.assertEqual(len(file_lines), declared, completed.stdout)
        self.assertTrue(all(line.startswith("ok ") for line in file_lines))
        self.assertIn("ok README.md", lines)
        self.assertIn("ok channel.md", lines)

    def test_flipped_frame_byte_fails(self) -> None:
        path = self.copy / "golden" / "frames" / "vfs-mut-write-1.json"
        doc = json.loads(path.read_text(encoding="utf-8"))
        frame = doc["frame_hex"]
        doc["frame_hex"] = frame[:-1] + ("1" if frame[-1] == "0" else "0")
        self.write_json("golden/frames/vfs-mut-write-1.json", doc)
        completed = run_checker(self.copy)
        self.assert_fails(completed, "frame mismatch")

    def test_changed_field_fails(self) -> None:
        path = self.copy / "golden" / "frames" / "vfs-mut-write-1.json"
        doc = json.loads(path.read_text(encoding="utf-8"))
        doc["fields"]["mseq"] += 1
        self.write_json("golden/frames/vfs-mut-write-1.json", doc)
        completed = run_checker(self.copy)
        self.assert_fails(completed, "payload mismatch")

    def test_reordered_json_payload_fails(self) -> None:
        path = self.copy / "golden" / "frames" / "hello-worker-1.json"
        doc = json.loads(path.read_text(encoding="utf-8"))
        payload = bytes.fromhex(doc["payload_hex"])
        value = json.loads(payload.decode("utf-8"))
        reordered = {key: value[key] for key in reversed(list(value))}
        mutated = json.dumps(reordered, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
        self.assertNotEqual(mutated, payload)
        self.assertEqual(len(mutated), len(payload))
        doc["payload_hex"] = mutated.hex()
        doc["frame_hex"] = doc["frame_hex"][:32] + mutated.hex()
        self.write_json("golden/frames/hello-worker-1.json", doc)
        completed = run_checker(self.copy)
        self.assert_fails(completed, "payload mismatch")

    def test_missing_required_schema_property_fails(self) -> None:
        path = self.copy / "golden" / "frames" / "hello-host-1.json"
        doc = json.loads(path.read_text(encoding="utf-8"))
        del doc["fields"]["role"]
        checker = load_checker(self.copy)
        frame = checker.encode_frame(doc["type_byte"], doc["seq"], doc["fields"], "mutated")
        doc["payload_hex"] = frame[16:].hex()
        doc["frame_hex"] = frame.hex()
        self.write_json("golden/frames/hello-host-1.json", doc)
        completed = run_checker(self.copy)
        self.assert_fails(completed, "oneOf")

    def test_host_refusal_pairing_is_required(self) -> None:
        # channel.md §4.8: a host reply carries `mseq` and `accepted_bytes`
        # together; the schema must reject a payload with only one of them.
        checker = load_checker(self.copy)
        schema = json.loads(
            (self.copy / "schema" / "error.schema.json").read_text(encoding="utf-8")
        )
        refusal_schema = schema["oneOf"][1]
        refusal = {
            "code": "VFS_REFUSED",
            "message": "EFBIG",
            "path": "/dsh/workspace/a",
            "limit": 10,
            "reason": "file-too-large",
            "accepted_bytes": 0,
        }
        with self.assertRaises(checker.SpecError) as raised:
            checker.validate_json(refusal, refusal_schema, "error.schema.json")
        self.assertIn("requires", str(raised.exception))
        refusal["mseq"] = 5
        checker.validate_json(refusal, refusal_schema, "error.schema.json")
        # The CLI rejects a golden frame whose fields carry a single member.
        path = self.copy / "golden" / "frames" / "error-3.json"
        doc = json.loads(path.read_text(encoding="utf-8"))
        del doc["fields"]["mseq"]
        frame = checker.encode_frame(doc["type_byte"], doc["seq"], doc["fields"], "mutated")
        doc["payload_hex"] = frame[16:].hex()
        doc["frame_hex"] = frame.hex()
        self.write_json("golden/frames/error-3.json", doc)
        completed = run_checker(self.copy)
        self.assert_fails(completed, "oneOf")

    def test_deleted_vector_fails(self) -> None:
        (self.copy / "golden" / "frames" / "vfs-mut-chmod-1.json").unlink()
        completed = run_checker(self.copy)
        self.assert_fails(completed, "missing VFS_MUT chmod variant")

    def test_deleted_schema_fails(self) -> None:
        (self.copy / "schema" / "console.schema.json").unlink()
        completed = run_checker(self.copy)
        self.assert_fails(completed, "core schema file is missing")

    def test_file_over_line_cap_fails(self) -> None:
        path = self.copy / "channel.md"
        original = path.read_text(encoding="utf-8")
        self.assertLessEqual(len(original.splitlines()), 350)
        path.write_text(original + ("\n" * 40), encoding="utf-8")
        completed = run_checker(self.copy)
        self.assert_fails(completed, "D16 cap")

    def test_full_fails_while_wal_vectors_are_absent(self) -> None:
        for name in ("wal.md", "exec.md"):
            path = self.copy / name
            if path.exists():
                path.unlink()
        wal_dir = self.copy / "golden" / "wal"
        if wal_dir.is_dir():
            shutil.rmtree(wal_dir)
        completed = run_checker(self.copy, full=True)
        self.assertNotEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        self.assertIn("golden/wal", completed.stdout)
        self.assertIn("required by --full but missing", completed.stdout)

    def test_full_real_tree_passes(self) -> None:
        completed = run_checker(SPEC_DIR, full=True)
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        self.assertIn("0 error(s)", completed.stdout)
        for line in ("ok wal.md", "ok exec.md", "ok golden/wal/segment-1.json"):
            self.assertIn(line, completed.stdout)

    def test_wal_flipped_crc_fails(self) -> None:
        path = self.copy / "golden" / "wal" / "segment-1.json"
        doc = json.loads(path.read_text(encoding="utf-8"))
        doc["records"][0]["crc32c"] ^= 0x00000001
        self.write_json("golden/wal/segment-1.json", doc)
        completed = run_checker(self.copy)
        self.assert_fails(completed, "crc32c does not match the computed value")

    def test_wal_wrong_header_length_fails(self) -> None:
        path = self.copy / "golden" / "wal" / "segment-1.json"
        doc = json.loads(path.read_text(encoding="utf-8"))
        doc["header"]["header_hex"] = doc["header"]["header_hex"][:-2]
        self.write_json("golden/wal/segment-1.json", doc)
        completed = run_checker(self.copy)
        self.assert_fails(completed, "header_hex must decode to exactly 40 bytes")

    def test_wal_epoch_close_mseq_mismatch_fails(self) -> None:
        path = self.copy / "golden" / "wal" / "segment-1.json"
        doc = json.loads(path.read_text(encoding="utf-8"))
        close = doc["records"][-1]
        self.assertEqual(close["kind"], "epoch_close")
        close["fields"]["mseq"] = close["fields"]["durable_upto"] + 1
        self.write_json("golden/wal/segment-1.json", doc)
        completed = run_checker(self.copy)
        self.assert_fails(completed, "epoch-close mseq must equal durable_upto (D7)")

    def test_wal_missing_appended_write_fails(self) -> None:
        def remove_append(doc) -> None:
            record = doc["records"][1]
            self.assertEqual(record["fields"]["mflags"], 2)
            record["fields"]["mflags"] = 0
            record["fields"]["append_from"] = 0

        self.rewrite_wal("golden/wal/segment-1.json", remove_append)
        completed = run_checker(self.copy)
        self.assert_fails(completed, "no appended write")

    def test_full_requires_epoch_only_vector(self) -> None:
        (self.copy / "golden" / "wal" / "segment-epoch-only.json").unlink()
        completed = run_checker(self.copy, full=True)
        self.assert_fails(completed, "required WAL vectors are missing")

    def test_full_requires_manifest_schema(self) -> None:
        (self.copy / "schema" / "manifest.schema.json").unlink()
        completed = run_checker(self.copy, full=True)
        self.assert_fails(completed, "manifest schema is required by --full but missing")

    def test_exec_req_idem_key_mismatch_fails(self) -> None:
        path = self.copy / "golden" / "frames" / "exec-req-1.json"
        doc = json.loads(path.read_text(encoding="utf-8"))
        doc["fields"]["idem_key"] = "0" * 64
        checker = load_checker(self.copy)
        frame = checker.encode_frame(doc["type_byte"], doc["seq"], doc["fields"], "mutated")
        doc["payload_hex"] = frame[16:].hex()
        doc["frame_hex"] = frame.hex()
        self.write_json("golden/frames/exec-req-1.json", doc)
        completed = run_checker(self.copy)
        self.assert_fails(completed, "does not match the D10 derivation")

    def test_manifest_schema_requires_last_mseq_fails(self) -> None:
        path = self.copy / "schema" / "manifest.schema.json"
        doc = json.loads(path.read_text(encoding="utf-8"))
        del doc["properties"]["last_mseq"]
        self.write_json("schema/manifest.schema.json", doc)
        completed = run_checker(self.copy)
        self.assert_fails(completed, "manifest schema properties must be exactly")

    def test_manifest_schema_rejects_resync_field_fails(self) -> None:
        path = self.copy / "schema" / "manifest.schema.json"
        doc = json.loads(path.read_text(encoding="utf-8"))
        doc["properties"]["needs_resync"] = {"type": "array"}
        self.write_json("schema/manifest.schema.json", doc)
        completed = run_checker(self.copy)
        self.assert_fails(completed, "manifest schema properties must be exactly")

    def test_wal_over_line_cap_fails(self) -> None:
        path = self.copy / "wal.md"
        self.assertTrue(path.is_file())
        original = path.read_text(encoding="utf-8")
        self.assertLessEqual(len(original.splitlines()), 320)
        path.write_text(original + ("\n" * 40), encoding="utf-8")
        completed = run_checker(self.copy)
        self.assert_fails(completed, "D16 cap")

    def _remove_wal_phrase(self, phrase: str, replacement: str) -> None:
        path = self.copy / "wal.md"
        text = path.read_text(encoding="utf-8")
        self.assertIn(phrase, text)
        path.write_text(text.replace(phrase, replacement), encoding="utf-8")
        completed = run_checker(self.copy, full=True)
        self.assert_fails(completed, "lacks required contract text")

    def test_wal_materialized_first_rule_required(self) -> None:
        self._remove_wal_phrase("fsync the changed materialized copy", "fsync the WAL first")

    def test_wal_strict_contiguous_watermark_required(self) -> None:
        self._remove_wal_phrase("strictly contiguous watermark", "materialization watermark")

    def test_wal_immediate_resync_rule_required(self) -> None:
        self._remove_wal_phrase("at once", "when convenient")

    def test_wal_next_epoch_close_failure_rule_required(self) -> None:
        self._remove_wal_phrase("next epoch close", "a later close")

    def test_wal_no_persisted_resync_rule_required(self) -> None:
        self._remove_wal_phrase(
            "No resync state is persisted in the manifest",
            "Resync state is persisted in the manifest",
        )

    def test_wal_next_mseq_formula_required(self) -> None:
        self._remove_wal_phrase("max(last_mseq, WAL tail) + 1", "WAL tail + 1")

    def test_wal_manifest_last_mseq_required(self) -> None:
        path = self.copy / "wal.md"
        text = path.read_text(encoding="utf-8")
        self.assertIn("`last_mseq`", text)
        path.write_text(text.replace("`last_mseq`", "`tail_mark`"), encoding="utf-8")
        completed = run_checker(self.copy, full=True)
        self.assert_fails(completed, "lacks required contract text")

    def test_wal_epoch_close_order_rule_required(self) -> None:
        self._remove_wal_phrase(
            "every segment file written in this epoch", "every segment file"
        )

    def test_wal_compaction_after_close_rule_required(self) -> None:
        self._remove_wal_phrase(
            "happen only after this order has completed", "may happen earlier"
        )

    def test_wal_torn_tail_logged_rule_required(self) -> None:
        self._remove_wal_phrase("the truncation is logged", "the truncation is silent")

    def test_wal_non_tail_crc_failure_rule_required(self) -> None:
        self._remove_wal_phrase("not at the tail", "anywhere")

    def test_wal_deferred_record_rule_required(self) -> None:
        path = self.copy / "wal.md"
        text = path.read_text(encoding="utf-8")
        self.assertIn("never discarded", text)
        path.write_text(text.replace("never discarded", "eventually dropped"), encoding="utf-8")
        completed = run_checker(self.copy, full=True)
        self.assert_fails(completed, "lacks required contract text")

    def test_wal_unlisted_placement_rule_required(self) -> None:
        path = self.copy / "wal.md"
        text = path.read_text(encoding="utf-8")
        self.assertIn("adopted tail", text)
        path.write_text(text.replace("adopted tail", "adopted segment"), encoding="utf-8")
        completed = run_checker(self.copy, full=True)
        self.assert_fails(completed, "lacks required contract text")

    def test_exec_accelerator_workspace_write_rule_required(self) -> None:
        path = self.copy / "exec.md"
        text = path.read_text(encoding="utf-8")
        self.assertIn("workspace-write", text)
        path.write_text(text.replace("workspace-write", "read-only"), encoding="utf-8")
        completed = run_checker(self.copy, full=True)
        self.assert_fails(completed, "lacks required contract text")

    def test_wal_missing_segment_rule_required(self) -> None:
        self._remove_wal_phrase("all of its recorded mutations have", "its mutations")

    def test_wal_never_wal_alone_rule_required(self) -> None:
        self._remove_wal_phrase("never the WAL alone", "from the WAL")

    def test_wal_reconcile_marker_rule_required(self) -> None:
        self._remove_wal_phrase("reconcile.inprogress", "reconcile marker")

    def test_wal_old_missing_segment_rule_cannot_return(self) -> None:
        path = self.copy / "wal.md"
        text = path.read_text(encoding="utf-8")
        phrase = "dropped silently only when"
        self.assertIn(phrase, text)
        path.write_text(
            text.replace(
                phrase,
                "dropped silently when all of its recorded mutations have",
            ),
            encoding="utf-8",
        )
        completed = run_checker(self.copy, full=True)
        self.assert_fails(completed, "still contains a superseded rule")

    def test_exec_single_step_id_rule_required(self) -> None:
        path = self.copy / "exec.md"
        text = path.read_text(encoding="utf-8")
        phrase = "One step id per call"
        self.assertIn(phrase, text)
        path.write_text(text.replace(phrase, "Two step ids per call"), encoding="utf-8")
        completed = run_checker(self.copy, full=True)
        self.assert_fails(completed, "lacks required contract text")

    def test_exec_step_id_ledger_coupling_required(self) -> None:
        path = self.copy / "exec.md"
        text = path.read_text(encoding="utf-8")
        phrase = "store the same decimal"
        self.assertIn(phrase, text)
        path.write_text(text.replace(phrase, "may use different `step_id` values"), encoding="utf-8")
        completed = run_checker(self.copy, full=True)
        self.assert_fails(completed, "lacks required contract text")

    def test_exec_old_double_step_id_rule_cannot_return(self) -> None:
        path = self.copy / "exec.md"
        text = path.read_text(encoding="utf-8")
        path.write_text(
            text + "\n`step_id` is the call's `XL_IDEMPOTENCY_KEY`.\n", encoding="utf-8"
        )
        completed = run_checker(self.copy, full=True)
        self.assert_fails(completed, "still contains a superseded rule")

    def _rewrite_frame(self, relative: str, fields) -> None:
        path = self.copy / relative
        doc = json.loads(path.read_text(encoding="utf-8"))
        doc["fields"] = fields
        checker = load_checker(self.copy)
        frame = checker.encode_frame(doc["type_byte"], doc["seq"], doc["fields"], "mutated")
        doc["payload_hex"] = frame[16:].hex()
        doc["frame_hex"] = frame.hex()
        self.write_json(relative, doc)

    def test_hello_caps_unique_items_enforced(self) -> None:
        path = self.copy / "golden" / "frames" / "hello-host-1.json"
        doc = json.loads(path.read_text(encoding="utf-8"))
        doc["fields"]["caps"].append(doc["fields"]["caps"][0])
        self._rewrite_frame("golden/frames/hello-host-1.json", doc["fields"])
        completed = run_checker(self.copy)
        self.assert_fails(completed, "uniqueItems")

    def test_schema_pattern_rejects_trailing_newline(self) -> None:
        path = self.copy / "golden" / "frames" / "exec-req-1.json"
        doc = json.loads(path.read_text(encoding="utf-8"))
        doc["fields"]["exec_id"] = doc["fields"]["exec_id"] + "\n"
        self._rewrite_frame("golden/frames/exec-req-1.json", doc["fields"])
        completed = run_checker(self.copy)
        self.assert_fails(completed, "does not match")

    def test_exec_evt_exit_status_enum_enforced(self) -> None:
        path = self.copy / "golden" / "frames" / "exec-evt-1.json"
        doc = json.loads(path.read_text(encoding="utf-8"))
        doc["fields"]["status"] = "finished"
        self._rewrite_frame("golden/frames/exec-evt-1.json", doc["fields"])
        completed = run_checker(self.copy)
        self.assert_fails(completed, "EXEC_EVT exit status")

    def test_decisions_cover_d20(self) -> None:
        path = self.copy / "README.md"
        lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
        kept = [line for line in lines if not line.startswith("| D20 |")]
        self.assertEqual(len(kept), len(lines) - 1)
        path.write_text("".join(kept), encoding="utf-8")
        completed = run_checker(self.copy)
        self.assert_fails(completed, "Decisions table is missing [20]")

    def test_decision_d16_requires_wal_cap_320(self) -> None:
        path = self.copy / "README.md"
        text = path.read_text(encoding="utf-8")
        self.assertIn("wal.md ≤ 320", text)
        path.write_text(text.replace("wal.md ≤ 320", "wal.md ≤ 300", 1), encoding="utf-8")
        completed = run_checker(self.copy)
        self.assert_fails(completed, "decision D16 must state wal.md ≤ 320")

    def test_decision_d4_points_at_the_single_file_revision(self) -> None:
        # The large-file budget revision moves the single-file cap from D4's
        # quoted 15 MiB to the budgets.md §4 tier table; the D4 row must name
        # that section so the two caps cannot be read independently.
        path = self.copy / "README.md"
        lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
        rewritten = []
        changed = False
        for line in lines:
            if line.startswith("| D4 |"):
                replaced = line.replace("budgets.md §4, §6; ", "", 1)
                changed = changed or replaced != line
                line = replaced
            rewritten.append(line)
        self.assertTrue(changed, "the D4 row must name budgets.md §4")
        path.write_text("".join(rewritten), encoding="utf-8")
        completed = run_checker(self.copy)
        self.assert_fails(completed, "decision D4 must point at the budgets.md")

    def test_internal_task_identifier_rejected(self) -> None:
        path = self.copy / "README.md"
        path.write_text(
            path.read_text(encoding="utf-8") + "\nInternal task " + "W0" + "-SPEC-A.\n",
            encoding="utf-8",
        )
        completed = run_checker(self.copy)
        self.assert_fails(completed, "contains an internal task identifier")


if __name__ == "__main__":
    unittest.main()
