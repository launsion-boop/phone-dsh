#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Mutation tests for spec/v1/tools/gateway_check.py.

Each test copies the real schema and vectors into a temporary tree, mutates
exactly one property of one vector, and asserts that the checker rejects it.
The clean copy must pass first, so a test cannot succeed because the checker
rejects everything.
"""

from __future__ import annotations

import contextlib
import io
import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

TOOLS = Path(__file__).resolve().parent
SPEC = TOOLS.parents[0]
REPO = TOOLS.parents[2]

sys.path.insert(0, str(TOOLS))
import gateway_check


def make_tree():
    root = Path(tempfile.mkdtemp(prefix="gateway-check-"))
    (root / "spec" / "v1" / "schema").mkdir(parents=True)
    shutil.copy2(
        SPEC / "schema" / "gateway-vector.schema.json",
        root / "spec" / "v1" / "schema" / "gateway-vector.schema.json",
    )
    shutil.copytree(
        SPEC / "golden" / "gateway", root / "spec" / "v1" / "golden" / "gateway"
    )
    (root / "spec" / "v1" / "tools").mkdir()
    (root / "spec" / "v1" / "tools" / "spec_golden.py").symlink_to(
        SPEC / "tools" / "spec_golden.py"
    )
    # New vectors cite the normative prose as a reference; keep that
    # resolvable in the temporary tree instead of copying the document.
    (root / "spec" / "v1" / "gateway-security.md").symlink_to(
        SPEC / "gateway-security.md"
    )
    (root / "Sources").symlink_to(REPO / "Sources", target_is_directory=True)
    (root / "Tests").symlink_to(REPO / "Tests", target_is_directory=True)
    return root


class GatewayCheckMutationTests(unittest.TestCase):
    def setUp(self):
        self.root = make_tree()
        self.addCleanup(shutil.rmtree, self.root, True)

    # ------------------------------------------------------------ helpers
    def vector_path(self, vector_id):
        return (
            self.root
            / "spec"
            / "v1"
            / "golden"
            / "gateway"
            / (vector_id[3:] + ".json")
        )

    def load(self, vector_id):
        path = self.vector_path(vector_id)
        return path, json.loads(path.read_text(encoding="utf-8"))

    def save(self, path, doc):
        path.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")

    def rows(self):
        rows, _stats = gateway_check.check(self.root)
        return rows

    def assert_rejected(self, needle):
        rows = self.rows()
        failed = [text for ok, text in rows if not ok]
        self.assertTrue(failed, "the checker accepted the mutated tree")
        self.assertTrue(
            any(needle in text for text in failed),
            "expected {!r} in one of:\n{}".format(needle, "\n".join(failed)),
        )

    # -------------------------------------------------------------- tests
    def test_pristine_vectors_pass(self):
        rows = self.rows()
        self.assertTrue(rows)
        failures = [text for ok, text in rows if not ok]
        self.assertEqual(failures, [], "\n".join(failures))

    def test_allow_leaking_caller_credential_fails(self):
        path, doc = self.load("gw-cred-001")
        doc["expect"]["outbound_headers"]["x-api-key"] = gateway_check.CALLER_SENTINEL
        self.save(path, doc)
        self.assert_rejected("reached the outbound")

    def test_deny_without_reason_fails(self):
        path, doc = self.load("gw-egress-002")
        del doc["expect"]["deny_reason"]
        self.save(path, doc)
        self.assert_rejected("a deny must carry deny_reason")

    def test_same_header_stripped_and_outbound_fails(self):
        path, doc = self.load("gw-cred-002")
        doc["expect"]["outbound_headers"]["authorization"] = "Bearer placeholder"
        self.save(path, doc)
        self.assert_rejected("is both stripped and in outbound_headers")

    def test_unsorted_stripped_list_fails(self):
        path, doc = self.load("gw-cred-002")
        doc["expect"]["stripped"] = list(reversed(doc["expect"]["stripped"]))
        self.save(path, doc)
        self.assert_rejected("must be ASCII-sorted")

    def test_source_line_out_of_range_fails(self):
        path, doc = self.load("gw-hop-001")
        doc["source"] = doc["source"].rsplit(":", 1)[0] + ":999999"
        self.save(path, doc)
        self.assert_rejected("but the file has")

    def test_missing_rule_coverage_fails(self):
        for vector_id in ("gw-resp-001", "gw-resp-002", "gw-resp-003",
                          "gw-resp-004", "gw-resp-005", "gw-resp-006",
                          "gw-log-001"):
            self.vector_path(vector_id).unlink()
        self.assert_rejected("rules without a vector")

    def test_missing_wildcard_coverage_fails(self):
        for vector_id in ("gw-redir-005", "gw-egress-004"):
            self.vector_path(vector_id).unlink()
        self.assert_rejected("wildcard rules need at least one allow and one deny")

    def test_expected_body_with_injected_secret_fails(self):
        path, doc = self.load("gw-resp-002")
        doc["expect"]["body_json"]["result"]["content"][0]["text"] = (
            "echo " + doc["input"]["credential"]["headers"]["authorization"]
        )
        self.save(path, doc)
        self.assert_rejected("redaction is incomplete")

    def test_schema_type_error_fails(self):
        path, doc = self.load("gw-egress-001")
        doc["expect"]["dispatch"] = True
        self.save(path, doc)
        self.assert_rejected("has type bool")

    def test_redirect_chain_arithmetic_fails(self):
        path, doc = self.load("gw-redir-002")
        doc["expect"]["redirects_followed"] = 0
        self.save(path, doc)
        self.assert_rejected("must follow every hop")

    def test_redirect_deny_final_url_fails(self):
        path, doc = self.load("gw-redir-001")
        doc["expect"]["final_url"] = doc["input"]["url"]
        self.save(path, doc)
        self.assert_rejected("must be the refused target")

    # ------------------------------------ refused redirect is observable
    def test_denied_redirect_without_status_fails(self):
        # The class invariant: a deny whose reason is redirect_* must name the
        # 3xx it hands back, so a future refused-redirect vector cannot omit it
        # and fall back to "anything without a failure envelope".
        path, doc = self.load("gw-redir-001")
        del doc["expect"]["status"]
        self.save(path, doc)
        self.assert_rejected("a refused redirect must state expect.status")

    def test_denied_redirect_status_outside_3xx_fails(self):
        path, doc = self.load("gw-redir-003")
        doc["expect"]["status"] = 200
        self.save(path, doc)
        self.assert_rejected("a refused redirect must stay 3xx")

    def test_denied_redirect_status_must_be_the_refused_hop(self):
        path, doc = self.load("gw-redir-003")
        doc["expect"]["status"] = 302
        self.save(path, doc)
        self.assert_rejected("must be the refused hop's own status 307")

    def test_refused_redirect_location_header_must_match(self):
        path, doc = self.load("gw-redir-008")
        doc["expect"]["response_headers"]["location"] = doc["input"]["url"]
        self.save(path, doc)
        self.assert_rejected("must be the refused hop's Location")

    def test_refused_redirect_cannot_report_a_resend(self):
        path, doc = self.load("gw-redir-007")
        doc["expect"]["upstream_contacts"] = 3
        self.save(path, doc)
        self.assert_rejected("2 contact(s), not 3")

    def test_denied_chain_that_follows_every_hop_fails(self):
        # The denied branch must report a clean failure, not index past the
        # last hop, when a mutation claims the chain reached its end.
        path, doc = self.load("gw-redir-008")
        doc["expect"]["redirects_followed"] = 1
        self.save(path, doc)
        self.assert_rejected("a denied chain must refuse a hop before the end")

    def test_allowed_chain_status_must_be_the_final_response(self):
        path, doc = self.load("gw-redir-002")
        doc["input"]["response"] = {"status": 201, "headers": {}}
        doc["expect"]["status"] = 200
        self.save(path, doc)
        self.assert_rejected("an allowed chain ends on input.response status 201")

    def test_preflight_deny_with_a_status_fails(self):
        path, doc = self.load("gw-fail-002")
        doc["expect"]["status"] = 403
        self.save(path, doc)
        self.assert_rejected("a pre-flight deny carries no response status")

    def test_worker_placeholder_reaches_outbound_fails(self):
        path, doc = self.load("gw-cred-003")
        doc["expect"]["outbound_headers"]["x-mcp-token"] = (
            gateway_check.WORKER_PLACEHOLDER
        )
        self.save(path, doc)
        self.assert_rejected("placeholder reached the outbound request")

    def test_sensitive_scalar_without_mcp_marker_fails(self):
        path, doc = self.load("gw-resp-004")
        del doc["input"]["mcp"]
        self.save(path, doc)
        self.assert_rejected("sensitive_credential requires an MCP call")

    def test_mcp_response_entering_log_fails(self):
        path, doc = self.load("gw-resp-004")
        doc["expect"]["log"]["recorded"] = True
        self.save(path, doc)
        self.assert_rejected("must exclude its response from the log")

    def test_bearer_echo_in_expected_body_fails(self):
        path, doc = self.load("gw-resp-004")
        doc["expect"]["body_json"]["result"]["content"][0]["text"] = (
            "echo Bearer " + doc["input"]["credential"]["value"]
        )
        self.save(path, doc)
        self.assert_rejected("redaction is incomplete")

    def test_body_sha256_mismatch_fails(self):
        path, doc = self.load("gw-resp-005")
        doc["expect"]["body_sha256"] = "0" * 64
        self.save(path, doc)
        self.assert_rejected("body_sha256 does not match")

    # ------------------------------------------------- new oracle teeth
    def test_log_recorded_false_in_the_positive_vector_fails(self):
        # A gateway that never writes a response log must not pass: the only
        # positive-log vectors are log-001 and resp-006.
        path, doc = self.load("gw-log-001")
        doc["expect"]["log"]["recorded"] = False
        self.save(path, doc)
        self.assert_rejected("recorded_ok requires log.recorded true")

    def test_positive_log_coverage_fails(self):
        for vector_id in ("gw-log-001", "gw-resp-006"):
            self.vector_path(vector_id).unlink()
        self.assert_rejected("no vector records a response")

    def test_recording_log_without_reason_fails(self):
        path, doc = self.load("gw-log-001")
        del doc["expect"]["log"]["reason"]
        self.save(path, doc)
        self.assert_rejected("must state reason recorded_ok")

    def test_recording_log_body_bytes_mismatch_fails(self):
        path, doc = self.load("gw-log-001")
        doc["expect"]["log"]["body_bytes"] = 54
        doc["expect"]["log"]["retained_bytes"] = 54
        self.save(path, doc)
        self.assert_rejected("log.body_bytes must equal expect.body_bytes")

    def test_body_forbidden_response_with_body_fails(self):
        path, doc = self.load("gw-resp-006")
        doc["expect"]["body"] = "must-not-be-forwarded"
        doc["expect"]["body_bytes"] = 21
        self.save(path, doc)
        self.assert_rejected("must suppress the body")

    def test_invalid_request_with_a_parseable_url_fails(self):
        path, doc = self.load("gw-fail-003")
        doc["input"]["url"] = "https://api.example.invalid/v1/models"
        self.save(path, doc)
        self.assert_rejected("not a valid absolute http(s) URL")

    def test_transport_reason_over_256_fails(self):
        path, doc = self.load("gw-fail-004")
        doc["expect"]["failure"]["reason"] = "x" * 300
        self.save(path, doc)
        self.assert_rejected("longer than 256")

    def test_transport_reason_with_newline_fails(self):
        path, doc = self.load("gw-fail-004")
        # Replace one character so the value stays within the 256-char schema
        # bound and the newline check, not maxLength, is what rejects it.
        reason = doc["expect"]["failure"]["reason"]
        doc["expect"]["failure"]["reason"] = reason[:100] + "\n" + reason[101:]
        self.save(path, doc)
        self.assert_rejected("newline-free")

    def test_transport_reason_not_derived_from_the_scripted_cause_fails(self):
        path, doc = self.load("gw-fail-004")
        doc["expect"]["failure"]["reason"] = "a made-up reason"
        self.save(path, doc)
        self.assert_rejected("bounded transport reason")

    def test_cli_exit_status_is_one_on_a_mutated_tree(self):
        path, doc = self.load("gw-egress-002")
        del doc["expect"]["deny_reason"]
        self.save(path, doc)
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            status = gateway_check.main(["--root", str(self.root)])
        self.assertEqual(status, 1)
        self.assertIn("FAIL spec/v1/golden/gateway/egress-002.json", buffer.getvalue())
        count = len(list(
            (self.root / "spec" / "v1" / "golden" / "gateway").glob("*.json")
        ))
        self.assertIn("{} vectors checked".format(count), buffer.getvalue())

    def test_cli_exit_status_is_zero_on_the_real_tree(self):
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            status = gateway_check.main(["--root", str(REPO)])
        self.assertEqual(status, 0, buffer.getvalue())
        coverage = [
            line
            for line in buffer.getvalue().splitlines()
            if line.startswith("ok  coverage rules")
        ]
        self.assertEqual(len(coverage), 1, buffer.getvalue())
        for rule in gateway_check.RULES:
            self.assertIn(rule + "=", coverage[0])


if __name__ == "__main__":
    unittest.main()
