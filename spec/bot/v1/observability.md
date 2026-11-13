<!-- SPDX-License-Identifier: MIT -->

# Bot observability v1：context lint

状态：`target`。本文件冻结 context lint 的六条规则、warn/error threshold、finding 字段与每条规则
的 `location` keys。行为权威是 `Sources/PhoneDSHBot/Watchdog/{BotContextLint,
BotContextLintRules}.swift`；`context-lint.schema.json` 冻结 finding 的 JSON shape。

## 1. 调用边界

**P0 没有 production caller。** `BotContextLint.lint(...)` 只在测试与显式 on-demand 调用中存在；
没有任何 turn、routine、Task 或 Watchdog 自动运行它。Android 若新增 caller（每回合、每 N 回合或
后台定时），那是**新行为**，不是 D7 移植：必须先定义运行预算（最大事件数、最大 bytes、最大耗时、
采样/丢弃规则、失败是否阻塞回合）和 UI 呈现，再另开 PC。不得因为“lint 很便宜”在每回合无上限重放
完整 session。

`context-profiles` 只是 DSH compaction 的**数据**（default/conservative 的参数与 YAML patch）。
Bot runtime 不执行 compaction，也不因为 lint 存在就重作 DSH 的上下文压缩；Android 不要求实现
compaction。Bot 侧只有显示/校验 profile 时才读 `context-profiles.json`；未知 profile 解析为
`default`（仅解析层回退，不新增持久化格式）。

## 2. 输入

`lint(events, promptMount?, tools?, thresholds, sessionId?)`：

- `events` 是最近 session 的事件（`turn/start`、`user/message`、`assistant/message`、
  `system/message`、`tool/call`、`tool/result`、`request/header`）。消息文本按 Swift 的
  `content`/`message.content` 规则抽取。
- `promptMount` 可选；`{chars}` 优先，否则把 `mounted[].chars`（缺省用 `text` 的 UTF-16 长度）
  求和。它用于 persona 的真实挂载大小。
- `tools` 可选；可以是工具数组或 `{tools:[...]}`；否则取最后一个 `request/header.header.tools`。
- `sessionId` 只写入 finding location，不参与规则判定。

## 3. Finding

每个 finding 是：

```json
{"rule": "<six-rule enum>", "severity": "warn|error", "evidence": "<non-empty diagnostic string>", "location": {"...": "per-rule keys"}}
```

- `rule` 只能是 `system-prompt-bloat`、`tool-result-bloat`、`duplicate-context`、
  `orphan-tool-call`、`orphan-tool-result`、`tool-def-bloat`。
- `severity` 只能是 `warn`/`error`；没有 info。
- `evidence` 是人类可读诊断，**不是** wire contract，不解析；字段与措辞可以随实现改进，但不得
  在其中放 secret 或完整工具结果。
- `location` 是 UTF-8 JSON object；每个规则使用下表的精确 key 集合，不允许额外 key（schema
  `context-lint.schema.json` 关闭）。nullable 值写 `null`，不省略。

| rule | location keys |
| --- | --- |
| `system-prompt-bloat`（prompt mount） | `sessionId, source("prompt-mount"), chars` |
| `system-prompt-bloat`（system message fallback） | `sessionId, source("system/message"), turn, seq, chars` |
| `tool-result-bloat` | `sessionId, turn, step, seq, callId, tool, tokens` |
| `duplicate-context`（runtime snapshots 过多） | `sessionId, turn, seq, occurrences` |
| `duplicate-context`（runtime snapshot 重复） | `sessionId, turn, seq, chars` |
| `duplicate-context`（runtime snapshot 累积包含） | `sessionId, turn, seq, earlierSeq, chars` |
| `duplicate-context`（普通消息重复） | `sessionId, turn, seq, firstSeq, occurrences, chars` |
| `orphan-tool-call` | `sessionId, turn, step, seq, callId, tool` |
| `orphan-tool-result` | `sessionId, turn, step, seq, callId` |
| `tool-def-bloat` | `sessionId, source("tools/list"|"request/header"), count, tokens, chars` |

`source` 为 `tools/list` 表示调用方显式传入 `tools`，`request/header` 表示最后一个请求头；两者
不能混写。`tool`/`callId` 缺失时写 `null`（`orphan-tool-call` 的 `callId` 非空）。

## 4. Thresholds

缺省值冻结为：

| 规则/参数 | warn | error |
| --- | ---: | ---: |
| persona（`system-prompt-bloat`） | 20000 chars | 32000 chars |
| tool result（`tool-result-bloat`） | 4096 tokens | 12000 tokens |
| tool definition（`tool-def-bloat`） | 8000 tokens | 16000 tokens |
| tool count（`tool-def-bloat`） | 40 tools | —（同 rule 的 token error 仍可为 error） |
| runtime contexts/turn（`duplicate-context`） | 2 个 | —（warn） |
| repeated text（`duplicate-context`） | 500 chars | —（warn） |
| repeated text findings 上限 | 20 个 | — |

规则：

- 比较是 `>=` threshold；persona 用 UTF-16 chars，tool result/tool definition 用下节的估算
  tokens，tool count 用数组长度。
- 非正 warn 回退到缺省 warn；非正 error 回退到**当期 warn**；error 小于 warn 时提升为 warn。
  即 `warn = positive(value, defaultWarn)`，`error = max(warn, positive(value, fallback: warn))`。
  这是 coercion，不是 reject；例如两栏都为 0 时 warn=20000、error=20000，刚好 20000 chars 报 error。
- `toolCountWarn`、`maxRuntimeContextsPerTurn`、`repeatedTextChars`、`repeatedTextMaxFindings`
  的最小有效值是 1；非正输入按 1/缺省处理。
- `repeatedTextMaxFindings` 只限制“普通消息重复”这一类 finding；runtime snapshot 的重复/累积
  不计入这 20 个上限。

## 5. 各规则语义

### 5.1 system-prompt-bloat

有 `promptMount` 时用其 chars；没有则累加所有非空 `system/message` 文本的 UTF-16 长度。达到 warn
报 warn，达到 error 报 error。有 `promptMount` 时不再回退 system message，避免同一 persona 报两次。

### 5.2 tool-result-bloat

只检查 `tool/result`，文本为空不报。`tokens = ceil(asciiUTF16 / 3.5) + nonASCIIUTF16`（非 ASCII
每个 UTF-16 unit 记 1 token）。达到 warn/error 才报。文本包含 spill notice（
`Full formatted result stored at:`、`Omitted N bytes.`、`More bytes were omitted.`、`[spill]`/
`[spilled]`、`spill(ed) to|file|at`，大小写不敏感）时不报，因为内容已外置。`tool` 来自同
`callId` 的 `tool/call`；找不到则 `null`。`turn`/`step`/`seq` 来自 result 或其所在 turn。

### 5.3 duplicate-context

输入先按 `(turn, source.kind=runtime-context)` 分组：

1. 同 turn 的 runtime-context 消息数 `> maxRuntimeContextsPerTurn` → warn，location 用最后一条的
   seq 与 occurrences。
2. 同组内 `normalizeText` 后完全相同的 runtime snapshot，第二次及以后各报一次（同一文本只报
   一次）；`normalizeText` 做 compatibility mapping 并把任意空白序列折叠为单个空格、去首尾空白。
3. 同组内较早文本是较晚文本的 literal substring，且长度差 `>= 200` UTF-16 units → warn，
   location 用 later seq、earlierSeq、later chars；每个 later 最多一条。
4. 非 runtime-context 消息按 `normalizeText` 后的完整文本分组；长度 `>= repeatedTextChars` 且
   出现 `>= 2` 次 → 每个不同文本一条 warn，最多 `repeatedTextMaxFindings` 条。location 用第二次
   出现的 turn/seq、firstSeq、occurrences、chars。

### 5.4 orphan-tool-call / orphan-tool-result

`tool/call`（含 assistant content 的 `tool-call` block）与 `tool/result` 按 callId 配对：

- 有 result、无 call → `orphan-tool-result`，severity `error`；result 没有 callId 也报。
- 有 call、无 result → `orphan-tool-call`，severity `error`。
- 两边都有不报。两个 list 各自按 `(seq, callId)` 排序，保证确定性。

### 5.5 tool-def-bloat

工具数组为空/缺失不报。逐个工具取规范 JSON 字符串，累加 UTF-16 chars 与估算 tokens。任一条件
达到即报一条（不是每个工具一条）：`count >= toolCountWarn` 或 `tokens >= toolDefTokensWarn`。
severity 由 tokens 是否达到 `toolDefTokensError` 决定；仅 count 超限时是 warn。`source` 见 §3。

## 6. 排序与确定性

先按 severity（error 在前），再按规则 enum 顺序（system-prompt-bloat、tool-result-bloat、
duplicate-context、orphan-tool-call、orphan-tool-result、tool-def-bloat），再按 location.seq
（缺省 -1），最后按发现顺序。相同输入必须产生相同数组；实现不得依赖 Dictionary 遍历顺序。

## 7. 与 Watchdog 的边界

context lint 不是 Watchdog check：它不写 `watchdog.flagged`，不进入 once-per-unit seen，不会停止
回合，也不自动 nudge。Watchdog 的 quota 只看 unit 的 token/cost 累计，不做上下文内容分析。两者
共享 `sessionId` 只是诊断关联，不是同一个事件流。
