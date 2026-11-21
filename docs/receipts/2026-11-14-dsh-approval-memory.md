# 2026-11-14 DSH 常用授权粒度、TTL 与建议卡指标

<!-- SPDX-License-Identifier: MIT -->

## 1. DSH “总是允许”改为范围化 + 只允许安全项

上一版按 `sessionID + tool` 记住，`bash` 一旦选总是，后续所有 bash 都会静默放行，和 Bot 侧 destructive 只能一次的策略不对称。

现在 `DSHApprovalPolicy.grantKey` 的判定：

- `bash`：
  - 只有**单条只读命令**才给 `bash:read-only` 范围；
  - `rm` / `git reset --hard` / `find -delete` / `dd` / `mkfs` / `shred` / `truncate` / `chmod -R` / `chown -R` 等 destructive 命令不给范围；
  - 带 `; | & < >`、反引号、`$(`、换行的复合命令不给范围（无法保证整条只读）；
  - `sed -i`、普通写命令、未知脚本等因为不在只读单命令 allowlist 里，也不给范围。
- `write` / `edit` / `delete` / `move` / `rename` / `mkdir` / `chmod` / `chown` 等文件变更工具：不给 always。
- 只读工具：`read` / `glob` / `grep` / `web_search` / `web_fetch` / `job_list` / `job_output` / `job_status` / `todo_write` 可按工具记忆。
- 未知 / MCP 工具：不给 always。

所以 destructive 请求的卡片只显示「允许一次」，不显示「总是允许」。

## 2. TTL、decidedAt 与设置页可见

`DSHApprovalMemory` 升级为 v2：

- 每条记录带 `decidedAt`；
- TTL **24 小时**，过期后重新询问；
- 旧 v1 记录没有时间戳，无法安全判断过期，升级后不再使用；
- `PhonePermissionsPage` 新增「DSH 会话常用授权」：
  - 列出 session 前缀、scope、相对时间；
  - 可清空全部；
  - 明确提示 24 小时自动失效；
- 其他设置页如果有 Bot 审批记录，仍应分别展示；这里只显示 DSH 本地记忆，避免把两套状态混在一起。

## 3. 本地建议卡使用指标

`BotNextStepsMetrics` 在 Bot 回合结束时本地记录：

- `turns_with_options`：最终 assistant 文本以 2–4 项有序/无序列表结尾的回合；
- `turns_with_next_steps`：上述回合中真正出现 `steps` 卡片的回合；
- 使用率 = 后者 / 前者；
- 只写 `UserDefaults`，不上传，不参与授权/渲染。

`PhonePermissionsPage` 的「建议卡使用（本地）」展示计数、使用率并可清空。

限制：分母是保守文本启发式，不是语义理解；代码块/表格/正文中间的编号步骤不计数，但普通结尾列表可能被计入。它只用于发现长期退化，不作为产品承诺。

## 4. 未验证 / 人工确认

- DSH 真机行为需要实际对一个 destructive bash 卡确认「总是允许」按钮已消失；safe `ls`/`git status` 仍可记忆 24h。
- 震动强度只能手感确认；`.soft` 改为 `.light` 并改为发送手势直接触发，自动化无法判断是否能被感知。
- 建议卡使用率需要多次真实回合，当前没有模型基准数据。
