// SPDX-License-Identifier: MIT
#if BOT_RESIDENCY_SPIKE

import Foundation

public enum BotResidencyEvidenceError: Error {
    case cannotCreateLog
}

public enum BotResidencySchedule {
    public static func make(configuration: BotResidencyConfiguration,
                            startedAt: Date = Date()) -> BotResidencyPlan {
        var random = BotResidencyRandom(seed: configuration.seed)
        let events = offsets(count: configuration.eventCount,
                             duration: configuration.durationSeconds,
                             random: &random).enumerated().map { index, offset in
            BotResidencyScheduledAction(id: String(format: "event-%03d", index + 1),
                                        offsetSeconds: offset)
        }
        let kills = offsets(count: configuration.killCount,
                            duration: configuration.durationSeconds,
                            random: &random).enumerated().map { index, offset in
            BotResidencyScheduledAction(id: String(format: "kill-%03d", index + 1),
                                        offsetSeconds: offset)
        }
        return BotResidencyPlan(configuration: configuration,
                                startedAt: BotResidencyTime.string(startedAt),
                                events: events, kills: kills)
    }

    private static func offsets(count: Int, duration: Int,
                                random: inout BotResidencyRandom) -> [Double] {
        guard count > 0 else { return [] }
        let segment = Double(duration) / Double(count)
        let margin = min(15, segment / 5)
        return (0..<count).map { index in
            let lower = Double(index) * segment + margin
            let upper = max(lower, Double(index + 1) * segment - margin)
            let value = lower + (upper - lower) * random.nextUnit()
            return (value * 1000).rounded() / 1000
        }
    }
}

public struct BotResidencyRandom: Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    public mutating func nextUnit() -> Double {
        Double(next() >> 11) / Double(UInt64(1) << 53)
    }
}
#endif
