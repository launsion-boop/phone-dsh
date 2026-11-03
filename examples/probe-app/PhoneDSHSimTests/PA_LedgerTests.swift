// SPDX-License-Identifier: MIT

import Foundation
import ProbeKit
import XCTest

private actor PAReceiptReconciler: OperationReconciling {
    let connectorID: String
    private var receipts: [UUID: ProviderReceipt?]
    private(set) var lookedUp: [UUID] = []

    init(connectorID: String = "gmail", receipts: [UUID: ProviderReceipt?] = [:]) {
        self.connectorID = connectorID
        self.receipts = receipts
    }

    func reconcile(_ record: OperationRecord) async throws -> ProviderReceipt? {
        lookedUp.append(record.id)
        return receipts[record.id] ?? nil
    }
}

final class PA_LedgerTests: XCTestCase {
    func testPrepareFreezesIntentAndCommitRequiresProviderReceiptAndState() async throws {
        let ledger = try FileOperationLedger(root: paTemporaryRoot(), now: { paFixedDate })
        let intent = paIntent()
        let prepared = try await ledger.prepare(intent)
        XCTAssertEqual(prepared.intent.argumentsJSON, intent.argumentsJSON)
        XCTAssertEqual(prepared.intent.digest, intent.digest)
        do {
            try await ledger.commit(intent.id, receipt: ProviderReceipt(providerObjectID: "message-1", rawJSON: "{}"))
            XCTFail("prepared 不能跳过 committing")
        } catch {
            XCTAssertEqual(error as? OperationLedgerError, .invalidTransition(.prepared, .committed))
        }
        try await ledger.markCommitting(intent.id)
        do {
            try await ledger.commit(intent.id, receipt: ProviderReceipt(providerObjectID: "", rawJSON: "{}"))
            XCTFail("空 provider 回执不能提交")
        } catch {
            XCTAssertEqual(error as? OperationLedgerError, .invalidReceipt)
        }
        try await ledger.commit(intent.id, receipt: ProviderReceipt(providerObjectID: "message-1", rawJSON: "{}"))
        paAssertEqual(await ledger.record(id: intent.id)?.phase, .committed)
        paAssertEqual(await ledger.record(id: intent.id)?.receipt?.providerObjectID, "message-1")
    }

    func testKillBeforeCommitCancelsAndNeverCallsProviderAfterRecovery() async throws {
        let root = paTemporaryRoot()
        let ledger = try FileOperationLedger(root: root, now: { paFixedDate })
        let intent = paIntent()
        _ = try await ledger.prepare(intent)
        _ = try await ledger.beginUndoWindow(intent.id)

        let restarted = try FileOperationLedger(root: root, now: { paFixedDate })
        let pending = try await restarted.recoverAfterProcessRestart()
        XCTAssertTrue(pending.isEmpty)
        paAssertEqual(await restarted.record(id: intent.id)?.phase, .cancelled)
        let providerCalls = PACounter()
        let recovery = OperationRecovery(ledger: restarted, breaker: try CircuitBreaker(root: root))
        _ = try await recovery.recover()
        paAssertEqual(await providerCalls.value, 0)
        paAssertEqual(await restarted.record(id: intent.id)?.phase, .cancelled)
    }

    func testProviderSucceededBeforeReceiptPersistenceRecoversByReconcileWithoutReplay() async throws {
        let root = paTemporaryRoot()
        let ledger = try FileOperationLedger(root: root, now: { paFixedDate })
        let intent = paIntent()
        _ = try await ledger.prepare(intent)
        try await ledger.markCommitting(intent.id)

        let restarted = try FileOperationLedger(root: root, now: { paFixedDate })
        let receipt = ProviderReceipt(providerObjectID: "message-9", rawJSON: #"{"id":"message-9"}"#)
        let reconciler = PAReceiptReconciler(receipts: [intent.id: receipt])
        let recovery = OperationRecovery(ledger: restarted, breaker: try CircuitBreaker(root: root),
                                         reconcilers: [reconciler])
        let pending = try await recovery.recover()
        XCTAssertTrue(pending.isEmpty)
        paAssertEqual(await restarted.record(id: intent.id)?.phase, .reconciled)
        paAssertEqual(await restarted.record(id: intent.id)?.receipt, receipt)
        paAssertEqual(await reconciler.lookedUp, [intent.id])
    }

    func testTimeoutStaysUnknownAndSimilarRequestCannotRepeatWrite() async throws {
        let root = paTemporaryRoot()
        let ledger = try FileOperationLedger(root: root, now: { paFixedDate })
        let breaker = try CircuitBreaker(root: root)
        let executor = OperationExecutor(ledger: ledger, breaker: breaker)
        let intent = paIntent(digest: "same-business-write")
        let result = try await executor.execute(intent: intent, connectorID: "gmail", effect: .write,
                                                reauthorize: { true }, provider: { throw PATestError.timeout })
        XCTAssertEqual(result.phase, .unknown)
        XCTAssertTrue(result.failureReason?.contains("不会自动重发") == true)

        do {
            _ = try await ledger.prepare(paIntent(digest: intent.digest))
            XCTFail("相似请求在 unknown 未对账时不能再次写入")
        } catch {
            XCTAssertEqual(error as? OperationLedgerError, .unknownConflict(intent.id))
        }
        let recovery = OperationRecovery(ledger: ledger, breaker: breaker,
                                         reconcilers: [PAReceiptReconciler(receipts: [intent.id: nil])])
        let pending = try await recovery.recover()
        XCTAssertEqual(pending.map(\.id), [intent.id])
        paAssertEqual(await ledger.record(id: intent.id)?.phase, .unknown)
    }

    func testPartialSuccessReconcilesOnlyUnknownOperation() async throws {
        let root = paTemporaryRoot()
        let ledger = try FileOperationLedger(root: root, now: { paFixedDate })
        let committed = paIntent(digest: "committed")
        let unknown = paIntent(digest: "unknown")
        for intent in [committed, unknown] {
            _ = try await ledger.prepare(intent)
            try await ledger.markCommitting(intent.id)
        }
        try await ledger.commit(committed.id, receipt: ProviderReceipt(providerObjectID: "sent-1", rawJSON: "{}"))
        try await ledger.markUnknown(unknown.id, reason: "timeout")

        let receipt = ProviderReceipt(providerObjectID: "sent-2", rawJSON: "{}")
        let reconciler = PAReceiptReconciler(receipts: [unknown.id: receipt])
        let recovery = OperationRecovery(ledger: ledger, breaker: try CircuitBreaker(root: root),
                                         reconcilers: [reconciler])
        _ = try await recovery.recover()
        paAssertEqual(await ledger.record(id: committed.id)?.phase, .committed)
        paAssertEqual(await ledger.record(id: unknown.id)?.phase, .reconciled)
        paAssertEqual(await reconciler.lookedUp, [unknown.id])
    }
}
