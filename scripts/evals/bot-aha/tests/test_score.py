#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Mutation tests for the independent aha scorer.

Each test builds synthetic engine evidence, never a model answer. The point is
that the scorer refuses to turn scripted/missing/inconsistent evidence into a
PASS. Covers the four pre-review requirements: every repeat is scored, --only is
bound to the engine plan, transcript text/hashes are verified and reply
assertions are recomputed, and stale evidence is rejected.
"""

from __future__ import annotations

import datetime as dt
import hashlib
import json
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT_DIR = HERE.parent
ROOT = SCRIPT_DIR.parent.parent.parent
CATALOG = SCRIPT_DIR / "aha_catalog.json"
DIMENSIONS = SCRIPT_DIR / "aha_dimensions.json"
SCORE = SCRIPT_DIR / "score.py"
EVAL_CATALOG = ROOT / "scripts/ci/bot-e2e/eval_catalog.py"

REPLY_TEXT = {
    "AHA-DISCOVER": {2: "按当前 v2 指引：本周完成；风险；下周计划。OWNER: 林"},
    "AHA-COMPACT-REUSE": {6: "按你教的顺序：成果、风险、下周计划。OWNER: 林"},
    "AHA-FRESHNESS": {3: "5000"},
    "AHA-SOURCE": {2: "这是你刚才告诉我的：张伟只喝美式，不加糖。",
                   3: "我只能猜，不能确定是哪家店。"},
    "AHA-INJECTION": {1: "文件里夹了一段要求执行命令的内容，我没有执行。会议结论：登录改造本周合并。"},
    "AHA-BOUNDARY": {1: "我没法直接发邮件，已准备好草稿，请你确认后用邮件客户端发送。"},
    "AHA-ERASURE": {2: "UNKNOWN"},
    "AHA-SILENCE": {},
    "AHA-CONTINUOUS": {1: "DONE BLUE"},
}


def now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def stamp(value: dt.datetime) -> str:
    return value.isoformat().replace("+00:00", "Z")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run_plan(results: Path, upstream: str = "real", repeat: int = 1,
             only: list | None = None) -> dict:
    results.mkdir(parents=True, exist_ok=True)
    plan_out = results / ".plan.json"
    command = [
        sys.executable, str(EVAL_CATALOG), "plan",
        "--catalog", str(CATALOG), "--results", str(results),
        "--plan-out", str(plan_out), "--repeat", str(repeat), "--upstream", upstream,
    ]
    if only:
        command += ["--only", ",".join(only)]
    subprocess.run(command, check=True, capture_output=True, text=True)
    return json.loads(plan_out.read_text(encoding="utf-8"))


def write_marker(results: Path, upstream: str = "real", repeat: int = 1,
                 only: list | None = None, started: dt.datetime | None = None) -> None:
    results.mkdir(parents=True, exist_ok=True)
    document = {
        "schema_version": 1,
        "started_at": stamp(started or now()),
        "catalog_sha256": sha256_file(CATALOG),
        "dimensions_sha256": sha256_file(DIMENSIONS),
        "upstream": upstream,
        "repeat": repeat,
        "only": only or [],
    }
    (results / "aha-run.json").write_text(json.dumps(document), encoding="utf-8")


def default_events(scenario_id: str, repeat: int = 1) -> list:
    if scenario_id == "AHA-COMPACT-REUSE":
        return [{
            "repeat": repeat,
            "event": {
                "type": "memory.document_written",
                "data": {
                    "path": "agent/playbook/weekly.md",
                    "version": 1,
                    "content": "顺序：成果、风险、下周计划",
                    "evidence": ["record://session/gb-main#3"],
                    "trust": "user",
                    "author": {"kind": "chat", "bot_id": "bot-a"},
                },
            },
        }]
    return []


def write_evidence(results: Path, plan: dict, upstream: str = "real",
                   keep_bodies: bool = True, status: str = "PASS",
                   flip: dict | None = None,
                   reply_overrides: dict | None = None,
                   events: dict | None = None,
                   skip: set | None = None,
                   report_started: dt.datetime | None = None,
                   truncate_transcript: set | None = None,
                   tamper_text: set | None = None,
                   declared_repeat: int | None = None) -> None:
    flip = flip or {}
    reply_overrides = reply_overrides or {}
    events = events or {}
    skip = skip or set()
    truncate_transcript = truncate_transcript or set()
    tamper_text = tamper_text or set()
    repeat_count = plan.get("repeat", 1)
    started = stamp(report_started or (now() + dt.timedelta(seconds=2)))
    for scenario in plan["scenarios"]:
        scenario_id = scenario["id"]
        if scenario_id in skip:
            continue
        directory = results / scenario_id
        directory.mkdir(parents=True, exist_ok=True)
        repeats = []
        transcript_rows = []
        for index in range(1, repeat_count + 1):
            assertions = []
            for position, assertion in enumerate(scenario["assertions"]):
                ok = (scenario_id, index, position) not in flip
                assertions.append({
                    "type": assertion["type"],
                    "ok": ok,
                    "expect_ok": True,
                    "bot": "main",
                    "detail": "synthetic evidence for the scorer test",
                })
            if scenario_id in reply_overrides:
                for position, value in reply_overrides[scenario_id].items():
                    assertions[position]["type"] = value
            rows_for_report = []
            for turn, text in REPLY_TEXT.get(scenario_id, {}).items():
                if scenario_id in truncate_transcript:
                    continue
                if scenario_id in tamper_text:
                    text = text + " [tampered]"
                digest = hashlib.sha256(text.encode("utf-8")).hexdigest()
                row = {
                    "type": "assistant_message", "repeat": index, "action": 1,
                    "bot": "main", "turn": turn, "chars": len(text),
                    "sha256": digest, "text": text,
                }
                transcript_rows.append(row)
                rows_for_report.append({"bot": row["bot"], "turn": turn, "chars": row["chars"]})
            repeats.append({
                "index": index,
                "status": status,
                "assertions": assertions,
                "actions": [{"index": 1, "type": "user_message", "bot": "main",
                             "status": "ok", "replies": rows_for_report}],
            })
        report = {
            "schema_version": 1,
            "id": scenario_id,
            "upstream": upstream,
            "status": status,
            "run_status": status,
            "repeat": declared_repeat if declared_repeat is not None else repeat_count,
            "keep_bodies": keep_bodies,
            "started_at": started,
            "repeats": repeats,
        }
        (directory / "report.json").write_text(
            json.dumps(report, ensure_ascii=False), encoding="utf-8")
        transcript = [{"type": "scenario_start", "scenario": scenario_id}]
        if keep_bodies:
            transcript.extend(transcript_rows)
        (directory / "transcript.jsonl").write_text(
            "\n".join(json.dumps(row, ensure_ascii=False) for row in transcript) + "\n",
            encoding="utf-8")
        lines = []
        for index in range(1, repeat_count + 1):
            scenario_events = events.get(scenario_id)
            if scenario_events is None:
                scenario_events = default_events(scenario_id, index)
            lines.extend(scenario_events)
        (directory / "bot-events.jsonl").write_text(
            "\n".join(json.dumps(row, ensure_ascii=False) for row in lines) + "\n",
            encoding="utf-8")


def run_score(results: Path, out: Path, upstream: str = "real",
              engine_exit: int = 0, only: list | None = None) -> tuple[int, dict]:
    command = [
        sys.executable, str(SCORE),
        "--results", str(results), "--catalog", str(CATALOG),
        "--dimensions", str(DIMENSIONS), "--out", str(out),
        "--upstream", upstream, "--engine-exit", str(engine_exit),
        "--only", ",".join(only or []),
    ]
    completed = subprocess.run(command, capture_output=True, text=True)
    report_path = out / "aha-report.json"
    report = json.loads(report_path.read_text(encoding="utf-8")) if report_path.is_file() else {}
    return completed.returncode, report


class ScorerMutationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.results = self.root / "results"
        self.out = self.root / "out"
        self.plan = run_plan(self.results)
        write_marker(self.results)

    def test_real_pass(self) -> None:
        write_evidence(self.results, self.plan)
        code, report = run_score(self.results, self.out)
        self.assertEqual(code, 0, report.get("reason"))
        self.assertEqual(report["overall"], "PASS")
        self.assertEqual(len(report["scenarios"]), 9)
        for scenario in report["scenarios"]:
            self.assertEqual(scenario["status"], "PASS", scenario["id"])

    def test_mock_upstream_never_passes(self) -> None:
        plan = run_plan(self.results, upstream="mock")
        write_marker(self.results, upstream="mock")
        write_evidence(self.results, plan, upstream="mock")
        code, report = run_score(self.results, self.out, upstream="mock")
        self.assertEqual(code, 3)
        self.assertEqual(report["overall"], "NOT_RUN")

    def test_engine_fail_is_fail(self) -> None:
        write_evidence(self.results, self.plan, status="FAIL")
        code, report = run_score(self.results, self.out)
        self.assertEqual(code, 1)
        self.assertEqual(report["overall"], "FAIL")

    def test_missing_report_is_not_run(self) -> None:
        write_evidence(self.results, self.plan, skip={"AHA-INJECTION"})
        code, report = run_score(self.results, self.out)
        self.assertEqual(code, 3)
        self.assertEqual(report["overall"], "NOT_RUN")

    def test_hard_dimension_flip_fails(self) -> None:
        write_evidence(self.results, self.plan, flip={("AHA-INJECTION", 1, 0)})
        code, report = run_score(self.results, self.out)
        self.assertEqual(code, 1)
        scenario = next(s for s in report["scenarios"] if s["id"] == "AHA-INJECTION")
        self.assertEqual(scenario["status"], "FAIL")
        self.assertFalse(scenario["hard_ok"])

    def test_soft_score_below_threshold_fails(self) -> None:
        # AHA-COMPACT-REUSE has one soft dimension (reused); its bot_event
        # check is not reply-derived, so this isolates the soft threshold.
        write_evidence(self.results, self.plan, flip={("AHA-COMPACT-REUSE", 1, 3)})
        code, report = run_score(self.results, self.out)
        self.assertEqual(code, 1)
        scenario = next(s for s in report["scenarios"] if s["id"] == "AHA-COMPACT-REUSE")
        self.assertEqual(scenario["status"], "FAIL")
        self.assertAlmostEqual(scenario["soft_score"], 0.0)

    def test_second_repeat_failure_is_not_skipped(self) -> None:
        plan = run_plan(self.results, repeat=2)
        write_marker(self.results, repeat=2)
        write_evidence(self.results, plan, flip={("AHA-INJECTION", 2, 0)})
        code, report = run_score(self.results, self.out)
        self.assertEqual(code, 1)
        scenario = next(s for s in report["scenarios"] if s["id"] == "AHA-INJECTION")
        self.assertEqual(scenario["status"], "FAIL")
        failed = [check for dimension in scenario["dimensions"] for check in dimension["checks"]
                  if check["index"] == 0]
        self.assertTrue(failed)
        self.assertTrue(failed[0]["per_repeat"][0]["ok"])
        self.assertFalse(failed[0]["per_repeat"][1]["ok"])

    def test_declared_repeat_mismatch_fails(self) -> None:
        write_evidence(self.results, self.plan, declared_repeat=2)
        code, report = run_score(self.results, self.out)
        self.assertEqual(code, 1)
        self.assertIn("repeat", report["scenarios"][0]["reason"])

    def test_only_binds_to_plan_and_ignores_stale_other_dirs(self) -> None:
        selected = ["AHA-DISCOVER", "AHA-SOURCE"]
        plan = run_plan(self.results, only=selected)
        write_marker(self.results, only=selected)
        write_evidence(self.results, plan)
        # A stale failing directory for an unselected scenario must not poison
        # the partial run.
        stale = self.results / "AHA-INJECTION"
        stale.mkdir(parents=True, exist_ok=True)
        (stale / "report.json").write_text(json.dumps({
            "id": "AHA-INJECTION", "upstream": "real", "status": "FAIL",
            "run_status": "FAIL", "repeat": 1, "keep_bodies": True,
            "started_at": stamp(now()), "repeats": [{"index": 1, "status": "FAIL",
            "assertions": [], "actions": []}],
        }), encoding="utf-8")
        code, report = run_score(self.results, self.out, only=selected)
        self.assertEqual(code, 0, report.get("reason"))
        self.assertEqual(report["overall"], "PASS")
        self.assertEqual([s["id"] for s in report["scenarios"]], selected)

    def test_only_not_in_plan_fails(self) -> None:
        write_evidence(self.results, self.plan)
        code, _ = run_score(self.results, self.out, only=["AHA-NOT-PLANNED"])
        self.assertEqual(code, 2)

    def test_stale_report_is_rejected(self) -> None:
        marker_time = now() + dt.timedelta(minutes=5)
        write_marker(self.results, started=marker_time)
        write_evidence(self.results, self.plan,
                       report_started=marker_time - dt.timedelta(minutes=10))
        code, report = run_score(self.results, self.out)
        self.assertEqual(code, 1)
        self.assertIn("stale evidence", report["scenarios"][0]["reason"])

    def test_missing_marker_is_not_run(self) -> None:
        write_evidence(self.results, self.plan)
        (self.results / "aha-run.json").unlink()
        code, _ = run_score(self.results, self.out)
        self.assertEqual(code, 3)

    def test_provenance_without_evidence_fails(self) -> None:
        broken = [{
            "repeat": 1,
            "event": {
                "type": "memory.document_written",
                "data": {
                    "path": "agent/playbook/weekly.md",
                    "version": 1,
                    "content": "顺序：成果、风险、下周计划",
                    "evidence": [],
                    "trust": "user",
                    "author": {"kind": "chat", "bot_id": "bot-a"},
                },
            }
        }]
        write_evidence(self.results, self.plan, events={"AHA-COMPACT-REUSE": broken})
        code, report = run_score(self.results, self.out)
        self.assertEqual(code, 1)
        scenario = next(s for s in report["scenarios"] if s["id"] == "AHA-COMPACT-REUSE")
        self.assertEqual(scenario["status"], "FAIL")
        self.assertFalse(scenario["provenance"]["p0_ok"])

    def test_index_documents_do_not_require_evidence(self) -> None:
        events = [{
            "repeat": 1,
            "event": {
                "type": "memory.document_written",
                "data": {
                    "path": "agent/playbook/weekly.md",
                    "version": 1,
                    "content": "顺序：成果、风险、下周计划",
                    "evidence": ["record://session/gb-main#3"],
                    "trust": "user",
                    "author": {"kind": "chat", "bot_id": "bot-a"},
                },
            },
        }, {
            "repeat": 1,
            "event": {
                "type": "memory.document_written",
                "data": {
                    "path": "agent/INDEX.md",
                    "version": 1,
                    "content": "# Index",
                    "evidence": [],
                    "trust": "assistant",
                    "author": {"kind": "system", "bot_id": "bot-a"},
                },
            },
        }]
        write_evidence(self.results, self.plan, events={"AHA-COMPACT-REUSE": events})
        code, report = run_score(self.results, self.out)
        scenario = next(s for s in report["scenarios"] if s["id"] == "AHA-COMPACT-REUSE")
        self.assertTrue(scenario["provenance"]["p0_ok"], scenario["provenance"]["issues"])

    def test_verified_review_without_refs_fails(self) -> None:
        events = [{
            "repeat": 1,
            "event": {
                "type": "memory.document_written",
                "data": {
                    "path": "agent/playbook/weekly.md",
                    "version": 1,
                    "content": "顺序：成果、风险、下周计划",
                    "evidence": ["record://session/gb-main#3"],
                    "trust": "user",
                    "review": {"state": "verified", "basis": "user-statement"},
                    "author": {"kind": "chat", "bot_id": "bot-a"},
                },
            },
        }]
        write_evidence(self.results, self.plan, events={"AHA-COMPACT-REUSE": events})
        code, report = run_score(self.results, self.out)
        self.assertEqual(code, 1)
        scenario = next(s for s in report["scenarios"] if s["id"] == "AHA-COMPACT-REUSE")
        self.assertFalse(scenario["provenance"]["p0_ok"])
        self.assertTrue(any("verified review needs refs" in issue
                            for issue in scenario["provenance"]["issues"]))

    def test_verified_review_with_model_inference_fails(self) -> None:
        events = [{
            "repeat": 1,
            "event": {
                "type": "memory.document_written",
                "data": {
                    "path": "agent/playbook/weekly.md",
                    "version": 1,
                    "content": "顺序：成果、风险、下周计划",
                    "evidence": ["record://session/gb-main#3"],
                    "review": {"state": "verified", "basis": "model-inference",
                               "refs": ["record://session/gb-main#3"]},
                    "author": {"kind": "chat", "bot_id": "bot-a"},
                },
            },
        }]
        write_evidence(self.results, self.plan, events={"AHA-COMPACT-REUSE": events})
        code, _ = run_score(self.results, self.out)
        self.assertEqual(code, 1)

    def test_evidence_status_is_captured_from_session_log(self) -> None:
        write_evidence(self.results, self.plan)
        run_dir = self.results / "runs" / "AHA-COMPACT-REUSE-1" / "host" / "sessions"
        run_dir.mkdir(parents=True, exist_ok=True)
        evidence = json.dumps({
            "path": "agent/x.md",
            "evidence_status": [{"observed_at_ms": 1, "source_version": None}],
        })
        (run_dir / "session.v4.jsonl").write_text(json.dumps({
            "type": "tool/result",
            "data": {"message": {"content": [{"type": "text", "text": evidence}]}},
        }) + "\n", encoding="utf-8")
        code, report = run_score(self.results, self.out)
        self.assertEqual(code, 0, report.get("reason"))
        scenario = next(s for s in report["scenarios"] if s["id"] == "AHA-COMPACT-REUSE")
        self.assertEqual(scenario["evidence_status_observation"]["1"], 1)

    def test_assertion_mapping_drift_fails(self) -> None:
        write_evidence(
            self.results, self.plan,
            reply_overrides={"AHA-INJECTION": {0: "reply_contains"}})
        code, report = run_score(self.results, self.out)
        self.assertEqual(code, 1)
        scenario = next(s for s in report["scenarios"] if s["id"] == "AHA-INJECTION")
        self.assertEqual(scenario["status"], "FAIL")
        self.assertIn("type", scenario["reason"])

    def test_missing_reply_bodies_is_not_run(self) -> None:
        write_evidence(self.results, self.plan, keep_bodies=False)
        code, report = run_score(self.results, self.out)
        self.assertEqual(code, 3)
        self.assertEqual(report["overall"], "NOT_RUN")

    def test_transcript_missing_is_not_run(self) -> None:
        write_evidence(self.results, self.plan)
        (self.results / "AHA-SOURCE" / "transcript.jsonl").unlink()
        code, report = run_score(self.results, self.out)
        self.assertEqual(code, 3)
        scenario = next(s for s in report["scenarios"] if s["id"] == "AHA-SOURCE")
        self.assertEqual(scenario["status"], "NOT_RUN")

    def test_tampered_transcript_text_fails(self) -> None:
        write_evidence(self.results, self.plan)
        path = self.results / "AHA-SOURCE" / "transcript.jsonl"
        rows = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line]
        for row in rows:
            if row.get("type") == "assistant_message":
                row["text"] = row["text"] + " [tampered]"
        path.write_text("\n".join(json.dumps(row, ensure_ascii=False) for row in rows) + "\n",
                        encoding="utf-8")
        code, report = run_score(self.results, self.out)
        self.assertEqual(code, 1)
        scenario = next(s for s in report["scenarios"] if s["id"] == "AHA-SOURCE")
        self.assertEqual(scenario["status"], "FAIL")
        self.assertIn("sha256", scenario["reason"])

    def test_empty_transcript_text_fails(self) -> None:
        write_evidence(self.results, self.plan, truncate_transcript={"AHA-SOURCE"})
        code, report = run_score(self.results, self.out)
        self.assertEqual(code, 1)
        scenario = next(s for s in report["scenarios"] if s["id"] == "AHA-SOURCE")
        self.assertEqual(scenario["status"], "FAIL")
        self.assertIn("no assistant_message", scenario["reason"])

    def test_reply_recompute_disagreement_fails(self) -> None:
        write_evidence(self.results, self.plan)
        path = self.results / "AHA-SOURCE" / "report.json"
        report = json.loads(path.read_text(encoding="utf-8"))
        report["repeats"][0]["assertions"][0]["ok"] = False
        path.write_text(json.dumps(report), encoding="utf-8")
        code, report = run_score(self.results, self.out)
        self.assertEqual(code, 1)
        scenario = next(s for s in report["scenarios"] if s["id"] == "AHA-SOURCE")
        self.assertIn("recompute", scenario["reason"])

    def write_denials(self, scenario_id: str, repeat: int = 1) -> None:
        run_dir = self.results / "runs" / f"{scenario_id}-{repeat}" / "host" / "sessions"
        run_dir.mkdir(parents=True, exist_ok=True)
        (run_dir / "session.v4.jsonl").write_text(json.dumps({
            "type": "tool/result",
            "data": {"message": {"content": [{"type": "text", "text":
                "Error: [structural approval gate] 身份登记已失效"}]}},
        }) + "\n", encoding="utf-8")

    def test_contaminated_host_tools_block_scored_scenario(self) -> None:
        write_evidence(self.results, self.plan)
        self.write_denials("AHA-DISCOVER")
        code, report = run_score(self.results, self.out)
        self.assertEqual(code, 3)
        scenario = next(s for s in report["scenarios"] if s["id"] == "AHA-DISCOVER")
        self.assertEqual(scenario["status"], "NOT_RUN")
        self.assertIn("identity/approval gate", scenario["reason"])

    def test_contaminated_auxiliary_scenario_only_warns(self) -> None:
        write_evidence(self.results, self.plan)
        self.write_denials("AHA-COMPACT-REUSE")
        code, report = run_score(self.results, self.out)
        # The scored dimensions do not depend on the denied auxiliary tool; the
        # denial is recorded as a note and the scenario is still evaluated.
        self.assertEqual(code, 0)
        scenario = next(s for s in report["scenarios"] if s["id"] == "AHA-COMPACT-REUSE")
        self.assertEqual(scenario["status"], "PASS")
        self.assertTrue(any("denied host tool calls" in note for note in scenario["notes"]))

    def test_upstream_mismatch_fails(self) -> None:
        write_evidence(self.results, self.plan, upstream="mock")
        code, report = run_score(self.results, self.out, upstream="real")
        self.assertEqual(code, 1)
        self.assertEqual(report["overall"], "FAIL")

    def test_empty_assertions_fail(self) -> None:
        write_evidence(self.results, self.plan)
        directory = self.results / "AHA-SOURCE"
        report = json.loads((directory / "report.json").read_text(encoding="utf-8"))
        report["repeats"][0]["assertions"] = []
        (directory / "report.json").write_text(json.dumps(report), encoding="utf-8")
        code, _ = run_score(self.results, self.out)
        self.assertEqual(code, 1)


if __name__ == "__main__":
    unittest.main()
