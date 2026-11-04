// SPDX-License-Identifier: MIT
// Actual WKWebView/Worker/Agent tools and durable restart; scripted model only.
#if os(macOS)
import AppKit
import Foundation
import XCTest
import PhoneDSH
import PhoneDSHAgentCore
import PhoneDSHEngine
import PhoneDSHHarness

@MainActor
final class PhoneDSHSmokeCreatorTests: XCTestCase {
    func testCreatorAuthorsInstallsAndResumesLocalPresetWithoutEntryPrompt() async throws {
        let environment: SmokeEnvironment
        do { environment = try SmokeEnvironment.resolve() }
        catch let skip as SmokeSkip { throw XCTSkip(skip.detail) }
        let nonce = UUID().uuidString.lowercased()
        let workspace = environment.smokeDirectory.appendingPathComponent("creator-\(nonce)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let directory = "/dsh/workspace/creator-bundle"
        let packageName = "@local/wk-created-review"
        let presetID = "wk-created-review"
        let manifest = #"{"name":"@local/wk-created-review","version":"1.0.0","private":true,"type":"module","dsh":{"bundle":{"patch":"./cordis.patch.yml"}}}"#
        let patch = """
        - insert:
            - id: preset-wk-created-review
              name: '@deepseek-ai/dsh-agent-preset'
              config:
                id: wk-created-review
                name: WK Created Review
                plugins:
                  - id: persona
                    name: '@deepseek-ai/dsh-persona'
                    config:
                      prefix: Review only, created through the real Worker.
                  - id: tool-fs
                    name: '@deepseek-ai/dsh-tool-fs'

        """
        let model = MockModelUpstream()
        model.script = .sequence(tools: [
            MockModelToolCall(name: "cordis_inspect_list", arguments: .object([:])),
            MockModelToolCall(name: "cordis_inspect_query", arguments: .object([
                "platform": .string("host"), "provider": .string("Config"), "method": .string("listConfigs"),
                "input": .object(["name": .string("@deepseek-ai/dsh-persona")]),
            ])),
            MockModelToolCall(name: "write", arguments: .object([
                "file_path": .string("\(directory)/package.json"), "content": .string(manifest),
            ])),
            MockModelToolCall(name: "write", arguments: .object([
                "file_path": .string("\(directory)/cordis.patch.yml"), "content": .string(patch),
            ])),
            MockModelToolCall(name: "plugin_manager", arguments: .object([
                "action": .string("install_bundle"), "target": .string(directory),
            ])),
        ], finalText: "CREATOR_DONE")
        let modelURL = try model.start()
        defer { model.stop() }
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 160, height: 120),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
        window.contentView = container
        WebEngineAppKitEventPump.show(window)
        defer { window.close() }
        let engine = WebEngine(configuration: WebEngineConfiguration(
            origin: URL(string: "http://127.0.0.1:1")!, token: "creator-placeholder"))
        engine.attach(to: container)
        var configuration = PhoneDSHConfiguration(
            workspaceRoot: workspace, token: "creator-launch-\(nonce)",
            origin: URL(string: "http://127.0.0.1:1")!,
            bundle: PhoneDSHBundleLocation(staticDirectory: environment.staticDirectory,
                                           imageArchive: environment.imageArchive),
            allowedModelHosts: ["http://127.0.0.1:\(model.port)"],
            credentialProvider: StaticCredentialProvider([
                CredentialScope(service: "127.0.0.1"): Credential(kind: .apiKey(header: "x-api-key"), value: "creator-dummy-key"),
            ]), drainDeadline: 2, helloTimeout: 240)
        configuration.engine.bootTimeout = 240
        configuration.engine.environment = ["DEEPSEEK_BASE_URL": modelURL.absoluteString,
                                            "DEEPSEEK_API_KEY": "creator-dummy-worker-key",
                                            "DSH_TELEMETRY_DISABLED": "1"]
        let host = PhoneDSHHost(configuration: configuration, engineFactory: { _ in engine })
        let events = SmokeEventLog()
        events.attach(host: host)
        defer { events.stop() }
        do {
            try await host.start()
            _ = try await harnessAssertPageVisible(engine, label: "before Creator")
            let transport = try await host.makeTransport()
            let roster = try await transport.call("agentPresets/list", args: .object([:]))
            let cordis = try XCTUnwrap(roster["presets"]?.arrayValue?.first { $0["id"]?.stringValue == "cordis" })
            XCTAssertNil(cordis["broken"])
            let harness = try await host.harness()
            let creator = try await harness.openSession(HarnessSessionRequest(preset: "cordis", workspace: "/dsh/workspace"))
            let initial = try await transport.call("session/projections", args: .object([
                "request": .object(["sessionId": .string(creator.id)]),
            ]))
            XCTAssertEqual(initial["values"]?["agentPreset"]?.stringValue, "cordis")
            XCTAssertEqual(model.requestCount, 0, "Opening Creator must not send a model request")
            // Explicit test permission selection; the product entry does not elevate access.
            _ = try await transport.call("commands/execute", args: .object([
                "agentId": .string(creator.id), "line": .string("/permission danger-full-access"), "submittedAttachments": .array([]),
            ]))
            events.attach(harness: harness, sessionID: creator.id)
            try await harness.send(.prompt(text: "Create and install the local review preset requested by this test.",
                                            attachments: [], requestID: "creator-explicit-\(nonce)"), to: creator.id)
            try await smokeWait(timeout: 180, label: "Creator explicit task completes") {
                events.harnessEvents.contains { event in
                    if case .turnEnded = event.kind { return true }
                    return false
                }
            }
            for event in events.harnessEvents {
                if case .turnEnded(_, let reason) = event.kind { XCTAssertEqual(reason, .completed) }
                if case .toolResult(_, let isError, let summary) = event.kind { XCTAssertFalse(isError, summary) }
            }
            XCTAssertTrue(model.requests.contains { String(decoding: $0.body, as: UTF8.self).contains("Phone Creator supports workspace-local") })
            let authored = workspace.appendingPathComponent("materialized/workspace/creator-bundle/cordis.patch.yml")
            let installed = workspace.appendingPathComponent("materialized/home/profiles/web/node_modules/\(packageName)/cordis.patch.yml")
            try await smokeWait(timeout: 30, label: "Creator files reach durable materialization") {
                FileManager.default.fileExists(atPath: authored.path) && FileManager.default.fileExists(atPath: installed.path)
            }
            XCTAssertEqual(try String(contentsOf: authored, encoding: .utf8), patch)
            XCTAssertEqual(try String(contentsOf: installed, encoding: .utf8), patch)
            let document = try await transport.call("agentPresets/read", args: .object(["agentPreset": .string(presetID)]))
            XCTAssertTrue(document["content"]?.stringValue?.contains("created through the real Worker") == true)
            try await host.plannedRestart(reason: "creator-persistence")
            let after = try await host.makeTransport()
            let coldDocument = try await after.call("agentPresets/read", args: .object(["agentPreset": .string(presetID)]))
            XCTAssertEqual(coldDocument["content"], document["content"])
            let coldHarness = try await host.harness()
            let custom = try await coldHarness.openSession(HarnessSessionRequest(preset: presetID, workspace: "/dsh/workspace"))
            let projection = try await after.call("session/projections", args: .object([
                "request": .object(["sessionId": .string(custom.id)]),
            ]))
            XCTAssertEqual(projection["values"]?["agentPreset"]?.stringValue, presetID)
            print("CREATOR_WK_PASS authored=2 installed=2 cold_preset=\(presetID) model=scripted")
        } catch {
            try? await host.stop()
            XCTFail("Creator WK failed: \(error)\n\(events.tail(40).joined(separator: "\n"))")
            return
        }
        try await host.stop()
    }
}
#endif
