# SPDX-License-Identifier: MIT
"""Unit tests for the cross-platform element-geometry comparator.

These tests are synthetic on purpose: they pin the comparator's contract
(missing elements, per-axis tolerance, line counts, wrap points) without
requiring either app to run. The real exporters are exercised by their own
platform commands.
"""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

import compare_geometry


def element(
    element_id: str,
    *,
    x: float = 10.0,
    y: float = 20.0,
    w: float = 100.0,
    h: float = 30.0,
    identity: str = "testTag",
    text: str | None = None,
    lines: list[str] | None = None,
    wrap_points: list[int] | None = None,
    tolerance: float | dict[str, float] | None = None,
    gated_axes: list[str] | None = None,
    exemption: str | None = None,
    found: bool = True,
) -> dict:
    value = {
        "id": element_id,
        "found": found,
        "identity": identity,
        "frame": {"x": x, "y": y, "w": w, "h": h},
        "absoluteFrame": {"x": x + 40.0, "y": y + 60.0, "w": w, "h": h},
        "text": text,
        "lines": lines,
        "lineCount": None if lines is not None else None,
        "wrapPoints": wrap_points,
    }
    if tolerance is not None:
        value["tolerance"] = tolerance
    if gated_axes is not None:
        value["gatedAxes"] = gated_axes
    if exemption is not None:
        value["exemption"] = exemption
    return value


def export(
    *elements: dict,
    platform: str = "android",
    fixture: str = "fixture-a",
    origin: str = "root",
    unit: str = "pt",
) -> dict:
    return {
        "schema": compare_geometry.SCHEMA,
        "fixture": fixture,
        "platform": platform,
        "unit": unit,
        "origin": origin,
        "originMissing": None,
        "frame": {"width": 402, "height": 874},
        "generatedAt": "2026-11-12T00:00:00+00:00",
        "elements": list(elements),
    }


class CompareTests(unittest.TestCase):
    def test_identical_frames_pass(self) -> None:
        report = compare_geometry.compare(
            export(element("root", x=0, y=0), element("a")),
            export(element("root", x=0, y=0), element("a"), platform="ios"),
        )
        self.assertEqual("PASS", report["status"])
        self.assertEqual([], report["failures"])
        self.assertEqual("PASS", report["elements"][1]["status"])

    def test_delta_above_default_tolerance_fails(self) -> None:
        report = compare_geometry.compare(
            export(element("a")),
            export(element("a", x=11.5), platform="ios"),
        )
        self.assertEqual("FAIL", report["status"])
        self.assertAlmostEqual(-1.5, report["elements"][0]["delta"]["x"])
        self.assertIn("Δx=-1.500", report["failures"][0])

    def test_delta_inside_tolerance_passes(self) -> None:
        report = compare_geometry.compare(
            export(element("a")),
            export(element("a", x=10.5), platform="ios"),
        )
        self.assertEqual("PASS", report["status"])

    def test_per_element_tolerance_is_honoured(self) -> None:
        # Default 1 pt would fail this 2 pt delta; the fixture allows 2.5 pt.
        report = compare_geometry.compare(
            export(element("a", tolerance=2.5)),
            export(element("a", x=12.0, tolerance=2.5), platform="ios"),
        )
        self.assertEqual("PASS", report["status"])
        self.assertEqual(2.5, report["elements"][0]["tolerance"]["x"])

    def test_per_axis_tolerance_is_honoured(self) -> None:
        report = compare_geometry.compare(
            export(element("a", tolerance={"x": 2.5, "y": 0.5, "w": 1, "h": 1})),
            export(
                element("a", x=12.0, y=20.2, tolerance={"x": 2.5, "y": 0.5, "w": 1, "h": 1}),
                platform="ios",
            ),
        )
        self.assertEqual("PASS", report["status"])

    def test_ungated_axis_is_reported_but_not_failed(self) -> None:
        report = compare_geometry.compare(
            export(element("a", gated_axes=["x", "w", "h"], exemption="insets")),
            export(
                element("a", y=80.0, gated_axes=["x", "w", "h"], exemption="insets"),
                platform="ios",
            ),
        )
        self.assertEqual("PASS", report["status"])
        self.assertEqual(-60.0, report["elements"][0]["delta"]["y"])
        self.assertEqual(["y"], report["elements"][0]["skippedAxes"])
        self.assertEqual("insets", report["elements"][0]["exemption"])

    def test_gated_axes_mismatch_between_exporters_fails(self) -> None:
        report = compare_geometry.compare(
            export(element("a", gated_axes=["x", "w", "h"])),
            export(element("a"), platform="ios"),
        )
        self.assertEqual("FAIL", report["status"])
        self.assertIn("gatedAxes differs", report["failures"][0])

    def test_invalid_gated_axis_is_an_input_error(self) -> None:
        with self.assertRaises(compare_geometry.InputError):
            compare_geometry.compare(
                export(element("a", gated_axes=["x", "depth"])),
                export(element("a", gated_axes=["x", "depth"]), platform="ios"),
            )

    def test_tolerance_mismatch_between_exporters_fails(self) -> None:
        report = compare_geometry.compare(
            export(element("a", tolerance=2.5)),
            export(element("a", tolerance=1.0), platform="ios"),
        )
        self.assertEqual("FAIL", report["status"])
        self.assertIn("tolerance differs", report["failures"][0])

    def test_missing_element_fails(self) -> None:
        report = compare_geometry.compare(
            export(element("a"), element("b")),
            export(element("a"), platform="ios"),
        )
        self.assertEqual("FAIL", report["status"])
        self.assertIn("b: missing on ios", report["failures"])

    def test_element_not_found_fails(self) -> None:
        report = compare_geometry.compare(
            export(element("a", found=False)),
            export(element("a"), platform="ios"),
        )
        self.assertEqual("FAIL", report["status"])
        self.assertIn("not found", report["failures"][0])

    def test_line_count_mismatch_fails(self) -> None:
        report = compare_geometry.compare(
            export(element("a", text="one two", lines=["one", "two"])),
            export(element("a", text="one two", lines=["one two"]), platform="ios"),
        )
        self.assertEqual("FAIL", report["status"])
        self.assertIn("line count 2 vs 1", report["failures"][0])
        self.assertEqual(2, report["elements"][0]["androidLineCount"])
        self.assertEqual(1, report["elements"][0]["iosLineCount"])

    def test_line_count_only_on_one_side_is_reported_not_failed(self) -> None:
        report = compare_geometry.compare(
            export(element("a", text="one two", lines=["one", "two"])),
            export(element("a", text="one two", lines=None), platform="ios"),
        )
        self.assertEqual("PASS", report["status"])
        self.assertIsNone(report["elements"][0]["linesMatch"])
        self.assertIn("line count only on android", report["warnings"][0])

    def test_wrap_point_mismatch_fails(self) -> None:
        report = compare_geometry.compare(
            export(element("a", text="abc def", lines=["abc", "def"], wrap_points=[4])),
            export(
                element("a", text="abc def", lines=["abc", "def"], wrap_points=[3]),
                platform="ios",
            ),
        )
        self.assertEqual("FAIL", report["status"])
        self.assertIn("wrap points [4] vs [3]", report["failures"][0])

    def test_wrap_points_only_on_one_side_is_reported_not_failed(self) -> None:
        report = compare_geometry.compare(
            export(element("a", text="abc def", lines=["abc", "def"], wrap_points=[4])),
            export(element("a", text="abc def", lines=["abc", "def"]), platform="ios"),
        )
        self.assertEqual("PASS", report["status"])
        self.assertIsNone(report["elements"][0]["wrapPointsMatch"])

    def test_text_difference_is_a_warning_not_a_geometry_failure(self) -> None:
        report = compare_geometry.compare(
            export(element("a", text="设置", lines=["设置"])),
            export(element("a", text="Settings", lines=["Settings"]), platform="ios"),
        )
        self.assertEqual("PASS", report["status"])
        self.assertFalse(report["elements"][0]["textMatch"])
        self.assertIn("text differs", report["warnings"][0])

    def test_fixture_mismatch_is_an_input_error(self) -> None:
        with self.assertRaises(compare_geometry.InputError):
            compare_geometry.compare(
                export(element("a"), fixture="one"),
                export(element("a"), platform="ios", fixture="two"),
            )

    def test_unit_mismatch_is_an_input_error(self) -> None:
        with self.assertRaises(compare_geometry.InputError):
            compare_geometry.compare(
                export(element("a"), unit="pt"),
                export(element("a"), platform="ios", unit="px"),
            )

    def test_origin_mismatch_is_an_input_error(self) -> None:
        with self.assertRaises(compare_geometry.InputError):
            compare_geometry.compare(
                export(element("a"), origin="root"),
                export(element("a"), platform="ios", origin="header"),
            )

    def test_missing_origin_is_an_input_error(self) -> None:
        right = export(element("a"), platform="ios")
        right["originMissing"] = True
        with self.assertRaises(compare_geometry.InputError):
            compare_geometry.compare(export(element("a")), right)

    def test_markdown_and_json_reports_are_written(self) -> None:
        report = compare_geometry.compare(
            export(element("a")),
            export(element("a", x=12.0), platform="ios"),
        )
        with tempfile.TemporaryDirectory() as directory:
            markdown_path, json_path = compare_geometry.write_reports(
                report, Path(directory), "fixture-a"
            )
            markdown = markdown_path.read_text(encoding="utf-8")
            payload = json.loads(json_path.read_text(encoding="utf-8"))
        self.assertIn("# Parity geometry — `fixture-a`", markdown)
        self.assertIn("**Status: FAIL**", markdown)
        self.assertIn("Δx=-2.0", markdown)
        self.assertEqual("FAIL", payload["status"])
        self.assertEqual("fixture-a", payload["fixture"])

    def test_load_export_rejects_wrong_schema(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bad.json"
            path.write_text(json.dumps({"schema": "wrong"}), encoding="utf-8")
            with self.assertRaises(compare_geometry.InputError):
                compare_geometry.load_export(path)

    def test_negative_default_tolerance_is_rejected(self) -> None:
        with self.assertRaises(compare_geometry.InputError):
            compare_geometry.compare(export(element("a")), export(element("a")), -1)


if __name__ == "__main__":
    unittest.main()
