// SPDX-License-Identifier: MIT
// W6-BACKGROUND probe tests: the flag gates the submission, the report is
// written and a wake callback flips `woken`.

import Foundation
import XCTest
import PhoneDSHController
@testable import PhoneDSH

/// Stub background URLSession transport.
final class RecordingProbeTransport: BackgroundProbeTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let outcome: BackgroundProbeOutcome
    private let wakeDuringSubmit: Bool
    private var submissions: [BackgroundProbeRequest] = []
    private var identifiers: [String] = []

    init(outcome: BackgroundProbeOutcome,
         wakeDuringSubmit: Bool = false) {
        self.outcome = outcome
        self.wakeDuringSubmit = wakeDuringSubmit
    }

    var submittedRequests: [BackgroundProbeRequest] { lock.withLock { submissions } }
    var submittedIdentifiers: [String] { lock.withLock { identifiers } }

    func submit(_ request: BackgroundProbeRequest,
                sessionIdentifier: String,
                onWake: @escaping @Sendable () -> Void) async
        -> BackgroundProbeOutcome {
        lock.withLock {
            submissions.append(request)
            identifiers.append(sessionIdentifier)
        }
        if wakeDuringSubmit {
            onWake()
        }
        return outcome
    }
}

final class BackgroundURLSessionProbeTests: XCTestCase {
    private let request = BackgroundProbeRequest(
        url: URL(string: "http://127.0.0.1:8080/v1/chat/completions")!,
        headers: ["Content-Type": "application/json"],
        body: Data("{\"stream\":false}".utf8))

    func testDisabledFlagSubmitsNothingAndWritesNothing() async {
        let root = BackgroundTestSupport.root(for: self)
        let reportURL = root.appendingPathComponent("probe.json")
        let transport = RecordingProbeTransport(
            outcome: BackgroundProbeOutcome(statusCode: 200,
                                            errorDescription: nil))
        let probe = BackgroundURLSessionProbe(
            configuration: .init(isEnabled: false, request: request,
                                 reportURL: reportURL),
            transport: transport)
        let report = await probe.submitIfEnabled()
        XCTAssertNil(report)
        XCTAssertTrue(transport.submittedRequests.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reportURL.path))
        let currentReport = await probe.currentReport()
        XCTAssertNil(currentReport)
    }

    func testEnabledProbeWritesTheReportAndTheProbeDisclaimer() async throws {
        let root = BackgroundTestSupport.root(for: self)
        let reportURL = root.appendingPathComponent("diagnostics/probe.json")
        let transport = RecordingProbeTransport(
            outcome: BackgroundProbeOutcome(statusCode: 200,
                                            errorDescription: nil))
        let probe = BackgroundURLSessionProbe(
            configuration: .init(isEnabled: true,
                                 sessionIdentifier: "xl.probe.test",
                                 request: request,
                                 reportURL: reportURL),
            transport: transport)
        let report = await probe.submitIfEnabled()
        let unwrapped = try XCTUnwrap(report)
        XCTAssertTrue(unwrapped.enabled)
        XCTAssertTrue(unwrapped.submitted)
        XCTAssertFalse(unwrapped.woken)
        XCTAssertEqual(unwrapped.statusCode, 200)
        XCTAssertEqual(unwrapped.sessionIdentifier, "xl.probe.test")
        XCTAssertEqual(unwrapped.note, BackgroundURLSessionProbe.disclaimer)
        XCTAssertEqual(transport.submittedRequests, [request])
        XCTAssertEqual(transport.submittedIdentifiers, ["xl.probe.test"])

        let data = try Data(contentsOf: reportURL)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["submitted"] as? Bool, true)
        XCTAssertEqual(object["woken"] as? Bool, false)
        XCTAssertEqual(object["probe"] as? String, "background-urlsession-upload")
        XCTAssertEqual(object["note"] as? String,
                       BackgroundURLSessionProbe.disclaimer)
    }

    func testWakeDuringSubmitIsRecorded() async throws {
        let transport = RecordingProbeTransport(
            outcome: BackgroundProbeOutcome(statusCode: 200,
                                            errorDescription: nil),
            wakeDuringSubmit: true)
        let probe = BackgroundURLSessionProbe(
            configuration: .init(isEnabled: true, request: request),
            transport: transport)
        let maybeReport = await probe.submitIfEnabled()
        let report = try XCTUnwrap(maybeReport)
        // The wake callback runs in a Task; give it one turn of the actor.
        try await Task.sleep(nanoseconds: 20_000_000)
        let current = await probe.currentReport()
        XCTAssertEqual(current?.woken, true)
        XCTAssertEqual(report.probe, "background-urlsession-upload")
    }

    func testWakeReportFlipsTheFlagOnlyOnce() async throws {
        let transport = RecordingProbeTransport(
            outcome: BackgroundProbeOutcome(statusCode: 200,
                                            errorDescription: nil))
        let probe = BackgroundURLSessionProbe(
            configuration: .init(isEnabled: true, request: request),
            transport: transport)
        _ = await probe.submitIfEnabled()
        let first = await probe.recordWake()
        XCTAssertEqual(first?.woken, true)
        let second = await probe.recordWake()
        XCTAssertEqual(second?.woken, true)
    }

    func testTransportErrorIsRecorded() async throws {
        let transport = RecordingProbeTransport(
            outcome: BackgroundProbeOutcome(statusCode: nil,
                                            errorDescription: "no route"))
        let probe = BackgroundURLSessionProbe(
            configuration: .init(isEnabled: true, request: request),
            transport: transport)
        let maybeReport = await probe.submitIfEnabled()
        let report = try XCTUnwrap(maybeReport)
        XCTAssertEqual(report.error, "no route")
        XCTAssertNil(report.statusCode)
    }

    func testEnvironmentFlagIsExplicit() {
        // The default follows the explicit process flag only.
        let expected = ProcessInfo.processInfo
            .environment[BackgroundURLSessionProbe.environmentFlag] == "1"
        XCTAssertEqual(BackgroundURLSessionProbe.isEnabledByEnvironment, expected)
        XCTAssertEqual(BackgroundURLSessionProbe.environmentFlag,
                       "PDSH_BACKGROUND_URLSESSION_PROBE")
    }
}
