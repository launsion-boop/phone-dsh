// SPDX-License-Identifier: MIT
//
// Replay entry for the real Bot activity projection. It reads a real DSH v4
// session log with the production decoder, folds every open-turn prefix
// through the production BotRuntimePresentationFactory and
// BotActivityEvidence.lineActivity, and prints the activity sentence that the
// non-interactive bubble would render. It fails hard on an empty log or a
// request/header that is not the accepted Flash/max route.
//
// Run with:
//   PDSH_ACTIVITY_SESSION=<.../gb-main/session.v4.jsonl> \
//     swift test --package-path scripts/ci/bot-e2e/harness \
//     --filter BotActivityReplayTests

import Foundation
import XCTest
@testable import BotEvalApp
import PhoneDSHBot

final class BotActivityReplayTests: XCTestCase {
    func testProductionReducerReplaysRealSessionLog() throws {
        guard let path = ProcessInfo.processInfo.environment["PDSH_ACTIVITY_SESSION"],
              !path.isEmpty else {
            throw XCTSkip("set PDSH_ACTIVITY_SESSION to a real DSH v4 session log")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let parsed = BotDSHSessionEvent.parseJSONL(data)
        XCTAssertFalse(parsed.events.isEmpty,
                       "refusing empty activity evidence: \(path)")

        let headers = parsed.events.filter { $0.type == "request/header" }
        let configs = headers.compactMap { event -> (String, String, String)? in
            guard let config = event.data["header"]?["config"] else { return nil }
            return (config["provider"]?.stringValue ?? "",
                    config["model"]?.stringValue ?? "",
                    config["reasoningEffort"]?.stringValue ?? "")
        }
        XCTAssertFalse(configs.isEmpty, "no request/header in \(path)")
        for (provider, model, effort) in configs {
            XCTAssertEqual(provider, "deepseek-official")
            XCTAssertEqual(model, "deepseek-flash")
            XCTAssertEqual(effort, "max")
            print("HEADER provider=\(provider) model=\(model) reasoningEffort=\(effort)")
        }

        var line = BotActivityLineState()
        var printed = 0
        var lastDetail = ""
        for end in parsed.events.indices {
            let prefix = Array(parsed.events[...end])
            let now = max(0, parsed.events[end].time)
            let presentation = BotRuntimePresentationFactory.make(
                botID: "main", sessionID: "gb-main",
                sessionEvents: prefix, uiEvents: [], now: now)
            let activity = BotActivityEvidence.lineActivity(
                factory: presentation.activity, streaming: false,
                pendingApprovals: 0,
                visible: presentation.runningTurnID != nil)
            line.receive(activity, at: now)
            guard let detail = activity?.detail, !detail.isEmpty,
                  detail != lastDetail,
                  detail != "等待响应", detail != "正在回复" else { continue }
            lastDetail = detail
            printed += 1
            let hasCJK = detail.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) }
            let bound = hasCJK ? 28 : 56
            XCTAssertLessThanOrEqual(detail.count, bound,
                                     "activity detail is not short: \(detail)")
            for forbidden in ["读取相关资料", "已收到", "执行当前操作", "处理中"] {
                XCTAssertFalse(detail.contains(forbidden),
                               "preset activity leaked: \(detail)")
            }
            print("ACTIVITY seq=\(parsed.events[end].seq) type=\(parsed.events[end].type) " +
                  "chars=\(detail.count) detail=\(detail)")
        }
        XCTAssertGreaterThan(printed, 0, "no real activity sentence in \(path)")
    }
}
