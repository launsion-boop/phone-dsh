# PC-20261116-bot-skill-lineage — skill 写事件 / 派生关系 / 跨 Bot 与压缩口径

- status: frozen
- base: `6936a2e78a32ae65a210af37bec0c0a823ec6731`
- contract_revision: `3b9f6d838277ffe165e06319b4c5a3f61acfa90a`（tree `6f57790c2a1b79f8a8c460d0c3201f831c1c4d87`）
- owning contract：`spec/bot/v2/provenance.md` §3.4（新增）、§4.6/§4.7；`skill-change.schema.json`
- P25 trigger：`spec/bot/v1/event-envelope.schema.json` + `golden/event-envelope.phone.json`
- shared vectors：`spec/bot/v2/golden/skill-lineage.json`；checker `spec/bot/v2/tools/validate_skill_lineage.py`
- validators：`validate_skill_lineage.py`、`validate_provenance.py`、`validate_vectors.py`、registry/cross_check

## 1. 触发与当前行为

- 触发：C 任务要求 skill 写事件驱动 derivation；root/A04 原目标含 skill 改动出处；此前
  `skill` 只有 `unknown + no-skill-write-event`。
- 当前：`plugins/phone-feature-admin` 的 `SkillsStore.write` 写 `/dsh/home/skills/*.md` 并
  invalidate catalog，但没有 Bot durable event；L 无法从现有 carrier 解析 skill。
- 本变更不复制 skill 文件写入逻辑；plugin 仍是唯一技能文件写入权威。

## 2. Delta

新增 durable type **`skill.changed`**（P25 enum add-only；未知 type reader 忽略）：

- envelope：`ignorable:true`；`origin.kind=local, source=ipc`；`principal.kind=ipc`；不新增
  origin/principal 枚举值。`author{kind:user|bot|migration|system,bot_id?,session_id?}` 记录实际写入者。
- `data`（`schema:"bot-skill-change/v1"`）：
  - `action:"write"`：`skill{name,file,revision,content_sha256,bytes,previous_sha256?}`；
  - `action:"delete"`：`skill{name,file,revision,previous_sha256}`；
  - `at_ms`；可选 `derivation`（G-1 同一形状，artifact kind=skill、id=name、version=revision）。
  - **不写 skill 正文/用户内容**；`content_sha256` 是原始 UTF-8 文件字节摘要。
- 语义：
  - `revision` 每 skill 从 1 单调，删除也占一个 revision；`previous_sha256` 必须匹配上一成功写；
  - skill 是 host-global，任一 Bot 可读 lineage，但不得读其他 Bot 的 session/事件；
  - 最新事件 write：读时宿主 recheck 当前文件 hash；匹配 → `current`，不同 → `changed`，未 recheck
    → `unknown + refresh-not-performed`；最新 delete → `unavailable + skill-deleted`；
  - 无事件 → `unknown + no-skill-write-event`（旧数据），不伪造；
  - 事件失败/文件改但无事件：catalog 标脏，下次启动按目录 hash 对账补事件（author=system，revision
    续接，不伪造 sources）。
- 同时新增 `cross-bot-unresolved` reason：共享 `user/` 记忆的 evidence 指向另一 Bot 时，能解析被
  引用的用户原话才 current；否则 unknown，不暴露其他 Bot session/索引，不降级 current。
- COMPACT：`shadowedBy` 只是读视图链接；压缩不新增 observation/version、不判 changed/current/erased，
  不改 baseline；`record://` 身份不变；latest 索引仍只从 durable carrier 建。

## 3. 兼容矩阵

| 组合 | 行为 |
| --- | --- |
| 旧 producer → 新 reader | 无 `skill.changed`：`unknown + no-skill-write-event`；不伪造 revision/hash。 |
| 新 producer → 旧 reader | 新 type 带 `ignorable:true`；旧 reader 忽略；skill 文件本身仍可用。 |
| 新数据 → 回滚旧 App | 旧 App 不写/不读新事件；文件不变；回滚后新 App 重读事件仍可恢复 lineage。 |
| 旧数据 → 新代码 | 旧 skill 文件无事件：`unknown`；不自动补 revision/sources；宿主对账可补 system 事件。 |
| 跨 Bot | skill lineage 全局可读；session/event 仍按 Bot 隔离；`cross-bot-unresolved` 显式。 |
| 删除 | 最新 delete → `unavailable + skill-deleted`；历史 lineage 保留；正文不可读。 |

## 4. 接线与验收

- L：`recordSkillWrite` append `skill.changed`；读模型把该事件当 skill carrier，删除用
  `skill-deleted`；不能用 `skill.written`/`record-erased` 替代。
- C：plugin skill 管理写成功后调用 L 的 producer（或 host bridge）；校验 catalog invalidation
  成功后才写事件；启动对账。
- E：A04 的 skill 出处用真实 skill 写事件验证；无事件旧数据只能记 unknown，不得 PASS。
- 命令：`python3 -B spec/bot/v2/tools/validate_skill_lineage.py`；`validate_provenance.py`；
  `python3 -B spec/bot/v1/tools/validate_vectors.py`；registry/cross_check。
- 未做：producer/host bridge、启动对账、真实跨 Bot/压缩运行时证据；不以本契约冻结代替。
