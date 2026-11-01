#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Tests for the trajectory / UiState normalizer (spec/v1/trajectory.md)."""

from __future__ import annotations

import json
import random
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
TOOLS = ROOT / "spec" / "v1" / "tools"
sys.path.insert(0, str(TOOLS))

import trajectory_norm as tn  # noqa: E402


SCHEMAS = tn.load_schemas(ROOT)


def trajectory_row(seq=1, event_type="user/message", data=None, platform=None, **extra):
    row = {
        "schemaVersion": "trajectory/1",
        "sessionID": "sess-001",
        "turnID": "turn-0001",
        "seq": seq,
        "type": event_type,
        "data": {} if data is None else data,
    }
    if platform is not None:
        row["platform"] = platform
    row.update(extra)
    return row


def uistate_row(
    node_id,
    parent_id,
    kind,
    surface,
    seq,
    turn_id,
    data=None,
    platform=None,
):
    row = {
        "schemaVersion": "ui-state/1",
        "sessionID": "sess-001",
        "turnID": turn_id,
        "seq": seq,
        "nodeID": node_id,
        "parentID": parent_id,
        "kind": kind,
        "surface": surface,
        "props": {} if data is None else data,
    }
    if platform is not None:
        row["platform"] = platform
    return row


def lines(*rows):
    return [json.dumps(row, ensure_ascii=False, sort_keys=True) for row in rows]


def parsed(lines_out):
    return [json.loads(line) for line in lines_out]


class TrajectoryNormalizationTests(unittest.TestCase):
    def normalize(self, rows, **kwargs):
        kwargs.setdefault("schemas", SCHEMAS)
        return tn.normalize(lines(*rows), tn.RULES, **kwargs)

    def test_timestamp_and_host_domain_stripped(self):
        row = trajectory_row(
            platform="ios",
            time=1761800000123,
            mono=998877,
            pid=831,
            port=51234,
            memoryBytes=104857600,
            cpuPercent=12.5,
            requestId="req-0007-3f2a9c",
            data={
                "path": "/var/mobile/Containers/Data/Application/"
                "8D3C2F1A-5B6E-4F70-9A81-2C3D4E5F6A7B/Library/workspace/notes/a.md",
                "text": "read it",
            },
        )
        result = parsed(self.normalize([row]))[0]
        for member in (
            "time",
            "mono",
            "pid",
            "port",
            "memoryBytes",
            "cpuPercent",
            "platform",
        ):
            self.assertNotIn(member, result)
        self.assertEqual(result["requestId"], "req-0007")
        self.assertEqual(result["data"]["path"], "/dsh/workspace/notes/a.md")
        self.assertEqual(result["data"]["text"], "read it")

    def test_window_reorder_is_deterministic(self):
        rows = [
            trajectory_row(seq=i, data={"text": "event {}".format(i)})
            for i in range(1, 7)
        ]
        shuffled = list(rows)
        random.Random(7).shuffle(shuffled)
        expected = self.normalize(rows)
        self.assertEqual(self.normalize(shuffled), expected)
        self.assertEqual(self.normalize(shuffled), self.normalize(shuffled))

    def test_out_of_window_is_rejected_not_reordered(self):
        rows = [
            trajectory_row(seq=i, data={"text": "event {}".format(i)})
            for i in range(1, 19)
        ]
        with self.assertRaises(tn.NormError) as caught:
            self.normalize(list(reversed(rows)))
        self.assertEqual(caught.exception.code, "OUT_OF_WINDOW")
        self.assertIn("window 16", str(caught.exception))

    def test_real_semantic_difference_survives(self):
        ios = trajectory_row(
            seq=1,
            event_type="turn/end",
            data={"reason": {"kind": "error", "error": {"message": "denied"}}},
        )
        android = trajectory_row(
            seq=1, event_type="turn/end", data={"reason": {"kind": "completed"}}
        )
        ios_out = self.normalize([ios])
        android_out = self.normalize([android])
        self.assertNotEqual(ios_out, android_out)
        self.assertIn('"kind":"error"', ios_out[0])
        self.assertIn('"kind":"completed"', android_out[0])

    def test_idempotent(self):
        row = trajectory_row(
            platform="android",
            timestamp=1761800000123,
            pid=4421,
            requestId="req-0040-abcdef",
            data={
                "path": "/data/user/0/dev.dsh.probe/files/workspace/x",
                "durationMs": 14.2,
                "bytes": "2 KiB",
                "score": 0.12345649,
            },
        )
        once = self.normalize([row])
        twice = tn.normalize(once, tn.RULES, schemas=SCHEMAS)
        self.assertEqual(twice, once)

    def test_two_runs_are_byte_identical(self):
        row = trajectory_row(
            platform="ios",
            time=1761800000123,
            data={"value": 0.12345649, "durationMs": 15.0},
        )
        first = tn.encode_lines(self.normalize([row]))
        second = tn.encode_lines(self.normalize([row]))
        self.assertEqual(first, second)
        self.assertTrue(first.endswith(b"\n"))

    def test_whitelist_is_platform_scoped(self):
        rules = [
            {
                "id": "ios-only",
                "platforms": ["ios"],
                "pattern": r"IOSNOISE",
                "replacement": "<ios-noise>",
                "reason": "test rule for iOS only",
            },
            {
                "id": "android-only",
                "platforms": ["android"],
                "pattern": r"ANDROIDNOISE",
                "replacement": "<android-noise>",
                "reason": "test rule for Android only",
            },
        ]
        ios = trajectory_row(
            platform="ios", data={"text": "IOSNOISE ANDROIDNOISE"}
        )
        android = trajectory_row(
            platform="android", data={"text": "IOSNOISE ANDROIDNOISE"}
        )
        ios_out = tn.normalize(lines(ios), rules, schemas=SCHEMAS)[0]
        android_out = tn.normalize(lines(android), rules, schemas=SCHEMAS)[0]
        self.assertIn('"text":"<ios-noise> ANDROIDNOISE"', ios_out)
        self.assertIn('"text":"IOSNOISE <android-noise>"', android_out)

    def test_platform_is_per_row_after_reordering(self):
        android = trajectory_row(seq=2, platform="android", data={"text": "thread=main"})
        ios = trajectory_row(seq=1, platform="ios", data={"text": "thread=RenderThread"})
        # Arrival order puts seq 2 first; stage 2 restores seq 1 then seq 2. The Android rule
        # must still follow the Android row and the iOS row must stay untouched.
        result = self.normalize([android, ios])
        self.assertIn('"seq":1', result[0])
        self.assertIn('"text":"thread=RenderThread"', result[0])
        self.assertIn('"seq":2', result[1])
        self.assertIn('"text":"thread=<worker>"', result[1])

    def test_request_id_uuid_is_removed_before_suffix_reduction(self):
        uuid = trajectory_row(
            seq=1, requestId="123e4567-e89b-12d3-a456-426614174000"
        )
        stem = trajectory_row(seq=2, requestId="req-0007-3f2a9c")
        hex_only = trajectory_row(seq=3, requestId="deadbeefcafe")
        result = parsed(self.normalize([uuid, stem, hex_only]))
        self.assertNotIn("requestId", result[0])
        self.assertEqual(result[1]["requestId"], "req-0007")
        self.assertNotIn("requestId", result[2])

    def test_numeric_precision_and_units(self):
        ios = trajectory_row(
            data={
                "durationMs": 15.0,
                "bytes": "1.5 KiB",
                "meta": {"score": 0.12345649, "ratio": 0.12349, "negative": -0.0000001},
            }
        )
        android = trajectory_row(
            data={
                "durationMs": 15.2,
                "bytes": 1536,
                "meta": {"score": 0.12345641, "ratio": 0.12348, "negative": 0.0},
            }
        )
        ios_out = self.normalize([ios])
        android_out = self.normalize([android])
        self.assertEqual(ios_out, android_out)
        data = parsed(ios_out)[0]["data"]
        self.assertEqual(data["durationMs"], 20)
        self.assertEqual(data["bytes"], 1536)
        self.assertEqual(data["meta"], {"score": 0.123456, "ratio": 0.123, "negative": 0})

    def test_empty_input(self):
        self.assertEqual(tn.normalize([], tn.RULES, schemas=SCHEMAS), [])
        self.assertEqual(tn.encode_lines([]), b"")
        self.assertEqual(tn.encode_lines(tn.normalize("", tn.RULES, schemas=SCHEMAS)), b"")


class UiStateNormalizationTests(unittest.TestCase):
    def setUp(self):
        self.base = [
            uistate_row("root", "root", "root", "none", 0, "-"),
            uistate_row("session/sess-001", "root", "session", "none", 0, "-"),
            uistate_row(
                "session/sess-001/turn/turn-0001",
                "session/sess-001",
                "turn",
                "none",
                0,
                "turn-0001",
            ),
            uistate_row(
                "session/sess-001/turn/turn-0001/event/1",
                "session/sess-001/turn/turn-0001",
                "turn-event",
                "none",
                1,
                "turn-0001",
            ),
        ]
        self.bubble = uistate_row(
            "session/sess-001/turn/turn-0001/event/1/assistant-block-0",
            "session/sess-001/turn/turn-0001/event/1",
            "bubble",
            "bubble",
            1,
            "turn-0001",
            {"score": 0.12345649},
        )

    def normalize_ui(self, rows):
        return tn.normalize(lines(*rows), tn.RULES, schemas=SCHEMAS)

    def test_ui_state_round_trip_with_platform_noise(self):
        ios_bubble = dict(self.bubble)
        ios_bubble["platform"] = "ios"
        ios_bubble["text"] = "answer at 2026-10-31T06:00:00Z pid=831"
        android_bubble = dict(self.bubble)
        android_bubble["platform"] = "android"
        android_bubble["text"] = "answer at 2026-10-31T06:00:01Z pid=4421"
        android_bubble["props"] = {"score": 0.12345641}
        android_rows = [android_bubble] + list(reversed(self.base))
        ios_out = self.normalize_ui(list(self.base) + [ios_bubble])
        android_out = self.normalize_ui(android_rows)
        self.assertEqual(ios_out, android_out)
        self.assertIn('"text":"answer at <timestamp> pid=<removed>"', ios_out[-1])
        self.assertEqual(parsed(ios_out)[0]["nodeID"], "root")

    def test_ui_state_rejects_unstable_or_extra_members(self):
        bad = dict(self.bubble)
        bad["nodeID"] = "session/sess-001/turn/turn-0001/event/1/abcdef12"
        with self.assertRaises(tn.NormError) as caught:
            self.normalize_ui(list(self.base) + [bad])
        self.assertEqual(caught.exception.code, "UNSTABLE_NODE_ID")

        absolute = dict(self.bubble)
        absolute["nodeID"] = "/dsh/workspace/chat"
        with self.assertRaises(tn.NormError) as caught:
            self.normalize_ui(list(self.base) + [absolute])
        self.assertIn(caught.exception.code, ("SCHEMA", "UNSTABLE_NODE_ID"))

        geometry = dict(self.bubble)
        geometry["geometry"] = {"frame": [0, 0, 10, 10]}
        with self.assertRaises(tn.NormError) as caught:
            self.normalize_ui(list(self.base) + [geometry])
        self.assertEqual(caught.exception.code, "SCHEMA")

    def test_ui_state_parent_must_precede_and_match(self):
        broken = dict(self.bubble)
        broken["parentID"] = "session/sess-001/turn/turn-0001"
        with self.assertRaises(tn.NormError) as caught:
            self.normalize_ui(list(self.base) + [broken])
        self.assertEqual(caught.exception.code, "UNSTABLE_NODE_ID")


class ContractTests(unittest.TestCase):
    def test_schemas_are_self_contained(self):
        for name in ("trajectory.schema.json", "ui-state-sequence.schema.json"):
            schema = json.loads((ROOT / "spec" / "v1" / "schema" / name).read_text())
            self.assertEqual(
                schema["$schema"], "https://json-schema.org/draft/2020-12/schema"
            )
            self.assertIs(schema["additionalProperties"], False)

            def walk(value):
                if isinstance(value, dict):
                    for forbidden in ("$ref", "$defs", "anyOf", "allOf"):
                        self.assertNotIn(forbidden, value)
                    for child in value.values():
                        walk(child)
                elif isinstance(value, list):
                    for child in value:
                        walk(child)

            walk(schema)

    def test_document_mirrors_rule_table_and_caps(self):
        text = (ROOT / "spec" / "v1" / "trajectory.md").read_text(encoding="utf-8")
        # D16 amendment (2026-10-31): the `context` kind needs one sentence,
        # cap 180 -> 182 (spec/v1/README.md §5.2).
        self.assertLessEqual(len(text.splitlines()), 182)
        self.assertLessEqual(len(tn.RULES), tn.RULE_CAP)
        for rule in tn.RULES:
            self.assertIn("`{}`".format(rule["id"]), text)
            self.assertIn(rule["platforms"][0], text)
            self.assertIn(rule["pattern"].replace("|", "\\|"), text)
            if rule["replacement"]:
                self.assertIn(rule["replacement"], text)
            else:
                self.assertIn("empty", text)
        self.assertIn("RULE_CAP", text)
        self.assertIn("RULE_GROWTH_LIMIT", text)

    def test_golden_checker_cli(self):
        completed = subprocess.run(
            [
                sys.executable,
                str(TOOLS / "trajectory_norm.py"),
                "--check-golden",
                "--root",
                str(ROOT),
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        self.assertEqual(completed.stdout.count("PASS golden/trajectory/"), 5)
        self.assertIn("real-difference preserved", completed.stdout)
        self.assertIn("SUMMARY 5/5 cases passed", completed.stdout)

    def test_cli_input_output_and_stats(self):
        row = trajectory_row(
            platform="ios",
            time=1761800000123,
            pid=831,
            requestId="req-0077-abcdef",
            data={"text": "hello"},
        )
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "in.jsonl"
            target = Path(temporary) / "out.jsonl"
            source.write_text(json.dumps(row) + "\n", encoding="utf-8")
            completed = subprocess.run(
                [
                    sys.executable,
                    str(TOOLS / "trajectory_norm.py"),
                    "--input",
                    str(source),
                    "--output",
                    str(target),
                    "--root",
                    str(ROOT),
                    "--stats",
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            stats = json.loads(completed.stdout)
            self.assertEqual(stats["inputLines"], 1)
            self.assertEqual(stats["outputLines"], 1)
            self.assertEqual(stats["kind"], "trajectory")
            output = target.read_text(encoding="utf-8")
            self.assertTrue(output.endswith("\n"))
            self.assertEqual(json.loads(output)["requestId"], "req-0077")


if __name__ == "__main__":
    unittest.main()
