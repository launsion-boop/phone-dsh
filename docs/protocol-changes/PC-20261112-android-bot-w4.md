<!-- SPDX-License-Identifier: MIT -->

# PC-20261112-android-bot-w4 — Android Bot port, wave 4 round 1: contracts first

## 0. Summary (machine-readable)

```yaml
change: PC-20261112-android-bot-w4
contracts: [P25, P26, P27, P09]
status: draft
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
