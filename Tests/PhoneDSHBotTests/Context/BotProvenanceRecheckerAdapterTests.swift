// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

private struct RecordingRechecker: BotProvenanceRechecking {
    let outcome: BotProvenanceRecheckOutcome
    let record: @Sendable (BotResourceIdentity) -> Void

    init(outcome: BotProvenanceRecheckOutcome,
         record: @escaping @Sendable (BotResourceIdentity) -> Void = { _ in }) {
        self.outcome = outcome
        self.record = record
    }

    func recheck(resource: BotResourceIdentity,
                 baseline: BotProvenanceSourceVersion,
                 botID: String?) async -> BotProvenanceRecheckOutcome {
        record(resource)
        return outcome
    }
}

final class BotProvenanceRecheckerAdapterTests: XCTestCase {
    private let webURL = URL(string: "https://example.test/source")!

    private func webResource() -> BotResourceIdentity {
        BotResourceIdentity(kind: .webURL, key: webURL.absoluteString,
                            owner: "bot-a", scope: "grant-7")
    }

    func testWebAdapterUsesArtifactBaselineAndMapsChanged() async throws {
        final class State: @unchecked Sendable {
            var etag = "\"v1\""
        }
        let state = State()
        let server = try LocalRecheckServer { _ in
            RecheckServerResponse(status: 200, headers: ["ETag": state.etag],
                                  body: Data("body".utf8))
        }
        let base = try await server.start()
        defer { server.stop() }
        let resource = BotResourceIdentity(
            kind: .webURL, key: base.appendingPathComponent("/source").absoluteString,
            owner: "bot-a", scope: "grant-7")
        let adapter = BotProvenanceWebRecheckAdapter(transport: URLSessionRecheckTransport())
        let baseline = BotProvenanceSourceVersion.known(
            basis: .etag, value: "etag:\"v1\"", observedAtMS: 1_000)
        let unchanged = await adapter.recheck(
            resource: resource, baseline: baseline, botID: "bot-a")
        guard case .same = unchanged else {
            return XCTFail("expected same, got \(unchanged)")
        }
        state.etag = "\"v2\""
        let changed = await adapter.recheck(
            resource: resource, baseline: baseline, botID: "bot-a")
        guard case let .changed(version, _) = changed else {
            return XCTFail("expected changed, got \(changed)")
        }
        guard case let .known(known) = version else {
            return XCTFail("expected known version")
        }
        XCTAssertEqual(known.basis, .etag)
        XCTAssertEqual(known.value, "etag:\"v2\"")
        XCTAssertEqual(server.requests.last?.headers["if-none-match"], "\"v1\"")
    }

    func testWebAdapterMapsDeniedAndUnsupportedResource() async throws {
        let server = try LocalRecheckServer { _ in
            RecheckServerResponse(status: 403, headers: [:], body: Data())
        }
        let base = try await server.start()
        defer { server.stop() }
        let resource = BotResourceIdentity(
            kind: .connectorResource,
            key: base.appendingPathComponent("/connector").absoluteString,
            owner: "bot-a")
        let adapter = BotProvenanceWebRecheckAdapter(transport: URLSessionRecheckTransport())
        let denied = await adapter.recheck(
            resource: resource,
            baseline: .known(BotKnownProvenanceSourceVersion(
                basis: .etag, value: "etag:\"v1\"")), botID: "bot-a")
        guard case let .denied(detail) = denied else {
            return XCTFail("expected denied, got \(denied)")
        }
        XCTAssertEqual(detail, "refresh-denied")

        let file = await adapter.recheck(
            resource: BotResourceIdentity(kind: .file, key: "notes/a.md"),
            baseline: .known(BotKnownProvenanceSourceVersion(
                basis: .contentSHA256,
                value: "sha256:\(String(repeating: "a", count: 64))")),
            botID: "bot-a")
        guard case .notPerformed = file else {
            return XCTFail("file must be P's producer, got \(file)")
        }
    }

    func testCompositeDispatchesEachFamilyAndMissingIsNotPerformed() async {
        final class Seen: @unchecked Sendable {
            var kinds: [BotResourceIdentity.Kind] = []
        }
        let seen = Seen()
        let file = RecordingRechecker(outcome: .same(atMS: 1)) { _ in
            seen.kinds.append(.file)
        }
        let web = RecordingRechecker(outcome: .same(atMS: 2)) { _ in
            seen.kinds.append(.webURL)
        }
        let context = RecordingRechecker(outcome: .same(atMS: 3)) { _ in
            seen.kinds.append(.contextSource)
        }
        let composite = BotProvenanceRecheckerComposite(
            file: file, web: web, context: context)
        let baseline = BotProvenanceSourceVersion.known(
            BotKnownProvenanceSourceVersion(basis: .etag, value: "etag:e1"))
        for kind in [BotResourceIdentity.Kind.file, .webURL, .connectorResource, .contextSource] {
            _ = await composite.recheck(
                resource: BotResourceIdentity(kind: kind, key: "k"),
                baseline: baseline, botID: "bot-a")
        }
        XCTAssertEqual(seen.kinds, [.file, .webURL, .webURL, .contextSource],
                       "connector resources go to the web producer")

        let missing = BotProvenanceRecheckerComposite(file: nil, web: nil, context: nil)
        for kind in [BotResourceIdentity.Kind.file, .webURL, .connectorResource, .contextSource] {
            let outcome = await missing.recheck(
                resource: BotResourceIdentity(kind: kind, key: "k"),
                baseline: baseline, botID: "bot-a")
            guard case .notPerformed = outcome else {
                return XCTFail("missing \(kind) producer must be notPerformed, got \(outcome)")
            }
        }
    }
}
