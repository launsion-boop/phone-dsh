#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Lay the iOS baseline and the Android parity capture of the same state side by side.

What it does, precisely:

  * pairs the PNGs through the parity registry's own join key (`iosFile` ->
    `androidName`), never by guessing from the file name;
  * scales both sides by ONE factor, so their heights stay comparable, and
    top-aligns them;
  * draws a frame-pixel ruler next to the pair, a per-side size caption, and the
    height difference (Δ) between the two frames;
  * writes one `<state>__ios-left.png` per paired state plus the `metrics.txt`
    index.

What it deliberately does NOT do:

  * no pixel diff and no difference mask. CoreText and Android's Minikin/HarfBuzz
    rasterise glyphs differently, so a raw diff is dominated by font rendering,
    not by layout: it would be a fake signal;
  * no structural-block boxes. The capture harness records the frame and font
    metrics only; it records no layout tree and no element geometry. Drawing
    "missing block" boxes from ink heuristics would be a guess, so the sheet
    does not pretend to know one. The ruler is frame geometry, not element
    geometry.

Requires `sips` (system, used for the resample) and Pillow (used for the canvas:
`sips` can resize and pad but cannot concatenate two PNGs). Pillow is optional in
the baseline comparator; this receipt generator needs it and says so instead of
silently producing a caption-less composite.

Usage:
    python3 android/tools/ui-parity-sheet.py
    python3 android/tools/ui-parity-sheet.py --out <dir> --panel-height 900
    python3 android/tools/ui-parity-sheet.py --state page-chat-default
"""

from __future__ import annotations

import argparse
import datetime
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_OUT = ROOT / "docs/receipts/ui-parity-sheet"
DEFAULT_REGISTRY = ROOT / "android/lib/src/test/resources/screenshots/ios-parity/parity-registry.txt"
DEFAULT_IOS_DIR = ROOT / "docs/receipts/ios-baseline-screens"
DEFAULT_ANDROID_DIR = ROOT / "android/lib/src/test/resources/screenshots/ios-parity"
# Captures the Compose harness cannot take: `env-home` is an `adb screencap` of
# the launcher (a device surface, not a page), so it lives beside the sheets
# rather than in the page baseline directory.
DEFAULT_ANDROID_EXTRA_DIR = ROOT / "docs/receipts/ui-parity-sheet/adb"

IOS_FRAME_PT = (402, 874)
IOS_FRAME_DPR = 3

FONT_CANDIDATES = (
    ("/System/Library/Fonts/SFNS.ttf", 0),
    ("/System/Library/Fonts/Helvetica.ttc", 0),
    ("/System/Library/Fonts/Supplemental/Arial.ttf", 0),
    ("/Library/Fonts/Arial.ttf", 0),
)
MONO_CANDIDATES = (
    ("/System/Library/Fonts/SFNSMono.ttf", 0),
    ("/System/Library/Fonts/Menlo.ttc", 0),
    ("/System/Library/Fonts/Supplemental/Courier New.ttf", 0),
)


def die(message: str):
    raise SystemExit(f"ui-parity-sheet: {message}")


# --------------------------------------------------------------------- inputs


def read_registry(path: Path) -> list[dict[str, str]]:
    """Parse the pulled registry: `category|androidName|iosFile|status|owner|screen|note`."""
    if not path.is_file():
        die(f"missing registry: {path}")
    rows = []
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        if not line.strip():
            continue
        fields = line.split("|")
        if len(fields) != 7:
            die(f"{path}:{number}: expected 7 pipe-separated fields, got {len(fields)}")
        rows.append(
            dict(
                zip(
                    ("category", "android", "ios", "status", "owner", "screen", "note"),
                    fields,
                )
            )
        )
    if not rows:
        die(f"{path}: the registry is empty")
    return rows


def sips_size(path: Path) -> tuple[int, int]:
    """Read pixelWidth/pixelHeight with sips; the size has to come from the file."""
    result = subprocess.run(
        ["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(path)],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        die(f"sips cannot read {path}: {result.stderr.strip()}")
    width = re.search(r"pixelWidth:\s*(\d+)", result.stdout)
    height = re.search(r"pixelHeight:\s*(\d+)", result.stdout)
    if width is None or height is None:
        die(f"sips returned no size for {path}: {result.stdout!r}")
    return int(width.group(1)), int(height.group(1))


def sips_resample(src: Path, dst: Path, width: int, height: int) -> None:
    """Resample to exactly width x height; the caller keeps the aspect ratio."""
    result = subprocess.run(
        ["sips", "-z", str(height), str(width), str(src), "--out", str(dst)],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0 or not dst.is_file():
        die(f"sips could not resample {src} -> {dst}: {result.stderr.strip()}")


def load_font(size: int, mono: bool = False):
    from PIL import ImageFont

    for path, index in MONO_CANDIDATES if mono else FONT_CANDIDATES:
        try:
            return ImageFont.truetype(path, size, index=index)
        except OSError:
            continue
    return ImageFont.load_default()


# --------------------------------------------------------------------- canvas


INK = (17, 17, 17)
MUTED = (102, 102, 102)
RULE = (208, 208, 208)
WARN = (179, 38, 30)
PANEL_BG = (255, 255, 255)

MARGIN = 22
RULER_WIDTH = 56
RULER_GAP = 10
PANEL_GAP = 18
HEADER_HEIGHT = 92
FOOTER_HEIGHT = 64


def dashed_line(draw, start: tuple[int, int], end: tuple[int, int], fill, dash: int = 6) -> None:
    """A dashed horizontal line, used only for a non-zero frame-height delta."""
    x0, y = start
    x1, _ = end
    x = x0
    while x < x1:
        draw.line([(x, y), (min(x + dash, x1), y)], fill=fill, width=1)
        x += dash * 2


def render_pair(
    state: str,
    ios_png: Path,
    android_png: Path,
    ios_size: tuple[int, int],
    android_size: tuple[int, int],
    panel_height: int,
    work: Path,
    destination_dir: Path,
    source: str = "device",
) -> Path:
    from PIL import Image, ImageDraw

    (ios_w, ios_h), (android_w, android_h) = ios_size, android_size
    # ONE scale for both sides: the pair has to stay comparable, and a differing
    # height has to remain visible instead of being normalised away.
    scale = panel_height / max(ios_h, android_h)
    ios_panel = (max(1, round(ios_w * scale)), max(1, round(ios_h * scale)))
    android_panel = (max(1, round(android_w * scale)), max(1, round(android_h * scale)))

    ios_small = work / f"{state}__ios.png"
    android_small = work / f"{state}__android.png"
    sips_resample(ios_png, ios_small, *ios_panel)
    sips_resample(android_png, android_small, *android_panel)

    canvas_width = (
        MARGIN + RULER_WIDTH + RULER_GAP + ios_panel[0] + PANEL_GAP + android_panel[0] + MARGIN
    )
    canvas_height = (
        MARGIN + HEADER_HEIGHT + max(ios_panel[1], android_panel[1]) + FOOTER_HEIGHT + MARGIN
    )
    canvas = Image.new("RGB", (canvas_width, canvas_height), PANEL_BG)
    draw = ImageDraw.Draw(canvas)

    title_font = load_font(23)
    label_font = load_font(13)
    small_font = load_font(12)
    delta_font = load_font(15)

    panel_x = MARGIN + RULER_WIDTH + RULER_GAP
    android_x = panel_x + ios_panel[0] + PANEL_GAP
    panel_y = MARGIN + HEADER_HEIGHT
    delta_height = ios_h - android_h
    delta_px = delta_height
    delta_pt = delta_height / IOS_FRAME_DPR

    # --- header -----------------------------------------------------------
    draw.text((MARGIN, MARGIN), state, font=title_font, fill=INK)
    delta_text = (
        f"frame height \u0394 {delta_px:+d} px" if delta_px else "frame height \u0394 0 px"
    )
    delta_width = draw.textlength(delta_text, font=delta_font)
    draw.text(
        (canvas_width - MARGIN - delta_width, MARGIN + 4),
        delta_text,
        font=delta_font,
        fill=INK if delta_px == 0 else WARN,
    )

    column_y = MARGIN + 34
    draw.text(
        (panel_x, column_y),
        f"iOS baseline \u00b7 {ios_png.name} \u00b7 {ios_w}\u00d7{ios_h} px",
        font=label_font,
        fill=INK,
    )
    draw.text(
        (android_x, column_y),
        f"Android capture \u00b7 {android_png.name} \u00b7 {android_w}\u00d7{android_h} px"
        + ("" if source == "device" else f" \u00b7 {source}"),
        font=label_font,
        fill=INK,
    )
    draw.text(
        (panel_x, column_y + 17),
        "left side of the pair \u2014 CoreText raster, iOS chrome",
        font=small_font,
        fill=MUTED,
    )
    draw.text(
        (android_x, column_y + 17),
        "right side of the pair \u2014 Minikin raster, Android chrome",
        font=small_font,
        fill=MUTED,
    )

    # --- frame-pixel ruler (source px, shared by both panels) --------------
    ruler_x = MARGIN + RULER_WIDTH
    draw.text((MARGIN, panel_y - 30), "frame px", font=small_font, fill=MUTED)
    source_height = max(ios_h, android_h)
    step = 100
    for value in range(0, source_height + 1, step):
        y = panel_y + round(value * scale)
        if y > canvas_height - MARGIN - FOOTER_HEIGHT:
            break
        long_tick = value % (step * 2) == 0
        draw.line(
            [(ruler_x - (10 if long_tick else 5), y), (ruler_x, y)],
            fill=RULE,
            width=1,
        )
        if long_tick:
            label = str(value)
            width = draw.textlength(label, font=small_font)
            draw.text(
                (ruler_x - 13 - width, y - 7),
                label,
                font=small_font,
                fill=MUTED,
            )

    # --- panels -----------------------------------------------------------
    canvas.paste(Image.open(ios_small).convert("RGB"), (panel_x, panel_y))
    canvas.paste(Image.open(android_small).convert("RGB"), (android_x, panel_y))
    draw.rectangle(
        [panel_x - 1, panel_y - 1, panel_x + ios_panel[0], panel_y + ios_panel[1]],
        outline=RULE,
        width=1,
    )
    draw.rectangle(
        [
            android_x - 1,
            panel_y - 1,
            android_x + android_panel[0],
            panel_y + android_panel[1],
        ],
        outline=RULE,
        width=1,
    )

    if delta_px:
        # Where the shorter frame ends, the taller one still has rows: mark that
        # band instead of silently cropping it away.
        shorter_bottom = panel_y + min(ios_panel[1], android_panel[1])
        dashed_line(draw, (panel_x, shorter_bottom), (canvas_width - MARGIN, shorter_bottom), WARN)
        label = f"\u0394 {abs(delta_px)} px ({abs(delta_pt):.1f} pt)"
        width = draw.textlength(label, font=small_font)
        draw.text(
            (canvas_width - MARGIN - width, shorter_bottom + 4),
            label,
            font=small_font,
            fill=WARN,
        )

    # --- footer -----------------------------------------------------------
    footer_y = panel_y + max(ios_panel[1], android_panel[1]) + 20
    draw.line([(MARGIN, footer_y - 8), (canvas_width - MARGIN, footer_y - 8)], fill=RULE, width=1)
    draw.text(
        (MARGIN, footer_y),
        f"uniform scale {scale:.3f}\u00d7  \u00b7  "
        f"shared frame {IOS_FRAME_PT[0]}\u00d7{IOS_FRAME_PT[1]} pt @ {IOS_FRAME_DPR}\u00d7  "
        "\u00b7  side-by-side only: no pixel diff, no cross-platform parity claim",
        font=label_font,
        fill=MUTED,
    )
    draw.text(
        (MARGIN, footer_y + 18),
        "ruler and \u0394 are frame geometry. No element geometry is recorded by the "
        "capture harness, so no structural-block boxes are drawn. See README.md.",
        font=small_font,
        fill=MUTED,
    )

    destination = destination_dir / f"{state}__ios-left.png"
    canvas.save(destination, optimize=True)
    return destination


# ----------------------------------------------------------------------- main

parser = argparse.ArgumentParser(
    description="Compose one iOS-left / Android-right sheet per captured parity state."
)
parser.add_argument("--out", type=Path, default=DEFAULT_OUT, help="output directory")
parser.add_argument("--registry", type=Path, default=DEFAULT_REGISTRY, help="pulled parity registry")
parser.add_argument("--ios-dir", type=Path, default=DEFAULT_IOS_DIR, help="iOS baseline PNGs")
parser.add_argument("--android-dir", type=Path, default=DEFAULT_ANDROID_DIR, help="Android parity PNGs")
parser.add_argument(
    "--android-extra-dir",
    type=Path,
    default=DEFAULT_ANDROID_EXTRA_DIR,
    help="hand-captured Android PNGs for states the Compose harness cannot take",
)
parser.add_argument(
    "--panel-height",
    type=int,
    default=1311,
    help="rendered height in px of the taller panel (default 1311 = 2622/2)",
)
parser.add_argument("--state", action="append", default=[], help="only these Android state names")
parser.add_argument(
    "--keep-work",
    action="store_true",
    help="keep the sips-resampled intermediates in a printed temp directory",
)
arguments = parser.parse_args()

if shutil.which("sips") is None:
    die("sips not found; this tool is macOS-only (and the Android baselines are not)")
try:
    import PIL  # noqa: F401
except ImportError:
    die(
        "Pillow is required for the canvas (it is already installed on this host; sips can "
        "resize but cannot concatenate two PNGs). Install with: python3 -m pip install --user pillow"
    )

out_dir = arguments.out if arguments.out.is_absolute() else (Path.cwd() / arguments.out)
out_dir.mkdir(parents=True, exist_ok=True)

registry_path = arguments.registry if arguments.registry.is_absolute() else Path.cwd() / arguments.registry
ios_dir = arguments.ios_dir if arguments.ios_dir.is_absolute() else Path.cwd() / arguments.ios_dir
android_dir = (
    arguments.android_dir if arguments.android_dir.is_absolute() else Path.cwd() / arguments.android_dir
)
android_extra_dir = (
    arguments.android_extra_dir
    if arguments.android_extra_dir.is_absolute()
    else Path.cwd() / arguments.android_extra_dir
)
rows = [row for row in read_registry(registry_path) if row["category"] == "parity"]
if not rows:
    die(f"{registry_path}: no parity rows")
selected = set(arguments.state)
if selected:
    unknown = selected - {row["android"] for row in rows}
    if unknown:
        die(f"--state names not in the registry: {sorted(unknown)}")

work = Path(tempfile.mkdtemp(prefix="ui-parity-sheet-"))
paired: list[dict[str, object]] = []
unpaired: list[dict[str, object]] = []
try:
    for row in rows:
        state = row["android"]
        ios_png = ios_dir / f"{row['ios']}.png"
        android_png = android_dir / f"{state}.png"
        source = "device"
        if not android_png.is_file():
            # A state whose capture cannot come from the Compose harness (the
            # environment proof is an `adb screencap` of the launcher, not a
            # page) may be pulled in from the hand-captured directory instead of
            # being left unpaired. The registry still calls it `pending`: nothing
            # about a launcher screenshot can be frozen into a page baseline.
            adb_png = android_extra_dir / f"{state}.png"
            if adb_png.is_file():
                android_png = adb_png
                source = "adb screencap"
        record = {
            "row": row,
            "state": state,
            "ios_png": ios_png,
            "android_png": android_png,
            "source": source,
        }
        if not ios_png.is_file():
            die(f"registry names an iOS file that does not exist: {ios_png}")
        if not android_png.is_file():
            unpaired.append({**record, "why": "no Android capture at this revision"})
            continue
        if selected and state not in selected:
            continue
        record["ios_size"] = sips_size(ios_png)
        record["android_size"] = sips_size(android_png)
        sheet = render_pair(
            state,
            ios_png,
            android_png,
            record["ios_size"],  # type: ignore[arg-type]
            record["android_size"],  # type: ignore[arg-type]
            arguments.panel_height,
            work,
            out_dir,
            source=source,
        )
        record["sheet"] = sheet
        paired.append(record)
        print(f"  {state:<28} {record['ios_size']} + {record['android_size']} -> {sheet.name}")
finally:
    if arguments.keep_work:
        print(f"  intermediates kept in {work}")
    else:
        shutil.rmtree(work, ignore_errors=True)

# ------------------------------------------------------------------- metrics

lines: list[str] = []
lines.append("# ui-parity-sheet metrics \u2014 the index of the side-by-side sheets.")
lines.append("#")
lines.append("# Generated by android/tools/ui-parity-sheet.py. One row per iOS baseline state,")
lines.append("# in registry order. `ios_px` is the iOS PNG, `android_px` the Android parity")
lines.append("# capture, `dw`/`dh` their difference in pixels (positive = iOS larger), `dh_pt`")
lines.append("# the same height difference in the shared 3x frame's points.")
lines.append("#")
lines.append("# `scale` is the ONE factor both sides of that sheet were resampled by, so the")
lines.append("# two panels stay comparable and a height difference stays visible.")
lines.append("# `paired=no` means this revision has no Android capture for the state, so no")
lines.append("# sheet exists for it \u2014 it is a visible gap, not a silent omission.")
lines.append("# `source=device` is a Compose harness capture in the parity baseline directory;")
lines.append("# `source=adb` is a hand `adb screencap` for a device surface the harness cannot")
lines.append("# reach (the launcher). A sheet's frame comparison is exact either way; what an")
lines.append("# `adb` sheet cannot claim is that Android's own capture drifted, because that")
lines.append("# capture is not part of the page regression gate.")
lines.append("#")
lines.append(f"# generated    {datetime.datetime.now().astimezone().isoformat(timespec='seconds')}")
lines.append(f"# registry     {registry_path.relative_to(ROOT) if registry_path.is_relative_to(ROOT) else registry_path}")
lines.append(f"# ios source   {ios_dir.relative_to(ROOT) if ios_dir.is_relative_to(ROOT) else ios_dir}")
lines.append(
    f"# android src  {android_dir.relative_to(ROOT) if android_dir.is_relative_to(ROOT) else android_dir}"
)
lines.append(f"# sheet dir    {out_dir.relative_to(ROOT) if out_dir.is_relative_to(ROOT) else out_dir}")
lines.append("#")
header = (
    f"{'state':<30} {'ios_px':<11} {'android_px':<11} {'dw':>4} {'dh':>5} {'dh_pt':>6} "
    f"{'scale':>6}  {'paired':<6} {'source':<7} sheet"
)
lines.append(header)
lines.append("-" * 118)
for record in paired:
    row = record["row"]
    ios_w, ios_h = record["ios_size"]  # type: ignore[misc]
    android_w, android_h = record["android_size"]  # type: ignore[misc]
    dh = ios_h - android_h
    scale = arguments.panel_height / max(ios_h, android_h)
    ios_text = f"{ios_w}x{ios_h}"
    android_text = f"{android_w}x{android_h}"
    lines.append(
        "%-30s %-11s %-11s %4d %5d %6.1f %6.3f  %-6s %-7s %s"
        % (
            record["state"],
            ios_text,
            android_text,
            ios_w - android_w,
            dh,
            dh / IOS_FRAME_DPR,
            scale,
            "yes",
            record["source"],
            Path(record["sheet"]).name,
        )
    )
for record in unpaired:
    row = record["row"]
    ios_w, ios_h = sips_size(record["ios_png"])  # type: ignore[arg-type]
    ios_text = f"{ios_w}x{ios_h}"
    lines.append(
        "%-30s %-11s %-11s %4s %5s %6s %6s  %-6s %-7s %s"
        % (record["state"], ios_text, "-", "-", "-", "-", "-", "no", "-", record["why"])
    )
lines.append("")
lines.append(
    f"# summary: {len(paired)} paired / {len(rows)} parity states; "
    f"{len(unpaired)} unpaired at this revision."
)
if unpaired:
    lines.append("# unpaired: " + ", ".join(str(record["state"]) for record in unpaired))
lines.append(
    "# out of scope: the 3 androidOnly states (page-device-connection, page-device-session,"
)
lines.append("# page-session-artifacts) have no iOS baseline, so there is nothing to lay them next to.")
lines.append(
    "# `env-home` stays `pending` in the registry: it is an `adb screencap` of the launcher,"
)
lines.append(
    "# not a Compose page, so it is paired from the adb directory and never frozen as a page baseline."
)
(out_dir / "metrics.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")

print(
    f"\n{len(paired)} sheet(s) in {out_dir}"
    f" ({len(unpaired)} parity state(s) unpaired at this revision)"
)
print(f"metrics: {out_dir / 'metrics.txt'}")
