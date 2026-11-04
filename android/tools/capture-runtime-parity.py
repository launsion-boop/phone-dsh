#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Capture the installed App, with provenance, alongside a named iOS baseline.

This never captures the Compose sample harness or promotes a golden. Matching
frames is a precondition for review, not evidence that content/interaction match.
"""
import argparse
import hashlib
import json
import re
import subprocess
import xml.etree.ElementTree as ET
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--adb", default="adb")
    parser.add_argument("--serial", required=True)
    parser.add_argument("--ios-state", required=True)
    parser.add_argument("--ios-dir", type=Path,
                        default=ROOT / "docs/receipts/pr14-ios-alignment/ios-latest",
                        help="fresh iOS captures; historical screenshot folders require an explicit override")
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"[a-z0-9-]+", args.ios_state):
        parser.error("ios-state must be a baseline name")
    ios = args.ios_dir / (args.ios_state + ".png")
    if not ios.is_file():
        parser.error("iOS baseline does not exist")

    def adb(*command, binary=False):
        return subprocess.check_output([args.adb, "-s", args.serial, *command],
                                       text=not binary, timeout=30)

    foreground = adb("shell", "dumpsys", "window")
    focus = next((line.strip() for line in foreground.splitlines() if "mCurrentFocus=" in line), "")
    if "com.phonedsh.app/" not in focus:
        parser.error("the real com.phonedsh.app must be foreground; harness/launcher captures are rejected")
    args.out.mkdir(parents=True, exist_ok=True)
    png = args.out / (args.ios_state + "__runtime.png")
    png.write_bytes(adb("exec-out", "screencap", "-p", binary=True))
    adb("shell", "uiautomator", "dump", "/sdcard/pr14-runtime.xml")
    xml = adb("shell", "cat", "/sdcard/pr14-runtime.xml")
    (args.out / (args.ios_state + ".xml")).write_text(xml)
    package = adb("shell", "dumpsys", "package", "com.phonedsh.app")
    apk_path = next(line.removeprefix("package:").strip() for line in
                    adb("shell", "pm", "path", "com.phonedsh.app").splitlines() if line.startswith("package:"))
    apk_hash = adb("shell", "sha256sum", apk_path).split()[0]
    source_hash = hashlib.sha256()
    source_files = subprocess.check_output(["git", "ls-files", "-co", "--exclude-standard", "android", "spec/ui/v1/tokens.json"],
                                           cwd=ROOT, text=True).splitlines()
    for name in sorted(set(source_files)):
        path = ROOT / name
        if path.is_file():
            source_hash.update(name.encode() + b"\0" + path.read_bytes() + b"\0")
    nodes = []
    for node in ET.fromstring(xml).iter("node"):
        if node.get("text") or node.get("content-desc"):
            nodes.append({key: node.get(key, "") for key in
                          ("text", "content-desc", "bounds", "class", "enabled", "clickable")})
    runtime_image, ios_image = Image.open(png).convert("RGB"), Image.open(ios).convert("RGB")
    frame_matches = runtime_image.size == ios_image.size
    header = 60
    canvas = Image.new("RGB", (ios_image.width + runtime_image.width, max(ios_image.height, runtime_image.height) + header), "#eeeeee")
    ImageDraw.Draw(canvas).text((12, 12), "iOS repository baseline | Android installed App (runtime, not samples)", fill="black")
    canvas.paste(ios_image, (0, header))
    canvas.paste(runtime_image, (ios_image.width, header))
    canvas.save(args.out / (args.ios_state + "__ios-runtime.png"))
    manifest = {
        "source": "installed-app-adb", "package": "com.phonedsh.app",
        "sampleHarness": False, "state": args.ios_state,
        "installedApkSha256": apk_hash, "androidSourceSha256": source_hash.hexdigest(),
        "gitHead": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "workingTreeDirty": bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT)),
        "iosSha256": hashlib.sha256(ios.read_bytes()).hexdigest(),
        "runtimeSha256": hashlib.sha256(png.read_bytes()).hexdigest(),
        "iosFrame": ios_image.size, "runtimeFrame": runtime_image.size,
        "frame": "PASS" if frame_matches else "FAIL", "visualParity": "NOT_RUN",
        "interactionParity": "NOT_RUN",
        "appVersion": [line.strip() for line in package.splitlines() if "versionName=" in line or "versionCode=" in line],
        "nodes": nodes,
    }
    (args.out / (args.ios_state + ".json")).write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    print(f"{args.ios_state}: runtime CAPTURED, frame {'PASS' if frame_matches else 'FAIL'}; visual/interaction review NOT_RUN")
    return 0 if frame_matches else 1


if __name__ == "__main__":
    raise SystemExit(main())
