#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Unit tests for the per-turn persistence counter reader (no Swift needed)."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import read_io_counters as reader  # noqa: E402

NOISY_LOG = """\
Test Suite 'LogIOCountersTests' started at 2026-11-12 23:00:00
Test Case 'LogIOCountersTests.testRealTurnSettlement' started.
PDSH_IO_FSYNC_CALLS=9
PDSH_IO_BYTES_WRITTEN=4096
Test Case 'LogIOCountersTests.testRealTurnSettlement' passed.
PDSH_IO_FSYNC_CALLS=11
PDSH_IO_BYTES_WRITTEN=5120
"""


class ParseCountersTests(unittest.TestCase):
    def test_last_settled_window_is_reported(self) -> None:
        counters = reader.parse_counters(NOISY_LOG)
        self.assertEqual(counters["fsync_calls_per_turn"], 11)
        self.assertEqual(counters["bytes_written_per_turn"], 5120)

    def test_missing_lines_fail_loudly(self) -> None:
        with self.assertRaises(reader.ProbeError):
            reader.parse_counters("Test Suite started\n")

    def test_unpaired_lines_fail_loudly(self) -> None:
        with self.assertRaises(reader.ProbeError):
            reader.parse_counters("PDSH_IO_FSYNC_CALLS=3\n")


class ReportTests(unittest.TestCase):
    def test_report_uses_the_budget_metric_names(self) -> None:
        payload = reader.report(
            {"fsync_calls_per_turn": 7, "bytes_written_per_turn": 2048},
            "test")
        self.assertEqual(payload["schema"], reader.SCHEMA_VERSION)
        self.assertEqual(payload["fsync_calls_per_turn"], 7)
        self.assertEqual(payload["bytes_written_per_turn"], 2048)
        self.assertIn("NOT counted", payload["scope"])


if __name__ == "__main__":
    unittest.main()
