# 「我的」页直接进入手机号登录（P09）

```yaml
change: PC-20261110-account-entry-on-me-tab
contracts: [P09]
status: implemented
breaking: false
version_decision: UI placement only. One row on the 我的 tab (iOS and Android) opens the existing Tono 账号 page. No account wire, store, token or gateway rule changes.
base: f594395f
contract_revision: spec/ui/v1/pages/settings.json @ this PR head
```

Protocol impact: P09; P27: none — SettingsPage.swift changes only the account row, the 已连接的电脑 row and PC Link state are unchanged

P09 — 我的 tab gains a 「Tono 账号」 row (value 「未登录 · 点此登录」 or 「尾号 NNNN」) that opens `TonoAccountPage`; iOS page contracts regenerated, Android `SettingsPage` mirrors it.

## 1. 问题

手机号登录与退出登录（[tono-account.md](../../spec/v1/tono-account.md) §3）早已实现，但入口只在聊天页打开的设置面板（sheet）里：「我的」标签页没有这一行，从「我的」进入的「设置」又把它和「模型服务」一起排除了（`includesProviders: false`）。普通用户在「我的」里找不到登录页，也就找不到退出登录。Android 同样只在 `SHEET_ONLY`。

## 2. Delta

| 端 | Before → After |
| --- | --- |
| iOS `SettingsPage` (`.tab`) | 无账号行 → 第一组为 `accountLink`：标题「Tono 账号」，值随 `TonoAccountSession.states()` 显示「未登录 · 点此登录」／「尾号 NNNN」／「已登录」，点开 `TonoAccountPage`（登录、退出登录）。 |
| Android `SettingsPage` (TAB) | 同上：`me.account` 组的 `me.tonoAccount` 行，值来自 `SettingsScreenState.tonoAccount`（`PdshNavFacts.tonoAccount`），点开 `SettingsDestination.TONO_ACCOUNT`。 |
| sheet / 设置 | 不变。 |

页面从不显示令牌或完整手机号（与 §3 可见状态一致）。

## 3. 相容性

纯 UI；无持久化、线格式或凭据行为变化。旧版本没有这一行，只能从 sheet 进入。

## 4. 证据

- Android：galic `./gradlew :lib:testDebugUnitTest --tests com.phonedsh.ui.page.SettingsModesAndConnectorsTest` → 7 tests, 0 failed（新增「我的」显示「未登录 · 点此登录」并打开 `TONO_ACCOUNT`、登录后显示「尾号 1234」）。
- iOS：`xcodebuild … -destination generic/platform=iOS`（Q322S2LD93 签名）→ BUILD SUCCEEDED；已安装到 longshu 的 iPhone 并启动。
- 契约：`extract_ios_pages.py --check` 无过期；`page_structure_check.py` 没有本变更带来的新分歧（main 上原有 7 条不变）；`check.sh --only phone-spec,phone-cross-tree` → PASS；`protocol_impact.py` → PASS。
- 未验证：手机屏幕上实际看到这一行（镜像未开，无法截屏）；真实短信登录（需要用户本人手机号和验证码）。

## 5. 修订纪录

| revision | 由谁 | 原因 | 通知 |
| --- | --- | --- | --- |
| 1 | Claude | 初版 | iOS、Android UI |
