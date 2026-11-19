# PC-20261119 Xiaozhi build and flash progress (DEBUG)

```yaml
change: PC-20261119-xiaozhi-progress
contracts: [P07, P09]
status: implemented
breaking: false
base: dd40c5ebcd9b40280e29cbf7a923b62ac0d35a3c
contract_revision: spec/device/v1/xiaozhi-firmware.md r3 at the commit that introduces this record
```

Protocol impact: P07; P09; P26: none — no tool name, input, result shape or effect changes;
P18: none — nothing is persisted (progress is derived from in-memory state).

## 1. Identification and roles

- **Trigger → now → expected:** the xiaozhi Bot can build and flash, but the UI shows no progress:
  the Build tool blocks up to 100 s behind a generic activity bubble, the page shows only
  `state: running`, and after Flash nothing tells the user whether the board restarted, is
  downloading, or took the image. Expected: live build counters and a flash timeline
  (放出 → 下载 → 安装 → 完成) in the xiaozhi Bot's chat and on the 小智固件 page.
- **Coordinator, contract owner, implementer, reviewer:** Claude (this session), one task.
- **Owning spec:** [xiaozhi-firmware.md](../../spec/device/v1/xiaozhi-firmware.md) §2.5, §9;
  [bot-chat.md](../../spec/ui/v1/pages/bot-chat.md) (strip clause). No shared fixture changes.
- **Ends:** relay listener (SDK `Sources/PhoneDSHBLE/Xiaozhi`) → app progress model and views
  (probe app). The board, the upstream and the Bot tools are untouched. Android: none (GAP-20).

## 2. Contract delta

| Item | Before → After |
| --- | --- |
| firmware download bytes | one `send` → head + 32 KiB chunks; identical bytes (test `testFirmwareHeadPlusBodyIsTheEncodedResponse`) |
| in-process relay state | + `XiaozhiDownloads` (per MAC, newest wins, monotonic, terminal states final); UI only |
| Bot tool surface | unchanged; the download count is not returned by `XiaozhiFirmwareStatus` |
| UI | + §9 progress on the 小智固件 page and a `bot.xiaozhi.progress` strip in a `xiaozhi:` Bot's chat |

Self-check: no second representation, no new wire field, no new error code, nothing persisted.

## 3. Compatibility

| Producer → Consumer | |
| --- | --- |
| board (any) → relay | same HTTP bytes; nothing to negotiate |
| old app ↔ new app | in-memory only; nothing persisted or exchanged |
| Bot tools / Worker | unchanged |

## 4. Not changed, on purpose

- `spec/ui/v1/bot/activity-phrases.json` (shared with Android) still has no rows for the four xiaozhi
  tools, so the activity bubble says the generic 「处理中」 while they run. Adding them is a P09 table
  change with an Android end; left for a separate change.
