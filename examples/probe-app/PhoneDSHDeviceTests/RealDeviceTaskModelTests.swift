// SPDX-License-Identifier: MIT
// Explicit physical-device integration test using the app's existing model.
import Foundation
import XCTest
import Security
import PhoneDSH
import PhoneDSHBLE
import PhoneDSHAgentCore
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

private final class TaskTestSecrets: ModelProviderSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func secret(for reference: String) throws -> String? { lock.lock(); defer { lock.unlock() }; return values[reference] }
    func setSecret(_ secret: String, for reference: String) throws { lock.lock(); defer { lock.unlock() }; values[reference] = secret }
    func deleteSecret(for reference: String) throws { lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: reference) }
}

@MainActor private final class TaskTestConnection {
    var connected = true
    var fail = false
    var paused = false
    var reading = false
    func status() async throws -> Bool {
        reading = true
        while paused { try await Task.sleep(for: .milliseconds(20)) }
        if fail { throw NSError(domain: "TaskTestConnection", code: 1) }
        return connected
    }
}

extension RealDeviceTaskModelTests {
    func testLANManagerGrantAndForegroundLifecycle() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["PDSH_TEST_LAN_HOST"], let port = env["PDSH_TEST_LAN_PORT"],
              let token = env["PDSH_TEST_LAN_TOKEN"], let cert64 = env["PDSH_TEST_LAN_CERT"],
              let certData = Data(base64Encoded: cert64), let cert = SecCertificateCreateWithData(nil, certData as CFData),
              let url = URL(string: "https://\(host):\(port)/mcp") else {
            throw XCTSkip("physical LAN fixture not supplied")
        }
        _ = try await configuredRunner()
        let delegate = RealModelFixtureTrust(certificate: cert, hostname: host)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let suite = "DeviceTaskManagerTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = PhoneMCPAccessSettings(defaults: defaults, secretStore: TaskTestSecrets())
        let connection = TaskTestConnection()
        let manager = DeviceTaskManager(settings: settings, makeLANInbox: { url, auth in
            try LANDeviceTaskInbox(mcpURL: url, authorization: auth, session: session)
        }, isLANConnected: { _ in try await connection.status() })
        let key = DeviceTaskManager.lanKey("fixture")
        func row(_ grant: PhoneMCPAccessGrant?) -> PhoneDSHProbe.MCPServerSummary {
            PhoneDSHProbe.MCPServerSummary(serverName: "fixture", url: url.absoluteString, enabled: true,
                             toolCallTimeoutMs: 10_000, headers: [], status: "connected", error: nil, tools: [], grant: grant)
        }
        await manager.startLAN(row(nil))
        XCTAssertFalse(manager.isActive(key), "MCP connection without an explicit task grant must not start intake")
        var grant = try settings.grant(serverName: "fixture", url: url.absoluteString,
                                       headers: ["Authorization"], values: ["Authorization": "Bearer " + token])
        connection.connected = false
        await manager.startLAN(row(grant))
        XCTAssertFalse(manager.isActive(key), "A stale connected UI row must not start intake")
        connection.connected = true
        connection.fail = true
        await manager.startLAN(row(grant))
        XCTAssertFalse(manager.isActive(key), "A failed registry read must not start intake")
        connection.fail = false
        connection.reading = false
        connection.paused = true
        let staleGrant = grant
        let pending = Task { await manager.startLAN(row(staleGrant)) }
        for _ in 0..<100 {
            if connection.reading { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(connection.reading, "The registry read did not start")
        try settings.revoke(serverName: "fixture")
        connection.paused = false
        await pending.value
        XCTAssertFalse(manager.isActive(key), "Revocation during the registry lookup must prevent intake")
        grant = try settings.grant(serverName: "fixture", url: url.absoluteString,
                                   headers: ["Authorization"], values: ["Authorization": "Bearer " + token])
        await manager.startLAN(row(grant))
        XCTAssertTrue(manager.isActive(key))
        let acceptAnyOutput = env["PDSH_TEST_LAN_EXPECT_ANY"] == "1"
        if let expectedID = env["PDSH_TEST_LAN_TASK_ID"],
           acceptAnyOutput || env["PDSH_TEST_LAN_TASK_OUTPUT"] != nil {
            let expectedOutput = env["PDSH_TEST_LAN_TASK_OUTPUT"]
            let seconds = min(180, max(1, Int(env["PDSH_TEST_LAN_TIMEOUT_SECONDS"] ?? "20") ?? 20))
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                      appropriateFor: nil, create: true)
            let journal = support.appendingPathComponent("device-task-journal", isDirectory: true)
            var completed = false
            for _ in 0..<(seconds * 10) {
                let files = (try? FileManager.default.contentsOfDirectory(at: journal, includingPropertiesForKeys: nil)) ?? []
                let records = files.compactMap { url -> DeviceTaskRecord? in
                    guard url.pathExtension == "json", let data = try? Data(contentsOf: url) else { return nil }
                    return try? JSONDecoder().decode(DeviceTaskRecord.self, from: data)
                }
                if records.contains(where: { record in
                    guard record.task.id == expectedID, record.phase == .terminal,
                          case let .completed(output, truncated) = record.outcome, !output.isEmpty else { return false }
                    return acceptAnyOutput || (output == expectedOutput && !truncated)
                }) { completed = true; break }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertTrue(completed, "The real manager did not complete the reference-device task")
        }
        await manager.stop(key)
        XCTAssertFalse(manager.isActive(key))
        await manager.startLAN(row(grant))
        XCTAssertTrue(manager.isActive(key))
        await manager.sceneActive(false)
        XCTAssertFalse(manager.isActive(key), "Entering the background must stop the connection-scoped grant")
        await manager.startLAN(row(grant))
        XCTAssertFalse(manager.isActive(key), "A background app must not start intake")
        await manager.sceneActive(true)
        await manager.startLAN(row(grant))
        XCTAssertTrue(manager.isActive(key))
        try settings.revoke(serverName: "fixture")
        for _ in 0..<40 {
            if !manager.isActive(key) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertFalse(manager.isActive(key), "Revoking the underlying MCP credential must stop intake")
        let newGrant = try settings.grant(serverName: "fixture", url: url.absoluteString,
                                          headers: ["Authorization"], values: ["Authorization": "Bearer " + token])
        await manager.startLAN(row(newGrant))
        XCTAssertTrue(manager.isActive(key))
        connection.connected = false
        for _ in 0..<40 {
            if !manager.isActive(key) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertFalse(manager.isActive(key), "A disconnected registry entry must stop intake")
        connection.connected = true
        await manager.startLAN(row(newGrant))
        XCTAssertTrue(manager.isActive(key))
        connection.fail = true
        for _ in 0..<40 {
            if !manager.isActive(key) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertFalse(manager.isActive(key), "An unreadable registry must fail closed")
        await manager.stop(key)
    }
}


extension RealDeviceTaskModelTests {
    func testBluetoothRadioReferenceDeviceToConfiguredModelAndBack() async throws {
        guard ProcessInfo.processInfo.environment["PDSH_TEST_BLE_RADIO"] == "1" else {
            throw XCTSkip("Bluetooth radio fixture not supplied")
        }
        let store = BLEDeviceStore.shared
        store.setDeviceTaskDiscoveryEnabled(true)
        defer { store.stopScan(); store.setDeviceTaskDiscoveryEnabled(false) }
        store.scan()
        var selected: UUID?
        for _ in 0..<200 {
            if let device = store.devices.first(where: { $0.name == "PDSHRT" }) { selected = device.id; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let id = try XCTUnwrap(selected, "The Bluetooth radio fixture was not discovered: \(store.bluetoothDiagnostics)")
        store.connect(id)
        defer { store.disconnect(id) }
        for _ in 0..<400 {
            if store.devices.first(where: { $0.id == id })?.supportsDeviceTasks == true { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let device = try XCTUnwrap(store.devices.first(where: { $0.id == id }))
        guard device.supportsDeviceTasks else {
            return XCTFail("Link task capability was not negotiated: \(device.linkState); \(store.status)")
        }
        try store.grantDeviceTasks(id, enabled: true)
        let inbox = try BLEDeviceTaskInbox(peripheralID: id, store: store)
        let received = try await inbox.next()
        let task = try XCTUnwrap(received)
        XCTAssertEqual(task.id, "task-1")
        let runner = try await configuredRunner()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pdsh-real-ble-task-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executor = try DeviceTaskExecutor(directory: directory, runner: runner)
        try await executor.process(deviceID: inbox.deviceID, task: task, authorized: true, inbox: inbox)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let records = files.compactMap { url -> DeviceTaskRecord? in
            guard url.pathExtension == "json", let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(DeviceTaskRecord.self, from: data)
        }
        let record = try XCTUnwrap(records.first(where: { $0.task.id == task.id }))
        guard case let .completed(output, _) = record.outcome else { return XCTFail("Model task did not complete successfully") }
        XCTAssertFalse(output.isEmpty)
        let remaining = try await inbox.next()
        XCTAssertNil(remaining, "The reference-device task remained nonterminal")
    }
}


extension RealDeviceTaskModelTests {
    func testUnprotectedBluetoothPeerCannotBecomeTaskDevice() async throws {
        guard ProcessInfo.processInfo.environment["PDSH_TEST_BLE_UNPROTECTED"] == "1" else {
            throw XCTSkip("Unprotected Bluetooth radio fixture not supplied")
        }
        let store = BLEDeviceStore.shared
        store.setDeviceTaskDiscoveryEnabled(true)
        defer { store.stopScan(); store.setDeviceTaskDiscoveryEnabled(false) }
        store.scan()
        var selected: UUID?
        for _ in 0..<200 {
            if let device = store.devices.first(where: { $0.name == "PDSHRT" }) { selected = device.id; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let id = try XCTUnwrap(selected, "The unprotected fixture was not discovered")
        store.connect(id)
        defer { store.disconnect(id) }
        for _ in 0..<150 {
            if store.devices.first(where: { $0.id == id })?.linkState.contains("PDSH Tools v1") == true { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let device = try XCTUnwrap(store.devices.first(where: { $0.id == id }))
        XCTAssertTrue(device.linkState.contains("PDSH Tools v1"), "Negative control did not complete ordinary Link discovery: \(device.linkState); \(store.status)")
        XCTAssertFalse(device.supportsDeviceTasks, "An unprotected BLE peer was accepted for device tasks")
        XCTAssertThrowsError(try store.grantDeviceTasks(id, enabled: true))
    }
}

extension RealDeviceTaskModelTests {
    func testPhysicalESP32OrdinaryLinkAndTaskContainment() async throws {
        guard ProcessInfo.processInfo.environment["PDSH_TEST_ESP32_RADIO"] == "1" else {
            throw XCTSkip("ESP32 Bluetooth radio fixture not supplied")
        }
        try await verifyOrdinaryLink(name: "PDSH ESP32 Link")
    }

    func testPairedMacOrdinaryLinkAndTaskContainment() async throws {
        guard ProcessInfo.processInfo.environment["PDSH_TEST_PAIRED_MAC_RADIO"] == "1" else {
            throw XCTSkip("Paired macOS Bluetooth radio fixture not supplied")
        }
        try await verifyOrdinaryLink(name: "PDSHRT")
    }

    private func verifyOrdinaryLink(name: String) async throws {
        let store = BLEDeviceStore.shared
        // Exercise task-tool advertisement on the ESP32 while keeping the
        // other ordinary-link fixtures at their original profile.
        store.setDeviceTaskDiscoveryEnabled(name == "PDSH ESP32 Link")
        defer { store.stopScan() }
        store.scan()
        var selected: UUID?
        for attempt in 0..<600 {
            if let device = store.devices.first(where: { $0.name == name }) { selected = device.id; break }
            if attempt > 0 && attempt % 140 == 0 { store.scan() }
            try await Task.sleep(for: .milliseconds(100))
        }
        let id = try XCTUnwrap(selected, "The Bluetooth peer \(name) was not discovered: \(store.bluetoothDiagnostics)")
        store.connect(id)
        defer { store.disconnect(id) }
        for _ in 0..<400 {
            if store.devices.first(where: { $0.id == id })?.linkState.contains("PDSH Tools v1") == true { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let device = try XCTUnwrap(store.devices.first(where: { $0.id == id }))
        guard device.linkState.contains("PDSH Tools v1") else {
            return XCTFail("Link discovery failed: \(device.linkState); \(store.status)")
        }
        XCTAssertNotNil(UUID(uuidString: device.linkIdentity))
        // No draft identity proof is called, even when the peer advertises it.
        XCTAssertTrue(device.pendingIdentity.isEmpty)
        XCTAssertTrue(device.taskIdentity.isEmpty)
        print("PDSH_IDENTITY_STATE name=\(name) trusted=\(!device.taskIdentity.isEmpty) pending=\(!device.pendingIdentity.isEmpty) supports=\(device.supportsDeviceTasks)")
        // Even a previously confirmed identity does not close GAP-16.
        XCTAssertFalse(device.supportsDeviceTasks)
        XCTAssertThrowsError(try store.grantDeviceTasks(id, enabled: true))
        if device.linkTools.contains("light.get") {
            store.grantLinkTool(id, name: "light.get", enabled: true)
            let request = UUID()
            let result = try await store.invokeLink(id, requestID: request, name: "light.get", arguments: .object([:]), key: UUID().uuidString.lowercased())
            XCTAssertEqual(result["status"]?.stringValue, "completed")
        }
    }
}

#if PDSH_TEST_HOOKS
private actor GrantTestRunner: DeviceTaskRunner {
    func session(for deviceID: String, existingSession: String?) async throws -> String { existingSession ?? "test" }
    func run(task: DeviceTask, record: DeviceTaskRecord) async -> DeviceTaskOutcome { .completed(output: "test", truncated: false) }
    func cancel(sessionID: String) async {}
}
private struct GrantTestTransport: DSHRemoteTransport {
    func call(_ endpoint: String, args: JSONValue) async throws -> JSONValue { throw DeviceTaskError.unauthorized }
    func openMux() async throws -> any DSHMuxConnection { throw DeviceTaskError.unauthorized }
}
private final class GrantTestURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {}
}
@MainActor private final class GrantTestMonitorGate {
    var count = 0
    var held = false
    var continuation: CheckedContinuation<Void, Never>?
    var finished = false
    func markFinished() { finished = true }
    func check() async -> Bool {
        count += 1
        if count == 2 {
            held = true
            await withCheckedContinuation { continuation = $0 }
            return false
        }
        return true
    }
    func release() { continuation?.resume(); continuation = nil }
}

extension RealDeviceTaskModelTests {
    /// A real manager starts twice while an old connection monitor is held.
    /// No external network, configured model, or physical device is required.
    func testOldLANMonitorCannotRevokeNewGeneration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executor = try DeviceTaskExecutor(directory: directory, runner: GrantTestRunner())
        let intake = DeviceTaskIntake(executor: executor)
        let runner = DeviceDSHRunner(transport: GrantTestTransport())
        let suite = "DeviceTaskManagerGeneration." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = PhoneMCPAccessSettings(defaults: defaults, secretStore: TaskTestSecrets())
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GrantTestURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let gate = GrantTestMonitorGate()
        let manager = DeviceTaskManager(settings: settings, makeLANInbox: { url, auth in
            try LANDeviceTaskInbox(mcpURL: url, authorization: auth, session: session)
        }, isLANConnected: { _ in await gate.check() })
        manager.testEngine = (intake, runner)
        let url = "https://fixture.example/mcp"
        let grant = try settings.grant(serverName: "fixture", url: url,
                                       headers: ["Authorization"], values: ["Authorization": "Bearer test"])
        let row = PhoneDSHProbe.MCPServerSummary(serverName: "fixture", url: url, enabled: true,
                          toolCallTimeoutMs: 10_000, headers: [], status: "connected", error: nil, tools: [], grant: grant)
        let key = DeviceTaskManager.lanKey("fixture")
        await manager.startLAN(row)
        XCTAssertTrue(manager.isActive(key))
        let oldGeneration = try XCTUnwrap(manager.testGeneration(key))
        let monitorReturned = expectation(description: "old monitor returned after its connection check")
        manager.testMonitorFinished = { token in if token == oldGeneration { gate.markFinished(); monitorReturned.fulfill() } }
        for _ in 0..<200 {
            if gate.held { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard gate.held else { await manager.stop(key); return XCTFail("old monitor did not reach the gate") }
        await manager.stop(key)
        await manager.startLAN(row)
        XCTAssertTrue(manager.isActive(key))
        gate.release()
        await fulfillment(of: [monitorReturned], timeout: 10)
        XCTAssertTrue(gate.finished)
        XCTAssertTrue(manager.isActive(key), "late old monitor revoked the new generation")
        await manager.stop(key)
    }

    /// The manager maps the LAN server name to the settlement and clears the
    /// mapping with the grant lifecycle. The executor observer itself is
    /// covered by PhoneDSHDeviceTasksTests; this host test covers the App-side
    /// name lookup and the owner-scoped callback install/remove.
    func testSettlementDisplayNameAndOwnerScopedCallback() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executor = try DeviceTaskExecutor(directory: directory, runner: GrantTestRunner())
        let intake = DeviceTaskIntake(executor: executor)
        let runner = DeviceDSHRunner(transport: GrantTestTransport())
        let suite = "DeviceTaskManagerSettlement." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = PhoneMCPAccessSettings(defaults: defaults, secretStore: TaskTestSecrets())
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GrantTestURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let manager = DeviceTaskManager(settings: settings, makeLANInbox: { url, auth in
            try LANDeviceTaskInbox(mcpURL: url, authorization: auth, session: session)
        }, isLANConnected: { _ in true })
        manager.testEngine = (intake, runner)
        let url = "https://fixture.example/mcp"
        let grant = try settings.grant(serverName: "fixture", url: url,
                                       headers: ["Authorization"], values: ["Authorization": "Bearer test"])
        let row = PhoneDSHProbe.MCPServerSummary(serverName: "fixture", url: url, enabled: true,
                          toolCallTimeoutMs: 10_000, headers: [], status: "connected", error: nil, tools: [], grant: grant)
        let key = DeviceTaskManager.lanKey("fixture")
        await manager.startLAN(row)
        XCTAssertTrue(manager.isActive(key))
        let deviceID = try LANDeviceTaskInbox(mcpURL: try XCTUnwrap(URL(string: url)),
                                              authorization: "Bearer test", session: session).deviceID
        let settlement = DeviceTaskSettlement(
            deviceID: deviceID, taskID: "task-1", idempotencyKey: "key-1", goal: "goal",
            outcome: .completed(output: "Answer", truncated: false))
        let owner = NSObject()
        var observed: (DeviceTaskSettlement, String)?
        manager.installTaskSettlementHandler(owner: owner) { value, name in
            observed = (value, name)
        }
        manager.testDeliverSettlement(settlement)
        XCTAssertEqual(observed?.0, settlement)
        XCTAssertEqual(observed?.1, "fixture")

        manager.removeTaskSettlementHandler(owner: NSObject())
        observed = nil
        manager.testDeliverSettlement(settlement)
        XCTAssertEqual(observed?.1, "fixture", "a foreign owner must not remove the handler")

        await manager.stop(key)
        observed = nil
        manager.testDeliverSettlement(settlement)
        XCTAssertEqual(observed?.1, deviceID, "the display name must be cleared with the grant")

        manager.removeTaskSettlementHandler(owner: owner)
        observed = nil
        manager.testDeliverSettlement(settlement)
        XCTAssertNil(observed, "the owner-scoped removal must stop delivery")
    }
}

#endif
