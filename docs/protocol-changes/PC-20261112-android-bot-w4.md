<!-- SPDX-License-Identifier: MIT -->

# PC-20261112-android-bot-w4 — Android Bot port, wave 4 round 1: contracts first

## 0. Summary (machine-readable)

```yaml
change: PC-20261112-android-bot-w4
contracts: [P25, P26, P27, P09]
status: round-1 frozen (CCRs open)
breaking: false
version_decision: Additive. New normative docs and phone-owned golden vectors for behaviour that today exists only in Swift; the Swift end must pass the same vectors. No existing wire field, event type meaning, or stored byte changes in this round, except recording the two memory.document_* durable types that Swift already writes.
base: 0a748a8f
tracks: GAP-38
```

## 1. Why

The roadmap's wave 4 ports the Bot to Android (`docs/parity/android-parity-roadmap.md`). The port plan
(`docs/design/android-bot-port-plan.md`, B0–B8) and the spec-delta list
(`docs/design/android-bot-spec-deltas.md`, D0–D15) found that no subsystem is spec-ready. Two hosts
cannot agree on row ids, replay or the chat page's derived state while those rules live only in Swift.
AGENTS.md §3.1 therefore freezes the contracts before Kotlin implements them.

## 2. Round-1 scope and ownership

| Lane | Checkpoint / delta | Owner (delegate of the contract owner) | Owns |
| --- | --- | --- | --- |
| C2 | B1 / D1–D2 — P25 store, envelope type list, user-action transaction | spec delegate | `spec/bot/v1/store.md` (new), P25 envelope type-list repair, new `*.phone.json` store/transaction vectors, Swift tests that read them |
| C3 | B7a / D11 — P27 session lifecycle and row projection | spec delegate | `spec/bot/v1/session-lifecycle.md`, `spec/bot/v1/projection.md` (new), vectors, Swift tests that read them |
| C4 | B7b / D15 — P09 Bot UI-state seam and page reconciliation | spec delegate | `spec/ui/v1/bot/**` (new), `spec/ui/v1/pages/bot-*.md`, README §1 Bot rows |
| C5 | B8 / D14 — BotFish numeric trajectory and assets | spec delegate | `spec/ui/v1/bot/fish/**` (new) |
| A1 | B7a consumers of already-frozen goldens | Android implementer | new `android/bot` Gradle module (`:bot`) |

Rules for every lane:
- Each new rule has shared valid **and** invalid vectors. The Swift end runs them through its real code (`Tests/PhoneDSHBotTests` only; no `Sources/**` behaviour change). If Swift disagrees with the written rule, the delegate reports it as a CONTRACT CHANGE REQUEST. It must not pick a side silently.
- Upstream-pinned `spec/bot/v1` files keep their pin (`dshbot-pin.json`). Phone-only additions go to `*.phone.json` overlays, as `spec/bot/v1/README.md` §8.1 requires.
- `spec/README.md`, `spec/registry.json` and this record are edited only by the contract owner.

## 3. Out of scope for round 1

- The B5 MCP listener: cards, `SendToUser`, memory, volatile context and Task.
- B2–B4 (memory, routines, wake, proactive, watchdog, ledger) and B6 (team).
- The Android Bot UI, the Bot tab, and the fish renderer. These start in round 2, against the frozen C4/C5 contracts.
- `bot-dock.md` is superseded and is not implemented.

## 4. Compatibility

No runtime behaviour changes in this round. The Swift end gains tests only. The `memory.document_*` type-list repair records types that Swift already writes and reads. Old readers that validate against the schema reject them today, so the repair has no effect on old→new data.

## 5. Acceptance

```
bash scripts/ci/check.sh --only phone-spec,phone-cross-tree,phone-p0-conformance,phone-android-structure
python3 spec/bot/v1/tools/validate_vectors.py   # and v2, if the lane touched it
swift test --filter PhoneDSHBotTests            # the new vector-reading tests
bash android/tools/with-android-toolchain.sh ./gradlew :bot:test --no-daemon
```

## 6. Round-1 result (contract revision = the merge of all five lanes on `feat/android-bot-w4`)

| Lane | Frozen | Swift end | Android end |
| --- | --- | --- | --- |
| C2 | [store.md](../../spec/bot/v1/store.md); `store.phone.json` (17 valid / 11 invalid, 140 steps), `user-action-transaction.phone.json` (5 / 9, 70 steps); envelope enum + 2 valid / 2 invalid `event-envelope.phone.json` cases | `Tests/PhoneDSHBotTests/Store/*VectorTests` drive the real `SQLiteDomainStore` | not started (round 2) |
| C3 | [session-lifecycle.md](../../spec/bot/v1/session-lifecycle.md), [projection.md](../../spec/bot/v1/projection.md) and their `*.phone.json` | `BotSessionLifecycleGoldenTests`, `BotProjectionGoldenTests` | not started (round 2) |
| C4 | [ui-state.md](../../spec/ui/v1/bot/ui-state.md), 14 schemas, `strings.json`, `activity-phrases.json`, six golden files, `check_bot_ui.py`; Bot pages reconciled (header capsule draws no icon/dot) | reference recomputation only; real-code conformance NOT_RUN (app Bot UI is not in a SwiftPM target) | round 2 |
| C5 | [fish.md](../../spec/ui/v1/bot/fish/fish.md), trajectory (97 cases / 954 frames, generated from the app renderer) and asset goldens, `check_fish.py` | generated from real code; XCTest conformance NOT_RUN | round 2 |
| A1 | — | — | `:bot` JVM module: rows/user action, card payloads, display projection, attachments, profile/roster, fish director against the frozen v1 goldens |

`spec/tools/cross_check.py` gained two `GOLDEN_READERS` rows (`spec/ui/v1/bot/golden`, `spec/ui/v1/bot/fish/golden`). They add readers and loosen nothing; the owner accepts them.

### Open contract change requests

Every one is a disagreement between two Swift code paths. The lane withheld the clause and did not pick a side. Each needs a decision and a Swift fix (a `Sources/**` or app change, outside round 1) before Android implements the clause.

| CCR | Clause | Problem | Proposed decision |
| --- | --- | --- | --- |
| W4-C2-1 | `store.md` §9.3/§9.7 | `BotRuntimeEffects.swift:100-116` pre-sorts its own candidates, then calls `store.lease`; a mismatch permanently dead-letters an effect that never ran | the store lease is the only selection order |
| W4-C2-2 | `store.md` §7 item 8 / §8 | `migrateToV3` commits before the contiguity scan; a gapped v2 file becomes an unopenable v3 file | validate inside the migration transaction, before COMMIT |
| UI-1 | `ui-state.md` §4.7 | `BotChatModel.fishState` and `BotRuntimeUnit.statusSnapshot` derive the fish lifecycle differently | one shared projection in the runtime unit; the page consumes it |
| UI-2 | `ui-state.md` §3.1 | a failed `dismiss` cannot be retried; `answer`/`beginApproval` can | make dismiss retryable like the others |
| FISH-1 | `fish.md` §7.4 | lively head-slice quantises at 0.25 but `sliceImage` restores at 0.1 | carry the active quantum through `SliceKey` and add a slice vector |

### Other blockers for round 2

- BotFish artwork: `examples/probe-app/BotFish/SOURCES.md` records a grant for phoneDSH **iOS** only. Android must not package the art until the rights holder extends the grant (and `NOTICE` records it).
- `examples/probe-app/BotFish/atlas.json` carries 51 `file`/`frames` paths that do not exist; the asset golden freezes them as the known exception set.

## 7. Round 2 — contract freeze (owner decisions)

Base: the commit that adds this section. The owner decides all five CCRs as proposed. Each decision becomes normative text plus shared vectors, and the Swift end is fixed in the same round.

| CCR | Decision (normative for every host) | Swift fix |
| --- | --- | --- |
| W4-C2-1 | The store's `lease` is the **only** selection order. A runner executes the effect it was leased and never pre-sorts or filters. An effect with no registered executor is released back to `pending` with the retry delay, never dead-lettered, unless its kind is unknown to the catalogue (then `fail(permanent)` with code `unknown_effect_kind`). | `BotRuntimeEffects.swift` |
| W4-C2-2 | Migration v1/v2→v3 validates `commit_seq` contiguity **inside** the migration transaction, before COMMIT. A gap rolls back, leaves the file at its old `user_version`, and open fails with `corrupted` naming the first gap. | `SQLiteDomainStore.migrateToV3` |
| UI-1 | One fish-lifecycle projection: inputs `{pendingApprovalCount, running = liveRunning ∨ remoteBusy ∨ routineRunning, idleSleeping, livePresentation?, durablePresentation?, liveTurn?, now}`. Priority: pending approval → `alerting`; then an unexpired one-shot; then live over durable presentation; then `running` coerces `idle` to `working`; then `idleSleeping` → `sleeping`; else `idle`. The runtime unit computes it; the page and the roster consume the same value. | `BotRuntimeUnit`, `BotChatModel` |
| UI-2 | A failed `dismiss` is retryable like `answer` and `approval` (`state == nil || state == .failed`). | `BotChatModel.dismiss` |
| FISH-1 | Head-slice displacement uses the quantum of the active profile end to end (`standard` 0.1, `lively` 0.25); `SliceKey` carries it. A slice vector freezes both profiles. | `BotFishRenderer.swift` |

Packaging: `:bot` is now the ninth published `com.phonedsh` artifact, and `:lib` has an `api` edge to it. The Bot pages and `BotFishView` take `:bot` value types, so there is no second copy of a Bot type in `:lib`. The `phone-android-release` gate now also requires the `bot` jar, with compile scope.

Test dependency: `org.xerial:sqlite-jdbc` is approved as **testImplementation of `:bot` only**. The P25 store vectors carry raw DDL, `PRAGMA user_version` and migration steps. Only a real SQLite engine can run those on the host JVM. The Android runtime driver uses `android.database.sqlite` and lives in `:app`. The same vectors run there as instrumented tests.

Artwork: the BotFish grant now covers every phoneDSH platform (`examples/probe-app/BotFish/SOURCES.md`, `NOTICE`).

### Round-2 lanes

| Lane | Owns | Contract |
| --- | --- | --- |
| S1 | Swift W4-C2-1/2 fixes; `spec/bot/v1/store.md` §7–§9; new `store.phone.json` cases; `export-manifest.json`; `Tests/PhoneDSHBotTests/Store` | P25 |
| S2 | Swift UI-1/UI-2/FISH-1 fixes in `examples/probe-app/PhoneDSHProbe/Bot/**`; `spec/ui/v1/bot/**` text and vectors | P09 |
| K1 | `android/bot/.../store/**`, `android/app/.../bot/store/**` (Android driver), `:bot` build file, version catalog | P25 |
| K2 | `android/bot/.../session/**`, `android/bot/.../projection/**` | P27 |
| K3 | `android/lib/.../ui/bot/state/**`: the UI-state seam values and derivations | P09 |
| K4 | `android/lib/.../ui/bot/fish/**`, the BotFish asset copy task in `lib/build.gradle.kts` | P09 |
| K5 (after K3) | Bot pages, drawer, info and the Bot tab in `android/lib/.../ui/bot/page/**` and `nav/**` | P09 |
