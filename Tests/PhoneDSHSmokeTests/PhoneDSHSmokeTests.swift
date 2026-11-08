// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — macOS end-to-end smoke (W2-SMOKE, G1 rehearsal).
//
// One real tool-call turn through the whole stack:
//
//   scripted model upstream → host ModelGateway → WKWebView Worker (real packed
//   DSH image) → DSH bash tool → VFS sink → ordered channel → WAL/materialized
//   copy → tool journal → host step machine
//
// then one `PhoneDSHHost.plannedRestart(reason:)` (D24), a resumed session
// with a second trivial turn, and a comparison that the WAL/materialized
// evidence for the first turn did not change.
//
// The test fails loud (last 50 console lines in the failure message,
// `$TMPDIR/pdsh-smoke/smoke-report.json` on disk) rather than hanging. It skips
// only when `scripts/ci/smoke.sh` could not export the built image/www.
//
// NOT_VERIFIED on an iPhone: this runs on macOS with the system WKWebView.

import AppKit
import Foundation
import XCTest
import WebKit
import PhoneDSHAgentCore
import PhoneDSHHarness
import PhoneDSHController
import PhoneDSH
import PhoneDSHEngine
import PhoneDSHLog
import PhoneDSHWire
import PhoneDSHSSH
import PhoneDSHShell
import PhoneDSHADB

private actor SmokeAndroidExecutor: ADBCommandExecuting {
    var commands: [String] = []
    func shell(endpoint: ADBEndpoint, command: String, timeout: TimeInterval, outputLimit: Int) async throws -> ADBShellResult {
        commands.append(command)
        return ADBShellResult(stdout: Data("package:/data/app/example/base.apk=com.example.smoke installer=com.android.vending\n".utf8))
    }
}

@MainActor
final class PhoneDSHSmokeTests: XCTestCase {
    /// Workspace-relative file the scripted shell writes.
    private static let targetPath = "/dsh/workspace/a.txt"
    /// Host credential the gateway injects for the mock upstream.
    private static let hostAPIKey = "smoke-host-key"
    /// Placeholder key the Worker's DSH adapter resolves from its own
    /// environment; the host gateway replaces it before the upstream sees it.
    private static let workerPlaceholderKey = "smoke-worker-placeholder"
    /// Type names `plugins/tool-journal` emits in its wire projection
    /// (`journal.ts`: `start → dispatched`, `done → completed`); the host
    /// journal stores exactly these records.
    private static let journalWireTypes: Set<String> = [
        "dispatched", "completed", "executed", "resolved",
    ]

    func testMacOSEndToEndSmoke() async throws {
        let environment: SmokeEnvironment
        do {
            environment = try SmokeEnvironment.resolve()
        } catch let skip as SmokeSkip {
            throw XCTSkip(skip.detail)
        } catch {
            throw XCTSkip("\(error)")
        }

        let fileManager = FileManager.default
        let workspace = environment.smokeDirectory
            .appendingPathComponent("workspace-\(UUID().uuidString.lowercased())",
                                    isDirectory: true)
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        let eventLog = SmokeEventLog()
        let report = SmokeReport(eventLog: eventLog, environment: environment,
                                 workspace: workspace)
        report.set("target_path", Self.targetPath)

        let mock = MockModelUpstream()
        let android = SmokeAndroidExecutor()
        var window: NSWindow?
        var engine: WebEngine?
        var host: PhoneDSHHost?
        var failure: Error?

        do {
            _ = NSApplication.shared
            let mockURL = try mock.start()
            report.set("mock_model_url", mockURL.absoluteString)

            // A real WKWebView attached with a one-point visible area (PLAN
            // §2.5): the engine refuses to boot a detached or fully clipped
            // view. The window is ordered in through the shared harness host
            // (floating, all spaces, activated, AppKit events pumped) so
            // WebKit sees a visible page instead of throttling a hidden one.
            let smokeWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 160, height: 120),
                                       styleMask: [.titled], backing: .buffered,
                                       defer: false)
            smokeWindow.isReleasedWhenClosed = false
            smokeWindow.title = "phone-dsh smoke"
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
            smokeWindow.contentView = container
            WebEngineAppKitEventPump.show(smokeWindow)
            window = smokeWindow

            let placeholder = WebEngineConfiguration(
                origin: URL(string: "http://127.0.0.1:1")!,
                token: "placeholder-token")
            let realEngine = WebEngine(configuration: placeholder)
            realEngine.attach(to: container)
            guard realEngine.isAttachedWithVisibleArea else {
                throw SmokeError.assertion("the WKWebView is not attached with a visible area")
            }
            engine = realEngine

            let bundle = PhoneDSHBundleLocation(
                staticDirectory: environment.staticDirectory,
                imageArchive: environment.imageArchive)
            var configuration = PhoneDSHConfiguration(
                workspaceRoot: workspace,
                token: "smoke-launch-token",
                origin: URL(string: "http://127.0.0.1:1")!,
                bundle: bundle,
                allowedModelHosts: ["http://127.0.0.1:\(mock.port)"],
                credentialProvider: StaticCredentialProvider([
                    CredentialScope(service: "127.0.0.1"):
                        Credential(kind: .apiKey(header: "x-api-key"),
                                   value: Self.hostAPIKey),
                ]),
                drainDeadline: 2,
                helloTimeout: 240)
            let sshFixturePath = ProcessInfo.processInfo.environment["PDSH_SSH_TEST_CONFIG"]
            if let sshFixturePath {
                let fixture = try JSONDecoder().decode(SmokeSSHFixture.self,
                    from: Data(contentsOf: URL(fileURLWithPath: sshFixturePath)))
                let connection = SSHConnection(host: "127.0.0.1", port: fixture.port,
                    username: "fixture", password: fixture.password, trustedHostKey: fixture.hostKey)
                configuration.execProvider = SSHExecProvider(
                    workspace: workspace.appendingPathComponent("materialized/workspace"),
                    home: workspace.appendingPathComponent("materialized/home"),
                    fallback: PDSHShellProvider(), connections: { "test" }, resolve: { _ in connection })
                configuration.acceleratorNames = ["ssh", "scp"]
            }
            configuration.engine.bootTimeout = 240
            // Real Worker MCP transport, with only the Android device simulated.
            let adbDefaultsName = "phone-dsh-adb-smoke-" + UUID().uuidString
            let adbDefaults = UserDefaults(suiteName: adbDefaultsName)!
            addTeardownBlock { adbDefaults.removePersistentDomain(forName: adbDefaultsName) }
            let adbSettings = ADBSettings(defaults: adbDefaults)
            try adbSettings.save(ADBConfiguration(enabled: true, host: "192.0.2.1"))
            configuration.nativeMCP = ADBMCPServer(settings: adbSettings, executor: android,
                receiptDirectory: workspace.appendingPathComponent("adb-receipts"))
            // The host injects the launch token/channel/gateway environment
            // itself (D24). Only the scripted model route is App-provided; an
            // explicit entry wins over the injected value of the same name.
            configuration.engine.environment = [
                "DEEPSEEK_BASE_URL": mockURL.absoluteString,
                "DEEPSEEK_API_KEY": Self.workerPlaceholderKey,
                "DSH_TELEMETRY_DISABLED": "1",
            ]

            let smokeHost = PhoneDSHHost(configuration: configuration,
                                         engineFactory: { _ in realEngine })
            host = smokeHost
            eventLog.attach(host: smokeHost)

            // MARK: Boot and HELLO
            let bootStart = Date()
            try await smokeHost.start()
            report.addPhase("boot_and_hello", milliseconds: Self.ms(since: bootStart))
            try await smokeWait(timeout: 60, label: "page bootReady") {
                realEngine.lastBootStatus?.state == .ready
            }
            try await smokeWait(timeout: 60, label: "Worker HELLO") {
                await smokeHost.diagnostics().workerHelloCount >= 1
            }
            let bootDiagnostics = await smokeHost.diagnostics()
            report.set("boot_id", bootDiagnostics.bootID)
            report.set("boot_state", String(describing: bootDiagnostics.hostState))
            report.set("boot_admission", bootDiagnostics.admission.rawValue)
            guard bootDiagnostics.state == .running, bootDiagnostics.admission == .open else {
                throw SmokeError.assertion("host did not reach Running with admission open")
            }
            guard eventLog.hellos.isEmpty == false else {
                throw SmokeError.assertion("no Worker HELLO appeared on the event stream")
            }

            // MARK: First scripted model turn
            let harness = try await smokeHost.harness()
            let session: HarnessSession
            do {
                session = try await harness.openSession(
                    HarnessSessionRequest(workspace: "/dsh/workspace"))
            } catch {
                let detail = await Self.rawSessionCreateDiagnostic(host: smokeHost)
                throw SmokeError.assertion("session/create failed: \(error); \(detail)")
            }
            // Exercise the same real Remote contracts used by the native app.
            let nativeTransport = try await smokeHost.makeTransport()
            _ = try await nativeTransport.call("session/rename", args: .object(["request": .object([
                "sessionId": .string(session.id), "title": .string("Native session verification")
            ])]))
            let nativeList = try await nativeTransport.call("session/list", args: .object([:]))
            XCTAssertTrue(nativeList["items"]?.arrayValue?.contains { $0["sessionId"]?.stringValue == session.id } == true)
            print("NATIVE_CONTRACT session/modelCatalog")
            _ = try await nativeTransport.call("session/modelCatalog", args: .object([:]))
            print("NATIVE_CONTRACT workspace/archiveSession")
            let archived = try await nativeTransport.call("workspace/archiveSession", args: .object(["request": .object([
                "sessionId": .string(session.id), "stopActivity": .bool(false)
            ])]))
            XCTAssertTrue(archived["archivedSessionIds"]?.arrayValue?.contains(.string(session.id)) == true)
            let restored = try await nativeTransport.call("workspace/unarchiveSession", args: .object(["request": .object([
                "sessionId": .string(session.id)
            ])]))
            XCTAssertFalse(restored["archivedSessionIds"]?.arrayValue?.contains(.string(session.id)) == true)
            if sshFixturePath != nil {
                let remote = "/smoke-" + UUID().uuidString + ".bin"
                let command = "printf AP+A | base64 -d > ssh-source.bin && scp ssh-source.bin test:" + remote
                    + " && scp test:" + remote + " ssh-result.bin && cmp ssh-source.bin ssh-result.bin && ssh test connected"
                let result = try await nativeTransport.call("phone/shellRun", args: .object(["request": .object([
                    "command": .string(command), "cwd": .string("/dsh/workspace"),
                    "timeoutMs": .number(30_000), "execId": .string("ssh-smoke-" + UUID().uuidString)
                ])]))
                guard result["exitCode"] == .number(0), result["stdout"]?.stringValue?.contains("connected") == true else {
                    throw SmokeError.assertion("SSH/SCP Worker round trip failed: \(result)")
                }
                try await smokeWait(timeout: 10, label: "SCP download materialized via VFS WAL") {
                    (try? Data(contentsOf: workspace.appendingPathComponent("materialized/workspace/ssh-result.bin"))) == Data([0, 255, 128])
                }
                report.set("ssh_scp_worker_roundtrip", "PASS")
                print("NATIVE_SSH_SCP_ROUNDTRIP PASS")
            }
            report.set("native_management_contracts", "PASS")
            report.set("session_id", session.id)
            eventLog.attach(harness: harness, sessionID: session.id)

            // G2-FIX-21: a page WebKit considers hidden is throttled, so the
            // Worker's fetch stalls while the test burns its timeout. Assert
            // both halves of the production precondition (occlusion-visible
            // window, visible document) before the first turn instead.
            let visibility = try await harnessAssertPageVisible(
                realEngine, label: "before the first smoke turn")
            report.set("page_visibility", harnessDescribePageVisibility(visibility))

            let turnStart = Date()
            try await harness.send(
                .prompt(text: "Write hi into a.txt and print it.",
                        attachments: [], requestID: "smoke-turn-1"),
                to: session.id)
            try await smokeWait(timeout: 240, label: "first model turn") {
                mock.requestCount >= 2
                    && fileManager.fileExists(atPath: workspace
                        .appendingPathComponent("materialized/workspace/a.txt").path)
            }
            report.addPhase("first_tool_turn", milliseconds: Self.ms(since: turnStart))

            try await smokeWait(timeout: 120, label: "journal completed") {
                let journal = try readJournalSummary(workspace: workspace,
                                                     sessionID: session.id)
                return journal.dispatched && journal.completed
            }
            try await smokeWait(timeout: 120, label: "step journaled") {
                try readStepSummary(workspace: workspace, sessionID: session.id)
                    .reachedJournaled
            }

            // MARK: First-turn evidence
            let materializedURL = workspace
                .appendingPathComponent("materialized/workspace/a.txt")
            let materializedText = try String(contentsOf: materializedURL, encoding: .utf8)
            let wal = try readWALSummary(workspace: workspace,
                                         targetPath: Self.targetPath)
            let journal = try readJournalSummary(workspace: workspace,
                                                 sessionID: session.id)
            let steps = try readStepSummary(workspace: workspace, sessionID: session.id)
            let requests = mock.requests

            let checks: [(String, Bool)] = [
                ("WAL has a write for \(Self.targetPath)",
                 wal.targetMseqs.isEmpty == false),
                ("WAL write contains 'hi'", wal.targetText.contains("hi")),
                ("WAL appended records match their replay base",
                 wal.appendMismatches.isEmpty),
                ("materialized a.txt contains 'hi'", materializedText.contains("hi")),
                ("journal has a dispatched record", journal.dispatched),
                ("journal has a completed record", journal.completed),
                ("journal records use the wire projection names",
                 journal.types.allSatisfy { Self.journalWireTypes.contains($0) }),
                ("step machine reached journaled", steps.reachedJournaled),
                ("model answered the tool result with a second request",
                 requests.count >= 2),
                ("the first model request had no tool result",
                 requests.first.map { MockModelUpstream.transcriptHasToolResult($0.body) } == false),
                ("the second model request carries the tool result",
                 requests.dropFirst().first.map { MockModelUpstream.transcriptHasToolResult($0.body) } == true),
                ("the host injected the credential upstream",
                 requests.allSatisfy { $0.apiKey == Self.hostAPIKey }),
            ]
            if let failed = checks.first(where: { $0.1 == false }) {
                throw SmokeError.assertion("first turn: \(failed.0)")
            }
            report.set("wal", [
                "segments": wal.segmentCount,
                "mutations": wal.mutationCount,
                "target_mseqs": wal.targetMseqs,
                "target_text": wal.targetText,
                "epoch_close_records": wal.epochCloseCount,
                "append_mismatches": wal.appendMismatches,
            ])
            let reopened = try await harness.openSession(HarnessSessionRequest(sessionID: session.id))
            XCTAssertEqual(reopened.id, session.id, "Reopening a nonblank session must preserve identity")
            let listAfterReopen = try await nativeTransport.call("session/list", args: .object([:]))
            XCTAssertEqual(listAfterReopen["items"]?.arrayValue?.count, nativeList["items"]?.arrayValue?.count,
                           "Reopening must not create a new blank session")
            let permissionCatalog = try await nativeTransport.call("permissionPresets/catalog", args: .object([:]))
            XCTAssertFalse(permissionCatalog["options"]?.arrayValue?.isEmpty ?? true)
            let permissionResult = try await nativeTransport.call("commands/execute", args: .object([
                "agentId": .string(session.id), "line": .string("/permission phone"),
                "submittedAttachments": .array([])
            ]))
            XCTAssertEqual(permissionResult["result"]?["kind"]?.stringValue, "success")
            _ = try await nativeTransport.call("skills/list", args: .object(["request": .object(["sessionId": .string(session.id)])]))
            _ = try await nativeTransport.call("schedule/catalog", args: .object([:]))
            let inventory = try await nativeTransport.call("phone/listTools", args: .object([:]))
            XCTAssertEqual(inventory["scope"]?.stringValue, "global")
            XCTAssertNotNil(inventory["tools"]?.arrayValue)
            let androidTools = inventory["tools"]?.arrayValue?.filter {
                $0["name"]?.stringValue?.hasPrefix("mcp__phone__android_") == true
            } ?? []
            XCTAssertEqual(androidTools.count, 26, "native Android tools must reach the real Worker registry")
            let scheduled = try await nativeTransport.call("phone/createSchedule", args: .object(["request": .object([
                "sessionId": .string(session.id), "title": .string("Native UI fixture"),
                "prompt": .string("Disposable local test reminder"), "after_seconds": .number(600)
            ])]))
            let scheduleID = try XCTUnwrap(scheduled["id"]?.stringValue)
            let catalog = try await nativeTransport.call("schedule/catalog", args: .object([:]))
            let schedule = try XCTUnwrap(catalog.arrayValue?.first { $0["id"]?.stringValue == scheduleID })
            XCTAssertEqual(schedule["target"]?["sessionId"]?.stringValue, session.id)
            let revised = try await nativeTransport.call("schedule/edit", args: .object(["request": .object([
                "id": .string(scheduleID), "action": .string("update"),
                "expectedUpdatedAt": schedule["updatedAt"] ?? .null,
                "patch": .object(["title": .string("Updated native UI fixture")])
            ])]))
            XCTAssertEqual(revised["title"]?.stringValue, "Updated native UI fixture")
            let deleted = try await nativeTransport.call("schedule/edit", args: .object(["request": .object([
                "id": .string(scheduleID), "action": .string("delete")
            ])]))
            XCTAssertEqual(deleted["deleted"]?.boolValue, true)
            let settings = try await nativeTransport.call("settings/describe", args: .object([:]))
            XCTAssertNotNil(settings["namespaces"]?.arrayValue)
            let plugins = try await nativeTransport.call("pluginInventory/list", args: .object([:]))
            XCTAssertFalse(plugins["entries"]?.arrayValue?.isEmpty ?? true)
            report.set("native_settings_inventory", "PASS")
            report.set("native_phone_adapters", "PASS")
            _ = try await nativeTransport.call("commands/list", args: .object(["agentId": .string(session.id)]))
            report.set("native_access_and_catalogs", "PASS")
            report.set("native_nonblank_resume", "PASS")
            report.set("materialized_a_txt", materializedText)
            report.set("journal", [
                "exists": journal.exists,
                "records": journal.recordCount,
                "types": journal.types,
                "sessions": Array(journal.sessionIDs),
                "dispatched": journal.dispatched,
                "completed": journal.completed,
                "tool_keys": Array(Set(journal.toolKeys)),
            ])
            report.set("steps", [
                "states": steps.states,
                "step_keys": Array(Set(steps.stepKeys)),
                "reached_journaled": steps.reachedJournaled,
            ])
            report.set("model_requests", [
                "count": requests.count,
                "paths": requests.map(\.path),
                "tool_result": requests.map { MockModelUpstream.transcriptHasToolResult($0.body) },
                "api_key_injected": requests.allSatisfy { $0.apiKey == Self.hostAPIKey },
            ])

            // MARK: Planned restart (D24)
            let targetMseqsBefore = wal.targetMseqs
            let targetBytesBefore = wal.targetBytes
            let helloCountBefore = bootDiagnostics.workerHelloCount
            let mutationCountBefore = wal.mutationCount
            let restartStart = Date()
            try await smokeHost.plannedRestart(reason: "smoke")
            report.addPhase("planned_restart", milliseconds: Self.ms(since: restartStart))
            try await smokeWait(timeout: 240, label: "restart reach Running") {
                await smokeHost.state == .running
            }
            let restarted = await smokeHost.diagnostics()
            report.set("restart_worker_hellos", restarted.workerHelloCount)
            guard restarted.state == .running, restarted.admission == .open else {
                throw SmokeError.assertion("the restarted host is not Running with admission open")
            }
            guard restarted.workerHelloCount > helloCountBefore else {
                throw SmokeError.assertion("the planned restart produced no new Worker HELLO")
            }
            let overlay = workspace.appendingPathComponent("overlay-\(restarted.bootID).tar")
            let overlayPrefix = [UInt8](try Data(contentsOf: overlay).prefix(2))
            guard overlayPrefix == [0x1f, 0x8b] else {
                throw SmokeError.assertion("the rebuilt overlay is not gzip (D21)")
            }
            report.set("restart", [
                "boot_id": restarted.bootID,
                "worker_hellos": restarted.workerHelloCount,
                "admission": restarted.admission.rawValue,
                "materialized_upto_mseq": restarted.materializedUptoMseq,
                "overlay_is_gzip": true,
            ])

            // One planned restart publishes exactly one `.restarted` event:
            // the engine's own report and the restart call's return value are
            // the same cold start and must not both reach subscribers.
            try await smokeWait(timeout: 30, label: "planned restart event") {
                eventLog.restarts.isEmpty == false
            }
            // Give a (buggy) second copy time to arrive before counting.
            try await WebEngineAppKitEventPump.wait(0.3)
            let restartEvents = eventLog.restarts
            guard restartEvents.count == 1 else {
                throw SmokeError.assertion(
                    "the planned restart published \(restartEvents.count) .restarted events, expected 1")
            }
            guard restartEvents.first?.reason == .planned else {
                throw SmokeError.assertion(
                    "the planned restart event reason is \(String(describing: restartEvents.first?.reason))")
            }
            report.set("restarted_events", restartEvents.map {
                ["reason": $0.reason.rawValue, "boot_id": $0.bootID,
                 "duration_seconds": $0.durationSeconds]
            })

            // D24 recovery keeps the acknowledged workspace exactly.
            let walAfterRestart = try readWALSummary(workspace: workspace,
                                                     targetPath: Self.targetPath)
            let materializedAfterRestart = try String(contentsOf: materializedURL,
                                                      encoding: .utf8)
            guard walAfterRestart.targetMseqs == targetMseqsBefore,
                  walAfterRestart.targetBytes == targetBytesBefore else {
                throw SmokeError.assertion("the planned restart changed the WAL bytes for a.txt")
            }
            guard walAfterRestart.appendMismatches.isEmpty else {
                throw SmokeError.assertion(
                    "the WAL after the restart has mismatched append bases: \(walAfterRestart.appendMismatches)")
            }
            guard materializedAfterRestart == materializedText else {
                throw SmokeError.assertion("the planned restart changed materialized a.txt")
            }
            report.set("wal_after_restart", [
                "segments": walAfterRestart.segmentCount,
                "mutations": walAfterRestart.mutationCount,
                "target_mseqs": walAfterRestart.targetMseqs,
                "target_text": walAfterRestart.targetText,
                "mutations_before_restart": mutationCountBefore,
                "append_mismatches": walAfterRestart.appendMismatches,
            ])
            report.set("materialized_after_restart", materializedAfterRestart)

            // MARK: Second trivial turn on the resumed session
            //
            // DSH 0.2.1's `session/create` mints a new Session when the named
            // one has already started a turn (resume through create is only
            // for a blank Session). The durable resume path is a prompt on the
            // existing Session id: `session/prompt` resolves the persisted
            // Session and resumes its Agent. The smoke uses that path so the
            // second turn proves the DSH session log survived the restart.
            let resumeStart = Date()
            let resumedHarness = try await smokeHost.harness()
            eventLog.attach(harness: resumedHarness, sessionID: session.id)
            let requestCountBeforeResume = mock.requestCount
            try await resumedHarness.send(
                .prompt(text: "Reply with one short confirmation.",
                        attachments: [], requestID: "smoke-turn-2"),
                to: session.id)
            try await smokeWait(timeout: 240, label: "second turn model request") {
                mock.requestCount > requestCountBeforeResume
            }
            report.addPhase("resumed_turn", milliseconds: Self.ms(since: resumeStart))
            let resumedRequests = mock.requests
            guard let last = resumedRequests.last,
                  MockModelUpstream.transcriptHasToolResult(last.body) else {
                throw SmokeError.assertion("the resumed turn did not reach the model with the transcript")
            }
            let finalWAL = try readWALSummary(workspace: workspace,
                                              targetPath: Self.targetPath)
            guard finalWAL.targetMseqs == targetMseqsBefore,
                  finalWAL.targetBytes == targetBytesBefore,
                  finalWAL.appendMismatches.isEmpty else {
                throw SmokeError.assertion("the resumed turn changed the WAL bytes for a.txt")
            }
            guard Array(finalWAL.mutationMseqs.prefix(mutationCountBefore))
                == Array(wal.mutationMseqs.prefix(mutationCountBefore)) else {
                throw SmokeError.assertion("the WAL mutation prefix changed after the restart")
            }
            report.set("resume", [
                "session_id": session.id,
                "resume_path": "session/prompt on the durable Session id",
                "model_requests_before": requestCountBeforeResume,
                "model_requests_after": resumedRequests.count,
                "target_mseqs": finalWAL.targetMseqs,
                "materialized_unchanged": true,
            ])
            report.set("not_implemented_fail_count",
                       eventLog.notImplementedFailLines.count)
            // A scripted model tool call must traverse the real DSH registry,
            // Worker fetch, authenticated loopback MCP, and native ADB harness.
            mock.script = .tool(name: "mcp__phone__android_list_packages", argumentsJSON: Data("{\"kind\":\"third_party\"}".utf8), finalText: "Android apps listed.")
            let androidSession = try await resumedHarness.openSession(HarnessSessionRequest(workspace: "/dsh/workspace"))
            let androidStart = mock.requestCount
            try await resumedHarness.send(.prompt(text: "List third-party apps on the configured Android device.", attachments: [],
                                                  requestID: "smoke-android"), to: androidSession.id)
            try await smokeWait(timeout: 120, label: "native Android tool result reaches model") {
                mock.requests.dropFirst(androidStart).contains {
                    MockModelUpstream.lastMessageHasToolResult($0.body)
                        && String(decoding: $0.body, as: UTF8.self).contains("com.example.smoke")
                }
            }
            let androidCommands = await android.commands
            XCTAssertEqual(androidCommands, ["pm list packages -f -i --user current -3"])
            let receiptFiles = try FileManager.default.contentsOfDirectory(at: workspace.appendingPathComponent("adb-receipts"),
                                                                           includingPropertiesForKeys: nil)
            XCTAssertEqual(receiptFiles.count, 1, "Worker MCP must carry a durable idempotency key")
            report.set("android_native_mcp", ["tool_count": androidTools.count, "command_count": androidCommands.count,
                                               "model_received_result": true, "physical_device": false])
            report.finish(ok: true)
        } catch {
            failure = error
            report.finish(ok: false, failure: String(describing: error))
        }

        // MARK: Teardown
        eventLog.stop()
        if let host {
            try? await host.stop()
        }
        engine?.shutdown()
        window?.close()
        window = nil
        mock.stop()
        do {
            try report.write()
        } catch {
            print("smoke: cannot write smoke-report.json: \(error)")
        }
        if let failure {
            // Record the diagnostic as a test failure (not a thrown error) so
            // the last 50 console lines reach the XCTest log verbatim, and the
            // same lines remain in smoke-report.json for the CI script.
            let tail = eventLog.tail(50).joined(separator: "\n")
            XCTFail("macOS end-to-end smoke failed: \(failure)\n"
                    + "--- last 50 console lines ---\n\(tail)\n"
                    + "--- report: \(report.reportURL.path) ---")
        }
    }

    /// Raw `session/create` error text for a fail-loud diagnosis. The harness
    /// maps gateway failures to a terse `ProviderError`; the transport keeps
    /// the DSH error code and message.
    private static func rawSessionCreateDiagnostic(host: PhoneDSHHost) async -> String {
        do {
            let transport = try await host.makeTransport()
            let value = try await transport.call(
                "session/create",
                args: .object(["request": .object(["cwd": .string("/dsh/workspace")])]))
            return "raw session/create unexpectedly succeeded: \(value)"
        } catch let error as DSHRemoteError {
            return "raw session/create error \(error.code): \(error.message)"
        } catch {
            return "raw session/create error: \(error)"
        }
    }

    private static func ms(since start: Date) -> Double {
        (Date().timeIntervalSince(start) * 1000).rounded()
    }
}

private struct SmokeSSHFixture: Decodable {
    let port: Int
    let password: String
    let hostKey: String
}
