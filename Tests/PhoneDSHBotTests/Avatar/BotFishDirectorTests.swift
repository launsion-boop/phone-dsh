// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

final class BotFishDirectorTests: XCTestCase {
    func testFrozenDirectorEventSequenceMatchesUpstream() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent("spec/bot/v1/golden/fish-director.json")
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let valid = fixture["valid"] as! [String: Any]
        let steps = valid["steps"] as! [[String: Any]]
        var state = BotFishDirectorState()
        for (index, step) in steps.enumerated() {
            let action = step["action"] as! String
            let event = step["event"] as! [String: Any]
            let time = (event["time"] as! NSNumber).int64Value
            let result: (directorState: BotFishDirectorState, command: BotFishCommand?)
            switch action {
            case "reduce":
                let data = event["data"] as! [String: Any]
                result = BotFishDirector.reduce(state, event: BotFishEvent(
                    type: event["type"] as! String, time: time, data: jsonObject(data)))
            case "expire":
                result = BotFishDirector.expireOneShot(state, now: time)
            case "lifecycle":
                result = BotFishDirector.setLifecycle(
                    state, lifecycle: BotFishLifecycle(rawValue: event["lifecycle"] as! String)!, now: time)
            default:
                return XCTFail("unknown action \(action)")
            }
            state = result.directorState
            let expected = step["expected"] as! [String: Any]
            let expectedState = expected["directorState"] as! [String: Any]
            XCTAssertEqual(state.current.rawValue, expectedState["current"] as? String, "step \(index)")
            XCTAssertEqual(state.lifecycle.rawValue, expectedState["lifecycle"] as? String, "step \(index)")
            XCTAssertEqual(state.priority, (expectedState["priority"] as! NSNumber).intValue, "step \(index)")
            XCTAssertEqual(state.now, (expectedState["now"] as! NSNumber).int64Value, "step \(index)")
            XCTAssertEqual(state.version, (expectedState["version"] as! NSNumber).intValue, "step \(index)")
            let expectedReaction = expectedState["oneShot"] as? [String: Any]
            XCTAssertEqual(state.oneShot?.state.rawValue, expectedReaction?["state"] as? String, "step \(index)")
            XCTAssertEqual(state.oneShot?.endsAt, (expectedReaction?["endsAt"] as? NSNumber)?.int64Value,
                           "step \(index)")
            let expectedCommand = expected["command"] as? [String: Any]
            XCTAssertEqual(result.command?.state.rawValue, expectedCommand?["state"] as? String, "step \(index)")
            XCTAssertEqual(result.command?.oneShot, expectedCommand?["oneShot"] as? Bool, "step \(index)")
            XCTAssertEqual(result.command?.priority, (expectedCommand?["priority"] as? NSNumber)?.intValue,
                           "step \(index)")
            XCTAssertEqual(result.command?.ttlMs, (expectedCommand?["ttlMs"] as? NSNumber)?.int64Value,
                           "step \(index)")
        }
    }

    func testDirectorUsesBotEventShapeWithoutModelContextWrites() {
        let event = BotEvent(type: "watchdog.flagged", eventId: "watchdog-1", time: 100,
                             origin: .local(source: "watchdog"), traceId: "watchdog-trace-1",
                             principal: BotPrincipal(botId: "main", sessionId: "gb-main", kind: "watchdog"),
                             causationId: nil, correlationId: nil, data: .object(["check": .string("heartbeat")]))
        guard case .object(let data) = event.data else { return XCTFail("watchdog data must be an object") }
        let result = BotFishDirector.reduce(BotFishDirectorState(),
                                            event: BotFishEvent(type: event.type, time: event.time, data: data))
        XCTAssertEqual(result.directorState.current, .alerting)
        XCTAssertEqual(result.directorState.priority, 100)
        XCTAssertEqual(result.command?.state, .alerting)
    }

    private func jsonObject(_ object: [String: Any]) -> [String: BotJSONValue] {
        object.mapValues { value in
            switch value {
            case let text as String: return .string(text)
            case let flag as Bool: return .bool(flag)
            case let number as NSNumber: return .number(number.doubleValue)
            case let object as [String: Any]: return .object(jsonObject(object))
            case let array as [Any]: return .array(array.map(jsonValue))
            default: return .null
            }
        }
    }

    private func jsonValue(_ value: Any) -> BotJSONValue {
        switch value {
        case let text as String: return .string(text)
        case let flag as Bool: return .bool(flag)
        case let number as NSNumber: return .number(number.doubleValue)
        case let object as [String: Any]: return .object(jsonObject(object))
        case let array as [Any]: return .array(array.map(jsonValue))
        default: return .null
        }
    }
}
