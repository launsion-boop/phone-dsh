// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

final class BotDSHRemoteRuntimeSourceTests: XCTestCase {
    func testWriteCarriesFullContentButEditPatchDoesNot() throws {
        let write = BotJSONValue.object([
            "name": .string("write"),
            "arguments": .string(#"{"file_path":"/dsh/workspace/.dshbot/agents/bot-a/.dsh/skills/weekly.md","content":"BODY_MARKER"}"#),
        ])
        XCTAssertEqual(BotDSHRemoteRuntime.toolWriteContent(from: write), "BODY_MARKER")
        let edit = BotJSONValue.object([
            "name": .string("edit"),
            "arguments": .object([
                "file_path": .string("/dsh/workspace/.dshbot/agents/bot-a/.dsh/skills/weekly.md"),
                "old_string": .string("old"),
                "new_string": .string("new"),
            ]),
        ])
        XCTAssertNil(BotDSHRemoteRuntime.toolWriteContent(from: edit))
    }
}
