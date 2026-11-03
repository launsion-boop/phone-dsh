// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import PhoneDSH
import PhoneDSHAgentCore
import ProbeKit

@MainActor
final class PA_GitHubWorkerSessionTests: XCTestCase {
    private static let dummyPAT = "github-worker-session-dummy-pat"

    func testRealWorkerSessionInvokesSharedGitHubReadBridge() async throws {
        let nonce = PhoneDSHWorkerCapabilityTests.makeNonce("gh")
        let report = SimSuiteReport(suite: "github-worker-session", gate: "G1",
                                    directory: try SimEnvironment.reportsDirectory(),
                                    fileName: "github-worker-session-report.json")
        let model = GitHubWorkerModelFixture(nonce: nonce)
        let github = MockConnectorHTTPTransport()
        await github.stub("/repos/owner/repo", json: githubRepositoryJSON)
        let credentials = InMemoryConnectorCredentials()
        let redactor = CapabilityRedactor([
            Self.dummyPAT, "Bearer \(Self.dummyPAT)",
            PhoneDSHWorkerCapabilityTests.hostAPIKey,
            "Bearer \(PhoneDSHWorkerCapabilityTests.hostAPIKey)",
            PhoneDSHWorkerCapabilityTests.workerPlaceholderKey,
            "Bearer \(PhoneDSHWorkerCapabilityTests.workerPlaceholderKey)",
        ])
        var host: CapabilityTestHost?
        var failure: Error?

        do {
            try credentials.saveCredential(Self.dummyPAT, for: "github.pat")
            let composition = try AppComposition(
                root: SimEnvironment.workspaceRoot(name: "github-composition-\(nonce)"),
                credentials: credentials, githubTransport: github)
            let grant = ConnectorGrant(connectorID: "github", version: 1,
                                       allowedActions: [.read],
                                       scope: GrantScope(repositories: ["owner/repo"]))
            _ = try await composition.registry.connect("github", grant: grant,
                                                       credentialRef: "github.pat") {}
            report.set("github_transport", "MockConnectorHTTPTransport")
            report.set("credential", "dummy-only; value not recorded")
            let modelURL = try model.start()
            report.set("model_url", modelURL.absoluteString)
            let testHost = try CapabilityTestHost(nonce: nonce, report: report)
            host = testHost
            try await testHost.boot(
                modelURL: modelURL,
                modelName: PhoneDSHWorkerCapabilityTests.modelName,
                environmentExtra: [:],
                toolBridge: composition.dshToolBridge)
            guard let transport = testHost.transport else {
                throw SimError.assertion("the host did not publish a DSH Remote transport")
            }

            let manifestURL = testHost.workspace.appendingPathComponent(
                "materialized/home/capabilities.json")
            let manifestData = try Data(contentsOf: manifestURL)
            let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: manifestData)
                                         as? [String: Any])
            let hostCaps = Set((manifest["host_caps"] as? [String] ?? []))
            let phone = try XCTUnwrap(manifest["phone"] as? [String: Any])
            let tools = try XCTUnwrap(phone["tools"] as? [[String: Any]])
            let toolNames = Set(tools.compactMap { $0["name"] as? String })
            let expectedReadTools: Set<String> = [
                "github.repository.get", "github.issue.get", "github.pull.get",
                "github.pull.diff", "github.pull.checks",
            ]
            let manifestOK = hostCaps.contains("accelerator:phone")
                && expectedReadTools.allSatisfy {
                    hostCaps.contains("phone-tool:\($0)") && toolNames.contains($0)
                }
                && !hostCaps.contains("phone-tool:github.issue.comment")
                && !hostCaps.contains("phone-tool:github.issue.create")
                && !toolNames.contains("github.issue.comment")
                && !toolNames.contains("github.issue.create")
            try require(report, "manifest", manifestOK, metrics: [
                "accelerator_phone": hostCaps.contains("accelerator:phone"),
                "repository_cap": hostCaps.contains("phone-tool:github.repository.get"),
                "read_tools": expectedReadTools.allSatisfy(toolNames.contains),
                "write_tools_absent": !toolNames.contains("github.issue.comment")
                    && !toolNames.contains("github.issue.create"),
            ], detail: "the real Worker manifest projects exactly the AppComposition read-only GitHub catalog")
            report.set("manifest_host_caps", hostCaps.sorted())
            report.set("manifest_github_tools", toolNames.filter { $0.hasPrefix("github.") }.sorted())

            let created = try await transport.call("session/create", args: .object([
                "request": .object([
                    "cwd": .string("/dsh/workspace"),
                    "agentPreset": .string("standard"),
                ]),
            ]))
            let sessionID = try XCTUnwrap(created["sessionId"]?.stringValue)
            report.set("session_id", sessionID)
            report.set("session_create", [
                "endpoint": "session/create", "cwd": "/dsh/workspace", "preset": "standard",
            ])
            let agent = try await testHost.hostHarness()
            try require(report, "session_create", !sessionID.isEmpty,
                        metrics: ["session_id": sessionID],
                        detail: "the real DSH Remote session/create returned a Session before the model turn")

            try await agent.send(.prompt(
                text: "PDSH_PHASE_GITHUB_\(nonce) Read owner/repo through the host GitHub connector.",
                attachments: [], requestID: "github-\(nonce)"), to: sessionID)
            var completedPage: PhoneDSHWorkerCapabilityTests.PageEvidence?
            var journalCursor = 0
            try await simWait(timeout: 60, label: "real Worker GitHub call") {
                let requests = await github.snapshot()
                guard requests.count == 1, model.observations.count >= 2 else { return false }
                let cursor = try await Self.currentJournalCursor(
                    sessionID: sessionID, transport: transport)
                let candidate = try await PhoneDSHWorkerCapabilityTests.sessionPage(
                    transport: transport, sessionID: sessionID, throughSeq: cursor)
                guard candidate.assistantTexts.contains(where: {
                    $0.contains("GITHUB_WORKER_DONE_\(nonce)")
                }) else { return false }
                completedPage = candidate
                journalCursor = cursor
                return true
            }

            report.set("session_follow", ["cursor": journalCursor, "assistant_done": true])
            let requests = await github.snapshot()
            let request = try XCTUnwrap(requests.first)
            let page = try XCTUnwrap(completedPage)
            let pageCall = try XCTUnwrap(page.toolCalls.first {
                $0.value.name == "bash" && $0.value.arguments.contains("phone github.repository.get")
            })
            let callID = pageCall.key
            let result = try XCTUnwrap(page.toolResults[callID])
            let repositoryPayload = result.text.contains("owner/repo")
                || result.text.contains("owner\\/repo")
            let toolOK = requests.count == 1 && request.method == "GET"
                && request.url.hasSuffix("/repos/owner/repo") && request.hasAuthorization
                && !result.isError && result.text.contains("full_name") && repositoryPayload
            try require(report, "tool_call", toolOK, metrics: [
                "call_id": callID,
                "github_requests": requests.count,
                "method": request.method,
                "path": URL(string: request.url)?.path ?? "",
                "dummy_authorization_present": request.hasAuthorization,
                "is_error": result.isError,
            ], detail: "the model's real Worker bash call executed phone github.repository.get through AppComposition and the mock GitHub client")

            let sameStream = repositoryPayload
                && page.assistantTexts.contains { $0.contains("GITHUB_WORKER_DONE_\(nonce)") }
            try require(report, "same_session_stream", sameStream, metrics: [
                "page_call_id": callID,
                "assistant_done": page.assistantTexts.contains {
                    $0.contains("GITHUB_WORKER_DONE_\(nonce)")
                },
            ], detail: "session/page carries the Worker callId, GitHub result and final assistant marker from the created Session")

            let modelObservations = model.observations
            let modelBoundary = modelObservations.count >= 2 && modelObservations.allSatisfy {
                $0.apiKey == PhoneDSHWorkerCapabilityTests.hostAPIKey
            }
            try require(report, "model_boundary", modelBoundary, metrics: [
                "requests": modelObservations.count,
                "host_dummy_key_only": modelBoundary,
            ], detail: "only the scripted model decisions are replaced; the host gateway still injects its dummy key")
            report.record("github.real_account", status: .info, gating: false,
                          metrics: ["status": "NOT_RUN"],
                          threshold: simInfoThreshold("github_real_account"),
                          detail: "NOT_RUN: GitHub is MockConnectorHTTPTransport and the PAT is a dummy")
            report.finish(ok: true)
        } catch {
            failure = error
            report.finish(ok: false, failure: redactor.redact(String(describing: error), limit: 4096))
            report.record("github.failure", status: .fail, gating: true,
                          metrics: ["error": redactor.redact(String(describing: error), limit: 512)],
                          threshold: simG1Threshold("github_worker_session_completed", measured: 0),
                          detail: redactor.redact(String(describing: error), limit: 4096))
        }

        if let host { await host.stop(redactingWith: redactor) }
        model.stop()
        try? report.write()
        if let failure {
            XCTFail("real GitHub Worker session failed: \(redactor.redact(String(describing: failure)))")
        }
    }

    private static func currentJournalCursor(
        sessionID: String, transport: any DSHRemoteTransport) async throws -> Int {
        let mux = try await transport.openMux()
        let streamID = "github-worker-cursor-\(UUID().uuidString)"
        do {
            try await mux.send(.object([
                "type": .string("open"), "streamId": .string(streamID),
                "endpoint": .string("session/follow"),
                "payload": .object(["args": .object(["request": .object([
                    "address": .object(["kind": .string("session"), "sessionId": .string(sessionID)]),
                    "maxMessages": .number(1), "assistantStream": .bool(false),
                ])])]),
            ]))
            let cursor = try await withThrowingTaskGroup(of: Int.self) { group in
                group.addTask {
                    while !Task.isCancelled {
                        guard let frame = try await mux.receive() else {
                            throw ProviderError.unavailable(retryAfter: nil)
                        }
                        guard frame["streamId"]?.stringValue == streamID,
                              frame["type"]?.stringValue == "item" else { continue }
                        let value = frame["value"] ?? .null
                        if value["type"]?.stringValue == "snapshot",
                           let cursor = value["cursor"]?.intValue {
                            return cursor
                        }
                    }
                    throw ProviderError.cancelled
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(10))
                    await mux.close()
                    throw ProviderError.unavailable(retryAfter: nil)
                }
                guard let cursor = try await group.next() else {
                    throw ProviderError.invalidResponse("session/follow returned no cursor")
                }
                group.cancelAll()
                return cursor
            }
            await mux.close()
            return cursor
        } catch {
            await mux.close()
            throw error
        }
    }

    private func require(_ report: SimSuiteReport, _ name: String, _ passed: Bool,
                         metrics: [String: Any], detail: String) throws {
        report.record("github.\(name)", status: passed ? .pass : .fail, gating: true,
                      metrics: metrics,
                      threshold: simG1Threshold("github_\(name)", measured: passed ? 1 : 0),
                      detail: detail)
        if !passed { throw SimError.assertion(detail) }
    }
}

private final class GitHubWorkerModelFixture: @unchecked Sendable {
    private let responder: GitHubWorkerModelResponder
    private let server: CapabilityHTTPServer

    init(nonce: String) {
        let responder = GitHubWorkerModelResponder(nonce: nonce)
        self.responder = responder
        server = CapabilityHTTPServer { request in responder.handle(request) }
    }

    @discardableResult
    func start() throws -> URL { try server.start() }
    func stop() { server.stop() }
    var observations: [CapabilityModelObservation] { responder.observations }
}

private final class GitHubWorkerModelResponder: @unchecked Sendable {
    private let nonce: String
    private let lock = NSLock()
    private var count = 0
    private var recorded: [CapabilityModelObservation] = []

    init(nonce: String) { self.nonce = nonce }

    var observations: [CapabilityModelObservation] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func handle(_ request: CapabilityHTTPRequest) -> CapabilityHTTPResponse {
        guard request.method == "POST", request.path.hasSuffix("/v1/messages"),
              let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
            return .json(["error": ["message": "invalid request"]], status: 400)
        }
        lock.lock()
        count += 1
        let number = count
        recorded.append(CapabilityModelObservation(
            method: request.method, path: request.path,
            apiKey: request.headers["x-api-key"], body: request.body))
        lock.unlock()

        let requestText = String(decoding: request.body, as: UTF8.self)
        let isGitHubTurn = requestText.contains("PDSH_PHASE_GITHUB_\(nonce)")
        let isTitleRequest = requestText.contains("Generate the session title")
        let hasResult = Self.hasToolResult(body)
        let includeTool = isGitHubTurn && !hasResult && !isTitleRequest
        let text = isTitleRequest ? "GitHub Worker Session" : isGitHubTurn && hasResult
            ? "GITHUB_WORKER_DONE_\(nonce)" : "I will read the repository."
        return sse(text: text, includeTool: includeTool, number: number)
    }

    private static func hasToolResult(_ body: [String: Any]) -> Bool {
        for message in body["messages"] as? [[String: Any]] ?? [] {
            for block in message["content"] as? [[String: Any]] ?? [] {
                if block["type"] as? String == "tool_result" { return true }
            }
        }
        return false
    }

    private func sse(text: String, includeTool: Bool, number: Int) -> CapabilityHTTPResponse {
        var output = ""
        func emit(_ event: String, _ payload: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: payload,
                                                         options: [.sortedKeys]) else { return }
            output += "event: \(event)\ndata: \(String(decoding: data, as: UTF8.self))\n\n"
        }
        emit("message_start", [
            "type": "message_start",
            "message": [
                "id": "msg_github_worker_\(number)", "type": "message", "role": "assistant",
                "model": PhoneDSHWorkerCapabilityTests.modelName, "content": [],
                "usage": ["input_tokens": 64, "output_tokens": 0],
            ],
        ])
        emit("content_block_start", [
            "type": "content_block_start", "index": 0,
            "content_block": ["type": "text", "text": ""],
        ])
        emit("content_block_delta", [
            "type": "content_block_delta", "index": 0,
            "delta": ["type": "text_delta", "text": text],
        ])
        emit("content_block_stop", ["type": "content_block_stop", "index": 0])
        if includeTool {
            let input = #"{"command":"phone github.repository.get '{\"repository\":\"owner/repo\"}'","description":"Read the repository through the host connector"}"#
            emit("content_block_start", [
                "type": "content_block_start", "index": 1,
                "content_block": [
                    "type": "tool_use", "id": "toolu_github_worker_\(number)",
                    "name": "bash", "input": [:] as [String: Any],
                ],
            ])
            emit("content_block_delta", [
                "type": "content_block_delta", "index": 1,
                "delta": ["type": "input_json_delta", "partial_json": input],
            ])
            emit("content_block_stop", ["type": "content_block_stop", "index": 1])
        }
        emit("message_delta", [
            "type": "message_delta",
            "delta": ["stop_reason": includeTool ? "tool_use" : "end_turn"],
            "usage": ["output_tokens": 24],
        ])
        emit("message_stop", ["type": "message_stop"])
        return CapabilityHTTPResponse(status: 200, headers: [
            "Content-Type": "text/event-stream", "Cache-Control": "no-cache",
        ], body: Data(output.utf8))
    }
}
