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
    public static func shouldSweep(incarnationChanged: Bool, wakeInFlight: Bool) -> Bool {
        incarnationChanged && !wakeInFlight
    }
}
