# 2026-11-13 — Bot 卡片预览、气泡对齐与 `phone info` 修复

<!-- SPDX-License-Identifier: MIT -->

Base: `175fe3f586393df660e77e8ab6fc0ddd157e81b9`（`main`）
Head: 本次工作树（未提交）
Protocol impact: **P18**（`capabilities.json` 加法字段 `paths.read_scope` /
`read_scope_note`，见 `PC-20261113-read-scope`）；**P19**（只补宿主私有
`info` 路由与 payload，envelope 字段/上限/错误码不变，见
`PC-20261113-phone-info`）；**P09: none** — 只改卡片 sheet/气泡的本地布局，
没有改 UI projection 格式；**P27: none** — `BotCardPayloads` 的卡片字段没有
增删；**P01/P14/P15: none** — HELLO、工具目录、VFS 挂载与 `PDSH_*` 环境未动。
Contract revision: `PC-20261113-read-scope`（draft）、`PC-20261113-phone-info`（draft）

## 1. 修了什么

| 问题 | 结果 | 关键文件 |
| --- | --- | --- |
| 建议卡点击后发出的消息气泡错位 | 修复：`BotAdaptiveBubbleLayout` 的 trailing 放置改用**实测内容宽度**，不再用 0.80/0.86 的宽度上限；短气泡贴住内容列右边缘 | `BotCardKit.swift`、`BotCardLayoutSupportTests.swift` |
| D1 附件卡「打开」是死按钮 | 修复：`BotCardActions` 增加 `canOpenPath`；生产页把 `openPath` 接到 `PreviewSurface`（与文件浏览器同一套预览），不可解析的路径不渲染按钮；fixture 显式声明能力后仍可录制动作 | `BotCardView.swift`、`BotChatPage.swift`、`BotCardFilePreview.swift`、`BotFixtures.swift` |
| D2 文档卡打开是空壳 | 修复：有 `content` 时用 Markdown 渲染；只有 `path` 时按 App 既有命名空间（`/dsh/workspace/...` 或相对路径）解析到 materialized workspace，按 256 KiB 上限读取 UTF-8，超限有提示并可打开系统完整预览；缺失/非文本/路径错误都有明确文案 | `BotCardFilePreview.swift`、`BotDocumentFileReader.swift`、`BotDocumentFileReaderTests.swift` |
| P1-2 `phone info` 返回 `unknown_tool` | 修复：`info` 加入 `PhoneToolCatalog.routes`（`.device`，只读、始终启用），桥接 `case "info"`，新增 `PhoneDeviceTools.info()` 返回 model/systemName/systemVersion/idiom/machine/display | `PhoneCapabilityGate.swift`、`PhoneCapabilityBridge.swift`、`PhoneDeviceTools.swift`、`PhoneInfoToolTests.swift`；同时更新两处 composite handles 计数 |
| P1-3 `web_fetch` 抓 `text/plain` 404 | **未在本地代码修复**：404 来自远端 `deepseek-fetch-api`，本仓不能 patch DSH，且 Worker 里 `web-fetch-http` 没有 host route。已写 upstream proposal（接受 `text/plain`，或加 host-routed provider）与现有绕行（`github get` / `curl`） | `docs/upstream/2026-11-13-web-fetch-raw-text.md` |
| P2-4 跨会话读没有边界 | **按交接单的“要设计”处理**：不假装读已隔离；在 `capabilities.json` 与 `AGENTS.md` 明确写「read/grep/glob 是全局的，写由 host policy 单独限制」。真正的会话级边界归 P14/P15，另立变更单 | `capabilities.ts`、`capability-manifest.test.ts`、`PC-20261113-read-scope.md` |
| P3-5 `git config --list` 不支持 | 修复：`git config --list` / `-l` 支持 effective/local 两种作用域，输出 `key=value`；`--show-origin` 等仍 loud fail | `plugins/wasi-toolbox/git/config.ts`、`tests/config-list.test.ts` |
| P3-5 `read` 目录提示 | **上游**：`dsh-tool-fs` 的 `FS_NOT_REGULAR_FILE` 文案没有「用 glob/ls」提示；本仓不能 patch pinned DSH。已写 proposal | `docs/upstream/2026-11-13-tool-fs-read-directory.md` |

另外修了两个**与本任务无关、但阻塞模拟器验证**的既有问题：

- `HostStorageCoordinatorTests.swift` 在 Xcode 26.5 下编译失败（IUO 推断 + actor 方法需要 async）。最小修复后 6/6 通过。
- `plugins/scripts/profile.test.mjs` 的 preset 清单停留在 7 个，profile 已有 9 个（`preset-phone-bot-maintainer`、`preset-verifier`）。更新后 `node --test scripts/profile.test.mjs` 11/11 通过。

## 2. 命令 → 结果

| 命令 | 结果 |
| --- | --- |
| `swift test --filter 'PhoneDSHBotTests'` | **PASS** — 750 tests, 0 failures |
| `swift test --filter BotCardLayoutSupportTests` | **PASS** — 14 tests |
| `swift test --filter BotDocumentFileReaderTests` | **PASS** — 8 tests |
| `xcodebuild build -scheme PhoneDSH`（iPhone 17 Pro 模拟器，CODE_SIGNING_ALLOWED=NO） | **PASS** |
| `xcodebuild test -scheme PhoneDSHSim -only-testing:PhoneDSHSimTests/PhoneInfoToolTests` | **PASS** — 3 tests |
| 同上 + `PhonePermissionContractTests` + `OfficeTests` | **PASS** |
| `xcodebuild test -only-testing:PhoneDSHSimTests/HostStorageCoordinatorTests` | **PASS** — 6 tests |
| `bash scripts/ci/bot-ui/capture.sh --appearance light`（仅采集，`BOT_UI_SKIP_UI_TESTS=1`） | **PASS** — capture app build + 61 张 fixture 截图；`chat.png` 目视确认用户气泡右对齐 |
| `cd plugins && node --test wasi-toolbox/git/tests/config-list.test.ts` | **PASS** — 3 tests |
| `cd plugins && node --test wasi-toolbox/git/tests/porcelain-corpus.test.ts wasi-toolbox/git/tests/unsupported.test.ts` | **PASS** — 8 tests |
| `cd plugins && node --test worker-entry/src/capability-manifest.test.ts` | **PASS** — 20 tests（含新增 read-scope 用例） |
| `cd plugins && PDSH_DSH_CHECKOUT=… node --test scripts/profile.test.mjs` | **PASS** — 11 tests |
| `npm run typecheck`（plugins） | **PASS** |
| `bash scripts/ci/check.sh --only phone-bundle-fresh` | **PASS** — 6 fresh；bundle 与 image 已按新源码重建 |
| `bash scripts/ci/check.sh --only phone-image` | **PASS** |
| `bash scripts/ci/check.sh --only phone-no-dsh-patch` | **PASS** |
| `bash scripts/ci/check.sh --only phone-license` | **PASS** |
| `bash scripts/ci/check.sh --only phone-github-oauth` | **PASS** |
| `bash scripts/ci/check.sh --only phone-plugins` | **FAIL** — 唯一失败为 `tests/worker-command-controller.test.ts` 的 timing 用例「an early cancel is bounded even when the Python runtime ignores its signal」（实际 0，期望 262145）；该文件单独跑 **55/55 PASS**，是 full-suite 的时序 flake。profile 用例已修并通过 |
| `bash scripts/ci/check.sh --only phone-hygiene` | **FAIL** — 扫描到既有私有域名/词（`tonoai`、`pdsh.tonoai.cn` 等），非本次文件；未改 allowlist |
| `bash scripts/ci/check.sh --only phone-gate-contracts` | **FAIL** — `selftest.py` 的 production scan 子进程同样命中上面的既有私有域名；非本次 diff |
| `bash scripts/ci/check.sh --only phone-cross-tree` | **PASS** — 64s |
| `bash scripts/ci/check.sh --only phone-sdk` | **INCOMPLETE** — 跑到 scenario 测试时 xctest 0% CPU 挂起 >7 分钟，已终止；本任务的 SwiftPM Bot 测试已单独 **PASS**（750 tests）。`phone-sdk` 的 filter 本来也不含 `PhoneDSHBotTests` |

## 3. 未验证 / 剩余风险

- **真机** `phone info`：**NOT_VERIFIED**（本机只跑模拟器）。模拟器桥接测试已证明 `ok:true`、`tool:"info"`、`data.model/systemVersion/display` 存在。
- **真机 D1/D2 交互**：**NOT_VERIFIED**。代码路径、App 构建与 fixture 构图已验证；真实 Bot 发卡、点开、文件 materialize 时序未在设备上跑。
- **I1 回归**（切后台 40 分钟）：**NOT_RUN**；本 diff 未触碰 `BotDSHRemoteRuntime` 的 reclaim 逻辑。
- **P1-3**：远端 Fetch API 的 `text/plain` 行为仍需 upstream 修；本仓只落 proposal。
- **P2-4**：清单已诚实声明全局读；真正的会话级读边界仍未实现，归 P14/P15。
- `phone-hygiene` / `phone-gate-contracts` 的既有失败会掩盖新问题；本次已用逐文件检查确认新文件未出现在失败列表中。
- `BotAdaptiveBubbleLayout` 的修复改变了所有 trailing 气泡的放置；capture 的 `chat.png` 是目视证据，但没有专门的 frame 断言（该布局在 app target，SimTests 不编译它）。
