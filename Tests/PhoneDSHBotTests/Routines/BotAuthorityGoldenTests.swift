// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

/// Drives the real authority models with the shared phone-only vector. The
/// vector is the contract; this test is the runtime conformance evidence.
final class BotAuthorityGoldenTests: XCTestCase {
    private func jsonValue(_ object: [String: Any]) throws -> BotJSONValue {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try BotJSONValue.parse(data)
    }

    private func routine(from object: [String: Any]) throws -> Routine {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try JSONDecoder().decode(Routine.self, from: data)
    }

    private func authority(from object: [String: Any]) throws -> BotTurnAuthority {
        let origin = try XCTUnwrap(BotTurnOriginKind(rawValue: try XCTUnwrap(object["origin"] as? String)))
        return BotTurnAuthority(
            rpcId: object["rpcId"] as? String,
            turnId: object["turnId"] as? String,
            sessionId: try XCTUnwrap(object["sessionId"] as? String),
            origin: origin,
            isUserTurn: try XCTUnwrap(object["isUserTurn"] as? Bool),
            approvalID: object["approvalID"] as? String)
    }

    func testRoutineCreatorCases() throws {
        let fixture = try BotGoldenFixture.rawObject("authority.phone")
        let valid = try XCTUnwrap(fixture["valid"] as? [String: Any])
        let template = try XCTUnwrap(valid["routineTemplate"] as? [String: Any])
        let cases = try XCTUnwrap(valid["routineCreators"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)
        for testCase in cases {
            let name = testCase["name"] as? String ?? "?"
            var routineObject = template
            routineObject["creator"] = testCase["creator"]
            let decoded = try routine(from: routineObject)
            let creator = try XCTUnwrap(decoded.creator, name)
            let expected = try XCTUnwrap(testCase["expected"] as? [String: Any])
            XCTAssertEqual(creator.origin.rawValue, expected["creatorOrigin"] as? String, name)
            XCTAssertEqual(creator.authorization.rawValue,
                           expected["creatorAuthorization"] as? String, name)
            let expectedNeeds = try XCTUnwrap(expected["creationNeedsConfirmation"] as? Bool)
            XCTAssertEqual(!(creator.origin == .user), expectedNeeds, name)
            XCTAssertFalse(decoded.completionCriteria.isEmpty, name)
            XCTAssertFalse(decoded.constraints.isEmpty, name)
        }
    }

    func testInvalidRoutineCreatorsAreRejected() throws {
        let fixture = try BotGoldenFixture.rawObject("authority.phone")
        let valid = try XCTUnwrap(fixture["valid"] as? [String: Any])
        let template = try XCTUnwrap(valid["routineTemplate"] as? [String: Any])
        let invalid = try XCTUnwrap(fixture["invalid"] as? [[String: Any]])
            .filter { ($0["suite"] as? String) == "routine-schema" }
        XCTAssertFalse(invalid.isEmpty)
        for testCase in invalid {
            var routineObject = template
            routineObject["creator"] = testCase["creator"]
            let decoded: Routine?
            do {
                decoded = try routine(from: routineObject)
            } catch {
                continue
            }
            XCTAssertThrowsError(try decoded?.validated(), testCase["name"] as? String ?? "?")
        }
    }

    func testRoutineLooseningCases() throws {
        let fixture = try BotGoldenFixture.rawObject("authority.phone")
        let valid = try XCTUnwrap(fixture["valid"] as? [String: Any])
        let template = try XCTUnwrap(valid["routineTemplate"] as? [String: Any])
        let cases = try XCTUnwrap(valid["routineChanges"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)
        let now: Int64 = 1_760_000_000_000
        for testCase in cases {
            let name = testCase["name"] as? String ?? "?"
            var current = try routine(from: template)
            current.id = "routine-test"
            let currentFields = try XCTUnwrap(testCase["current"] as? [String: Any])
            if let scheduleObject = currentFields["schedule"] as? [String: Any] {
                current.schedule = try BotRoutineTool.schedule(try jsonValue(scheduleObject))
            }
            if let delivery = currentFields["delivery"] as? String {
                current.delivery = try XCTUnwrap(RoutineDeliveryMode(rawValue: delivery))
            }
            if let urgent = currentFields["urgent"] as? Bool { current.urgent = urgent }
            if let enabled = currentFields["enabled"] as? Bool { current.enabled = enabled }

            var patch = RoutinePatch()
            let patchFields = try XCTUnwrap(testCase["patch"] as? [String: Any])
            if let scheduleObject = patchFields["schedule"] as? [String: Any] {
                patch.schedule = try BotRoutineTool.schedule(try jsonValue(scheduleObject))
            }
            if let delivery = patchFields["delivery"] as? String {
                patch.delivery = try XCTUnwrap(RoutineDeliveryMode(rawValue: delivery))
            }
            if let urgent = patchFields["urgent"] as? Bool { patch.urgent = urgent }
            if let reason = patchFields["urgent_reason"] as? String { patch.urgentReason = reason }
            if let reason = patchFields["interrupt_reason"] as? String { patch.interruptReason = reason }
            if let enabled = patchFields["enabled"] as? Bool { patch.enabled = enabled }

            let expected = try XCTUnwrap(testCase["expectedConfirmation"] as? Bool)
            XCTAssertEqual(RoutineAuthority.isLoosening(current: current, patch: patch, now: now),
                           expected, name)
        }
    }

    func testTaskAuthorizationCases() throws {
        let fixture = try BotGoldenFixture.rawObject("authority.phone")
        let valid = try XCTUnwrap(fixture["valid"] as? [String: Any])
        let cases = try XCTUnwrap(valid["taskAuthorizations"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)
        for testCase in cases {
            let name = testCase["name"] as? String ?? "?"
            let requested = try XCTUnwrap(testCase["requested"] as? [String])
            let resolved = try BotTaskAuthorization.resolve(
                requestedDirectories: requested,
                workspaceRoot: try XCTUnwrap(testCase["workspaceRoot"] as? String))
            let expected = try XCTUnwrap(testCase["expected"] as? [String: Any])
            XCTAssertEqual(resolved.allowedWriteDirectories,
                           try XCTUnwrap(expected["allowedWriteDirectories"] as? [String]), name)
            XCTAssertEqual(resolved.canWriteOutsideWorkspace,
                           try XCTUnwrap(expected["canWriteOutsideWorkspace"] as? Bool), name)
            XCTAssertEqual(resolved.canNetworkWrite,
                           try XCTUnwrap(expected["canNetworkWrite"] as? Bool), name)
            XCTAssertEqual(resolved.canDelegateTasks,
                           try XCTUnwrap(expected["canDelegateTasks"] as? Bool), name)
        }

        let invalid = try XCTUnwrap(fixture["invalid"] as? [[String: Any]])
            .filter { ($0["suite"] as? String) == "task-authorization" }
        XCTAssertFalse(invalid.isEmpty)
        for testCase in invalid {
            let requested = try XCTUnwrap(testCase["requested"] as? [String])
            XCTAssertThrowsError(try BotTaskAuthorization.resolve(
                requestedDirectories: requested,
                workspaceRoot: try XCTUnwrap(testCase["workspaceRoot"] as? String)),
                testCase["name"] as? String ?? "?")
        }
    }

    func testTeammateAuthorCases() throws {
        let fixture = try BotGoldenFixture.rawObject("authority.phone")
        let valid = try XCTUnwrap(fixture["valid"] as? [String: Any])
        let cases = try XCTUnwrap(valid["teammateAuthors"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)
        for testCase in cases {
            let name = testCase["name"] as? String ?? "?"
            let turn = try authority(from: try XCTUnwrap(testCase["authority"] as? [String: Any]))
            let expected = try XCTUnwrap(testCase["expected"] as? [String: Any])
            if turn.isUserTurn {
                let author = try XCTUnwrap(BotTeammateAuthor(authority: turn), name)
                XCTAssertEqual(author.authorization.rawValue,
                               expected["authorization"] as? String, name)
                XCTAssertNil(author.approvalID, name)
            } else {
                var withoutApproval = turn
                withoutApproval.approvalID = nil
                XCTAssertNil(BotTeammateAuthor(authority: withoutApproval),
                             "\(name): a non-user author without approvalID must be refused")
                var approved = turn
                approved.approvalID = expected["approvalID"] as? String
                let author = try XCTUnwrap(BotTeammateAuthor(authority: approved), name)
                XCTAssertEqual(author.authorization.rawValue,
                               expected["authorization"] as? String, name)
                XCTAssertEqual(author.approvalID, expected["approvalID"] as? String, name)
            }
        }
    }
}
