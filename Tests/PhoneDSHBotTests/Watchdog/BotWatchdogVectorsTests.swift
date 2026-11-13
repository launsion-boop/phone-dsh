// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

final class BotWatchdogVectorsTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("phonedsh-bot-watchdog-vectors-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testConfigVectorsSupplyDefaultsAndRejectFrozenErrors() throws {
        let fixture = try botGolden("watchdog.phone")
        let configCases = try XCTUnwrap(fixture["configCases"] as? [String: Any])
        let valid = try XCTUnwrap(configCases["valid"] as? [[String: Any]])
        for item in valid {
            let name = try XCTUnwrap(item["name"] as? String)
            let actual = try botDecode(BotWatchdogConfig.self, item["input"]!)
            let expected = try botDecode(BotWatchdogConfig.self, item["expect"]!)
            XCTAssertEqual(actual, expected, name)
        }
        let invalid = try XCTUnwrap(configCases["invalid"] as? [[String: Any]])
        for item in invalid {
            let name = try XCTUnwrap(item["name"] as? String)
            XCTAssertThrowsError(try botDecode(BotWatchdogConfig.self, item["input"]!), name)
        }
    }

    func testUnitVectorsDriveRealStartUnitDeadlineAndIdentityRules() async throws {
        let fixture = try botGolden("watchdog.phone")
        let unitCases = try XCTUnwrap(fixture["unitCases"] as? [String: Any])
        let cases = try XCTUnwrap(unitCases["valid"] as? [[String: Any]])
        let store = try SQLiteDomainStore(
            fileURL: directory.appendingPathComponent("units.sqlite"), now: { 0 })
        let monitor = BotWatchdogMonitor(eventLog: store, config: .default, now: { 0 })

        for item in cases {
            let name = try XCTUnwrap(item["name"] as? String)
            let kind = try XCTUnwrap(BotWatchdogUnitKind(rawValue: item["kind"] as! String))
            let id = try XCTUnwrap(item["id"] as? String)
            let expected = try XCTUnwrap(item["expect"] as? [String: Any])
            let flags = await monitor.startUnit(
                kind: kind, id: id,
                botId: item["botId"] as? String,
                sessionId: item["sessionId"] as? String,
                startedAt: fixtureInt64(item["startedAt"]),
                deadlineOverrideMs: fixtureInt64(item["deadlineOverrideMs"]),
                at: fixtureInt64(item["at"]))
            XCTAssertEqual(flags.map(\.check.rawValue), [], name)
            let unit = await monitor.unit(kind: kind, id: id)
            XCTAssertEqual(unit?.kind, kind, name)
            XCTAssertEqual(unit?.id, id, name)
            XCTAssertEqual(unit?.botId, expected["botId"] as? String, name)
            XCTAssertEqual(unit?.sessionId, expected["sessionId"] as? String, name)
            XCTAssertEqual(unit?.startedAt, fixtureInt64(expected["startedAt"]), name)
            XCTAssertEqual(unit?.lastEventAt, fixtureInt64(expected["lastEventAt"]), name)
            XCTAssertEqual(unit?.deadlineAt, fixtureInt64(expected["deadlineAt"]), name)
        }
        try await store.close()
    }

    func testMonitorVectorsAndFlagPayloadsDriveRealMonitorAndStore() async throws {
        let fixture = try botGolden("watchdog.phone")
        let scenarios = try XCTUnwrap(fixture["monitorCases"] as? [[String: Any]])
        var eventsById: [String: BotEvent] = [:]

        for (scenarioIndex, scenario) in scenarios.enumerated() {
            let name = try XCTUnwrap(scenario["name"] as? String)
            let config = try botDecode(BotWatchdogConfig.self, scenario["config"]!)
            let store = try SQLiteDomainStore(
                fileURL: directory.appendingPathComponent("scenario-\(scenarioIndex).sqlite"),
                now: { 0 })
            let monitor = BotWatchdogMonitor(eventLog: store, config: config, now: { 0 })
            let steps = try XCTUnwrap(scenario["steps"] as? [[String: Any]])
            for (stepIndex, step) in steps.enumerated() {
                let context = "\(name).steps[\(stepIndex)]"
                let op = try XCTUnwrap(step["op"] as? String)
                let stepKind = (step["kind"] as? String)
                    .flatMap(BotWatchdogUnitKind.init(rawValue:))
                let flags: [BotWatchdogFlag]
                switch op {
                case "start":
                    flags = await monitor.startUnit(
                        kind: stepKind!, id: step["id"] as! String,
                        botId: step["botId"] as? String,
                        sessionId: step["sessionId"] as? String,
                        startedAt: fixtureInt64(step["startedAt"]),
                        deadlineOverrideMs: fixtureInt64(step["deadlineOverrideMs"]),
                        at: fixtureInt64(step["at"]))
                case "tick":
                    flags = await monitor.tick(at: fixtureInt64(step["at"]))
                case "finish":
                    await monitor.finishUnit(kind: stepKind!, id: step["id"] as! String)
                    flags = []
                case "mobile":
                    let event = try XCTUnwrap(BotMobileWatchdogEvent(rawValue: step["event"] as! String))
                    let evidence = try botDecode(
                        [String: BotJSONValue].self, step["evidence"] ?? [:])
                    flags = await monitor.observeMobile(
                        event, kind: stepKind!, id: step["id"] as! String,
                        botId: step["botId"] as? String,
                        sessionId: step["sessionId"] as? String,
                        evidence: evidence,
                        at: fixtureInt64(step["at"]))
                case "toolCall":
                    flags = await monitor.observeToolCall(
                        kind: stepKind!, id: step["id"] as! String,
                        name: step["name"] as! String,
                        argumentsDigest: step["digest"] as? String,
                        callId: step["callId"] as? String,
                        at: fixtureInt64(step["at"]))
                case "toolResult":
                    flags = await monitor.observeToolResult(
                        kind: stepKind!, id: step["id"] as! String,
                        name: step["name"] as? String,
                        status: step["status"] as! String,
                        error: step["error"] as? String,
                        resultDigest: step["resultDigest"] as? String,
                        callId: step["callId"] as? String,
                        at: fixtureInt64(step["at"]))
                case "usage":
                    flags = await monitor.observeUsage(
                        kind: stepKind!, id: step["id"] as! String,
                        tokens: (step["tokens"] as? NSNumber)?.intValue ?? 0,
                        costUsd: (step["costUsd"] as? NSNumber)?.doubleValue ?? 0,
                        at: fixtureInt64(step["at"]))
                default:
                    XCTFail("\(context): unknown op \(op)")
                    continue
                }
                let expectedChecks = try XCTUnwrap(step["expectChecks"] as? [String])
                XCTAssertEqual(flags.map(\.check.rawValue), expectedChecks, context)
                if let expectedUnit = step["expectUnit"] {
                    let unit = await monitor.unit(kind: stepKind!, id: step["id"] as! String)
                    if expectedUnit is NSNull {
                        XCTAssertNil(unit, context)
                    } else {
                        let expected = try XCTUnwrap(expectedUnit as? [String: Any])
                        XCTAssertEqual(unit?.kind, stepKind, context)
                        XCTAssertEqual(unit?.id, step["id"] as? String, context)
                        XCTAssertEqual(unit?.botId, expected["botId"] as? String, context)
                        XCTAssertEqual(unit?.sessionId, expected["sessionId"] as? String, context)
                        XCTAssertEqual(unit?.startedAt, fixtureInt64(expected["startedAt"]), context)
                        XCTAssertEqual(unit?.lastEventAt, fixtureInt64(expected["lastEventAt"]), context)
                        XCTAssertEqual(unit?.deadlineAt, fixtureInt64(expected["deadlineAt"]), context)
                    }
                }
            }
            for event in try await store.events(after: 0, limit: 1_000) {
                eventsById[event.eventId] = event
            }
            try await store.close()
        }

        let payloads = try XCTUnwrap(fixture["flagPayloadCases"] as? [[String: Any]])
        for item in payloads {
            let name = try XCTUnwrap(item["name"] as? String)
            let eventId = try XCTUnwrap(item["eventId"] as? String)
            let event = try XCTUnwrap(eventsById[eventId], name)
            let expected = try botDecode(BotJSONValue.self, item["expect"]!)
            XCTAssertEqual(event.type, "watchdog.flagged", name)
            XCTAssertEqual(event.origin, .local(source: "watchdog"), name)
            XCTAssertEqual(event.data, expected, name)
            let expectedAt = try XCTUnwrap((item["expect"] as? [String: Any])?["at"] as? NSNumber)
            XCTAssertEqual(event.time, expectedAt.int64Value, name)
        }
    }

    func testContextProfilesRemainReadOnlyData() throws {
        let watchdog = try botGolden("watchdog.phone")
        let block = try XCTUnwrap(watchdog["contextProfiles"] as? [String: Any])
        XCTAssertEqual(block["readOnly"] as? Bool, true)
        XCTAssertEqual(block["botRuntimeCompaction"] as? Bool, false)
        XCTAssertEqual(block["unknownResolution"] as? String, "default")
        let profiles = try botGolden("context-profiles")
        let document = try botDecode(BotContextProfileDocument.self, profiles["valid"]!)
        XCTAssertEqual(document, .frozen)
        XCTAssertEqual(BotContextProfileName.resolve("unknown"), .default)
    }

    private func fixtureInt64(_ value: Any?) -> Int64? {
        if value == nil || value is NSNull { return nil }
        return (value as? NSNumber)?.int64Value
    }
}
