// SPDX-License-Identifier: MIT

import XCTest

final class DSHApprovalMemoryTests: XCTestCase {
    func testGrantScopeRejectsDestructiveAndUnknownRequests() {
        XCTAssertEqual(
            DSHApprovalPolicy.grantKey(tool: "bash", arguments: ["command": "git status"]),
            "bash:read-only")
        XCTAssertEqual(
            DSHApprovalPolicy.grantKey(tool: "bash", arguments: ["command": "ls -la"]),
            "bash:read-only")
        XCTAssertNil(DSHApprovalPolicy.grantKey(tool: "bash", arguments: ["command": "sed -i s/a/b/ file"]))
        XCTAssertNil(DSHApprovalPolicy.grantKey(tool: "bash", arguments: ["command": "ls; rm -rf build"]))
        XCTAssertNil(DSHApprovalPolicy.grantKey(tool: "bash", arguments: ["command": "ls\nrm -rf build"]))
        XCTAssertNil(DSHApprovalPolicy.grantKey(tool: "bash", arguments: ["command": "rm -rf build"]))
        XCTAssertNil(DSHApprovalPolicy.grantKey(tool: "bash", arguments: ["command": "git reset --hard"]))
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

        DSHApprovalMemory.remember(sessionID: session, scope: "bash:read-only", now: now)
        XCTAssertTrue(DSHApprovalMemory.isAllowed(
            sessionID: session, scope: "bash:read-only", now: now.addingTimeInterval(60)))
        XCTAssertFalse(DSHApprovalMemory.isAllowed(
            sessionID: session, scope: "tool:read", now: now))
        XCTAssertFalse(DSHApprovalMemory.isAllowed(
            sessionID: otherSession, scope: "bash:read-only", now: now))

        // 24h TTL.
        XCTAssertTrue(DSHApprovalMemory.isAllowed(
            sessionID: session, scope: "bash:read-only", now: now.addingTimeInterval(23 * 3600)))
        XCTAssertFalse(DSHApprovalMemory.isAllowed(
            sessionID: session, scope: "bash:read-only", now: now.addingTimeInterval(25 * 3600)))
        XCTAssertEqual(DSHApprovalMemory.activeGrants(now: now.addingTimeInterval(25 * 3600)).count, 0)
    }

    func testForgetAndClearRemoveOnlyTheMatchingGrant() {
        let session = "dsh-memory-test-\(UUID().uuidString)"
        let now = Date(timeIntervalSince1970: 1_000_000)
        DSHApprovalMemory.clearAll()
        defer { DSHApprovalMemory.clearAll() }

        DSHApprovalMemory.remember(sessionID: session, scope: "bash:read-only", now: now)
        DSHApprovalMemory.remember(sessionID: session, scope: "tool:read", now: now)
        DSHApprovalMemory.forget(sessionID: session, scope: "bash:read-only")
        XCTAssertFalse(DSHApprovalMemory.isAllowed(
            sessionID: session, scope: "bash:read-only", now: now))
        XCTAssertTrue(DSHApprovalMemory.isAllowed(sessionID: session, scope: "tool:read", now: now))
        XCTAssertEqual(DSHApprovalMemory.activeGrants(now: now).map(\.scope), ["tool:read"])

        DSHApprovalMemory.clearAll()
        XCTAssertTrue(DSHApprovalMemory.activeGrants(now: now).isEmpty)
    }
}
