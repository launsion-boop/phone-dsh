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
            kind: sessionKind.memoryAuthorKind)
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

extension BotSessionKind {
    var memoryAuthorKind: BotMemoryAuthorKind {
        switch self {
        case .chat: return .chat
        case .task: return .task
        case .routine: return .routine
        case .team: return .team
        case .proactive: return .proactive
        case .watchdog: return .watchdog
        case .maintainer: return .maintainer
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
        source: BotMemorySource? = nil
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
        trust: String? = nil
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
