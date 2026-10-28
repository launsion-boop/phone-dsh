// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — iOS Simulator native-runtime acceptance.
//
// The workflow and Streamable HTTP MCP real-WebWorker acceptance tests, each
// runnable on its own with `-only-testing`. The separate Streamable HTTP
// text/event-stream response case lives in WorkerCapabilitySSETests.swift; the
// model Messages SSE response below is the model transport, not the MCP server
// response.
//
//   * standard preset health + `session/create` + the official `workflow`
//     tool. The model is scripted; the parent Session, the dedicated workflow
//     Worker, the child Activation, the Worker bash/VFS write, the tool
//     journal and the parent Session result are real. A second isolate runs a
//     synchronous `while (true) {}` and is terminated by the workflow
//     deadline; the next ordinary workflow in the same Session must succeed.
//     The workflow script also performs a real constructor escape and proves
//     the isolate cannot see the parent Worker's channel/token, VFS or module
//     globals (and the parent dummy environment sentinel).
//   * phone-mcp mounted in the real WKWebView WebWorker: the local Streamable
//     HTTP MCP fixture is registered through `phone/mcpUpsert`, listed,
//     invoked by a real model tool call, then removed. The fixture observes
//     the actual JSON-RPC initialize/tools/list/tools/call sequence and only
//     accepts the host `/mcp` credential, not the different env-only dummy.
//     This is the MCP Streamable HTTP transport with finite JSON POST
//     responses, not the separate text/event-stream response case and not the
//     model Messages SSE stream.
//
// The host assembly is the App's `WebHostConfiguration` (complete DSH page,
// persistent WebEngine store, pinned loopback origin, shell provider). Each
// test uses a unique nonce and a unique Documents/chat-host-capability-<nonce>
// root so an older WAL/JSONL/mcp.json cannot satisfy this run. Nothing is
// deleted from an older run.
//
// iOS Simulator only. A physical-iPhone run, a real model endpoint, a real
// external MCP server and a real credential are NOT_RUN.

import CoreGraphics
import Foundation
import XCTest
import WebKit
import PhoneDSHAgentCore
import PhoneDSH
import PhoneDSHEngine
import ProbeKit

/// One redaction pass shared by every console line, failure string, diagnostic
/// and XCTest tail that enters a capability report. Secrets are matched
/// longest-first so `Bearer <token>` is replaced before the bare token.
struct CapabilityRedactor {
    private let secrets: [String]

    init(_ secrets: [String]) {
        self.secrets = secrets
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
    }

    func redact(_ text: String, limit: Int? = nil) -> String {
        var value = text
        for secret in secrets {
            value = value.replacingOccurrences(of: secret, with: "[redacted]")
        }
        guard let limit else { return value }
        let flat = value.replacingOccurrences(of: "\n", with: " ")
        return flat.count <= limit ? flat : String(flat.prefix(limit)) + "…"
    }
}

@MainActor
final class PhoneDSHWorkerCapabilityTests: XCTestCase {
    static let fullPagePath = WebHostConfiguration.pagePath
    static let modelName = "worker-capability"
    static let hostAPIKey = "worker-capability-host-key"
    static let workerPlaceholderKey = "worker-capability-worker-placeholder"
    private static let parentSentinelName = "PDSH_PARENT_SENTINEL"

    // MARK: - Workflow acceptance

    func testSimulatorStandardWorkflowIsolateBashAndDeadline() async throws {
        let nonce = Self.makeNonce("wf")
        let directory = try SimEnvironment.reportsDirectory()
        let report = SimSuiteReport(suite: "worker-workflow", gate: "G1", directory: directory,
                                    fileName: "worker-workflow-report.json")
        let model = CapabilityModelFixture(mode: .workflow(nonce: nonce))
        let parentSentinelValue = "dummy-parent-sentinel-\(nonce)"
        let redactor = CapabilityRedactor([Self.hostAPIKey,
                                           "Bearer \(Self.hostAPIKey)",
                                           Self.workerPlaceholderKey,
                                           "Bearer \(Self.workerPlaceholderKey)",
                                           parentSentinelValue])
        var host: CapabilityTestHost?
        var failure: Error?

        do {
            report.set("nonce", nonce)
            let modelURL = try model.start()
            report.set("model_url", modelURL.absoluteString)
            let testHost = try CapabilityTestHost(nonce: nonce, report: report)
            host = testHost
            try await testHost.boot(modelURL: modelURL,
                                    modelName: Self.modelName,
                                    environmentExtra: [
                                        Self.parentSentinelName: parentSentinelValue,
                                    ])
            guard let transport = testHost.transport else {
                throw SimError.assertion("the host did not publish a DSH Remote transport")
            }

            // MARK: Standard preset health
            let presets = try await transport.call("agentPresets/list", args: .object([:]))
            let presetRows = presets["presets"]?.arrayValue ?? []
            let standard = presetRows.first { $0["id"]?.stringValue == "standard" }
            let standardBroken = standard?["broken"]?.stringValue ?? ""
            let standardDefault = standard?["isDefault"]?.boolValue ?? false
            try require(report, "workflow.preset",
                        standard != nil && standardBroken.isEmpty && standardDefault,
                        metrics: [
                            "listed": standard != nil,
                            "broken": standardBroken,
                            "is_default": standardDefault,
                            "roster_count": presetRows.count,
                        ],
                        detail: "the real agent-preset registry lists standard, marks it default and reports no broken row")

            // MARK: session/create on standard
            let agent = try await testHost.hostHarness()
            let session: HarnessSession
            do {
                session = try await agent.openSession(
                    HarnessSessionRequest(preset: "standard", workspace: "/dsh/workspace"))
            } catch {
                let diagnostic = await Self.rawSessionCreateDiagnostic(transport: transport,
                                                                        redactor: redactor)
                report.set("session_create_error", diagnostic)
                throw SimError.assertion("standard session/create failed: "
                    + "\(redactor.redact(String(describing: error))); \(diagnostic)")
            }
            testHost.eventLog.attach(harness: agent, sessionID: session.id)
            report.set("session_id", session.id)
            let projection = try await transport.call(
                "session/projections",
                args: .object(["request": .object(["sessionId": .string(session.id)])]))
            let projectedPresetBefore = projection["values"]?["agentPreset"]?.stringValue ?? ""
            try await simWait(timeout: 30, label: "session/list has the created Session projection") {
                let list = try await transport.call("session/list", args: .object([:]))
                guard let row = (list["items"]?.arrayValue ?? []).first(where: {
                    $0["sessionId"]?.stringValue == session.id
                }) else { return false }
                return row["cwd"]?.stringValue == "/dsh/workspace"
                    && row["projections"]?["values"]?["agentPreset"]?.stringValue == "standard"
            }
            let list = try await transport.call("session/list", args: .object([:]))
            let listedSession = (list["items"]?.arrayValue ?? []).first {
                $0["sessionId"]?.stringValue == session.id
            }
            let cwd = listedSession?["cwd"]?.stringValue ?? ""
            // `session/list` carries the live projection block; read the
            // agentPreset cell from that actual response, not only from the
            // separate projection call or a metrics/default guess.
            let listedPreset = listedSession?["projections"]?["values"]?["agentPreset"]?.stringValue ?? ""
            try require(report, "workflow.session",
                        !session.id.isEmpty
                            && cwd == "/dsh/workspace"
                            && projectedPresetBefore == "standard"
                            && listedPreset == "standard",
                        metrics: ["session_id": session.id,
                                  "agent_preset_before_prompt": projectedPresetBefore,
                                  "listed_agent_preset": listedPreset,
                                  "cwd": cwd,
                                  "listed": listedSession != nil],
                        detail: "session/create returned a real Session in /dsh/workspace; both the Session "
                            + "projection and the session/list projection block report agentPreset=standard")

            // MARK: One real synchronously-hung workflow isolate
            // Capture the current boot/engine before the deadline. A Worker or
            // engine reload after the deadline must change one of these; the
            // post-loop assertions below compare both snapshots.
            let bootEngine = testHost.engine
            let bootPublishedEngine = testHost.bootPublishedEngine
            let hellosBeforeLoop = testHost.eventLog.hellos
            let diagnosticsBeforeLoop = try await testHost.diagnostics()
            let loopPrompt = "PDSH_PHASE_LOOP_\(nonce) Run the synchronous loop workflow probe \(nonce)."
            let loopFileURL = testHost.workspace
                .appendingPathComponent("materialized/workspace/loop-start-\(nonce).txt")
            let loopStart = Date()
            try await agent.send(
                .prompt(text: loopPrompt, attachments: [], requestID: "loop-\(nonce)"),
                to: session.id)
            try await simWait(timeout: 90, label: "loop workflow deadline") {
                let records = Self.toolRecords(from: testHost.eventLog.harnessEvents)
                guard let record = records.first(where: {
                    $0.name == "workflow" && $0.arguments.contains("worker-loop-\(nonce)")
                }), let result = record.result else { return false }
                return result.text.contains("synchronous execution budget")
                    && result.text.contains("terminated")
                    && FileManager.default.fileExists(atPath: loopFileURL.path)
            }
            // Non-gating diagnostic snapshot before the gating final row: if the
            // following normal phase times out, the report still shows that the
            // loop request was (or was not) selected from the real user marker.
            report.record("worker.workflow.fixture_selection_after_loop",
                          status: .info, gating: false,
                          metrics: Self.fixtureSelectionMetrics(model.selection),
                          threshold: simInfoThreshold(
                            "worker_workflow_fixture_selection_after_loop"),
                          detail: "non-gating snapshot of the scripted model branches selected up to the "
                              + "loop deadline; the gating workflow.fixture_selection row is emitted later")
            let loopFileText = (try? String(contentsOf: loopFileURL, encoding: .utf8)) ?? ""
            try require(report, "workflow.loop_started",
                        loopFileText.trimmingCharacters(in: .whitespacesAndNewlines)
                            == "LOOP_STARTED_\(nonce)",
                        metrics: ["path": loopFileURL.path,
                                  "text": loopFileText.trimmingCharacters(in: .whitespacesAndNewlines),
                                  "expected": "LOOP_STARTED_\(nonce)"],
                        detail: "the loop isolate first ran a real child bash write, proving the synchronous "
                            + "while (true) body executed rather than a boot-time termination")
            try await simWait(timeout: 30, label: "loop turn settled") {
                let assistantDone = Self.assistantTexts(in: testHost.eventLog.harnessEvents)
                    .contains { $0.contains("LOOP_TERMINATED_\(nonce)") }
                return assistantDone || Self.hasTurnEnded(in: testHost.eventLog.harnessEvents)
            }
            let loopElapsed = Date().timeIntervalSince(loopStart)
            let afterLoopRecords = Self.toolRecords(from: testHost.eventLog.harnessEvents)
            guard let loopRecord = afterLoopRecords.first(where: {
                $0.name == "workflow" && $0.arguments.contains("worker-loop-\(nonce)")
            }), let loopResult = loopRecord.result else {
                throw SimError.artifact("the parent Session has no loop workflow call/result")
            }
            let diagnosticsAfterLoop = try await testHost.diagnostics()
            let hellosAfterLoop = testHost.eventLog.hellos
            let hostAfterLoop = diagnosticsAfterLoop.state
            let sameBoot = diagnosticsBeforeLoop.bootID == diagnosticsAfterLoop.bootID
            let sameHelloCount = diagnosticsBeforeLoop.workerHelloCount
                == diagnosticsAfterLoop.workerHelloCount
            let sameWorkerBoot = hellosBeforeLoop.count == hellosAfterLoop.count
                && hellosBeforeLoop.last?.bootID == hellosAfterLoop.last?.bootID
            let sameConnectionCount = diagnosticsBeforeLoop.channelConnectionCount
                == diagnosticsAfterLoop.channelConnectionCount
            let noTerminations = diagnosticsBeforeLoop.webContentTerminations == 0
                && diagnosticsAfterLoop.webContentTerminations == 0
            let noRestarts = testHost.eventLog.restarts.isEmpty
            let sameEngine = testHost.engine === bootEngine
            let samePublishedEngine = testHost.publishedEngine === bootPublishedEngine
            let engineStillPublished = testHost.engine === testHost.publishedEngine
            let deadlineText = loopResult.text.contains("synchronous execution budget")
            let terminationText = loopResult.text.contains("terminated")
            try require(report, "workflow.loop_terminated",
                        loopResult.isError
                            && deadlineText
                            && terminationText
                            && loopElapsed < 30
                            && hostAfterLoop == .running
                            && sameBoot
                            && sameHelloCount
                            && sameWorkerBoot
                            && sameConnectionCount
                            && noTerminations
                            && noRestarts
                            && sameEngine
                            && samePublishedEngine
                            && engineStillPublished,
                        metrics: [
                            "is_error": loopResult.isError,
                            "elapsed_seconds": loopElapsed.rounded(),
                            "host_state": hostAfterLoop.rawValue,
                            "call_id": loopRecord.callID,
                            "deadline_text": deadlineText,
                            "termination_text": terminationText,
                            "boot_id_before": diagnosticsBeforeLoop.bootID,
                            "boot_id_after": diagnosticsAfterLoop.bootID,
                            "worker_hello_count_before": diagnosticsBeforeLoop.workerHelloCount,
                            "worker_hello_count_after": diagnosticsAfterLoop.workerHelloCount,
                            "worker_hello_boot_id_before": hellosBeforeLoop.last?.bootID ?? "",
                            "worker_hello_boot_id_after": hellosAfterLoop.last?.bootID ?? "",
                            "channel_connection_count_before":
                                diagnosticsBeforeLoop.channelConnectionCount,
                            "channel_connection_count_after":
                                diagnosticsAfterLoop.channelConnectionCount,
                            "web_content_terminations_before":
                                diagnosticsBeforeLoop.webContentTerminations,
                            "web_content_terminations_after":
                                diagnosticsAfterLoop.webContentTerminations,
                            "restart_count": testHost.eventLog.restarts.count,
                            "same_engine": sameEngine,
                            "same_published_engine": samePublishedEngine,
                            "engine_still_published": engineStillPublished,
                        ],
                        detail: "the real workflow isolate running while (true) was hard-terminated at the deadline "
                            + "(an error result naming the synchronous budget and termination); the same boot, Worker "
                            + "HELLO count, engine and published engine remain, with no WebContent termination or "
                            + "restart, and the main Worker stayed Running")

            // MARK: The next ordinary workflow in the same Session
            let normalPrompt = "PDSH_PHASE_NORMAL_\(nonce) Run the normal workflow probe \(nonce)."
            try await agent.send(
                .prompt(text: normalPrompt, attachments: [], requestID: "normal-\(nonce)"),
                to: session.id)
            let fileURL = testHost.workspace
                .appendingPathComponent("materialized/workspace/workflow-\(nonce).txt")
            try await simWait(timeout: 240, label: "normal workflow child bash + parent result") {
                let records = Self.toolRecords(from: testHost.eventLog.harnessEvents)
                guard let record = records.first(where: {
                    $0.name == "workflow"
                        && $0.arguments.contains("worker-bash-probe-\(nonce)")
                }), let result = record.result else { return false }
                return !result.isError
                    && result.text.contains("WORKFLOW_BASH_OK_\(nonce)")
                    && Self.assistantTexts(in: testHost.eventLog.harnessEvents)
                        .contains { $0.contains("WORKFLOW_DONE_\(nonce)") }
                    && FileManager.default.fileExists(atPath: fileURL.path)
            }
            let records = Self.toolRecords(from: testHost.eventLog.harnessEvents)
            guard let normalRecord = records.first(where: {
                $0.name == "workflow" && $0.arguments.contains("worker-bash-probe-\(nonce)")
            }), let normalResult = normalRecord.result else {
                throw SimError.artifact("the parent Session has no successful normal workflow result")
            }
            let fileText = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
            let escapeChecks = [
                "globalObject=true",
                "parentEnvSentinel=undefined",
                "parentToken=undefined",
                "moduleLoader=undefined",
                "vfs=undefined",
                "process=undefined",
                "fetch=undefined",
                "worker=undefined",
            ]
            let escapePassed = escapeChecks.allSatisfy { normalResult.text.contains($0) }
            let projectionAfter = try await transport.call(
                "session/projections",
                args: .object(["request": .object(["sessionId": .string(session.id)])]))
            let projectedPresetAfter = projectionAfter["values"]?["agentPreset"]?.stringValue ?? ""
            try require(report, "workflow.preset_projection",
                        projectedPresetAfter == "standard",
                        metrics: ["agent_preset_after_prompt": projectedPresetAfter,
                                  "agent_preset_before_prompt": projectedPresetBefore],
                        detail: "the same Session projects agentPreset=standard after the real standard-preset turn")
            try require(report, "workflow.next_workflow",
                        !normalResult.isError
                            && normalResult.text.contains("WORKFLOW_BASH_OK_\(nonce)")
                            && normalRecord.callID != loopRecord.callID,
                        metrics: ["is_error": normalResult.isError,
                                  "call_id": normalRecord.callID,
                                  "loop_call_id": loopRecord.callID,
                                  "child_text": normalResult.text.contains("WORKFLOW_BASH_OK_\(nonce)")],
                        detail: "after the terminated isolate, a fresh workflow isolate started a real child Activation "
                            + "and returned the child's WORKFLOW_BASH_OK text to the same parent Session")
            // The model fixture must have selected the real user phase from the
            // Messages body, not the trailing time context or an agent
            // instruction that merely mentions "loop". These are gating so a
            // worker-bash-probe turn can never satisfy the loop row.
            let fixtureSelection = model.selection
            try require(report, "workflow.fixture_selection",
                        fixtureSelection.sawParentLoop
                            && fixtureSelection.sawParentNormal
                            && fixtureSelection.sawChildLoop
                            && fixtureSelection.sawChildNormal,
                        metrics: Self.fixtureSelectionMetrics(fixtureSelection),
                        detail: "the scripted model selected the loop and normal parent phases from the explicit "
                            + "per-turn markers, and the loop/normal child branches from their distinct child "
                            + "markers; the loop row therefore proves the loop script was actually sent")
            try require(report, "workflow.bash_fs",
                        fileText.trimmingCharacters(in: .whitespacesAndNewlines)
                            == "WORKFLOW_FILE_OK_\(nonce)",
                        metrics: ["path": fileURL.path,
                                  "text": fileText.trimmingCharacters(in: .whitespacesAndNewlines),
                                  "expected": "WORKFLOW_FILE_OK_\(nonce)"],
                        detail: "the child's real bash command wrote and read this run's unique VFS file")
            try require(report, "workflow.isolate_escape",
                        escapePassed,
                        metrics: ["escape_checks": escapeChecks.joined(separator: ","),
                                  "parent_env_sentinel_configured": !parentSentinelValue.isEmpty,
                                  "global_object_identity": normalResult.text.contains("globalObject=true"),
                                  "token_value_recorded": false],
                        detail: "the workflow isolate's real constructor escape returned the genuine isolate "
                            + "globalThis (Object/Math identity) and saw no parent "
                            + "__PDSH_CHANNEL__/__PDSH_VFS_FLUSH__/__PDSH_MODULE_LOADER__, no process/fetch/Worker "
                            + "global and not the configured parent PDSH_PARENT_SENTINEL environment value; the "
                            + "parent dummy sentinel is test-only")

            // MARK: Same Worker Session/page stream and callId
            let lastSeq = testHost.eventLog.harnessEvents.compactMap(\.seq).max()
                .map { Int($0 / 8) } ?? 100
            let page = try await Self.sessionPage(transport: transport,
                                                  sessionID: session.id,
                                                  throughSeq: lastSeq)
            let loopPage = page.toolCalls.first { $0.value.name == "workflow"
                && $0.value.arguments.contains("worker-loop-\(nonce)") }
            let normalPage = page.toolCalls.first { $0.value.name == "workflow"
                && $0.value.arguments.contains("worker-bash-probe-\(nonce)") }
            let loopPageResult = loopPage.flatMap { page.toolResults[$0.key] }
            let normalPageResult = normalPage.flatMap { page.toolResults[$0.key] }
            let pageAssistant = page.assistantTexts.contains {
                $0.contains("WORKFLOW_DONE_\(nonce)")
            }
            let pageLoopFinal = page.assistantTexts.contains {
                $0.contains("LOOP_TERMINATED_\(nonce)")
            }
            let sameLoop = loopPage?.key == loopRecord.callID
                && loopPageResult?.text.contains("synchronous execution budget") == true
            let sameNormal = normalPage?.key == normalRecord.callID
                && normalPageResult?.text.contains("WORKFLOW_BASH_OK_\(nonce)") == true
            try require(report, "workflow.same_stream",
                        sameLoop && sameNormal && pageAssistant,
                        metrics: ["harness_loop_call_id": loopRecord.callID,
                                  "page_loop_call_id": loopPage?.key ?? "",
                                  "harness_normal_call_id": normalRecord.callID,
                                  "page_normal_call_id": normalPage?.key ?? "",
                                  "page_assistant_markers": pageAssistant,
                                  "page_loop_final_marker": pageLoopFinal],
                        detail: "the harness event stream and session/page carry the same two workflow callIds and "
                            + "results, so the result came from the same Worker Session, not a parallel execution path")

            // MARK: Official workflow run-end records
            let loopRun = page.workflowRuns.values.first {
                $0.name == "worker-loop-\(nonce)"
            }
            let normalRun = page.workflowRuns.values.first {
                $0.name == "worker-bash-probe-\(nonce)"
            }
            let loopStopReason = loopRun?.stopReason ?? ""
            let normalStopReason = normalRun?.stopReason ?? ""
            try require(report, "workflow.workflow_end",
                        loopStopReason == "error" && normalStopReason == "completed",
                        metrics: ["loop_run_id": loopRun?.runID ?? "",
                                  "loop_stop_reason": loopStopReason,
                                  "normal_run_id": normalRun?.runID ?? "",
                                  "normal_stop_reason": normalStopReason,
                                  "run_count": page.workflowRuns.count],
                        detail: "the official tool-workflow plugin's session records pair the deadline run with "
                            + "stopReason=error and the next ordinary run with stopReason=completed, so the isolate "
                            + "termination is not inferred from the deadline text alone")

            // MARK: Real-host model boundary
            let observations = model.observations
            let hostInjected = observations.allSatisfy {
                $0.apiKey == Self.hostAPIKey && $0.apiKey != Self.workerPlaceholderKey
            }
            try require(report, "workflow.model_boundary",
                        observations.count >= 4 && hostInjected,
                        metrics: ["requests": observations.count,
                                  "host_key_injected": hostInjected,
                                  "worker_placeholder_seen": observations.contains {
                                      $0.apiKey == Self.workerPlaceholderKey
                                  }],
                        detail: "the scripted Messages endpoint received only the host-injected dummy key; the Worker "
                            + "placeholder key never reached the upstream. Only model tool choices are scripted")
            report.record("worker.workflow.real_model_api", status: .info, gating: false,
                          metrics: ["status": "NOT_RUN"],
                          threshold: simInfoThreshold("worker_workflow_real_model_api"),
                          detail: "NOT_RUN: no real model endpoint or real credential is used")
            report.finish(ok: true)
        } catch {
            failure = error
            // A loop/normal timeout must still say which fixture branch was
            // selected; the gating row below the normal workflow only runs on
            // success.
            report.record("worker.workflow.fixture_selection_at_failure",
                          status: .info, gating: false,
                          metrics: Self.fixtureSelectionMetrics(model.selection),
                          threshold: simInfoThreshold(
                            "worker_workflow_fixture_selection_at_failure"),
                          detail: "non-gating snapshot of the scripted model branches selected when the "
                              + "workflow acceptance failed")
            let failureText = redactor.redact(String(describing: error), limit: 4096)
            report.finish(ok: false, failure: failureText)
            let console = host?.eventLog.console ?? []
            report.record("worker.workflow.failure", status: .fail, gating: true,
                          metrics: ["error": redactor.redact(String(describing: error), limit: 512)],
                          threshold: simG1Threshold("g1_worker_workflow_completed", measured: 0),
                          detail: failureText)
            report.set("failure_console", Self.relevantConsole(console, nonce: nonce,
                                                               redactor: redactor))
        }

        if let host { await host.stop(redactingWith: redactor) }
        model.stop()
        try? report.write()
        if let failure {
            let tail = Self.redactedTail(host?.eventLog.tail(50) ?? [],
                                         redactor: redactor, limit: 50)
            XCTFail("iOS Simulator workflow acceptance failed: "
                + "\(redactor.redact(String(describing: failure), limit: 4096))\n"
                + "--- last 50 console lines ---\n\(tail.joined(separator: "\n"))\n"
                + "--- report: \(report.fileURL.path) ---")
        }
    }

    // MARK: - Fixture selection regression

    /// Pure fixture regression using the real Messages wire shape and order:
    /// the actual user text, agent instructions, runtime context and trailing
    /// time context arrive as separate user messages. The selection must follow
    /// the explicit per-turn marker, including when another message mentions
    /// "loop", and child requests must never inherit the parent phase. The
    /// result stage is then fed the fixture's actual `tool_use.input` (with
    /// `meta.name` and the script child marker) so a workflow result returns
    /// `LOOP_TERMINATED` or `WORKFLOW_DONE` instead of falling through.
    func testCapabilityModelFixtureSelectsRealUserPhase() throws {
        let nonce = "select-\(UUID().uuidString.prefix(8))"
        let model = CapabilityModelFixture(mode: .workflow(nonce: nonce))
        let loopPrompt = "PDSH_PHASE_LOOP_\(nonce) Run the synchronous loop workflow probe."
        let normalPrompt = "PDSH_PHASE_NORMAL_\(nonce) Run the normal workflow probe."

        func text(_ value: String) -> [String: Any] {
            ["type": "text", "text": value]
        }
        func user(_ texts: [String]) -> [String: Any] {
            ["role": "user", "content": texts.map(text)]
        }
        func body(_ messages: [[String: Any]]) -> [String: Any] {
            ["model": "worker-capability", "messages": messages]
        }
        func assistantToolUse(id: String,
                              input: [String: Any]?) -> [String: Any] {
            ["role": "assistant", "content": [
                ["type": "tool_use", "id": id, "name": "workflow",
                 "input": input ?? [String: Any]()],
            ]]
        }
        func toolResult(id: String, text value: String,
                        isError: Bool) -> [String: Any] {
            ["role": "user", "content": [
                ["type": "tool_result", "tool_use_id": id,
                 "content": [text(value)], "is_error": isError],
            ]]
        }

        let loopMessages: [[String: Any]] = [
            user([loopPrompt]),
            user(["agent instructions: a loop workflow may run"]),
            user(["runtime-context: session, cwd and tools"]),
            user(["time-context: current time"]),
        ]
        let normalMessages: [[String: Any]] = [
            user([normalPrompt]),
            user(["agent instructions: a loop workflow may run"]),
            user(["runtime-context: session, cwd and tools"]),
            user(["time-context: current time"]),
        ]

        let loopBody = body(loopMessages)
        let loopTurn = model.plannedTurn(for: loopBody)
        XCTAssertEqual(loopTurn.toolName, "workflow")
        let loopInput = try XCTUnwrap(loopTurn.toolInput)
        XCTAssertEqual((loopInput["meta"] as? [String: Any])?["name"] as? String,
                       "worker-loop-\(nonce)")
        XCTAssertTrue((loopInput["script"] as? String)?
            .contains("WORKFLOW_CHILD_LOOP_\(nonce)") == true)
        XCTAssertTrue(model.selection.sawParentLoop)
        XCTAssertFalse(model.selection.sawParentNormal)

        // Result stage: the real tool_use input above is echoed back with the
        // deadline tool_result. The loop is also a `workflow` result, so this
        // must use the per-run name/script marker rather than treating any
        // workflow result as a normal completion.
        let loopResultBody = body(loopMessages + [
            assistantToolUse(id: "toolu_loop", input: loopInput),
            toolResult(id: "toolu_loop",
                       text: "synchronous execution budget terminated the workflow",
                       isError: true),
        ])
        let loopResultTurn = model.plannedTurn(for: loopResultBody)
        XCTAssertNil(loopResultTurn.toolName)
        XCTAssertEqual(loopResultTurn.text, "LOOP_TERMINATED_\(nonce)")

        let normalBody = body(loopMessages + [
            assistantToolUse(id: "toolu_loop", input: loopInput),
            toolResult(id: "toolu_loop",
                       text: "synchronous execution budget terminated the workflow",
                       isError: true),
        ] + normalMessages)
        let normalTurn = model.plannedTurn(for: normalBody)
        XCTAssertEqual(normalTurn.toolName, "workflow")
        let normalInput = try XCTUnwrap(normalTurn.toolInput)
        XCTAssertEqual((normalInput["meta"] as? [String: Any])?["name"] as? String,
                       "worker-bash-probe-\(nonce)")
        XCTAssertTrue((normalInput["script"] as? String)?
            .contains("WORKFLOW_CHILD_NORMAL_\(nonce)") == true)
        XCTAssertTrue(model.selection.sawParentNormal)

        let normalResultBody = body(loopMessages + [
            assistantToolUse(id: "toolu_loop", input: loopInput),
            toolResult(id: "toolu_loop",
                       text: "synchronous execution budget terminated the workflow",
                       isError: true),
        ] + normalMessages + [
            assistantToolUse(id: "toolu_normal", input: normalInput),
            toolResult(id: "toolu_normal",
                       text: "WORKFLOW_BASH_OK_\(nonce)", isError: false),
        ])
        let normalResultTurn = model.plannedTurn(for: normalResultBody)
        XCTAssertNil(normalResultTurn.toolName)
        XCTAssertEqual(normalResultTurn.text, "WORKFLOW_DONE_\(nonce)")

        // An unknown workflow result is not a normal completion either.
        let unknownResultBody = body(loopMessages + [
            assistantToolUse(id: "toolu_other",
                             input: ["meta": ["name": "worker-other-\(nonce)"] as [String: Any]]),
            toolResult(id: "toolu_other", text: "done", isError: false),
        ])
        let unknownResultTurn = model.plannedTurn(for: unknownResultBody)
        XCTAssertNil(unknownResultTurn.toolName)
        XCTAssertEqual(unknownResultTurn.text, "Waiting for the workflow tool result.")

        let childLoopBody = body([user([
            "WORKFLOW_CHILD_LOOP_\(nonce): write loop-start-\(nonce).txt with the real bash tool",
            "time-context: current time",
        ])])
        XCTAssertEqual(model.plannedToolName(for: childLoopBody), "bash")
        XCTAssertTrue(model.selection.sawChildLoop)

        let childNormalBody = body([user([
            "WORKFLOW_CHILD_NORMAL_\(nonce): write and read workflow-\(nonce).txt with the real bash tool",
            "time-context: current time",
        ])])
        XCTAssertEqual(model.plannedToolName(for: childNormalBody), "bash")
        XCTAssertTrue(model.selection.sawChildNormal)

        // A child request carries the parent loop history as separate user
        // messages, but its own normal marker must still select the child bash
        // branch rather than the parent loop.
        let childNormalAfterParentLoopBody = body(loopMessages + [
            user(["WORKFLOW_CHILD_NORMAL_\(nonce): write and read workflow-\(nonce).txt with the real bash tool"]),
            user(["time-context: current time"]),
        ])
        XCTAssertEqual(model.plannedToolName(for: childNormalAfterParentLoopBody), "bash")
        XCTAssertTrue(model.selection.sawChildNormal)

        let contextOnlyBody = body([user([
            "agent instructions: a loop workflow may run",
            "runtime-context: loop state is not a user turn",
            "time-context: current time",
        ])])
        XCTAssertNil(model.plannedToolName(for: contextOnlyBody))
        XCTAssertGreaterThan(model.selection.undecided, 0)
    }

    /// Host-free MCP fixture regression: GET/SSE and DELETE use the same
    /// credential gate as POST. Missing, env-only and model-key credentials are
    /// rejected with 401 and counted; the host `/mcp` dummy is accepted. This
    /// proves the gate directly even when the bundled client sends no DELETE.
    func testCapabilityMcpFixtureRejectsUnauthenticatedGetAndDelete() {
        let nonce = "fixture-auth-\(UUID().uuidString.prefix(8))"
        let modelKey = "model-key-\(nonce)"
        let fixture = CapabilityMcpFixture(nonce: nonce,
                                           forbiddenAuthorization: "Bearer \(modelKey)")

        func request(_ method: String,
                     _ authorization: String?) -> CapabilityHTTPRequest {
            var headers: [String: String] = [:]
            if let authorization { headers["authorization"] = authorization }
            return CapabilityHTTPRequest(method: method, path: "/mcp",
                                         headers: headers, body: Data())
        }

        // OPTIONS is the only method that may skip the credential gate.
        XCTAssertEqual(fixture.handle(request("OPTIONS", nil)).status, 204)
        XCTAssertEqual(fixture.authenticatedRequestCount, 0)

        for method in ["GET", "DELETE"] {
            XCTAssertEqual(fixture.handle(request(method, nil)).status, 401)
            XCTAssertEqual(fixture.handle(request(method,
                                                  fixture.authorizationValue)).status, 401)
            XCTAssertEqual(fixture.handle(request(method,
                                                  "Bearer \(modelKey)")).status, 401)
        }
        XCTAssertEqual(fixture.deleteRequestCount, 3)
        XCTAssertEqual(fixture.authenticatedDeleteCount, 0)
        XCTAssertTrue(fixture.sawUnauthenticatedDelete)
        XCTAssertTrue(fixture.sawUnauthenticatedGet)
        XCTAssertTrue(fixture.sawEnvOnlyAuthorization)
        XCTAssertTrue(fixture.sawForbiddenAuthorization)
        XCTAssertEqual(fixture.authenticatedRequestCount, 0)

        // The same gate accepts the host `/mcp` credential for both methods.
        XCTAssertEqual(fixture.handle(request("GET",
                                              fixture.hostAuthorizationValue)).status, 405)
        XCTAssertEqual(fixture.handle(request("DELETE",
                                              fixture.hostAuthorizationValue)).status, 200)
        XCTAssertEqual(fixture.authenticatedRequestCount, 2)
        XCTAssertEqual(fixture.authenticatedDeleteCount, 1)
        XCTAssertEqual(fixture.deleteRequestCount, 4)
    }

    // MARK: - MCP acceptance

    func testSimulatorPhoneMCPHTTPToolRegisterListInvokeRemove() async throws {
        let nonce = Self.makeNonce("mcp")
        let directory = try SimEnvironment.reportsDirectory()
        let report = SimSuiteReport(suite: "worker-mcp", gate: "G1", directory: directory,
                                    fileName: "worker-mcp-report.json")
        let serverName = "local-\(nonce)"
        let echoTool = "mcp__\(serverName)__echo"
        let mcp = CapabilityMcpFixture(nonce: nonce,
                                       forbiddenAuthorization: "Bearer \(Self.hostAPIKey)")
        let model = CapabilityModelFixture(
            mode: .mcp(nonce: nonce, toolName: echoTool, message: "MCP_ECHO_\(nonce)"))
        let redactor = CapabilityRedactor([mcp.authorizationValue,
                                           mcp.environmentTokenValue,
                                           mcp.hostAuthorizationValue,
                                           mcp.tokenValue,
                                           Self.hostAPIKey,
                                           "Bearer \(Self.hostAPIKey)",
                                           Self.workerPlaceholderKey,
                                           "Bearer \(Self.workerPlaceholderKey)"])
        var host: CapabilityTestHost?
        var failure: Error?

        do {
            report.set("nonce", nonce)
            let mcpURL = try mcp.start()
            report.set("mcp_url", mcpURL.absoluteString)
            let modelURL = try model.start()
            report.set("model_url", modelURL.absoluteString)
            let testHost = try CapabilityTestHost(nonce: nonce, report: report)
            host = testHost
            let mcpPort = mcpURL.port ?? 0
            try await testHost.boot(modelURL: modelURL,
                                    modelName: Self.modelName,
                                    environmentExtra: [
                                        "PDSH_TEST_MCP_TOKEN": mcp.authorizationValue,
                                    ],
                                    egressHosts: ["http://127.0.0.1:\(mcpPort)"],
                                    extraCredentials: [
                                        // Match the gateway's actual full scope: the
                                        // scheme, host, explicit port and normalized
                                        // path of this run's endpoint. A host/path-only
                                        // key is shadowed by the model's host fallback
                                        // in StaticCredentialProvider, so the fixture
                                        // would receive the model key and answer 401.
                                        CredentialScope(service: mcpURL.host?.lowercased() ?? "",
                                                        audience: mcpURL.path,
                                                        scheme: mcpURL.scheme?.lowercased(),
                                                        port: mcpURL.port):
                                            Credential(kind: .bearer, value: mcp.tokenValue),
                                    ])
            guard let transport = testHost.transport else {
                throw SimError.assertion("the host did not publish a DSH Remote transport")
            }

            // MARK: phone-mcp service exists and the registry starts empty
            let initialList = try await Self.phoneMcpCall(
                transport: transport, "phone/mcpList", args: .object([:]),
                report: report, redactor: redactor)
            let initialServers = initialList["servers"]?.arrayValue ?? []
            let configFile = initialList["file"]?.stringValue ?? ""
            let initialError = initialList["error"]?.stringValue ?? ""
            try require(report, "mcp.service",
                        configFile == "/dsh/home/mcp.json"
                            && initialServers.isEmpty
                            && initialError.isEmpty,
                        metrics: ["config_file": configFile,
                                  "initial_servers": initialServers.count,
                                  "initial_error": redactor.redact(initialError, limit: 256)],
                        detail: "the real phone-mcp Remote answered from the WebWorker (no Node substitute) and its "
                            + "registry started empty at /dsh/home/mcp.json")

            // MARK: register + list
            let upsert = try await Self.phoneMcpCall(
                transport: transport, "phone/mcpUpsert",
                args: .object(["request": .object([
                    "serverName": .string(serverName),
                    "url": .string(mcpURL.absoluteString),
                    "headersFromEnv": .object(["Authorization": .string("PDSH_TEST_MCP_TOKEN")]),
                    "enabled": .bool(true),
                    "toolCallTimeoutMs": .number(5000),
                ])]),
                report: report, redactor: redactor)
            let registeredTools = (upsert["tools"]?.arrayValue ?? []).compactMap(\.stringValue)
            let expectedTools = ["mcp__\(serverName)__echo", "mcp__\(serverName)__ping"]
            try require(report, "mcp.register",
                        upsert["status"]?.stringValue == "connected"
                            && registeredTools == expectedTools
                            && upsert["authentication"]?.stringValue == "headers-env",
                        metrics: ["status": upsert["status"]?.stringValue ?? "",
                                  "tools": registeredTools.joined(separator: ","),
                                  "authentication": upsert["authentication"]?.stringValue ?? ""],
                        detail: "phone/mcpUpsert mounted the real Streamable HTTP fixture and published its exact "
                            + "ToolRuntime names; a failed mount would have left no row")

            let listed = try await Self.phoneMcpCall(
                transport: transport, "phone/mcpList", args: .object([:]),
                report: report, redactor: redactor)
            let listedRow = (listed["servers"]?.arrayValue ?? []).first {
                $0["serverName"]?.stringValue == serverName
            }
            let listedTools = (listedRow?["tools"]?.arrayValue ?? []).compactMap(\.stringValue)
            try require(report, "mcp.list",
                        listedRow?["status"]?.stringValue == "connected"
                            && listedTools == expectedTools,
                        metrics: ["status": listedRow?["status"]?.stringValue ?? "",
                                  "tools": listedTools.joined(separator: ","),
                                  "servers": listed["servers"]?.arrayValue?.count ?? 0],
                        detail: "phone/mcpList reports the live mount and its real tool registrations")

            let inventoryBefore = try await transport.call("phone/listTools", args: .object([:]))
            let toolNamesBefore = Self.toolNames(inventoryBefore)
            try require(report, "mcp.inventory",
                        toolNamesBefore.contains(echoTool)
                            && toolNamesBefore.contains("mcp__\(serverName)__ping"),
                        metrics: ["tool_count": toolNamesBefore.count,
                                  "echo_present": toolNamesBefore.contains(echoTool),
                                  "ping_present": toolNamesBefore.contains("mcp__\(serverName)__ping")],
                        detail: "the global ToolRuntime inventory shows the exact MCP names before the model call")

            // MARK: invoke through the real model tool dispatch
            let agent = try await testHost.hostHarness()
            let session: HarnessSession
            do {
                session = try await agent.openSession(
                    HarnessSessionRequest(preset: "standard", workspace: "/dsh/workspace"))
            } catch {
                let diagnostic = await Self.rawSessionCreateDiagnostic(transport: transport,
                                                                        redactor: redactor)
                report.set("session_create_error", diagnostic)
                throw SimError.assertion("standard session/create failed: "
                    + "\(redactor.redact(String(describing: error))); \(diagnostic)")
            }
            testHost.eventLog.attach(harness: agent, sessionID: session.id)
            report.set("session_id", session.id)
            let prompt = "PDSH_PHASE_MCP_\(nonce) Call the registered MCP echo tool with MCP_ECHO_\(nonce)."
            try await agent.send(
                .prompt(text: prompt, attachments: [], requestID: "mcp-\(nonce)"),
                to: session.id)
            try await simWait(timeout: 180, label: "MCP tool result") {
                let calls = mcp.toolCalls
                let records = Self.toolRecords(from: testHost.eventLog.harnessEvents)
                guard let record = records.first(where: { $0.name == echoTool }),
                      let result = record.result else { return false }
                return calls.contains { $0.name == "echo" && $0.message == "MCP_ECHO_\(nonce)" }
                    && !result.isError
                    && result.text.contains("echo:MCP_ECHO_\(nonce)")
                    && Self.assistantTexts(in: testHost.eventLog.harnessEvents)
                        .contains { $0.contains("MCP_DONE_\(nonce)") }
            }
            let records = Self.toolRecords(from: testHost.eventLog.harnessEvents)
            guard let mcpRecord = records.first(where: { $0.name == echoTool }),
                  let mcpResult = mcpRecord.result else {
                throw SimError.artifact("the parent Session has no MCP tool call/result")
            }
            let calls = mcp.toolCalls
            try require(report, "mcp.tool_invoke",
                        !mcpResult.isError
                            && mcpResult.text.contains("echo:MCP_ECHO_\(nonce)")
                            && calls.contains { $0.name == "echo" && $0.message == "MCP_ECHO_\(nonce)" },
                        metrics: ["call_id": mcpRecord.callID,
                                  "is_error": mcpResult.isError,
                                  "fixture_echo_calls": calls.filter { $0.name == "echo" }.count,
                                  "result_text": redactor.redact(mcpResult.text, limit: 256)],
                        detail: "the model's real mcp__…__echo tool call reached the local MCP JSON-RPC fixture and its "
                            + "echo result came back into the same parent Session")

            // MARK: Same Worker stream and real JSON-RPC sequence
            let lastSeq = testHost.eventLog.harnessEvents.compactMap(\.seq).max()
                .map { Int($0 / 8) } ?? 100
            let page = try await Self.sessionPage(transport: transport,
                                                  sessionID: session.id,
                                                  throughSeq: lastSeq)
            let pageCall = page.toolCalls.first { $0.value.name == echoTool }
            let pageResult = pageCall.flatMap { page.toolResults[$0.key] }
            let pageAssistant = page.assistantTexts.contains { $0.contains("MCP_DONE_\(nonce)") }
            let methods = mcp.requestMethods
            let initializeIndex = methods.firstIndex(of: "initialize")
            let listIndex = methods.firstIndex(of: "tools/list")
            let callIndex = methods.firstIndex(of: "tools/call")
            let rpcSequence: Bool
            if let initializeIndex, let listIndex, let callIndex {
                rpcSequence = initializeIndex < listIndex && listIndex < callIndex
            } else {
                rpcSequence = false
            }
            try require(report, "mcp.same_stream",
                        pageCall?.key == mcpRecord.callID
                            && pageResult?.text.contains("echo:MCP_ECHO_\(nonce)") == true
                            && pageAssistant
                            && rpcSequence,
                        metrics: ["harness_call_id": mcpRecord.callID,
                                  "page_call_id": pageCall?.key ?? "",
                                  "rpc_methods": methods.joined(separator: ","),
                                  "initialize_index": initializeIndex ?? -1,
                                  "tools_list_index": listIndex ?? -1,
                                  "tools_call_index": callIndex ?? -1,
                                  "page_assistant": pageAssistant],
                        detail: "the harness stream and session/page carry the same MCP callId/result, and the local "
                            + "fixture observed initialize → tools/list → tools/call")

            // MARK: remove + clear
            _ = try await Self.phoneMcpCall(
                transport: transport, "phone/mcpRemove",
                args: .object(["request": .object(["serverName": .string(serverName)])]),
                report: report, redactor: redactor)
            let afterRemove = try await Self.phoneMcpCall(
                transport: transport, "phone/mcpList", args: .object([:]),
                report: report, redactor: redactor)
            let remaining = afterRemove["servers"]?.arrayValue ?? []
            let inventoryAfter = try await transport.call("phone/listTools", args: .object([:]))
            let toolNamesAfter = Self.toolNames(inventoryAfter)
            // Remove must not be provable by a local list alone when the
            // remote operation bypassed the host credential. The fixture now
            // gates GET/DELETE exactly like POST, so any DELETE it received is
            // host-authenticated; an env-only/model-key or missing credential
            // is rejected with 401 and recorded as an unauthenticated DELETE.
            let authenticatedDeletes = mcp.authenticatedDeleteCount
            let deleteRequests = mcp.deleteRequestCount
            let unauthenticatedDelete = mcp.sawUnauthenticatedDelete
            let unauthenticatedGet = mcp.sawUnauthenticatedGet
            let removeDetail = authenticatedDeletes > 0
                ? "phone/mcpRemove left no persisted row and removed both real ToolRuntime "
                    + "registrations; every DELETE the fixture received was counted against the host "
                    + "/mcp credential (delete_requests == authenticated_delete_requests), so the "
                    + "remote session-termination request used the host credential"
                : "phone/mcpRemove left no persisted row and removed both real ToolRuntime "
                    + "registrations; the bundled client sent no DELETE, so remote session termination "
                    + "stays NOT_RUN (see worker.mcp.remote_session_terminated) and is not inferred from "
                    + "the empty local registry. The fixture still rejected every unauthenticated "
                    + "GET/DELETE, and no env-only/model-key credential was accepted"
            try require(report, "mcp.remove",
                        remaining.isEmpty
                            && !toolNamesAfter.contains(echoTool)
                            && !toolNamesAfter.contains("mcp__\(serverName)__ping")
                            && deleteRequests == authenticatedDeletes
                            && !unauthenticatedDelete
                            && !unauthenticatedGet
                            && !mcp.sawForbiddenAuthorization
                            && !mcp.sawEnvOnlyAuthorization,
                        metrics: ["servers_after_remove": remaining.count,
                                  "echo_still_registered": toolNamesAfter.contains(echoTool),
                                  "ping_still_registered": toolNamesAfter.contains("mcp__\(serverName)__ping"),
                                  "delete_requests": deleteRequests,
                                  "authenticated_delete_requests": authenticatedDeletes,
                                  "unauthenticated_delete_seen": unauthenticatedDelete,
                                  "unauthenticated_get_seen": unauthenticatedGet,
                                  "model_key_seen_by_mcp": mcp.sawForbiddenAuthorization,
                                  "env_only_authorization_seen": mcp.sawEnvOnlyAuthorization],
                        detail: removeDetail)
            // Do not infer remote session termination from a local list of 0.
            report.record("worker.mcp.remote_session_terminated", status: .info, gating: false,
                          metrics: ["status": authenticatedDeletes > 0 ? "observed" : "NOT_RUN",
                                    "authenticated_delete_requests": authenticatedDeletes],
                          threshold: simInfoThreshold("worker_mcp_remote_session_terminated"),
                          detail: authenticatedDeletes > 0
                              ? "the fixture received a host-authenticated DELETE, which is the remote "
                                  + "Streamable HTTP session-termination request"
                              : "NOT_RUN: the bundled MCP client closes the Streamable HTTP transport without "
                                  + "calling terminateSession, so the fixture observed no DELETE. This report does "
                                  + "not claim remote session termination from the empty local registry")

            // MARK: Key and console boundaries
            let observations = model.observations
            let hostInjected = observations.allSatisfy { $0.apiKey == Self.hostAPIKey }
            let envOnlySeen = mcp.sawEnvOnlyAuthorization
            let distinctDummies = mcp.authorizationValue != mcp.hostAuthorizationValue
            let noMixedKey = !mcp.sawForbiddenAuthorization
                && !envOnlySeen
                && distinctDummies
                && mcp.authenticatedRequestCount > 0
                && observations.count >= 2
                && hostInjected
            try require(report, "mcp.key_boundary",
                        noMixedKey,
                        metrics: ["model_requests": observations.count,
                                  "model_key_injected": hostInjected,
                                  "mcp_authenticated_requests": mcp.authenticatedRequestCount,
                                  "model_key_seen_by_mcp": mcp.sawForbiddenAuthorization,
                                  "env_only_authorization_seen": envOnlySeen,
                                  "distinct_env_host_dummies": distinctDummies,
                                  "env_token_configured": !mcp.environmentTokenValue.isEmpty,
                                  "host_credential_configured": !mcp.tokenValue.isEmpty],
                        detail: "the fixture accepted at least one request with the host /mcp credential injected "
                            + "by the host /v1/http egress; the different env-only dummy and the model-gateway key "
                            + "never reached it, so a direct Worker fetch cannot satisfy this row")
            let console = testHost.eventLog.console
            let warnings = Self.relevantConsole(console, nonce: nonce, redactor: redactor)
            report.set("mcp_console", warnings)
            report.set("mcp_rpc_methods", methods)
            let importFailure = console.contains { line in
                let text = line.text
                return text.contains("global is not defined")
                    || (text.contains("phone-mcp") && (text.contains("failed to import")
                        || text.contains("not implemented")))
            }
            try require(report, "mcp.console",
                        !importFailure,
                        metrics: ["console_count": console.count,
                                  "relevant_lines": warnings.count,
                                  "import_failure": importFailure],
                        detail: "the Worker console carries no phone-mcp import/JSC failure; bounded warning lines are "
                            + "recorded in mcp_console for diagnosis")
            report.record("worker.mcp.real_external_server", status: .info, gating: false,
                          metrics: ["status": "NOT_RUN"],
                          threshold: simInfoThreshold("worker_mcp_real_external_server"),
                          detail: "NOT_RUN: the fixture is a local 127.0.0.1 Streamable HTTP MCP server; no real "
                              + "external MCP endpoint or real key is used")
            report.record("worker.mcp.node_substitute", status: .info, gating: false,
                          metrics: ["status": "NOT_RUN"],
                          threshold: simInfoThreshold("worker_mcp_node_substitute"),
                          detail: "NOT_RUN: this result is from a real WKWebView WebWorker on the iOS Simulator, "
                              + "not the Node phone-mcp test")
            report.finish(ok: true)
        } catch {
            failure = error
            let failureText = redactor.redact(String(describing: error), limit: 4096)
            report.finish(ok: false, failure: failureText)
            let console = host?.eventLog.console ?? []
            let diagnostic = Self.mcpDiagnostic(error, console: console, redactor: redactor)
            report.set("mcp_failure_diagnostic", diagnostic)
            let failureName = (diagnostic["name"] as? String) ?? "Error"
            let failureMessage = (diagnostic["message"] as? String) ?? ""
            report.record("worker.mcp.failure", status: .fail, gating: true,
                          metrics: ["name": failureName,
                                    "message": failureMessage],
                          threshold: simG1Threshold("g1_worker_mcp_completed", measured: 0),
                          detail: "phone-mcp/iOS WebWorker failure; bounded name/message/stack and console warnings "
                              + "are in mcp_failure_diagnostic")
            report.set("failure_console", Self.relevantConsole(console, nonce: nonce,
                                                               redactor: redactor))
        }

        if let host { await host.stop(redactingWith: redactor) }
        mcp.stop()
        model.stop()
        try? report.write()
        if let failure {
            let tail = Self.redactedTail(host?.eventLog.tail(50) ?? [],
                                         redactor: redactor, limit: 50)
            XCTFail("iOS Simulator MCP acceptance failed: "
                + "\(redactor.redact(String(describing: failure), limit: 4096))\n"
                + "--- last 50 console lines ---\n\(tail.joined(separator: "\n"))\n"
                + "--- report: \(report.fileURL.path) ---")
        }
    }

    // MARK: - Helpers

    @discardableResult
    private func require(_ report: SimSuiteReport,
                         _ probe: String,
                         _ passed: Bool,
                         metrics: [String: Any] = [:],
                         detail: String) throws -> Bool {
        report.record("worker.\(probe)",
                      status: passed ? .pass : .fail, gating: true,
                      metrics: metrics,
                      threshold: simG1Threshold("g1_worker_\(probe.replacingOccurrences(of: ".", with: "_"))",
                                                measured: passed ? 1 : 0),
                      detail: detail)
        if !passed { throw SimError.assertion(detail) }
        return passed
    }

    static func makeNonce(_ prefix: String) -> String {
        let value = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return "\(prefix)\(value.prefix(10))"
    }

    /// Non-gating fixture-selection snapshot. The final
    /// `workflow.fixture_selection` row stays gating; these rows exist so a
    /// loop/normal timeout still records which branch the request actually
    /// selected before the test fails.
    private static func fixtureSelectionMetrics(_ selection: CapabilityModelSelection)
        -> [String: Any] {
        [
            "parent_loop_selected": selection.sawParentLoop,
            "parent_normal_selected": selection.sawParentNormal,
            "child_loop_selected": selection.sawChildLoop,
            "child_normal_selected": selection.sawChildNormal,
            "mcp_selected": selection.sawMCP,
            "undecided_requests": selection.undecided,
        ]
    }

    private static func rawSessionCreateDiagnostic(transport: any DSHRemoteTransport,
                                                   redactor: CapabilityRedactor) async -> String {
        do {
            let value = try await transport.call(
                "session/create",
                args: .object(["request": .object([
                    "cwd": .string("/dsh/workspace"),
                    "agentPreset": .string("standard"),
                ])]))
            return redactor.redact("raw session/create unexpectedly succeeded: \(value)", limit: 1024)
        } catch let error as DSHRemoteError {
            return redactor.redact("raw session/create error \(error.code): \(error.message)",
                                   limit: 512)
        } catch {
            return redactor.redact("raw session/create error: \(String(describing: error))",
                                   limit: 512)
        }
    }

    /// Bound and redact one console tail. The same redactor is used for the
    /// report's `console_last_50`, failure detail and XCTest message.
    private static func redactedTail(_ lines: [String],
                                     redactor: CapabilityRedactor,
                                     limit: Int) -> [String] {
        lines.suffix(max(0, limit)).map { redactor.redact($0) }
    }

    static func toolNames(_ inventory: JSONValue) -> [String] {
        (inventory["tools"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue }
    }

    // MARK: - Tool events

    struct ToolResultEvidence {
        let isError: Bool
        let text: String
    }

    struct ToolCallEvidence {
        let callID: String
        let name: String
        let arguments: String
        let result: ToolResultEvidence?
    }

    static func toolRecords(from events: [HarnessEvent]) -> [ToolCallEvidence] {
        var calls: [String: (name: String, arguments: String)] = [:]
        var order: [String] = []
        var results: [String: ToolResultEvidence] = [:]
        for event in events {
            switch event.kind {
            case .toolCall(let callID, let name, let arguments):
                let text = (try? arguments.encoded())
                    .flatMap { String(data: $0, encoding: .utf8) } ?? ""
                if calls[callID] == nil { order.append(callID) }
                calls[callID] = (name, text)
            case .toolResult(let callID, let isError, let summary):
                results[callID] = ToolResultEvidence(
                    isError: isError,
                    text: event.toolResultDetail?.text ?? summary)
            default:
                break
            }
        }
        return order.compactMap { callID in
            guard let call = calls[callID] else { return nil }
            return ToolCallEvidence(callID: callID, name: call.name,
                                    arguments: call.arguments, result: results[callID])
        }
    }

    static func assistantTexts(in events: [HarnessEvent]) -> [String] {
        events.compactMap { event in
            if case .assistantMessage(let text) = event.kind { return text }
            return nil
        }
    }

    private static func hasTurnEnded(in events: [HarnessEvent]) -> Bool {
        events.contains { event in
            if case .turnEnded = event.kind { return true }
            return false
        }
    }

    // MARK: - session/page

    struct PageCall {
        let name: String
        let arguments: String
        let seq: Int
    }

    struct PageResult {
        let text: String
        let isError: Bool
        let seq: Int
    }

    struct PageRun {
        let runID: String
        var name = ""
        var stopReason: String?
    }

    struct PageEvidence {
        var toolCalls: [String: PageCall] = [:]
        var toolResults: [String: PageResult] = [:]
        var assistantTexts: [String] = []
        /// `tool-workflow/run-start` + `tool-workflow/run-end` records from the
        /// official workflow tool plugin, keyed by run id.
        var workflowRuns: [String: PageRun] = [:]
    }

    static func sessionPage(transport: any DSHRemoteTransport,
                                    sessionID: String,
                                    throughSeq: Int) async throws -> PageEvidence {
        let value = try await transport.call(
            "session/page",
            args: .object(["request": .object([
                "address": .object(["kind": .string("session"),
                                    "sessionId": .string(sessionID)]),
                "throughSeq": .number(Double(max(0, throughSeq))),
                "maxMessages": .number(500),
            ])]))
        var page = PageEvidence()
        for record in value["records"]?.arrayValue ?? [] {
            let event = record["event"] ?? record
            guard let type = event["type"]?.stringValue,
                  let data = event["data"]?.objectValue else { continue }
            let seq = event["seq"]?.intValue ?? 0
            switch type {
            case "tool/call":
                let callID = data["callId"]?.stringValue ?? ""
                guard !callID.isEmpty else { continue }
                page.toolCalls[callID] = PageCall(
                    name: data["name"]?.stringValue ?? "",
                    arguments: data["arguments"]?.stringValue ?? "",
                    seq: seq)
            case "tool/result":
                let message = data["message"] ?? .null
                let callID = message["toolCallId"]?.stringValue
                    ?? message["source"]?["callId"]?.stringValue ?? ""
                guard !callID.isEmpty else { continue }
                page.toolResults[callID] = PageResult(
                    text: contentText(message["content"]),
                    isError: message["isError"]?.boolValue ?? (data["error"] != nil),
                    seq: seq)
            case "assistant/message":
                let text = contentText(data["message"]?["content"])
                if !text.isEmpty { page.assistantTexts.append(text) }
            case "tool-workflow/run-start":
                let runID = data["runId"]?.stringValue ?? ""
                guard !runID.isEmpty else { continue }
                var run = page.workflowRuns[runID] ?? PageRun(runID: runID)
                run.name = data["name"]?.stringValue ?? ""
                page.workflowRuns[runID] = run
            case "tool-workflow/run-end":
                let runID = data["runId"]?.stringValue ?? ""
                guard !runID.isEmpty else { continue }
                var run = page.workflowRuns[runID] ?? PageRun(runID: runID)
                run.stopReason = data["stopReason"]?.stringValue
                page.workflowRuns[runID] = run
            default:
                break
            }
        }
        return page
    }

    private static func contentText(_ content: JSONValue?) -> String {
        (content?.arrayValue ?? []).compactMap { block in
            block["type"]?.stringValue == "text" ? block["text"]?.stringValue : nil
        }.joined()
    }

    // MARK: - phone/mcp diagnostics

    static func phoneMcpCall(transport: any DSHRemoteTransport,
                                     _ endpoint: String,
                                     args: JSONValue,
                                     report: SimSuiteReport,
                                     redactor: CapabilityRedactor) async throws -> JSONValue {
        do {
            return try await transport.call(endpoint, args: args)
        } catch {
            let diagnostic = mcpDiagnostic(error, console: [], redactor: redactor)
            report.set("\(endpoint.replacingOccurrences(of: "/", with: "_"))_error", diagnostic)
            throw error
        }
    }

    static func mcpDiagnostic(_ error: Error,
                                      console: [SimConsoleLine],
                                      redactor: CapabilityRedactor) -> [String: Any] {
        let typeName = String(reflecting: type(of: error))
        var message = String(describing: error)
        var name = typeName
        if let remote = error as? DSHRemoteError {
            name = "DSHRemoteError"
            message = "\(remote.code): \(remote.message)"
        }
        let relevant = relevantConsole(console, nonce: "", redactor: redactor)
        return [
            "name": redactor.redact(name, limit: 1024),
            "message": redactor.redact(message, limit: 1024),
            "stack": redactor.redact(Thread.callStackSymbols.prefix(8).joined(separator: "\n"),
                                     limit: 1024),
            "console_warnings": relevant,
            "console_warning_count": relevant.count,
            "jsc_import_failure_seen": console.contains {
                $0.text.contains("global is not defined")
                    || ($0.text.contains("phone-mcp") && ($0.text.contains("failed to import")
                        || $0.text.contains("not implemented")))
            },
        ]
    }

    static func relevantConsole(_ lines: [SimConsoleLine],
                                        nonce: String,
                                        redactor: CapabilityRedactor) -> [[String: String]] {
        let markers = ["phone-mcp", "mcp", "workflow", "global is not defined",
                       "failed to import", "not implemented", nonce]
        return lines.filter { line in
            let text = line.text.lowercased()
            return line.level == "warning" || line.level == "error"
                || markers.contains { !$0.isEmpty && text.contains($0.lowercased()) }
        }.suffix(8).map { line in
            let text = redactor.redact(line.text)
            let (parsedName, parsedMessage) = consoleNameAndMessage(text)
            return ["name": "console.\(line.level).\(parsedName)",
                    "message": redactor.redact(parsedMessage, limit: 512)]
        }
    }

    /// Preserve a leading `Name: message` pair from a Worker console line when
    /// JavaScriptCore/WebKit did not provide a structured Error object.
    private static func consoleNameAndMessage(_ text: String) -> (String, String) {
        guard let separator = text.range(of: ": ") else { return ("console", text) }
        let candidate = String(text[..<separator.lowerBound])
        guard !candidate.isEmpty, candidate.count <= 80,
              !candidate.contains(" "), !candidate.contains("\n") else {
            return ("console", text)
        }
        return (candidate, String(text[separator.upperBound...]))
    }
}

// MARK: - Host assembly

/// One real WKWebView + PhoneDSHHost boot for a capability test. It reuses the
/// App's complete-Web factory; it does not build a parallel host or persistence
/// implementation.
@MainActor
final class CapabilityTestHost {
    let nonce: String
    let report: SimSuiteReport
    let eventLog = SimSmokeEventLog()
    let workspace: URL
    /// The Streamable HTTP suite keeps its bounded console tail in the report.
    /// The SSE-response suite passes `false` because its report carries only
    /// redacted booleans/counts/hashes (no raw console text).
    private let recordsConsoleTail: Bool
    /// The SSE-response suite also suppresses the private host roots/ports. The
    /// existing Streamable HTTP report keeps them; its evidence contract is not
    /// changed by this test-only option.
    private let reportHostDetails: Bool
    private let bundle: PhoneDSHBundleLocation
    private(set) var host: PhoneDSHHost?
    private(set) var engine: WebEngine?
    /// Engine the factory published during `boot()`, kept as the startup
    /// identity so a later factory call cannot reset the comparison baseline.
    private(set) var bootPublishedEngine: WebEngine?
    private(set) var transport: (any DSHRemoteTransport)?
    private var window: SimVisibleWindow?
    private var slot = CapabilityEngineSlot()

    init(nonce: String, report: SimSuiteReport,
         recordsConsoleTail: Bool = true,
         reportHostDetails: Bool = true) throws {
        self.nonce = nonce
        self.report = report
        self.recordsConsoleTail = recordsConsoleTail
        self.reportHostDetails = reportHostDetails
        guard let container = SimEnvironment.appDataContainer() else {
            throw SimError.environment(
                "the probe app data container is missing; scripts/ci/sim.sh installs it first")
        }
        let documents = container.appendingPathComponent("Documents", isDirectory: true)
        let workspace = documents.appendingPathComponent(
            "chat-host-capability-\(nonce)", isDirectory: true)
        if FileManager.default.fileExists(atPath: workspace.path) {
            throw SimError.environment(
                "the unique capability workspace already exists: \(workspace.path)")
        }
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        self.workspace = workspace
        let bundle = try SimEnvironment.workerBundle()
        self.bundle = bundle
        let page = bundle.staticDirectory.appendingPathComponent("web/index.html")
        if reportHostDetails {
            report.set("app_container", container.path)
            report.set("workspace_root", workspace.path)
            report.set("worker_static_directory", bundle.staticDirectory.path)
            report.set("worker_image", bundle.imageArchive.path)
            report.set("page_path", PhoneDSHWorkerCapabilityTests.fullPagePath)
        }
        if !FileManager.default.fileExists(atPath: page.path) {
            throw SimError.environment(
                "the complete Web page is missing at \(page.path); the Web bundle group "
                + "has not staged Bundle/worker/web yet")
        }
    }

    func boot(modelURL: URL,
              modelName: String,
              environmentExtra: [String: String],
              egressHosts: Set<String> = [],
              extraCredentials: [CredentialScope: Credential] = [:]) async throws {
        let visibleWindow = SimVisibleWindow(size: CGSize(width: 430, height: 932))
        window = visibleWindow
        guard visibleWindow.isAttached else {
            throw SimError.assertion("the full-Web window anchor is not attached")
        }
        let anchor = VisibleEngineAnchor()
        visibleWindow.anchor.addSubview(anchor.view)
        visibleWindow.window.layoutIfNeeded()
        guard anchor.isInWindow else {
            throw SimError.assertion("the WebEngine anchor is not in the window")
        }
        let fixedPort = WebHostConfiguration.freeLoopbackPort()
        var credentials: [CredentialScope: Credential] = [
            CredentialScope(service: "127.0.0.1"):
                Credential(kind: .apiKey(header: "x-api-key"),
                           value: PhoneDSHWorkerCapabilityTests.hostAPIKey),
        ]
        for (scope, credential) in extraCredentials {
            credentials[scope] = credential
        }
        let assembly = WebHostConfiguration.make(
            workspaceRoot: workspace,
            bundle: bundle,
            modelURL: modelURL,
            modelName: modelName,
            credentialProvider: StaticCredentialProvider(credentials),
            egressHosts: egressHosts,
            loopbackPort: fixedPort,
            workerPlaceholderKey: PhoneDSHWorkerCapabilityTests.workerPlaceholderKey,
            pagePath: PhoneDSHWorkerCapabilityTests.fullPagePath,
            drainDeadline: 5,
            helloTimeout: 240)
        var configuration = assembly.configuration
        configuration.engine.visibleAreaPoints = 430
        for (name, value) in environmentExtra {
            configuration.engine.environment[name] = value
        }
        let hostAssembly: [String: Any] = [
            "page_path": configuration.engine.pagePath,
            "persistent_store": configuration.engine.usesPersistentWebsiteDataStore,
            "loopback_port": Int(configuration.loopback.port),
            "origin": configuration.engine.origin.absoluteString,
            "exec_provider": configuration.execProvider != nil,
            "accelerator_names": configuration.acceleratorNames,
            "extra_environment_names": environmentExtra.keys.sorted(),
            "egress_hosts": configuration.egressAllowHosts.sorted(),
        ]
        if reportHostDetails {
            report.set("host_assembly", hostAssembly)
            report.set("configured_page_path", configuration.engine.pagePath)
        } else {
            report.set("host_assembly_checked", [
                "persistent_store": configuration.engine.usesPersistentWebsiteDataStore,
                "exec_provider": configuration.execProvider != nil,
                "accelerator_count": configuration.acceleratorNames.count,
                "egress_host_count": configuration.egressAllowHosts.count,
            ])
        }
        guard fixedPort != 0,
              configuration.engine.pagePath == PhoneDSHWorkerCapabilityTests.fullPagePath,
              configuration.loopback.port == fixedPort else {
            throw SimError.assertion(
                "the complete-Web host assembly did not use the fixed loopback origin and page")
        }

        let slot = CapabilityEngineSlot()
        self.slot = slot
        let host = PhoneDSHHost(
            configuration: configuration,
            engineFactory: WebHostConfiguration.engineFactory(anchor: anchor) { engine in
                slot.publish(engine)
            })
        self.host = host
        eventLog.attach(host: host)
        try await host.start()
        try await simWait(timeout: 240, label: "host Running") {
            await host.state == .running
        }
        guard let engine = slot.engine else {
            throw SimError.assertion("the host did not create a WebEngine")
        }
        self.engine = engine
        self.bootPublishedEngine = slot.engine
        guard engine.isAttachedWithVisibleArea else {
            throw SimError.assertion("the WKWebView is not attached with a visible area")
        }
        try await simWait(timeout: 240, label: "full Web page bootReady") {
            engine.lastBootStatus?.state == .ready
        }
        let transport = try await host.makeTransport()
        self.transport = transport
        // The page's first-use baseline needs the same existing directory the
        // App registers. This creates no Session; the capability test creates
        // its own Session after this point.
        _ = try await transport.call(
            "workspace/create",
            args: .object(["request": .object(["path": .string("/dsh/workspace")])]))
        let diagnostics = await host.diagnostics()
        if reportHostDetails {
            report.set("boot_id", diagnostics.bootID)
        } else {
            report.set("boot_id_hash", Self.hashForReport(diagnostics.bootID))
        }
        report.set("host_state", diagnostics.state.rawValue)
        report.set("worker_hello_count", Int(diagnostics.workerHelloCount))
    }

    /// The engine the factory last published. A new factory call (a new
    /// engine) changes this identity; a WebContent restart on the same engine
    /// does not, which is why the test also gates the Worker HELLO count and
    /// the restart/termination counters.
    var publishedEngine: WebEngine? { slot.engine }

    func diagnostics() async throws -> PhoneDSHDiagnostics {
        guard let host else { throw SimError.assertion("the host is not booted") }
        return await host.diagnostics()
    }

    func hostHarness() async throws -> any AgentHarness {
        guard let host else { throw SimError.assertion("the host is not booted") }
        return try await host.harness()
    }

    /// Stable non-reversible tag for a raw host value in a redacted report.
    private static func hashForReport(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }

    func stop(redactingWith redactor: CapabilityRedactor) async {
        eventLog.stop()
        if let host { try? await host.stop() }
        engine?.shutdown()
        window?.shutdown()
        if recordsConsoleTail {
            report.addConsole(lines: eventLog.tail(50).map { redactor.redact($0) })
        }
        report.set("console_count", eventLog.console.count)
        try? report.write()
    }
}

@MainActor
private final class CapabilityEngineSlot {
    private(set) var engine: WebEngine?

    func publish(_ engine: WebEngine) {
        self.engine = engine
    }
}
