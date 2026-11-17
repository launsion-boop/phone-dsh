// SPDX-License-Identifier: MIT

import Foundation

public enum BotMemoryAuthorKind: String, Codable, Sendable, CaseIterable {
    case chat
    case task
    case routine
    case team
    case proactive
    case watchdog
    case maintainer
    case ui
    case migration
    case system
}

public struct BotMemoryAuthor: Codable, Sendable, Equatable {
    public let botID: String?
    public let sessionID: String?
    public let kind: BotMemoryAuthorKind

    public init(botID: String?, sessionID: String? = nil, kind: BotMemoryAuthorKind) {
        self.botID = botID
        self.sessionID = sessionID
        self.kind = kind
    }

    public init(botID: String, sessionKind: BotSessionKind) {
        self.init(
            botID: botID,
            sessionID: nil,
            kind: sessionKind.memoryAuthorKind ?? .system)
    }

    enum CodingKeys: String, CodingKey {
        case botID = "bot_id"
        case sessionID = "session_id"
        case kind
    }

    /// The P25 event envelope only accepts the existing principal kinds.
    var principalKind: String {
        switch kind {
        case .chat, .task, .routine, .team, .proactive, .watchdog, .maintainer:
            return kind.rawValue
        case .ui, .migration, .system:
            return "ipc"
        }
    }

    var isInboxOnly: Bool {
        switch kind {
        case .task, .routine, .team, .proactive, .watchdog:
            return true
        case .chat, .maintainer, .ui, .migration, .system:
            return false
        }
    }
}

/// Writer-recorded check state (spec/bot/v2 §1.5.1). It is a model assertion
/// with a resolvable basis, not a host certification of the conclusion. Absent
/// means no recorded judgment at all — never `verified`, and not a synonym for
/// `unverified`.
public enum BotMemoryReviewState: String, Codable, Sendable, CaseIterable {
    case verified
    case unverified
    case disputed
}

public enum BotMemoryReviewBasis: String, Codable, Sendable, CaseIterable {
    case userStatement = "user-statement"
    case observation
    case recordRecheck = "record-recheck"
    case modelInference = "model-inference"
}

public struct BotMemoryReview: Sendable, Equatable {
    public var state: BotMemoryReviewState
    public var basis: BotMemoryReviewBasis
    /// Free text, ≤200 scalars. The host stores it but does not authenticate it.
    public var method: String?
    /// Writer-claimed time. The host does not validate the clock.
    public var atMS: Int64?
    /// Resolvable references behind the claim. `verified`/`disputed` need ≥1.
    public var refs: [String]

    public init(state: BotMemoryReviewState,
                basis: BotMemoryReviewBasis,
                method: String? = nil,
                atMS: Int64? = nil,
                refs: [String] = []) {
        self.state = state
        self.basis = basis
        self.method = method
        self.atMS = atMS
        self.refs = refs
    }
}

extension BotMemoryReview: Codable {
    enum CodingKeys: String, CodingKey {
        case state
        case basis
        case method
        case atMS = "at_ms"
        case refs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = try container.decode(BotMemoryReviewState.self, forKey: .state)
        basis = try container.decode(BotMemoryReviewBasis.self, forKey: .basis)
        method = try container.decodeIfPresent(String.self, forKey: .method)
        atMS = try container.decodeIfPresent(Int64.self, forKey: .atMS)
        refs = try container.decodeIfPresent([String].self, forKey: .refs) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(state, forKey: .state)
        try container.encode(basis, forKey: .basis)
        if let method { try container.encode(method, forKey: .method) }
        if let atMS { try container.encode(atMS, forKey: .atMS) }
        if !refs.isEmpty { try container.encode(refs, forKey: .refs) }
    }
}

/// Host-derived per-evidence observation time (spec/bot/v2 §1.5.1). Never
/// persisted: it is recomputed by one batched resolve per read/recall call.
/// `observed_at_ms == nil` means the record does not resolve (or was erased) or
/// carries no time; `source_version` is always null in this revision because
/// neither session lines nor Bot events expose a source version.
public struct BotMemoryEvidenceStatus: Sendable, Equatable {
    public let ref: String
    public let observedAtMS: Int64?
    public let sourceVersion: Int?

    public init(ref: String, observedAtMS: Int64?, sourceVersion: Int? = nil) {
        self.ref = ref
        self.observedAtMS = observedAtMS
        self.sourceVersion = sourceVersion
    }
}

extension BotMemoryEvidenceStatus: Codable {
    enum CodingKeys: String, CodingKey {
        case ref
        case observedAtMS = "observed_at_ms"
        case sourceVersion = "source_version"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ref = try container.decode(String.self, forKey: .ref)
        observedAtMS = try container.decodeIfPresent(Int64.self, forKey: .observedAtMS)
        sourceVersion = try container.decodeIfPresent(Int.self, forKey: .sourceVersion)
    }

    /// Both nullable members are required by the schema, so nulls are encoded
    /// explicitly rather than omitted.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ref, forKey: .ref)
        if let observedAtMS {
            try container.encode(observedAtMS, forKey: .observedAtMS)
        } else {
            try container.encodeNil(forKey: .observedAtMS)
        }
        if let sourceVersion {
            try container.encode(sourceVersion, forKey: .sourceVersion)
        } else {
            try container.encodeNil(forKey: .sourceVersion)
        }
    }
}

extension BotSessionKind {
    /// `verifier` has no memory write surface: the preset allow-list and the
    /// Worker guard both deny `UpdateMemory`, and the MCP runtime rejects a
    /// verifier call explicitly. Keeping the mapping optional means no code
    /// path can silently record a verifier write under another author kind.
    var memoryAuthorKind: BotMemoryAuthorKind? {
        switch self {
        case .chat: return .chat
        case .task: return .task
        case .routine: return .routine
        case .team: return .team
        case .proactive: return .proactive
        case .watchdog: return .watchdog
        case .maintainer: return .maintainer
        case .verifier: return nil
        }
    }
}

public struct BotMemoryDocument: Codable, Sendable, Equatable, Identifiable {
    public let path: String
    public let scope: BotMemoryScope
    public let content: String
    public let version: Int
    public let updatedAtMS: Int64
    public let author: BotMemoryAuthor
    public let evidence: [String]
    public let trust: String?
    public let source: BotMemorySource?
    public let review: BotMemoryReview?

    public var id: String { path }

    public init(
        path: String,
        scope: BotMemoryScope,
        content: String,
        version: Int,
        updatedAtMS: Int64,
        author: BotMemoryAuthor,
        evidence: [String] = [],
        trust: String? = nil,
        source: BotMemorySource? = nil,
        review: BotMemoryReview? = nil
    ) {
        self.path = path
        self.scope = scope
        self.content = content
        self.version = version
        self.updatedAtMS = updatedAtMS
        self.author = author
        self.evidence = evidence
        self.trust = trust
        self.source = source
        self.review = review
    }

    enum CodingKeys: String, CodingKey {
        case path
        case scope
        case content
        case version
        case updatedAtMS = "updated_at_ms"
        case author
        case evidence
        case trust
        case source
        case review
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        scope = try container.decode(BotMemoryScope.self, forKey: .scope)
        content = try container.decode(String.self, forKey: .content)
        version = try container.decode(Int.self, forKey: .version)
        updatedAtMS = try container.decode(Int64.self, forKey: .updatedAtMS)
        author = try container.decode(BotMemoryAuthor.self, forKey: .author)
        evidence = try container.decodeIfPresent([String].self, forKey: .evidence) ?? []
        trust = try container.decodeIfPresent(String.self, forKey: .trust)
        source = try container.decodeIfPresent(BotMemorySource.self, forKey: .source)
        review = try container.decodeIfPresent(BotMemoryReview.self, forKey: .review)
    }
}

public struct BotMemoryDocumentVersion: Codable, Sendable, Equatable, Identifiable {
    public let path: String
    public let scope: BotMemoryScope
    public let version: Int
    public let content: String
    public let deleted: Bool
    public let deletionReason: String?
    public let updatedAtMS: Int64
    public let author: BotMemoryAuthor
    public let evidence: [String]
    public let trust: String?
    /// Restored by `restore`/rollback so the inherited metadata can be read
    /// back version by version. Not part of the read schema.
    public let source: BotMemorySource?
    public let review: BotMemoryReview?

    public var id: String { "\(path)#\(version)" }

    public init(
        path: String,
        scope: BotMemoryScope,
        version: Int,
        content: String,
        deleted: Bool = false,
        deletionReason: String? = nil,
        updatedAtMS: Int64,
        author: BotMemoryAuthor,
        evidence: [String] = [],
        trust: String? = nil,
        source: BotMemorySource? = nil,
        review: BotMemoryReview? = nil
    ) {
        self.path = path
        self.scope = scope
        self.version = version
        self.content = content
        self.deleted = deleted
        self.deletionReason = deletionReason
        self.updatedAtMS = updatedAtMS
        self.author = author
        self.evidence = evidence
        self.trust = trust
        self.source = source
        self.review = review
    }

    enum CodingKeys: String, CodingKey {
        case path
        case scope
        case version
        case content
        case deleted
        case deletionReason = "deletion_reason"
        case updatedAtMS = "updated_at_ms"
        case author
        case evidence
        case trust
        case source
        case review
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        scope = try container.decode(BotMemoryScope.self, forKey: .scope)
        version = try container.decode(Int.self, forKey: .version)
        content = try container.decode(String.self, forKey: .content)
        deleted = try container.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        deletionReason = try container.decodeIfPresent(String.self, forKey: .deletionReason)
        updatedAtMS = try container.decode(Int64.self, forKey: .updatedAtMS)
        author = try container.decode(BotMemoryAuthor.self, forKey: .author)
        evidence = try container.decodeIfPresent([String].self, forKey: .evidence) ?? []
        trust = try container.decodeIfPresent(String.self, forKey: .trust)
        source = try container.decodeIfPresent(BotMemorySource.self, forKey: .source)
        review = try container.decodeIfPresent(BotMemoryReview.self, forKey: .review)
    }
}

public struct BotMemoryDirectoryEntry: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case document
        case directory
    }

    public let path: String
    public let name: String
    public let kind: Kind
    public let version: Int?
    public let updatedAtMS: Int64?

    public init(path: String, name: String, kind: Kind, version: Int? = nil, updatedAtMS: Int64? = nil) {
        self.path = path
        self.name = name
        self.kind = kind
        self.version = version
        self.updatedAtMS = updatedAtMS
    }

    enum CodingKeys: String, CodingKey {
        case path
        case name
        case kind
        case version
        case updatedAtMS = "updated_at_ms"
    }
}

public enum BotMemoryReadResult: Sendable, Equatable {
    case document(BotMemoryDocumentVersion)
    case directory(path: String, scope: BotMemoryScope, entries: [BotMemoryDirectoryEntry])
    case failure(code: String, error: String, path: String?)

    public var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }
}

public enum BotMemoryAction: String, Codable, Sendable, CaseIterable {
    case write
    case append
    case replace
    case move
    case delete
    case restore
}

public enum BotMemoryAuthorizer {
    /// Reserved `UpdateMemory.evidence` item: the host resolves it to the user
    /// message that opened the current turn. It is not a `record://` reference
    /// and is never accepted as a stored value; the resolved reference is.
    public static let currentUserTurnEvidence = "current-user-turn"
    public static let indexLimit = 1_500
    public static let injectionTotalLimit = 4_000
    public static let maximumPathScalars = 200
    public static let maximumSegmentScalars = 64
    public static let roots: [BotMemoryScope] = [.user, .agent]

    public static func scope(of path: String) -> BotMemoryScope? {
        guard let parts = parse(path, allowRoot: true), let first = parts.first else { return nil }
        return BotMemoryScope(rawValue: first)
    }

    public static func parse(_ path: String, allowRoot: Bool = false) -> [String]? {
        guard !path.isEmpty, path.unicodeScalars.count <= maximumPathScalars else { return nil }
        guard !path.hasPrefix("/"), !path.hasSuffix("/") else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let first = parts.first, BotMemoryScope(rawValue: first) != nil else { return nil }
        if parts.count == 1 { return allowRoot ? parts : nil }
        for segment in parts {
            guard !segment.isEmpty, segment != ".", segment != ".." else { return nil }
            guard segment.unicodeScalars.count <= maximumSegmentScalars else { return nil }
            guard segment == segment.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
            guard !segment.contains("\\") else { return nil }
            guard !segment.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
                return nil
            }
        }
        return parts
    }

    public static func isIndex(_ path: String) -> Bool {
        path == "user/INDEX.md" || path == "agent/INDEX.md"
    }

    public static func scopeDenial(author: BotMemoryAuthor, path: String) -> String? {
        guard author.isInboxOnly else { return nil }
        guard let session = author.sessionID, !session.isEmpty else {
            return "memory-scope-denied"
        }
        let prefix = "agent/inbox/\(session)/"
        guard path.hasPrefix(prefix), path.count > prefix.count else {
            return "memory-scope-denied"
        }
        return nil
    }

    public static func userBoundaryError(
        sourceKind: BotMemorySourceKind,
        trust: BotRecordTrust?,
        path: String,
        authorKind: BotMemoryAuthorKind = .chat,
        hostRollback: Bool = false
    ) -> String? {
        guard scope(of: path) == .user else { return nil }
        // A rollback restores a version that already passed this boundary. It
        // is a host operation, never a model write, so the source rule does
        // not apply; the version premise still does.
        if hostRollback { return nil }
        if authorKind == .maintainer || sourceKind == .maintenance {
            // A maintainer has no user turn. Its user/ boundary is evidence:
            // at least one reference must derive `user`, and only the maintainer
            // principal takes this branch.
            guard authorKind == .maintainer, sourceKind == .maintenance else {
                return "memory-source-boundary"
            }
            return trust == .user ? nil : "memory-evidence-required"
        }
        guard sourceKind == .userTurn else { return "memory-source-boundary" }
        if let trust, trust != .user { return "memory-evidence-required" }
        if trust == nil { return "memory-evidence-required" }
        return nil
    }

    /// The shared `user/` root has exactly one maintainer: the main Bot's.
    /// Non-main maintainers only maintain their own `agent/`.
    public static func maintenanceScopeDenial(
        author: BotMemoryAuthor, path: String, isMainBot: Bool
    ) -> String? {
        guard author.kind == .maintainer, !isMainBot, scope(of: path) == .user else {
            return nil
        }
        return "memory-scope-denied"
    }

    /// §1.5.1: the host checks that the state/basis combination is coherent and
    /// that the refs are canonical parsed references. Reference existence,
    /// ownership and erasure are resolved by the caller against the record
    /// service (the model can never supply an already-canonical claim without
    /// it being checked).
    public static let maximumReviewMethodScalars = 200
    public static let maximumReviewRefs = 8

    public static func reviewError(_ review: BotMemoryReview) -> String? {
        switch review.state {
        case .verified:
            guard review.basis != .modelInference else { return "memory-review-invalid" }
            guard !review.refs.isEmpty else { return "memory-review-invalid" }
        case .disputed:
            guard !review.refs.isEmpty else { return "memory-review-invalid" }
        case .unverified:
            break
        }
        if let method = review.method {
            guard !method.isEmpty,
                  method.unicodeScalars.count <= maximumReviewMethodScalars else {
                return "memory-review-invalid"
            }
        }
        if let atMS = review.atMS, atMS < 0 { return "memory-review-invalid" }
        guard review.refs.count <= maximumReviewRefs else { return "memory-review-invalid" }
        for raw in review.refs {
            guard let parsed = BotRecordReference.parse(raw),
                  parsed.canonical == raw else {
                return "memory-review-invalid"
            }
        }
        return nil
    }

    public static func indexOverflow(path: String, content: String) -> Int? {
        guard isIndex(path) else { return nil }
        let count = BotMemoryText.codePointCount(content)
        return count > indexLimit ? count : nil
    }
}

public struct BotMemoryLimits: Codable, Sendable, Equatable {
    public let index: Int
    public let total: Int

    public init(index: Int = BotMemoryAuthorizer.indexLimit,
                total: Int = BotMemoryAuthorizer.injectionTotalLimit) {
        self.index = index
        self.total = total
    }

    public static let standard = BotMemoryLimits()
}

public struct BotMemoryInjection: Codable, Sendable, Equatable {
    public let text: String
    public let limits: BotMemoryLimits

    public init(text: String, limits: BotMemoryLimits = .standard) {
        self.text = text
        self.limits = limits
    }
}
