// SPDX-License-Identifier: MIT

import Combine
import Foundation

/// Counts transcript row-body evaluations. The capture fixture attaches this
/// to the real `BotChatPage`; a stable fixture must stop evaluating rows after
/// the keyboard, composer and appended rows have settled. Calling this from a
/// view body mutates a plain class only, so it cannot invalidate SwiftUI.
final class BotTranscriptRenderProbe {
    private(set) var bodyEvaluations = 0
    private(set) var perRow: [String: Int] = [:]

    func note(_ rowID: String) {
        bodyEvaluations += 1
        perRow[rowID, default: 0] += 1
    }

    func reset() {
        bodyEvaluations = 0
        perRow.removeAll()
    }
}

/// Fixture-only stability probe. `chatLayoutTyping` attaches the real chat
/// model; the capture conformance check waits for the fixture to finish
/// appending rows, then proves neither `objectWillChange` nor a row body keeps
/// firing for two seconds.
/// Thread-safe counter: `objectWillChange` is delivered synchronously, and a
/// hop to the main actor could land after the conformance snapshot.
private final class BotAtomicCounter {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    func reset() {
        lock.lock()
        value = 0
        lock.unlock()
    }

    var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

@MainActor
final class BotTranscriptStabilityProbe {
    static let shared = BotTranscriptStabilityProbe()

    struct Snapshot {
        let publishes: Int
        let rowBodyEvaluations: Int
        let rowCount: Int
    }

    let renderProbe = BotTranscriptRenderProbe()
    private let publishCounter = BotAtomicCounter()
    private var cancellable: AnyCancellable?
    private var attachedModel: BotChatModel?
    private(set) var settled = false

    func attach(model: BotChatModel) {
        guard attachedModel !== model else { return }
        cancellable?.cancel()
        attachedModel = model
        publishCounter.reset()
        settled = false
        renderProbe.reset()
        let counter = publishCounter
        cancellable = model.objectWillChange.sink { _ in
            counter.increment()
        }
    }

    func markSettled() {
        settled = true
    }

    /// Polls without blocking the main run loop. The capture check runs on the
    /// main actor; a synchronous wait would stop the fixture itself.
    func waitUntilSettled(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !settled, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return settled
    }

    func snapshot() -> Snapshot {
        Snapshot(publishes: publishCounter.current,
                 rowBodyEvaluations: renderProbe.bodyEvaluations,
                 rowCount: renderProbe.perRow.count)
    }
}
