// SPDX-License-Identifier: MIT
//
// WP3 Bot egress spike: the Swift approval-pattern analyzer (Q2 helper).
//
// The command-text patterns are advisory only. After the S4a exit boundary,
// network writes are approved at the host `/v1/http` exit by host + method
// (`BotMCPRuntime.approveEgress`), not by matching `curl`, a script file, a
// variable concatenation or an interpreter name. These tests pin that
// downgrade: none of WP3's bypass spellings produces a network approval effect,
// and `BotEgressApprovalTests` proves the same spellings are caught at the
// exit. Destructive patterns stay classified as card hints.

import XCTest
@testable import PhoneDSHBot

final class BotEgressSpikeApprovalPatternTests: XCTestCase {
    private let workspace = "/dsh/workspace"

    private func operations(_ command: String) -> [String] {
        BotApprovalPatternAnalyzer.effects(
            tool: "bash", arguments: .object(["command": .string(command)]),
            workspace: workspace).map(\.operation)
    }

    func testLiteralCurlPostIsNoLongerAnApprovalPattern() {
        let command = "curl -sS -X POST --data-raw '{\"jsonrpc\":\"2.0\"}' "
            + "http://127.0.0.1:8787/identity/register"
        XCTAssertEqual(operations(command), [],
            "the command text is not the network-write boundary")
    }

    func testDestructivePatternsRemainAdvisoryHints() {
        XCTAssertEqual(operations("rm -rf /tmp/wp3-artifact"), ["rm-destructive"])
        XCTAssertEqual(operations("git reset --hard HEAD"), ["git-destructive"])
        XCTAssertEqual(operations("find . -name '*.tmp' -delete"), ["find-delete"])
    }

    func testScriptFileCurlPostIsNotAClassificationBoundary() {
        let command = "printf '%s\\n' 'curl -sS -X POST --data-raw \"{}\" "
            + "http://127.0.0.1:8787/identity/register' > /tmp/wp3.sh; bash /tmp/wp3.sh"
        XCTAssertEqual(operations(command), [],
            "a script file must be caught by the host exit, not by command text")
    }

    func testVariableConcatenatedCurlPostIsNotAClassificationBoundary() {
        let command = "c=cur; l=\"${c}l\"; \"$l\" -sS -X POST --data-raw '{}' "
            + "http://127.0.0.1:8787/identity/register"
        XCTAssertEqual(operations(command), [],
            "variable concatenation must be caught by the host exit, not by a literal `curl` regex")
    }

    func testScriptFilePythonNetworkProgramIsNotAClassificationBoundary() {
        XCTAssertEqual(operations("python3 /tmp/wp3.py"), [],
            "an interpreter script must be caught by the host exit, not by its outer argv")
    }
}
