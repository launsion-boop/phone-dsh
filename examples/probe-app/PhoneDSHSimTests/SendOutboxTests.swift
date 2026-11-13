// SPDX-License-Identifier: MIT
// W1-C: durable outbox state machine and the five crash points from
// spec/host/v1/README.md section 10. A crash is modelled by dropping the actor
// and opening a new one on the same directory.

import XCTest
import ProbeKit

final class SendOutboxTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-outbox-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func freshQueue() -> SendOutbox { SendOutbox(directory: root) }

    func testEnqueueUsesLowercaseUUIDv4AndPersists() async throws {
        let entry = try await freshQueue().enqueue(sessionID: "gb-main", text: "hello")
        XCTAssertTrue(SendOutbox.isValidRpcId(entry.rpcId))
        XCTAssertEqual(entry.rpcId, entry.rpcId.lowercased())
        XCTAssertEqual(entry.state, .queued)
        XCTAssertEqual(entry.attempts, 0)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("\(entry.rpcId).json").path))

        // A new process sees the same entry and never invents a new rpcId.
        let reopenedEntry = await freshQueue().entry(rpcId: entry.rpcId)
        let reopened = try XCTUnwrap(reopenedEntry)
        XCTAssertEqual(reopened, entry)
    }

    func testFiveCrashPointsNeitherLoseNorDuplicate() async throws {
        // 1. Before the file write: nothing was accepted and nothing exists.
        var queue = freshQueue()
        let initial = await queue.entries()
        XCTAssertTrue(initial.isEmpty)

        // 2. After the write, before submit.
        let queued = try await queue.enqueue(sessionID: "gb-main", text: "one")
        queue = freshQueue()
        let queuedReplay = await queue.entry(rpcId: queued.rpcId)
        XCTAssertEqual(queuedReplay?.state, .queued)

        // 3. Mid-submit.
        _ = try await queue.markSubmitting(rpcId: queued.rpcId)
        queue = freshQueue()
        let submittingReplay = await queue.entry(rpcId: queued.rpcId)
        XCTAssertEqual(submittingReplay?.state, .submitting)
        XCTAssertEqual(submittingReplay?.attempts, 1)

        // 4. Accepted, before durable.
        _ = try await queue.markAccepted(rpcId: queued.rpcId)
        queue = freshQueue()
        let acceptedReplay = await queue.entry(rpcId: queued.rpcId)
        XCTAssertEqual(acceptedReplay?.state, .accepted)
        let deleted = try await queue.observeAuthoritativeUserMessage(rpcId: queued.rpcId)
        XCTAssertTrue(deleted)
        let afterDelete = await queue.entry(rpcId: queued.rpcId)
        XCTAssertNil(afterDelete)

        // 5. Durable, before the delete: the leftover file is removed on the
        // next scan, and the entry never becomes a second message.
        let durable = try await queue.enqueue(sessionID: "gb-main", text: "two")
        _ = try await queue.markSubmitting(rpcId: durable.rpcId)
        _ = try await queue.markAccepted(rpcId: durable.rpcId)
        _ = try await queue.markDurable(rpcId: durable.rpcId)
        queue = freshQueue()
        let durableReplay = await queue.entry(rpcId: durable.rpcId)
        XCTAssertEqual(durableReplay?.state, .durable)
        let removed = try await queue.deleteIfDurable(rpcId: durable.rpcId)
        XCTAssertTrue(removed)
        let afterDurableDelete = await queue.entry(rpcId: durable.rpcId)
        XCTAssertNil(afterDurableDelete)
    }

    func testOutcomeUnknownNeverResendsAndRequeuesOnlyAfterProof() async throws {
        let queue = freshQueue()
        let entry = try await queue.enqueue(sessionID: "gb-main", text: "maybe")
        _ = try await queue.markSubmitting(rpcId: entry.rpcId)
        let unknown = try await queue.markOutcomeUnknown(
            rpcId: entry.rpcId, lastError: "transport closed after write")
        XCTAssertEqual(unknown.state, .outcomeUnknown)
        XCTAssertEqual(unknown.lastError, "transport closed after write")

        // No transition can resend directly from outcomeUnknown.
        do {
            _ = try await queue.markSubmitting(rpcId: entry.rpcId)
            XCTFail("outcomeUnknown must not submit")
        } catch {
            XCTAssertEqual(error as? SendOutboxError,
                           SendOutboxError.illegalTransition(from: .outcomeUnknown,
                                                              to: .submitting))
        }

        // Read-back found it: accepted, then durable and deleted.
        _ = try await queue.markAccepted(rpcId: entry.rpcId)
        let observed = try await queue.observeAuthoritativeUserMessage(rpcId: entry.rpcId)
        XCTAssertTrue(observed)
        let gone = await queue.entry(rpcId: entry.rpcId)
        XCTAssertNil(gone)

        // Read-back proved it absent: same rpcId goes back to queued.
        let second = try await queue.enqueue(sessionID: "gb-main", text: "again")
        _ = try await queue.markSubmitting(rpcId: second.rpcId)
        _ = try await queue.markOutcomeUnknown(rpcId: second.rpcId, lastError: "cut")
        let requeued = try await queue.requeue(rpcId: second.rpcId)
        XCTAssertEqual(requeued.rpcId, second.rpcId)
        XCTAssertEqual(requeued.state, .queued)
    }

    func testIllegalTransitionsAndDeleteGuard() async throws {
        let queue = freshQueue()
        let entry = try await queue.enqueue(sessionID: "gb-main", text: "x")
        do {
            _ = try await queue.markDurable(rpcId: entry.rpcId)
            XCTFail("queued → durable is illegal")
        } catch {
            XCTAssertEqual(error as? SendOutboxError,
                           SendOutboxError.illegalTransition(from: .queued,
                                                              to: .durable))
        }
        do {
            _ = try await queue.deleteIfDurable(rpcId: entry.rpcId)
            XCTFail("accepted/queued must not delete")
        } catch {
            XCTAssertEqual(error as? SendOutboxError,
                           SendOutboxError.deleteRequiresDurable(.queued))
        }
    }

    func testPerSessionFIFOAndIndependentSessions() async throws {
        let queue = freshQueue()
        let first = try await queue.enqueue(
            sessionID: "a", text: "1", now: Date(timeIntervalSince1970: 1))
        let second = try await queue.enqueue(
            sessionID: "a", text: "2", now: Date(timeIntervalSince1970: 2))
        let other = try await queue.enqueue(
            sessionID: "b", text: "3", now: Date(timeIntervalSince1970: 1.5))
        let ordered = await queue.pending(sessionID: "a")
        XCTAssertEqual(ordered.map(\.rpcId), [first.rpcId, second.rpcId])
        let otherPending = await queue.pending(sessionID: "b")
        XCTAssertEqual(otherPending.map(\.rpcId), [other.rpcId])
    }

    func testSchemaShapeRejectsInvalidInput() async throws {
        let queue = freshQueue()
        do {
            _ = try await queue.enqueue(sessionID: "bad id", text: "x")
            XCTFail("invalid session id")
        } catch {
            XCTAssertEqual(error as? SendOutboxError, .invalidSessionId)
        }
        do {
            _ = try await queue.enqueue(sessionID: "gb-main", text: "")
            XCTFail("empty text")
        } catch {
            XCTAssertEqual(error as? SendOutboxError, .emptyText)
        }
        do {
            _ = try await queue.enqueue(sessionID: "gb-main", text: "x",
                                        rpcId: "not-a-uuid")
            XCTFail("invalid rpcId")
        } catch {
            XCTAssertEqual(error as? SendOutboxError, .invalidRpcId)
        }
        XCTAssertFalse(SendOutbox.isValidRpcId("3F2A1C4E-5B6D-4E8F-9A0B-1C2D3E4F5A6B"))
        XCTAssertFalse(SendOutbox.isValidRpcId("3f2a1c4e-5b6d-3e8f-9a0b-1c2d3e4f5a6b"))
        XCTAssertTrue(SendOutbox.isValidRpcId("3f2a1c4e-5b6d-4e8f-9a0b-1c2d3e4f5a6b"))
    }
}

// MARK: - Rev 3/4 attachment durability (PC-20261112-w1-browse-outbox)

extension SendOutboxTests {
    private func attachmentInput(
        id: String = "att-1",
        name: String = "photo.png",
        mime: String = "image/png",
        bytes: Data = Data("image-bytes".utf8)
    ) -> SendOutboxAttachmentInput {
        SendOutboxAttachmentInput(id: id, kind: .image, contentType: mime,
                                  filename: name, data: bytes)
    }

    private func attachmentFile(_ entry: SendOutboxEntry,
                                _ attachment: SendOutboxAttachment) -> URL {
        root.appendingPathComponent(attachment.storePath)
    }

    private func entryFile(_ rpcId: String) -> URL {
        root.appendingPathComponent("\(rpcId).json")
    }

    private func writeRaw(_ object: [String: Any], rpcId: String) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: entryFile(rpcId))
    }

    private func readObject(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testAttachmentEnqueueWritesBytesBeforeEntryAndPersistsMetadata() async throws {
        let bytes = Data("image-bytes".utf8)
        let input = attachmentInput(bytes: bytes)
        let queue = freshQueue()
        let entry = try await queue.enqueue(sessionID: "gb-main", text: "look",
                                            attachments: [input])
        let attachment = try XCTUnwrap(entry.attachments?.first)
        XCTAssertEqual(entry.state, .queued)
        XCTAssertEqual(attachment.id, "att-1")
        XCTAssertEqual(attachment.kind, .image)
        XCTAssertEqual(attachment.byteSize, bytes.count)
        XCTAssertEqual(attachment.sha256, SendOutbox.sha256Hex(bytes))
        XCTAssertEqual(attachment.contentType, "image/png")
        XCTAssertEqual(attachment.filename, "photo.png")
        XCTAssertEqual(attachment.storePath, "attachments/\(entry.rpcId)/att-1")
        let file = attachmentFile(entry, attachment)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try Data(contentsOf: file), bytes)

        // The entry file is committed after the byte file exists and the
        // reopened process sees the same references without inventing an id.
        let reopened = await freshQueue().entry(rpcId: entry.rpcId)
        XCTAssertEqual(reopened?.attachments, entry.attachments)
        let loaded = try await freshQueue().verifiedAttachmentData(rpcId: entry.rpcId)
        XCTAssertEqual(loaded.map(\.data), [bytes])
    }

    func testFiveCrashPointsWithAttachmentsNeitherLoseNorDuplicate() async throws {
        let bytes = Data("crash-image".utf8)
        let input = attachmentInput(bytes: bytes)
        var queue = freshQueue()

        // 1. Before the file write: nothing was accepted and nothing exists.
        let initiallyEmpty = await queue.entries()
        XCTAssertTrue(initiallyEmpty.isEmpty)

        // 2. After the entry write, before submit.
        let queued = try await queue.enqueue(sessionID: "gb-main", text: "one",
                                             attachments: [input])
        queue = freshQueue()
        let queuedReplay = await queue.entry(rpcId: queued.rpcId)
        XCTAssertEqual(queuedReplay?.state, .queued)
        XCTAssertEqual(queuedReplay?.attachments?.first?.sha256,
                       SendOutbox.sha256Hex(bytes))
        let queuedBytes = try await queue.verifiedAttachmentData(rpcId: queued.rpcId)
        let firstLoaded = try XCTUnwrap(queuedBytes.first)
        XCTAssertEqual(firstLoaded.data, bytes)

        // 3. Mid-submit: a resumed process must not resend on its own.
        _ = try await queue.markSubmitting(rpcId: queued.rpcId)
        queue = freshQueue()
        let submittingReplay = await queue.entry(rpcId: queued.rpcId)
        XCTAssertEqual(submittingReplay?.state, .submitting)
        XCTAssertEqual(submittingReplay?.attempts, 1)

        // 4. Accepted, before durable: still a live entry and its bytes.
        _ = try await queue.markAccepted(rpcId: queued.rpcId)
        queue = freshQueue()
        let acceptedReplay = await queue.entry(rpcId: queued.rpcId)
        XCTAssertEqual(acceptedReplay?.state, .accepted)
        let acceptedEntry = try XCTUnwrap(acceptedReplay)
        let acceptedAttachment = try XCTUnwrap(acceptedEntry.attachments?.first)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: attachmentFile(acceptedEntry, acceptedAttachment).path))
        let deleted = try await queue.observeAuthoritativeUserMessage(rpcId: queued.rpcId)
        XCTAssertTrue(deleted)
        let afterObserve = await queue.entry(rpcId: queued.rpcId)
        XCTAssertNil(afterObserve)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: queue.attachmentDirectory(rpcId: queued.rpcId).path),
            "attachment directory must be unlinked after the entry is deleted")

        // 5. Durable, before the delete: the leftover file and its bytes are
        // removed on the next scan; the message is never appended twice.
        let durable = try await queue.enqueue(sessionID: "gb-main", text: "two",
                                              attachments: [input])
        _ = try await queue.markSubmitting(rpcId: durable.rpcId)
        _ = try await queue.markAccepted(rpcId: durable.rpcId)
        _ = try await queue.markDurable(rpcId: durable.rpcId)
        queue = freshQueue()
        let durableReplay = await queue.entry(rpcId: durable.rpcId)
        XCTAssertEqual(durableReplay?.state, .durable)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: queue.attachmentDirectory(rpcId: durable.rpcId).path))
        let removed = try await queue.deleteIfDurable(rpcId: durable.rpcId)
        XCTAssertTrue(removed)
        let afterDurableDelete = await queue.entry(rpcId: durable.rpcId)
        XCTAssertNil(afterDurableDelete)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: queue.attachmentDirectory(rpcId: durable.rpcId).path))
    }

    func testAttachmentValidationBlocksSubmitAndPreservesTheEntry() async throws {
        let queue = freshQueue()
        let entry = try await queue.enqueue(sessionID: "gb-main", text: "look",
                                            attachments: [attachmentInput()])
        let attachment = try XCTUnwrap(entry.attachments?.first)
        let file = attachmentFile(entry, attachment)
        try FileManager.default.removeItem(at: file)

        do {
            _ = try await queue.verifiedAttachmentData(rpcId: entry.rpcId)
            XCTFail("a missing attachment must not verify")
        } catch {
            XCTAssertEqual(error as? SendOutboxError, .attachmentMissing("att-1"))
        }
        try await queue.recordAttachmentFailure(rpcId: entry.rpcId, failure: .missing)
        let kept = await queue.entry(rpcId: entry.rpcId)
        XCTAssertEqual(kept?.state, .queued)
        XCTAssertEqual(kept?.attempts, 0)
        XCTAssertEqual(kept?.lastError, "attachment_missing")

        // Same byte count, different bytes: the digest must fail closed.
        try Data("image-bytez".utf8).write(to: file)
        do {
            _ = try await queue.verifiedAttachmentData(rpcId: entry.rpcId)
            XCTFail("a modified attachment must not verify")
        } catch {
            XCTAssertEqual(error as? SendOutboxError, .attachmentDigestMismatch("att-1"))
        }
        try await queue.recordAttachmentFailure(rpcId: entry.rpcId,
                                                failure: .digestMismatch)
        let stillQueued = await queue.entry(rpcId: entry.rpcId)
        XCTAssertEqual(stillQueued?.state, .queued)
        XCTAssertEqual(stillQueued?.lastError, "attachment_digest_mismatch")
        let stillPending = await queue.pending()
        XCTAssertEqual(stillPending.map(\.rpcId), [entry.rpcId],
                       "the entry must stay queued and must not be re-created")
    }

    func testRestartKeepsAttachmentEntryWhenBytesAreMissingOrModified() async throws {
        let queue = freshQueue()
        let entry = try await queue.enqueue(sessionID: "gb-main", text: "look",
                                            attachments: [attachmentInput()])
        let attachment = try XCTUnwrap(entry.attachments?.first)
        try Data("different!".utf8).write(to: attachmentFile(entry, attachment))

        // A fresh process still sees the same entry and rpcId. It does not
        // delete it, rewrite it, or fall back to a text-only message.
        let restarted = freshQueue()
        let replay = await restarted.entry(rpcId: entry.rpcId)
        XCTAssertEqual(replay?.state, .queued)
        XCTAssertEqual(replay?.rpcId, entry.rpcId)
        XCTAssertEqual(replay?.attachments, entry.attachments)
        let restartedPending = await restarted.pending()
        XCTAssertEqual(restartedPending.map(\.rpcId), [entry.rpcId])
        do {
            _ = try await restarted.verifiedAttachmentData(rpcId: entry.rpcId)
            XCTFail("modified bytes must block dispatch")
        } catch {
            XCTAssertEqual(error as? SendOutboxError, .attachmentDigestMismatch("att-1"))
        }
    }

    func testLegacyAttachmentFreeEntryStillDecodesAndDelivers() async throws {
        let rpcId = "3f2a1c4e-5b6d-4e8f-9a0b-1c2d3e4f5a6b"
        let legacy: [String: Any] = [
            "v": 1,
            "rpcId": rpcId,
            "sessionId": "gb-main",
            "text": "old text-only entry",
            "createdAtMs": 1794398651000,
            "state": "queued",
            "attempts": 0,
            "backend": "local",
        ]
        try writeRaw(legacy, rpcId: rpcId)
        let queue = freshQueue()
        let decoded = await queue.entry(rpcId: rpcId)
        let entry = try XCTUnwrap(decoded)
        XCTAssertNil(entry.attachments)
        _ = try await queue.markSubmitting(rpcId: rpcId)
        _ = try await queue.markAccepted(rpcId: rpcId)
        let observed = try await queue.observeAuthoritativeUserMessage(rpcId: rpcId)
        XCTAssertTrue(observed)
        let delivered = await queue.entry(rpcId: rpcId)
        XCTAssertNil(delivered)
    }

    func testOrphanAttachmentGCOnlyRemovesDirectoriesWithoutAnEntry() async throws {
        let queue = freshQueue()
        let entry = try await queue.enqueue(sessionID: "gb-main", text: "look",
                                            attachments: [attachmentInput()])
        let attachment = try XCTUnwrap(entry.attachments?.first)
        let keptFile = attachmentFile(entry, attachment)
        XCTAssertTrue(FileManager.default.fileExists(atPath: keptFile.path))

        let orphanId = UUID().uuidString.lowercased()
        let orphanDir = queue.attachmentDirectory(rpcId: orphanId)
        try FileManager.default.createDirectory(at: orphanDir,
                                                withIntermediateDirectories: true)
        try Data("orphan".utf8).write(to: orphanDir.appendingPathComponent("a"))

        let removed = await freshQueue().collectOrphanAttachments()
        XCTAssertEqual(removed, [orphanId])
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanDir.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: keptFile.path),
                      "bytes referenced by an entry are never GC'd")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: entryFile(entry.rpcId).path))
        let stillPending = await freshQueue().pending()
        XCTAssertEqual(stillPending.map(\.rpcId), [entry.rpcId])
    }

    func testDeleteOrderRefusesWhileQueuedAndRemovesBytesAfterDurable() async throws {
        let queue = freshQueue()
        let entry = try await queue.enqueue(sessionID: "gb-main", text: "look",
                                            attachments: [attachmentInput()])
        let attachment = try XCTUnwrap(entry.attachments?.first)
        do {
            _ = try await queue.deleteIfDurable(rpcId: entry.rpcId)
            XCTFail("queued entries must not be deleted")
        } catch {
            XCTAssertEqual(error as? SendOutboxError, .deleteRequiresDurable(.queued))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: entryFile(entry.rpcId).path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: attachmentFile(entry, attachment).path))

        _ = try await queue.markSubmitting(rpcId: entry.rpcId)
        _ = try await queue.markAccepted(rpcId: entry.rpcId)
        _ = try await queue.markDurable(rpcId: entry.rpcId)
        let deleted = try await queue.deleteIfDurable(rpcId: entry.rpcId)
        XCTAssertTrue(deleted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: entryFile(entry.rpcId).path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: queue.attachmentDirectory(rpcId: entry.rpcId).path))
    }

    func testStrictDecodeRejectsInlineBytesUnknownMembersAndWrongStorePath() async throws {
        let queue = freshQueue()
        let entry = try await queue.enqueue(sessionID: "gb-main", text: "look",
                                            attachments: [attachmentInput()])
        let original = try readObject(entryFile(entry.rpcId))

        var inline = original
        var inlineAttachments = try XCTUnwrap(inline["attachments"] as? [[String: Any]])
        inlineAttachments[0]["data"] = "aW1hZ2UtYnl0ZXM="
        inline["attachments"] = inlineAttachments
        try writeRaw(inline, rpcId: entry.rpcId)
        let inlineRead = await freshQueue().entry(rpcId: entry.rpcId)
        XCTAssertNil(inlineRead, "inline bytes are not part of the closed entry")

        var unknown = original
        unknown["dataBase64"] = "aW1hZ2UtYnl0ZXM="
        try writeRaw(unknown, rpcId: entry.rpcId)
        let unknownRead = await freshQueue().entry(rpcId: entry.rpcId)
        XCTAssertNil(unknownRead, "additionalProperties:false rejects unknown members")

        var wrongPath = original
        var wrongAttachments = try XCTUnwrap(wrongPath["attachments"] as? [[String: Any]])
        wrongAttachments[0]["storePath"] = "attachments/\(UUID().uuidString.lowercased())/att-1"
        wrongPath["attachments"] = wrongAttachments
        try writeRaw(wrongPath, rpcId: entry.rpcId)
        let wrongPathRead = await freshQueue().entry(rpcId: entry.rpcId)
        XCTAssertNil(wrongPathRead,
                     "storePath must name exactly attachments/<rpcId>/<attachmentId>")

        // Restoring the original entry makes it readable again.
        try writeRaw(original, rpcId: entry.rpcId)
        let restored = await freshQueue().entry(rpcId: entry.rpcId)
        XCTAssertEqual(restored?.rpcId, entry.rpcId)
    }

    func testAttachmentCountAndDuplicateIdsFailClosedBeforeWriting() async throws {
        let queue = freshQueue()
        let twentyOne = (0..<21).map { index in
            attachmentInput(id: "att-\(index)", bytes: Data("\(index)".utf8))
        }
        do {
            _ = try await queue.enqueue(sessionID: "gb-main", text: "too many",
                                        attachments: twentyOne)
            XCTFail("more than twenty are rejected by the closed schema")
        } catch {
            XCTAssertEqual(error as? SendOutboxError, .tooManyAttachments(21))
        }
        let afterTooMany = await queue.entries()
        XCTAssertTrue(afterTooMany.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: queue.attachmentsDirectory.path))

        // The host-declared fallback is 20, so exactly 20 is valid.
        let twenty = (0..<20).map { index in
            attachmentInput(id: "att-\(index)", bytes: Data("\(index)".utf8))
        }
        let accepted = try await queue.enqueue(sessionID: "gb-main", text: "",
                                                attachments: twenty)
        XCTAssertEqual(accepted.attachments?.count, 20)
        XCTAssertEqual(accepted.text, "")

        let duplicate = [attachmentInput(id: "same"), attachmentInput(id: "same")]
        do {
            _ = try await queue.enqueue(sessionID: "gb-main", text: "dupe",
                                        attachments: duplicate)
            XCTFail("duplicate attachment ids are rejected")
        } catch {
            XCTAssertEqual(error as? SendOutboxError, .duplicateAttachmentId("same"))
        }
    }

    func testEmptyTextIsAllowedOnlyWithAttachments() async throws {
        let queue = freshQueue()
        do {
            _ = try await queue.enqueue(sessionID: "gb-main", text: "")
            XCTFail("a text-only entry still requires text")
        } catch {
            XCTAssertEqual(error as? SendOutboxError, .emptyText)
        }

        let entry = try await queue.enqueue(sessionID: "gb-main", text: "",
                                            attachments: [attachmentInput()])
        XCTAssertEqual(entry.text, "")
        XCTAssertEqual(entry.attachments?.count, 1)
        let reopened = await queue.entry(rpcId: entry.rpcId)
        XCTAssertEqual(reopened?.text, "")
    }

    func testGeneratedEntryPassesTheOwningSchema() async throws {
        let queue = freshQueue()
        let entry = try await queue.enqueue(
            sessionID: "gb-main", text: "帮我看一下这张图",
            attachments: [
                attachmentInput(id: "att-1", name: "one.png",
                                bytes: Data("first-image".utf8)),
                SendOutboxAttachmentInput(id: "att-2", kind: .file,
                                          contentType: "application/pdf",
                                          filename: "report.pdf",
                                          data: Data("pdf-bytes".utf8)),
            ])
        let encoded = try Data(contentsOf: entryFile(entry.rpcId))
        let instance = try JSONSerialization.jsonObject(with: encoded)
        let schema = try loadOutboxSchema()
        let schemaText = try String(contentsOf: outboxSchemaURL(), encoding: .utf8)
        XCTAssertTrue(schemaText.contains("\"attachments\""),
                      "the checkout must contain PC-20261112-w1-browse-outbox rev 4")
        XCTAssertTrue(schemaText.contains("\"maxItems\""),
                      "rev 4 must carry the attachment count bound")
        let errors = schemaErrors(instance, schema: schema, path: "$", root: schema)
        XCTAssertTrue(errors.isEmpty, errors.joined(separator: "\n"))

        // Rev 4 also allows an attachment-only entry (empty text).
        let only = try await queue.enqueue(
            sessionID: "gb-main", text: "",
            attachments: [attachmentInput(id: "att-9", name: "only.png",
                                          bytes: Data("only".utf8))])
        let onlyData = try Data(contentsOf: entryFile(only.rpcId))
        let onlyInstance = try JSONSerialization.jsonObject(with: onlyData)
        let onlyErrors = schemaErrors(onlyInstance, schema: schema, path: "$",
                                      root: schema)
        XCTAssertTrue(onlyErrors.isEmpty, onlyErrors.joined(separator: "\n"))

        // Rev 4 raises the bound to 20; exactly 20 must be schema-valid.
        let twenty = (0..<20).map { index in
            attachmentInput(id: "att-20-\(index)",
                            bytes: Data("twenty-\(index)".utf8))
        }
        let twentyEntry = try await queue.enqueue(
            sessionID: "gb-main", text: "", attachments: twenty)
        let twentyData = try Data(contentsOf: entryFile(twentyEntry.rpcId))
        let twentyInstance = try JSONSerialization.jsonObject(with: twentyData)
        let twentyErrors = schemaErrors(twentyInstance, schema: schema, path: "$",
                                        root: schema)
        XCTAssertTrue(twentyErrors.isEmpty, twentyErrors.joined(separator: "\n"))
    }

    // MARK: - Minimal JSON Schema subset used by the outbox schema

    private func outboxSchemaURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // PhoneDSHSimTests
            .deletingLastPathComponent() // probe-app
            .deletingLastPathComponent() // examples
            .deletingLastPathComponent() // repository root
            .appendingPathComponent("spec/host/v1/schema/outbox-entry.schema.json")
    }

    private func loadOutboxSchema() throws -> [String: Any] {
        let data = try Data(contentsOf: outboxSchemaURL())
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func schemaErrors(_ value: Any, schema: [String: Any],
                              path: String, root: [String: Any]) -> [String] {
        var errors: [String] = []
        if let reference = schema["$ref"] as? String,
           reference.hasPrefix("#/") {
            var target: Any? = root
            for piece in reference.dropFirst(2).split(separator: "/") {
                guard let object = target as? [String: Any] else {
                    target = nil
                    break
                }
                target = object[String(piece)]
            }
            guard let targetSchema = target as? [String: Any] else {
                return ["\(path): unresolved $ref \(reference)"]
            }
            return schemaErrors(value, schema: targetSchema, path: path, root: root)
        }
        if let variants = schema["oneOf"] as? [[String: Any]] {
            let matches = variants.filter {
                schemaErrors(value, schema: $0, path: path, root: root).isEmpty
            }
            if matches.count != 1 {
                errors.append("\(path): must match exactly one oneOf variant (matched \(matches.count))")
            }
        }
        if let expected = schema["const"] {
            if !schemaEqual(value, expected) {
                errors.append("\(path): expected const \(expected)")
            }
        }
        if let allowed = schema["enum"] as? [Any] {
            if !allowed.contains(where: { schemaEqual(value, $0) }) {
                errors.append("\(path): value \(value) not in enum")
            }
        }
        if let type = schema["type"] as? String {
            switch type {
            case "object":
                guard let object = value as? [String: Any] else {
                    return errors + ["\(path): expected object"]
                }
                let properties = schema["properties"] as? [String: Any] ?? [:]
                let required = schema["required"] as? [String] ?? []
                for key in required where object[key] == nil {
                    errors.append("\(path): missing required \(key)")
                }
                let closed = (schema["additionalProperties"] as? Bool) == false
                for (key, child) in object {
                    guard let childSchema = properties[key] as? [String: Any] else {
                        if closed { errors.append("\(path): unknown member \(key)") }
                        continue
                    }
                    errors.append(contentsOf: schemaErrors(
                        child, schema: childSchema, path: "\(path).\(key)", root: root))
                }
            case "array":
                guard let array = value as? [Any] else {
                    return errors + ["\(path): expected array"]
                }
                if let minimum = schema["minItems"] as? Int, array.count < minimum {
                    errors.append("\(path): fewer than \(minimum) items")
                }
                if let maximum = schema["maxItems"] as? Int, array.count > maximum {
                    errors.append("\(path): more than \(maximum) items")
                }
                if let itemSchema = schema["items"] as? [String: Any] {
                    for (index, item) in array.enumerated() {
                        errors.append(contentsOf: schemaErrors(
                            item, schema: itemSchema, path: "\(path)[\(index)]", root: root))
                    }
                }
            case "string":
                guard let string = value as? String else {
                    return errors + ["\(path): expected string"]
                }
                if let minimum = schema["minLength"] as? Int,
                   string.unicodeScalars.count < minimum {
                    errors.append("\(path): shorter than \(minimum) characters")
                }
                if let maximum = schema["maxLength"] as? Int,
                   string.unicodeScalars.count > maximum {
                    errors.append("\(path): longer than \(maximum) characters")
                }
                if let pattern = schema["pattern"] as? String,
                   string.range(of: pattern, options: .regularExpression) == nil {
                    errors.append("\(path): does not match \(pattern)")
                }
            case "integer":
                guard let number = value as? NSNumber,
                      number.doubleValue.rounded() == number.doubleValue else {
                    return errors + ["\(path): expected integer"]
                }
                if let minimum = schema["minimum"] as? NSNumber,
                   number.doubleValue < minimum.doubleValue {
                    errors.append("\(path): below minimum \(minimum)")
                }
                if let maximum = schema["maximum"] as? NSNumber,
                   number.doubleValue > maximum.doubleValue {
                    errors.append("\(path): above maximum \(maximum)")
                }
            default:
                break
            }
        }
        return errors
    }

    private func schemaEqual(_ lhs: Any, _ rhs: Any) -> Bool {
        if let left = lhs as? String, let right = rhs as? String {
            return left == right
        }
        if let left = lhs as? NSNumber, let right = rhs as? NSNumber {
            return left.doubleValue == right.doubleValue
        }
        if let left = lhs as? Bool, let right = rhs as? Bool {
            return left == right
        }
        return false
    }
}
