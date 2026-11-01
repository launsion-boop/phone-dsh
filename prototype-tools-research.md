# 商业/AI 原型设计工具 × Agent 自动化调研（2026-10）

**调研方法**：全部结论经 web_search/web_fetch 核实（2026-10 时点），来源见文中链接。

## 1. Figma

- **原型能力**：Prototype（跳转/Smart Animate/变量/条件逻辑）；Code layers 开放 beta——在画布上放真实运行代码，可交互原型（[Config India 2026](https://help.figma.com/hc/en-us/articles/43663368947863-What-s-new-from-Config-India-2026)）。
- **Agent 自动化**：
  - 官方 Dev Mode MCP（本地服务，Professional+，Dev 席位 200 调用/天）。2026-10 新增 `html_to_figma`（agent 生成的 HTML→可编辑设计层）、`generate_image`、Specs 读写、code layers 生成（同上来源）。
  - 社区 [Framelink figma-developer-mcp](https://github.com/GLips/Figma-Context-MCP)：只读，把设计 JSON 简化后喂给 Cursor 等。
  - [REST API](https://developers.figma.com/compare-apis/)：**大部分只读**，仅 Comments、Variables（Enterprise）、Dev Resources 可写。
  - Plugin API 可写当前文件，但需用户在 Figma 内手动运行，外部程序不能直接驱动。
  - Figma Make：agentic coding，已支持本地代码库/GitHub 双向同步 + Payload 后端（[博客](https://www.figma.com/blog/figma-make-now-on-your-local-code/)）。First Draft：AI 生成可编辑设计稿（[帮助文档](https://help.figma.com/hc/en-us/articles/23955143044247-Use-First-Draft-with-Figma-AI)）。
- **导出**：HTML/React（Make、code layers）、Figma 设计、图片/PDF。
- **定价**（[2026 拆解](https://www.awesomic.com/blog/figma-pricing)）：Professional Full $16/月（年付）、Dev 席位 $12；Organization $55；AI 积分 3,000-4,250/席/月。
- **结论**：**适合接入**。官方 MCP + Make 生态最完整；但 MCP 客户端限 [Figma MCP Catalog](https://www.figma.com/mcp-catalog/)，且写设计内容主要靠 html_to_figma / Make，REST 直接写能力弱。

## 2. Google Stitch

- **原型能力**：prompt→高保真 UI 屏（Gemini 3 系模型），多屏变体、design system 约束。
- **Agent 自动化**：2026-10 起有**官方 agent-first CLI + MCP**：[npm @google/stitch v0.12.1](https://www.npmjs.com/package/@google/stitch)（2026-10-29 更新，[GitHub google-labs-code/stitch-sdk](https://github.com/google-labs-code/stitch-sdk)）。支持 `generate screen`、`edit`、`capture`（抓本地 dev server 页面）、`upload screen`（HTML 上传为屏）、`serve`（本地预览整项目）、`stitch mcp install`。实验性 Loop：GitHub repo+priorities→insights→solutions。
- **导出**：HTML/前端代码；导 Figma 需社区插件 [Stitch Figma Bridge](https://www.figma.com/community/plugin/1671565299728925846/stitch-figma-bridge)。
- **定价**：Google Labs 免费（部分 Canvas 操作需 STITCH_API_KEY）。
- **结论**：**最适合 agent 直调**（正是为 agent 设计），免费；缺点是无国内服务器、无 Figma 原生导出。

## 3. v0.dev（Vercel）

- **产物**：代码（React/Next.js），非设计稿；有 Design Mode 可视化编辑。
- **Agent 自动化**：官方 [v0 API v2](https://v0.app/docs/api/v2/reference/chats/create-chat)（create/stream chat、from repo/ZIP、deploy、下载文件）+ [TypeScript SDK `v0`](https://github.com/vercel/v0-sdk)（`v0.chats.create()`、getPreview、[MCP client 指南](https://v0.app/docs/api/v2/guides/mcp-server)）。
- **导出**：React 代码、预览 URL、Vercel 部署；可导入 Figma（Pro+）。
- **定价**（[官方](https://v0.app/pricing)）：Free 7 条/天；Plus $30/用户/月；Business $100。模型按 token 计费（v0 Pro $2/$10 每百万）。
- **结论**：**适合**，编程接口最成熟的 prompt→code 服务；但它跳过"设计稿"阶段，交互架构需在 prompt 里自定。

## 4. Lovable / bolt.new

- **Lovable**：官方 [REST API](https://docs.lovable.dev/api-reference/introduction.md)（api.lovable.dev/v1，版本化 2026-09-11）**仅管理/部署已有项目**，AI 生成走官方 [MCP server](https://docs.lovable.dev/integrations/lovable-mcp-server)；API key 需 Business/Enterprise。视觉先行：内置 Visual Edit（截图/点选反馈回 agent）。
- **bolt.new**：**无公开 API、无 MCP**（[Headless Index Band F 25/100](https://headless-systems.com/the-headless-index/ai-platforms/bolt-new)："not currently suitable for agent consumption"）。产品自身即 agent；有 Figma 集成、[visual edits](https://support.bolt.new/reference/faq)、design system 同步。
- **结论**：Lovable 半开放（管理 API + MCP）；bolt.new 不适合外部 agent 接入。

## 5. Uizard / Visily / UX Pilot / Relume

- **Uizard**（Miro 旗下）：文本/截图/手绘→多屏原型；导出图片/PDF + 组件级 React/CSS（Pro+）；**无 API、无 Figma 导出**；Free AI 3 次/月，Pro $12/月（[2026 综述](https://aiteller.jp/blog/ui-design-ai-tool)）。
- **Visily**：同类；Pro/Business 可导 **Figma（可编辑元素）+ React/Vue/HTML**（10 屏/次）；Free 300 积分/月，Pro $14/编辑者/月；**无公开 API**（同上）。
- **UX Pilot**：Figma 插件+Web，AI 生成线框图/高保真+设计系统，产物落 Figma（[官网](https://uxpilot.ai/)）；**无公开 API**。
- **Relume**：sitemap→wireframe→导出 **Figma/Webflow**，营销站场景；$38/月（Freelancer）/$75（Agency）；**无公开 API**（[评测](https://www.uiguides.com/tools/relume-review)）。
- **结论**：此组均无 API/官方 MCP，只能人肉操作，**不适合 agent 工作流**；Relume 的 sitemap→wireframe 流程思路值得自建 prompt 流程借鉴。

## 6. 国内产品

- **Motiff 妙多**：⚠️ **已于 2026-06-23 停止服务，导出截止 2026-10-31**（[定价页公告](https://miaoduo.com/pricing)）——不可选。
- **MasterGo**：AI 快搭/AI 设计助手（生成设计稿+局部修改）。官方 MCP 双轨：[Magic MCP](https://mastergo.com/help/ai-features/magic-mcp.html)（远程、只读 DSL/D2C，需团队版）；[Vibe MCP](https://mastergo.com/help/ai-features/vibe-mcp.html)（本地客户端 `127.0.0.1:30678`，**完整读写**：`design_page` 生成整页、`agent_update_node` 局部改、`agent_sync_design` 本地 HTML 同步画布、变量/组件 CRUD、`get_selection_image` 预览、`get_design_diff` 差异）。
- **即时设计**：无官方 MCP；社区 [jsdesign-mcp-server](https://github.com/nothing-sy/js.design)（只读导出节点树，需桌面端+插件）。
- **Pixso**：官方 [MCP](https://pixso.cn/developer/zh/mcp/tools.html) 工具箱最全：`design_to_code`（HTML/React/Vue/ArkUI/Flutter）、`code_to_design`（HTML/ZIP→可编辑设计稿）、`apply_design` 批量写、`write_styles/variables`、`eval_script`（Figma 兼容 Plugin API 执行 JS）、截图/布局检查/属性批量替换。本地+新版远程 MCP 均支持；需全功能/研发席位，D2C+ 需企业版。有配套 [MCP Skill 工作流实践](https://cloud.tencent.com.cn/developer/article/2736011)（先设计稿后代码，与你的场景一致）。
- 另有 [Refore](https://reforeai.cn/)：网页/交互→像素级导入 MasterGo/Pixso/即时设计 + Talk-to-Design MCP。

## 7. ProtoPie / Axure / Balsamiq / Framer

- **ProtoPie**：**官方 MCP（Beta）**——Studio MCP 用自然语言生成触发/响应/公式（可写交互），Code MCP+Dev View 把场景/变量/逻辑交给 agent 转代码，BYOM（[发布说明](https://www.borndigital.co.jp/campaign/protopie-mcp/)）。
- **Axure RP**：仅 [Legacy RP API](https://www.axure.com/axure-rp-api)（C#/.NET，**只读**，2020 技术预览）；RP 私有格式不可程序化生成；导出 HTML 原型。
- **Balsamiq**：无 API（[Agent-Ready 指数 48/100 "Not Agent-Ready"](https://www.xpay.sh/agent-ready-index/balsamiq-mockups/)）。
- **Framer**：Framer Server API（社区 [framer-design-mcp](https://github.com/superprat/framer-design-mcp-server)）；Framer Agents AI 建站；**不提供 HTML 导出**（官方帮助文档）；Basic $10/月、Pro $30/月按站点。

## Top 3 推荐（考虑中国团队可用性）

1. **MasterGo**（首选）：国产、网络无障碍、官方 Vibe MCP 让 agent 直接读写画布（生成页面→人工确认→`get_selection_code`/D2C 回代码），人民币定价，完整覆盖"先原型后编码"闭环。
2. **Pixso**：同为国产，MCP 能力最全（D2C+C2D+eval_script+批量写），适合 agent 双向流转；注意 D2C+/写回需企业版席位，预算允许可作主力。
3. **Figma**（若海外服务可用）：生态与规范化程度最高，官方 MCP 的 `html_to_figma` + Make/code layers 可承接 agent 产出的 HTML 并继续开发，适合已有 Figma 设计系统的团队。**轻量替代**：Google Stitch——免费且官方 CLI/MCP 为 agent 原生设计，但国内访问受限。

**通用落地建议**：无论选哪家，让 agent 先产出「页面清单→HTML 原型→人工确认→转设计稿/直接转码」的两段式流程，均可用 Stitch CLI（免费）或 MasterGo/Pixso MCP（国内）实现。
