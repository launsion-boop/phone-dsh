WP7-b: 改写
<!-- SPDX-License-Identifier: MIT -->

# WP7 persona 消融：组 b「卡片与决策」（2026-11-11）

## 0. 结论

**组级：改写。** 本组不是一块同质的规则，拆开后的结论不同：

| 范围 | 结论 | 依据 |
| --- | --- | --- |
| 1.3 文件与视觉内容 | **删除** | 7 个 WP2 场景没有一个触发附件/图片/图表/链接卡；卸载后没有场景退步，也没有可观测的回复形态变化，且不属于安全边界。 |
| 1.4 请求用户决策 | **保留，场景覆盖不足** | 7 个场景里基线唯一一张提问卡（E01 repeat 2）在卸载后变成 93 字正文问句，卡片 1→0；WP2 没有任何 `card.presented` / 卡片数量 / 回合结束断言，无法用退步与否证明它有增益。 |
| 手机工具与回合边界里的卡片条目（ask_user / show_next_steps；内容卡数量与位置） | **保留** | 与 1.4 同组；`ask_user` / `show_next_steps` 的“卡片结束回合”语义只有这一条，不在别处重复。内容卡“最多两张、放在正文之后”与 1.4 重复，可后续去重，但不单独删除。 |

因此推荐的最终 persona 是：删掉 1.3，恢复 1.4 和手机工具里的卡片条目；先补卡片场景（§8），再判断 1.4 是否还有必要整段保留。

**工作区状态：** 本分支当前保留的是本次消融的**全组卸载变体**（1.3 + 1.4 + 卡片条目都删掉），也就是实际跑过真实模型的那一份；它不是“改写”后的最终状态。集成时若要按本结论合入，需要从 `git show HEAD:plugins/bot-runtime/prompts/system-prompt{,.zh-CN}.md` 恢复 1.4 与 `ask_user` / `show_next_steps` 条目，再重新生成 `personaPrefix`。这也是本单元只能给出“改写”而不是直接合入的原因。

## 1. 实验设置

- 基线：`871488cfe`（`origin/main`）+ WP2 场景目录 `8343a7202`。工作树：`dsh-work/s1-wp7-b`，分支 `s1/wp7-ablation-b`，没有 commit。
- 场景：`BOT-E01`…`BOT-E07`，各 3 次；按任务说明不跑 E08（已知生产 bug：`agent.comm` 出站事件缺失）。
- 上游：真实模型 `deepseek-flash`（`api.deepseek.com`），`--upstream real`，`--repeat 3`。凭据只通过任务给定的 `scripts/ci/model-env.mjs` 导入；没有打印、记录或写入 key。实际产物里也没有出现 key 字符串（对 `/tmp/s1-wp7-b` 做了逐字节检查）。
- 环境：macOS 26.0（arm64），Node 24.9.0，Swift 6.3.2 / Xcode 26.5，`PDSH_DSH_CHECKOUT=/private/tmp/dsh-0.2.2`。
- 结果目录：`/tmp/s1-wp7-b`（保留）；批门 `summary.md` 为 **PASS**（7/7 场景 gate PASS）。
- 请求上限：目录声明 `273 min / 660 requests`（7 场景 × 3 次 × 各自预算之和 220/次）。**实际用掉 200 次模型请求**（另外 bundle 构建和 Swift 编译不计入模型请求）。

## 2. 卸掉的段落（原文与位置）

行号取 `HEAD` 版本（`git show HEAD:<file>`）；中英文一一对应。删除方式是把段落从模板里删掉（没有新增 `mount` 条件；现有 `mount` 只支持 `engine/platform/lang/variant` 四个键，加新键要改 `markup.ts`，不在本单元允许的修改范围内）。

### 2.1 「手机工具与回合边界」/「Phone tools and turn boundaries」

| 位置 | 中文原文（首句） | English original（first sentence） |
| --- | --- | --- |
| zh:15 / en:15 | 整条：**需要用户选择时用 `mcp__phone__ask_user`；给可点选的下一步用 `mcp__phone__show_next_steps`。** 两者成功后会结束回合：立刻停下，不再输出文字、调用 SendToUser 或其他工具，等用户选择。宿主也会抑制这些卡片后的收尾文字。 | Whole bullet: **Use `mcp__phone__ask_user` for a real user decision and `mcp__phone__show_next_steps` for tappable next actions.** Either card ENDS the turn: stop immediately with no more text, SendToUser, or tools. The host suppresses wrap-up text after these cards. |
| zh:16 / en:16 | 该条后半句：**内容卡不结束回合，一回合最多两张，放在正文结论之后。** 相同 cardKey 的 progress 会更新同一张卡。（同条前半句“文件用 show_attachment / 文档用 show_document / 进度 / 清单 / 链接”保留，属于工具面映射，不是卡片数量/位置规则。） | The second sentence of the bullet: **Content cards do not end the turn; at most two, after the prose conclusion.** The same progress cardKey updates one card. (The file/document/progress/checklist/link mapping earlier in the same bullet was kept.) |

### 2.2 1.3 文件与视觉内容 / 1.3 Files and visuals

| 位置 | 中文原文（首句） | English original（first sentence） |
| --- | --- | --- |
| zh:56 / en:56 | **## 1.3 文件与视觉内容** — **截图、图片、图表、示意图或文件能表达得比文字更多时，就附上；琐碎步骤之后不要附噪声内容。** | **## 1.3 Files and visuals** — **Attach a screenshot, image, chart, diagram or file when it shows more than text would; skip noise after trivial steps.** |
| zh:60 / en:60 | **要附文件或图片，用 `mcp__phone__show_attachment` 并传工作区里的绝对路径；** 卡片会把文件呈现给用户。路径要来自真实工具结果，绝不自行编造。文档用 `mcp__phone__show_document`。 | **To attach a file or image, use `mcp__phone__show_attachment` with an absolute path in the workspace;** the card presents it to the user. Paths must come from a real tool result; never invent one. Use `mcp__phone__show_document` for documents. |
| zh:61 / en:61 | **用户可能打开、购买或比较的东西，链接到它们的页面通常比截图更好，因为截图点不动。** 截图留给「页面状态本身就是重点」的场景；这个宿主没有截图工具，不要声称截了屏。 | **For things the user may open, buy, or compare, links to their pages usually beat screenshots, which cannot be clicked.** Keep screenshots for when the state of a page is the point; this host has no screenshot tool, so never claim to have taken one. |
| zh:62 / en:62 | **不要声称你生成了图片、插画或照片。** 这个宿主没有图像生成能力；用户要视觉内容时，如实说明，并给出可行替代：找一张已有图片、用 bash 生成图表或 SVG，或请用户提供素材。 | **Never claim you generated an image, illustration or photo.** This host has no image-generation capability; when the user wants a visual, say so plainly and offer a real alternative: find an existing image, generate a chart or SVG with bash, or ask the user for the material. |
| zh:63 / en:63 | **网页图片先下载到工作区，再用绝对路径附件；不要让客户端去加载远程 URL。** 绝不用图片描绘真实的人或物。 | **Download web images to the workspace and attach the file instead of making the client load a remote URL.** Never depict a real person or thing with an image you made up. |

整节连同它的 `<!-- mount: always -->`、`<!-- tools: show_attachment, show_document, bash -->` 标记一起删除。

### 2.3 1.4 请求用户决策 / 1.4 Asking for decisions

| 位置 | 中文原文（首句） | English original（first sentence） |
| --- | --- | --- |
| zh:67 / en:67 | **## 1.4 请求用户决策** — **默认自己决策并推进。只有真实取舍、需要点头的有后果操作，或动手前需要批准的计划才出卡。** 只问一个自然问题，给 2–4 个真实选项；…… | **## 1.4 Asking for decisions** — **Decide and proceed by default. Use a card only for a real choice, a consequential action needing assent, or a plan requiring approval.** Ask one natural question with 2–4 real options whose values read like the user's reply. … |
| zh:71 / en:71 | **内容卡（progress / checklist / link）不是答案，是让用户扫读的结构：先把结论写进正文，再把卡放在回复最后。** 一回合最多两张内容卡；需要第三张就说明卡片过量，改写进正文。 | **Content cards (progress / checklist / link) are not the answer: put the conclusion in prose first, then the card at the end.** At most two content cards per turn; a third means you are over-carding — fold it into prose. |
| zh:72 / en:72 | **回复结尾若包含建议、下一步或可选项，正文只写结论和一句理由，然后用 `mcp__phone__show_next_steps` 或 `mcp__phone__ask_user` 呈现，不要把建议写成正文列表后结束。** | **If your reply ends with recommendations, next steps, or choices, keep prose to the conclusion and one reason, then present them with `mcp__phone__show_next_steps` or `mcp__phone__ask_user`; do not end with a prose list of suggestions.** |
| zh:73 / en:73 | **完成报告且没有需要用户决定的事项时，正文回答即可，不要为了有卡硬造卡片。** | **When a finished report has no decision for the user, answer in prose and do not manufacture a card.** |
| zh:75 / en:75 | **硬规则：回复里只要是在请用户做选择，就必须用卡片。** 如果你正要写「要我……吗？」「要不要先……」「选哪一个？」这类带离散选项的问句，不要把它写进正文，改用 `mcp__phone__ask_user`，把原本要写的选项做成按钮。写完卡片就停。 | **Hard rule: when your reply would ASK the user to choose, use the card.** If you are about to write "Should I…?", "Do you want me to… first?", or "Which one?" with discrete options, do not ask it in prose. Call `mcp__phone__ask_user` and turn those options into buttons. Stop after the card. |

整节连同 `<!-- tools: ask_user, show_next_steps -->` 标记一起删除。**没有**删除 1.4 之外的其他段落（1.1 回合流程、1.11 自主性、1.12 审批、1.17 委派等全部保持原样）。

## 3. 变体生成与 bundle 链路

1. 删除上述段落后按 `assemblePrompt()`（zh、platform=ios、无 variant）重新生成 `plugins/profile/phone.worker.cordis.patch.yml` 的 `personaPrefix`；zh persona 从 10,671 字符降到 9,432 字符（−1,239），profile 里的块与组装结果逐字节一致。
2. `plugins/tests/bot-persona.test.ts` 的期望同步：从章节清单去掉 `文件与视觉内容` / `Files and visuals`；“每个 P0 工具都要在正文里教到”的循环排除 `ask_user` / `show_next_steps`（它们仍然出现在 `mount.tools` 声明里；`show_attachment` 原本就排除）。没有放宽其他断言。
3. 重建 `examples/probe-app/Bundle/worker`：
   - `node plugins/worker-entry/build.mjs --out examples/probe-app/Bundle/worker` → exit 0；
   - `PDSH_DSH_CHECKOUT=/private/tmp/dsh-0.2.2 node plugins/scripts/pack-image.mjs --out examples/probe-app/Bundle/worker` → exit 0；
   - `bash scripts/ci/check.sh --only phone-bundle-fresh` → **PASS**（6 fresh / 0 stale / 0 absent）。
4. 确认评测实际用的是新 bundle：`eval.sh` 在 `PDSH_DSH_WWW/PDSH_DSH_IMAGE` 未设置时，按 `plugins/**` 源码哈希在 `PDSH_BOT_EVAL_BUILD_DIR` 里重建；本次先删掉 `/tmp/s1-wp7-b-build`，`/tmp/s1-wp7-b/bundle.log` 记录的是 `packing the Worker bundle under /tmp/s1-wp7-b-build`（不是 `reusing`），说明评测重新打包。随后从 `/tmp/s1-wp7-b-build/www/image.tar.gz` 解出 `home/cordis.patch.yml` 核对：包含 `## 手机工具与回合边界`、`## 1.5 单一聊天线程`；不包含 `1.3 文件与视觉内容`、`1.4 请求用户决策`、`需要用户选择时用`、`内容卡不结束回合`。即模型实际拿到的系统提示是卸载后的版本。

## 4. 逐场景对比

基线与消融各 3 次。失败断言一栏只列非 PASS 的 repeat。

| 场景 | 基线通过 | 消融通过 | 基线失败断言 | 消融失败断言 | 基线请求 | 消融请求 | 基线 wall | 消融 wall |
| --- | ---: | ---: | --- | --- | ---: | ---: | ---: | ---: |
| BOT-E01 | 3/3 | 3/3 | — | — | 46 | 40 | 142.9 s | 127.8 s |
| BOT-E02 | 3/3 | 3/3 | — | — | 31 | 30 | 83.7 s | 81.8 s |
| BOT-E03 | 3/3 | 3/3 | — | — | 15 | 14 | 33.6 s | 32.4 s |
| BOT-E04 | 3/3 | 3/3 | — | — | 47 | 48 | 103.9 s | 99.4 s |
| BOT-E05 | 1/3 | **3/3** | repeat 2/3：`approval_count` = 3，期望 1 | — | 26 | 22 | 55.5 s | 41.3 s |
| BOT-E06 | 3/3 | 3/3 | — | — | 27 | 28 | 71.5 s | 68.8 s |
| BOT-E07 | 3/3 | 3/3 | — | — | 18 | 18 | 36.8 s | 39.0 s |
| **合计** | **18/21** | **21/21** | 2 个失败 repeat | 0 | **210** | **200** | 527.9 s | 490.6 s |

消融后每次 repeat 的请求数：

| 场景 | repeat 1 | repeat 2 | repeat 3 |
| --- | ---: | ---: | ---: |
| BOT-E01 | 16 | 14 | 10 |
| BOT-E02 | 10 | 10 | 10 |
| BOT-E03 | 4 | 5 | 5 |
| BOT-E04 | 16 | 16 | 16 |
| BOT-E05 | 7 | 8 | 7 |
| BOT-E06 | 9 | 10 | 9 |
| BOT-E07 | 6 | 6 | 6 |

**规则判定：** 基线 3/3 的 E01、E02、E03、E04、E06、E07 全部仍为 3/3；E05 从 1/3 升到 3/3，没有下降。按“基线 3/3 必须仍 3/3、部分通过不得下降”的规则，场景层面**没有退步**。

E05 的 1/3→3/3 不应算作本组的增益。查看事件可见原因是工具选择差异：基线 repeat 2/3 用 `write` 改本地文件，每次 repeat 产生 2 个 `write` 审批 + 1 个 `curl` 审批 = 3；消融后三个 repeat 的本地文件都用 `bash` 写（`printf > notes/...`），只剩 `curl` 的 1 个审批。1.12“普通工作区写入不要 RequestApproval”和审批闸门都没动，这更像模型采样路径的波动，而不是卡片组规则的结果。报告中按“没有退步”计，但不当作收益。

## 5. 回复形态的数字

从每个场景每个 repeat 的 `transcript.jsonl` / `bot-events.jsonl` 取用户可见的 `conversation.assistant_message` 全文（用 transcript 的 sha256 对齐事件正文；52 条对 52 条，全部匹配），统计：

| 指标 | 基线 | 消融 | 变化 |
| --- | ---: | ---: | --- |
| 可见回复条数 | 52 | 52 | 0 |
| 字符数中位数 | 37.0 | **28.5** | **−23%** |
| 字符数平均值 | 48.8 | 40.7 | −16.6% |
| 总字符数 | 2,536 | 2,116 | −16.6% |
| 最长回复 | 355 | 329 | −26 |
| >90 字的回复 | 6 | 5 | −1 |
| markdown 列表行总数 | 0 | 0 | 0 |
| 含 ≥2 个列表项的回复 | 0 | 0 | 0 |
| 多行回复（含换行） | 2 | 2 | 0（都在 E03，段落换行，不是列表） |
| `card.presented` 总数 | 1 | **0** | −1 |
| 其中内容卡（progress/checklist/link 等） | 0 | 0 | 0 |
| 以问号结尾的正文回复 | 0 | **1** | +1 |

逐场景：

| 场景 | 中位数字符 | 最长字符 | 卡片数 | 列表行 | 备注 |
| --- | --- | --- | --- | --- | --- |
| BOT-E01 | 20.0 → 6.0 | 150 → 93 | 1 → 0 | 0 → 0 | 基线 repeat 2 的 `ask_user` 提问卡（3 个选项）消失；消融 repeat 2 在第 2 回合用 93 字正文问“还要继续吗？” |
| BOT-E02 | 34.5 → 31.5 | 63 → 52 | 0 → 0 | 0 → 0 | — |
| BOT-E03 | 166.0 → 280.0 | 355 → 329 | 0 → 0 | 0 → 0 | 中位数上升是回复条数 4→3 的假象：基线 repeat 1 多一条 21 字开场确认；三段概括本身是 355/152/180 对 180/280/329，最长反而下降 |
| BOT-E04 | 70.5 → 47.0 | 105 → 93 | 0 → 0 | 0 → 0 | — |
| BOT-E05 | 61.5 → 23.0 | 90 → 52 | 0 → 0 | 0 → 0 | 本地完成回复 69/70/4 字 → 3/3/3 字（用户要求“只回一句完成”）；网络拒绝解释 45/90/54 → 52/43/43 |
| BOT-E06 | 6.0 → 6.0 | 6 → 16 | 0 → 0 | 0 → 0 | 消融 repeat 2 多一条 16 字进度“正在派一个子代理去试，等它结果。” |
| BOT-E07 | 22.0 → 21.5 | 42 → 38 | 0 → 0 | 0 → 0 | — |

**形态判读：** 没有出现长列表（两边都是 0 个列表行），没有把建议写成正文列表，也没有多发内容卡（内容卡 0→0，提问卡 1→0）。长度整体变短（中位数 −23%）。唯一的反向信号是 E01：基线用提问卡给出 3 个带说明的选项，消融后变成一句 93 字的正文问句，选项信息丢失；这正是 1.4 的覆盖点，但 3 个 repeat 里只出现 1 次，且没有长列表或内容卡增加，所以判为“可见的形态变化，尚不足以量化成整体形态变差”。

## 6. 结论与理由

1. **1.3 删除。** 7 个场景没有一个会产出文件/图片/图表/链接卡，卸载前后看不出任何差别；它也不是审批、凭据、不可信内容那样的安全边界。按本单元“没有场景退步且形态没有明显变化”的删除标准，可以删。注意这是“没有覆盖”而不是“被证明无用”；如果产品要保留“文件能表达更多时附上”的行为，应先补 §8 的文件场景再单独评估。
2. **1.4 保留，场景覆盖不足。** 基线唯一一张提问卡在消融后变成正文问句，说明这条规则确实在改变行为；WP2 只断言结果（回忆、记忆、文件、审批数、静默、任务状态），没有任何场景断言“问选择必须出卡”“回合在卡后结束”“内容卡数量/位置”。因此不能用“场景全部通过”证明 1.4 没有增益，也不能用“形态没变差”证明它可以删。按任务给出的规则，这种情况写“保留，场景覆盖不足”。
3. **手机工具里的卡片条目随 1.4 保留。** `ask_user` / `show_next_steps` 的“卡片结束回合、宿主抑制收尾文字”是 1.4 之外唯一的一处；`内容卡不结束回合 / 同 cardKey 更新同一张卡` 也是唯一的一处。与 1.4 重复的“最多两张、放在正文之后”可以在后续改写中去重，但不应在本单元单独删掉。
4. **不建议把本组的全量删除作为最终状态。** 场景 21/21 通过只能说明这七个结果型场景不依赖卡片组；它不能覆盖卡片的交互价值。E05 的 1/3→3/3 已确认是 `bash` vs `write` 的工具选择差异，不是卡片组的功劳，也不能反过来当作保留的证据。

## 7. 请求数

- 消融运行：**200 次模型请求**（`/tmp/s1-wp7-b/*/report.json` 的 `usage.model_requests` 求和：40+30+14+48+22+28+18）。
- 基线：210 次（46+31+15+47+26+27+18），来自 `/tmp/s1-baseline/lane-*/BOT-E0*/report.json`。
- 计划上限：660 次 / 273 分钟（`/tmp/s1-wp7-b/.plan.json`），本次用了 30.3% 的请求上限；E08 按任务说明没有运行。
- 模型 wall 时间合计 490.6 s；另有 Worker bundle 重建（build.mjs + pack-image.mjs）和 SwiftPM 编译，不计入模型请求。

## 8. 建议补的场景

如果按“1.4 保留”处理，先补下面这些场景再决定它是否能删：

1. **决策卡（优先级最高）**：用户给出 2–4 个离散选项让 Bot 选（例如“周五团建去 A 还是 B？”）。断言：出现 `card.presented` 且 `cardType` 为 `question`/`steps`；选项 2–4 个；最多一个 `recommended`，没有 `danger` 推荐；正文不出现带选项的问句或选项列表；卡片后不再有正文（回合结束）；再用 `ui_action card_answer` 驱动一次真实回合。这个场景在消融变体上应当失败。
2. **内容卡数量与位置**：一个多步骤任务自然产生 progress/checklist。断言：一回合最多 2 张内容卡；卡在正文结论之后；第 3 张改写成正文；routine 隐藏回合不出卡（现有 E04 只断言 `[quiet]` 和 `routine.run_finished`，不覆盖卡片）。
3. **文件/视觉卡（给 1.3 补覆盖）**：让 Bot 生成一个图表/文件并附上。断言：`card.presented` 的附件/文档卡带工作区绝对路径；路径来自真实工具结果；没有声称生成图片或截图；远程 URL 不被客户端加载。这个场景同时也是 1.3 删除决定的复核条件。
4. （可选）在 E01 的提问回合加一条宽松的卡片断言（例如“若出现卡片，cardType 必须是 question 且选项 2–4 个”），但 E01 的提问是模型自发的，不能要求每次都出卡；更适合放到专用场景。

## 9. 验证记录

| 命令 | 结果 |
| --- | --- |
| `node plugins/bot-runtime/scripts/check-prompt.mjs` | **PASS**：`ok: true`，P0 工具齐全，P1 为空；中英文三变体都组装成功 |
| `node --test plugins/tests/bot-persona.test.ts` | **PASS**：5/5 |
| `node --test plugins/tests/bot-team-persona.test.ts plugins/tests/bot-tool-surface.test.ts` | **PASS**：5/5 |
| `node plugins/worker-entry/build.mjs --out examples/probe-app/Bundle/worker` | **PASS**：exit 0 |
| `PDSH_DSH_CHECKOUT=/private/tmp/dsh-0.2.2 node plugins/scripts/pack-image.mjs --out examples/probe-app/Bundle/worker` | **PASS**：exit 0 |
| `bash scripts/ci/check.sh --only phone-bundle-fresh` | **PASS**：6 fresh / 0 stale / 0 absent |
| `bash scripts/ci/check.sh --only phone-plugins` | **INCOMPLETE**：`tsc` 通过；`npm test` 两次都在同一位置停止输出（约 1,310 个用例通过后、wasi/python 用例尾部），未得到最终汇总；persona 相关的 3 个测试文件已单独跑通；详见 §9.1。 |
| `bash scripts/ci/bot-e2e/eval.sh --catalog scripts/ci/bot-e2e/catalog.json --only BOT-E01,…,BOT-E07 --upstream real --repeat 3 --results /tmp/s1-wp7-b` | **PASS**：gate PASS，7/7 场景 PASS，3/3 repeat，200 请求 |

### 9.1 phone-plugins 的未完成项

`phone-plugins` 的 typecheck 通过。`npm test` 的第一次运行在约 1,000 个用例后不再产生输出（当时并行的 eval/Swift 已结束，仍无进展），终止；第二次把输出重定向到 `/tmp/s1-wp7-b-plugins.log` 重跑，仍然在**同一位置**停住（日志显示 1,310 个通过用例，最后是 `wasi-toolbox` 的 python 用例），至少 6 分钟无新输出后终止；`npm test` 的最终汇总未取得。两次运行都记录了 `bot-egress-spike` 的两个 `{ todo: 'WP3: ...' }` 已知失败用例，属于预期 todo，不是本改动引入的失败。

这个停滞没有定位到与 persona 改动相关的用例：`bot-persona`、`bot-team-persona`、`bot-tool-surface` 三个测试文件单独运行都通过，`check-prompt.mjs` 通过。停滞点与 persona 无关（两次都停在 wasi/python 尾部，且第一次是在 bundle 重建之前启动的）。为了不把停滞扩大成结论，本次**不把 `phone-plugins` 记为 PASS**；建议在干净环境里单独跑一次 `bash scripts/ci/check.sh --only phone-plugins` 再合入。

## 10. 分支改动清单

- `plugins/bot-runtime/prompts/system-prompt.zh-CN.md`：删除 §2 列出的手机工具卡片条目、1.3、1.4。
- `plugins/bot-runtime/prompts/system-prompt.md`：同上英文版。
- `plugins/profile/phone.worker.cordis.patch.yml`：仅 `personaPrefix` 段，按 `assemblePrompt()` 重新生成。
- `plugins/tests/bot-persona.test.ts`：同步章节清单，并把 `ask_user` / `show_next_steps` 从“正文必须教到”的循环中排除（它们的 `mount.tools` 声明仍然断言）。
- `docs/research/bot-persona-ablation-b-20261111.md`：本报告。

未改：`assemble.ts`、`markup.ts`、其他 persona 段落、Swift、catalog、fixture。

## 11. 交接给集成者

- 本分支的 diff 是**实验处理**（全组卸载），不是推荐合入状态。按 §0 的“改写”结论，合入前应恢复 1.4 和手机工具里的卡片条目（原文在 `HEAD`），只保留 1.3 的删除；然后按 WP7 的验收在集成分支上重跑 E01–E08 各 3 次。
- 如果决定“1.4 也删”，那就等于把“决策卡”交给模型自由发挥；本次 E01 的证据表明模型会改用正文问句。这个产品取舍应显式记录，而不是用“场景 21/21 通过”掩盖。
- 真实模型结果目录 `/tmp/s1-wp7-b` 保留；bundle 缓存 `/tmp/s1-wp7-b-build`、Swift 构建 `/tmp/s1-wp7-b-scratch`、SPM 缓存 `/tmp/s1-wp7-b-spm` 也在，便于复核。

## 12. 最终合入状态

**状态：完成（WP7-b-FINAL: 完成）。** §0 的「工作区状态」描述的是消融实验时的全组卸载变体；本轮已把它恢复成推荐的「只删 1.3」状态，改动留在工作区，未 commit。基线仍为 `871488cfe`，HEAD 为 `8343a7202`。

### 12.1 删了什么、为什么

- 只删除 `## 1.3 文件与视觉内容` / `## 1.3 Files and visuals` 整节，连同它的 `<!-- mount: always -->` 和 `<!-- tools: show_attachment, show_document, bash -->` 两行标记。1.4、`ask_user` / `show_next_steps` 条目、内容卡「最多两张、放在正文之后」那句都保留。
- 理由：7 个 WP2 场景没有一个产出附件/图片/图表/链接卡；整组卸载后场景通过数从基线 18/21 到 21/21，没有退步（E05 的 1/3→3/3 是 `write` 与 `bash` 的工具选择差异，不是卡片组的收益）；符合宪法第一条「去掉机制只需评估不退步」。这是「无场景覆盖」下的删除，不是「已证明无用」；若产品要保留该行为，应先补 §8 的文件/视觉场景再单独评估。

### 12.2 工具覆盖检查

1.3 的 `tools` 标记声明了 `show_attachment, show_document, bash`。删除后逐一核对：

- `show_attachment` / `show_document` 仍出现在「手机工具与回合边界」的文件卡条目里（`system-prompt.zh-CN.md:16` / `system-prompt.md:16`），`bash` 仍在 1.12、1.17、1.23 等段落出现。
- `check-prompt.mjs` 通过（P0 工具齐全、P1 为空）；用 `assemblePrompt()` 逐语言核对 `PHONE_P0_TOOLS`，`untaught=[]`（zh、en 都是 0）。
- `bot-persona.test.ts` 里原有的 `show_attachment` 单独排除未改动，`show_document` 仍按正文包含断言通过。

因此 1.3 **不是** `show_attachment` / `show_document` 在 persona 里的唯一提及处，没有把最小说明并入文件卡条目，也没有新增/放宽任何断言。

### 12.3 保留了什么

- **1.4 请求用户决策 / Asking for decisions** 整节保留，包括硬规则。理由：E01 的提问卡在卸载后变成正文问句（3 个 repeat 里 1 次），说明规则在改变行为；WP2 没有 `card.presented` / 选项数 / 回合结束断言，无法用「场景全过」证明它没有增益。先补场景，再决定是否整段删除。
- **手机工具里的 `ask_user` / `show_next_steps` 条目保留。** 「卡片结束回合、宿主抑制收尾文字」只有这一处；`内容卡不结束回合 / 同 cardKey 更新同一张卡` 也只有这一处。
- **内容卡「一回合最多两张、放在正文结论之后」保留。** 它与 1.4 有重复，可以在后续改写中去重，但本单元不单独删。

### 12.4 最终 diff 摘要

| 文件 | 最终 diff |
| --- | --- |
| `plugins/bot-runtime/prompts/system-prompt.zh-CN.md` | −11 行 / **−482 字符**；组装后 zh persona **10,671 → 10,265（−406 字符）** |
| `plugins/bot-runtime/prompts/system-prompt.md` | −11 行 / **−1,160 字符**；组装后 en persona **26,544 → 25,460（−1,084 字符）** |
| `plugins/profile/phone.worker.cordis.patch.yml` | 仅 `personaPrefix`，−9 行、0 新增；与 `assemblePrompt({ lang: 'zh' })` 逐字节一致 |
| `plugins/tests/bot-persona.test.ts` | 章节清单只去掉 `文件与视觉内容` / `Files and visuals`，其余断言未动 |

说明：`git checkout HEAD -- <四个文件>` 在本会话被沙箱拒绝（`index.lock: Operation not permitted`），改用 `git show HEAD:<path> > <path>` 恢复；恢复后 `git status` 只剩本报告未跟踪，四个文件与 HEAD 一致，再做上述删除。

### 12.5 验证结果

| 命令 | 结果 |
| --- | --- |
| `node plugins/bot-runtime/scripts/check-prompt.mjs` | **PASS**：`ok: true`，P0 齐全，P1 为空 |
| `cd plugins && npm run typecheck && node --test tests/bot-persona.test.ts tests/bot-team-persona.test.ts tests/bot-tool-surface.test.ts` | **PASS**：typecheck 通过；10/10 测试通过 |
| `node plugins/worker-entry/build.mjs --out examples/probe-app/Bundle/worker` | **PASS**：exit 0 |
| `PDSH_DSH_CHECKOUT=/private/tmp/dsh-0.2.2 node plugins/scripts/pack-image.mjs --out examples/probe-app/Bundle/worker` | **PASS**：exit 0；4,541 files，45,517,312 B raw，11,448,332 B gzip |
| `bash scripts/ci/check.sh --only phone-bundle-fresh,phone-license` | **PASS**：6 fresh / 0 stale / 0 absent；license PASS |
| `bash scripts/ci/bot-e2e/eval.sh --catalog scripts/ci/bot-e2e/selftest.json --results /tmp/s1-wp7-b-self` | **PASS**：`upstream: mock`，10/10 场景 gate PASS；结果目录按任务要求已删除 |

未验证：完整 `phone-plugins` 的 `npm test`（本单元只按要求跑了 typecheck + 三个 persona/tool-surface 测试文件）、真实模型 E2E、真机。没有使用真实模型或凭据。

### 12.6 建议补的场景

1. **决策卡**：2–4 个离散选项；断言 `card.presented` 的 cardType、选项数、最多一个 `recommended`、正文无选项问句、卡片后回合结束。
2. **内容卡数量与位置**：一回合最多 2 张、在正文之后、第三张改写进正文；routine 隐藏回合不出卡。
3. **文件/视觉卡**：生成文件/图表并附上；断言附件卡带工作区绝对路径、路径来自真实工具结果、不声称生成图片、不加载远程 URL。这个场景也是 1.3 删除决定的复核条件。
4. （可选）在 E01 的提问回合加一条宽松断言（若出现卡片，cardType 必须是 question 且选项 2–4 个），不要求每次必出卡。

### 12.7 建议提交信息

```
feat(bot-persona): drop files-and-visuals section (WP7-b)

Remove §1.3 Files and visuals / 文件与视觉内容 from both personas and the
generated personaPrefix. Keep §1.4, the ask_user/show_next_steps turn-boundary
bullet, and the content-card count/placement sentence.

Rebuild the Worker bundle. Persona chapter tests drop only 1.3.

Protocol impact: P26; P16: none — profile change is personaPrefix text only, no startup parameters or init frames.
```
