// SPDX-License-Identifier: MIT
// PhoneDSHAgentCore public-surface tests.
//
// The module is the dependency boundary every phone-DSH module builds on.
// These tests are compile-time proof that its contracts are public and usable
// on their own, plus a few value assertions.

import Foundation
import XCTest
import PhoneDSHAgentCore

final class AgentCorePublicSurfaceTests: XCTestCase {
    // MARK: - Exec seam

    func testExecSeamIsPublic() async {
        let request = ExecRequest(execID: "xl1-agent-core", argv: ["rg", "needle"],
                                  cwd: "/dsh/workspace", env: ["LANG": "C"],
                                  tier: .session)
        XCTAssertEqual(request.execID, "xl1-agent-core")
        XCTAssertEqual(request.argv, ["rg", "needle"])
        XCTAssertEqual(request.tier, .session)

        let capabilities = ExecCapabilities(environment: "agent-core-test",
                                            network: false,
                                            persistentWorkspace: true,
                                            tiers: [.interactive, .batch])
        let provider: any ExecProvider = StubExecProvider(capabilities: capabilities)
        XCTAssertEqual(provider.capabilities, capabilities)

        let events: [ExecEvent] = [
            .stdout(seq: 0, data: Data("needle\n".utf8)),
            .stderr(seq: 1, data: Data()),
            .exit(code: 0, signal: nil, truncated: false),
        ]
        XCTAssertEqual(events.count, 3)
        await provider.cancel(execID: request.execID)
    }

    // MARK: - Credentials

    func testCredentialContractIsPublic() async throws {
        let scope = CredentialScope(service: "agent-core", audience: "tests")
        let credential = Credential(kind: .bearer, value: "secret")
        let provider: any CredentialProvider = StaticCredentialProvider([scope: credential])
        let resolved = try await provider.credential(for: scope)
        XCTAssertEqual(resolved, credential)
        await provider.invalidate(resolved, for: scope)

        var request = URLRequest(url: URL(string: "http://127.0.0.1/")!)
        credential.apply(to: &request)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
    }

    // MARK: - Agent harness contract

    func testHarnessContractIsPublic() {
        let capabilities = HarnessCapabilities(cancel: true, steer: true, resume: .native,
                                               permission: .native, clientTools: .none,
                                               toolVisibility: true,
                                               runsWhileAppSuspended: true)
        let session = HarnessSession(id: "s1", capabilities: capabilities, lastSeq: 3)
        XCTAssertEqual(session.id, "s1")
        XCTAssertEqual(session.lastSeq, 3)

        let openRequest = HarnessSessionRequest(sessionID: "s1", preset: nil,
                                                workspace: "/dsh/workspace")
        XCTAssertEqual(openRequest.sessionID, "s1")

        let toolCall = HarnessEvent(seq: 8, time: Date(timeIntervalSince1970: 0),
                                    kind: .toolCall(callID: "c1", name: "bash",
                                                    arguments: .object(["argv": .array([.string("true")])])))
        XCTAssertTrue(toolCall.isDurable)

        let permission = HarnessPermissionRequest(requestID: "r1", tool: "bash",
                                                  summary: "Run a command?", risk: .readOnly)
        XCTAssertEqual(permission.risk, .readOnly)
        XCTAssertEqual(HarnessCommand.permissionResponse(requestID: "r1", decision: .allowOnce),
                       .permissionResponse(requestID: "r1", decision: .allowOnce))
        XCTAssertEqual(HarnessTurnEnd.completed, .completed)
        XCTAssertEqual(PermissionDecision.allowAlways, .allowAlways)
        XCTAssertEqual(ToolRisk.sideEffect, .sideEffect)
        XCTAssertEqual(HarnessQuestion(requestID: "q1", prompt: "Continue?").prompt, "Continue?")
        XCTAssertEqual(HarnessAttachment(name: "a", mimeType: "text/plain", data: Data()).name, "a")
        XCTAssertEqual(MCPServerReference(name: "phone",
                                          transport: .inProcess(name: "phone")).name, "phone")

        let harness: any AgentHarness = StubHarness(capabilities: capabilities)
        XCTAssertTrue(harness.capabilities.steer)
    }

    // MARK: - DSH Remote seam

    func testDSHRemoteSeamIsPublic() {
        XCTAssertEqual(DSHEventMapper.partsPerEvent, 8)
        XCTAssertEqual(DSHEventMapper.position(of: 19).dshSeq, 2)
        XCTAssertEqual(DSHEventMapper.position(of: 19).part, 3)
        let mapped = DSHEventMapper.map(.object([
            "type": .string("turn/end"),
            "seq": .number(4),
            "time": .number(0),
            "data": .object(["turn": .number(1),
                             "reason": .object(["kind": .string("completed")])]),
        ]))
        XCTAssertEqual(mapped.count, 1)

        let error = DSHRemoteError(code: "session/not-found", message: "gone")
        XCTAssertEqual(error.providerError, .invalidRequest("session_not_found"))

        let provider = StaticCredentialProvider([
            CredentialScope(service: "dsh-remote"): Credential(kind: .none, value: "")
        ])
        let transport = DSHWebTransport(baseURL: URL(string: "http://127.0.0.1:1")!,
                                        credentials: provider)
        let seam: any DSHRemoteTransport = transport
        XCTAssertNotNil(seam)

        let harness = DSHRemoteHarness(transport: transport)
        XCTAssertTrue(harness.capabilities.cancel)
    }

    // MARK: - Exec-bridge host seam

    func testExecBridgeHostSeamIsPublic() async throws {
        let bridge = StubBridge()
        let started = try await bridge.start()
        XCTAssertEqual(started, StubBridge.endpoint)
        let token = bridge.token
        XCTAssertEqual(token, "token")
        await bridge.setLifecycle(.pause)
        let lifecycle = await bridge.lifecycle
        XCTAssertEqual(lifecycle, .pause)
        await bridge.stop()
    }

    // MARK: - Shared values

    func testProviderErrorAndJSONValueArePublic() throws {
        XCTAssertTrue(ProviderError.unavailable(retryAfter: nil).isRetryable)
        XCTAssertFalse(ProviderError.invalidRequest("bad").isRetryable)

        let value = JSONValue.object(["b": .number(2), "a": .array([.bool(true), .null])])
        let encoded = try value.encoded()
        XCTAssertEqual(try JSONValue.parse(encoded), value)
    }
}

// MARK: - Test doubles

private struct StubExecProvider: ExecProvider {
    let capabilities: ExecCapabilities

    func run(_ request: ExecRequest) -> AsyncThrowingStream<ExecEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.exit(code: 0, signal: nil, truncated: false))
            continuation.finish()
        }
    }

    func cancel(execID: String) async {}
}

private final class StubHarness: AgentHarness, @unchecked Sendable {
    let capabilities: HarnessCapabilities

    init(capabilities: HarnessCapabilities) {
        self.capabilities = capabilities
    }

    func openSession(_ request: HarnessSessionRequest) async throws -> HarnessSession {
        HarnessSession(id: "s1", capabilities: capabilities)
    }

    func send(_ command: HarnessCommand, to sessionID: String) async throws {}

    func events(sessionID: String, after seq: UInt64?) -> AsyncThrowingStream<HarnessEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private actor StubBridge: ExecBridgeHosting {
    static let endpoint = URL(string: "http://127.0.0.1:9")!
    private(set) var lifecycle: ExecBridgeLifecycleState = .run
    nonisolated var token: String? { "token" }
    nonisolated var baseURL: URL? { Self.endpoint }

    func start() async throws -> URL { Self.endpoint }
    func stop() async {}
    func setLifecycle(_ state: ExecBridgeLifecycleState) async { lifecycle = state }
}
