// SPDX-License-Identifier: MIT

import Foundation

/// One write-time source baseline for a derived object (P lane, G-1 §3.2).
///
/// The baseline is captured once, in the same batched resolve that derives the
/// document's trust, and is stored only in the durable `memory.document_written`
/// event data under `derivation.sources[]`. It is never copied into the memory
/// document body and never re-written by reads.
///
/// A source that genuinely has no version still gets an explicit
/// `sourceVersion` of `.unknown(<reason>)`; omitting the entry is not allowed,
/// because that is indistinguishable from "the host never looked".
public enum BotSourceRole: String, Codable, Sendable, CaseIterable {
    case evidence
    case review
    case trigger
    case creator
    case recipient
    case basis
}

public struct BotSourceBaseline: Sendable, Equatable {
    /// Canonical `record://` reference the derived object used.
    public let record: String
    public let role: BotSourceRole?
    /// Required for observations (known or explicit unknown), absent for
    /// non-observation records (G-1 §2.2).
    public let sourceVersion: BotSourceVersion?

    public init(record: String, role: BotSourceRole? = nil,
                sourceVersion: BotSourceVersion?) {
        self.record = record
        self.role = role
        self.sourceVersion = sourceVersion
    }
}

public enum BotSourceBaselineError: Error, Sendable, Equatable {
    /// The resolver did not return a state for a reference. That is a resolver
    /// bug; fabricating an unknown baseline would hide it.
    case missingState(String)
}

/// Write-time derivation metadata carried by the durable
/// `memory.document_written` event data. It names the derived object and one
/// explicit baseline per source; it never lives in the memory document body and
/// is not part of the read result.
public struct BotMemoryDerivation: Codable, Sendable, Equatable {
    public struct ObjectIdentity: Codable, Sendable, Equatable {
        public let kind: String
        public let id: String
        public let version: Int

        public init(kind: String, id: String, version: Int) {
            self.kind = kind
            self.id = id
            self.version = version
        }
    }

    public let artifact: ObjectIdentity
    public let sources: [BotSourceBaseline]

    public init(artifact: ObjectIdentity, sources: [BotSourceBaseline]) {
        self.artifact = artifact
        self.sources = sources
    }

    public static func memory(path: String, version: Int,
                              sources: [BotSourceBaseline]) -> BotMemoryDerivation {
        BotMemoryDerivation(
            artifact: ObjectIdentity(kind: "memory", id: path, version: version),
            sources: sources)
    }
}

public enum BotSourceBaselineBuilder {
    /// Builds one baseline per distinct reference, preserving first-seen order.
    /// Callers pass `evidence + review.refs`; duplicates collapse.
    public static func baselines(for references: [String],
                                 states: [BotSourceState]) throws -> [BotSourceBaseline] {
        var byRef: [String: BotSourceState] = [:]
        for state in states {
            if byRef[state.ref] == nil { byRef[state.ref] = state }
        }
        var result: [BotSourceBaseline] = []
        var seen = Set<String>()
        for raw in references {
            let ref = BotRecordReference.canonicalize(raw) ?? raw
            guard seen.insert(ref).inserted else { continue }
            guard let state = byRef[ref] else {
                throw BotSourceBaselineError.missingState(ref)
            }
            result.append(BotSourceBaseline(
                record: ref,
                sourceVersion: state.version))
        }
        return result
    }

    /// Memory write path: evidence and review refs are two different roles but
    /// share one batch and one baseline list. A record used by both roles gets
    /// one entry per role, matching `derivation.sources` uniqueness on
    /// `(record, role)`.
    public static func baselines(evidence: [String], reviewRefs: [String],
                                 states: [BotSourceState]) throws -> [BotSourceBaseline] {
        var byRef: [String: BotSourceState] = [:]
        for state in states where byRef[state.ref] == nil { byRef[state.ref] = state }
        var result: [BotSourceBaseline] = []
        var seen = Set<String>()
        func append(_ raw: String, role: BotSourceRole) throws {
            let ref = BotRecordReference.canonicalize(raw) ?? raw
            let key = "\(role.rawValue)|\(ref)"
            guard seen.insert(key).inserted else { return }
            guard let state = byRef[ref] else {
                throw BotSourceBaselineError.missingState(ref)
            }
            result.append(BotSourceBaseline(
                record: ref, role: role, sourceVersion: state.version))
        }
        for ref in evidence { try append(ref, role: .evidence) }
        for ref in reviewRefs { try append(ref, role: .review) }
        return result
    }
}

/// Wire encoding of one baseline for `derivation.sources[]` (G-1 §3.2).
/// `sourceVersion` keeps the same known/unknown shape as `source_statuses`.
extension BotSourceBaseline: Codable {
    enum CodingKeys: String, CodingKey {
        case record
        case role
        case sourceVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        record = try container.decode(String.self, forKey: .record)
        guard BotRecordReference.canonicalize(record) != nil else {
            throw DecodingError.dataCorruptedError(
                forKey: .record, in: container,
                debugDescription: "baseline record must be a canonical record:// reference")
        }
        role = try container.decodeIfPresent(BotSourceRole.self, forKey: .role)
        sourceVersion = try container.decodeIfPresent(BotSourceVersion.self, forKey: .sourceVersion)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(record, forKey: .record)
        if let role { try container.encode(role, forKey: .role) }
        if let sourceVersion {
            try container.encode(sourceVersion, forKey: .sourceVersion)
        }
    }
}
