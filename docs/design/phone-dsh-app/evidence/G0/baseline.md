# G0 基线记录

- 日期：2026-11-03
- 源码：`fe33f75f46e970c051668027d85e9748b8f591ce`
- 结论：基线检查未完成，不能将本轮标记为 PASS 或 FAIL

## 执行环境与命令

- macOS，XcodeGen 可用，Xcode 包解析可完成。
- `bash scripts/ci/check.sh`：运行 300 秒后前台超时。日志已进入 PhoneDSHScenario 测试，未得到完整结果。
- `bash scripts/ci/sim.sh`：运行 300 秒后前台超时。日志停在完整 DSH Web 依赖安装阶段，未进入完整模拟器验收。

## 可确认结果

- `xcrun swiftc -typecheck .../Contracts.swift`：通过。
- `xcodegen generate`：通过。
- `xcodebuild -resolvePackageDependencies -scheme PhoneDSHSim`：通过。

## 后续要求

- 使用更长后台时限重跑完整检查，保留完整日志。
- 将超时、SKIP、NOT_RUN、环境失败与测试失败分别记录。
- 后续改动不得以本次超时作为“基线全绿”或“基线已失败”的证据。
