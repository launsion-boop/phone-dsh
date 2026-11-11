<!-- SPDX-License-Identifier: MIT -->

# Bot 会话日志抹除 spike（S6 第二步，只取证）

日期：2026-11-12  
范围：`spec/v1/wal.md`、DSH `0.2.2` 只读 checkout（`/private/tmp/dsh-0.2.2`，pin
`66491b05e3f05ad35bcdd4f6cd7ed26041d9e3db`）、宿主物化副本路径、`workspace/archiveSession`、
`@deepseek-ai/dsh-session-persistence-jsonl`、S1 `record://` 与 S6 第一步实现。  
结论先说：**条件可行，但当前 P02/WAL 与 DSH session persistence 契约下不可直接实现。** 本 spike
不实现第二步，也不改任何会话文件。

## 1. 问题

总方案 §3.1 的第二步是：主对话换到新的 DSH 会话（「会话纪元」），接续上下文从原始记录和记忆
索引重建（排除被抹除区间）；旧会话文件关闭后由宿主改写，把被抹除区间换成墓碑。要回答：

1. 宿主能否安全改写已关闭会话在 **WAL** 和**物化副本**里的文件，且 Worker 重启/resume 不会从
   WAL 恢复出原文？
2. DSH 是否提供关闭/归档会话的接口（`workspace/archiveSession`）？
3. 纪元切换对用户可见的连续性有什么影响？

## 2. 证据

### 2.1 宿主的两份持久状态

`spec/v1/wal.md` §1：

- Worker 运行时的内存 VFS 是唯一权威；WAL 是每个已提交 mutation 的恢复日志；物化副本由 WAL
  派生（"the materialized copy is derived from it"）。
- 会话文件位于 `materialized/home/sessions/**`（同文件 §1、§6；宿主路径见
  `Sources/PhoneDSH/PhoneDSHHost.swift:2652`、`Sources/PhoneDSHBot/Journal/BotRecordService.swift`
  的 `materialized/home/sessions` locator）。

`spec/v1/wal.md` §3/§5.1：

- 只有 mutation 和 epoch-close 记录；mutation 记录 append-only、按 mseq 连续无洞。
- 已接受的记录 **never discarded and never rewritten**（§5.1）；base mismatch 的修复也是用
  新的完整 write 记录覆盖，而不是删除旧记录。

`spec/v1/wal.md` §7.2/§10：

- 恢复会扫描 `wal/*.xlwal`，按 mseq 放置并 replay 到物化副本；未列出但高于 watermark 的尾部
  会被 adopted；列出的段只有在 mseq ≤ watermark 后才可删。
- 崩溃后 replay 从 manifest watermark 重放 durable 前缀；启动 overlay 由物化树打包（§8）。
- 因此：只改物化副本、不改 WAL，下一次恢复/重放可能把旧字节写回；只删 WAL 段、不改 manifest
  会触发 `WAL_CORRUPT`/`Failed` 或丢失已确认写。

`spec/v1/wal.md` §9：

- compaction 是**整段 truncation**，只删 droppable 段；删段用 unlink，规范没有定义安全擦除
  （secure erase）、APFS 快照或备份处理。即使段被删，旧文件内容是否还能从文件系统/备份恢复
  不在当前契约的保证内。

**结论 2.1：** 按现有 P02 契约，宿主没有一个「改写已关闭会话的某个区间」的原语。用 App-lane
完整 write 覆盖会话文件会在 WAL 里留下旧记录，且要等 watermark/epoch close/compaction 才能删段；
compaction 也不是安全擦除。要物理抹除，必须新增一个 WAL 级「retire/rewrite + secure delete」操作，
这会改 P02 的只追加和恢复不变量。

### 2.2 DSH session persistence 本身保留历史

`/private/tmp/dsh-0.2.2/packages/session/session-persistence-jsonl/README.md`：

- "stores each session in a current append-only JSONL log and **retains immutable historical format
  generations**"。
- "Committed events are never rewritten."（§Durability and crash semantics）
- 历史 generation 的 write open 会发布 successor，但 "**The source remains byte-identical**"。
- 文件布局：`session.vN.jsonl(.zstd)` 并存，读取选择最高 N；旧 generation 仍在同一
  session-owned 目录。
- `SessionHandle.close()`（`session-persistence/src/handle.ts`）只是释放 handle/写所有权，
  不删除也不改写日志；`append` 的注释再次写明 committed events are never rewritten。

**结论 2.2：** DSH 没有「关闭后改写/删除一个 session 文件」的公开接口；即使从 Worker 内部关闭
handle，旧 generation 仍保留，重启/resume 仍可能被 `list`/历史读取选中。

### 2.3 `workspace/archiveSession`

`/private/tmp/dsh-0.2.2/packages/workspace/workspace/src/index.ts:365`：

- `archiveSession(sessionId, options?)` 把 id 写入 registry-global `archivedSessionIds`，并清掉
  pin；默认先询问 `workspace/session-activity`，有活动则拒绝；`{stopActivity:true}` 先写归档再
  发停止事件。
- `unarchiveSession` 只从归档集合移除 id；注释明确 "an entry whose session is gone still
  unarchives"。
- 归档 "hidden from every grouping surface"；**不删除、不关闭、不改写 session 文件**，也不改变
  `sessionPersistence.list()` 的物理文件。

**结论 2.3：** `archiveSession` 可以作为「用户不再看到旧会话」的 UI 层，但不是关闭/擦除接口。

### 2.4 重启、resume 与历史读取

- `spec/v1/wal.md` §10：cold recovery 不信任内存，用物化树打包 overlay，并 replay WAL 尾部；
  durable 语义由 epoch-close 决定。
- DSH `list()`/`open()` 选择最高 generation；历史 generation 可被迁移读取。若只归档 id，旧文件
  仍可被直接路径读取，`phone record` 的 `record://session/...` 也仍能读到原行。
- S6 第一步的 `record://event` 已能返回 `record_erased`，但 `record://session` 没有 tombstone
  表；本 spike 未改它。

**结论 2.4：** 宿主改写物化文件必须同时处理 WAL 尾部、manifest watermark、boot overlay、历史
generation 和 `record://session`；否则 resume/历史读取会恢复原文。

### 2.5 纪元切换的用户可见影响

如果按总方案开新 DSH session：

- Bot 主对话的 `sessionID` 会变化；Gateway claim、`record://session`、隐藏回合的
  `hiddenTextSessions`、held/后续投递和 UI 行投影都以 session id 为键。
- 现有 Bot 行投影 (`BotSessionLogProjection`) 从 session log 重建；切到新 session 后旧行不会
  自动出现在新会话。用户会看到对话「断掉」或历史消失，除非 UI 额外拼接旧 epoch。
- 接续上下文必须由宿主用原始记录 + 记忆索引重建；被抹除区间必须排除。压缩摘要的
  `replacedRange`、held 块和隐藏回合不在新 session 里自动存在。
- routine/Task 使用各自的后台 session，不受主会话纪元影响；但它们的 `record://` 引用仍指旧
  session。
- `workspace/archiveSession` 只能让旧 session 从列表消失；若 UI 要读旧 epoch 展示历史，仍会
  读到未擦除的原文。

## 3. 结论

**条件可行。** 在「用户可见地切换会话纪元」这个产品行为上可行，但「宿主安全改写已关闭会话的
WAL + 物化副本 + 历史 generation，使原文不可恢复」在现有契约下 **不可行**；需要同时改 P02、
DSH session persistence 或引入宿主自有的会话日志所有权，并补齐 UI 连续性。

满足以下条件后才建议进入实现：

1. **P02 新增受控的 erase/retire 原语。** 例如 `VFS_ERASE`/host-side `retirePathRange`：
   指定 path、seq 区间/完整 prefix，生成新的完整 write（墓碑）并允许在 manifest 中 retire 旧
   mseq 区间；恢复只按新 manifest 的有效前缀 replay，且必须在同一 DSH 关闭/epoch-close 顺序内
   fsync、更新 manifest、安全擦除被 retire 的段。需要覆盖断电、torn tail、Worker 崩溃、manifest
   滞后/超前、恢复后不复活原文的测试。
2. **DSH 提供关闭/改写接口，或 phoneDSH 自己拥有 closed-session log 格式。**
   当前 `session-persistence-jsonl` 明确保留 immutable generations 且 committed events 永不
   rewritten。可行路径是上游新增 `closeSession` + `rewriteClosedSession`（发布新 generation 并
   删除旧 generation），或 phoneDSH 把会话日志改成宿主可安全重写的自有格式（这会替换 DSH
   上游持久化，属于更大的私有补丁风险）。
3. **会话纪元与 UI 连续性的显式契约。** `session.epoch.switched`/epoch marker、旧 session 归档、
   UI 拼接旧 epoch 时过滤 tombstone 区间、接续上下文的 seam turn、`record://session` 的
   tombstone 解析、隐藏回合/held 重建、用户可见说明。
4. **安全擦除与备份边界。** APFS 写时复制/快照、iOS 备份、`recovery-backup/`、SQLite/日志备份、
   `materialized.staging/`、旧 WAL 段、DSH 历史 generation、模型 provider 日志和外部连接器副本
   都要有明确「不承诺」或「一并处理」的文案和证据。

## 4. 建议实现步骤（若条件满足）

1. **契约（P02 + P25/P26）**：先冻结 WAL erase/retire 语义、manifest 新字段（retired ranges）、
   session epoch marker、`record://session` tombstone 语义和新错误码；加共享向量、断电/恢复
   测试矩阵。
2. **宿主**：在 Bot 主对话上写 epoch marker；关闭 Writer/Worker 并等待 journal drain；调用
   上游 closed-session rewrite（若没有则停止，不直接改文件）；按区段生成墓碑；安全擦除 retired
   WAL 段、物化文件和 staging/backup；更新 manifest；验证 `record://session` 和 `phone record`。
3. **上下文重建**：从原始记录 + 记忆索引构造新 epoch 的 seam prompt，排除 `erasure` 范围；
   旧 epoch 只读归档；held/隐藏回合按宿主元数据重建。
4. **UI**：按 epoch 拼接时间线，明确用户可见的「此处内容已抹除」；会话继续输入到新 session；
   通知/深链仍指向 Bot，不指向旧 session id。
5. **验证**：断电/杀进程后 restart/resume 不复活；`list()`/历史 generation 不返回原文；DB/WAL/
   物化/备份文件字节级断言；真机与模拟器分别记录；真实模型 E2E 由主会话跑。

## 5. 风险

- **不可恢复性不可证明**：iOS 文件系统、APFS 快照、系统备份和闪存磨损层都不提供可验证的
  物理擦除；最多做到「App 可访问的权威/派生副本不再含原文」，界面不能宣称更广。
- **DSH 上游依赖**：不 patch/vendor DSH 是本仓硬规则；没有上游 closed-session rewrite 时，
  第二步会长期停在条件不可行。
- **双权威窗口**：关闭旧 Worker、切新 session 期间若有后台 job/routine 写旧 session，会重新
  写入原文；需要 S4 的 job/egress 归属和 S5 的 presence/routine 收敛一起保证。
- **UI 连续性成本**：epoch 拼接、旧行过滤、压缩摘要引用重写、held/隐藏回合重建都比第一步大。
- **记录引用语义扩散**：`record://session` tombstone 会影响记忆 evidence、审计、观察信封和
  `phone record`，需要一次跨 P25/P26/P27 的变更，而不是局部补丁。

## 6. 实测/读取清单

| 项 | 证据 | 结论 |
| --- | --- | --- |
| 物化副本是否权威 | `spec/v1/wal.md` §1、§6、§10 | 派生自 WAL；恢复/replay 可覆盖 |
| WAL 是否允许改写单条 | §3、§5.1 "never discarded and never rewritten" | 不允许；新增 erase 原语才行 |
| 删除 WAL 段是否安全擦除 | §9 compaction 用 segment unlink；无 secure-delete | 不保证；需新契约 |
| DSH 历史 generation | session-persistence-jsonl README §On-disk layout / §Durability | 旧 generation 保留且不可改写 |
| 关闭接口 | `session-persistence/src/handle.ts` `close()` | 只释放 handle；不删文件 |
| 归档接口 | `workspace/src/index.ts:365` | 只改归档集合；不关闭/删除/改写 |
| Worker 重启/resume | `wal.md` §10；DSH list/open 选最高 generation | 不做 WAL/历史清理就会恢复 |
| UI 连续性 | `BotSessionLogProjection` 按 session log 重建 | 新 session 会断档，需 epoch 拼接 |
| 第一步现状 | S6 的 `record://event` `record_erased` | 事件载荷可证明清除；session 未覆盖 |
