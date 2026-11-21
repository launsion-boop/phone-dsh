# PC-20261116 Bot worker recovery isolation

```yaml
change: PC-20261116-bot-recovery-isolation
contracts: [P09, P25, P26, P27]
status: implemented
breaking: true
version_decision: rebuild Swift SDK and app with actor-isolated scheduler API; no wire or on-disk version change
base: 021ef3eaa
contract_revision: spec/bot/v2/README.md@recovery-isolation-v2
```

The production scheduler serializes termination/HELLO/readiness, retries,
worker replacement, manual rebind, cancellation, timeouts and late completions.
The runtime module may not be main-actor bound. The scheduler becomes a Swift
actor and owns its state on that actor; its existing commands and snapshot reads
are awaited. Recovery is an asynchronous Sendable callback; application/UI work
is explicitly entered on the app's actor, never by main-actor annotation inside
the runtime module. Phase notifications are delivered in scheduler order using
a single non-dropping stream, consumed by the application on its UI actor.
Install the callback and establish the stream before accepting host events.
Stop, manual rebind and new-generation fences must finish before a new bind can
observe them. Preserve the existing unstructured bounded timeout race and retry
budget; a non-cooperative timed-out operation cannot overwrite a newer generation.
No module dependency, wire message, persisted field or Worker behavior changes.

This is a Swift source API change: SDK and app must rebuild together, actor calls
must be awaited, and callback consumers migrate to the ordered stream. Old/new
processes retain existing interchange; old data and rollback are unaffected.
Coordinator owns spec; implementer owns the scheduler, its Swift test files,
`Tests/PhoneDSHKillTests/PhoneDSHReplacementWorkerBootIDTests.swift` and app
`BotRuntimeComposition.swift` recovery call sites. Existing recovery tests and
new tests must exercise ordering, same/new boot, ready fallback, cancellation,
timeout, stale completion, retry bound and stop/rebind races on the real scheduler.
Acceptance: `swift test --filter BotWorkerRecoverySchedulerTests`, affected kill
and lifecycle tests, `bash scripts/ci/check.sh --only phone-modules`, iOS Simulator
and integration gate. Real device and non-cooperative OS shutdown remain NOT_RUN.

## Revision 2: unit-start lifecycle fence

A source review found that `BotRuntimeUnit.start` can resume after `detach` and
restart its timer and live observer despite the outer bind epoch. Before dependent
implementation, the coordinator freezes a unit-local generation: each start gets
a generation; detach and newer starts invalidate earlier work before any await.
After each suspended start step, and before each next effect or publishing started,
the unit must check cancellation and the generation and abort stale work. The host
bind epoch is also checked where supplied, so a newer bind invalidates an old unit
start even before detach enters it. Existing app-only call sites migrate together;
no wire or persisted format changes. The implementer additionally owns
`examples/probe-app/PhoneDSHProbe/Bot/BotRuntimeUnit.swift` and associated hosted
unit-start tests, alongside the existing composition and scheduler tests. The
existing non-cooperative timeout bound remains; process death and device NOT_RUN.

## Implementation evidence

`swift test --filter BotWorkerRecoverySchedulerTests --filter
PhoneDSHReplacementWorkerBootIDTests --filter BotRuntimeLifecycleRebindTests`
→ PASS: 32, 2 and 13 tests respectively. Hosted `BotUnitStartFenceTests` on
iOS Simulator → PASS, 5 tests against the real production unit. `phone-modules`
and the full iOS Simulator gate passed; real device and power loss remain
NOT_RUN. GAP-49 tracks the unverified Worker-ready identity boundary.
