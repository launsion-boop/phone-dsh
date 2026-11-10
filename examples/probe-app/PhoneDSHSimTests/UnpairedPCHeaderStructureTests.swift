// SPDX-License-Identifier: MIT
// Source-level guard for the unpaired PC placeholder's chrome container.
//
// The shell ignores the safe area for the drawer, so `PCWorkspaceChatPlaceholder`
// must sit in the same `NavigationStack` container as `ChatPage` instead of
// directly in the tab ZStack. The actual layout is verified by the simulator
// screenshots; this guard fails when the branch drops that container again.

import Foundation
import XCTest

// The guarded source lives on the host, not inside the simulator/device
// container. `#filePath` resolves on the simulator run; the device twin also
// compiles this directory, so keep the test out of that target.
#if targetEnvironment(simulator)
final class UnpairedPCHeaderStructureTests: XCTestCase {
    func testUnpairedPCPlaceholderUsesTheChatPageNavigationContainer() throws {
        let source = try nativeShellSource()
        let branchStart = try XCTUnwrap(
            source.range(of: "} else if !models.isPhoneSelected {"),
            "the unpaired PC branch moved; update this guard")

        // Brace-match the else-if body so the assertions cannot be satisfied by
        // an unrelated branch later in the file.
        var depth = 1
        var cursor = branchStart.upperBound
        while cursor < source.endIndex, depth > 0 {
            if source[cursor] == "{" { depth += 1 }
            else if source[cursor] == "}" { depth -= 1 }
            cursor = source.index(after: cursor)
        }
        XCTAssertEqual(depth, 0, "unbalanced else-if branch")
        XCTAssertGreaterThan(cursor, branchStart.upperBound)
        let branch = source[branchStart.upperBound..<source.index(before: cursor)]

        let navigation = try XCTUnwrap(
            branch.range(of: "NavigationStack {"),
            "PCWorkspaceChatPlaceholder must keep ChatPage's NavigationStack container")
        let placeholder = try XCTUnwrap(
            branch.range(of: "PCWorkspaceChatPlaceholder("),
            "the unpaired PC branch no longer renders PCWorkspaceChatPlaceholder")
        XCTAssertLessThan(navigation.lowerBound, placeholder.lowerBound,
                          "the placeholder sits outside the NavigationStack")
        XCTAssertTrue(branch.contains(".toolbar(.hidden, for: .navigationBar)"),
                      "the placeholder's NavigationStack must hide the system bar")
    }

    private func nativeShellSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("PhoneDSHProbe/NativeShell.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }
}
#endif
