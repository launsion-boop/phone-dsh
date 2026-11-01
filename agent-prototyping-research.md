# 让 Agent 先画原型：交互原型设计工具调研与落地方案

> 调研日期：2026-10-30（全部关键结论经 web 核实）
> 背景：Agent（即使配了 skill）直接写 App 时 UI 质量差。目标：让 agent 先产出**交互原型 + 整个 App 的交互架构**，定稿后再写代码。
> 配套文件：商业工具详查见 [prototype-tools-research.md](prototype-tools-research.md)

---

## 0. TL;DR（结论先行）

**核心判断：不要指望「把 agent 接到一个画图工具上」就解决问题。真正有效的路径是把「设计」拆成独立的前置阶段，产物是 agent 最擅长生成的结构化文件（交互架构文档 + DESIGN.md + 可点击 HTML 原型），并用「截图自评审循环」闭环质量。** 画布类工具（tldraw offline / Penpot）适合做人审与协作环节，商业生成 API（v0 / Stitch）适合当高保真出稿引擎，但都不该是架构的「唯一事实源」。此判断与 Anthropic 官方 frontend-design skill、Google Stitch 的 DESIGN.md 范式、以及两个开源「设计先行」工作流模板（ai-product-ui-workflow、BMAD Design Loop）的实践一致。

**推荐组合（按投入度递增）：**

| 方案 | 组成 | 适合 |
|---|---|---|
| A. 自建原型管线（推荐主线） | 交互架构文档 + DESIGN.md + 高保真 HTML 可点击原型 + Playwright 截图评审循环 | 无设计师、要可控、要沉淀 |
| B. 开源画布辅助 | Penpot 自部署 + 官方 MCP（含 penpot-ai-kit）/ tldraw offline | 需要设计协作、私有化、探索期画板 |
| C. 商业生成引擎 | Google Stitch 官方 CLI/MCP `@google/stitch`（免费）/ v0 API（付费、接口最成熟） | 想快速出高保真稿 |
| D. 国内生态 | MasterGo Vibe MCP（本地读写画布）/ Pixso MCP（工具箱最全） | 团队在国产工具链上 |

> ⚠️ 两个时效性提醒：**Motiff 妙多已于 2026-06 停服**（相关方案作废）；**Google Stitch 于 2026-10 发布官方 agent-first CLI/MCP**（从「社区 hack」升级为官方路线）。

---

## 1. 问题拆解：Agent 直接做 App 为什么烂

先明确病因，才能选对药：

1. **没有全局信息架构**——agent 逐页/逐组件生成，页面之间导航层级、信息密度、术语不一致。
2. **视觉决策随机**——每写一个页面重新「发明」一次颜色、间距、圆角，没有先定 design token。
3. **交互架构缺失**——loading / empty / error / 权限 / 离线这些状态没人设计，跳转流没人梳理。
4. **没有评审闭环**——一次生成直接交付，没有「看一眼、批评、修改」的循环。人类设计师的核心优势不是画得快，而是**有 taste 且能自我批评**。
5. **审美收敛**——Anthropic 官方实验证实：无设计指导时，模型输出会收敛到「Inter 字体 + 紫色渐变」这类安全但千篇一律的审美；约 400 token 的设计指导按需注入即可显著改善。这说明**设计指导必须显式前置**，不能指望模型默认值。

所以「原型工具」要解决的是：**给 agent 一个强制的设计前置阶段 + 一个可被评审的产物 + 一个迭代闭环**，而不是仅仅「换个地方画」。

---

## 2. 全景图：四类候选方案

```
A. 开源画布/设计工具     Penpot(+官方MCP+ai-kit) · tldraw(+offline+MCP) · Excalidraw(+mcp_excalidraw) · draw.io(+官方@drawio/mcp) · Quant-UX · Onlook
B. 商业设计工具+AI      Figma(Make/First Draft/Dev Mode MCP/html_to_figma) · Framer · Uizard · Relume · MasterGo · Pixso · 即时设计
C. 生成式 UI(prompt→UI) Google Stitch(官方CLI+MCP) · v0(API/SDK) · Lovable(MCP) · bolt.new(开源) · OpenUI(开源) · openstitch(开源)
D. 方法论/管线          截图自评审循环 · HTML 原型 · DESIGN.md/token 先行 · 多阶段设计工作流模板
```

关键判断维度（下文打分都用这四条）：
- **Agent 可写性**：agent 能否程序化创建/修改原型（API / MCP / 文件格式）？
- **交互原型能力**：能否表达页面跳转、状态切换（不只是静态图）？
- **产物可消费性**：能否导出 HTML / React / Figma，让后续代码阶段接着用？
- **人审体验**：人类能否方便地看、点、评。

---

## 3. 开源项目详评

### 3.1 tldraw / tldraw offline —— 最「agent 原生」的画布 ⭐⭐⭐⭐

- 51.1k★，2026-10 仍高频更新；SDK 已到 4.x。2026 年 7 月发布 **tldraw offline**（本地桌面画布、本地文件、无需登录），7-9 月迭代出「**spatial harness**」：agent 通过**写代码**操作画布（受 CodeAct / Cloudflare Code Mode 启发），画布上下文按需拉取，官方还带 canvas linting（如检测文字重叠）；官方随 app 附带 **agent skill**，`.tldraw` 文件本身即工程（内含 script.js 可编程）。
- **自动化接口**：官方 **MCP App**（2026-03 起，支持 Cursor/VSCode/ChatGPT/Claude，提供 create/edit/delete shape 工具）+ MIT 协议的 **agent starter kit**（tldraw.dev/starter-kits/agent）；`.tldr` 文件是 JSON snapshot（records 数组），agent 可直接生成/消费。
- 已被 Google Stitch、Lovable、Replit 等用作底层画布 SDK。
- **局限**：① 本质是画布，**没有原型交互语义**（点击跳转要自定义 shape props 或配 Make Real）；② **license 注意**：自定义协议（非 OSI），SDK 4.0 起**开发环境免费、生产需要 license key**（starter kits 为 MIT）。
- 接入方式：装 offline.tldraw.com 桌面端让 agent 操作本地文件；或在 Cursor/Claude 里装官方 MCP App；最可控的方式是用 SDK + agent starter kit 自建「原型画布」。

### 3.2 Penpot + 官方 MCP —— 开源界的「全能选手」 ⭐⭐⭐⭐⭐

- MPL-2.0，61.9k★，当前 2.18/2.19，自部署（docker-compose 一键）。是开源里唯一的「**真设计工具 + 交互原型（flows/navigate/open-overlay/close-overlay/组件 variants 状态）+ 官方 MCP**」三合一。
- **官方 MCP server**（`npx @penpot/mcp`，2.15 "Master of Puppets" 引入、2.16–2.19 持续增强）：架构是 MCP server ↔ WebSocket ↔ 浏览器内插件，agent 可查询/创建/修改设计元素甚至执行代码片段；官方博客明确支持**多向工作流**：design→design、design→code（可交互代码原型/token/Storybook）、code→design、design→docs。
- **penpot-ai-kit**（官方，CC-BY-4.0）：AGENTS.md + 14 个 skills + workflows + evals，专为 agent 设计治理，拿来即用。
- 2026 年 10 月在推「declarative design（布局即代码）」方向，对 agent 生成友好。
- **局限**：① MCP 需浏览器 tab 保持活跃（headless CI 可用社区 `@ai-dala/penpot-headless` 或导入文件）；② 写入质量依赖 design token/组件底子；③ 生态不如 Figma。
- 接入方式：自部署 → agent 经官方 MCP 建 board/组件/flow → 直接套 penpot-ai-kit 的 skills；原型可直接分享 View Mode 链接给人点按。

### 3.3 Excalidraw + mcp_excalidraw ⭐⭐⭐

- 134.8k★，MIT。`.excalidraw` 是纯 JSON（elements 数组，类型化），**agent 直接生成/修改文件最省事**；渲染轻、diff 友好、可入库。
- 社区 MCP：**yctimlin/mcp_excalidraw**（2.58k★，MIT，2026-10 仍活跃），支持 create/edit/export、实时画布同步、附带 Claude Code skill。
- **局限**：无可点击原型（仅超链接），高保真弱。定位「低保真线框 + 架构图」载体——BMAD Design Loop 就用它做线框层。

### 3.4 draw.io + 官方 @drawio/mcp ⭐⭐⭐（最省事的结构化文件路线）

- Apache-2.0，纯静态可自托管。mxGraph XML 纯文本、LLM 可写。
- **官方 MCP**（`@drawio/mcp`，jgraph 出品，2026-02 v1.0 → 2026-10 v1.10 高频更新）：`open_drawio_xml/csv/mermaid`、万级 shape 库搜索、**`list/get/set_page` 直接读写本地 `.drawio` 文件**，还内置 LLM XML 修复/归一化。
- 有 mockup 线框 shape 库；**局限**：无原型模式（shape 可链接到其他 page，弱跳转）。适合线框图+页面流图。

### 3.5 Quant-UX ⭐⭐⭐

- 开源里少见的「**真交互原型 + 用户测试**」工具（页面跳转、back action、hover/active/error 状态、可用性测试统计），2.75k★，GPL-3.0，低频但存活。
- 亮点：**官方 file-format 文档**（JSON：screens/widgets/lines，`event:"click"` 触发跳转、startScreen、38 种 widget）——agent 可直接按文档生成原型 JSON，无浏览器依赖。
- **局限**：无官方 MCP/API、社区小、部署重（4 容器）。适合当「原型 DSL 长什么样」的参考，或坚持纯 JSON 文件路线时的备选。

### 3.6 Onlook ⭐⭐⭐（定位不同：代码之后）

- 27k★，Apache-2.0，活跃（YC 公司）。开源「设计师的 Cursor」：对**已存在的 React/Next.js 项目**做可视化点选编辑，产物是真代码（DOM 插桩 + 代码同步）。
- 不是「先画原型」的工具，而是**代码阶段的视觉微调层**；MCP 集成仍在 roadmap。可与你的管线互补：原型 → 代码 → Onlook 微调。

### 3.6b 传统工具与新项目速览

- **Pencil Project**（9.9k★，GPL-2.0，仍更新）：桌面线框工具，交互弱；**Akira**（停滞）；**Wireflow / MyDraft**（小、无 API）——均不建议作 agent 画布。
- **SuperDesign**（7.6k★）：IDE 内 AI 设计 agent（mockup/wireframe/components、fork 探索），**开源 IDE 版已停止维护**、转向闭源 web app，但留了开源的 superdesign-skill（Claude Code/Cursor 设计 skill）可参考。
- **WireDSL**（早期）：声明式线框 DSL + AI 生成，方向值得关注。

### 3.7 OpenUI（wandb）/ openstitch / bolt.new ⭐⭐⭐

- **OpenUI**（wandb，22.7k★，Apache-2.0，2026-10 仍活跃）：描述 UI → 实时渲染 → 对话迭代 → 导出 React/Svelte/Web Components；支持 Ollama/LiteLLM 本地跑。适合当**生成器底座**自建。局限：单屏思维，无流程/IA 概念。
- **openstitch**（heldernoid，2026-04 新项目，MIT，但仅 32★、活跃度低）：本地 Ollama（qwen3-coder + 视觉模型），文本/截图/手绘 → HTML；**无限画布多屏排布、连线成 flow、Play Mode 全屏可点击原型、多屏共享 DESIGN.md、内置 50+ 品牌设计系统、ZIP 导出**——**架构上最贴合「先出可点原型再写码」的开源实现**，可作参考实现或fork底座；注意 Play Mode 只是模拟点击（不产真实路由），且维护风险高。
- **bolt.new / bolt.diy**：StackBlitz 官方开源主仓（MIT，16.5k★，更新放缓），社区分支 **bolt.diy（20k★，MIT，2026-10 仍活跃）** 支持任意 LLM、可自部署做「prompt→全栈应用」。
- 共同局限：它们本质还是「生成应用」，不是「设计先行」；直接用会回到老问题，但**可以作为方案 A 管线里『高保真出稿』的引擎**。

---

## 4. 商业 / AI 项目详评

> 本章节详细版（含每工具的自动化等级/导出/定价/全部来源）见附录：`prototype-tools-research.md`。

### 4.1 Figma 生态 ⭐⭐⭐⭐（取决于是否已有设计师）

- **REST API 大部分只读**（仅 Comments、Variables[Enterprise]、Dev Resources 可写）；Plugin API 可写但必须人工在 Figma 内触发——外部 agent 无法纯 API 写设计内容，这是硬限制。
- 但 2026-10 官方 Dev Mode MCP（Professional+，Dev 席位约 200 调用/天）新增了关键工具：**`html_to_figma`（把 agent 生成的 HTML 变成可编辑设计层）**、`generate_image`、Specs 读写、**code layers**（画布上放真实可交互运行代码，Config India 2026 宣布）。也就是说，Figma 走的路线是：**agent 在外面用 HTML 干活，成果一键收回 Figma**。
- **Figma Make**：prompt-to-app，支持本地代码库/GitHub 双向同步、Payload 后端、发布上线、预览复制回 Figma Design 图层；**First Draft**：AI 生成可编辑设计稿。均为产品内功能，无公开 API。
- 社区 **figma-developer-mcp / Framelink**（0.13.2，活跃）：只读，把设计稿结构喂给代码 agent。
- 定价：Professional Full $16/月（年付）、Dev 席位 $12，AI 积分 3,000+/席/月。
- 定位：已有设计师、走 Figma 协作流时的最佳选择；`html_to_figma` 让它也能接「agent 先出 HTML 原型」的管线。

### 4.2 Google Stitch —— 官方 agent-first CLI/MCP ⭐⭐⭐⭐⭐（海外免费方案里最优）

- 2026-10 重磅变化：官方发布 **`@google/stitch`（npm，v0.12.1，自我定位「Agent-first CLI and MCP server for Google Stitch」，2026-10-29 更新）**，GitHub google-labs-code/stitch-sdk（1.8k★）。
- 能力：`generate screen`（Gemini 3 系模型生成高保真 UI 屏）、`edit`、`capture`（抓本地 dev server 页面）、`upload screen`（把 HTML 上传成设计屏）、`serve`（本地预览整项目）、`stitch mcp install`；导出 HTML/前端代码；导 Figma 走社区插件 Stitch Figma Bridge。
- **这是免费方案里唯一「为 agent 直调而生」的官方工具**——你的管线里「高保真出稿引擎」可以直接用它。且它官方推 DESIGN.md 规范（见 5.5）。
- 局限：无国内服务器（访问受限）、原型交互语义弱（出的是屏和代码，跳转逻辑仍靠你的管线）。

### 4.3 v0（Vercel）⭐⭐⭐⭐⭐（可编程性最强、付费）

- 官方 **API v2 + TypeScript SDK（`v0.chats.create()` / getPreview）+ MCP client 指南**：支持从 repo/ZIP 继续、部署、下载文件、流式输出。
- 输出是 React/Next.js 代码（shadcn 生态），有 Design Mode 可视化编辑；可导入 Figma（Pro+）。
- 定价：Free 7 条/天；Plus $30/用户/月；Business $100；模型按 token 另计。
- 定位：**编程接口最成熟的 prompt→code 服务**；但它跳过「设计稿」阶段，交互架构必须在 prompt/管线里自定——正好与你的「设计先行」管线互补（v0 当引擎，不当架构）。

### 4.4 Lovable / bolt.new（产品层）⭐⭐⭐

- **Lovable**：官方 REST API（api.lovable.dev/v1）**仅管理/部署已有项目**，AI 生成要走官方 MCP server，API key 需 Business/Enterprise。内置 Visual Edit（截图/点选反馈回 agent）。工程思路值得抄，集成门槛高。
- **bolt.new**：无公开 API、无 MCP（第三方评测直言 "not currently suitable for agent consumption"）；开源版 bolt.diy 可自部署。两者本质都是「完整产品 agent」，不适合嵌入你自己的管线当引擎。

### 4.5 Uizard / Visily / UX Pilot / Relume ⭐⭐

- 全部**无公开 API/官方 MCP**，只能人肉操作，不适合 agent 工作流。
- 可借鉴的只有思路：Relume 的 sitemap→wireframe 流程；Visily 的 Figma+React 双导出（10 屏/次）；UX Pilot 的线框→高保真+设计系统落 Figma。

### 4.6 国内工具（格局剧变，对国内团队现实意义大）⭐⭐⭐⭐

- ⚠️ **Motiff 妙多已停服**（2026-06-23 停止服务，数据导出截止 2026-10-31）——**不可选**，此前调研中的 Motiff MCP 路线作废。
- **MasterGo**：双 MCP 体系。**Vibe MCP（本地客户端，`127.0.0.1:30678`）提供完整读写**：`design_page` 生成整页、`agent_update_node` 局部修改、`agent_sync_design`（本地 HTML 同步进画布）、变量/组件 CRUD、`get_design_diff`；Magic MCP（远程）偏只读 DSL/D2C。`@mastergo/vibe-mcp` 2026-10-30 仍在发版，极活跃。
- **Pixso**：官方 MCP 工具箱最全：`design_to_code`（HTML/React/Vue/ArkUI/Flutter）、**`code_to_design`（HTML/ZIP → 可编辑设计稿）**、`apply_design` 批量写、`write_styles/variables`、**`eval_script`（Figma 兼容 Plugin API 执行 JS）**、截图/布局检查。注意 D2C+/写回需企业版席位。
- **即时设计**：仅社区只读 MCP（导出节点树）。
- 结论：**国内首选 MasterGo（Vibe MCP 本地读写闭环）或 Pixso（MCP 工具箱最全）**，人民币定价、网络无障碍；腾讯云社区已有与「先原型后编码」场景一致的 Pixso MCP+Skill 实践文章可参考。

### 4.7 ProtoPie / Axure / Balsamiq / Framer ⭐⭐~⭐⭐⭐

- **ProtoPie**：有官方 MCP（Beta）——Studio MCP 可用自然语言生成触发/响应/公式（**可写交互**，这是交互原型工具里少见的），Code MCP+Dev View 把场景/变量/逻辑交给 agent 转代码。值得交互重度场景关注。
- Axure：仅 Legacy .NET 只读 API，RP 私有格式不可程序化生成，出局。
- Balsamiq：无 API（Agent-Ready 指数 48/100）。
- Framer：有 Server API（社区 MCP 基于它）但不提供 HTML 导出，偏建站，出局。

---

## 5. 方法论：原型阶段到底应该怎么做（核心章节）

工具只是载体，真正决定质量的是**管线设计**。以下综合了已被验证的实践：Anthropic 官方 skills、Penpot 官方 AI 工作流指南、egghead 的 Playwright MCP 课程、Lovable 工程实践、以及两个现成的开源「设计先行」工作流模板（ai-product-ui-workflow、BMAD/WDS Design Loop）。

### 5.0 两个可直接抄的开源模板（先看这个）

1. **ai-product-ui-workflow**（开源中文 skill，最直接可用）：产品想法 → PRD（定位/IA/页面清单/核心流程/字段+空态+错误态/验收标准）→ **黑白 HTML 低保真**（仅黑白灰+真实文案，禁品牌色渐变，先锁结构）→ **人工停靠点确认** → 风格参考图出主视觉 → 提取 visual-spec.md（色 token hex/字阶/间距/组件规范/Do-Don't）→ 全页面 UI → Figma 交接。分阶段目录（01-prd…06-handoff）+ 每阶段质量检查清单。核心原则：**「不要从模糊想法直接生成最终 UI」**。
   - https://github.com/2558497967long-droid/ai-product-ui-workflow
2. **BMAD/WDS「The Design Loop」9 步**：讨论 → 写页面 spec → agent 生成 **Excalidraw JSON 线框**（纯 JSON 可编程编辑，用户在 VS Code 里拖拽，双方改同一文件）→ 秒级迭代 → **用户导出 PNG = 审批门**（agent 自己导不了，限制即功能）→ spec 同步 → 实现 → **Puppeteer 在 375/768/1280 三个断点截图评审** → 沉淀 design tokens（间距只用命名刻度，spec 禁止裸像素）。铁律：**「spec 是合同，永远不要直接按线框实现」**。
   - https://cdn.jsdelivr.net/npm/cc4pm@2.0.6/_bmad/wds/workflows/4-ux-design/data/guides/DESIGN-LOOP-GUIDE.md

### 5.1 交互架构先行（agent 最擅长的一步）

先用**结构化文本**定死全局，产物入库：
1. **信息架构**：页面清单（含每页职责）、导航层级、层级树；
2. **用户流**：mermaid flowchart 表达「任务 → 屏幕跳转」（agent 生成 mermaid 的可靠性远高于画图）；
3. **每屏状态矩阵**：loading / empty / error / success / 无权限 / 离线 / 边界数据（ai-product-ui-workflow 的 PRD 模板就强制这一点）；
4. **导航与返回逻辑**、**全局组件清单**（哪些页面共用什么）。

> 这一步零工具依赖、纯文本，是「把交互架构设计好」的主体，也是当前所有方案里 agent 做得最稳的部分。

### 5.2 低保真线框（快速否决坏结构）

- 载体可选：**Excalidraw JSON**（Design Loop 的选择：diff 友好、人可以在 VS Code 里拖、双向编辑同一文件）/ **黑白灰 HTML**（ai-product-ui-workflow 的选择：锁结构禁彩色，直接进化成高保真）/ draw.io XML（流程图）。
- 目的：在这一层砍掉 70% 的结构错误，别在高保真阶段返工。**人工评审门设在这里**（确认 or 导出 PNG = 审批），成本最低。

### 5.3 高保真可点击原型：HTML 是事实标准

- **单页/多页 HTML + Tailwind（CDN）+ hash 路由 + mock 数据**，即可表达：页面跳转、状态切换、弹层/抽屉、移动端视口。
- 关键优势：agent 生成 HTML 的能力远强于操作画布工具；原型**天然可截图评审**、可交付真人点按、可后续被代码阶段直接引用；必要时还能用 **html.to.design** 插件把 HTML 原型导回 Figma 给设计师精修。
- 实践参考：Penpot 官方也在推「设计稿 → 代码原型」这个方向；OpenUI / v0 / bolt 都可做这一层的生成引擎；openstitch 证明了「画布 + 多屏连线 + Play Mode」形态可行。

### 5.4 截图自评审循环（质量闭环的发动机）

```
生成/修改原型 → Playwright 截全屏/关键状态 → 视觉模型按 rubric 批评
（一致性/层级/密度/对齐/空态覆盖/与 token 符合度）→ 列 issue → 修改 → 循环 2~4 轮 → 人工 gate
```

已被验证的工程细节（来自 egghead 课程 + Lovable 文档 + 社区实践）：
- **固定截图规格**（如 1024×768 PNG + 命名约定），把约定写进规则文件；
- **diff 用 pixelmatch + pngjs** 生成视觉差异图，agent 读 diff 改代码；
- **把循环固化成一个脚本**（navigate → resize → screenshot → diff），别让 agent 逐次调 MCP 工具——慢且贵；
- **2~4 轮收敛**是社区实测的经验值，反馈信号必须是**真实渲染物**而非模型自我批评；
- Lovable 官方文档也承认：截图判断「细微视觉/色彩差异」不可靠——所以 rubric 检查结构/一致性/状态覆盖比检查「好看」更有效；
- 参考链接：egghead 课程、Lovable browser testing 文档、coleam00 的 Visual Self-Validation 笔记。

### 5.5 Design system 先行（压制视觉随机性）

- **DESIGN.md 范式**（Google Stitch 官方提出）：纯 markdown 设计系统文档放项目根目录——AGENTS.md 告诉 agent 怎么建项目，**DESIGN.md 告诉它项目该长什么样**；无 Figma、无 schema，LLM 直接读。
- **VoltAgent/awesome-design-md**：84 份从真实网站（Stripe/Linear/Vercel/Notion…）提取的 DESIGN.md（色彩角色+hex、字阶、组件样式含状态、间距刻度、Do/Don't、响应式策略），复制进项目根即用。
- **Anthropic 官方 frontend-design skill**：强制两遍流程——先 brainstorm「紧凑 token 系统」（4–6 个命名 hex 色、字体及角色、一句话布局概念+ASCII 线框、设计原则），对照 skill 内置的「AI 生成页通病清单」（cream 底+terracotta、酸绿 accent、SaaS 卡片套件等）自检修订，确认非模板化后才写代码；官方博客证实约 400 token 的设计指导按需注入即可显著提升质量。配套 **webapp-testing skill**（Python Playwright + 服务器生命周期管理）做验收。
- 结论：**token/规范先行有三种现成形态**（DESIGN.md、awesome-design-md 库、frontend-design skill），都能直接用。

### 5.6 代码阶段：以原型为规格做验收

- 代码 agent 的输入 = 交互架构文档 + 已审批 HTML 原型 + DESIGN.md/token 文件；验收 = 用同样的截图循环**对照原型做 pixelmatch diff**（Design2Code 的工程化反用），而不是口头描述「做个好看点」。
- Design Loop 的铁律同样适用：**spec（原型+DESIGN.md）是合同，实现阶段不许自由发挥**。

---

## 6. 推荐落地架构（针对你的 Agent 环境）

把上面组装成一条可立刻实施的管线（做成一个 prototype/design skill）。两个现成模板（ai-product-ui-workflow、BMAD Design Loop）+ Anthropic skills 可直接作底座改造：

```
阶段0  PRD/需求澄清            →  docs/prd.md（含验收标准）
阶段1  交互架构                 →  design/app-map.md（页面清单+导航树）
                                   design/flows.mermaid（用户流）
                                   design/states.md（每屏状态矩阵：loading/empty/error/权限/离线）
阶段2  DESIGN.md / tokens       →  design/DESIGN.md（markdown 设计系统，可从 awesome-design-md 改）
阶段3  低保真线框               →  design/wireframes/（黑白灰 HTML 或 Excalidraw JSON）
        ── 人工评审门 ①：确认结构（确认 or 导出 PNG = 审批）──
阶段4  高保真可点击原型         →  prototype/（HTML+Tailwind+hash路由+mock 数据）
阶段5  自动视觉评审（2~4 轮）    →  scripts/review.mjs（Playwright 截图 → 视觉模型 rubric 批评 → 修改；
                                   375/768/1280 三断点；对照 DESIGN.md 检查一致性）
        ── 人工评审门 ②：人点一遍原型，签字锁定 ──
阶段6  代码生成                 →  以 阶段1/2/4 产物为唯一规格写码（spec 是合同）
阶段7  验收                     →  复用阶段5 脚本，pixelmatch diff「已批原型 vs 实现」
```

**关键设计原则：**
- **产物全部入库（git）**，原型+DESIGN.md 是「单一事实源」，代码阶段禁止自由发挥视觉；
- **两道人工 gate**（结构层 + 视觉层），避免「一次生成到底」；低保真层砍错误的成本最低；
- **rubric 即资产**：把你的 taste 写成可执行的评审清单（对照 frontend-design 的「通病清单」思路自建）；
- **评审循环固化为单脚本**（截图/断点/diff 全自动），不要让 agent 逐步调 MCP；
- **引擎可替换**：阶段 4 可以纯手写 HTML，也可以换 v0 API / Stitch MCP / OpenUI 出稿，管线不变。

**质量兜底（建议直接装）：**
- Anthropic 官方 **frontend-design + webapp-testing** skills（Claude Code：`/plugin marketplace add anthropics/skills`），前者治「AI 味审美」，后者提供 Playwright 验收骨架。

**可选集成（按需叠加）：**
- 探索期想要可视化画板 → **tldraw offline**（agent 直接操作本地文件，或装官方 MCP App）；
- 需要设计师协作/私有化 → **Penpot 自部署 + 官方 MCP + penpot-ai-kit**（设计稿/组件化/可分享原型链接一套全有）；
- 想要快速高保真出稿 → **Google Stitch 官方 CLI/MCP `@google/stitch`**（免费、agent-first）或 **v0 API**（付费、接口最成熟）；
- 团队在国产工具链 → **MasterGo Vibe MCP**（本地读写画布：生成页→确认→D2C 回代码）或 **Pixso MCP**（D2C + code_to_design + eval_script）；
- 已有 Figma 设计系统 → **Figma Dev Mode MCP 的 `html_to_figma`** 把 agent 的 HTML 原型收回 Figma 继续精修；
- 交互重度（动效/复杂状态）→ 关注 **ProtoPie 官方 MCP（Beta）**；
- 想参考「画布+多屏+Play Mode」形态的开源实现 → **openstitch**（fork 改造）。

---

## 7. 决策建议

| 你的情况 | 建议 |
|---|---|
| 无设计师、追求可控与沉淀 | **方案 A 自建管线**（HTML 原型 + DESIGN.md + 截图评审），成本最低、效果最稳 |
| 有设计师共同协作 | Figma + First Draft（人画）+ Dev Mode MCP（agent 读→代码）+ `html_to_figma`（agent 的 HTML 原型收回 Figma）；或 Penpot 自部署走 penpot-ai-kit |
| 数据敏感/私有化 | Penpot 自部署 + 官方 MCP；画板用 tldraw offline |
| 海外服务可用、想免费 | 管线不变，把阶段 4 引擎换成 **Google Stitch CLI/MCP** |
| 预算允许、想省事 | 管线不变，把阶段 4 引擎换成 **v0 API** |
| 国内团队、国产工具链 | **MasterGo Vibe MCP**（本地读写闭环）或 **Pixso MCP**（工具箱最全）接入现有设计资产 |

**一句话：先搭方案 A 的管线（它不依赖任何外部工具、今天就能跑通），再按需要把 Stitch / v0 / Penpot / tldraw / MasterGo 作为可插拔的引擎与画布叠上去。落地顺序建议：先抄 ai-product-ui-workflow 或 BMAD Design Loop 的模板改造成自己的 skill → 装上 Anthropic frontend-design + webapp-testing 兜底 → 引擎按预算接入。**

---

## 8. 关键链接

**方法论与模板（最值得先读）**
- Anthropic 官方 skills 仓库：https://github.com/anthropics/skills（frontend-design / webapp-testing）
- 官方博客《Improving frontend design through skills》：https://claude.com/blog/improving-frontend-design-through-skills
- ai-product-ui-workflow（中文开源 skill，PRD→低保真→高保真→交接全流程）：https://github.com/2558497967long-droid/ai-product-ui-workflow
- BMAD/WDS Design Loop（Excalidraw JSON 线框 + 审批门 + 截图评审）：https://cdn.jsdelivr.net/npm/cc4pm@2.0.6/_bmad/wds/workflows/4-ux-design/data/guides/DESIGN-LOOP-GUIDE.md
- DESIGN.md 规范（Google Stitch）：https://stitch.withgoogle.com/docs/design-md/overview/
- awesome-design-md（84 份真实网站设计系统）：https://github.com/VoltAgent/awesome-design-md
- egghead 课程《AI-Driven Design Workflow: Playwright MCP Screenshots, Visual Diffs, and Cursor Rules》：https://egghead.io/ai-driven-design-workflow-playwright-mcp-screenshots-visual-diffs-and-cursor-rules~aulxx
- Lovable browser testing / Visual Edits：https://docs.lovable.dev/features/browser-testing · https://lovable.dev/blog/visual-edits
- Visual Self-Validation Loop 笔记：https://github.com/coleam00/cole-medin-knowledge-base/blob/main/concepts/visual-self-validation.md

**开源工具**
- Penpot（MPL-2.0，61.9k★）：https://github.com/penpot/penpot · 官方 MCP：https://github.com/penpot/penpot/blob/develop/mcp/README.md · 指南：https://help.penpot.app/technical-guide/integration/mcp-server/ · AI 工作流：https://penpot.app/blog/guide-to-multi-directional-ai-workflows/ · **penpot-ai-kit**：https://github.com/penpot/penpot-ai-kit
- tldraw offline / spatial harness：https://tldraw.dev/blog/tldraw-offline · https://tldraw.dev/blog/harnessing-the-agents · https://offline.tldraw.com · 官方 MCP App：https://tldraw.dev/blog/tldraw-mcp-app · agent starter kit（MIT）：https://tldraw.dev/starter-kits/agent · 4.0 license 变更：https://tldraw.dev/blog/tldraw-sdk-4-0
- Excalidraw（MIT，134.8k★）：https://github.com/excalidraw/excalidraw · mcp_excalidraw（2.58k★，MIT，活跃）：https://github.com/yctimlin/mcp_excalidraw
- draw.io 官方 MCP：https://github.com/jgraph/drawio-mcp · npm：https://www.npmjs.com/package/@drawio/mcp
- Quant-UX（GPL-3.0，2.75k★）：https://github.com/KlausSchaefers/quant-ux · 官方文件格式文档：https://github.com/KlausSchaefers/quant-ux/blob/master/docs/file-format.md
- Onlook（Apache-2.0，27k★）：https://github.com/onlook-dev/onlook
- OpenUI（Apache-2.0，22.7k★）：https://github.com/wandb/openui
- openstitch（MIT，早期项目）：https://github.com/heldernoid/openstitch
- bolt.new / bolt.diy（MIT）：https://github.com/stackblitz/bolt.new · https://github.com/stackblitz-labs/bolt.diy
- SuperDesign（开源版停更，skill 可参考）：https://github.com/superdesigndev/superdesign · https://github.com/superdesigndev/superdesign-skill
- WireDSL（线框 DSL，早期）：https://github.com/Wire-DSL/wire-dsl

**商业 / API**
- Google Stitch 官方 SDK：npm `@google/stitch`（https://www.npmjs.com/package/@google/stitch）· https://github.com/google-labs-code/stitch-sdk · 社区 stitch-mcp：https://www.npmjs.com/package/stitch-mcp
- v0 API/SDK：https://v0.app/docs/api/v1/packages/v0-sdk · SDK 仓库：https://github.com/vercel/v0-sdk · 定价：https://v0.app/pricing
- Figma Make FAQ：https://help.figma.com/hc/en-us/articles/31722591905559-Figma-Make-FAQs · Dev Mode MCP：https://help.figma.com/hc/en-us/articles/32132100833559 · Config India 2026（code layers/html_to_figma）：https://help.figma.com/hc/en-us/articles/43663368947863 · API 对比（读写能力）：https://developers.figma.com/compare-apis/
- figma-developer-mcp（Framelink）：https://www.npmjs.com/package/figma-developer-mcp
- Lovable API/MCP：https://docs.lovable.dev/api-reference/introduction.md · https://docs.lovable.dev/integrations/lovable-mcp-server
- MasterGo：Magic MCP：https://mastergo.com/help/ai-features/magic-mcp.html · Vibe MCP：https://mastergo.com/help/ai-features/vibe-mcp.html · npm：https://www.npmjs.com/package/@mastergo/vibe-mcp
- Pixso MCP（官方工具文档）：https://pixso.cn/developer/zh/mcp/tools.html · 实践参考：https://cloud.tencent.com.cn/developer/article/2736011
- ProtoPie MCP（Beta）：https://www.borndigital.co.jp/campaign/protopie-mcp/
- html.to.design（HTML→Figma）：https://html.to.design
- Design2Code（NAACL 2025）：https://aclanthology.org/2025.naacl-long.199/

**附录**
- 商业/AI 工具详查（每工具自动化等级/导出/定价/来源）：[prototype-tools-research.md](prototype-tools-research.md)
