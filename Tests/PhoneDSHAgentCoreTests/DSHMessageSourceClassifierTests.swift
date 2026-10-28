// SPDX-License-Identifier: MIT
import XCTest
@testable import PhoneDSHAgentCore

final class DSHMessageSourceClassifierTests: XCTestCase {
    func testOrdinaryUserSourceRemainsUser() {
        let message: JSONValue = .object([
            "source": .object(["kind": .string("user")]),
            "content": .array([.object(["type": .string("text"), "text": .string("Please inspect this file.")])]),
        ])
        XCTAssertEqual(DSHMessageSourceClassifier.classify(message), .user)
    }

    func testNonUserInjectionSourceBecomesContext() {
        let message: JSONValue = .object([
            "source": .object(["kind": .string("agent-instructions")]),
            "content": .array([.object(["type": .string("text"), "text": .string("<system-reminder>runtime data</system-reminder>")])]),
        ])
        XCTAssertEqual(DSHMessageSourceClassifier.classify(message), .context(sourceKind: "agent-instructions"))
    }

    func testSystemReminderTextWithUserSourceRemainsUser() {
        let message: JSONValue = .object([
            "source": .object(["kind": .string("user")]),
            "content": .array([.object(["type": .string("text"), "text": .string("I literally typed <system-reminder> as an example.")])]),
        ])
        XCTAssertEqual(DSHMessageSourceClassifier.classify(message), .user)
    }
}
