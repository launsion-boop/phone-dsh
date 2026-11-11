// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

final class MemoryErasureTests: XCTestCase {
    private var store: SQLiteDomainStore!
    private var root: URL!

    override func setUp() async throws {
        (store, root) = try makeMemoryTestStore()
    }

    override func tearDown() async throws {
        try? await store?.close()
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func context(botID: String, session: String = "gb-main") -> BotMemoryWriteContext {
        BotMemoryWriteContext(
            botID: botID,
            sessionID: session,
            authorKind: .chat,
            source: BotMemorySource(kind: .userTurn, sessionID: session),
            trust: .user)
    }

    @discardableResult
    private func write(
        _ memory: BotMemory, _ action: BotMemoryAction, path: String,
        content: String? = nil, expected: Int, botID: String = "main"
    ) async throws -> BotMemoryWriteResult {
        try await memory.write(
            BotMemoryWriteRequest(action: action, path: path, content: content,
                                  expectedVersion: expected),
            context: context(botID: botID))
    }

    private func appendConversationCopy(_ marker: String, botID: String = "main") async throws -> Int {
        let event = BotEvent(
            type: "conversation.user_message", eventId: "copy-\(UUID().uuidString)",
            time: MemoryTestFixtures.now,
            origin: .dsh(sessionId: "gb-main", seq: 3),
            traceId: "copy-\(UUID().uuidString)",
            principal: BotPrincipal(botId: botID, sessionId: "gb-main", kind: "chat"),
            causationId: nil, correlationId: nil,
            data: .object([
                "text": .string("please remember \(marker)"),
                "source": .object(["kind": .string("user"), "rpcId": .string("bot-1")]),
            ]))
        return try await store.append(event)
    }

    func testSingleDocumentErasureClearsAllVersionsCopiesAndDbBytes() async throws {
        let marker = "ERASE_MARKER_7F3A9"
        let memory = makeMemory(store: store, botID: "main")
        let first = try await write(memory, .write, path: "agent/notes/secret.md",
                                    content: "# Note\n- \(marker) v1", expected: 0)
        XCTAssertTrue(first.ok)
        let second = try await write(memory, .append, path: "agent/notes/secret.md",
                                     content: "\n- \(marker) v2", expected: 1)
        XCTAssertTrue(second.ok)
        let user = try await write(memory, .write, path: "user/profile.md",
                                   content: "unrelated shared fact", expected: 0)
        XCTAssertTrue(user.ok)
        let copySequence = try await appendConversationCopy(marker)

        let events = try await store.events(after: 0, limit: 100)
        let memorySequences = events.filter {
            ($0.type == "memory.document_written" || $0.type == "memory.document_deleted")
                && $0.data["path"]?.stringValue == "agent/notes/secret.md"
        }.compactMap(\.commitSeq)
        XCTAssertEqual(memorySequences.count, 2)

        let outcome = try await memory.erase(path: "agent/notes/secret.md")
        XCTAssertTrue(outcome.ok, outcome.error ?? "")
        XCTAssertEqual(outcome.scope, .agent)
        XCTAssertEqual(outcome.paths, ["agent/notes/secret.md"])
        XCTAssertEqual(outcome.removedDocuments, 1)
        XCTAssertEqual(outcome.removedVersions, 2)
        XCTAssertGreaterThanOrEqual(outcome.erasedEvents, 3)
        XCTAssertNotNil(outcome.erasureRecord)

        // Memory page / recall / injection no longer see it.
        if case .failure = try await memory.read(path: "agent/notes/secret.md") {
        } else {
            XCTFail("erased document must not be readable")
        }
        let versions = try await memory.versions(path: "agent/notes/secret.md")
        XCTAssertTrue(versions.isEmpty)
        let recall = try await memory.recall(marker, limit: 20, scope: nil)
        XCTAssertTrue(recall.isEmpty)
        let injection = try await memory.injection()
        XCTAssertFalse(injection.text.contains(marker))
        // The shared document is untouched.
        if case let .document(document) = try await memory.read(path: "user/profile.md") {
            XCTAssertEqual(document.content, "unrelated shared fact")
        } else {
            XCTFail("shared document must survive an agent erase")
        }

        // phone record: erased event references return an explicit error.
        let gateway = BotGateway(now: { MemoryTestFixtures.now })
        _ = try await gateway.issueSession(botId: "main", sessionId: "gb-main", kind: .chat)
        let recordService = BotRecordService(
            store: store, gateway: gateway, workspaceRoot: root,
            now: { MemoryTestFixtures.now })
        for sequence in memorySequences + [copySequence] {
            let output = await recordService.execute(
                arguments: ["read", "record://event/\(sequence)"],
                callerSessionID: "gb-main")
            XCTAssertEqual(output.exitCode, 1)
            XCTAssertTrue(output.stdout.contains("\"code\":\"record_erased\""), output.stdout)
            XCTAssertFalse(output.stdout.contains(marker))
        }
        let search = await recordService.execute(
            arguments: ["search", marker], callerSessionID: "gb-main")
        XCTAssertEqual(search.exitCode, 0)
        XCTAssertTrue(search.stdout.contains("\"hits\":[]"), search.stdout)
        XCTAssertFalse(search.stdout.contains("record://event/"))

        // The header/digest/sequence survive; the host authority still passes
        // its gapless-sequence and payload-digest verification.
        try await store.verifyIntegrity()
        let remaining = try await store.events(after: 0, limit: 100)
        XCTAssertEqual(remaining.map(\.commitSeq), Array(1...remaining.count))
        XCTAssertTrue(remaining.contains { $0.type == "erasure" })
        let erasedHeaders = remaining.filter {
            memorySequences.contains($0.commitSeq ?? 0) || $0.commitSeq == copySequence
        }
        XCTAssertEqual(erasedHeaders.count, memorySequences.count + 1)
        for event in erasedHeaders {
            XCTAssertTrue(event.isErasedPayload)
            XCTAssertNotNil(event.erasureCommitSeq)
        }

        // Direct file assertion: close, checkpoint, grep the SQLite bytes.
        try await store.close()
        store = nil
        let database = root.appendingPathComponent("domain.sqlite")
        let bytes = try Data(contentsOf: database)
        XCTAssertFalse(Self.contains(marker, in: bytes),
                       "erased plaintext must not remain in the SQLite file")
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: database.path + suffix)
            if let sidecarBytes = try? Data(contentsOf: sidecar) {
                XCTAssertFalse(Self.contains(marker, in: sidecarBytes),
                               "erased plaintext must not remain in \(suffix)")
            }
        }
    }

    func testScopeErasureKeepsOtherBotAndOtherRoot() async throws {
        let main = makeMemory(store: store, botID: "main")
        let other = makeMemory(store: store, botID: "bot-b")
        let marker = "SCOPE_ERASE_MARKER_9911"
        let mainAgent = try await write(main, .write, path: "agent/private.md",
                                        content: marker, expected: 0)
        XCTAssertTrue(mainAgent.ok)
        let mainUser = try await write(main, .write, path: "user/shared.md",
                                       content: "shared \(marker)", expected: 0)
        XCTAssertTrue(mainUser.ok)
        let otherAgent = try await write(other, .write, path: "agent/private.md",
                                         content: "other \(marker)", expected: 0, botID: "bot-b")
        XCTAssertTrue(otherAgent.ok)
        let otherUser = try await write(other, .write, path: "user/shared.md",
                                        content: "shared-from-b \(marker)", expected: 1, botID: "bot-b")
        XCTAssertTrue(otherUser.ok)

        let agentErase = try await main.erase(scope: .agent)
        XCTAssertTrue(agentErase.ok)
        XCTAssertGreaterThanOrEqual(agentErase.removedDocuments, 1)
        XCTAssertTrue(agentErase.paths.contains("agent/private.md"))
        if case .failure = try await main.read(path: "agent/private.md") {
        } else {
            XCTFail("main agent document must be erased")
        }
        let mainUserSurvives = try await main.documentExists(path: "user/shared.md")
        XCTAssertTrue(mainUserSurvives)
        if case let .document(document) = try await other.read(path: "agent/private.md") {
            XCTAssertTrue(document.content.contains(marker))
        } else {
            XCTFail("another Bot's agent document must survive")
        }

        let userErase = try await main.erase(scope: .user)
        XCTAssertTrue(userErase.ok)
        XCTAssertGreaterThanOrEqual(userErase.removedDocuments, 1)
        XCTAssertTrue(userErase.paths.contains("user/shared.md"))
        if case .failure = try await main.read(path: "user/shared.md") {
        } else {
            XCTFail("shared user document must be erased")
        }
        if case .failure = try await other.read(path: "user/shared.md") {
        } else {
            XCTFail("shared user document must be erased for every Bot")
        }
        try await store.verifyIntegrity()
    }

    func testObservationAndRedactionPayloadsPointingAtErasedRecordsAreCleared() async throws {
        let marker = "OBSERVATION_ERASE_MARKER_31"
        let memory = makeMemory(store: store, botID: "main")
        let written = try await write(memory, .write, path: "agent/notes/observed.md",
                                      content: "# Observed\n- \(marker)", expected: 0)
        XCTAssertTrue(written.ok)

        // A tool result carries both a copy of the text and the system-generated
        // observation envelope that points at the session line.
        let envelope = """
        <observation source="tool" origin="web" at="2026-11-12T00:00:00Z" owner="main" ref="record://session/gb-main#4">
        \(marker)
        </observation>
        """
        let toolResult = BotEvent(
            type: "conversation.tool_result",
            eventId: "tool-result-\(UUID().uuidString)",
            time: MemoryTestFixtures.now,
            origin: .dsh(sessionId: "gb-main", seq: 4),
            traceId: "tool-result-\(UUID().uuidString)",
            principal: BotPrincipal(botId: "main", sessionId: "gb-main", kind: "chat"),
            causationId: nil, correlationId: nil,
            data: .object([
                "sessionId": .string("gb-main"),
                "seq": .number(4),
                "message": .object([
                    "role": .string("tool"),
                    "toolCallId": .string("call-observed"),
                    "content": .array([
                        .object(["type": .string("text"), "text": .string(envelope)]),
                    ]),
                ]),
            ]))
        let toolSequence = try await store.append(toolResult)
        let redaction = BotEvent(
            type: "redaction.applied",
            eventId: "redaction-\(UUID().uuidString)",
            time: MemoryTestFixtures.now,
            origin: .dsh(sessionId: "gb-main", seq: 4),
            traceId: "redaction-\(UUID().uuidString)",
            principal: BotPrincipal(botId: "main", sessionId: "gb-main", kind: "chat"),
            causationId: nil, correlationId: nil,
            data: .object([
                "sessionId": .string("gb-main"),
                "seq": .number(4),
                "record": .string("record://event/\(toolSequence)"),
                "sessionRecord": .string("record://session/gb-main#4"),
                "rules": .array([.object([
                    "rule": .string("secret"),
                    "count": .number(1),
                ])]),
            ]))
        let redactionSequence = try await store.append(redaction)

        let outcome = try await memory.erase(path: "agent/notes/observed.md")
        XCTAssertTrue(outcome.ok, outcome.error ?? "")
        XCTAssertGreaterThanOrEqual(outcome.erasedEvents, 3)

        let events = try await store.events(after: 0, limit: 100)
        let bySequence = Dictionary(uniqueKeysWithValues: events.compactMap { event in
            event.commitSeq.map { ($0, event) }
        })
        for sequence in [toolSequence, redactionSequence] {
            XCTAssertTrue(bySequence[sequence]?.isErasedPayload == true,
                          "event \(sequence) payload must be erased")
        }
        let encoder = JSONEncoder()
        XCTAssertFalse(events.contains { event in
            guard !event.isErasedPayload,
                  let payload = try? encoder.encode(event.data),
                  let text = String(data: payload, encoding: .utf8) else { return false }
            return text.contains(marker)
        })
        try await store.verifyIntegrity()
    }

    /// Agent-scope erase is bounded by the target paths and the erasing Bot.
    /// A shared `user/` document whose content happens to contain a target
    /// document's unique marker is a *surviving* document, not a derived copy:
    /// before this regression the needle scan also cleared its version event,
    /// leaving a hole that made the next replay report `.corrupted`.
    func testAgentScopeEraseKeepsSharedUserDocumentAndReplaysWithoutCorruption() async throws {
        let marker = "SHARED_COPY_MARKER_7A9"
        let memory = makeMemory(store: store, botID: "main")
        // prepare() materializes the two empty INDEX documents as version 1.
        _ = try await memory.injection()
        let agentV2 = try await write(
            memory, .write, path: "agent/INDEX.md",
            content: "# Agent index\n- \(marker) v1", expected: 1)
        XCTAssertTrue(agentV2.ok)
        let agentV3 = try await write(
            memory, .append, path: "agent/INDEX.md",
            content: "\n- \(marker) v2", expected: 2)
        XCTAssertTrue(agentV3.ok)

        let userV2 = try await write(
            memory, .write, path: "user/INDEX.md",
            content: "# User index\n- baseline", expected: 1)
        XCTAssertTrue(userV2.ok)
        let userV3 = try await write(
            memory, .write, path: "user/INDEX.md",
            content: "# User index\n- copied observation: \(marker) v2", expected: 2)
        XCTAssertTrue(userV3.ok)
        let userV4 = try await write(
            memory, .write, path: "user/INDEX.md",
            content: "# User index\n- baseline\n- copied observation: \(marker) v2\n- still here", expected: 3)
        XCTAssertTrue(userV4.ok)

        let erased = try await memory.erase(scope: .agent)
        XCTAssertTrue(erased.ok, erased.error ?? "")
        XCTAssertEqual(erased.scope, .agent)
        XCTAssertEqual(erased.paths, ["agent/INDEX.md"])

        // A fresh process replays the whole log. The shared document and
        // every surviving version must still be there; no `.corrupted`.
        let database = root.appendingPathComponent("domain.sqlite")
        try await store.close()
        store = try SQLiteDomainStore(fileURL: database, now: { MemoryTestFixtures.now })
        let reopened = makeMemory(
            store: store, botID: "main", now: MemoryTestFixtures.now + 1_000)
        let documents = try await reopened.documents(scope: nil)
        // Missing INDEX documents are re-materialized empty by prepare(); the
        // erased content must be gone, not merely the path.
        let agentIndex = documents.first { $0.path == "agent/INDEX.md" }
        XCTAssertEqual(agentIndex?.content, "# Index")
        XCTAssertFalse(documents.contains { $0.path == "agent/INDEX.md" && $0.content.contains(marker) })
        let userIndex = try XCTUnwrap(documents.first { $0.path == "user/INDEX.md" })
        XCTAssertEqual(userIndex.content, "# User index\n- baseline\n- copied observation: \(marker) v2\n- still here")
        let versions = try await reopened.versions(path: "user/INDEX.md")
        XCTAssertEqual(versions.map(\.version), [1, 2, 3, 4],
                       "an agent-scope erase must not erase a shared user document version")

        // The re-materialized index is a normal new document version.
        let rewritten = try await write(
            reopened, .write, path: "agent/INDEX.md",
            content: "# Agent index\n- rebuilt", expected: 1)
        XCTAssertTrue(rewritten.ok)
        XCTAssertEqual(rewritten.version, 2)
        let userNext = try await write(
            reopened, .write, path: "user/INDEX.md",
            content: "# User index\n- updated", expected: 4)
        XCTAssertTrue(userNext.ok)
        XCTAssertEqual(userNext.version, 5)
        try await store.verifyIntegrity()
    }

    /// Physical erasure is the only legal way a payload becomes NULL. Replay
    /// must treat such an event as a tombstone, not as evidence that the log
    /// is corrupt: a later version may continue after erased versions.
    func testReplayTreatsAnErasedDocumentVersionAsATombstone() async throws {
        let memory = makeMemory(store: store, botID: "main")
        // prepare() materializes the empty INDEX as version 1.
        _ = try await memory.injection()
        for version in 1..<4 {
            let result = try await write(
                memory, .write, path: "user/INDEX.md",
                content: "# Index\n- v\(version + 1)", expected: version)
            XCTAssertTrue(result.ok)
        }
        let events = try await store.events(after: 0, limit: 100)
        let secondSequence = try XCTUnwrap(events.first {
            $0.type == "memory.document_written"
                && $0.data["path"]?.stringValue == "user/INDEX.md"
                && $0.data["version"]?.intValue == 2
        }?.commitSeq)
        // Simulate the legacy shape produced before the scope fix: one
        // surviving document version was cleared without a target path. It is
        // still a legal tombstone, so replay must skip it.
        let data = BotErasureEventData(
            erasureId: "erasure-legacy-hole",
            reason: "memory-scope-erase",
            atMS: MemoryTestFixtures.now,
            targets: [BotErasureEventData.Target(kind: "memory", scope: "agent")])
        let event = BotEvent(
            type: "erasure",
            eventId: "erasure-legacy-hole",
            time: MemoryTestFixtures.now,
            origin: .local(source: "user"),
            traceId: "trace-erasure-legacy-hole",
            principal: BotPrincipal(botId: "main", sessionId: nil, kind: "ipc"),
            causationId: nil,
            correlationId: nil,
            data: try Self.encode(data))
        _ = try await store.erasePayloads(
            [secondSequence], erasureEvent: event, atMS: MemoryTestFixtures.now)

        let database = root.appendingPathComponent("domain.sqlite")
        try await store.close()
        store = try SQLiteDomainStore(fileURL: database, now: { MemoryTestFixtures.now })
        let reopened = makeMemory(store: store, botID: "main")
        let documents = try await reopened.documents(scope: .user)
        let userIndex = try XCTUnwrap(documents.first { $0.path == "user/INDEX.md" })
        XCTAssertEqual(userIndex.content, "# Index\n- v4")
        XCTAssertEqual(userIndex.version, 4)
        let survivingVersions = try await reopened.versions(path: "user/INDEX.md")
        XCTAssertEqual(survivingVersions.map(\.version), [1, 3, 4])
        let next = try await write(
            reopened, .append, path: "user/INDEX.md", content: "\n- v5", expected: 4)
        XCTAssertTrue(next.ok)
        XCTAssertEqual(next.version, 5)
    }

    private static func encode<T: Encodable>(_ value: T) throws -> BotJSONValue {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try BotJSONValue.parse(encoder.encode(value))
    }

    func testEraseIsIdempotentAndReplayDoesNotResurrect() async throws {
        let marker = "IDEMPOTENT_ERASE_MARKER_22"
        let memory = makeMemory(store: store, botID: "main")
        let written = try await write(memory, .write, path: "agent/a.md",
                                      content: marker, expected: 0)
        XCTAssertTrue(written.ok)
        let first = try await memory.erase(path: "agent/a.md")
        XCTAssertTrue(first.ok)
        let second = try await memory.erase(path: "agent/a.md")
        XCTAssertFalse(second.ok)
        XCTAssertEqual(second.error, "memory-not-found")

        let reopened = makeMemory(store: store, botID: "main")
        if case .failure = try await reopened.read(path: "agent/a.md") {
        } else {
            XCTFail("replay must not resurrect the erased document")
        }
        let recall = try await reopened.recall(marker, limit: 20, scope: nil)
        XCTAssertTrue(recall.isEmpty)
        let events = try await store.events(after: 0, limit: 100)
        XCTAssertEqual(events.filter { $0.type == "erasure" }.count, 1)
    }

    private static func contains(_ needle: String, in data: Data) -> Bool {
        data.range(of: Data(needle.utf8)) != nil
    }
}

private extension BotMemory {
    func documentExists(path: String) async throws -> Bool {
        if case .document = try await read(path: path) { return true }
        return false
    }
}
