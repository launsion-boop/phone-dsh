// SPDX-License-Identifier: MIT
// Host §10.3.5: the dshSchedule mirror is built from the engine's real
// `schedule/list` remote method. This test boots the production WebHost
// assembly in the simulator and calls that method through the real transport,
// so the namespace and the request shape are verified against the Worker, not
// guessed from a type declaration.
import Foundation
import XCTest
import ProbeKit
import PhoneDSH
import PhoneDSHAgentCore
import PhoneDSHEngine

@MainActor
final class DshScheduleListSimTests: XCTestCase {
    func testScheduleListIsServedByTheRealWorker() async throws {
        let workspace = SimEnvironment.workspaceRoot(
            name: "schedule-list-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let bundle = try SimEnvironment.workerBundle()
        let visible = SimVisibleWindow(size: CGSize(width: 430, height: 932))
        let anchor = VisibleEngineAnchor()
        visible.anchor.addSubview(anchor.view)
        visible.window.layoutIfNeeded()
        guard anchor.isInWindow else {
            throw SimError.assertion("the schedule-list anchor is not in a visible window")
        }
        let assembly = WebHostConfiguration.make(
            workspaceRoot: workspace,
            bundle: bundle,
            modelURL: URL(string: "http://127.0.0.1:1")!,
            modelName: "deepseek-flash",
            credentialProvider: RecordingModelCredentialProvider(value: "sim-model-key"),
            egressHosts: [],
            loopbackPort: WebHostConfiguration.freeLoopbackPort(),
            allowedModelHosts: [],
            environment: [
                "DEEPSEEK_API_KEY": "phone-host-injects-key",
                "DEEPSEEK_BASE_URL": "http://127.0.0.1:1",
                "DSH_TELEMETRY_DISABLED": "1",
                "PDSH_MODEL_NAME": "deepseek-flash",
            ],
            drainDeadline: 5,
            helloTimeout: 240)
        let host = PhoneDSHHost(
            configuration: assembly.configuration,
            engineFactory: WebHostConfiguration.engineFactory(anchor: anchor))
        do {
            try await host.start()
            try await simWait(timeout: 240, label: "schedule/list host Running") {
                await host.state == .running
            }
            let transport = try await host.makeTransport()
            let result = try await transport.call(
                "schedule/list",
                args: .object(["request": .object([
                    "active": .bool(true),
                    "limit": .number(1),
                ])]))
            // The method answers the documented ScheduleListResult page shape.
            XCTAssertNotNil(result["items"]?.arrayValue,
                            "schedule/list did not return an items page: \(result)")
            XCTAssertNotNil(result["total"], "schedule/list did not return total")
            XCTAssertEqual(result["limit"]?.numberValue, 1)
        } catch {
            try? await host.stop()
            throw error
        }
        try? await host.stop()
    }
}
