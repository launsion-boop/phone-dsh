#!/bin/bash
# SPDX-License-Identifier: MIT
#
# macOS Phase 0 probes and the kill matrix (PLAN W3-PROBES and W3-KILL, G0).
#
# Runs two test targets:
#   * PhoneDSHProbeTests — channel probes in a real WKWebView Worker fed by the
#     real loopback origin, timer throttling, the JavaScriptCore/WKWebView
#     benchmark and the 100-file WorkspaceLog checkpoint;
#   * PhoneDSHKillTests — 20 seeded kills across the three kill kinds and four
#     timings, each followed by recovery and WAL/materialized/step assertions.
#
# Output: $TMPDIR/pdsh-probes/probe-report.json and kill-report.json. The report
# table is printed after both targets finish; a missing report, a gating FAIL or
# a test-process failure makes the script exit non-zero.
#
# Usage: bash scripts/ci/probes.sh
# Env:   PDSH_PROBES_DIR  output directory (default $TMPDIR/pdsh-probes)

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
BASE_DIR="${TMPDIR:-/tmp}"
BASE_DIR="${BASE_DIR%/}"
PROBE_DIR="${PDSH_PROBES_DIR:-$BASE_DIR/pdsh-probes}"
PROBE_DIR="${PROBE_DIR%/}"
mkdir -p "$PROBE_DIR"
PROBE_LOG="$PROBE_DIR/probes.log"
KILL_LOG="$PROBE_DIR/kill.log"
REPORT="$PROBE_DIR/probe-report.json"
KILL_REPORT="$PROBE_DIR/kill-report.json"
rm -f "$REPORT" "$KILL_REPORT" "$PROBE_LOG" "$KILL_LOG"
export PDSH_PROBES_DIR="$PROBE_DIR"

echo "probes: repo $ROOT"
echo "probes: output $PROBE_DIR"

probe_rc=0
kill_rc=0
set +e
echo "probes: running PhoneDSHProbeTests"
( cd "$ROOT" && swift test --disable-sandbox --filter PhoneDSHProbe ) \
  > "$PROBE_LOG" 2>&1
probe_rc=$?
echo "probes: running PhoneDSHKillTests"
( cd "$ROOT" && swift test --disable-sandbox --filter PhoneDSHKill ) \
  > "$KILL_LOG" 2>&1
kill_rc=$?
set -e

report_rc=0
echo ""
echo "probe report: $REPORT"
python3 - "$REPORT" <<'PY' || report_rc=$?
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        report = json.load(handle)
except Exception as error:  # noqa: BLE001 - diagnostics only
    print(f"FAIL: cannot read the probe report: {error}")
    raise SystemExit(1)

rows = report.get("rows", [])
print(f"{'probe':<44} {'status':<5} {'measurement':<42} threshold")
interesting = (
    "p95_ms", "elapsed_ms", "first_chunk_ms", "total_ms", "append_100_ms",
    "close_epoch_ms", "ratio", "speedup_ratio", "visible_ticks",
    "hidden_ticks", "offscreen_ticks", "crossOriginIsolated",
    "worker_crossOriginIsolated", "secure_context", "coop_header", "coep_header",
)
for row in rows:
    metrics = row.get("metrics") or {}
    parts = []
    for key in interesting:
        if key in metrics:
            value = metrics[key]
            if isinstance(value, float):
                value = f"{value:.2f}"
            parts.append(f"{key}={value}")
    measurement = " ".join(parts)[:42]
    threshold = ""
    spec = row.get("threshold")
    if spec and spec.get("name") not in (None, "none"):
        threshold = (f"{spec.get('name')} {spec.get('comparison')} "
                     f"{spec.get('value')} {spec.get('unit', '')} "
                     f"[{'met' if spec.get('met') else 'not met'}]")
    print(f"{row.get('probe', '?'):<44} {row.get('status', '?'):<5} "
          f"{measurement:<42} {threshold}")

summary = report.get("summary", {})
print("")
print(f"G0 summary: pass={summary.get('pass', 0)} fail={summary.get('fail', 0)} "
      f"info={summary.get('info', 0)} g0_passed={summary.get('g0_passed', False)}")
failed = summary.get("failed_gating_probes") or []
if failed:
    print("G0 gating failures: " + ", ".join(failed))
raise SystemExit(0 if summary.get("g0_passed") else 1)
PY

kill_report_rc=0
if [ -f "$KILL_REPORT" ]; then
  echo ""
  echo "kill report: $KILL_REPORT"
  python3 - "$KILL_REPORT" <<'PY' || kill_report_rc=$?
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        report = json.load(handle)
except Exception as error:  # noqa: BLE001 - diagnostics only
    print(f"FAIL: cannot read the kill report: {error}")
    raise SystemExit(1)

print(f"{'#':<3} {'kill kind':<20} {'timing':<20} result")
for row in report.get("rows", []):
    print(f"{row.get('index', '?'):<3} {row.get('kind', '?'):<20} "
          f"{row.get('timing', '?'):<20} "
          f"{'PASS' if row.get('passed') else 'FAIL'}")
print("")
print(f"kill matrix: {report.get('passed', 0)}/{report.get('iterations', 0)} iterations passed")
raise SystemExit(0 if report.get("failed", 1) == 0 else 1)
PY
else
  kill_report_rc=1
fi

executed_probe=$(grep -Eo "Executed [1-9][0-9]* test" "$PROBE_LOG" | head -1 || true)
executed_kill=$(grep -Eo "Executed [1-9][0-9]* test" "$KILL_LOG" | head -1 || true)

status=0
if [ "$probe_rc" -ne 0 ]; then
  echo "FAIL: PhoneDSHProbeTests exited $probe_rc"
  status=1
fi
if [ "$kill_rc" -ne 0 ]; then
  echo "FAIL: PhoneDSHKillTests exited $kill_rc"
  status=1
fi
if [ -z "$executed_probe" ]; then
  echo "FAIL: the probe target executed no tests"
  status=1
fi
if [ -z "$executed_kill" ]; then
  echo "FAIL: the kill target executed no tests"
  status=1
fi
if [ "$report_rc" -ne 0 ]; then
  echo "FAIL: the probe report has a gating failure or is missing"
  status=1
fi
if [ "$kill_report_rc" -ne 0 ]; then
  echo "FAIL: the kill report is missing or has failures"
  status=1
fi

if [ "$status" -ne 0 ]; then
  echo ""
  echo "== PhoneDSHProbeTests log (last 40 lines) =="
  tail -40 "$PROBE_LOG" 2>/dev/null || true
  echo ""
  echo "== PhoneDSHKillTests log (last 40 lines) =="
  tail -40 "$KILL_LOG" 2>/dev/null || true
else
  echo ""
  echo "probes: PASS ($executed_probe; $executed_kill)"
fi
exit "$status"
