// SPDX-License-Identifier: MIT
#if os(macOS)
import Foundation
import Security
import XCTest
@testable import PhoneDSHDeviceTasks

private final class FixtureTrust: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    let certificate: SecCertificate
    init(_ certificate: SecCertificate) { self.certificate = certificate }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        guard challenge.protectionSpace.host == "localhost",
              let leaf = SecTrustGetCertificateAtIndex(trust, 0),
              SecCertificateCopyData(leaf) == SecCertificateCopyData(certificate) else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        // Test-only pin: production uses the OS trust store without this delegate.
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

private actor FixtureRunner: DeviceTaskRunner {
    private(set) var count = 0
    func session(for deviceID: String, existingSession: String?) async throws -> String { "fixture-session" }
    func run(task: DeviceTask, record: DeviceTaskRecord) async -> DeviceTaskOutcome {
        count += 1
        return .completed(output: "fixture answer", truncated: false)
    }
    func cancel(sessionID: String) async {}
}

final class LANRealInboxTests: XCTestCase {
    private func run(_ arguments: [String], directory: URL? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = Pipe(); process.standardError = Pipe()
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "fixture command failed")
    }

    func testSwiftInboxExecutorAgainstAuthenticatedTLSDevice() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let device = root.appendingPathComponent("examples/lan-mcp-device")
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let cert = temp.appendingPathComponent("cert.pem"), key = temp.appendingPathComponent("key.pem")
        let token = temp.appendingPathComponent("token"), state = temp.appendingPathComponent("state.sqlite")
        try Data(String(repeating: "x", count: 40).utf8).write(to: token)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: token.path)
        try run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost", "-keyout", key.path, "-out", cert.path])
        try run(["python3", device.appendingPathComponent("taskctl.py").path, "--state", state.path, "submit", "--id", "fixture:1", "--text", "Hello from device"])
        let process = Process(), output = Pipe(), error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", device.appendingPathComponent("server.py").path, "--cert", cert.path, "--key", key.path,
                             "--token-file", token.path, "--hostname", "localhost", "--listen", "127.0.0.1", "--port", "0", "--state", state.path]
        process.standardOutput = output; process.standardError = error
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        let line = try XCTUnwrap(String(data: output.fileHandleForReading.availableData, encoding: .utf8))
        let port = try XCTUnwrap(Int(line.split(separator: " ").last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""))
        let pem = try String(contentsOf: cert, encoding: .utf8)
        let base64 = pem.components(separatedBy: "\n").filter { !$0.hasPrefix("---") }.joined()
        let certData = try XCTUnwrap(Data(base64Encoded: base64))
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, certData as CFData))
        let session = URLSession(configuration: .ephemeral, delegate: FixtureTrust(certificate), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let inbox = try LANDeviceTaskInbox(mcpURL: XCTUnwrap(URL(string: "https://localhost:\(port)/mcp")),
                                           authorization: "Bearer " + String(repeating: "x", count: 40), session: session)
        var iterator = inbox.tasks().makeAsyncIterator()
        let received = try await iterator.next()
        let task = try XCTUnwrap(received)
        XCTAssertEqual(task.id, "fixture:1")
        let runner = FixtureRunner()
        let executor = try DeviceTaskExecutor(directory: temp.appendingPathComponent("journal"), runner: runner)
        try await executor.process(deviceID: "lan-fixture", task: task, authorized: true, inbox: inbox)
        let count = await runner.count
        XCTAssertEqual(count, 1)
        // A matching terminal report is idempotent and is acknowledged by the real device.
        try await inbox.report(id: task.id, outcome: .completed(output: "fixture answer", truncated: false))
        do {
            try await inbox.report(id: task.id, outcome: .completed(output: "other", truncated: false))
            XCTFail("conflicting terminal report must fail")
        } catch { XCTAssertEqual(error as? LANDeviceTaskInboxError, .conflict) }
    }
}
#endif
