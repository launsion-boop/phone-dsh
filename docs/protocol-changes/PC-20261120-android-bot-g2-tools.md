# PC-20261120 Android Bot: shared golden drift (device-app/xiaozhi effects, G-2 tools)

```yaml
change: PC-20261120-android-bot-g2-tools
contracts: [P05, P26, P27]
status: implemented
breaking: false
base: 25906ccd3fff4179d56b03d6369a18933bc56a0d
contract_revision: spec/bot/v2/README.md at the commit that introduces this record
```

Protocol impact: P05; P26; P27 (the decision tool is answered after attribution and before the grant check, per decision-context.md §1.7).

## 1. Identification and roles

- **Trigger → now → expected:** the shared Bot goldens were updated for iOS on 2026-11-17/18
  (`c2bf96de1`, `30db16c5f`, `611118905`, `fd1424777`) without the Android end, so
  `android :bot:test` failed on clean `main`:
  - `tool-effects.phone.json` gained eight rows (`DeviceAppStage`, `DeviceAppInstall`,
    `DeviceAppList`, `DeviceAppRemove`, `XiaozhiSourceExport`, `XiaozhiFirmwareBuild`,
    `XiaozhiFirmwareStatus`, `XiaozhiFirmwareFlash`); Android classified all eight as unknown/ask.
  - `mcp-rpc-cases.phone.json` `tools/list` added `RecordFeedback` and `BotDecisionContext` and moved
    the team tools after `SendToUser`; Android listed neither and kept the team tools last.

  Expected: the Android classifier and catalog agree with the goldens, without changing them.
- **Coordinator, contract owner, implementer, reviewer:** Claude (this session), one task.
- **Owning spec:** goldens unchanged. [spec/bot/v2/README.md](../../spec/bot/v2/README.md) header
  (Android end of G-2), [decision-context.md](../../spec/bot/v2/decision-context.md) §1.7,
  [record-feedback-tool.json](../../spec/bot/v2/record-feedback-tool.json),
  [decision-internal-tool.schema.json](../../spec/bot/v2/decision-internal-tool.schema.json).
- **Ends:** Android `android/bot` classifier (`authz/BotToolEffects.kt`), catalog
  (`mcp/BotToolCatalog.kt`), runtime and ports (`mcp/BotMCPToolRuntime.kt`, `mcp/BotMCPPorts.kt`).
  iOS is the reference end and is not changed.

## 2. Contract delta

| Item | Before → After |
| --- | --- |
| Effect table (P26) | Android adds the eight device-app/xiaozhi classifier forms and `RecordFeedback` (`write`/`ask`, `execution: feedback`), copied from `DeviceAppToolEffects`, `XiaozhiFirmwareToolEffects` and `BotToolEffects.swift`. No golden change. |
| `tools/list` (P05) | Static list: P0, `SendToAgent`, `CreateTeammate`, `FishAction`, `BotVolatileContext`, `attach_to_model`, `RecordFeedback`, `BotDecisionContext` (= Swift `workerDefinitions`). Identified caller: the same without `BotDecisionContext` (= Swift `allDefinitions(roster:callerBotID:)`; golden per-caller count 23). |
| `RecordFeedback` call | Validation and failure sentences of `BotFeedbackTools.swift`: no store → `unavailable`; non-`chat` principal → `permission_denied`; bad arguments → `invalid_arguments`; store error → `execution_failed`. A valid call is passed to the injected `BotFeedbackPort`. |
| `BotDecisionContext` call | Answered right after attribution, before the per-caller and grant checks (as in Swift). Same checks and frozen result envelope `bot-decision-context-result/v1`; no service → `material-unavailable`; another session → `permission-denied`; an unknown service code → `material-unavailable`. |
| Clause status | G-2 on Android: host boundary only. The feedback store (`BotFeedbackCenter`), the material service and pre-delivery review are **not** ported; no Android composition installs them yet. Device-app/xiaozhi hosts stay `target` on Android (GAP-20); only the classification exists. |

Self-check: no second envelope, no alias field, no new error code; goldens and schemas untouched.

## 3. Compatibility

| Producer → Consumer | Behaviour |
| --- | --- |
| Android Worker → Android host | The Worker sees two more tools in the static list. A model call to `RecordFeedback` fails closed with `unavailable`; the internal tool fails with `material-unavailable`. Nothing is written. |
| old → new / new → old | No wire field, persisted data or schema changes; rollback restores the previous list and unknown-tool classification. |

## 4. Verification

- `cd android && ./gradlew :bot:test` → PASS (the shared `tool-effects` and `mcp-rpc-cases` goldens
  through the real classifier/handler, plus `BotG2ToolsTest`, which compares both definitions to
  the frozen spec files and drives the fail-closed paths).
- Not verified: an Android device or Worker E2E; a real feedback store or material service on Android.
