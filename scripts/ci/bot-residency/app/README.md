<!-- SPDX-License-Identifier: MIT -->

# WP1 Bot WebContent residency spike

This directory holds the independent XcodeGen application configuration. The
Swift sources remain under the WP1-owned `examples/probe-app` directories. It
does not replace or modify the normal `PhoneDSHProbe` entry point. Every new
Swift declaration is inside `#if BOT_RESIDENCY_SPIKE`, so the existing app and
`ProbeKit` targets see empty files and need no new package product. The
independent scheme defines that condition and links the existing
`PhoneDSHHarness` product for its public, scripted `MockModelUpstream`.

The run uses this real path:

```text
host event with stable requestID
  → DSHRemoteHarness
  → WKWebView Worker / DSH session
  → loopback scripted Messages model (two model calls: tool, then final text)
  → one successful bash tool result
  → BOT_RESIDENCY_DELIVERED assistant message
  → completed turn
```

No real model or external account is used. This is a test of where the DSH LLM
loop executes and whether it recovers, not a claim about model quality or an
external provider.

The app keeps the real `PhoneDSHHost` running instead of parking it. It starts
the PR #36 `SilentAudioKeepAlive` / `PhoneAudioSessionLease` path before asking
the operator to lock the device. `PhoneDSHHost` still owns its foreground gate;
the spike never calls `start`, `resume`, `plannedRestart`, or a recovery HTTP
endpoint to bypass it.

## Files

- `project.yml`: independent app and existing ProbeKit targets.
- `../../../../examples/probe-app/PhoneDSHProbe/BotResidencySpike/Sources/`:
  SwiftUI shell and the real host/session runner.
- `Config/`: audio background mode, loopback ATS, no extra entitlement.
- `../../../../examples/probe-app/ProbeKit/BotResidencySpike/`: seeded schedule,
  evidence records, append/fsync JSONL logging, atomic state/report writing,
  and WebContent PID reader.
- `Generated/`: ignored staged Worker folder reference; the generated
  `BotResidencySpike.xcodeproj/` is also ignored.

The app writes only below `Documents/BotResidencySpike/<run-id>/` in its own
container. Each run gets a new workspace; previous runs are not cleared or
reused as evidence.

## WebContent kill evidence

The app reads `_webContentProcessIdentifier` from its own `WKWebView` when that
debug-WebKit accessor exists. The host script additionally requires
`devicectl device info processes` to identify that exact PID as WebContent
before sending signal 9. A missing accessor, an unverified process record, a
failed signal, or a missing WebKit termination callback is not a successful
kill. A planned restart is never substituted.

A background termination can expose the intended P6 blocker:
`PhoneDSHHost.recoverAfterTermination` sets `pendingRecovery` instead of
booting WebContent while `isForeground == false`. In that state there is no new
PID for a second or third random kill. The run records that outcome rather than
unlocking early to manufacture three kills.

## App-side delivery definition

An injected event is delivered only when all of these are observed for its
stable request ID:

1. exactly one durable user-message sequence number;
2. exactly one successful scripted tool result;
3. exactly one final `BOT_RESIDENCY_DELIVERED` assistant message;
4. a completed turn.

Reconnect cursors deduplicate only by durable sequence; gaps are not treated as
loss. Failed or interrupted attempts are logged, and retry uses the same
request ID. Delivery latency starts at the later of host injection and the last
completed replacement-Worker HELLO. Every event must measure at most 30 seconds.

`app-report.json` says `COMPLETE` or `ABORTED`, never PASS. The host-side
analyzer adds devicectl SIGKILL, process identity, lock-state, recovery, and
protocol-error evidence before issuing the final verdict.
