#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Compare element geometry exported by the Android and iOS parity exporters.

The bench deliberately compares *frames* (accessibility / Compose semantics),
text content and text line structure, never pixels. CoreText and Android's
Minikin/HarfBuzz rasterise glyphs differently, so a pixel diff measures font
rasterisation, not layout.

Input is the shared export v0 format written by:
  * android/lib/src/test/kotlin/com/phonedsh/ui/parity/ParityGeometryExportTest.kt
  * examples/probe-app/PhoneDSHDeviceUITests/ParityGeometryExportUITests.swift

Usage:
    python3 scripts/parity/compare_geometry.py \
        --android build/parity/android/chat-empty.json \
        --ios build/parity/ios/chat-empty.json \
        --out-dir build/parity/reports

Exit status is 0 only when every compared element passes. Missing elements,
frame deltas above tolerance, line-count and wrap-point mismatches fail.
"""

from __future__ import annotations

import argparse
import datetime as _datetime
import json
import math
import sys
from pathlib import Path
from typing import Any

SCHEMA = "pdsh.parity.geometry-export.v0"
REPORT_SCHEMA = "pdsh.parity.geometry-report.v0"
DEFAULT_TOLERANCE_PT = 1.0
AXES = ("x", "y", "w", "h")


class InputError(ValueError):
    """An export file is malformed or the pair is not comparable."""


def _number(value: Any, where: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise InputError(f"{where}: expected a number, got {value!r}")
    number = float(value)
    if not math.isfinite(number):
        raise InputError(f"{where}: expected a finite number, got {value!r}")
    return number


def load_export(path: Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise InputError(f"missing export: {path}") from error
    except json.JSONDecodeError as error:
        raise InputError(f"{path}: invalid JSON: {error}") from error
    if not isinstance(data, dict):
        raise InputError(f"{path}: export must be a JSON object")
    if data.get("schema") != SCHEMA:
        raise InputError(f"{path}: schema must be {SCHEMA!r}, got {data.get('schema')!r}")
    for key in ("fixture", "platform", "unit", "elements"):
        if key not in data:
            raise InputError(f"{path}: missing {key!r}")
    if data["platform"] not in ("android", "ios"):
        raise InputError(f"{path}: platform must be 'android' or 'ios', got {data['platform']!r}")
    if not isinstance(data["elements"], list) or not data["elements"]:
        raise InputError(f"{path}: elements must be a non-empty list")
    for index, element in enumerate(data["elements"]):
        if not isinstance(element, dict) or not isinstance(element.get("id"), str):
            raise InputError(f"{path}: elements[{index}] must be an object with a string id")
    return data


def _gated_axes(element: dict[str, Any]) -> list[str]:
    raw = element.get("gatedAxes", list(AXES))
    if not isinstance(raw, list) or any(axis not in AXES for axis in raw):
        raise InputError(f"{element['id']}.gatedAxes: expected a subset of {list(AXES)}")
    return list(raw)


def _tolerance_for(element: dict[str, Any], default: float) -> dict[str, float]:
    raw = element.get("tolerance", default)
    if isinstance(raw, (int, float)) and not isinstance(raw, bool):
        value = _number(raw, f"{element['id']}.tolerance")
        return {axis: value for axis in AXES}
    if isinstance(raw, dict):
        result = {}
        for axis in AXES:
            result[axis] = _number(raw.get(axis, default), f"{element['id']}.tolerance.{axis}")
        return result
    raise InputError(f"{element['id']}.tolerance: expected a number or per-axis object")


def _frame(element: dict[str, Any]) -> dict[str, float] | None:
    raw = element.get("frame")
    if raw is None:
        return None
    if not isinstance(raw, dict):
        raise InputError(f"{element['id']}.frame: expected an object")
    return {axis: _number(raw.get(axis), f"{element['id']}.frame.{axis}") for axis in AXES}


def _line_count(element: dict[str, Any]) -> int | None:
    if element.get("lines") is not None:
        lines = element["lines"]
        if not isinstance(lines, list) or any(not isinstance(line, str) for line in lines):
            raise InputError(f"{element['id']}.lines: expected a list of strings or null")
        return len(lines)
    raw = element.get("lineCount")
    if raw is None:
        return None
    if isinstance(raw, bool) or not isinstance(raw, int) or raw < 0:
        raise InputError(f"{element['id']}.lineCount: expected a non-negative integer or null")
    return raw


def _wrap_points(element: dict[str, Any]) -> list[int] | None:
    raw = element.get("wrapPoints")
    if raw is None:
        return None
    if not isinstance(raw, list) or any(isinstance(value, bool) or not isinstance(value, int) for value in raw):
        raise InputError(f"{element['id']}.wrapPoints: expected a list of integers or null")
    return raw


def compare(
    android: dict[str, Any],
    ios: dict[str, Any],
    default_tolerance: float = DEFAULT_TOLERANCE_PT,
) -> dict[str, Any]:
    """Compare two exports and return the report object (also used by tests)."""
    if default_tolerance < 0:
        raise InputError("default tolerance must be >= 0")
    if android["fixture"] != ios["fixture"]:
        raise InputError(
            f"fixture mismatch: android={android['fixture']!r} ios={ios['fixture']!r}"
        )
    if android["unit"] != ios["unit"]:
        raise InputError(f"unit mismatch: android={android['unit']!r} ios={ios['unit']!r}")
    if android.get("origin") != ios.get("origin"):
        raise InputError(
            f"origin mismatch: android={android.get('origin')!r} ios={ios.get('origin')!r}"
        )
    if not android.get("origin"):
        raise InputError("both exports must name the fixture origin")
    if android.get("originMissing") or ios.get("originMissing"):
        raise InputError(
            "origin element was not found: "
            f"android={android.get('originMissing')!r} ios={ios.get('originMissing')!r}"
        )

    android_by_id = {element["id"]: element for element in android["elements"]}
    ios_by_id = {element["id"]: element for element in ios["elements"]}
    ordered_ids = [element["id"] for element in android["elements"]]
    ordered_ids += [element["id"] for element in ios["elements"] if element["id"] not in android_by_id]

    results: list[dict[str, Any]] = []
    failures: list[str] = []
    warnings: list[str] = []
    for element_id in ordered_ids:
        left = android_by_id.get(element_id)
        right = ios_by_id.get(element_id)
        base = {
            "id": element_id,
            "status": "PASS",
            "failures": [],
            "warnings": [],
        }
        if left is None or right is None:
            missing_on = "android" if left is None else "ios"
            base["status"] = "FAIL"
            base["failures"].append(f"missing on {missing_on}")
            failures.append(f"{element_id}: missing on {missing_on}")
            results.append(base)
            continue

        base["androidIdentity"] = left.get("identity")
        base["iosIdentity"] = right.get("identity")
        base["android"] = left.get("frame")
        base["ios"] = right.get("frame")
        base["absoluteAndroid"] = left.get("absoluteFrame")
        base["absoluteIos"] = right.get("absoluteFrame")
        base["tolerance"] = _tolerance_for(left, default_tolerance)
        base["gatedAxes"] = _gated_axes(left)
        base["skippedAxes"] = [axis for axis in AXES if axis not in base["gatedAxes"]]
        base["exemption"] = left.get("exemption") or right.get("exemption")
        if _gated_axes(right) != base["gatedAxes"]:
            message = f"{element_id}: gatedAxes differs between exports"
            base["failures"].append(message)
            failures.append(message)
        if right.get("tolerance", default_tolerance) != left.get("tolerance", default_tolerance):
            message = f"{element_id}: tolerance differs between exports"
            base["failures"].append(message)
            failures.append(message)
        if left.get("found") is False or right.get("found") is False:
            message = f"{element_id}: exporter marked the element not found"
            base["failures"].append(message)
            failures.append(message)

        left_frame = _frame(left)
        right_frame = _frame(right)
        if left_frame is None or right_frame is None:
            message = f"{element_id}: frame missing from an export"
            base["failures"].append(message)
            failures.append(message)
        else:
            delta = {axis: round(left_frame[axis] - right_frame[axis], 6) for axis in AXES}
            base["delta"] = delta
            for axis in AXES:
                if axis not in base["gatedAxes"]:
                    continue
                tolerance = base["tolerance"][axis]
                if abs(delta[axis]) > tolerance + 1e-9:
                    message = (
                        f"{element_id}: Δ{axis}={delta[axis]:+.3f} pt "
                        f"exceeds tolerance {tolerance:g} pt"
                    )
                    base["failures"].append(message)
                    failures.append(message)

        left_identity = left.get("identity")
        right_identity = right.get("identity")
        if left_identity != right_identity:
            base["warnings"].append(
                f"identity differs: android={left_identity!r} ios={right_identity!r}"
            )
            warnings.append(f"{element_id}: identity {left_identity!r} vs {right_identity!r}")

        left_text = left.get("text")
        right_text = right.get("text")
        base["androidText"] = left_text
        base["iosText"] = right_text
        if isinstance(left_text, str) and isinstance(right_text, str):
            base["textMatch"] = left_text == right_text
            if left_text != right_text:
                base["warnings"].append("text differs (copy is not gated by this bench)")
                warnings.append(f"{element_id}: text differs")
        else:
            base["textMatch"] = None

        left_lines = _line_count(left)
        right_lines = _line_count(right)
        base["androidLineCount"] = left_lines
        base["iosLineCount"] = right_lines
        if left_lines is not None and right_lines is not None:
            base["linesMatch"] = left_lines == right_lines
            if left_lines != right_lines:
                message = f"{element_id}: line count {left_lines} vs {right_lines}"
                base["failures"].append(message)
                failures.append(message)
        else:
            base["linesMatch"] = None
            exposed_on = "android" if left_lines is not None else "ios"
            if left_lines is not None or right_lines is not None:
                base["warnings"].append(f"line count exposed only on {exposed_on}")
                warnings.append(f"{element_id}: line count only on {exposed_on}")

        left_wrap = _wrap_points(left)
        right_wrap = _wrap_points(right)
        base["androidWrapPoints"] = left_wrap
        base["iosWrapPoints"] = right_wrap
        if left_wrap is not None and right_wrap is not None:
            base["wrapPointsMatch"] = left_wrap == right_wrap
            if left_wrap != right_wrap:
                message = f"{element_id}: wrap points {left_wrap} vs {right_wrap}"
                base["failures"].append(message)
                failures.append(message)
        else:
            base["wrapPointsMatch"] = None

        if base["failures"]:
            base["status"] = "FAIL"
        results.append(base)

    status = "PASS" if not failures else "FAIL"
    return {
        "schema": REPORT_SCHEMA,
        "fixture": android["fixture"],
        "status": status,
        "unit": android["unit"],
        "origin": android.get("origin"),
        "defaultTolerancePt": default_tolerance,
        "android": {
            "platform": android["platform"],
            "generatedAt": android.get("generatedAt"),
            "frame": android.get("frame"),
            "source": android.get("source"),
        },
        "ios": {
            "platform": ios["platform"],
            "generatedAt": ios.get("generatedAt"),
            "frame": ios.get("frame"),
            "source": ios.get("source"),
        },
        "elements": results,
        "failures": failures,
        "warnings": warnings,
    }


def _fmt(value: Any, digits: int = 1) -> str:
    if value is None:
        return "—"
    if isinstance(value, (int, float)):
        return f"{value:.{digits}f}"
    return str(value)


def render_markdown(report: dict[str, Any]) -> str:
    lines = [
        f"# Parity geometry — `{report['fixture']}`",
        "",
        f"**Status: {report['status']}**",
        "",
        "| field | Android | iOS |",
        "|---|---|---|",
        f"| platform | {report['android']['platform']} | {report['ios']['platform']} |",
        f"| generated | {report['android'].get('generatedAt') or '—'} | "
        f"{report['ios'].get('generatedAt') or '—'} |",
        f"| frame (pt) | {report['android'].get('frame') or '—'} | "
        f"{report['ios'].get('frame') or '—'} |",
        f"| origin | `{report['origin']}` | `{report['origin']}` |",
        f"| unit | {report['unit']} | {report['unit']} |",
        "",
        "Frames are in the fixture's origin coordinate space. The origin element is "
        "at `(0, 0)` on both sides; absolute window frames stay in the JSON export "
        "but are not gated, because the spec §5 `insets` whitelist allows the "
        "system bars to differ.",
        "",
        "## Elements",
        "",
        "| id | status | Δx | Δy | Δw | Δh | tol (pt) | lines A/I | wrap A/I | identity A/I |",
        "|---|---|---:|---:|---:|---:|---:|---|---|---|",
    ]
    for element in report["elements"]:
        delta = element.get("delta") or {}
        tolerance = element.get("tolerance") or {}
        tolerance_text = "/".join(
            f"{tolerance.get(axis, 0):g}" if axis in (element.get("gatedAxes") or AXES) else "—"
            for axis in AXES
        )
        lines_text = f"{_fmt(element.get('androidLineCount'))}/{_fmt(element.get('iosLineCount'))}"
        wrap_text = (
            f"{element.get('androidWrapPoints')}/{element.get('iosWrapPoints')}"
            if element.get("androidWrapPoints") is not None or element.get("iosWrapPoints") is not None
            else "—"
        )
        identity_text = f"{element.get('androidIdentity')}/{element.get('iosIdentity')}"
        skipped = element.get("skippedAxes") or []
        if skipped:
            identity_text += " · not gated: " + ",".join(skipped)
            if element.get("exemption"):
                identity_text += " (" + str(element["exemption"]) + ")"
        lines.append(
            "| `{id}` | {status} | {dx} | {dy} | {dw} | {dh} | {tol} | {lines} | {wrap} | {identity} |".format(
                id=element["id"],
                status=element["status"],
                dx=_fmt(delta.get("x")),
                dy=_fmt(delta.get("y")),
                dw=_fmt(delta.get("w")),
                dh=_fmt(delta.get("h")),
                tol=tolerance_text,
                lines=lines_text,
                wrap=wrap_text,
                identity=identity_text,
            )
        )

    lines += ["", "## Failures", ""]
    if report["failures"]:
        lines += [f"- {failure}" for failure in report["failures"]]
    else:
        lines.append("None.")
    lines += ["", "## Warnings", ""]
    if report["warnings"]:
        lines += [f"- {warning}" for warning in report["warnings"]]
    else:
        lines.append("None.")
    lines += [
        "",
        "## What this does not prove",
        "",
        "It does not prove pixels, colour, glyph rasterisation, animation, or "
        "interaction timing. Line counts and wrap points are compared only where "
        "both platforms expose a text layout; a side that exposes none is reported "
        "as `null`, never guessed from a frame height.",
        "",
        f"Default tolerance: {report['defaultTolerancePt']:g} pt. "
        "Per-element tolerances come from the fixture.",
        "",
    ]
    return "\n".join(lines)


def write_reports(report: dict[str, Any], out_dir: Path, stem: str | None = None) -> tuple[Path, Path]:
    out_dir.mkdir(parents=True, exist_ok=True)
    stem = stem or report["fixture"]
    markdown_path = out_dir / f"{stem}.md"
    json_path = out_dir / f"{stem}.json"
    markdown_path.write_text(render_markdown(report), encoding="utf-8")
    json_path.write_text(
        json.dumps(report, ensure_ascii=False, indent=2, sort_keys=False) + "\n",
        encoding="utf-8",
    )
    return markdown_path, json_path


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--android", type=Path, required=True, help="Android export JSON")
    parser.add_argument("--ios", type=Path, required=True, help="iOS export JSON")
    parser.add_argument(
        "--out-dir",
        type=Path,
        default=Path("build/parity/reports"),
        help="directory for the Markdown and JSON reports",
    )
    parser.add_argument(
        "--tolerance",
        type=float,
        default=DEFAULT_TOLERANCE_PT,
        help="default per-axis tolerance in pt (fixtures may override per element)",
    )
    parser.add_argument("--stem", help="output file stem (default: fixture id)")
    parser.add_argument("--quiet", action="store_true", help="print only the summary")
    arguments = parser.parse_args(argv)

    try:
        android = load_export(arguments.android)
        ios = load_export(arguments.ios)
        report = compare(android, ios, default_tolerance=arguments.tolerance)
    except InputError as error:
        print(f"compare_geometry: {error}", file=sys.stderr)
        return 2
    if not report["android"].get("generatedAt"):
        report["android"]["generatedAt"] = _datetime.datetime.now().astimezone().isoformat(
            timespec="seconds"
        )
    markdown_path, json_path = write_reports(report, arguments.out_dir, arguments.stem)
    if not arguments.quiet:
        print(render_markdown(report))
    print(
        f"{report['fixture']}: {report['status']} — "
        f"{sum(1 for element in report['elements'] if element['status'] == 'PASS')}"
        f"/{len(report['elements'])} elements pass; "
        f"{len(report['failures'])} failure(s), {len(report['warnings'])} warning(s)",
        file=sys.stderr,
    )
    print(f"markdown: {markdown_path}")
    print(f"json:     {json_path}")
    return 0 if report["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
