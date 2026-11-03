# ADR-6：本期 iOS 交付与 Android 例外

- 日期：2026-11-03
- 状态：已决定，待实现验收

## 背景

本期要求先做 iOS 基线，但仓库已有 Android 页面镜像和结构门禁，不能静默只做 iOS 后留下隐性失败。

## 决定

本期仅实现 iOS。所有新页面在 Android 例外清单中显式登记原因和后续补齐里程碑；不改写 Android 页面来制造假同步。若例外机制不接受，停止合入并报告，而不是删除门禁。

## 后果

- iOS 与 Android 的验收证据分开。
- 新 UI 契约、preview/golden 和页面归属同时维护。
- 不宣称跨平台一致性已完成。

## 验证

- `phone-spec`、`phone-p0-conformance`、`phone-android-structure` 的结果和例外均可解释。
- Android 不出现无归属的新增页面或隐性结构失败。
