#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""L10 reachability walk: launch -> drawer tap -> entry tap -> screenshot.

Every step is a real `adb shell input tap` on a semantics node found by
`uiautomator dump`; nothing calls `nav.push`. Screenshots are `screencap`.
"""
import json
import re
import subprocess
import sys
import time

ADB = "/opt/homebrew/share/android-commandlinetools/platform-tools/adb"
SERIAL = "emulator-5624"
OUT = "/tmp/l10-shots-final"

ENTRIES = [
    ("对话", "10-chat"),
    ("会话", "11-sessions"),
    ("工作文件夹", "12-workspace-folders"),
    ("命令", "13-tools-commands"),
    ("设备连接", "14-device-connection"),
    ("定时任务", "15-automation"),
    ("设置", "16-settings"),
    ("DSH 页面", "17-dsh-web-surface"),
]

evidence = {"pages": [], "drawer": {}, "sessionsHandoff": {}, "deviceSession": {}}


def adb(*args, check=True):
    return subprocess.run([ADB, "-s", SERIAL, *args], check=check, capture_output=True, text=True)


def dump_nodes():
    adb("shell", "uiautomator", "dump", "/sdcard/ui.xml")
    xml = adb("shell", "cat", "/sdcard/ui.xml").stdout
    nodes = []
    for m in re.finditer(r"<node[^>]*>", xml):
        nodes.append(dict(re.findall(r'([\w-]+)="([^"]*)"', m.group(0))))
    return nodes


def bounds(node):
    return list(map(int, re.findall(r"\d+", node["bounds"])))


def find(nodes, desc=None, text=None, contains=False):
    for n in nodes:
        if desc is not None:
            value = n.get("content-desc", "")
            if (desc in value) if contains else (value == desc):
                return n
        if text is not None:
            value = n.get("text", "")
            if (text in value) if contains else (value == text):
                return n
    return None


def tap_node(node, what):
    x1, y1, x2, y2 = bounds(node)
    x, y = (x1 + x2) // 2, (y1 + y2) // 2
    print(f"tap {what} at ({x},{y}) bounds={node['bounds']}")
    adb("shell", "input", "tap", str(x), str(y))
    time.sleep(2.0)


def tap_desc(desc):
    nodes = dump_nodes()
    node = find(nodes, desc=desc)
    if node is None:
        raise SystemExit(f"NOT FOUND: {desc}\n" + repr([n.get("content-desc") for n in nodes]))
    tap_node(node, desc)


def back():
    adb("shell", "input", "keyevent", "4")
    time.sleep(1.4)


def shot(name):
    data = subprocess.run(
        [ADB, "-s", SERIAL, "exec-out", "screencap", "-p"], check=True, capture_output=True
    ).stdout
    with open(f"{OUT}/{name}.png", "wb") as f:
        f.write(data)
    print("shot", name)


def visible(nodes=None):
    nodes = nodes or dump_nodes()
    out = []
    for n in nodes:
        for key in ("content-desc", "text"):
            v = n.get(key, "")
            if v and v not in out:
                out.append(v)
    return out


def at_home():
    return find(dump_nodes(), desc="打开抽屉") is not None


def open_drawer():
    tap_desc("打开抽屉")


def main():
    adb("shell", "am", "force-stop", "com.phonedsh.probe")
    adb("shell", "am", "start", "-n", "com.phonedsh.probe/.MainActivity")
    time.sleep(7)
    if not at_home():
        raise SystemExit("not at home: " + repr(visible()[:20]))
    shot("00-home")

    open_drawer()
    shot("01-drawer")
    nodes = dump_nodes()
    rows = [
        {"label": n.get("content-desc"), "bounds": n["bounds"]}
        for n in nodes
        if n.get("content-desc") in [label for label, _ in ENTRIES]
    ]
    evidence["drawer"]["rows"] = rows
    text_node = find(nodes, text="对话")
    evidence["drawer"]["firstRowLabelBounds"] = text_node["bounds"] if text_node else None
    container = next(
        (
            n
            for n in nodes
            if bounds(n)[2] - bounds(n)[0] == 840 and bounds(n)[3] - bounds(n)[1] > 300
        ),
        None,
    )
    evidence["drawer"]["panelLikeBounds"] = container["bounds"] if container else None
    back()

    for label, stem in ENTRIES:
        if not at_home():
            raise SystemExit(f"not home before {label}: " + repr(visible()[:10]))
        open_drawer()
        tap_desc(label)
        shot(stem)
        texts = visible()
        evidence["pages"].append({"label": label, "shot": stem + ".png", "texts": texts[:12]})
        print(f"PAGE {label}:", texts[:10])
        back()
        if not at_home():
            print(f"WARN not home after {label}:", visible()[:8])

    # 定时任务's bar controls: they only render when the route passes the
    # callbacks (NativeAutomationPage.kt:598/607). Tap both and record the host
    # handoff lines they produce.
    open_drawer()
    tap_desc("定时任务")
    adb("shell", "logcat", "-c")
    tap_desc("刷新")
    shot("15b-automation-refresh")
    refresh_log = [
        line
        for line in adb("shell", "logcat", "-d", "-s", "PDSHNav").stdout.splitlines()
        if "handed off" in line
    ]
    refresh_visible = visible()[:4]
    tap_desc("新建")
    shot("15c-automation-new")
    new_log = [
        line
        for line in adb("shell", "logcat", "-d", "-s", "PDSHNav").stdout.splitlines()
        if "handed off" in line
    ]
    evidence["automationBar"] = {
        "refreshLog": refresh_log,
        "refreshVisible": refresh_visible,
        "newLog": new_log,
        "newVisible": visible()[:4],
    }
    print("AUTOMATION REFRESH:", refresh_log, refresh_visible)
    print("AUTOMATION NEW:", new_log)
    back()
    if not at_home():
        raise SystemExit("not home after automation: " + repr(visible()[:10]))

    open_drawer()
    tap_desc("会话")
    adb("shell", "logcat", "-c")
    nodes = dump_nodes()
    new_session = find(nodes, text="新建会话")
    tap_node(new_session, "新建会话")
    log = adb("shell", "logcat", "-d", "-s", "PDSHSessions").stdout
    handoff = [line for line in log.splitlines() if "handed off" in line]
    evidence["sessionsHandoff"] = {"log": handoff, "visible": visible()[:6]}
    shot("18-sessions-host-handoff")
    print("SESSIONS HANDOFF:", handoff)
    back()
    if not at_home():
        raise SystemExit("not home after sessions: " + repr(visible()[:10]))

    open_drawer()
    tap_desc("设备连接")
    nodes = dump_nodes()
    device = find(nodes, desc="客厅网关")
    if device is None:
        raise SystemExit("no device row: " + repr(visible()[:20]))
    tap_node(device, "客厅网关")
    shot("20-device-session")
    texts = visible()
    evidence["deviceSession"] = {"texts": texts[:16]}
    print("DEVICE SESSION:", texts[:14])
    back()
    back()
    evidence["homeAtEnd"] = at_home()
    print("home at end:", evidence["homeAtEnd"])
    with open("/tmp/l10-evidence.json", "w") as f:
        json.dump(evidence, f, ensure_ascii=False, indent=1)
    print("EVIDENCE WRITTEN")


if __name__ == "__main__":
    sys.exit(main())
