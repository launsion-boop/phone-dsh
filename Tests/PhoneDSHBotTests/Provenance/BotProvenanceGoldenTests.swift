// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import XCTest
@testable import PhoneDSHBot

/// L conformance against the frozen G-1 vectors
/// (`spec/bot/v2/golden/provenance.json` @ 45ab603e…). Each case is translated
/// into durable events (derivation rides in the carrier event), session records
/// are supplied as P facts, and the service must reproduce the frozen view.
final class BotProvenanceGoldenTests: XCTestCase {
    func testAllGoldenCases() async throws {
        let golden = try ProvenanceGolden.load()
        XCTAssertEqual(golden.cases.count, 23)
        for testCase in golden.cases {
            let (service, artifact) = try await makeService(for: testCase)
            let view = try await service.currentState(for: artifact)
            try assertView(view, matches: testCase.expected, name: testCase.name)
        }
    }

    func testValidDerivationFixturesPrepare() async throws {
        let golden = try ProvenanceGolden.load()
        let log = BotProvenanceTestLog()
        let service = BotProvenanceService(eventLog: log)
        for (index, value) in (golden.valid.derivation ?? []).enumerated() {
            let derivation = try JSONDecoder().decode(
                BotDerivation.self, from: value.encoded())
            let prepared = try await service.prepareBaseline(derivation)
            XCTAssertNotNil(prepared["artifact"], "valid.derivation[\(index)]")
            XCTAssertNotNil(prepared["sources"], "valid.derivation[\(index)]")
        }
    }

    func testInvalidDerivationFixturesReject() async throws {
        let golden = try ProvenanceGolden.load()
        let log = BotProvenanceTestLog()
        let service = BotProvenanceService(eventLog: log)
        for (index, value) in (golden.invalid.derivation ?? []).enumerated() {
            var rejected = false
            do {
                let derivation = try JSONDecoder().decode(
                    BotDerivation.self, from: value.encoded())
                _ = try await service.prepareBaseline(derivation)
            } catch {
                rejected = true
            }
            if !rejected {
                rejected = provenanceShapeViolation(value)
            }
            XCTAssertTrue(rejected, "invalid.derivation[\(index)] unexpectedly accepted")
        }
    }

    func testKnownRevisionFixtures() throws {
        let golden = try ProvenanceGolden.load()
        for (index, value) in golden.knownRevisions.enumerated() {
            let revision = try JSONDecoder().decode(
                BotProvenanceSourceVersion.self, from: value.encoded())
            XCTAssertNil(revision.validationError(), "known_revisions[\(index)]")
        }
        for (index, value) in golden.invalidKnownRevisions.enumerated() {
            var rejected = false
            if let revision = try? JSONDecoder().decode(
                BotProvenanceSourceVersion.self, from: value.encoded()) {
                rejected = revision.validationError() != nil
            } else {
                rejected = true
            }
            XCTAssertTrue(rejected, "invalid_known_revisions[\(index)] accepted")
        }
        for (index, value) in (golden.invalid.sourceRevision ?? []).enumerated() {
            var rejected = false
            if let revision = try? JSONDecoder().decode(
                BotProvenanceSourceVersion.self, from: value.encoded()) {
                rejected = revision.validationError() != nil
            } else {
                rejected = true
            }
            XCTAssertTrue(rejected, "invalid.source_revision[\(index)] accepted")
        }
        for (index, value) in (golden.valid.sourceRevision ?? []).enumerated() {
            let revision = try JSONDecoder().decode(
                BotProvenanceSourceVersion.self, from: value.encoded())
            XCTAssertNil(revision.validationError(), "valid.source_revision[\(index)]")
        }
    }

    // MARK: - harness

    private func makeService(for testCase: ProvenanceGolden.Case) async throws
        -> (BotProvenanceService, BotDerivedRef) {
        let log = BotProvenanceTestLog()
        let artifactsByCarrier = Dictionary(
            uniqueKeysWithValues: testCase.artifacts.compactMap { artifact in
                artifact.carrier.map { ($0, artifact) }
            })
        for (ref, record) in testCase.records where record.kind == "event" {
            guard let seq = eventSeq(ref) else { continue }
            var data: [String: BotJSONValue] = [:]
            if let artifact = artifactsByCarrier[ref] {
                data["derivation"] = try ProvenanceTest.encoded(artifact.derivation)
                if let review = artifact.review {
                    var reviewData: [String: BotJSONValue] = [
                        "state": .string(review.state),
                    ]
                    if let basis = review.basis { reviewData["basis"] = .string(basis) }
                    if let refs = review.refs {
                        reviewData["refs"] = .array(refs.map(BotJSONValue.string))
                    }
                    data["review"] = .object(reviewData)
                }
            }
            await log.append(ProvenanceTest.event(
                seq: seq, type: record.type, eventId: "carrier-\(seq)",
                at: record.atMs ?? 1_000, data: .object(data),
                botID: record.botId ?? "bot-a", sessionID: "gb-main"), at: seq)
        }
        var used = Set((try await log.all()).compactMap(\.commitSeq))
        for erasure in testCase.erasures {
            let seq = used.contains(erasure.seq) ? (used.max() ?? 0) + 1 : erasure.seq
            used.insert(seq)
            var event = ProvenanceTest.erasureEvent(
                erasureId: "case-\(testCase.name)", eventRecords: erasure.records)
            event = event.assigningCommitSeq(seq)
            await log.append(event, at: seq)
        }
        for grant in testCase.grants {
            let seq = grant.revokedAtSeq ?? ((used.max() ?? 0) + 1)
            let final = used.contains(seq) ? (used.max() ?? 0) + 1 : seq
            used.insert(final)
            await log.append(ProvenanceTest.event(
                seq: final, type: "grant.revoked", eventId: "revoke-\(grant.id)",
                data: .object(["grantId": .string(grant.id)])), at: final)
        }

        var syntheticSeq = 10_000
        for (ref, record) in testCase.records where record.kind == "session" {
            guard let observation = record.observation,
                  let seq = sessionSeq(ref) else { continue }
            // Real G-1 r11 carrier: the observation envelope is the message
            // text of conversation.tool_result, not `data.observation`.
            let event = ProvenanceTest.toolResultEvent(
                eventId: "observation-\(ref)",
                source: observation.source,
                origin: observation.origin,
                owner: observation.owner ?? record.botId ?? "bot-a",
                text: record.text ?? "observation body",
                resource: record.resource,
                at: record.atMs ?? 1_000,
                sessionID: "gb-main",
                seq: seq)
            await log.append(event, at: syntheticSeq)
            syntheticSeq += 1
        }
        if testCase.scanExceeded == true {
            // More than 32 distinct resources trips the G-1 scan window.
            for index in 0..<40 {
                let event = ProvenanceTest.toolResultEvent(
                    eventId: "scan-filler-\(index)",
                    source: "web",
                    origin: "https://scan.example/\(index)",
                    owner: "bot-a",
                    at: 2_000 + Int64(index),
                    sessionID: "gb-main", seq: 100 + index)
                await log.append(event, at: syntheticSeq)
                syntheticSeq += 1
            }
        }
        let facts = makeFacts(for: testCase)
        let resolver = BotProvenanceTestResolver(facts: facts)
        let rechecker = BotProvenanceTestRechecker(
            outcome: testCase.recheck, atMS: testCase.checkedAtMS)
        let service = BotProvenanceService(
            eventLog: log, resolver: resolver, rechecker: rechecker)
        let subject = testCase.artifacts[testCase.subject].derivation.artifact
        return (service, subject)
    }

    private func makeFacts(for testCase: ProvenanceGolden.Case)
        -> [String: BotProvenanceSourceFact] {
        var facts: [String: BotProvenanceSourceFact] = [:]
        for (ref, record) in testCase.records {
            let identity = record.observation.map { "\($0.source)\u{1F}\($0.origin)" }
            let revision = recordRevision(record, ref: ref)
            let fact = BotProvenanceSourceFact(
                resolved: true,
                erased: record.erased == true || testCase.erasures.contains {
                    $0.records.contains(ref)
                },
                observedAtMS: record.atMs,
                recordType: record.type,
                trust: trust(record),
                version: revision)
            facts[ref] = fact
        }
        return facts
    }

    private func recordRevision(_ record: ProvenanceGolden.Case.Record,
                                ref: String) -> BotProvenanceSourceVersion? {
        guard record.observation != nil else { return record.version }
        if let version = record.version {
            switch version {
            case let .known(known):
                return .known(basis: known.basis, value: known.value,
                              observedAtMS: known.observedAtMS,
                              basisRef: known.basisRef ?? ref,
                              subject: known.subject)
            case let .unknown(reason, observed, basisRef):
                return .unknown(reason: reason, observedAtMS: observed,
                                basisRef: basisRef ?? ref)
            }
        }
        if let text = record.text {
            let digest = SHA256.hash(data: Data(text.utf8))
                .map { String(format: "%02x", $0) }.joined()
            return .known(basis: .contentSHA256, value: "sha256:\(digest)",
                          observedAtMS: record.atMs, basisRef: ref)
        }
        return .unknown(reason: .recordWithoutContent, observedAtMS: record.atMs,
                        basisRef: ref)
    }

    private func trust(_ record: ProvenanceGolden.Case.Record) -> String? {
        if record.observation != nil { return "observation" }
        switch record.type {
        case "user/message":
            let rpc = record.rpcId ?? ""
            return rpc.isEmpty || rpc.hasPrefix("bot-") || rpc.hasPrefix("user-action:")
                || rpc.hasPrefix("card-answer:") ? "user" : "assistant"
        case "tool/result":
            return "assistant"
        default:
            return nil
        }
    }

    private func sessionSeq(_ ref: String) -> Int? {
        guard ref.hasPrefix("record://session/"),
              let hash = ref.lastIndex(of: "#") else { return nil }
        return Int(ref[ref.index(after: hash)...])
    }

    private func eventSeq(_ ref: String) -> Int? {
        guard ref.hasPrefix("record://event/") else { return nil }
        return Int(String(ref.split(separator: "/").last ?? ""))
    }

    private func recordOrder(_ ref: String) -> String {
        if ref.hasPrefix("record://event/") {
            return "1|\(String(format: "%012d", eventSeq(ref) ?? 0))|"
        }
        let tail = ref.replacingOccurrences(of: "record://session/", with: "")
        let parts = tail.split(separator: "#", maxSplits: 1).map(String.init)
        return "0|\(String(format: "%012d", Int(parts.last ?? "") ?? 0))|\(parts.first ?? "")"
    }

    // MARK: - comparison

    private func assertView(_ view: BotDerivationView, matches expectedValue: BotJSONValue,
                            name: String) throws {
        var actual = try jsonObject(view)
        actual.removeValue(forKey: "carrier")
        actual.removeValue(forKey: "generation")
        actual.removeValue(forKey: "truncated")
        var actualSources: [[String: Any]] = []
        for source in view.sources {
            var status = try jsonObject(source.status)
            status.removeValue(forKey: "roles")
            actualSources.append(status)
        }
        actualSources.sort { ($0["ref"] as? String ?? "") < ($1["ref"] as? String ?? "") }
        actual["sources"] = actualSources

        var expected = try JSONSerialization.jsonObject(
            with: expectedValue.encoded()) as? [String: Any] ?? [:]
        var expectedSources = (expected["sources"] as? [[String: Any]]) ?? []
        expectedSources.sort { ($0["ref"] as? String ?? "") < ($1["ref"] as? String ?? "") }
        expected["sources"] = expectedSources

        let keys = ["artifact", "state", "reasons", "review_effective", "upstream", "sources"]
        var actualSelected: [String: Any] = [:]
        var expectedSelected: [String: Any] = [:]
        for key in keys {
            actualSelected[key] = actual[key]
            expectedSelected[key] = expected[key]
        }
        let actualData = try JSONSerialization.data(
            withJSONObject: actualSelected, options: [.sortedKeys])
        let expectedData = try JSONSerialization.data(
            withJSONObject: expectedSelected, options: [.sortedKeys])
        XCTAssertEqual(
            String(decoding: actualData, as: UTF8.self),
            String(decoding: expectedData, as: UTF8.self),
            "case \(name)")
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Extra members that Codable ignores but the frozen schema rejects.
    private func provenanceShapeViolation(_ value: BotJSONValue) -> Bool {
        guard let root = value.objectValue else { return true }
        let allowedRoot: Set<String> = ["artifact", "sources", "basis"]
        if !Set(root.keys).isSubset(of: allowedRoot) { return true }
        guard let artifact = root["artifact"]?.objectValue,
              Set(artifact.keys).isSubset(of: ["kind", "id", "version"]) else { return true }
        for source in root["sources"]?.arrayValue ?? [] {
            guard let object = source.objectValue,
                  Set(object.keys).isSubset(
                    of: ["record", "role", "sourceVersion", "grantId"]) else { return true }
        }
        return false
    }
}
