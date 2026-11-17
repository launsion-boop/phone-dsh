// SPDX-License-Identifier: MIT

import Foundation

/// How a source version was derived for one `record://` reference
/// (P lane, spec/bot/v2 §1.5.1 delta).
///
/// The host never invents a version. Today the only basis it can produce is a
/// SHA-256 content digest of the exact stored record; `etag`, `last-modified`
/// and `provider-version` are reserved for context sources that really carry
/// one and are added by the source provider when that boundary is frozen
/// (G-3 / N).
public enum BotSourceVersionKind: String, Codable, Sendable, CaseIterable {
    /// SHA-256 over the canonical record bytes; the only basis P can produce
    /// for the current session/event stores.
    case contentSHA256 = "content-sha256"
    case etag
    case lastModified = "last-modified"
    case providerVersion = "provider-version"
}

/// Why no source version could be produced for a resolved (or failed) record.
/// A `null` version without one of these reasons is not allowed: "unknown for
/// five different reasons" must stay distinguishable.
public enum BotSourceVersionUnknownReason: String, Codable, Sendable, CaseIterable {
    /// The reference does not resolve for this Bot: not owned, missing line,
    /// missing session log, or a foreign event.
    case recordUnresolved = "record-unresolved"
    /// The record was physically erased (event payload cleared or session-line
    /// tombstone); the version must never be reconstructed from the tombstone.
    case recordErased = "record-erased"
    /// The record exists but carries no canonical bytes to digest.
    case recordWithoutContent = "record-without-content"
    /// The source itself has no version the host can obtain. Kept for source
    /// providers that can prove a native version should exist but it is absent;
    /// it is not used to hide a missing record.
    case sourceUnversioned = "source-unversioned"
    /// The caller supplied something that is not a canonical `record://` ref.
    case invalidReference = "invalid-reference"
}

/// G-1 r13: what a `content-sha256` was computed over. A file-byte digest and a
/// record-readable-text digest are not interchangeable; missing means
/// `record-text` (conservative).
public enum BotSourceVersionSubject: String, Codable, Sendable, CaseIterable {
    case fileBytes = "file-bytes"
    case recordText = "record-text"
}

/// One version observed from the authoritative record store.
///
/// `basisRef` is the record the version was read from. For content digests it
/// is the referenced record itself; a future source provider may point at a
/// different observation record. The host does not persist this value: it is
/// recomputed on every read from the record store (input guide §5.1 retirement
/// condition).
public struct BotKnownSourceVersion: Sendable, Equatable {
    public let kind: BotSourceVersionKind
    /// Canonical token: `sha256:<hex>`, `rev:<value>`, `etag:<value>`.
    public let value: String
    /// The record's own observation time; nil when the record has no usable
    /// time (0/negative timestamps are "no time", never a fake epoch).
    public let observedAtMS: Int64?
    public let basisRef: String?
    /// Only meaningful for `content-sha256`; nil means the conservative
    /// `record-text` interpretation.
    public let subject: BotSourceVersionSubject?

    public init(kind: BotSourceVersionKind, value: String,
                observedAtMS: Int64?, basisRef: String?,
                subject: BotSourceVersionSubject? = nil) {
        self.kind = kind
        self.value = value
        self.observedAtMS = observedAtMS
        self.basisRef = basisRef
        self.subject = subject
    }
}

extension BotKnownSourceVersion: Codable {
    enum CodingKeys: String, CodingKey {
        case kind = "basis"
        case value
        case observedAtMS = "observed_at_ms"
        case basisRef = "basis_ref"
        case subject
    }
}

public enum BotSourceVersion: Sendable, Equatable {
    case known(BotKnownSourceVersion)
    case unknown(BotSourceVersionUnknownReason)

    public var known: BotKnownSourceVersion? {
        guard case let .known(value) = self else { return nil }
        return value
    }

    public var unknownReason: BotSourceVersionUnknownReason? {
        guard case let .unknown(reason) = self else { return nil }
        return reason
    }
}

/// Wire shape proposed to G-1 for `source_statuses[].version`: one object that
/// is either the known fields or `{"reason": "<closed enum>"}`. The two forms
/// are mutually exclusive, so a reader cannot see a value without its basis or
/// an unknown without its reason.
extension BotSourceVersion: Codable {
    private enum CodingKeys: String, CodingKey {
        case reason
        case basis
        case value
        case observedAtMS = "observed_at_ms"
        case basisRef = "basis_ref"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let reason = try container.decodeIfPresent(
            BotSourceVersionUnknownReason.self, forKey: .reason) {
            for key in [CodingKeys.basis, .value, .observedAtMS, .basisRef]
            where container.contains(key) {
                throw DecodingError.dataCorruptedError(
                    forKey: key, in: container,
                    debugDescription: "an unknown source version carries only a reason")
            }
            self = .unknown(reason)
            return
        }
        self = .known(try BotKnownSourceVersion(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case let .known(known):
            try known.encode(to: encoder)
        case let .unknown(reason):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(reason, forKey: .reason)
        }
    }
}

/// Host-side facts for one evidence reference. It deliberately does **not**
/// carry a live/stale/revoked verdict: current status is owned by the
/// provenance read model (L) so there is exactly one status authority. This
/// type only answers: does the record resolve for this Bot, is it erased, when
/// was it observed, what type/trust does it have, and what version can be read
/// from it.
public struct BotSourceState: Sendable, Equatable {
    public let ref: String
    public let resolved: Bool
    public let erased: Bool
    public let observedAtMS: Int64?
    public let recordType: String?
    public let trust: BotRecordTrust?
    /// The source version for an *observation*. `nil` means the source is not
    /// an observation (user message, Bot output, review assertion): G-1 §2.2
    /// allows its `sourceVersion` to be omitted, and the read view reports the
    /// record's own liveness instead of inventing a version.
    public let version: BotSourceVersion?
    /// Authorization grant under which this source was read, when the host has
    /// a real grant decision. It is carried into the baseline/derivation; a
    /// nil value is never replaced by a guessed grant.
    public let grantId: String?

    public init(ref: String, resolved: Bool, erased: Bool,
                observedAtMS: Int64?, recordType: String?,
                trust: BotRecordTrust?, version: BotSourceVersion?,
                grantId: String? = nil) {
        self.ref = ref
        self.resolved = resolved
        self.erased = erased
        self.observedAtMS = observedAtMS
        self.recordType = recordType
        self.trust = trust
        self.version = version
        self.grantId = grantId
    }
}

/// Wire shape proposed to G-1 for one `source_statuses` item. This is the only
/// host-derived status view: `current_status` is not part of it yet because the
/// provenance read model (L) owns that verdict and C merges it separately.
extension BotSourceState: Codable {
    enum CodingKeys: String, CodingKey {
        case ref
        case resolved
        case erased
        case observedAtMS = "observed_at_ms"
        case recordType = "record_type"
        case trust
        case version
        case grantId = "grant_id"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ref = try container.decode(String.self, forKey: .ref)
        resolved = try container.decode(Bool.self, forKey: .resolved)
        erased = try container.decode(Bool.self, forKey: .erased)
        observedAtMS = try container.decodeIfPresent(Int64.self, forKey: .observedAtMS)
        recordType = try container.decodeIfPresent(String.self, forKey: .recordType)
        if let raw = try container.decodeIfPresent(String.self, forKey: .trust) {
            guard let parsed = BotRecordTrust(rawValue: raw) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .trust, in: container,
                    debugDescription: "unknown record trust")
            }
            trust = parsed
        } else {
            trust = nil
        }
        grantId = try container.decodeIfPresent(String.self, forKey: .grantId)
        version = try container.decodeIfPresent(BotSourceVersion.self, forKey: .version)
    }

    /// Nullable members are encoded explicitly so "no time/type/trust" stays
    /// distinguishable from an omitted member.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ref, forKey: .ref)
        try container.encode(resolved, forKey: .resolved)
        try container.encode(erased, forKey: .erased)
        if let observedAtMS {
            try container.encode(observedAtMS, forKey: .observedAtMS)
        } else {
            try container.encodeNil(forKey: .observedAtMS)
        }
        if let recordType {
            try container.encode(recordType, forKey: .recordType)
        } else {
            try container.encodeNil(forKey: .recordType)
        }
        if let trust {
            try container.encode(trust.rawValue, forKey: .trust)
        } else {
            try container.encodeNil(forKey: .trust)
        }
        if let version {
            try container.encode(version, forKey: .version)
        }
        if let grantId {
            try container.encode(grantId, forKey: .grantId)
        }
    }
}

/// Batch resolver over the two authoritative Bot record stores.
///
/// - One call performs one event-log scan and at most one session-log read per
///   session, exactly like `BotRecordEvidenceResolving.evidenceSnapshot`; the
///   existing protocol keeps its signature and behaviour.
/// - The result has one entry per distinct input reference in first-seen
///   order. Invalid, foreign and erased references come back as entries rather
///   than being dropped, so a caller can report a reason for every input.
/// - More than 512 distinct references is rejected with
///   `BotRecordServiceError.invalidArguments`; the ceiling is the frozen
///   RecallMemory batch bound, not a per-call heuristic.
public protocol BotSourceStateResolving: Sendable {
    func sourceStates(for references: [String], callerBotID: String,
                      callerSessionID: String) async throws -> [BotSourceState]
}
