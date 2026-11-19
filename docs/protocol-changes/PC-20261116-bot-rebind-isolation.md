# PC-20261116 Bot rebind isolation

```yaml
change: PC-20261116-bot-rebind-isolation
contracts: [P25, P26, P27]
status: implemented
breaking: true
version_decision: source-level Swift helper change, rebuild app and SDK together; no on-disk or wire version change
base: 5466c3eec
contract_revision: spec/bot/v2/README.md@rebind-isolation-20261116
```

## Trigger → current → expected

The public Swift `BotRebindScope` helper and its callbacks are main-actor isolated
inside an actor-neutral runtime module. Change the driver to actor-neutral and
sequentially invoke `@Sendable` async callbacks for `T: Sendable`. App-specific UI
and host state remain actor-owned: the app explicitly awaits its own actor methods.
Keep candidate order, exactly one state read per candidate, force-restart behavior,
per-unit error recording and immediate cancellation short-circuit. Do not loosen
the module checker or drop existing tests.

## Compatibility and evidence

This is a **Swift source API change**: callers with non-Sendable candidates or
mutable captures must migrate to Sendable identities and explicit actor hops, then
rebuild the SDK and app together. It does not add or modify wire, events, on-disk
data or Worker behavior. Old and new processes exchange the existing contracts;
old data and rollback need no migration. No stable Swift binary ABI is promised.
The coordinator owns the spec; the implementer owns
`Sources/PhoneDSHBot/MCP/BotRebindScope.swift`, its existing and new Swift tests,
and the caller in `examples/probe-app/PhoneDSHProbe/Bot/BotRuntimeComposition.swift`.
Test sequential ordering, live-unit preservation, force restart, per-unit errors,
cancellation and explicit actor-isolated callbacks using the real helper. The
existing Bot lifecycle tests provide production-path fixtures; this pure Swift
helper has no shared wire/persistence fixture to change. Acceptance:
`swift test --filter BotRuntimeLifecycleRebindTests` and
`bash scripts/ci/check.sh --only phone-modules`; scheduler findings may remain.
Device NOT_RUN.

## Implementation evidence

`swift test --filter BotRuntimeLifecycleRebindTests` → PASS, 13 tests. The
coordinated application caller compiled for iOS Simulator. Device NOT_RUN.
