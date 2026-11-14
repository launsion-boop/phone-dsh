# 2026-11-13 真机回归、权限记忆与轻震动回执

<!-- SPDX-License-Identifier: MIT -->

Base: `06a80094e` (main)
Device: iPhone Air (iPhone18,4), iOS 27.0, UDID `00008150-001220302EF2401C`
Build: Debug, `PDSH_WITH_XZSHELL=1`, team `KC5NZ8GRQ9`

## 1. `phone`/`rg`/`jaq`/`ts-*` 回归

### 根因

上一台真机包用默认 `xcodebuild build` 构建，没有设置 `PDSH_WITH_XZSHELL=1`。`PhoneDSHShell` 因此编译了纯 Swift stub：`PDSHShellC.linked == false`，所有 accelerator 都返回 `not_linked`。
另外 `PDSHShellProvider.advertisedAcceleratorNames` 只要有 `recordQuery` 就追加 `phone`，即使 stub 不能执行；这使 host HELLO 和 capabilities.json 继续宣称 `accelerator:phone`。

### 修复

- `advertisedAcceleratorNames` 现在要求 `PDSHShellC.linked`；stub 不再广告 phone。
- 用 `PDSH_WITH_XZSHELL=1` 重新解析/编译，链接 `libpdsh_ffi.a`；`nm` 可见 `_pdsh_caps_json`/`_pdsh_version`。
- `workerUnavailableCommands` 新增 boot facts：缺 `rg`/`phone`/`ts-parse`/`ts-query`/`jq`/`jaq` 时写入 `unavailable[]`；有 host accelerator 的 `jq`/`jaq` 不再误报。
- 真机 host HELLO（linked build）实际为：
  `accelerator:adb, jaq, jq, phone, rg, scp, ssh, ts-parse, ts-query`；
  `capabilities.json` 的 `phone.tools` 含 `info`，`commands` 含 `phone/rg/jaq/ts-parse/ts-query`。
- 未链接构建仍会诚实返回 `not_linked`，且不再宣称 phone。

## 2. “总是允许”权限记忆

### Bot

- `BotApprovalCoordinator` 的 `.always` 决策现在为每个 effect 创建 **resource `*`** 的 grant，保留 tool/operation，scope 仍按 `session`/`until` 限制。
- `BotGrantStore.find` 接受 resource 通配符；后续同 tool/operation 的不同路径/命令不再重复弹卡。
- `.allowOnce` 仍只创建 exact-resource once grant，消费后下次重新审批；deny 不创建 grant。

### DSH session

- DSH Remote wire 只有 `allowed-once`；App 新增 `DSHApprovalMemory`，按 `sessionID + tool` 持久化“总是允许”。
- 权限卡新增「总是允许」（sandbox escalation 仍只给一次）；点击后当前请求以 `allow_once` 放行并记住，后续同 session/tool 的 approval 事件直接静默以 `allow_once` 回答，不再弹卡。
- 「允许一次」/「拒绝」会清除该 session/tool 的 always 记录；下一次重新审批。
- 记录存放在 App 的 `UserDefaults`，不跨 DSH session 共享。

## 3. 轻震动

- `PhoneHaptics` 统一使用低强度 `UIImpactFeedbackGenerator`：
  - 发送后 agent 开始工作：`.light` intensity 0.34
  - 回合结束：`.light` intensity 0.28
  - 新审批卡：`.light` intensity 0.36
- DSH 与 Bot 都接入；Bot 审批卡原来使用 `.light` 所以可感知，thinking/completion 原先 `.soft` 在 iPhone Air 上几乎不可感知，已改为 `.light`。
- 仅用户发起/已发送的回合触发；打开历史页不会震动。

## 4. 验证

| 项目 | 结果 |
| --- | --- |
| `PDSHShellProviderTests` | **PASS** 6（stub 不再广告 phone） |
| `worker-entry/src/capability-manifest.test.ts` | **PASS** 21（unavailable facts、jq/jaq host accelerator） |
| `BotGrantRecoveryTests` | **PASS** 8（wildcard always grant） |
| `BotMCPRuntimeTests` / `BotModelImageToolTests` | **PASS** 33 |
| `xcodebuild build`（simulator） | **PASS** |
| `xcodebuild build`（`PDSH_WITH_XZSHELL=1`, generic iOS） | **PASS**；`nm` 有 `_pdsh_caps_json` |
| 真机安装/启动 | **PASS**，devicectl install + launch |
| 真机 linked host HELLO | 已观察到 `accelerator:jaq/jq/phone/rg/ts-*` |
| 真机震动 | **NOT_VERIFIED（自动化无法测量）**；thinking/completed 已由 `.soft` 改为 `.light`，需用户手感确认 |
| DSH “总是允许” | **NOT_VERIFIED（需真机点一次卡片）** |

## 5. 注意

- `capabilities.json` 是 Worker 持久化文件；更新 app 后如果 host 从旧 overlay 恢复，旧文件可能仍存在，直到 host 重新 boot/publish。最终构建的 Worker bundle 已含新逻辑；若设备仍显示旧 manifest，需在 App 内停止/重启 host 或完整重启 App。
- `jq` 现在有 linked host 的 `accelerator:jq`；不再报 unavailable。若某构建没有 jq/jaq host accelerator 且没有 WASI engine，manifest 会把它列入 `unavailable`，而不是空数组。
