WP7-a: 保留
<!-- SPDX-License-Identifier: MIT -->

# WP7-a：persona 消融组 a「回合与回复格式」（2026-11-11）

状态：真实模型消融完成，结论 **保留**。消融变体在跑完后已回滚，本分支最终只新增本报告（§9 给出复现方法）。
基线：`origin/main` `871488cfe`；本工作树 `dsh-work/s1-wp7-a`，分支 `s1/wp7-ablation-a`，工作树起点 `8343a7202`（main + WP2 场景目录）。
模型：`deepseek-flash`（`https://api.deepseek.com`，real）。请求由 `scripts/ci/model-env.mjs` 导入，key 没有打印、记录或写入任何文件。

## 0. 结论

**保留本组，原样保留。**

按任务给的删除标准，本组不满足删除条件：

1. **有场景从 3/3 退步到 2/3**：E01 主跑 2/3。唯一失败是 turn 5 的 `reply_contains` 按大小写比较，
   模型实际回复 `zebra-quartz-3317`，断言要 `ZEBRA-QUARTZ-3317`；词被召回，但 gate 仍是 FAIL。
2. **部分通过场景的通过次数下降**：E05 基线 1/3，消融 0/3（三次都是 `approval_count == 3`）。
3. **回复形态明显变差**：全体可见回复的平均长度 48.8 → 65.3 字符（+34%），最长 355 → 510，超过 90 字符的
   回复 6 → 8；E01 首轮闲聊 25 → 69 字符并出现 emoji/语气词；E03 概括 166 → 395 字符并出现 3 条以上列表；
   E01 有一次 349 字符的回复以冒号结尾、没有下文（1.1 的「收尾」规则正是约束这个）。

第 3 条独立于 E01/E05 的争议：即使把 E01 的大小写失败和 E05 的已知审批 bug 都排除，回复形态仍然变差，
所以也不能删除。

「改写」同样不成立：没有发现某一条规则本身写错；变差来自**卸掉**这些规则，不是规则内容有缺陷。三节里
`1.5 单一聊天线程` 没有被任何 WP2 场景覆盖（没有线程/频道/多串场景），但它是边界陈述、成本只有 112 个
中文字符，本轮维持保留，并在 §8 建议补场景后再单独评估。

## 1. 卸掉的段落

本组三节，中英文模板各一份。删除前位置按 `HEAD` 行号；为什么不用 `mount` 条件见 §2。

| 文件 | 标题 | 首句 | 段长（字符 / 行） |
|---|---|---|---|
| `plugins/bot-runtime/prompts/system-prompt.zh-CN.md:31-41` | `## 回复长度（硬规则）` | 默认最多 2 句话或约 90 个中文字，取较短者；多数回答只写 1 句。 | 311 / 8 |
| `plugins/bot-runtime/prompts/system-prompt.zh-CN.md:42-52` | `## 1.1 回合流程` | 你对用户可见的输出就是你写出的助手文本；普通助手文本会直接送达，也可以用 `mcp__phone__SendToUser` 显式发送一条。 | 563 / 9 |
| `plugins/bot-runtime/prompts/system-prompt.zh-CN.md:77-80` | `## 1.5 单一聊天线程` | 每个 Bot 只有一条和用户的连续一对一聊天：没有串式回复，也没有 `reply_to` 参数。 | 112 / 3 |
| `plugins/bot-runtime/prompts/system-prompt.md:31-41` | `## Reply length (hard rule)` | Default hard cap: 2 sentences or roughly 90 characters, whichever is shorter; most replies should be one sentence. | 903 / 8 |
| `plugins/bot-runtime/prompts/system-prompt.md:42-52` | `## 1.1 How a turn works` | Your user-visible output is the assistant text you write; plain assistant text is delivered directly, and you can also send one explicitly with `mcp__phone__SendToUser`. | 1499 / 9 |
| `plugins/bot-runtime/prompts/system-prompt.md:77-80` | `## 1.5 One chat thread` | Each Bot has one continuous one-to-one chat with the user: there are no threaded replies and no `reply_to` parameter. | 315 / 3 |

只删这三节，其他段落未改。整组删除量：中文 986 字符（组装后 persona 10,671 → 9,679），英文 2,717 字符
（26,544 → 23,821）。profile 里的 `personaPrefix` 是中文组装结果，同步重新生成。

## 2. 变体生成与「运行器确实用了新 bundle」的证据

`mount` 机制只支持 `engine` / `platform` / `lang` / `variant` 四种条件（`plugins/bot-runtime/src/prompt/markup.ts`
的 `CONDITION_VALUES`），没有可表达「消融组 a」的条件；按任务给的持久做法，直接删除三节，然后按
`assemblePrompt()` 重新生成 profile：

1. 删除上表中的六段（中英文各三节）。
2. 用 `assemblePrompt()` 重新组装，把结果按 profile 既有格式（每行 6 空格缩进）写回
   `plugins/profile/phone.worker.cordis.patch.yml` 的 `personaPrefix: |` 段；profile 其他内容未动。
3. `plugins/tests/bot-persona.test.ts` 的章节清单同步去掉两组标题（中文 `回复长度`、`单一聊天线程`，
   英文 `Reply length`、`One chat thread`）；断言结构不变。

验证：

| 命令 | 结果 |
|---|---|
| `node plugins/bot-runtime/scripts/check-prompt.mjs` | PASS；zh 9,679 字符 / en 23,821；默认 22 节挂载 + 1 个未传 `variant` 的 insert 跳过；带 variant 时 23 节 |
| `node --test plugins/tests/bot-persona.test.ts` | PASS 5/5 |
| `node plugins/worker-entry/build.mjs --out examples/probe-app/Bundle/worker` + `PDSH_DSH_CHECKOUT=/private/tmp/dsh-0.2.2 node plugins/scripts/pack-image.mjs --out examples/probe-app/Bundle/worker` | 重建成功；image gzip 11,447,489 B |
| `bash scripts/ci/check.sh --only phone-bundle-fresh` | PASS：6 个 artifact 全部 fresh（worker-entry.js、tool-worker-python.js、tool-worker.js、workflow-isolate.js、web-boot.js、image.tar.gz） |
| `PDSH_DSH_CHECKOUT=/private/tmp/dsh-0.2.2 node plugins/scripts/profile.test.mjs` | PASS 11/11（pinned checkout 下，无 skip） |

运行器实际使用的不是仓库里那份 bundle：本单元显式把
`PDSH_BOT_EVAL_BUILD_DIR=/tmp/s1-wp7-a-build` 指向一个**新建**缓存目录，`eval.sh` 因 source hash 不匹配
重新打包（`bundle.log`：`packing the Worker bundle under /tmp/s1-wp7-a-build`，不是 `reusing`）。
从该次构建的 `www/image.tar.gz` 解出 `home/cordis.patch.yml` 后检查：`## 回复长度（硬规则）`、
`## 1.1 回合流程`、`## 1.5 单一聊天线程` 均已不存在，`## 目标验证（硬规则）`、`## 1.4 请求用户决策`、
`## 1.16 用户身份` 仍在。E06 重跑时 `bundle.log` 显示 `reusing the Worker bundle /tmp/s1-wp7-a-build/www`，
说明复用的是同一份消融产物。

## 3. 实跑

主跑命令（凭据导入命令原样使用，未打印 key）：

```sh
export PATH=/tmp/node24/bin:$PATH
export PDSH_DSH_CHECKOUT=/private/tmp/dsh-0.2.2
export PDSH_BOT_EVAL_BUILD_DIR=/tmp/s1-wp7-a-build
export PDSH_BOT_EVAL_SCRATCH=/tmp/s1-wp7-a-scratch
export PDSH_BOT_EVAL_SPM_CACHE=/tmp/s1-wp7-a-spm
eval "$(DSH_PROFILE=agent-hub-kit-qa-deepseek \
  DSH_HOME='/Users/leilangsheng/Documents/Codex/2026-08-14/https-github-com-deepseek-ai-deepseek/dsh-data' \
  PDSH_DSH_CHECKOUT=/private/tmp/dsh-0.2.2 node scripts/ci/model-env.mjs)"
bash scripts/ci/bot-e2e/eval.sh --catalog scripts/ci/bot-e2e/catalog.json \
  --only BOT-E01,BOT-E02,BOT-E03,BOT-E04,BOT-E05,BOT-E06,BOT-E07 \
  --upstream real --repeat 3 --results /tmp/s1-wp7-a
```

- 计划：7 个场景 × 3 次；预算 273 分钟 / 660 requests；`upstream: real`，`repeat: 3`。
- 结果目录：`/tmp/s1-wp7-a`（保留）。主跑 gate **FAIL**（E01、E05、E06）。
- E08 未跑：被已知生产 bug（`agent.comm` outbound 事件不出现）挡住，按任务说明排除。
- **E06 额外重跑**：主跑 E06 repeat 1 是基础设施错误（见 §4），不是行为结果。为区分，单独重跑
  `--only BOT-E06 --repeat 3 --results /tmp/s1-wp7-a-e06-rerun`，3/3 PASS，结果目录保留。
  重跑没有改变 E01/E05 的行为结果。

## 4. 逐场景对比

基线：`/tmp/s1-baseline/lane-*/BOT-E0*/report.json`（摘要 `/tmp/s1-baseline/summary.txt`）。
消融：`/tmp/s1-wp7-a`；E06 的「消融」列用 `/tmp/s1-wp7-a-e06-rerun` 的行为结果，主跑异常在括号内注明。

| 场景 | 基线通过 | 消融通过 | 失败断言（消融） | 基线 requests | 消融 requests |
|---|---|---|---|---|---|
| BOT-E01 | 3/3 | **2/3** | r1 `reply_contains "ZEBRA-QUARTZ-3317"`（实际回复小写 `zebra-quartz-3317`） | 46 | 47 |
| BOT-E02 | 3/3 | 3/3 | — | 31 | 31 |
| BOT-E03 | 3/3 | 3/3 | — | 15 | 15 |
| BOT-E04 | 3/3 | 3/3 | — | 47 | 49 |
| BOT-E05 | 1/3 | **0/3** | r1–r3 `approval_count`：3 个审批，期望恰好 1 | 26 | 29 |
| BOT-E06 | 3/3 | **2/3**（主跑 r1 ERROR；重跑 3/3） | 主跑 r1 无可见回复：`llm-bridge: model response headers delivery stalled for 10000 ms (PDSH_DELIVERY_TIMEOUT)` | 27 | 21（重跑 27） |
| BOT-E07 | 3/3 | 3/3 | — | 18 | 18 |
| **合计** | **19/21** | **16/21**（E06 重跑后 17/21） | | **210** | **210**（重跑后 216） |

基线失败断言只有 E05 的 r2/r3：`approval_count` 实测 3、期望 1（E05 r1 通过）；E01–E04、E06、E07
基线都是 3/3、无失败断言。E08 是已知生产 bug，基线和本单元都不在对比范围。

详细失败：

- **E01 r1**：turn 5 的实际助手文本是 `zebra-quartz-3317`（17 字符），断言是区分大小写的
  `reply_contains "ZEBRA-QUARTZ-3317"`，所以 gate FAIL。词本身被正确召回，三轮的 turn 5 都是 17 字符；
  这不是召回失败，是大小写格式失败。按规则仍算退步。
- **E05 r1–r3**：断言 0–2（两个文件存在/内容）和断言 4（echo 请求 0 次）都通过，只有断言 3
  `approval_count == 1` 失败，三次实测都是 3。原因是本地两个文件用了两次 `write` 工具，每次都触发
  「Run unclassified tool write」审批，加上网络 POST 的审批共 3 个；基线唯一通过的 r1 用一条 `bash`
  同时写两个文件，本地写入没有审批，只有网络 POST 1 个。这是已知的生产审批缺口 + 模型的工具选择差异，
  不能归因于本组规则，但按任务规则「部分通过场景通过次数不得下降」，E05 的确退步了。
- **E06 主跑 r1**：动作 1 `user_message` 在模型响应头阶段被 10 秒投递超时拒绝，没有产生任何可见回复；
  断言因此判失败。该 repeat 消耗 3 个 request 后终止，r2/r3 正常 PASS。单独重跑 E06 3/3 PASS
  （每次 9 个 request，共 27），回复都精确是 `FAILED`。这是上游/传输抖动，不是 persona 行为差异。

## 5. 回复形态

统计口径：每个 repeat 的 `conversation.assistant_message` 文本（用户可见的助手回复）；字符数为
Swift/JS 字符串长度（中文按 1 字符计）；「长列表」= 单条回复中至少 3 个列表项；「内容卡」= `card.presented`
里 `cardType` 不是 `question`/`steps` 的卡。E06 消融列使用重跑结果（主跑 r1 没有回复，不具可比性）。

| 场景 | 基线条数 | 基线 中位/均值/最长 | 消融 中位/均值/最长 | >90 字符 | 长列表 | 内容卡 |
|---|---|---|---|---|---|---|
| BOT-E01 | 15 | 20 / 34.1 / 150 | 6 / 42.9 / 349 | 1 → 1 | 0 → 0 | 0 → 0 |
| BOT-E02 | 12 | 34.5 / 33.4 / 63 | 43.5 / 40.5 / 63 | 0 → 0 | 0 → 0 | 0 → 0 |
| BOT-E03 | 4 → 3 | 166 / 177 / 355 | 395 / 417.3 / 510 | 3 → 3 | **0 → 1** | 0 → 0 |
| BOT-E04 | 6 | 70.5 / 71.2 / 105 | 88 / 90.3 / 135 | 2 → 3 | 0 → 0 | 0 → 0 |
| BOT-E05 | 6 | 61.5 / 55.3 / 90 | 30.5 / 36.2 / 92 | 0 → 1 | 0 → 0 | 0 → 0 |
| BOT-E06（重跑） | 3 | 6 / 6 / 6 | 6 / 6 / 6 | 0 → 0 | 0 → 0 | 0 → 0 |
| BOT-E07 | 6 | 22 / 23.2 / 42 | 24 / 28.3 / 56 | 0 → 0 | 0 → 0 | 0 → 0 |
| **全体** | **52 → 51** | **37 / 48.8 / 355** | **40 / 65.3 / 510** | **6 → 8** | **0 → 1** | **0 → 0** |

中位数受 E01 的强制单行回答影响（三轮共 9 条「第 N 轮完成」只有 5–6 字符，占 15 条回复的多数），
所以同时看均值、最长值和逐 turn 数字：

| 场景 / turn | 基线条符（各 repeat） | 消融字符（各 repeat） | 观察 |
|---|---|---|---|
| E01 turn 1（闲聊回应） | 20, 25, 26（中位 25） | 69, 87, 40（中位 69） | 多出「哈哈」「～」「🐟」和天气闲聊，最长 87 |
| E01 turn 2（压力测试回应） | 51, 80, 5 | 6, **349**, 6 | 349 字符那条以「如果想真测压力，可以换个测法：」结尾，冒号后没有内容；基线最长 150 |
| E01 turn 5（召回答案） | 17, 17, 17 | 17, 17, 17 | 内容相同；消融 r1 为小写 |
| E02 turn 1（写记忆） | 37, 32, 39 | 53, 45, 56 | 一致变长，但仍是单段文字 |
| E03 概括回复 | 21+355, 152, 180（4 条） | 347, **510**, 395（3 条） | 消融取消独立的短开场，合并成一条长报告；r2 出现 `**加粗**` + 3 条列表，并以正文提议收尾 |
| E04 turn 2（文件修改） | 44, 39, 61 | 61, 92, 102 | 增加字节数、绝对路径等过程细节 |
| E05 turn 1（本地文件） | 70, 69, 4 | 3, 4, 2 | 变成「完成/已完成/完成」；同一场景三次都因审批数 3 失败 |
| E07 turn 1（写随机词） | 42, 39, 37 | 41, 56, 52 | 多出「所有 Bot 都能看到」等解释和 1 个 emoji |

形态判断：

- **内容卡没有多发**：两轮都是 0 张内容卡；决策卡只有 E01 的 `question`，基线 1 张、消融 1 张。
  `1.4 请求用户决策` 不在本组，卡片行为没有被这次删除破坏。
- **长列表出现了 1 次**：E03 r2 的概括用了 3 条以上列表和加粗小标题；基线 E03 全部是连续 prose。
- **正文建议/追问没有明显增加，但出现了一次未收尾**：基线 E01 r2 本来就有一次正文追问
  （「所以先跟你确认怎么继续。」）；消融 E01 r2 的追问被写成半句并以冒号结束，E03 r2 又新增一次正文提议
  （「如果这两处记录你希望保留作证据，我可以……」）。后者是把选择写进正文而不是卡片的形态退化。
- **长度退化是稳定的、跨场景的**：E01 首轮、E02 首轮、E03 概括、E04 两轮、E07 首轮都变长；只有 E05
  因为三次失败、回复退化成单词而变短，不能当作改善。

## 6. 结论与理由

**保留。** 具体理由：

1. 删除标准是「没有场景退步，且回复形态没有明显变差」。E01 从 3/3 到 2/3（gate FAIL），E05 从 1/3 到
   0/3，两条都不满足；E01 的失败还偏偏是「答案大小写」这种格式问题，说明这一组卸载后更容易出现格式漂移。
2. 回复形态明确变差：均值 +34%、最长 +44%、>90 字符回复 +2、长列表 0→1，并出现一次冒号结尾的未完成回复。
   这与 `回复长度` 和 `1.1 收尾` 的职责一一对应。
3. 没有发现「规则本身写错」的证据，所以不是「改写」；问题是卸载造成的，不是规则内容造成的。
4. `1.5 单一聊天线程` 没有被任何 WP2 场景触发（场景里没有线程、频道、`reply_to`），属于**场景覆盖不足**；
   它只有 112 个中文字符，是边界陈述，没有理由单独删除。若以后要单独评估，需先补一个能观察线程/频道
   描述的 scenario（见 §8），不能把「本轮没测出问题」当成「可以删」。

## 7. 实际用掉的模型请求

| 运行 | 场景数 × 次数 | requests |
|---|---|---|
| 基线（E01–E07，E08 排除） | 7 × 3 | 210 |
| 消融主跑（E01–E07） | 7 × 3 | 210（E06 r1 超时只用了 3 个，r2/r3 各 9 个） |
| E06 基础设施错误后的单独重跑 | 1 × 3 | 27 |
| **本单元实际合计** | | **237** |

主跑计划上限 660 requests（7 场景预算 × 3），实际 210；加上 E06 重跑为 237，仍在目录声明的 800 request
总上限内。逐场景主跑 requests 见 §4 表。

## 8. 限制与后续建议

- **E01 断言对大小写敏感**是场景问题，不应通过改断言来「修」消融结论。建议另开 scenario 修复
  （例如 `reply_contains` 加大小写无关选项），并重跑基线；本单元没有改断言。
- **E05 的 1/3 基线**本身是已知生产审批 bug（本地 `write` 触发 unclassified-tool 审批）。本轮 0/3 的
  直接原因是模型三次都选择 `write` 工具而不是一条 `bash`；这不应被读成 persona 的审批规则变差。
  等 E05 的生产问题修复后，应重跑基线和本消融再确认。
- **E06 r1 的 10 秒投递超时**是上游/传输问题，不是产品行为；报告同时保留主跑和重跑证据，未删除主跑。
  如果重跑策略要写进 WP2 规则，建议在 runner 层区分「基础设施重试」和「产品失败」。
- **1.5 覆盖不足**：建议新增一个「用户问是否有线程/频道/`reply_to`」或「模拟多串」的 scenario，再单独
  消融 `1.5`。当前证据只能说明「删掉整组后没有场景因此单独退步」，不能说明 `1.5` 无用。
- **只跑了 3 次/场景、单轮**；模型有随机性。E01 的大小写、E05 的工具选择都只出现了一部分 repeat。
  结论按任务规则取实际 gate 结果，不做统计外推。
- **未验证**：iOS 真机/模拟器、真实 App、英文 runtime persona（profile 只存中文；英文模板只通过
  `assemblePrompt`/测试验证）、E08。

## 9. 变体复现（本分支最终已回滚）

本报告结论是保留，所以工作树在跑完后把四份文件恢复到了 `HEAD`，只保留本报告；这样合入时不会误删
有用的规则。消融变体本身可这样复现：

1. 从两份模板删除 §1 表中的六段（中英文各三节，含各自的 `<!-- mount: ... -->` / `<!-- tools: ... -->` 行）。
2. 用 `assemblePrompt()` 重新生成中文 persona，按 6 空格缩进写回 profile 的 `personaPrefix: |` 段。
3. 从 `plugins/tests/bot-persona.test.ts` 的期望标题清单删掉四个标题（中英文各两个）。
4. 按 §3 的命令重建 bundle 并跑评测。变体 diff 的临时副本留在 `/tmp/s1-wp7-a-tools/variant.diff`
   （不属于仓库产物），主跑证据在 `/tmp/s1-wp7-a`，E06 重跑证据在 `/tmp/s1-wp7-a-e06-rerun`。

## 10. 交接证据（AGENTS.md §3.5）

- **Base / head**：`871488cfe` / 工作树 `8343a7202` + 本报告（未 commit、未 push）。
- **Protocol impact**：P26（persona 内容变更）。本单元没有触碰 wire、WAL、bridge、gateway、Worker URL
  参数、原生 ABI 或 `spec/**`。
- **Contract revision**：不适用（没有改 `spec/**`）。
- **Changed files**：`docs/research/bot-persona-ablation-a-20261111.md`（新增；消融变体已回滚）。
- **Status per end**：TS persona/profile/test 已恢复为 `HEAD`；Swift/App/Android 未改。
- **Commands → result**：
  - `node plugins/bot-runtime/scripts/check-prompt.mjs` → PASS（变体态）
  - `node --test plugins/tests/bot-persona.test.ts` → PASS 5/5（变体态）
  - `PDSH_DSH_CHECKOUT=/private/tmp/dsh-0.2.2 node plugins/scripts/profile.test.mjs` → PASS 11/11（变体态）
  - `bash scripts/ci/check.sh --only phone-bundle-fresh` → PASS 6/6 fresh（变体态重建后）
  - `bash scripts/ci/bot-e2e/eval.sh ... --upstream real --repeat 3` → FAIL（E01、E05、E06；E08 未跑）
  - `bash scripts/ci/bot-e2e/eval.sh --only BOT-E06 ...` → PASS 3/3（E06 重跑）
  - `(cd plugins && npm run typecheck)` → PASS（tsc 退出 0）
  - `bash scripts/ci/check.sh --only phone-plugins` → INCOMPLETE：完整 plugins 测试套件在本机挂起超过
    1 小时、无输出后终止；定向的 persona/profile 测试和 typecheck 已单独通过，不把挂起算作 PASS。
  - **回滚后复验**：`check-prompt.mjs` → PASS（zh 10,671 / en 26,544，25 节）；`bot-persona.test.ts` →
    PASS 5/5；`phone-bundle-fresh` → PASS 6/6；`profile.test.mjs`（带 pinned checkout）→ PASS 11/11。
- **Not verified**：真机、模拟器、真实 App、英文 runtime、E08。
- **Remaining risks**：E01 断言大小写、E05 已知审批 bug、E06 上游 10 秒超时、1.5 无场景覆盖。
