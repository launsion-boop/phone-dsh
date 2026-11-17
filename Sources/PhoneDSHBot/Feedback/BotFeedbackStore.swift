// SPDX-License-Identifier: MIT

import Foundation

/// Persistence seam for the P18 feedback index. Production uses the shared
/// `UserDefaults` key; tests use the in-memory store. Both are actors, so one
/// center serializes reads and writes without a second lock.
public protocol BotFeedbackStoring: Sendable {
    /// `nil` means "nothing persisted yet". An unsupported version or a corrupt
    /// payload throws; the center then ignores the whole file and rebuilds from
    /// the durable events instead of trusting a partial index.
    func load() async throws -> BotFeedbackIndexFile?
    func save(_ index: BotFeedbackIndexFile) async throws
}

/// `phone-dsh.bot.feedback.v1` (P18, G-2 §3.4).
///
/// The value is the compact gate index described by the frozen contract; the
/// only fact source stays the `feedback.recorded` durable events. A missing
/// key is an empty index, a wrong version or bad JSON is ignored by the center
/// and rebuilt from events.
public actor UserDefaultsBotFeedbackStore: BotFeedbackStoring {
    public static let key = BotFeedbackIndexFile.defaultsKey

    public nonisolated let defaultsKey: String
    private let defaults: UserDefaults
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(defaults: UserDefaults = .standard,
                key: String = BotFeedbackIndexFile.defaultsKey) {
        self.defaults = defaults
        self.defaultsKey = key
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    public func load() async throws -> BotFeedbackIndexFile? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        guard !data.isEmpty else { return nil }
        let index: BotFeedbackIndexFile
        do {
            index = try decoder.decode(BotFeedbackIndexFile.self, from: data)
        } catch {
            throw BotFeedbackStoreError.corrupted("feedback-index-decode-failed")
        }
        guard index.v == BotFeedbackIndexFile.currentVersion else {
            throw BotFeedbackStoreError.unsupportedVersion(index.v)
        }
        return index
    }

    public func save(_ index: BotFeedbackIndexFile) async throws {
        guard index.v == BotFeedbackIndexFile.currentVersion else {
            throw BotFeedbackStoreError.unsupportedVersion(index.v)
        }
        let data: Data
        do {
            data = try encoder.encode(index)
        } catch {
            throw BotFeedbackStoreError.corrupted("feedback-index-encode-failed")
        }
        defaults.set(data, forKey: defaultsKey)
    }
}

/// Test double. Failure injection lets the tests drive the "event first, index
/// later" and "index write failed" recovery paths.
public actor InMemoryBotFeedbackStore: BotFeedbackStoring {
    private var index: BotFeedbackIndexFile?
    private let loadError: BotFeedbackStoreError?
    private var saveError: BotFeedbackStoreError?
    public private(set) var saveCount = 0

    public init(index: BotFeedbackIndexFile? = nil,
                loadError: BotFeedbackStoreError? = nil,
                saveError: BotFeedbackStoreError? = nil) {
        self.index = index
        self.loadError = loadError
        self.saveError = saveError
    }

    public func load() async throws -> BotFeedbackIndexFile? {
        if let loadError { throw loadError }
        return index
    }

    public func save(_ index: BotFeedbackIndexFile) async throws {
        if let saveError { throw saveError }
        self.index = index
        saveCount += 1
    }

    public func setSaveError(_ error: BotFeedbackStoreError?) { saveError = error }

    public func currentIndex() -> BotFeedbackIndexFile? { index }
}

enum BotFeedbackIndexLimits {
    /// G-2 §3.4: at most 512 active records; evict the oldest by created_at_ms.
    /// Durable events are never deleted, so the audit history is unaffected.
    static let maximumActive = 512
    static let maximumTotal = 1_536
}
