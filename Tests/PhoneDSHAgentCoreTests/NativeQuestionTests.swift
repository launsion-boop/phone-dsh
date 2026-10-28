// SPDX-License-Identifier: MIT
import XCTest
@testable import PhoneDSHAgentCore

final class NativeQuestionTests: XCTestCase {
    func testIndependentAnswersAndMultiSelection() throws {
        let questions = try JSONValue.parse(Data("""
        [{"id":"a","options":[{"label":"Yes"},{"label":"No"}]},
         {"id":"b","multiSelect":true,"options":[{"label":"One"},{"label":"Two"}]}]
        """.utf8))
        let result = DSHRemoteHarness.questionAnswer("{\"a\":\"No\",\"b\":[\"One\",\"Two\"]}", questions: questions)
        let answers = try XCTUnwrap(result["answers"]?.arrayValue)
        XCTAssertEqual(answers[0]["selected"]?.arrayValue, [.string("No")])
        XCTAssertEqual(answers[1]["selected"]?.arrayValue, [.string("One"), .string("Two")])
    }

    func testMissingStructuredAnswerDoesNotReuseWholeJSON() throws {
        let questions = try JSONValue.parse(Data("[{\"id\":\"a\"},{\"id\":\"b\"}]".utf8))
        let result = DSHRemoteHarness.questionAnswer("{\"a\":\"answer A\"}", questions: questions)
        XCTAssertEqual(result["answers"]?.arrayValue?[1]["custom"]?.stringValue, "")
    }

    func testMultiSelectionPreservesCustomText() throws {
        let questions = try JSONValue.parse(Data("[{\"id\":\"q\",\"options\":[{\"label\":\"One\"}]}]".utf8))
        let result = DSHRemoteHarness.questionAnswer("{\"q\":[\"One\",\"Something else\"]}", questions: questions)
        XCTAssertEqual(result["answers"]?.arrayValue?[0]["custom"]?.stringValue, "Something else")
    }

    func testLegacyQuestionDecoding() throws {
        let question = try JSONDecoder().decode(HarnessQuestion.self, from: Data("{\"request_id\":\"r\",\"prompt\":\"Which?\",\"options\":[]}".utf8))
        XCTAssertNil(question.questions)
    }
}
