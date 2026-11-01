#!/usr/bin/env bash
# Capture the official DSH Web UI at the iPhone-parity viewport
# (CSS 402×874, DPR 3, light) into docs/receipts/ios-session-audit/screens/official/.
#
# Why this exists: serving apps/web/dist with a static file server cannot boot
# the official UI — the real `dsh web` server injects the
# `window.__ModuleLoader__` bootstrap and the plugin preload map. This script
# boots that server from the official checkout, waits for its authenticated URL,
# and then drives headless Chrome over the DevTools Protocol (the page keeps a
# WebSocket open, so `chrome --headless --screenshot` never returns).
#
# It fails loudly: no URL, a shell without `__ModuleLoader__`, an app that never
# mounts, a console error marker, or a wrong PNG size all exit non-zero.
#
# Session states: the sessionless hero alone cannot validate the chat layout, so
# this harness also opens recorded sessions. It copies the real DSH_HOME into the
# temporary work dir (the real one is only read), boots the same server against
# that copy, and drives the real UI: drawer -> group -> session row -> transcript.
# The copy exists because opening a V3 session migrates it in place.
#
# The local history only holds single-turn MISSING_CREDENTIAL failures, so four
# of the copied sessions are replaced (in the copy only) by official recorded
# fixtures, seeded through the official JsonlSessionPersistence API
# (`seed-official-session.mjs`):
#   - snapshots/session/bash-tool-turn          -> assistant markdown + bash tool card
#   - snapshots/web/question-composer           -> answered ask_user_question card
#   - snapshots/web/plan-review                 -> approved exit_plan_mode plan card
#   - snapshots/session/subagent-spawn-in-process -> session-header subagent
#     catalog count + an expanded `subagent` tool row (child id + started state)
# Both web fixtures carry their `tool/result`, so they are the SETTLED states
# (answered / approved); the pending review takeover is not fabricated. The
# subagent fixture carries `tool/result` too, and its `subagent/catalog` event
# is what the header renders as "1 个子智能体" — the count is projected from the
# logged catalog, never typed into the DOM.
#
# Usage:
#   scripts/ios-parity/golden/capture-official.sh          # hero + auth + 7 sessions
#   SKIP_SESSION=1 scripts/ios-parity/golden/capture-official.sh   # hero + auth only
#
# Environment overrides:
#   DSH_OFFICIAL_REPO       official deepseek-harness checkout
#   DSH_GOLDEN_OUT_DIR      output directory
#   NODE_BIN                node >= 22.19 (Cellar paths are auto-detected)
#   CHROME_BIN              Google Chrome executable
#   DSH_GOLDEN_PORT         fixed port (default 0 = OS-assigned)
#   DSH_GOLDEN_SESSION_HOME source DSH_HOME copied for the session capture (default ~/.dsh)
#   DSH_GOLDEN_SESSION_ID   short session to open (default session-ca5b4ecd-da54-488a-b11b-2df2dcae94f2)
#   DSH_GOLDEN_SESSION_LONG_ID  long-prompt session to open (default session-d81de3d6-526a-4894-b3aa-1520db906f62)
#   DSH_GOLDEN_TOOL_SESSION_ID  session replaced by the bash-tool-turn fixture (default session-4f117741-269b-464e-a2cc-4c121c50531c)
#   DSH_GOLDEN_TOOL_FIXTURE official recorded fixture (default <repo>/snapshots/session/bash-tool-turn/session.v4.jsonl)
#   DSH_GOLDEN_QUESTION_SESSION_ID  session replaced by the question fixture (default session-08d252dc-f487-42c1-9b87-68467f70f1e2)
#   DSH_GOLDEN_QUESTION_FIXTURE  question fixture (default <repo>/snapshots/web/question-composer/session.v4.jsonl)
#   DSH_GOLDEN_QUESTION_EXPECTED  state proof for the question capture
#                                (default <repo>/snapshots/web/question-composer/answered-expanded.expected.md)
#   DSH_GOLDEN_QUESTION_PENDING_EXPECTED  pending state that this fixture does NOT render
#                                (default <repo>/snapshots/web/question-composer/ui.expected.md)
#   DSH_GOLDEN_PLAN_SESSION_ID  session replaced by the plan fixture (default session-1b0222d8-77f1-40b2-9ff4-13ee4a69164c)
#   DSH_GOLDEN_PLAN_FIXTURE  plan fixture (default <repo>/snapshots/web/plan-review/session.v4.jsonl)
#   DSH_GOLDEN_PLAN_CREATED_AT  clock anchor for the plan fixture (default 1788240594856:
#                                the v4 header reset createdAt to 0, its official v2 sibling recorded this value)
#   DSH_GOLDEN_PLAN_EXPECTED  state proof for the plan capture
#                                (default <repo>/snapshots/web/plan-review/approved.expected.md)
#   DSH_GOLDEN_PLAN_PENDING_EXPECTED  pending state that this fixture does NOT render
#                                (default <repo>/snapshots/web/plan-review/review.expected.md)
#   DSH_GOLDEN_SUBAGENT_SESSION_ID  session replaced by the subagent fixture (default session-ff9414c5-36db-4327-955e-84d7fa18547c)
#   DSH_GOLDEN_SUBAGENT_FIXTURE  subagent fixture (default <repo>/snapshots/session/subagent-spawn-in-process/session.v4.jsonl)
#   DSH_GOLDEN_SUBAGENT_PARALLEL_SESSION_ID  session replaced by the parallel-subagent fixture
#                                (default session-d6126d5c-82a0-4de9-9f58-14205fcc27fb)
#   DSH_GOLDEN_SUBAGENT_PARALLEL_FIXTURE  parallel-subagent fixture
#                                (default <repo>/snapshots/session/subagent-parallel/session.v4.jsonl)
#   SKIP_SESSION=1          hero + auth only, no DSH_HOME copy
#   KEEP_WORK_DIR=1         keep the temporary DSH_HOME / server log / cookies
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

OFFICIAL_REPO="${DSH_OFFICIAL_REPO:-/Users/leilangsheng/Documents/Codex/2026-08-14/https-github-com-deepseek-ai-deepseek/deepseek-harness}"
OUT_DIR="${DSH_GOLDEN_OUT_DIR:-$REPO_ROOT/docs/receipts/ios-session-audit/screens/official}"
REPORTS_DIR="$OUT_DIR/reports"
CHROME_BIN="${CHROME_BIN:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
DSH_GOLDEN_PORT="${DSH_GOLDEN_PORT:-0}"

HERO_PNG="$OUT_DIR/official-hero-sessionless-402x874-dpr3.png"
HERO_REPORT="$REPORTS_DIR/official-hero-sessionless-402x874-dpr3.json"
AUTH_PNG="$OUT_DIR/official-auth-gate-402x874-dpr3.png"
AUTH_REPORT="$REPORTS_DIR/official-auth-gate-402x874-dpr3.json"
SESSION_PNG="$OUT_DIR/official-session-chat-402x874-dpr3.png"
SESSION_REPORT="$REPORTS_DIR/official-session-chat-402x874-dpr3.json"
SESSION_LONG_PNG="$OUT_DIR/official-session-chat-long-user-turn-402x874-dpr3.png"
SESSION_LONG_REPORT="$REPORTS_DIR/official-session-chat-long-user-turn-402x874-dpr3.json"
TOOL_PNG="$OUT_DIR/official-session-chat-tool-402x874-dpr3.png"
TOOL_REPORT="$REPORTS_DIR/official-session-chat-tool-402x874-dpr3.json"
QUESTION_PNG="$OUT_DIR/official-session-question-402x874-dpr3.png"
QUESTION_REPORT="$REPORTS_DIR/official-session-question-402x874-dpr3.json"
PLAN_PNG="$OUT_DIR/official-session-plan-402x874-dpr3.png"
PLAN_REPORT="$REPORTS_DIR/official-session-plan-402x874-dpr3.json"
SUBAGENT_PNG="$OUT_DIR/official-session-subagent-402x874-dpr3.png"
SUBAGENT_REPORT="$REPORTS_DIR/official-session-subagent-402x874-dpr3.json"
SUBAGENT_PARALLEL_PNG="$OUT_DIR/official-session-subagent-parallel-402x874-dpr3.png"
SUBAGENT_PARALLEL_REPORT="$REPORTS_DIR/official-session-subagent-parallel-402x874-dpr3.json"

SESSION_SOURCE="${DSH_GOLDEN_SESSION_HOME:-$HOME/.dsh}"
SESSION_ID="${DSH_GOLDEN_SESSION_ID:-session-ca5b4ecd-da54-488a-b11b-2df2dcae94f2}"
SESSION_LONG_ID="${DSH_GOLDEN_SESSION_LONG_ID:-session-d81de3d6-526a-4894-b3aa-1520db906f62}"
TOOL_SESSION_ID="${DSH_GOLDEN_TOOL_SESSION_ID:-session-4f117741-269b-464e-a2cc-4c121c50531c}"
TOOL_FIXTURE="${DSH_GOLDEN_TOOL_FIXTURE:-$OFFICIAL_REPO/snapshots/session/bash-tool-turn/session.v4.jsonl}"
QUESTION_SESSION_ID="${DSH_GOLDEN_QUESTION_SESSION_ID:-session-08d252dc-f487-42c1-9b87-68467f70f1e2}"
QUESTION_FIXTURE="${DSH_GOLDEN_QUESTION_FIXTURE:-$OFFICIAL_REPO/snapshots/web/question-composer/session.v4.jsonl}"
QUESTION_EXPECTED="${DSH_GOLDEN_QUESTION_EXPECTED:-$OFFICIAL_REPO/snapshots/web/question-composer/answered-expanded.expected.md}"
QUESTION_PENDING_EXPECTED="${DSH_GOLDEN_QUESTION_PENDING_EXPECTED:-$OFFICIAL_REPO/snapshots/web/question-composer/ui.expected.md}"
PLAN_SESSION_ID="${DSH_GOLDEN_PLAN_SESSION_ID:-session-1b0222d8-77f1-40b2-9ff4-13ee4a69164c}"
PLAN_FIXTURE="${DSH_GOLDEN_PLAN_FIXTURE:-$OFFICIAL_REPO/snapshots/web/plan-review/session.v4.jsonl}"
PLAN_CREATED_AT="${DSH_GOLDEN_PLAN_CREATED_AT:-1788240594856}"
PLAN_EXPECTED="${DSH_GOLDEN_PLAN_EXPECTED:-$OFFICIAL_REPO/snapshots/web/plan-review/approved.expected.md}"
PLAN_PENDING_EXPECTED="${DSH_GOLDEN_PLAN_PENDING_EXPECTED:-$OFFICIAL_REPO/snapshots/web/plan-review/review.expected.md}"
SUBAGENT_SESSION_ID="${DSH_GOLDEN_SUBAGENT_SESSION_ID:-session-ff9414c5-36db-4327-955e-84d7fa18547c}"
SUBAGENT_FIXTURE="${DSH_GOLDEN_SUBAGENT_FIXTURE:-$OFFICIAL_REPO/snapshots/session/subagent-spawn-in-process/session.v4.jsonl}"
SUBAGENT_PARALLEL_SESSION_ID="${DSH_GOLDEN_SUBAGENT_PARALLEL_SESSION_ID:-session-d6126d5c-82a0-4de9-9f58-14205fcc27fb}"
SUBAGENT_PARALLEL_FIXTURE="${DSH_GOLDEN_SUBAGENT_PARALLEL_FIXTURE:-$OFFICIAL_REPO/snapshots/session/subagent-parallel/session.v4.jsonl}"
SESSION_CAPTURE=1
if [[ "${SKIP_SESSION:-0}" == "1" ]]; then
  SESSION_CAPTURE=0
fi

die() {
  echo "" >&2
  echo "ERROR: $*" >&2
  exit 1
}

note() { echo "==> $*"; }

# ---------------------------------------------------------------- prerequisites

[[ -d "$OFFICIAL_REPO" ]] \
  || die "official repository not found: $OFFICIAL_REPO (set DSH_OFFICIAL_REPO)"
[[ -f "$OFFICIAL_REPO/apps/cli/lib/bin.js" ]] \
  || die "missing built CLI: $OFFICIAL_REPO/apps/cli/lib/bin.js
  Build the official checkout first (from the repo root):
    export PATH=\"\$(dirname \"\$NODE_BIN\"):\$PATH\"
    pnpm install
    pnpm build            # or: pnpm run build:lib && pnpm run build:web"
[[ -f "$OFFICIAL_REPO/apps/web/dist/index.html" ]] \
  || die "missing frontend build: $OFFICIAL_REPO/apps/web/dist/index.html (run: pnpm run build:web)"
[[ -x "$CHROME_BIN" ]] \
  || die "Google Chrome not found at: $CHROME_BIN (set CHROME_BIN)"

resolve_node() {
  if [[ -n "${NODE_BIN:-}" ]]; then
    printf '%s\n' "$NODE_BIN"
    return 0
  fi
  local candidates=() candidate cmd
  shopt -s nullglob
  candidates+=(/opt/homebrew/Cellar/node@22/*/bin/node)
  candidates+=(/opt/homebrew/Cellar/node@24/*/bin/node)
  candidates+=(/usr/local/Cellar/node@22/*/bin/node)
  candidates+=(/opt/homebrew/Cellar/node@20/*/bin/node)
  shopt -u nullglob
  cmd="$(command -v node 2>/dev/null || true)"
  [[ -n "$cmd" ]] && candidates+=("$cmd")
  for candidate in "${candidates[@]}"; do
    [[ -x "$candidate" ]] || continue
    if "$candidate" -e 'const [a, b] = process.versions.node.split(".").map(Number); process.exit(a > 22 || (a === 22 && b >= 19) ? 0 : 1)' 2>/dev/null; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

NODE_BIN="$(resolve_node || true)"
[[ -n "$NODE_BIN" && -x "$NODE_BIN" ]] \
  || die "no Node >= 22.19 found (official engines require ^22.19.0 || >=24.0.0); set NODE_BIN=... or add the Homebrew Cellar bin to PATH"
NODE_VERSION="$("$NODE_BIN" --version)"
CHROME_VERSION="$("$CHROME_BIN" --version 2>/dev/null | tr -d '\r' | sed -E 's/[[:space:]]+$//' || true)"
[[ -n "$CHROME_VERSION" ]] || CHROME_VERSION="unknown"

# Read .git without invoking git (the audit is not allowed to run git commands).
resolve_commit() {
  local repo="$1" gitdir head ref
  if [[ -d "$repo/.git" ]]; then
    gitdir="$repo/.git"
  elif [[ -f "$repo/.git" ]]; then
    gitdir="$(sed -n 's/^gitdir: //p' "$repo/.git")"
    [[ "$gitdir" == /* ]] || gitdir="$repo/$gitdir"
  else
    return 1
  fi
  [[ -f "$gitdir/HEAD" ]] || return 1
  head="$(tr -d '\r\n' < "$gitdir/HEAD")"
  if [[ "$head" == ref:\ * ]]; then
    ref="${head#ref: }"
    [[ -f "$gitdir/$ref" ]] || return 1
    tr -d '\r\n' < "$gitdir/$ref"
  else
    printf '%s\n' "$head"
  fi
}
COMMIT="$(resolve_commit "$OFFICIAL_REPO" || true)"
[[ -n "$COMMIT" ]] || die "could not read the official checkout commit from $OFFICIAL_REPO/.git/HEAD"
if [[ "$COMMIT" != 7be5505b0be06009d74891c869063c9cf19a0df0 ]]; then
  echo "WARNING: official checkout is at commit $COMMIT, audit baseline is 7be5505b0be06009d74891c869063c9cf19a0df0" >&2
fi
PKG_VERSION="$("$NODE_BIN" -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).version)' "$OFFICIAL_REPO/package.json")"

note "official repo: $OFFICIAL_REPO"
note "commit: $COMMIT (version $PKG_VERSION)"
note "node: $NODE_VERSION ($NODE_BIN)"
note "chrome: $CHROME_VERSION"

# ------------------------------------------------------------- temporary state

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dsh-golden.XXXXXX")"
PRISTINE_HOME="$WORK_DIR/dsh-home-pristine"
SESSION_HOME="$WORK_DIR/dsh-home-session"
SERVER_LOG="$WORK_DIR/dsh-web.log"
SESSION_SERVER_LOG="$WORK_DIR/dsh-web-session.log"
SEED_REPORT="$WORK_DIR/seed-tool-session.json"
QUESTION_SEED_REPORT="$WORK_DIR/seed-question-session.json"
PLAN_SEED_REPORT="$WORK_DIR/seed-plan-session.json"
SUBAGENT_SEED_REPORT="$WORK_DIR/seed-subagent-session.json"
SUBAGENT_PARALLEL_SEED_REPORT="$WORK_DIR/seed-subagent-parallel-session.json"
SHELL_HTML="$WORK_DIR/shell.html"
SESSION_SHELL_HTML="$WORK_DIR/shell-session.html"
COOKIE_JAR="$WORK_DIR/cookies.txt"
SESSION_COOKIE_JAR="$WORK_DIR/cookies-session.txt"
SERVER_PID=""
STARTED_URL=""
STARTED_PORT=""
URL=""
PORT=""
SESSION_URL=""
SESSION_PORT=""
mkdir -p "$PRISTINE_HOME" "$OUT_DIR" "$REPORTS_DIR"

cleanup() {
  local status=$?
  trap - EXIT INT TERM
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  if [[ "${KEEP_WORK_DIR:-0}" == "1" ]]; then
    echo "kept work dir: $WORK_DIR"
  else
    rm -rf "$WORK_DIR"
  fi
  exit "$status"
}
trap cleanup EXIT INT TERM

# ------------------------------------------------------------ server control

# Boot `dsh web` against one DSH_HOME and prove the served shell carries the real
# module-loader bootstrap. Sets STARTED_URL / STARTED_PORT; SERVER_PID is the node
# process so cleanup and stop_server can reap it.
start_server() {
  local home="$1" log="$2" shell="$3" jar="$4" redacted=""
  note "booting official web profile (port $DSH_GOLDEN_PORT, DSH_HOME=$home)"
  cd "$OFFICIAL_REPO"
  DSH_HOME="$home" \
  PATH="$(dirname "$NODE_BIN"):$PATH" \
    "$NODE_BIN" apps/cli/lib/bin.js --profile web --no-open --host 127.0.0.1 --port "$DSH_GOLDEN_PORT" \
    >"$log" 2>&1 &
  SERVER_PID=$!
  cd "$REPO_ROOT"

  STARTED_URL=""
  for _ in $(seq 1 300); do
    STARTED_URL="$(grep -Eo 'dsh web: https?://[^[:space:]]+' "$log" 2>/dev/null | head -1 | sed -E 's/^dsh web: //' || true)"
    [[ -n "$STARTED_URL" ]] && break
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
      echo "--- dsh web log ---" >&2
      cat "$log" >&2
      die "dsh web exited before printing a URL"
    fi
    sleep 0.5
  done
  if [[ -z "$STARTED_URL" ]]; then
    echo "--- dsh web log ---" >&2
    cat "$log" >&2
    die "dsh web did not print its URL within 150s"
  fi
  STARTED_PORT="$(printf '%s' "$STARTED_URL" | sed -E 's#.*:([0-9]+)/.*#\1#')"
  redacted="$(printf '%s' "$STARTED_URL" | sed -E 's/(token=)[^&]+/\1<redacted>/')"
  note "server ready: $redacted"

  # The static-server failure mode must be impossible to mistake for success: the
  # real server injects the module-loader bootstrap into index.html.
  if ! curl -sS -f -L --max-time 30 -c "$jar" -b "$jar" -o "$shell" "$STARTED_URL"; then
    echo "--- dsh web log ---" >&2
    cat "$log" >&2
    die "authenticated GET $redacted failed (expected a 303 to ./ with an auth cookie)"
  fi
  if ! grep -q '__ModuleLoader__' "$shell"; then
    echo "--- first 40 lines of served HTML ---" >&2
    head -40 "$shell" >&2
    die "served shell has no window.__ModuleLoader__ bootstrap — this is the static-dist failure mode, not a real dsh web server"
  fi
  if grep -q 'web boot: window.__ModuleLoader__ bootstrap facade is missing' "$shell"; then
    die "server reported the plugin-boot failure: window.__ModuleLoader__ bootstrap facade is missing"
  fi
  note "shell contains the module-loader bootstrap ($(wc -c < "$shell" | tr -d ' ') bytes)"
}

stop_server() {
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  SERVER_PID=""
}

# Seed one recorded official fixture into the temp DSH_HOME copy. The seeder
# owns the official reader/persistence seams; this wrapper only adds the optional
# deterministic clock anchor used by the plan fixture.
seed_fixture() {
  local label="$1" fixture="$2" session_id="$3" report="$4" created_at="${5:-}"
  local extra=()
  if [[ -n "$created_at" ]]; then
    extra+=(--created-at "$created_at")
  fi
  note "seeding $label fixture into temp DSH_HOME session $session_id"
  "$NODE_BIN" "$SCRIPT_DIR/seed-official-session.mjs" \
    --official-repo "$OFFICIAL_REPO" \
    --home "$SESSION_HOME" \
    --fixture "$fixture" \
    --session-id "$session_id" \
    ${extra[@]+"${extra[@]}"} \
    --out "$report"
}

# The manifest labels the two web fixtures "answered" / "approved". Fail the run
# if the seeded log no longer carries the settled tool call those labels require,
# so a fixture change can never silently ship a pending state under a settled
# label (or the reverse).
assert_seed_state() {
  local report="$1" tool="$2" expected="$3"
  "$NODE_BIN" -e '
    const fs = require("node:fs")
    const [file, tool, expected] = process.argv.slice(1)
    const report = JSON.parse(fs.readFileSync(file, "utf8"))
    const call = (report.toolCalls ?? []).find((entry) => entry.name === tool)
    if (call === undefined) {
      console.error(`[capture-official] seeded log has no ${tool} call; cannot label ${expected}`)
      process.exit(1)
    }
    if (expected === "settled" && call.hasResult !== true) {
      console.error(`[capture-official] ${tool} has no tool/result; the fixture is pending, not settled`)
      process.exit(1)
    }
    if (report.turnEnd?.type !== "turn/end" || report.turnEnd?.reason !== "completed") {
      console.error(`[capture-official] seeded log does not end in turn/end completed: ${JSON.stringify(report.turnEnd)}`)
      process.exit(1)
    }
    console.log(`[capture-official] state proof: ${tool} result=${String(call.hasResult)}; turn ${report.turnEnd.reason}; ${JSON.stringify((call.resultText ?? "").slice(0, 140))}`)
  ' "$report" "$tool" "$expected"
}

# ------------------------------------------------------- session fixture check
#
# Opening a V3 session migrates it to V4 in place, so the session phase never runs
# against the real DSH_HOME. The source is validated here (fail fast) and copied
# into the work dir only when the session phase starts; the real home is read-only.

if [[ "$SESSION_CAPTURE" == "1" ]]; then
  [[ -d "$SESSION_SOURCE" ]] || die "session source DSH_HOME not found: $SESSION_SOURCE
  Set DSH_GOLDEN_SESSION_HOME=/path/to/dsh-home, or SKIP_SESSION=1 to capture only hero + auth."
  [[ -r "$SESSION_SOURCE/sessions" ]] || die "session source has no readable sessions/: $SESSION_SOURCE"
  for fixture in "$TOOL_FIXTURE" "$QUESTION_FIXTURE" "$PLAN_FIXTURE" "$SUBAGENT_FIXTURE" "$SUBAGENT_PARALLEL_FIXTURE"; do
    [[ -f "$fixture" ]] || die "official recorded fixture not found: $fixture
  Set the matching DSH_GOLDEN_*_FIXTURE, or SKIP_SESSION=1."
  done
  # The .expected.md files are the state contracts this harness labels against:
  # answered/approved for the two web fixtures, and the pending takeover states
  # they do NOT contain (recorded in the manifest as unreachable).
  for expected in "$QUESTION_EXPECTED" "$QUESTION_PENDING_EXPECTED" "$PLAN_EXPECTED" "$PLAN_PENDING_EXPECTED"; do
    [[ -f "$expected" ]] || die "state-proof .expected.md not found: $expected
  Set the matching DSH_GOLDEN_*_EXPECTED, or SKIP_SESSION=1."
  done
  for session_id in "$SESSION_ID" "$SESSION_LONG_ID" "$TOOL_SESSION_ID" "$QUESTION_SESSION_ID" "$PLAN_SESSION_ID" \
    "$SUBAGENT_SESSION_ID" "$SUBAGENT_PARALLEL_SESSION_ID"; do
    session_dir="$(find "$SESSION_SOURCE/sessions" -maxdepth 2 -type d -name "$session_id" -print -quit)"
    [[ -n "$session_dir" ]] || die "session $session_id is not present in $SESSION_SOURCE/sessions
  Set DSH_GOLDEN_SESSION_ID / DSH_GOLDEN_SESSION_LONG_ID / DSH_GOLDEN_TOOL_SESSION_ID /
  DSH_GOLDEN_QUESTION_SESSION_ID / DSH_GOLDEN_PLAN_SESSION_ID / DSH_GOLDEN_SUBAGENT_SESSION_ID /
  DSH_GOLDEN_SUBAGENT_PARALLEL_SESSION_ID to ids that exist there, or SKIP_SESSION=1."
    [[ -n "$(find "$session_dir" -maxdepth 1 -name 'session.v*.jsonl*' -print -quit)" ]] \
      || die "session $session_id has no session.v*.jsonl log in $session_dir"
    note "session fixture (read-only): $session_id ($(du -h "$session_dir" | awk '{print $1}'))"
  done
  note "seeded bash-tool-turn fixture (read-only): $TOOL_FIXTURE"
  note "seeded question fixture (read-only): $QUESTION_FIXTURE (answered state; pending composer is NOT in the log)"
  note "seeded plan fixture (read-only): $PLAN_FIXTURE (approved state; pending review is NOT in the log)"
  note "seeded subagent fixture (read-only): $SUBAGENT_FIXTURE (session header catalog count + subagent tool row)"
  note "seeded parallel-subagent fixture (read-only): $SUBAGENT_PARALLEL_FIXTURE (two catalogs / two rows)"
else
  note "SKIP_SESSION=1: capturing hero + auth only (no chat golden)"
fi

# ------------------------------------------------------- phase 1: pristine home
#
# The hero golden is a fresh-install state ("no session"). A seeded home changes
# the hero composer to "select a workspace", so hero/auth get their own pristine
# DSH_HOME instead of reusing the session copy.

start_server "$PRISTINE_HOME" "$SERVER_LOG" "$SHELL_HTML" "$COOKIE_JAR"
URL="$STARTED_URL"
PORT="$STARTED_PORT"

# ------------------------------------------------------------------- captures

note "capturing sessionless hero (402x874 @ DPR3, light)"
"$NODE_BIN" "$SCRIPT_DIR/cdp-capture.mjs" \
  --url "$URL" \
  --out "$HERO_PNG" \
  --report "$HERO_REPORT" \
  --label hero-sessionless \
  --dismiss-onboarding \
  --settle-ms 3000 \
  --chrome "$CHROME_BIN"

note "capturing first-use auth gate (login / add API key blocker)"
"$NODE_BIN" "$SCRIPT_DIR/cdp-capture.mjs" \
  --url "$URL" \
  --out "$AUTH_PNG" \
  --report "$AUTH_REPORT" \
  --label auth-gate \
  --click-selector 'button[aria-label="关闭提示"]' \
  --click-text '继续' \
  --require-text '开始使用' \
  --settle-ms 2500 \
  --chrome "$CHROME_BIN"

for png in "$HERO_PNG" "$AUTH_PNG"; do
  [[ -s "$png" ]] || die "capture did not produce $png"
done

REPORT_ARGS=(--report "$HERO_REPORT" --report "$AUTH_REPORT")
PNG_LIST=("$HERO_PNG" "$AUTH_PNG")

# ------------------------------------------------- phase 2: seeded session home

if [[ "$SESSION_CAPTURE" == "1" ]]; then
  stop_server
  note "copying $SESSION_SOURCE -> temp DSH_HOME (source stays read-only)"
  cp -R "$SESSION_SOURCE/." "$SESSION_HOME/"
  chmod -R u+rwX "$SESSION_HOME"
  # A stale lock file from the copied home would look like a live writer.
  find "$SESSION_HOME/sessions" -name 'session.lock' -delete 2>/dev/null || true

  # Replace five copied sessions with official recorded fixtures. The seeder
  # goes through the official format reader and the real
  # JsonlSessionPersistence create/append/close seams, so the backend owns the
  # frame layout, seq envelope and encoding. Only the copy is touched.
  seed_fixture "bash-tool-turn" "$TOOL_FIXTURE" "$TOOL_SESSION_ID" "$SEED_REPORT"
  seed_fixture "question-composer (answered)" "$QUESTION_FIXTURE" "$QUESTION_SESSION_ID" "$QUESTION_SEED_REPORT"
  # The v4 plan header reset createdAt to 0; the official v2 sibling of the same
  # scenario recorded 1788240594856, so pin it for a reproducible transcript clock.
  seed_fixture "plan-review (approved)" "$PLAN_FIXTURE" "$PLAN_SESSION_ID" "$PLAN_SEED_REPORT" "$PLAN_CREATED_AT"
  seed_fixture "subagent-spawn-in-process" "$SUBAGENT_FIXTURE" "$SUBAGENT_SESSION_ID" "$SUBAGENT_SEED_REPORT"
  seed_fixture "subagent-parallel" "$SUBAGENT_PARALLEL_FIXTURE" "$SUBAGENT_PARALLEL_SESSION_ID" "$SUBAGENT_PARALLEL_SEED_REPORT"

  assert_seed_state "$QUESTION_SEED_REPORT" "ask_user_question" "settled"
  assert_seed_state "$PLAN_SEED_REPORT" "exit_plan_mode" "settled"
  # The subagent fixture logs `started subagent <childId>` as its tool/result, so
  # the row is the SETTLED launched state; the header catalog count comes from
  # the logged `subagent/catalog` event, not from a live child session.
  assert_seed_state "$SUBAGENT_SEED_REPORT" "subagent" "settled"
  assert_seed_state "$SUBAGENT_PARALLEL_SEED_REPORT" "subagent" "settled"

  start_server "$SESSION_HOME" "$SESSION_SERVER_LOG" "$SESSION_SHELL_HTML" "$SESSION_COOKIE_JAR"
  SESSION_URL="$STARTED_URL"
  SESSION_PORT="$STARTED_PORT"

  note "opening recorded session $SESSION_ID (real transcript, 402x874 @ DPR3)"
  "$NODE_BIN" "$SCRIPT_DIR/cdp-capture.mjs" \
    --url "$SESSION_URL" \
    --out "$SESSION_PNG" \
    --report "$SESSION_REPORT" \
    --label session-chat \
    --dismiss-onboarding \
    --open-session "$SESSION_ID" \
    --body-text-max 1200 \
    --settle-ms 3000 \
    --chrome "$CHROME_BIN"

  note "opening long-prompt session $SESSION_LONG_ID (scrolled to turn tail)"
  "$NODE_BIN" "$SCRIPT_DIR/cdp-capture.mjs" \
    --url "$SESSION_URL" \
    --out "$SESSION_LONG_PNG" \
    --report "$SESSION_LONG_REPORT" \
    --label session-chat-long-user-turn \
    --dismiss-onboarding \
    --open-session "$SESSION_LONG_ID" \
    --body-text-max 1200 \
    --settle-ms 3000 \
    --chrome "$CHROME_BIN"

  # Rich-chat state: the seeded recording. Three real disclosure clicks (turn
  # process, the process group, the bash row) expose the tool card, and the
  # capture asserts both the assistant answer and the tool-call row are visible
  # rather than trusting "some transcript rows exist".
  note "opening seeded tool-turn session $TOOL_SESSION_ID (assistant text + bash tool card)"
  "$NODE_BIN" "$SCRIPT_DIR/cdp-capture.mjs" \
    --url "$SESSION_URL" \
    --out "$TOOL_PNG" \
    --report "$TOOL_REPORT" \
    --label session-chat-tool \
    --dismiss-onboarding \
    --open-session "$TOOL_SESSION_ID" \
    --after-open-click-selector 'button[data-turn-process]' \
    --after-open-click-selector '[data-chat-group-key] > div > button[aria-expanded]' \
    --after-open-click-selector 'div[data-sample="bash"]' \
    --require-visible-transcript-flow assistant-step \
    --require-visible-transcript-flow tool-call \
    --body-text-max 1600 \
    --settle-ms 3000 \
    --chrome "$CHROME_BIN"

  # Answered question card. The official fixture carries the recorded answer, so
  # the settled ask_user_question row renders "1/1 answered" with the question and
  # both answer lines; the pending composer takeover is NOT in the log and is
  # never simulated. The row lives inside the collapsed turn process, so three
  # real disclosures open it, and the card (not the turn tail) frames the shot.
  note "opening seeded question session $QUESTION_SESSION_ID (answered ask_user_question card)"
  "$NODE_BIN" "$SCRIPT_DIR/cdp-capture.mjs" \
    --url "$SESSION_URL" \
    --out "$QUESTION_PNG" \
    --report "$QUESTION_REPORT" \
    --label session-question-answered \
    --dismiss-onboarding \
    --open-session "$QUESTION_SESSION_ID" \
    --after-open-click-selector 'button[data-turn-process]' \
    --after-open-click-selector 'button[data-process-activity="questions"]' \
    --after-open-click-selector '[data-tool="ask_user_question"] [data-disclosure-row]' \
    --transcript-require-flow-kind user \
    --transcript-require-flow-kind tool-call \
    --require-visible-selector '[data-chat-node-key] [data-tool="ask_user_question"]' \
    --scroll-to-selector '[data-tool="ask_user_question"]' \
    --require-text 'Include accessibility notes' \
    --fail-on-console-error \
    --body-text-max 2000 \
    --settle-ms 3000 \
    --chrome "$CHROME_BIN"

  # Approved plan card. The fixture's tool/result records the approval, so the
  # plan is a logged artifact rendered in the turn tail ("Open plan: ..." card).
  # The pending "Plan review / Approve this plan?" takeover described by
  # review.expected.md is not in the log and is not simulated.
  note "opening seeded plan session $PLAN_SESSION_ID (approved exit_plan_mode plan card)"
  "$NODE_BIN" "$SCRIPT_DIR/cdp-capture.mjs" \
    --url "$SESSION_URL" \
    --out "$PLAN_PNG" \
    --report "$PLAN_REPORT" \
    --label session-plan-approved \
    --dismiss-onboarding \
    --open-session "$PLAN_SESSION_ID" \
    --transcript-require-flow-kind command \
    --transcript-require-flow-kind tool-call \
    --transcript-require-flow-kind turn-tail \
    --require-visible-selector '[data-chat-node-key] [data-plan-card]' \
    --require-text 'Add `--greeting` flag to CLI' \
    --fail-on-console-error \
    --body-text-max 2000 \
    --settle-ms 3000 \
    --chrome "$CHROME_BIN"

  # Subagent state (in-process spawn). The recorded fixture carries a
  # `subagent/catalog` event for its child plus the `subagent` tool call and its
  # `tool/result` (`started subagent <childId>`), so the official UI projects the
  # catalog into the session-header count — here "1 个子智能体" — and renders the
  # tool row inside the folded turn process. The header count is a projection of
  # the logged catalog, never typed into the DOM; the capture asserts it and
  # records the button's text/aria-label. Two group disclosures (turn process +
  # the "已协调子智能体" process group) and one row disclosure are real clicks.
  note "opening seeded subagent session $SUBAGENT_SESSION_ID (session-header catalog count + subagent tool row)"
  "$NODE_BIN" "$SCRIPT_DIR/cdp-capture.mjs" \
    --url "$SESSION_URL" \
    --out "$SUBAGENT_PNG" \
    --report "$SUBAGENT_REPORT" \
    --label session-subagent-spawn \
    --dismiss-onboarding \
    --open-session "$SUBAGENT_SESSION_ID" \
    --after-open-click-selector 'button[data-turn-process]' \
    --after-open-click-selector '[data-chat-group-key] > div > button[aria-expanded]' \
    --after-open-click-selector '[data-tool="subagent"] [data-disclosure-row]' \
    --transcript-require-flow-kind user \
    --transcript-require-flow-kind assistant-step \
    --transcript-require-flow-kind tool-call \
    --require-visible-transcript-flow tool-call \
    --require-visible-selector '[data-chat-node-key] [data-tool="subagent"]' \
    --require-visible-selector 'button[aria-haspopup="tree"]' \
    --require-text '1 个子智能体' \
    --fail-on-console-error \
    --fail-on-network-error \
    --body-text-max 2400 \
    --settle-ms 3000 \
    --chrome "$CHROME_BIN"

  # Parallel-subagent state: the same tool/config with TWO logged catalogs, so the
  # same header renders "2 个子智能体" and two `subagent` rows share one process
  # group (the first row is expanded, the second stays collapsed). This is the
  # evidence that the header count is derived from the log rather than a static
  # label — the two fixtures differ only in their catalog events.
  note "opening seeded parallel-subagent session $SUBAGENT_PARALLEL_SESSION_ID (two catalog entries / two rows)"
  "$NODE_BIN" "$SCRIPT_DIR/cdp-capture.mjs" \
    --url "$SESSION_URL" \
    --out "$SUBAGENT_PARALLEL_PNG" \
    --report "$SUBAGENT_PARALLEL_REPORT" \
    --label session-subagent-parallel \
    --dismiss-onboarding \
    --open-session "$SUBAGENT_PARALLEL_SESSION_ID" \
    --after-open-click-selector 'button[data-turn-process]' \
    --after-open-click-selector '[data-chat-group-key] > div > button[aria-expanded]' \
    --after-open-click-selector '[data-tool="subagent"] [data-disclosure-row]' \
    --transcript-require-flow-kind user \
    --transcript-require-flow-kind assistant-step \
    --transcript-require-flow-kind tool-call \
    --require-visible-transcript-flow tool-call \
    --require-visible-selector '[data-chat-node-key] [data-tool="subagent"]' \
    --require-visible-selector 'button[aria-haspopup="tree"]' \
    --require-text '2 个子智能体' \
    --fail-on-console-error \
    --fail-on-network-error \
    --body-text-max 2400 \
    --settle-ms 3000 \
    --chrome "$CHROME_BIN"

  for png in "$SESSION_PNG" "$SESSION_LONG_PNG" "$TOOL_PNG" "$QUESTION_PNG" "$PLAN_PNG" \
    "$SUBAGENT_PNG" "$SUBAGENT_PARALLEL_PNG"; do
    [[ -s "$png" ]] || die "capture did not produce $png"
  done
  REPORT_ARGS+=(--report "$SESSION_REPORT" --report "$SESSION_LONG_REPORT" --report "$TOOL_REPORT"
    --report "$QUESTION_REPORT" --report "$PLAN_REPORT"
    --report "$SUBAGENT_REPORT" --report "$SUBAGENT_PARALLEL_REPORT")
  PNG_LIST+=("$SESSION_PNG" "$SESSION_LONG_PNG" "$TOOL_PNG" "$QUESTION_PNG" "$PLAN_PNG"
    "$SUBAGENT_PNG" "$SUBAGENT_PARALLEL_PNG")
  stop_server
fi

# --------------------------------------------------------------- manifest

note "writing manifest"
"$NODE_BIN" "$SCRIPT_DIR/write-manifest.mjs" \
  --out-dir "$OUT_DIR" \
  "${REPORT_ARGS[@]}" \
  --repo "$OFFICIAL_REPO" \
  --commit "$COMMIT" \
  --version "$PKG_VERSION" \
  --url "$(printf '%s' "$URL" | sed -E 's/(token=)[^&]+/\1<redacted>/')" \
  --port "$PORT" \
  --session-url "$(printf '%s' "$SESSION_URL" | sed -E 's/(token=)[^&]+/\1<redacted>/')" \
  --session-port "${SESSION_PORT:-}" \
  --server-command "node apps/cli/lib/bin.js --profile web --no-open --host 127.0.0.1 --port $DSH_GOLDEN_PORT (cwd: $OFFICIAL_REPO, DSH_HOME=<temp pristine>)" \
  --server-log "$SERVER_LOG" \
  --session-server-log "$SESSION_SERVER_LOG" \
  --node "$NODE_VERSION" \
  --chrome "$CHROME_VERSION" \
  --session-source "$SESSION_SOURCE" \
  --session-id "$SESSION_ID" \
  --session-long-id "$SESSION_LONG_ID" \
  --session-tool-id "$TOOL_SESSION_ID" \
  --tool-fixture "$TOOL_FIXTURE" \
  --seed-report "$SEED_REPORT" \
  --question-session-id "$QUESTION_SESSION_ID" \
  --question-fixture "$QUESTION_FIXTURE" \
  --question-expected "$QUESTION_EXPECTED" \
  --question-pending-expected "$QUESTION_PENDING_EXPECTED" \
  --question-seed-report "$QUESTION_SEED_REPORT" \
  --plan-session-id "$PLAN_SESSION_ID" \
  --plan-fixture "$PLAN_FIXTURE" \
  --plan-expected "$PLAN_EXPECTED" \
  --plan-pending-expected "$PLAN_PENDING_EXPECTED" \
  --plan-seed-report "$PLAN_SEED_REPORT" \
  --subagent-session-id "$SUBAGENT_SESSION_ID" \
  --subagent-fixture "$SUBAGENT_FIXTURE" \
  --subagent-seed-report "$SUBAGENT_SEED_REPORT" \
  --subagent-parallel-session-id "$SUBAGENT_PARALLEL_SESSION_ID" \
  --subagent-parallel-fixture "$SUBAGENT_PARALLEL_FIXTURE" \
  --subagent-parallel-seed-report "$SUBAGENT_PARALLEL_SEED_REPORT" \
  --session-capture "$SESSION_CAPTURE" \
  --generated-at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

note "done"
printf '  %s\n' "${PNG_LIST[@]}" "$OUT_DIR/manifest.json" "$OUT_DIR/manifest.md"
