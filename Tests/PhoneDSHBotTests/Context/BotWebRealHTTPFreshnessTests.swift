// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

/// A03/E7 vertical on an already-running SC loopback cloud assembly:
/// real HTTP `/v1/web/fetch` content A -> real memory baseline -> switch the
/// controlled upstream to B -> real HTTP recheck -> changed material on the
/// next decision request. The test skips unless the SC session env is supplied.
final class BotWebRealHTTPFreshnessTests: XCTestCase {
    private let url = URL(string: "https://public.example/freshness-report")!

    func testRealHTTPBaselineThenChangedMaterial() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["A03_CLOUD_BASE_URL"].flatMap(URL.init(string:)),
              let token = env["A03_CLOUD_TOKEN"], !token.isEmpty,
              let setMode = env["A03_SET_MODE"] else {
            throw XCTSkip("SC loopback session env not supplied")
        }
        let transport = CloudWebRecheckTransport(
            configuration: .init(baseURL: base, requestTimeoutSeconds: 20),
            tokenProvider: { token })
        let request = BotWebRecheckHTTPRequest(
            method: "GET", url: url, headers: [:],
            timeoutMilliseconds: 3_000, maximumBodyBytes: 1_048_576)
        let first = try await transport.perform(request)
        XCTAssertEqual(first.status, 200)
        XCTAssertFalse(first.body.isEmpty)
        let normalizedFirst = try XCTUnwrap(
            BotWebSourceRechecker.normalizedWebText(first.body))
        let firstDigest = "sha256:" + BotWebSourceRechecker.sha256(
            Data(normalizedFirst.utf8))
        XCTAssertFalse(first.headers["date"]?.isEmpty ?? true,
                       "real cloud must carry HTTP Date")

        let (store, root) = try makeMemoryTestStore()
        defer { cleanupMemoryTestStore(root); Task { try? await store.close() } }
        let envelope = try XCTUnwrap(BotObservationEnvelope(
            source: "web", origin: url.absoluteString,
            at: "2026-11-16T08:00:00.000Z", owner: "main",
            reference: BotRecordReference.session(sessionID: "gb-main", seq: 1),
            text: String(decoding: first.body, as: UTF8.self)))
        let seq = try await store.append(BotEvent(
            type: "conversation.tool_result", eventId: "a03-real-http:observation",
            time: 1_760_000_000_000, origin: .local(source: "runtime"),
            traceId: "trace-a03-real-http",
            principal: BotPrincipal(botId: "main", sessionId: "gb-main", kind: "chat"),
            causationId: nil, correlationId: "gb-main",
            data: .object(["message": .object([
                "role": .string("tool"),
                "content": .array([.object([
                    "type": .string("text"), "text": .string(envelope.encoded()),
                ])]),
            ])])))
        let ref = "record://event/\(seq)"
        let baseline = BotSourceBaseline(
            record: ref, role: .evidence,
            sourceVersion: .known(BotKnownSourceVersion(
                kind: .contentSHA256, value: firstDigest,
                observedAtMS: 1_760_000_000_000, basisRef: ref,
                subject: .recordText)),
            resource: BotMemoryResource(
                kind: "web-url", key: url.absoluteString,
                owner: "main", scope: "agent"))
        let memory = makeMemory(store: store, botID: "main")
        let written = try await memory.write(
            BotMemoryWriteRequest(
                action: .write, path: "agent/a03/web-freshness.md",
                content: "observed web text", expectedVersion: 0,
                evidence: [ref], sourceBaselines: [baseline]),
            context: BotMemoryWriteContext(
                botID: "main", sessionID: "gb-main", authorKind: .chat,
                source: BotMemorySource(kind: .userTurn, sessionID: "gb-main"),
                trust: .observation, isMainBot: true))
        XCTAssertTrue(written.ok, "\(String(describing: written.code))")

        let adapter = BotProvenanceWebRecheckAdapter(
            transport: transport, timeoutMilliseconds: 3_000)
        let currentService = BotProvenanceService(eventLog: store, rechecker: adapter)
        let artifact = BotDerivedRef(
            kind: .memory, id: "agent/a03/web-freshness.md", version: 1)
        let current = try await currentService.sourceStatuses(
            for: artifact, botID: "main")
        XCTAssertEqual(current.first?.state, .current)

        try switchMode(setMode, "content_b")
        defer { try? switchMode(setMode, "content_a") }
        let freshService = BotProvenanceService(eventLog: store, rechecker: adapter)
        let changed = try await freshService.sourceStatuses(
            for: artifact, botID: "main")
        XCTAssertEqual(changed.first?.state, .changed)

        let materialState = BotDecisionMaterialStateAdapter(provenance: freshService)
        let context = BotDecisionContextService(
            memoryForBot: { _ in memory },
            permissionRevision: { _, _, _ in "rev-a03" },
            materialState: { request in await materialState.state(for: request) },
            workspaceMaterials: nil, now: { 1_760_000_000_000 })
        let block = try await context.materials(for: BotDecisionRequest(
            stage: .preDelivery, botID: "main", sessionID: "gb-main",
            turnID: "gb-main#1", step: 1, tool: "RequestApproval",
            goal: "freshness", query: "observed web text", origin: "a03",
            scopes: [.agent], permissionRevision: "rev-a03",
            limits: BotDecisionLimits()))
        let material = try XCTUnwrap(block.materials.first)
        XCTAssertEqual(material.state, .changed)
        XCTAssertNotEqual(material.state, .current)
        XCTAssertFalse(material.snippet.isEmpty)
    }

    private func switchMode(_ script: String, _ mode: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script, mode]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
