<!-- SPDX-License-Identifier: MIT -->

# Bot 审批按动作类常设授权（P26/P09）

```yaml
change: PC-20261122-bot-approval-action-class
contracts: [P25, P26, P09]
status: implemented
breaking: false
version_decision: Additive. No wire field, JSON-RPC method, frame, route or BotEvent shape changes. `authz.grant_snapshot` keeps exactly 11 fields; only the value domain of `operation` (new `exec:*` class ids) and `canonicalResource` (the existing wildcard `"*"`) is used more widely. An old build reading a new snapshot still validates it and simply never matches a class grant, so its next destructive call asks again; a new build reading an old snapshot keeps every exact grant and behaves as before.
base: f892cb1b076336f707b53eb8fd0262c4c9f7f11c
contract_revision: spec/bot/v1/README.md@PC-20261122-bot-approval-action-class + spec/ui/v1/pages/bot-chat.md@PC-20261122-bot-approval-action-class
```

Protocol impact: P09; P25; P26; P25 —— `authz.grant_snapshot` 的 entry 仍是冻结的 11 个字段，但 `operation` 值域新增 `exec:*` 类 id、`canonicalResource` 更常使用既有 `"*"`；`approval.requested` 只多一个可选 `effects[].actionClass`（`tool-effects.schema.json` 的 effect 允许附加成员），没有新事件类型；P27: none — 没有 row/user-action/projection 字段变化，审批卡仍是既有 approval 行。

## 1. 识别与角色

- **Trigger → 现况 → 期望。**
  - 现况：`bash` 只有三类破坏性模式会出审批卡（`rm -d`/`find -delete`、`git reset --hard`）。用户点「始终允许」时，Grant 存的是**具体实例**（`rm` 的目标路径，或整条命令文本），所以下一次删除另一个目标仍然出卡；`BotApprovalOffer` 也会因为效果没有稳定 scope 而根本不提供「始终允许」（`offeredScope = none`）。用户实测「每条 bash 都弹一次、点了总是允许下次还问」。
  - 期望：同一**动作类**确认一次「始终允许」后，同类操作长期默认放行；不同类互不越权；不可归类命令永远只给一次性许可；具体 deny 永远优先；同轮已排队的同类卡片在决定后静默接续；卡片必须写明「总是允许」覆盖哪一类。
  - 与提案的两处偏差（有意，记录在案）：
    1. 工作区内的 `write`/`edit` 仍不出结构审批卡。§2.4 已冻结「根内写是 DSH 文件沙箱的边界」，加上首卡只会增加打扰；本次不把 L1 变成新卡。
    2. 只读 `bash` 仍不出卡（既有 `effects=[]` → 宿主 auto-policy），本次不为它新增「首次静默提示」toast。
- **责任。** 本轮由单一 agent 兼任 contract owner、implementer 与 integrator；真机验证未执行，见 §4。
- **Owning spec / fixtures.** [spec/bot/v1/README.md](../../../spec/bot/v1/README.md) §2.3（Grant 恢复与匹配）、[spec/ui/v1/pages/bot-chat.md](../../../spec/ui/v1/pages/bot-chat.md) §2 审批卡按钮、[spec/bot/v1/golden/approval-patterns.phone.json](../../../spec/bot/v1/golden/approval-patterns.phone.json)（不新增 kind，`matches` 形状不变）。
- **受影响的 producer / consumer.**
  - Swift 宿主：`Sources/PhoneDSHBot/Authz/{BotActionClass,BotToolEffects,BotApprovalPatterns,BotGrants,BotExecutionAuthorizer}.swift`、`Sources/PhoneDSHBot/MCP/BotApprovalCoordinator.swift`。
  - iOS App：`BotWorkCardView`（类范围说明）、`BotUIFormat`（`exec:*` 标题与 `*` 资源摘要）、`DSHApprovalMemory`（工作台「总是允许」改用同一动作类键）。
  - Worker/TS：`plugins/bot-runtime/src/approval-gate.ts` 未改。宿主在 `/approval` 自己重算 effects；Worker 传来的 `effects` 只用于展示与 `grantSets`，不是授权依据，所以类信息不需要跨进程传播。
  - Android/HarmonyOS：没有 Bot runtime，`not started`。

## 2. 契约 delta

| 项目 | Before → After／依据条款 |
| --- | --- |
| 效果新增可选 `actionClass` | 无 → `rm-destructive`/`find-delete` 为 `exec:delete`，`git-destructive` 为 `exec:git-reset`；其余效果无此字段。它是宿主派生值，不来自模型参数；`exec:unknown` 不可常设。 |
| 常设 Grant 的键 | `(tool, operation, resource=<具体实例>)` → 破坏性 `bash` 的常设决定存 `(tool="bash", operation=<class>, resource="*")`；一次性决定仍存精确实例。 |
| 匹配顺序 | 具体 deny → 具体 allow → 类别 allow → 无匹配按分级。具体 deny 的 specificity 高于类别 allow；`resource="*"` 的类别 Grant 不匹配任何没有 `actionClass` 的效果。 |
| Grant 快照 | 形状不变（11 字段）。`operation` 值域增加 `exec:delete`/`exec:git-reset`；`canonicalResource` 使用既有的 `"*"`。旧数据照常恢复；旧构建读到新 Grant 只视为不匹配。 |
| 同类队列接续 | 无 → 交互式（非持久）同类卡片在「始终允许」后按 `allowOnce` 自动结束；持久待办（task/routine）仍走 §2.7 的恢复点，不在此路径。 |
| UI 文案 | 「始终允许」按钮下增加类范围说明（`bot.approval.class-scope`）：`exec:delete` →「删除文件或目录」、`exec:git-reset` →「丢弃 Git 未提交改动」。`alwaysScope=none` 的卡片仍只有「允许」「拒绝」。 |
| 工作台 DSH「总是允许」 | 会话+`bash:read-only` → 会话+动作类键：`bash:read`、`bash:delete`、`bash:git-reset`；无法归类的命令不再提供常设键。24 小时 TTL 与会话范围不变（本轮不改工作台的过期模型）。 |

自检：没有引入第二种表达（`actionClass` 只在效果上派生，Grant 仍用既有快照字段）；新字段可选、缺省为 nil；没有收窄任何两读消息；`exec:*` 是新的值域而非新 enum 枚举文件，未知值路径不变。

## 3. 兼容性与发布

| Producer → Consumer | 支持／拒绝方式及理由；对应测试 |
| --- | --- |
| old host → new app | 旧宿主不产生 `actionClass`，卡片不显示类范围说明，行为与今天相同。`BotActionClassTests` 只证明新宿主。 |
| new host → old app | 旧 App 忽略额外的 `effects[].actionClass`（effect schema 允许附加成员），卡片仍显示「始终允许」但不知道覆盖范围；Grant 仍能命中，因为匹配在宿主。 |
| new host → new app | 类范围说明 + 同轮接续；`BotApprovalClassContinuationTests`、`BotActionClassTests`。 |
| old snapshot → new host | 精确 Grant 原样恢复；没有类别 Grant 时下一次破坏性调用仍出卡。`BotGrantRecoveryTests` 通过。 |
| new snapshot → old host / rollback | 旧 host 按 `operation`/`resource` 精确匹配，类别 Grant 不命中 → 更保守地重新询问；不误放行。 |

- 版本／adapter：不需要新版本号；快照 schema 未变，值域扩张按未知值规则处理。
- Worker/app 更新顺序：不需要重建 Worker 资产（`approval-gate.ts` 未改）。
- `target`／`draft` 差异：无。

## 4. 验证

- `swift test --filter BotActionClassTests` → 8/8 PASS。
- `swift test --filter BotApprovalClassContinuationTests` → 2/2 PASS（同类卡片接续、异类不接续、Grant 以 `exec:delete`/`*`/`until` 落库）。
- `swift test --filter 'BotAuthorizationTests|BotGoldenVectorTests|BotEgressSpikeApprovalPatternTests|BotGrantRecoveryTests|BotInternalReadToolsApprovalTests|BotReadMemoryApprovalTests'` → 33/33 PASS。
- `swift test --filter 'BotApprovalCancelTests|BotApprovalLongWaitTests|BotApprovalExpiryRaceTests|BotMCPRuntimeTests'` → 28/28 PASS。
- `DSHApprovalMemoryTests`（simulator target）→ 随 App 测试运行；本轮 NOT_RUN。
- 未验证：真机端到端（模型连续执行两条 `rm`，第一次点「始终允许」后第二条不再出卡）、深浅色卡片文案、旧 App + 新宿主的混合版本、Android。

## 5. 修订记录

- 2026-11-22：初版冻结并实现（`exec:delete` / `exec:git-reset` 两类；只读与工作区写保持既有行为）。