// SPDX-License-Identifier: MIT
// End-to-end (host + scripted Worker) regression for the d-heal replacement
// identity: when the replacement Worker reuses the previous boot id, the
// HELLO immediately after `.webContentTerminated` is still a new connection
// and must drive exactly one App-side rebind.
//
// The scripted `KillMockEngine` exercises the same engine path as a production
// engine that has no `WebEngineRestartRequesting` lever: `bootWorker` is called
// with the host's existing `WebEngineConfiguration`, so the replacement Worker
// presents the same `boot_id`. This is the path the scheduler must not identify
// by boot id alone.

import Foundation
import XCTest
import PhoneDSH
import PhoneDSHBot
import PhoneDSHHarness

@MainActor
final class PhoneDSHReplacementWorkerBootIDTests: XCTestCase {
    /// Collects the ordered-channel HELLOs the host publishes.
    private final class HelloCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [PhoneDSHWorkerHello] = []
        private var task: Task<Void, Never>?

        init(_ stream: AsyncStream<PhoneDSHEvent>) {
            task = Task { [weak self] in
                for await event in stream {
                    guard let self else { return }
                    guard case .workerHello(let hello) = event else { continue }
                    self.lock.lock()
                    self.storage.append(hello)
                    self.lock.unlock()
                }
            }
        }

        var hellos: [PhoneDSHWorkerHello] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func waitForCount(_ count: Int, timeout: TimeInterval = 20) async throws
            -> PhoneDSHWorkerHello {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if let hello = hellos[safe: count - 1] { return hello }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            throw KillError.timeout("only \(hellos.count) Worker HELLOs arrived; wanted \(count)")
        }

        func stop() {
            task?.cancel()
            task = nil
        }
    }

    func testTerminationRecoveryWithAReusedBootIDRebindsTheReplacementHello() async throws {
        let fixture = try KillFixture()
        defer { fixture.cleanup() }
        let worker = KillWorker()
        let engine = KillMockEngine(worker: worker)
        let host = PhoneDSHHost(configuration: try fixture.configuration(),
                                engineFactory: { _ in engine })
        addTeardownBlock { try? await host.stop() }

        let collector = HelloCollector(host.eventStream())
        defer { collector.stop() }

        try await host.start()
        try await waitForHost(host, .running)
        try await worker.waitForOpenFrames()
        let first = try await collector.waitForCount(1)

        engine.emitTermination()
        try await waitForHost(host, .running)
        let second = try await collector.waitForCount(2)

        XCTAssertGreaterThan(engine.bootCount, 1, "the replacement Worker must have booted")
        XCTAssertEqual(second.bootID, first.bootID,
                       "this harness path reuses the host's engine configuration, so the "
                           + "regression must be covered with an unchanged Worker boot id")
        XCTAssertGreaterThan(second.count, first.count,
                            "the host HELLO count is monotonic across the replacement")

        // Reproduce the composition's event handling without the probe app:
        // seed the initial bind, consume the HELLO that belongs to it, then feed
        // the termination and the same-id replacement HELLO.
        let scheduler = BotWorkerRecoveryScheduler(timeoutMilliseconds: 1_000)
        defer { scheduler.stop() }
        var attempts: [String?] = []
        scheduler.install { bootID in attempts.append(bootID) }
        scheduler.seed(recoveredBootID: first.bootID)
        scheduler.noteWorkerBoot(first.bootID,
                                 helloCount: first.count,
                                 fenceGeneration: first.generation)
        XCTAssertTrue(attempts.isEmpty,
                      "the HELLO that is already covered by the seeded bind must not rebind")

        scheduler.noteTermination(count: 1)
        scheduler.noteWorkerBoot(second.bootID,
                                 helloCount: second.count,
                                 fenceGeneration: second.generation)

        let ready = await waitUntil(timeout: 2) { scheduler.phase == .ready }
        XCTAssertTrue(ready,
                      "the same-boot-id replacement HELLO must finish the rebind; "
                          + "phase=\(scheduler.phase) attempts=\(attempts)")
        XCTAssertEqual(attempts, [second.bootID],
                       "the replacement connection is claimed exactly once")
        XCTAssertEqual(scheduler.recoveredBootID, second.bootID)
        XCTAssertEqual(scheduler.latestHelloCount, second.count)
    }

    private func waitForHost(_ host: PhoneDSHHost, _ state: PhoneDSHState,
                             timeout: TimeInterval = 20) async throws {
        try await killWait(timeout: timeout) {
            await host.state == state
        }
    }

    private func waitUntil(timeout: TimeInterval,
                           _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
