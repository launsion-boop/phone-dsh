// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — when a second wake arrives while one is in flight.
//
// host contract §10.2.5: "A second wake that arrives while the first is in
// flight is merged: it does not boot again, does not queue a second sweep, and
// awaits the first sweep's report." Only after the in-flight wake has entered
// stage D may one follow-up wake be queued; any number of arrivals collapse
// into it, keeping the widest eligibility (foreground/resident over any lease,
// and the longest remaining lease otherwise).

import Foundation

/// How far the in-flight wake has progressed. Stage D is the first point after
/// which a new arrival needs its own (merged) follow-up sweep.
public enum WakePhase: Int, Sendable, Equatable, CaseIterable {
    case stageA
    case stageB
    case stageC
    case stageD
}

public enum WakeMergeAction: Equatable, Sendable {
    /// Nothing in flight: this wake runs now.
    case start
    /// A wake is in flight before stage D: join it, no second boot or sweep.
    case joinInFlight
    /// The in-flight wake already started its sweep: queue at most one
    /// follow-up, merging every later arrival into it.
    case mergePending
}

public enum WakeMergePolicy {
    public static func action(hasInFlight: Bool, phase: WakePhase?) -> WakeMergeAction {
        guard hasInFlight else { return .start }
        guard let phase else { return .joinInFlight }
        return phase == .stageD ? .mergePending : .joinInFlight
    }

    /// Widest eligibility wins: a `nil` lease means foreground or resident
    /// audio and beats any lease; otherwise the longer remaining lease wins.
    public static func mergedLease(_ current: WakeLease?, _ incoming: WakeLease?,
                                   nowMs: Int64 = WakeLease.nowMs()) -> WakeLease? {
        if current == nil || incoming == nil { return nil }
        let currentRemaining = current?.remainingMs(nowMs: nowMs) ?? 0
        let incomingRemaining = incoming?.remainingMs(nowMs: nowMs) ?? 0
        return incomingRemaining > currentRemaining ? incoming : current
    }
}

/// I4: a newly adopted engine instance owes one ReadySweep. The sweep is owned
/// by the wake already in flight when there is one; otherwise adoption starts
/// a wake itself, so a button-triggered boot is swept exactly once.
public enum EngineAdoptionPolicy {
    /// `isCurrentIncarnation` is a staleness guard only: an old adoption
    /// notification must not sweep a newer engine. Whether the sweep runs now,
    /// joins an in-flight wake or becomes the one pending follow-up is the
    /// merge rule's decision (§10.2.5).
    public static func shouldSweep(isCurrentIncarnation: Bool) -> Bool {
        isCurrentIncarnation
    }
}

/// The merge state machine the orchestrator drives (§10.2.5). It decides
/// admission and holds the single pending follow-up; the orchestrator owns the
/// continuations that make every merged caller wait for the run it joined.
public struct WakeMergeState: Sendable, Equatable {
    public struct Request: Sendable, Equatable {
        public var reason: WakeReason
        public var lease: WakeLease?
        public var wakeId: String

        public init(reason: WakeReason, lease: WakeLease?, wakeId: String) {
            self.reason = reason
            self.lease = lease
            self.wakeId = wakeId
        }
    }

    public enum Admission: Equatable, Sendable {
        /// Nothing in flight: run this request now.
        case start(Request)
        /// Join the in-flight run; its outcome is the caller's outcome.
        case join(Request)
        /// The in-flight run already reached stage D: one follow-up request,
        /// merged with every arrival until that follow-up starts.
        case pending(Request)
    }

    public private(set) var inFlight: Request?
    public private(set) var phase: WakePhase?
    public private(set) var pending: Request?

    public init() {}

    public mutating func arrive(_ request: Request,
                                nowMs: Int64 = WakeLease.nowMs()) -> Admission {
        guard let running = inFlight else {
            inFlight = request
            phase = .stageA
            return .start(request)
        }
        switch WakeMergePolicy.action(hasInFlight: true, phase: phase) {
        case .start, .joinInFlight:
            return .join(running)
        case .mergePending:
            var merged = pending ?? request
            merged.lease = WakeMergePolicy.mergedLease(merged.lease, request.lease, nowMs: nowMs)
            if request.lease == nil { merged.reason = request.reason }
            pending = merged
            return .pending(merged)
        }
    }

    public mutating func enter(_ phase: WakePhase) {
        guard inFlight != nil else { return }
        self.phase = phase
    }

    /// The in-flight run ended. Returns the follow-up to start, if any; every
    /// later arrival before that start merges into the same follow-up.
    public mutating func finish() -> Request? {
        if let pending {
            inFlight = pending
            phase = .stageA
            self.pending = nil
            return pending
        }
        inFlight = nil
        phase = nil
        return nil
    }
}
