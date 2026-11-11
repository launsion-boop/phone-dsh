// SPDX-License-Identifier: MIT

import Foundation

/// The payload of the durable `erasure` event. An erasure never deletes a
/// header: the original sequence number, event id, type and payload digest
/// stay, and this event names what the host physically cleared.
public struct BotErasureEventData: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public struct Target: Codable, Sendable, Equatable {
        /// `memory` is the only target kind implemented by S6 step 1.
        public let kind: String
        public let scope: String?
        public let path: String?

        public init(kind: String, scope: String? = nil, path: String? = nil) {
            self.kind = kind
            self.scope = scope
            self.path = path
        }
    }

    public struct MemoryVersionRange: Codable, Sendable, Equatable {
        public let path: String
        public let scope: String
        public let versions: [Int]

        public init(path: String, scope: String, versions: [Int]) {
            self.path = path
            self.scope = scope
            self.versions = versions
        }
    }

    public struct ErasedEvent: Codable, Sendable, Equatable {
        public let record: String
        public let type: String
        public let digest: String
        public let payloadBytes: Int

        public init(record: String, type: String, digest: String, payloadBytes: Int) {
            self.record = record
            self.type = type
            self.digest = digest
            self.payloadBytes = payloadBytes
        }
    }

    public struct UncoveredRecord: Codable, Sendable, Equatable {
        public let record: String
        public let reason: String

        public init(record: String, reason: String) {
            self.record = record
            self.reason = reason
        }
    }

    public struct ErasedSessionRecord: Codable, Sendable, Equatable {
        public let record: String
        public let sessionId: String
        public let seq: Int
        public let epoch: Int?

        public init(record: String, sessionId: String, seq: Int, epoch: Int? = nil) {
            self.record = record
            self.sessionId = sessionId
            self.seq = seq
            self.epoch = epoch
        }
    }

    public struct SessionEpoch: Codable, Sendable, Equatable {
        public let fromSessionId: String
        public let toSessionId: String
        public let atMS: Int64

        public init(fromSessionId: String, toSessionId: String, atMS: Int64) {
            self.fromSessionId = fromSessionId
            self.toSessionId = toSessionId
            self.atMS = atMS
        }

        enum CodingKeys: String, CodingKey {
            case fromSessionId
            case toSessionId
            case atMS = "at_ms"
        }
    }

    public let schemaVersion: Int
    public let erasureId: String
    public let reason: String
    public let requestedBy: String
    public let atMS: Int64
    public let targets: [Target]
    public let memoryVersions: [MemoryVersionRange]
    public let erasedEvents: [ErasedEvent]
    public let erasedBytes: Int
    public let uncoveredRecords: [UncoveredRecord]
    public let legacyFactIDs: [String]
    public let erasedSessionRecords: [ErasedSessionRecord]
    public let sessionEpochs: [SessionEpoch]

    public init(
        schemaVersion: Int = BotErasureEventData.currentSchemaVersion,
        erasureId: String,
        reason: String,
        requestedBy: String = "user",
        atMS: Int64,
        targets: [Target],
        memoryVersions: [MemoryVersionRange] = [],
        erasedEvents: [ErasedEvent] = [],
        erasedBytes: Int? = nil,
        uncoveredRecords: [UncoveredRecord] = [],
        legacyFactIDs: [String] = [],
        erasedSessionRecords: [ErasedSessionRecord] = [],
        sessionEpochs: [SessionEpoch] = []
    ) {
        self.schemaVersion = schemaVersion
        self.erasureId = erasureId
        self.reason = reason
        self.requestedBy = requestedBy
        self.atMS = atMS
        self.targets = targets
        self.memoryVersions = memoryVersions
        self.erasedEvents = erasedEvents
        self.erasedBytes = erasedBytes ?? erasedEvents.reduce(0) { $0 + $1.payloadBytes }
        self.uncoveredRecords = uncoveredRecords
        self.legacyFactIDs = legacyFactIDs
        self.erasedSessionRecords = erasedSessionRecords
        self.sessionEpochs = sessionEpochs
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case erasureId
        case reason
        case requestedBy
        case atMS = "at_ms"
        case targets
        case memoryVersions
        case erasedEvents
        case erasedBytes
        case uncoveredRecords
        case legacyFactIDs
        case erasedSessionRecords
        case sessionEpochs
    }

    /// Step-1 erasure payloads predate the two session fields, so decoding
    /// them must not require the additive keys (P25 compatibility).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        erasureId = try container.decode(String.self, forKey: .erasureId)
        reason = try container.decode(String.self, forKey: .reason)
        requestedBy = try container.decode(String.self, forKey: .requestedBy)
        atMS = try container.decode(Int64.self, forKey: .atMS)
        targets = try container.decode([Target].self, forKey: .targets)
        memoryVersions = try container.decode([MemoryVersionRange].self, forKey: .memoryVersions)
        erasedEvents = try container.decode([ErasedEvent].self, forKey: .erasedEvents)
        erasedBytes = try container.decode(Int.self, forKey: .erasedBytes)
        uncoveredRecords = try container.decode([UncoveredRecord].self, forKey: .uncoveredRecords)
        legacyFactIDs = try container.decode([String].self, forKey: .legacyFactIDs)
        erasedSessionRecords = try container.decodeIfPresent(
            [ErasedSessionRecord].self, forKey: .erasedSessionRecords) ?? []
        sessionEpochs = try container.decodeIfPresent(
            [SessionEpoch].self, forKey: .sessionEpochs) ?? []
    }
}

extension BotEvent {
    /// A durable event whose payload was physically cleared. The host keeps the
    /// header/digest and materializes this sentinel so readers cannot mistake
    /// the event for its original content.
    public var isErasedPayload: Bool {
        guard case let .object(data) = self.data else { return false }
        return data["$erased"]?.boolValue == true
    }

    /// The erasure that cleared this payload, when it was cleared.
    public var erasureCommitSeq: Int? {
        guard isErasedPayload, case let .object(data) = self.data else { return nil }
        guard let number = data["$erasureCommitSeq"]?.numberValue,
              number.isFinite, number.rounded() == number, number >= 1 else { return nil }
        return Int(exactly: number)
    }

    func assigningData(_ data: BotJSONValue) -> Self {
        Self(schemaVersion: schemaVersion, type: type, eventId: eventId, commitSeq: commitSeq, time: time,
             origin: origin, traceId: traceId, principal: principal, causationId: causationId,
             correlationId: correlationId, turnId: turnId, runId: runId, attempt: attempt, batch: batch,
             ignorable: ignorable, data: data)
    }

    /// Builds one header-only event whose payload is the erased sentinel.
    static func erasedHeader(schemaVersion: Int, type: String, eventId: String, commitSeq: Int,
                             time: Int64, origin: BotEventOrigin, traceId: String,
                             principal: BotPrincipal, causationId: String?, correlationId: String?,
                             turnId: String?, runId: String?, attempt: Int?,
                             batch: BotEventBatchRef?, ignorable: Bool?, erasureCommitSeq: Int) -> Self {
        Self(
            schemaVersion: schemaVersion, type: type, eventId: eventId, commitSeq: commitSeq, time: time,
            origin: origin, traceId: traceId, principal: principal, causationId: causationId,
            correlationId: correlationId, turnId: turnId, runId: runId, attempt: attempt, batch: batch,
            ignorable: ignorable,
            data: .object([
                "$erased": .bool(true),
                "$erasureCommitSeq": .number(Double(erasureCommitSeq)),
            ]))
    }
}

/// One event whose payload the host is about to clear. The digest and byte
/// count are what the erasure event records after the bytes are gone.
public struct BotEventErasureTarget: Sendable, Equatable {
    public let commitSeq: Int
    public let type: String
    public let digest: String
    public let payloadBytes: Int

    public init(commitSeq: Int, type: String, digest: String, payloadBytes: Int) {
        self.commitSeq = commitSeq
        self.type = type
        self.digest = digest
        self.payloadBytes = payloadBytes
    }

    public var record: String { "record://event/\(commitSeq)" }
}

public struct BotEventErasureCommit: Sendable, Equatable {
    public let erasureCommitSeq: Int
    public let erased: [BotEventErasureTarget]

    public init(erasureCommitSeq: Int, erased: [BotEventErasureTarget]) {
        self.erasureCommitSeq = erasureCommitSeq
        self.erased = erased
    }
}
