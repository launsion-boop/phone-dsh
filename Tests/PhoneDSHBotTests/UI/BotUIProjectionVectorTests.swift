// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

/// Runs the shared P09 vectors through the real pure projection, retry policy
/// and head-slice quantiser. The vectors live in the repository, not in this
/// file; the app integration is a separate compile check.
final class BotUIProjectionVectorTests: XCTestCase {
    private func root() throws -> URL {
        try BotGoldenFixture.repositoryRoot(filePath: #filePath)
    }

    private func object(_ path: String) throws -> [String: Any] {
        let url = try root().appendingPathComponent(path)
        let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return try XCTUnwrap(value as? [String: Any], path)
    }

    private func int(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    private func int64(_ value: Any?) -> Int64? {
        (value as? NSNumber)?.int64Value
    }

    private func double(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private func bool(_ value: Any?) -> Bool? {
        (value as? NSNumber)?.boolValue
    }

    private func presentation(_ value: Any?) -> BotFishLifecyclePresentation? {
        guard let dictionary = value as? [String: Any] else { return nil }
        let raw = dictionary["fishState"] as? String ?? "idle"
        let state = BotFishLifecycle(rawValue: raw) ?? .idle
        var oneShot: BotFishOneShot?
        if let shot = dictionary["oneShot"] as? [String: Any],
           let rawState = shot["state"] as? String,
           let shotState = BotFishLifecycle(rawValue: rawState) {
            oneShot = BotFishOneShot(
                state: shotState,
                priority: int(shot["priority"]) ?? 0,
                startedAt: int64(shot["startedAt"]) ?? 0,
                endsAt: int64(shot["endsAt"]) ?? 0)
        }
        return BotFishLifecyclePresentation(fishState: state, oneShot: oneShot)
    }

    func testUIStateProjectionVectors() throws {
        let document = try object("spec/ui/v1/bot/golden/ui-state-vectors.json")
        let now = try XCTUnwrap(int64(document["now"]), "pinned now")
        let cases = try XCTUnwrap(document["cases"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(cases.count, 42)
        for testCase in cases {
            let id = testCase["id"] as? String ?? "?"
            let input = try XCTUnwrap(testCase["input"] as? [String: Any], id)
            let expected = try XCTUnwrap(testCase["expected"] as? [String: Any], id)
            let expectedFish = try XCTUnwrap(expected["fishState"] as? String,
                                             "\(id): expected.fishState")
            let actual = BotFishLifecycleProjection.resolve(
                pendingApprovalCount: int(input["pendingApprovalCount"]) ?? 0,
                running: bool(input["running"]) ?? false,
                idleSleeping: bool(input["idleSleeping"]) ?? false,
                livePresentation: presentation(input["livePresentation"]),
                durablePresentation: presentation(input["runtimePresentation"])
                    ?? BotFishLifecyclePresentation(),
                liveTurn: input["live"] is [String: Any],
                now: now)
            XCTAssertEqual(actual.rawValue, expectedFish, id)

            // The header renders the same projected value (§4.6).
            let header = try XCTUnwrap(expected["header"] as? [String: Any], id)
            XCTAssertEqual(header["fishState"] as? String,
                           actual.rawValue, "\(id): header must consume the projection")
        }
    }

    func testActionRetryVectors() throws {
        let document = try object("spec/ui/v1/bot/golden/ui-state-vectors.json")
        let cases = try XCTUnwrap(document["intentCases"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(cases.count, 6)
        for testCase in cases {
            let id = testCase["id"] as? String ?? "?"
            let intent = try XCTUnwrap(
                (testCase["action"] as? String).flatMap(BotUIActionRetry.Intent.init(rawValue:)),
                id)
            let card = try XCTUnwrap(
                (testCase["cardKind"] as? String).flatMap(BotUIActionRetry.CardKind.init(rawValue:)),
                id)
            let state = (testCase["state"] as? String).flatMap(BotUIActionRetry.KeyState.init(rawValue:))
            let accepted = try XCTUnwrap(bool(testCase["accepted"]), id)
            XCTAssertEqual(
                BotUIActionRetry.accepts(intent: intent, cardKind: card, state: state),
                accepted, id)
        }
    }

    func testHeadSliceVectors() throws {
        let trajectory = try object("spec/ui/v1/bot/fish/golden/trajectory.json")
        let section = try XCTUnwrap(trajectory["headSlice"] as? [String: Any])
        let profiles = try XCTUnwrap(section["profiles"] as? [String: Any])
        let standard = try XCTUnwrap(profiles["standard"] as? [String: Any])
        let lively = try XCTUnwrap(profiles["lively"] as? [String: Any])
        XCTAssertEqual(double(standard["quantum"]), BotFishHeadSlice.standardQuantum)
        XCTAssertEqual(double(lively["quantum"]), BotFishHeadSlice.livelyQuantum)

        let cases = try XCTUnwrap(section["cases"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(cases.count, 4)
        var inputsByProfile: [String: Set<[Double]>] = [:]
        for testCase in cases {
            let id = testCase["id"] as? String ?? "?"
            let profile = try XCTUnwrap(testCase["profile"] as? String, id)
            let quantum = BotFishHeadSlice.quantum(lively: profile == "lively")
            XCTAssertEqual(double(testCase["quantum"]), quantum,
                           "\(id): case quantum must be the profile quantum")
            let input = try XCTUnwrap(testCase["input"] as? [String: Any], id)
            let headX = try XCTUnwrap(double(input["headX"]), id)
            let headY = try XCTUnwrap(double(input["headY"]), id)
            let hairSway = try XCTUnwrap(double(input["hairSway"]), id)
            let earFlutter = try XCTUnwrap(double(input["earFlutter"]), id)
            inputsByProfile[profile, default: []].insert(
                [headX, headY, hairSway, earFlutter])

            let levels = BotFishHeadSlice.levels(
                headX: headX, headY: headY, hairSway: hairSway,
                earFlutter: earFlutter, quantum: quantum)
            let expectedLevels = try XCTUnwrap(testCase["levels"] as? [String: Any], id)
            XCTAssertEqual(levels.headX, int(expectedLevels["headX"]), "\(id).headX")
            XCTAssertEqual(levels.headY, int(expectedLevels["headY"]), "\(id).headY")
            XCTAssertEqual(levels.hairSway, int(expectedLevels["hairSway"]), "\(id).hairSway")
            XCTAssertEqual(levels.earFlutter, int(expectedLevels["earFlutter"]),
                           "\(id).earFlutter")

            let displacement = BotFishHeadSlice.displacement(levels, quantum: quantum)
            let expected = try XCTUnwrap(testCase["displacement"] as? [String: Any], id)
            let expectedHeadX = try XCTUnwrap(double(expected["headX"]),
                                              "\(id).displacement.headX")
            let expectedHeadY = try XCTUnwrap(double(expected["headY"]),
                                              "\(id).displacement.headY")
            let expectedHairSway = try XCTUnwrap(double(expected["hairSway"]),
                                                 "\(id).displacement.hairSway")
            let expectedEarFlutter = try XCTUnwrap(double(expected["earFlutter"]),
                                                   "\(id).displacement.earFlutter")
            XCTAssertEqual(displacement.headX, expectedHeadX, accuracy: 1e-12,
                           "\(id).displacement.headX")
            XCTAssertEqual(displacement.headY, expectedHeadY, accuracy: 1e-12,
                           "\(id).displacement.headY")
            XCTAssertEqual(displacement.hairSway, expectedHairSway, accuracy: 1e-12,
                           "\(id).displacement.hairSway")
            XCTAssertEqual(displacement.earFlutter, expectedEarFlutter, accuracy: 1e-12,
                           "\(id).displacement.earFlutter")
        }
        XCTAssertFalse(inputsByProfile["standard", default: []]
            .isDisjoint(with: inputsByProfile["lively", default: []]),
                       "one raw input must appear under both profiles")
    }
}
