#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# The seven product steps a person performs on the phone, as one reproducible
# command:
#
#   1  保存 key       设置 → 模型服务 → 编辑 → 保存（key 由运行时生成, 不落仓库）
#   2  新建会话       会话列表 → 新建会话
#   3  流式正文       输入一句话 → 生成中与完成后的 dump 不同且更长
#   4  选 CSV 进工作区 选一个文件 → run-as 能看到它且字节数一致
#   5  模型处理它     回答里含 CSV 的具体数字（夹具从工具输出解析, 不是常量）
#   6  预览 / 分享产物 产物页 → 预览里有那个数字 → 分享拉起系统选择器
#   7  冷启动          force-stop 前后 pid 不同, 重开会话原消息还在
#
# Every step is independent (`--step 3`), prints exactly one `PASS/FAIL 步骤N:`
# line, keeps its scene on failure (dump + PNG + logcat tail) and the process
# exits non-zero when any requested step fails. A failing step is the product
# of this script: it names the assertion, the measured value and the evidence
# it looked at.
#
# The model is a SCRIPT (`fixtures/scripted-acceptance-upstream.py`), not a
# model: the run never carries a real credential and never calls an inference
# service. The key the step 1 form receives is generated per run, stored only in
# the App's Keystore-backed store on the device, and recorded in the report by
# SHA-256 only.
#
# Usage:
#   bash android/tools/acceptance/run-product-flow.sh                 # all seven
#   bash android/tools/acceptance/run-product-flow.sh --step 3        # one step
#   bash android/tools/acceptance/run-product-flow.sh --step 1 --no-build
#   bash android/tools/acceptance/run-product-flow.sh --list-steps
#
# Environment:
#   ANDROID_HOME   (default: android/local.properties sdk.dir)
#   JAVA_HOME      (default: derived from `java` on PATH)
#   TMPDIR         the report and the kept scenes land under it
#   PDSH_ACCEPT_REPORT / PDSH_ACCEPT_BASE  override those paths
#
# Device: this script only ever drives `emulator-<--port>` (default 5738) and
# refuses a serial that belongs to another lane (5556/5558/5670-5736) unless
# `--serial` says so explicitly.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
ACCEPT_DIR="$ROOT/android/tools/acceptance"
FIXTURES="$ACCEPT_DIR/fixtures"
UI_PY="$ACCEPT_DIR/lib/ui.py"
CSV_NAME="orders.csv"
SUMMARY_NAME="orders-summary.md"
PACKAGE="com.phonedsh.app"

MODE="all"
STEP=""                 # the single requested step, when MODE=single
EMU_PORT="${PDSH_ACCEPT_EMULATOR_PORT:-5738}"
AVD="${PDSH_ACCEPT_AVD:-pdsh-acc35}"
UPSTREAM_PORT="${PDSH_ACCEPT_UPSTREAM_PORT:-8787}"
EXPLICIT_SERIAL="${PDSH_ACCEPT_SERIAL:-}"
BUILD=""                # "" = build only when the APK is missing
KEEP=0
FAIL_FAST=0
VERBOSE=0
STREAM_TIMEOUT="${PDSH_ACCEPT_STREAM_TIMEOUT:-120}"
ANSWER_TIMEOUT="${PDSH_ACCEPT_ANSWER_TIMEOUT:-180}"

BASE="${PDSH_ACCEPT_BASE:-${TMPDIR:-/tmp}/pdsh-acceptance}"
BASE="$(printf '%s' "$BASE" | sed -e 's://*:/:g' -e 's:/*$::')"
REPORT="${PDSH_ACCEPT_REPORT:-$BASE/acceptance-report.md}"
STATE_FILE="$BASE/state.sh"
RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
RUN_DIR="$BASE/$RUN_ID"
RUN_TAG="$(date +%H%M%S)"

STREAM_MARK="流式验收"
STREAM_END="[STREAM-END]"

PASS_COUNT=0
FAIL_COUNT=0
FAILED_ANY=0
EV=""                   # one-sentence evidence of the step being run
UPSTREAM_PID=""
SERIAL=""
APP_APK=""

usage() {
   cat <<'EOF'
usage: bash android/tools/acceptance/run-product-flow.sh [options]

Runs the seven product steps against a device and prints one PASS/FAIL line per
step. Exit code 0 only when every requested step passed.

  --step N          run only step N (1..7). Steps reuse what earlier steps left
                    on the device; --step 1 starts from a cleared App.
  --all             run all seven in order (the default); continues after a
                    failure so the report shows every step's state.
  --fail-fast       stop at the first failing step.
  --list-steps      print the seven steps and the assertion each one makes.

  --build           force a Gradle :app:assembleDebug before installing.
  --no-build        never build; fail when there is no APK.
                    (default: build only when the APK is absent)
  --serial SERIAL   pin one adb serial (default: emulator-<--port>).
  --port N          emulator console port for the dedicated AVD (default 5738).
  --avd NAME        AVD to boot when nothing is attached on that port
                    (default pdsh-acc35).
  --upstream-port N host port of the scripted upstream, and the port the saved
                    model service points at (default 8787).
  --report PATH     report path (default $TMPDIR/pdsh-acceptance/acceptance-report.md).
  --timeout N       seconds to wait for one streamed answer / one model answer
                    (PDSH_ACCEPT_STREAM_TIMEOUT / ANSWER_TIMEOUT run separately).
  --keep            keep the scene directory even when every step passed.
  --verbose         echo every adb command's output.
  -h, --help        this text.

What the assertions actually read (none of them is "the tap happened"):

  1  the provider page shows 已配置 + the key's last four digits; the device
     record files/settings/model-provider.v1.properties contains the endpoint;
     no_backup/secure-store/*.bin exists and its bytes do NOT contain the key;
     a force-stop + relaunch still shows a configured provider.
  2  the count of session rows (^新会话( N)?$) grows after the tap and stays
     after leaving the page.
  3  dumps sampled while the answer is being written show the fixture's marker
     text growing at least twice, the final dump is longer than every mid
     sample, and the credential header the upstream received hashes to the key
     step 1 saved.
  4  the picker was a system picker, and the file the App kept has exactly the
     fixture's byte count inside the materialized workspace.
  5  the answer text on screen contains the amount total the script computed
     from fixtures/orders.csv, and the upstream's audit line reports the same
     row count / total / rows digest — computed from the tool RESULT, not from
     a constant (the fixture source is grepped for the number and must not
     contain it).
  6  the artifact exists in the workspace with the total inside, the artifacts
     page lists it, the preview shows the total, and tapping 分享 brings a
     system chooser to the foreground.
  7  pidof before force-stop differs from pidof after the relaunch, and the
     reopened session's dump still contains the original message text and the
     answer's number.
EOF
}

list_steps() {
   cat <<'EOF'
1 保存 key          断言: 页面「已配置」+ 设备记录含端点 + 密文存在且无明文 + 冷启动后仍已配置
2 新建会话          断言: 会话行数 ^新会话( N)?$ 由 0 增至 >=1 且离开后仍在
3 流式正文          断言: 生成中 dump 里正文至少增长两次, 完成态更长且含 [STREAM-END]
4 选 CSV 进工作区  断言: 系统选择器选中后 run-as 找得到该文件且字节数 == 夹具字节数
5 模型处理它        断言: 回答含脚本自算的合计; 夹具审计的 rows/total/rows_digest 一致
6 预览 / 分享产物  断言: 产物文件含合计 + 预览显示合计 + 分享拉起系统选择器
7 冷启动            断言: force-stop 前后 pid 不同 + 重开会话 dump 含原消息与回答数字
EOF
}

say() { printf '\n== %s\n' "$*"; }
info() { printf '   %s\n' "$*"; }
verbose() { [ "$VERBOSE" = 1 ] && printf '   [adb] %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }

# ---------------------------------------------------------------- arguments
while [ $# -gt 0 ]; do
   case "$1" in
      --step) [ $# -ge 2 ] || die "--step needs a value"; STEP="$2"; MODE="single"; shift 2 ;;
      --step=*) STEP="${1#--step=}"; MODE="single"; shift ;;
      --all) MODE="all"; STEP=""; shift ;;
      --list-steps) list_steps; exit 0 ;;
      --build) BUILD=1; shift ;;
      --no-build) BUILD=0; shift ;;
      --serial) [ $# -ge 2 ] || die "--serial needs a value"; EXPLICIT_SERIAL="$2"; shift 2 ;;
      --serial=*) EXPLICIT_SERIAL="${1#--serial=}"; shift ;;
      --port) [ $# -ge 2 ] || die "--port needs a value"; EMU_PORT="$2"; shift 2 ;;
      --avd) [ $# -ge 2 ] || die "--avd needs a value"; AVD="$2"; shift 2 ;;
      --upstream-port) [ $# -ge 2 ] || die "--upstream-port needs a value"; UPSTREAM_PORT="$2"; shift 2 ;;
      --upstream-port=*) UPSTREAM_PORT="${1#--upstream-port=}"; shift ;;
      --report) [ $# -ge 2 ] || die "--report needs a value"; REPORT="$2"; shift 2 ;;
      --timeout) [ $# -ge 2 ] || die "--timeout needs a value"; STREAM_TIMEOUT="$2"; ANSWER_TIMEOUT="$2"; shift 2 ;;
      --keep) KEEP=1; shift ;;
      --fail-fast) FAIL_FAST=1; shift ;;
      --verbose) VERBOSE=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) printf 'unknown argument: %s (see --help)\n' "$1" >&2; exit 2 ;;
   esac
done

if [ "$MODE" = "single" ]; then
   case "$STEP" in 1|2|3|4|5|6|7) : ;; *) die "--step must be 1..7 (got: $STEP)" ;; esac
fi
if [ -n "$EXPLICIT_SERIAL" ]; then
   # Never silently share another lane's emulator: 5556/5558/5670-5736 belong to
   # other lanes. An explicit --serial is the only way in.
   case "$EXPLICIT_SERIAL" in
      emulator-5556|emulator-5558) info "warning: $EXPLICIT_SERIAL is another lane's device (explicit --serial given)" ;;
      emulator-*) info "device pinned explicitly: $EXPLICIT_SERIAL" ;;
   esac
fi

# ---------------------------------------------------------------- environment
ANDROID_HOME="${ANDROID_HOME:-$(sed -n 's/^sdk\.dir=//p' "$ROOT/android/local.properties" 2>/dev/null | head -1)}"
[ -n "${ANDROID_HOME:-}" ] || die "no ANDROID_HOME and android/local.properties carries no sdk.dir"
if [ -z "${JAVA_HOME:-}" ] && command -v java >/dev/null 2>&1; then
   JAVA_HOME="$(cd "$(dirname "$(command -v java)")/.." && pwd)"
fi
export ANDROID_HOME
[ -n "${JAVA_HOME:-}" ] && export JAVA_HOME
export PATH="${JAVA_HOME:+$JAVA_HOME/bin:}$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:${PATH}"
command -v adb >/dev/null 2>&1 || die "adb not found under $ANDROID_HOME"
command -v python3 >/dev/null 2>&1 || die "python3 is required (UI dump parsing and the fixture)"
[ -f "$UI_PY" ] || die "missing $UI_PY"
[ -f "$FIXTURES/$CSV_NAME" ] || die "missing $FIXTURES/$CSV_NAME"
[ -f "$FIXTURES/scripted-acceptance-upstream.py" ] || die "missing the scripted upstream"

mkdir -p "$RUN_DIR" || die "cannot create $RUN_DIR"

# ---------------------------------------------------------------- tiny utils
adb_c() { command adb -s "$SERIAL" "$@" 2>/dev/null; }
adb_raw() { command adb -s "$SERIAL" "$@"; }

sha256_text() { printf '%s' "$1" | python3 -c 'import hashlib,sys;sys.stdout.write(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'; }

random_key() {
   # A key-shaped value generated per run. It is never written to a file of this
   # repository; it exists in this shell, in the App's Keystore-backed store, and
   # as a SHA-256 in the report.
   python3 -c 'import secrets,sys;sys.stdout.write("skaccept" + secrets.token_hex(12))'
}

cpu_abi() { adb_c shell getprop ro.product.cpu.abi | tr -d '\r'; }
android_release() { adb_c shell getprop ro.build.version.release | tr -d '\r'; }
app_pid() { adb_c shell pidof "$PACKAGE" | tr -d '\r'; }
app_installed() { [ -n "$(adb_c shell pm path "$PACKAGE" | tr -d '\r')" ]; }
device_size() { adb_c shell run-as "$PACKAGE" stat -c %s "$1" | tr -d '\r'; }
device_find() { adb_c shell run-as "$PACKAGE" find files -name "$1" -type f | tr -d '\r'; }

focus_line() { adb_c shell dumpsys window 2>/dev/null | grep -m1 "mCurrentFocus" || true; }

# ---------------------------------------------------------------- UI helpers
UI_XML=""

ui_dump() {
   local out="${1:-$RUN_DIR/last.xml}" tries=0
   while [ "$tries" -lt 3 ]; do
      adb_c shell uiautomator dump /sdcard/pdsh-accept-window.xml >/dev/null
      adb_c exec-out cat /sdcard/pdsh-accept-window.xml >"$out" 2>/dev/null
      if [ -s "$out" ] && grep -q "<hierarchy" "$out"; then UI_XML="$out"; return 0; fi
      tries=$((tries + 1)); sleep 0.3
   done
   UI_XML="$out"
   return 1
}

ui_find() { python3 "$UI_PY" find "$UI_XML" "$@" 2>/dev/null; }
ui_has() { python3 "$UI_PY" has "$UI_XML" "$@" >/dev/null 2>&1; }
ui_count_rows() { python3 "$UI_PY" count "$UI_XML" --regex "$1" --field text 2>/dev/null || printf '0'; }

ui_tap_xy() { adb_c shell input tap "$1" "$2"; }

ui_tap() { # substring match on text or content-desc
   local xy
   ui_dump "$RUN_DIR/last.xml" || return 1
   xy="$(ui_find --text "$1")"
   [ -n "$xy" ] || return 1
   verbose "tap 「$1」 at $xy"
   # shellcheck disable=SC2086
   ui_tap_xy $xy
}

ui_tap_exact() {
   local xy
   ui_dump "$RUN_DIR/last.xml" || return 1
   xy="$(ui_find --text "$1" --exact)"
   [ -n "$xy" ] || return 1
   verbose "tap 「$1」 (exact) at $xy"
   # shellcheck disable=SC2086
   ui_tap_xy $xy
}

ui_wait() { # text, seconds
   local want="$1" secs="$2" end=$((SECONDS + ${2:-20}))
   while [ "$SECONDS" -lt "$end" ]; do
      if ui_dump "$RUN_DIR/last.xml" && ui_has --text "$want"; then return 0; fi
      sleep 0.6
   done
   return 1
}

ui_type() {
   local text="$1" escaped
   escaped="${text// /%s}"
   adb_c shell input text "$escaped" >/dev/null
}

ui_hide_ime() {
   # A soft keyboard swallows a swipe (glide typing even turns it into letters),
   # so the editor is scrolled only after the IME is gone. BACK closes the IME
   # first and only then reaches the page, which is why the page is re-checked
   # by the caller instead of assumed.
   if adb_c shell dumpsys input_method 2>/dev/null | grep -q "mInputShown=true"; then
      adb_c shell input keyevent 4 >/dev/null
      sleep 0.8
   fi
}

ui_swipe_content() { # down = reveal lower content, up = back to the top
   local dir="$1" xy cx cy y_end
   xy=""
   if ui_dump "$RUN_DIR/last.xml"; then
      xy="$(python3 "$UI_PY" drag-gap "$UI_XML" --ymin 620 --ymax 1500 2>/dev/null)"
   fi
   [ -n "${xy:-}" ] || xy="540 1100"
   cx="${xy%% *}"; cy="${xy##* }"
   if [ "$dir" = "down" ]; then
      y_end=$((cy - 620))
      [ "$y_end" -lt 120 ] && y_end=120
   else
      y_end=$((cy + 620))
      [ "$y_end" -gt 2280 ] && y_end=2280
   fi
   verbose "swipe $dir from $cx,$cy to $cx,$y_end"
   adb_c shell input swipe "$cx" "$cy" "$cx" "$y_end" 250 >/dev/null
}

ui_scroll_until() { # text, tries, down|up, [exact]
   local want="$1" tries="${2:-6}" dir="${3:-down}" exact="${4:-}" i=0 found=""
   ui_hide_ime
   while [ "$i" -lt "$tries" ]; do
      if ui_dump "$RUN_DIR/last.xml"; then
         if [ -n "$exact" ]; then found="$(ui_find --text "$want" --exact)"; else found="$(ui_find --text "$want")"; fi
         [ -n "$found" ] && return 0
      fi
      ui_swipe_content "$dir"
      i=$((i + 1)); sleep 0.4
   done
   ui_dump "$RUN_DIR/last.xml" || return 1
   if [ -n "$exact" ]; then found="$(ui_find --text "$want" --exact)"; else found="$(ui_find --text "$want")"; fi
   [ -n "$found" ]
}

field_under() { # label -> "x y"
   local xy
   ui_dump "$RUN_DIR/last.xml" || return 1
   xy="$(python3 "$UI_PY" field-under "$UI_XML" --label "$1" 2>/dev/null)"
   [ -n "$xy" ] || return 1
   printf '%s' "$xy"
}

scene() { # step number
   local n="$1" tag="step$1-fail"
   ui_dump "$RUN_DIR/$tag.xml" || true
   adb_c exec-out screencap -p >"$RUN_DIR/$tag.png" 2>/dev/null || true
   adb_raw logcat -d -v time >"$RUN_DIR/$tag-logcat.txt" 2>/dev/null || true
   if [ -s "$RUN_DIR/$tag-logcat.txt" ]; then
      grep -E "PDSH|AndroidRuntime|FATAL" "$RUN_DIR/$tag-logcat.txt" | tail -12 >&2 || true
   fi
   printf '   现场: %s\n' "$RUN_DIR/$tag.{xml,png} + $tag-logcat.txt" >&2
}

# ---------------------------------------------------------------- state
S_KEY=""; S_KEY_SHA=""; S_LAST4=""; S_URL=""; S_APK_SHA=""; S_APK_SHA_INSTALLED=""
S_PROMPT=""; S_CSV_PROMPT=""; S_SESSION_TITLE=""; S_ANSWER=""
S_EXPECTED_ROWS=""; S_EXPECTED_TOTAL=""; S_CSV_BYTES=""; S_CSV_DIGEST=""
R_1=""; R_2=""; R_3=""; R_4=""; R_5=""; R_6=""; R_7=""
E_1=""; E_2=""; E_3=""; E_4=""; E_5=""; E_6=""; E_7=""

load_state() {
   [ -f "$STATE_FILE" ] || return 0
   # shellcheck disable=SC1090
   . "$STATE_FILE" 2>/dev/null || true
}

save_state() {
   mkdir -p "$BASE" 2>/dev/null || true
   {
      printf 'S_KEY=%q\n' "${S_KEY:-}"
      printf 'S_KEY_SHA=%q\n' "${S_KEY_SHA:-}"
      printf 'S_LAST4=%q\n' "${S_LAST4:-}"
      printf 'S_URL=%q\n' "${S_URL:-}"
      printf 'S_APK_SHA=%q\n' "${S_APK_SHA:-}"
      printf 'S_APK_SHA_INSTALLED=%q\n' "${S_APK_SHA_INSTALLED:-}"
      printf 'S_PROMPT=%q\n' "${S_PROMPT:-}"
      printf 'S_CSV_PROMPT=%q\n' "${S_CSV_PROMPT:-}"
      printf 'S_SESSION_TITLE=%q\n' "${S_SESSION_TITLE:-}"
      printf 'S_ANSWER=%q\n' "${S_ANSWER:-}"
      printf 'S_EXPECTED_ROWS=%q\n' "${S_EXPECTED_ROWS:-}"
      printf 'S_EXPECTED_TOTAL=%q\n' "${S_EXPECTED_TOTAL:-}"
      printf 'S_CSV_BYTES=%q\n' "${S_CSV_BYTES:-}"
      printf 'S_CSV_DIGEST=%q\n' "${S_CSV_DIGEST:-}"
      for i in 1 2 3 4 5 6 7; do
         eval "printf 'R_$i=%q\\n' \"\${R_$i:-}\""
         eval "printf 'E_$i=%q\\n' \"\${E_$i:-}\""
      done
   } >"$STATE_FILE" 2>/dev/null || true
}

csv_stats() {
   python3 - "$FIXTURES/$CSV_NAME" <<'PY'
import decimal, hashlib, sys
path = sys.argv[1]
raw = open(path, "rb").read()
lines = raw.decode("utf-8").splitlines()
header = [cell.strip() for cell in lines[0].split(",")]
index = header.index("amount")
total = decimal.Decimal("0")
rows = []
for line in lines[1:]:
    if not line.strip():
        continue
    cells = [cell.strip() for cell in line.split(",")]
    total += decimal.Decimal(cells[index])
    rows.append(",".join(cells))
print(len(rows), total.quantize(decimal.Decimal("0.01")), len(raw),
      hashlib.sha256(("\n".join(rows) + "\n").encode()).hexdigest() if rows else "-")
PY
}

# ---------------------------------------------------------------- device prep
ensure_device() {
   if [ -n "$EXPLICIT_SERIAL" ]; then
      SERIAL="$EXPLICIT_SERIAL"
   else
      SERIAL="emulator-$EMU_PORT"
   fi
   if [ "$(adb_c shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; then
      info "device: $SERIAL (already booted)"
      return 0
   fi
   adb start-server >/dev/null 2>&1 || true
   if ! "$ANDROID_HOME/emulator/emulator" -list-avds 2>/dev/null | grep -qx "$AVD"; then
      printf 'ERROR: AVD %s does not exist. Create it once, or pin a running device with --serial.\n' "$AVD" >&2
      printf '       avdmanager create avd -n %s -k "system-images;android-35;google_apis;arm64-v8a"\n' "$AVD" >&2
      exit 2
   fi
   info "device: $SERIAL is not booted; starting AVD $AVD on port $EMU_PORT"
   "$ANDROID_HOME/emulator/emulator" -avd "$AVD" -port "$EMU_PORT" \
      -no-window -no-audio -no-boot-anim -no-snapshot -gpu swiftshader_indirect \
      >"$RUN_DIR/emulator.log" 2>&1 &
   local end=$((SECONDS + 300))
   while [ "$SECONDS" -lt "$end" ]; do
      if [ "$(adb_c shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; then
         info "device: $SERIAL booted"
         return 0
      fi
      sleep 3
   done
   die "the AVD $AVD did not boot on port $EMU_PORT within 300s (log: $RUN_DIR/emulator.log)"
}

ensure_apk() {
   APP_APK="$ROOT/android/app/build/outputs/apk/debug/app-debug.apk"
   if [ "${BUILD:-}" = "0" ]; then
      [ -f "$APP_APK" ] || die "--no-build was given but there is no APK at ${APP_APK#"$ROOT"/}"
      return 0
   fi
   if [ "${BUILD:-}" = "1" ] || [ ! -f "$APP_APK" ]; then
      say "build :app (Gradle)"
      ( cd "$ROOT/android" && ./gradlew :app:assembleDebug --no-daemon --console=plain ) \
         || die "the Gradle build failed; the acceptance cannot run against an APK that was not built"
   fi
   [ -f "$APP_APK" ] || die "no APK at ${APP_APK#"$ROOT"/}"
}

ensure_app() {
   # The APK is the thing under test, so a changed APK must be installed: a
   # previous run's install is not evidence about today's build. The identity is
   # recorded in the state file so a second --step invocation does not reinstall
   # the same bytes.
   local want have
   want="$(python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest()[:16])' "$APP_APK")"
   S_APK_SHA="$want"
   have="$(printf '%s' "${S_APK_SHA_INSTALLED:-}" | tr -d "'\"")"
   if app_installed && [ "$have" = "$want" ]; then
      info "app: already installed (APK $want)"
      return 0
   fi
   say "install $PACKAGE (APK $want)"
   adb_raw install -r -t "$APP_APK" >/dev/null || die "adb install failed"
   S_APK_SHA_INSTALLED="$want"
}

component() {
   adb_c shell cmd package resolve-activity --brief "$PACKAGE" | tr -d '\r' | tail -1
}

launch_app() {
   local which
   which="$(component)"
   [ -n "$which" ] || die "could not resolve the launcher activity of $PACKAGE"
   adb_c shell am start -W -n "$which" >/dev/null || die "am start failed"
   # A pure product launch: no pdsh.* extras at all. The endpoint the App talks
   # to is the one step 1 saved, which is the point of that step.
}

start_upstream() {
   say "scripted upstream on 127.0.0.1:$UPSTREAM_PORT"
   python3 "$FIXTURES/scripted-acceptance-upstream.py" --port "$UPSTREAM_PORT" \
      --csv-name "$CSV_NAME" >"$RUN_DIR/upstream.log" 2>&1 &
   UPSTREAM_PID=$!
   local i=0
   while [ "$i" -lt 60 ]; do
      if grep -q "^LISTENING " "$RUN_DIR/upstream.log" 2>/dev/null; then
         info "upstream: host process $UPSTREAM_PID, adb reverse tcp:$UPSTREAM_PORT"
         adb_c reverse "tcp:$UPSTREAM_PORT" "tcp:$UPSTREAM_PORT" >/dev/null
         return 0
      fi
      sleep 0.2; i=$((i + 1))
   done
   die "the scripted upstream did not start on port $UPSTREAM_PORT (see $RUN_DIR/upstream.log)"
}

cleanup() {
   if [ -n "$UPSTREAM_PID" ]; then
      kill "$UPSTREAM_PID" 2>/dev/null || true
      adb_c reverse --remove "tcp:$UPSTREAM_PORT" >/dev/null 2>&1 || true
   fi
   save_state
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# ---------------------------------------------------------------- navigation
ensure_home() {
   local end=$((SECONDS + 45))
   while [ "$SECONDS" -lt "$end" ]; do
      if ui_dump "$RUN_DIR/last.xml"; then
         # iOS's sessions surface has no page-title row. Identify its two real
         # controls so a correct title-less list is not mistaken for a failure.
         if ui_has --text "搜索会话" --exact && ui_has --text "新建会话" --exact; then return 0; fi
         if ui_has --text "重试本地引擎" || ui_has --text "启动本地引擎"; then
            ui_tap_exact "启动本地引擎" >/dev/null 2>&1 || true
         fi
      fi
      sleep 1
   done
   return 1
}

open_session() {
   local title="${S_SESSION_TITLE:-新会话}"
   if ui_tap_exact "$title"; then return 0; fi
   if ui_tap_exact "新会话"; then return 0; fi
   # The newest row may carry a suffix (新会话 2 …): take the first row that is
   # not the 新建会话 control.
   if ui_dump "$RUN_DIR/last.xml"; then
      local line
      line="$(ui_find --text "新会话")"
      if [ -n "$line" ]; then
         # shellcheck disable=SC2086
         ui_tap_xy $line
         return 0
      fi
   fi
   return 1
}

wait_chat() {
   local end=$((SECONDS + 30))
   while [ "$SECONDS" -lt "$end" ]; do
      if ui_dump "$RUN_DIR/last.xml"; then
         if ui_has --text "发送消息" --exact || ui_has --text "发消息或创建任务"; then return 0; fi
      fi
      sleep 1
   done
   return 1
}

go_home() {
   # A conversation is a pushed route: BACK is what the product offers to leave
   # it, and the sessions list is what it lands on.
   if ui_dump "$RUN_DIR/last.xml" && ui_has --text "发送消息" --exact; then
      adb_c shell input keyevent 4 >/dev/null
      sleep 1.5
   fi
   ensure_home
}

channel_note() {
   # A host whose channel dies after HELLO cannot start a turn at all. Naming
   # that here keeps "the model answered badly" from being blamed for a
   # transport that never carried the request.
   local log="$RUN_DIR/logcat-step.txt" count
   adb_raw logcat -d -v brief >"$log" 2>/dev/null || return 0
   count="$(grep -c "channel closed.*HANDLER_FAILED" "$log" 2>/dev/null || true)"
   [ -n "${count:-}" ] || count=0
   if [ "$count" -gt 0 ]; then
      printf '；logcat: %s 次 channel closed cause=HANDLER_FAILED（宿主通道握手后就断）' "$count"
   fi
}

wait_engine_ready() { # seconds
   # A turn needs a live host: the composer accepts text while the engine is
   # down and then sends nothing, which is exactly the silent failure this wait
   # turns into a named one.
   local secs="${1:-60}" end=$((SECONDS + ${1:-60}))
   while [ "$SECONDS" -lt "$end" ]; do
      if ui_dump "$RUN_DIR/last.xml"; then
         if ui_has --text "运行中" --exact; then return 0; fi
         if ui_has --text "启动本地引擎"; then
            ui_tap_exact "启动本地引擎" >/dev/null 2>&1 || true
            sleep 5
            continue
         fi
      fi
      sleep 2
   done
   return 1
}

open_chat() {
   # A route transition can be slow enough that the first dump after the tap is
   # still the list; one retry is the difference between a flaky driver and a
   # real finding, and the retry is visible in the scene when it fails twice.
   local attempt=0
   while [ "$attempt" -lt 2 ]; do
      if go_home && open_session && wait_chat; then return 0; fi
      attempt=$((attempt + 1))
      sleep 2
   done
   return 1
}

# ---------------------------------------------------------------- steps
step_1() {
   local url="http://127.0.0.1:$UPSTREAM_PORT" key xy record keyfile ksize plain found
   key="$(random_key)"
   S_KEY="$key"
   S_KEY_SHA="$(sha256_text "$key")"
   S_LAST4="${key: -4}"
   S_URL="$url"

   # ---- open 模型服务 through the product's own entry points
   if ! ui_tap_exact "去配置模型服务"; then
      if ! ui_tap_exact "打开会话列表"; then
         EV="首屏既没有「去配置模型服务」卡片，也没有抽屉按钮（App 没有启动到产品首屏）"
         return 1
      fi
      ui_wait "设置" 10 || { EV="抽屉里没有「设置」入口"; return 1; }
      ui_tap_exact "设置"
      ui_wait "模型服务" 15 || { EV="设置页里没有「模型服务」行"; return 1; }
      ui_tap_exact "模型服务"
   fi
   ui_wait "添加模型服务" 20 || { EV="模型服务页 20s 内没有加载出来"; return 1; }

   # ---- the editor
   if ui_tap_exact "编辑"; then :; elif ui_tap_exact "添加模型服务"; then :; else
      EV="模型服务页既没有「编辑」也没有「添加模型服务」"
      return 1
   fi
   ui_wait "服务 URL" 15 || { EV="模型服务编辑器没有打开（找不到「服务 URL」标签）"; return 1; }

   xy="$(field_under "服务 URL")" || { EV="编辑器里「服务 URL」标签下面没有输入框"; return 1; }
   # shellcheck disable=SC2086
   ui_tap_xy $xy; sleep 0.5
   ui_type "$url"; sleep 0.4
   ui_hide_ime
   if ! ui_has --text "服务 URL"; then
      EV="输入服务 URL 后编辑器被关掉了（返回手势被页面吃掉）"
      return 1
   fi

   ui_scroll_until "API 密钥" 8 down || { EV="编辑器滚不到「API 密钥」输入框"; return 1; }
   xy="$(field_under "API 密钥")" || { EV="「API 密钥」标签下面没有输入框"; return 1; }
   # shellcheck disable=SC2086
   ui_tap_xy $xy; sleep 0.5
   ui_type "$key"; sleep 0.4
   ui_hide_ime

   ui_scroll_until "保存" 10 up exact || { EV="编辑器滚不回顶部，「保存」按钮不在视口里"; return 1; }
   ui_tap_exact "保存" || { EV="编辑器顶部的「保存」按钮点不到"; return 1; }

   # ---- the page must show what the store holds
   if ! ui_wait "已配置" 25; then
      EV="点「保存」后 25s 内模型服务页没有出现「已配置」"
      return 1
   fi
   ui_dump "$RUN_DIR/step1-saved.xml" || true
   if ! ui_has --text "密钥后四位 $S_LAST4"; then
      EV="页面没有显示「密钥后四位 ${S_LAST4}」，保存后的密钥状态与刚存的不一致"
      return 1
   fi

   # ---- device evidence: the record and the ciphertext
   record="files/settings/model-provider.v1.properties"
   found="$(adb_c shell run-as "$PACKAGE" cat "$record" | tr -d '\r')"
   if [ -z "$found" ]; then
      EV="设备上没有 ${record}（页面说保存了，磁盘上没有记录）"
      return 1
   fi
   case "$found" in
      *"127.0.0.1"*"$UPSTREAM_PORT"*) : ;;
      *) EV="设备记录里没有端点 127.0.0.1:$UPSTREAM_PORT"; return 1 ;;
   esac
   keyfile="$(adb_c shell run-as "$PACKAGE" find no_backup/secure-store -type f | tr -d '\r' | head -1)"
   if [ -z "$keyfile" ]; then
      EV="设备上没有 no_backup/secure-store/*.bin（密钥密文不存在）"
      return 1
   fi
   ksize="$(device_size "$keyfile")"
   plain="$(adb_c shell run-as "$PACKAGE" grep -c "$S_KEY" "$keyfile" | tr -d '\r')"
   case "${plain:-0}" in
      0) : ;;
      *) EV="密钥密文里出现了明文 key（$ksize B 的文件里能 grep 到）"; return 1 ;;
   esac

   # ---- save means it survives a process death
   adb_c shell am force-stop "$PACKAGE" >/dev/null; sleep 1
   launch_app
   if ! ensure_home; then
      EV="保存后冷启动，App 45s 内没有回到会话列表首屏"
      return 1
   fi
   ui_dump "$RUN_DIR/step1-coldstart.xml" || true
   if ui_has --text "还差一步" && ui_has --text "去配置模型服务"; then
      EV="冷启动后首屏又要求配置模型服务（key 没有持久化）"
      return 1
   fi

   EV="页面「已配置 / 密钥后四位 ${S_LAST4}」，设备记录 ${record##*/} 含端点 127.0.0.1:${UPSTREAM_PORT}，"\
"密钥密文 ${ksize} B 且 grep 不到明文，冷启动后首屏不再要求配置"
   return 0
}

step_2() {
   local before after i=0 created=0 handoff sid rowtitle on_chat=0
   ensure_home || { EV="App 不在会话列表首屏，步骤2 无法点击「新建会话」"; return 1; }
   ui_dump "$RUN_DIR/step2-before.xml" || { EV="拿不到会话列表首屏的 dump"; return 1; }
   before="$(ui_count_rows '^新会话( [0-9]+)?$')"
   [ -n "$before" ] || before=0

   adb_raw logcat -c 2>/dev/null || true

   if ! ui_tap_exact "新建会话"; then
      if ui_has --text "先启动本地引擎"; then
         EV="「新建会话」被页面禁用（显示「先启动本地引擎,才能新建会话。」，引擎当前未启动）"
      else
         EV="首屏没有可点击的「新建会话」入口"
      fi
      return 1
   fi

   # Two honest shapes: the host may land the person in the new conversation, or
   # the row may appear in place. Both count only if a session really exists.
   while [ "$i" -lt 25 ]; do
      if ui_dump "$RUN_DIR/step2-after.xml"; then
         if ui_has --text "发送消息" --exact; then on_chat=1; created=1; break; fi
         after="$(ui_count_rows '^新会话( [0-9]+)?$')"
         [ -n "$after" ] || after=0
         if [ "$after" -gt "$before" ]; then created=1; break; fi
      fi
      sleep 1; i=$((i + 1))
   done
   sid="$(adb_raw logcat -d 2>/dev/null | grep -o "chat: new session [a-z0-9-]*" | tail -1 || true)"
   handoff="$(adb_raw logcat -d 2>/dev/null | grep -m1 "host session gesture handed off: new" || true)"
   if [ "$created" != "1" ] && [ -z "$sid" ]; then
      if [ -n "$handoff" ]; then
         EV="点「新建会话」${i}s 后没有会话出现；logcat 显示该手势只被交接（host session gesture handed off: new），宿主没有创建会话"
      else
         EV="点「新建会话」${i}s 后既没有进入对话页，会话行也没有增加（仍是 $before 个），logcat 里没有创建会话的痕迹"
      fi
      return 1
   fi

   # The row has to survive leaving the conversation: that is what makes it a
   # session and not a screen the shell painted for one gesture.
   if [ "$on_chat" = "1" ]; then
      adb_c shell input keyevent 4 >/dev/null; sleep 1.5
   fi
   ensure_home || { EV="新建会话后回不到会话列表首屏"; return 1; }
   ui_dump "$RUN_DIR/step2-list.xml" || true
   after="$(ui_count_rows '^新会话( [0-9]+)?$')"
   [ -n "${after:-}" ] || after=0
   if [ "$after" -le "$before" ]; then
      EV="会话行在对话页出现过，但回到会话列表后仍是 $before 个（会话没有留下）"
      return 1
   fi
   rowtitle="$(python3 "$UI_PY" texts "$UI_XML" 2>/dev/null | awk -F'\t' '$1 ~ /^新会话( [0-9]+)?$/ {print $1; exit}')"
   [ -n "${rowtitle:-}" ] && S_SESSION_TITLE="$rowtitle"
   [ -n "${S_SESSION_TITLE:-}" ] || S_SESSION_TITLE="新会话"

   EV="会话行 $before → ${after}（标题「${S_SESSION_TITLE}」，离开对话后仍在列表里）${sid:+；logcat: ${sid}}"
   return 0
}

step_3() {
   local samples="$RUN_DIR/step3-samples.txt" i=0 end_seen=0 final_len=0 mid_max=0 growing=0
   local req_count auth_sha key_sha hit=""
   : >"$samples"

   if ! open_chat; then
      if ! ensure_home; then EV="App 不在会话列表首屏"; return 1; fi
      EV="会话列表里没有可打开的会话行（步骤2 没有创建出会话），无法进入对话页"
      return 1
   fi
   adb_raw logcat -c 2>/dev/null || true

   if ! wait_engine_ready 90; then
      EV="对话页的引擎状态不是「运行中」（dump 里是「未启动」），这句话发不出去"
      return 1
   fi
   if ! ui_tap "发消息" && ! ui_tap "输入消息"; then
      EV="对话页找不到输入框（composer）"
      return 1
   fi
   ui_type "$S_PROMPT"; sleep 0.5
   if ! ui_tap_exact "发送消息"; then
      EV="对话页没有可点的「发送」按钮"
      return 1
   fi

   local deadline=$((SECONDS + STREAM_TIMEOUT))
   while [ "$SECONDS" -lt "$deadline" ]; do
      if ! ui_dump "$RUN_DIR/stream-$i.xml"; then sleep 0.3; continue; fi
      local line len
      line="$(python3 "$UI_PY" longest "$UI_XML" --contains "$STREAM_MARK" 2>/dev/null)"
      len="${line%%	*}"
      [ -n "$len" ] || len=0
      printf '%s\n' "$len" >>"$samples"
      if ui_has --text "$STREAM_END"; then
         end_seen=1
         cp "$UI_XML" "$RUN_DIR/stream-final.xml" 2>/dev/null || true
         break
      fi
      i=$((i + 1))
   done

   # The numbers behind the claim: the biggest mid-stream sample, the final
   # length, and how many times the visible text actually grew.
   read -r mid_max final_len growing <<<"$(python3 - "$samples" <<'PY'
import sys
values = [int(line.strip() or 0) for line in open(sys.argv[1]) if line.strip()]
if not values:
    print(0, 0, 0)
else:
    final = values[-1]
    mids = values[:-1]
    mid_max = max(mids) if mids else 0
    growing = sum(1 for index in range(1, len(values)) if values[index] > values[index - 1])
    print(mid_max, final, growing)
PY
)"
   [ -n "${final_len:-}" ] || final_len=0

   req_count="$(grep -c "^MODEL_REQ" "$RUN_DIR/upstream.log" 2>/dev/null || true)"
   [ -n "${req_count:-}" ] || req_count=0

   if [ "$req_count" = "0" ]; then
      EV="发送后 ${STREAM_TIMEOUT}s 内夹具没有收到任何请求（turn 没有到达模型；dump 里正文长度始终为 0）$(channel_note)"
      return 1
   fi

   # The credential on the wire must be the key step 1 saved. Only the hash is
   # compared: neither the key nor its header value is written anywhere.
   if [ -n "${S_KEY_SHA:-}" ]; then
      auth_sha="$(printf 'Bearer %s' "$S_KEY" | python3 -c 'import hashlib,sys;sys.stdout.write(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')"
      key_sha="$S_KEY_SHA"
      if grep -q "authorization_sha256=$auth_sha" "$RUN_DIR/upstream.log"; then
         hit="Authorization: Bearer（与步骤1 保存的 key 哈希一致）"
      elif grep -q "x_api_key_sha256=$key_sha" "$RUN_DIR/upstream.log"; then
         hit="x-api-key（与步骤1 保存的 key 哈希一致）"
      fi
   fi

   if [ "$end_seen" != "1" ]; then
      if [ "$final_len" = "0" ]; then
         EV="夹具收到了 $req_count 个请求，但 ${STREAM_TIMEOUT}s 内界面上没有出现正文（没有流式输出到 UI）"
      else
         EV="正文出现到 $final_len 字，但 ${STREAM_TIMEOUT}s 内没有走完（缺 ${STREAM_END}）"
      fi
      return 1
   fi
   if [ "$growing" -lt 2 ] || [ "$final_len" -le "$mid_max" ]; then
      EV="正文只以 $final_len 字一次出现（生成中最大 ${mid_max}，增长 $growing 次），不是流式"
      return 1
   fi
   if [ -z "$hit" ]; then
      EV="流式正常（$mid_max → $final_len 字），但夹具收到的凭证与步骤1 保存的 key 不一致"
      return 1
   fi
   if ! ui_has --text "$S_PROMPT"; then
      EV="流式正常，但完成后的 dump 里找不到刚发送的用户文本「${S_PROMPT}」"
      return 1
   fi

   EV="采样 $(wc -l <"$samples" | tr -d ' ') 次，正文 $mid_max → $final_len 字（增长 $growing 次，完成态更长），含 ${STREAM_END}；上游 $req_count 个请求，凭证 $hit"
   return 0
}

step_4() {
   local want_bytes path size focus
   want_bytes="$S_CSV_BYTES"
   [ -n "$want_bytes" ] || { EV="脚本没有算出夹具字节数"; return 1; }

   adb_c shell mkdir -p /sdcard/Download >/dev/null 2>&1 || true
   adb_raw push "$FIXTURES/$CSV_NAME" "/sdcard/Download/$CSV_NAME" >/dev/null 2>&1 \
      || { EV="adb push 把夹具 CSV 送到设备 Downloads 失败"; return 1; }

   if ! open_chat; then
      EV="$(prereq_note 2 3)进不了对话页（会话行不存在），无法打开「添加文件（写入工作区）」"
      return 1
   fi

   ui_tap_exact "添加指令、引用或附件" || { EV="对话页 composer 上没有「+」（添加指令、引用或附件）"; return 1; }
   ui_wait "添加文件（写入工作区）" 15 || { EV="点「+」后 15s 内没有出现「添加文件（写入工作区）」菜单项"; return 1; }
   ui_tap_exact "添加文件（写入工作区）" || { EV="「添加文件（写入工作区）」点不动"; return 1; }

   local end=$((SECONDS + 30)) tapped=0
   while [ "$SECONDS" -lt "$end" ]; do
      ui_dump "$RUN_DIR/step4-picker.xml" || { sleep 0.8; continue; }
      if ui_has --text "$CSV_NAME" --exact; then
         ui_tap_exact "$CSV_NAME"
         tapped=1
         break
      fi
      if ui_has --text "Downloads" --exact; then
         ui_tap_exact "Downloads"
      elif ui_has --text "下载" --exact; then
         ui_tap_exact "下载"
      elif ui_has --text "Show roots"; then
         ui_tap_exact "Show roots"
      fi
      sleep 1
   done
   focus="$(focus_line)"
   if [ "$tapped" != "1" ]; then
      case "$focus" in
         *documentsui*|*DocumentsUI*) EV="系统文件选择器开了，但 30s 内没有列出 $CSV_NAME" ;;
         *) EV="点「添加文件（写入工作区）」后没有出现系统文件选择器（前台仍是 ${focus##* })" ;;
      esac
      return 1
   fi

   # The App must really have written it: search the App's own data dir.
   local i=0
   path=""
   while [ "$i" -lt 30 ]; do
      path="$(device_find "$CSV_NAME")"
      if [ -n "$path" ]; then break; fi
      sleep 1; i=$((i + 1))
   done
   if [ -z "$path" ]; then
      EV="选择器里点了 ${CSV_NAME}，但 30s 后 App 的 data 目录里找不到这个文件"
      return 1
   fi
   size="$(device_size "$path")"
   case "$path" in
      *materialized/workspace*) : ;;
      *) EV="文件落到了 ${path}，不在 materialized/workspace 里" ; return 1 ;;
   esac
   if [ "$size" != "$want_bytes" ]; then
      EV="工作区里的 $CSV_NAME 是 $size B，夹具是 $want_bytes B（字节数不一致）"
      return 1
   fi

   EV="系统选择器选中 $CSV_NAME 后，$path 存在且 $size B == 夹具 $want_bytes B"
   return 0
}

step_5() {
   local end=$((SECONDS + ANSWER_TIMEOUT)) audit_line req_before
   if [ -z "${S_EXPECTED_TOTAL:-}" ]; then
      EV="脚本没有算出 orders.csv 的合计（夹具缺失）"
      return 1
   fi
   if grep -qF "$S_EXPECTED_TOTAL" "$FIXTURES/scripted-acceptance-upstream.py"; then
      EV="夹具源码里硬编码了 ${S_EXPECTED_TOTAL}，步骤5 的断言会自欺"
      return 1
   fi

   if ! open_chat; then
      EV="$(prereq_note 2 3)进不了对话页（会话行不存在），无法让模型处理 CSV"
      return 1
   fi
   req_before="$(grep -c "^MODEL_REQ" "$RUN_DIR/upstream.log" 2>/dev/null || true)"
   [ -n "${req_before:-}" ] || req_before=0

   if ! wait_engine_ready 90; then
      EV="$(prereq_note 4)导入 CSV 后引擎停在「未启动」（logcat: start cancelled / start aborted after materialization），对话页没有再把它拉起来，这句话发不出去"
      return 1
   fi
   ui_tap "发消息" >/dev/null 2>&1 || ui_tap "输入消息" >/dev/null 2>&1 \
      || { EV="对话页找不到输入框"; return 1; }
   ui_type "$S_CSV_PROMPT"; sleep 0.5
   ui_tap_exact "发送消息" || { EV="对话页没有可点的「发送」按钮"; return 1; }

   local seen=0 sent_at=$SECONDS stalled=0 reqs=""
   while [ "$SECONDS" -lt "$end" ]; do
      if ui_dump "$RUN_DIR/step5.xml"; then
         if ui_has --text "$S_EXPECTED_TOTAL"; then seen=1; break; fi
      fi
      # A turn that never left the device is not "an answer without numbers":
      # after 45 s with no request at all, the transport is the finding.
      if [ $((SECONDS - sent_at)) -ge 45 ]; then
         reqs="$(grep -c "^MODEL_REQ" "$RUN_DIR/upstream.log" 2>/dev/null || true)"
         [ -n "${reqs:-}" ] || reqs=0
         if [ "$reqs" -le "$req_before" ]; then stalled=1; break; fi
      fi
      sleep 2
   done
   if [ "$seen" != "1" ]; then
      reqs="$(grep -c "^MODEL_REQ" "$RUN_DIR/upstream.log" 2>/dev/null || true)"
      [ -n "${reqs:-}" ] || reqs=0
      # What the screen said is part of the evidence: a turn that died on the
      # transport must not be reported as "the model answered without numbers".
      local ui_error=""
      if ui_dump "$RUN_DIR/step5-error.xml"; then
         ui_error="$(python3 "$UI_PY" texts "$UI_XML" 2>/dev/null | awk -F'\t' '$1 ~ /发送失败|channel_lost|失败/ {print $1; exit}')"
      fi
      if [ "$reqs" -le "$req_before" ]; then
         EV="发送后上游零请求（turn 没有到达模型），对话里也没有合计 ${S_EXPECTED_TOTAL}$(channel_note)"
      elif [ -n "${ui_error:-}" ]; then
         EV="上游收到了 $reqs 个请求（夹具已从工具输出解析出合计 ${S_EXPECTED_TOTAL}），但界面显示「${ui_error}」，回答没有到达对话"
      else
         EV="上游收到了 $reqs 个请求，但 ${ANSWER_TIMEOUT}s 内对话里没有出现合计 ${S_EXPECTED_TOTAL}（回答里没有 CSV 的具体数字）"
      fi
      return 1
   fi

   audit_line="$(grep "lane=csv round=2" "$RUN_DIR/upstream.log" | tail -1 || true)"
   if [ -z "$audit_line" ]; then
      EV="界面上出现了 ${S_EXPECTED_TOTAL}，但夹具没有记录到「从工具输出解析 CSV」那一轮"
      return 1
   fi
   case "$audit_line" in
      *"rows=$S_EXPECTED_ROWS "*) : ;;
      *) EV="夹具解析出的行数不是 ${S_EXPECTED_ROWS}（${audit_line}）"; return 1 ;;
   esac
   case "$audit_line" in
      *"total=$S_EXPECTED_TOTAL"*) : ;;
      *) EV="夹具解析出的合计不是 ${S_EXPECTED_TOTAL}（${audit_line}）"; return 1 ;;
   esac
   case "$audit_line" in
      *"rows_digest=$S_CSV_DIGEST"*) : ;;
      *) EV="夹具解析出的行摘要与 orders.csv 不一致（${audit_line}）"; return 1 ;;
   esac

   S_ANSWER="$S_EXPECTED_TOTAL"
   ui_dump "$RUN_DIR/step5-answer.xml" || true

   EV="回答含合计 ${S_EXPECTED_TOTAL}；夹具从工具输出解析 rows=$S_EXPECTED_ROWS / total=$S_EXPECTED_TOTAL / rows_digest=${S_CSV_DIGEST:0:12}…（== orders.csv 行摘要），夹具源码不含该数字"
   return 0
}

step_6() {
   local path size content focus end demo=""
   path="$(device_find "$SUMMARY_NAME")"
   if [ -z "$path" ]; then
      EV="$(prereq_note 3 4 5)工作区里没有 ${SUMMARY_NAME}（模型没有把产物写进 /dsh/workspace）"
      return 1
   fi
   size="$(device_size "$path")"
   content="$(adb_c shell run-as "$PACKAGE" cat "$path" | tr -d '\r')"
   case "$content" in
      *"$S_EXPECTED_TOTAL"*) : ;;
      *) EV="产物 ${path}（$size B）里没有合计 $S_EXPECTED_TOTAL"; return 1 ;;
   esac
   local on_disk="工作区里的 ${SUMMARY_NAME}（$size B）含 ${S_EXPECTED_TOTAL}"

   if ! open_chat; then
      EV="$(prereq_note 2 3)${on_disk}，但进不了对话页，打不开产物页"
      return 1
   fi
   ui_tap_exact "更多操作" || { EV="${on_disk}；但对话页没有「更多操作」(⋯) 按钮"; return 1; }
   ui_wait "产物" 10 || { EV="${on_disk}；但「更多操作」菜单里没有「产物」项"; return 1; }
   ui_tap_exact "产物"
   ui_wait "本 session 产物" 20 || { EV="${on_disk}；但 20s 内没有打开「本 session 产物」页"; return 1; }
   ui_dump "$RUN_DIR/step6-artifacts.xml" || true
   if ! ui_has --text "$SUMMARY_NAME"; then
      demo="$(python3 "$UI_PY" texts "$UI_XML" 2>/dev/null | awk -F'\t' '$1 ~ /^演示数据/ {print $1; exit}')"
      if [ -n "${demo:-}" ]; then
         EV="${on_disk}；但产物页列的是演示数据（界面写「${demo}」），没有列出真实产物，也没有预览/分享可点"
      else
         EV="${on_disk}；但产物页没有列出 ${SUMMARY_NAME}，也没有预览/分享可点"
      fi
      return 1
   fi
   ui_tap "$SUMMARY_NAME"
   ui_wait "$S_EXPECTED_TOTAL" 25 || { EV="产物页列出了 ${SUMMARY_NAME}，但预览里没有 ${S_EXPECTED_TOTAL}"; return 1; }
   if ! ui_tap_exact "分享" && ! ui_tap_exact "分享产物"; then
      EV="产物预览里有 ${S_EXPECTED_TOTAL}，但预览页没有「分享」入口"
      return 1
   fi
   end=$((SECONDS + 20))
   while [ "$SECONDS" -lt "$end" ]; do
      focus="$(focus_line)"
      case "$focus" in
         *intentresolver*|*ChooserActivity*|*ResolverActivity*) break ;;
      esac
      sleep 1
   done
   case "$focus" in
      *intentresolver*|*ChooserActivity*|*ResolverActivity*)
         adb_c shell input keyevent 4 >/dev/null 2>&1 || true
         EV="产物 ${SUMMARY_NAME}（$size B）在产物页可打开，预览显示 ${S_EXPECTED_TOTAL}，点「分享」后前台是 ${focus##* }"
         return 0
         ;;
      *)
         EV="预览里有 ${S_EXPECTED_TOTAL}，但点「分享」20s 后前台仍不是系统选择器（${focus##* }）"
         return 1
         ;;
   esac
}

step_7() {
   local pid_before pid_after i=0
   pid_before="$(app_pid)"
   if [ -z "$pid_before" ]; then
      EV="App 没在运行（pidof 为空），无法做冷启动对比"
      return 1
   fi
   adb_c shell am force-stop "$PACKAGE" >/dev/null
   while [ "$i" -lt 10 ]; do
      [ -z "$(app_pid)" ] && break
      sleep 1; i=$((i + 1))
   done
   if [ -n "$(app_pid)" ]; then
      EV="force-stop 后 10s 进程仍在（${pid_before}）"
      return 1
   fi

   launch_app
   i=0
   while [ "$i" -lt 40 ]; do
      pid_after="$(app_pid)"
      [ -n "$pid_after" ] && break
      sleep 1; i=$((i + 1))
   done
   if [ -z "${pid_after:-}" ]; then
      EV="重启后 40s 内没有新进程"
      return 1
   fi
   if [ "$pid_after" = "$pid_before" ]; then
      EV="重启前后进程号相同（${pid_before}），没有真的冷启动"
      return 1
   fi

   ensure_home || { EV="重启后 45s 内没有回到会话列表首屏"; return 1; }
   ui_dump "$RUN_DIR/step7-home.xml" || true
   if [ -n "${S_SESSION_TITLE:-}" ] && ! ui_has --text "$S_SESSION_TITLE"; then
      EV="重启后会话列表里没有原来的会话「${S_SESSION_TITLE}」"
      return 1
   fi
   if ! open_session; then
      if [ -z "${S_SESSION_TITLE:-}" ]; then
         EV="重启后会话列表里没有会话行（步骤2 没有创建成功），没有原会话可重开"
      else
         EV="重启后点不开原会话「${S_SESSION_TITLE}」（会话行不可点）"
      fi
      return 1
   fi
   wait_chat || { EV="重启后原会话没有打开对话页"; return 1; }

   ui_dump "$RUN_DIR/step7-reopened.xml" || true
   # The transcript is a lazy list: only composed rows are in the dump, so an
   # older message has to be scrolled back into view before it can be missed.
   local scrolls=0
   while [ "$scrolls" -lt 4 ]; do
      if [ -z "${S_PROMPT:-}" ] || ui_has --text "$S_PROMPT"; then break; fi
      adb_c shell input swipe 540 700 540 1600 250 >/dev/null
      sleep 1.2
      ui_dump "$RUN_DIR/step7-reopened.xml" || true
      scrolls=$((scrolls + 1))
   done
   if [ -n "${S_PROMPT:-}" ] && ! ui_has --text "$S_PROMPT"; then
      EV="重开原会话后 dump 里没有原消息「${S_PROMPT}」（消息没有持久化）"
      return 1
   fi
   if [ "${R_5:-}" = "pass" ] && [ -n "${S_EXPECTED_TOTAL:-}" ] && ! ui_has --text "$S_EXPECTED_TOTAL"; then
      EV="重开原会话后 dump 里没有回答里的 ${S_EXPECTED_TOTAL}（回答没有持久化）"
      return 1
   fi
   if [ "${R_3:-}" = "pass" ] && ! ui_has --text "STREAM-END"; then
      EV="重开原会话后 dump 里没有第 3 步的回答（流式正文没有持久化）"
      return 1
   fi

   EV="pid $pid_before → ${pid_after}（进程真的重启）；重开「${S_SESSION_TITLE:-会话}」后 dump 仍含原消息「${S_PROMPT}」"
   if [ "${R_3:-}" = "pass" ]; then EV="${EV} 与第 3 步的回答正文"; fi
   if [ "${R_5:-}" = "pass" ]; then EV="${EV} 与合计 ${S_EXPECTED_TOTAL}"; fi

   return 0
}

# ---------------------------------------------------------------- runner
report_step() { # n, pass|fail, evidence
   local n="$1" status="$2" ev="$3"
   eval "R_$n=$status"
   eval "E_$n=\$ev"
   if [ "$status" = "pass" ]; then
      PASS_COUNT=$((PASS_COUNT + 1))
      printf 'PASS 步骤%s: %s\n' "$n" "$ev"
   else
      FAIL_COUNT=$((FAIL_COUNT + 1))
      FAILED_ANY=1
      printf 'FAIL 步骤%s: %s\n' "$n" "$ev"
   fi
}

run_step() {
   local n="$1"
   say "步骤 $n"
   EV=""
   if "step_$n"; then
      report_step "$n" pass "$EV"
   else
      [ -n "$EV" ] || EV="步骤 $n 没有给出证据句（脚本 bug）"
      report_step "$n" fail "$EV"
      scene "$n"
      save_state
      if [ "$FAIL_FAST" = "1" ]; then
         say "fail-fast: 停在步骤 $n"
         return 1
      fi
   fi
   save_state
   return 0
}

write_report() {
   local apk_line device_line mode_line i status ev
   mkdir -p "$(dirname "$REPORT")" 2>/dev/null || true
   apk_line="n/a"
   if [ -n "$APP_APK" ] && [ -f "$APP_APK" ]; then
      apk_line="$(basename "$APP_APK") $(wc -c <"$APP_APK" | tr -d ' ') B, sha256 $(python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest()[:12])' "$APP_APK")"
   fi
   device_line="$SERIAL ($(android_release) / $(cpu_abi))"
   if [ "$MODE" = "all" ]; then mode_line="--all"; else mode_line="--step $STEP"; fi
   {
      printf '# 产品七步验收报告\n\n'
      printf -- '- 运行: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
      printf -- '- 模式: `%s`\n' "$mode_line"
      printf -- '- 设备: %s\n' "$device_line"
      printf -- '- APK: %s\n' "$apk_line"
      printf -- '- 上游: scripted fixture `127.0.0.1:%s`（不是模型；本次没有任何推理发生）\n' "$UPSTREAM_PORT"
      printf -- '- 夹具: `android/tools/acceptance/fixtures/%s`（%s B, %s 行, 合计 %s）\n' \
         "$CSV_NAME" "${S_CSV_BYTES:-?}" "${S_EXPECTED_ROWS:-?}" "${S_EXPECTED_TOTAL:-?}"
      printf -- '- 保存的 key: 运行时生成，仅以 sha256 `%s` 记录\n' "${S_KEY_SHA:0:16}…"
      printf -- '- 现场目录: `%s`\n\n' "$RUN_DIR"
      printf '| 步骤 | 结果 | 证据 / 卡点 |\n|---|---|---|\n'
      for i in 1 2 3 4 5 6 7; do
         eval "status=\${R_$i:-}"
         eval "ev=\${E_$i:-}"
         [ -n "$status" ] || status="未运行"
         [ -n "$ev" ] || ev="（本次没有跑到）"
         ev="${ev//|/\\|}"
         printf '| %s %s | %s | %s |\n' "$i" "$(step_title "$i")" "$(upper_status "$status")" "$ev"
      done
      printf '\n'
      if [ "$FAIL_COUNT" -gt 0 ]; then
         printf '## 结论\n\n七步里 **%s 步通过、%s 步失败**（本次调用）。失败步骤的现场在 `%s`：\n\n' \
            "$PASS_COUNT" "$FAIL_COUNT" "$RUN_DIR"
         for i in 1 2 3 4 5 6 7; do
            eval "status=\${R_$i:-}"
            [ "$status" = "fail" ] || continue
            printf -- '- 步骤%s: `step%s-fail.{xml,png}` + `step%s-logcat.txt`\n' "$i" "$i" "$i"
         done
      else
         printf '## 结论\n\n七步全过（本次调用）。\n'
      fi
   } >"$REPORT" 2>/dev/null || true
}

prereq_note() {
   # A step downstream of a failure cannot be honest about its own subject, so
   # its line starts by naming the prerequisite that did not hold.
   local s r missing=""
   for s in "$@"; do
      eval "r=\${R_$s:-}"
      [ "$r" = "fail" ] && missing="$missing$s "
   done
   if [ -n "$missing" ]; then
      printf '前置步骤%s未通过：' "${missing% }"
   fi
}

step_title() {
   case "$1" in
      1) printf '保存 key' ;;
      2) printf '新建会话' ;;
      3) printf '流式正文' ;;
      4) printf '选 CSV 进工作区' ;;
      5) printf '模型处理它' ;;
      6) printf '预览 / 分享产物' ;;
      7) printf '冷启动' ;;
   esac
}

upper_status() {
   case "$1" in
      pass) printf 'PASS' ;;
      fail) printf 'FAIL' ;;
      *) printf '%s' "$1" ;;
   esac
}

# ---------------------------------------------------------------- main
load_state

# The expectations are computed from the fixture, never from the fixture script.
read -r S_EXPECTED_ROWS S_EXPECTED_TOTAL S_CSV_BYTES S_CSV_DIGEST <<<"$(csv_stats)"
[ -n "${S_EXPECTED_TOTAL:-}" ] || die "cannot compute the fixture's totals"
if [ "$MODE" = "all" ] || [ "$STEP" = "1" ]; then
   S_PROMPT="acceptance $RUN_TAG hello there"
   S_CSV_PROMPT="acceptance $RUN_TAG sum $CSV_NAME"
   S_KEY=""; S_KEY_SHA=""; S_LAST4=""; S_URL=""; S_APK_SHA=""; S_SESSION_TITLE=""; S_ANSWER=""
   R_1=""; R_2=""; R_3=""; R_4=""; R_5=""; R_6=""; R_7=""
   E_1=""; E_2=""; E_3=""; E_4=""; E_5=""; E_6=""; E_7=""
fi
[ -n "${S_PROMPT:-}" ] || S_PROMPT="acceptance $RUN_TAG hello there"
[ -n "${S_CSV_PROMPT:-}" ] || S_CSV_PROMPT="acceptance $RUN_TAG sum $CSV_NAME"

say "product flow acceptance ($MODE${STEP:+, step $STEP})"
info "repo: ${ROOT##*/}  run: $RUN_ID"
info "fixture: $CSV_NAME rows=$S_EXPECTED_ROWS total=$S_EXPECTED_TOTAL bytes=$S_CSV_BYTES"

ensure_device
info "device: $SERIAL ($(android_release), $(cpu_abi))"
ensure_apk
ensure_app
start_upstream

if [ "$MODE" = "all" ] || [ "$STEP" = "1" ]; then
   say "reset the App to a first-run state (pm clear)"
   adb_c shell pm clear "$PACKAGE" >/dev/null
fi
adb_raw logcat -c 2>/dev/null || true
launch_app

if [ "$MODE" = "single" ]; then
   run_step "$STEP"
else
   for n in 1 2 3 4 5 6 7; do
      run_step "$n" || break
   done
fi

write_report

say "结果"
info "$PASS_COUNT 步通过 / $FAIL_COUNT 步失败（本次调用；七步的完整表在报告里）"
info "报告: $REPORT"
info "现场: $RUN_DIR"
if [ "$FAILED_ANY" = "1" ] || [ "$KEEP" = "1" ]; then
   info "（失败步骤的 dump / PNG / logcat 尾巴保留在 ${RUN_DIR}）"
else
   info "全过；现场保留在 ${RUN_DIR}（--keep 不影响保留，便于复查）"
fi

[ "$FAILED_ANY" = "0" ] || exit 1
exit 0
