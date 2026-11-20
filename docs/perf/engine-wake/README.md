<!-- SPDX-License-Identifier: MIT -->
# Engine-first-launch wake measurement (iOS)

Plan: `§2.4` (WebView-in-window risk) and `§2.8` (LAN unreachable while
suspended, cloud-task push fallback).

This directory describes the **evidence format** and the operator protocol for
the physical-device run. It contains **no device numbers**: the Fleet worker
that wrote this had no Xcode, simulator or iPhone, so every command below is
`NOT_RUN` in its own report. The caller runs them on a Mac with a paired iPhone.

The tool extends the existing WP1 `scripts/ci/bot-residency` harness
(`BotResidencySpike` app + `analyze.py`); it is not a second measurement stack.

```bash
bash scripts/ci/bot-residency/run-engine-wake.sh \
  --development-team <team-id> \
  --lan-host <iPhone-LAN-IP> \
  --output-dir /tmp/phonedsh-engine-wake/run-1
```

`--lan-host` is required for meaningful LAN evidence. Without it the two LAN
scenarios are recorded as `NOT_RUN`, never as a pass.

## 1. What is measured

Each attempt records:

| Field | Meaning |
|---|---|
| `wakeToHostStartMs` | trigger receipt → `PhoneDSHHost.start()` / `resume()` returned |
| `hostStateBefore` | `absent`, `parked`, `running`, `failed`, … before the wake |
| `decision` | the provisional policy result (`boot`, `resume`, `ready`, `nativeOnly`, `needsAttention`) |
| `processWasRunning` | whether the app process predated the trigger (cold-start check) |
| `sceneConnectedAtTrigger` | whether any `UIScene` was connected when the trigger arrived |
| `offscreenWindowUsed` | whether the anchor was hosted by the prototype offscreen `UIWindow` |
| `anchorInWindowAfterBoot` | `VisibleEngineAnchor.isInWindow` after the boot |
| `webContentPIDBefore` / `After` | best-effort `_webContentProcessIdentifier`; `webContentTerminated` is set when both exist and differ |
| `leaseRemainingMsAtTrigger` | `UIApplication.backgroundTimeRemaining` at the trigger, when backgrounded |
| `backgroundTimeRemainingCurve` | `{atMs, remainingMs}` samples every 250 ms |
| `residentAudio` | whether the silent audio keep-alive was rendering |
| `userVisiblePrompt` | always `false` in this spike: it never shows a status line or error |
| `error` | boot/resume failure text, if any |

Scenarios (fixed ids):

1. `push-cold-start` — content-available push with no live process; no connected
   scene; the anchor is hosted by the offscreen 2×2, alpha 0.01 window.
2. `push-parked-resume` — the host was parked, then a push resumes it.
3. `bgprocessing-cold-start` — a `BGProcessingTask` cold launch.
4. `board-wake-cold-start` — control group: the existing audio keep-alive is
   rendering and the board-wake entry boots the engine. The process is already
   alive (that is the point of the control); only the engine is cold.
5. `lan-resident` — app resident; the helper probes the app's local TCP port and
   expects an answer.
6. `lan-suspended` — app backgrounded and suspended; the helper's probe must be
   unreachable, then a cloud-task push must wake the app. A reachable probe is a
   `FAIL` (the process was not suspended or the listener kept it alive).

## 2. Thresholds

The analysis reads the frozen constants from
`spec/host/v1/golden/engine-launch.json` when that file exists:

- `minLeaseForColdBootMs = 20000` (provisional)
- `minLeaseForResumeMs = 8000` (provisional)
- `parkMarginMs = 5000` (provisional)

If the golden is absent it falls back to those plan values and labels the
source `provisional-plan`. The spike boots even when the provisional rule would
have deferred, and records `forcedForMeasurement`, so the run yields a latency
distribution instead of an empty report. It does **not** change the contract;
only a new frozen revision can do that.

## 3. Triggers

The tool never fabricates a physical-device wake.

| Scenario | How the trigger is produced |
|---|---|
| push | APNs test push with `content-available: 1` (development APNs provider, Xcode push notification tool, or the caller's developer tooling). The first launch is `--arm-only`: it registers the token and persists the configuration, then the helper terminates the process. Send the push after the helper prints the action. |
| BGProcessing | `EngineWakeBGTask.submit()` schedules one request; let the system run it or simulate it from Xcode (**Debug → Simulate Background Task**) with the printed identifier. |
| board | The real board / BLE path. With no board attached, the spike synthesises the event after 3 s at the same audio-resident entry; the report records `synthetic-board-wake` in `engine-wake-events.jsonl`. This measures the audio-resident boot latency, not BLE radio latency. |
| LAN | The helper issues `HTTP GET /engine-wake?scenario=...` to `--lan-host:<port>`; the app reports its bound port in `engine-wake-state.json`. |
| simulator | `xcrun simctl push` only. Harness exercise; every verdict is `NOT_RUN`. |

A user force-quit disables background relaunch. The helper uses a process
termination, which still leaves the cold-start claim to the evidence:
`processWasRunning` must be `false`, otherwise the attempt fails.

## 4. Evidence layout

Default output `${TMPDIR}/phonedsh-engine-wake/<run-id>/`:

- `summary.json` — final `PASS` / `FAIL` / `NOT_RUN`, per-scenario p50/p95,
  suggested thresholds, checks;
- `host-report.json` — helper-side LAN probe records, last app phase,
  acquisition errors;
- `device/**/engine-wake-report.json` — the app report described by
  `engine-wake.schema.json`;
- `device/**/engine-wake-state.json` — last polled scenario/trigger/probe state;
- `device/**/engine-wake-events.jsonl` — append/fsync event log;
- `device.json` / `device-discovery.json` — sanitised device identity;
- `lan-probes` inside `host-report.json` — sent/reachability/RTT per probe;
- `push-payload.json` — the simulator-only payload used by `simctl push`;
- `xcodebuild.log`, `install.log`, `launch.log`, `commands/`.

`engine-wake-empty.json` is the empty app-report template (schema + zero
attempts). It is not evidence.

## 5. Verdict rules

`analyze.py --engine-wake` sets the verdict from the real evidence:

- a simulator report is always `NOT_RUN` (`deviceClass=simulator`), whatever
  the timings look like;
- a scenario with no attempt is `NOT_RUN`, never `PASS`;
- a physical attempt fails (FAIL) when `wakeToHostStartMs` is missing/negative,
  the anchor is not in a window after boot, or an error was recorded;
- a scenario is `NOT_RUN`, not `FAIL`, when it was not exercised as specified:
  `push-cold-start` / `bgprocessing-cold-start` ran on an already-running
  process, the resume scenario did
  not start from `parked`, the board scenario had no resident audio, or a
  scene-less push did not use the offscreen window;
- `lan-resident` passes only if at least one probe answered;
- `lan-suspended` passes only if every probe was unreachable **and** the push
  fallback attempt was measured;
- overall: any `FAIL` → `FAIL`; all six `PASS` → `PASS`; otherwise `NOT_RUN`.

p50/p95 use the nearest-rank definition over the valid samples of each
scenario.

### Suggested constants

```
minLeaseForColdBootMs = ceil_to_1000(p95(cold wake→hostStart) + parkMarginMs)
minLeaseForResumeMs   = ceil_to_1000(p95(parked resume)     + parkMarginMs)
```

Cold scenarios are `push-cold-start`, `bgprocessing-cold-start` and
`board-wake-cold-start`. Simulator samples are excluded. The suggestion is a
lower bound for the next contract revision; the contract owner decides the
final value together with the ReadySweep budget.

## 6. What this tool does not do

- It does not change `ChatModel`, `ProbeKit/Lifecycle`, the production
  `EngineLaunchOrchestrator`, any spec, schema, golden, payload or quota.
- It does not add `UIBackgroundModes` to the production app, an audio keep-alive
  purpose, or a push SDK. The spike plist declares `processing` only so the
  BGProcessing scenario can run; the production plist already has it.
- It does not claim device behaviour from static checks, compilation, a
  simulator or a host build.

## 7. Handoff evidence shape (AGENTS.md §3.5)

```text
Base / head:        <sha> / <sha>
Protocol impact:    P06: none — measurement harness only
Contract revision:  <spec/host/v1/golden/engine-launch.json @ rev>
Changed files:      scripts/ci/bot-residency/**, examples/probe-app/**/BotResidencySpike/**, docs/perf/engine-wake/**
Status per end:     iOS: partial (tool delivered; device run NOT_RUN)
Commands → result:  <exact command> → PASS | FAIL | NOT_RUN
Not verified:       physical-device timings, WebContent survival, BGTask, APNs, BLE board, LAN fallback
Remaining risks:    offscreen window may not keep WebKit visible; force-quit disables push relaunch
```
