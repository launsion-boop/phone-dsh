// SPDX-License-Identifier: MIT

import Foundation
import ProbeKit
import XCTest

final class PA_UndoWindowTests: XCTestCase {
    func testCancelInsideUndoWindowProducesNoProviderCall() async throws {
        let root = paTemporaryRoot()
        let ledger = try FileOperationLedger(root: root, now: { paFixedDate })
        let executor = OperationExecutor(ledger: ledger, breaker: try CircuitBreaker(root: root), undoInterval: 5,
                                         sleep: { _ in try await Task.sleep(nanoseconds: 300_000_000) })
        let intent = paIntent()
        let calls = PACounter()
        let task = Task {
            try await executor.execute(intent: intent, connectorID: "gmail", effect: .irreversible,
                                       reauthorize: { true }, provider: {
                await calls.increment()
                return ProviderReceipt(providerObjectID: "should-not-send", rawJSON: "{}")
            })
        }
        while await ledger.record(id: intent.id)?.phase != .undoWindow {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try await executor.cancel(id: intent.id)
        let record = try await task.value
        XCTAssertEqual(record.phase, .cancelled)
        paAssertEqual(await calls.value, 0)
    }

    func testKillInsideUndoWindowRecoversCancelledWithoutReplay() async throws {
        let root = paTemporaryRoot()
        let ledger = try FileOperationLedger(root: root, now: { paFixedDate })
        let intent = paIntent()
        _ = try await ledger.prepare(intent)
        _ = try await ledger.beginUndoWindow(intent.id)

        let restarted = try FileOperationLedger(root: root, now: { paFixedDate })
        let recovery = OperationRecovery(ledger: restarted, breaker: try CircuitBreaker(root: root))
        _ = try await recovery.recover()
        paAssertEqual(await restarted.record(id: intent.id)?.phase, .cancelled)
        let duplicate = try await restarted.prepare(intent)
        XCTAssertEqual(duplicate.phase, .cancelled)
    }

    func testUndoExpiryRechecksAuthorizationBeforeSingleCommit() async throws {
        let root = paTemporaryRoot()
        let ledger = try FileOperationLedger(root: root, now: { paFixedDate })
        let observedDelay = PACounter()
        let executor = OperationExecutor(ledger: ledger, breaker: try CircuitBreaker(root: root), undoInterval: 5,
                                         sleep: { interval in
            XCTAssertEqual(interval, 5)
            await observedDelay.increment()
        })
        let intent = paIntent()
        let calls = PACounter()
        let denied = try await executor.execute(intent: intent, connectorID: "gmail", effect: .irreversible,
                                                reauthorize: { false }, provider: {
            await calls.increment()
            return ProviderReceipt(providerObjectID: "no", rawJSON: "{}")
        })
        XCTAssertEqual(denied.phase, .cancelled)
        paAssertEqual(await observedDelay.value, 1)
        paAssertEqual(await calls.value, 0)

        let allowedIntent = paIntent(digest: "allowed")
        let allowed = try await executor.execute(intent: allowedIntent, connectorID: "gmail", effect: .irreversible,
                                                 reauthorize: { true }, provider: {
            await calls.increment()
            return ProviderReceipt(providerObjectID: "sent", rawJSON: "{}")
        })
        XCTAssertEqual(allowed.phase, .committed)
        paAssertEqual(await calls.value, 1)
    }
}
