# PC-20261116-workspace-materials — G-2 workspace decision materials

- status: frozen
- base: `9a373adeac0e10f2d3b61c9136a70107778bbc5b`
- contract_revision: `d7f5ddcb8a11a253998d2b98eed6a04cbb613d37`（tree `a2305dc23c2cabe76f06eaa874e957f8b16f7bb2`）
- owning contract: `spec/bot/v2/decision-context.md` §1（G-2 r6）
- no schema field change; `decision-material` ref/path are strings.

## Delta

- Same `BotDecisionContext` block may include ≤2 Bot-root-relative workspace materials:
  `ref=workspace:<path>@sha256:<64hex>`，path 不以 `/` 开头、无 `..` 段、无反斜线/空白/控制字符、≤200；
  `path` 与 ref 一致；`scope=agent`；`evidence=[]`；`version`=mtime 秒（≥1）；`updated_at_ms`=mtime ms；
  `selection_reason ∈ match|recency|goal`；`state=current`（同 turn 真实 read+sha256），无 `reason`。
- `sha256` 是本次实际读取字节（≤64 KiB）的摘要；ref 固定该次读取身份。pre-delivery/reuse 必须重读并
  核 hash，不一致丢弃/重生成。读取失败/超时/越界/非文本 → 候选不出现，不生成 unknown 材料。
- workspace 计入既有 `max_materials`/`max_characters`/`max_snippet_characters`；memory 保留其余槽；
  block `truncated` 反映省略。
- workspace ref 不是交付/附件来源：delivery/approval 资源仍必须 memory/record；R review 的 parseRef
  跳过 `workspace:`。
- 不新增 MCP 工具/`systemPrompt.context` section/profile 行；R2 只新增 `WorkspaceDecisionContext*`；
  R 改主 service；C 在唯一 `BotRuntimeComposition.prepare` 注入；E 的 A/B 用 R 插件 profile
  `workspaceMaterials: false`，同一 worker 开关，不用两棵不同 SHA 树。

## 兼容

| 组合 | 行为 |
| --- | --- |
| 旧 reader | ref/path 仍是 string；未知 workspace ref 按普通字符串不崩；delivery 不接受 |
| 旧数据 | 无 workspace 材料；memory/record 语义不变 |
| 回滚 | 不写新持久字段；旧材料块仍可读；workspace 候选只是本 turn 材料 |

## 未做

- R2 实现/测试、R 主 service patch、C 注入、E 同源 A/B、真实 request 证据；本契约不替代。
