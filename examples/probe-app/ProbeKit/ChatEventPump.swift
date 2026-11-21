// SPDX-License-Identifier: MIT
import Foundation
import PhoneDSHAgentCore

/// Rebuild the view from a fresh snapshot before reopening a broken subscription.
@MainActor
public enum ChatEventPump {
    private enum StreamError: Error { case ended }

    public static func run(
        after initialSeq: UInt64?,
        retryDelay: Duration = .milliseconds(300),
        isCurrent: () -> Bool,
        events: (UInt64?) -> AsyncThrowingStream<HarnessEvent, Error>,
        synchronize: () async throws -> UInt64?,
        handle: (HarnessEvent) -> Void,
        interrupted: (Error) -> Void,
        recovered: () -> Void
    ) async {
        var after = initialSeq
        var needsSnapshot = false
        var failures = 0
        while !Task.isCancelled && isCurrent() {
            do {
                if needsSnapshot {
                    let cursor = try await synchronize()
                    guard !Task.isCancelled, isCurrent() else { return }
                    after = cursor
                    needsSnapshot = false
                    recovered()
                }
                let clock = ContinuousClock()
                var sliceStart = clock.now
                var sliceCount = 0
                for try await event in events(after) {
                    // A replay can already be buffered: `await next()` then
                    // need not yield the MainActor. Let input/layout run after
                    // a bounded batch without dropping or reordering events.
                    if sliceCount >= 64 || sliceStart.duration(to: clock.now) >= .milliseconds(2) {
                        try await Task.sleep(for: .milliseconds(1))
                        sliceStart = clock.now
                        sliceCount = 0
                    }
                    guard !Task.isCancelled, isCurrent() else { return }
                    sliceCount += 1
                    if let seq = event.seq, let current = after, seq <= current { continue }
                    if let seq = event.seq { after = seq }
                    handle(event)
                    failures = 0
                }
                // EOF is also a lost subscription, even without an error frame.
                throw StreamError.ended
            } catch {
                guard !Task.isCancelled, isCurrent() else { return }
                interrupted(error)
                needsSnapshot = true
                failures = min(failures + 1, 5)
                do {
                    try await Task.sleep(for: min(retryDelay * (1 << (failures - 1)), .seconds(5)))
                } catch { return }
            }
        }
    }
}
