// SPDX-License-Identifier: MIT
// Exercises the real iOS Worker and task adapter with a scripted local model.
import Foundation
import XCTest
import PhoneDSH
import PhoneDSHAgentCore
@testable import PhoneDSHDeviceTasks
import PhoneDSHEngine
import PhoneDSHHarness
import Security

private actor DeviceTaskProductionInbox: DeviceTaskInbox {
    private var received: DeviceTaskOutcome?
    func accept(id: String) async throws {}
    func report(id: String, outcome: DeviceTaskOutcome) async throws { received = outcome }
    func outcome() -> DeviceTaskOutcome? { received }
}

@MainActor final class DeviceTaskProductionTests: XCTestCase {
    func testDeviceTaskRunsInRealWorkerWithoutTools() async throws {
        let mock = MockModelUpstream()
        mock.script = .sequence(tools: [], finalText: "DEVICE_TASK_OK")
        let upstream = try mock.start()
        defer { mock.stop() }
        let workspace = SimEnvironment.workspaceRoot(name: "device-task-\(UUID().uuidString.lowercased())")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let hostedBundle = PhoneDSHBundleLocation(staticDirectory: Bundle.main.bundleURL.appendingPathComponent("worker", isDirectory: true))
        let bundle = try hostedBundle.exists() ? hostedBundle : SimEnvironment.workerBundle()
        let visible = SimVisibleWindow()
        XCTAssertTrue(visible.isAttached)
        let engine = WebEngine(configuration: WebEngineConfiguration(origin: URL(string: "http://127.0.0.1:1")!, token: "placeholder"))
        engine.attach(to: visible.anchor)
        XCTAssertTrue(engine.isAttachedWithVisibleArea)
        var config = PhoneDSHConfiguration(workspaceRoot: workspace, token: "device-task-test-token",
            origin: URL(string: "http://127.0.0.1:1")!, bundle: bundle,
            allowedModelHosts: ["http://127.0.0.1:\(mock.port)"],
            credentialProvider: StaticCredentialProvider([CredentialScope(service: "127.0.0.1"):
                Credential(kind: .apiKey(header: "x-api-key"), value: "test-model-key")]),
            drainDeadline: 2, helloTimeout: 240)
        config.engine.bootTimeout = 240
        config.engine.environment = ["DEEPSEEK_BASE_URL": upstream.absoluteString,
                                     "DEEPSEEK_API_KEY": "phone-worker-placeholder",
                                     "DSH_TELEMETRY_DISABLED": "1"]
        let host = PhoneDSHHost(configuration: config, engineFactory: { _ in engine })
        do {
            try await host.start()
            try await simWait(timeout: 240, label: "device task host running") { await host.state == .running }
            let transport = try await host.makeTransport()
            let runner = DeviceDSHRunner(transport: transport), inbox = DeviceTaskProductionInbox()
            let task = try DeviceTask.decode(Data(#"{"id":"task-1","idempotency_key":"device-key-1","requester":"test device","created_at":"2026-11-06T00:00:00Z","body":{"type":"goal","text":"Say hello."}}"#.utf8))
            let executor = try DeviceTaskExecutor(directory: workspace.appendingPathComponent("device-task-test"), runner: runner)
            try await executor.process(deviceID: "device-test", task: task, authorized: true, inbox: inbox)
            let outcome = await inbox.outcome()
            XCTAssertEqual(outcome, .completed(output: "DEVICE_TASK_OK", truncated: false))
            let request = try XCTUnwrap(mock.requests.last)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
            XCTAssertTrue((payload["tools"] as? [Any] ?? []).isEmpty, "device task must not expose model tools")
            try await host.stop()
        } catch {
            try? await host.stop()
            throw error
        }
        _ = visible
    }
}

/// Pins only the ephemeral fixture certificate in this test target. The
/// production inbox continues to use unmodified system TLS verification.
private final class PhysicalLANFixtureTrust: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
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

extension DeviceTaskProductionTests {
    func testPhysicalLANDeviceToRealWorkerAndBack() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let hostName = env["PDSH_TEST_LAN_HOST"], let port = env["PDSH_TEST_LAN_PORT"],
              let token = env["PDSH_TEST_LAN_TOKEN"], let cert64 = env["PDSH_TEST_LAN_CERT"],
              let certData = Data(base64Encoded: cert64), let cert = SecCertificateCreateWithData(nil, certData as CFData),
              let url = URL(string: "https://\(hostName):\(port)/mcp") else {
            throw XCTSkip("physical LAN fixture not supplied")
        }
        let delegate = PhysicalLANFixtureTrust(certificate: cert, hostname: hostName)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let inbox = try LANDeviceTaskInbox(mcpURL: url, authorization: "Bearer " + token, session: session)
        var iterator = inbox.tasks().makeAsyncIterator()
        let received = try await iterator.next()
        let task = try XCTUnwrap(received)
        XCTAssertEqual(task.id, "physical-lan-1")
        let mock = MockModelUpstream(); mock.script = .sequence(tools: [], finalText: "DEVICE_TASK_OK")
        let upstream = try mock.start()
        defer { mock.stop() }
        let workspace = SimEnvironment.workspaceRoot(name: "physical-lan-task-\(UUID().uuidString.lowercased())")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let hostedBundle = PhoneDSHBundleLocation(staticDirectory: Bundle.main.bundleURL.appendingPathComponent("worker", isDirectory: true))
        let bundle = try hostedBundle.exists() ? hostedBundle : SimEnvironment.workerBundle()
        let visible = SimVisibleWindow(); XCTAssertTrue(visible.isAttached)
        let engine = WebEngine(configuration: WebEngineConfiguration(origin: URL(string: "http://127.0.0.1:1")!, token: "placeholder"))
        engine.attach(to: visible.anchor); XCTAssertTrue(engine.isAttachedWithVisibleArea)
        var config = PhoneDSHConfiguration(workspaceRoot: workspace, token: "physical-lan-test-token",
            origin: URL(string: "http://127.0.0.1:1")!, bundle: bundle,
            allowedModelHosts: ["http://127.0.0.1:\(mock.port)"],
            credentialProvider: StaticCredentialProvider([CredentialScope(service: "127.0.0.1"):
                Credential(kind: .apiKey(header: "x-api-key"), value: "test-model-key")]), drainDeadline: 2, helloTimeout: 240)
        config.engine.bootTimeout = 240
        config.engine.environment = ["DEEPSEEK_BASE_URL": upstream.absoluteString,
                                     "DEEPSEEK_API_KEY": "phone-worker-placeholder", "DSH_TELEMETRY_DISABLED": "1"]
        let host = PhoneDSHHost(configuration: config, engineFactory: { _ in engine })
        do {
            try await host.start()
            try await simWait(timeout: 240, label: "physical LAN task host running") { await host.state == .running }
            let runner = DeviceDSHRunner(transport: try await host.makeTransport())
            let executor = try DeviceTaskExecutor(directory: workspace.appendingPathComponent("device-task-test"), runner: runner)
            try await executor.process(deviceID: inbox.deviceID, task: task, authorized: true, inbox: inbox)
            // The reference device returns 409 only for an identical stored
            // outcome; a mismatch is 422 and fails this test.
            try await inbox.report(id: task.id, outcome: .completed(output: "DEVICE_TASK_OK", truncated: false))
            let request = try XCTUnwrap(mock.requests.last)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
            XCTAssertTrue((payload["tools"] as? [Any] ?? []).isEmpty)
            try await host.stop()
        } catch {
            try? await host.stop()
            throw error
        }
        _ = visible
    }
}
