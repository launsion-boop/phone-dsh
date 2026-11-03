# G0 基线记录

- 日期：2026-11-03
- 源码：`fe33f75f46e970c051668027d85e9748b8f591ce`
- 结论：主要 iOS 阶段和模拟器 gating rows 已通过，但完整检查与测试套件不能标记为全绿

## 初次执行

- macOS，XcodeGen 可用，Xcode 包解析可完成。
- `bash scripts/ci/check.sh`：初次运行 300 秒超时，未得到完整结果。
- `bash scripts/ci/sim.sh`：初次运行 300 秒超时，停在完整 DSH Web 依赖安装阶段。
- `xcrun swiftc -typecheck .../Contracts.swift`、`xcodegen generate`、`xcodebuild -resolvePackageDependencies -scheme PhoneDSHSim`：通过。

## 长时限重跑结果

`bash scripts/ci/check.sh` 完成后的阶段结果：

- `phone-spec`、`phone-p0-conformance`、`phone-cross-tree`、`phone-compat`、`phone-bundle-fresh`、`phone-image`、`phone-sdk`、`phone-no-dsh-patch`、`phone-license`、`phone-modules`、`phone-android-structure`、`phone-xcode-resolve`：PASS。
- `phone-plugins`：初次因未设置 `PDSH_DSH_CHECKOUT` 失败；设置为当前 pin 的 DSH checkout 后重跑 PASS（2361 passed，20 skipped）。
- `phone-hygiene`、`phone-gate-contracts`：初次因注入样例中的邮箱格式触发扫描失败；改为非邮箱文本后重跑 PASS。该问题属于本轮新增，现已修复。
- `phone-android-tests`：SKIP，当前环境没有可用 JDK 17+。
- `phone-android-release`：SKIP，缺少 Android NDK 构建产物。

`bash scripts/ci/sim.sh`：

- 所有 gating rows 通过，`environment=ios-simulator`。
- 测试套件仍有 `OfficeTests.testOfficeBridgeDoesNotAdvertiseUnsupportedContext` 一项既有失败，进程以 65 退出。该失败与验收矩阵中已记录的既有链接缺失问题一致，不能写成全量 PASS。

## 后续要求

- 后续命令必须先设置 `PDSH_DSH_CHECKOUT` 为 pin 对应的 checkout，不能用 `/dsh-reference` 默认值代替。
- 将超时、SKIP、NOT_RUN、环境失败、既有失败与新增失败分别记录。
- 后续改动不得让已通过阶段退化，也不得把上述结果简化为“基线全绿”。
