// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — the pure wake projection.
//
// host contract `spec/host/v1/README.md` §10.3.3 (engine-launch-v1 revision 2):
// `WakeProjection.plan(nowMs, resident, demands)` is pure and total over valid
// input. It decides the resident host timer, the earliest time a background
// task may ask for (always, because suspension can happen at any moment), and
// which demands are due now.

import Foundation

/// The result of one projection plan.
public struct WakeProjection: Codable, Equatable, Sendable {
    /// One due demand identity (`source`, `key`) — the golden's `dueNow` shape.
    public struct DueDemand: Codable, Equatable, Sendable {
        public let source: WakeDemandSource
        public let key: String

        public init(source: WakeDemandSource, key: String) {
            self.source = source
            self.key = key
        }
    }

    public let residentTimerAtMs: Int64?
    /// Always present when the ledger has a demand, resident or not: the OS
    /// request never asks to start earlier than `now + minBackgroundDelayMs`.
    public let backgroundEarliestMs: Int64?
    public let dueNow: [DueDemand]

    public init(residentTimerAtMs: Int64?, backgroundEarliestMs: Int64?,
                dueNow: [DueDemand]) {
        self.residentTimerAtMs = residentTimerAtMs
        self.backgroundEarliestMs = backgroundEarliestMs
        self.dueNow = dueNow
    }

    /// Contract order: `dueAtMs`, then the `demandSources` order, then `key`.
    public static func dueOrder(_ lhs: WakeDemand, _ rhs: WakeDemand) -> Bool {
        if lhs.dueAtMs != rhs.dueAtMs { return lhs.dueAtMs < rhs.dueAtMs }
        if lhs.source.order != rhs.source.order { return lhs.source.order < rhs.source.order }
        return lhs.key < rhs.key
    }

    public static func plan(nowMs: Int64, resident: Bool,
                            demands: [WakeDemand]) -> WakeProjection {
        guard let earliest = demands.map(\.dueAtMs).min() else {
            return WakeProjection(residentTimerAtMs: nil, backgroundEarliestMs: nil, dueNow: [])
        }
        let residentTimer = resident ? max(earliest, nowMs) : nil
        let background = max(earliest, nowMs + EngineLaunchThresholds.minBackgroundDelayMs)
        let due = demands
            .filter { $0.dueAtMs <= nowMs }
            .sorted(by: dueOrder)
            .map { DueDemand(source: $0.source, key: $0.key) }
        return WakeProjection(residentTimerAtMs: residentTimer,
                              backgroundEarliestMs: background,
                              dueNow: due)
    }

    public static func plan(_ request: WakeProjectionRequest) -> WakeProjection {
        plan(nowMs: request.nowMs, resident: request.resident, demands: request.demands)
    }
}

/// The projection input, decoded strictly (§10.3.3: invalid input is rejected,
/// never coerced). The invalid golden vectors name the exact rejection reason.
public struct WakeProjectionRequest: Decodable, Sendable {
    public let nowMs: Int64
    public let resident: Bool
    public let demands: [WakeDemand]

    enum CodingKeys: String, CodingKey {
        case nowMs
        case resident
        case demands
    }

    public init(nowMs: Int64, resident: Bool, demands: [WakeDemand]) {
        self.nowMs = nowMs
        self.resident = resident
        self.demands = demands
    }

    public init(from decoder: Decoder) throws {
        do {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            nowMs = try c.decode(Int64.self, forKey: .nowMs)
            resident = try c.decode(Bool.self, forKey: .resident)
            demands = try c.decode([WakeDemand].self, forKey: .demands)
            guard Set(demands.map(\.id)).count == demands.count else {
                throw WakeContractError.duplicateDemand
            }
        } catch let error as WakeContractError {
            throw error
        } catch DecodingError.keyNotFound {
            throw WakeContractError.missingMember
        } catch DecodingError.valueNotFound {
            throw WakeContractError.missingMember
        } catch DecodingError.typeMismatch {
            throw WakeContractError.memberType
        } catch {
            throw WakeContractError.memberType
        }
    }
}
