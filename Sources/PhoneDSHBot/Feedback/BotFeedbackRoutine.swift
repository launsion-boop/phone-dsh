// SPDX-License-Identifier: MIT

import Foundation

/// Host-verified snapshot of one routine. A routine can be suppressed before
/// its first run, so no proactive delivery exists yet; this is the real durable
/// definition the feedback must bind instead of inventing a delivery.
public struct BotFeedbackRoutineSnapshot: Sendable, Equatable {
    public var routineID: String
    public var title: String
    public var enabled: Bool
    /// `RoutineDocument.version` at resolution time; recorded as the feedback
    /// target version so the audit can be rechecked against the document.
    public var revision: Int

    public init(routineID: String, title: String, enabled: Bool, revision: Int) {
        self.routineID = routineID
        self.title = title
        self.enabled = enabled
        self.revision = revision
    }
}

public protocol BotFeedbackRoutineReading: Sendable {
    /// Bot-scoped lookup: a routine from another Bot's document must be nil.
    func routine(botID: String, routineID: String) async -> BotFeedbackRoutineSnapshot?
}

/// Production adapter over the durable routine document. `RoutineStore.read`
/// is bot-scoped and returns the document version; deleted routines disappear
/// from the document, so a stale id cannot be suppressed.
public struct BotFeedbackRoutineReader: BotFeedbackRoutineReading {
    private let store: any RoutineStore

    public init(store: any RoutineStore) {
        self.store = store
    }

    public init(domainStore: SQLiteDomainStore) {
        self.init(store: SQLiteRoutineStore(domainStore: domainStore))
    }

    public func routine(botID: String, routineID: String) async -> BotFeedbackRoutineSnapshot? {
        let trimmed = routineID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let document = try? await store.read(botId: botID),
              let routine = document.routines.first(where: { $0.id == trimmed }) else {
            return nil
        }
        return BotFeedbackRoutineSnapshot(
            routineID: routine.id, title: routine.title,
            enabled: routine.enabled, revision: document.version)
    }
}
