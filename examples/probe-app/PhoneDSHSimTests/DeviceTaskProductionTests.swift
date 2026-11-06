// SPDX-License-Identifier: MIT
// Exercises the real iOS Worker and task adapter with a scripted local model.
import Foundation
import XCTest
import PhoneDSH
import PhoneDSHAgentCore
import PhoneDSHDeviceTasks
import PhoneDSHEngine
import PhoneDSHHarness

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
