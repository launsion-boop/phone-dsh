// SPDX-License-Identifier: MIT
//
// sim-fix-rt C1: a delayed user decision must not lose the retried write.
//
// The Worker's `curl`/fetch budget can be shorter than the approval wait. The
// `/v1/http` request then aborts; the host must not consume the allowOnce Grant
// for that dead request. The fixed composition returns a human pending answer
// before the client timeout and leaves the durable card for the retry, which
// consumes the once Grant and reaches the mock upstream exactly once.

import Foundation
import Network
import XCTest
@testable import PhoneDSHBot
import PhoneDSHGateway
import PhoneDSHAgentCore

private struct BotTestAnonymousProvider: CredentialProvider {
    func credential(for scope: CredentialScope) async throws -> Credential { .none }
    func invalidate(_ credential: Credential, for scope: CredentialScope) async {}
}

/// Minimal loopback HTTP/1.1 upstream: one request per connection, one `200 ok`.
private final class BotEgressMockUpstream: @unchecked Sendable {
    private let queue = DispatchQueue(label: "sim-fix-rt.mock-upstream")
    private let listener: NWListener
    private let lock = NSLock()
    private var storedRequests = 0
    private(set) var port: UInt16 = 0

    init() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    var requestCount: Int { lock.lock(); defer { lock.unlock() }; return storedRequests }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            let once = BotEgressOnceFlag()
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    let port = self.listener.port?.rawValue ?? 0
                    self.port = port
                    if once.claim() { continuation.resume(returning: port) }
                case .failed(let error):
                    if once.claim() { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
                let length = head.components(separatedBy: "\r\n").compactMap { line -> Int? in
                    let parts = line.split(separator: ":", maxSplits: 1)
                    guard parts.count == 2,
                          parts[0].trimmingCharacters(in: .whitespaces).lowercased()
                            == "content-length" else { return nil }
                    return Int(parts[1].trimmingCharacters(in: .whitespaces))
                }.first ?? 0
                if buffer.count - headerEnd.upperBound >= length {
                    self.lock.lock()
                    self.storedRequests += 1
                    self.lock.unlock()
                    let body = Data("ok".utf8)
                    var response = "HTTP/1.1 200 OK\r\n"
                    response += "Content-Type: text/plain\r\n"
                    response += "Content-Length: \(body.count)\r\n"
                    response += "Connection: close\r\n\r\n"
                    var payload = Data(response.utf8)
                    payload.append(body)
                    connection.send(content: payload, completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                    return
                }
            }
            if complete || error != nil {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }
}

private final class BotEgressOnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !used else { return false }
        used = true
        return true
    }
}

private final class RuntimeEgressApprover: BotEgressWriteApproving, @unchecked Sendable {
    private let runtime: BotMCPRuntime
    init(runtime: BotMCPRuntime) { self.runtime = runtime }

    func approveBotEgressWrite(_ request: BotEgressWriteRequest) async -> BotEgressWriteDecision {
        switch await runtime.approveEgress(
            method: request.method,
            host: request.url.host ?? "",
            scheme: request.url.scheme ?? "",
            port: request.url.port,
            hostAllowed: request.hostAllowed) {
        case .notBot: return .notBot
        case .allowed: return .allow
        case .denied(let code, let message): return .deny(code: code, message: message)
        }
    }
}

final class BotEgressGatewayIntegrationTests: XCTestCase {
    private func makeGateway(port: UInt16, approver: any BotEgressWriteApproving)
        async throws -> ModelGateway {
        let configuration = ModelGatewayConfiguration(
            allowedUpstreamHosts: ["127.0.0.1:\(port)"],
            responseLogQuotaBytes: 1_000_000,
            backoff: ModelGatewayBackoffPolicy(initialDelay: 0, multiplier: 2,
                                               maximumDelay: 60, jitterFraction: 0,
                                               maximumAttempts: 1),
            upstreamRequestTimeout: 10)
        let gateway = ModelGateway(configuration: configuration,
                                   credentialProvider: BotTestAnonymousProvider(),
                                   botEgressApprover: approver)
        addTeardownBlock { await gateway.shutdown() }
        return gateway
    }

    private func request(port: UInt16) -> GatewayRequest {
        GatewayRequest(
            method: "POST",
            url: URL(string: "http://127.0.0.1:\(port)/upload")!,
            headers: ["content-type": "text/plain"],
            body: Data("marker=C1".utf8))
    }

    private func firstFailure(_ stream: AsyncThrowingStream<GatewayResponseChunk, Error>)
        async -> Error? {
        do {
            for try await _ in stream {}
            return nil
        } catch {
            return error
        }
    }

    func testDelayedApprovalReturnsPendingAndTheRetryReachesTheUpstreamOnce() async throws {
        let server = try BotEgressMockUpstream()
        _ = try await server.start()
        addTeardownBlock { server.stop() }
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        // The test's "fetch timeout" is well below the user's decision delay.
        await fixture.runtime.setEgressInteractiveWaitMilliseconds(0)
        let issued = try await fixture.runtime.issueSessionToken(
            botId: "main", sessionId: "gb-main", kind: .chat)
        _ = try await fixture.runtime.registerIdentity(
            runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: "gb-main",
            callId: "c1-approval", name: "bash",
            arguments: .object(["command": .string(
                "curl -sS -m 1 -X POST https://httpbin.org/post")]),
            sessionToken: issued.token)
        await beginUserTurn(fixture.runtime)

        let gateway = try await makeGateway(
            port: server.port, approver: RuntimeEgressApprover(runtime: fixture.runtime))
        let clock = Date()
        let error = await firstFailure(gateway.handle(request(port: server.port)))
        let elapsed = Date().timeIntervalSince(clock)

        guard case .egressApprovalDenied(let code, let message)? = error as? ModelGatewayError else {
            XCTFail("expected the pending egress answer, got \(String(describing: error))")
            return
        }
        XCTAssertEqual(code, "egress_approval_denied")
        XCTAssertTrue(message.contains("已提交审批，批准后请重试"), message)
        XCTAssertLessThan(elapsed, 1.0,
                          "the host answered after the simulated fetch timeout")
        XCTAssertEqual(server.requestCount, 0, "the first request must not be sent")

        // The user approves after the caller gave up. The once Grant stays.
        let requests = try await botEvents(fixture.store)
            .filter { $0.type == "approval.requested" }
        let event = try XCTUnwrap(requests.first)
        let approvalID = try XCTUnwrap(event.data["approvalID"]?.stringValue)
        let digest = try XCTUnwrap(event.data["digest"]?.stringValue)
        let resolution = await fixture.runtime.approvals.resolve(
            approvalId: approvalID, decision: .allowOnce, digest: digest)
        XCTAssertEqual(resolution, .resolved)

        var status: Int?
        var body = Data()
        for try await chunk in gateway.handle(request(port: server.port)) {
            if let value = chunk.status { status = value }
            body.append(chunk.body)
        }
        XCTAssertEqual(status, 200)
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "ok")
        XCTAssertEqual(server.requestCount, 1, "the retried write reaches the upstream once")
        let approvalRequests = try await botEvents(fixture.store)
            .filter { $0.type == "approval.requested" }
        XCTAssertEqual(approvalRequests.count, 1,
                       "the retry must not ask for approval again")
    }

    func testAbortedRequestDoesNotWriteAndTheApprovedRetryDoes() async throws {
        let server = try BotEgressMockUpstream()
        _ = try await server.start()
        addTeardownBlock { server.stop() }
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        await fixture.runtime.setEgressInteractiveWaitMilliseconds(2_000)
        let issued = try await fixture.runtime.issueSessionToken(
            botId: "main", sessionId: "gb-main", kind: .chat)
        _ = try await fixture.runtime.registerIdentity(
            runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: "gb-main",
            callId: "c1-abort", name: "bash",
            arguments: .object(["command": .string(
                "curl -sS -m 1 -X POST https://example.com/")]),
            sessionToken: issued.token)
        await beginUserTurn(fixture.runtime)
        let gateway = try await makeGateway(
            port: server.port, approver: RuntimeEgressApprover(runtime: fixture.runtime))

        // Simulate the caller's fetch timeout: cancel the consumer while the
        // user is still deciding. The host must not send the dead request.
        let consumer = Task {
            await self.firstFailure(gateway.handle(self.request(port: server.port)))
        }
        let deadline = Date().addingTimeInterval(2)
        var event: BotEvent?
        while Date() < deadline, event == nil {
            event = try await botEvents(fixture.store)
                .first { $0.type == "approval.requested" }
            if event == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        }
        let requested = try XCTUnwrap(event)
        consumer.cancel()
        _ = await consumer.value
        try await Task.sleep(nanoseconds: 50_000_000)

        let approvalID = try XCTUnwrap(requested.data["approvalID"]?.stringValue)
        let digest = try XCTUnwrap(requested.data["digest"]?.stringValue)
        let resolution = await fixture.runtime.approvals.resolve(
            approvalId: approvalID, decision: .allowOnce, digest: digest)
        XCTAssertEqual(resolution, .resolved)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(server.requestCount, 0,
                       "an aborted /v1/http request must not be written after approval")

        var status: Int?
        for try await chunk in gateway.handle(request(port: server.port)) {
            if let value = chunk.status { status = value }
        }
        XCTAssertEqual(status, 200)
        XCTAssertEqual(server.requestCount, 1,
                       "the approved retry consumes the kept once Grant and writes once")
    }
}
