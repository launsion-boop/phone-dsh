// SPDX-License-Identifier: MIT

import Foundation

/// The single fish-lifecycle projection shared by the Bot runtime unit, the
/// chat page and the roster drawer (P09 `ui/v1/bot/ui-state.md` §4.7).
///
/// The presentation input is deliberately narrower than the app's
/// `BotRuntimePresentation`: this type is pure and testable without the app
/// target, and the projection only needs the director state and its one-shot.
public struct BotFishLifecyclePresentation: Equatable, Sendable {
    public var fishState: BotFishLifecycle
    public var oneShot: BotFishOneShot?

    public init(fishState: BotFishLifecycle = .idle,
                oneShot: BotFishOneShot? = nil) {
        self.fishState = fishState
        self.oneShot = oneShot
    }
}

/// One lifecycle, one priority. A caller supplies the inputs; this function
/// never reads a wall clock and never invents an event.
///
/// Order (normative, `ui-state.md` §4.7):
/// 1. a pending approval is `alerting`;
/// 2. an unexpired one-shot is that one-shot's state;
/// 3. the live presentation wins over the durable one while a live turn exists;
/// 4. while running, an `idle` base is drawn as `working`;
/// 5. when not running, an idle-sleeping Bot is `sleeping`;
/// 6. otherwise the selected presentation's state (`idle` by default).
///
/// The live one-shot is considered even after the live turn has settled: the
/// durable projection may not have caught up yet. An unexpired one-shot in the
/// durable presentation is already reflected in its `fishState` by the
/// factory, but it is accepted here too so both ends can pass the same value.
public enum BotFishLifecycleProjection {
    public static func resolve(pendingApprovalCount: Int,
                               running: Bool,
                               idleSleeping: Bool,
                               livePresentation: BotFishLifecyclePresentation?,
                               durablePresentation: BotFishLifecyclePresentation,
                               liveTurn: Bool,
                               now: Int64) -> BotFishLifecycle {
        if pendingApprovalCount > 0 {
            return .alerting
        }
        if let shot = unexpiredOneShot(livePresentation, now: now)
            ?? unexpiredOneShot(durablePresentation, now: now) {
            return shot.state
        }
        let base: BotFishLifecycle
        if liveTurn, let livePresentation {
            base = livePresentation.fishState
        } else {
            base = durablePresentation.fishState
        }
        if running {
            return base == .idle ? .working : base
        }
        if idleSleeping {
            return .sleeping
        }
        return base
    }

    private static func unexpiredOneShot(_ presentation: BotFishLifecyclePresentation?,
                                         now: Int64) -> BotFishOneShot? {
        guard let shot = presentation?.oneShot, now < shot.endsAt else { return nil }
        return shot
    }
}

/// The quantised head-slice inputs. They are source-space units divided by the
/// active profile's quantum: `standard` 0.1, `lively` 0.25
/// (`examples/probe-app/PhoneDSHProbe/Bot/Fish/BotFishRenderer.swift`).
///
/// The same quantum MUST convert the levels back to source units. Keeping the
/// quantiser and the restore in one pure type is what freezes FISH-1.
public struct BotFishHeadSliceLevels: Equatable, Sendable {
    public var headX: Int
    public var headY: Int
    public var hairSway: Int
    public var earFlutter: Int

    public init(headX: Int, headY: Int, hairSway: Int, earFlutter: Int) {
        self.headX = headX
        self.headY = headY
        self.hairSway = hairSway
        self.earFlutter = earFlutter
    }

    public static let identity = BotFishHeadSliceLevels(
        headX: 0, headY: 0, hairSway: 0, earFlutter: 0)

    public var isIdentity: Bool { self == Self.identity }
}

/// The effective displacement in source units for one slice row.
public struct BotFishHeadSliceDisplacement: Equatable, Sendable {
    public var headX: Double
    public var headY: Double
    public var hairSway: Double
    public var earFlutter: Double

    public init(headX: Double, headY: Double,
                hairSway: Double, earFlutter: Double) {
        self.headX = headX
        self.headY = headY
        self.hairSway = hairSway
        self.earFlutter = earFlutter
    }
}

public enum BotFishHeadSlice {
    /// `standard` profile quantum in source units.
    public static let standardQuantum: Double = 0.1
    /// `lively` profile quantum in source units.
    public static let livelyQuantum: Double = 0.25

    public static func quantum(lively: Bool) -> Double {
        lively ? livelyQuantum : standardQuantum
    }

    /// Quantise with Swift `Double.rounded()` (nearest, half away from zero).
    public static func levels(headX: Double, headY: Double,
                              hairSway: Double, earFlutter: Double,
                              quantum: Double) -> BotFishHeadSliceLevels {
        let step = quantum > 0 ? quantum : standardQuantum
        func quantise(_ value: Double) -> Int {
            Int((value / step).rounded())
        }
        return BotFishHeadSliceLevels(headX: quantise(headX),
                                      headY: quantise(headY),
                                      hairSway: quantise(hairSway),
                                      earFlutter: quantise(earFlutter))
    }

    /// Restore the levels with the same quantum that produced them.
    public static func displacement(_ levels: BotFishHeadSliceLevels,
                                    quantum: Double) -> BotFishHeadSliceDisplacement {
        let step = quantum > 0 ? quantum : standardQuantum
        return BotFishHeadSliceDisplacement(
            headX: Double(levels.headX) * step,
            headY: Double(levels.headY) * step,
            hairSway: Double(levels.hairSway) * step,
            earFlutter: Double(levels.earFlutter) * step)
    }
}

/// The UI-2 retry policy (`ui-state.md` §3.1): a failed action key is
/// retryable, a pending or accepted key is not, and only a question card has a
/// dismiss intent. The page maps its local `BotUIActionState` onto this value.
/// The types are nested so they cannot collide with the app's card kinds.
public enum BotUIActionRetry {
    public enum Intent: String, Sendable {
        case dismiss, answer, approval
    }

    public enum CardKind: String, Sendable {
        case question, steps
    }

    public enum KeyState: String, Sendable {
        case pending, accepted, failed
    }

    public static func accepts(intent: Intent,
                               cardKind: CardKind,
                               state: KeyState?) -> Bool {
        let retryable = state == nil || state == .failed
        switch intent {
        case .dismiss:
            return cardKind == .question && retryable
        case .answer, .approval:
            return retryable
        }
    }
}
