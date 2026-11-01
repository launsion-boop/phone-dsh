# 收口计划（2026-11-01）

> 依据：本轮评估的 4 项剩余工作。原则：**官方 golden 先做裁判；平台缺失只写决策，不伪装实现；Composer 只做可验证的小步。**

## 0. 文件所有权（并行不冲突）

| 工作流 | 所有者 | 允许改的文件 | 禁止 |
|---|---|---|---|
| A. 官方 402pt golden | 子 Agent A | `scripts/ios-parity/golden/**`、`docs/receipts/ios-session-audit/GOLDEN.md`、`docs/receipts/ios-session-audit/screens/official/**` | iOS 源码、ChatPage/ChatModel |
| B. Composer + 折叠时机 | 子 Agent B | `examples/probe-app/PhoneDSHProbe/ChatPage.swift`、`ChatModel.swift` | 其他源码、docs、project.yml |
| C. 平台决策记录 | 子 Agent C | 新建 `docs/receipts/ios-session-audit/DECISIONS.md` | 任何代码 |
| D. 集成/构建/验收 | 主 Agent | 全部（B 完成后） | 在 B 运行期间改 ChatPage/ChatModel |

## 1. 工作流 A：官方 402pt golden

**目标**：拿到至少一张官方 Web UI 的 402×874、DPR3 截图，证明/推翻当前 CSS 推导值；如果环境不能完成，交付可复现的 harness + 精确 blocker，不伪造官方图。

已知条件：
- 官方仓：`/Users/leilangsheng/Documents/Codex/2026-08-14/https-github-com-deepseek-ai-deepseek/deepseek-harness`
- `apps/web/dist` 已存在；静态 `python3 http.server` 会因缺少 `window.__ModuleLoader__` 启动失败。
- Node 已安装但未链接：`/opt/homebrew/Cellar/node@22/22.22.1_3/bin/node`（v22.22.1），`node@20` 也在。
- Chrome：`/Applications/Google Chrome.app/Contents/MacOS/Google Chrome`。
- `pnpm` 可用，`apps/web/node_modules` / 根 `node_modules` 已存在（2.0G）。

验收：
1. `scripts/ios-parity/golden/capture-official.sh` 能启动官方 UI（不是静态 dist 直出）。
2. 402×874、DPR3 截图至少一张：空态/hero 或 sample session 均可，必须标注实际状态。
3. `GOLDEN.md` 更新：官方截图路径、启动命令、已知限制（auth/session fixture）。
4. 若无法启动，`GOLDEN.md` 写清阻塞点 + 复现命令 + 建议（例如 `pnpm --filter ... dsh web` 的具体包名）。

## 2. 工作流 B：Composer + 折叠时机

### B1. pending submission 独立行（P2）

- 当前 `queueLine(for:)` 在用户消息下方显示“发送中…” + spinner，不是独立 pending 行。
- 目标：发送中/排队项在输入区上方或转录尾部有独立可辨识行；不重复现有行内标签。
- 需保持 `queueLabel` 与 `pendingQueue` 状态一致；不要破坏失败重发。

### B2. 键盘发送（P2）

- 当前 `TextEditor` 只能换行，没有发送键。
- 目标：键盘上方出现“发送”按钮，调用现有 `submitDraft()`；`canSubmit` 时可用；不改变多行输入。
- 不要替换 `TextEditor` 为 `UITextView`（本轮风险太高）。

### B3. `On next message` 折叠时机（P2）

- 官方默认 `completion-time`；可选 `On next message`。
- 目标：加一个 `@AppStorage("chat.collapseOnNextMessage")`；在页头 `...` 菜单加“折叠时机”二选一；行为：
  - false：所有 eligible closed 轮自动折叠（现状）。
  - true：只有该轮之后出现新的 user/steering/trigger 输入，才自动折叠；最新 exchange 保持展开。
- 手动展开仍不被后续自动折叠覆盖。
- 不要求官方设置页；菜单入口即可，并在 `DECISIONS.md` 记录这是 iOS 适配。

### B 验收

- `xcodebuild -scheme PhoneDSHProbe ... build` 通过。
- 不修改 `ChatPage.swift`/`ChatModel.swift` 之外的文件。
- 返回：改动点、测试过的场景、未覆盖风险。

## 3. 工作流 C：平台决策记录

在 `DECISIONS.md` 写：
- `open-in-app`：iOS 没有宿主外部打开；选项 A 不做、B ShareLink、C Files/QuickLook。推荐与理由。
- `sidebar-right`：iOS 没有右侧栏；选项 A 不做、B sheet、C split view。推荐与理由。
- `On next message`：iOS 用菜单二选一，不进系统设置；理由。
- 明确“这不是 parity 实现，是平台适配”。

## 4. 主 Agent 集成

1. 等 B 完成，跑 `xcodegen` + `xcodebuild`。
2. 跑 A 的 golden（若可用），与 iOS 当前截图对照；更新 `GOLDEN.md`/`10-wave0`。
3. 审 C 的决策，若同意则保留。
4. 最终回执：已完成/未完成/产品决策，不把 B 的适配说成官方行为。

## 5. 不做什么

- 不为 `open-in-app`/`sidebar-right` 造“看起来像”的假 UI。
- 不在没有官方 golden 的情况下宣称逐像素一致。
- 不在本轮替换 TextEditor / 大改滚动系统。

## 6. 执行结果（2026-11-01）

| 流 | 结果 | 证据 |
|---|---|---|
| A 官方 golden | **成功（9 张）** | hero/auth/session chat/long/tool/question/plan/subagent/subagent-parallel（均 1206×2622）；`capture-official.sh` 可复现 |
| B Composer/折叠 | **代码落地，构建通过** | 独立 pending 行；键盘“发送”；`collapseOnNextMessage` + 页头菜单；`xcodebuild` ✅ |
| C 平台决策 | **完成** | [DECISIONS.md](DECISIONS.md)：D-01 N/A、D-02 sheet、D-03 本地偏好 |
| D 集成 | 构建通过 | `swift build --target PhoneDSHAgentCore` + `xcodebuild` ✅；页头统一 more（子 Agent/任务/定时/产物/导出/运行状态/设置/折叠/preset），Device 图标 + more 菜单已接；sidebar-right 在菜单 |

仍未完成：官方**真实会话** golden（需登录或 fixture）、D-02 的 corner 入口（需先还页头预算）、命令/压缩长尾、深色/Dynamic Type。
