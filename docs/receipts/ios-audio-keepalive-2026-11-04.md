# iOS audio keepalive lifecycle regression

The native root did not forward scene changes to `ChatModel.scenePhaseChanged`.
The existing silent-audio implementation therefore never started when a running
conversation moved to the background. Forwarding from the persistent `RootView`
restores the existing policy across native subpages.

Base: public main `bd1dea5ee5cc0576eb75fb45d8eb97107c92e275`.
Protocol impact: P09: none, app-local lifecycle wiring only. No projection schema,
SDK state machine, Worker asset, audio configuration, or persisted format changed.

## Physical-device method

Runs were performed on 2026-11-04 using an iPhone 18 Pro Max on iOS 27.0.1,
connected by USB and charging. The app was launched through `devicectl` without
an attached debugger. The test did not use a Bluetooth accessory.

A scripted model endpoint sent a numbered SSE delta every five seconds through
the real app gateway, WebKit Worker, harness event pump, and native conversation.
The shell provider was unlinked. Source snapshots were compared byte-for-byte
with the checked-out Swift sources before the device run.

## Before the fix

On unmodified main, at least 214.8 seconds of confirmed screen lock produced no
audio activation or background heartbeat. Seven status-log samples were identical.
After unlock, the same process and session remained at `LOCK_TICK_011`.
The turn failed after 301.4 seconds without a session event, against a 300-second
inactivity deadline.

## After the fix

| Scenario | Observed result |
| --- | --- |
| Lock during a four-minute streamed turn | PASS. Twenty advancing background heartbeats, ending at 207 seconds. Event count advanced from 14 to 53. |
| Complete while still locked | PASS. The device still required its passcode when the turn completed. Audio was released and the idle host parked. |
| Unlock and return | PASS. The host resumed and the UI showed all deltas 000 through 048, the completion marker, and a completed turn. |
| Home screen during a two-minute streamed turn | PASS. The first audio interval lasted 39 seconds with advancing Worker events. |
| Return to the foreground mid-turn | PASS. Audio was released immediately; the same turn continued. |
| Background the same turn again | PASS. Audio restarted, events advanced, the turn completed, audio was released, and the idle host parked. |

Decisive locked-run log excerpt, timestamps in UTC:

```text
15:00:02 keep-alive audio session active (playback, mixWithOthers)
15:00:12 bg-heartbeat t=10s events+=2 total=14 turnRunning=true host=running audio=true remaining=unlimited
15:03:30 bg-heartbeat t=207s events+=2 total=53 turnRunning=true host=running audio=true remaining=unlimited
15:03:35 Turn ended: completed
15:03:35 keep-alive audio session released
15:03:35 Turn finished in the background; keep-alive audio stopped, parking the idle host
15:03:35 Host parked; resume by returning to the app
```

`audio=true` is the helper's activation flag, not an independent audio-render
measurement. The advancing Worker events and completed locked turn are the
end-to-end evidence; the flag alone was not used as acceptance.

## Checks and limits

The physical-device build, focused independent review, platform checker,
`git diff --check`, and `phone-no-dsh-patch` passed.

`phone-p0-conformance`, `phone-hygiene`, and `phone-license` failed identically
when rerun on untouched main. Existing failures were a stale ChatPage color
provenance reference, hostname allowlisting, and missing Android test SPDX headers.
These checks are not reported as passing.

This establishes the two scripted-stream scenarios on this device. Real model
and shell-tool workloads, calls and audio interruptions, media-service resets,
other devices or OS releases, prolonged runs, and battery consumption remain
unverified. This receipt does not establish App Store acceptance or general
background-execution guarantees.
