// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation

/// SQLite-backed document-tree authority. Every version (including deletion)
/// is one durable event. Replay is incremental and applies each event once;
/// agent paths are filtered to this Bot, user paths are shared.
public actor SQLiteBotMemoryDocumentStore: BotMemoryDocumentStore {
    private struct DeletedData: Codable {
        let path: String
        let scope: BotMemoryScope
        let version: Int
        let expectedVersion: Int
        let at: Int64
        let reason: String
        let author: BotMemoryAuthor
        let evidence: [String]
        let trust: String?
        let source: BotMemorySource?

        enum CodingKeys: String, CodingKey {
            case path, scope, version, at, reason, author, evidence, trust, source
            case expectedVersion = "expected_version"
        }
    }

    private struct WrittenData: Codable {
        let path: String
        let scope: BotMemoryScope
        let content: String
        let version: Int
        let expectedVersion: Int
        let updatedAtMS: Int64
        let author: BotMemoryAuthor
        let evidence: [String]
        let trust: String?
        let source: BotMemorySource?

        enum CodingKeys: String, CodingKey {
            case path, scope, content, version, author, evidence, trust, source
            case expectedVersion = "expected_version"
            case updatedAtMS = "updated_at_ms"
        }

        var document: BotMemoryDocument {
            BotMemoryDocument(
                path: path, scope: scope, content: content, version: version,
                updatedAtMS: updatedAtMS, author: author, evidence: evidence,
                trust: trust, source: source)
        }
    }

    private struct LegacyForgotten: Codable {
        let factId: String
        let scope: BotMemoryScope
        let at: Int64
        let reason: String

        enum CodingKeys: String, CodingKey {
            case factId = "factId"
            case scope
            case at
            case reason
        }
    }

    private struct ReplayState {
        var order: [String] = []
        var live: [String: BotMemoryDocument] = [:]
        var versions: [String: [Int: BotMemoryDocumentVersion]] = [:]
        var latestVersion: [String: Int] = [:]
        var legacyFacts: [String: BotMemoryFact] = [:]
        var legacyOrder: [String] = []
        var appliedEventIDs: Set<String> = []

        func documents(scope: BotMemoryScope?) -> [BotMemoryDocument] {
            order.compactMap { path in
                guard let document = live[path] else { return nil }
                if let scope, document.scope != scope { return nil }
                return document
            }.sorted { $0.path < $1.path }
        }

        func versions(path: String) -> [BotMemoryDocumentVersion] {
            (versions[path] ?? [:]).values.sorted { $0.version < $1.version }
        }
    }

    private static let writtenEventPrefix = "evt-memory-document-written-"
    private static let deletedEventPrefix = "evt-memory-document-deleted-"
    private static let replayPageSize = 500
    private static let maximumSkippedEventIDs = 256

    private let eventLog: SQLiteDomainStore
    private let replayFeed: BotMemoryReplayFeed
    private let botID: String?
    private let now: @Sendable () -> Int64
    private let mutationMutex = BotMemoryAsyncMutex()

    private var state = ReplayState()
    private var processedEventIndex = 0
    private var processedMemoryEventCount = 0
    private var lastProcessedCommitSeq = 0
    private var skippedEventIDs: [String] = []

    public init(
        eventLog: SQLiteDomainStore,
        botID: String? = nil,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }
    ) {
        self.eventLog = eventLog
        self.botID = botID
        self.now = now
        self.replayFeed = BotMemoryReplayFeedRegistry.shared.feed(
            for: eventLog, pageSize: Self.replayPageSize)
    }

    public func documents(scope: BotMemoryScope? = nil) async throws -> [BotMemoryDocument] {
        try await replay().documents(scope: scope)
    }

    public func document(path: String) async throws -> BotMemoryDocument? {
        try await replay().live[path]
    }

    public func versions(path: String) async throws -> [BotMemoryDocumentVersion] {
        try await replay().versions(path: path)
    }

    public func legacyFacts(scope: BotMemoryScope? = nil) async throws -> [BotMemoryFact] {
        let snapshot = try await replay()
        return snapshot.legacyOrder.compactMap { id in
            guard let fact = snapshot.legacyFacts[id] else { return nil }
            if let scope, fact.scope != scope { return nil }
            return fact
        }
    }

    public func replayDiagnostics() async -> BotMemoryReplayDiagnostics {
        let feed = await replayFeed.diagnostics()
        return BotMemoryReplayDiagnostics(
            fullReplayCount: feed.fullReplayCount,
            incrementalReplayCount: feed.incrementalReplayCount,
            scannedEventCount: feed.scannedEventCount,
            processedMemoryEventCount: processedMemoryEventCount,
            skippedEventIDs: skippedEventIDs,
            lastProcessedCommitSeq: lastProcessedCommitSeq
        )
    }

    public func write(_ request: BotMemoryStoreWriteRequest) async throws -> BotMemoryStoreWriteOutcome {
        try await mutationMutex.withLock {
            let snapshot = try await replay()
            let pathVersion = snapshot.live[request.path]?.version ?? 0
            guard request.expectedVersion == pathVersion else {
                return .conflict(currentVersion: pathVersion)
            }
            let current = snapshot.live[request.path]
            switch request.action {
            case .write, .restore, .append, .replace, .move, .delete:
                break
            }

            var writtenContent: String?
            var replacedCount: Int?
            var targetPath = request.path
            switch request.action {
            case .write:
                writtenContent = request.content ?? ""
            case .append:
                guard let current else { return .notFound(path: request.path) }
                writtenContent = current.content + (request.content ?? "")
            case .replace:
                guard let current else { return .notFound(path: request.path) }
                let find = request.find ?? ""
                guard !find.isEmpty else { return .replaceNotFound }
                let count = current.content.components(separatedBy: find).count - 1
                guard count > 0 else { return .replaceNotFound }
                writtenContent = current.content.replacingOccurrences(
                    of: find, with: request.replace ?? "")
                replacedCount = count
            case .restore:
                let version = request.restoreVersion ?? 0
                guard let restored = snapshot.versions[request.path]?[version], !restored.deleted else {
                    return .versionNotFound(version: version)
                }
                writtenContent = restored.content
            case .move:
                guard let current else { return .notFound(path: request.path) }
                guard let destination = request.to else { return .notFound(path: request.path) }
                if snapshot.live[destination] != nil { return .pathExists(path: destination) }
                targetPath = destination
                writtenContent = current.content
            case .delete:
                guard let current else { return .notFound(path: request.path) }
                let version = (snapshot.latestVersion[request.path] ?? current.version) + 1
                let deletion = BotMemoryDocumentVersion(
                    path: request.path,
                    scope: current.scope,
                    version: version,
                    content: "",
                    deleted: true,
                    deletionReason: "forget",
                    updatedAtMS: request.atMS,
                    author: request.author,
                    evidence: request.evidence,
                    trust: request.trust?.rawValue)
                let event = try deletionEvent(
                    deletion, expectedVersion: request.expectedVersion,
                    data: deletionData(deletion, expectedVersion: request.expectedVersion),
                    correlationID: request.correlationID)
                try await commit([event])
                return .deleted(deletion)
            }

            guard let content = writtenContent else { return .notFound(path: request.path) }
            let scope = BotMemoryAuthorizer.scope(of: targetPath) ?? current?.scope ?? .agent
            if let actual = BotMemoryAuthorizer.indexOverflow(path: targetPath, content: content) {
                return .indexTooLong(
                    path: targetPath,
                    limit: BotMemoryAuthorizer.indexLimit,
                    actual: actual)
            }
            let latest = snapshot.latestVersion[targetPath] ?? 0
            let version = latest + 1
            let document = BotMemoryDocument(
                path: targetPath,
                scope: scope,
                content: content,
                version: version,
                updatedAtMS: request.atMS,
                author: request.author,
                evidence: request.evidence,
                trust: request.trust?.rawValue ?? (scope == .user ? "user" : "assistant"),
                source: request.source)
            let targetExpected = snapshot.live[targetPath]?.version ?? 0
            let writeEvent = try writtenEvent(
                document, expectedVersion: targetExpected,
                correlationID: request.correlationID)

            if request.action == .move {
                guard let sourceVersion = current?.version,
                      let source = snapshot.live[request.path] else {
                    return .notFound(path: request.path)
                }
                let deletion = BotMemoryDocumentVersion(
                    path: source.path,
                    scope: source.scope,
                    version: sourceVersion + 1,
                    content: "",
                    deleted: true,
                    deletionReason: "move",
                    updatedAtMS: request.atMS,
                    author: request.author,
                    evidence: request.evidence,
                    trust: request.trust?.rawValue)
                let deleteEvent = try deletionEvent(
                    deletion,
                    expectedVersion: sourceVersion,
                    data: deletionData(deletion, expectedVersion: sourceVersion),
                    correlationID: request.correlationID)
                try await commit([writeEvent, deleteEvent])
            } else {
                try await commit([writeEvent])
            }
            return .written(try await replay().live[targetPath] ?? document, replaced: replacedCount)
        }
    }

    public func eraseAll(scope: BotMemoryScope, author: BotMemoryAuthor, atMS: Int64) async throws -> Int {
        try await mutationMutex.withLock {
            let snapshot = try await replay()
            let targets = snapshot.documents(scope: scope)
            guard !targets.isEmpty else { return 0 }
            var events: [BotEvent] = []
            for document in targets {
                let version = (snapshot.latestVersion[document.path] ?? document.version) + 1
                let deletion = BotMemoryDocumentVersion(
                    path: document.path,
                    scope: document.scope,
                    version: version,
                    content: "",
                    deleted: true,
                    deletionReason: "erase",
                    updatedAtMS: atMS,
                    author: author,
                    evidence: [],
                    trust: nil)
                events.append(try deletionEvent(
                    deletion,
                    expectedVersion: document.version,
                    data: deletionData(deletion, expectedVersion: document.version),
                    correlationID: nil))
            }
            try await commit(events)
            return targets.count
        }
    }

    // MARK: - physical erasure (S6)

    public func erase(path: String, author: BotMemoryAuthor,
                      atMS: Int64) async throws -> BotMemoryPhysicalEraseOutcome {
        try await mutationMutex.withLock {
            let snapshot = try await replay()
            guard let scope = BotMemoryAuthorizer.scope(of: path) else {
                return BotMemoryPhysicalEraseOutcome(
                    ok: false, error: "memory-path-invalid", scope: .agent)
            }
            let hasHistory = snapshot.versions[path] != nil
            guard hasHistory || snapshot.live[path] != nil else {
                return BotMemoryPhysicalEraseOutcome(
                    ok: false, error: "memory-not-found", scope: scope)
            }
            return try await erasePhysical(
                paths: [path],
                scope: scope,
                targets: [BotErasureEventData.Target(
                    kind: "memory", scope: scope.rawValue, path: path)],
                scopeErase: false,
                author: author,
                atMS: atMS,
                snapshot: snapshot)
        }
    }

    public func erase(scope: BotMemoryScope, author: BotMemoryAuthor,
                      atMS: Int64) async throws -> BotMemoryPhysicalEraseOutcome {
        try await mutationMutex.withLock {
            let snapshot = try await replay()
            let paths = Self.paths(in: scope, snapshot: snapshot)
            return try await erasePhysical(
                paths: paths,
                scope: scope,
                targets: [BotErasureEventData.Target(kind: "memory", scope: scope.rawValue)],
                scopeErase: true,
                author: author,
                atMS: atMS,
                snapshot: snapshot)
        }
    }

    private static func paths(in scope: BotMemoryScope, snapshot: ReplayState) -> [String] {
        var paths = Set<String>()
        for (path, versions) in snapshot.versions
        where versions.values.contains(where: { $0.scope == scope }) {
            paths.insert(path)
        }
        for document in snapshot.live.values where document.scope == scope {
            paths.insert(document.path)
        }
        return paths.sorted()
    }

    private func erasePhysical(
        paths: [String],
        scope: BotMemoryScope,
        targets: [BotErasureEventData.Target],
        scopeErase: Bool,
        author: BotMemoryAuthor,
        atMS: Int64,
        snapshot: ReplayState
    ) async throws -> BotMemoryPhysicalEraseOutcome {
        let targetPaths = Set(paths)
        var versionsByPath: [String: [BotMemoryDocumentVersion]] = [:]
        for path in targetPaths {
            let versions = (snapshot.versions[path] ?? [:]).values.sorted { $0.version < $1.version }
            if versions.isEmpty, let live = snapshot.live[path] {
                versionsByPath[path] = [BotMemoryDocumentVersion(
                    path: live.path, scope: live.scope, version: live.version,
                    content: live.content, updatedAtMS: live.updatedAtMS,
                    author: live.author, evidence: live.evidence, trust: live.trust)]
            } else {
                versionsByPath[path] = versions
            }
        }

        var needles = Set<String>()
        for versions in versionsByPath.values {
            for version in versions where !version.deleted {
                needles.formUnion(Self.erasureNeedles(in: version.content))
            }
        }
        let needleList = Array(needles)

        let allEvents = try await allDurableEvents()
        var targetSequences = Set<Int>()
        var legacyFactIDs = Set<String>()
        for event in allEvents {
            guard let sequence = event.commitSeq, !event.isErasedPayload,
                  event.type != "erasure" else { continue }
            switch event.type {
            case "memory.document_written":
                if let data = try? Self.decode(WrittenData.self, from: event.data),
                   targetPaths.contains(data.path),
                   eventBelongs(event, scope: data.scope) {
                    targetSequences.insert(sequence)
                }
            case "memory.document_deleted":
                if let data = try? Self.decode(DeletedData.self, from: event.data),
                   targetPaths.contains(data.path),
                   eventBelongs(event, scope: data.scope) {
                    targetSequences.insert(sequence)
                }
            case "memory.written":
                if let fact = try? Self.decode(BotMemoryFact.self, from: event.data),
                   legacyFactBelongs(fact, event: event, scope: scope, scopeErase: scopeErase,
                                     needles: needleList) {
                    targetSequences.insert(sequence)
                    legacyFactIDs.insert(fact.factID)
                }
            case "memory.forgotten":
                if let forgotten = try? Self.decode(LegacyForgotten.self, from: event.data),
                   legacyFactBelongs(factID: forgotten.factId, scope: forgotten.scope,
                                     event: event, targetScope: scope, scopeErase: scopeErase,
                                     targeted: legacyFactIDs) {
                    targetSequences.insert(sequence)
                    legacyFactIDs.insert(forgotten.factId)
                }
            default:
                break
            }
            if eventBelongs(event, scope: scope), !needleList.isEmpty,
               Self.payloadContains(event.data, any: needleList) {
                targetSequences.insert(sequence)
            }
        }

        // Observation envelopes and redaction traces that point at an erased
        // event are scrubbed too. Memory-version events are excluded here:
        // surviving documents must not lose their own payload because an
        // evidence reference went away.
        let erasedRefs = targetSequences.map { "record://event/\($0)" }
        if !erasedRefs.isEmpty {
            for event in allEvents {
                guard let sequence = event.commitSeq, !targetSequences.contains(sequence),
                      !event.isErasedPayload, event.type != "erasure",
                      !event.type.hasPrefix("memory."),
                      eventBelongs(event, scope: scope),
                      Self.payloadContains(event.data, any: erasedRefs) else { continue }
                targetSequences.insert(sequence)
            }
        }

        let metadata = try await eventLog.erasureTargets(for: targetSequences.sorted())
        let payloadTargets = metadata.filter { $0.payloadBytes > 0 }
        var erasureRecord: String?
        var erasedBytes = 0
        if !payloadTargets.isEmpty {
            let erasureID = "erasure-\(UUID().uuidString.lowercased())"
            let erasedEvents = payloadTargets.map {
                BotErasureEventData.ErasedEvent(
                    record: $0.record, type: $0.type, digest: $0.digest,
                    payloadBytes: $0.payloadBytes)
            }
            var uncovered = Set<String>()
            for versions in versionsByPath.values {
                for version in versions {
                    for raw in version.evidence {
                        if case .session = BotRecordReference.parse(raw) {
                            uncovered.insert(BotRecordReference.parse(raw)?.canonical ?? raw)
                        }
                    }
                }
            }
            let memoryVersions = versionsByPath.keys.sorted().compactMap { path -> BotErasureEventData.MemoryVersionRange? in
                guard let versions = versionsByPath[path] else { return nil }
                return BotErasureEventData.MemoryVersionRange(
                    path: path,
                    scope: versions.first?.scope.rawValue ?? scope.rawValue,
                    versions: versions.map(\.version))
            }
            let data = BotErasureEventData(
                erasureId: erasureID,
                reason: scopeErase ? "memory-scope-erase" : "memory-document-erase",
                atMS: atMS,
                targets: targets,
                memoryVersions: memoryVersions,
                erasedEvents: erasedEvents,
                uncoveredRecords: uncovered.sorted().map {
                    BotErasureEventData.UncoveredRecord(
                        record: $0, reason: "session-log-erasure-not-implemented")
                },
                legacyFactIDs: legacyFactIDs.sorted())
            let event = BotEvent(
                type: "erasure",
                eventId: "erasure-\(erasureID)",
                time: max(0, atMS),
                origin: .local(source: "user"),
                traceId: "trace-\(erasureID)",
                principal: BotPrincipal(botId: author.botID, sessionId: nil, kind: "ipc"),
                causationId: nil,
                correlationId: nil,
                data: try Self.encode(data))
            let commit = try await eventLog.erasePayloads(
                payloadTargets.map(\.commitSeq), erasureEvent: event, atMS: atMS)
            erasureRecord = "record://event/\(commit.erasureCommitSeq)"
            erasedBytes = payloadTargets.reduce(0) { $0 + $1.payloadBytes }
        }

        removeFromState(paths: targetPaths, scope: scope,
                        legacyFactIDs: legacyFactIDs, scopeErase: scopeErase)
        return BotMemoryPhysicalEraseOutcome(
            ok: true,
            scope: scope,
            paths: paths,
            removedDocuments: paths.filter { snapshot.live[$0] != nil }.count,
            removedVersions: versionsByPath.values.reduce(0) { $0 + $1.count },
            erasedEvents: payloadTargets.count,
            erasedBytes: erasedBytes,
            erasureRecord: erasureRecord,
            uncoveredRecords: versionsByPath.values.flatMap { versions in
                versions.flatMap(\.evidence)
            }.compactMap { raw -> String? in
                guard case .session = BotRecordReference.parse(raw) else { return nil }
                return BotRecordReference.parse(raw)?.canonical
            }.sorted())
    }

    private func legacyFactBelongs(_ fact: BotMemoryFact, event: BotEvent,
                                   scope: BotMemoryScope, scopeErase: Bool,
                                   needles: [String]) -> Bool {
        guard eventBelongs(event, scope: scope) else { return false }
        if scopeErase { return fact.scope == scope }
        return !needles.isEmpty && needles.contains(where: { fact.text.contains($0) })
    }

    private func legacyFactBelongs(factID: String, scope factScope: BotMemoryScope,
                                   event: BotEvent, targetScope: BotMemoryScope,
                                   scopeErase: Bool, targeted: Set<String>) -> Bool {
        guard eventBelongs(event, scope: targetScope) else { return false }
        if scopeErase { return factScope == targetScope }
        return targeted.contains(factID)
    }

    private func eventBelongs(_ event: BotEvent, scope: BotMemoryScope) -> Bool {
        if scope == .user { return true }
        return belongsToThisBot(event, scope: scope)
    }

    private func allDurableEvents() async throws -> [BotEvent] {
        var result: [BotEvent] = []
        var cursor = 0
        while true {
            let page = try await eventLog.events(after: cursor, limit: 500)
            if page.isEmpty { break }
            result.append(contentsOf: page)
            guard let last = page.last?.commitSeq else { break }
            cursor = last
            if page.count < 500 { break }
        }
        return result
    }

    private func removeFromState(paths: Set<String>, scope: BotMemoryScope,
                                 legacyFactIDs: Set<String>, scopeErase: Bool) {
        for path in paths {
            state.live.removeValue(forKey: path)
            state.versions.removeValue(forKey: path)
            state.latestVersion.removeValue(forKey: path)
        }
        state.order.removeAll { paths.contains($0) }
        state.legacyFacts = state.legacyFacts.filter { factID, fact in
            if legacyFactIDs.contains(factID) { return false }
            if scopeErase, fact.scope == scope { return false }
            return true
        }
        state.legacyOrder.removeAll { factID in
            state.legacyFacts[factID] == nil
        }
    }

    /// Exact version text, each non-empty line, and distinctive tokens. The
    /// token rule catches a unique marker copied into a conversation while a
    /// plain English line still needs the line/full-text match; short common
    /// words are never needles.
    private static func erasureNeedles(in content: String) -> Set<String> {
        var result = Set<String>()
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.unicodeScalars.count >= 8 { result.insert(trimmed) }
        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.unicodeScalars.count >= 8 { result.insert(value) }
        }
        let separators = Set(",;:!?()[]{}<>\"'".map { $0 })
        for token in content.split(whereSeparator: { $0.isWhitespace || separators.contains($0) }) {
            let value = String(token)
            guard value.unicodeScalars.count >= 8 else { continue }
            if value.contains("_") || value.contains(where: { $0.isNumber }) {
                result.insert(value)
            }
        }
        return result
    }

    private static func payloadContains(_ value: BotJSONValue, any needles: [String]) -> Bool {
        switch value {
        case let .string(text):
            return needles.contains { text.contains($0) }
        case let .array(values):
            return values.contains { payloadContains($0, any: needles) }
        case let .object(object):
            return object.values.contains { payloadContains($0, any: needles) }
        case .number, .bool, .null:
            return false
        }
    }

    private func replay() async throws -> ReplayState {
        let events = try await replayFeed.memoryEvents(
            from: processedEventIndex, eventLog: eventLog)
        guard !events.isEmpty else { return state }
        var index = processedEventIndex
        for event in events {
            guard let commitSeq = event.commitSeq else {
                processedEventIndex = index
                throw BotMemoryFactStoreError.corrupted("durable memory event has no commitSeq")
            }
            do {
                try apply(event)
            } catch is DecodingError {
                recordSkipped(event)
            } catch {
                processedEventIndex = index
                throw error
            }
            index += 1
            processedMemoryEventCount += 1
            lastProcessedCommitSeq = commitSeq
        }
        processedEventIndex = index
        return state
    }

    private func apply(_ event: BotEvent) throws {
        guard !state.appliedEventIDs.contains(event.eventId) else { return }
        if event.isErasedPayload {
            // The header/digest survive; there is nothing left to replay.
            return
        }
        switch event.type {
        case "memory.document_written":
            let data = try Self.decode(WrittenData.self, from: event.data)
            guard belongsToThisBot(event, scope: data.scope) else { return }
            try applyWritten(data.document, eventID: event.eventId)
        case "memory.document_deleted":
            let data = try Self.decode(DeletedData.self, from: event.data)
            guard belongsToThisBot(event, scope: data.scope) else { return }
            try applyDeleted(data)
        case "memory.written":
            let fact = try Self.decode(BotMemoryFact.self, from: event.data)
            guard belongsToThisBot(event, scope: fact.scope) else { return }
            if state.legacyFacts[fact.factID] == nil {
                state.legacyOrder.append(fact.factID)
            }
            state.legacyFacts[fact.factID] = fact
        case "memory.forgotten":
            let forgotten = try Self.decode(LegacyForgotten.self, from: event.data)
            guard belongsToThisBot(event, scope: forgotten.scope) else { return }
            state.legacyFacts.removeValue(forKey: forgotten.factId)
            state.legacyOrder.removeAll { $0 == forgotten.factId }
        case "erasure":
            let data = try Self.decode(BotErasureEventData.self, from: event.data)
            let erasingBot = Self.normalizedBotID(event.principal.botId)
            func appliesToThisStore(_ target: BotErasureEventData.Target) -> Bool {
                guard target.kind == "memory" else { return false }
                guard target.scope != BotMemoryScope.user.rawValue else { return true }
                return erasingBot == effectiveBotID
            }
            var removedPaths = Set<String>()
            var scopeErases: [BotMemoryScope] = []
            for target in data.targets where appliesToThisStore(target) {
                if let path = target.path {
                    removedPaths.insert(path)
                } else if let rawScope = target.scope,
                          let targetScope = BotMemoryScope(rawValue: rawScope) {
                    scopeErases.append(targetScope)
                }
            }
            for path in removedPaths {
                state.live.removeValue(forKey: path)
                state.versions.removeValue(forKey: path)
                state.latestVersion.removeValue(forKey: path)
            }
            for targetScope in scopeErases {
                let scoped = state.versions.compactMap { path, versions in
                    versions.values.contains(where: { $0.scope == targetScope }) ? path : nil
                }
                for path in scoped {
                    state.live.removeValue(forKey: path)
                    state.versions.removeValue(forKey: path)
                    state.latestVersion.removeValue(forKey: path)
                }
                state.legacyFacts = state.legacyFacts.filter { $0.value.scope != targetScope }
            }
            for factID in data.legacyFactIDs {
                state.legacyFacts.removeValue(forKey: factID)
            }
            let visible = Set(state.live.keys)
            state.order.removeAll { !visible.contains($0) }
            state.legacyOrder.removeAll { state.legacyFacts[$0] == nil }
        default:
            return
        }
        state.appliedEventIDs.insert(event.eventId)
    }

    private func applyWritten(_ document: BotMemoryDocument, eventID: String) throws {
        let latest = state.latestVersion[document.path] ?? 0
        if let existing = state.versions[document.path]?[document.version] {
            guard existing.content == document.content, existing.deleted == false else {
                throw BotMemoryFactStoreError.corrupted(
                    "conflicting document.written payloads for \(document.path)#\(document.version)")
            }
            return
        }
        guard document.version == latest + 1 else {
            throw BotMemoryFactStoreError.corrupted(
                "non-contiguous document version \(document.path)#\(document.version)")
        }
        if state.live[document.path] == nil {
            state.order.append(document.path)
        }
        state.live[document.path] = document
        state.versions[document.path, default: [:]][document.version] = BotMemoryDocumentVersion(
            path: document.path,
            scope: document.scope,
            version: document.version,
            content: document.content,
            updatedAtMS: document.updatedAtMS,
            author: document.author,
            evidence: document.evidence,
            trust: document.trust)
        state.latestVersion[document.path] = document.version
        _ = eventID
    }

    private func applyDeleted(_ data: DeletedData) throws {
        let latest = state.latestVersion[data.path] ?? 0
        if let existing = state.versions[data.path]?[data.version] {
            guard existing.deleted else {
                throw BotMemoryFactStoreError.corrupted(
                    "conflicting document.deleted payloads for \(data.path)#\(data.version)")
            }
            return
        }
        guard data.version == latest + 1 else {
            throw BotMemoryFactStoreError.corrupted(
                "non-contiguous document version \(data.path)#\(data.version)")
        }
        let version = BotMemoryDocumentVersion(
            path: data.path,
            scope: data.scope,
            version: data.version,
            content: "",
            deleted: true,
            deletionReason: data.reason,
            updatedAtMS: data.at,
            author: data.author,
            evidence: data.evidence,
            trust: data.trust)
        state.versions[data.path, default: [:]][data.version] = version
        state.live.removeValue(forKey: data.path)
        state.latestVersion[data.path] = data.version
    }

    private func recordSkipped(_ event: BotEvent) {
        guard !skippedEventIDs.contains(event.eventId) else { return }
        skippedEventIDs.append(event.eventId)
        if skippedEventIDs.count > Self.maximumSkippedEventIDs {
            skippedEventIDs.removeFirst(skippedEventIDs.count - Self.maximumSkippedEventIDs)
        }
    }

    private func writtenEvent(
        _ document: BotMemoryDocument,
        expectedVersion: Int,
        correlationID: String? = nil
    ) throws -> BotEvent {
        let data = WrittenData(
            path: document.path,
            scope: document.scope,
            content: document.content,
            version: document.version,
            expectedVersion: expectedVersion,
            updatedAtMS: document.updatedAtMS,
            author: document.author,
            evidence: document.evidence,
            trust: document.trust,
            source: document.source)
        return try makeEvent(
            type: "memory.document_written",
            eventID: Self.stableEventID(Self.writtenEventPrefix, [
                document.path, Self.scopedBotID(botID) ?? "-", String(document.version),
                Self.digest(data.content), String(expectedVersion), String(document.updatedAtMS),
            ]),
            data: Self.encode(data),
            at: document.updatedAtMS,
            author: document.author,
            source: document.source,
            correlationID: correlationID)
    }

    private func deletionEvent(
        _ version: BotMemoryDocumentVersion,
        expectedVersion: Int,
        data: DeletedData,
        correlationID: String? = nil
    ) throws -> BotEvent {
        try makeEvent(
            type: "memory.document_deleted",
            eventID: Self.stableEventID(Self.deletedEventPrefix, [
                version.path, Self.scopedBotID(botID) ?? "-", String(version.version),
                String(expectedVersion), String(version.updatedAtMS), version.deletionReason ?? "",
            ]),
            data: Self.encode(data),
            at: version.updatedAtMS,
            author: version.author,
            source: nil,
            correlationID: correlationID)
    }

    private func deletionData(
        _ version: BotMemoryDocumentVersion,
        expectedVersion: Int
    ) -> DeletedData {
        DeletedData(
            path: version.path,
            scope: version.scope,
            version: version.version,
            expectedVersion: expectedVersion,
            at: version.updatedAtMS,
            reason: version.deletionReason ?? "forget",
            author: version.author,
            evidence: version.evidence,
            trust: version.trust,
            source: nil)
    }

    private func makeEvent(
        type: String,
        eventID: String,
        data: BotJSONValue,
        at: Int64,
        author: BotMemoryAuthor,
        source: BotMemorySource?,
        correlationID: String? = nil
    ) throws -> BotEvent {
        BotEvent(
            type: type,
            eventId: eventID,
            time: max(0, at),
            origin: .local(source: "memory-service"),
            traceId: "trace-\(eventID)",
            principal: BotPrincipal(
                botId: author.botID,
                sessionId: author.sessionID,
                kind: author.principalKind),
            causationId: nil,
            correlationId: correlationID,
            turnId: source?.turnID,
            runId: nil,
            data: data)
    }

    private func commit(_ events: [BotEvent]) async throws {
        guard !events.isEmpty else { return }
        do {
            if events.count == 1 {
                _ = try await eventLog.append(events[0])
            } else {
                _ = try await eventLog.appendBatch(events)
            }
        } catch {
            if (try? await committedEventsMatch(events)) == true { return }
            throw error
        }
        for event in events {
            guard let persisted = try await eventLog.event(withId: event.eventId) else {
                throw BotMemoryFactStoreError.corrupted("committed memory event is missing: \(event.eventId)")
            }
            guard persisted.type == event.type, persisted.data == event.data else {
                throw BotMemoryFactStoreError.corrupted(
                    "committed memory event payload mismatch: \(event.eventId)")
            }
        }
    }

    private func committedEventsMatch(_ events: [BotEvent]) async throws -> Bool {
        for event in events {
            guard let persisted = try await eventLog.event(withId: event.eventId),
                  persisted.type == event.type,
                  persisted.data == event.data else { return false }
        }
        return true
    }

    private var effectiveBotID: String {
        Self.normalizedBotID(botID)
    }

    private func belongsToThisBot(_ event: BotEvent, scope: BotMemoryScope) -> Bool {
        if scope == .user { return true }
        return Self.normalizedBotID(event.principal.botId) == effectiveBotID
    }

    private static func normalizedBotID(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "main" }
        return value
    }

    private static func scopedBotID(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value != "main" else { return nil }
        return value
    }

    private static func stableEventID(_ prefix: String, _ components: [String]) -> String {
        prefix + digest(components.joined(separator: "\u{0}"))
    }

    private static func encode<T: Encodable>(_ value: T) throws -> BotJSONValue {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try BotJSONValue.parse(encoder.encode(value))
    }

    private static func decode<T: Decodable>(_ type: T.Type, from value: BotJSONValue) throws -> T {
        try JSONDecoder().decode(type, from: value.encoded())
    }

    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
