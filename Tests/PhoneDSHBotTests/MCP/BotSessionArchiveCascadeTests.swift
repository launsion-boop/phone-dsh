// SPDX-License-Identifier: MIT
//
// GAP-45: the delete cascade archives a Bot's sessions before it removes the profile record. When
// a later step fails the Bot stays, so the archive must be rolled back, or the Worker's
// archived-session gate ends every turn of the surviving Bot as `blocked`.

import Foundation
import XCTest
import PhoneDSHAgentCore
@testable import PhoneDSHBot

private final class ArchiveRegistryTransport: DSHRemoteTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var archived: [String]
    private var failing: Set<String>
    private(set) var calls: [String] = []

    init(archived: [String] = [], failing: Set<String> = []) {
        self.archived = archived
        self.failing = failing
    }

    var archivedIDs: [String] { lock.withLock { archived } }

    func call(_ endpoint: String, args: JSONValue) async throws -> JSONValue {
        let id = args["request"]?["sessionId"]?.stringValue ?? ""
        return try lock.withLock {
            calls.append("\(endpoint) \(id)")
            switch endpoint {
            case "workspace/archiveSession":
                if failing.contains(id) {
                    throw DSHRemoteError(code: "session/not-found", message: id)
                }
                if !archived.contains(id) { archived.append(id) }
            case "workspace/unarchiveSession":
                archived.removeAll { $0 == id }
            default:
                throw DSHRemoteError(code: "gateway/internal", message: endpoint)
            }
            return .object(["archivedSessionIds": .array(archived.map { .string($0) })])
        }
    }

    func openMux() async throws -> any DSHMuxConnection { throw DSHRemoteError(code: "x", message: "x") }
}

final class BotSessionArchiveCascadeTests: XCTestCase {
    func testRollbackLiftsTheArchiveOfASurvivingBotSession() async {
        let worker = ArchiveRegistryTransport()
        let receipt = await BotSessionArchiveCascade.archive(
            ["gb-agent-aaaa", "gb-agent-aaaa-old"], via: worker)
        XCTAssertEqual(worker.archivedIDs, ["gb-agent-aaaa", "gb-agent-aaaa-old"])
        XCTAssertEqual(receipt.archivedHere, ["gb-agent-aaaa", "gb-agent-aaaa-old"])

        // A later cascade step failed: the Bot stays, so its own session must be usable again.
        await BotSessionArchiveCascade.restore(receipt, via: worker)
        XCTAssertEqual(worker.archivedIDs, [])
    }

    func testRollbackNeverUnarchivesWhatWasArchivedBeforeTheCascade() async {
        // An old main-chat epoch archived by `rebuildMainSession` stays archived.
        let worker = ArchiveRegistryTransport(archived: ["gb-agent-aaaa-epoch1", "gb-other"])
        let receipt = await BotSessionArchiveCascade.archive(
            ["gb-agent-aaaa", "gb-agent-aaaa-epoch1"], via: worker)
        XCTAssertEqual(receipt.archivedHere, ["gb-agent-aaaa"])
        await BotSessionArchiveCascade.restore(receipt, via: worker)
        XCTAssertEqual(worker.archivedIDs, ["gb-agent-aaaa-epoch1", "gb-other"])
    }

    func testIdsTheWorkerRejectsAreNotInTheReceiptAndTheProbeSessionIsNeverArchived() async {
        let worker = ArchiveRegistryTransport(failing: ["gb-agent-aaaa-gone"])
        let receipt = await BotSessionArchiveCascade.archive(
            ["gb-agent-aaaa", "gb-agent-aaaa-gone"], via: worker)
        XCTAssertEqual(receipt.archivedHere, ["gb-agent-aaaa"])
        XCTAssertFalse(worker.archivedIDs.contains(BotSessionArchiveCascade.probeSessionID))
        XCTAssertFalse(worker.calls.contains("workspace/archiveSession \(BotSessionArchiveCascade.probeSessionID)"))
    }

    func testArchiveAndRestoreOnlyTouchTheNamedBotSessions() async {
        // The recreated device Bot has a fresh id; deleting the old one must not archive it.
        let worker = ArchiveRegistryTransport()
        _ = await BotSessionArchiveCascade.archive(["gb-agent-old"], via: worker)
        XCTAssertFalse(worker.archivedIDs.contains("gb-agent-new"))
    }
}
