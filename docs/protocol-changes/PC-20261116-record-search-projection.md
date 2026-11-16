# PC-20261116-record-search-projection — record search 投影/去重/嵌套回声

- status: frozen
- base: `9a373adeac0e10f2d3b61c9136a70107778bbc5b`
- contract_revision: `9c3e57c67c3605e7841f796c69810502f666cefb`（tree `1e651d16211b38cd5e6de7a382064d5977803bf8`）
- owning contract: `spec/bot/v1/README.md` §4.4（addendum）
- shared vectors: `spec/bot/v1/golden/record-search-projection.json`；checker
  `spec/bot/v1/tools/validate_record_search_projection.py`
- 不改 `record-query.schema.json` 形状、不新增 CLI 参数/字段。

## 1. 触发（rawlog 实测）

`/tmp/mf-quality-real/M-E5-CONTRADICTION/bot-events.jsonl`：
- `commitSeq 34/38` 的 `conversation.tool_result` 各 **43,424 字符**、11 个 `record://`；
  `record.read` 的 `lines[].raw` 是再次 JSON 转义的原始 session 行；
- `commitSeq 40` 的 `record.search` 又把这些回显/嵌套 raw 当正文命中，形成“来源检索把自身回显再当
  搜索材料”的放大链；40–50k 字符工具返回被再次喂模型，单批 ~400k token。
- 仅提高预算不能修复该链。

## 2. Delta（语义收紧，形状不变）

- `search` 只索引每条记录自己的顶层可读文本（session message.content text、durable data.text/
  data.message.text、tool result text）；不得递归 `data/raw/lines/hits` 或解引用嵌套 `record://`。
- 顶层 text 解析为 P19 envelope 且 `tool == record.search|record.read` 的记录是 bridge echo，默认
  不进索引；原文仍可按 ref `read`；其他 assistant/tool 产物保留，仅索引顶层文本。
- 一个规范 `record://` 只出一 hit；同一 ref 多来源/嵌套/引用不重复。
- 沿用 hits≤20、snippet≤400、输出≤256 KiB；snippet 折叠空白、不返回转义 raw。`read` 仍返回原文
  （256 KiB 上限），但消费方不得把 `read` 的 lines/raw 当新来源。
- 来源/信任/授权不变；不按业务关键词/样例特判。

## 3. 反例

共享向量：`#5` 用户原话 + `#41` assistant 摘要应各一条；`#40` record.read 回显、`#42` record.search
回显必须 excluded；`#5` 只出现一次；#40 的 43k raw 不展开；snippet≤400。显式 `read` 仍返回原文。

## 4. 兼容与分工

| 组合 | 行为 |
| --- | --- |
| 旧 reader | 形状不变；只是 hits 更少、snippet 不展开；无字段变化 |
| 旧数据 | 仍可 search/read；bridge echo 默认不进 hits，但显式 ref 可读 |
| 回滚 | 旧逻辑可读同数据；不会因新字段失败 |
| P | `BotRecordService` 的 searchable/snippet/bridge-echo/去重 + 真实 rawlog 回归 |
| M | maintenance material 只消费 excerpt+ref，不把 read lines/raw 回灌；预算仍 r10 |
| C | 集成；不改 source baseline |

## 5. 未做

- P/M 代码、真实 rawlog 的 Swift 复算、M maintenance 材料改造、真机/模型；本文件只冻结投影语义与
  共享向量，不得当实现完成。
