// SPDX-License-Identifier: MIT

import XCTest
import PhoneDSHBot
@testable import PhoneDSHProbe

private final class GatedLifecycleSource: BotContextSourceRequesting,
                                          BotContextSourceStreaming,
                                          @unchecked Sendable {
    let kind: BotContextSourceKind = .calendar
    private let lock = NSLock()
    private var calls = 0
    private var continuations: [Int: CheckedContinuation<BotSourceAuthorization, Never>] = [:]
    private var starts = 0

    func authorization() async -> BotSourceAuthorization {
        await withCheckedContinuation { continuation in
            lock.lock()
            calls += 1
            continuations[calls] = continuation
            lock.unlock()
        }
    }

    func requestAuthorization() async -> BotSourceAuthorization { .authorized }
    func start(permissionRevision: Int,
               emit: @escaping @Sendable (BotContextObservation) -> Void) async throws {
        lock.lock(); starts += 1; lock.unlock()
    }
    func observations(since: Int64?) async throws -> [BotContextObservation] { [] }
    func stop() async {}

    func waitForCall(_ number: Int) async -> Bool {
        for _ in 0..<150 {
            lock.lock(); let value = calls >= number; lock.unlock()
            if value { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    func resume(call number: Int, _ status: BotSourceAuthorization) {
        lock.lock(); let continuation = continuations.removeValue(forKey: number); lock.unlock()
        continuation?.resume(returning: status)
    }

    func startCount() -> Int { lock.lock(); defer { lock.unlock() }; return starts }
}


private final class ImmediateLifecycleSource: BotContextSourceRequesting,
                                            BotContextSourceStreaming,
                                            @unchecked Sendable {
    let kind: BotContextSourceKind = .calendar
    func authorization() async -> BotSourceAuthorization { .authorized }
    func requestAuthorization() async -> BotSourceAuthorization { .authorized }
    func start(permissionRevision: Int,
               emit: @escaping @Sendable (BotContextObservation) -> Void) async throws {}
    func observations(since: Int64?) async throws -> [BotContextObservation] { [] }
    func stop() async {}
}

private actor PauseGate {
    private var arrived = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        arrived = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }
    func waitUntilArrived() async {
        for _ in 0..<150 {
            if arrived { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    func release() {
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume()
    }
}

@MainActor
final class BotContextSourcesAssemblyLifecycleTests: XCTestCase {
    func testStopThenLatestStartWinsAndOldStartCannotSetStarted() async throws {
        let source = GatedLifecycleSource()
        let assembly = BotContextSourcesAssembly(
            dependencies: .init(sourceOverrides: [.calendar: source]))

        let first = Task { @MainActor in
            try await assembly.start { _ in }
        }
        let reachedFirst = await source.waitForCall(1)
        XCTAssertTrue(reachedFirst, "first start did not reach authorization")
        await assembly.stopAll()

        let second = Task { @MainActor in
            try await assembly.start { _ in }
        }
        let reachedSecond = await source.waitForCall(2)
        XCTAssertTrue(reachedSecond, "latest start did not reach authorization")

        source.resume(call: 1, .authorized)
        try await first.value
        XCTAssertFalse(assembly.isStarted(), "late old start must not win")
        source.resume(call: 2, .authorized)
        try await second.value
        XCTAssertTrue(assembly.isStarted(), "latest start must eventually take effect")
    }

    func testStopAloneInvalidatesInFlightStart() async throws {
        let source = GatedLifecycleSource()
        let assembly = BotContextSourcesAssembly(
            dependencies: .init(sourceOverrides: [.calendar: source]))
        let first = Task { @MainActor in
            try await assembly.start { _ in }
        }
        let reached = await source.waitForCall(1)
        XCTAssertTrue(reached)
        await assembly.stopAll()
        source.resume(call: 1, .authorized)
        try await first.value
        XCTAssertFalse(assembly.isStarted())
        XCTAssertEqual(source.startCount(), 0)
    }

    func testStopWhileWakeInstallPausedBeforeHandlerLeavesNoStartedRelay() async throws {
        let gate = PauseGate()
        let assembly = BotContextSourcesAssembly(
            dependencies: .init(
                sourceOverrides: [.calendar: ImmediateLifecycleSource()],
                wakeInstallBefore: { await gate.wait() }))
        let start = Task { @MainActor in try await assembly.start { _ in } }
        await gate.waitUntilArrived()
        let stop = Task { @MainActor in await assembly.stopAll() }
        await gate.release()
        try await start.value
        await stop.value
        XCTAssertFalse(assembly.isStarted(), "paused-before wake install must be cleaned up")
    }

    func testStopWhileWakeInstallPausedAfterRelayLeavesNoStartedRelay() async throws {
        let gate = PauseGate()
        let assembly = BotContextSourcesAssembly(
            dependencies: .init(
                sourceOverrides: [.calendar: ImmediateLifecycleSource()],
                wakeInstallAfter: { await gate.wait() }))
        let start = Task { @MainActor in try await assembly.start { _ in } }
        await gate.waitUntilArrived()
        let stop = Task { @MainActor in await assembly.stopAll() }
        await gate.release()
        try await start.value
        await stop.value
        XCTAssertFalse(assembly.isStarted(), "paused-after wake install must be cleaned up")
    }
}
