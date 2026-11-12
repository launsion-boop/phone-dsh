#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Mutation tests for check_fish.py.

Each test builds a throw-away repository root: the fish spec directory is
copied (so the test can mutate the goldens), while `examples/`, `Sources/`,
`NOTICE` and `LICENSE` are symlinked read-only. The checker is invoked as a
subprocess exactly the way CI invokes it, and every mutation must fail with the
expected diagnostic. A checker that silently accepts a mutated golden would
pass this suite only if the test itself is broken, so the tests also assert the
unmutated tree passes.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[6]
CHECK = Path(__file__).resolve().with_name("check_fish.py")
FISH_REL = Path("spec/ui/v1/bot/fish")


class FishCheckTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = Path(tempfile.mkdtemp(prefix="fish-check-test-"))
        target = self.temp / FISH_REL
        target.parent.mkdir(parents=True)
        shutil.copytree(REPO_ROOT / FISH_REL, target)
        for name in ("examples", "Sources"):
            os.symlink(REPO_ROOT / name, self.temp / name)
        for name in ("NOTICE", "LICENSE"):
            os.symlink(REPO_ROOT / name, self.temp / name)

    def tearDown(self) -> None:
        shutil.rmtree(self.temp, ignore_errors=True)

    # -- helpers ---------------------------------------------------------
    def run_check(self, root: Path | None = None) -> subprocess.CompletedProcess:
        return subprocess.run(
            [sys.executable, str(CHECK), "--root", str(root or self.temp)],
            capture_output=True, text=True, timeout=180)

    def load(self, name: str) -> dict:
        path = self.temp / FISH_REL / "golden" / name
        return json.loads(path.read_text(encoding="utf-8"))

    def save(self, name: str, value: dict) -> None:
        path = self.temp / FISH_REL / "golden" / name
        path.write_text(json.dumps(value, indent=2, sort_keys=True,
                                   ensure_ascii=False) + "\n", encoding="utf-8")

    def mutate_trajectory(self, mutate) -> None:
        value = self.load("trajectory.json")
        mutate(value)
        self.save("trajectory.json", value)

    def mutate_assets(self, mutate) -> None:
        value = self.load("assets.json")
        mutate(value)
        self.save("assets.json", value)

    def assert_fails(self, *needles: str) -> None:
        result = self.run_check()
        self.assertNotEqual(result.returncode, 0,
                            f"checker unexpectedly passed:\n{result.stdout}")
        for needle in needles:
            self.assertIn(needle, result.stderr,
                          f"missing diagnostic {needle!r}:\n{result.stderr}")

    # -- baseline --------------------------------------------------------
    def test_current_checkout_passes(self) -> None:
        result = self.run_check(REPO_ROOT)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("check_fish: OK", result.stdout)

    def test_fresh_copy_passes(self) -> None:
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stderr)

    # -- schema / params / pose -----------------------------------------
    def test_schema_version_mutation_fails(self) -> None:
        self.mutate_trajectory(lambda value: value.__setitem__("schemaVersion", 2))
        self.assert_fails("schemaVersion")

    def test_missing_param_fails(self) -> None:
        def mutate(value):
            del value["cases"][0]["frames"][0]["params"]["smile"]
        self.mutate_trajectory(mutate)
        self.assert_fails("parameter key set")

    def test_pose_mutation_fails(self) -> None:
        def mutate(value):
            frame = value["cases"][0]["frames"][0]
            frame["pose"]["offsetX"] = frame["pose"]["offsetX"] + 0.25
        self.mutate_trajectory(mutate)
        self.assert_fails("pose.offsetX", "pose/boost/quantum")

    # -- head-slice quantum (FISH-1) -------------------------------------
    def test_lively_slice_restores_with_standard_quantum_fails(self) -> None:
        def mutate(value):
            case = next(c for c in value["headSlice"]["cases"]
                        if c["id"] == "lively-values")
            # The old bug: a lively level restored at the standard 0.1.
            case["displacement"]["headX"] = case["levels"]["headX"] * 0.1
        self.mutate_trajectory(mutate)
        self.assert_fails("displacement.headX", "lively quantum")

    def test_slice_profile_quantum_mutation_fails(self) -> None:
        def mutate(value):
            case = next(c for c in value["headSlice"]["cases"]
                        if c["id"] == "lively-values")
            case["quantum"] = 0.1
        self.mutate_trajectory(mutate)
        self.assert_fails("must be the lively quantum")

    def test_slice_half_away_mutation_fails(self) -> None:
        def mutate(value):
            case = next(c for c in value["headSlice"]["cases"]
                        if c["id"] == "standard-half-away")
            case["levels"]["headX"] = 0
        self.mutate_trajectory(mutate)
        self.assert_fails("levels.headX", "expected 1")

    def test_slice_missing_profile_fails(self) -> None:
        def mutate(value):
            value["headSlice"]["cases"] = [
                c for c in value["headSlice"]["cases"]
                if c["profile"] != "lively"]
        self.mutate_trajectory(mutate)
        self.assert_fails("both profiles")

    def test_alpha_mutation_fails(self) -> None:
        def mutate(value):
            value["cases"][0]["frames"][0]["alpha"] = 0.5
        self.mutate_trajectory(mutate)
        self.assert_fails("alpha")

    def test_time_mutation_fails(self) -> None:
        def mutate(value):
            value["cases"][0]["frames"][0]["timeMs"] = 1.0
        self.mutate_trajectory(mutate)
        self.assert_fails("timeMs")

    def test_frame_order_mutation_fails(self) -> None:
        def mutate(value):
            frames = value["cases"][0]["frames"]
            frames.reverse()
        self.mutate_trajectory(mutate)
        self.assert_fails("step")

    def test_missing_case_fails(self) -> None:
        def mutate(value):
            value["cases"] = [case for case in value["cases"]
                              if case["name"] != "p0-idle"]
        self.mutate_trajectory(mutate)
        self.assert_fails("missing cases")

    def test_random_prefix_mutation_fails(self) -> None:
        def mutate(value):
            value["cases"][-1]["randomValues"][0] = 0.25
        self.mutate_trajectory(mutate)
        self.assert_fails("LCG prefix")

    # -- clips / sprites / tint -----------------------------------------
    def test_clip_period_mutation_fails(self) -> None:
        def mutate(value):
            value["clips"]["idle"]["period"] = 2401
        self.mutate_trajectory(mutate)
        self.assert_fails("atlas period")

    def test_sprite_order_mutation_fails(self) -> None:
        def mutate(value):
            eyes = value["spriteOrder"]["eyes"]
            eyes[0], eyes[1] = eyes[1], eyes[0]
        self.mutate_trajectory(mutate)
        self.assert_fails("spriteOrder.eyes")

    def test_palette_lut_mutation_fails(self) -> None:
        def mutate(value):
            value["palettes"][0]["lut"][255] = (value["palettes"][0]["lut"][255] + 1) % 256
        self.mutate_trajectory(mutate)
        self.assert_fails("LUT differs")

    # -- sources / anchors / assets -------------------------------------
    def test_source_hash_mutation_fails(self) -> None:
        def mutate(value):
            value["source"]["files"][0]["sha256"] = "0" * 64
        self.mutate_trajectory(mutate)
        self.assert_fails("SHA-256 drifted")

    def test_stale_anchor_fails(self) -> None:
        def mutate(value):
            value["anchors"][0]["contains"] = "this line no longer exists"
        self.mutate_trajectory(mutate)
        self.assert_fails("no longer contains")

    def test_asset_hash_mutation_fails(self) -> None:
        def mutate(value):
            value["files"][0]["sha256"] = "0" * 64
        self.mutate_assets(mutate)
        self.assert_fails("SHA-256 drifted")

    def test_asset_manifest_count_mutation_fails(self) -> None:
        def mutate(value):
            value["files"] = value["files"][:-1]
        self.mutate_assets(mutate)
        self.assert_fails("manifest/actual mismatch", "frozen 35-file set")

    def test_atlas_missing_exception_mutation_fails(self) -> None:
        def mutate(value):
            value["atlas"]["missingFiles"] = value["atlas"]["missingFiles"][:-1]
        self.mutate_assets(mutate)
        self.assert_fails("atlas.missingFiles")

    def test_grant_scope_mutation_fails(self) -> None:
        def mutate(value):
            # The extended grant is ios+android; a false flag contradicts it.
            value["source"]["grant"]["androidGranted"] = False
        self.mutate_assets(mutate)
        self.assert_fails("androidGranted")

    # -- documentation ---------------------------------------------------
    def test_doc_requirement_mutation_fails(self) -> None:
        doc = self.temp / FISH_REL / "fish.md"
        text = doc.read_text(encoding="utf-8").replace("PROPOSAL", "proposal")
        doc.write_text(text, encoding="utf-8")
        self.assert_fails("missing required text")


if __name__ == "__main__":
    unittest.main()
