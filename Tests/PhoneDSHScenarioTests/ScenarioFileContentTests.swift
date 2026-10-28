// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — G2 scenario runner: file content assertion semantics.
//
// Regression tests for the `file_regex` assertion. The pattern is evaluated
// grep-style, so `^`/`$` anchor at every line boundary of a multi-line
// artifact. Before the fix the pattern was compiled without
// `.anchorsMatchLines`, so `^## ` only matched a `## ` at offset zero and
// heading assertions on a generated README were reported as failures even
// though the output was correct.
//
// `file_contains` is pinned separately as a literal substring check: its
// values are never interpreted as patterns.

import Foundation
import XCTest
@testable import PhoneDSHScenario

// The `PhoneDSH` prefix keeps these regression tests inside the CI
// gate filter `swift test --filter 'PhoneDSH|PhoneDSHShell'`
// (the filter matches test specifiers by target/class name), next to the
// assertion-semantics fixes they pin.
final class PhoneDSHScenarioFileContentTests: XCTestCase {
    /// Verbatim content of the README the G2-C01 run produced (the artifact at
    /// `results/G2-C01/workspace/README.md`): the first `## ` heading is on
    /// line 3, the others on lines 7, 23, 34 and 44. No heading starts at
    /// offset zero, which is exactly the shape the whole-file anchor missed.
    private static let g2c01Readme = """
    # 客厅灯光小助手

    ## 简介

    客厅灯光小助手是一个运行在树莓派上的轻量 HTTP 服务，主要用于通过手机控制客厅灯带。服务入口为 `app.py`，启动后可以查询灯光状态、开关灯带以及调节亮度，适合在家庭局域网内日常使用。

    ## 启动

    在树莓派上进入项目目录，执行：

    ```bash
    python3 app.py --port 8123
    ```

    其中 `--port` 用于指定服务监听端口，上面的示例使用 `8123`。如果该端口已被占用，服务会自动切换到其他可用端口，启动时请留意提示信息，确认实际使用的端口。

    服务通过环境变量 `LIGHTS_HOME` 指定配置目录；未设置时默认使用 `~/.lights`。如需自定义：

    ```bash
    LIGHTS_HOME=/path/to/config python3 app.py --port 8123
    ```

    ## 接口

    以下路径均相对于服务地址，例如 `http://<树莓派地址>:8123`。

    | 方法 | 路径 | 说明 |
    | --- | --- | --- |
    | GET | `/status` | 查询所有灯的状态 |
    | POST | `/on` | 打开客厅灯带 |
    | POST | `/off` | 关闭客厅灯带 |
    | POST | `/brightness` | 设置亮度，请求体需携带 `level` 字段，取值范围为 0–255 |

    ## 常见问题

    ### 定时关灯为什么在 0 点之后失效？

    这是目前尚未修复的问题。定时关灯在 0 点之后会失效，请勿依赖该功能；在问题修复前，建议手动关灯。

    ### 亮度可以平滑过渡吗？

    暂不支持。亮度平滑过渡尚未实现。

    ## 注意事项

    - **配置目录**：`LIGHTS_HOME` 指向的目录用于存放服务配置，默认是 `~/.lights`。迁移或备份时请一并保留该目录。
    - **使用范围**：建议仅在家庭局域网内使用，不要直接暴露到公网。

    """

    // MARK: Line anchoring

    func testHeadingRegexMatchesG2C01ReadmeWithSeveralHeadingLines() throws {
        // The exact assertion G2-C01 evaluates against its generated README.
        XCTAssertTrue(try ScenarioFileContent.matches("^## ", in: Self.g2c01Readme))
        XCTAssertTrue(try ScenarioFileContent.matches("^# ", in: Self.g2c01Readme))
    }

    func testHeadingRegexStillRejectsAFileWithoutThePrefix() throws {
        // Anchoring is not loose: a heading prefix that no line starts with
        // must still fail, including one that resembles the real title.
        XCTAssertFalse(try ScenarioFileContent.matches("^#XYZ", in: Self.g2c01Readme))
        XCTAssertFalse(try ScenarioFileContent.matches("^## 不存在的章节", in: Self.g2c01Readme))
        XCTAssertFalse(try ScenarioFileContent.matches(
            "^## ", in: "# 只有标题\n\n一段正文，没有二级标题。\n"))
        XCTAssertFalse(try ScenarioFileContent.matches("^## ", in: ""))
    }

    func testHeadingRegexDoesNotMatchAPrefixInTheMiddleOfALine() throws {
        // grep-like `^` is a line-start anchor, not "occurring anywhere".
        XCTAssertFalse(try ScenarioFileContent.matches(
            "^## ", in: "说明：正文里提到 ## 但不在行首\n"))
    }

    func testDollarAnchorsAtLineEndsOfAMultiLineFile() throws {
        XCTAssertTrue(try ScenarioFileContent.matches(
            "^python3 app\\.py --port 8123$", in: Self.g2c01Readme))
        // The same shape with a different port must not match.
        XCTAssertFalse(try ScenarioFileContent.matches(
            "^python3 app\\.py --port 9999$", in: Self.g2c01Readme))
        // `$` is per line here, so a pattern cannot span unrelated lines.
        XCTAssertFalse(try ScenarioFileContent.matches(
            "^# 客厅灯光小助手$## 简介$", in: Self.g2c01Readme))
    }

    func testInvalidRegexStillThrowsInsteadOfMatchingEverything() {
        XCTAssertThrowsError(try ScenarioFileContent.matches("(", in: Self.g2c01Readme))
    }

    // MARK: file_contains stays literal

    func testFileContainsUsesLiteralSubstringSemantics() {
        XCTAssertTrue(ScenarioFileContent.contains("--port 8123", in: Self.g2c01Readme))
        XCTAssertTrue(ScenarioFileContent.contains("LIGHTS_HOME", in: Self.g2c01Readme))
        XCTAssertTrue(ScenarioFileContent.contains("/status", in: Self.g2c01Readme))
        XCTAssertTrue(ScenarioFileContent.contains("常见问题", in: Self.g2c01Readme))

        // Regex syntax in a `file_contains` value is literal text, never a
        // pattern: neither `^## ` nor `常见问题|FAQ` occurs verbatim.
        XCTAssertFalse(ScenarioFileContent.contains("^## ", in: Self.g2c01Readme))
        XCTAssertFalse(ScenarioFileContent.contains("常见问题|FAQ", in: Self.g2c01Readme))
        XCTAssertFalse(ScenarioFileContent.contains("--port [0-9]+", in: Self.g2c01Readme))
        XCTAssertFalse(ScenarioFileContent.contains("## {1,2}", in: Self.g2c01Readme))
    }
}
