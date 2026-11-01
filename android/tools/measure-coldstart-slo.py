#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""P5 lane: cold-start SLO numbers from ONE emulator, measured, never estimated.

What one run does (all timestamps are the device's own clock, so no host/device
offset enters the numbers):

  1. force-stop the probe app, clear logcat
  2. `am start` with a real model base URL and one prompt
  3. wait for `APP_WORKER_READY` (the worker's `XL_DSH_READY` reached the host)
  4. read the screen, tap `跑一轮` once
  5. wait for `APP_TURN_OK`/`APP_TURN_FAILED`, sampling `dumpsys meminfo`
     before, during and after the turn
  6. read the turn's own session journal (session.v4.jsonl) and take the
     `assistant/message` row's `time` (epoch ms) as the first assistant message

Reported per run:

  cold_start_ms        ActivityTaskManager START -> APP_WORKER_READY
  worker_load_ms       the engine's own "worker assets: ... in N ms" (the
                       materialize() call; the log-line delta is kept separately)
  overlay_load_ms      "page started:" -> worker "tree active (... data overlays=1 ...)"
  ttft_ms              APP_TURN_BUTTON -> assistant/message row `time`
  ttft_first_text_ms   APP_TURN_BUTTON -> first streamed `text` block start
  rss_peak_kb          max TOTAL RSS over the before/during/after samples
  pss_peak_kb          max TOTAL PSS over the same samples

The meminfo `TOTAL` row's first number is **PSS**, not RSS; the fifth is RSS.
This script parses the App Summary line ("TOTAL PSS: ... TOTAL RSS: ...") so
the two are never confused, and prints both.

Usage:
  python3 android/tools/measure-coldstart-slo.py --serial emulator-5564 --runs 5
  python3 android/tools/measure-coldstart-slo.py --serial emulator-5564 --runs 5 --prompt '...'

Requires: adb on PATH (or ANDROID_HOME set), a booted emulator/device, the app
installed, and its model key already imported. This script does not deploy the
key and does not build the APK.
"""

import argparse
import json
import os
import re
import statistics
import subprocess
import sys
import time

PACKAGE = "com.phonedsh.probe"
COMPONENT = PACKAGE + "/.MainActivity"
DEFAULT_PROMPT = "只回答一个数字：1+1 等于几？"
DEFAULT_BASE = "https://api.deepseek.com/anthropic"
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
ARTIFACTS = os.path.join(ROOT, "android", "build", "p5-slo")


def adb(serial, *args, timeout=120):
    cmd = ["adb", "-s", serial] + [str(a) for a in args]
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)


def device_epoch_ms(serial):
    out = adb(serial, "shell", "date", "+%s%3N").stdout.strip()
    return int(out)


def logcat_dump(serial):
    return adb(serial, "logcat", "-d", "-v", "epoch").stdout


def wait_log(serial, pattern, timeout_s=180):
    deadline = time.time() + timeout_s
    regex = re.compile(pattern)
    while time.time() < deadline:
        for line in logcat_dump(serial).splitlines():
            m = regex.search(line)
            if m:
                return line
        time.sleep(0.35)
    return None


def ui_center_of(serial, label):
    """Center of the node whose text or content-desc is exactly `label`."""
    import xml.etree.ElementTree as ET

    for _ in range(10):
        dump = adb(serial, "shell", "uiautomator", "dump", "/sdcard/p5-ui.xml")
        if dump.returncode != 0:
            time.sleep(0.5)
            continue
        xml = adb(serial, "exec-out", "cat", "/sdcard/p5-ui.xml").stdout
        try:
            root = ET.fromstring(xml)
        except ET.ParseError:
            time.sleep(0.5)
            continue
        for node in root.iter("node"):
            text = (node.get("text") or "").strip()
            desc = (node.get("content-desc") or "").strip()
            if text == label or desc == label:
                bounds = node.get("bounds") or ""
                m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", bounds)
                if m:
                    x1, y1, x2, y2 = map(int, m.groups())
                    return (x1 + x2) // 2, (y1 + y2) // 2
        time.sleep(0.5)
    return None


def meminfo_kb(serial):
    """(pss_kb, rss_kb) from the App Summary; None when the read failed."""
    out = adb(serial, "shell", "dumpsys", "meminfo", PACKAGE, timeout=60).stdout
    m = re.search(r"TOTAL PSS:\s*(\d+)\s+TOTAL RSS:\s*(\d+)", out)
    if not m:
        return None
    return int(m.group(1)), int(m.group(2))


def journal_path(serial, session_id):
    found = adb(
        serial,
        "shell",
        "run-as",
        PACKAGE,
        "find",
        "./files/xl",
        "-name",
        "session.v4.jsonl",
    ).stdout
    for path in found.splitlines():
        path = path.strip()
        if session_id and session_id in path:
            return path
    return None


def parse_journal(serial, session_id):
    """Assistant-row time + first streamed text-block start, from the device WAL."""
    path = journal_path(serial, session_id)
    if path is None:
        return {"journal": None, "assistant_time_ms": None, "first_text_ms": None}
    raw = adb(serial, "shell", "run-as", PACKAGE, "cat", "--", path).stdout
    assistant_time = None
    first_text = None
    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        if row.get("type") != "assistant/message":
            continue
        if assistant_time is None:
            assistant_time = row.get("time")
        data = row.get("data") or {}
        for chunk in data.get("stream") or []:
            inner = chunk.get("chunk") or {}
            if inner.get("type") == "block-start" and inner.get("blockType") == "text":
                if first_text is None:
                    first_text = chunk.get("time")
                break
        if assistant_time is not None and first_text is not None:
            break
    return {
        "journal": path,
        "assistant_time_ms": assistant_time,
        "first_text_ms": first_text,
    }


def run_once(serial, index, prompt, base):
    adb(serial, "shell", "am", "force-stop", PACKAGE)
    adb(serial, "logcat", "-c")
    time.sleep(1.5)

    started = adb(
        serial,
        "shell",
        "am",
        "start",
        "-n",
        COMPONENT,
        "--es",
        "pdsh.deepseek.baseUrl",
        base,
        "--es",
        "pdsh.prompt",
        prompt,
    )
    if started.returncode != 0:
        return {"run": index, "error": "am start failed: " + started.stderr.strip()}

    ready_line = wait_log(serial, r"PDSHAppTurn:\s*APP_WORKER_READY", 180)
    if ready_line is None:
        return {"run": index, "error": "APP_WORKER_READY never appeared"}

    mem_before = meminfo_kb(serial)

    point = ui_center_of(serial, "跑一轮")
    if point is None:
        return {"run": index, "error": "no 跑一轮 button on screen"}

    button_log_before = len(re.findall(r"APP_TURN_BUTTON", logcat_dump(serial)))
    adb(serial, "shell", "input", "tap", str(point[0]), str(point[1]))

    # Sample memory while the turn runs, then once more after it ends. The
    # turn itself is asynchronous on the device; the samples are wall-clock
    # observations, not instrumented peaks.
    samples = []
    turn_line = None
    deadline = time.time() + 300
    while time.time() < deadline:
        now = device_epoch_ms(serial)
        hit = meminfo_kb(serial)
        if hit is not None:
            samples.append({"t_ms": now, "pss_kb": hit[0], "rss_kb": hit[1]})
        lines = logcat_dump(serial)
        for line in lines.splitlines():
            if "APP_TURN_OK" in line or "APP_TURN_FAILED" in line:
                turn_line = line
                break
        if turn_line is not None:
            break
        time.sleep(0.4)

    mem_after = meminfo_kb(serial)
    log = logcat_dump(serial)
    os.makedirs(ARTIFACTS, exist_ok=True)
    with open(os.path.join(ARTIFACTS, "run-%d.logcat.txt" % index), "w") as fh:
        fh.write(log)

    def epoch_of(pattern):
        for line in log.splitlines():
            m = re.search(pattern, line)
            if m:
                return float(m.group(1))
        return None

    t_start = epoch_of(r"\s(\d+\.\d+)\s+\d+\s+\d+\s+I\s+ActivityTaskManager:\s+START u0 .*com\.phonedsh\.probe")
    t_ready = epoch_of(r"\s(\d+\.\d+)\s+\d+\s+\d+\s+I\s+PDSHAppTurn:\s*APP_WORKER_READY")
    t_materialize = epoch_of(r"\s(\d+\.\d+)\s+\d+\s+\d+\s+I\s+PDSHEngine:\s*start: materializing")
    t_bundle = epoch_of(r"\s(\d+\.\d+)\s+\d+\s+\d+\s+I\s+PDSHEngine:\s*start: bundle ")
    t_page_started = epoch_of(r"\s(\d+\.\d+)\s+\d+\s+\d+\s+I\s+PDSHEngine:\s*page started:")
    t_tree_active = epoch_of(r"\s(\d+\.\d+)\s+\d+\s+\d+\s+D\s+PDSHEngine:\s*console LOG: webworker host: tree active")
    t_button = epoch_of(r"\s(\d+\.\d+)\s+\d+\s+\d+\s+I\s+PDSHAppTurn:\s*APP_TURN_BUTTON")

    session_match = re.search(r"APP_TURN_OK session=(\S+)", turn_line or "")
    session_id = session_match.group(1) if session_match else None
    journal = parse_journal(serial, session_id)

    def delta(a, b):
        if a is None or b is None:
            return None
        return round((b - a) * 1000)

    printed = re.search(r"worker assets: (?:reusing|ready).*? in (\d+) ms", log)
    worker_load_printed = int(printed.group(1)) if printed else None

    rss_values = [s["rss_kb"] for s in samples]
    pss_values = [s["pss_kb"] for s in samples]
    if mem_before is not None:
        rss_values.append(mem_before[1])
        pss_values.append(mem_before[0])
    if mem_after is not None:
        rss_values.append(mem_after[1])
        pss_values.append(mem_after[0])

    assistant_time = journal["assistant_time_ms"]
    first_text_time = journal["first_text_ms"]

    return {
        "run": index,
        "button_logged": button_log_before,
        "turn_log": (turn_line or "").split("PDSHAppTurn: ")[-1].strip()[:200],
        "session": session_id,
        "journal": journal["journal"],
        "cold_start_ms": delta(t_start, t_ready),
        "worker_load_ms": worker_load_printed,
        "worker_load_log_delta_ms": delta(t_materialize, t_bundle),
        "overlay_load_ms": delta(t_page_started, t_tree_active),
        "ttft_ms": delta(t_button, assistant_time / 1000.0) if assistant_time else None,
        "ttft_first_text_ms": delta(t_button, first_text_time / 1000.0) if first_text_time else None,
        "rss_before_kb": mem_before[1] if mem_before else None,
        "rss_after_kb": mem_after[1] if mem_after else None,
        "rss_peak_kb": max(rss_values) if rss_values else None,
        "pss_before_kb": mem_before[0] if mem_before else None,
        "pss_after_kb": mem_after[0] if mem_after else None,
        "pss_peak_kb": max(pss_values) if pss_values else None,
        "mid_samples": len(samples),
        "t_start": t_start,
        "t_ready": t_ready,
    }


def summary(values):
    values = [v for v in values if v is not None]
    if not values:
        return None
    values = sorted(values)
    return {
        "n": len(values),
        "min": values[0],
        "median": statistics.median(values),
        "max": values[-1],
        "samples": values,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--serial", required=True, help="adb serial, e.g. emulator-5564")
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--prompt", default=DEFAULT_PROMPT)
    parser.add_argument("--base", default=DEFAULT_BASE)
    args = parser.parse_args()

    os.makedirs(ARTIFACTS, exist_ok=True)
    rows = []
    for i in range(1, args.runs + 1):
        print("run %d/%d ..." % (i, args.runs), flush=True)
        row = run_once(args.serial, i, args.prompt, args.base)
        rows.append(row)
        print(json.dumps(row, ensure_ascii=False), flush=True)
        with open(os.path.join(ARTIFACTS, "runs.jsonl"), "w") as fh:
            for r in rows:
                fh.write(json.dumps(r, ensure_ascii=False) + "\n")

    metrics = [
        "cold_start_ms",
        "worker_load_ms",
        "overlay_load_ms",
        "ttft_ms",
        "ttft_first_text_ms",
        "rss_peak_kb",
        "pss_peak_kb",
    ]
    report = {m: summary([r.get(m) for r in rows]) for m in metrics}
    report["runs"] = rows
    with open(os.path.join(ARTIFACTS, "summary.json"), "w") as fh:
        json.dump(report, fh, ensure_ascii=False, indent=2)

    print("\n== summary (ms; RSS/PSS in KB)")
    for m in metrics:
        s = report[m]
        if s is None:
            print("%-20s no measurement" % m)
        else:
            print(
                "%-20s min=%s median=%s max=%s n=%d"
                % (m, s["min"], s["median"], s["max"], s["n"])
            )
    print("\nartifacts: %s" % ARTIFACTS)
    errors = [r for r in rows if r.get("error")]
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
