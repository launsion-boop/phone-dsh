#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# P6 kill-matrix harness: one cell = one kill method at one timing.
#
# Evidence per cell is a tar of the app's workspace, the prefs marker and the
# logcat, captured at three moments: BEFORE the kill (cheap probe), AFTER it
# (process dead) and after RECOVERY (app force-stopped first, so the tar cannot
# race the materialized-tree exchange). Everything lands in
# $ART/<cell>/ (default /tmp/p6-matrix/<cell>/).
#
#   SERIAL=emulator-5566 bash android/tools/kill-matrix.sh <cell> <method> [prompt]
#   methods: force-stop-foreground force-stop-idle kill9-foreground kill9-idle
#            am-kill-background trim-memory emu-kill
#
# Read the result with android/tools/kill-matrix-report.py.
# The `emu-kill` cell restarts the AVD named by $AVD (default pdsh-p6-5566).
set -uo pipefail

export ANDROID_HOME="${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}"
ADB="$ANDROID_HOME/platform-tools/adb"
SERIAL="${SERIAL:-emulator-5566}"
AVD="${AVD:-pdsh-p6-5566}"
P="${PDSH_PACKAGE:-com.phonedsh.app}"
CELL="${1:?usage: p6-kill.sh <cell> <method> [prompt]}"
METHOD="${2:?usage: p6-kill.sh <cell> <method> [prompt]}"
PROMPT="${3:-用 shell 工具执行这一条命令：sleep 20; echo slept。只做这一件事，然后把输出贴出来。}"
ART="${ART_ROOT:-/tmp/p6-matrix}/$CELL"
mkdir -p "$ART"

D() { "$ADB" -s "$SERIAL" "$@"; }

# A cheap, non-atomic probe for the moment before a kill: sizes and per-session
# line counts, no tar. The authoritative copy is the `after` snapshot, taken with
# the process dead.
probe() { # $1 = tag
  local tag="$1"
  {
    echo "pid=$(D shell pidof "$P" | tr -d '\r')"
    D shell "run-as $P sh -c 'ls -la files/xl/wal files/xl/journal files/xl/materialized/home/sessions/*/*/session.v4.jsonl 2>/dev/null'" | tr -d '\r'
  } > "$ART/$tag.state" 2>&1
  D logcat -d > "$ART/$tag.logcat" 2>/dev/null
}

# A quiescent snapshot: the app is force-stopped first, so the tar cannot race the
# materialized-tree exchange or the journal recovery window. A live tar over a
# recovering workspace really does read a stale/partial tree (measured 2026-11-01:
# 32 of 66 entries, journal/ absent), and evidence must not be that artifact.
snap() { # $1 = tag [keep-running]
  local tag="$1" keep="${2:-}"
  [ -z "$keep" ] && D shell am force-stop "$P"
  sleep 1
  D exec-out "run-as $P tar -cf - files/xl" > "$ART/$tag.xl.tar" 2>/dev/null
  D exec-out "run-as $P cat shared_prefs/pdsh_background_state.xml" > "$ART/$tag.prefs.xml" 2>/dev/null
  D logcat -d > "$ART/$tag.logcat" 2>/dev/null
  rm -rf "$ART/$tag.x"
  mkdir -p "$ART/$tag.x"
  tar -xf "$ART/$tag.xl.tar" -C "$ART/$tag.x" 2>/dev/null
  printf '%s' "$(D shell pidof "$P" | tr -d '\r')" > "$ART/$tag.pid"
}

mark() { printf '%s %s\n' "$(date +%H:%M:%S)" "$1" >> "$ART/timeline.txt"; }

assert_running() {
  if D logcat -d -s PDSHAppTurn 2>/dev/null | grep -qE "APP_TURN_OK|APP_TURN_FAILED"; then
    mark "WARNING turn already ended before the kill"
  else
    mark "assert: turn still open at kill time"
  fi
}

launch() {
  # One remote command string: `adb shell` joins its arguments, so an unquoted
  # multi-word prompt would arrive as `--es pdsh.prompt <first-word>` only.
  D shell "am start -W -n $P/.MainActivity --ez pdsh.face.probe true --es pdsh.deepseek.baseUrl 'https://api.deepseek.com/anthropic' --es pdsh.prompt '$PROMPT'" >/dev/null 2>&1
}

wait_ready() { # seconds
  local limit="${1:-90}" i
  for ((i = 0; i < limit; i++)); do
    D logcat -d -s PDSHAppTurn 2>/dev/null | grep -q APP_WORKER_READY && return 0
    sleep 1
  done
  return 1
}

tap_run() {
  D shell uiautomator dump /sdcard/p6.xml >/dev/null 2>&1
  D pull /sdcard/p6.xml "$ART/ui-run.xml" >/dev/null 2>&1
  local xy
  xy=$(python3 - "$ART/ui-run.xml" <<'PY'
import sys
import xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
for n in root.iter("node"):
    if (n.get("text") or "").strip() == "跑一轮" or (n.get("content-desc") or "").strip() == "跑一轮":
        b = n.get("bounds") or ""
        try:
            lt, rb = b.split("][")
            l, t = lt.lstrip("[").split(",")
            r, bo = rb.rstrip("]").split(",")
            print(f"{(int(l)+int(r))//2} {(int(t)+int(bo))//2}")
        except Exception:
            pass
        break
PY
)
  [ -z "$xy" ] && { echo "FAIL no run button"; return 1; }
  D shell input tap $xy
}

newest_session() {
  D shell "run-as $P sh -c 'ls -t files/xl/materialized/home/sessions/*/*/session.v4.jsonl 2>/dev/null | head -1'" | tr -d '\r'
}

# Progress is observed on the durable materialized session, not on logcat: the
# turn runner logs its host events only after the turn returns, so logcat says
# nothing while the turn is open.
wait_mid_turn() { # seconds; a NEW session (not $PRE_SESSION) with a tool/call and no turn/end
  local limit="${1:-90}" i s path calls ends
  for ((i = 0; i < limit; i++)); do
    if D logcat -d -s PDSHAppTurn 2>/dev/null | grep -qE "APP_TURN_OK|APP_TURN_FAILED"; then
      return 2
    fi
    path=$(newest_session)
    if [ -n "$path" ] && [ "$path" != "$PRE_SESSION" ]; then
      s=$(D shell "run-as $P sh -c 'grep -c \"tool/call\" $path; grep -c \"turn/end\" $path'" | tr -d '\r')
      calls=$(echo "$s" | sed -n 1p); ends=$(echo "$s" | sed -n 2p)
      if [ "${calls:-0}" -ge 1 ] && [ "${ends:-0}" -eq 0 ]; then
        mark "mid-turn: session=$path tool_calls=$calls"
        return 0
      fi
    fi
    sleep 1
  done
  return 1
}

start_cell() {
  rm -rf "$ART"; mkdir -p "$ART"; : > "$ART/timeline.txt"
  D shell am force-stop "$P"
  D shell "run-as $P rm -f files/xl/recovery-injected-marker" >/dev/null 2>&1
  D logcat -c
  PRE_SESSION=""
  mark "cold launch ($METHOD)"
  launch
  wait_ready 90 || { echo "FAIL worker never ready"; exit 1; }
  PRE_SESSION=$(newest_session)
  mark "worker ready (pre-turn session=${PRE_SESSION:--})"
}

# ---- the five kill methods -------------------------------------------------
do_force_stop() { mark "kill: am force-stop"; D shell am force-stop "$P"; }
do_kill9() { mark "kill: kill -9"; D shell "run-as $P kill -9 $(D shell pidof "$P" | tr -d '\r')"; }
do_am_kill() { mark "kill: am kill (background)"; D shell am kill "$P"; }
do_trim() { mark "kill: am send-trim-memory COMPLETE"; D shell am send-trim-memory "$P" COMPLETE; }
do_home() { mark "background: HOME"; D shell input keyevent KEYCODE_HOME; sleep 2; }

recover() {
  sleep 1
  mark "recovery: relaunch"
  D logcat -c
  D shell am start -W -n "$P/.MainActivity" >/dev/null 2>&1
  wait_ready 120 || { echo "WARN worker not ready after recovery"; }
  sleep 8
  mark "recovery: snapshot"
  D logcat -d > "$ART/recovered.logcat" 2>/dev/null
  D shell uiautomator dump /sdcard/p6.xml >/dev/null 2>&1
  D pull /sdcard/p6.xml "$ART/recovered.ui.xml" >/dev/null 2>&1
  snap recovered
}

case "$METHOD" in
force-stop-foreground)
  start_cell; tap_run; wait_mid_turn 60; probe before; assert_running; do_force_stop; sleep 1; snap after
  recover
  ;;
force-stop-idle)
  start_cell; tap_run
  for i in $(seq 1 150); do D logcat -d -s PDSHAppTurn 2>/dev/null | grep -qE "APP_TURN_OK|APP_TURN_FAILED" && break; sleep 1; done
  sleep 10; probe before; do_force_stop; sleep 1; snap after
  recover
  ;;
kill9-foreground)
  start_cell; tap_run; wait_mid_turn 60; probe before; assert_running; do_kill9; sleep 1; snap after
  recover
  ;;
kill9-idle)
  start_cell; tap_run
  for i in $(seq 1 150); do D logcat -d -s PDSHAppTurn 2>/dev/null | grep -qE "APP_TURN_OK|APP_TURN_FAILED" && break; sleep 1; done
  sleep 10; probe before; do_kill9; sleep 1; snap after
  recover
  ;;
am-kill-background)
  start_cell; tap_run; wait_mid_turn 60; do_home; sleep 1; probe before; assert_running; do_am_kill; sleep 1; snap after
  recover
  ;;
trim-memory)
  start_cell; tap_run; wait_mid_turn 60
  probe before; assert_running
  do_trim
  sleep 3
  probe after-trim      # proves the process survived the trim callback
  do_home; sleep 2
  do_am_kill            # the closest real low-memory-class kill this box can do
  sleep 1
  snap after-kill
  recover
  ;;
emu-kill)
  start_cell; tap_run; wait_mid_turn 60; probe before; assert_running
  mark "kill: adb emu kill (VM abrupt)"
  # The whole VM goes away. The emulator process is killed without a guest shutdown,
  # which is not a storage-level power cut but is the closest this box offers.
  "$ADB" -s "$SERIAL" emu kill || true
  for i in $(seq 1 60); do "$ADB" -s "$SERIAL" get-state >/dev/null 2>&1 || break; sleep 1; done
  sleep 3
  mark "recovery: cold boot"
  nohup "$ANDROID_HOME/emulator/emulator" -avd "$AVD" -port "${AVD_PORT:-5566}" -no-window -no-audio \
    -no-boot-anim -no-snapshot -gpu swiftshader_indirect > /tmp/p6-emu-5566.log 2>&1 &
  "$ADB" -s "$SERIAL" wait-for-device
  for i in $(seq 1 120); do
    [ "$("$ADB" -s "$SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ] && break
    sleep 2
  done
  sleep 10
  mark "recovery: snapshot after cold boot"
  snap after-reboot
  D logcat -c
  launch
  wait_ready 120 || true
  sleep 8
  snap recovered
  ;;
*)
  echo "unknown method: $METHOD"; exit 2;;
esac

mark "cell done"
echo "== $CELL / $METHOD"
ls -la "$ART" | head
