// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — iOS Simulator Streamable HTTP SSE-response acceptance.
//
// This is a separate `-only-testing` case from
// `testSimulatorPhoneMCPHTTPToolRegisterListInvokeRemove`:
//
//   * the existing case speaks the same Streamable HTTP transport with finite
//     `application/json` POST responses;
//   * this case keeps that transport (one `/mcp` endpoint, `phone/mcpUpsert`,
//     no extra transport selector) but the server answers every id-bearing
//     JSON-RPC POST with a real `Content-Type: text/event-stream` body. The
//     body arrives as `event: message` / `data: <JSON-RPC result>` frames,
//     split across at least two network sends, with the request's exact id;
//   * notification-only POSTs (including `notifications/initialized`) get a
//     bodyless 204;
//   * the scripted Messages upstream also streams SSE, but that is the model
//     transport and not the MCP server response. The report keeps the two
//     labels separate.
//
// The host is the App's real `WebHostConfiguration`/`PhoneDSHHost` assembly and
// the test drives the real `phone-mcp` Remote in the WKWebView WebWorker. Only
// the model's tool choice is scripted; registration, discovery, tool dispatch,
// the session/page projection and removal are real Worker paths.
//
// This snapshot's official DSH/phone-mcp schema and `dsh-mcp-client` expose
// stdio and Streamable HTTP only. There is no Legacy SSE selector to add or
// request, so this case uses the real Streamable HTTP transport and verifies
// its server-sent-event response mode. It is not a Legacy HTTP+SSE endpoint.
//
// iOS Simulator only. Physical iPhone, real external MCP server, real model and
// real credentials are NOT_RUN.

import CoreGraphics
import Foundation
import XCTest
import WebKit
import PhoneDSHAgentCore
import PhoneDSH
import PhoneDSHEngine
import ProbeKit

@MainActor
final class PhoneDSHWorkerCapabilitySSETests: XCTestCase {
    private static let envName = "PDSH_TEST_MCP_SSE_TOKEN"

    func testSimulatorPhoneMCPStreamableHTTPSSEResponseToolRegisterListInvokeRemove() async throws {
        let nonce = PhoneDSHWorkerCapabilityTests.makeNonce("sse")
        let modelName = PhoneDSHWorkerCapabilityTests.modelName
        let modelKey = PhoneDSHWorkerCapabilityTests.hostAPIKey
        let workerPlaceholderKey = PhoneDSHWorkerCapabilityTests.workerPlaceholderKey
        let directory = try SimEnvironment.reportsDirectory()
        let report = SimSuiteReport(suite: "worker-mcp-sse-response", gate: "G1",
                                    directory: directory,
                                    fileName: "worker-mcp-sse-response-report.json")
        let serverName = "sse-\(nonce)"
        let echoTool = "mcp__\(serverName)__echo"
        let marker = "MCP_SSE_RESPONSE_ECHO_\(nonce)"
        let mcp = CapabilityMCPSSEFixture(nonce: nonce,
                                          forbiddenModelKey: modelKey)
        let model = CapabilityModelFixture(
            mode: .mcp(nonce: nonce, toolName: echoTool, message: marker))
        // Reuse the shared NativeRuntime redactor so the SSE suite applies the
        // same longest-first secret scrubbing to every console tail and failure
        // path as the workflow/Streamable HTTP cases.
        let redactor = CapabilityRedactor([mcp.hostTokenValue,
                                           mcp.envTokenValue,
                                           modelKey,
                                           workerPlaceholderKey])
        var host: CapabilityTestHost?
        var stage = "fixture"
        var failureText: String?

        do {
            report.set("mcp_transport", "streamable-http")
            report.set("mcp_response_mode", "text/event-stream")
            report.set("mcp_endpoint_path", "/mcp")
            report.set("run_tag_hash", Self.hash(nonce))
            let mcpURL = try mcp.start()
            let mcpPort = mcpURL.port ?? 0
            let modelURL = try model.start()

            let testHost = try CapabilityTestHost(nonce: nonce, report: report,
                                                  recordsConsoleTail: false,
                                                  reportHostDetails: false)
            host = testHost
            stage = "boot"
            try await testHost.boot(
                modelURL: modelURL,
                modelName: modelName,
                environmentExtra: [Self.envName: mcp.envAuthorizationValue],
                egressHosts: ["http://127.0.0.1:\(mcpPort)"],
                extraCredentials: [
                    // Use the same full endpoint scope the gateway routes with
                    // (scheme/host/explicit port/normalized path). The legacy
                    // host/path-only key is not an exact match for the new
                    // scheme/port scope and would fall back to the model key.
                    CredentialScope(service: mcpURL.host?.lowercased() ?? "",
                                    audience: mcpURL.path,
                                    scheme: mcpURL.scheme?.lowercased(),
                                    port: mcpURL.port):
                        Credential(kind: .bearer, value: mcp.hostTokenValue),
                ])
            guard let transport = testHost.transport else {
                throw SimError.assertion("the host did not publish a DSH Remote transport")
            }

            // MARK: phone-mcp registry starts empty
            stage = "mcpList"
            let initialList = try await transport.call("phone/mcpList",
                                                       args: .object([:]))
            let initialServers = initialList["servers"]?.arrayValue ?? []
            let configFile = initialList["file"]?.stringValue ?? ""
            let initialError = initialList["error"]?.stringValue ?? ""
            try require(report, "mcp.sse_response.service",
                        configFile == "/dsh/home/mcp.json"
                            && initialServers.isEmpty
                            && initialError.isEmpty,
                        metrics: ["config_file": configFile,
                                  "initial_servers": initialServers.count,
                                  "initial_error": initialError],
                        detail: "the real phone-mcp Remote answered from the WKWebView WebWorker and its registry "
                            + "started empty for this unique Worker root")

            // MARK: register over the real Streamable HTTP transport
            stage = "register"
            let upsert = try await transport.call(
                "phone/mcpUpsert",
                args: .object(["request": .object([
                    "serverName": .string(serverName),
                    "url": .string(mcpURL.absoluteString),
                    "headersFromEnv": .object(["Authorization": .string(Self.envName)]),
                    "enabled": .bool(true),
                    "toolCallTimeoutMs": .number(5000),
                ])]))
            let registeredTools = (upsert["tools"]?.arrayValue ?? []).compactMap(\.stringValue)
            let expectedTools = ["mcp__\(serverName)__echo", "mcp__\(serverName)__ping"]
            let registerMethods = mcp.requestMethods
            let discoverIndex = registerMethods.firstIndex(of: "server/discover")
            let initializeIndex = registerMethods.firstIndex(of: "initialize")
            let initializedIndex = registerMethods.firstIndex(of: "notifications/initialized")
            let listIndex = registerMethods.firstIndex(of: "tools/list")
            let requestSequence: Bool
            if let discoverIndex, let initializeIndex, let initializedIndex, let listIndex {
                requestSequence = discoverIndex < initializeIndex
                    && initializeIndex < initializedIndex
                    && initializedIndex < listIndex
            } else {
                requestSequence = false
            }
            let sseResponseOK = mcp.sseResponseCount >= 3
                && mcp.sseContentTypeResponseCount == mcp.sseResponseCount
                && mcp.sseEventCount >= mcp.sseResponseCount
                && mcp.sseBodySendCount >= mcp.sseResponseCount * 2
                && mcp.sseSplitResponseCount == mcp.sseResponseCount
                && mcp.replyIDMismatchCount == 0
                && mcp.parseFailureCount == 0
                && mcp.notificationNoContentCount >= 1
            var registerMetrics = mcp.diagnostics
            registerMetrics["status"] = upsert["status"]?.stringValue ?? ""
            registerMetrics["tools"] = registeredTools.joined(separator: ",")
            registerMetrics["authentication"] = upsert["authentication"]?.stringValue ?? ""
            registerMetrics["request_sequence"] = requestSequence
            registerMetrics["host_authorization_seen"] = mcp.sawHostAuthorization
            registerMetrics["env_authorization_seen"] = mcp.sawEnvAuthorization
            registerMetrics["model_credential_seen"] = mcp.sawModelCredential
            try require(report, "mcp.sse_response.register",
                        upsert["status"]?.stringValue == "connected"
                            && registeredTools == expectedTools
                            && upsert["authentication"]?.stringValue == "headers-env"
                            && requestSequence
                            && sseResponseOK
                            && mcp.sawHostAuthorization
                            && !mcp.sawEnvAuthorization
                            && !mcp.sawModelCredential
                            && mcp.accessControlHeaderCount == 0,
                        metrics: registerMetrics,
                        detail: "phone/mcpUpsert mounted the real Streamable HTTP transport; the local fixture "
                            + "answered server/discover, initialize, notifications/initialized and tools/list with "
                            + "real text/event-stream responses (notification 204, exact ids, split frames) and "
                            + "published the exact ToolRuntime names. The env-only and model-gateway dummy values "
                            + "were rejected, and no CORS header was needed")

            // MARK: list + inventory
            stage = "list"
            let listed = try await transport.call("phone/mcpList", args: .object([:]))
            let listedRow = (listed["servers"]?.arrayValue ?? []).first {
                $0["serverName"]?.stringValue == serverName
            }
            let listedTools = (listedRow?["tools"]?.arrayValue ?? []).compactMap(\.stringValue)
            try require(report, "mcp.sse_response.list",
                        listedRow?["status"]?.stringValue == "connected"
                            && listedTools == expectedTools,
                        metrics: ["status": listedRow?["status"]?.stringValue ?? "",
                                  "tools": listedTools.joined(separator: ","),
                                  "servers": listed["servers"]?.arrayValue?.count ?? 0],
                        detail: "phone/mcpList reports the live Streamable HTTP mount and its real tool "
                            + "registrations")

            let inventoryBefore = try await transport.call("phone/listTools",
                                                           args: .object([:]))
            let toolNamesBefore = PhoneDSHWorkerCapabilityTests.toolNames(inventoryBefore)
            try require(report, "mcp.sse_response.inventory",
                        toolNamesBefore.contains(echoTool)
                            && toolNamesBefore.contains("mcp__\(serverName)__ping"),
                        metrics: ["tool_count": toolNamesBefore.count,
                                  "echo_present": toolNamesBefore.contains(echoTool),
                                  "ping_present": toolNamesBefore.contains("mcp__\(serverName)__ping")],
                        detail: "the global ToolRuntime inventory shows the exact MCP names before the model call")

            // MARK: same real Worker Session
            stage = "session/create"
            let agent = try await testHost.hostHarness()
            let session: HarnessSession
            do {
                session = try await agent.openSession(
                    HarnessSessionRequest(preset: "standard", workspace: "/dsh/workspace"))
            } catch {
                throw SimError.assertion(
                    "standard session/create failed for the SSE-response test; see the worker capability report")
            }
            testHost.eventLog.attach(harness: agent, sessionID: session.id)
            report.set("session_id_hash", Self.hash(session.id))

            stage = "tool_invoke"
            let prompt = "PDSH_PHASE_MCP_\(nonce) Call the registered MCP echo tool with \(marker)."
            try await agent.send(
                .prompt(text: prompt, attachments: [], requestID: "mcp-sse-\(nonce)"),
                to: session.id)
            try await simWait(timeout: 180, label: "MCP SSE-response tool result") {
                let calls = mcp.toolCalls
                let records = PhoneDSHWorkerCapabilityTests.toolRecords(
                    from: testHost.eventLog.harnessEvents)
                guard let record = records.first(where: { $0.name == echoTool }),
                      let result = record.result else { return false }
                return calls.contains { $0.name == "echo" && $0.message == marker }
                    && !result.isError
                    && result.text.contains("echo:\(marker)")
                    && PhoneDSHWorkerCapabilityTests.assistantTexts(
                        in: testHost.eventLog.harnessEvents)
                        .contains { $0.contains("MCP_DONE_\(nonce)") }
            }
            let records = PhoneDSHWorkerCapabilityTests.toolRecords(
                from: testHost.eventLog.harnessEvents)
            guard let mcpRecord = records.first(where: { $0.name == echoTool }),
                  let mcpResult = mcpRecord.result else {
                throw SimError.artifact("the parent Session has no MCP SSE-response tool call/result")
            }
            let calls = mcp.toolCalls
            try require(report, "mcp.sse_response.tool_invoke",
                        !mcpResult.isError
                            && mcpResult.text.contains("echo:\(marker)")
                            && calls.contains { $0.name == "echo" && $0.message == marker },
                        metrics: ["call_id_hash": Self.hash(mcpRecord.callID),
                                  "is_error": mcpResult.isError,
                                  "fixture_echo_calls": calls.filter { $0.name == "echo" }.count,
                                  "result_contains_marker": mcpResult.text.contains("echo:\(marker)")],
                        detail: "the model's real mcp__…__echo tool call reached the fixture's tools/call and the "
                            + "echo result came back into the same parent Session")

            // MARK: real SSE responses, methods, ids and same page
            stage = "same_stream"
            let lastSeq = testHost.eventLog.harnessEvents.compactMap(\.seq).max()
                .map { Int($0 / 8) } ?? 100
            let page = try await PhoneDSHWorkerCapabilityTests.sessionPage(
                transport: transport, sessionID: session.id, throughSeq: lastSeq)
            let pageCall = page.toolCalls.first { $0.value.name == echoTool }
            let pageResult = pageCall.flatMap { page.toolResults[$0.key] }
            let pageAssistant = page.assistantTexts.contains { $0.contains("MCP_DONE_\(nonce)") }
            let methods = mcp.requestMethods
            let streamDiscoverIndex = methods.firstIndex(of: "server/discover")
            let streamInitializeIndex = methods.firstIndex(of: "initialize")
            let streamInitializedIndex = methods.firstIndex(of: "notifications/initialized")
            let streamListIndex = methods.firstIndex(of: "tools/list")
            let callIndex = methods.firstIndex(of: "tools/call")
            let rpcSequence: Bool
            if let streamDiscoverIndex, let streamInitializeIndex, let streamInitializedIndex,
               let streamListIndex, let callIndex {
                rpcSequence = streamDiscoverIndex < streamInitializeIndex
                    && streamInitializeIndex < streamInitializedIndex
                    && streamInitializedIndex < streamListIndex
                    && streamListIndex < callIndex
            } else {
                rpcSequence = false
            }
            let sseTransportOK = mcp.sseResponseCount >= 4
                && mcp.sseContentTypeResponseCount == mcp.sseResponseCount
                && mcp.sseEventCount >= mcp.sseResponseCount
                && mcp.sseBodySendCount >= mcp.sseResponseCount * 2
                && mcp.sseSplitResponseCount == mcp.sseResponseCount
                && mcp.replyIDMismatchCount == 0
                && mcp.parseFailureCount == 0
                && mcp.notificationNoContentCount >= 1
                && mcp.postRequestCount == mcp.authorizedPostCount
                && mcp.authorizedPostCount >= 5
                && mcp.getRequestCount == mcp.authorizedGetCount
                && mcp.deleteRequestCount == mcp.authorizedDeleteCount
                && mcp.unauthorizedRequestCount == 0
                && mcp.accessControlHeaderCount == 0
            try require(report, "mcp.sse_response.same_stream",
                        pageCall?.key == mcpRecord.callID
                            && pageResult?.text.contains("echo:\(marker)") == true
                            && pageAssistant
                            && rpcSequence
                            && sseTransportOK,
                        metrics: ["harness_call_id_hash": Self.hash(mcpRecord.callID),
                                  "page_call_id_hash": pageCall.map { Self.hash($0.key) } ?? "",
                                  "rpc_methods": methods.joined(separator: ","),
                                  "discover_index": streamDiscoverIndex ?? -1,
                                  "initialize_index": streamInitializeIndex ?? -1,
                                  "initialized_index": streamInitializedIndex ?? -1,
                                  "tools_list_index": streamListIndex ?? -1,
                                  "tools_call_index": callIndex ?? -1,
                                  "page_assistant": pageAssistant,
                                  "sse_responses": mcp.sseResponseCount,
                                  "sse_content_type_responses": mcp.sseContentTypeResponseCount,
                                  "sse_events": mcp.sseEventCount,
                                  "sse_body_sends": mcp.sseBodySendCount,
                                  "sse_split_responses": mcp.sseSplitResponseCount,
                                  "sse_reply_id_mismatches": mcp.replyIDMismatchCount,
                                  "sse_parse_failures": mcp.parseFailureCount,
                                  "notification_204": mcp.notificationNoContentCount,
                                  "post_requests": mcp.postRequestCount,
                                  "post_authorized": mcp.authorizedPostCount,
                                  "authenticated_requests": mcp.authenticatedRequestCount,
                                  "cors_headers_sent": mcp.accessControlHeaderCount],
                        detail: "the harness stream and session/page carry the same MCP callId/result, the fixture "
                            + "observed server/discover → initialize → notifications/initialized → tools/list → "
                            + "tools/call, and every id-bearing response was a split text/event-stream body with "
                            + "the request's exact id. GET/DELETE used the existing fixture protocol only after the "
                            + "host bearer, and no CORS header was emitted")

            // MARK: remove + clear
            stage = "remove"
            _ = try await transport.call(
                "phone/mcpRemove",
                args: .object(["request": .object(["serverName": .string(serverName)])]))
            let afterRemove = try await transport.call("phone/mcpList", args: .object([:]))
            let remaining = afterRemove["servers"]?.arrayValue ?? []
            let inventoryAfter = try await transport.call("phone/listTools", args: .object([:]))
            let toolNamesAfter = PhoneDSHWorkerCapabilityTests.toolNames(inventoryAfter)
            try require(report, "mcp.sse_response.remove",
                        remaining.isEmpty
                            && !toolNamesAfter.contains(echoTool)
                            && !toolNamesAfter.contains("mcp__\(serverName)__ping"),
                        metrics: ["servers_after_remove": remaining.count,
                                  "echo_still_registered": toolNamesAfter.contains(echoTool),
                                  "ping_still_registered": toolNamesAfter.contains("mcp__\(serverName)__ping")],
                        detail: "phone/mcpRemove disposed the Streamable HTTP mount, left no persisted row and "
                            + "removed both real ToolRuntime registrations")

            // MARK: Credential and CORS boundaries
            stage = "credential_boundary"
            let observations = model.observations
            let hostInjected = observations.allSatisfy { $0.apiKey == modelKey }
            try require(report, "mcp.sse_response.key_boundary",
                        observations.count >= 2
                            && hostInjected
                            && mcp.sawHostAuthorization
                            && !mcp.sawEnvAuthorization
                            && !mcp.sawModelCredential
                            && mcp.authenticatedRequestCount > 0,
                        metrics: ["model_requests": observations.count,
                                  "model_key_injected": hostInjected,
                                  "host_authorization_seen": mcp.sawHostAuthorization,
                                  "env_authorization_seen": mcp.sawEnvAuthorization,
                                  "model_credential_seen": mcp.sawModelCredential,
                                  "mcp_authorized_requests": mcp.authenticatedRequestCount,
                                  "mcp_authorized_posts": mcp.authorizedPostCount],
                        detail: "the host /v1/http route replaced the Worker's env-header dummy with the different "
                            + "host credential; the fixture accepted only that host value and never saw the "
                            + "model-gateway key or the env-only value")

            stage = "cors_boundary"
            let corsHeaders = mcp.accessControlHeaderCount
            try require(report, "mcp.sse_response.no_cors",
                        corsHeaders == 0,
                        metrics: ["access_control_headers_sent": corsHeaders,
                                  "sse_responses": mcp.sseResponseCount,
                                  "authorized_posts": mcp.authorizedPostCount,
                                  "get_requests": mcp.getRequestCount,
                                  "delete_requests": mcp.deleteRequestCount],
                        detail: "the fixture emitted no Access-Control-* header; the real Worker/host path "
                            + "completed without an external server enabling CORS")

            stage = "console"
            let consoleSummary = Self.consoleSummary(testHost.eventLog.console)
            report.set("mcp_console_summary", consoleSummary)
            let globalNotDefined = consoleSummary["global_not_defined_seen"] as? Bool ?? false
            let importFailure = consoleSummary["phone_mcp_import_failure_seen"] as? Bool ?? false
            try require(report, "mcp.sse_response.console",
                        !globalNotDefined && !importFailure,
                        metrics: ["console_count": consoleSummary["total_lines"] as? Int ?? 0,
                                  "warning_error_lines": consoleSummary["warning_error_lines"] as? Int ?? 0,
                                  "global_not_defined_seen": globalNotDefined,
                                  "phone_mcp_import_failure_seen": importFailure],
                        detail: "the Worker console carries no phone-mcp import/JSC failure; only counts, fixed "
                            + "booleans and bounded line hashes are retained")

            report.record("worker.mcp.sse_response.transport_distinction", status: .info,
                          gating: false,
                          metrics: ["mcp_transport": "streamable-http",
                                    "mcp_response_mode": "text/event-stream",
                                    "json_response_mcp_case_separate": true,
                                    "model_messages_sse_is_mcp_sse": false],
                          threshold: simInfoThreshold("worker_mcp_sse_response_transport_distinction"),
                          detail: "this report covers a server text/event-stream response under the same "
                              + "Streamable HTTP POST transport; the separate MCP HTTP case covers JSON POST "
                              + "responses, and the scripted Messages SSE upstream is the model transport")
            report.record("worker.mcp.sse_response.real_external_server", status: .info,
                          gating: false,
                          metrics: ["status": "NOT_RUN"],
                          threshold: simInfoThreshold("worker_mcp_sse_response_real_external_server"),
                          detail: "NOT_RUN: the fixture is a local 127.0.0.1 Streamable HTTP server; no real "
                              + "external MCP endpoint or real key is used")
            report.record("worker.mcp.sse_response.node_substitute", status: .info,
                          gating: false,
                          metrics: ["status": "NOT_RUN"],
                          threshold: simInfoThreshold("worker_mcp_sse_response_node_substitute"),
                          detail: "NOT_RUN: this result comes from the real WKWebView WebWorker on the iOS Simulator, "
                              + "not the Node phone-mcp test")
            report.finish(ok: true)
        } catch {
            let safe = Self.redactedError(error,
                                          secrets: [mcp.hostTokenValue,
                                                    mcp.envTokenValue,
                                                    modelKey,
                                                    workerPlaceholderKey],
                                          nonce: nonce,
                                          url: mcp.url)
            failureText = safe
            var metrics: [String: Any] = [
                "stage": stage,
                "error_name": Self.errorName(error),
                "error_hash": Self.hash(safe),
            ]
            for (key, value) in mcp.diagnostics where key != "rpc_methods" {
                metrics[key] = value
            }
            report.record("worker.mcp.sse_response.failure",
                          status: .fail, gating: true,
                          metrics: metrics,
                          threshold: simG1Threshold("g1_worker_mcp_sse_response_completed", measured: 0),
                          detail: "Streamable HTTP SSE-response acceptance failed at stage \(stage); bounded fixture "
                              + "counts and a redacted error hash/name are recorded. A FAIL here is the acceptance "
                              + "result, not a skip and not a substitution for the JSON-response case.")
            report.set("mcp_sse_response_fixture_at_failure", mcp.diagnostics)
            report.set("mcp_sse_response_error_redacted", safe)
            report.set("mcp_console_summary", Self.consoleSummary(host?.eventLog.console ?? []))
            report.finish(ok: false, failure: safe)
        }

        if let host { await host.stop(redactingWith: redactor) }
        mcp.stop()
        model.stop()
        report.set("mcp_sse_response_fixture_final", mcp.diagnostics)
        try? report.write()
        if let failureText {
            XCTFail("iOS Simulator Streamable HTTP SSE-response acceptance failed: \(failureText)\n"
                + "--- report: \(report.fileURL.path) ---")
        }
    }

    // MARK: - Assertions and redaction

    @discardableResult
    private func require(_ report: SimSuiteReport,
                         _ probe: String,
                         _ passed: Bool,
                         metrics: [String: Any] = [:],
                         detail: String) throws -> Bool {
        report.record("worker.\(probe)",
                      status: passed ? .pass : .fail, gating: true,
                      metrics: metrics,
                      threshold: simG1Threshold(
                        "g1_worker_\(probe.replacingOccurrences(of: ".", with: "_"))",
                        measured: passed ? 1 : 0),
                      detail: detail)
        if !passed { throw SimError.assertion(detail) }
        return passed
    }

    private static func errorName(_ error: Error) -> String {
        if error is DSHRemoteError { return "DSHRemoteError" }
        return String(reflecting: type(of: error))
    }

    /// FNV-1a is used only to keep a stable, non-reversible tag in the report.
    private static func hash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }

    private static func redactedError(_ error: Error,
                                      secrets: [String],
                                      nonce: String,
                                      url: URL?) -> String {
        var text = String(describing: error)
        var values = secrets
        if let url { values.append(url.absoluteString) }
        for secret in values.filter({ !$0.isEmpty }).sorted(by: { $0.count > $1.count }) {
            text = text.replacingOccurrences(of: secret, with: "[redacted]")
        }
        text = text.replacingOccurrences(of: nonce, with: "[nonce]")
        text = replacing(#"https?://127\.0\.0\.1:[0-9]+[^\s"']*"#,
                         in: text, with: "<loopback-url>")
        text = replacing(#"\?[^\s"']*"#, in: text, with: "?[redacted]")
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count <= 512 ? flat : String(flat.prefix(512)) + "…"
    }

    private static func replacing(_ pattern: String,
                                  in text: String,
                                  with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range,
                                              withTemplate: template)
    }

    /// Report-safe console evidence: counts, fixed failure booleans and hashes.
    /// No raw console line (which may contain a header, query or tool argument)
    /// is written to the report.
    private static func consoleSummary(_ lines: [SimConsoleLine]) -> [String: Any] {
        let warningOrError = lines.filter { $0.level == "warning" || $0.level == "error" }
        let texts = lines.map(\.text)
        return [
            "total_lines": lines.count,
            "warning_error_lines": warningOrError.count,
            "global_not_defined_seen": texts.contains { $0.contains("global is not defined") },
            "phone_mcp_import_failure_seen": texts.contains { line in
                line.contains("phone-mcp")
                    && (line.contains("failed to import") || line.contains("not implemented"))
            },
            "not_implemented_seen": texts.contains { $0.contains("not implemented") },
            "relevant_line_hashes": warningOrError.suffix(8).map { hash($0.text) },
        ]
    }
}
