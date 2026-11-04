#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# L85 — the chat must keep its context across every way the Worker page can be
# rebuilt. Six scenarios (S1-S5 are the requested regression; S6 proves the
# fail-loud path), one product flow, one scripted upstream:
#
#   S1  SAF   the system file picker imports a CSV, the CSV turn completes, and
#             a recall question is answered from the conversation the model saw.
#   S2  picker cancelled (BACK in DocumentsUI) — the same recall must hold.
#   S3  background round trip (HOME, wait, relaunch) — same recall.
#   S4  the share sheet from the artifact preview, cancelled, back to the chat —
#             same recall.
#   S5  cold start (force-stop, relaunch, reopen the conversation) — the model
#             must still answer the recall, i.e. the Worker session was resumed
#             from its durable log rather than replaced.
#   S6  the fail-loud half: the session log is really removed and the Worker is
#             rebuilt, so the next send answers `session/not-found`. The App must
#             say 「上一段上下文已丢失」 in the transcript — never UNKNOWN in
#             silence. Needs `adb root` (renderer kill + materialized file).
#
# The model is `fixtures/scripted-acceptance-upstream.py`, a SCRIPT, not an
# inference service: its recall lane decides from the **request transcript** it
# receives. `CONTEXT-OK 323` means the Worker's own resumed session carried the
# earlier message into the model request; `UNKNOWN` means it did not. Nothing is
# canned per turn: the CSV numbers come from the App's real tool result, and the
# recall answer is a function of the wire body.
#
# Usage:
#   bash android/tools/acceptance/run-chat-context-flow.sh                 # all five
#   bash android/tools/acceptance/run-chat-context-flow.sh --scenario 1
#   bash android/tools/acceptance/run-chat-context-flow.sh --no-build --keep
#
# Device: only `emulator-<--port>` (default 5800) is driven; this lane never
# touches 5556/5558/5670-5772. The AVD is created when absent and deleted with
# `--delete-avd`.
#
# Environment: JAVA_HOME, ANDROID_HOME (default android/local.properties sdk.dir),
# PDSH_CTX_REPORT (default ${TMPDIR}/pdsh-chat-context/report.md).

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
ACCEPT_DIR="${ROOT}/android/tools/acceptance"
FIXTURES="${ACCEPT_DIR}/fixtures"
UI_PY="${ACCEPT_DIR}/lib/ui.py"
PACKAGE="com.phonedsh.app"
CSV_NAME="orders.csv"

EMU_PORT="${PDSH_CTX_EMULATOR_PORT:-5800}"
AVD="${PDSH_CTX_AVD:-pdsh-l85}"
UPSTREAM_PORT="${PDSH_CTX_UPSTREAM_PORT:-8789}"
BASE="${PDSH_CTX_BASE:-${TMPDIR:-/tmp}/pdsh-chat-context}"
BASE="$(printf '%s' "${BASE}" | sed -e 's://*:/:g' -e 's:/*$::')"
RUN_DIR="${BASE}/$(date +%Y%m%d-%H%M%S)-$$"
REPORT="${PDSH_CTX_REPORT:-${BASE}/report.md}"

SCENARIO="all"
BUILD="auto"
KEEP=0
DELETE_AVD=0
REUSE_PROVIDER=0
VERBOSE=0
SERIAL=""
UPSTREAM_PID=""
PASS_COUNT=0
FAIL_COUNT=0
EV=""

SECRET_PROMPT="Remember PR14CHATOK. What is 17 times 19"
SECRET_ANSWER="PR14CHATOK 323"
RECALL_PROMPT="RECALL: what exact multiplication did I request at the start of this chat"
RECALL_ANSWER="CONTEXT-OK 323"

say() { printf '\n== %s\n' "$*"; }
info() { printf '   %s\n' "$*"; }
verbose() { [ "${VERBOSE}" = "1" ] && printf '   · %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }

usage() {
   cat <<'EOF'
usage: bash android/tools/acceptance/run-chat-context-flow.sh [options]

  --scenario N        run only scenario N (1..6; S6 is the fail-loud proof
                      and needs adb root)
  --all               run all five (default)
  --build / --no-build
  --port N            emulator console port (default 5800)
  --avd NAME          AVD to boot when the port is not attached (default pdsh-l85)
  --serial SERIAL     pin an already-running device
  --upstream-port N   host port of the scripted upstream (default 8789)
  --keep              keep the scene directory on success
  --reuse-provider    skip pm clear/provider setup (iteration only; a clean
                      acceptance run is the default)
  --delete-avd        remove the AVD this run created
  --verbose
EOF
}

while [ $# -gt 0 ]; do
   case "$1" in
      --scenario) SCENARIO="${2:-}"; shift 2 ;;
      --all) SCENARIO="all"; shift ;;
      --build) BUILD="1"; shift ;;
      --no-build) BUILD="0"; shift ;;
      --port) EMU_PORT="${2:-5800}"; shift 2 ;;
      --avd) AVD="${2:-${AVD}}"; shift 2 ;;
      --serial) SERIAL="${2:-}"; shift 2 ;;
      --upstream-port) UPSTREAM_PORT="${2:-8789}"; shift 2 ;;
      --keep) KEEP=1; shift ;;
      --reuse-provider) REUSE_PROVIDER=1; shift ;;
      --delete-avd) DELETE_AVD=1; shift ;;
      --verbose) VERBOSE=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown option: $1" ;;
   esac
done

ANDROID_HOME="${ANDROID_HOME:-$(sed -n 's/^sdk.dir=//p' "${ROOT}/android/local.properties" 2>/dev/null | head -1)}"
[ -n "${ANDROID_HOME}" ] && [ -d "${ANDROID_HOME}" ] || die "ANDROID_HOME is not a directory: set ANDROID_HOME"
if [ -z "${JAVA_HOME:-}" ] && command -v java >/dev/null 2>&1; then
   JAVA_HOME="$(cd "$(dirname "$(command -v java)")/.." && pwd)"
fi
[ -n "${JAVA_HOME:-}" ] && export JAVA_HOME
export ANDROID_HOME
export PATH="${JAVA_HOME:+${JAVA_HOME}/bin:}${ANDROID_HOME}/platform-tools:${ANDROID_HOME}/emulator:${PATH}"
command -v adb >/dev/null 2>&1 || die "adb not found under ${ANDROID_HOME}"
command -v python3 >/dev/null 2>&1 || die "python3 is required"
[ -f "${UI_PY}" ] || die "missing ${UI_PY}"
[ -f "${FIXTURES}/${CSV_NAME}" ] || die "missing ${FIXTURES}/${CSV_NAME}"
mkdir -p "${RUN_DIR}" || die "cannot create ${RUN_DIR}"

# ------------------------------------------------------------------ transport
adb_c() { command adb -s "${SERIAL}" "$@" 2>/dev/null; }
adb_raw() { command adb -s "${SERIAL}" "$@"; }
app_pid() { adb_c shell pidof "${PACKAGE}" | tr -d '\r'; }
focus_line() { adb_c shell dumpsys window 2>/dev/null | grep -m1 "mCurrentFocus" || true; }
component() { adb_c shell cmd package resolve-activity --brief "${PACKAGE}" | tr -d '\r' | tail -1; }

UI_XML=""
ui_dump() {
   local out="${1:-${RUN_DIR}/last.xml}" tries=0
   while [ "${tries}" -lt 3 ]; do
      adb_c shell uiautomator dump /sdcard/pdsh-ctx-window.xml >/dev/null
      adb_c exec-out cat /sdcard/pdsh-ctx-window.xml >"${out}" 2>/dev/null
      if [ -s "${out}" ] && grep -q "<hierarchy" "${out}"; then UI_XML="${out}"; return 0; fi
      tries=$((tries + 1)); sleep 0.3
   done
   UI_XML="${out}"
   return 1
}
ui_find() { python3 "${UI_PY}" find "${UI_XML}" "$@" 2>/dev/null; }
ui_has() { python3 "${UI_PY}" has "${UI_XML}" "$@" >/dev/null 2>&1; }
ui_tap_xy() { adb_c shell input tap "$1" "$2"; }
ui_tap() {
   local xy
   ui_dump "${RUN_DIR}/last.xml" || return 1
   xy="$(ui_find --text "$1")"
   [ -n "${xy}" ] || return 1
   verbose "tap 「$1」 at ${xy}"
   ui_tap_xy ${xy}
}
ui_tap_exact() {
   local xy
   ui_dump "${RUN_DIR}/last.xml" || return 1
   xy="$(ui_find --text "$1" --exact)"
   [ -n "${xy}" ] || return 1
   verbose "tap 「$1」 (exact) at ${xy}"
   ui_tap_xy ${xy}
}
ui_wait() { # text seconds
   local want="$1" end=$((SECONDS + ${2:-20}))
   while [ "${SECONDS}" -lt "${end}" ]; do
      if ui_dump "${RUN_DIR}/last.xml" && ui_has --text "${want}"; then return 0; fi
      sleep 0.6
   done
   return 1
}
ui_type() {
   local text="$1"
   adb_c shell input text "${text// /%s}" >/dev/null
}
ui_hide_ime() {
   if adb_c shell dumpsys input_method 2>/dev/null | grep -q "mInputShown=true"; then
      adb_c shell input keyevent 4 >/dev/null
      sleep 0.8
   fi
}
scene() { # tag
   local tag="$1"
   ui_dump "${RUN_DIR}/${tag}.xml" || true
   adb_c exec-out screencap -p >"${RUN_DIR}/${tag}.png" 2>/dev/null || true
   adb_raw logcat -d -v time >"${RUN_DIR}/${tag}-logcat.txt" 2>/dev/null || true
}

# ------------------------------------------------------------------ device
ensure_device() {
   SERIAL="${SERIAL:-emulator-${EMU_PORT}}"
   if [ "$(adb_c shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; then
      info "device: ${SERIAL} (already booted)"
      return 0
   fi
   adb start-server >/dev/null 2>&1 || true
   if ! "${ANDROID_HOME}/emulator/emulator" -list-avds 2>/dev/null | grep -qx "${AVD}"; then
      say "create AVD ${AVD} (android-35, arm64)"
      echo no | "${ANDROID_HOME}/cmdline-tools/latest/bin/avdmanager" create avd \
         -n "${AVD}" -k "system-images;android-35;google_apis;arm64-v8a" -d pixel_5 --force >/dev/null 2>&1 || true
      AVD_CREATED=1
   fi
   "${ANDROID_HOME}/emulator/emulator" -list-avds 2>/dev/null | grep -qx "${AVD}" \
      || die "AVD ${AVD} does not exist and could not be created"
   say "boot AVD ${AVD} on port ${EMU_PORT}"
   "${ANDROID_HOME}/emulator/emulator" -avd "${AVD}" -port "${EMU_PORT}" \
      -no-window -no-audio -no-boot-anim -no-snapshot -gpu swiftshader_indirect \
      >"${RUN_DIR}/emulator.log" 2>&1 &
   local end=$((SECONDS + 300))
   while [ "${SECONDS}" -lt "${end}" ]; do
      if [ "$(adb_c shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; then
         info "device: ${SERIAL} booted"
         return 0
      fi
      sleep 3
   done
   die "the AVD ${AVD} did not boot on port ${EMU_PORT} within 300s (log: ${RUN_DIR}/emulator.log)"
}

APP_APK=""
ensure_apk() {
   APP_APK="${ROOT}/android/app/build/outputs/apk/debug/app-debug.apk"
   if [ "${BUILD}" = "0" ]; then
      [ -f "${APP_APK}" ] || die "--no-build was given but there is no APK at ${APP_APK}"
      return 0
   fi
   if [ "${BUILD}" = "1" ] || [ ! -f "${APP_APK}" ]; then
      say "build :app:assembleDebug"
      ( cd "${ROOT}/android" && ./gradlew :app:assembleDebug --no-daemon --console=plain ) \
         || die "the Gradle build failed"
   fi
   [ -f "${APP_APK}" ] || die "no APK at ${APP_APK}"
}

install_app() {
   say "install ${PACKAGE}"
   adb_raw install -r -t "${APP_APK}" >/dev/null || die "adb install failed"
}

start_upstream() {
   say "scripted upstream on 127.0.0.1:${UPSTREAM_PORT} (a script, not a model)"
   python3 "${FIXTURES}/scripted-acceptance-upstream.py" --port "${UPSTREAM_PORT}" \
      --csv-name "${CSV_NAME}" >"${RUN_DIR}/upstream.log" 2>&1 &
   UPSTREAM_PID=$!
   local i=0
   while [ "${i}" -lt 60 ]; do
      if grep -q "^LISTENING " "${RUN_DIR}/upstream.log" 2>/dev/null; then
         adb_c reverse "tcp:${UPSTREAM_PORT}" "tcp:${UPSTREAM_PORT}" >/dev/null
         adb_c reverse --list >"${RUN_DIR}/reverse.txt" 2>&1
         grep -q "tcp:${UPSTREAM_PORT}" "${RUN_DIR}/reverse.txt" \
            || die "adb reverse tcp:${UPSTREAM_PORT} is not installed (see ${RUN_DIR}/reverse.txt)"
         # The device must reach the host fixture before the first prompt; a
         # missing reverse is a driver fault, not a product finding.
         adb_c shell "toybox nc -z 127.0.0.1 ${UPSTREAM_PORT}" >/dev/null 2>&1 \
            || die "the device cannot reach 127.0.0.1:${UPSTREAM_PORT} through adb reverse"
         info "upstream: pid ${UPSTREAM_PID}, adb reverse tcp:${UPSTREAM_PORT} (verified from the device)"
         return 0
      fi
      sleep 0.2; i=$((i + 1))
   done
   die "the scripted upstream did not start (see ${RUN_DIR}/upstream.log)"
}
cleanup() {
   if [ -n "${UPSTREAM_PID}" ]; then
      kill "${UPSTREAM_PID}" 2>/dev/null || true
      adb_c reverse --remove "tcp:${UPSTREAM_PORT}" >/dev/null 2>&1 || true
   fi
   if [ "${DELETE_AVD}" = "1" ] && [ -n "${AVD_CREATED:-}" ]; then
      say "delete AVD ${AVD}"
      "${ANDROID_HOME}/cmdline-tools/latest/bin/avdmanager" delete avd -n "${AVD}" >/dev/null 2>&1 || true
   fi
}
trap cleanup EXIT INT TERM

launch_app() {
   local which
   which="$(component)"
   [ -n "${which}" ] || die "could not resolve the launcher activity of ${PACKAGE}"
   # A pure product launch: no pdsh.* extras. The endpoint and the key are the
   # ones the product's own settings page saved (see `ensure_provider`).
   adb_c shell am start -W -n "${which}" >/dev/null || die "am start failed"
}

# ------------------------------------------------------------------ navigation
ensure_home() {
   local end=$((SECONDS + 60))
   while [ "${SECONDS}" -lt "${end}" ]; do
      if ui_dump "${RUN_DIR}/last.xml"; then
         if ui_has --text "会话列表" --exact || ui_has --text "还没有会话"; then return 0; fi
         if ui_has --text "启动本地引擎"; then ui_tap_exact "启动本地引擎" >/dev/null 2>&1 || true; fi
      fi
      sleep 1
   done
   return 1
}
wait_chat() {
   local end=$((SECONDS + 45))
   while [ "${SECONDS}" -lt "${end}" ]; do
      if ui_dump "${RUN_DIR}/last.xml"; then
         if ui_has --text "发送消息" --exact || ui_has --text "发消息或创建任务"; then return 0; fi
      fi
      sleep 1
   done
   return 1
}
wait_engine_ready() {
   local end=$((SECONDS + ${1:-90}))
   while [ "${SECONDS}" -lt "${end}" ]; do
      if ui_dump "${RUN_DIR}/last.xml"; then
         ui_has --text "运行中" --exact && return 0
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
new_chat() {
   if ! ensure_home; then EV="App 不在会话列表首屏"; return 1; fi
   ui_tap_exact "新建会话" || { EV="会话列表上没有「新建会话」"; return 1; }
   wait_chat || { EV="点「新建会话」后 45s 内没有对话页"; return 1; }
   wait_engine_ready 120 || { EV="对话页的引擎 120s 内没有「运行中」"; return 1; }
   return 0
}

send_text() { # text -> sends it in the open chat
   local text="$1" tried=0
   while [ "${tried}" -lt 2 ]; do
      if ui_tap "发消息" || ui_tap "输入消息" || ui_tap "输入框"; then
         ui_type "${text}"; sleep 0.6; ui_hide_ime
         if ui_tap_exact "发送消息"; then return 0; fi
      fi
      tried=$((tried + 1)); sleep 1
   done
   return 1
}
wait_screen_text() { # text seconds
   local want="$1" secs="${2:-120}" end=$((SECONDS + ${2:-120}))
   while [ "${SECONDS}" -lt "${end}" ]; do
      if ui_dump "${RUN_DIR}/last.xml" && ui_has --text "${want}"; then return 0; fi
      sleep 1
   done
   return 1
}

wait_answer() { # text seconds -> visible OR reachable by scrolling to the newest row
   local want="$1" end=$((SECONDS + ${2:-150})) nudges=0
   while [ "$SECONDS" -lt "$end" ]; do
      if ui_dump "$RUN_DIR/last.xml"; then
         ui_has --text "${want}" && return 0
         if ui_has --text "回到最新"; then
            # The transcript is a lazy list: a long conversation stays where the
            # person left it, so the settled answer can be below the viewport.
            ui_tap_exact "回到最新" >/dev/null 2>&1 || true
         else
            nudges=$((nudges + 1))
            if [ $((nudges % 6)) -eq 0 ]; then
               adb_c shell input swipe 540 1600 540 700 250 >/dev/null 2>&1 || true
            fi
         fi
      fi
      sleep 1
   done
   return 1
}

ask_and_check() { # what -> sends the recall question and asserts the answer
   local what="$1"
   if ! send_text "${RECALL_PROMPT}"; then EV="${what}：召回问题发不出去（composer 不可用）"; return 1; fi
   if ! wait_answer "${RECALL_ANSWER}" 150; then
      if ui_has --text "UNKNOWN"; then
         EV="${what}：模型答了 UNKNOWN —— UI 里还留着更早的消息，但模型上下文已经丢了"
      else
         EV="${what}：150s 内界面上没有 ${RECALL_ANSWER}（也没有 UNKNOWN）"
      fi
      return 1
   fi
   EV="${what}：同一对话里追问「之前的乘法」→ 界面出现 ${RECALL_ANSWER}（上游从请求 transcript 判定，上下文在）"
   return 0
}

# -- the fixture must be alive and reachable from the device before every
# scenario; a dead fixture or a dropped reverse is a driver fault, not a finding.
probe_upstream() {
   if ! kill -0 "${UPSTREAM_PID}" 2>/dev/null; then
      EV="脚本化上游进程已退出（pid ${UPSTREAM_PID}），后面的回合无法被回答"
      return 1
   fi
   adb_c reverse "tcp:${UPSTREAM_PORT}" "tcp:${UPSTREAM_PORT}" >/dev/null
   if ! adb_c shell "toybox nc -z 127.0.0.1 ${UPSTREAM_PORT}" >/dev/null 2>&1; then
      EV="设备侧 127.0.0.1:${UPSTREAM_PORT} 不可达（adb reverse 掉了或上游不再监听）"
      return 1
   fi
   return 0
}

# ------------------------------------------------------------------ scenarios
SAF_SUMMARY="orders-summary.md"

scenario_1() {
   probe_upstream || return 1
   adb_c shell mkdir -p /sdcard/Download >/dev/null 2>&1 || true
   adb_raw push "${FIXTURES}/${CSV_NAME}" "/sdcard/Download/${CSV_NAME}" >/dev/null 2>&1 \
      || { EV="adb push 送 CSV 到 Downloads 失败"; return 1; }
   if ! ui_tap_exact "添加指令、引用或附件"; then EV="composer 上没有「+」"; return 1; fi
   ui_wait "添加文件（写入工作区）" 15 || { EV="点「+」后没有「添加文件（写入工作区）」"; return 1; }
   ui_tap_exact "添加文件（写入工作区）" || { EV="「添加文件（写入工作区）」点不动"; return 1; }
   local end=$((SECONDS + 40)) tapped=0
   while [ "${SECONDS}" -lt "${end}" ]; do
      ui_dump "${RUN_DIR}/s1-picker.xml" || { sleep 0.8; continue; }
      if ui_has --text "${CSV_NAME}" --exact; then ui_tap_exact "${CSV_NAME}"; tapped=1; break; fi
      if ui_has --text "Downloads" --exact; then ui_tap_exact "Downloads"
      elif ui_has --text "下载" --exact; then ui_tap_exact "下载"
      elif ui_has --text "Show roots"; then ui_tap_exact "Show roots"
      fi
      sleep 1
   done
   [ "${tapped}" = "1" ] || { EV="系统选择器 40s 内没有列出 ${CSV_NAME}"; return 1; }
   wait_chat || { EV="选完 CSV 后回不到对话页"; return 1; }
   local observed=0 i=0
   while [ "${i}" -lt 20 ]; do
      if ui_dump "${RUN_DIR}/s1-attached.xml" && { ui_has --text "${CSV_NAME}" || ui_has --text "工作区"; }; then observed=1; break; fi
      sleep 1; i=$((i + 1))
   done
   [ "${observed}" = "1" ] || { EV="选了 ${CSV_NAME}，但对话页上没有它被加入工作区的痕迹"; return 1; }
   if ! send_text "Please read the attached CSV and report its row count and amount total"; then
      EV="CSV 回合发不出去"; return 1
   fi
   if ! wait_screen_text "[CSV-END]" 240; then
      EV="CSV 回合 240s 内没有完成（界面上没有 [CSV-END]）"
      return 1
   fi
   ask_and_check "SAF 选完 CSV 并处理之后"
}

scenario_2() {
   probe_upstream || return 1
   if ! ui_tap_exact "添加指令、引用或附件"; then EV="composer 上没有「+」"; return 1; fi
   ui_wait "添加文件（写入工作区）" 15 || { EV="点「+」后没有「添加文件（写入工作区）」"; return 1; }
   ui_tap_exact "添加文件（写入工作区）" || { EV="「添加文件（写入工作区）」点不动"; return 1; }
   local end=$((SECONDS + 30)) focused=0
   while [ "${SECONDS}" -lt "${end}" ]; do
      case "$(focus_line)" in
         *documentsui*|*DocumentsUI*|*picker*) focused=1; break ;;
      esac
      sleep 1
   done
   [ "${focused}" = "1" ] || { EV="没有出现系统文件选择器，取消无从发生"; return 1; }
   adb_c shell input keyevent 4 >/dev/null 2>&1 || true
   wait_chat || { EV="取消选择器后回不到对话页"; return 1; }
   ask_and_check "取消系统文件选择器返回后"
}

scenario_3() {
   probe_upstream || return 1
   adb_c shell input keyevent 3 >/dev/null 2>&1 || true
   sleep 8
   if ! launch_app; then EV="后台后重新拉起 App 失败"; return 1; fi
   wait_chat || { EV="从后台返回后 45s 内没有对话页"; return 1; }
   ask_and_check "切后台 8s 返回后"
}

scenario_4() {
   probe_upstream || return 1
   # The share sheet lives behind the artifact page: ⋯ → 产物 → tap the summary →
   # 分享. The artifact was written by scenario 1's CSV turn.
   if ! ui_tap_exact "更多操作"; then EV="对话页没有「更多操作」(⋯)"; return 1; fi
   ui_wait "产物" 10 || { EV="「更多操作」菜单里没有「产物」"; return 1; }
   ui_tap_exact "产物"
   ui_wait "本 session 产物" 20 || { EV="没有打开「本 session 产物」页"; return 1; }
   if ! ui_wait "${SAF_SUMMARY}" 20; then EV="产物页没有列出 ${SAF_SUMMARY}（S1 的 CSV 产物）"; return 1; fi
   ui_tap "${SAF_SUMMARY}"
   ui_wait "分享" 20 || { EV="产物预览里没有「分享」"; return 1; }
   ui_tap_exact "分享" || ui_tap_exact "分享产物" || { EV="「分享」点不动"; return 1; }
   local end=$((SECONDS + 20)) chooser=0
   while [ "${SECONDS}" -lt "${end}" ]; do
      case "$(focus_line)" in
         *intentresolver*|*ChooserActivity*|*ResolverActivity*) chooser=1; break ;;
      esac
      sleep 1
   done
   [ "${chooser}" = "1" ] || { EV="点「分享」20s 内没有出现系统分享选择器"; return 1; }
   adb_c shell input keyevent 4 >/dev/null 2>&1 || true
   sleep 1
   # Back from the preview to the chat.
   local i=0
   while [ "${i}" -lt 4 ]; do
      if wait_chat; then break; fi
      adb_c shell input keyevent 4 >/dev/null 2>&1 || true
      sleep 1.2; i=$((i + 1))
   done
   wait_chat || { EV="取消分享选择器后回不到对话页"; return 1; }
   ask_and_check "分享选择器取消返回后"
}

# -- S6 is the fail-loud proof: the Worker is rebuilt with the session log
# really gone (the host repacks the materialized home the log was removed from),
# so the next send answers `session/not-found`. The App must then say, in the
# transcript, that the earlier context is lost — silence is the defect.
scenario_6() {
   probe_upstream || return 1
   local session_id renderer pid_before
   # The first send has no session yet (`worker=-`); the claim and the settled
   # turn carry it.
   session_id="${SECRET_SESSION:-}"
   if [ -z "${session_id}" ]; then
      session_id="$(adb_raw logcat -d 2>/dev/null | grep -o "worker=session-[a-z0-9-]*" | tail -1 | sed -e 's/worker=//')"
   fi
   if [ -z "${session_id}" ]; then
      EV="S6：logcat 里没有当前对话的 worker session id，无法制造丢上下文"
      return 1
   fi
   if [ "$(adb_c shell id -u | tr -d '\r')" != "0" ]; then
      adb_raw root >/dev/null 2>&1 || true
      sleep 2
   fi
   if [ "$(adb_c shell id -u | tr -d '\r')" != "0" ]; then
      EV="S6：需要 adb root 才能删除物化目录并结束 WebView renderer（本机不允许）"
      return 1
   fi
   local dir="files/xl/materialized/home/sessions"
   local found
   found="$(adb_c shell "run-as ${PACKAGE} find ${dir} -type d -name ${session_id}" 2>/dev/null | tr -d '\r' | head -1)"
   if [ -z "${found}" ]; then
      EV="S6：设备物化目录里没有 ${session_id} 的会话日志，无法制造 session/not-found"
      return 1
   fi
   adb_c shell "run-as ${PACKAGE} rm -rf '${found}'" >/dev/null 2>&1
   adb_raw logcat -c 2>/dev/null || true
   # End the WebView renderer: the engine rebuilds the page and repacks the boot
   # overlay from the materialized tree (which no longer has that log).
   for pid_before in $(adb_c shell ps -A 2>/dev/null | grep sandboxed_process | awk '{print $2}'); do
      adb_c shell kill -9 "${pid_before}" >/dev/null 2>&1 || true
   done
   local end=$((SECONDS + 90)) rebuilt=0
   while [ "$SECONDS" -lt "$end" ]; do
      if adb_raw logcat -d 2>/dev/null | grep -qE "(start|recovered): Running\(origin="; then rebuilt=1; break; fi
      sleep 2
   done
   [ "${rebuilt}" = "1" ] || { EV="S6：结束 renderer 后 90s 内 Worker 没有重建完成"; return 1; }
   sleep 3
   if ! send_text "What did I tell you to remember at the start"; then
      EV="S6：重建后的对话页发不出消息"; return 1
   fi
   if ! wait_screen_text "上一段上下文已丢失" 60; then
      EV="S6：会话日志已被删除，但聊天里没有出现「上一段上下文已丢失」——这正是最坏的静默状态"
      return 1
   fi
   if ! adb_raw logcat -d 2>/dev/null | grep -q "APP_CHAT_CONTEXT_LOST"; then
      EV="S6：界面出现了丢失提示，但 logcat 没有 APP_CHAT_CONTEXT_LOST"
      return 1
   fi
   if adb_raw logcat -d 2>/dev/null | grep -q "is gone (session/not-found); opening a new one"; then
      EV="S6：删掉会话日志并重建 Worker 后，App 在聊天里明确写了「上一段上下文已丢失」，并开了新会话（旧 ${session_id}）"
      return 0
   fi
   EV="S6：界面有丢失提示，但 logcat 里没有 session/not-found 的判定"
   return 1
}

scenario_5() {
   probe_upstream || return 1
   local before after i=0
   before="$(app_pid)"
   [ -n "${before}" ] || { EV="App 没在运行，无法做冷启动"; return 1; }
   adb_c shell am force-stop "${PACKAGE}" >/dev/null
   while [ "${i}" -lt 15 ]; do [ -z "$(app_pid)" ] && break; sleep 1; i=$((i + 1)); done
   [ -z "$(app_pid)" ] || { EV="force-stop 后 15s 进程仍在"; return 1; }
   # A cold start of the same configured App: the process, the Worker page and
   # its in-memory sessions are gone; only the persisted home survives.
   launch_app
   i=0
   while [ "${i}" -lt 60 ]; do after="$(app_pid)"; [ -n "${after}" ] && break; sleep 1; i=$((i + 1)); done
   [ -n "${after}" ] || { EV="冷启动后 60s 内没有新进程"; return 1; }
   [ "${after}" != "${before}" ] || { EV="冷启动前后进程号相同（${before}）"; return 1; }
   if ! ensure_home; then EV="冷启动后没有回到会话列表"; return 1; fi
   # The newest conversation opens by default; if the list is shown, open it.
   if ! wait_chat; then
      ui_tap_exact "新会话" || ui_tap "新会话" || { EV="冷启动后打不开原会话"; return 1; }
      wait_chat || { EV="冷启动后原会话没有对话页"; return 1; }
   fi
   wait_engine_ready 150 || { EV="冷启动后引擎 150s 内没有运行中"; return 1; }
   # The transcript must still show the earlier exchange, otherwise the recall
   # answer below would prove nothing about the UI/model agreement.
   local scrolls=0
   while [ "${scrolls}" -lt 4 ]; do
      if ui_has --text "PR14CHATOK"; then break; fi
      adb_c shell input swipe 540 700 540 1700 250 >/dev/null; sleep 1.2
      ui_dump "${RUN_DIR}/s5-scroll.xml" || true
      scrolls=$((scrolls + 1))
   done
   if ! ui_has --text "PR14CHATOK"; then
      EV="冷启动后重开的对话里看不到更早的 PR14CHATOK 消息（UI 记录丢了，召回无从判断）"
      return 1
   fi
   ask_and_check "冷启动重开同一对话后"
}

run_scenario() {
   local n="$1" rc
   say "S${n}"
   case "${n}" in
      1) scenario_1 ;;
      2) scenario_2 ;;
      3) scenario_3 ;;
      4) scenario_4 ;;
      5) scenario_5 ;;
      6) scenario_6 ;;
      *) EV="unknown scenario"; return 1 ;;
   esac
   rc=$?
   if [ "${rc}" = "0" ]; then
      PASS_COUNT=$((PASS_COUNT + 1))
      printf 'PASS 场景%s: %s\n' "${n}" "${EV}"
   else
      FAIL_COUNT=$((FAIL_COUNT + 1))
      scene "s${n}-fail"
      printf 'FAIL 场景%s: %s\n' "${n}" "${EV}"
      printf '   现场: %s\n' "${RUN_DIR}/s${n}-fail.{xml,png} + s${n}-fail-logcat.txt"
   fi
   {
      printf '| S%s | %s | %s |\n' "${n}" "$([ "${rc}" = 0 ] && echo PASS || echo FAIL)" "${EV}"
   } >>"${RUN_DIR}/report.md"
   return "${rc}"
}

write_report() {
   {
      printf '\n## L85 chat context acceptance\n\n'
      printf 'Scripted upstream (NOT a model): `%s` on 127.0.0.1:%s; recall lane decides from the request transcript.\n\n' \
         "fixtures/scripted-acceptance-upstream.py" "${UPSTREAM_PORT}"
      printf 'Device: `%s` (%s, API %s)\n\n' "${SERIAL}" "$(adb_c shell getprop ro.product.cpu.abi | tr -d '\r')" \
         "$(adb_c shell getprop ro.build.version.sdk | tr -d '\r')"
      cat "${RUN_DIR}/report.md" 2>/dev/null || true
      printf '\n'
   } >"${REPORT}"
}

# -- the provider record: the acceptance step 1 saves the endpoint and a key
# through the product's own settings page and proves both survive a cold start.
ensure_provider() {
   if ui_dump "${RUN_DIR}/last.xml" && ! ui_has --text "还差一步"; then
      info "provider: already configured on the device"
      return 0
   fi
   say "configure the provider through the product's settings page (product-flow step 1)"
   bash "${ACCEPT_DIR}/run-product-flow.sh" --step 1 --serial "${SERIAL}" \
      --port "${EMU_PORT}" --upstream-port "${UPSTREAM_PORT}" --no-build \
      >"${RUN_DIR}/step1.log" 2>&1
   local rc=$?
   tail -2 "${RUN_DIR}/step1.log" | sed -e 's/^/   /'
   [ "${rc}" = "0" ] || die "product-flow step 1 did not pass; see ${RUN_DIR}/step1.log"
}

# ------------------------------------------------------------------ main
say "chat context acceptance (L85)"
info "repo: ${ROOT##*/}  run: $(basename "${RUN_DIR}")"
ensure_device
ensure_apk
install_app
if [ "${REUSE_PROVIDER}" = "1" ]; then
   info "reuse: keeping the installed App data (provider + transcripts)"
else
   say "reset the App (pm clear) and configure the provider"
   adb_c shell pm clear "${PACKAGE}" >/dev/null
fi
launch_app
sleep 2
ensure_provider
start_upstream
adb_c shell logcat -G 16M >/dev/null 2>&1 || true
adb_raw logcat -c 2>/dev/null || true
launch_app

: >"${RUN_DIR}/report.md"
printf '| scenario | result | evidence |\n| --- | --- | --- |\n' >>"${RUN_DIR}/report.md"

if ! new_chat; then
   printf 'FAIL 场景0: %s\n' "${EV}" >&2
   scene "s0-fail"
   write_report
   exit 1
fi
if ! send_text "${SECRET_PROMPT}"; then
   printf 'FAIL 场景0: 首句发不出去\n' >&2
   write_report
   exit 1
fi
if ! wait_screen_text "${SECRET_ANSWER}" 240; then
   printf 'FAIL 场景0: 首轮没有回答 %s（脚本化上游没收到请求或回合没完成）\n' "${SECRET_ANSWER}" >&2
   scene "s0-fail"
   write_report
   exit 1
fi
info "记住口令：界面出现 ${SECRET_ANSWER}"
# The log ring can rotate within a minute on this device, so the session id is
# captured now, not later in S6.
SECRET_SESSION="$(adb_raw logcat -d 2>/dev/null | grep -o "worker=session-[a-z0-9-]*" | tail -1 | sed -e 's/worker=//')"
[ -n "${SECRET_SESSION}" ] && info "worker session: ${SECRET_SESSION}"

if [ "${SCENARIO}" = "all" ]; then
   for n in 1 2 3 4 5 6; do run_scenario "${n}" || true; done
else
   run_scenario "${SCENARIO}" || true
fi

write_report
say "结果"
info "${PASS_COUNT} 通过 / ${FAIL_COUNT} 失败"
info "报告: ${REPORT}"
info "现场: ${RUN_DIR}（$([ "${KEEP}" = "1" ] && echo '--keep' || echo '失败场景的 dump/png/logcat 保留')）"
[ "${FAIL_COUNT}" = "0" ] || exit 1
exit 0
