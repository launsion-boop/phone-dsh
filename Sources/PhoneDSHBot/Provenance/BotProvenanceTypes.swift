// SPDX-License-Identifier: MIT

import Foundation

// G-1 frozen contract types (contracts/G-1.md @ 45ab603e38d0b6aae3d82f4d533a6b15ee0d4507).
// Shapes mirror spec/bot/v2/{derivation,source-revision,source-status,derivation-view}.schema.json.

/// One derived artifact identity. `version` is the artifact's own real
/// monotonic revision (memory document version, routine snapshot version); it
/// is never a source revision.
public struct BotDerivedRef: Codable, Sendable, Hashable, Comparable {
    public var kind: BotDerivedKind
    public var id: String
    public var version: Int?

    public init(kind: BotDerivedKind, id: String, version: Int? = nil) {
        self.kind = kind
        self.id = id
        self.version = version
    }

    public var canonical: String {
        version.map { "\(kind.rawValue):\(id)@\($0)" } ?? "\(kind.rawValue):\(id)"
    }

    public static func < (lhs: BotDerivedRef, rhs: BotDerivedRef) -> Bool {
        if lhs.kind.rawValue != rhs.kind.rawValue { return lhs.kind.rawValue < rhs.kind.rawValue }
        if lhs.id != rhs.id { return lhs.id < rhs.id }
        return (lhs.version ?? 0) < (rhs.version ?? 0)
    }
}

public enum BotDerivedKind: String, Codable, Sendable, CaseIterable {
    case memory
    case review
    case routine
    case proactive
    case notification
    case delivery
    case suggestion
    case draft
    case skill
    case workspaceFile
}

/// G-1 r5 resource identity: channel is not a resource. The latest index is
/// keyed by (kind,key,owner,scope), never by source+origin.
public struct BotResourceIdentity: Codable, Sendable, Equatable, Hashable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case webURL = "web-url"
        case connectorResource = "connector-resource"
        case file
        case workspaceFile = "workspace-file"
        case contextSource = "context-source"
        case provider
    }

    public var kind: Kind
    public var key: String
    public var owner: String?
    public var scope: String?

    public init(kind: Kind, key: String, owner: String? = nil, scope: String? = nil) {
        self.kind = kind
        self.key = key
        self.owner = owner
        self.scope = scope
    }

    public var canonical: String {
        "\(kind.rawValue)\u{1F}\(key)\u{1F}\(owner ?? "")\u{1F}\(scope ?? "")"
    }

    public var kindKey: String { "\(kind.rawValue)\u{1F}\(key)" }
}

public enum BotProvenanceRecheckOutcome: Sendable, Equatable {
    case same(atMS: Int64)
    case changed(version: BotProvenanceSourceVersion, atMS: Int64)
    case revisionBasisMismatch(atMS: Int64)
    case denied(detail: String?)
    case unavailable(detail: String?)
    case notPerformed
}

/// G-1 skill identity: (source, owner?, name). Legacy events without source are
/// host/global. Project roots are per-Bot and must never merge by name.
public enum BotSkillSource: String, Codable, Sendable, CaseIterable {
    case projectDsh = "project-dsh"
    case projectAgents = "project-agents"
    case userDsh = "user-dsh"
    case userAgents = "user-agents"
    case custom
    case bundled
}

public struct BotSkillIdentity: Codable, Sendable, Equatable, Hashable {
    public var source: BotSkillSource
    public var ownerBotID: String?
    public var name: String

    public init(source: BotSkillSource = .userDsh,
                ownerBotID: String? = nil, name: String) {
        self.source = source
        self.ownerBotID = ownerBotID
        self.name = name
    }

    public var isProject: Bool {
        source == .projectDsh || source == .projectAgents
    }
}

/// Last durable `skill.changed` for one skill. Host reconciliation uses this to
/// decide whether a file hash already has a carrier and what the next revision is.
public struct BotSkillChangeSnapshot: Sendable, Equatable {
    public var name: String
    public var file: String
    public var revision: Int
    public var action: String
    public var source: BotSkillSource
    public var ownerBotID: String?
    public var contentSHA256: String?
    public var previousSHA256: String?
    public var bytes: Int?
    public var carrier: String
    public var atMS: Int64

    public init(name: String, file: String, revision: Int, action: String,
                source: BotSkillSource = .userDsh, ownerBotID: String? = nil,
                contentSHA256: String?, previousSHA256: String?, bytes: Int?,
                carrier: String, atMS: Int64) {
        self.name = name
        self.file = file
        self.revision = revision
        self.action = action
        self.source = source
        self.ownerBotID = ownerBotID
        self.contentSHA256 = contentSHA256
        self.previousSHA256 = previousSHA256
        self.bytes = bytes
        self.carrier = carrier
        self.atMS = atMS
    }
}

public enum BotSkillRecheckOutcome: Sendable, Equatable {
    case same(atMS: Int64)
    case changed(actualSHA256: String, atMS: Int64)
    case denied(detail: String?)
    case unavailable(detail: String?)
    case notPerformed
    /// Known-invalid lineage: the host deliberately did not read the file.
    case skipped
}

public protocol BotSkillRootResolving: Sendable {
    func root(for source: BotSkillSource, ownerBotID: String?) -> URL?
}

public protocol BotSkillRechecking: Sendable {
    func recheckSkill(identity: BotSkillIdentity, file: String,
                      expectedSHA256: String) async -> BotSkillRecheckOutcome
}

public protocol BotProvenanceRechecking: Sendable {
    func recheck(resource: BotResourceIdentity,
                 baseline: BotProvenanceSourceVersion,
                 botID: String?) async -> BotProvenanceRecheckOutcome
}

public enum BotDerivationRole: String, Codable, Sendable, CaseIterable {
    case evidence
    case review
    case trigger
    case creator
    case recipient
    case basis

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = Self(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "unknown derivation role \(raw)")
        }
        self = value
    }
}

/// G-1 r13 subject of a content-sha256 version.
public enum BotProvenanceSourceVersionSubject: String, Codable, Sendable, CaseIterable {
    case fileBytes = "file-bytes"
    case recordText = "record-text"
}

public struct BotKnownProvenanceSourceVersion: Codable, Sendable, Equatable, Hashable {
    public var basis: BotProvenanceSourceVersion.BotSourceBasis
    public var value: String
    public var observedAtMS: Int64?
    public var basisRef: String?
    /// Only meaningful for content-sha256; nil is conservatively record-text.
    public var subject: BotProvenanceSourceVersionSubject?

    public init(basis: BotProvenanceSourceVersion.BotSourceBasis, value: String,
                observedAtMS: Int64? = nil, basisRef: String? = nil,
                subject: BotProvenanceSourceVersionSubject? = nil) {
        self.basis = basis
        self.value = value
        self.observedAtMS = observedAtMS
        self.basisRef = basisRef
        self.subject = subject
    }
}

/// Closed source-revision shape. Exactly one of known or unknown is encoded;
/// known values must carry their basis prefix.
public enum BotProvenanceSourceVersion: Codable, Sendable, Equatable, Hashable {
    case known(BotKnownProvenanceSourceVersion)
    case unknown(reason: BotSourceUnknownReason,
                 observedAtMS: Int64? = nil, basisRef: String? = nil)

    public enum BotSourceBasis: String, Codable, Sendable, CaseIterable {
        case contentSHA256 = "content-sha256"
        case etag
        case lastModified = "last-modified"
        case providerVersion = "provider-version"
    }

    public enum BotSourceUnknownReason: String, Codable, Sendable, CaseIterable {
        case recordUnresolved = "record-unresolved"
        case recordErased = "record-erased"
        case recordWithoutContent = "record-without-content"
        case sourceUnversioned = "source-unversioned"
        case invalidReference = "invalid-reference"
    }

    public static func known(
        basis: BotSourceBasis, value: String, observedAtMS: Int64? = nil,
        basisRef: String? = nil, subject: BotProvenanceSourceVersionSubject? = nil
    ) -> Self {
        .known(BotKnownProvenanceSourceVersion(
            basis: basis, value: value, observedAtMS: observedAtMS,
            basisRef: basisRef, subject: subject))
    }

    public var knownFields: (basis: BotSourceBasis, value: String,
                             observedAtMS: Int64?, basisRef: String?,
                             subject: BotProvenanceSourceVersionSubject?)? {
        guard case let .known(known) = self else { return nil }
        return (known.basis, known.value, known.observedAtMS,
                known.basisRef, known.subject)
    }

    public var knownValue: String? {
        guard case let .known(known) = self else { return nil }
        return known.value
    }

    public var knownBasis: BotSourceBasis? {
        guard case let .known(known) = self else { return nil }
        return known.basis
    }

    public var subject: BotProvenanceSourceVersionSubject? {
        guard case let .known(known) = self else { return nil }
        return known.subject ?? (known.basis == .contentSHA256 ? .recordText : nil)
    }

    enum CodingKeys: String, CodingKey {
        case basis
        case value
        case observedAtMS = "observed_at_ms"
        case basisRef = "basis_ref"
        case reason
        case subject
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let observed = try container.decodeIfPresent(Int64.self, forKey: .observedAtMS)
        let basisRef = try container.decodeIfPresent(String.self, forKey: .basisRef)
        if let reasonText = try container.decodeIfPresent(String.self, forKey: .reason) {
            guard container.contains(.basis) == false,
                  container.contains(.value) == false,
                  let reason = BotSourceUnknownReason(rawValue: reasonText) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .reason, in: container,
                    debugDescription: "source revision mixes known and unknown members")
            }
            self = .unknown(reason: reason, observedAtMS: observed, basisRef: basisRef)
            return
        }
        guard let basisText = try container.decodeIfPresent(String.self, forKey: .basis),
              let basis = BotSourceBasis(rawValue: basisText),
              let value = try container.decodeIfPresent(String.self, forKey: .value),
              !value.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .basis, in: container,
                debugDescription: "known source revision needs a valid basis and value")
        }
        let subject = try container.decodeIfPresent(
            BotProvenanceSourceVersionSubject.self, forKey: .subject)
        self = .known(BotKnownProvenanceSourceVersion(
            basis: basis, value: value, observedAtMS: observed,
            basisRef: basisRef, subject: subject))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .known(known):
            try container.encode(known.basis, forKey: .basis)
            try container.encode(known.value, forKey: .value)
            if let observed = known.observedAtMS {
                try container.encode(observed, forKey: .observedAtMS)
            }
            if let basisRef = known.basisRef {
                try container.encode(basisRef, forKey: .basisRef)
            }
            if let subject = known.subject {
                try container.encode(subject, forKey: .subject)
            }
        case let .unknown(reason, observed, basisRef):
            try container.encode(reason, forKey: .reason)
            if let observed { try container.encode(observed, forKey: .observedAtMS) }
            if let basisRef { try container.encode(basisRef, forKey: .basisRef) }
        }
    }

    /// The basis-prefix rule from provenance.md §2.1. Returns a diagnostic or
    /// nil when the value is valid for its basis.
    public func validationError() -> String? {
        switch self {
        case let .known(known):
            let basis = known.basis
            let value = known.value
            let basisRef = known.basisRef
            switch basis {
            case .contentSHA256:
                let hex = value.hasPrefix("sha256:") ? value.dropFirst(7) : ""
                guard hex.count == 64,
                      hex.allSatisfy({ "0123456789abcdef".contains($0) }) else {
                    return "content-sha256 value must be sha256:<64 lowercase hex>"
                }
            case .etag:
                guard value.hasPrefix("etag:"), value.count > 5 else {
                    return "etag value must be etag:<opaque>"
                }
            case .lastModified:
                guard value.hasPrefix("last-modified:"), value.count > 14 else {
                    return "last-modified value must be last-modified:<date>"
                }
            case .providerVersion:
                guard value.hasPrefix("rev:"), value.count > 4 else {
                    return "provider-version value must be rev:<opaque>"
                }
            }
            if let basisRef, BotRecordReference.parse(basisRef) == nil {
                return "basis_ref is not a canonical record reference"
            }
            if known.subject != nil, basis != .contentSHA256 {
                return "subject is only valid for content-sha256"
            }
        case let .unknown(_, _, basisRef):
            if let basisRef, BotRecordReference.parse(basisRef) == nil {
                return "basis_ref is not a canonical record reference"
            }
        }
        return nil
    }
}

/// One source edge of a derivation assertion.
public struct BotDerivationSource: Codable, Sendable, Equatable, Hashable {
    public var record: String
    public var role: BotDerivationRole?
    public var resource: BotResourceIdentity?
    public var sourceVersion: BotProvenanceSourceVersion?
    public var grantId: String?

    public init(record: String, role: BotDerivationRole? = nil,
                resource: BotResourceIdentity? = nil,
                sourceVersion: BotProvenanceSourceVersion? = nil,
                grantId: String? = nil) {
        self.record = record
        self.role = role
        self.resource = resource
        self.sourceVersion = sourceVersion
        self.grantId = grantId
    }

    enum CodingKeys: String, CodingKey {
        case record
        case role
        case resource
        case sourceVersion
        case grantId
    }
}

/// The G-1 `derivation` member of an existing durable event data object. The
/// carrying event is the carrier; this value never repeats it.
public struct BotDerivation: Codable, Sendable, Equatable {
    public var artifact: BotDerivedRef
    public var sources: [BotDerivationSource]
    public var basis: String?

    public init(artifact: BotDerivedRef, sources: [BotDerivationSource],
                basis: String? = nil) {
        self.artifact = artifact
        self.sources = sources
        self.basis = basis
    }

    public static let maximumSources = 16
    public static let maximumBasisScalars = 200
    /// G-1 r2: memory artifacts carry the complete v2 path (200 scalars).
    public static let maximumIDScalars = 200
}

/// Closed current-state vocabulary shared by sources and artifacts.
public enum BotProvenanceStatus: String, Codable, Sendable, CaseIterable {
    case current
    case changed
    case unavailable
    case revoked
    case erased
    case unknown

    /// Worst-of precedence from G-1 §1.3: erased > revoked > changed >
    /// unavailable > unknown > current.
    public var severity: Int {
        switch self {
        case .current: return 0
        case .unknown: return 1
        case .unavailable: return 2
        case .changed: return 3
        case .revoked: return 4
        case .erased: return 5
        }
    }

    public static func worst(_ values: [BotProvenanceStatus]) -> BotProvenanceStatus {
        values.max(by: { $0.severity < $1.severity }) ?? .current
    }
}

/// Closed reason vocabulary. Source-status uses the first ten; the view adds
/// the remaining four.
public enum BotProvenanceReason: String, Codable, Sendable, CaseIterable {
    case recordUnresolved = "record-unresolved"
    case recordErased = "record-erased"
    case grantRevoked = "grant-revoked"
    case sourceChanged = "source-changed"
    case newerObservationUnversioned = "newer-observation-unversioned"
    case revisionBasisMismatch = "revision-basis-mismatch"
    case noBaseline = "no-baseline"
    case sourceVersionUnknown = "source-version-unknown"
    case cycleDetected = "cycle-detected"
    case scanLimitExceeded = "scan-limit-exceeded"
    case upstreamInvalidated = "upstream-invalidated"
    case noDerivation = "no-derivation"
    case noSkillWriteEvent = "no-skill-write-event"
    case reviewModelBasis = "review-model-basis"
    /// Root R1: an observation without a stable resource identity
    /// (owner + real resource key) must be explicitly unverifiable, never
    /// merged with another tool/channel observation.
    case noResourceIdentity = "no-resource-identity"
    case skillDeleted = "skill-deleted"
    case crossBotUnresolved = "cross-bot-unresolved"
    case resourceScopeMismatch = "resource-scope-mismatch"
    case refreshNotPerformed = "refresh-not-performed"
    case refreshUnavailable = "refresh-unavailable"
    case refreshDenied = "refresh-denied"
}

/// `source_statuses` item (source-status.schema.json).
public struct BotSourceStatus: Codable, Sendable, Equatable {
    public var ref: String
    public var roles: [String]
    public var resolved: Bool
    public var erased: Bool
    public var state: BotProvenanceStatus
    public var reasons: [BotProvenanceReason]
    public var observedAtMS: Int64?
    public var recordType: String?
    public var trust: String?
    public var sourceVersion: BotProvenanceSourceVersion?
    public var latestRef: String?
    public var baseline: BotProvenanceSourceVersion?
    public var resource: BotResourceIdentity?
    public var recheckedAtMS: Int64?

    public init(ref: String, roles: [String], resolved: Bool = false,
                erased: Bool = false, state: BotProvenanceStatus = .current,
                reasons: [BotProvenanceReason] = [], observedAtMS: Int64? = nil,
                recordType: String? = nil, trust: String? = nil,
                sourceVersion: BotProvenanceSourceVersion? = nil, latestRef: String? = nil,
                baseline: BotProvenanceSourceVersion? = nil,
                resource: BotResourceIdentity? = nil,
                recheckedAtMS: Int64? = nil) {
        self.ref = ref
        self.roles = roles
        self.resolved = resolved
        self.erased = erased
        self.state = state
        self.reasons = reasons
        self.observedAtMS = observedAtMS
        self.recordType = recordType
        self.trust = trust
        self.sourceVersion = sourceVersion
        self.latestRef = latestRef
        self.baseline = baseline
        self.resource = resource
        self.recheckedAtMS = recheckedAtMS
    }

    enum CodingKeys: String, CodingKey {
        case ref
        case roles
        case resolved
        case erased
        case state
        case reasons
        case observedAtMS = "observed_at_ms"
        case recordType = "record_type"
        case trust
        case sourceVersion = "source_version"
        case latestRef = "latest_ref"
        case baseline
        case resource
        case recheckedAtMS = "rechecked_at_ms"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ref = try container.decode(String.self, forKey: .ref)
        roles = try container.decode([String].self, forKey: .roles)
        resolved = try container.decode(Bool.self, forKey: .resolved)
        erased = try container.decode(Bool.self, forKey: .erased)
        state = try container.decode(BotProvenanceStatus.self, forKey: .state)
        reasons = try container.decode([BotProvenanceReason].self, forKey: .reasons)
        observedAtMS = try container.decodeIfPresent(Int64.self, forKey: .observedAtMS)
        recordType = try container.decodeIfPresent(String.self, forKey: .recordType)
        trust = try container.decodeIfPresent(String.self, forKey: .trust)
        sourceVersion = try container.decodeIfPresent(BotProvenanceSourceVersion.self, forKey: .sourceVersion)
        latestRef = try container.decodeIfPresent(String.self, forKey: .latestRef)
        baseline = try container.decodeIfPresent(BotProvenanceSourceVersion.self, forKey: .baseline)
        resource = try container.decodeIfPresent(BotResourceIdentity.self, forKey: .resource)
        recheckedAtMS = try container.decodeIfPresent(Int64.self, forKey: .recheckedAtMS)
    }

    /// The schema marks observed_at_ms/record_type/trust as required nullable;
    /// encode nil explicitly instead of dropping the member.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ref, forKey: .ref)
        try container.encode(roles, forKey: .roles)
        try container.encode(resolved, forKey: .resolved)
        try container.encode(erased, forKey: .erased)
        try container.encode(state, forKey: .state)
        try container.encode(reasons, forKey: .reasons)
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
            try container.encode(trust, forKey: .trust)
        } else {
            try container.encodeNil(forKey: .trust)
        }
        if let sourceVersion { try container.encode(sourceVersion, forKey: .sourceVersion) }
        if let latestRef { try container.encode(latestRef, forKey: .latestRef) }
        if let baseline { try container.encode(baseline, forKey: .baseline) }
        if let resource { try container.encode(resource, forKey: .resource) }
        if let recheckedAtMS { try container.encode(recheckedAtMS, forKey: .recheckedAtMS) }
    }
}

public struct BotReviewEffective: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        case verified
        case unverified
        case disputed
        case unknown
    }

    public var state: State
    public var reasons: [BotProvenanceReason]

    public init(state: State, reasons: [BotProvenanceReason] = []) {
        self.state = state
        self.reasons = reasons
    }
}

public struct BotDerivationSourceView: Codable, Sendable, Equatable {
    public var record: String
    public var role: String
    public var status: BotSourceStatus

    public init(record: String, role: String, status: BotSourceStatus) {
        self.record = record
        self.role = role
        self.status = status
    }
}

public struct BotUpstreamView: Codable, Sendable, Equatable {
    public var artifact: BotDerivedRef
    public var state: BotProvenanceStatus

    public init(artifact: BotDerivedRef, state: BotProvenanceStatus) {
        self.artifact = artifact
        self.state = state
    }
}

/// `derivation-view` (derivation-view.schema.json). This is also the C/U state
/// type (`BotDerivedState`).
public struct BotDerivationView: Codable, Sendable, Equatable {
    public var artifact: BotDerivedRef
    public var carrier: String?
    public var state: BotProvenanceStatus
    public var reasons: [BotProvenanceReason]
    public var sources: [BotDerivationSourceView]
    public var reviewEffective: BotReviewEffective
    public var upstream: [BotUpstreamView]
    public var generation: BotProvenanceGeneration
    public var truncated: Bool?

    public init(artifact: BotDerivedRef, carrier: String? = nil,
                state: BotProvenanceStatus, reasons: [BotProvenanceReason] = [],
                sources: [BotDerivationSourceView] = [],
                reviewEffective: BotReviewEffective = .init(state: .unknown),
                upstream: [BotUpstreamView] = [],
                generation: BotProvenanceGeneration, truncated: Bool? = nil) {
        self.artifact = artifact
        self.carrier = carrier
        self.state = state
        self.reasons = reasons
        self.sources = sources
        self.reviewEffective = reviewEffective
        self.upstream = upstream
        self.generation = generation
        self.truncated = truncated
    }

    enum CodingKeys: String, CodingKey {
        case artifact
        case carrier
        case state
        case reasons
        case sources
        case reviewEffective = "review_effective"
        case upstream
        case generation
        case truncated
    }
}

public typealias BotDerivedState = BotDerivationView

public struct BotProvenanceGeneration: Codable, Sendable, Equatable, Comparable {
    public var headCommitSeq: Int
    public var lastErasureSeq: Int
    public var lastGrantSeq: Int

    public init(headCommitSeq: Int, lastErasureSeq: Int, lastGrantSeq: Int) {
        self.headCommitSeq = headCommitSeq
        self.lastErasureSeq = lastErasureSeq
        self.lastGrantSeq = lastGrantSeq
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.headCommitSeq, lhs.lastErasureSeq, lhs.lastGrantSeq)
            < (rhs.headCommitSeq, rhs.lastErasureSeq, rhs.lastGrantSeq)
    }

    enum CodingKeys: String, CodingKey {
        case headCommitSeq = "head_commit_seq"
        case lastErasureSeq = "last_erasure_seq"
        case lastGrantSeq = "last_grant_seq"
    }
}

/// Facts supplied by P for one record. P deliberately does not decide
/// current/changed and does not parse source identity or the latest
/// observation; those are L's read-model job.
public struct BotProvenanceSourceFact: Sendable, Equatable {
    public var resolved: Bool
    public var erased: Bool
    public var observedAtMS: Int64?
    public var recordType: String?
    public var trust: String?
    public var version: BotProvenanceSourceVersion?

    public init(resolved: Bool, erased: Bool, observedAtMS: Int64? = nil,
                recordType: String? = nil, trust: String? = nil,
                version: BotProvenanceSourceVersion? = nil) {
        self.resolved = resolved
        self.erased = erased
        self.observedAtMS = observedAtMS
        self.recordType = recordType
        self.trust = trust
        self.version = version
    }
}

/// Internal fact set after L has added the observation identity and the latest
/// observation from durable observation carriers. Never crosses the P boundary.
struct BotProvenanceResolvedFacts: Sendable, Equatable {
    var resolved: Bool
    var erased: Bool
    /// True when this record is an observation carrier (or P supplied a
    /// version). A tool/channel observation can have no resource identity yet;
    /// it must still be treated as an observation, not as a non-observation
    /// current record.
    var isObservation: Bool
    var observedAtMS: Int64?
    var recordType: String?
    var trust: String?
    var currentVersion: BotProvenanceSourceVersion?
    var identity: String?
    var latestRef: String?
    var latestObservedAtMS: Int64?
    var latestVersion: BotProvenanceSourceVersion?
    var resource: BotResourceIdentity?
    var recheckOutcome: BotProvenanceRecheckOutcome?
    /// Recheck results are per baseline. A source record can back several
    /// artifacts/versions with different captured baselines; one global outcome
    /// must never decide all of them.
    var recheckOutcomesByBaseline: [BotProvenanceSourceVersion: BotProvenanceRecheckOutcome] = [:]
    var skillRecheckOutcome: BotSkillRecheckOutcome?
    var scanLimitExceeded: Bool
}

public protocol BotProvenanceEvidenceResolving: Sendable {
    func sourceFacts(for refs: [String], botID: String?, sessionID: String?)
        async -> [String: BotProvenanceSourceFact]
}

/// Closure adapter so P can bridge its `BotSourceStateResolving` without L
/// importing P's evolving types. The closure returns only facts.
public struct BotProvenanceFactsResolver: BotProvenanceEvidenceResolving {
    public typealias Resolve = @Sendable ([String], String?, String?) async
        -> [String: BotProvenanceSourceFact]

    private let resolve: Resolve

    public init(_ resolve: @escaping Resolve) {
        self.resolve = resolve
    }

    public func sourceFacts(for refs: [String], botID: String?, sessionID: String?)
        async -> [String: BotProvenanceSourceFact] {
        await resolve(refs, botID, sessionID)
    }
}
public enum BotInvalidationReason: String, Codable, Sendable, CaseIterable {
    case sourceErased = "source-erased"
    case authorizationRevoked = "authorization-revoked"
    case sourceChanged = "source-changed"
    case recordUnavailable = "record-unavailable"

    public var status: BotProvenanceStatus {
        switch self {
        case .sourceErased: return .erased
        case .authorizationRevoked: return .revoked
        case .sourceChanged: return .changed
        case .recordUnavailable: return .unavailable
        }
    }

    public var reason: BotProvenanceReason {
        switch self {
        case .sourceErased: return .recordErased
        case .authorizationRevoked: return .grantRevoked
        case .sourceChanged: return .sourceChanged
        case .recordUnavailable: return .recordUnresolved
        }
    }
}

public struct BotInvalidationResult: Sendable, Equatable {
    public var sourceRefs: [String]
    public var affected: [BotDerivedRef]
    public var states: [BotDerivationView]
    public var unresolvedSources: [String]
    public var generation: BotProvenanceGeneration

    public init(sourceRefs: [String], affected: [BotDerivedRef],
                states: [BotDerivationView], unresolvedSources: [String],
                generation: BotProvenanceGeneration) {
        self.sourceRefs = sourceRefs
        self.affected = affected
        self.states = states
        self.unresolvedSources = unresolvedSources
        self.generation = generation
    }
}

public enum BotProvenanceError: Error, Sendable, Equatable {
    case invalidDerivation(String)
}
