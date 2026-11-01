# Axis 10 — 完备性反查（官方 session surface 全量清单）

先读 `docs/receipts/ios-session-audit/BRIEF.md` 全文，然后读 01–09 的报告：

- `01-data-path.md`
- `02-plan-todo.md`
- `03-questions.md`
- `04-subagent-inbox.md`
- `05-timeline.md`
- `06-tools.md`
- `07-content-actions.md`
- `08-composer.md`
- `09-tokens-pixels.md`

报告路径：`docs/receipts/ios-session-audit/10-completeness.md`

## 目标

你是“反查者”。任务不是重复写一遍审计，而是**独立建立官方 session 会话线的全量 surface 清单**，再对照 01–09，找出漏项、重复、冲突、覆盖不足，确保“完整的 check 清楚”。用户特别担心“深藏在官方消息流里、只有被调起才显示的控件”被漏掉。

## 必须做

### A. 以 shipped composition 为准

1. 先确认官方 **实际随 Web app 发布的** session UI 插件清单：`packages/bundle/web-app/package.json`、`packages/bundle/web-app/presets/*.patch.yml`、`packages/bundle/web-app/src/index.ts`、`apps/web/src/*`。不要把所有 experimental 包都算进基线；如果某个 surface 只在 experimental/agent-team 等未随 Web app 发布的包里，单独标注。
2. 同时检查 phone-dsh 自己的 `plugins/` 是否给官方 Web bundle 追加了 session UI（`plugins/bundle`、`plugins/surface-phone`、`scripts/ci/build-web-dist.sh`），如果有，标注“phone 定制”而非官方基线。

### B. 全量清单（独立 grep，不依赖报告）

按以下维度建立 master checklist，每项给官方注册点 `file:line`：

1. `conversation.chat.node` 的所有 key（含 ui-chat 之外包的注册，例如 `submitted-plan`、`question-reply`、`workflow-run`、goal 的 command input 等）。
2. `conversation.chat.turnTail` 的所有贡献（deliverables、plan preview、schedule-created、test-file-deliveries 等）。
3. `conversation.input.dock`（goal/queue/todo/…）、`conversation.composer.dock`（activity/usage/…）、`conversation.input.overlay`（command-popup/slash-menu/feedback-dialog/…）。
4. `conversation.composer` 的接管者（question composer、subagent read-only composer 等）。
5. `conversation.session.header.{lineage,actions,utilities,corner}` 的所有贡献；`conversation.session` 的视图切换。
6. `tool.call.toolview` 的所有 key（官方全量，约 51 个；以 grep 结果为准）。
7. `conversation.chat.reasoning.body`、`conversation.chat.reasoning.content`、`conversation.chat.message.images`、`conversation.chat.user.images`、`conversation.chat.commandview`、`conversation.chat.assistant-actions` 等子槽。
8. session 页可见的 projection：`todos`、`plan`、`inbox`、`goal`、`turnOutline`、`subagent`、`context` 等。
9. `session/header` 的 mobile 特化（`ui-mobile`、`ui-session`、`ui-sidebar` 手机行为）。
10. 其他条件 surface：image viewer/lightbox、feedback dialog、approval panel、permission request、MCP elicitation、deliverable preview、workflow run、schedule card、job list、agent preset、session tabs、context meter、quota notice、installed/PWA 提示等（只列与 session 会话页直接相关的）。

对每一项标注：
- 是否在 01–09 中被覆盖（报告编号 + 章节/ID）
- 覆盖质量：完整 / 部分 / 只提名字 / 未提
- 是否 P0/P1（按 BRIEF 严重度）
- 备注：官方是否手机端隐藏/迁移、是否需要产品决策

### C. 反查报告

1. **漏项清单**：官方有、01–09 完全没提的 session surface，按用户可见影响排序；每项给官方 `file:line` + 应该由哪个轴补 + 建议的验收。
2. **覆盖不足清单**：报告提到了但没有像素规格/状态机/数据来源的项。
3. **冲突清单**：两个报告对同一事实说法不一致（例如某控件是否存在、某事件是否被映射、某尺寸是多少），指出哪个更可信、需要谁复核。
4. **重复清单**：多份报告重复覆盖同一 surface（可接受，但要指出主报告，避免实现时重复劳动）。
5. **“只有被调起才显示”专项**：单独一张表，列出所有条件 surface 的触发条件、官方出现位置、iOS 是否有、用户如何触发、如果没有入口用户是否永远看不到。
6. **最终 master checklist**：按实现 wave 分组（P0 基础、P1 视觉/交互、P2 细节），每项一行，便于后续排期。

### D. 质量要求

- 你的价值在“找到别人漏掉的”，不要复述报告。
- 每个“未覆盖”结论必须给出你独立 grep 的证据（命令 + 结果）。
- 对官方 shipped composition 的判断要给出 `package.json`/preset 证据；不要把实验包当 shipped。
- 不要改源码；只写 `10-completeness.md`。

完成后按 BRIEF 的 JSON schema 返回：`axis` 用 `10-completeness`，`top_gaps` 放最关键的漏项（最多 8 条），`hidden_surfaces_missing` 放所有漏掉的隐藏 surface 名称，`data_gaps`/`unknowns` 按需。
