#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Check the BotFish numeric-trajectory and asset goldens.

Golden reader pattern for spec/tools/cross_check.py: golden/*.json
(one entry can cover both trajectory.json and assets.json).

Usage:
    python3 spec/ui/v1/bot/fish/tools/check_fish.py --root .

What is checked (all failures are reported together, first 60 printed):

* the trajectory against `schema/fish-trajectory.schema.json` (a small, dependency-
  free JSON-Schema subset: object/array/property/required/additionalProperties/
  items/type/enum/const/oneOf/min/max/pattern);
* the frozen sources: the SHA-256 in `source.files` still matches the checkout,
  and every `source.anchors` `file:line` still contains its citation, so a moved
  or edited model fails instead of silently freezing a stale number;
* the frozen constants (crop/pivot/boost/head-slice/frame clock/tolerances);
* the clip table against `examples/probe-app/BotFish/atlas.json`, the sprite
  names against `expressive/atlas.json`, and the 15-colour LUT against the
  documented stop formula and the real hex table;
* every case/frame: the fixed schedule, parameter key set, pose quantisation
  (0.25 output px, 0.5/target scale, 0.1 degree roll, 1/64 alpha) and motion
  boost, all recomputed from the frame's own params;
* `trajectory.json#headSlice`: the standard 0.1 and lively 0.25 quanta, the
  levels under Swift half-away-from-zero rounding, and the displacement
  restored with the same quantum;
* the case inventory (97 cases, including 10 P0 states, the 4 one-shots, the
  15 colours x 4 hairstyles, 3 seeded replays);
* `golden/assets.json`: one SHA-256 per shipped file (33 PNG + 2 atlas JSON),
  PNG dimensions/bit depth/colour type, the runtime layer map, the expressive
  grid/rects, and the exact `atlas.json` `file`/`frames` exception set. The
  top-level atlas names 51 web pre-render files that are not shipped and are
  never opened by `BotFishRenderer`; they are frozen as an exact missing list,
  not silently ignored. Every asset the native runtime actually opens must
  exist;
* the licence anchor: SOURCES.md still names the upstream revision and states
  the artwork grant (currently iOS-only), which is why `fish.md` carries an
  asset-sharing PROPOSAL rather than an Android shipping rule.

Exit codes: 0 pass, 1 failure. The checker never writes to the tree.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
import struct
import sys
from pathlib import Path

LIFECYCLE = [
    "idle", "thinking", "streaming", "working", "sleeping", "alerting",
    "listening", "speaking", "happy", "sad", "surprised", "confused",
    "laughing", "love", "angry", "wink", "nod", "shrug", "celebrate", "poke",
    "waking", "waiting", "loading", "done", "standby", "spawning", "bouncing",
    "dancing", "waving", "shy", "smug", "crying", "sighing", "cheering",
    "bowing", "clapping", "stretching", "yawning", "kiss", "shaking-head",
    "high-five", "powering-down",
]
ATLAS_AUX = ["blink", "look", "gaze", "morph"]
COLORS = [
    "white", "brown", "red", "orange", "amber", "green", "teal", "blue",
    "purple", "magenta", "gray", "black", "silver", "peach", "sky",
]
COLOR_HEX = {
    "white": "#FFFFFF", "brown": "#9D6937", "red": "#E5484D",
    "orange": "#F76B15", "amber": "#FFB224", "green": "#14C16F",
    "teal": "#13B7A2", "blue": "#1680F3", "purple": "#8F59F9",
    "magenta": "#F93498", "gray": "#8B8B8B", "black": "#1C1C1C",
    "silver": "#C9CBD1", "peach": "#F3B6A4", "sky": "#7ED0E8",
}
HAIRSTYLES = ["long", "twin-tail", "bob", "side-braid"]
WORK_STYLES = ["generic", "reading", "searching", "running", "writing"]
EYE_NAMES = [
    "laughing", "focused", "surprised", "sad", "love", "confused",
    "angry", "sleepy", "wink", "excited", "deadpan", "shy",
]
MOUTH_NAMES = [
    "smile", "smile-open", "laugh", "shocked", "pout", "sad",
    "smug", "small-o", "vowel-a", "vowel-e", "kiss", "yawn",
]
ACTIONS = {
    "waving": 1600, "bowing": 2800, "clapping": 1200, "kiss": 2600,
    "cheering": 1600, "shy": 3200, "smug": 2600, "crying": 2400,
    "sighing": 3600, "shaking-head": 2400, "stretching": 4200,
    "yawning": 4800, "high-five": 2200, "nod": 2000, "celebrate": 1500,
    "dancing": 1800,
}
EXPRESSIONS = ["happy", "sad", "surprised", "confused", "laughing", "love",
               "angry", "wink"]
EXPRESSION_DURATION = 4000
PARAMS_KEYS = {
    "eyeL", "eyeR", "joy", "browL", "browR", "anger", "sorrow", "smile",
    "mouth", "mouthWidth", "round", "blush", "tears", "love", "gazeX",
    "gazeY", "roll", "y", "x", "sx", "sy", "alpha", "finL", "finR",
    "finWave", "decoration", "progress", "phase", "eyeArt", "mouthArt",
    "finFold", "hairSway", "earFlutter", "puff", "breath", "headX", "headY",
    "bodyX", "bodyY", "blink", "morphX", "morphY", "artMix", "eyeArtPrev",
    "mouthArtPrev", "motionScale", "gazeEmphasis", "dotLift", "dotScale",
    "dotStagger", "isLivelyMotion",
}
DECORATIONS = {
    "", "dots", "sleep", "alert", "listen", "spark", "question", "hearts",
    "anger", "confetti", "waiting", "loading", "check", "music",
}
GROUPS = ["p0", "sampling", "one-shot", "still-reduced", "appearance",
          "lively", "replay"]
EXPECTED_GROUP_ORDER = GROUPS

EXPECTED_GEOMETRY = {
    "designCanvas": 512,
    "pad": 24,
    "designScale": 0.453125,
    "crop": {"origin": [48, 30], "side": 416},
    "crownedCrop": {"origin": [32, 10], "side": 448},
    "pivot": {"normal": [0.5, 320 / 416], "crowned": [0.5, 340 / 448]},
    "motionBoost": {"smallSize": 40, "largeSize": 64, "factor": 2.2,
                    "maxTranslation": 20, "maxRoll": 9},
    "headSlicing": {"minimumSize": 40, "livelyMinimumSize": 24,
                    "quantum": 0.1, "livelyQuantum": 0.25},
    "ink": [33, 25, 45],
}
EXPECTED_FRAME_CLOCK = {
    "standardFps": 20,
    "standardSmallFps": 15,
    "standardSmallMaxSizePt": 40,
    "livelyFps": 30,
    "deltaClampMs": 100,
    "freezeSampleMs": 650,
    "blinkDurationMs": 260,
    "poseSpringOmega": 18.0,
    "poseTransitionMs": 320,
}
DEFAULT_DT = 1000.0 / 60.0
REQUIRED_SOURCE_FILES = {
    "examples/probe-app/PhoneDSHProbe/Bot/Fish/BotFishModel.swift",
    "examples/probe-app/PhoneDSHProbe/Bot/Fish/BotFishEngine.swift",
    "examples/probe-app/PhoneDSHProbe/Bot/Fish/BotFishRenderer.swift",
    "examples/probe-app/PhoneDSHProbe/Bot/Fish/BotFishAssets.swift",
    "examples/probe-app/PhoneDSHProbe/Bot/Fish/BotFishImageCache.swift",
    "examples/probe-app/PhoneDSHProbe/Bot/Fish/BotFishLivelyMotion.swift",
    "examples/probe-app/PhoneDSHProbe/Bot/Fish/BotFishMotionProfile.swift",
    "examples/probe-app/PhoneDSHProbe/Bot/Fish/BotFishView.swift",
    "Sources/PhoneDSHBot/Avatar/BotFishDirector.swift",
    "Sources/PhoneDSHBot/Avatar/BotFishReactions.swift",
    "Sources/PhoneDSHBot/Profile/BotFishAppearance.swift",
    "Sources/PhoneDSHBot/UI/BotUIProjection.swift",
    "examples/probe-app/BotFish/atlas.json",
    "examples/probe-app/BotFish/expressive/atlas.json",
    "examples/probe-app/BotFish/SOURCES.md",
    "spec/ui/v1/bot/fish/tools/trajectory_harness.swift",
    "spec/ui/v1/bot/fish/tools/generate_trajectory.py",
}
EXPECTED_CASES = set()
for _state in ["idle", "thinking", "streaming", "working", "sleeping",
               "alerting", "listening", "speaking", "happy", "sad"]:
    EXPECTED_CASES.add(f"p0-{_state}")
EXPECTED_CASES |= {
    "sample-idle-32", "sample-alerting-32", "sample-idle-crowned",
    "sample-alerting-crowned", "sample-standby",
    "one-shot-poke", "one-shot-celebrate-reaction",
    "one-shot-waving-reaction", "one-shot-bowing-reaction",
    "one-shot-happy-expression",
    "still-idle", "still-reaction-bowing", "reduced-thinking",
    "reduced-reaction-celebrate",
}
EXPECTED_CASES |= {f"appearance-{color}-{hair}"
                   for color in COLORS for hair in HAIRSTYLES}
EXPECTED_CASES |= {f"lively-working-{style}" for style in WORK_STYLES}
EXPECTED_CASES |= {f"lively-{state}" for state in
                   ["streaming", "speaking", "celebrate", "done"]}
EXPECTED_CASES |= {"lively-celebrate-after-clip"}
EXPECTED_CASES |= {
    "replay-standard-poke-celebrate", "replay-lively-idle-blink",
    "replay-lively-thinking-reading",
}
EXPECTED_ASSET_FILES = {
    "atlas.json", "expressive/atlas.json",
    "base/blush.png", "base/body.png", "base/eyes-open.png",
    "base/eyes-white.png", "base/face-mask.png", "base/fixed.png",
    "base/iris-left.png", "base/iris-right.png",
    "expressive/eyes.png", "expressive/mouths.png",
    "overlays/crown.png", "overlays/crown-crystal.png",
}
for _style in HAIRSTYLES:
    _plain = "base" if _style == "long" else f"hair/{_style}"
    for _name in ("body", "fixed", "face-mask"):
        EXPECTED_ASSET_FILES.add(f"{_plain}/{_name}.png")
        EXPECTED_ASSET_FILES.add(f"crowned/{_style}/{_name}.png")
if len(EXPECTED_ASSET_FILES) != 35:
    raise AssertionError(len(EXPECTED_ASSET_FILES))


class Report:
    def __init__(self) -> None:
        self.errors: list[tuple[str, str]] = []

    def error(self, path: str, message: str) -> None:
        self.errors.append((path, message))

    def require(self, condition: bool, path: str, message: str) -> bool:
        if not condition:
            self.error(path, message)
        return condition

    def __bool__(self) -> bool:
        return not self.errors


def type_ok(value, expected) -> bool:
    if isinstance(expected, list):
        return any(type_ok(value, item) for item in expected)
    if expected == "object":
        return isinstance(value, dict)
    if expected == "array":
        return isinstance(value, list)
    if expected == "string":
        return isinstance(value, str)
    if expected == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if expected == "number":
        return (isinstance(value, (int, float))
                and not isinstance(value, bool)
                and math.isfinite(value))
    if expected == "boolean":
        return isinstance(value, bool)
    if expected == "null":
        return value is None
    return True


def json_equal(left, right) -> bool:
    if isinstance(left, bool) or isinstance(right, bool):
        return left is right
    if isinstance(left, (int, float)) and isinstance(right, (int, float)):
        return math.isclose(left, right, rel_tol=0, abs_tol=1e-12)
    return left == right


def validate_schema(value, schema: dict, path: str, report: Report) -> int:
    """Validate a small JSON-Schema subset. Returns the error count added."""
    before = len(report.errors)
    if not isinstance(schema, dict):
        return 0
    if "oneOf" in schema:
        matches = 0
        for index, option in enumerate(schema["oneOf"]):
            scratch = Report()
            validate_schema(value, option, path, scratch)
            if not scratch.errors:
                matches += 1
        if matches != 1:
            report.error(path, f"oneOf matched {matches} branches (expected 1)")
        return len(report.errors) - before
    if "type" in schema and not type_ok(value, schema["type"]):
        report.error(path, f"expected type {schema['type']!r}, got "
                           f"{type(value).__name__}")
        return len(report.errors) - before
    if "const" in schema and not json_equal(value, schema["const"]):
        report.error(path, f"expected const {schema['const']!r}, got {value!r}")
    if "enum" in schema and not any(json_equal(value, item)
                                    for item in schema["enum"]):
        report.error(path, f"{value!r} is not one of {schema['enum']!r}")
    if isinstance(value, str):
        if "minLength" in schema and len(value) < schema["minLength"]:
            report.error(path, f"string shorter than {schema['minLength']}")
        if "pattern" in schema and not re.search(schema["pattern"], value):
            report.error(path, f"string does not match {schema['pattern']!r}")
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if "minimum" in schema and value < schema["minimum"]:
            report.error(path, f"{value} < minimum {schema['minimum']}")
        if "maximum" in schema and value > schema["maximum"]:
            report.error(path, f"{value} > maximum {schema['maximum']}")
        if "exclusiveMinimum" in schema and value <= schema["exclusiveMinimum"]:
            report.error(path, f"{value} <= exclusiveMinimum "
                               f"{schema['exclusiveMinimum']}")
    if isinstance(value, list):
        if "minItems" in schema and len(value) < schema["minItems"]:
            report.error(path, f"{len(value)} items < minItems "
                               f"{schema['minItems']}")
        if "maxItems" in schema and len(value) > schema["maxItems"]:
            report.error(path, f"{len(value)} items > maxItems "
                               f"{schema['maxItems']}")
        if "items" in schema:
            for index, item in enumerate(value):
                validate_schema(item, schema["items"], f"{path}[{index}]", report)
    if isinstance(value, dict):
        if "minProperties" in schema and len(value) < schema["minProperties"]:
            report.error(path, f"{len(value)} properties < minProperties "
                               f"{schema['minProperties']}")
        properties = schema.get("properties", {})
        for name in schema.get("required", []):
            if name not in value:
                report.error(path, f"missing required property {name!r}")
        extra = schema.get("additionalProperties", True)
        for name, item in value.items():
            if name in properties:
                validate_schema(item, properties[name],
                                f"{path}.{name}", report)
            elif extra is False:
                report.error(path, f"unexpected property {name!r}")
            elif isinstance(extra, dict):
                validate_schema(item, extra, f"{path}.{name}", report)
    return len(report.errors) - before


def load_json(path: Path, report: Report, label: str):
    if not path.is_file():
        report.error(label, f"missing file {path}")
        return None
    try:
        text = path.read_text(encoding="utf-8")
        return json.loads(
            text,
            parse_constant=lambda value: (_ for _ in ()).throw(
                ValueError(f"non-finite JSON constant {value}")))
    except (ValueError, UnicodeDecodeError) as error:
        report.error(label, f"invalid JSON: {error}")
        return None


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def png_header(path: Path):
    with path.open("rb") as handle:
        header = handle.read(33)
    if header[:8] != b"\x89PNG\r\n\x1a\n" or header[12:16] != b"IHDR":
        return None
    return struct.unpack(">IIBBBBB", header[16:29])


def close(value, expected, tolerance=1e-6) -> bool:
    return abs(float(value) - float(expected)) <= tolerance


def away_round(value: float) -> float:
    """Swift `Double.rounded()`: half away from zero (not banker's)."""
    return math.floor(value + 0.5) if value >= 0 else math.ceil(value - 0.5)


def clamp(value: float, low: float, high: float) -> float:
    return max(low, min(high, value))


def motion_boost(size: float) -> float:
    if size <= 40:
        return 2.2
    if size >= 64:
        return 1.0
    t = (size - 40) / (64 - 40)
    return 2.2 + (1 - 2.2) * t


def expected_pose(case: dict, frame: dict, geometry: dict) -> dict:
    params = frame["params"]
    size = float(case["viewport"]["sizePt"])
    scale = float(case["viewport"]["displayScale"])
    target = math.ceil(size * scale)
    crowned = bool(case["crowned"])
    crop_side = (geometry["crownedCrop"]["side"] if crowned
                 else geometry["crop"]["side"])
    pixel_scale = target / crop_side
    points_per_pixel = max(1.0, size) / target
    boost = 1.0 if params["isLivelyMotion"] else motion_boost(size)
    x, y, roll = params["x"], params["y"], params["roll"]
    if boost > 1:
        limit = geometry["motionBoost"]["maxTranslation"]
        x = clamp(x * boost, -limit, limit)
        y = clamp(y * boost, -limit, limit)
        roll = clamp(roll * boost, -geometry["motionBoost"]["maxRoll"],
                     geometry["motionBoost"]["maxRoll"])

    def offset(value: float) -> float:
        pixels = value * pixel_scale
        return (away_round(pixels / 0.25) * 0.25) * points_per_pixel

    quantum = 0.5 / target
    return {
        "offsetX": offset(x),
        "offsetY": offset(y),
        "roll": away_round(roll / 0.1) * 0.1,
        "scaleX": away_round((params["sx"] * params["morphX"]) / quantum) * quantum,
        "scaleY": away_round((params["sy"] * params["morphY"]) / quantum) * quantum,
    }


def expected_alpha(params: dict) -> float:
    return away_round(clamp(params["alpha"], 0.0, 1.0) * 64) / 64


def shade(rgb: list, amount: float, white: float = 0.0) -> list:
    result = []
    for channel in rgb:
        value = channel * amount
        result.append(int(away_round(value + (255 - value) * white)))
    return result


def lut_for(hex_value: str) -> tuple:
    raw = hex_value.lstrip("#")
    rgb = [int(raw[0:2], 16), int(raw[2:4], 16), int(raw[4:6], 16)]
    stops = [
        (0.0, [13.0, 15.0, 25.0]),
        (0.20, [float(v) for v in shade(rgb, 0.25)]),
        (0.48, [float(v) for v in shade(rgb, 0.52)]),
        (0.73, [float(v) for v in rgb]),
        (0.91, [float(v) for v in shade(rgb, 1.0, 0.36)]),
        (1.0, [float(v) for v in shade(rgb, 1.0, 0.73)]),
    ]
    lut = []
    for index in range(256):
        x = index / 255.0
        lower, upper = stops[0], stops[-1]
        for candidate in range(1, len(stops)):
            if x <= stops[candidate][0]:
                lower = stops[candidate - 1]
                upper = stops[candidate]
                break
        span = upper[0] - lower[0]
        t = 0.0 if span == 0 else (x - lower[0]) / span
        for channel in range(3):
            value = lower[1][channel] + (upper[1][channel] - lower[1][channel]) * t
            lut.append(max(0, min(255, int(away_round(value)))))
    return lut, shade(rgb, 0.22), list(rgb), shade(rgb, 1.0, 0.5)


def get_path(root: Path, rel: str) -> Path:
    return root / rel


def check_anchor(root: Path, anchor: dict, report: Report, path: str) -> None:
    rel = anchor.get("path")
    if not isinstance(rel, str):
        report.error(path, "anchor.path is not a string")
        return
    file_path = get_path(root, rel)
    if not file_path.is_file():
        report.error(path, f"anchor file does not exist: {rel}")
        return
    lines = file_path.read_text(encoding="utf-8").splitlines()
    number = anchor.get("line")
    if not isinstance(number, int) or not 1 <= number <= len(lines):
        report.error(path, f"anchor line {number} outside {rel} ({len(lines)} lines)")
        return
    needle = anchor.get("contains")
    if not isinstance(needle, str) or needle not in lines[number - 1]:
        report.error(path, f"{rel}:{number} no longer contains {needle!r}")


def check_source(root: Path, trajectory: dict, report: Report) -> None:
    source = trajectory.get("source", {})
    report.require(source.get("contractBase") == "e477497b",
                   "$.source.contractBase",
                   "contract base must stay e477497b")
    files = source.get("files", [])
    paths = set()
    for index, entry in enumerate(files):
        rel = entry.get("path")
        paths.add(rel)
        file_path = get_path(root, rel) if isinstance(rel, str) else None
        if file_path is None or not file_path.is_file():
            report.error(f"$.source.files[{index}]", f"missing source {rel}")
            continue
        if entry.get("bytes") != file_path.stat().st_size:
            report.error(f"$.source.files[{index}]",
                         f"byte size drifted for {rel}")
        if entry.get("sha256") != sha256_file(file_path):
            report.error(f"$.source.files[{index}]",
                         f"SHA-256 drifted for {rel}; regenerate the trajectory")
    missing = REQUIRED_SOURCE_FILES - paths
    if missing:
        report.error("$.source.files",
                     f"source manifest omits: {sorted(missing)}")

    for index, anchor in enumerate(trajectory.get("anchors", [])):
        check_anchor(root, anchor, report, f"$.anchors[{index}]")


def check_geometry(trajectory: dict, report: Report) -> None:
    geometry = trajectory.get("geometry", {})

    def compare(path: str, actual, expected) -> None:
        if isinstance(expected, dict):
            if not isinstance(actual, dict):
                report.error(path, "expected an object")
                return
            for key, value in expected.items():
                compare(f"{path}.{key}", actual.get(key), value)
            extra = set(actual) - set(expected)
            if extra:
                report.error(path, f"unexpected keys {sorted(extra)}")
        elif isinstance(expected, list):
            if not isinstance(actual, list) or len(actual) != len(expected):
                report.error(path, f"expected {expected!r}, got {actual!r}")
                return
            for index, value in enumerate(expected):
                compare(f"{path}[{index}]", actual[index], value)
        elif isinstance(expected, (int, float)) and not isinstance(expected, bool):
            if not isinstance(actual, (int, float)) or not close(actual, expected):
                report.error(path, f"expected {expected!r}, got {actual!r}")
        elif actual != expected:
            report.error(path, f"expected {expected!r}, got {actual!r}")

    compare("$.geometry", geometry, EXPECTED_GEOMETRY)


def check_head_slice(trajectory: dict, report: Report) -> None:
    """FISH-1: both the quantiser and the restore use the active profile's
    quantum. Recompute every level and displacement from the raw inputs."""
    section = trajectory.get("headSlice")
    if not isinstance(section, dict):
        report.error("$.headSlice", "missing head-slice vectors")
        return
    geometry = trajectory.get("geometry", {}).get("headSlicing", {})
    profile_expected = {
        "standard": geometry.get("quantum"),
        "lively": geometry.get("livelyQuantum"),
    }
    profiles = section.get("profiles")
    if not isinstance(profiles, dict):
        report.error("$.headSlice.profiles", "missing profiles")
        return
    for name, expected in profile_expected.items():
        entry = profiles.get(name)
        if not isinstance(entry, dict):
            report.error(f"$.headSlice.profiles.{name}", "missing profile")
            continue
        quantum = entry.get("quantum")
        if not isinstance(expected, (int, float)) or \
                not isinstance(quantum, (int, float)) or \
                isinstance(quantum, bool) or not close(quantum, expected):
            report.error(f"$.headSlice.profiles.{name}.quantum",
                         f"expected {expected!r}, got {quantum!r}")
    extra = set(profiles) - set(profile_expected)
    if extra:
        report.error("$.headSlice.profiles", f"unexpected profiles {sorted(extra)}")

    cases = section.get("cases")
    if not isinstance(cases, list):
        report.error("$.headSlice.cases", "must be an array")
        return
    if len(cases) < 4:
        report.error("$.headSlice.cases", "need at least four slice cases")
    seen = set()
    seen_profiles = set()
    raw_inputs = {"standard": set(), "lively": set()}
    for index, case in enumerate(cases):
        path = f"$.headSlice.cases[{index}]"
        cid = case.get("id")
        if not isinstance(cid, str) or not cid or cid in seen:
            report.error(f"{path}.id", "must be a unique non-empty string")
        else:
            seen.add(cid)
        profile = case.get("profile")
        if profile not in profile_expected:
            report.error(f"{path}.profile", f"unknown profile {profile!r}")
            continue
        seen_profiles.add(profile)
        quantum = profile_expected[profile]
        if not isinstance(quantum, (int, float)) or quantum <= 0:
            report.error(f"{path}.quantum", "profile quantum is missing")
            continue
        actual_quantum = case.get("quantum")
        if not isinstance(actual_quantum, (int, float)) or \
                isinstance(actual_quantum, bool) or not close(actual_quantum, quantum):
            report.error(f"{path}.quantum",
                         f"must be the {profile} quantum {quantum!r}")
        raw = case.get("input")
        levels = case.get("levels")
        displacement = case.get("displacement")
        if not all(isinstance(value, dict) for value in (raw, levels, displacement)):
            report.error(path, "input/levels/displacement must be objects")
            continue
        keys = ("headX", "headY", "hairSway", "earFlutter")
        if set(raw) != set(keys) or set(levels) != set(keys) \
                or set(displacement) != set(keys):
            report.error(path, f"keys must be exactly {list(keys)!r}")
            continue
        raw_inputs[profile].add(tuple(raw[key] for key in keys))
        for key in keys:
            value = raw[key]
            if not isinstance(value, (int, float)) or isinstance(value, bool):
                report.error(f"{path}.input.{key}", "must be a number")
                continue
            expected_level = int(away_round(value / quantum))
            actual_level = levels[key]
            if not isinstance(actual_level, int) or isinstance(actual_level, bool):
                report.error(f"{path}.levels.{key}", "must be an integer")
                continue
            if actual_level != expected_level:
                report.error(f"{path}.levels.{key}",
                             f"expected {expected_level}, got {actual_level}")
            expected_displacement = expected_level * quantum
            if not close(displacement[key], expected_displacement, 1e-12):
                report.error(f"{path}.displacement.{key}",
                             f"expected {expected_displacement} with the "
                             f"{profile} quantum {quantum}, got "
                             f"{displacement[key]!r}")
    if seen_profiles != {"standard", "lively"}:
        report.error("$.headSlice.cases", "must cover both profiles")
    shared = raw_inputs["standard"] & raw_inputs["lively"]
    if not shared:
        report.error("$.headSlice.cases",
                     "one raw input must appear under both profiles so the "
                     "two quanta are compared")
    halves = 0
    for case in cases:
        profile = case.get("profile")
        quantum = profile_expected.get(profile)
        raw = case.get("input")
        if not isinstance(quantum, (int, float)) or not isinstance(raw, dict):
            continue
        for key in ("headX", "headY", "hairSway", "earFlutter"):
            value = raw.get(key)
            if isinstance(value, (int, float)) and not isinstance(value, bool):
                scaled = value / quantum
                if abs(abs(scaled - math.floor(scaled)) - 0.5) <= 1e-12:
                    halves += 1
    if halves == 0:
        report.error("$.headSlice.cases",
                     "must exercise Swift half-away-from-zero rounding")


def check_frame_clock(trajectory: dict, report: Report) -> None:
    clock = trajectory.get("frameClock", {})
    for key, expected in EXPECTED_FRAME_CLOCK.items():
        actual = clock.get(key)
        if isinstance(expected, float):
            if not isinstance(actual, (int, float)) or not close(actual, expected):
                report.error(f"$.frameClock.{key}",
                             f"expected {expected}, got {actual!r}")
        elif actual != expected:
            report.error(f"$.frameClock.{key}",
                         f"expected {expected}, got {actual!r}")
    extra = set(clock) - set(EXPECTED_FRAME_CLOCK)
    if extra:
        report.error("$.frameClock", f"unexpected keys {sorted(extra)}")
    tolerances = trajectory.get("tolerances", {})
    for key in ("params", "pose", "timeMs", "alpha"):
        if tolerances.get(key) != 1e-6:
            report.error(f"$.tolerances.{key}", "must be 1e-6")
    if not isinstance(tolerances.get("rationale"), str) or \
            len(tolerances["rationale"]) < 100:
        report.error("$.tolerances.rationale", "missing the tolerance rationale")


def check_clips(trajectory: dict, atlas: dict, report: Report) -> None:
    clips = trajectory.get("clips", {})
    if set(clips) != set(LIFECYCLE):
        report.error("$.clips", f"states must be exactly the 42 lifecycle cases; "
                               f"missing {sorted(set(LIFECYCLE) - set(clips))}, "
                               f"extra {sorted(set(clips) - set(LIFECYCLE))}")
    if len(clips) != 42:
        report.error("$.clips", f"expected 42 clips, got {len(clips)}")
    states = atlas.get("states", {})
    for state in LIFECYCLE:
        clip = clips.get(state)
        if not isinstance(clip, dict):
            continue
        period = clip.get("period")
        duration = clip.get("duration")
        is_static = clip.get("isStatic")
        entry = states.get(state, {})
        animation = entry.get("animation", {})
        if animation.get("implementation") != f"sample:{state}":
            report.error(f"$.clips.{state}",
                         f"atlas implementation is "
                         f"{animation.get('implementation')!r}")
        if period is not None:
            if animation.get("period") != period:
                report.error(f"$.clips.{state}.period",
                             f"atlas period {animation.get('period')!r} != {period!r}")
            if entry.get("loop") is not True:
                report.error(f"$.clips.{state}",
                             "a period clip must be loop=true in atlas.json")
            if duration is not None:
                report.error(f"$.clips.{state}",
                             "period and duration are mutually exclusive")
        elif "period" in animation:
            report.error(f"$.clips.{state}.period",
                         "atlas has a period but the clip does not")
        if duration is not None:
            if animation.get("duration") != duration:
                report.error(f"$.clips.{state}.duration",
                             f"atlas duration {animation.get('duration')!r} "
                             f"!= {duration!r}")
            if entry.get("loop") is not False:
                report.error(f"$.clips.{state}",
                             "a duration clip must be loop=false in atlas.json")
        elif "duration" in animation:
            report.error(f"$.clips.{state}.duration",
                         "atlas has a duration but the clip does not")
        if is_static is True:
            if animation.get("static") is not True:
                report.error(f"$.clips.{state}",
                             "static clip must be static=true in atlas.json")
            if period is not None or duration is not None:
                report.error(f"$.clips.{state}",
                             "a static clip cannot have period/duration")
        if period is None and duration is None and is_static is not True:
            report.error(f"$.clips.{state}",
                         "clip has neither period, duration nor static")
    aux = atlas.get("auxEntries", [])
    if aux != ATLAS_AUX:
        report.error("$.clips", f"atlas auxiliary entries changed: {aux!r}")
    for name, entry in states.items():
        if name in ATLAS_AUX:
            continue
        if name not in LIFECYCLE:
            report.error("$.clips", f"atlas has an unknown state {name!r}")
        _ = entry


def check_sprites(trajectory: dict, expressive: dict, report: Report) -> None:
    order = trajectory.get("spriteOrder", {})
    if order.get("eyes") != EYE_NAMES:
        report.error("$.spriteOrder.eyes", "must be the 12-cell eye order")
    if order.get("mouths") != MOUTH_NAMES:
        report.error("$.spriteOrder.mouths", "must be the 12-cell mouth order")
    if expressive.get("eyes") != EYE_NAMES:
        report.error("assets.expressive.eyes",
                     "expressive/atlas.json eyes disagree with the trajectory")
    if expressive.get("mouths") != MOUTH_NAMES:
        report.error("assets.expressive.mouths",
                     "expressive/atlas.json mouths disagree with the trajectory")


def check_palettes(trajectory: dict, report: Report) -> None:
    palettes = trajectory.get("palettes", [])
    ids = [entry.get("id") for entry in palettes]
    if ids != COLORS:
        report.error("$.palettes", f"expected the 15 colours in order, got {ids!r}")
    for index, entry in enumerate(palettes):
        path = f"$.palettes[{index}]"
        color = entry.get("id")
        expected_hex = COLOR_HEX.get(color)
        if expected_hex is None:
            report.error(path, f"unknown colour {color!r}")
            continue
        if entry.get("hex") != expected_hex:
            report.error(f"{path}.hex", f"expected {expected_hex}")
        expected_lut, ink, mid, light = lut_for(expected_hex)
        if entry.get("lut") != expected_lut:
            mismatch = next((i for i, (a, b) in enumerate(
                zip(entry.get("lut", []), expected_lut)) if a != b), None)
            report.error(f"{path}.lut",
                         f"LUT differs from the documented formula at index "
                         f"{mismatch}")
        for name, expected in (("ink", ink), ("mid", mid), ("light", light)):
            if entry.get(name) != expected:
                report.error(f"{path}.{name}",
                             f"expected {expected}, got {entry.get(name)!r}")


def lcg_prefix(seed: int, count: int) -> list:
    state = seed & 0xFFFF_FFFF
    values = []
    for _ in range(count):
        state = (1664525 * state + 1013904223) & 0xFFFF_FFFF
        values.append(state / 4294967296.0)
    return values


def check_reaction(case: dict, report: Report, path: str) -> None:
    reaction = case.get("reaction")
    dt = case.get("dtMs")
    if not isinstance(reaction, dict):
        if any("reactionActive" in frame for frame in case.get("frames", [])):
            report.error(path, "reactionActive is only valid with a reaction")
        return
    name = reaction.get("name")
    if name in ACTIONS:
        expected_kind, expected_duration = "action", ACTIONS[name]
    elif name in EXPRESSIONS:
        expected_kind, expected_duration = "expression", EXPRESSION_DURATION
    else:
        report.error(f"{path}.name", f"unknown reaction {name!r}")
        return
    if reaction.get("kind") != expected_kind:
        report.error(f"{path}.kind", f"expected {expected_kind}")
    if reaction.get("durationMs") != expected_duration:
        report.error(f"{path}.durationMs",
                     f"expected {expected_duration}, got "
                     f"{reaction.get('durationMs')!r}")
    start_step = reaction.get("startStep")
    if not isinstance(start_step, int) or start_step < 0:
        report.error(f"{path}.startStep", "must be a non-negative integer")
        return
    expected_start = 0.0 if start_step == 0 else (start_step - 1) * dt
    if not close(reaction.get("startTimeMs", -1), expected_start):
        report.error(f"{path}.startTimeMs",
                     "must equal the machine clock when configure applies the "
                     "event: 0 for step 0, (startStep - 1) * dtMs otherwise")
    for frame in case.get("frames", []):
        step = frame.get("step")
        active = (step >= start_step
                  and (frame.get("timeMs", 0) - reaction["startTimeMs"])
                  < expected_duration)
        if step < start_step:
            if "reactionActive" in frame:
                report.error(f"{path}.frames[{step}].reactionActive",
                             "must be absent before the reaction starts")
        elif frame.get("reactionActive") is not active:
            report.error(f"{path}.frames[{step}].reactionActive",
                         f"expected {active}")


def check_cases(trajectory: dict, report: Report) -> None:
    cases = trajectory.get("cases", [])
    names = [case.get("name") for case in cases]
    if len(names) != len(set(names)):
        report.error("$.cases", "case names are not unique")
    if set(names) != EXPECTED_CASES:
        missing = sorted(EXPECTED_CASES - set(names))
        extra = sorted(set(names) - EXPECTED_CASES)
        if missing:
            report.error("$.cases", f"missing cases: {missing}")
        if extra:
            report.error("$.cases", f"unexpected cases: {extra}")
    seen_groups = []
    for case in cases:
        group = case.get("group")
        if group not in EXPECTED_GROUP_ORDER:
            report.error(f"$.cases[{case.get('name')}].group",
                         f"unknown group {group!r}")
            continue
        if not seen_groups or seen_groups[-1] != group:
            if group in seen_groups:
                report.error(f"$.cases[{case.get('name')}].group",
                             "group blocks must not be interleaved")
            seen_groups.append(group)
    if seen_groups != EXPECTED_GROUP_ORDER:
        report.error("$.cases", f"group order {seen_groups!r} != "
                                f"{EXPECTED_GROUP_ORDER!r}")

    palette_colors = {entry.get("id") for entry in trajectory.get("palettes", [])}
    appearances = set()
    for case in cases:
        name = case.get("name")
        path = f"$.cases[{name}]"
        state = case.get("state")
        if state not in LIFECYCLE:
            report.error(path, f"unknown lifecycle {state!r}")
        appearance = case.get("appearance", {})
        color = appearance.get("color")
        hairstyle = appearance.get("hairstyle")
        if color not in COLORS:
            report.error(f"{path}.appearance.color", f"unknown colour {color!r}")
        if hairstyle not in HAIRSTYLES:
            report.error(f"{path}.appearance.hairstyle",
                         f"unknown hairstyle {hairstyle!r}")
        if color in palette_colors and hairstyle in HAIRSTYLES:
            appearances.add((color, hairstyle))
        viewport = case.get("viewport", {})
        size = viewport.get("sizePt")
        scale = viewport.get("displayScale")
        if not isinstance(size, (int, float)) or size < 1:
            report.error(f"{path}.viewport.sizePt", "must be >= 1")
        if not isinstance(scale, (int, float)) or scale < 1:
            report.error(f"{path}.viewport.displayScale", "must be >= 1")
        if isinstance(size, (int, float)) and isinstance(scale, (int, float)) \
                and viewport.get("pixelSide") != math.ceil(size * scale):
            report.error(f"{path}.viewport.pixelSide",
                         "must equal ceil(sizePt * displayScale)")
        if case.get("motionProfile") not in ("standard", "lively"):
            report.error(f"{path}.motionProfile", "unknown motion profile")
        if case.get("workStyle") not in WORK_STYLES:
            report.error(f"{path}.workStyle", "unknown work style")
        if not isinstance(case.get("seed"), int) or case.get("seed") < 1:
            report.error(f"{path}.seed", "must be a positive integer")
        if not close(case.get("dtMs", 0), DEFAULT_DT, 1e-9):
            report.error(f"{path}.dtMs", "the fixture grid is 1000/60 ms")
        steps = case.get("steps")
        if not isinstance(steps, int) or steps < 0:
            report.error(f"{path}.steps", "must be a non-negative integer")
            continue
        sample_steps = case.get("sampleSteps")
        if sample_steps is not None:
            if (not isinstance(sample_steps, list)
                    or sample_steps != sorted(set(sample_steps))
                    or any(not isinstance(step, int) or step < 0 or step > steps
                           for step in sample_steps)):
                report.error(f"{path}.sampleSteps",
                             "must be sorted unique step indices in [0, steps]")
                sample_steps = None
        random_values = case.get("randomValues")
        if isinstance(random_values, list) and isinstance(case.get("seed"), int):
            expected_random = lcg_prefix(case["seed"], len(random_values))
            if len(random_values) != len(expected_random) or any(
                    not close(a, b, 1e-12)
                    for a, b in zip(random_values, expected_random)):
                report.error(f"{path}.randomValues",
                             "must be the consumed LCG prefix of `seed`")
        if not isinstance(random_values, list) or not random_values:
            report.error(f"{path}.randomValues",
                         "every case records the consumed random values")
        frames = case.get("frames", [])
        expected_frame_count = (len(sample_steps) if sample_steps is not None
                                else steps + 1)
        if len(frames) != expected_frame_count:
            report.error(f"{path}.frames",
                         f"expected {expected_frame_count} frames, "
                         f"got {len(frames)}")
        expected_steps = (sample_steps if sample_steps is not None
                          else list(range(steps + 1)))
        previous_time = -1.0
        for index, frame in enumerate(frames):
            fpath = f"{path}.frames[{index}]"
            step = frame.get("step")
            if expected_steps is not None and index < len(expected_steps) \
                    and step != expected_steps[index]:
                report.error(f"{fpath}.step",
                             f"expected step {expected_steps[index]}, got {step}")
            expected_time = (step * case.get("dtMs", 0)
                             if isinstance(step, int) else None)
            if expected_time is not None and not close(
                    frame.get("timeMs", -1), expected_time, 1e-6):
                report.error(f"{fpath}.timeMs",
                             f"expected {expected_time}, got "
                             f"{frame.get('timeMs')!r}")
            if frame.get("timeMs", -1) < previous_time:
                report.error(f"{fpath}.timeMs", "timeMs is not monotonic")
            previous_time = frame.get("timeMs", -1)
            params = frame.get("params", {})
            if set(params) != PARAMS_KEYS:
                report.error(f"{fpath}.params",
                             f"parameter key set drifted; missing "
                             f"{sorted(PARAMS_KEYS - set(params))}, extra "
                             f"{sorted(set(params) - PARAMS_KEYS)}")
                continue
            for key, value in params.items():
                if key in ("decoration",):
                    if value not in DECORATIONS:
                        report.error(f"{fpath}.params.{key}",
                                     f"unknown decoration {value!r}")
                elif key in ("eyeArt", "mouthArt", "eyeArtPrev", "mouthArtPrev"):
                    allowed = EYE_NAMES if "eye" in key.lower() else MOUTH_NAMES
                    if value is not None and value not in allowed:
                        report.error(f"{fpath}.params.{key}",
                                     f"unknown sprite name {value!r}")
                elif key == "isLivelyMotion":
                    if not isinstance(value, bool):
                        report.error(f"{fpath}.params.{key}", "must be boolean")
                else:
                    if not isinstance(value, (int, float)) or not math.isfinite(value):
                        report.error(f"{fpath}.params.{key}",
                                     f"must be a finite number, got {value!r}")
            if params.get("motionScale") != 1.0:
                report.error(f"{fpath}.params.motionScale",
                             "the state machine's raw value is 1; the view "
                             "amplification is recorded in frame.view")
            view = frame.get("view", {})
            expected_boost = (1.0 if params.get("isLivelyMotion")
                              else motion_boost(size))
            if not close(view.get("motionScale", -1), expected_boost):
                report.error(f"{fpath}.view.motionScale",
                             f"expected {expected_boost}")
            if view.get("pixelSide") != viewport.get("pixelSide"):
                report.error(f"{fpath}.view.pixelSide",
                             "must equal the case pixelSide")
            pose = frame.get("pose", {})
            expected = expected_pose(case, frame, trajectory["geometry"])
            for key, value in expected.items():
                if not close(pose.get(key, 1e9), value):
                    report.error(f"{fpath}.pose.{key}",
                                 f"expected {value}, got {pose.get(key)!r} "
                                 "(pose/boost/quantum mismatch)")
            if not close(frame.get("alpha", -1), expected_alpha(params)):
                report.error(f"{fpath}.alpha",
                             f"expected {expected_alpha(params)}")
            if frame.get("static") is not (bool(case.get("still"))
                                           or bool(case.get("reduced"))):
                report.error(f"{fpath}.static",
                             "must equal still || reduced")
            if not isinstance(frame.get("needsAnimation"), bool):
                report.error(f"{fpath}.needsAnimation", "must be boolean")
        check_reaction(case, report, path)

    expected_appearances = {(color, hair) for color in COLORS
                            for hair in HAIRSTYLES}
    if appearances != expected_appearances:
        report.error("$.cases", "appearance coverage is not 15 colours x "
                                "4 hairstyles")
    replay = [case for case in cases if case.get("group") == "replay"]
    if len(replay) != 3:
        report.error("$.cases", f"expected 3 seeded replays, got {len(replay)}")
    for case in replay:
        if case.get("sampleSteps") is not None:
            report.error(f"$.cases[{case.get('name')}].sampleSteps",
                         "a replay records every step")
        frames = case.get("frames", [])
        if frames and not any(frame.get("needsAnimation") for frame in frames):
            report.error(f"$.cases[{case.get('name')}]",
                         "a replay must exercise the animation clock")


def check_assets(root: Path, assets: dict, trajectory: dict,
                 report: Report) -> None:
    asset_rel = assets.get("root")
    if asset_rel != "examples/probe-app/BotFish":
        report.error("$.root", f"expected examples/probe-app/BotFish, got "
                               f"{asset_rel!r}")
        return
    asset_root = get_path(root, asset_rel)
    files = assets.get("files", [])
    manifest = {}
    for index, entry in enumerate(files):
        rel = entry.get("path")
        path = f"$.files[{index}]"
        if not isinstance(rel, str):
            report.error(path, "path must be a string")
            continue
        manifest[rel] = entry
        file_path = asset_root / rel
        if not file_path.is_file():
            report.error(path, f"asset does not exist: {rel}")
            continue
        if entry.get("bytes") != file_path.stat().st_size:
            report.error(path, f"byte size drifted for {rel}")
        if entry.get("sha256") != sha256_file(file_path):
            report.error(path, f"SHA-256 drifted for {rel}")
        if rel.endswith(".png"):
            header = png_header(file_path)
            if header is None:
                report.error(path, f"not a PNG: {rel}")
                continue
            width, height, depth, color_type, compression, filter_, interlace = header
            expected_size = (768, 512) if rel.startswith("expressive/") else (512, 512)
            if (width, height) != expected_size:
                report.error(path, f"{rel} is {width}x{height}, expected "
                                   f"{expected_size}")
            if (depth, color_type, compression, filter_, interlace) != (8, 6, 0, 0, 0):
                report.error(path, f"{rel} must be 8-bit RGBA, non-interlaced")
    actual_files = {
        path.relative_to(asset_root).as_posix()
        for path in asset_root.rglob("*")
        if path.is_file() and path.name != "SOURCES.md"
    }
    if set(manifest) != actual_files:
        report.error("$.files",
                     f"manifest/actual mismatch; unmanifested "
                     f"{sorted(actual_files - set(manifest))}, missing "
                     f"{sorted(set(manifest) - actual_files)}")
    if set(manifest) != EXPECTED_ASSET_FILES:
        report.error("$.files", "asset inventory is not the frozen 35-file set")
    png_count = sum(1 for rel in manifest if rel.endswith(".png"))
    if png_count != 33:
        report.error("$.files", f"expected 33 PNGs, got {png_count}")

    layers = assets.get("runtimeLayers", {})
    runtime_paths = set(layers.get("shared", []))
    if not layers.get("shared"):
        report.error("$.runtimeLayers.shared", "empty")
    for style, entry in layers.get("hairstyles", {}).items():
        if style not in HAIRSTYLES:
            report.error("$.runtimeLayers.hairstyles",
                         f"unknown hairstyle {style!r}")
        runtime_paths.update(entry.get("plain", []))
        runtime_paths.update(entry.get("crowned", []))
    for rel in sorted(runtime_paths):
        if not (asset_root / rel).is_file():
            report.error("$.runtimeLayers", f"runtime layer is missing: {rel}")
    for rel in sorted(runtime_paths):
        if rel not in manifest:
            report.error("$.runtimeLayers", f"{rel} is not in files[]")

    expressive = assets.get("expressive", {})
    check_sprites(trajectory, expressive, report)
    grid = expressive.get("grid")
    cell = expressive.get("cell")
    if grid != [3, 4] or cell != [256, 128]:
        report.error("$.expressive", "grid/cell must stay 3x4 of 256x128")
    else:
        for kind in ("eyes", "mouths"):
            entries = expressive.get(f"{kind}Entries")
            if not isinstance(entries, list) or len(entries) != 12:
                report.error(f"$.expressive.{kind}Entries",
                             "must contain 12 cells")
                continue
            seen = set()
            for index, entry in enumerate(entries):
                name = entry.get("name")
                rect = entry.get("rect")
                if name != (EYE_NAMES if kind == "eyes" else MOUTH_NAMES)[index]:
                    report.error(f"$.expressive.{kind}Entries[{index}]",
                                 f"unexpected name {name!r}")
                if (not isinstance(rect, list) or len(rect) != 4
                        or rect[0] % 256 or rect[1] % 128
                        or rect[2:] != [256, 128]
                        or rect[0] + 256 > 768 or rect[1] + 128 > 512):
                    report.error(f"$.expressive.{kind}Entries[{index}]",
                                 f"invalid cell rect {rect!r}")
                if tuple(rect or []) in seen:
                    report.error(f"$.expressive.{kind}Entries[{index}]",
                                 "duplicate cell rect")
                seen.add(tuple(rect or []))

    atlas = assets.get("atlas", {})
    if atlas.get("stateCount") != 42:
        report.error("$.atlas.stateCount", "expected 42 lifecycle states")
    if atlas.get("auxEntries") != ATLAS_AUX:
        report.error("$.atlas.auxEntries", f"expected {ATLAS_AUX!r}")
    top_atlas = load_json(asset_root / "atlas.json", report, "atlas.json")
    if top_atlas is not None:
        expected_states = [name for name in top_atlas if name not in ATLAS_AUX]
        if sorted(expected_states) != sorted(LIFECYCLE):
            report.error("$.atlas.states",
                         "atlas states no longer equal BotFishLifecycle")
        referenced = set()
        for name, entry in top_atlas.items():
            if "file" in entry:
                referenced.add(entry["file"])
            for frame in entry.get("frames", []):
                referenced.add(frame)
        actual_missing = {rel for rel in referenced
                          if not (asset_root / rel).is_file()}
        actual_present = referenced - actual_missing
        if set(atlas.get("referencedFiles", [])) != referenced:
            report.error("$.atlas.referencedFiles",
                         "atlas file/frames references changed")
        if set(atlas.get("missingFiles", [])) != actual_missing:
            report.error("$.atlas.missingFiles",
                         "must be the exact set of atlas references absent "
                         "from the tree")
        if set(atlas.get("presentFiles", [])) != actual_present:
            report.error("$.atlas.presentFiles",
                         "must be the exact set of atlas references present")
        if len(atlas.get("missingFiles", [])) != 51:
            report.error("$.atlas.missingFiles",
                         f"expected the frozen 51 web pre-renders, got "
                         f"{len(atlas.get('missingFiles', []))}")
        if any(not (rel.startswith("expressions/")
                    or rel.startswith("anim/"))
               for rel in atlas.get("missingFiles", [])):
            report.error("$.atlas.missingFiles",
                         "only web pre-render expressions/anim paths may be absent")
        for name in ATLAS_AUX:
            entry = top_atlas.get(name)
            if not isinstance(entry, dict):
                report.error("$.atlas.states", f"atlas auxiliary {name} missing")
                continue
            implementation = entry.get("implementation") or \
                entry.get("animation", {}).get("implementation")
            if implementation != f"controller.{name}" and name != "blink":
                report.error("$.atlas.states", f"{name} implementation changed")
        if top_atlas.get("blink", {}).get("implementation") != "controller.blink":
            report.error("$.atlas.states", "blink implementation changed")

    provenance = assets.get("source", {})
    provenance_path = asset_root / "SOURCES.md"
    if not provenance_path.is_file():
        report.error("$.source.provenance", "SOURCES.md is missing")
    else:
        if provenance.get("provenanceSha256") != sha256_file(provenance_path):
            report.error("$.source.provenanceSha256", "SOURCES.md drifted")
    if provenance.get("upstream") != "launsion-boop/dsh-bot":
        report.error("$.source.upstream", "upstream repository changed")
    if provenance.get("revision") != "bf4075b0a2e8092b04b726c59a7b085d5a37e6f6":
        report.error("$.source.revision", "upstream revision changed")
    grant = provenance.get("grant", {})
    scope = grant.get("scope")
    if scope not in ("ios-only", "ios+android"):
        report.error("$.source.grant.scope", f"unknown scope {scope!r}")
    text = grant.get("text", "")
    if "iOS" not in text:
        report.error("$.source.grant.text", "SOURCES.md no longer states the grant")
    if (scope == "ios+android") != ("Android" in text):
        report.error("$.source.grant.scope",
                     "scope must agree with the SOURCES.md wording")
    if scope == "ios-only" and grant.get("androidGranted") is not False:
        report.error("$.source.grant.androidGranted",
                     "must be false while the grant names only iOS")
    if scope == "ios+android" and grant.get("androidGranted") is not True:
        report.error("$.source.grant.androidGranted",
                     "must be true while the grant names every platform")

    for index, anchor in enumerate(assets.get("anchors", [])):
        check_anchor(root, anchor, report, f"$.anchors[{index}]")


def check_doc(root: Path, report: Report) -> None:
    doc = root / "spec/ui/v1/bot/fish/fish.md"
    if not doc.is_file():
        report.error("fish.md", "missing the normative document")
        return
    text = doc.read_text(encoding="utf-8")
    required = [
        "python3 spec/ui/v1/bot/fish/tools/generate_trajectory.py --check",
        "1e-6",
        "PROPOSAL",
        "SOURCES.md",
        "Status: partial",
        "BotFishView(state: BotFishLifecycle",
        "### 7.4.1 Head-slice quantum (normative, FISH-1)",
        "trajectory.json#headSlice",
    ]
    for needle in required:
        if needle not in text:
            report.error("fish.md", f"missing required text {needle!r}")


def run(root: Path) -> Report:
    report = Report()
    fish = root / "spec/ui/v1/bot/fish"
    schema = load_json(fish / "schema/fish-trajectory.schema.json", report,
                       "schema")
    trajectory = load_json(fish / "golden/trajectory.json", report,
                           "trajectory")
    assets = load_json(fish / "golden/assets.json", report, "assets")
    if schema is not None and trajectory is not None:
        validate_schema(trajectory, schema, "$", report)
    if trajectory is not None:
        check_source(root, trajectory, report)
        check_geometry(trajectory, report)
        check_head_slice(trajectory, report)
        check_frame_clock(trajectory, report)
        atlas = None
        if assets is not None:
            atlas = assets.get("atlas")
            if trajectory.get("clips") is not None and atlas is not None:
                check_clips(trajectory, atlas, report)
            check_sprites(trajectory, assets.get("expressive", {}), report)
        check_palettes(trajectory, report)
        check_cases(trajectory, report)
    if assets is not None:
        if trajectory is not None:
            check_assets(root, assets, trajectory, report)
        else:
            check_assets(root, assets, {"spriteOrder": {}, "clips": {}}, report)
    check_doc(root, report)
    return report


def main(argv: list) -> int:
    parser = argparse.ArgumentParser(
        description="Validate the BotFish trajectory and asset goldens.")
    parser.add_argument("--root", type=Path,
                        default=Path(__file__).resolve().parents[6],
                        help="repository root (default: this checkout)")
    args = parser.parse_args(argv)
    root = args.root.resolve()
    report = run(root)
    for path, message in report.errors[:60]:
        print(f"{path}: {message}", file=sys.stderr)
    if len(report.errors) > 60:
        print(f"... {len(report.errors) - 60} more error(s)", file=sys.stderr)
    if report.errors:
        print(f"check_fish: FAIL ({len(report.errors)} error(s))", file=sys.stderr)
        return 1
    fish = root / "spec/ui/v1/bot/fish"
    trajectory = json.loads((fish / "golden/trajectory.json").read_text())
    assets = json.loads((fish / "golden/assets.json").read_text())
    frames = sum(len(case["frames"]) for case in trajectory["cases"])
    slices = len(trajectory.get("headSlice", {}).get("cases", []))
    print(f"check_fish: OK ({len(trajectory['cases'])} cases, {frames} frames, "
          f"{slices} head-slice cases, {len(assets['files'])} assets, "
          f"{len(trajectory['clips'])} clips, "
          f"{len(trajectory['palettes'])} palettes)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
