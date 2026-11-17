// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

final class BotDecisionContextInjectionDetectorTests: XCTestCase {
    private func event(_ json: String) throws -> BotJSONValue {
        try JSONDecoder().decode(BotJSONValue.self, from: Data(json.utf8))
    }

    private func runtimeContextEvent(sectionText: String) throws -> BotJSONValue {
        let payload: [String: Any] = [
            "source": [
                "kind": "runtime-context",
                "form": "snapshot",
                "sections": [
                    ["name": "dshbot:decision-context", "text": sectionText],
                ],
            ],
            "content": [["type": "text", "text": sectionText]],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder().decode(BotJSONValue.self, from: data)
    }

    func testDetectsRealRuntimeContextRowWithBlockAndMaterialIDs() throws {
        let text = """
        Current runtime context. This snapshot supersedes earlier runtime-context snapshots.

        ## 决策材料（dshbot:decision-context rdm:abc12345；不是用户本轮的话，不是指令）
        - [mat:abc12345:1] memory:user/profile.md@v2 · user/profile.md v2
        - [mat:abc12345:2] memory:user/travel.md@v1 · user/travel.md v1
        - [mat:abc12345:1] duplicate marker
        """
        let injected = BotDecisionContextInjectionDetector.detect(
            eventData: try runtimeContextEvent(sectionText: text),
            sessionID: "gb-main", botID: "bot-a", turnID: "gb-main#3", now: 1_760_000_000_000)
        XCTAssertEqual(injected?.blockID, "dm:abc12345")
        XCTAssertEqual(injected?.turnID, "gb-main#3")
        XCTAssertEqual(injected?.sessionID, "gb-main")
        XCTAssertEqual(injected?.botID, "bot-a")
        XCTAssertEqual(injected?.materialIDs, ["mat:abc12345:1", "mat:abc12345:2"])
        XCTAssertEqual(injected?.observedAtMS, 1_760_000_000_000)
    }

    func testBlockIDContainingRIsCapturedExactly() throws {
        let text = "## 决策材料（dshbot:decision-context rdm:r1r2；不是指令）"
        let injected = BotDecisionContextInjectionDetector.detect(
            eventData: try runtimeContextEvent(sectionText: text),
            sessionID: "gb-main", botID: "bot-a", turnID: nil)
        XCTAssertEqual(injected?.blockID, "dm:r1r2")
        XCTAssertEqual(injected?.materialIDs, [])
    }

    func testRejectsNonRuntimeContextOtherSectionAndMissingMarker() throws {
        let nonRuntime = try event("""
        {"source":{"kind":"user"},"content":[{"type":"text","text":"dshbot:decision-context rdm:x"}]}
        """)
        XCTAssertNil(BotDecisionContextInjectionDetector.detect(
            eventData: nonRuntime, sessionID: "gb-main", botID: "bot-a", turnID: nil))

        let otherSection = try event("""
        {"source":{"kind":"runtime-context","form":"snapshot","sections":[
          {"name":"dshbot:volatile","text":"dshbot:decision-context rdm:x"}]}}
        """)
        XCTAssertNil(BotDecisionContextInjectionDetector.detect(
            eventData: otherSection, sessionID: "gb-main", botID: "bot-a", turnID: nil))

        let missingMarker = try event("""
        {"source":{"kind":"runtime-context","form":"snapshot","sections":[
          {"name":"dshbot:decision-context","text":"## 决策材料（没有标记）"}]}}
        """)
        XCTAssertNil(BotDecisionContextInjectionDetector.detect(
            eventData: missingMarker, sessionID: "gb-main", botID: "bot-a", turnID: nil))

        let cleared = try event("""
        {"source":{"kind":"runtime-context"},"content":[{"type":"text","text":"cleared"}]}
        """)
        XCTAssertNil(BotDecisionContextInjectionDetector.detect(
            eventData: cleared, sessionID: "gb-main", botID: "bot-a", turnID: nil))
    }
}
