# 执行命令与当前证据

- 日期：2026-11-03
- 基线：`fe33f75f46e970c051668027d85e9748b8f591ce`

## 已执行

| 命令 | 结果 | 证据等级 |
| --- | --- | --- |
| `xcrun swiftc -typecheck examples/probe-app/ProbeKit/PersonalAgent/Contracts/Contracts.swift` | PASS | 契约源码，非 iOS 端到端 |
| `cd examples/probe-app && xcodegen generate` | PASS | 工程生成 |
| `xcodebuild -resolvePackageDependencies -scheme PhoneDSHSim` | PASS，解析 PhoneDSH、SwiftMarkdown、SwiftMath、cmark-gfm | Xcode 包解析，非设备行为 |
| `bash scripts/ci/check.sh` | 前台 300 秒超时；日志到 PhoneDSHScenario 测试，不能记为 PASS 或 FAIL | 基线检查未完成 |
| `bash scripts/ci/sim.sh` | 前台 300 秒超时；停在完整 DSH Web 依赖安装阶段，不能记为 PASS 或 FAIL | 基线构建未完成 |

## 后续命令

```bash
# 全量静态/插件/SDK 门禁
bash scripts/ci/check.sh

# iOS 模拟器总门禁
bash scripts/ci/sim.sh

# 阶段筛选
bash scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-android-structure,phone-xcode-resolve
bash scripts/ci/check.sh --only phone-plugins,phone-bundle-fresh
bash scripts/ci/check.sh --only phone-hygiene,phone-license,phone-no-dsh-patch

# 工程与测试
cd examples/probe-app && xcodegen generate
xcodebuild -scheme PhoneDSHProbe -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
xcodebuild test -scheme PhoneDSHSim -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:PhoneDSHSimTests/<类名>

# 截图
bash scripts/ios-parity/capture.sh
```

所有后续运行需记录源码 SHA、构建产物、环境、准确命令、耗时和失败分类。超时、SKIP、NOT_RUN 与既有失败不得写成 PASS。
