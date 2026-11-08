<!-- SPDX-License-Identifier: MIT -->

# Run the WP1 physical-device spike

Contract revision: `b5192c4a3eedd94ac4878bc0270684f7854ac273`.
The acceptance command is:

```bash
bash scripts/ci/bot-residency/run-device.sh \
  --duration-seconds 7200 --events 10 --kill-webcontent 3 \
  --development-team <team-id>
```

Use `--device <devicectl-identifier>` when more than one physical device is
available. `--seed <uint64>` reproduces the per-segment random event/kill
offsets. The default seed and run ID are recorded. Other runs must use a new
`--run-id` or `--output-dir`; an existing non-empty evidence directory is never
deleted.

## Prerequisites

- Xcode, XcodeGen, Python 3, and `xcrun devicectl`.
- A paired physical iPhone/iPad whose `tunnelState` is `available` or
  `connected`. A paired but unavailable device, or a simulator, produces
  `NOT_RUN`. Connection alone never upgrades the verdict to PASS.
- Automatic-signing credentials for the selected device. Pass the team with
  `--development-team`; optionally choose a provisionable `--bundle-id`.
- The normal Worker assets staged by the existing repository flow. The spike
  does not patch, vendor, or build a private DSH variant:

```bash
# Existing phoneDSH DSH checkout, not the read-only dsh-bot specification checkout.
export PDSH_DSH_CHECKOUT=<existing-phoneDSH-DSH-checkout>
bash examples/probe-app/scripts/copy-bundle-assets.sh \
  --checkout "$PDSH_DSH_CHECKOUT" --force
```

The copy step has its own documented artifact prerequisites. If assets or
signing are unavailable, `run-device.sh` stops as `NOT_RUN` before starting a
device measurement.

## Operator protocol

1. Keep the device connected and launch the command.
2. When the app says **Ready**, lock it. Do not press Home and do not unlock
   during the requested window.
3. The app schedules ten host events and the host schedules three SIGKILLs from
   one recorded seeded plan. The host also samples `devicectl lockState`.
4. When the app says the locked window is complete, unlock once if it asks.
   Foreground return permits deferred P6 recovery. Do not relaunch the app.
5. Wait for the command to pull evidence and print the final verdict. Cleanup
   terminates only the spike app's recorded PID.

A first background kill may make later kills impossible because P6 does not
create a replacement WebContent process until foreground return. This is a
valid negative spike result, not something to work around by unlocking early.

## Exit and verdict

| Exit | Meaning |
| --- | --- |
| 0 | `PASS` / go: all checks passed on a physical device. |
| 1 | `FAIL` / no-go: a run started or evidence exists, but acceptance failed. |
| 2 | Invalid arguments or an unsafe output-directory choice. |
| 3 | `NOT_RUN`: no physical-device measurement was performed. |

PASS requires all of the following:

- the requested locked duration is covered by protected-data and/or devicectl
  lock evidence;
- every expected event was injected and delivered exactly once, with one user
  sequence, one successful tool result, one final assistant message, and a
  completed turn;
- every delivery latency from the later of injection and recovered HELLO is at
  most 30 seconds;
- every requested kill has both a successful, process-verified devicectl
  SIGKILL and an associated WebKit termination/replacement HELLO;
- no P6 background-boot violation and no HELLO/P15 error evidence;
- the scripted loopback model completed at least two requests per event.

Static checks, compilation, and analyzer self-tests do not satisfy any of these
device checks. Simulator execution is not accepted by this runner.

## Evidence layout

The default output is `${TMPDIR}/phonedsh-bot-residency/<run-id>/`:

- `summary.json`: final PASS/FAIL/NOT_RUN, per-check results, metrics, and CCR
  filenames;
- `device.json`: selected model, product type, OS/build, and availability (the
  user device name and private hostname are not exported);
- `device-discovery.json`: sanitized discovery records;
- `device/**/app-report.json`: app event/recovery records;
- `device/**/app-events.jsonl`: ordered, append/fsynced app observations;
- `device/**/plan.json`: run configuration and seeded schedule;
- `kill-results.json`: PID verification and signal outcomes;
- `lock-samples.jsonl`: timestamped devicectl lock observations;
- `host-report.json`: acquisition status and host-side kill summary;
- `commands/`: devicectl JSON/log results;
- `xcodebuild.log`, `install.log`, `launch.log`: build and launch evidence.

Evidence is written outside git by default. Review it for local paths before
sharing it. No credentials are used; the model is the existing loopback mock.

## CCR behavior

P01 HELLO/lease failures and P15 recovery-route failures emit the exact AGENTS
§3.3 `CONTRACT CHANGE REQUEST` shape as `ccr-P01.txt` or `ccr-P15.txt`. If P6
prevents the required repeated background kills, `ccr-P08.txt` records the
architectural decision for WP0/WP10. WP1 does not patch HELLO, P15, P6, specs,
wire fields, environment variables, or dependencies.

## Local-only validation

```bash
python3 scripts/ci/bot-residency/analyze.py --selftest
python3 scripts/ci/bot-residency/device_driver.py --selftest
bash -n scripts/ci/bot-residency/run-device.sh
plutil -lint \
  scripts/ci/bot-residency/app/Config/BotResidencySpike-Info.plist \
  scripts/ci/bot-residency/app/Config/BotResidencySpike.entitlements
```

These commands validate the harness only and are not device evidence.
