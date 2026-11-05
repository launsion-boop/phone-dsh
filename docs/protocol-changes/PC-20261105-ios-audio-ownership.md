# iOS audio ownership closeout

```yaml
change: PC-20261105-ios-audio-ownership
contracts: [P08]
status: implemented
breaking: true
version_decision: app-local source API revision 2; migrate all callers in one bundle, no wire version
base: 515e3395a4b7c80a522bd4f12f76edd0b5c2a058
contract_revision: spec/platform/ios-audio-session.md@2
```

## Trigger and roles

PR31/32 device acceptance found a foreground recorder losing its compatible
session when keep-alive starts under lock, and idle cancellation releasing an
unowned session. The initial ownership candidate also reproduced a redundant
background category setter clearing mix options before failing with 560557684.
The existing public ProbeKit helper was not explicitly named in P08's registry;
this change registers that boundary before the remaining acquisition fix.

Codex is contract owner and final integrator. DSH implements the lease and its
three callers in isolated staging directories and independently reviews changes.
The authority is `spec/platform/ios-audio-session.md`, with the existing lease as
its implementation. Fixtures use its real ownership state, not a copied model.

## Delta

One optional reclaim callback becomes one keep-alive claim plus one exclusive,
identity-checked microphone token. See the authority for ordering, profiles,
rollback and zero-owner deactivation. The remaining fix must avoid repeating
category/activation while the microphone profile remains owned. Phone-tool
arguments, limits, confirmation, error envelope, requested duration, AAC artifact
format, cancellation outcome, Worker, SDK and durability semantics are unchanged.

## Compatibility

| Pair | Decision |
| --- | --- |
| Old caller with new helper | Unsupported source combination; compile all callers atomically. |
| New caller with old helper | Unsupported source combination; compile/link fails. |
| New caller with new helper | Supported within the same signed app bundle. |
| Old persisted data / rollback | Unchanged formats; whole-app rollback is supported. |

No external API version or compatibility adapter is introduced. Rust, TypeScript
and Kotlin do not consume this app-local API and need no change. Android retains
its existing foreground-service policy. P09 projection and P19 envelopes remain
unchanged.

## Ownership and acceptance

The DSH writer owns only the lease and lifecycle tests for the remaining fix.
Codex integrates the already migrated BackgroundKeepAlive, ComposerVoiceInput and
PhoneMediaTools and performs physical-device acceptance. No concurrent writers
share a file. The existing recorder remains; mirror-off testing disproved the
proposed recording replacement.

Run the lifecycle simulator suite and `swift test --filter
ProbeScenePhaseWiringTests`. Contract metadata runs `bash scripts/ci/check.sh
--only phone-spec,phone-p0-conformance,phone-cross-tree`. Device cases are valid
3/5-second recordings, live-recording background/foreground and lock transitions,
release back to keep-alive, retained-profile reacquisition and locked streaming
completion. Record waveform duration and SHA separately from the JSON receipt.

No successful dictation transcript, interruption recovery, media-service reset,
power-loss or model intelligence end-to-end result is inferred from these checks.
The final receipt records actual results and baseline gate failures.

## Revision record

Revision 2 freezes the existing cross-module ownership API and the retained-profile
reacquisition rule. All iOS callers migrate together; other platform ends remain
unchanged for the reasons above.
