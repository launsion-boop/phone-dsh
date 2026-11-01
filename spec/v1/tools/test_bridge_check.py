#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Mutation tests for the page-host bridge vectors, schema and document.

Every test runs the real checker against a temporary copy of ``spec/v1`` with one deliberate
corruption, so the checked-in tree is never modified. The tests cover the invariants that a single
vector cannot express (method echo, result/error exclusivity, requestId uniqueness, one-way
answering), the size and base64 caps, the direction/kind pairing, the schema-subset guard and the
document line cap.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SPEC_DIR = Path(__file__).resolve().parents[1]
ROOT = SPEC_DIR.parents[1]
CHECKER = SPEC_DIR / "tools" / "bridge_check.py"
VECTOR_DIR = "golden/bridge"
SCHEMA = "schema/bridge-message.schema.json"


def run_checker(root: Path) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(CHECKER), "--root", str(root)],
        capture_output=True,
        text=True,
        check=False,
    )


class BridgeCheckTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "phone-dsh"
        shutil.copytree(
            SPEC_DIR,
            self.root / "spec" / "v1",
            ignore=shutil.ignore_patterns("__pycache__", "*.pyc"),
        )

    def spec_path(self, relative: str) -> Path:
        return self.root / "spec" / "v1" / relative

    def read_json(self, relative: str):
        return json.loads(self.spec_path(relative).read_text(encoding="utf-8"))

    def write_json(self, relative: str, value) -> None:
        self.spec_path(relative).write_text(
            json.dumps(value, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
        )

    def check(self) -> subprocess.CompletedProcess:
        return run_checker(self.root)

    def assert_fails(self, completed: subprocess.CompletedProcess, needle: str) -> None:
        self.assertNotEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        self.assertIn(needle, completed.stdout, completed.stdout)
        self.assertIn("FAIL", completed.stdout)

    # -- the real tree ----------------------------------------------------

    def test_real_tree_passes_with_one_line_per_file(self) -> None:
        completed = run_checker(ROOT)
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        lines = completed.stdout.splitlines()
        file_lines = [line for line in lines if line.startswith(("ok ", "FAIL "))]
        summaries = [line for line in lines if line.endswith("files checked, 0 error(s)")]
        self.assertEqual(len(summaries), 1, completed.stdout)
        declared = int(summaries[0].split(" files checked", 1)[0])
        self.assertEqual(len(file_lines), declared, completed.stdout)
        self.assertTrue(all(line.startswith("ok ") for line in file_lines), completed.stdout)
        for expected in (
            "ok bridge.md",
            "ok schema/bridge-message.schema.json",
            "ok golden/bridge/request-response-preview.json",
            "ok golden/bridge/oneway-console.json",
        ):
            self.assertIn(expected, lines)

    # -- cross-message invariants -----------------------------------------

    def test_response_method_must_match_the_request(self) -> None:
        document = self.read_json(VECTOR_DIR + "/request-response-preview.json")
        document["instance"][1]["instance"]["method"] = "preview.close"
        self.write_json(VECTOR_DIR + "/request-response-preview.json", document)
        self.assert_fails(self.check(), "does not match the request method")

    def test_result_and_error_are_mutually_exclusive(self) -> None:
        document = self.read_json(VECTOR_DIR + "/request-response-preview.json")
        document["instance"][1]["instance"]["error"] = {
            "code": "BRIDGE_FAILED",
            "message": "a late failure that must not ride a result",
        }
        self.write_json(VECTOR_DIR + "/request-response-preview.json", document)
        self.assert_fails(self.check(), "must not carry both result and error")

    def test_duplicate_request_id_in_one_sequence_is_refused(self) -> None:
        document = self.read_json(VECTOR_DIR + "/request-response-preview.json")
        request = document["instance"][0]["instance"]
        document["instance"].append({"direction": "page-to-host", "instance": dict(request)})
        self.write_json(VECTOR_DIR + "/request-response-preview.json", document)
        self.assert_fails(self.check(), "duplicate requestId")

    def test_oneway_message_must_not_be_answered(self) -> None:
        document = {
            "name": "oneway-answered",
            "direction": "sequence",
            "schema": "bridge-message.schema.json",
            "instance": [
                {
                    "direction": "page-to-host",
                    "instance": {
                        "v": 1,
                        "kind": "oneway",
                        "method": "console.line",
                        "params": {"level": "warn", "text": "a line with no reply"},
                    },
                },
                {
                    "direction": "host-to-page",
                    "instance": {
                        "v": 1,
                        "kind": "response",
                        "requestId": "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d",
                        "method": "console.line",
                        "result": None,
                    },
                },
            ],
            "notes": "bridge.md 2; a one-way message must never be answered.",
        }
        self.write_json(VECTOR_DIR + "/oneway-answered.json", document)
        self.assert_fails(self.check(), "oneway message must not be answered")

    # -- caps and encodings -----------------------------------------------

    def test_result_over_the_1_mib_cap_is_refused(self) -> None:
        document = self.read_json(VECTOR_DIR + "/request-response-preview.json")
        document["instance"][1]["instance"]["result"] = {"blob": "x" * (1024 * 1024 + 16)}
        self.write_json(VECTOR_DIR + "/request-response-preview.json", document)
        self.assert_fails(self.check(), "exceeds the 1048576 byte cap")

    def test_base64_data_must_be_padded_standard_base64(self) -> None:
        document = self.read_json(VECTOR_DIR + "/request-response-binary.json")
        document["instance"][1]["instance"]["result"]["data"] = "aGVsbG8gcGhvbmUtZHNo!"
        self.write_json(VECTOR_DIR + "/request-response-binary.json", document)
        self.assert_fails(self.check(), "is not padded standard base64")

    def test_encoding_member_is_reserved_for_base64(self) -> None:
        document = self.read_json(VECTOR_DIR + "/request-response-binary.json")
        document["instance"][1]["instance"]["result"] = {"encoding": "hex", "data": "68656c6c6f"}
        self.write_json(VECTOR_DIR + "/request-response-binary.json", document)
        self.assert_fails(self.check(), "encoding is reserved for the base64 marker")

    # -- envelope pairing --------------------------------------------------

    def test_kind_must_match_the_declared_direction(self) -> None:
        document = self.read_json(VECTOR_DIR + "/error-cancelled.json")
        document["instance"][1]["direction"] = "page-to-host"
        self.write_json(VECTOR_DIR + "/error-cancelled.json", document)
        self.assert_fails(self.check(), "is not allowed in direction")

    def test_retryable_flag_must_follow_the_code_table(self) -> None:
        document = self.read_json(VECTOR_DIR + "/error-unknown-method.json")
        document["instance"][1]["instance"]["error"]["retryable"] = True
        self.write_json(VECTOR_DIR + "/error-unknown-method.json", document)
        self.assert_fails(self.check(), "is not retryable")

    def test_vector_members_are_exactly_the_five_required_ones(self) -> None:
        document = self.read_json(VECTOR_DIR + "/oneway-console.json")
        del document["notes"]
        self.write_json(VECTOR_DIR + "/oneway-console.json", document)
        self.assert_fails(self.check(), "vector members must be exactly")

    # -- schema subset and document ---------------------------------------

    def test_schema_keyword_outside_the_subset_is_refused(self) -> None:
        document = self.read_json(SCHEMA)
        document["$defs"] = {}
        self.write_json(SCHEMA, document)
        self.assert_fails(self.check(), "outside the supported subset")

    def test_document_line_cap_is_enforced(self) -> None:
        path = self.spec_path("bridge.md")
        path.write_text(path.read_text(encoding="utf-8") + "\n" * 5, encoding="utf-8")
        self.assert_fails(self.check(), "line cap")

    def test_missing_vector_directory_is_refused(self) -> None:
        shutil.rmtree(self.spec_path(VECTOR_DIR))
        self.assert_fails(self.check(), "bridge vectors are required")


if __name__ == "__main__":
    unittest.main()
