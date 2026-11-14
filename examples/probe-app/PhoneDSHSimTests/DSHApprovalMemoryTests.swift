// SPDX-License-Identifier: MIT

import XCTest

final class DSHApprovalMemoryTests: XCTestCase {
    func testAlwaysIsScopedToSessionAndToolAndForgetClearsIt() {
        let session = "dsh-memory-test-\(UUID().uuidString)"
        let otherSession = "dsh-memory-test-\(UUID().uuidString)"
        let tool = "bash"
        XCTAssertFalse(DSHApprovalMemory.isAllowed(sessionID: session, tool: tool))

        DSHApprovalMemory.remember(sessionID: session, tool: tool)
        XCTAssertTrue(DSHApprovalMemory.isAllowed(sessionID: session, tool: tool))
        XCTAssertFalse(DSHApprovalMemory.isAllowed(sessionID: session, tool: "read_image"))
        XCTAssertFalse(DSHApprovalMemory.isAllowed(sessionID: otherSession, tool: tool))

        // A deny / allow-once clears exactly this session+tool entry.
        DSHApprovalMemory.forget(sessionID: session, tool: tool)
        XCTAssertFalse(DSHApprovalMemory.isAllowed(sessionID: session, tool: tool))
    }
}
