// SPDX-License-Identifier: MIT
// Explicit physical-device integration test using the app's existing model.
import Foundation
import XCTest
import Security
@testable import PhoneDSHDeviceTasks
@testable import PhoneDSHProbe

private actor RealModelTaskInbox: DeviceTaskInbox {
    private var value: DeviceTaskOutcome?
    func accept(id: String) async throws {}
    func report(id: String, outcome: DeviceTaskOutcome) async throws { value = outcome }
    func result() -> DeviceTaskOutcome? { value }
}

@MainActor final class RealDeviceTaskModelTests: XCTestCase {
    private func configuredRunner() async throws -> DeviceDSHRunner {
        let chat = ChatModel.shared
        for _ in 0..<100 {
            if chat.anchor.isInWindow { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertTrue(chat.anchor.isInWindow, "The application engine anchor never entered a window")
        for _ in 0..<100 {
            if chat.isStarted { break }
            await chat.start()
            if chat.isStarted { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertTrue(chat.isStarted, "The application engine did not start")
        return DeviceDSHRunner(transport: try await chat.transportForManagement())
    }

    func testDeviceTaskAgainstConfiguredModel() async throws {
        let runner = try await configuredRunner()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pdsh-real-device-task-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let task = try DeviceTask.decode(Data(#"{"id":"real-model-1","idempotency_key":"real-model-1","requester":"device integration test","created_at":"2026-11-06T00:00:00Z","body":{"type":"goal","text":"Reply exactly PDSH_DEVICE_OK. Do not use tools or access files."}}"#.utf8))
        let inbox = RealModelTaskInbox()
        let executor = try DeviceTaskExecutor(directory: directory, runner: runner)
        try await executor.process(deviceID: "physical-test-device", task: task, authorized: true, inbox: inbox)
        let result = await inbox.result()
        XCTAssertEqual(result, .completed(output: "PDSH_DEVICE_OK", truncated: false))
    }
}

// Test-only pin for the ephemeral reference-device certificate. Production TLS
// continues to use the system trust store.
private final class RealModelFixtureTrust: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    let certificate: SecCertificate
    let hostname: String
    init(certificate: SecCertificate, hostname: String) { self.certificate = certificate; self.hostname = hostname }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == hostname, let trust = challenge.protectionSpace.serverTrust,
              let leaf = SecTrustGetCertificateAtIndex(trust, 0),
              SecCertificateCopyData(leaf) == SecCertificateCopyData(certificate) else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }
}

extension RealDeviceTaskModelTests {
    func testPhysicalLANDeviceToConfiguredModelAndBack() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["PDSH_TEST_LAN_HOST"], let port = env["PDSH_TEST_LAN_PORT"],
              let token = env["PDSH_TEST_LAN_TOKEN"], let cert64 = env["PDSH_TEST_LAN_CERT"],
              let certData = Data(base64Encoded: cert64), let cert = SecCertificateCreateWithData(nil, certData as CFData),
              let url = URL(string: "https://\(host):\(port)/mcp") else {
            throw XCTSkip("physical LAN fixture not supplied")
        }
        let delegate = RealModelFixtureTrust(certificate: cert, hostname: host)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let inbox = try LANDeviceTaskInbox(mcpURL: url, authorization: "Bearer " + token, session: session)
        var iterator = inbox.tasks().makeAsyncIterator()
        let received = try await iterator.next()
        let task = try XCTUnwrap(received)
        XCTAssertEqual(task.id, "physical-real-model-1")
        let runner = try await configuredRunner()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pdsh-real-lan-task-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executor = try DeviceTaskExecutor(directory: directory, runner: runner)
        try await executor.process(deviceID: inbox.deviceID, task: task, authorized: true, inbox: inbox)
        try await inbox.report(id: task.id, outcome: .completed(output: "PDSH_DEVICE_OK", truncated: false))
    }
}
