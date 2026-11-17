// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

/// A02 routine producer: definition/update snapshot carriers must name the real
/// durable user/approval records, not a random or run-trigger ref.
final class RoutineDerivationTests: XCTestCase {
    private func storeAndMachine() throws -> (SQLiteDomainStore, RoutineMachine) {
        let root = try wp6TempDirectory(self)
        let store = try SQLiteDomainStore(fileURL: root.appendingPathComponent("domain.sqlite"))
        return (store, RoutineMachine(store: SQLiteRoutineStore(domainStore: store)))
    }

    private func appendUserMessage(_ store: SQLiteDomainStore, turn: String) async throws -> String {
        let seq = try await store.append(BotEvent(
            type: "conversation.user_message", eventId: "user-\(turn)", time: 1_000,
            origin: .local(source: "user"), traceId: "trace-\(turn)",
            principal: BotPrincipal(botId: "bot-a", sessionId: "s1", kind: "chat"),
            causationId: nil, correlationId: nil, turnId: turn,
            data: .object(["source": .object(["kind": .string("user")]),
                           "text": .string("remind me daily")])))
        return "record://event/\(seq)"
    }

    private func appendApproval(_ store: SQLiteDomainStore) async throws -> String {
        let seq = try await store.append(BotEvent(
            type: "approval.decided", eventId: "approval-1", time: 2_000,
            origin: .local(source: "user"), traceId: "trace-approval",
            principal: BotPrincipal(botId: "bot-a", sessionId: "s1", kind: "chat"),
            causationId: nil, correlationId: "approval-1",
            data: .object(["approvalId": .string("approval-1"),
                           "decision": .string("allowOnce")])))
        return "record://event/\(seq)"
    }

    private func latestRoutineEvent(_ store: SQLiteDomainStore, routineID: String) async throws -> BotEvent? {
        let events = try await store.events(after: 0, limit: 500)
        return events.last { event in
            guard ["routine.defined", "routine.updated"].contains(event.type),
                  case .object(let data) = event.data,
                  case .object(let document)? = data["document"],
                  case .array(let routines)? = document["routines"] else { return false }
            return routines.contains { $0["id"]?.stringValue == routineID }
        }
    }

    func testCreateNamesTheRealUserRecordAndKeepsItReadable() async throws {
        let (store, machine) = try storeAndMachine()
        let userRef = try await appendUserMessage(store, turn: "t1")
        _ = try await machine.create(
            botId: "bot-a", title: "Daily", prompt: "remind me",
            schedule: .interval(everyMinutes: 60, timezone: "UTC"),
            derivation: RoutineDerivationBuilder.fromUserTurn(userRef),
            now: 1_000, id: "routine-a02")
        let fetchedEvent = try await latestRoutineEvent(store, routineID: "routine-a02")
        let event = try XCTUnwrap(fetchedEvent)
        let derivation = try XCTUnwrap(event.data["derivation"])
        XCTAssertEqual(derivation["artifact"]?["kind"]?.stringValue, "routine")
        XCTAssertEqual(derivation["artifact"]?["id"]?.stringValue, "routine-a02")
        let source = try XCTUnwrap(derivation["sources"]?.arrayValue?.first)
        XCTAssertEqual(source["record"]?.stringValue, userRef)
        XCTAssertEqual(source["role"]?.stringValue, "evidence")
        // The ref resolves to the real user message event; no random ref.
        let seq = Int(userRef.dropFirst("record://event/".count))
        XCTAssertNotNil(seq)
    }

    func testUpdateKeepsUserAndApprovalRoles() async throws {
        let (store, machine) = try storeAndMachine()
        let userRef = try await appendUserMessage(store, turn: "t2")
        let approvalRef = try await appendApproval(store)
        _ = try await machine.create(
            botId: "bot-a", title: "Daily", prompt: "remind me",
            schedule: .interval(everyMinutes: 60, timezone: "UTC"),
            now: 1_000, id: "routine-a02")
        _ = try await machine.update(
            botId: "bot-a", routineId: "routine-a02",
            patch: RoutinePatch(title: "Daily updated"),
            derivation: RoutineDerivationBuilder.userTurnAndApproval(
                userTurn: userRef, approval: approvalRef),
            now: 2_000)
        let fetchedEvent = try await latestRoutineEvent(store, routineID: "routine-a02")
        let event = try XCTUnwrap(fetchedEvent)
        let sources = try XCTUnwrap(event.data["derivation"]?["sources"]?.arrayValue)
        XCTAssertEqual(Set(sources.compactMap { $0["role"]?.stringValue }),
                       ["evidence", "basis"])
        XCTAssertEqual(Set(sources.compactMap { $0["record"]?.stringValue }),
                       [userRef, approvalRef])
    }

    func testNoFactMeansNoDerivationAndRunTriggerIsNotContentEvidence() async throws {
        let (store, machine) = try storeAndMachine()
        _ = try await machine.create(
            botId: "bot-a", title: "No basis", prompt: "remind me",
            schedule: .interval(everyMinutes: 60, timezone: "UTC"),
            now: 1_000, id: "routine-a02-none")
        let fetchedEvent = try await latestRoutineEvent(store, routineID: "routine-a02-none")
        let event = try XCTUnwrap(fetchedEvent)
        XCTAssertNil(event.data["derivation"], "no fact content must stay unknown, not fabricated")
    }

    func testSyntheticOrMalformedRecordIsRejected() async throws {
        let (_, machine) = try storeAndMachine()
        do {
            _ = try await machine.create(
                botId: "bot-a", title: "Bad", prompt: "x",
                schedule: .interval(everyMinutes: 60, timezone: "UTC"),
                derivation: RoutineDerivation(sources: [
                    .init(record: "record://event/not-a-number", role: .evidence),
                ]),
                now: 1_000, id: "routine-bad")
            XCTFail("malformed derivation record must be rejected")
        } catch let error as RoutineError {
            guard case .invalidRoutine(_) = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }
}
