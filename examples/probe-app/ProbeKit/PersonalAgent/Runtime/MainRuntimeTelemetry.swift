// SPDX-License-Identifier: MIT

import Foundation

public struct MainTurnLatency: Codable, Sendable, Equatable {
    public let turnID: UUID
    public let requestSentAt: [Date]
    public let firstTextDeltaAt: Date?
    public let endedAt: Date
    public let outcome: String

    public init(turnID: UUID, requestSentAt: [Date], firstTextDeltaAt: Date?,
                endedAt: Date, outcome: String) {
        self.turnID = turnID
        self.requestSentAt = requestSentAt
        self.firstTextDeltaAt = firstTextDeltaAt
        self.endedAt = endedAt
        self.outcome = outcome
    }

    public var firstTextLatencyMilliseconds: Double? {
        guard let firstRequest = requestSentAt.first, let firstTextDeltaAt else { return nil }
        return firstTextDeltaAt.timeIntervalSince(firstRequest) * 1_000
    }

    public var turnDurationMilliseconds: Double? {
        guard let firstRequest = requestSentAt.first else { return nil }
        return endedAt.timeIntervalSince(firstRequest) * 1_000
    }
}

public protocol MainLatencyRecording: Sendable {
    func record(_ latency: MainTurnLatency) async
}

public actor MainLatencyRecorder: MainLatencyRecording {
    private var samples: [UUID: MainTurnLatency] = [:]

    public init() {}

    public func record(_ latency: MainTurnLatency) {
        samples[latency.turnID] = latency
    }

    public func latency(for turnID: UUID) -> MainTurnLatency? {
        samples[turnID]
    }

    public func allSamples() -> [MainTurnLatency] {
        samples.values.sorted { $0.endedAt < $1.endedAt }
    }
}

final class MainTurnLatencyTracker: @unchecked Sendable {
    let turnID: UUID
    private let lock = NSLock()
    private var requestSentAt: [Date] = []
    private var firstTextDeltaAt: Date?

    init(turnID: UUID) {
        self.turnID = turnID
    }

    func markRequest(at date: Date = Date()) {
        lock.lock()
        requestSentAt.append(date)
        lock.unlock()
    }

    func markText(at date: Date = Date()) {
        lock.lock()
        if firstTextDeltaAt == nil { firstTextDeltaAt = date }
        lock.unlock()
    }

    func sample(endedAt: Date = Date(), outcome: String) -> MainTurnLatency {
        lock.lock()
        let requests = requestSentAt
        let firstText = firstTextDeltaAt
        lock.unlock()
        return MainTurnLatency(turnID: turnID, requestSentAt: requests,
                               firstTextDeltaAt: firstText, endedAt: endedAt, outcome: outcome)
    }
}
