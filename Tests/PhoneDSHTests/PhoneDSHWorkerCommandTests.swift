// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — G2-FIX-35: Worker command wire contract.
//
// The scenario evaluator consumes a typed receipt; this regression pins the
// request keys the route validates and the receipt fields that distinguish a
// Worker VFS fork from a host process.

import Foundation
import XCTest
import PhoneDSHAgentCore
@testable import PhoneDSH

final class PhoneDSHWorkerCommandTests: XCTestCase {
    func testRequestCarriesEveryBindingAndClampsTheBudget() throws {
        let request = PhoneDSHWorkerCommandRequest(
            command: "printf worker",
            program: "python3",
            cwd: "/dsh/home",
            timeoutMilliseconds: 10_000_000,
            scenarioID: "G2-WC",
            sessionID: "session-1",
            turn: 3,
            assertionIndex: 7,
            completionWatermark: 3)
        XCTAssertEqual(request.timeoutMilliseconds,
                       PhoneDSHWorkerCommandProtocol.maximumBudgetMilliseconds)
        guard case .object(let object) = request.json else {
            return XCTFail("request.json must be an object")
        }
        XCTAssertEqual(object["command"]?.stringValue, "printf worker")
        XCTAssertEqual(object["program"]?.stringValue, "python3")
        XCTAssertEqual(object["cwd"]?.stringValue, "/dsh/home")
        XCTAssertEqual(object["scenario_id"]?.stringValue, "G2-WC")
        XCTAssertEqual(object["session_id"]?.stringValue, "session-1")
        XCTAssertEqual(object["turn"]?.intValue, 3)
        XCTAssertEqual(object["assertion_index"]?.intValue, 7)
        XCTAssertEqual(object["completion_watermark"]?.intValue, 3)
        XCTAssertEqual(object["timeout_ms"]?.intValue,
                       PhoneDSHWorkerCommandProtocol.maximumBudgetMilliseconds)

        let noWatermark = PhoneDSHWorkerCommandRequest(
            command: "true", scenarioID: "s", sessionID: "x", turn: 0, assertionIndex: 0)
        guard case .object(let bare) = noWatermark.json else {
            return XCTFail("request.json must be an object")
        }
        XCTAssertNil(bare["completion_watermark"])
    }

    func testReceiptParsesTheWorkerLocationAndRejectsOtherProtocols() throws {
        let raw = JSONValue.object([
            "protocol": .string("pdsh-worker-command/1"),
            "receipt_id": .string("wc-1"),
            "location": .object([
                "kind": .string("worker"),
                "carrier": .string("ordered-channel"),
                "worker_vfs": .bool(true),
                "host_process": .bool(false),
                "fork": .string("memory-vfs"),
            ]),
            "binding": .object([
                "scenario_id": .string("s"),
                "session_id": .string("x"),
                "turn": .number(0),
                "assertion_index": .number(1),
                "completion_watermark": .number(0),
            ]),
            "source": .object([
                "kind": .string("worker-vfs-fork"),
                "fork": .bool(true),
                "missing_roots": .array([]),
                "source_mseq_start": .number(4),
                "source_mseq_end": .number(4),
                "source_frozen": .bool(true),
                "digest": .string("sha256:" + String(repeating: "0", count: 64)),
                "entries": .number(1),
                "bytes": .number(2),
            ]),
            "execution": .object([
                "program": .string("bash"),
                "cwd": .string("/dsh/workspace"),
                "budget_ms": .number(100),
                "duration_ms": .number(2),
                "exit_code": .number(0),
                "timed_out": .bool(false),
                "cancelled": .bool(false),
                "stdout": .string("ok"),
                "stderr": .string(""),
                "stdout_bytes": .number(2),
                "stderr_bytes": .number(0),
                "stdout_truncated": .bool(false),
                "stderr_truncated": .bool(false),
            ]),
            "model_requests": .number(0),
            "live_workspace_unchanged": .bool(true),
            "side_effects": .object([
                "isolated": .bool(true),
                "live_workspace": .bool(false),
                "journal": .bool(false),
                "changes": .array([]),
                "changed": .number(0),
            ]),
        ])
        let receipt = try PhoneDSHWorkerCommandReceipt(raw: raw)
        XCTAssertTrue(receipt.isWorkerVFS)
        XCTAssertTrue(receipt.isImmutableFork)
        XCTAssertEqual(receipt.carrier, "ordered-channel")
        XCTAssertEqual(receipt.bindingAssertionIndex, 1)
        XCTAssertEqual(receipt.sourceMseqStart, 4)
        XCTAssertEqual(receipt.sourceEntries, 1)
        XCTAssertEqual(receipt.modelRequests, 0)
        XCTAssertEqual(receipt.liveWorkspaceUnchanged, true)
        XCTAssertEqual(receipt.sideEffectsIsolated, true)
        XCTAssertEqual(receipt.sideEffectsLiveWorkspace, false)
        XCTAssertEqual(receipt.sideEffectsJournal, false)
        XCTAssertEqual(receipt.sourceMissingRoots, [])
        XCTAssertTrue(receipt.succeeded)

        XCTAssertThrowsError(try PhoneDSHWorkerCommandReceipt(
            raw: .object(["protocol": .string("something-else")])))
    }

    func testImmutableForkRequiresAFrozenSourceAndAnEmptyStructuredMissingRootsList() throws {
        let raw = try validReceiptRaw()
        func receipt(_ mutate: (inout [String: JSONValue]) -> Void) throws
            -> PhoneDSHWorkerCommandReceipt {
            guard case .object(var object) = raw else {
                throw PhoneDSHError.invalidResponse("fixture is not an object")
            }
            mutate(&object)
            return try PhoneDSHWorkerCommandReceipt(raw: .object(object))
        }
        let valid = try receipt { _ in }
        XCTAssertTrue(valid.isImmutableFork)

        let unfrozen = try receipt { object in
            guard case .object(var source)? = object["source"] else { return }
            source["source_frozen"] = .bool(false)
            object["source"] = .object(source)
        }
        XCTAssertFalse(unfrozen.isImmutableFork)

        let noMissingRoots = try receipt { object in
            guard case .object(var source)? = object["source"] else { return }
            source.removeValue(forKey: "missing_roots")
            object["source"] = .object(source)
        }
        XCTAssertFalse(noMissingRoots.isImmutableFork)

        let nonEmptyMissingRoots = try receipt { object in
            guard case .object(var source)? = object["source"] else { return }
            source["missing_roots"] = .array([.string("/dsh/home")])
            object["source"] = .object(source)
        }
        XCTAssertFalse(nonEmptyMissingRoots.isImmutableFork)

        let malformedMissingRoots = try receipt { object in
            guard case .object(var source)? = object["source"] else { return }
            source["missing_roots"] = .array([.number(1)])
            object["source"] = .object(source)
        }
        XCTAssertFalse(malformedMissingRoots.isImmutableFork)
    }

    private func validReceiptRaw() throws -> JSONValue {
        .object([
            "protocol": .string(PhoneDSHWorkerCommandProtocol.receiptProtocol),
            "receipt_id": .string("wc-1"),
            "location": .object([
                "kind": .string("worker"),
                "carrier": .string("ordered-channel"),
                "worker_vfs": .bool(true),
                "host_process": .bool(false),
                "fork": .string("memory-vfs"),
            ]),
            "binding": .object([
                "scenario_id": .string("s"),
                "session_id": .string("x"),
                "turn": .number(0),
                "assertion_index": .number(1),
                "completion_watermark": .number(0),
            ]),
            "source": .object([
                "kind": .string("worker-vfs-fork"),
                "fork": .bool(true),
                "missing_roots": .array([]),
                "source_mseq_start": .number(4),
                "source_mseq_end": .number(4),
                "source_frozen": .bool(true),
                "digest": .string("sha256:" + String(repeating: "0", count: 64)),
                "entries": .number(1),
                "bytes": .number(2),
            ]),
            "execution": .object([
                "program": .string("bash"),
                "cwd": .string("/dsh/workspace"),
                "budget_ms": .number(100),
                "duration_ms": .number(2),
                "exit_code": .number(0),
                "timed_out": .bool(false),
                "cancelled": .bool(false),
                "stdout": .string("ok"),
                "stderr": .string(""),
                "stdout_bytes": .number(2),
                "stderr_bytes": .number(0),
                "stdout_truncated": .bool(false),
                "stderr_truncated": .bool(false),
            ]),
            "model_requests": .number(0),
            "live_workspace_unchanged": .bool(true),
            "side_effects": .object([
                "isolated": .bool(true),
                "live_workspace": .bool(false),
                "journal": .bool(false),
                "changes": .array([]),
                "changed": .number(0),
            ]),
        ])
    }
}
