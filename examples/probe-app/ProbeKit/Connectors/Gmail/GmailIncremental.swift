// SPDX-License-Identifier: MIT

import Foundation

public struct GmailIncrementalState: Codable, Sendable, Equatable {
    public var historyID: String?
    public var timeCursor: Date?
    public var processedMessageIDs: [String]

    public init(historyID: String? = nil, timeCursor: Date? = nil, processedMessageIDs: [String] = []) {
        self.historyID = historyID
        self.timeCursor = timeCursor
        self.processedMessageIDs = processedMessageIDs
    }
}

public protocol GmailIncrementalStoring: Actor {
    func state() throws -> GmailIncrementalState
    func save(_ state: GmailIncrementalState) throws
}

public actor GmailFileIncrementalStore: GmailIncrementalStoring {
    private let fileURL: URL
    private let fileManager: FileManager

    public init(root: URL, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        fileURL = root.appendingPathComponent("gm-incremental.json")
    }

    public func state() throws -> GmailIncrementalState {
        guard fileManager.fileExists(atPath: fileURL.path) else { return GmailIncrementalState() }
        return try GmailJSON.decoder.decode(GmailIncrementalState.self, from: Data(contentsOf: fileURL))
    }

    public func save(_ state: GmailIncrementalState) throws {
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try GmailJSON.encoder.encode(state)
        try data.write(to: fileURL, options: .atomic)
    }
}

public struct GmailIncrementalResult: Sendable, Equatable {
    public let newMessages: [GmailMessage]
    public let state: GmailIncrementalState

    public init(newMessages: [GmailMessage], state: GmailIncrementalState) {
        self.newMessages = newMessages
        self.state = state
    }
}

public actor GmailIncrementalSynchronizer {
    private let client: any GmailReading
    private let store: any GmailIncrementalStoring
    private let resultLimit: Int

    public init(client: any GmailReading, store: any GmailIncrementalStoring, resultLimit: Int = 20) {
        self.client = client
        self.store = store
        self.resultLimit = min(max(1, resultLimit), GmailLimits.maximumSearchResults)
    }

    public func synchronize() async throws -> GmailIncrementalResult {
        var current = try await store.state()
        let processed = Set(current.processedMessageIDs)
        let references: [String]
        let latestHistoryID: String?
        if let historyID = current.historyID {
            do {
                let changes = try await client.history(startHistoryID: historyID)
                references = changes.messagesAdded
                latestHistoryID = changes.historyID
            } catch GmailError.httpStatus(404) {
                let result = try await client.search(GmailSearchQuery(since: current.timeCursor,
                                                                      limit: resultLimit))
                references = result.messages.map(\.id)
                latestHistoryID = Self.maximumHistoryID(result.messages) ?? current.historyID
            }
        } else {
            let result = try await client.search(GmailSearchQuery(limit: resultLimit))
            references = result.messages.map(\.id)
            latestHistoryID = Self.maximumHistoryID(result.messages)
        }

        var newMessages: [GmailMessage] = []
        for id in Array(Set(references)).sorted() where !processed.contains(id) {
            let message = try await client.message(id: id, includeBody: false)
            newMessages.append(message)
        }
        current.processedMessageIDs.append(contentsOf: newMessages.map(\.id))
        current.processedMessageIDs = Array(Set(current.processedMessageIDs)).sorted()
            .suffix(GmailLimits.processedMessageIDs)
        if let latestHistoryID { current.historyID = latestHistoryID }
        let dates = newMessages.compactMap(\.internalDate)
        if let latest = dates.max(), latest.timeIntervalSince1970 > (current.timeCursor?.timeIntervalSince1970 ?? 0) {
            current.timeCursor = latest
        }
        try await store.save(current)
        return GmailIncrementalResult(newMessages: newMessages, state: current)
    }

    private static func maximumHistoryID(_ messages: [GmailMessage]) -> String? {
        messages.compactMap(\.historyID).max { left, right in
            (UInt64(left) ?? 0) < (UInt64(right) ?? 0)
        }
    }
}

public struct GmailDailyBriefBatch: Sendable, Equatable {
    public let items: [DailyBriefItem]
    public let sourceCursors: [String: String]
    public let expiresAt: Date

    public init(items: [DailyBriefItem], sourceCursors: [String: String], expiresAt: Date) {
        self.items = items
        self.sourceCursors = sourceCursors
        self.expiresAt = expiresAt
    }
}

public struct GmailDailyBriefSource {
    public static let sourceID = "gmail"
    private let synchronizer: GmailIncrementalSynchronizer
    private let now: @Sendable () -> Date

    public init(synchronizer: GmailIncrementalSynchronizer, now: @escaping @Sendable () -> Date = { Date() }) {
        self.synchronizer = synchronizer
        self.now = now
    }

    public func refresh() async throws -> GmailDailyBriefBatch? {
        let result = try await synchronizer.synchronize()
        guard !result.newMessages.isEmpty else { return nil }
        let items = result.newMessages.map { message in
            DailyBriefItem(id: message.id, sourceID: Self.sourceID, sourceName: "Gmail",
                           title: message.subject.isEmpty ? "（无主题）" : message.subject,
                           summary: String("\(message.from) \(message.snippet)".prefix(280)),
                           link: message.link, publishedAt: message.internalDate)
        }
        var cursors: [String: String] = [:]
        if let historyID = result.state.historyID { cursors[Self.sourceID] = historyID }
        return GmailDailyBriefBatch(items: items, sourceCursors: cursors,
                                    expiresAt: now().addingTimeInterval(GmailLimits.derivedSummaryLifetime))
    }
}
