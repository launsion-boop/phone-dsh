# Native iPhone DSH and development probes

The shipped app opens the **native SwiftUI shell** (conversation, workspace
drawer, composer, workbench) on top of `PhoneDSHHost`, which owns the Worker,
VFS, model gateway and native `PDSHShellProvider`. The complete DSH Web UI is
**removed**: the Worker image still carries the DSH page it boots from
(`/static/web/index.html`), but the app no longer has a Web surface, and its
lifecycle/tests were deleted with it. The worker page stays a Worker input,
not an app surface. The recovery Settings page opens the native
**MCP 网络与密钥** sheet, which keeps the one Worker `mcp.json` registry, adds
only the exact MCP scheme/host/port/path to Worker egress, and stores header
values in the dedicated MCP Keychain.
The old probe pages are available only through Debug developer tools.

For a build linked to the real xz-shell command library, run from the repository root:

```bash
bash shell/build-apple.sh
# Full DSH Web page at /static/web/index.html (the legacy Worker/www page works
# without it, but the in-app full Web boot needs this build from the same
# controlled checkout).
bash scripts/ci/build-web-dist.sh --source "$PDSH_DSH_CHECKOUT" --store /tmp/phone-dsh-pnpm-store
bash examples/probe-app/scripts/copy-bundle-assets.sh --checkout "$PDSH_DSH_CHECKOUT"
cd examples/probe-app
PDSH_WITH_SHELL=1 xcodegen generate
PDSH_WITH_SHELL=1 xcodebuild -scheme PhoneDSHProbe \
  -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES
```

The current XCFramework simulator slice is arm64 (Apple Silicon); an Intel simulator needs its own x86_64 slice.

The environment flag must also be present during Xcode's Swift package resolution.
Without it the SDK intentionally uses an unlinked provider, and the Shell page reports
that status. Device signing and iOS 27 validation require the corresponding local tools.

The following sections retain the original probe/test runbook.

# iOS phone-DSH Phase 0 probe app

An iOS 17+ SwiftUI app that runs the phone-DSH Phase 0 probes on the device
UI actor and collects the numbers the G0/G1 gates need: the W3-PROBES suite,
real `PhoneDSHHost` boots with 20/50/100 MB synthetic overlays, the
background/lock matrix with and without `BGContinuedProcessingTask`, the
Lockdown Mode state, the black low-brightness task screen and one exported JSON
report.

This is the PLAN W3-APP deliverable (`examples/probe-app/**`). The
app links the landed phone-DSH modules directly from `../..`; it adds no
protocol behaviour.

Status: **builds for the iOS Simulator** (Xcode 26.5) and has **not run on an
iPhone**. Every device-only number in the report is empty / `NOT_VERIFIED`
until an operator runs the pages on a device and exports the report. Statements
about iOS/WebKit behaviour in this directory are `NOT_VERIFIED` unless they are
documented Apple platform facts.

## Layout

| Path | Contents |
|---|---|
| `project.yml` | XcodeGen project. Bundle id placeholder `dev.phone-dsh.probe`; change it for device signing. |
| `PhoneDSHProbe/` | SwiftUI app: `Probes`, `Memory`, `Background`, `Screen`, `Export`. |
| `ProbeKit/` | Library target: the iOS port of the W3-PROBES suite, the report model, the host session, the shared complete-page host assembly (`WebHostConfiguration`, used by the simulator suites), the synthetic-overlay writer and the memory/background runners. |
| `PhoneDSHSimTests/` | Hostless XCTest target for the W3-SIM simulator gate: probes via `ProbeKit`, the end-to-end smoke, the kill matrix and the shared report/window/bundle discovery. |
| `Bundle/worker/` | Build-time copy of the packed Worker assets. Not committed; filled by `scripts/copy-bundle-assets.sh`. |
| `Config/PhoneDSHProbe-Info.plist` | Local-network ATS exception, `processing` background mode, `BGTaskSchedulerPermittedIdentifiers` family. |
| `Config/PhoneDSHSimTests-Info.plist` | ATS loopback exception for the hostless smoke/Worker pages. |
| `scripts/copy-bundle-assets.sh` | Documented Worker-asset copy step (below). |
| `README.md` | This file; the exported report schema lives here. |

Targets: the app (`PhoneDSHProbe`) depends on the `ProbeKit` framework and the
SwiftPM products `PhoneDSH`, `PhoneDSHEngine` and
`PhoneDSHController`; `ProbeKit` additionally links `PhoneDSHLoopback`,
`PhoneDSHLog`, `PhoneDSHWire` and `PhoneDSHShell`. The `PhoneDSHSim` scheme's
hostless `PhoneDSHSimTests` target links `ProbeKit` and the phone modules, plus
the `PhoneDSHHarness` SwiftPM product: that regular target holds the landed
macOS smoke model upstream, the smoke evidence readers and the kill fixtures
with the shared acked/WAL/reconcile verifier, so nothing under `Tests/` is
path-included and no test target depends on another test target. The test
target carries no Worker assets of its own: the installed app's
`Bundle/worker/` is the single set the suites load, so a run needs the app
installed (the simulator-gate script does that before `xcodebuild test`).
SwiftPM products are not re-exported, so each target links every module it
imports.

## Generate and build (Simulator)

```bash
cd examples/probe-app
xcodegen generate

xcodebuild -scheme PhoneDSHProbe \
  -destination 'generic/platform=iOS Simulator' \
  build CODE_SIGNING_ALLOWED=NO
```

The generated `PhoneDSHProbe.xcodeproj` is intentionally not committed. The
plain build does not boot the Worker; the W3-SIM gate below does. Every
simulator report is written with `environment: "ios-simulator"` and is **not**
device evidence.

## Simulator gate (W3-SIM)

`scripts/ci/sim.sh` is the headless iOS Simulator gate for the phone-DSH
host. It boots (or reuses) the `iPhone 17 Pro` simulator, builds the packed
Worker assets and the probe app, installs the app, runs the hostless
`PhoneDSHSimTests` target with `xcodebuild test -scheme PhoneDSHSim`, and pulls
the four JSON reports from the app container. When `Bundle/worker/web` is not
staged yet and the pinned checkout is available, it builds the complete DSH
Web page through `scripts/ci/build-web-dist.sh` first; a prebuilt
`PDSH_DSH_WWW/web` is staged through the same `--web-dist` path.

Before staging and again afterwards, `sim.sh` audits the same-source records:
`web/web-build.json` must name `plugins/dsh-pin.json` and its recorded
`index_sha256`/`entry_sha256` must match the staged page bytes;
`sizes.json` must name the same pin/commit/version and its `gzip_bytes` must
match `image.tar.gz`; `probe-bundle.json` must record the pack-image source
and JavaScriptCore prelude. A missing record is never synthesized for a
prebuilt page — the gate fails instead of stamping an older Web dist with the
current pin. `sim.sh` repeats the same comparison on the staged bundle before
any suite starts.

```bash
# From the repository root. DSH is resolved from PDSH_DSH_CHECKOUT or the
# single line of $HOME/.config/phone-dsh/dsh-checkout; no local path is committed.
export PDSH_DSH_CHECKOUT="${PDSH_DSH_CHECKOUT:-$(cat "$HOME/.config/phone-dsh/dsh-checkout")}"
bash scripts/ci/sim.sh
```

The `PhoneDSHSim` scheme has one hostless test target, `PhoneDSHSimTests`; it
builds the app because the tests load the same `Bundle/worker/` a device build
serves. Four gated report suites run in one process; the same target also runs
the MCP production and Web→native bridge suites (the former writes its own
`worker-mcp-production-report.json`):

| Suite | Report | Gate |
|---|---|---|
| Phase 0 probes through the same `ProbeKit` implementation the Probes page runs | `probe-report.json` | G0 |
| One real model tool call (`bash -c` writing `a.txt`), WAL/materialized/journal/step-machine assertions, one D24 planned restart, resumed session | `smoke-report.json` | G1 |
| 20 seeded kills over `worker-terminate` and `webcontent-restart` × the four W3-KILL timings, each with acked-prefix/VFS/reconcile assertions | `kill-report.json` | G1 |

Every row carries its G0/G1 threshold (or an explicit `n/a`), a
PASS/FAIL/INFO status and `"environment": "ios-simulator"`. The script prints
the table, exits non-zero on any FAIL row or missing report, and prints the
last 50 smoke console lines on failure. Information-only probes that cannot
produce a measurement stay INFO with the reason in `detail`; they never
masquerade as a FAIL row. Timeouts are generous (Worker boot up to 240 s; the
whole run defaults to 1800 s).

The report table and its exit status live in
`scripts/ci/sim_gate.py`. Every `sim.sh` invocation first runs
`sim_gate.py --selftest`, which feeds synthetic reports through the same gate
and asserts that a non-gating FAIL row (as well as a gating FAIL row, a wrong
environment, `ok: false` and a missing report) exits non-zero. The
FAIL-to-exit-status path is therefore demonstrated on every run, not only
inspected. The complete script log, including the tail of the `xcodebuild
test` output, is written to `$OUT/sim.log`.

Reports are written by the tests into the probe app container at
`Documents/pdsh-reports/` and copied by the script to:

```
$OUT/probe-report.json
$OUT/smoke-report.json
$OUT/kill-report.json
```

`OUT` defaults to `${TMPDIR}/pdsh-sim`; override it with `OUT=/path`. The
simulator run also attempts one real WebContent SIGKILL, scoped to the selected
simulator: before the suites the script records that simulator's existing
WebContent pids and starts a background watcher that follows the app's current
data container to write `expect-real-kill` there. The smoke suite writes
`real-kill-ready.json` while its real WKWebView is alive, waits (bounded) for
the watcher's result, and then gates recovery of the same Session and a
completed follow-up turn from that real kill. Following the container matters
because `xcodebuild test` can reinstall the app and move
`Documents/pdsh-reports`; a marker written only before the run would be lost. A
candidate pid must contain the simulator's runtime path (`CoreSimulator`) and
the WebKit WebContent executable path, and carry the selected simulator's
`SIMULATOR_UDID` in its environment; a host process — including a Safari or
other-simulator WebContent — matches none of that and is never signalled. The
attempt is logged and recorded as an INFO row; the recovery row after it is
the gate, so a run that never attempted the SIGKILL cannot pass. If the harness forbids the pseudo-terminal
`xcodebuild test` needs, the script falls back to launching the same XCTest
bundle with `simctl spawn` (same suites, same reports) and says so in its log.

All of this is simulator evidence. iOS/WebKit behaviour on an iPhone —
background scheduling, memory ceilings/jetsam, real JIT speed, thermal
behaviour — stays **NOT_VERIFIED** until a device run records its own report.

## Run on a device

1. `xcodegen generate`, then open `PhoneDSHProbe.xcodeproj` in Xcode.
2. Set your development team (or pass `DEVELOPMENT_TEAM=<id>` to
   `xcodebuild`). The bundle id is a placeholder
   (`dev.phone-dsh.probe`); replace it in `project.yml` with an
   identifier your team owns. The continued-processing task identifier family
   in `Config/PhoneDSHProbe-Info.plist` derives from
   `$(PRODUCT_BUNDLE_IDENTIFIER)`, so it follows automatically.
3. Copy the Worker assets (next section), then build and run on the phone.
4. Use the five tabs; keep the active page in the foreground while a run is in
   progress.
5. Open **Export**, tap **Write report**, then **Share JSON** and copy the file
   into the repository at:

   ```
   acceptance/device/<date>-<device>.json
   ```

   The suggested file name is already `<yyyy-MM-dd>-<hardware model>.json`
   (for example `2026-10-25-iPhone17_1.json`). The report records the
   environment, so a simulator export is clearly labelled as such.

Device caveats that are `NOT_VERIFIED`: background scheduling and survival,
`BGContinuedProcessingTask` granting, Lockdown Mode effects on the Worker,
jetsam/WebContent termination behaviour, real memory ceilings and screen
brightness control. The app records what it observes; it never substitutes a
default.

## Worker asset copy step

The Memory and Background pages need the packed Worker image and static www.
They are produced by the verified DSH checkout and are not committed:

```bash
# From the repository root. The checkout is resolved from PDSH_DSH_CHECKOUT or
# the single line of $HOME/.config/phone-dsh/dsh-checkout; no path is written to git.
export PDSH_DSH_CHECKOUT="${PDSH_DSH_CHECKOUT:-$(cat "$HOME/.config/phone-dsh/dsh-checkout")}"

# Mac non-root: keep pnpm's store outside the checkout and outside /root.
export PDSH_PNPM_STORE="${PDSH_PNPM_STORE:-/tmp/phone-dsh-pnpm-store}"

# Warm plugins dependencies once (esbuild/typescript); the scripts do not
# install anything themselves.
( cd plugins && npm install --no-audit --no-fund )

# Default: build the canonical plugins/dsh-pin.json commit from a read-only
# temporary clone. The shared pnpm store is explicit.
bash scripts/ci/build-web-dist.sh --source "$PDSH_DSH_CHECKOUT" \
  --store "$PDSH_PNPM_STORE"

# Controlled release checkout (for example the upgraded 21-item phone Web):
# pass the actual clean/built checkout HEAD and its apps/cli version. The pair
# must match the checkout; dsh-pin.json is not edited.
export DSH_COMMIT="<40-hex actual checkout HEAD>"
export DSH_VERSION="<apps/cli/package.json version>"
bash scripts/ci/build-web-dist.sh --source "$PDSH_DSH_CHECKOUT" \
  --commit "$DSH_COMMIT" --version "$DSH_VERSION" \
  --store "$PDSH_PNPM_STORE"

# Build and copy the Worker bundle into examples/probe-app/Bundle/worker/.
# The copy step forwards web-build.json's commit/version to pack-image and
# requires the staged web and image sizes.json to name the same source.
examples/probe-app/scripts/copy-bundle-assets.sh \
  --checkout "$PDSH_DSH_CHECKOUT" --force

# Re-generate the project so Xcode picks up the folder contents and rebuild.
cd examples/probe-app && xcodegen generate
```

The standard copy builds or reuses the CPython/WASI pair with
`scripts/ci/python-artifacts.sh` and the jq WASI engine with
`scripts/ci/jq-artifacts.sh`, then packs both into the app image. The helpers
store their caches under the system temporary directory by default; set
`PDSH_PYTHON_ARTIFACTS` / `PDSH_JQ_ARTIFACTS` to choose another local cache. To
intentionally omit Python or jq, pass `--without-python` or `--without-jq`.
That choice is recorded in `Bundle/worker/phone-dsh-provenance.json` and
`probe-bundle.json`. Reusing `--image-out DIR` requires the packer provenance
sidecar, and the final bundle is checked against its source and byte hashes
before the build completes.

`scripts/copy-bundle-assets.sh`:

1. when `--worker-out` is not supplied, verifies the `--checkout` with
   `plugins/scripts/dsh-checkout.mjs` against the Web build's commit/version,
   then runs `plugins/worker-entry/build.mjs --out <tmp>` for the page entry.
   A checkout that differs from the Web/image source fails before anything is
   staged; pass `--worker-out` only for a separately verified build;
2. resolves the Python artifact pair and the jq engine by default, then runs
   `plugins/scripts/pack-image.mjs --out <tmp> --checkout-sha <web commit>
   --checkout-version <web dsh_version> --python <artifact-dir> --jq <dir>` for
   `image.tar.gz`, `lazy/`, `worker.js`, `client.js`, `manifest.json` and
   `sizes.json` plus the image provenance sidecar (`--without-python` /
   `--without-jq` are the explicit opt-outs);
3. prepends the same JavaScriptCore compatibility prelude
   `scripts/ci/smoke.sh` uses (`Symbol.dispose`,
   `Symbol.asyncDispose`, `ReadableStream` async iteration). This is a known
   W1-ENTRY gap: the entry bundle does not install these definitions itself, so
   the probe build applies them at copy time;
4. assembles `Bundle/worker/` (`index.html`, `boot.js`, `worker-entry.js`,
   `tool-worker-python.js`, `tool-worker.js`, `image.tar.gz`, `lazy/`,
   metadata). Both tool workers are served beside `worker-entry.js`: the
   python runtime spawns `tool-worker-python.js` and the generic WASI toolbox
   (the jq engine) spawns `tool-worker.js`; omitting either leaves that
   command family waiting on a 404 nested Worker instead of running;
5. preserves `Bundle/worker/web/` (the full DSH Web page built by
   `scripts/ci/build-web-dist.sh`) and stages the built `web-boot.js` beside
   `web/index.html`; the page's relative `assets/*` then resolve under
   `/static/web/assets/*`. When a Web dist is supplied or already staged, the
   copy requires the real `web-build.json` and fails when it is missing, does
   not match the staged bytes, or names a different commit/version than
   `sizes.json`; it never fabricates the record. When none exists, the copy
   still stages the legacy Worker/www assets and says that the full page is
   absent. A no-force run that finds an existing same-source `Bundle/worker/`
   skips only when every runtime file is present and non-empty
   (`worker-entry.js`, `tool-worker-python.js`, `index.html`, `boot.js`,
   `web/index.html`, `web/web-boot.js`, `web/assets/`, `sizes.json`,
   `probe-bundle.json`); otherwise it fails and asks for `--force`.

Reuse existing build outputs with `--worker-out DIR` / `--image-out DIR` /
`--web-dist DIR` (or `PDSH_WEB_DIST`), or replace a previous copy with
`--force`; prebuilt worker directories must be complete bundle outputs with
the JavaScriptCore prelude already applied. Without the assets the Memory and
Background pages stay disabled and show exactly which files are missing; the
Probes page does not need them. The
full Web page still needs the app-side `/static/web/index.html` page path and
the `/api` + mux loopback carrier from the fullscreen/carrier work packages;
staging the files here is not by itself proof that the Web session is live.

## Pages

### Probes

Runs the same probe groups as `Tests/PhoneDSHProbeTests`, ported to the iOS
UI actor in `ProbeKit/ProbeRunner.swift` (the macOS test target is AppKit-bound
and stays the macOS implementation):

- channel: same-origin 1 KB / 1 MB `fetch` POSTs through `/v1/http`, chunked
  NDJSON first-chunk latency, 1000 sequential WebSocket echoes (p50/p95),
  COOP/COEP headers with the isolation switch on and off, secure-context and
  `crossOriginIsolated` reports, `localhost` cross-check;
- timer throttling: 10 ms interval in a one-point visible view, the same view
  hidden, and a detached WKWebView;
- JIT baseline: the MB-scale JSON + template benchmark in a bare
  `JSContext` and in the WKWebView;
- `WorkspaceLog` checkpoint: 100 one-KiB writes, materialization and epoch
  close.

Rows show PASS/FAIL/INFO, every metric and the G0 threshold it was compared
against. The thresholds listed before any run are:

| Name | Bound | Gating | Source |
|---|---|---|---|
| `loopback_round_trip_p95` | p95 ≤ 5 ms | yes | PLAN §2.5, `spec/v1/budgets.md` §4 |
| `checkpoint_100_files` | ≤ 100 ms (append time) | no | PLAN W1-LOG, informational |
| `recovery_time_target` | `a + k × MB`, `a ≤ 3 s`, `k ≤ 0.05 s/MB` | no | PLAN §2.5, `budgets.md` §4 |

### Memory

Each level boots the real `PhoneDSHHost` on a fresh workspace and measures:

1. a first boot that lets `WorkspaceLog` create `manifest.json` (recovery
   deletes an unmanifested materialized tree);
2. the synthetic overlay: 20/50/100 MiB of deterministic, incompressible
   files written under `materialized/workspace/overlay/` in ≤ 8 MiB chunks
   (below the 15 MiB single-file cap; total below the 150 MB VFS cap);
3. a second boot, so the host packs the gzip overlay (D21) and the Worker
   loads it;
4. a scripted long session (12 stages, two `PhoneDSHHost.plannedRestart`
   cycles) with process proxy samples.

Recorded values: boot time, WebContent termination count, peak
`phys_footprint`, minimum `os_proc_available_memory`, VFS/session/WAL bytes from
the host budget snapshot, and a time series of all of these. The probe app
ships **no model upstream**, so the scripted session exercises host lifecycle
and overlay reloads, not model turns; a model-backed long session remains a
manual addition.

### Background

The matrix is `background` / `lock` × 10 minutes × with / without the iOS 26
`BGContinuedProcessingTask` window:

- **Start cell** boots the host and opens the OS window (`PlatformBackgroundTaskScheduler`
  when the continued-processing arm is selected, `NoopBackgroundTaskScheduler`
  for the arm without it).
- The operator then presses Home (background row) or locks the phone (lock
  row). On the way out the runner parks the host; on return it measures the
  observed interval, resumes the host, records the recovery duration and writes
  the matrix cell.
- The lock row also records `protectedDataWillBecomeUnavailable` /
  `protectedDataDidBecomeAvailable` notifications as the lock signal.
- The 60-second selection exists only as a UI smoke; it is recorded as
  `PARTIAL` and never satisfies the 10-minute matrix.

Recorded values: the arm the OS actually opened
(`continuedProcessing`, `backgroundTask`, `none`), observed background interval,
`heldFullWindow`, `lockObserved`, `recovered`, recovery seconds and every
controller/app transition observed.

### Screen

Presents the landed `TaskScreen` from `PhoneDSH` with a configurable
minimum brightness: pure black, no timers, no animation. The screen dimming is
best effort (global `UIScreen.main.brightness`) and is restored on disappear.

### Lockdown indicator

Every page shows the system Lockdown Mode state read from
`WKWebpagePreferences.isLockdownModeEnabled` (a public API). When it is on, the
indicator says the local harness is unavailable; the host itself also refuses
to boot (`PhoneDSHError.lockdownMode`).

### Export

Writes the aggregate report into the app's
`Documents/pdsh-reports/<yyyy-MM-dd>-<hardware model>.json` and offers it through
the system share sheet. The preview shows the same JSON document that is exported.

## Exported report schema

Top-level document (`schema: 1`). Fields that a run has not measured are
**absent** and the containing section carries `status: "NOT_VERIFIED"` (or
`"PARTIAL"` / `"FAILED"`). No placeholder number is ever written.

```json
{
  "schema": 1,
  "product": "phone-dsh-probe",
  "generatedAt": "2026-10-25T10:00:00.000Z",
  "environment": "ios-simulator | ios-device",
  "status": "NOT_VERIFIED | PARTIAL | MEASURED",
  "application": {
    "bundleID": "dev.phone-dsh.probe",
    "displayName": "phone DSH probe",
    "version": "0.1.0",
    "build": "1"
  },
  "device": {
    "model": "uname(2) machine, e.g. iPhone17,1",
    "system": "iOS 26.5",
    "name": "UIDevice.name",
    "physicalMemoryBytes": 8589934592
  },
  "lockdown": {
    "enabled": false,
    "source": "WKWebpagePreferences.isLockdownModeEnabled",
    "localHarnessAvailable": true
  },
  "probes": {
    "schema": 1,
    "generatedAt": "…",
    "platform": "iOS Simulator | iOS",
    "osVersion": "…",
    "environment": "ios-simulator | ios-device",
    "g0Thresholds": [
      {"name": "loopback_round_trip_p95", "value": 5.0, "unit": "ms",
       "source": "PLAN §2.5 and spec/v1/budgets.md §4",
       "gating": true}
    ],
    "summary": {"pass": 0, "fail": 0, "info": 0, "g0Passed": true,
                "failedGatingProbes": []},
    "rows": [
      {
        "probe": "channel.ws-echo-1000",
        "kind": "channel",
        "status": "PASS | FAIL | INFO",
        "gating": true,
        "metrics": {"count": 1000, "p50_ms": 0.8, "p95_ms": 1.4},
        "threshold": {"name": "loopback_round_trip_p95", "value": 5.0,
                      "unit": "ms", "source": "…", "comparison": "<=",
                      "measured": 1.4, "met": true, "gating": true},
        "detail": "…",
        "recordedAt": "2026-10-25T10:00:00.000Z",
        "environment": "ios-simulator | ios-device"
      }
    ]
  },
  "memory": {
    "levels": [
      {
        "overlayMB": 20,
        "status": "NOT_VERIFIED | MEASURED | FAILED | SKIPPED",
        "startedAt": "…",
        "durationSeconds": 90.5,
        "bootSeconds": 1.2,
        "webContentTerminations": 0,
        "peakFootprintBytes": 123456789,
        "minAvailableBytes": 987654321,
        "samples": [
          {"offsetSeconds": 5.0, "footprintBytes": 123456789,
           "availableBytes": 987654321, "hostState": "running",
           "vfsBytes": 0, "sessionBytes": 0, "walBytes": 0,
           "webContentTerminations": 0}
        ],
        "detail": "…"
      }
    ],
    "session": {
      "status": "NOT_VERIFIED | MEASURED | FAILED",
      "startedAt": "…", "durationSeconds": 90.0, "plannedRestarts": 2,
      "webContentTerminations": 0, "peakFootprintBytes": 123456789,
      "minAvailableBytes": 987654321, "samples": [], "detail": "…"
    },
    "notes": ["…"]
  },
  "background": {
    "requiredDurationSeconds": 600.0,
    "cells": [
      {
        "scenario": "background | lock",
        "continuedProcessing": true,
        "status": "NOT_VERIFIED | MEASURED | PARTIAL | FAILED",
        "arm": "continuedProcessing | backgroundTask | none",
        "requiredSeconds": 600.0,
        "observedBackgroundSeconds": 601.2,
        "heldFullWindow": true,
        "lockObserved": true,
        "recovered": true,
        "recoverySeconds": 0.42,
        "transitions": [
          {"at": "…", "kind": "scene-phase", "from": null, "to": null,
           "detail": "background"}
        ],
        "detail": "…"
      }
    ],
    "notes": ["…"]
  },
  "taskScreen": {
    "presented": false,
    "minimumBrightness": 0.0,
    "note": "…"
  },
  "notes": ["…"]
}
```

`probes.rows[].threshold` is omitted when the row has no numeric bound
(INFO-only probes). `probes.rows[].metrics` values are JSON numbers, booleans
or strings; sections and row members that have not been measured are omitted.
`memory` values are proxies: `phys_footprint` is the App process footprint and
`os_proc_available_memory` is the headroom the system reports; WebContent is a
separate process. `background.cells[].arm` uses the SDK's
`BackgroundTaskKind` raw values. Every `transitions[]` entry is a timestamped
observation, not an inferred state.

A report exported on the simulator carries `environment: "ios-simulator"` on
the document and on every probe row; do not treat it as an iPhone measurement.

## Known gaps

- **Shared probe implementation.** `ProbeKit` is the iOS port of the W3-PROBES
  suite and bundles the same `probe-site` fixture folder by a project reference
  to `Sources/PhoneDSHHarness/Resources/probe-site` (one source of
  truth for the JavaScript). The W3-SIM `PhoneDSHSimTests` target runs the Probes
  page's `ProbeKit` implementation directly. The Swift probe helpers in the
  macOS XCTest target are AppKit-bound and could not be moved out of `sdk/`
  from this example's write scope. A follow-up should add an SDK library target
  (for example `PhoneDSHProbeKit`) and have both the macOS test target
  and this app depend on it, so there is one shared implementation.
- **JavaScriptCore prelude.** The Worker entry built by
  `plugins/worker-entry/build.mjs` needs `Symbol.dispose` /
  `Symbol.asyncDispose` and `ReadableStream` async iteration before DSH 0.2.1
  boots in JavaScriptCore. The copy script prepends them, as
  `scripts/ci/smoke.sh` does; W1-ENTRY should install them in the entry.
- **No app model upstream.** The Memory page's scripted session is a lifecycle
  workload; it does not drive model turns. The W3-SIM smoke does drive one
  scripted model turn through a loopback HTTP server inside its test process.
- Device behaviour listed under "Run on a device" is `NOT_VERIFIED` until the
  user runs the app and exports the JSON.

## License

MIT. Every source file carries an SPDX MIT header. The app links only
permissive phone-DSH modules and never `XiaozhiLinkToolbox*` (GPL).
