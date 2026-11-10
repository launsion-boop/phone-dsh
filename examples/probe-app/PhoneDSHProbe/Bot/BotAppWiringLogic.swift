// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSHBot

// Pure app-layer wiring rules that the production composition and the
// fixture checks share. Keeping the decisions here (instead of inside actors
// that need a live Host) is what makes the delete cascade, unread routing,
// main-Bot routing and team delivery policy testable without a Worker.

// MARK: - Main-Bot pointer

/// Every legacy hard-coded `"main"` is replaced by the roster's main-Bot
/// pointer. `legacyMainID` names the pre-roster record only so old deep links
/// and old data can still find their Bot; it is never a routing default.
enum BotMainPointerRouting {
    static let legacyMainID = "main"

    static func mainBot(in roster: BotRoster) -> BotProfile? {
        guard let id = roster.mainBotID else { return nil }
        return roster.bots.first { $0.id == id }
    }

    static func mainBotID(in roster: BotRoster) -> String? {
        roster.mainBotID
    }

    /// Restores a persisted selection only when that Bot still exists;
    /// otherwise the repaired main pointer wins, then the first Bot.
    static func restoredSelection(_ saved: String?, in roster: BotRoster) -> String? {
        if let saved, roster.bots.contains(where: { $0.id == saved }) { return saved }
        return roster.mainBotID ?? roster.bots.first?.id
    }

    /// Device task results and default routine ownership belong to the main
    /// Bot pointer, not to a literal id.
    static func deviceTaskRecipient(in roster: BotRoster) -> String? {
        roster.mainBotID ?? roster.bots.first?.id
    }

    static func defaultRoutineBotID(in roster: BotRoster) -> String? {
        roster.mainBotID ?? roster.bots.first?.id
    }

    /// A deep link names its Bot explicitly. A stale legacy link to `main`
    /// resolves to the current main-Bot pointer when no `main` record exists;
    /// a link to any other removed id fails closed.
    static func deepLinkBotID(_ requested: String, in roster: BotRoster) -> String? {
        if roster.bots.contains(where: { $0.id == requested }) { return requested }
        if requested == legacyMainID { return roster.mainBotID }
        return nil
    }
}

// MARK: - Unread

/// Who receives an unread bump for one agent-comm row. The current Bot is
/// never bumped, matching upstream `store.cjs:603-608`.
enum BotUnreadRules {
    /// `outbound` means the target received the message; `inbound` and
    /// `reply` mean the transcript owner received one. `incoming` is the
    /// target-side row for a message that just arrived.
    static func recipient(for record: BotTeamAgentCommRecord) -> String? {
        switch record.direction {
        case .outbound:
            return record.toAgent?.id
        case .inbound:
            return record.botID
        case .incoming:
            return record.botID
        case .reply:
            return record.botID
        }
    }

    static func shouldIncrement(recipient: String?, selectedBotID: String?) -> Bool {
        guard let recipient, !recipient.isEmpty else { return false }
        return recipient != selectedBotID
    }

    /// Routines and device-task results are delivered as messages to a Bot;
    /// only a non-selected recipient gets an unread count.
    static func shouldIncrementForDelivery(to botID: String, selectedBotID: String?) -> Bool {
        !botID.isEmpty && botID != selectedBotID
    }
}

// MARK: - Team delivery

enum BotTeamDeliveryMode: String, Equatable, Sendable {
    case now
    case queued
}

/// What the host does for one `SendToAgent` delivery. The decision is
/// independent of which runtime call performs it so it can be checked in the
/// capture app without a live target.
enum BotTeamDeliveryDecision: Equatable, Sendable {
    /// Target is idle: open a visible target turn and wait for its final text.
    case openVisibleTurn
    /// Target is busy: hold the message, wake the target after its current
    /// turn and wait for that wake turn's final text.
    case queueHeldAndWakeAfterBusy
    /// Delivery was requested as queued: hold the message and do not wake.
    case queueHeldOnly
}

enum BotTeamDeliveryPolicy {
    static func decide(delivery: String, targetBusy: Bool) -> BotTeamDeliveryDecision {
        if delivery == BotTeamDeliveryMode.queued.rawValue { return .queueHeldOnly }
        return targetBusy ? .queueHeldAndWakeAfterBusy : .openVisibleTurn
    }

    /// The held item's idempotency key. A `now` delivery that had to queue is
    /// distinct from the sender's explicit `queued` call for the same call id.
    static func heldRequestID(for request: BotAgentDeliveryRequest, suffix: String = "") -> String {
        suffix.isEmpty ? "now:\(request.requestId)" : "now:\(request.requestId):\(suffix)"
    }
}

// MARK: - Delete cascade

/// One ordered delete-cascade step. The profile record is deleted by the last
/// step; every earlier step is a pre-clean that must not leave a deleted
/// record behind if it fails.
struct BotDeletionStep {
    let name: String
    let action: () async throws -> Void
    /// Restores in-memory state (selection, cached models, live unit). Durable
    /// pre-clean operations are intentionally not invented back.
    let rollback: (() async throws -> Void)?

    init(name: String, action: @escaping () async throws -> Void,
         rollback: (() async throws -> Void)? = nil) {
        self.name = name
        self.action = action
        self.rollback = rollback
    }
}

struct BotDeletionFailure: Error, CustomStringConvertible {
    let step: String
    let executed: [String]
    let underlying: Error

    var description: String {
        "Bot deletion failed at \(step) after \(executed.joined(separator: " → ")): \(underlying)"
    }
}

struct BotDeletionPlan {
    static let orderedStepNames = [
        "abort-turns", "deny-approvals", "revoke-auth", "archive-sessions",
        "clear-routines", "clear-held", "erase-memory", "forget-memory",
        "unregister-sessions", "delete-profile", "teardown-caches",
    ]

    let steps: [BotDeletionStep]

    init(steps: [BotDeletionStep]) { self.steps = steps }

    /// Executes in order. A failure rolls back the already executed steps in
    /// reverse and rethrows a `BotDeletionFailure`, so a caller can tell the
    /// user which step blocked the delete without pretending it succeeded.
    @discardableResult
    func run() async throws -> [String] {
        var executed: [BotDeletionStep] = []
        for step in steps {
            do {
                try await step.action()
                executed.append(step)
            } catch {
                for previous in executed.reversed() {
                    try? await previous.rollback?()
                }
                throw BotDeletionFailure(
                    step: step.name,
                    executed: executed.map(\.name),
                    underlying: error)
            }
        }
        return executed.map(\.name)
    }
}
