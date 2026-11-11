<!-- SPDX-License-Identifier: MIT -->

# Bot v2 主导权移交（P26 memory／wake／proactive）

```yaml
change: PC-20261111-bot-v2-handover
contracts: [P26]
status: implemented
breaking: false
version_decision: Ownership transfer only. The three contract parts move from `spec/bot/v1` (dsh-bot pin bf4075b0a2e8092b04b726c59a7b085d5a37e6f6) to the phoneDSH-owned `spec/bot/v2` with byte-identical schema and golden files. There is no wire version, field, enum, default, error code, persistent format or producer/consumer change; old readers, old data and rollback keep working.
base: 871488cfe
contract_revision: spec/bot/v2/README.md@v2-handover-20261111 + spec/README.md@P26-v2
```

Protocol impact: P26; P25: none — `event-envelope.schema.json`、事件日志和 effects 未改，`dshbot-pin.json` 只删除已移交批次的 `requiredMergeCommits`，`source`/`repository` 未改；P27: none — `held-inbox.phone.json` 移到 v2，行、行批、用户动作、投影 schema/golden 未改。

## 1. 识别与角色

- **Trigger → 现况 → 期望.** 记忆、唤醒标记和主动提醒三部分此前作为 P26 的一部分从 dsh-bot
  `bf4075b0a2e8092b04b726c59a7b085d5a37e6f6` 原样导出，但用户已决定这三部分改由 phoneDSH
  作准（方案 §6 决定 1，2026-11-10）。期望：建立 `spec/bot/v2` 收拢这三部分的 schema 与
  golden，`spec/README.md` 的 P26 登记表和触发表同时指向 v1（其余 Bot 契约）与 v2（这三部分）；
  上游导出器不再写这些文件；Swift/TS 测试从 v2 路径读取。
- **Coordinator / contract owner / implementer / reviewer-integrator.** 本单元 `s1-v2`
  （分支 `s1/bot-spec-v2`）兼任 contract owner 与 implementer，按 AGENTS.md §3.1 先冻结
  v2 契约，再在本分支完成路径接线。没有生产行为改动。
- **Owning contract / schema / fixtures.** P26 的 v2 部分：
  `spec/bot/v2/README.md`；`spec/bot/v2/{memory-fact,memory-injection,memory-recall,memory-policy,wake-routine,held-inbox-item,routine}.schema.json`；
  `spec/bot/v2/golden/{memory-fact,memory-injection,memory-recall,memory-policy,wake-routine,held-inbox,held-inbox.phone}.json`；
  v2 校验入口 `spec/bot/v2/tools/validate_vectors.py`。v1 仍拥有事件信封、工具面、卡片、行、
  回合来源（`spec/bot/v1/README.md` §4.1）和 MCP 端点。
- **受影响的 producer / consumer.** Swift `Sources/PhoneDSHBot/**` 的 codec/状态机继续读同一批
  schema/golden；测试加载器 `Tests/PhoneDSHBotTests/GoldenFixtureSupport.swift`、WP6/Memory
  测试支持改为 v2 路径；TS `plugins/tests/bot-golden.ts` 的合并加载器按文件选择 v1/v2。
  `spec/tools/bot/export-vectors.mjs` 删除这三部分的导出与 `memoryCore`/`routineDelivery`
  合并要求。Android 与 HarmonyOS 没有 Bot runtime，不受影响。

## 2. 契约 delta

| 项目 | Before → After／依据条款 |
| --- | --- |
| 权威 | dsh-bot 钉版（P26 全域）→ 三部分改由 `spec/bot/v2` 作准；其余 P26 仍由 v1/dsh-bot 作准。 |
| schema／golden | 7 个 schema 与 7 个 golden 文件从 `spec/bot/v1` 原样移动到 `spec/bot/v2`；逐字节相同（`cmp` 对 `git show HEAD:` 验证），`$id` 之外的 `title` 等未改。 |
| 线格式／字段／默认值 | 无变化。没有新增、删除或修改字段、enum、错误码、限额或版本号。 |
| `.phone.json` 覆盖 | `held-inbox.phone.json` 一并移到 v2；合并语义（对象按 key、数组按 identity 追加/替换、不能删除上游用例）不变。`card-payload.phone`、`row-protocol.phone`、`tool-catalog.phone`、`tool-effects.phone`、`turn-origin.phone`、`mcp-egress.phone` 仍属 v1。 |
| 导出器／manifest | `export-vectors.mjs` 不再生成这 7 个上游 golden；v1 `export-manifest.json` 从 29 文件缩为 22（16 upstream + 6 overlays）；v2 没有 manifest/pin，因为不再由上游导出。`dshbot-pin.json` 删除 `requiredMergeCommits` 中已移交的 `memoryCore`、`routineDelivery`，`repository`/`source` 不变。 |
| 校验 | `phone-spec` 仍运行 v1 校验器；v1 校验器调用 `spec/bot/v2/tools/validate_vectors.py`，两棵树在同一步校验。`cross_check` 的 fixture 覆盖表显式登记 v2 golden。 |
| 条款状态 | 仍为 `target`。本单只移交权威，不把任何 v2 条款升级为 `implemented`。 |

自检（`spec/README.md` §5.1）：没有新增第二种表达、没有新增字段、没有收窄或放宽合法输入、
没有新增 enum、没有删除或重用名称；移动文件本身不是 wire 变化。

## 3. 兼容性

| Producer → Consumer | 支援／拒絕方式及理由；對應測試 |
| --- | --- |
| old → new | 旧代码读同一 schema/golden 内容；新增的 v2 路径只改变仓库内测试和校验器位置。 |
| new → old | 旧读者不需要知道 v2；文件内容未改。回滚到旧分支后文件仍在 v1 原路径可读。 |
| new → new | Swift/TS 加载器按文件名选择 v2 或 v1，合并逻辑不变。 |
| persisted old data → new／rollback | 没有持久化格式变化；Bot facts、held inbox、routine 记录和通知深链不变。 |

- 版本决定：不升 P26 版本、不新增 schema 版本；这是权威位置变化，不是格式变化。
- bundle／image 顺序：无 Worker/native artifact 变化；TS 只是测试加载器。重建 bundle 不需要。
- `target`／`draft` 差异：v2 仍为 `target`；本次没有新增运行时证据，也没有把条款升级。

## 4. 验收命令与证据

| 检查 | 命令 | 结果 |
| --- | --- | --- |
| 移交文件逐字节 | `cmp` 对 `git show HEAD:spec/bot/v1/...` | PASS：7 schema + 7 golden 全部相同 |
| v2 向量 | `python3 spec/bot/v2/tools/validate_vectors.py` | PASS |
| v1 + v2 向量 | `python3 spec/bot/v1/tools/validate_vectors.py` | PASS |
| golden 清单（离线） | `python3 spec/tools/bot/check_golden.py --root .` | PASS：22 files / 16 upstream / 6 overlays |
| 上游重新导出 | `python3 spec/tools/bot/check_golden.py --root . --checkout /tmp/s1v2-dsh-bot --sha bf4075b0...` | PASS：fresh export byte-identical |
| 协议 CI | `CI_PROTOCOL_BASE=871488cfe bash scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree` | `phone-spec` PASS 13s、`phone-cross-tree` PASS 13s；`phone-p0-conformance` FAIL（16s），7 条 page-structure divergence 在基线 HEAD 上已存在 |
| Swift | `swift test --disable-sandbox --filter PhoneDSHBotTests` | PASS：429 tests / 0 failures，与移交前 429/0 相同 |
| plugins | `cd plugins && node scripts/run-tests.mjs "tests/bot-*.test.ts"` | PASS：82 tests / 79 pass / 1 skip / 2 todo，与移交前相同 |

## 5. 修订纪录

| revision | 由谁 | 原因 | 通知了哪些端 |
| --- | --- | --- | --- |
| v2-handover-20261111 | s1-v2 contract owner | 用户 2026-11-10 决定三部分改由 phoneDSH 作准 | Swift、TS、spec registry |
