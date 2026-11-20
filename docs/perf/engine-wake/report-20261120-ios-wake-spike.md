Protocol impact: P06: none — this unit adds a device-measurement harness only and changes no WakeReason, WakeLease, ReadySweep or engine-launch rule; P05: none — no cloud-task payload, route, ack or limit; P09: none — no production UI text; P04: none — the offscreen anchor window exists only in the spike target, not in the bridge or the production WebView path.

# ios-wake-spike — physical-device measurement tool (plan §2.4 / §2.8)

Base / head: `87a2486edb715f8bff959c94621abe423163a951` / this unit's single commit (SHA in the activity handoff; a commit cannot contain its own SHA)
Contract revision: `PC-20261120-engine-first-launch` (owned by `contracts`; this unit edits no `spec/**` file)
Mode: implementation (spike instrumentation, not production policy)

## Deliverable

One command on the caller's Mac + iPhone:

```bash
bash scripts/ci/bot-residency/run-engine-wake.sh \
  --development-team <team-id> \
  --lan-host <iPhone-LAN-IP> \
  --output-dir /tmp/phonedsh-engine-wake/run-1
```

The tool extends the existing WP1 `BotResidencySpike` app, its XcodeGen project,
`device_driver.py` and `analyze.py`; it does not start a second harness. It
covers the five requested scenarios (six ids):

| Scenario id | What it measures |
|---|---|
| `push-cold-start` | content-available push with no live process; offscreen 2×2 / alpha 0.01 window hosts the anchor when no scene is connected |
| `push-parked-resume` | push resume from a parked host |
| `bgprocessing-cold-start` | `BGProcessingTask` cold launch |
| `board-wake-cold-start` | audio-resident control group (the real board path; synthesized 3 s after arming when no board is attached) |
| `lan-resident` | app resident: helper `HTTP GET /engine-wake` answers |
| `lan-suspended` | app suspended: probe must be unreachable; cloud-task push fallback must wake it |

Every attempt records `wakeToHostStartMs` (trigger → `start()`/`resume()`
return), WebContent PID before/after and whether it was replaced,
`backgroundTimeRemaining` sampled every 250 ms, scene connectivity, anchor
visibility, lease remaining, policy decision and `forcedForMeasurement`.
`analyze.py --engine-wake` emits per-scenario p50/p95 and:

```
minLeaseForColdBootMs = ceil_to_1000(p95(cold wake→hostStart) + parkMarginMs)
minLeaseForResumeMs   = ceil_to_1000(p95(parked resume)     + parkMarginMs)
```

Simulator reports carry `deviceClass=simulator` and are always `NOT_RUN`;
`PASS` can only come from a physical-device report.

## Changed files (this unit only)

- `scripts/ci/bot-residency/analyze.py` — engine-wake analysis, p50/p95,
  threshold suggestions, PASS/FAIL/NOT_RUN, expanded selftests.
- `scripts/ci/bot-residency/device_driver.py` — engine-wake driver (state
  polling, LAN probes, external-trigger instructions, simulator push, evidence
  pull), unchanged WP1 residency path.
- `scripts/ci/bot-residency/run-engine-wake.sh` — new one-command runner.
- `scripts/ci/bot-residency/app/Config/BotResidencySpike-Info.plist` —
  spike-only `processing` background mode and BGProcessing identifier.
- `examples/probe-app/PhoneDSHProbe/BotResidencySpike/Sources/` —
  `OffscreenEngineWindow.swift`, `EngineWakeRunner.swift`,
  `EngineWakeTriggers.swift`, `EngineWakeLANListener.swift`; app entry branches
  to the new root view by launch mode.
- `examples/probe-app/ProbeKit/BotResidencySpike/EngineWakeEvidence.swift` —
  Codable evidence model, armed configuration, thresholds.
- `docs/perf/engine-wake/` — README/format, JSON schema, empty template,
  NOT_RUN evidence.

No production file was modified: `ChatModel.swift`, `ProbeKit/Lifecycle`,
`EngineLaunchOrchestrator.swift`, `spec/**`, `android/**` and the production
`Config/PhoneDSHProbe-Info.plist` are untouched.

## 用戶可見變化

**正式 App：零變更。**

- 新增提示／限制／文案：無。正式 App 沒有新增任何提示、限制或文案。
- 刪除提示／文案：無。本單元沒有刪除 Bot 頁「請先啟動引擎」或 `Booting` 狀態行；那些屬於 `ios-launch` / `ios-bot`，且本單元未觸碰正式 UI 路徑。
- 本單元只在獨立的 `BotResidencySpike` scheme 新增一個量測畫面
  （"Engine-first-launch wake"，顯示 phase / scenario / attempts / token）。
  該 scheme 不隨正式 App 出貨，也不改變正式 App 的可見行為。

## 檢查結果

### 實際執行並通過

| Command | Result |
|---|---|
| `python3 -m py_compile scripts/ci/bot-residency/analyze.py scripts/ci/bot-residency/device_driver.py` | PASS |
| `python3 scripts/ci/bot-residency/analyze.py --selftest` | PASS（engine-wake + WP1 residency） |
| `python3 scripts/ci/bot-residency/device_driver.py --selftest` | PASS |
| `bash -n scripts/ci/bot-residency/run-device.sh` | PASS |
| `bash -n scripts/ci/bot-residency/run-engine-wake.sh` | PASS |
| `bash scripts/ci/bot-residency/run-device.sh --help` | PASS（exit 0） |
| `python3 scripts/ci/hygiene.py --root scripts/ci/bot-residency` | PASS（exit 0） |
| `python3 scripts/ci/hygiene.py --root examples/probe-app/PhoneDSHProbe/BotResidencySpike` | PASS（exit 0） |
| `python3 scripts/ci/hygiene.py --root examples/probe-app/ProbeKit/BotResidencySpike` | PASS（exit 0） |
| `python3 scripts/ci/hygiene.py --root docs/perf/engine-wake` | PASS（exit 0） |
| `python3 scripts/ci/license.py --root <each changed root>` | PASS（exit 0，四個 root） |
| `plistlib.load` on the spike `Info.plist` and `.entitlements` | PASS |
| JSON parse of `engine-wake.schema.json` and `engine-wake-empty.json` | PASS |
| `bash scripts/ci/bot-residency/run-engine-wake.sh --simulator "iPhone 17 Pro" --output-dir /tmp/ew-smoke` | exit 3 `NOT_RUN`（`xcodebuild is unavailable`），proves the NOT_RUN path and summary wiring |

### 實際執行但失敗

| Command | Result | Analysis |
|---|---|---|
| `bash scripts/ci/check.sh --only phone-license,phone-hygiene` | `phone-license` PASS；`phone-hygiene` **FAIL**（39 s, exit 1） | 同一個 base commit 的乾淨 worktree 也以相同方式失敗（`phone-hygiene` exit 1），因此不是本 diff 造成。全repo 既有 466 條 finding，例如 `spec/v1/tono-account.md:9`（banned-word / hostname）與 `docs/perf/sim-io-smoke-20261113.md:42`（home-path）。本單元新增／修改的四個 root 以 `hygiene.py --root` / `license.py --root` 執行皆 PASS；未放寬 allowlist，也未修改那些既有檔案。 |

### 未執行（原因與所需環境）

| Item | Status | Needed environment |
|---|---|---|
| `xcodegen generate` / `xcodebuild build` / `xcodebuild test` for the spike | NOT_RUN | macOS + Xcode + XcodeGen; Fleet worker is Linux and has no Swift toolchain |
| Swift compilation of the new spike files | NOT_RUN | macOS + Xcode. Static review only here; do not read this as a compile claim |
| Simulator run of the six scenarios | NOT_RUN | macOS + Xcode simulator. Even if run, the analyzer stamps `deviceClass=simulator` and returns `NOT_RUN`, never PASS |
| Physical-device wake, WebContent survival, `backgroundTimeRemaining` curve | NOT_RUN | paired iPhone + signing + `xcrun devicectl` + Worker assets |
| APNs content-available push (cold and parked) | NOT_RUN | APNs development credentials / Xcode push tooling; the caller sends the push after the helper prints the action |
| BGProcessingTask launch | NOT_RUN | device + system scheduling, or Xcode "Simulate Background Task" |
| Real BLE board wake | NOT_RUN | board hardware; the spike falls back to a synthetic event at the audio-resident entry and records that in `engine-wake-events.jsonl` |
| LAN resident/suspended probes and cloud-task push fallback | NOT_RUN | device on the same LAN with `--lan-host`, plus an APNs test push |

## Unresolved limitations / risks

1. **Offscreen window is unproven.** Whether WebKit keeps WebContent visible in a
   non-key 2×2 alpha-0.01 `UIWindow` with no connected scene can only be settled
   by the device run. If it fails, the contract's degradation is native pass +
   BGProcessing reservation, as plan §2.4 says.
2. **Cold push is hard to stage.** A user force-quit disables background
   relaunch. The helper uses a process termination and records
   `processWasRunning`; a warm attempt is classified `NOT_RUN`, not a pass.
3. **BGProcessing cold start is not deterministic.** Xcode's simulation runs in
   the existing process, so the honest result is usually `NOT_RUN`; only a
   system launch produces a cold sample.
4. **Board scenario is a control, not BLE radio measurement.** The synthetic
   event reuses the audio-resident entry; it does not measure BLE wake latency.
5. **WebContent PID is best-effort.** `_webContentProcessIdentifier` is a
   private WebKit accessor; when absent the field is omitted and
   `webContentTerminated` stays false.
6. **`phone-hygiene` is red at base.** Tracked separately; this unit did not
   touch the failing files and did not add an allowlist entry.
7. **Threshold recommendation is a lower bound.** `p95 + parkMarginMs` does not
   include ReadySweep execution time; the contract owner should combine it with
   the sweep budget before freezing a new revision.

## Handoff for the caller

1. Stage Worker assets (`examples/probe-app/Bundle/worker`), then run the
   command above with a signing team and the iPhone's LAN IP.
2. Follow the printed `ACTION REQUIRED` lines: send the APNs push after the
   helper terminates the armed process, press Home for the suspended LAN probe,
   and let/simulate the BGProcessingTask.
3. Read `summary.json`; `PASS`/`FAIL`/`NOT_RUN` is the only verdict vocabulary.
4. Use the suggested `minLeaseForColdBootMs` / `minLeaseForResumeMs` as input to
   the next contract revision; this unit does not re-freeze them.

Full diff: `git show HEAD` after checkout.
