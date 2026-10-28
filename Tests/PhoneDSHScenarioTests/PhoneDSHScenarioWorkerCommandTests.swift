// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — G2-FIX-35: Worker-side command acceptance regressions.
//
// These tests pin the parts that make `worker_command` different from the old
// host `workspace_command`:
//   * the catalog schema accepts only the typed keys and requires a command;
//   * a report without a `pdsh-worker-command/1` receipt fails as
//     `missing_receipt`, never as a host pass;
//   * a receipt is accepted only when it says Worker VFS fork, no host process,
//     the exact scenario/session/turn/assertion binding and zero model calls;
//   * raw stdout/stderr, exit, timeout and cancellation survive into the report
//     detail and the raw receipt.

import Foundation
import XCTest
import PhoneDSH
import PhoneDSHAgentCore
@testable import PhoneDSHScenario

final class PhoneDSHScenarioWorkerCommandTests: XCTestCase {
    // MARK: - Fixtures

    private func assertion(command: String = "printf worker",
                           program: String? = nil,
                           cwd: String? = nil,
                           timeoutMilliseconds: Int? = nil) -> Scenario.Assertion {
        var value: [String: Any] = ["type": "worker_command", "command": command]
        if let program { value["program"] = program }
        if let cwd { value["cwd"] = cwd }
        if let timeoutMilliseconds { value["timeout_ms"] = timeoutMilliseconds }
        return try! decodeAssertion(JSONSerialization.data(withJSONObject: value))
    }

    private func decodeAssertion(_ data: Data) throws -> Scenario.Assertion {
        try JSONDecoder().decode(Scenario.Assertion.self, from: data)
    }

    private func receiptJSON(exitCode: Int = 0,
                             timedOut: Bool = false,
                             cancelled: Bool = false,
                             stdout: String = "worker\n",
                             stderr: String = "",
                             program: String = "bash",
                             cwd: String = "/dsh/workspace",
                             scenarioID: String = "G2-WC",
                             sessionID: String = "session-1",
                             turn: Int = 1,
                             assertionIndex: Int = 2,
                             watermark: Int = 1,
                             hostProcess: Bool = false,
                             modelRequests: Int = 0,
                             liveWorkspaceUnchanged: Bool = true,
                             carrier: String = "ordered-channel",
                             sourceFrozen: Bool = true,
                             sourceMissingRoots: [String] = [],
                             sourceMseqStart: Int = 12,
                             sourceMseqEnd: Int = 12) -> JSONValue {
        .object([
            "protocol": .string("pdsh-worker-command/1"),
            "receipt_id": .string("wc-test"),
            "location": .object([
                "kind": .string("worker"),
                "carrier": .string(carrier),
                "worker_vfs": .bool(true),
                "host_process": .bool(hostProcess),
                "fork": .string("memory-vfs"),
            ]),
            "binding": .object([
                "scenario_id": .string(scenarioID),
                "session_id": .string(sessionID),
                "turn": .number(Double(turn)),
                "assertion_index": .number(Double(assertionIndex)),
                "completion_watermark": .number(Double(watermark)),
            ]),
            "source": .object([
                "kind": .string("worker-vfs-fork"),
                "fork": .bool(true),
                "source_mseq_start": .number(Double(sourceMseqStart)),
                "source_mseq_end": .number(Double(sourceMseqEnd)),
                "source_frozen": .bool(sourceFrozen),
                "missing_roots": .array(sourceMissingRoots.map { .string($0) }),
                "digest": .string("sha256:" + String(repeating: "0", count: 64)),
                "entries": .number(3),
                "bytes": .number(40),
            ]),
            "execution": .object([
                "program": .string(program),
                "cwd": .string(cwd),
                "budget_ms": .number(1_000),
                "duration_ms": .number(5),
                "exit_code": .number(Double(exitCode)),
                "timed_out": .bool(timedOut),
                "cancelled": .bool(cancelled),
                "stdout": .string(stdout),
                "stderr": .string(stderr),
                "stdout_bytes": .number(Double(stdout.utf8.count)),
                "stderr_bytes": .number(Double(stderr.utf8.count)),
                "stdout_truncated": .bool(false),
                "stderr_truncated": .bool(false),
            ]),
            "model_requests": .number(Double(modelRequests)),
            "live_workspace_unchanged": .bool(liveWorkspaceUnchanged),
            "side_effects": .object([
                "isolated": .bool(true),
                "live_workspace": .bool(false),
                "journal": .bool(false),
                "changes": .array([]),
                "changed": .number(0),
            ]),
        ])
    }

    private func receipt(mutating mutate: (inout [String: JSONValue]) -> Void) -> JSONValue {
        var value = receiptJSON()
        guard case .object(var object) = value else { return value }
        mutate(&object)
        return .object(object)
    }

    private class FakeTransport: DSHRemoteTransport, @unchecked Sendable {
        func call(_ endpoint: String, args: JSONValue) async throws -> JSONValue {
            throw ProviderError.unsupported("not used by this test")
        }
        func openMux() async throws -> any DSHMuxConnection {
            throw ProviderError.unsupported("not used by this test")
        }
    }

    private final class WorkerCommandTransport: FakeTransport, PhoneDSHWorkerCommandCalling,
        @unchecked Sendable {
        var receipt: JSONValue
        var error: Error?
        var requests: [PhoneDSHWorkerCommandRequest] = []

        init(receipt: JSONValue, error: Error? = nil) {
            self.receipt = receipt
            self.error = error
        }

        func executeWorkerCommand(_ request: PhoneDSHWorkerCommandRequest) async throws
            -> PhoneDSHWorkerCommandReceipt {
            requests.append(request)
            if let error { throw error }
            return try PhoneDSHWorkerCommandReceipt(raw: receipt)
        }
    }

    private func evaluate(_ transport: any DSHRemoteTransport,
                          assertion: Scenario.Assertion? = nil,
                          redactor: ScenarioRedactor = ScenarioRedactor()) async
        -> ScenarioAssertionReport {
        await ScenarioWorkerCommand.evaluate(
            assertion: assertion ?? self.assertion(),
            index: 2,
            scenarioID: "G2-WC",
            sessionID: "session-1",
            turn: 1,
            completionWatermark: 1,
            transport: transport,
            redactor: redactor)
    }

    /// Write one report exactly as the runner does and return the encoded
    /// artifact, so secret checks cover `report.json`, not just the object.
    private func writtenArtifact(_ report: ScenarioAssertionReport) throws -> String {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-worker-receipt-redaction-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootDirectory) }
        let reportURL = rootDirectory.appendingPathComponent("report.json")
        let artifact = ScenarioReport(
            id: "G2-WC",
            status: "FAIL",
            assertions: [report],
            turns: [],
            perturbations: [],
            usage: ScenarioUsageReport(modelRequests: 0,
                                       upstreamBytesIn: 0,
                                       upstreamBytesOut: 0,
                                       wallS: 0),
            pageVisibility: nil,
            deferred: nil,
            runnerInfra: nil,
            webContentTerminations: 0,
            hostEvaluated: nil,
            consoleErrors: [],
            runnerErrors: [],
            hostStates: [],
            runCompleted: true,
            runIncompleteReason: nil)
        try ScenarioReportArtifact.write(artifact, to: reportURL)
        return String(decoding: try Data(contentsOf: reportURL), as: UTF8.self)
    }

    // MARK: - Schema

    func testWorkerCommandHasItsOwnTypedSchema() throws {
        XCTAssertEqual(Scenario.Assertion.allowedKeysByType["worker_command"],
                       Set(["type", "command", "program", "cwd", "timeout_ms"]))
        XCTAssertEqual(Scenario.Assertion.requiredKeysByType["worker_command"], Set(["command"]))

        let decoded = try decodeAssertion(Data(#"""
            {"type":"worker_command","command":"python3 -V","program":"python3",
             "cwd":"/dsh/home","timeout_ms":250}
            """#.utf8))
        XCTAssertEqual(decoded.command, "python3 -V")
        XCTAssertEqual(decoded.program, "python3")
        XCTAssertEqual(decoded.cwd, "/dsh/home")
        XCTAssertEqual(decoded.timeoutMilliseconds, 250)
    }

    func testCatalogRejectsUnknownWorkerCommandKeyAndMissingCommand() throws {
        func load(_ assertions: [[String: Any]]) -> String? {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("pdsh-worker-command-schema-\(UUID().uuidString)",
                                        isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let document: [String: Any] = [
                    "version": 1,
                    "scenarios": [[
                        "id": "G2-WC-SCHEMA", "category": "recovery",
                        "title": "schema", "user_story": "schema",
                        "workspace": ["files": [String: String]()],
                        "turns": [["prompt": "hello"]],
                        "assertions": assertions,
                        "budget": ["max_minutes": 1, "max_model_requests": 1],
                        "target": "macos",
                    ]],
                ]
                let url = root.appendingPathComponent("catalog.json")
                try JSONSerialization.data(withJSONObject: document).write(to: url)
                _ = try ScenarioCatalog.load(from: url)
                return nil
            } catch {
                return String(describing: error)
            }
        }
        let unknown = load([["type": "worker_command", "command": "true", "host": "bash"]])
        XCTAssertNotNil(unknown)
        XCTAssertTrue(unknown?.contains("\"host\"") == true, unknown ?? "")
        let missing = load([["type": "worker_command"]])
        XCTAssertNotNil(missing)
        XCTAssertTrue(missing?.contains("command") == true, missing ?? "")
    }

    // MARK: - Receipt acceptance

    func testAMissingReceiptIsANonPassingMissingReceiptFailure() async {
        let report = await evaluate(FakeTransport())
        XCTAssertFalse(report.ok)
        XCTAssertFalse(report.isPassing)
        XCTAssertNil(report.workerEvaluated)
        XCTAssertEqual(report.failure?.kind, .missingReceipt)
        XCTAssertTrue(report.detail.contains("no Worker command channel"), report.detail)
    }

    func testAValidWorkerReceiptCarriesRawStreamsAndTheWorkerLocation() async throws {
        let transport = WorkerCommandTransport(receipt: receiptJSON(
            stdout: "worker stdout\n", stderr: "worker stderr\n"))
        let report = await evaluate(
            transport, assertion: assertion(timeoutMilliseconds: 1_000))
        XCTAssertTrue(report.ok)
        XCTAssertTrue(report.isPassing)
        XCTAssertEqual(report.workerEvaluated, true)
        XCTAssertNil(report.hostEvaluated)
        XCTAssertEqual(report.durationMs, 5)
        XCTAssertEqual(report.program, "bash")
        XCTAssertEqual(report.cwd, "/dsh/workspace")
        XCTAssertEqual(report.timeoutMilliseconds, 1_000)
        XCTAssertTrue(report.detail.contains("bash exit 0"), report.detail)
        XCTAssertTrue(report.detail.contains("worker VFS: used (immutable fork)"), report.detail)
        XCTAssertTrue(report.detail.contains("host process: not used"), report.detail)
        XCTAssertTrue(report.detail.contains("worker stdout"), report.detail)
        XCTAssertTrue(report.detail.contains("worker stderr"), report.detail)
        let raw = try XCTUnwrap(report.workerReceipt)
        XCTAssertEqual(raw["protocol"]?.stringValue, "pdsh-worker-command/1")
        XCTAssertEqual(raw["model_requests"], .number(0))
        XCTAssertEqual(raw["execution"]?["stdout"]?.stringValue, "worker stdout\n")
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.scenarioID, "G2-WC")
        XCTAssertEqual(request.sessionID, "session-1")
        XCTAssertEqual(request.turn, 1)
        XCTAssertEqual(request.assertionIndex, 2)
        XCTAssertEqual(request.completionWatermark, 1)
    }

    func testWorkerReceiptStringsAreRecursivelyRedactedBeforeTheArtifactIsWritten() async throws {
        let opaque = "opaque-worker-key-7f3c9d11"
        // Both values are fake and are passed as exact secrets. `prefixed`
        // deliberately has hyphens after `sk-`, so it is the exact-value rule
        // rather than the redactor's `sk-[A-Za-z0-9]{8,}` regex that must
        // remove it from the raw receipt and the artifact.
        let prefixed = "sk-live-worker-key-1234567890"
        var receipt = receiptJSON(
            stdout: "worker stdout \(opaque) \(prefixed)\n",
            stderr: "worker stderr \(opaque)\n")
        guard case .object(var root) = receipt,
              case .object(var sideEffects)? = root["side_effects"],
              case .array(var changes)? = sideEffects["changes"] else {
            return XCTFail("receipt fixture shape changed")
        }
        changes.append(.object([
            "path": .string("/dsh/workspace/\(opaque)"),
            "change": .string("created"),
            "bytes": .number(3),
        ]))
        sideEffects["changes"] = .array(changes)
        root["side_effects"] = .object(sideEffects)
        root["future_note"] = .object([
            "nested": .string("\(opaque)-nested"),
            "keep_number": .number(7),
            "keep_bool": .bool(true),
            "keep_array": .array([.string("\(opaque)-array"), .number(2)]),
        ])
        receipt = .object(root)

        let report = await evaluate(WorkerCommandTransport(receipt: receipt),
                                    redactor: ScenarioRedactor(secrets: [opaque, prefixed]))
        XCTAssertTrue(report.ok, report.detail)
        let raw = try XCTUnwrap(report.workerReceipt)
        let encoded = String(decoding: try JSONEncoder().encode(raw), as: UTF8.self)
        XCTAssertFalse(encoded.contains(opaque), encoded)
        XCTAssertFalse(encoded.contains(prefixed), encoded)
        XCTAssertTrue(encoded.contains("<redacted>"), encoded)
        XCTAssertEqual(raw["model_requests"]?.numberValue, 0.0)
        XCTAssertEqual(raw["future_note"]?["keep_number"]?.numberValue, 7.0)
        XCTAssertEqual(raw["future_note"]?["keep_bool"]?.boolValue, true)
        XCTAssertEqual(raw["future_note"]?["keep_array"]?.arrayValue?.count, 2)
        XCTAssertEqual(raw["side_effects"]?["changes"]?.arrayValue?.count, 1)
        XCTAssertEqual(raw["side_effects"]?["changes"]?.arrayValue?.first?["bytes"]?.numberValue, 3.0)

        // The report writer encodes the object directly: the artifact must not
        // contain the secret even though the receipt arrived raw over the wire.
        let written = try writtenArtifact(report)
        XCTAssertFalse(written.contains(opaque), written)
        XCTAssertFalse(written.contains(prefixed), written)
        XCTAssertTrue(written.contains("<redacted>"), written)
    }

    func testWorkerRequestProgramAndCwdAreRedactedAndStillMatchTheReceipt() async throws {
        let opaque = "opaque-worker-location-6d2f4a81"
        let prefixed = "sk-live-worker-location-1234567890"
        let program = "python3-\(opaque)"
        let cwd = "/dsh/workspace/\(opaque)/\(prefixed)"
        let redactor = ScenarioRedactor(secrets: [opaque, prefixed])
        let transport = WorkerCommandTransport(
            receipt: receiptJSON(program: program, cwd: cwd))

        let report = await evaluate(
            transport,
            assertion: assertion(program: program, cwd: cwd),
            redactor: redactor)
        XCTAssertTrue(report.ok, report.detail)

        // The Worker still receives the real request facts; only the report is
        // redacted. The receipt is recursively redacted, so its execution
        // program/cwd must stay equal to the redacted top-level declarations:
        // scenario_evidence.py compares those two fields.
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.program, program)
        XCTAssertEqual(request.cwd, cwd)
        let expectedProgram = redactor.redact(program)
        let expectedCwd = redactor.redact(cwd)
        XCTAssertEqual(report.program, expectedProgram)
        XCTAssertEqual(report.cwd, expectedCwd)
        let raw = try XCTUnwrap(report.workerReceipt)
        XCTAssertEqual(raw["execution"]?["program"]?.stringValue, expectedProgram)
        XCTAssertEqual(raw["execution"]?["cwd"]?.stringValue, expectedCwd)

        let written = try writtenArtifact(report)
        XCTAssertFalse(written.contains(opaque), written)
        XCTAssertFalse(written.contains(prefixed), written)
        let document = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(written.utf8)) as? [String: Any])
        let assertions = try XCTUnwrap(document["assertions"] as? [[String: Any]])
        let row = try XCTUnwrap(assertions.first)
        XCTAssertEqual(row["program"] as? String, expectedProgram)
        XCTAssertEqual(row["cwd"] as? String, expectedCwd)
        let receiptRow = try XCTUnwrap(row["worker_receipt"] as? [String: Any])
        let execution = try XCTUnwrap(receiptRow["execution"] as? [String: Any])
        XCTAssertEqual(execution["program"] as? String, expectedProgram)
        XCTAssertEqual(execution["cwd"] as? String, expectedCwd)
    }

    func testAHostLocationOrBindingMismatchCannotPass() async {
        let host = await evaluate(WorkerCommandTransport(receipt: receiptJSON(hostProcess: true)))
        XCTAssertFalse(host.ok)
        XCTAssertEqual(host.failure?.kind, .workerReceiptMismatch)
        XCTAssertTrue(host.detail.contains("location is not a Worker VFS fork"), host.detail)

        let model = await evaluate(WorkerCommandTransport(receipt: receiptJSON(modelRequests: 1)))
        XCTAssertFalse(model.ok)
        XCTAssertEqual(model.failure?.kind, .workerReceiptMismatch)
        XCTAssertTrue(model.detail.contains("model_requests"), model.detail)

        let wrongTurn = await evaluate(WorkerCommandTransport(receipt: receiptJSON(turn: 9)))
        XCTAssertFalse(wrongTurn.ok)
        XCTAssertEqual(wrongTurn.failure?.kind, .workerReceiptMismatch)
        XCTAssertTrue(wrongTurn.detail.contains("turn 9"), wrongTurn.detail)

        let changed = await evaluate(WorkerCommandTransport(
            receipt: receiptJSON(liveWorkspaceUnchanged: false)))
        XCTAssertFalse(changed.ok)
        XCTAssertEqual(changed.failure?.kind, .workerReceiptMismatch)
        XCTAssertTrue(changed.detail.contains("live_workspace_unchanged"), changed.detail)
        XCTAssertTrue(changed.detail.contains("live workspace NOT verified unchanged"),
                      changed.detail)
        XCTAssertFalse(changed.detail.contains("fork side effects: 0 path(s); live workspace unchanged"),
                       changed.detail)

        let desktop = await evaluate(WorkerCommandTransport(
            receipt: receiptJSON(carrier: "surface-process")))
        XCTAssertFalse(desktop.ok)
        XCTAssertEqual(desktop.failure?.kind, .workerReceiptMismatch)
        XCTAssertTrue(desktop.detail.contains("surface-process"), desktop.detail)
        XCTAssertTrue(desktop.detail.contains("not the ordered channel"), desktop.detail)

        let movingSource = await evaluate(WorkerCommandTransport(
            receipt: receiptJSON(sourceFrozen: false, sourceMseqStart: 12, sourceMseqEnd: 13)))
        XCTAssertFalse(movingSource.ok)
        XCTAssertEqual(movingSource.failure?.kind, .workerReceiptMismatch)
        XCTAssertTrue(movingSource.detail.contains("source is not frozen"), movingSource.detail)
        XCTAssertTrue(movingSource.detail.contains("source not frozen; not immutable"),
                      movingSource.detail)
        XCTAssertFalse(movingSource.detail.contains("used (immutable fork)"), movingSource.detail)
        XCTAssertFalse(movingSource.detail.contains("live workspace unchanged"), movingSource.detail)

        let missingRoot = await evaluate(WorkerCommandTransport(
            receipt: receiptJSON(sourceMissingRoots: ["/dsh/workspace"])))
        XCTAssertFalse(missingRoot.ok)
        XCTAssertEqual(missingRoot.failure?.kind, .workerReceiptMismatch)
        XCTAssertTrue(missingRoot.detail.contains("missing_roots"), missingRoot.detail)
        XCTAssertTrue(missingRoot.detail.contains("/dsh/workspace"), missingRoot.detail)
        do {

            let missingRoot = await evaluate(WorkerCommandTransport(receipt: receipt { object in
                guard case .object(var source)? = object["source"] else { return }
                source["missing_roots"] = .array([.string("/dsh/home")])
                object["source"] = .object(source)
            }))
            XCTAssertFalse(missingRoot.ok)
            XCTAssertEqual(missingRoot.failure?.kind, .workerReceiptMismatch)
            XCTAssertTrue(missingRoot.detail.contains("missing_roots"), missingRoot.detail)

            let noMissingRoots = await evaluate(WorkerCommandTransport(receipt: receipt { object in
                guard case .object(var source)? = object["source"] else { return }
                source.removeValue(forKey: "missing_roots")
                object["source"] = .object(source)
            }))
            XCTAssertFalse(noMissingRoots.ok)
            XCTAssertEqual(noMissingRoots.failure?.kind, .workerReceiptMismatch)
            XCTAssertTrue(noMissingRoots.detail.contains("missing_roots"), noMissingRoots.detail)

            for (field, detail) in [("live_workspace", "side_effects.live_workspace"),
                                    ("journal", "side_effects.journal")] {
                let leak = await evaluate(WorkerCommandTransport(receipt: receipt { object in
                    guard case .object(var sideEffects)? = object["side_effects"] else { return }
                    sideEffects[field] = .bool(true)
                    object["side_effects"] = .object(sideEffects)
                }))
                XCTAssertFalse(leak.ok, detail)
                XCTAssertEqual(leak.failure?.kind, .workerReceiptMismatch)
                XCTAssertTrue(leak.detail.contains(detail), leak.detail)

                let missing = await evaluate(WorkerCommandTransport(receipt: receipt { object in
                    guard case .object(var sideEffects)? = object["side_effects"] else { return }
                    sideEffects.removeValue(forKey: field)
                    object["side_effects"] = .object(sideEffects)
                }))
                XCTAssertFalse(missing.ok, detail)
                XCTAssertEqual(missing.failure?.kind, .workerReceiptMismatch)
                XCTAssertTrue(missing.detail.contains(detail), missing.detail)
            }
        }
    }

    func testAFailedSnapshotDoesNotClaimAnImmutableFork() async {
        guard case .object(var root) = receiptJSON(liveWorkspaceUnchanged: false),
              case .object(var location)? = root["location"],
              case .object(var source)? = root["source"] else {
            return XCTFail("receipt fixture shape changed")
        }
        location["worker_vfs"] = .bool(false)
        location["fork"] = .string("none")
        source["fork"] = .bool(false)
        source["source_frozen"] = .bool(false)
        source["digest"] = .string("")
        source["entries"] = .number(0)
        source["bytes"] = .number(0)
        source["missing_roots"] = .array([.string("/dsh/workspace")])
        source["failure"] = .string("worker-command/snapshot-missing-root")
        source["failure_detail"] = .string("/dsh/workspace is missing")
        source["timed_out"] = .bool(false)
        root["location"] = .object(location)
        root["source"] = .object(source)

        let failed = await evaluate(WorkerCommandTransport(receipt: .object(root)))
        XCTAssertFalse(failed.ok)
        XCTAssertEqual(failed.failure?.kind, .workerReceiptMismatch)
        XCTAssertTrue(failed.detail.contains("snapshot failed (not used)"), failed.detail)
        XCTAssertTrue(failed.detail.contains(
            "source failure: worker-command/snapshot-missing-root"), failed.detail)
        XCTAssertTrue(failed.detail.contains("/dsh/workspace is missing"), failed.detail)
        XCTAssertFalse(failed.detail.contains("worker VFS: used (immutable fork)"), failed.detail)
        XCTAssertTrue(failed.detail.contains("fork side effects: not recorded"), failed.detail)
        XCTAssertFalse(failed.detail.contains("live workspace unchanged"), failed.detail)
    }

    func testAKeptForkStillReportsExecutionFailureWithoutClaimingSuccess() async {
        guard case .object(var root) = receiptJSON(exitCode: 1),
              case .object(var execution)? = root["execution"] else {
            return XCTFail("receipt fixture shape changed")
        }
        execution["failure"] = .string("worker-command/execution-failed")
        execution["failure_detail"] = .string("python runtime exploded")
        root["execution"] = .object(execution)

        let report = await evaluate(WorkerCommandTransport(receipt: .object(root)))
        XCTAssertFalse(report.ok)
        XCTAssertEqual(report.failure?.kind, .commandFailed)
        XCTAssertTrue(report.detail.contains("used (immutable fork)"), report.detail)
        XCTAssertTrue(report.detail.contains("execution failure: worker-command/execution-failed"),
                      report.detail)
        XCTAssertTrue(report.detail.contains("python runtime exploded"), report.detail)
        XCTAssertTrue(report.detail.contains("live workspace unchanged"), report.detail)
    }

    func testATimedOutWorkerCommandIsCommandFailedWithItsBudget() async {
        let report = await evaluate(WorkerCommandTransport(receipt: receiptJSON(
            exitCode: 124, timedOut: true,
            stderr: "pdsh-shell: command exceeded its wall-clock limit\n")))
        XCTAssertFalse(report.ok)
        XCTAssertEqual(report.failure?.kind, .commandFailed)
        XCTAssertTrue(report.detail.contains("exit 124"), report.detail)
        XCTAssertTrue(report.detail.contains("timed out"), report.detail)
        XCTAssertTrue(report.detail.contains("budget 1000 ms"), report.detail)
        XCTAssertTrue(report.detail.contains("wall-clock limit"), report.detail)
        XCTAssertEqual(report.workerEvaluated, true)
    }

    func testARouteFailureIsMissingReceiptNotAHostFallback() async {
        struct RouteFailure: Error, CustomStringConvertible {
            var description: String { "route unavailable" }
        }
        let report = await evaluate(WorkerCommandTransport(
            receipt: receiptJSON(), error: RouteFailure()))
        XCTAssertFalse(report.ok)
        XCTAssertEqual(report.failure?.kind, .missingReceipt)
        XCTAssertTrue(report.detail.contains("route unavailable"), report.detail)
    }

    // MARK: - Gate and evaluator

    func testWorkerCommandWithoutAnOverrideFailsMissingReceipt() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-worker-command-eval-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let evaluator = ScenarioAssertionEvaluator(
            workspace: root, resultsDirectory: root,
            turnStartedCount: 0, deliveredTurnCount: 0,
            modelRequests: 0, consoleErrors: [], restartRecovered: nil,
            redactor: ScenarioRedactor())
        let report = try XCTUnwrap(evaluator.reports(
            for: [assertion()], completion: .completed).first)
        XCTAssertFalse(report.ok)
        XCTAssertEqual(report.failure?.kind, .missingReceipt)
        XCTAssertTrue(report.detail.contains("no captured Worker receipt"), report.detail)
    }

    func testIncompleteRunGatesWorkerCommandToNotExecuted() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-worker-command-gate-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let evaluator = ScenarioAssertionEvaluator(
            workspace: root, resultsDirectory: root,
            turnStartedCount: 1, deliveredTurnCount: 1,
            modelRequests: 0, consoleErrors: [], restartRecovered: nil,
            redactor: ScenarioRedactor())
        let report = try XCTUnwrap(evaluator.reports(
            for: [assertion()],
            completion: .incomplete(reason: "the run ended with status TIMEOUT")).first)
        XCTAssertEqual(report.status, ScenarioAssertionStatus.notExecuted)
        XCTAssertEqual(report.failure?.kind, .notExecuted)
        XCTAssertFalse(report.isPassing)
    }
}

private extension JSONValue {
    subscript(_ key: String) -> JSONValue? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var numberValue: Double? {
        guard case .number(let value) = self else { return nil }
        return value
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    var arrayValue: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }
}
