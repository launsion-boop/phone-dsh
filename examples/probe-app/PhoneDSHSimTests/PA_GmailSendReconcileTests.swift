// SPDX-License-Identifier: MIT

import Foundation
@testable import ProbeKit
import XCTest

final class PA_GmailSendReconcileTests: XCTestCase {
    func testTimeoutMarksUnknownAndDoesNotRetry() async throws {
        let store = PA_GmailTokenStore(PA_GmailTokens())
        let transport = PA_GmailTransport()
        let client = GmailClient(tokens: PA_GmailManager(store: store, transport: transport,
                                                         scopes: [GmailScope.readOnly, GmailScope.compose]),
                                 transport: transport)
        let ledger = PA_GmailLedger()
        let coordinator = GmailWriteCoordinator(client: client, gate: PA_GmailAllowGate(), ledger: ledger,
                                                undoWindow: PA_GmailImmediateUndo())
        let input = GmailSendInput(kind: .new, draft: PA_GmailDraft())
        let grant = PA_GmailGrant(actions: [.read, .gmailSendNew],
                                  scopes: [GmailScope.readOnly, GmailScope.compose])
        let mandate = PA_GmailMandate(actions: [.gmailSendNew], recipients: ["friend@example.com"])
        await transport.enqueue("POST /gmail/v1/users/me/messages/send", result: .failure(GmailError.timeout))
        do {
            _ = try await coordinator.send(input, caller: .personalAgent(mandate: mandate), grant: grant,
                                           argumentsJSON: arguments(input))
            XCTFail("timeout must not report sent")
        } catch {
            XCTAssertEqual(error as? GmailError, .outcomeUnknown)
        }
        let records = await ledger.all
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].phase, .unknown)
        let requests = await transport.requests(for: "/gmail/v1/users/me/messages/send")
        XCTAssertEqual(requests.count, 1)
        struct Raw: Decodable { let raw: String }
        let raw = try GmailJSON.decoder.decode(Raw.self, from: requests[0].body ?? Data()).raw
        let plaintext = try XCTUnwrap(GmailMIME.plaintext(raw: raw))
        XCTAssertTrue(plaintext.contains("Message-ID: <\(records[0].id.uuidString.lowercased())@phone-dsh.invalid>"))
        XCTAssertTrue(plaintext.contains("X-PhoneDSH-Request-Digest: \(input.digest)"))
    }

    func testProcessKillRecoveryDoesNotSendAndNoMatchStaysUnknown() async throws {
        let input = GmailSendInput(kind: .new, draft: PA_GmailDraft())
        let intent = OperationIntent(toolName: "gmail.message.send", argumentsJSON: arguments(input),
                                     digest: "digest", mandateID: UUID())
        let record = OperationRecord(id: intent.id, intent: intent, phase: .committing)
        let ledger = PA_GmailLedger()
        await ledger.seed(record)
        let reading = PA_GmailReadingMock()
        await reading.enqueueSearch(GmailSearchResult(messages: [], nextPageToken: nil))
        let reconciler = GmailSendReconciler(client: reading, ledger: ledger)
        let result = await reconciler.reconcilePending()
        XCTAssertEqual(result[record.id], .unknown)
        let recoveredRecord = await ledger.record(record.id)
        XCTAssertEqual(recoveredRecord?.phase, .committing)
        let queries = await reading.sendSearchQueries
        XCTAssertEqual(queries.count, 1)
        XCTAssertTrue(queries[0].sentOnly)
        XCTAssertTrue(queries[0].gmailQuery.contains("rfc822msgid"))
    }

    func testReconcileMatchesOperationDigestAndCommitsReceipt() async throws {
        let input = GmailSendInput(kind: .new, draft: PA_GmailDraft())
        let intent = OperationIntent(toolName: "gmail.message.send", argumentsJSON: arguments(input),
                                     digest: "digest", mandateID: UUID())
        let record = OperationRecord(id: intent.id, intent: intent, phase: .unknown)
        let ledger = PA_GmailLedger()
        await ledger.seed(record)
        let sent = PA_GmailMessage(id: "provider-message", operationID: record.id.uuidString, digest: input.digest)
        let reading = PA_GmailReadingMock()
        await reading.enqueueSearch(GmailSearchResult(messages: [sent], nextPageToken: nil))
        let result = await GmailSendReconciler(client: reading, ledger: ledger).reconcile(record)
        guard case .reconciled(let receipt) = result else { return XCTFail("expected provider receipt") }
        XCTAssertEqual(receipt.providerObjectID, "provider-message")
        let recoveredRecord = await ledger.record(record.id)
        XCTAssertEqual(recoveredRecord?.phase, .reconciled)
    }

    func testFileOperationLedgerReconcilesUnknownToReconciled() async throws {
        let input = GmailSendInput(kind: .new, draft: PA_GmailDraft())
        let intent = OperationIntent(toolName: "gmail.message.send", argumentsJSON: arguments(input),
                                     digest: "digest", mandateID: UUID())
        let ledger = try FileOperationLedger(root: paTemporaryRoot())
        _ = try await ledger.prepare(intent)
        try await ledger.markCommitting(intent.id)
        try await ledger.markUnknown(intent.id, reason: "进程退出后的结果未知")

        let sent = PA_GmailMessage(id: "provider-message", operationID: intent.id.uuidString, digest: input.digest)
        let reading = PA_GmailReadingMock()
        await reading.enqueueSearch(GmailSearchResult(messages: [sent], nextPageToken: nil))
        let persisted = await ledger.record(id: intent.id)
        let record = try XCTUnwrap(persisted)
        let result = await GmailSendReconciler(client: reading, ledger: ledger).reconcile(record)

        guard case .reconciled = result else { return XCTFail("真实账本必须完成对账：\(result)") }
        let recovered = await ledger.record(id: intent.id)
        XCTAssertEqual(recovered?.phase, .reconciled)
        XCTAssertEqual(recovered?.receipt?.providerObjectID, "provider-message")
    }

    private func arguments(_ input: GmailSendInput) -> String {
        String(decoding: (try! GmailJSON.encoder.encode(input)), as: UTF8.self)
    }
}
