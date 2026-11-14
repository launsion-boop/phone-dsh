// SPDX-License-Identifier: MIT

import Foundation

/// One roster unit as a host bind sees it. The bind decides from this snapshot
/// whether the unit has to be restarted, never from the order of the roster or
/// from the identity of the selected Bot.
public struct BotRebindUnit: Sendable, Equatable {
    public let botID: String
    /// The unit's Worker transport is attached and answers for the Worker
    /// incarnation the bind is binding to.
    public let hasLiveTransport: Bool
    /// The last `BotRuntimeUnit.start` completed (transport, main session,
    /// scheduler, live observation). A unit whose start failed is restarted
    /// even if it already attached a transport, because its environment and
    /// scheduler never reached the running state.
    public let isStarted: Bool

    public init(botID: String, hasLiveTransport: Bool, isStarted: Bool) {
        self.botID = botID
        self.hasLiveTransport = hasLiveTransport
        self.isStarted = isStarted
    }
}

public enum BotRebindDecision: String, Sendable, Equatable {
    /// Keep the unit's transport and running turn. Restarting it would swap a
    /// working transport and cut a live turn for no reason.
    case keep
    /// The unit has no usable transport (never attached, detached, or a failed
    /// start) or the bind is for a replaced Worker incarnation.
    case restart
}

/// Why a bind replaces a Worker incarnation. A bind that is not for a new
/// Worker must not touch a live unit at all: it would otherwise turn any
/// App-side rebind trigger into a cancellation of every Bot's running turn.
public enum BotWorkerIncarnation {
    /// True when `currentBootID` names a different Worker process than the one
    /// the units are attached to. The first bind (`previousBootID == nil`) is a
    /// replacement by definition; an empty comparison is never used to keep a
    /// transport whose Worker identity is unknown.
    public static func isReplaced(previousBootID: String?, currentBootID: String) -> Bool {
        guard let previousBootID, !previousBootID.isEmpty else { return true }
        return previousBootID != currentBootID
    }
}

/// Applies one host bind's restart scope to the roster units.
///
/// This is the mechanism that keeps "one Bot's turn running" independent of
/// "the other Bot was selected". Before it, every bind cancelled each unit's
/// in-flight turns and re-claimed every session, so an unrelated rebind looked
/// to the user like the other Bot disconnected. A live unit is now left alone:
/// its transport, main session, scheduler and running turn stay untouched.
@MainActor
public enum BotRebindScope {
    public struct Outcome: Sendable, Equatable {
        /// Units left untouched; their transport and turn kept running.
        public var kept: [String] = []
        /// Units whose `restart` completed.
        public var restarted: [String] = []
        /// Units whose `restart` threw, keyed by Bot id. The caller owns the
        /// user-facing policy (the selected Bot fails the bind; another Bot is
        /// skipped and reported).
        public var failed: [String: String] = [:]
        /// The bind was cancelled while restarting; the caller rethrows.
        public var wasCancelled = false
    }

    /// Restarts every unit that is not serving the current Worker incarnation,
    /// and exactly those. Each restart runs sequentially so transient transport
    /// creation stays ordered, and a thrown error is recorded for that unit
    /// without stopping the rest (the caller decides whether that is fatal).
    ///
    /// - Parameter forceRestart: the bind is for a replaced Worker incarnation.
    ///   Every unit's transport belongs to the old process, so all are
    ///   restarted; `BotDSHRemoteRuntime.attachTransport` then *adopts* the new
    ///   transport (marks a running turn interrupted, never cancels it).
    public static func apply<T>(
        _ candidates: [T],
        forceRestart: Bool,
        state: @MainActor (T) async -> BotRebindUnit,
        restart: @MainActor (T) async throws -> Void
    ) async -> Outcome {
        var outcome = Outcome()
        for candidate in candidates {
            let unit = await state(candidate)
            let decision: BotRebindDecision =
                forceRestart || !(unit.hasLiveTransport && unit.isStarted)
                ? .restart : .keep
            switch decision {
            case .keep:
                outcome.kept.append(unit.botID)
            case .restart:
                do {
                    try await restart(candidate)
                    outcome.restarted.append(unit.botID)
                } catch is CancellationError {
                    outcome.wasCancelled = true
                    return outcome
                } catch {
                    outcome.failed[unit.botID] = String(describing: error)
                }
            }
        }
        return outcome
    }
}
