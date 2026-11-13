// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

/// Runs `spec/bot/v2/golden/proactive.json` through the real ProactiveSettings,
/// ProactivityPolicy, ProactiveEngine, ProactiveSources-owned candidate shape
/// and RoutineScheduledNotification types. Cases and expectations are read from
/// the shared file; nothing below copies a vector.
final class ProactiveVectorTests: XCTestCase {
    private let golden = "spec/bot/v2/golden/proactive.json"

    // MARK: - Fixture loading

    private func fixture() throws -> [String: Any] {
        let url = try wp6RepoRoot().appendingPathComponent(golden)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return try XCTUnwrap(object as? [String: Any], "\(golden) is not an object")
    }

    private func dictionary(_ value: Any?) throws -> [String: Any] {
        try XCTUnwrap(value as? [String: Any])
    }

    private func array(_ value: Any?) throws -> [[String: Any]] {
        try XCTUnwrap(value as? [[String: Any]])
    }

    private func int64(_ value: Any?) throws -> Int64 {
        let number = try XCTUnwrap(value as? NSNumber)
        return number.int64Value
    }

    private func settings(_ object: [String: Any]) throws -> ProactiveSettings {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(ProactiveSettings.self, from: data)
    }

    private func policy(_ object: [String: Any]) throws -> ProactivePolicyConfiguration {
        ProactivePolicyConfiguration(
            fuseWindowMs: try int64(object["fuseWindowMs"]),
            fuseMaxWakeups: try XCTUnwrap((object["fuseMaxWakeups"] as? NSNumber)?.intValue))
    }

    private func deliveryKinds(_ object: [String: Any]) -> Set<ProactiveKind> {
        Set((object["deliveryKinds"] as? [String] ?? []).compactMap(ProactiveKind.init(rawValue:)))
    }

    private func candidate(_ object: [String: Any]) throws -> ProactiveCandidate {
        let kindRaw = try XCTUnwrap(object["kind"] as? String)
        let kind = try XCTUnwrap(ProactiveKind(rawValue: kindRaw), "unknown kind \(kindRaw)")
        let delivery = (object["delivery"] as? String)
            .flatMap(RoutineDeliveryMode.init(rawValue:))
        return ProactiveCandidate(
            id: object["id"] as? String,
            kind: kind,
            botId: try XCTUnwrap(object["botId"] as? String),
            dedupeKey: object["dedupeKey"] as? String,
            trigger: object["trigger"] as? String,
            sourceEventId: object["sourceEventId"] as? String,
            createdAt: try int64(object["createdAt"]),
            channel: object["channel"] as? String ?? "system-notification",
            title: object["title"] as? String,
            body: object["body"] as? String,
            taskId: object["taskId"] as? String,
            taskTitle: object["taskTitle"] as? String,
            summary: object["summary"] as? String,
            status: object["status"] as? String,
            routineId: object["routineId"] as? String,
            runId: object["runId"] as? String,
            attempt: (object["attempt"] as? NSNumber)?.intValue,
            delivery: delivery,
            quiet: object["quiet"] as? Bool ?? false,
            resultExcerpt: object["resultExcerpt"] as? String,
            deliveryKey: object["deliveryKey"] as? String,
            rowId: object["rowId"] as? String,
            reminderId: object["reminderId"] as? String,
            allowDuringDnd: object["allowDuringDnd"] as? Bool ?? false)
    }

    private func deliveryMode(_ value: Any?) throws -> ProactiveVectorDeliverer.Mode {
        guard let value else { return .ok }
        if let text = value as? String {
            guard text == "ok" else {
                throw ProactiveVectorError(description: "unsupported deliverer \(text)")
            }
            return .ok
        }
        let object = try dictionary(value)
        if let message = object["throw"] as? String {
            return .failure(message)
        }
        return .result(ProactiveDeliveryResult(
            delivered: object["delivered"] as? Bool ?? false,
            channel: object["channel"] as? String ?? "system-notification",
            error: object["error"] as? String))
    }

    // MARK: - Settings

    func testSettingsVectorsMatchTheRealSettingsType() throws {
        let root = try fixture()
        let settingsFixture = try dictionary(root["settings"])
        let valid = try dictionary(settingsFixture["valid"])
        XCTAssertFalse(valid.isEmpty)

        for (name, value) in valid {
            let object = try dictionary(value)
            let decoded = try settings(object)
            XCTAssertEqual(decoded.mode.rawValue, object["mode"] as? String, name)
            XCTAssertEqual(decoded.dnd, object["dnd"] as? Bool, name)
            XCTAssertEqual(decoded.quietStart, object["quietStart"] as? String, name)
            XCTAssertEqual(decoded.quietEnd, object["quietEnd"] as? String, name)
            XCTAssertEqual(decoded.routineQuietWeekends, object["routineQuietWeekends"] as? Bool, name)
            XCTAssertEqual(decoded.timeZone, object["timeZone"] as? String, name)
            XCTAssertEqual(decoded, decoded.normalized(), name)

            let configuration = try policy(object)
            XCTAssertEqual(configuration.fuseWindowMs, try int64(object["fuseWindowMs"]), name)
            XCTAssertEqual(configuration.fuseMaxWakeups,
                           (object["fuseMaxWakeups"] as? NSNumber)?.intValue, name)
            XCTAssertEqual(deliveryKinds(object),
                           Set((object["deliveryKinds"] as? [String] ?? [])
                               .compactMap(ProactiveKind.init(rawValue:))), name)
        }

        for testCase in try array(settingsFixture["invalid"]) {
            let name = try XCTUnwrap(testCase["name"] as? String)
            let object = try dictionary(testCase["settings"])
            switch try XCTUnwrap(testCase["recovery"] as? String) {
            case "decode-fails":
                XCTAssertThrowsError(try settings(object), name)
            case "normalize":
                let normalized = try settings(object).normalized()
                let expected = try dictionary(testCase["normalized"])
                if let quietStart = expected["quietStart"] as? String {
                    XCTAssertEqual(normalized.quietStart, quietStart, name)
                }
                if let quietEnd = expected["quietEnd"] as? String {
                    XCTAssertEqual(normalized.quietEnd, quietEnd, name)
                }
                if expected["timeZone"] as? String == "<current>" {
                    XCTAssertNotNil(TimeZone(identifier: normalized.timeZone), name)
                    XCTAssertNotEqual(normalized.timeZone, object["timeZone"] as? String, name)
                }
            case "decode-ignores", "contract-only":
                XCTAssertNoThrow(try settings(object), name)
            default:
                XCTFail("\(name): unknown recovery")
            }
        }

        for testCase in try array(settingsFixture["normalization"]) {
            let name = try XCTUnwrap(testCase["name"] as? String)
            let input = try dictionary(testCase["input"])
            let normalized = try settings(input).normalized()
            for (field, expected) in try dictionary(testCase["expect"]) {
                switch field {
                case "quietStart":
                    XCTAssertEqual(normalized.quietStart, expected as? String, name)
                case "quietEnd":
                    XCTAssertEqual(normalized.quietEnd, expected as? String, name)
                case "timeZone":
                    XCTAssertEqual(expected as? String, "<current>", name)
                    XCTAssertNotNil(TimeZone(identifier: normalized.timeZone), name)
                    XCTAssertNotEqual(normalized.timeZone, input["timeZone"] as? String, name)
                default:
                    XCTFail("\(name): unknown normalized field \(field)")
                }
            }
        }
    }

    // MARK: - Decisions

    func testDecisionVectorsMatchTheRealEngine() async throws {
        let root = try fixture()
        let decisions = try dictionary(root["decisions"])
        let valid = try array(decisions["valid"])
        XCTAssertFalse(valid.isEmpty)

        for testCase in valid {
            let name = try XCTUnwrap(testCase["name"] as? String)
            let steps = try array(testCase["steps"])
            let actual = try await run(testCase)
            XCTAssertEqual(actual.count, steps.count, name)
            for (index, pair) in zip(actual, steps).enumerated() {
                let expected = try dictionary(pair.1["expect"])
                XCTAssertEqual(
                    try canonical(decisionJSON(pair.0)),
                    try canonical(expected),
                    "\(name) step \(index + 1)")
            }
        }
    }

    func testPolicyFuseIsStrictPerBotAndIgnoresNonRecordedEntries() {
        var policy = ProactivityPolicy(configuration: ProactivePolicyConfiguration(
            fuseWindowMs: 1_000, fuseMaxWakeups: 2))
        policy.restore(AcceptedConsideration(at: 1_000, kind: .taskDone,
                                             botId: "bot-a", fuseRecorded: true))
        policy.restore(AcceptedConsideration(at: 1_500, kind: .taskDone,
                                             botId: "bot-a", fuseRecorded: true))
        XCTAssertTrue(policy.fuseTripped(botId: "bot-a", now: 1_999))
        XCTAssertFalse(policy.fuseTripped(botId: "bot-a", now: 2_500))
        XCTAssertFalse(policy.fuseTripped(botId: "bot-b", now: 1_999))

        var ignored = ProactivityPolicy(configuration: ProactivePolicyConfiguration(
            fuseWindowMs: 1_000, fuseMaxWakeups: 1))
        ignored.restore(AcceptedConsideration(at: 1_000, kind: .taskDone,
                                              botId: "bot-a", fuseRecorded: false))
        XCTAssertFalse(ignored.fuseTripped(botId: "bot-a", now: 1_500))
    }

    private func run(_ testCase: [String: Any]) async throws -> [ProactiveDecision] {
        let settingsObject = try dictionary(testCase["settings"])
        let decodedSettings = try settings(settingsObject)
        let configuration = try policy(settingsObject)
        let kinds = deliveryKinds(settingsObject)
        let deliverer = ProactiveVectorDeliverer()
        let nilDeliverer = (testCase["deliverer"] as? String) == "none"
        let clock = WP6Clock(0)
        let engine = ProactiveEngine(
            settings: { decodedSettings },
            now: { clock.now },
            policy: configuration,
            deliverer: nilDeliverer ? nil : deliverer,
            deliveryKinds: kinds)
        var decisions: [ProactiveDecision] = []
        for step in try array(testCase["steps"]) {
            clock.set(try int64(step["at"]))
            if !nilDeliverer {
                deliverer.set(try deliveryMode(step["deliverer"]))
            }
            decisions.append(await engine.consider(try candidate(try dictionary(step["candidate"]))))
        }
        return decisions
    }

    private func decisionJSON(_ decision: ProactiveDecision) -> [String: Any] {
        var value: [String: Any] = [
            "id": decision.id,
            "at": decision.at,
            "decision": decision.decision.rawValue,
            "reason": decision.reason,
            "mode": decision.mode.rawValue,
            "channel": decision.channel,
        ]
        if let kind = decision.kind { value["kind"] = kind.rawValue }
        if let botId = decision.botId { value["botId"] = botId }
        if let dedupeKey = decision.dedupeKey { value["dedupeKey"] = dedupeKey }
        if let notification = decision.notification {
            value["notification"] = notificationJSON(notification)
        }
        if let delivery = decision.delivery {
            value["delivery"] = deliveryJSON(delivery)
        }
        if let commitSeq = decision.commitSeq { value["commitSeq"] = commitSeq }
        return value
    }

    private func notificationJSON(_ notification: ProactiveNotification) -> [String: Any] {
        var value: [String: Any] = [
            "title": notification.title,
            "body": notification.body,
            "kind": notification.kind.rawValue,
            "botId": notification.botId,
            "dedupeKey": notification.dedupeKey,
            "channel": notification.channel,
        ]
        if let rowId = notification.rowId { value["rowId"] = rowId }
        if let deepLink = notification.deepLink { value["deepLink"] = deepLink }
        return value
    }

    private func deliveryJSON(_ delivery: ProactiveDeliveryResult) -> [String: Any] {
        var value: [String: Any] = [
            "delivered": delivery.delivered,
            "channel": delivery.channel,
        ]
        if let error = delivery.error { value["error"] = error }
        return value
    }

    private func canonical(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Routine due (§3.1)

    func testRoutineDueNotificationIsNotAProactiveDecision() async throws {
        let root = try fixture()
        let due = try dictionary(root["routineDue"])
        let cases = try array(due["cases"])
        XCTAssertFalse(cases.isEmpty)

        for testCase in cases {
            let input = try dictionary(testCase["input"])
            let expected = try dictionary(testCase["expect"])
            let notification = RoutineScheduledNotification(
                botId: try XCTUnwrap(input["botId"] as? String),
                routineId: try XCTUnwrap(input["routineId"] as? String),
                routineTitle: try XCTUnwrap(input["routineTitle"] as? String),
                fireAt: try int64(input["fireAt"]))
            XCTAssertEqual(notification.identifier, expected["identifier"] as? String)
            XCTAssertEqual(notification.botId, expected["botId"] as? String)
            XCTAssertEqual(notification.routineId, expected["routineId"] as? String)
            XCTAssertEqual(notification.title, expected["title"] as? String)
            XCTAssertEqual(notification.body, expected["body"] as? String)
            XCTAssertEqual(notification.fireAt, try int64(expected["fireAt"]))
            XCTAssertEqual(notification.deepLink, expected["deepLink"] as? String)
            XCTAssertEqual(BotRoutineDeepLink.parse(notification.deepLink)?.routineId,
                           notification.routineId)
            XCTAssertNil(BotNotificationDeepLink.parse(notification.deepLink))
            XCTAssertEqual(testCase["proactive"] as? Bool, false)
            XCTAssertEqual(testCase["consumesFuse"] as? Bool, false)
        }

        // Register due notifications through the real §3.1 scheduler, then run
        // the shared fuse case. A due notification must not add a fuse entry.
        let decisions = try dictionary(root["decisions"])
        let fuseCase = try XCTUnwrap(try array(decisions["valid"]).first {
            $0["name"] as? String == "fuse-allows-fourth-and-blocks-fifth"
        })
        let settingsObject = try dictionary(fuseCase["settings"])
        let decodedSettings = try settings(settingsObject)
        let fuseSteps = try array(fuseCase["steps"])
        let now = try int64(try XCTUnwrap(fuseSteps.first)["at"])
        let rootDirectory = try wp6TempDirectory(self)
        let machine = try wp6Machine(root: rootDirectory)
        let spy = ProactiveRoutineNotificationSpy()
        let scheduler = RoutineScheduler(
            botId: "bot-a",
            machine: machine,
            inbox: try wp6Inbox(root: rootDirectory),
            sink: WP6RoutineSink(),
            notifications: spy,
            runner: { _ in .success("done") },
            available: { _ in true },
            settings: { decodedSettings },
            now: { now })
        for index in 1...5 {
            _ = try await machine.create(
                botId: "bot-a",
                title: "Due \(index)",
                prompt: "due",
                schedule: .interval(everyMinutes: 30, timezone: "UTC"),
                now: now - 60_000,
                id: "due-\(index)")
        }
        try await scheduler.syncNotifications()
        let pending = await spy.pending()
        XCTAssertEqual(pending.count, 5)

        let actual = try await run(fuseCase)
        let expectedDecisions = try fuseSteps.map {
            try dictionary($0["expect"])["decision"] as? String
        }
        XCTAssertEqual(actual.map(\.decision.rawValue), expectedDecisions)
        let expectedLastReason = try dictionary(try XCTUnwrap(fuseSteps.last)["expect"])["reason"]
            as? String
        XCTAssertEqual(actual.last?.reason, expectedLastReason)
    }
}

// MARK: - Test doubles

private struct ProactiveVectorError: Error, CustomStringConvertible {
    let description: String
}

private struct ProactiveVectorFailure: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private final class ProactiveVectorDeliverer: ProactiveDelivering, @unchecked Sendable {
    enum Mode {
        case ok
        case result(ProactiveDeliveryResult)
        case failure(String)
    }

    private let lock = NSLock()
    private var nextMode: Mode = .ok
    private var recorded: [ProactiveNotification] = []

    var notifications: [ProactiveNotification] { lock.withLock { recorded } }

    func set(_ mode: Mode) {
        lock.withLock { nextMode = mode }
    }

    func deliver(_ notification: ProactiveNotification) async throws -> ProactiveDeliveryResult {
        let mode: Mode = lock.withLock {
            let current = nextMode
            nextMode = .ok
            recorded.append(notification)
            return current
        }
        switch mode {
        case .ok:
            return ProactiveDeliveryResult(delivered: true, channel: notification.channel)
        case .result(let result):
            return result
        case .failure(let message):
            throw ProactiveVectorFailure(message: message)
        }
    }
}

private actor ProactiveRoutineNotificationSpy: RoutineNotificationScheduling {
    private var scheduled: [String: RoutineScheduledNotification] = [:]

    func schedule(_ notification: RoutineScheduledNotification) async throws {
        scheduled[notification.identifier] = notification
    }

    func pendingIdentifiers(prefix: String) async -> [String] {
        scheduled.keys.filter { $0.hasPrefix(prefix) }.sorted()
    }

    func cancel(identifiers: [String]) async {
        for identifier in identifiers {
            scheduled.removeValue(forKey: identifier)
        }
    }

    func pending() -> [RoutineScheduledNotification] {
        scheduled.values.sorted { ($0.fireAt, $0.identifier) < ($1.fireAt, $1.identifier) }
    }
}
