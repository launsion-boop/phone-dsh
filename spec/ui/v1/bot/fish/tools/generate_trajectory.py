#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Regenerate the BotFish numeric-trajectory golden from the real Swift model.

This script is the *only* supported way to produce
`spec/ui/v1/bot/fish/golden/trajectory.json` and
`spec/ui/v1/bot/fish/golden/assets.json`.

It does not re-implement the model. It builds a throw-away SwiftPM package in
the system temp directory whose executable target is a symlink farm:

    Sources/FishHarness/
        main.swift -> spec/ui/v1/bot/fish/tools/trajectory_harness.swift
        BotFishModel.swift -> examples/probe-app/PhoneDSHProbe/Bot/Fish/...
        ...

so the *original app files* are compiled (nothing is copied, moved or
modified), against the real `PhoneDSHBot` module from this checkout. The
executable is built for the iOS simulator (UIKit + Core Graphics are required
by the renderer), run with `xcrun simctl spawn`, and writes the numeric core.
This script then adds the source hashes, anchors, clock metadata and canonical
formatting, and writes the two goldens.

Usage:
    python3 spec/ui/v1/bot/fish/tools/generate_trajectory.py --check
    python3 spec/ui/v1/bot/fish/tools/generate_trajectory.py --write
    python3 spec/ui/v1/bot/fish/tools/generate_trajectory.py --core FILE --write

`--check` regenerates and diffs byte-for-byte; it fails on any difference.
On a host that cannot build/run the iOS simulator it exits 77 with SKIP (never
0), so a missing toolchain is never reported as PASS.
"""

from __future__ import annotations

import argparse
import difflib
import hashlib
import json
import os
import platform
import re
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[6]
FISH_DIR = REPO_ROOT / "spec/ui/v1/bot/fish"
TOOLS_DIR = FISH_DIR / "tools"
GOLDEN_DIR = FISH_DIR / "golden"
ASSET_ROOT_REL = "examples/probe-app/BotFish"
ASSET_ROOT = REPO_ROOT / ASSET_ROOT_REL
SWIFT_DIR_REL = "examples/probe-app/PhoneDSHProbe/Bot/Fish"
SWIFT_DIR = REPO_ROOT / SWIFT_DIR_REL

CONTRACT_BASE = "e477497b"
SCHEMA_VERSION = 1

APP_FILES = [
    "BotFishModel.swift",
    "BotFishEngine.swift",
    "BotFishRenderer.swift",
    "BotFishAssets.swift",
    "BotFishImageCache.swift",
    "BotFishLivelyMotion.swift",
    "BotFishMotionProfile.swift",
]
# BotFishView.swift is not compiled by the harness (it needs SwiftUI's
# environment), but it is the frozen source of the frame clock and pivot, so
# its hash anchors those numbers.
SOURCE_FILES = [f"{SWIFT_DIR_REL}/{name}" for name in APP_FILES] + [
    f"{SWIFT_DIR_REL}/BotFishView.swift",
    "Sources/PhoneDSHBot/Avatar/BotFishDirector.swift",
    "Sources/PhoneDSHBot/Avatar/BotFishReactions.swift",
    "Sources/PhoneDSHBot/Profile/BotFishAppearance.swift",
    "examples/probe-app/BotFish/atlas.json",
    "examples/probe-app/BotFish/expressive/atlas.json",
    "examples/probe-app/BotFish/SOURCES.md",
    "spec/ui/v1/bot/fish/tools/trajectory_harness.swift",
    "spec/ui/v1/bot/fish/tools/generate_trajectory.py",
]

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

PARAMS_KEYS = [
    "eyeL", "eyeR", "joy", "browL", "browR", "anger", "sorrow", "smile",
    "mouth", "mouthWidth", "round", "blush", "tears", "love", "gazeX",
    "gazeY", "roll", "y", "x", "sx", "sy", "alpha", "finL", "finR",
    "finWave", "decoration", "progress", "phase", "eyeArt", "mouthArt",
    "finFold", "hairSway", "earFlutter", "puff", "breath", "headX", "headY",
    "bodyX", "bodyY", "blink", "morphX", "morphY", "artMix", "eyeArtPrev",
    "mouthArtPrev", "motionScale", "gazeEmphasis", "dotLift", "dotScale",
    "dotStagger", "isLivelyMotion",
]

TOLERANCES = {
    "params": 1e-6,
    "pose": 1e-6,
    "timeMs": 1e-6,
    "alpha": 1e-6,
    "rationale": (
        "Every number is an IEEE-754 binary64 result of the same operations; "
        "spring substeps are 1/120 s and the longest replay is 300 steps, so "
        "an independent libm's <=1 ulp sin/cos difference accumulates far "
        "below 1e-6. The visible quanta are 0.25 output px, 0.5/target scale, "
        "0.1 degree roll and 1/64 alpha, all >=16x larger than this tolerance. "
        "Enums, art names, booleans and the frame/case set are exact."
    ),
}

FRAME_CLOCK = {
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

# (path, exact substring). The line number is resolved from the checkout so a
# moved/edited anchor makes --check fail instead of silently freezing a stale
# citation.
TRAJECTORY_ANCHORS = [
    ("Sources/PhoneDSHBot/Avatar/BotFishDirector.swift",
     'case surprised, confused, laughing, love, angry, wink, nod, shrug, celebrate, poke'),
    ("Sources/PhoneDSHBot/Avatar/BotFishDirector.swift",
     'case shakingHead = "shaking-head"'),
    (f"{SWIFT_DIR_REL}/BotFishModel.swift",
     "case .idle: return BotFishClip(period: 2400)"),
    (f"{SWIFT_DIR_REL}/BotFishModel.swift",
     "case .standby: return BotFishClip(period: nil, duration: nil, isStatic: true)"),
    (f"{SWIFT_DIR_REL}/BotFishModel.swift", "struct BotFishParams {"),
    (f"{SWIFT_DIR_REL}/BotFishModel.swift", "struct BotFishClip {"),
    (f"{SWIFT_DIR_REL}/BotFishModel.swift",
     "static func sample(state: BotFishLifecycle, time: Double) -> BotFishParams"),
    (f"{SWIFT_DIR_REL}/BotFishModel.swift",
     "static func expressiveMotion(state: BotFishLifecycle, time: Double, params: BotFishParams)"),
    (f"{SWIFT_DIR_REL}/BotFishModel.swift",
     "let h = min(left, 1.0 / 120.0)"),
    (f"{SWIFT_DIR_REL}/BotFishModel.swift",
     '"laughing", "focused", "surprised", "sad", "love", "confused",'),
    (f"{SWIFT_DIR_REL}/BotFishModel.swift",
     '"smile", "smile-open", "laugh", "shocked", "pout", "sad",'),
    (f"{SWIFT_DIR_REL}/BotFishEngine.swift",
     "private let gazeXSpring = BotFishSpring(0, omega: 23)"),
    (f"{SWIFT_DIR_REL}/BotFishEngine.swift",
     "let dt = BotFishMath.clamp(dtMilliseconds, 0, 100)"),
    (f"{SWIFT_DIR_REL}/BotFishEngine.swift",
     "let stateTime = (reduced || isStatic) ? 650 : elapsed"),
    (f"{SWIFT_DIR_REL}/BotFishEngine.swift",
     "private static let offsetQuantum: CGFloat = 0.25"),
    (f"{SWIFT_DIR_REL}/BotFishEngine.swift",
     "private static let rollQuantum = 0.1"),
    (f"{SWIFT_DIR_REL}/BotFishEngine.swift",
     "if blinkAge >= 0, blinkAge < 260 {"),
    (f"{SWIFT_DIR_REL}/BotFishEngine.swift",
     "p.artMix = (reduced || isStatic) ? 1 : BotFishMath.clamp((time - artStart) / 180, 0, 1)"),
    (f"{SWIFT_DIR_REL}/BotFishEngine.swift",
     "let poking = pokeAge >= 0 && pokeAge < 420"),
    (f"{SWIFT_DIR_REL}/BotFishEngine.swift",
     "private static let staticActionPhase: [String: Double] = ["),
    (f"{SWIFT_DIR_REL}/BotFishEngine.swift",
     "private static func pose(_ p: BotFishParams, size: CGFloat,"),
    (f"{SWIFT_DIR_REL}/BotFishEngine.swift",
     "let boost = params.isLivelyMotion ? 1 : BotFishRenderer.motionBoost(for: size)"),
    (f"{SWIFT_DIR_REL}/BotFishEngine.swift",
     "(BotFishMath.clamp(value, 0, 1) * 64).rounded() / 64"),
    (f"{SWIFT_DIR_REL}/BotFishView.swift",
     "init(state: BotFishLifecycle, size: CGFloat,"),
    (f"{SWIFT_DIR_REL}/BotFishView.swift", "private var hardPaused: Bool {"),
    (f"{SWIFT_DIR_REL}/BotFishView.swift", "if botFishPaused { return true }"),
    (f"{SWIFT_DIR_REL}/BotFishView.swift", "if !isVisible { return true }"),
    (f"{SWIFT_DIR_REL}/BotFishView.swift",
     "if motionProfile == .lively { return 1.0 / 30.0 }"),
    (f"{SWIFT_DIR_REL}/BotFishView.swift",
     "return size <= BotFishRenderer.motionBoostSmallSize ? 1.0 / 15.0 : 1.0 / 20.0"),
    (f"{SWIFT_DIR_REL}/BotFishView.swift",
     "if still || reduceMotion || lowPowerMode { return true }"),
    (f"{SWIFT_DIR_REL}/BotFishView.swift",
     "private func syncPauseState() async {"),
    (f"{SWIFT_DIR_REL}/BotFishView.swift", "UnitPoint(x: 0.5,"),
    (f"{SWIFT_DIR_REL}/BotFishRenderer.swift",
     "static let cropOrigin = CGPoint(x: 48, y: 30)"),
    (f"{SWIFT_DIR_REL}/BotFishRenderer.swift",
     "static let cropSide: CGFloat = 416"),
    (f"{SWIFT_DIR_REL}/BotFishRenderer.swift",
     "static let crownedCropSide: CGFloat = 448"),
    (f"{SWIFT_DIR_REL}/BotFishRenderer.swift",
     "static let motionBoostSmallSize: CGFloat = 40"),
    (f"{SWIFT_DIR_REL}/BotFishRenderer.swift",
     "static let motionBoostLargeSize: CGFloat = 64"),
    (f"{SWIFT_DIR_REL}/BotFishRenderer.swift",
     "static let motionBoostFactor: Double = 2.2"),
    (f"{SWIFT_DIR_REL}/BotFishRenderer.swift",
     "static let headSlicingMinimumSize: CGFloat = 40"),
    (f"{SWIFT_DIR_REL}/BotFishRenderer.swift",
     "static func motionBoost(for size: CGFloat) -> Double {"),
    (f"{SWIFT_DIR_REL}/BotFishRenderer.swift",
     "private static func faceSignature("),
    (f"{SWIFT_DIR_REL}/BotFishRenderer.swift",
     "private func sliceImage("),
    (f"{SWIFT_DIR_REL}/BotFishRenderer.swift",
     "static let livelyHeadSliceQuantum = 0.25"),
    (f"{SWIFT_DIR_REL}/BotFishAssets.swift", "struct BotFishPalette {"),
    (f"{SWIFT_DIR_REL}/BotFishAssets.swift", "(0, [13, 15, 25]),"),
    (f"{SWIFT_DIR_REL}/BotFishAssets.swift", "private static func tintBody("),
    (f"{SWIFT_DIR_REL}/BotFishAssets.swift",
     'case (.long, false): folder = "base"'),
    (f"{SWIFT_DIR_REL}/BotFishLivelyMotion.swift",
     "static let poseSpringOmega = 18.0"),
    (f"{SWIFT_DIR_REL}/BotFishLivelyMotion.swift",
     "static let transitionMilliseconds = 320.0"),
    (f"{SWIFT_DIR_REL}/BotFishLivelyMotion.swift",
     "static let blinkIntervalMilliseconds: ClosedRange<Double> = 3000...5000"),
    (f"{SWIFT_DIR_REL}/BotFishLivelyMotion.swift",
     "static func sample(state: BotFishLifecycle, workStyle: BotFishWorkStyle,"),
    ("Sources/PhoneDSHBot/Avatar/BotFishReactions.swift", '"bowing": 2_800,'),
    ("Sources/PhoneDSHBot/Avatar/BotFishReactions.swift",
     "public static let expressionDurationMs: Int64 = 4_000"),
    ("Sources/PhoneDSHBot/Profile/BotFishAppearance.swift",
     'case .blue: return "#1680F3"'),
    ("examples/probe-app/BotFish/atlas.json", '"implementation": "sample:idle"'),
    ("examples/probe-app/BotFish/expressive/atlas.json", '"grid": ['),
    ("examples/probe-app/project.yml", "- path: BotFish"),
    ("examples/probe-app/BotFish/SOURCES.md",
     "用户已明确授权在 phoneDSH iOS 中使用大肥鱼形象素材"),
]

ASSET_ANCHORS = [
    ("examples/probe-app/BotFish/SOURCES.md", "来源仓库：`launsion-boop/dsh-bot`"),
    ("examples/probe-app/BotFish/SOURCES.md",
     "固定提交：`bf4075b0a2e8092b04b726c59a7b085d5a37e6f6`"),
    ("examples/probe-app/BotFish/SOURCES.md",
     "源目录：`src/renderer/public/assets/fish/`"),
    ("examples/probe-app/BotFish/SOURCES.md",
     "`body.png` 为灰度，运行时按颜色 LUT 着色"),
    ("examples/probe-app/BotFish/SOURCES.md",
     "`expressive/eyes.png`、`expressive/mouths.png`：768×512 表情 sprite（3×4，单元 256×128）"),
    ("examples/probe-app/project.yml", "- path: BotFish"),
    ("examples/probe-app/project.yml", "type: folder"),
    ("examples/probe-app/BotFish/atlas.json", '"static": true'),
    ("examples/probe-app/BotFish/atlas.json", '"duration": 420'),
    ("examples/probe-app/BotFish/expressive/atlas.json", '"cell": ['),
    ("NOTICE", "Artwork: the mascot in docs/assets/logo.png"),
    ("LICENSE", "MIT License"),
]


class GenerationSkipped(Exception):
    """The host cannot build/run the real Swift model."""


class GenerationFailed(Exception):
    pass


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def png_header(path: Path) -> dict:
    with path.open("rb") as handle:
        header = handle.read(33)
    if header[:8] != b"\x89PNG\r\n\x1a\n" or header[12:16] != b"IHDR":
        raise GenerationFailed(f"not a PNG with an IHDR: {path}")
    width, height, bit_depth, color_type, compression, filter_, interlace = (
        struct.unpack(">IIBBBBB", header[16:29])
    )
    return {
        "width": width,
        "height": height,
        "bitDepth": bit_depth,
        "colorType": color_type,
        "compression": compression,
        "filter": filter_,
        "interlace": interlace,
    }


def resolve_anchor(path_rel: str, needle: str) -> dict:
    path = REPO_ROOT / path_rel
    if not path.is_file():
        raise GenerationFailed(f"anchor file is missing: {path_rel}")
    for index, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if needle in line:
            return {"path": path_rel, "line": index, "contains": needle}
    raise GenerationFailed(f"anchor text not found in {path_rel}: {needle!r}")


def source_manifest() -> list:
    files = []
    for path_rel in sorted(SOURCE_FILES):
        path = REPO_ROOT / path_rel
        if not path.is_file():
            raise GenerationFailed(f"source file is missing: {path_rel}")
        files.append({
            "path": path_rel,
            "bytes": path.stat().st_size,
            "sha256": sha256_file(path),
        })
    return files


def build_assets_manifest() -> dict:
    if not ASSET_ROOT.is_dir():
        raise GenerationFailed(f"asset tree is missing: {ASSET_ROOT_REL}")

    files = []
    for path in sorted(ASSET_ROOT.rglob("*")):
        if not path.is_file() or path.name == "SOURCES.md":
            continue
        rel = path.relative_to(ASSET_ROOT).as_posix()
        entry = {
            "path": rel,
            "bytes": path.stat().st_size,
            "sha256": sha256_file(path),
        }
        if path.suffix.lower() == ".png":
            entry.update(png_header(path))
        files.append(entry)
    png_count = sum(1 for entry in files if entry["path"].endswith(".png"))
    if png_count != 33:
        raise GenerationFailed(f"expected 33 PNG layers, found {png_count}")

    top_atlas = json.loads((ASSET_ROOT / "atlas.json").read_text(encoding="utf-8"))
    expressive = json.loads(
        (ASSET_ROOT / "expressive/atlas.json").read_text(encoding="utf-8"))

    states = [name for name in top_atlas if name not in ATLAS_AUX]
    if sorted(states) != sorted(LIFECYCLE):
        raise GenerationFailed(
            "atlas state set no longer matches BotFishLifecycle: "
            f"{sorted(states)!r} != {sorted(LIFECYCLE)!r}")

    state_animation = {}
    referenced = set()
    for name, entry in top_atlas.items():
        if "file" in entry:
            referenced.add(entry["file"])
        for frame in entry.get("frames", []):
            referenced.add(frame)
        animation = entry.get("animation") or {
            key: entry[key] for key in ("implementation", "fps", "loop")
            if key in entry
        }
        state_animation[name] = {
            "group": entry.get("group"),
            "loop": entry.get("loop"),
            "fps": entry.get("fps"),
            "animation": animation,
            "size": entry.get("size"),
            "anchor": entry.get("anchor"),
        }
    missing = sorted(ref for ref in referenced
                     if not (ASSET_ROOT / ref).is_file())
    present = sorted(ref for ref in referenced
                     if (ASSET_ROOT / ref).is_file())

    provenance_path = ASSET_ROOT / "SOURCES.md"
    provenance_lines = provenance_path.read_text(encoding="utf-8").splitlines()
    grant_index = next(
        (index for index, line in enumerate(provenance_lines, 1)
         if "授权" in line and "iOS" in line), None)
    if grant_index is None:
        raise GenerationFailed(
            "SOURCES.md no longer states the iOS artwork grant; the Android "
            "asset ruling needs a new owner decision")
    grant_text = provenance_lines[grant_index - 1].strip()
    grant_scope = "ios+android" if "Android" in grant_text else "ios-only"

    revision_match = re.search(r"固定提交：`([0-9a-f]{40})`",
                               provenance_path.read_text(encoding="utf-8"))
    repo_match = re.search(r"来源仓库：`([^`]+)`",
                           provenance_path.read_text(encoding="utf-8"))
    if not revision_match or not repo_match:
        raise GenerationFailed("SOURCES.md provenance header changed")

    shared = [
        "base/eyes-open.png", "base/eyes-white.png", "base/iris-left.png",
        "base/iris-right.png", "base/blush.png",
        "expressive/eyes.png", "expressive/mouths.png",
        "overlays/crown.png", "overlays/crown-crystal.png",
    ]
    hairstyles = {}
    for style in ("long", "twin-tail", "bob", "side-braid"):
        plain_dir = "base" if style == "long" else f"hair/{style}"
        crowned_dir = f"crowned/{style}"
        hairstyles[style] = {
            "plain": [f"{plain_dir}/{name}.png"
                      for name in ("body", "fixed", "face-mask")],
            "crowned": [f"{crowned_dir}/{name}.png"
                        for name in ("body", "fixed", "face-mask")],
        }
    runtime_paths = set(shared)
    for entry in hairstyles.values():
        runtime_paths.update(entry["plain"])
        runtime_paths.update(entry["crowned"])
    for rel in sorted(runtime_paths):
        if not (ASSET_ROOT / rel).is_file():
            raise GenerationFailed(f"runtime layer is missing: {rel}")

    sheet = png_header(ASSET_ROOT / "expressive/eyes.png")
    mouths_sheet = png_header(ASSET_ROOT / "expressive/mouths.png")
    grid = expressive.get("grid")
    cell = expressive.get("cell")
    if grid != [3, 4] or cell != [256, 128]:
        raise GenerationFailed(
            f"expressive atlas grid/cell changed: {grid!r} {cell!r}")
    expected_sheet = (grid[0] * cell[0], grid[1] * cell[1])
    if (sheet["width"], sheet["height"]) != expected_sheet or (
            mouths_sheet["width"], mouths_sheet["height"]) != expected_sheet:
        raise GenerationFailed("expressive sheet dimensions disagree with atlas")

    anchors = [resolve_anchor(path, needle) for path, needle in ASSET_ANCHORS]

    return {
        "schemaVersion": SCHEMA_VERSION,
        "vector": "bot-fish-assets",
        "root": ASSET_ROOT_REL,
        "source": {
            "contractBase": CONTRACT_BASE,
            "provenance": f"{ASSET_ROOT_REL}/SOURCES.md",
            "provenanceSha256": sha256_file(provenance_path),
            "upstream": repo_match.group(1),
            "revision": revision_match.group(1),
            "grant": {
                "line": grant_index,
                "text": grant_text,
                "scope": grant_scope,
                "androidGranted": grant_scope == "ios+android",
            },
        },
        "summary": {
            "files": len(files),
            "pngLayers": png_count,
            "topLevelAtlasStates": len(states),
            "auxiliaryEntries": list(ATLAS_AUX),
            "expressiveCells": len(expressive["eyes"]),
        },
        "files": files,
        "runtimeLayers": {
            "shared": shared,
            "hairstyles": hairstyles,
        },
        "expressive": {
            "eyes": expressive["eyes"],
            "mouths": expressive["mouths"],
            "eyesEntries": expressive.get("eyesEntries"),
            "mouthsEntries": expressive.get("mouthsEntries"),
            "grid": grid,
            "cell": cell,
            "sheet": {"width": sheet["width"], "height": sheet["height"]},
        },
        "atlas": {
            "stateCount": len(states),
            "auxEntries": list(ATLAS_AUX),
            "states": state_animation,
            "referencedFiles": sorted(referenced),
            "presentFiles": present,
            "missingFiles": missing,
            "note": (
                "The top-level atlas `file`/`frames` members are web pre-render "
                "paths from dsh-bot. No native layer under examples/probe-app/"
                "BotFish is at those paths; BotFishRenderer never opens them and "
                "implements `animation.implementation` directly. They are kept "
                "here as an exact, frozen exception list, not as shipped assets."
            ),
        },
        "anchors": anchors,
    }


def run_checked(command: list, cwd: Path | None = None,
                timeout: int = 900) -> subprocess.CompletedProcess:
    try:
        result = subprocess.run(command, cwd=cwd, capture_output=True,
                                text=True, timeout=timeout)
    except FileNotFoundError as error:
        raise GenerationSkipped(f"missing command: {command[0]}") from error
    except subprocess.TimeoutExpired as error:
        raise GenerationFailed(
            f"command timed out after {timeout}s: {' '.join(command)}") from error
    if result.returncode != 0:
        tail = "\n".join((result.stderr or result.stdout).splitlines()[-25:])
        raise GenerationFailed(
            f"command failed ({result.returncode}): {' '.join(command)}\n{tail}")
    return result


def swift_toolchain() -> tuple:
    if sys.platform != "darwin":
        raise GenerationSkipped("the app fish renderer needs UIKit; only macOS "
                                "with an iOS simulator can run it")
    for tool in ("xcrun", "swift"):
        if shutil.which(tool) is None:
            raise GenerationSkipped(f"{tool} is not installed")
    sdk_result = run_checked(["xcrun", "--sdk", "iphonesimulator",
                              "--show-sdk-path"], timeout=60)
    sdk = sdk_result.stdout.strip()
    if not sdk:
        raise GenerationSkipped("no iphonesimulator SDK")
    machine = platform.machine()
    arch = "arm64" if machine in ("arm64", "aarch64") else "x86_64"
    triple = f"{arch}-apple-ios17.0-simulator"
    return sdk, arch, triple


def simulator_udid() -> str:
    result = run_checked(["xcrun", "simctl", "list", "devices", "booted", "-j"],
                         timeout=60)
    devices = json.loads(result.stdout).get("devices", {})
    for runtime, entries in devices.items():
        if "iOS" not in runtime:
            continue
        for device in entries:
            if device.get("state") == "Booted":
                return device["udid"]

    result = run_checked(["xcrun", "simctl", "list", "devices", "available", "-j"],
                         timeout=60)
    devices = json.loads(result.stdout).get("devices", {})
    candidate = None
    for runtime, entries in devices.items():
        if "iOS" not in runtime:
            continue
        for device in entries:
            if device.get("isAvailable", True) and "iPhone" in device.get("name", ""):
                candidate = device["udid"]
                break
        if candidate:
            break
    if not candidate:
        raise GenerationSkipped("no available iOS Simulator iPhone device")
    run_checked(["xcrun", "simctl", "boot", candidate], timeout=180)
    run_checked(["xcrun", "simctl", "bootstatus", candidate, "-b"], timeout=300)
    return candidate


def build_package(sdk: str, triple: str) -> Path:
    package_dir = Path(tempfile.gettempdir()) / "phone-dsh-fish-harness-pkg"
    scratch = Path(tempfile.gettempdir()) / "phone-dsh-fish-harness-build"
    sources = package_dir / "Sources/FishHarness"
    if sources.exists():
        shutil.rmtree(sources)
    sources.mkdir(parents=True)
    package_dir.joinpath("Package.swift").write_text(
        f'''// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "FishTrajectoryHarness",
    platforms: [.iOS(.v17), .macOS(.v14)],
    dependencies: [
        .package(name: "phone-dsh", path: "{REPO_ROOT}"),
    ],
    targets: [
        .executableTarget(
            name: "FishHarness",
            dependencies: [.product(name: "PhoneDSHBot", package: "phone-dsh")],
            path: "Sources/FishHarness"),
    ]
)
''', encoding="utf-8")
    for name in APP_FILES:
        (sources / name).symlink_to(SWIFT_DIR / name)
    (sources / "main.swift").symlink_to(TOOLS_DIR / "trajectory_harness.swift")

    run_checked(["swift", "build", "--package-path", str(package_dir),
                 "--triple", triple, "--sdk", sdk,
                 "--scratch-path", str(scratch), "-c", "debug",
                 # Never rewrite the checkout's Package.resolved: a local
                 # path dependency is resolved from the existing lock.
                 "--disable-automatic-resolution"], timeout=1200)
    binaries = sorted(scratch.glob(f"**/debug/FishHarness"))
    binaries = [path for path in binaries if path.is_file()]
    if not binaries:
        raise GenerationFailed(
            f"swift build succeeded but no FishHarness binary under {scratch}")
    return binaries[0]


def run_harness(binary: Path, udid: str, core_path: Path) -> None:
    run_dir = Path(tempfile.mkdtemp(prefix="phone-dsh-fish-run-", dir="/tmp"))
    try:
        executable = run_dir / "FishHarness"
        shutil.copy2(binary, executable)
        shutil.copytree(ASSET_ROOT, run_dir / "BotFish")
        run_checked(["xcrun", "simctl", "spawn", udid, str(executable),
                     "--out", str(core_path)], timeout=600)
    finally:
        shutil.rmtree(run_dir, ignore_errors=True)


def canonical(data: dict) -> str:
    return json.dumps(data, indent=2, sort_keys=True, ensure_ascii=False,
                      allow_nan=False) + "\n"


def build_trajectory(core: dict) -> dict:
    if core.get("schemaVersion") != SCHEMA_VERSION:
        raise GenerationFailed("harness schemaVersion mismatch")
    if core.get("vector") != "bot-fish-trajectory":
        raise GenerationFailed("harness vector mismatch")
    trajectory = dict(core)
    trajectory["source"] = {
        "contractBase": CONTRACT_BASE,
        "generatedBy": "spec/ui/v1/bot/fish/tools/generate_trajectory.py",
        "harness": "spec/ui/v1/bot/fish/tools/trajectory_harness.swift",
        "assetsManifest": "spec/ui/v1/bot/fish/golden/assets.json",
        "files": source_manifest(),
    }
    trajectory["tolerances"] = TOLERANCES
    trajectory["frameClock"] = FRAME_CLOCK
    trajectory["anchors"] = [resolve_anchor(path, needle)
                             for path, needle in TRAJECTORY_ANCHORS]
    return trajectory


def diff_text(expected: str, actual: str, limit: int = 40) -> str:
    return "\n".join(list(difflib.unified_diff(
        expected.splitlines(), actual.splitlines(),
        fromfile="golden", tofile="regenerated", lineterm=""))[:limit])


def main(argv: list) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--check", action="store_true",
                       help="regenerate and fail on any difference")
    group.add_argument("--write", action="store_true",
                       help="write the golden files (default)")
    parser.add_argument("--core", type=Path,
                        help="reuse an existing harness core JSON (skips build/run)")
    args = parser.parse_args(argv)
    write = args.write or not args.check

    try:
        if args.core:
            core = json.loads(args.core.read_text(encoding="utf-8"))
        else:
            sdk, _arch, triple = swift_toolchain()
            udid = simulator_udid()
            binary = build_package(sdk, triple)
            core_fd, core_name = tempfile.mkstemp(
                prefix="phone-dsh-fish-core-", suffix=".json", dir="/tmp")
            os.close(core_fd)
            core_path = Path(core_name)
            try:
                run_harness(binary, udid, core_path)
                core = json.loads(core_path.read_text(encoding="utf-8"))
            finally:
                core_path.unlink(missing_ok=True)

        trajectory = build_trajectory(core)
        assets = build_assets_manifest()
        outputs = {
            GOLDEN_DIR / "trajectory.json": canonical(trajectory),
            GOLDEN_DIR / "assets.json": canonical(assets),
        }
    except GenerationSkipped as error:
        print(f"generate_trajectory: SKIP: {error}", file=sys.stderr)
        return 77
    except GenerationFailed as error:
        print(f"generate_trajectory: FAIL: {error}", file=sys.stderr)
        return 1

    failures = 0
    for path, text in outputs.items():
        rel = path.relative_to(REPO_ROOT)
        if write:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")
            print(f"wrote {rel} ({len(text)} bytes)")
            continue
        if not path.is_file():
            print(f"MISSING {rel}", file=sys.stderr)
            failures += 1
            continue
        expected = path.read_text(encoding="utf-8")
        if expected != text:
            print(f"DIFF {rel}\n{diff_text(expected, text)}", file=sys.stderr)
            failures += 1
    if failures:
        print(f"generate_trajectory: FAIL ({failures} file(s)); "
              "re-run with --write and review the diff", file=sys.stderr)
        return 1
    if not write:
        print("generate_trajectory: OK (goldens match the real Swift model)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
