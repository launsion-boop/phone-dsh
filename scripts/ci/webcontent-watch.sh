#!/bin/bash
# SPDX-License-Identifier: MIT
#
# phone-dsh phone DSH — the device-scoped iOS Simulator WebContent watcher.
#
# The sandboxed simulator test process cannot signal a host process. This
# script is the one watcher implementation used by both simulator flows:
#
#   * `sim.sh` smoke handshake: create `expect-real-kill` in the app's current
#     report container, then wait for `real-kill-ready.json` written by the
#     smoke suite while its real WKWebView is alive; SIGKILL the selected
#     simulator's WebContent process and write `real-kill-result.json`. The
#     smoke suite then gates recovery of the same Session and a follow-up turn
#     after that real kill. The expectation marker is written after every
#     `resolve_directory`, so an xcodebuild reinstall that migrates the data
#     container cannot leave the handshake in the old path.
#   * scenario handshake: `scenarios.sh --run-on sim` starts this watcher next
#     to the catalog run; the runner writes `<token>.request` into the results
#     tree for a `webcontent_kill` perturbation and waits for `<token>.result`.
#     The request/result pair is how the G2 perturbation reaches a real
#     WebContent process from inside the simulator sandbox.
#
# Pid selection is device-scoped and evidence-based: the command must contain
# the `CoreSimulator` runtime path and the WebKit WebContent executable path,
# and the process environment must carry `SIMULATOR_UDID=<selected udid>`.
# Host processes (Safari, other simulators, other users' apps) carry neither.
# Pids already alive when the watcher starts are excluded so only the test
# run's own WebContent process can be signalled.
#
# Usage:
#   webcontent-watch.sh smoke    --udid <UDID> --directory <report-dir> [--bundle-id <id>]
#   webcontent-watch.sh scenario --udid <UDID> --directory <handshake-dir>
#
# Exit: 0 after the smoke result was written; the scenario mode runs until the
# caller stops it.

set -uo pipefail

MODE=""
UDID=""
DIRECTORY=""
BUNDLE_ID=""
EXPECT_NAME=""

usage() {
  sed -n '2,42p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    smoke|scenario)
      MODE="$1"; shift ;;
    --udid)
      [ "$#" -ge 2 ] || { echo "webcontent-watch: --udid needs a value" >&2; exit 2; }
      UDID="$2"; shift 2 ;;
    --directory)
      [ "$#" -ge 2 ] || { echo "webcontent-watch: --directory needs a value" >&2; exit 2; }
      DIRECTORY="$2"; shift 2 ;;
    --bundle-id)
      [ "$#" -ge 2 ] || { echo "webcontent-watch: --bundle-id needs a value" >&2; exit 2; }
      BUNDLE_ID="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "webcontent-watch: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -z "$MODE" ] || [ -z "$UDID" ] || [ -z "$DIRECTORY" ]; then
  usage >&2
  exit 2
fi

log() { echo "webcontent-watch: $*"; }

webcontent_pids() {
  xcrun simctl spawn "$UDID" /bin/ps -A -E -o pid=,command= 2>/dev/null \
    | awk -v udid="SIMULATOR_UDID=$UDID" \
        -v runtime="CoreSimulator" \
        -v marker="com.apple.WebKit.WebContent" \
        'index($0, udid) > 0 && index($0, runtime) > 0 && index($0, marker) > 0 {print $1}' \
    | sort -u
}

# The app container path is outside the caller's writable sandbox, so results
# are written through the selected simulator's launchd (the test process reads
# the same files from inside the container).
container_write() { # <container path> <content>
  xcrun simctl spawn "$UDID" /bin/sh -c \
    'printf "%s\n" "$1" > "$2.tmp" && /bin/mv "$2.tmp" "$2"' \
    container-write "$2" "$1" 2>/dev/null
}

# A hosted test run can reinstall the app and move its data container. When the
# caller passes --bundle-id, follow the current container instead of the path
# captured before the run, so a marker written after the move is still seen.
resolve_directory() {
  [ -n "$BUNDLE_ID" ] || return 0
  local current candidate
  current="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data 2>/dev/null || true)"
  [ -n "$current" ] || return 0
  candidate="$current/Documents/pdsh-reports"
  [ -d "$candidate" ] || return 0
  DIRECTORY="$candidate"
}

# Fills TARGETS (WebContent pids not alive before the run) and SENT (those that
# accepted SIGKILL). Shared by both modes.
TARGETS=""
SENT=""
kill_new_webcontent() {
  TARGETS=""
  SENT=""
  for pid in $(webcontent_pids); do
    case " $BASELINE_PIDS " in
      *" $pid "*) ;;
      *) TARGETS="$TARGETS $pid" ;;
    esac
  done
  for pid in $TARGETS; do
    if xcrun simctl spawn "$UDID" /bin/kill -9 "$pid" 2>/dev/null; then
      SENT="$SENT $pid"
    fi
  done
}

BASELINE_PIDS="$(webcontent_pids | tr '\n' ' ')"
log "baseline (selected simulator): ${BASELINE_PIDS:-none}"

if [ "$MODE" = "smoke" ]; then
  READY_NAME="real-kill-ready.json"
  RESULT_NAME="real-kill-result.json"
  EXPECT_NAME="expect-real-kill"
  # The expectation marker belongs to the directory this watcher currently
  # resolves, not to the path captured by `sim.sh` before `xcodebuild test`
  # installed the app. A hosted test run can move the data container; writing
  # the marker after every resolve keeps the handshake visible in the new one
  # instead of silently degrading to NOT_RUN.
  write_expectation() {
    [ -n "$EXPECT_NAME" ] || return 0
    [ -f "$DIRECTORY/$EXPECT_NAME" ] && return 0
    container_write "$DIRECTORY/$EXPECT_NAME" "expected"
  }
  while :; do
    resolve_directory
    write_expectation
    if [ -f "$DIRECTORY/$READY_NAME" ]; then
      kill_new_webcontent
      if [ -n "${SENT// /}" ]; then
        status="attempted: SIGKILL sent to selected-simulator WebContent pid(s)$SENT"
      elif [ -n "${TARGETS// /}" ]; then
        status="unavailable: selected-simulator WebContent pid(s)$TARGETS rejected SIGKILL"
      else
        status="unavailable: no new WebContent process of the selected simulator was alive"
      fi
      container_write "$DIRECTORY/$RESULT_NAME" \
        "$(printf '{"status":"%s","pids":"%s"}' "$status" "${TARGETS// /}")"
      log "$status"
      exit 0
    fi
    sleep 0.25
  done
fi

# Scenario mode: one request/result pair per webcontent_kill perturbation.
log "watching $DIRECTORY for scenario kill requests"
while :; do
  resolve_directory
  for request in "$DIRECTORY"/*.request; do
    [ -f "$request" ] || continue
    base="${request%.request}"
    [ -f "$base.result" ] && continue
    kill_new_webcontent
    if [ -n "${SENT// /}" ]; then
      status="killed"
      log "SIGKILL sent to selected-simulator WebContent pid(s)$SENT for $(basename "$base")"
    elif [ -n "${TARGETS// /}" ]; then
      status="unavailable: selected-simulator WebContent pid(s)$TARGETS rejected SIGKILL"
      log "$status"
    else
      status="unavailable: no new WebContent process of the selected simulator was alive"
      log "$status"
    fi
    container_write "$base.result" \
      "$(printf '{"status":"%s","pids":"%s"}' "$status" "${SENT// /}")"
  done
  sleep 0.25
done
