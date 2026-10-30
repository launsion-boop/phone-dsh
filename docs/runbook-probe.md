# Runbook: phone-DSH probe package and smoke

Status: the procedures below cover the landed macOS tooling, iOS Simulator
gates and selected physical-iPhone Phase 0/A1 evidence. Simulator behaviour is
never device evidence. The selected physical smoke, probes and kill matrix have
run; the full physical-device suite is not green.

This runbook covers:

1. building the Worker artifacts the probe package and the smoke boot from;
2. running the Phase 0 probe package and the kill matrix, and reading
   `probe-report.json` against **G0**;
3. running the end-to-end smoke and reading `smoke-report.json` against **G1**;
4. what exists for the iOS probe app today (nothing is an app target in this
   tree) and what a device run must additionally show.

All output directories are temporary (`$TMPDIR` or an explicit environment
variable). None of them belongs in the repository, and no report contains a
source-checkout path.

## What runs where

| Piece | Where it runs | Entry point | Report |
|---|---|---|---|
| Probe package | macOS XCTest process with a real WKWebView and a real loopback origin | `scripts/ci/probes.sh` → `PhoneDSHProbeTests` | `probe-report.json` |
| Kill matrix | macOS XCTest process; deterministic `MockEngine`/`MockWorker` for the facade cases and a forked child for the host-SIGKILL cases | the same script → `PhoneDSHKillTests` | `kill-report.json` |
| Smoke | macOS XCTest process with the real packed Worker image, a real WKWebView and a scripted model upstream | `scripts/ci/smoke.sh` → `PhoneDSHSmokeTests` | `smoke-report.json`, `smoke.log` |

The probe package and the smoke are not the same gate: the probe package
measures the transport, WebView and log primitives in isolation; the smoke
drives the public `PhoneDSHHost` facade through a model turn, a real shell
call, a planned restart and a session resume.

## Prerequisites

| Requirement | Why | Check |
|---|---|---|
| macOS with Xcode / WKWebView | the probe and smoke targets instantiate WKWebView | `xcode-select -p` |
| Swift 6 toolchain | `Package.swift` | `swift --version` |
| Node ≥ 22.19 | `plugins` scripts and the Worker bundle | `node --version` |
| pinned DSH checkout | the Worker bundle, the image and the profile come from it; it is never copied or patched | `node plugins/scripts/dsh-checkout.mjs --verify` |
| `plugins/node_modules` | `esbuild`, `typescript` and the DSH development dependency | `test -d plugins/node_modules` |

The checkout is resolved from `PDSH_DSH_CHECKOUT` when set, otherwise from the
single line of `$HOME/.config/phone-dsh/dsh-checkout`. Do not put that absolute path
into a file in this repository.

```sh
# Resolve once for the commands below (no path is written into the repo).
PDSH_DSH_CHECKOUT="${PDSH_DSH_CHECKOUT:-$(sed -n '1p' "$HOME/.config/phone-dsh/dsh-checkout")}"
export PDSH_DSH_CHECKOUT
node plugins/scripts/dsh-checkout.mjs --verify
```

`--verify` exits non-zero when HEAD differs from `plugins/dsh-pin.json`,
when a tracked file is modified, when an untracked file exists under a root the
image packer reads, or when the runtime/packer build artifacts are missing.

## Build the artifacts

The smoke script builds everything itself when the prebuilt paths are absent.
To build by hand (or to reuse a build across runs):

```sh
# 1. Worker entry bundle: worker-entry.js + www/index.html + www/boot.js
node plugins/worker-entry/build.mjs --out "$TMPDIR/pdsh-phone/worker-entry"

# 2. Worker image: image.tar.gz, lazy/*.tar.gz, manifest.json, sizes.json,
#    worker.js and client.js
( cd plugins && node scripts/pack-image.mjs --out "$TMPDIR/pdsh-phone/image" )
# Controlled release checkout: add the explicit clean/built pair (the same one
# passed to build-web-dist.sh); the canonical pin stays recorded in sizes.json.
#   --checkout "$PDSH_DSH_CHECKOUT" \
#   --checkout-sha "$DSH_COMMIT" --checkout-version "$DSH_VERSION"

# 3. Static directory the loopback origin serves. It must contain
#    index.html, boot.js, worker-entry.js, image.tar.gz and lazy/.
mkdir -p "$TMPDIR/pdsh-phone/www/lazy"
cp "$TMPDIR/pdsh-phone/worker-entry/worker-entry.js" \
   "$TMPDIR/pdsh-phone/worker-entry/www/index.html" \
   "$TMPDIR/pdsh-phone/worker-entry/www/boot.js" \
   "$TMPDIR/pdsh-phone/www/"
cp "$TMPDIR/pdsh-phone/image/image.tar.gz" "$TMPDIR/pdsh-phone/www/"
cp -R "$TMPDIR/pdsh-phone/image/lazy/." "$TMPDIR/pdsh-phone/www/lazy/"
```

`scripts/ci/smoke.sh` performs these steps, prepends the JavaScriptCore
compatibility definitions the smoke needs (`Symbol.dispose`,
`Symbol.asyncDispose` and `ReadableStream` async iteration), and validates the
result. If `PDSH_DSH_WWW` and `PDSH_DSH_IMAGE` point at a usable static directory
and image, the script reuses them instead of rebuilding; it still needs its
`plugins/node_modules` warm before it can validate either path.

The image packer is the only place that imports the pinned checkout's packer.
It stages each `plugins` workspace package, bundles every source export
face, and asks the checkout's `packVfsImage` to pack the roster with
`profile/phone.worker.cordis.patch.yml` as the home patch. See
[plugins/README.md](../plugins/README.md) for the output table and the
staging rules.

## Run the probe package and the kill matrix

```sh
bash scripts/ci/probes.sh
```

Optional environment:

| Variable | Effect |
|---|---|
| `PDSH_PROBES_DIR` | output directory; default `$TMPDIR/pdsh-probes` |

The script runs two filtered XCTest targets sequentially and always prints both
reports:

- `PhoneDSHProbeTests` (5 tests): Worker channel round trips through the real
  loopback origin, same-origin `fetch` at 1 KiB and 1 MiB, NDJSON first-chunk
  streaming, 1000 WebSocket echoes, COOP/COEP on and off, timer throttling
  while offscreen versus one point visible, the JavaScriptCore/WKWebView
  benchmark and the 100-file `WorkspaceLog` checkpoint.
- `PhoneDSHKillTests` (1 test, 20 iterations): every iteration kills one of
  {worker terminate, WebContent restart, host-child SIGKILL} at one of
  {after a write, during exec, during checkpoint, during an epoch close},
  recovers, and asserts that every level-1-acked `mseq` is in the WAL with the
  same mutation, that WAL replay equals the materialized copy, and that the
  step-machine reconcile set is exactly the interrupted steps.

Exit code 0 requires the probe report to exist and to have no gating failure,
the kill report to exist with `failed == 0`, and both targets to have executed
at least one test. A `SKIP` from `swift test` is not success.

Outputs:

| File | Content |
|---|---|
| `$TMPDIR/pdsh-probes/probe-report.json` | one row per probe plus the G0 summary |
| `$TMPDIR/pdsh-probes/kill-report.json` | one row per kill iteration plus the totals |
| `$TMPDIR/pdsh-probes/probes.log` | the `PhoneDSHProbeTests` process log |
| `$TMPDIR/pdsh-probes/kill.log` | the `PhoneDSHKillTests` process log |

## Run the smoke

```sh
bash scripts/ci/smoke.sh
```

Optional environment:

| Variable | Effect |
|---|---|
| `PDSH_DSH_CHECKOUT` | pinned checkout; absent falls back to `$HOME/.config/phone-dsh/dsh-checkout` |
| `PDSH_DSH_WWW` | prebuilt static directory; skips the bundle/image build only when both this and `PDSH_DSH_IMAGE` are usable |
| `PDSH_DSH_IMAGE` | prebuilt `image.tar.gz` |
| `PDSH_SMOKE_DIR` | output directory; default `$TMPDIR/pdsh-smoke` |

The smoke boots the real Worker image in a real WKWebView attached with a
one-point visible area and drives the facade with a scripted model upstream
(no network model is contacted). It asserts, in this order:

1. `boot_and_hello`: `Running`, admission `open`, at least one Worker `HELLO`.
2. `first_tool_turn`: the scripted model calls the DSH `bash` tool with
   `echo hi > a.txt && cat a.txt`; the Worker VFS mutation reaches the WAL and
   the materialized copy, the tool journal records `dispatched` and `completed`,
   the step machine reaches `journaled`, the model sees the tool result in a
   second request, and the host injected its credential.
3. `planned_restart`: `plannedRestart(reason:)` relabels the overlay as gzip,
   boots a second Worker, sends a second `HELLO`, and reopens admission.
4. `resumed_turn`: the durable session id accepts a second prompt after the
   restart and the materialized tree is unchanged.

Outputs (under `$PDSH_SMOKE_DIR`):

| File | Content |
|---|---|
| `smoke-report.json` | phases, durations, state changes, HELLOs, restarts, resume evidence, console tail, host/harness errors |
| `smoke.log` | the complete `swift test` output; also replayed to stdout |
| `www/`, `image/` | the built static directory and image (or the reused ones) |

A passing smoke prints `smoke: PASS` and exits 0.

## The iOS probe app

The probe app is [`examples/probe-app`](../examples/probe-app/README.md):
an XcodeGen project (`project.yml`) with the SwiftUI app (`Probes`, `Memory`,
`Background`, `Screen`, `Export` pages), the `ProbeKit` library (the iOS port of
the probe suite and the report model) and the hostless `PhoneDSHSimTests`
target. The simulator gate is `scripts/ci/sim.sh`: it boots or reuses the
iPhone 17 Pro simulator, builds the native shell, packed Worker assets and app,
then runs `xcodebuild test-without-building -scheme PhoneDSHSim`. It pulls
`probe-report.json`, `smoke-report.json` and `kill-report.json` from its stable
report output directory (never an older app container) and prints one
PASS/FAIL/INFO table; any FAIL row, a missing report or a failed test process
exits non-zero. Environment: `PDSH_DSH_CHECKOUT` (or the per-machine checkout
file), optional `PDSH_DSH_WWW` / `PDSH_DSH_IMAGE` for prebuilt assets, `OUT`
(default `${TMPDIR:-/tmp}/pdsh-sim`), `PDSH_SIM_TIMEOUT`. The default install
uninstalls the app and resets its data container for CI. To keep existing sessions,
use `PDSH_SIM_PRESERVE_DATA=1 bash scripts/ci/sim.sh`, which installs without
uninstalling and creates an isolated `chat-host-sim-*` test workspace. Override its
suffix with `PDSH_SIM_WORKSPACE_NAME`; assertions are unchanged. Every row carries
`environment: "ios-simulator"`: the procedures above prove macOS behaviour, the
gate proves simulator behaviour, and neither is device evidence.

Running the app on an iPhone uses the same public entry points, not a private
harness: embed the static directory and image from
[Build the artifacts](#build-the-artifacts), create a `PhoneDSHHost` with a
`PhoneDSHBundleLocation`, and attach the `WebEngine` view to a window with at
least one visible point before `start()` (see
[docs/architecture.md](architecture.md#ui-attachment-requirement)). The probe set to
run on the device is the same probe package listed above; a device report must
carry a device environment and cannot be replaced by the macOS report.

### Running the scenario catalog on the simulator

`scripts/ci/scenarios.sh --run-on sim` runs the same catalog, mock/real
upstream and assertions as the macOS path inside the probe app's
`PhoneDSHScenarioSimTests` bundle. The engine is the regular SwiftPM library
`PhoneDSHScenario`; the macOS `PhoneDSHScenarioTests` target is only
XCTest glue, so both runners share one implementation and write the same
`<results>/<id>/{report.json,transcript.jsonl,workspace.tar,host/}` tree.

```sh
# Mock upstream, no key (the CI self-test):
bash scripts/ci/scenarios.sh --run-on sim --upstream mock \
  --only G2-SELFTEST,G2-SELFTEST-DELIVERY

# Real model: the three PDSH_MODEL_* variables are exported by model-env.mjs;
# the script passes them to the test runner as TEST_RUNNER_PDSH_MODEL_* only.
eval "$(node scripts/ci/model-env.mjs)"
bash scripts/ci/scenarios.sh --run-on sim --upstream real
```

Defaults: `--results $TMPDIR/pdsh-scenarios` and the `PDSH_SIM_DEVICE` simulator
(`iPhone 17 Pro`). `--target` still filters the catalog (`macos`, `sim` or
`both`); it is not the execution target. For a simulator run the default
catalog filter is `both`, so a scenario whose catalog target says `macos` runs
too (the engine no longer depends on the macOS AppKit window).

The driver:

1. builds/reuses the Worker assets exactly as `sim.sh` does, copies them into
   the probe app's `Bundle/worker`, generates the Xcode project and runs
   `xcodebuild build-for-testing -scheme PhoneDSHScenarioSim`;
2. installs the probe app and stages `Documents/pdsh-scenarios/`:

   ```text
   Documents/pdsh-scenarios/
     catalog.json     # the selected catalog, byte-for-byte
     fixtures/        # scripts/ci/scenarios/fixtures/
     config.json      # upstream, only, tag, target, keep_bodies
     results/         # written by the test bundle, pulled back afterwards
   ```

   `config.json` never contains a model credential. Model credentials reach the
   simulator only through the `xcodebuild` test-runner environment
   (`TEST_RUNNER_PDSH_MODEL_BASE_URL/NAME/API_KEY`) and are redacted from every
   artifact.
3. runs `xcodebuild test-without-building -scheme PhoneDSHScenarioSim` (with an
   `simctl spawn` XCTest fallback for harnesses that cannot launch the standard
   test runner), pulls `results/` back into `--results`, and applies the same
   report check and exit codes as the macOS path.

Perturbations on the simulator: `planned_restart`, `park_resume` and
`worker_kill` run the same facade/engine paths as on macOS. `webcontent_kill`
needs a host-process signal that the simulator test process cannot send; the
report records it per scenario with `ok: null` and an explicit
`not available on this runner` detail instead of skipping it silently. The
device-scoped WebContent killer remains `sim.sh`'s watcher.

`sim.sh` itself remains the W3-SIM gate and runs the probe, smoke, kill and
complete Web-surface suites; `scenarios.sh --run-on macos` is still the default
and keeps the `swift test --filter PhoneDSHScenario` path.

### Running the same catalog on a real iPhone

The host driver accepts an `xcodebuild` destination pass-through, so the same
catalog can target a device:

```sh
# Destination id: `xcrun devicectl list devices` or
# `xcrun xctrace list devices`; a name also works:
#   --destination 'platform=iOS,id=<device-udid>'
bash scripts/ci/scenarios.sh --run-on sim --upstream real \
  --destination 'platform=iOS,id=<device-udid>' \
  --results "$TMPDIR/pdsh-scenarios-device"
```

Signing caveat: the simulator build passes `CODE_SIGNING_ALLOWED=NO`; a device
build must use automatic signing with a development team. Set
`PDSH_DEVELOPMENT_TEAM=<team-id>` before invoking the script (it passes
`DEVELOPMENT_TEAM` to `xcodebuild`), or set the team in
`examples/probe-app/project.yml`'s `DEVELOPMENT_TEAM` — the committed
placeholder is empty on purpose. The driver installs the signed app with
`xcrun devicectl device install app`, stages the same
`Documents/pdsh-scenarios/` tree with `xcrun devicectl device copy to
--domain-type appDataContainer`, runs `xcodebuild test-without-building` with
the destination, and pulls `Documents/pdsh-scenarios/results` back with
`devicectl device copy from`.

Selected `PhoneDSHDevice` Phase 0/A1 tests have run on a physical iPhone:
minimal smoke, G0 probes, 20 kill-matrix iterations and Daily Brief tests pass.
The full physical-device suite is not green: full-Web and file-bridge failures
remain open. Before relying on a new run, confirm on the Mac that `devicectl
list devices` sees the iPhone and that the app installs; on the phone, check
each report's environment and perturbation rows. A device report is its own
evidence and never replaces or extends a simulator report.

On-device expectations that remain unmeasured: timer throttling under a
one-point attachment, JIT versus JavaScriptCore performance, WebContent memory
and jetsam, Lockdown Mode, and background scheduling. Each is `NOT_VERIFIED`
until a device run produces evidence.

## Reading `probe-report.json` against G0

The report is written atomically after every row, so a later crash still leaves
the measurements that ran. Default path:
`$TMPDIR/pdsh-probes/probe-report.json`.

Top-level fields:

| Field | Meaning |
|---|---|
| `schema` | `1` |
| `generated_at` | ISO-8601 timestamp |
| `platform`, `os_version` | where the target ran (`macOS` here; a device run would carry its own value) |
| `g0_thresholds` | the thresholds the reporter knows about, with `value`, `unit`, `source` and `gating` |
| `summary.pass` / `summary.fail` / `summary.info` | row counts by status |
| `summary.g0_passed` | `true` iff no row with `gating: true` has `status: "FAIL"` |
| `summary.failed_gating_probes` | the names of those failing rows |
| `rows` | one object per probe |

Each row:

| Field | Meaning |
|---|---|
| `probe` | stable name (`channel.fetch-post-1mb`, `throttle.offscreen-vs-visible`, …) |
| `kind` | probe family |
| `status` | `PASS`, `FAIL` or `INFO` |
| `gating` | whether this row takes part in the G0 decision |
| `metrics` | measured values (milliseconds, bytes, counts, booleans) |
| `threshold` | `{name, value, unit, source, comparison, measured, met, gating}`, or `name: "none"` when the plan defines no numeric bound |
| `detail` | human-readable note, usually empty |
| `recorded_at` | ISO-8601 timestamp |

How to decide G0:

1. `summary.g0_passed` must be `true` and `summary.failed_gating_probes` must
   be empty.
2. A `status: "INFO"` row is **not** a pass. It records a measurement that has
   no gating bound in this target, or whose bound is informational; do not
   count it as evidence that a threshold was met.
3. Read `threshold.met` only when `threshold.gating` is `true`; a matching
   `comparison`/`value`/`unit` triple is the interpretive key.
4. Check `platform`: a macOS report is a macOS result and does not close a
   device G0.

What is gating in the landed target: the 1000-echo loopback round trip
(`channel.ws-echo-1000`, p95 < 5 ms, `budgets.md` §4). The `g0_thresholds`
block also names the 100-file checkpoint and the recovery-time formula, both
marked non-gating; the other rows (COOP/COEP, cross-origin isolation, 1 KiB and
1 MiB POST, NDJSON first chunk, timer throttling, the JIT benchmark) record
measurements without a numeric gate here. Do not infer a pass or a failure for
a capability the plan gates elsewhere from the absence of a row or from an
`INFO` row.

Quick summary without extra tooling:

```sh
python3 - "$TMPDIR/pdsh-probes/probe-report.json" <<'PY'
import json, sys
report = json.load(open(sys.argv[1], encoding="utf-8"))
print(report["platform"], report["generated_at"])
for row in report["rows"]:
    threshold = row.get("threshold") or {}
    print(f'{row["status"]:<4} {row["probe"]:<44} '
          f'gating={row["gating"]} met={threshold.get("met")}')
print(report["summary"])
raise SystemExit(0 if report["summary"]["g0_passed"] else 1)
PY
```

## Reading `kill-report.json` against G1

The kill report is the crash-consistency half of G1 (the smoke is the task
half). Default path: `$TMPDIR/pdsh-probes/kill-report.json`.

| Field | Meaning |
|---|---|
| `schema` | `1` |
| `generated_at` | ISO-8601 timestamp |
| `iterations` | number of seeded kills executed (20 when the plan ran completely) |
| `passed`, `failed` | iteration counts |
| `rows[]` | `index`, `kind`, `timing`, `passed`, `detail`, `metrics` |

The gate is `failed == 0` and `iterations == 20`; `scripts/ci/probes.sh`
fails the run if the report is missing or `failed != 0`. Each row describes one
matrix cell; the plan is seeded, so a failure is reproducible. `detail` carries
the recovery assertion that failed, and `metrics` carries the positions the
iteration observed before and after the kill.

## Reading `smoke-report.json` against G1

Default path: `$TMPDIR/pdsh-smoke/smoke-report.json`.

| Field | Meaning |
|---|---|
| `version` | `1` |
| `ok` | `true` only when every smoke assertion passed |
| `phases` | `[{name, duration_ms, ok}]`, in execution order |
| `state_changes` | the facade state transitions observed (`stopped→starting`, `starting→running`, …) |
| `worker_hellos` | `{boot_id, last_mseq, generation, wal_seq, count}` per HELLO |
| `restarts` | `{reason, boot_id, duration_seconds}` per restart |
| `console`, `console_last_50` | Worker console lines; the tail is what the failure path prints |
| `not_implemented_fail` | any `notImplementedFail` console line; must be empty |
| `host_errors`, `harness_errors` | structured errors from the host event stream and the harness |
| `failure` | present only on a failed run |
| `wal`, `journal`, `steps`, `model_requests`, `materialized_*`, `restart`, `resume` | the evidence details the test read back from the workspace |

Enforced by the test and the script:

1. `ok == true` (the test body finished with every assertion satisfied);
2. `phases` contains `boot_and_hello`, `first_tool_turn`, `planned_restart`
   and `resumed_turn`, in that order, all `ok` (a phase is only added as it is
   reached);
3. `restart.overlay_is_gzip` is true, `restart_worker_hellos` is at least 2,
   and `resume.materialized_unchanged` is true;
4. `swift test` exits 0 and no `skipped` line appears in `smoke.log` (a skip is
   not a pass).

Read this field as G1 evidence as well; the test records it but does not fail
on it by itself:

5. `not_implemented_fail` is empty, and `host_errors` / `harness_errors` are
   empty or explained in the report.

If a phase fails, read `failure`, then `console_last_50` and the two error
arrays in that order; the console lines carry the Worker-side reason, while the
host arrays carry the facade's view. `smoke.log` has the whole process output.

## Troubleshooting

| Symptom | Likely cause | Action |
|---|---|---|
| `PDSH_DSH_CHECKOUT is not set and ~/.config/phone-dsh/dsh-checkout has no checkout path` | checkout not configured | set `PDSH_DSH_CHECKOUT` or write the single path line into the per-machine file |
| smoke builds but `/v1/http` fails | upstream host not in `allowedModelHosts`, or the credential provider has no entry for the lowercased host | check the configuration and the app's `CredentialProvider` |
| `swift test` reports 0 tests executed | `--filter` typo or the target did not build | run the unfiltered target once and read the log |
| smoke hangs at boot | WKWebView has no visible attachment or the page could not load the image | check `WebEngine.isAttachedWithVisibleArea`, the static directory names, and the `console_last_50` tail |
| a stale Worker bundle is loaded | a previous build directory was reused | rebuild the artifacts with the commands above; do not ship a stale `worker-entry.js` |
| a kill iteration fails | recovery, WAL appending or materialization inconsistency | treat as a fail-loud signal; keep the row and the workspace under the temporary directory for inspection |

## Recording evidence

- Attach the reports and the logs, not a source-checkout path, to the G0/G1
  evidence.
- `probe-report.json` and `kill-report.json` contain no local paths.
  `smoke-report.json.paths` contains the temporary `www`, `image`, `workspace`
  and `smoke_dir` paths: strip that object before publishing a report outside
  the machine, and never copy those values into the repository.
- A report from a different platform, or an `INFO`-only run, is not a gate
  pass.
