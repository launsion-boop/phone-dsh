#!/bin/bash
# SPDX-License-Identifier: MIT
# Regression for the enrollment console task stack (ble-secure-session.md §3.2
# console; on-air run 2026-11-08: the 4096-byte task overflowed on `begin`).
# Compiles the real pdsh_enroll.c with -fstack-usage and requires the deepest
# console path (pdsh_enroll_feed/process_line/command + emit) plus a reserve
# for console_task, printf and the console VFS to fit
# PDSH_ENROLL_CONSOLE_STACK, and main.c to create the task with that constant.
# Host frame sizes approximate the Xtensa ones (measured: emit 2896 +
# process_line 1408 on the device build, 2960 + 1552 on host clang -Os).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MAIN="$ROOT/firmware/esp32-reference/main"
CJSON="$ROOT/firmware/esp32-reference/managed_components/espressif__cjson/cJSON"
OUT="$ROOT/.build/link-host/enroll-stack"
RESERVE=2048
rm -rf "$OUT" && mkdir -p "$OUT"
(cd "$OUT" && cc -std=c11 -Os -D_DEFAULT_SOURCE -fstack-usage -I"$ROOT/firmware/tests/stubs" -I"$MAIN" -I"$CJSON" \
  -c "$MAIN/pdsh_enroll.c" -o enroll.o)
SU="$(ls "$OUT"/*.su)"
frame() { awk -F'\t' -v f="$1" '{split($1, a, ":"); n=a[length(a)]; sub(/\..*/, "", n); if (n == f && $2 > m) m = $2} END {print m + 0}' "$SU"; }
EMIT=$(frame emit)
PATHMAX=0
for f in pdsh_enroll_feed process_line command; do v=$(frame "$f"); PATHMAX=$((PATHMAX + v)); done
LIMIT=$(sed -n 's/^#define PDSH_ENROLL_CONSOLE_STACK \([0-9]*\)u.*/\1/p' "$MAIN/pdsh_enroll.h")
NEED=$((EMIT + PATHMAX + RESERVE))
echo "enroll console stack: emit=$EMIT path=$PATHMAX reserve=$RESERVE need=$NEED limit=${LIMIT:-missing}"
[ -n "$LIMIT" ] && [ "$EMIT" -gt 0 ] && [ "$NEED" -le "$LIMIT" ] || { echo "FAIL: enrollment console stack budget" >&2; exit 1; }
grep -q 'xTaskCreate(console_task, "pdsh_enroll", PDSH_ENROLL_CONSOLE_STACK,' "$ROOT/firmware/esp32-reference/main/main.c" \
  || { echo "FAIL: main.c does not size the console task with PDSH_ENROLL_CONSOLE_STACK" >&2; exit 1; }
echo "PASS enroll console stack"
