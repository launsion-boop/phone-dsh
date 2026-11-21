#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Reference oracle for engine-first launch (P06, host README sections 10.2 and 10.3).

The schema is judged by the repository validator; the decision order, the ReadySweep step gate,
the wake projection and the strict input decoders are judged here, because a JSON schema cannot
express them. Every end's real implementation (Swift now, Kotlin later) must agree with the same
golden. The README tables are also read back so the normative text and the vectors cannot drift.
"""
from __future__ import annotations

import json
import re
import sys
import unittest
from pathlib import Path

TOOLS = Path(__file__).resolve().parent
V1_TOOLS = TOOLS.parents[2] / "v1" / "tools"
sys.path.insert(0, str(V1_TOOLS))

from spec_golden import load_json, validate_json  # noqa: E402

CONTRACT = TOOLS.parent
GOLDEN = CONTRACT / "golden" / "engine-launch.json"
SCHEMA = CONTRACT / "schema" / "engine-launch.schema.json"
README = CONTRACT / "README.md"

DECISION_MEMBERS = ("reason", "foreground", "residentAudio", "hostState", "leaseRemainingMs",
                    "userStopped", "needsReset")
HOST_STATES = ("absent", "parked", "running", "failed")
DEMAND_MEMBERS = ("source", "key", "dueAtMs", "kind", "userVisible")
KEY = re.compile(r"^[A-Za-z0-9._:-]{1,128}$")


class Rejected(Exception):
    def __init__(self, reason: str):
        super().__init__(reason)
        self.reason = reason


def _is_int(value) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


class Oracle:
    def __init__(self, instance: dict):
        self.c = instance["constants"]
        self.reasons = tuple(instance["wakeReasons"])
        self.steps = tuple(instance["steps"])
        self.sources = tuple(instance["demandSources"])

    # -- 10.2.4 -----------------------------------------------------------------------------
    def decode_decision(self, raw: dict) -> dict:
        for member in DECISION_MEMBERS:
            if member not in raw:
                raise Rejected("missing-member")
        for member in ("foreground", "residentAudio", "userStopped", "needsReset"):
            if not isinstance(raw[member], bool):
                raise Rejected("member-type")
        if not isinstance(raw["reason"], str) or not isinstance(raw["hostState"], str):
            raise Rejected("member-type")
        if raw["reason"] not in self.reasons:
            raise Rejected("unknown-reason")
        if raw["hostState"] not in HOST_STATES:
            raise Rejected("unknown-host-state")
        lease = raw["leaseRemainingMs"]
        if lease is not None:
            if not _is_int(lease):
                raise Rejected("lease-not-integer")
            if lease < 0:
                raise Rejected("lease-negative")
        return raw

    def decide(self, raw: dict) -> str:
        x = self.decode_decision(raw)
        if x["needsReset"]:
            return "needsAttention"
        if x["userStopped"]:
            return "defer"
        if x["hostState"] == "running":
            return "ready"
        required = (self.c["minLeaseForResumeMs"] if x["hostState"] == "parked"
                    else self.c["minLeaseForColdBootMs"])
        lease = x["leaseRemainingMs"]
        eligible = x["foreground"] or x["residentAudio"] or (lease is not None and lease >= required)
        if not eligible:
            return "nativeOnly"
        return "resume" if x["hostState"] == "parked" else "boot"

    # -- 10.2.5 / 10.3.5 --------------------------------------------------------------------
    def should_run(self, raw: dict) -> str:
        if "step" not in raw or "remainingMs" not in raw:
            raise Rejected("missing-member")
        if not isinstance(raw["step"], str) or not _is_int(raw["remainingMs"]):
            raise Rejected("member-type")
        if raw["step"] not in self.steps:
            raise Rejected("unknown-step")
        if raw["remainingMs"] < 0:
            raise Rejected("remaining-negative")
        need = self.c["parkMarginMs"] + self.c["stepBudgetMs"][raw["step"]]
        return "run" if raw["remainingMs"] >= need else "skip"

    # -- 10.3.3 -----------------------------------------------------------------------------
    def decode_projection(self, raw: dict) -> dict:
        for member in ("nowMs", "resident", "demands"):
            if member not in raw:
                raise Rejected("missing-member")
        if not _is_int(raw["nowMs"]) or raw["nowMs"] < 0 or not isinstance(raw["resident"], bool) \
                or not isinstance(raw["demands"], list):
            raise Rejected("member-type")
        seen = set()
        for demand in raw["demands"]:
            if not isinstance(demand, dict):
                raise Rejected("member-type")
            for member in DEMAND_MEMBERS:
                if member not in demand:
                    raise Rejected("missing-member")
            if not isinstance(demand["source"], str) or not isinstance(demand["kind"], str) \
                    or not isinstance(demand["userVisible"], bool) or not _is_int(demand["dueAtMs"]) \
                    or not isinstance(demand["key"], str) or not KEY.match(demand["key"]):
                raise Rejected("member-type")
            if demand["source"] not in self.sources:
                raise Rejected("unknown-source")
            if demand["kind"] not in ("once", "recurring"):
                raise Rejected("unknown-kind")
            if demand["dueAtMs"] < 0:
                raise Rejected("due-negative")
            identity = (demand["source"], demand["key"])
            if identity in seen:
                raise Rejected("duplicate-demand")
            seen.add(identity)
        return raw

    def plan(self, raw: dict) -> dict:
        x = self.decode_projection(raw)
        now, demands = x["nowMs"], x["demands"]
        if not demands:
            return {"residentTimerAtMs": None, "backgroundEarliestMs": None, "dueNow": []}
        earliest = min(d["dueAtMs"] for d in demands)
        due = sorted((d for d in demands if d["dueAtMs"] <= now),
                     key=lambda d: (d["dueAtMs"], self.sources.index(d["source"]), d["key"]))
        return {
            "residentTimerAtMs": max(earliest, now) if x["resident"] else None,
            "backgroundEarliestMs": max(earliest, now + self.c["minBackgroundDelayMs"]),
            "dueNow": [{"source": d["source"], "key": d["key"]} for d in due],
        }


def _table_rows(text: str, header_first_cell: str) -> list[list[str]]:
    """Rows of the first markdown table whose header row starts with `header_first_cell`."""
    lines = text.splitlines()
    for index, line in enumerate(lines):
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if line.lstrip().startswith("|") and cells and cells[0] == header_first_cell:
            rows = []
            for body in lines[index + 2:]:
                if not body.lstrip().startswith("|"):
                    break
                rows.append([c.strip() for c in body.strip().strip("|").split("|")])
            return rows
    raise AssertionError(f"README table with first header {header_first_cell!r} not found")


def _ticked(cell: str) -> str:
    match = re.search(r"`([^`]+)`", cell)
    return match.group(1) if match else cell


class EngineLaunchContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.doc = json.loads(GOLDEN.read_text(encoding="utf-8"))
        cls.instance = cls.doc["instance"]
        cls.oracle = Oracle(cls.instance)
        cls.readme = README.read_text(encoding="utf-8")

    def test_golden_matches_schema(self):
        self.assertEqual(self.doc["schema"], "schema/engine-launch.schema.json")
        self.assertIsNone(validate_json(self.instance, load_json(SCHEMA), "engine-launch"))
        self.assertEqual(self.instance["revision"], 3)

    def test_decision_vectors(self):
        for vector in self.instance["decisionVectors"]:
            with self.subTest(vector["id"]):
                self.assertEqual(self.oracle.decide(vector["input"]), vector["expected"])

    def test_invalid_decision_vectors(self):
        for vector in self.instance["invalidDecisionVectors"]:
            with self.subTest(vector["id"]):
                with self.assertRaises(Rejected) as caught:
                    self.oracle.decide(vector["input"])
                self.assertEqual(caught.exception.reason, vector["reason"])

    def test_sweep_vectors(self):
        for vector in self.instance["sweepVectors"]:
            with self.subTest(vector["id"]):
                self.assertEqual(self.oracle.should_run(
                    {"step": vector["step"], "remainingMs": vector["remainingMs"]}), vector["expected"])

    def test_invalid_sweep_vectors(self):
        for vector in self.instance["invalidSweepVectors"]:
            with self.subTest(vector["id"]):
                with self.assertRaises(Rejected) as caught:
                    self.oracle.should_run(vector["input"])
                self.assertEqual(caught.exception.reason, vector["reason"])

    def test_projection_vectors(self):
        for vector in self.instance["projectionVectors"]:
            with self.subTest(vector["id"]):
                self.assertEqual(self.oracle.plan(vector["input"]), vector["expected"])

    def test_invalid_projection_vectors(self):
        for vector in self.instance["invalidProjectionVectors"]:
            with self.subTest(vector["id"]):
                with self.assertRaises(Rejected) as caught:
                    self.oracle.plan(vector["input"])
                self.assertEqual(caught.exception.reason, vector["reason"])

    def test_every_vocabulary_value_is_exercised(self):
        reasons = {v["input"]["reason"] for v in self.instance["decisionVectors"]}
        self.assertEqual(reasons, set(self.instance["wakeReasons"]), "every WakeReason has a vector")
        decisions = {v["expected"] for v in self.instance["decisionVectors"]}
        self.assertEqual(decisions, set(self.instance["decisions"]), "every decision is reached")
        for step in self.instance["steps"]:
            outcomes = {v["expected"] for v in self.instance["sweepVectors"] if v["step"] == step}
            self.assertEqual(outcomes, {"run", "skip"}, f"{step} has both a run and a skip boundary")
        sources = {d["source"] for v in self.instance["projectionVectors"] for d in v["input"]["demands"]}
        self.assertEqual(sources, set(self.instance["demandSources"]), "every demand source is projected")

    def test_readme_tables_agree_with_golden(self):
        reasons = [_ticked(row[0]) for row in _table_rows(self.readme, "Value")]
        self.assertEqual(reasons, self.instance["wakeReasons"], "README WakeReason table")
        steps = [_ticked(row[1]) for row in _table_rows(self.readme, "#")]
        self.assertEqual(steps, self.instance["steps"], "README ReadySweep step table")
        budgets = {_ticked(row[0]): int(_ticked(row[1])) for row in _table_rows(self.readme, "Step")}
        self.assertEqual(budgets, self.instance["constants"]["stepBudgetMs"], "README step budgets")
        sources = [_ticked(row[0]) for row in _table_rows(self.readme, "Source")]
        self.assertEqual(sources, self.instance["demandSources"], "README WakeDemand sources")
        constants = {_ticked(row[0]): int(_ticked(row[1])) for row in _table_rows(self.readme, "Constant")}
        for name, value in self.instance["constants"].items():
            if name != "stepBudgetMs":
                self.assertEqual(constants.get(name), value, f"README constant {name}")

    def test_oracle_rejects_mutations(self):
        """The oracle must notice a broken rule, not merely agree with the file."""
        mutated = Oracle(self.instance)
        mutated.c = dict(self.instance["constants"], minLeaseForColdBootMs=19999)
        boundary = next(v for v in self.instance["decisionVectors"]
                        if v["id"] == "bg-app-refresh-below-cold-boot-is-native-only")
        self.assertNotEqual(mutated.decide(boundary["input"]), boundary["expected"])
        mutated.c = dict(self.instance["constants"], minBackgroundDelayMs=0)
        clamp = next(v for v in self.instance["projectionVectors"]
                     if v["id"] == "near-demand-background-clamped-to-min-delay")
        self.assertNotEqual(mutated.plan(clamp["input"]), clamp["expected"])


if __name__ == "__main__":
    unittest.main()
