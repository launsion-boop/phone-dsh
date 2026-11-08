<!-- SPDX-License-Identifier: MIT -->

# BotInfoPage（target）

契约：P09、P25、P26。目标实现路径：`examples/probe-app/PhoneDSHProbe/Bot/**`。

Bot 信息页使用 phoneDSH 现有设置页分组、列表和导航 token，展示并编辑由 runtime-context 注入的 Bot 名，提供记忆、Routines、审批记录三个真实数据入口。页面不得伪造条目数、授权状态或后台 session 过程；读取失败显示失败，不显示为零。

- 记忆：展示 facts 的 tier/scope/source/时间，支持已有 forget/erase 语义；不提供第一版未实现的自动抽取、反思或衰减开关。
- Routines：展示 schedule、timezone、delivery、quiet/urgent 标记和运行结果，动作通过 UserAction/宿主服务，不直接修改数据库。
- 审批记录：只显示参数摘要和实际决定，不显示密钥或完整敏感参数。
- 深链 `phonedsh://bot/<botID>/row/<rowID>` 定位真实行；未知或过期行显示不可用，不跳到无关会话。

浅色、深色、空状态、读取失败和长文本需要模拟器截图与交互证据；当前状态为 target，不代表页面已经实现。
