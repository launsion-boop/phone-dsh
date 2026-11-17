// SPDX-License-Identifier: MIT

import Foundation
@testable import PhoneDSHBot

actor BotProvenanceTestLog: BotEventLog {
    private var storage: [Int: BotEvent] = [:]
    private var nextSeq = 1

    init() {}

    func append(_ event: BotEvent) async throws -> Int {
        let seq = nextSeq
        nextSeq += 1
        storage[seq] = event.assigningCommitSeq(seq)
        return seq
    }

    func append(_ event: BotEvent, at seq: Int) {
        storage[seq] = event.assigningCommitSeq(seq)
        nextSeq = max(nextSeq, seq + 1)
    }

    func events(after commitSeq: Int, limit: Int) async throws -> [BotEvent] {
        Array(storage.values
            .filter { ($0.commitSeq ?? 0) > commitSeq }
            .sorted { ($0.commitSeq ?? 0) < ($1.commitSeq ?? 0) }
            .prefix(limit))
    }

    func all() -> [BotEvent] {
        storage.values.sorted { ($0.commitSeq ?? 0) < ($1.commitSeq ?? 0) }
    }
}

enum ProvenanceTest {
    static let now: Int64 = 1_760_000_000_000

    static func event(
        seq: Int? = nil,
        type: String,
        eventId: String? = nil,
        at: Int64 = now,
        data: BotJSONValue,
        causationId: String? = nil,
        principalKind: String = "chat",
        botID: String? = "main",
        sessionID: String? = "gb-main"
    ) -> BotEvent {
        BotEvent(
            type: type,
            eventId: eventId ?? "\(type)-\(seq ?? 0)-\(UUID().uuidString)",
            commitSeq: seq,
            time: at,
            origin: .local(source: "ipc"),
            traceId: "trace-\(type)-\(seq ?? 0)",
            principal: BotPrincipal(botId: botID, sessionId: sessionID, kind: principalKind),
            causationId: causationId,
            correlationId: nil,
            data: data)
    }

    static func encoded(_ value: some Encodable) throws -> BotJSONValue {
        try BotJSONValue.parse(JSONEncoder().encode(value))
    }

    static func isoInstant(_ atMS: Int64) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date(timeIntervalSince1970: Double(atMS) / 1_000))
    }

    /// Real `conversation.tool_result` carrier: the v1 observation envelope is
    /// in the message text, not in an invented `data.observation` member.
    static func toolResultEvent(
        eventId: String,
        source: String,
        origin: String,
        owner: String,
        text: String = "observation body",
        resource: BotResourceIdentity? = nil,
        at: Int64 = now,
        sessionID: String = "gb-main",
        seq: Int = 1,
        grantId: String? = nil
    ) -> BotEvent {
        let envelope = BotObservationEnvelope(
            source: source, origin: origin, at: isoInstant(at), owner: owner,
            reference: .session(sessionID: sessionID, seq: seq), text: text)!
        var data: [String: BotJSONValue] = [
            "message": .object([
                "content": .array([
                    .object(["type": .string("text"), "text": .string(envelope.encoded())]),
                ]),
            ]),
        ]
        if let resource, let encoded = try? ProvenanceTest.encoded(resource) {
            data["resource"] = encoded
        }
        if let grantId { data["grant_id"] = .string(grantId) }
        return .init(
            type: "conversation.tool_result",
            eventId: eventId,
            time: at,
            origin: .dsh(sessionId: sessionID, seq: seq),
            traceId: "trace-\(eventId)",
            principal: BotPrincipal(botId: owner, sessionId: sessionID, kind: "chat"),
            causationId: nil,
            correlationId: nil,
            data: .object(data))
    }

    /// Real G-3 `context.observed` flat carrier.
    static func contextObservedEvent(
        eventId: String,
        source: String = "calendar",
        kind: String = "calendar.upcoming",
        owner: String = "bot-a",
        at: Int64 = now,
        resource: BotResourceIdentity? = nil,
        version: BotProvenanceSourceVersion? = nil,
        grantId: String? = nil,
        payload: BotJSONValue = .object(["id": .string("event-1")])
    ) -> BotEvent {
        var data: [String: BotJSONValue] = [
            "schema": .string("bot-context-observation/v1"),
            "source": .string(source),
            "kind": .string(kind),
            "observed_at_ms": .number(Double(at)),
            "owner_bot_id": .string(owner),
            "consent_generation": .number(1),
            "source_version": (try? ProvenanceTest.encoded(
                version ?? .unknown(reason: .sourceUnversioned))) ?? .object([:]),
            "uncertainty": .object([
                "level": .string("low"), "completeness": .string("complete"),
            ]),
            "delivery": .string("os"),
            "payload": payload,
            "dedupe_key": .string("\(source):\(kind):\(eventId)"),
            "wake_requested": .bool(false),
        ]
        if let resource, let encoded = try? ProvenanceTest.encoded(resource) {
            data["resource"] = encoded
        }
        if let grantId { data["grant_id"] = .string(grantId) }
        return .init(
            type: "context.observed",
            eventId: eventId,
            time: at,
            origin: .local(source: "runtime"),
            traceId: "trace-\(eventId)",
            principal: BotPrincipal(botId: owner, sessionId: nil, kind: "proactive"),
            causationId: nil,
            correlationId: nil,
            ignorable: true,
            data: .object(data))
    }

    static func erasureEvent(erasureId: String, at: Int64 = now,
                             eventRecords: [String]) -> BotEvent {
        .init(
            type: "erasure",
            eventId: "erasure-\(erasureId)",
            time: at,
            origin: .local(source: "memory-service"),
            traceId: "trace-\(erasureId)",
            principal: BotPrincipal(botId: "main", sessionId: nil, kind: "ipc"),
            causationId: nil,
            correlationId: nil,
            data: .object([
                "schemaVersion": .number(1),
                "erasureId": .string(erasureId),
                "reason": .string("memory-document-erase"),
                "requestedBy": .string("user"),
                "at_ms": .number(Double(at)),
                "targets": .array([]),
                "memoryVersions": .array([]),
                "erasedEvents": .array(eventRecords.map { record in
                    .object([
                        "record": .string(record),
                        "type": .string("conversation.user_message"),
                        "digest": .string("sha256:test"),
                        "payloadBytes": .number(10),
                    ])
                }),
                "erasedBytes": .number(10),
                "uncoveredRecords": .array([]),
                "legacyFactIDs": .array([]),
                "erasedSessionRecords": .array([]),
                "sessionEpochs": .array([]),
            ]))
    }
}

struct BotProvenanceTestRechecker: BotProvenanceRechecking {
    var outcome: String?
    var atMS: Int64?

    func recheck(resource: BotResourceIdentity,
                 baseline: BotProvenanceSourceVersion,
                 botID: String?) async -> BotProvenanceRecheckOutcome {
        switch outcome {
        case "ok":
            return .same(atMS: atMS ?? baseline.knownFields?.observedAtMS ?? 0)
        case "denied":
            return .denied(detail: nil)
        case "unavailable":
            return .unavailable(detail: nil)
        default:
            return .notPerformed
        }
    }
}

actor BotProvenanceRecordingResolver: BotProvenanceEvidenceResolving {
    private(set) var seenRefs: [String] = []
    var facts: [String: BotProvenanceSourceFact]

    init(facts: [String: BotProvenanceSourceFact] = [:]) {
        self.facts = facts
    }

    func sourceFacts(for refs: [String], botID: String?, sessionID: String?)
        async -> [String: BotProvenanceSourceFact] {
        seenRefs.append(contentsOf: refs)
        var result: [String: BotProvenanceSourceFact] = [:]
        for ref in refs {
            if let fact = facts[ref] { result[ref] = fact }
        }
        return result
    }
}

struct BotProvenanceTestSkillRechecker: BotSkillRechecking {
    var outcome: BotSkillRecheckOutcome

    func recheckSkill(identity: BotSkillIdentity, file: String,
                      expectedSHA256: String) async -> BotSkillRecheckOutcome {
        outcome
    }
}

struct BotProvenanceTestResolver: BotProvenanceEvidenceResolving {
    var facts: [String: BotProvenanceSourceFact]

    func sourceFacts(for refs: [String], botID: String?, sessionID: String?)
        async -> [String: BotProvenanceSourceFact] {
        var result: [String: BotProvenanceSourceFact] = [:]
        for ref in refs {
            if let fact = facts[ref] { result[ref] = fact }
        }
        return result
    }
}

// MARK: - G-1 golden decoding

struct ProvenanceGolden: Decodable {
    struct Case: Decodable {
        struct Record: Decodable {
            var kind: String
            var type: String
            var botId: String?
            var atMs: Int64?
            var rpcId: String?
            var observation: Observation?
            var text: String?
            var version: BotProvenanceSourceVersion?
            var resource: BotResourceIdentity?
            var erased: Bool?

            struct Observation: Decodable {
                var source: String
                var origin: String
                var owner: String?
            }

            enum CodingKeys: String, CodingKey {
                case kind, type, botId, atMs = "at_ms", rpcId, observation, text, version, erased
            }
        }

        struct Review: Decodable {
            var state: String
            var basis: String?
            var refs: [String]?
        }

        struct Artifact: Decodable {
            var carrier: String?
            var derivation: BotDerivation
            var review: Review?
        }

        struct Erasure: Decodable {
            var seq: Int
            var records: [String]
        }

        struct Grant: Decodable {
            var id: String
            var revokedAtSeq: Int?

            enum CodingKeys: String, CodingKey {
                case id, revokedAtSeq = "revoked_at_seq"
            }
        }

        var name: String
        var records: [String: Record]
        var artifacts: [Artifact]
        var subject: Int
        var erasures: [Erasure]
        var grants: [Grant]
        var scanExceeded: Bool?
        var recheck: String?
        var checkedAtMS: Int64?
        var expected: BotJSONValue

        enum CodingKeys: String, CodingKey {
            case name, records, artifacts, subject, erasures, grants, recheck
            case scanExceeded = "scan_exceeded"
            case checkedAtMS = "checked_at_ms"
            case expected
        }
    }

    struct Vectors: Decodable {
        var derivation: [BotJSONValue]?
        var sourceRevision: [BotJSONValue]?
        var status: [BotJSONValue]?
        var view: [BotJSONValue]?

        enum CodingKeys: String, CodingKey {
            case derivation
            case sourceRevision = "source_revision"
            case status
            case view
        }
    }

    var schemaVersion: Int
    var cases: [Case]
    var valid: Vectors
    var invalid: Vectors
    var knownRevisions: [BotJSONValue]
    var invalidKnownRevisions: [BotJSONValue]

    enum CodingKeys: String, CodingKey {
        case schemaVersion, cases, valid, invalid
        case knownRevisions = "known_revisions"
        case invalidKnownRevisions = "invalid_known_revisions"
    }

    static func load() throws -> ProvenanceGolden {
        // The G-1 contract lives in the contract owner's worktree until C
        // integrates it. A fixed input may be supplied by revision for local
        // conformance runs; production/CI finds the file in the merged tree.
        if let override = ProcessInfo.processInfo.environment["PDSH_PROVENANCE_GOLDEN"],
           !override.isEmpty {
            return try JSONDecoder().decode(
                ProvenanceGolden.self, from: Data(contentsOf: URL(fileURLWithPath: override)))
        }
        var candidate = URL(fileURLWithPath: #filePath)
        for _ in 0..<10 {
            candidate.deleteLastPathComponent()
            let url = candidate
                .appendingPathComponent("spec/bot/v2/golden/provenance.json")
            if FileManager.default.fileExists(atPath: url.path) {
                return try JSONDecoder().decode(
                    ProvenanceGolden.self, from: Data(contentsOf: url))
            }
        }
        throw NSError(domain: "ProvenanceGolden", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "golden not found"])
    }
}
