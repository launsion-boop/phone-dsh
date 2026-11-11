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
