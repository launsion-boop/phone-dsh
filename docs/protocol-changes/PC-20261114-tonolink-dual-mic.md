# TonoLink wake word through both microphones

```yaml
change: PC-20261114-tonolink-dual-mic
contracts: [P07]
status: implemented
breaking: false
version_decision: No version change. Wire bytes, events and limits are unchanged; only how the board decides a wake changes.
base: origin/main 7a11fd5b
contract_revision: spec/device/v1/tonolink-board.md §4.1 @ this branch
```

Protocol impact: P07. P07 — §4.1 records that the board now decides the wake with its two-mic AFE (BSS plus 2-channel WakeNet), while the turn's Opus packets still carry one raw microphone; the packet format, `ev wake`, `ev listen_end` and every limit stay as they were.

## Trigger → current → expected

- Trigger: the board has two microphones but woke on one; the user asked for real dual-mic processing.
- Current: WakeNet on one channel; the turn recorded that channel.
- Expected: ESP-SR's MM AFE (BSS) with WakeNet in 2-channel mode decides the wake; the turn keeps recording the raw microphone; single-mic WakeNet stays as the fallback when the AFE cannot be created.

## Ends

| End | Change |
| --- | --- |
| Firmware (`tonolink-m21-r4-firmware`, branch `feat/dual-mic-afe`) | `main/wake.c` AFE path: the wake task feeds both mics to the AFE (BSS) on core 1 at priority 6; an `afe_fetch` task (PSRAM stack) runs WakeNet on core 0 at priority 4; the turn records the raw mic on the wake task. `main/kconf/wake.in` `TONOLINK_WAKE_AFE`; `sdkconfig.defaults` CPU at 240 MHz. |
| Phone BLE library / app | none: same packets and events |
| Device tests | `TonoLinkWakeDeviceTests`: the phone's speaker says 你好小智 over a volume sweep; wake followed by a command checked through the app's voice log; board `wake info`, `diag`, log, USB reachability |

## Compatibility

| Pair | Behaviour |
| --- | --- |
| New firmware → any phone | identical bytes |
| Rollback of the firmware | single-mic path; nothing persisted by this change |
| AFE cannot start (memory) | the board logs a warning and wakes on one mic; `wake info` shows `engine=single-mic why=…` |

## What was measured and changed on the way (real board, phone speaker next to it)

| Build | Finding |
| --- | --- |
| AFE polled with `fetch_with_delay(…, 0)` | reset by the task watchdog (`reset_reason=task_wdt`): empty polls logged a warning each and starved core 1's idle task |
| AFE output recorded for the turn, all on core 1 at 160 MHz | AFE ring 100 % full, mic ring overrun, BSS `feed` up to 206 ms, `fetch` up to 560 ms; cloud ASR heard 1 of 3 |
| 240 MHz, `fetch` on core 0 | ring at most 28 %; ASR still heard 1 of 5 from the BSS output, against 5 of 5 from one raw mic on single-mic firmware in the same test |
| Wake on the AFE, record the raw mic | wake 5/5, ASR 5/5 (今天星期几) |
| …while unpinned AirPlay/USB tasks (priority 4–5) ran | `feed` held off core 1 for up to 551 ms, mic ring overrun 48 960 frames, wake 4/5 at full volume |
| Wake task 6, fetch task 4 (final) | `feed` at most 57 ms with the mirror off and 90 ms with it on, mic overrun 0, AFE ring at most 36 %, no reset |

Final build, mirror off: wake 5/5 at volumes 1.0, 0.02 and 0.017, 0/5 at 0.014 — the same threshold as single mic (0.017 5/5, 0.014 0/5). Wake followed by 今天星期几: 5 wakes, 5 correct transcripts. Wake-task stack free 9408 of 32 768 bytes; `afe_fetch` 31 348 free; internal heap minimum 33 676 bytes (below the 60 KB `diag` red line, as it was before this change).

Not verified:
- Wake with the AirPlay mirror running: the test cannot play through the phone's speaker while mirroring (the raw mic peaked at 208), so this needs a person speaking.
- Noise or speech from another direction (the near-field test cannot show BSS's gain), far field, and a long soak.
