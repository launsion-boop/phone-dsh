// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — iOS Simulator end-to-end smoke (PLAN W3-SIM / W2-SMOKE).
//
// The same closed loop as `Tests/PhoneDSHSmokeTests`, on the iOS
// Simulator:
//
//   scripted model upstream → host ModelGateway → WKWebView Worker (the packed
//   DSH image from the probe app's Bundle/worker) → DSH bash tool → VFS sink →
//   ordered channel → WAL/materialized copy → tool journal → host step machine
//
// then one `PhoneDSHHost.plannedRestart(reason:)` (D24), a resumed session
// with a second trivial turn, and a comparison that the WAL/materialized
// evidence for the first turn did not change. The assertions and the WAL /
// journal / step readers are the landed macOS smoke ones (ported to this
// target by `SimSmokeSupport.swift`); the model upstream comes from the linked
// `PhoneDSHHarness` package product.
//
// The report goes to the probe app container's `Documents/pdsh-reports/` as
// `smoke-report.json`, every row carries a G1 threshold and
// `environment: "ios-simulator"`.
//
// NOT_VERIFIED on an iPhone: no physical-device run exists.

import Foundation
import XCTest
import WebKit
import PhoneDSHAgentCore
import PhoneDSHHarness
import PhoneDSH
import PhoneDSHEngine
import PhoneDSHLog
import PhoneDSHWire

@MainActor
final class PhoneDSHSimSmokeTests: XCTestCase {
    /// Workspace-relative file the scripted shell writes.
    private static let targetPath = "/dsh/workspace/a.txt"
    /// Host credential the gateway injects for the mock upstream.
    private static let hostAPIKey = "sim-host-key"
    /// Per-start loopback token the smoke host pins (a static fixture, not a
    /// credential). The Python acceptance checks that this value never enters
    /// the guest environment or an upstream Referer.
    private static let launchToken = "sim-launch-token"
    /// Placeholder key the Worker's DSH adapter resolves from its own
    /// environment; the host gateway replaces it before the upstream sees it.
    private static let workerPlaceholderKey = "sim-worker-placeholder"
    /// Type names `plugins/tool-journal` emits in its wire projection.
    private static let journalWireTypes: Set<String> = [
        "dispatched", "completed", "executed", "resolved",
    ]

    func testSimulatorEndToEndSmoke() async throws {
        let directory = try SimEnvironment.reportsDirectory()
        let report = SimSuiteReport(suite: "smoke", gate: "G1", directory: directory,
                                    fileName: "smoke-report.json")
        let eventLog = SimSmokeEventLog()
        let fileManager = FileManager.default
        let workspace = SimEnvironment.workspaceRoot(
            name: "smoke-\(UUID().uuidString.lowercased())")
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        report.set("workspace_root", workspace.path)
        report.set("target_path", Self.targetPath)

        let mock = MockModelUpstream()
        var window: SimVisibleWindow?
        var engine: WebEngine?
        var host: PhoneDSHHost?
        var failure: Error?

        do {
            let mockURL = try mock.start()
            report.set("mock_model_url", mockURL.absoluteString)

            let bundle = try SimEnvironment.workerBundle()
            report.set("worker_static_directory", bundle.staticDirectory.path)
            report.set("worker_image", bundle.imageArchive.path)

            // A real WKWebView attached with a one-point visible area (PLAN
            // §2.5). The hostless test process has no App scene, so the suite
            // supplies the smallest window that satisfies the engine.
            let visibleWindow = SimVisibleWindow()
            window = visibleWindow
            guard visibleWindow.isAttached else {
                throw SimError.assertion("the smoke window anchor is not attached")
            }
            let placeholder = WebEngineConfiguration(
                origin: URL(string: "http://127.0.0.1:1")!,
                token: "placeholder-token")
            let realEngine = WebEngine(configuration: placeholder)
            realEngine.attach(to: visibleWindow.anchor)
            guard realEngine.isAttachedWithVisibleArea else {
                throw SimError.assertion(
                    "the WKWebView is not attached with a visible area")
            }
            engine = realEngine

            var configuration = PhoneDSHConfiguration(
                workspaceRoot: workspace,
                token: Self.launchToken,
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
            configuration.engine.bootTimeout = 240
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
            try await simWait(timeout: 240, label: "Worker HELLO") {
                await smokeHost.diagnostics().workerHelloCount >= 1
            }
            let bootDiagnostics = await smokeHost.diagnostics()
            report.set("boot_id", bootDiagnostics.bootID)
            report.set("boot_state", String(describing: bootDiagnostics.hostState))
            report.set("boot_admission", bootDiagnostics.admission.rawValue)
            let booted = bootDiagnostics.state == .running
                && bootDiagnostics.admission == .open
            report.record("smoke.boot", status: booted ? .pass : .fail, gating: true,
                          metrics: ["boot_id": bootDiagnostics.bootID,
                                    "state": bootDiagnostics.state.rawValue,
                                    "admission": bootDiagnostics.admission.rawValue,
                                    "worker_hellos": Int(bootDiagnostics.workerHelloCount)],
                          threshold: simG1Threshold("g1_host_boot_running_admission",
                                                    measured: booted ? 1 : 0),
                          detail: "PhoneDSHHost reached Running with admission open")
            guard booted else {
                throw SimError.assertion("host did not reach Running with admission open")
            }

            // MARK: First scripted model turn
            let harness = try await smokeHost.harness()
            let session: HarnessSession
            do {
                session = try await harness.openSession(
                    HarnessSessionRequest(workspace: "/dsh/workspace"))
            } catch {
                let detail = await Self.rawSessionCreateDiagnostic(host: smokeHost)
                throw SimError.assertion("session/create failed: \(error); \(detail)")
            }
            report.set("session_id", session.id)
            eventLog.attach(harness: harness, sessionID: session.id)

            let turnStart = Date()
            let firstPromptMarker = "sim-turn-1-\(UUID().uuidString.lowercased())"
            let firstTurnWatermark = eventLog.harnessSequenceWatermark
            try await harness.send(
                .prompt(text: "Write hi into a.txt and print it. [\(firstPromptMarker)]",
                        attachments: [], requestID: "sim-turn-1"),
                to: session.id)
            try await simWait(timeout: 240, label: "first model turn") {
                mock.requestCount >= 2
                    && fileManager.fileExists(atPath: workspace
                        .appendingPathComponent("materialized/workspace/a.txt").path)
            }
            report.addPhase("first_tool_turn", milliseconds: Self.ms(since: turnStart))

            try await simWait(timeout: 120, label: "journal completed") {
                let journal = try simReadJournalSummary(workspace: workspace,
                                                        sessionID: session.id)
                return journal.dispatched && journal.completed
            }
            try await simWait(timeout: 120, label: "step journaled") {
                try simReadStepSummary(workspace: workspace, sessionID: session.id)
                    .reachedJournaled
            }
            let firstTurnReceipt = try await waitForCompletedHarnessTurn(
                eventLog: eventLog,
                after: firstTurnWatermark,
                promptMarker: firstPromptMarker,
                label: "first model turn")
            guard firstTurnReceipt.reason == .completed else {
                throw SimError.assertion(
                    "first turn \(firstTurnReceipt.turnID) ended as \(firstTurnReceipt.reason); "
                        + "tool errors: \(firstTurnReceipt.toolErrors.joined(separator: " | "))")
            }

            // MARK: First-turn evidence
            let materializedURL = workspace
                .appendingPathComponent("materialized/workspace/a.txt")
            let materializedText = try String(contentsOf: materializedURL, encoding: .utf8)
            let wal = try simReadWALSummary(workspace: workspace,
                                            targetPath: Self.targetPath)
            let journal = try simReadJournalSummary(workspace: workspace,
                                                   sessionID: session.id)
            let steps = try simReadStepSummary(workspace: workspace,
                                               sessionID: session.id)
            let requests = mock.requests
            let checks: [(String, Bool, String)] = [
                ("WAL has a write for \(Self.targetPath)", wal.targetMseqs.isEmpty == false,
                 "g1_wal_has_tool_write"),
                ("WAL write contains 'hi'", wal.targetText.contains("hi"),
                 "g1_wal_contains_tool_output"),
                ("WAL appended records match their replay base",
                 wal.appendMismatches.isEmpty, "g1_wal_append_replay_matches"),
                ("materialized a.txt contains 'hi'", materializedText.contains("hi"),
                 "g1_materialized_contains_tool_output"),
                ("journal has a dispatched record", journal.dispatched,
                 "g1_journal_dispatched"),
                ("journal has a completed record", journal.completed,
                 "g1_journal_completed"),
                ("journal records use the wire projection names",
                 journal.types.allSatisfy { Self.journalWireTypes.contains($0) },
                 "g1_journal_wire_projection"),
                ("step machine reached journaled", steps.reachedJournaled,
                 "g1_step_machine_journaled"),
                ("model answered the tool result with a second request",
                 requests.count >= 2, "g1_model_second_request"),
                ("the first model request had no tool result",
                 requests.first.map { MockModelUpstream.transcriptHasToolResult($0.body) } == false,
                 "g1_model_first_request_no_tool_result"),
                // The follow-up that carries the tool result is not always
                // the second request: the pinned runtime's session-title
                // service may issue its own model request around the same
                // time, so wait for the property, not for an index.
                ("a model request after the first carries the tool result",
                 requests.dropFirst().contains {
                     MockModelUpstream.transcriptHasToolResult($0.body)
                 }, "g1_model_second_request_has_tool_result"),
                ("the host injected the credential upstream",
                 requests.allSatisfy { $0.apiKey == Self.hostAPIKey },
                 "g1_model_credential_injected"),
            ]
            var failedChecks: [String] = []
            for check in checks {
                let passed = check.1
                if !passed { failedChecks.append(check.0) }
                report.record("smoke.\(check.2)", status: passed ? .pass : .fail,
                              gating: true,
                              metrics: ["assertion": check.0, "passed": passed],
                              threshold: simG1Threshold(check.2,
                                                        measured: passed ? 1 : 0),
                              detail: check.0)
            }
            report.set("wal", [
                "segments": wal.segmentCount,
                "mutations": wal.mutationCount,
                "target_mseqs": wal.targetMseqs,
                "target_text": wal.targetText,
                "epoch_close_records": wal.epochCloseCount,
                "append_mismatches": wal.appendMismatches,
            ])
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
            report.set("first_turn_lifecycle", Self.describe(firstTurnReceipt))
            report.set("model_requests", [
                "count": requests.count,
                "paths": requests.map(\.path),
                "tool_result": requests.map {
                    MockModelUpstream.transcriptHasToolResult($0.body)
                },
                "api_key_injected": requests.allSatisfy { $0.apiKey == Self.hostAPIKey },
            ])
            if failedChecks.isEmpty == false {
                throw SimError.assertion(
                    "first turn: " + failedChecks.joined(separator: "; "))
            }

            // MARK: Real WebContent kill (native surface) and recovery
            //
            // This is the only automated process-kill coverage: the native
            // surface boots the same Worker page, so a real SIGKILL of the
            // simulator's WebContent must leave the same Session, journal and
            // materialized evidence and a working follow-up turn. Without the
            // sim.sh watcher (a direct `xcodebuild test`) the row is present
            // but non-gating.
            let killStart = Date()
            switch await requestRealWebContentKill(directory: directory) {
            case .notRequested:
                report.record("smoke.real_webcontent_kill", status: .info, gating: false,
                              metrics: ["attempt": "not requested (no watcher marker)"],
                              threshold: simInfoThreshold("real_webcontent_kill"),
                              detail: "a direct xcodebuild run without scripts/ci/sim.sh "
                                  + "does not attempt the kill")
            case .unavailable(let status):
                report.set("real_kill", ["status": status])
                report.record("smoke.real_webcontent_kill", status: .fail, gating: true,
                              metrics: ["attempt": status],
                              threshold: simG1Threshold("real_webcontent_kill", measured: 0),
                              detail: "scripts/ci/sim.sh expected the WebContent kill "
                                  + "and the watcher did not send it")
                throw SimError.assertion("the WebContent kill was not attempted: \(status)")
            case .attempted(let status):
                report.set("real_kill", ["status": status])
                try await simWait(timeout: 120, label: "WebContent termination observed") {
                    realEngine.terminationCount >= 1
                }
                try await simWait(timeout: 240, label: "host Running after WebContent kill") {
                    await smokeHost.state == .running
                }
                report.addPhase("webcontent_kill_recovery",
                                milliseconds: Self.ms(since: killStart))
                let harnessAfterKill = try await smokeHost.harness()
                eventLog.attach(harness: harnessAfterKill, sessionID: session.id)
                let journalAfterKill = try simReadJournalSummary(workspace: workspace,
                                                                 sessionID: session.id)
                let materializedAfterKill = (try? String(contentsOf: materializedURL,
                                                         encoding: .utf8)) ?? ""
                let followUpMarker = "sim-after-kill-\(UUID().uuidString.lowercased())"
                let followUpWatermark = eventLog.harnessSequenceWatermark
                try await harnessAfterKill.send(
                    .prompt(text: "Say ok. [\(followUpMarker)]",
                            attachments: [], requestID: "sim-after-kill"),
                    to: session.id)
                let followUpReceipt = try await waitForCompletedHarnessTurn(
                    eventLog: eventLog, after: followUpWatermark,
                    promptMarker: followUpMarker, label: "turn after WebContent kill")
                let killRecovered = journalAfterKill.dispatched && journalAfterKill.completed
                    && journalAfterKill.sessionIDs == journal.sessionIDs
                    && materializedAfterKill.contains("hi")
                    && followUpReceipt.reason == .completed
                report.record("smoke.real_webcontent_kill_recovery",
                              status: killRecovered ? .pass : .fail, gating: true,
                              metrics: ["attempt": status,
                                        "terminations": realEngine.terminationCount,
                                        "session_ids_after": journalAfterKill.sessionIDs.count,
                                        "follow_up_turn": followUpReceipt.turnID],
                              threshold: simG1Threshold("real_webcontent_kill_recovery",
                                                        measured: killRecovered ? 1 : 0),
                              detail: "a real SIGKILL of this simulator's WebContent was followed "
                                  + "by the same Session, journal and materialized evidence, and a "
                                  + "completed follow-up turn")
                if !killRecovered {
                    throw SimError.assertion(
                        "WebContent kill recovery: the same Session, evidence and a "
                            + "follow-up turn were not restored")
                }
            }

            // MARK: Planned restart (D24)
            let targetMseqsBefore = wal.targetMseqs
            let targetBytesBefore = wal.targetBytes
            let helloCountBefore = bootDiagnostics.workerHelloCount
            let mutationCountBefore = wal.mutationCount
            let restartStart = Date()
            try await smokeHost.plannedRestart(reason: "sim-smoke")
            report.addPhase("planned_restart", milliseconds: Self.ms(since: restartStart))
            try await simWait(timeout: 240, label: "restart reach Running") {
                await smokeHost.state == .running
            }
            let restarted = await smokeHost.diagnostics()
            report.set("restart_worker_hellos", restarted.workerHelloCount)
            let restartedOK = restarted.state == .running
                && restarted.admission == .open
                && restarted.workerHelloCount > helloCountBefore
            report.record("smoke.planned_restart", status: restartedOK ? .pass : .fail,
                          gating: true,
                          metrics: ["state": restarted.state.rawValue,
                                    "admission": restarted.admission.rawValue,
                                    "worker_hellos_before": Int(helloCountBefore),
                                    "worker_hellos_after": Int(restarted.workerHelloCount),
                                    "boot_id": restarted.bootID],
                          threshold: simG1Threshold("g1_planned_restart_recovery",
                                                    measured: restartedOK ? 1 : 0),
                          detail: "D24 planned restart reached Running with a new HELLO")
            guard restartedOK else {
                throw SimError.assertion(
                    "the restarted host is not Running with admission open and a new HELLO")
            }
            let overlay = workspace.appendingPathComponent("overlay-\(restarted.bootID).tar")
            let overlayPrefix = [UInt8](try Data(contentsOf: overlay).prefix(2))
            let overlayIsGzip = overlayPrefix == [0x1f, 0x8b]
            report.record("smoke.overlay_gzip",
                          status: overlayIsGzip ? .pass : .fail, gating: true,
                          metrics: ["prefix": overlayPrefix.map(String.init).joined(separator: ",")],
                          threshold: simG1Threshold("g1_overlay_rebuilt_gzip",
                                                    measured: overlayIsGzip ? 1 : 0),
                          detail: "D21: the rebuilt overlay is a gzip tar")
            report.set("restart", [
                "boot_id": restarted.bootID,
                "worker_hellos": restarted.workerHelloCount,
                "admission": restarted.admission.rawValue,
                "materialized_upto_mseq": restarted.materializedUptoMseq,
                "overlay_is_gzip": overlayIsGzip,
            ])
            guard overlayIsGzip else {
                throw SimError.assertion("the rebuilt overlay is not gzip (D21)")
            }

            // One planned restart publishes exactly one `.restarted` event.
            // The WebContent kill earlier publishes its own
            // `webContentTerminated` event; this assertion is about the planned
            // restart, so it counts only that reason.
            try await simWait(timeout: 30, label: "planned restart event") {
                eventLog.restarts.contains { $0.reason == .planned }
            }
            try await Task.sleep(nanoseconds: 300_000_000)
            let restartEvents = eventLog.restarts.filter { $0.reason == .planned }
            let restartEventOK = restartEvents.count == 1
                && restartEvents.first?.reason == .planned
            report.record("smoke.restarted_event",
                          status: restartEventOK ? .pass : .fail, gating: true,
                          metrics: ["count": restartEvents.count,
                                    "reason": restartEvents.first?.reason.rawValue ?? "none"],
                          threshold: simG1Threshold("g1_restart_single_event",
                                                    measured: restartEventOK ? 1 : 0),
                          detail: "one `.restarted` event with reason planned")
            report.set("restarted_events", restartEvents.map {
                ["reason": $0.reason.rawValue, "boot_id": $0.bootID,
                 "duration_seconds": $0.durationSeconds]
            })
            guard restartEventOK else {
                throw SimError.assertion(
                    "the planned restart published \(restartEvents.count) events")
            }

            // D24 recovery keeps the acknowledged workspace exactly.
            let walAfterRestart = try simReadWALSummary(workspace: workspace,
                                                        targetPath: Self.targetPath)
            let materializedAfterRestart = try String(contentsOf: materializedURL,
                                                      encoding: .utf8)
            let preserved = walAfterRestart.targetMseqs == targetMseqsBefore
                && walAfterRestart.targetBytes == targetBytesBefore
                && walAfterRestart.appendMismatches.isEmpty
                && materializedAfterRestart == materializedText
            report.record("smoke.restart_preserves_wal",
                          status: preserved ? .pass : .fail, gating: true,
                          metrics: ["target_mseqs_before": targetMseqsBefore.count,
                                    "target_mseqs_after": walAfterRestart.targetMseqs.count,
                                    "append_mismatches": walAfterRestart.appendMismatches.count,
                                    "materialized_unchanged": materializedAfterRestart == materializedText],
                          threshold: simG1Threshold("g1_restart_preserves_acked_workspace",
                                                    measured: preserved ? 1 : 0),
                          detail: "the planned restart did not change acked WAL/materialized bytes")
            report.set("wal_after_restart", [
                "segments": walAfterRestart.segmentCount,
                "mutations": walAfterRestart.mutationCount,
                "target_mseqs": walAfterRestart.targetMseqs,
                "target_text": walAfterRestart.targetText,
                "mutations_before_restart": mutationCountBefore,
                "append_mismatches": walAfterRestart.appendMismatches,
            ])
            report.set("materialized_after_restart", materializedAfterRestart)
            guard preserved else {
                throw SimError.assertion(
                    "the planned restart changed the WAL/materialized evidence for a.txt")
            }

            // MARK: Second trivial turn on the resumed session
            let resumeStart = Date()
            let resumedHarness = try await smokeHost.harness()
            eventLog.attach(harness: resumedHarness, sessionID: session.id)
            let requestCountBeforeResume = mock.requestCount
            let resumedPromptMarker = "sim-turn-2-\(UUID().uuidString.lowercased())"
            let resumedTurnWatermark = eventLog.harnessSequenceWatermark
            try await resumedHarness.send(
                .prompt(text: "Reply with one short confirmation. [\(resumedPromptMarker)]",
                        attachments: [], requestID: "sim-turn-2"),
                to: session.id)
            try await simWait(timeout: 240, label: "second turn model request") {
                mock.requestCount > requestCountBeforeResume
            }
            let resumedTurnReceipt = try await waitForCompletedHarnessTurn(
                eventLog: eventLog,
                after: resumedTurnWatermark,
                promptMarker: resumedPromptMarker,
                label: "resumed model turn")
            guard resumedTurnReceipt.reason == .completed else {
                throw SimError.assertion(
                    "resumed turn \(resumedTurnReceipt.turnID) ended as \(resumedTurnReceipt.reason); "
                        + "tool errors: \(resumedTurnReceipt.toolErrors.joined(separator: " | "))")
            }
            report.addPhase("resumed_turn", milliseconds: Self.ms(since: resumeStart))
            let resumedRequests = mock.requests
            let resumedOK = resumedRequests.last.map {
                MockModelUpstream.transcriptHasToolResult($0.body)
            } == true
            let finalWAL = try simReadWALSummary(workspace: workspace,
                                                 targetPath: Self.targetPath)
            let walUnchanged = finalWAL.targetMseqs == targetMseqsBefore
                && finalWAL.targetBytes == targetBytesBefore
                && finalWAL.appendMismatches.isEmpty
                && Array(finalWAL.mutationMseqs.prefix(mutationCountBefore))
                    == Array(wal.mutationMseqs.prefix(mutationCountBefore))
            report.record("smoke.resumed_session",
                          status: resumedOK && walUnchanged ? .pass : .fail,
                          gating: true,
                          metrics: ["model_requests_before": requestCountBeforeResume,
                                    "model_requests_after": resumedRequests.count,
                                    "transcript_reached_model": resumedOK,
                                    "wal_unchanged": walUnchanged],
                          threshold: simG1Threshold("g1_resumed_session_after_restart",
                                                    measured: resumedOK && walUnchanged ? 1 : 0),
                          detail: "session/prompt on the durable Session id after the restart")
            report.set("resume", [
                "session_id": session.id,
                "resume_path": "session/prompt on the durable Session id",
                "model_requests_before": requestCountBeforeResume,
                "model_requests_after": resumedRequests.count,
                "target_mseqs": finalWAL.targetMseqs,
                "materialized_unchanged": true,
                "turn_lifecycle": Self.describe(resumedTurnReceipt),
            ])
            guard resumedOK && walUnchanged else {
                throw SimError.assertion(
                    "the resumed turn did not continue the durable session intact")
            }

            // MARK: Real-CPython urllib over the Worker /v1/http bridge
            // This is a separate scripted-model turn after every original
            // smoke assertion: the fixed model text is not evidence; the
            // structured VFS result and the direct upstream capture are.
            try await runPythonHTTPAcceptance(harness: resumedHarness,
                                              eventLog: eventLog,
                                              sessionID: session.id,
                                              workspace: workspace,
                                              mock: mock,
                                              report: report)

            let notImplementedFail = eventLog.notImplementedFailLines
            report.record("smoke.not_implemented_fail",
                          status: .info, gating: false,
                          metrics: ["count": notImplementedFail.count],
                          threshold: simInfoThreshold("not_implemented_fail"),
                          detail: notImplementedFail.joined(separator: " | "))
            report.set("not_implemented_fail", notImplementedFail)
            report.set("host_errors", eventLog.hostErrors)
            report.set("harness_errors", eventLog.harnessErrors)
            report.set("state_changes", eventLog.stateChanges)
            report.set("worker_hellos", eventLog.hellos.map {
                ["boot_id": $0.bootID, "last_mseq": $0.lastMseq,
                 "generation": $0.generation, "wal_seq": $0.walSeq,
                 "count": $0.count]
            })
            report.finish(ok: true)
        } catch {
            failure = error
            report.finish(ok: false, failure: String(describing: error))
            report.record("smoke.failure", status: .fail, gating: true,
                          metrics: ["error": String(describing: error)],
                          threshold: simG1Threshold("g1_smoke_completed",
                                                    measured: 0),
                          detail: String(describing: error))
        }

        // MARK: - Teardown
        eventLog.stop()
        if let host {
            try? await host.stop()
        }
        engine?.shutdown()
        window?.shutdown()
        mock.stop()
        report.addConsole(lines: eventLog.tail(50))
        report.set("console_count", eventLog.console.count)
        if let failure {
            print("sim-smoke: FAILED: \(failure)")
            for line in eventLog.tail(50) { print("sim-smoke console: \(line)") }
        }
        do {
            try report.write()
        } catch {
            print("sim-smoke: cannot write smoke-report.json: \(error)")
        }
        if let failure {
            let tail = eventLog.tail(50).joined(separator: "\n")
            XCTFail("iOS Simulator end-to-end smoke failed: \(failure)\n"
                    + "--- last 50 console lines ---\n\(tail)\n"
                    + "--- report: \(report.fileURL.path) ---")
        }
    }

    /// How the real WebContent-kill handshake ended.
    private enum RealKillOutcome {
        /// No watcher marker was present: a direct `xcodebuild test` run.
        case notRequested
        /// The watcher SIGKILLed this run's WebContent.
        case attempted(String)
        /// The watcher ran but could not signal the WebContent (or did not
        /// answer in time).
        case unavailable(String)
    }

    /// Hands this suite's live WebContent to the simulator gate's real-kill
    /// watcher and returns what the watcher did.
    ///
    /// `scripts/ci/sim.sh` creates `expect-real-kill` in the report
    /// directory and runs a background watcher before the suites. This method
    /// writes `real-kill-ready.json` while the smoke host's real WKWebView is
    /// alive, then waits (bounded) for the watcher's `real-kill-result.json`.
    /// The watcher selects pids by the simulator runtime path and the selected
    /// simulator's `SIMULATOR_UDID` environment, so it can never reach a host
    /// WebContent process.
    private func requestRealWebContentKill(directory: URL) async -> RealKillOutcome {
        let fileManager = FileManager.default
        let expect = directory.appendingPathComponent("expect-real-kill")
        guard fileManager.fileExists(atPath: expect.path) else { return .notRequested }
        let ready = directory.appendingPathComponent("real-kill-ready.json")
        let result = directory.appendingPathComponent("real-kill-result.json")
        let request: [String: Any] = [
            "requested_at": ISO8601DateFormatter().string(from: Date()),
            "webcontent_live": true,
            "detail": "the smoke host's real WKWebView is alive; the shell "
                + "watcher may SIGKILL this simulator's WebContent",
        ]
        if let data = try? JSONSerialization.data(withJSONObject: request,
                                                  options: [.sortedKeys]) {
            try? data.write(to: ready, options: .atomic)
        }
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if let data = try? Data(contentsOf: result),
               let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any] {
                let status = object["status"] as? String
                    ?? "unavailable: the watcher result has no status"
                return status.hasPrefix("attempted:")
                    ? .attempted(status) : .unavailable(status)
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return .unavailable("unavailable: scripts/ci/sim.sh did not report "
            + "the attempt within 15 s")
    }

    /// One independent scripted-model turn whose real DSH `bash` tool runs
    /// `python3 -c` over the packed CPython WASI runtime. The Python program
    /// exercises `urllib.request` against the already allow-listed local mock:
    /// POST 200/SSE, GET 404 with a body, and the host allow-list rejection of
    /// `forbidden.invalid`. It writes a structured VFS result only after every
    /// assertion passes; this method reads the materialized copy and also
    /// checks the mock's actual request capture, so a guest-only env assertion
    /// cannot stand in for the upstream boundary.
    private func runPythonHTTPAcceptance(harness: any AgentHarness,
                                         eventLog: SimSmokeEventLog,
                                         sessionID: String,
                                         workspace: URL,
                                         mock: MockModelUpstream,
                                         report: SimSuiteReport) async throws {
        let fileManager = FileManager.default
        let marker = "python-http-\(UUID().uuidString.lowercased())"
        let resultName = "\(marker).json"
        let guestResultPath = "/dsh/workspace/\(resultName)"
        let resultURL = workspace
            .appendingPathComponent("materialized/workspace/\(resultName)")
        let command = SimPythonHTTPAcceptance.command(origin: mock.baseURL,
                                                      marker: marker,
                                                      resultPath: guestResultPath)
        mock.script = .generic(
            command: command,
            toolText: "Running the Python urllib /v1/http acceptance script.",
            finalText: "The Python acceptance script finished.")
        let requestsBefore = mock.requestCount
        let turnWatermark = eventLog.harnessSequenceWatermark
        let start = Date()
        try await harness.send(
            .prompt(text: "Run the Python urllib /v1/http acceptance script. [\(marker)]",
                    attachments: [], requestID: "sim-python-http"),
            to: sessionID)
        // The event watermark, prompt marker and actual DSH turn ID join this
        // prompt to its durable lifecycle. Do not let request arrival count or
        // a VFS file stand in for turn completion.
        let turnReceipt = try await waitForCompletedHarnessTurn(
            eventLog: eventLog,
            after: turnWatermark,
            promptMarker: marker,
            label: "Python /v1/http tool turn")
        guard turnReceipt.reason == .completed else {
            throw SimError.assertion(
                "Python turn \(turnReceipt.turnID) ended as \(turnReceipt.reason); "
                    + "tool errors: \(turnReceipt.toolErrors.joined(separator: " | "))")
        }
        guard turnReceipt.toolErrors.isEmpty else {
            throw SimError.assertion(
                "Python turn \(turnReceipt.turnID) completed with tool errors: "
                    + turnReceipt.toolErrors.joined(separator: " | "))
        }
        try await simWait(timeout: 120, label: "Python /v1/http materialized result") {
            guard fileManager.fileExists(atPath: resultURL.path) else { return false }
            return (try? SimPythonHTTPAcceptance.readResult(at: resultURL)) != nil
        }
        report.addPhase("python_http_acceptance", milliseconds: Self.ms(since: start))

        let result = try SimPythonHTTPAcceptance.readResult(at: resultURL)
        let turnRequests = Array(mock.requests.dropFirst(requestsBefore))
        let pythonRequests = turnRequests.filter {
            SimPythonHTTPAcceptance.pythonRequest(in: [$0], marker: marker) != nil
        }
        let pythonRequest = pythonRequests.first
        let headers = pythonRequest?.headers ?? [:]
        let referer = headers["referer"]
        let referrer = headers["referrer"]
        let refererHasLaunchToken = (referer?.contains(Self.launchToken) ?? false)
            || (referrer?.contains(Self.launchToken) ?? false)
        let cookie = headers["cookie"]
        let cookie2 = headers["cookie2"]
        let headerNames = Set(headers.keys.map { $0.lowercased() })
        let post = result["post"] as? [String: Any] ?? [:]
        let getMissing = result["get_missing"] as? [String: Any] ?? [:]
        let forbidden = result["forbidden"] as? [String: Any] ?? [:]
        let env = result["env"] as? [String: Any] ?? [:]
        let envLeaks = env["leaks"] as? [String] ?? []
        let pythonPlatform = result["platform"] as? String ?? ""
        let pythonMachine = result["machine"] as? String ?? ""
        let pythonRequestIndex = turnRequests.firstIndex { request in
            SimPythonHTTPAcceptance.pythonRequest(in: [request], marker: marker) != nil
        }
        let modelFollowUpIndex = turnRequests.indices.first { index in
            guard let pythonRequestIndex, index > pythonRequestIndex else { return false }
            return SimPythonHTTPAcceptance.lastMessageToolResultContains(
                turnRequests[index].body,
                marker: "PYTHON_HTTP_ACCEPTANCE_OK \(marker)")
        }
        let modelFollowUp = modelFollowUpIndex != nil

        let postStatus = post["status"] as? Int
        let postBodyBytes = post["body_bytes"] as? Int
        let postSSE = (post["sse_message_start"] as? Bool == true)
            && (post["sse_data"] as? Bool == true)
        let postContentType = post["content_type"] as? String ?? ""
        let missingStatus = getMissing["status"] as? Int
        let missingBodyBytes = getMissing["body_bytes"] as? Int
        let forbiddenStatus = forbidden["status"] as? Int
        let forbiddenBodyBytes = forbidden["body_bytes"] as? Int
        let forbiddenDenied = forbiddenStatus == 403
            && (forbidden["host_not_allowed"] as? Bool == true)
        let envIsolated = envLeaks.isEmpty
            && (env["has_channel_token"] as? Bool == false)
            && (env["python_http_flag"] as? String == "1")

        let checks: [(name: String, label: String, passed: Bool,
                      metrics: [String: Any])] = [
            ("python_http_result",
             "the WASI Worker wrote the structured Python result",
             (result["success"] as? Bool == true)
                && (result["marker"] as? String == marker)
                && ((result["python"] as? String)?.isEmpty == false)
                && pythonPlatform == "wasi" && pythonMachine == "wasm32",
             ["success": result["success"] as? Bool ?? false,
              "marker_matches": result["marker"] as? String == marker,
              "python": result["python"] as? String ?? "unknown",
              "platform": pythonPlatform,
              "machine": pythonMachine]),
            ("python_http_post",
             "urllib POST /v1/messages returned 200 with the mock SSE body",
             postStatus == 200 && (postBodyBytes ?? 0) > 0 && postSSE
                && postContentType.contains("text/event-stream"),
             ["status": postStatus ?? 0, "body_bytes": postBodyBytes ?? 0,
              "sse": postSSE, "content_type": postContentType]),
            ("python_http_get_404",
             "urllib GET on a missing path raised HTTPError 404 with a body",
             missingStatus == 404 && (missingBodyBytes ?? 0) > 0
                && (getMissing["body_has_no_route"] as? Bool == true),
             ["status": missingStatus ?? 0, "body_bytes": missingBodyBytes ?? 0,
              "body_has_no_route": getMissing["body_has_no_route"] as? Bool ?? false]),
            ("python_http_allowlist_deny",
             "the host allow-list refused forbidden.invalid with 403",
             forbiddenDenied,
             ["status": forbiddenStatus ?? 0, "body_bytes": forbiddenBodyBytes ?? 0,
              "host_not_allowed": forbidden["host_not_allowed"] as? Bool ?? false]),
            ("python_http_env_isolation",
             "the guest environment has no host launch token or API secret",
             envIsolated,
             ["leaks": envLeaks.count,
              "has_channel_token": env["has_channel_token"] as? Bool ?? false,
              "has_channel_origin": env["has_channel_origin"] as? Bool ?? false,
              "python_http_flag": env["python_http_flag"] as? String ?? ""]),
            ("python_http_upstream_cookie_boundary",
             "the Python POST carried no Cookie upstream",
             pythonRequests.count == 1 && cookie == nil && cookie2 == nil,
             ["captured": pythonRequest != nil,
              "captured_requests": pythonRequests.count,
              "cookie_present": cookie != nil,
              "cookie2_present": cookie2 != nil]),
            ("python_http_upstream_referer_boundary",
             "the Python POST carried no loopback Referer or Referrer upstream",
             pythonRequests.count == 1 && referer == nil && referrer == nil
                && refererHasLaunchToken == false,
             ["captured": pythonRequest != nil,
              "captured_requests": pythonRequests.count,
              "referer_present": referer != nil,
              "referrer_present": referrer != nil,
              "referer_has_launch_token": refererHasLaunchToken]),
            ("python_http_host_credential",
             "the host credential was applied after ambient headers were dropped",
             headers["x-api-key"] == Self.hostAPIKey,
             ["api_key_injected": headers["x-api-key"] == Self.hostAPIKey]),
            ("python_http_turn_follow_up",
             "the scripted model received the Python tool result",
             modelFollowUp && (turnReceipt.reason == .completed),
             ["requests": turnRequests.count,
              "python_request_index": pythonRequestIndex ?? -1,
              "follow_up_index": modelFollowUpIndex ?? -1,
              "last_request_has_this_result": modelFollowUp,
              "turn_id": turnReceipt.turnID,
              "turn_end_sequence": turnReceipt.endedSequence]),
        ]
        var failedChecks: [String] = []
        for check in checks {
            if !check.passed { failedChecks.append(check.label) }
            report.record("smoke.\(check.name)",
                          status: check.passed ? .pass : .fail,
                          gating: true,
                          metrics: check.metrics,
                          threshold: simG1Threshold(check.name,
                                                    measured: check.passed ? 1 : 0),
                          detail: check.label)
        }
        let capturedRequest: [String: Any] = [
            "found": pythonRequest != nil,
            "header_names": headerNames.sorted(),
            "cookie_present": cookie != nil,
            "cookie2_present": cookie2 != nil,
            "referer_present": referer != nil,
            "referrer_present": referrer != nil,
            "referer_has_launch_token": refererHasLaunchToken,
            "host_credential_injected": headers["x-api-key"] == Self.hostAPIKey,
        ]
        let pythonDetails: [String: Any] = [
            "marker": marker,
            "guest_result_path": guestResultPath,
            "materialized_result": resultName,
            "requests": turnRequests.count,
            "turn_lifecycle": Self.describe(turnReceipt),
            "post": post,
            "get_missing": getMissing,
            "forbidden": forbidden,
            "env": env,
            "captured_request": capturedRequest,
            "failed_checks": failedChecks,
        ]
        report.set("python_http", pythonDetails)
        if failedChecks.isEmpty == false {
            throw SimError.assertion(
                "python /v1/http acceptance: " + failedChecks.joined(separator: "; "))
        }
    }

    private func waitForCompletedHarnessTurn(eventLog: SimSmokeEventLog,
                                             after watermark: UInt64,
                                             promptMarker: String,
                                             label: String) async throws
        -> SimHarnessTurnReceipt {
        var receipt: SimHarnessTurnReceipt?
        try await simWait(timeout: 240, label: "\(label) durable turn end") {
            receipt = eventLog.completedHarnessTurn(after: watermark,
                                                    promptMarker: promptMarker)
            return receipt != nil
        }
        guard let receipt else {
            throw SimError.assertion("\(label) ended without a durable lifecycle receipt")
        }
        return receipt
    }

    private static func describe(_ receipt: SimHarnessTurnReceipt) -> [String: Any] {
        ["turn_id": receipt.turnID,
         "started_sequence": receipt.startedSequence,
         "ended_sequence": receipt.endedSequence,
         "reason": String(describing: receipt.reason),
         "tool_errors": receipt.toolErrors]
    }

    /// Raw `session/create` error text for a fail-loud diagnosis.
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
