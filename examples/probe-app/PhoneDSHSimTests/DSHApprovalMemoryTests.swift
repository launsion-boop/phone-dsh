// SPDX-License-Identifier: MIT

import XCTest

final class DSHApprovalMemoryTests: XCTestCase {
    /// A standing answer is stored per action class, not per command text:
    /// the same delete of another path must not ask again.
    func testGrantScopeUsesTheActionClass() {
        XCTAssertEqual(
            DSHApprovalPolicy.grantKey(tool: "bash", arguments: ["command": "git status"]),
            "bash:read")
        XCTAssertEqual(
            DSHApprovalPolicy.grantKey(tool: "bash", arguments: ["command": "ls -la"]),
            "bash:read")
        XCTAssertEqual(
            DSHApprovalPolicy.grantKey(tool: "bash", arguments: ["command": "rm -rf build"]),
            "bash:delete")
        XCTAssertEqual(
            DSHApprovalPolicy.grantKey(tool: "bash", arguments: ["command": "ls; rm -rf build"]),
            "bash:delete")
        XCTAssertEqual(
            DSHApprovalPolicy.grantKey(tool: "bash", arguments: ["command": "git reset --hard"]),
            "bash:git-reset")
        // A command the classifier cannot place keeps the one-shot answer.
        XCTAssertNil(DSHApprovalPolicy.grantKey(tool: "bash", arguments: ["command": "sed -i s/a/b/ file"]))
        XCTAssertNil(DSHApprovalPolicy.grantKey(tool: "bash", arguments: ["command": "python3 run.py"]))
        XCTAssertNil(DSHApprovalPolicy.grantKey(tool: "bash", arguments: ["command": "ls; ls"]))
        XCTAssertNil(DSHApprovalPolicy.grantKey(tool: "bash", arguments: ["command": ""]))
        XCTAssertNil(DSHApprovalPolicy.grantKey(tool: "write", arguments: ["file_path": "/a"]))
        XCTAssertNil(DSHApprovalPolicy.grantKey(tool: "mcp__unknown", arguments: [:]))
        XCTAssertEqual(DSHApprovalPolicy.grantKey(tool: "read", arguments: [:]), "tool:read")
    }

    func testAlwaysIsScopedToSessionAndScopeAndExpires() {
        let session = "dsh-memory-test-\(UUID().uuidString)"
        let otherSession = "dsh-memory-test-\(UUID().uuidString)"
        let now = Date(timeIntervalSince1970: 1_000_000)
        DSHApprovalMemory.clearAll()
        defer { DSHApprovalMemory.clearAll() }

        DSHApprovalMemory.remember(sessionID: session, scope: "bash:read", now: now)
        XCTAssertTrue(DSHApprovalMemory.isAllowed(
            sessionID: session, scope: "bash:read", now: now.addingTimeInterval(60)))
        XCTAssertFalse(DSHApprovalMemory.isAllowed(
            sessionID: session, scope: "tool:read", now: now))
        XCTAssertFalse(DSHApprovalMemory.isAllowed(
            sessionID: otherSession, scope: "bash:read", now: now))

        // 24h TTL.
        XCTAssertTrue(DSHApprovalMemory.isAllowed(
            sessionID: session, scope: "bash:read", now: now.addingTimeInterval(23 * 3600)))
        XCTAssertFalse(DSHApprovalMemory.isAllowed(
            sessionID: session, scope: "bash:read", now: now.addingTimeInterval(25 * 3600)))
        XCTAssertEqual(DSHApprovalMemory.activeGrants(now: now.addingTimeInterval(25 * 3600)).count, 0)
    }

    func testForgetAndClearRemoveOnlyTheMatchingGrant() {
        let session = "dsh-memory-test-\(UUID().uuidString)"
        let now = Date(timeIntervalSince1970: 1_000_000)
        DSHApprovalMemory.clearAll()
        defer { DSHApprovalMemory.clearAll() }

        DSHApprovalMemory.remember(sessionID: session, scope: "bash:read", now: now)
        DSHApprovalMemory.remember(sessionID: session, scope: "tool:read", now: now)
        DSHApprovalMemory.forget(sessionID: session, scope: "bash:read")
        XCTAssertFalse(DSHApprovalMemory.isAllowed(
            sessionID: session, scope: "bash:read", now: now))
        XCTAssertTrue(DSHApprovalMemory.isAllowed(sessionID: session, scope: "tool:read", now: now))
        XCTAssertEqual(DSHApprovalMemory.activeGrants(now: now).map(\.scope), ["tool:read"])

        DSHApprovalMemory.clearAll()
        XCTAssertTrue(DSHApprovalMemory.activeGrants(now: now).isEmpty)
    }
}
