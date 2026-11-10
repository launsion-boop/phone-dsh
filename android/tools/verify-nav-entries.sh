#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Entry-point assertion for the X1 navigation wiring.
#
# `spec/ui/v1/README.md` §1 lists an 入口 for every page. A page that compiles
# and passes its JVM tests is still unreachable until a row, a header button or a
# sheet actually opens it. This script taps those entries on a device with
# uiautomator and asserts the page they open rendered its own title plus one
# page-owned line, so "the page exists" becomes "the page can be reached".
#
# The launch supplies no upstream and no egress grant on purpose: every page must
# render from the host's read-only snapshot, and an unmeasured fact is expected to
# show its 未知 wording rather than a fabricated value. That is also why the
# assertions include the unknown-state line (for example 定时任务状态未知): it is
# the honest reading of a host that has no schedule store.
#
# Usage:
#   bash android/tools/verify-nav-entries.sh             # build, install, assert
#   bash android/tools/verify-nav-entries.sh --no-build  # reuse the built APK
#   bash android/tools/verify-nav-entries.sh --web-face  # also assert §1's
#                                                        # 引擎就绪时的默认面
#
# Environment:
#   ANDROID_HOME  (default from android/local.properties on this host)
#   JAVA_HOME     (derived from `java` on PATH when unset)
#   ANDROID_SERIAL / SERIAL  pin one device (default: first emulator)

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ANDROID_HOME="${ANDROID_HOME:-$(sed -n 's/^sdk\.dir=//p' "$ROOT/android/local.properties" 2>/dev/null | head -1)}"
if [ -z "${JAVA_HOME:-}" ] && command -v java >/dev/null 2>&1; then
  JAVA_HOME="$(cd "$(dirname "$(command -v java)")/.." && pwd)"
fi
PACKAGE="${PDSH_PACKAGE:-com.phonedsh.app}"
ARTIFACTS="$ROOT/android/build/nav-artifacts"

BUILD=1
WEB_FACE=0
for arg in "$@"; do
  case "$arg" in
    --no-build) BUILD=0 ;;
    --web-face) WEB_FACE=1 ;;
    -h|--help) sed -n '3,27p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

export ANDROID_HOME JAVA_HOME
export PATH="$JAVA_HOME/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH"

say() { printf '\n== %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ -n "${ANDROID_HOME:-}" ] || die "no ANDROID_HOME and android/local.properties has no sdk.dir"
command -v adb >/dev/null 2>&1 || die "adb not found under $ANDROID_HOME"
command -v python3 >/dev/null 2>&1 || die "python3 is required to parse the UI dump"

# ---------------------------------------------------------------- device
say "device"
if [ -z "${SERIAL:-}" ]; then SERIAL="${ANDROID_SERIAL:-}"; fi
if [ -z "${SERIAL:-}" ]; then
  SERIAL="$(adb devices | awk '/^emulator-[0-9]+[[:space:]]+device$/ {print $1; exit}')"
fi
[ -n "${SERIAL:-}" ] || die "no attached emulator; start one with android/tools/run-demo.sh first"
export ANDROID_SERIAL="$SERIAL"
adb() { command adb ${SERIAL:+-s "$SERIAL"} "$@"; }
echo "device: $SERIAL ($(adb shell getprop ro.product.cpu.abi | tr -d '\r'))"

mkdir -p "$ARTIFACTS"

# ---------------------------------------------------------------- build
APK="$ROOT/android/app/build/outputs/apk/debug/app-debug.apk"
if [ "$BUILD" = "1" ]; then
  say "build :app"
  ( cd "$ROOT/android" && ./gradlew :app:assembleDebug --no-daemon --console=plain ) \
    || die "the APK did not build"
fi
[ -f "$APK" ] || die "no APK at android/app/build/outputs/apk/debug/app-debug.apk (run without --no-build)"

# ---------------------------------------------------------------- helpers
UI_DUMP="$ARTIFACTS/ui.xml"
STATUS=0

dump() {
  adb shell uiautomator dump /sdcard/pdsh-nav.xml >/dev/null 2>&1 || true
  adb pull /sdcard/pdsh-nav.xml "$UI_DUMP" >/dev/null 2>&1 || true
}

# `ui has <needle>` exits 0 when any text or content-desc contains <needle>;
# `ui center <needle>` prints the tap point of the first exact (then partial) hit.
ui() {
  python3 - "$UI_DUMP" "$1" "$2" <<'PY'
import sys
import xml.etree.ElementTree as ET

path, mode, needle = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    root = ET.parse(path).getroot()
except Exception:
    sys.exit(2)

def values(node):
    return ((node.get("text") or "").strip(), (node.get("content-desc") or "").strip())

if mode == "has":
    for node in root.iter("node"):
        for value in values(node):
            if needle in value:
                sys.exit(0)
    sys.exit(1)

if mode == "center":
    for exact in (True, False):
        for node in root.iter("node"):
            for value in values(node):
                hit = value == needle if exact else needle in value
                if not hit:
                    continue
                bounds = node.get("bounds") or ""
                try:
                    left_top, right_bottom = bounds.split("][")
                    left, top = left_top.lstrip("[").split(",")
                    right, bottom = right_bottom.rstrip("]").split(",")
                    print((int(left) + int(right)) // 2, (int(top) + int(bottom)) // 2)
                except Exception:
                    print("")
                sys.exit(0)
    sys.exit(1)

sys.exit(2)
PY
}

pass_line() { echo "PASS $*"; }
fail_line() { echo "FAIL $*"; STATUS=1; }

# `expect <label> <needle>`: the current screen must show <needle>.
expect() {
  dump
  if ui has "$2"; then pass_line "$1: shows '$2'"; else fail_line "$1: no '$2' on screen"; fi
}

# `expect_any <label> <needle>...`: the current screen must show one of them.
expect_any() {
  local label="$1"
  shift
  dump
  for needle in "$@"; do
    if ui has "$needle"; then pass_line "$label: shows '$needle'"; return 0; fi
  done
  fail_line "$label: none of $* on screen"
}

# `expect_disabled <label> <needle>`: every node matching <needle> must be
# disabled. Compose renders a disabled `clickable` as enabled="false" in the
# uiautomator dump, which is how the script proves the control is not just inert.
expect_disabled() {
  dump
  if python3 - "$UI_DUMP" "$2" <<'PY2'
import sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()
needle = sys.argv[2]
hits = []
for node in root.iter("node"):
    for value in ((node.get("text") or "").strip(), (node.get("content-desc") or "").strip()):
        if needle in value:
            hits.append(node.get("enabled"))
if hits and all(hit == "false" for hit in hits):
    sys.exit(0)
sys.exit(1)
PY2
  then
    pass_line "$1: '$2' is disabled"
  else
    fail_line "$1: '$2' is not disabled"
  fi
}

# `tap <text|content-desc>`: tap the centre of the first matching node.
tap() {
  dump
  local point
  point="$(ui center "$1")"
  if [ -z "$point" ]; then
    fail_line "tap: no node '$1' on screen"
    return 1
  fi
  adb shell input tap $point >/dev/null
  sleep 1.2
}

# `back` prefers the page's own header back control (content-desc 返回) and falls
# back to the system back key only where the page has no header (the full-screen
# DSH surface). The header control is the path a person takes; the key event is
# the platform path and is kept for the surface, which has no header by design.
back() {
  dump
  local point
  point="$(ui center "返回")"
  if [ -n "$point" ]; then
    adb shell input tap $point >/dev/null
  else
    adb shell input keyevent 4 >/dev/null
  fi
  sleep 1
}

# ---------------------------------------------------------------- install
say "install"
adb install -r -t "$APK" >/dev/null || die "adb install failed"

say "launch (no extras: an unmeasured fact must render 未知)"
COMPONENT="$(adb shell cmd package resolve-activity --brief "$PACKAGE" 2>/dev/null \
  | tr -d '\r' | tail -1)"
[ -n "$COMPONENT" ] || die "could not resolve the launcher activity of $PACKAGE"
adb shell am force-stop "$PACKAGE" >/dev/null
adb logcat -c
adb shell am start -W -n "$COMPONENT" >/dev/null

# The probe screen is the launch face; wait for it before tapping anything.
READY=0
for _ in $(seq 1 30); do
  dump
  if ui has "跑一轮"; then READY=1; break; fi
  sleep 1
done
[ "$READY" = "1" ] || die "the native face never rendered (is the APK the probe app?)"
pass_line "launch: the native face renders 跑一轮"

# ---------------------------------------------------------------- entries
#
# Each entry starts from a fresh launch of the native face. That costs a few
# seconds per entry but keeps the script independent of the previous entry's
# navigation state: a page that cannot be left with one gesture would otherwise
# poison every later assertion. `back()` is kept for the one route that has no
# header (the full-screen DSH surface).
start_app() {
  adb shell am force-stop "$PACKAGE" >/dev/null
  adb shell am start -W -n "$COMPONENT" >/dev/null
  local ready=0
  for _ in $(seq 1 30); do
    dump
    if ui has "跑一轮"; then ready=1; break; fi
    sleep 1
  done
  [ "$ready" = "1" ]
}

open_settings() {
  tap "我的" && tap "设置"
}

say "entry: 抽屉「工作文件夹」 → WorkspaceFoldersPage"
tap "打开抽屉" && expect "drawer" "工作文件夹"
tap "工作文件夹"
expect "workspace page" "工作文件夹"
expect "workspace page" "宿主未提供写命令：本页只读"
# The baseline's toolbar verb is 添加 (NativeShell.swift:376), and the empty-state
# carries the longer 添加工作文件夹 call to action.
expect_disabled "workspace page" "添加"
expect "workspace note" "只读：本宿主未实现文件夹的新建、切换、删除"

say "entry: 抽屉「文件」 → FilesPage"
# The files page had no touch entry in the App: the workspace-folders row it
# normally hangs from is drawn disabled while that page is read-only. This drawer
# row is the direct read entry; on a fresh install the workspace tree may not have
# been materialized yet, so both honest states are accepted.
start_app && tap "打开抽屉" && tap "文件"
expect "files page" "手机工作区"
expect_any "files page" "还没有文件" "等待引擎连接…"

say "entry: 我的 › 定时任务 → NativeAutomationPage"
start_app && tap "我的" && tap "定时任务"
expect "automation page" "定时任务"
expect "automation page" "定时任务状态未知"

say "entry: 页头 ⋯ → NativeConfigurationPage (sheet)"
start_app && tap "本会话设置"
expect "configuration page" "本会话设置"
expect "configuration page" "只读"
expect "configuration page" "完成"

say "entry: 页头运行状态点 → RuntimeDetailsPage (sheet)"
start_app && tap "运行状态"
expect "runtime page" "运行时详情"
expect "runtime page" "WebView"

say "entry: 我的 › 设置 → SettingsPage"
start_app && open_settings
expect "settings page" "设置"
expect "settings page" "网络访问"

say "entry: 我的 › 模型服务 → ModelProviderSettingsPage"
start_app && tap "我的" && tap "模型服务"
expect "provider page" "模型服务"
expect "provider page" "DeepSeek（本机）"
expect "provider note" "本宿主未接入模型服务的编辑与保存"
expect "provider page" "宿主未提供写命令：本页只读"
expect_disabled "provider page" "添加"

say "entry: 发现 › 网页搜索 → WebSearchSettingsPage"
start_app && tap "发现" && tap "网页搜索" && tap "设置网页搜索"
expect "websearch page" "网页搜索"
expect "websearch page" "网页搜索状态未知"
# The web-search page has no readable backend list on this host, so it renders
# its unknown state and has no control to disable; the host note above it still
# states the read/write gap. The writable fact is wired for a host that can read.
expect "websearch note" "只读：本宿主未实现网页搜索的读取与保存"

say "entry: 设置内 → MCPSettingsPage, then MCPEditorPage from the list"
start_app && open_settings && tap "MCP"
expect "mcp page" "MCP 服务器"
expect "mcp page" "MCP 服务器状态未知"
tap "添加"
expect "mcp editor" "添加 MCP 服务器"
expect "mcp editor note" "保存会提交给宿主；本宿主未实现持久化"
expect "mcp editor handoff" "保存会提交给宿主；本宿主未实现持久化"

say "entry: 设置内「网络访问」 → EgressAllowListPage"
start_app && open_settings && tap "网络访问"
expect "egress page" "出网白名单"
expect "egress page" "白名单状态未知"
expect "egress note" "本机 App 的出网规则（不是 DSH 设置里的白名单）"

say "entry: 抽屉「DSH 页面」 → WebSurfacePage"
start_app && tap "打开抽屉" && tap "DSH 页面"
expect_any "web surface page" "DSH Web 页面" "DSH 页面"
back
expect "web surface back" "跑一轮"

# ---------------------------------------------------------------- optional
if [ "$WEB_FACE" = "1" ]; then
  say "entry: 引擎就绪时的默认面 (pdsh.face.web)"
  adb shell am force-stop "$PACKAGE" >/dev/null
  adb shell am start -W -n "$COMPONENT" --ez pdsh.face.web true >/dev/null
  WEB_FACE_OK=0
  for _ in $(seq 1 60); do
    dump
    if ui has "DSH Web 页面"; then WEB_FACE_OK=1; break; fi
    sleep 2
  done
  if [ "$WEB_FACE_OK" = "1" ]; then
    pass_line "web face: the engine-ready default face is the live DSH surface"
  else
    fail_line "web face: the DSH surface never became live (engine not ready?)"
  fi
fi

say "receipt"
echo "device: $SERIAL (emulator; not a physical device)"
echo "launch: no upstream, no egress grant (every 未知 line above is a missing host read)"
echo "artifacts: $ARTIFACTS"
if [ "$STATUS" = "0" ]; then
  echo "NAV_ENTRIES_OK"
else
  echo "NAV_ENTRIES_FAILED"
fi
exit "$STATUS"
