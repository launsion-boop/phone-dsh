// SPDX-License-Identifier: MIT

import Foundation

public struct BotMemoryWriteContext: Sendable {
    public let botID: String
    public let sessionID: String?
    public let authorKind: BotMemoryAuthorKind
    public let source: BotMemorySource
    public let trust: BotRecordTrust?

    public init(
        botID: String,
        sessionID: String?,
        authorKind: BotMemoryAuthorKind,
        source: BotMemorySource,
        trust: BotRecordTrust?
    ) {
        self.botID = botID
        self.sessionID = sessionID
        self.authorKind = authorKind
        self.source = source
        self.trust = trust
    }

    public init(source: BotMemorySource, trust: BotRecordTrust? = nil) {
        self.init(
            botID: "main",
            sessionID: source.sessionID,
            authorKind: .chat,
            source: source,
            trust: trust)
    }
}

public struct BotMemoryWriteRequest: Sendable {
    public var action: BotMemoryAction
    public var path: String
    public var content: String?
    public var find: String?
    public var replace: String?
    public var to: String?
    public var expectedVersion: Int
    public var restoreVersion: Int?
    public var evidence: [String]

    public init(
        action: BotMemoryAction = .write,
        path: String,
        content: String? = nil,
        find: String? = nil,
        replace: String? = nil,
        to: String? = nil,
        expectedVersion: Int,
        restoreVersion: Int? = nil,
        evidence: [String] = []
    ) {
        self.action = action
        self.path = path
        self.content = content
        self.find = find
        self.replace = replace
        self.to = to
        self.expectedVersion = expectedVersion
        self.restoreVersion = restoreVersion
        self.evidence = evidence
    }
}

public struct BotMemoryWriteResult: Sendable, Equatable {
    public let ok: Bool
    public let code: String?
    public let error: String?
    public let action: BotMemoryAction
    public let path: String
    public let scope: BotMemoryScope?
    public let version: Int?
    public let previousVersion: Int?
    public let replaced: Int?
    public let currentVersion: Int?
    public let limit: Int?
    public let actual: Int?

    public init(
        ok: Bool,
        code: String? = nil,
        error: String? = nil,
        action: BotMemoryAction,
        path: String,
        scope: BotMemoryScope? = nil,
        version: Int? = nil,
        previousVersion: Int? = nil,
        replaced: Int? = nil,
        currentVersion: Int? = nil,
        limit: Int? = nil,
        actual: Int? = nil
    ) {
        self.ok = ok
        self.code = code
        self.error = error
        self.action = action
        self.path = path
        self.scope = scope
        self.version = version
        self.previousVersion = previousVersion
        self.replaced = replaced
        self.currentVersion = currentVersion
        self.limit = limit
        self.actual = actual
    }
}

public struct BotMemoryForgetResult: Sendable, Equatable {
    public let ok: Bool
    public let error: String?
    public let removed: Int
    public let removedFacts: Int
    public let path: String
    public let version: Int?
    public let count: Int
    public let scope: BotMemoryScope

    public init(
        ok: Bool,
        error: String? = nil,
        removed: Int,
        path: String,
        version: Int? = nil,
        count: Int,
        scope: BotMemoryScope
    ) {
        self.ok = ok
        self.error = error
        self.removed = removed
        self.removedFacts = removed
        self.path = path
        self.version = version
        self.count = count
        self.scope = scope
    }
}

public struct BotMemoryEraseScopeResult: Sendable, Equatable {
    public let ok: Bool
    public let error: String?
    public let scope: BotMemoryScope
    public let botID: String
    public let removed: Int
    public let removedFacts: Int
    public let count: Int

    public init(
        ok: Bool,
        error: String? = nil,
        scope: BotMemoryScope,
        botID: String,
        removed: Int,
        count: Int
    ) {
        self.ok = ok
        self.error = error
        self.scope = scope
        self.botID = botID
        self.removed = removed
        self.removedFacts = removed
        self.count = count
    }
}

public actor BotMemory {
    private let store: any BotMemoryDocumentStore
    private let botID: String
    private let language: BotMemoryPromptLanguage
    private let now: @Sendable () -> Int64
    private let prepareMutex = BotMemoryAsyncMutex()
    private var prepared = false
    private var recallIndex = BotMemoryDocumentRecallIndex()

    public init(
        store: any BotMemoryDocumentStore,
        botID: String,
        language: BotMemoryPromptLanguage = .zh,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }
    ) {
        self.store = store
        self.botID = botID
        self.language = language
        self.now = now
    }

    public func documents(scope: BotMemoryScope? = nil) async throws -> [BotMemoryDocument] {
        try await prepare()
        return try await store.documents(scope: scope)
    }

    public func versions(path: String) async throws -> [BotMemoryDocumentVersion] {
        try await prepare()
        return try await store.versions(path: path)
    }

    public func replayDiagnostics() async -> BotMemoryReplayDiagnostics {
        await store.replayDiagnostics()
    }

    public func write(
        _ request: BotMemoryWriteRequest,
        context: BotMemoryWriteContext
    ) async throws -> BotMemoryWriteResult {
        try await prepare()
        guard BotMemoryAuthorizer.parse(request.path) != nil else {
            return failure(request, code: "memory-path-invalid",
                           error: "Memory paths must be under user/ or agent/ without empty, '.', '..' or backslash segments.")
        }
        if request.action == .move {
            guard let to = request.to, BotMemoryAuthorizer.parse(to) != nil else {
                return failure(request, code: "memory-path-invalid",
                               error: "The move destination must be a valid memory path.")
            }
        }
        let author = BotMemoryAuthor(
            botID: botID, sessionID: context.sessionID, kind: context.authorKind)
        if let denial = BotMemoryAuthorizer.scopeDenial(author: author, path: request.path) {
            return failure(request, code: denial,
                           error: "Task and routine sessions may only write their own agent/inbox/<session>/ directory.")
        }
        if request.action == .move, let to = request.to,
           let denial = BotMemoryAuthorizer.scopeDenial(author: author, path: to) {
            return failure(request, code: denial,
                           error: "The move destination is outside this session's inbox.")
        }
        if let boundary = BotMemoryAuthorizer.userBoundaryError(
            sourceKind: context.source.kind, trust: context.trust, path: request.path) {
            return boundaryFailure(request, code: boundary)
        }
        if request.action == .move, let to = request.to,
           let boundary = BotMemoryAuthorizer.userBoundaryError(
            sourceKind: context.source.kind, trust: context.trust, path: to) {
            return boundaryFailure(request, code: boundary)
        }
        let evidence = request.evidence.isEmpty ? nil : Array(request.evidence.prefix(8))
        let storeRequest = BotMemoryStoreWriteRequest(
            action: request.action,
            path: request.path,
            content: request.content,
            find: request.find,
            replace: request.replace,
            to: request.to,
            expectedVersion: request.expectedVersion,
            restoreVersion: request.restoreVersion,
            author: author,
            evidence: evidence ?? [],
            trust: context.trust,
            source: context.source,
            atMS: now())
        let outcome = try await store.write(storeRequest)
        switch outcome {
        case let .written(document, replaced):
            return BotMemoryWriteResult(
                ok: true,
                action: request.action,
                path: document.path,
                scope: document.scope,
                version: document.version,
                previousVersion: request.expectedVersion == 0 ? 0 : request.expectedVersion,
                replaced: replaced)
        case let .deleted(version):
            return BotMemoryWriteResult(
                ok: true,
                action: request.action,
                path: version.path,
                scope: version.scope,
                version: version.version,
                previousVersion: request.expectedVersion)
        case let .conflict(currentVersion):
            return BotMemoryWriteResult(
                ok: false,
                code: "memory-version-conflict",
                error: "The document is at version \(currentVersion); re-read it and retry with that expected_version.",
                action: request.action,
                path: request.path,
                scope: BotMemoryAuthorizer.scope(of: request.path),
                currentVersion: currentVersion)
        case let .notFound(path):
            return BotMemoryWriteResult(
                ok: false,
                code: "memory-not-found",
                error: "No document exists at \(path).",
                action: request.action,
                path: path,
                scope: BotMemoryAuthorizer.scope(of: path))
        case let .pathExists(path):
            return BotMemoryWriteResult(
                ok: false,
                code: "memory-path-exists",
                error: "The destination document already exists: \(path).",
                action: request.action,
                path: path,
                scope: BotMemoryAuthorizer.scope(of: path))
        case .replaceNotFound:
            return BotMemoryWriteResult(
                ok: false,
                code: "memory-replace-not-found",
                error: "The find text does not occur in the document.",
                action: request.action,
                path: request.path,
                scope: BotMemoryAuthorizer.scope(of: request.path))
        case let .versionNotFound(version):
            return BotMemoryWriteResult(
                ok: false,
                code: "memory-version-not-found",
                error: "No live historical version \(version) exists for this document.",
                action: request.action,
                path: request.path,
                scope: BotMemoryAuthorizer.scope(of: request.path))
        case let .indexTooLong(path, limit, actual):
            return BotMemoryWriteResult(
                ok: false,
                code: "memory-index-too-long",
                error: "\(path) has \(actual) characters; INDEX.md is limited to \(limit). Move detail into documents and keep paths in the index.",
                action: request.action,
                path: path,
                scope: BotMemoryAuthorizer.scope(of: path),
                limit: limit,
                actual: actual)
        }
    }

    /// Direct host path for the memory page: forget one document without model
    /// evidence. History stays readable; physical erase is S6.
    public func forget(path: String, expectedVersion: Int) async throws -> BotMemoryForgetResult {
        try await prepare()
        let author = BotMemoryAuthor(botID: botID, kind: .ui)
        let request = BotMemoryStoreWriteRequest(
            action: .delete, path: path, expectedVersion: expectedVersion,
            author: author, evidence: [], trust: nil, source: nil, atMS: now())
        let outcome = try await store.write(request)
        switch outcome {
        case let .deleted(version):
            let remaining = try await store.documents(scope: version.scope).count
            return BotMemoryForgetResult(
                ok: true, removed: 1, path: path, version: version.version,
                count: remaining, scope: version.scope)
        case let .conflict(currentVersion):
            return BotMemoryForgetResult(
                ok: false, error: "The document is at version \(currentVersion); refresh and retry.",
                removed: 0, path: path, count: 0,
                scope: BotMemoryAuthorizer.scope(of: path) ?? .agent)
        case .notFound:
            return BotMemoryForgetResult(
                ok: true, removed: 0, path: path, count: 0,
                scope: BotMemoryAuthorizer.scope(of: path) ?? .agent)
        default:
            return BotMemoryForgetResult(
                ok: false, error: "The document could not be forgotten.",
                removed: 0, path: path, count: 0,
                scope: BotMemoryAuthorizer.scope(of: path) ?? .agent)
        }
    }

    @discardableResult
    public func eraseAll(scope: BotMemoryScope) async throws -> BotMemoryEraseScopeResult {
        try await prepare()
        let removed = try await store.eraseAll(
            scope: scope,
            author: BotMemoryAuthor(botID: botID, kind: .ui),
            atMS: now())
        let remaining = try await store.documents(scope: scope).count
        return BotMemoryEraseScopeResult(
            ok: true, scope: scope, botID: botID, removed: removed, count: remaining)
    }

    public func read(path: String, version: Int? = nil) async throws -> BotMemoryReadResult {
        try await prepare()
        guard BotMemoryAuthorizer.parse(path, allowRoot: true) != nil else {
            return .failure(code: "memory-path-invalid", error: "Invalid memory path.", path: path)
        }
        guard let scope = BotMemoryAuthorizer.scope(of: path) else {
            return .failure(code: "memory-path-invalid", error: "Invalid memory path.", path: path)
        }
        if let version {
            let versions = try await store.versions(path: path)
            guard let found = versions.first(where: { $0.version == version }) else {
                return .failure(
                    code: "memory-version-not-found",
                    error: "No version \(version) exists for \(path).",
                    path: path)
            }
            return .document(found)
        }
        if let document = try await store.document(path: path) {
            return .document(BotMemoryDocumentVersion(
                path: document.path, scope: document.scope, version: document.version,
                content: document.content, updatedAtMS: document.updatedAtMS,
                author: document.author, evidence: document.evidence, trust: document.trust))
        }
        let documents = try await store.documents(scope: scope)
        let entries = Self.directoryEntries(documents: documents, path: path)
        if !entries.isEmpty || path == scope.rawValue {
            return .directory(path: path, scope: scope, entries: entries)
        }
        return .failure(code: "memory-not-found", error: "No document or directory at \(path).", path: path)
    }

    public func recall(
        _ query: String = "",
        limit: Int = 40,
        scope: BotMemoryScope? = nil
    ) async throws -> [BotMemoryRecallHit] {
        try await prepare()
        let documents = try await store.documents(scope: scope)
            .filter { !BotMemoryAuthorizer.isIndex($0.path) }
        recallIndex.sync(documents)
        return recallIndex.search(
            query,
            limit: limit,
            now: now(),
            includeScope: scope)
    }

    public func recallPage(
        _ query: String = "",
        limit: Int = 40,
        scope: BotMemoryScope? = nil
    ) async throws -> (hits: [BotMemoryRecallHit], total: Int) {
        try await prepare()
        let documents = try await store.documents(scope: scope)
            .filter { !BotMemoryAuthorizer.isIndex($0.path) }
        recallIndex.sync(documents)
        return recallIndex.searchPage(
            query, limit: limit, now: now(), includeScope: scope)
    }

    public func injection() async throws -> BotMemoryInjection {
        try await prepare()
        try await ensureIndexes()
        let userIndex = try await store.document(path: "user/INDEX.md")
        let agentIndex = try await store.document(path: "agent/INDEX.md")
        return BotMemoryInjector.render(
            userIndex: userIndex,
            agentIndex: agentIndex,
            language: language)
    }

    public func promptBlock() async throws -> String {
        try await injection().text
    }

    public func promptBlock(language: BotMemoryPromptLanguage) async throws -> String {
        try await prepare()
        try await ensureIndexes()
        return try await BotMemoryInjector.render(
            userIndex: store.document(path: "user/INDEX.md"),
            agentIndex: store.document(path: "agent/INDEX.md"),
            language: language
        ).text
    }

    // MARK: - preparation

    private func prepare() async throws {
        if prepared { return }
        try await prepareMutex.withLock {
            if prepared { return }
            let facts = try await store.legacyFacts(scope: nil)
            if !facts.isEmpty {
                try await BotMemoryMigrator.migrate(
                    facts: facts, store: store, botID: botID, now: now())
            }
            prepared = true
        }
        do {
            try await ensureIndexes()
        } catch {
            prepared = false
            throw error
        }
    }

    private func ensureIndexes() async throws {
        for scope in BotMemoryScope.allCases {
            let path = "\(scope.rawValue)/INDEX.md"
            if try await store.document(path: path) != nil { continue }
            let request = BotMemoryStoreWriteRequest(
                action: .write,
                path: path,
                content: "# Index",
                expectedVersion: 0,
                author: BotMemoryAuthor(botID: botID, kind: .system),
                evidence: [],
                trust: nil,
                source: nil,
                atMS: now())
            _ = try await store.write(request)
        }
    }

    private func failure(_ request: BotMemoryWriteRequest, code: String, error: String) -> BotMemoryWriteResult {
        BotMemoryWriteResult(
            ok: false,
            code: code,
            error: error,
            action: request.action,
            path: request.path,
            scope: BotMemoryAuthorizer.scope(of: request.path))
    }

    private func boundaryFailure(_ request: BotMemoryWriteRequest, code: String) -> BotMemoryWriteResult {
        let message = code == "memory-source-boundary"
            ? "Only a real user turn can write user/ memory."
            : "Writing user/ memory needs at least one evidence reference to a user message."
        return failure(request, code: code, error: message)
    }

    private static func directoryEntries(
        documents: [BotMemoryDocument],
        path: String
    ) -> [BotMemoryDirectoryEntry] {
        let prefix = path.hasSuffix("/") ? path : path + "/"
        var entries: [String: BotMemoryDirectoryEntry] = [:]
        for document in documents where document.path.hasPrefix(prefix) {
            let remainder = document.path.dropFirst(prefix.count)
            guard let head = remainder.split(separator: "/", maxSplits: 1).first else { continue }
            let child = prefix + head
            if remainder.contains("/") {
                entries[child] = BotMemoryDirectoryEntry(
                    path: child, name: String(head), kind: .directory)
            } else {
                entries[child] = BotMemoryDirectoryEntry(
                    path: child, name: String(head), kind: .document,
                    version: document.version, updatedAtMS: document.updatedAtMS)
            }
        }
        return entries.values.sorted { $0.path < $1.path }
    }
}
