# PhoneDSH 黑白低保真原型

这是独立 PhoneDSH App 的结构评审稿，不是桌面客户端换皮，也不是高保真视觉或生产实现。

## 打开

可直接用浏览器打开 `index.html`，无需安装依赖或构建。也可以在本目录运行：

```bash
python3 -m http.server 8765
```

然后访问 `http://127.0.0.1:8765/`。

建议视口：390 × 844。桌面浏览器会以手机框显示；窄屏会自动填满。

## 五 Tab 动态结构

- **Personal Agent Chat**：配置 API key 和首次命名后开启的个性化主对话。
- **AI日记**：Personal Agent 配置完成后出现；录音来源、三环概览、纪要与原话。
- **DSH**：首次启动默认页；沿用当前 PhoneDSH 原生会话主页与会话抽屉，首次显示“新会话 / 引擎还没启动”，启动后呈现消息流、TaskRun、工作区和产物。
- **AI日记详情**：对齐桌面客户端的纪要 / 画板 / 逐字稿结构，附摘要、诊断、来源引用和 Mock 音频控制。
- **发现**：硬件、连接器和服务应用的统一目录。
- **个人**：不登录也可用；API key、命名、Memory、Provider/Credits、隐私与设置。

未配置时 Dock 为 Chat / DSH / 发现 / 个人四格；配置完成后在 Chat 与 DSH 之间插入 AI日记。

## 建议人工门①走查路径

1. **首次启动**：默认 `#dsh`，确认无需 Personal Agent 即可看到通用任务和产物。
2. **Personal Agent 配置**：`#chat` → 配置 API key → Agent 名 → 主人称呼 → 进入个性化 Chat，并确认 AI日记出现。
3. **任务闭环**：发送一条任务 → 打开 TaskRun → 推进完成（Mock）→ 查看纪要与原话。
4. **外部动作**：打开飞书确认卡 → 分别检查允许与拒绝路径。
5. **录音到日记**：AI日记 → 麦克风来源或导入 → 会议纪要 → 原话 → 引用到 Chat。
6. **Memory**：个人 → Memory → 打开候选 → 确认/驳回/修改/彻底忘记 → 撤销。
7. **BLE 接入**：从 Chat、AI日记或发现进入 → 选择 → 授权 → 能力 → Ready → 反向 LED 控制，确认设备状态一致。
8. **状态检查**：通过顶部“场景”切换未配置、默认、无设备、离线、引擎失败和空数据。

## 主要 hash 路由

```text
#dsh
#chat
#agent-setup
#agent-name
#owner-name
#recap
#minutes-hardware-review
#discover
#personal
#memory
#memory-local-first
#task-hardware-plan
#approval-feishu
#devices
#pair-xiaozhi
#settings
#privacy
```

## Mock 范围

- 所有设备、任务、转写、记忆、Credits 和发送回执都是虚构数据。
- “验证 API key”“推进任务”“配对成功”“允许发送”只改变本地视图，不产生真实网络或设备副作用。
- “导出 Mock 数据”会在本机生成一份虚构 JSON，不包含真实个人信息。
- 黑白稿只用于确认信息架构、内容顺序、术语、状态与导航。

不包含：Tailwind、高保真材质、真实 LLM/ASR/TTS、真实 BLE、后台验证、OAuth、真实账号、Playwright 评审和 SwiftUI 实现。上述内容均在人工门①之后分阶段进行。
