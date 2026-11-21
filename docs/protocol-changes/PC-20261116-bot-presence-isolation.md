# PC-20261116 Bot presence isolation

```yaml
change: PC-20261116-bot-presence-isolation
contracts: [P25, P26, P27]
status: implemented
breaking: false
version_decision: rebuild Swift modules together; no persisted or wire version change
base: 01585fc39
contract_revision: spec/bot/v2/README.md@presence-isolation-20261116
```

The app writes foreground and keep-alive flags while Bot information reads them.
The current process-local singleton is main-actor isolated, violating the runtime
module's actor-neutral boundary. Preserve defaults, values, updates, coherent paired
snapshot and all public member names; replace actor confinement with a synchronized,
Sendable implementation so reads and writes can originate from any actor. Separate
flag getters remain independent reads, while `context()` returns one atomic pair.
No events, serialized values, lifecycle rules or timestamps change. Swift source
isolation is relaxed and all modules are rebuilt; old/new runtime endpoints and
persisted data remain interoperable. No binary ABI stability is asserted.

Coordinator owns this contract. Implementer owns `Sources/PhoneDSHBot/Routines/RoutinePresence.swift`,
the related Swift unit tests and `examples/probe-app/PhoneDSHProbe/Bot/BotProductionServices.swift`;
no other files. Existing routine and Bot tests plus tests for paired concurrent reads,
partial updates and defaults exercise the real API. Shared persisted/wire fixtures do
not apply because no external representation changes. Acceptance: `swift test --filter
RoutinePresence` and `bash scripts/ci/check.sh --only phone-modules`; the latter may
still fail on the separate recovery scheduler/rebind violations. Device NOT_RUN.

## Implementation evidence

`swift test --filter BotPresenceCenterTests` → PASS, 6 tests. The actor-neutral
store was integrated in the app, which compiled for iOS Simulator. Device NOT_RUN.
