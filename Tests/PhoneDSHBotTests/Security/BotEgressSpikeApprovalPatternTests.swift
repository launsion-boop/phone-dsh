// SPDX-License-Identifier: MIT
//
// WP3 Bot egress spike: the Swift approval-pattern analyzer (Q2 helper).
//
// `BotApprovalPatternAnalyzer` is the App-side classification used when a
// structural approval payload is built/validated. It sees only the `bash`
// command string. These tests pin which spellings are classified as network
// egress and which are not; the `XCTExpectFailure` cases are the spike finding,
// not a regression baseline.

import XCTest
@testable import PhoneDSHBot

final class BotEgressSpikeApprovalPatternTests: XCTestCase {
    private let workspace = "/dsh/workspace"

    private func operations(_ command: String) -> [String] {
        BotApprovalPatternAnalyzer.effects(
            tool: "bash", arguments: .object(["command": .string(command)]),
            workspace: workspace).map(\.operation)
    }

    func testLiteralCurlPostIsClassified() {
        let command = "curl -sS -X POST --data-raw '{\"jsonrpc\":\"2.0\"}' "
            + "http://127.0.0.1:8787/identity/register"
        XCTAssertTrue(operations(command).contains("curl-post"),
            "operations=\(operations(command))")
    }

    func testScriptFileCurlPostIsClassified() {
        let command = "printf '%s\\n' 'curl -sS -X POST --data-raw \"{}\" "
            + "http://127.0.0.1:8787/identity/register' > /tmp/wp3.sh; bash /tmp/wp3.sh"
        XCTExpectFailure("WP3: BotApprovalPatternAnalyzer sees only the outer bash command; "
            + "a curl POST written into a script file is not classified as network egress") {
            XCTAssertTrue(operations(command).contains("curl-post"),
                "operations=\(operations(command))")
        }
    }

    func testVariableConcatenatedCurlPostIsClassified() {
        let command = "c=cur; l=\"${c}l\"; \"$l\" -sS -X POST --data-raw '{}' "
            + "http://127.0.0.1:8787/identity/register"
        XCTExpectFailure("WP3: variable concatenation hides the literal `curl` token from "
            + "BotApprovalPatternAnalyzer") {
            XCTAssertTrue(operations(command).contains("curl-post"),
                "operations=\(operations(command))")
        }
    }

    func testScriptFilePythonNetworkProgramIsClassified() {
        let command = "python3 /tmp/wp3.py"
        XCTExpectFailure("WP3: the analyzer only sees `python3 /tmp/wp3.py`, not the urllib "
            + "network program inside the script") {
            XCTAssertTrue(operations(command).contains("network-egress"),
                "operations=\(operations(command))")
        }
    }
}
