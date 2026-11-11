<!-- SPDX-License-Identifier: MIT -->

# 联调打磨：审批回执、转交链、验证器取证、文件卡标题与人格边界（P09/P26/P27）

```yaml
change: PC-20261112-int-polish-receipt-chain-verifier
contracts: [P09, P12, P16, P26, P27]
status: implemented
breaking: false
version_decision: Additive: optional RequestApproval result fields and clarification of already-frozen P26/P09 semantics. No event type, envelope, tool name, schema version, error code or persisted shape changes.
base: 3e62bea5
contract_revision: spec/bot/v1/README.md@int-polish-v1 + spec/ui/v1/pages/bot-chat.md@int-polish-v1
```

Protocol impact: P09, P26, P27; P12: none — only a Swift provider helper adds `phone` to the HELLO
advertising set, no FFI/header/native ABI change; P16: none — the App reuses the existing
`accelerator:phone` HELLO capability, no URL/env/init field. P03: none — the lifecycle-gate edit only
adds the already-read-only `od` to the verifier bash allowlist; no exec/journal/frame behaviour
changed. P25: none — `RequestApproval` result fields are tool output, not a BotEventLog event shape.

## 1. 识别与角色

- **Trigger → 现况 → 期望。** Real-model integration found four mismatches: a session grant
  rendered as "已允许一次"; a teammate's reply polluted the hand-off chain so the next send was
  rejected as a cycle; the verifier was told `phone record` works while the unlinked host did not
  advertise `phone`; and a document card rendered "文档 · Document". The persona also let internal
  ids/tool names/English status values leak into user-facing prose.
- **Owner / implementer / reviewer.** This unit `int-polish`; contract edits and both ends are in the
  same frozen revision.
- **Owning contract / schema / fixtures.** P26 [`spec/bot/v1/README.md`](../../spec/bot/v1/README.md)
  §2.7/§2.8 and `golden/row-protocol.phone.json`; P09
  [`spec/ui/v1/pages/bot-chat.md`](../../spec/ui/v1/pages/bot-chat.md); P27 row projection.
- **Producer/consumer.** Swift `BotApprovalCoordinator`/`BotMCPRuntime` produce the tool result;
  `BotSessionLogProjection` + `BotWorkCardView` consume it. `BotTeamTools` produces the held request;
  the App composition consumes its explicit hand-off context. The App host produces the HELLO
  accelerator list; the Worker restricted session consumes it.

## 2. 契约 delta

| 项目 | Before → After／依据条款 |
| --- | --- |
| `RequestApproval` tool result | Add optional `approvalDecision` (`allowOnce|always|deny`) and `scope` (`once|session|until`) next to the existing `allowed`/`decision`. Missing values fall back to the old one-time/denied rendering, so old readers keep working. |
| Approval card receipt | One mapping shared by row projection and SwiftUI: `allowed`→已允许一次, `allowed-session`→本次对话都允许, `always`→已总是允许; denied/timeout/expired/cancelled have their own labels. A session grant never renders as one-time. |
| Hand-off chain | The chain describes one in-progress hand-off. `now` releases it when the target turn ends; `queued` releases it when the target consumes the held item. A teammate's reply held item is the end notification and carries no chain, so the original sender is not marked as visited. A real A→B→A cycle in the same live chain is still rejected. |
| Cycle error text | Bot names only; internal `agent-…` ids never enter the user/model-facing error. |
| Verifier record access | The frozen verifier surface is still exactly `read/grep/glob/bash`; `phone record search|read` remains the evidence bridge. A host that has the Swift record bridge but not the linked Rust shell must still advertise `accelerator:phone`; the prompt and the actual capability list agree. `od` is added to the read-only bash allowlist for artifact inspection. |
| Document card label | `docTypeLabel` defaults are Chinese (`文档/表格/代码/文件库`; Markdown/PDF keep their format names). The eyebrow is the type label only, not `文档 · <label>`. |
| Persona leak rule | One sentence in both persona languages and the profile block: user-facing prose must not contain internal ids, tool names or English status enums. |

自检：no second envelope or alias; new fields are optional; no existing enum value is removed or
reused; no persisted shape changes.

## 3. 兼容性

| Producer → Consumer | 支援／拒絕方式及理由；對應測試 |
| --- | --- |
| old → new | Old tool results without `approvalDecision`/`scope` still project as one-time allowed or denied. Old held requests without `handOff` behave as before. |
| new → old | Old readers ignore the new optional tool-result fields; the old projection fallback remains. A new App with an old Worker still gets the existing `phone record` contract; the HELLO only advertises commands the host can answer. |
| new → new | Swift row projection and SwiftUI share `BotApprovalReceipt`; the tool and host share the explicit `handOff` context; the verifier prompt is tested against the frozen tool/bash vectors. |
| persisted old data → new／rollback | No persisted format change. Approval events and grants keep their shape; chain state is memory-only and rebuilt from live turns. |

## 4. 验证

- Commands are listed in the unit report `int-polish-20261112.md`. Key gates: `swift build`,
  `PhoneDSHBotTests|PhoneDSHTests` (one known baseline scene-phase failure), plugin typecheck and
  bot/verifier/lifecycle tests, prompt check, bot vectors/goldens, UI check, spec/cross-tree/eval
  catalog, eval selftest 18/18, product mock 14/14, bundle freshness/license, App build and Bot UI
  capture 48/48.
- Shared fixtures: `spec/bot/v1/golden/row-protocol.phone.json` (`approvalReceipts`),
  `spec/bot/v1/golden/verification.phone.json` (read-only `od` and `phone record` vectors).
- Remaining risk: the `phone record` path was not exercised on a physical iPhone in this unit; the
  App build and shell-provider tests prove the advertisement/dispatch seam, and the eval host already
  covers the record bridge end to end.
