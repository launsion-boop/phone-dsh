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
import PhoneDSHAgentCore
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

    /// The replacement Worker follows the production boot order: the ordered
    /// channel HELLOs as soon as the socket opens, but `serveApiRequests` is
    /// installed only near the end of the boot (the reserved `ready` phase).
    /// This drives a real `session/page` request through a real host transport
    /// after the ready line and proves it reached the replacement connection,
    /// not the old one, and answered inside two seconds.
    func testReplacementTransportAnswersARealRequestOnTheNewConnection() async throws {
        let fixture = try KillFixture()
        defer { fixture.cleanup() }
        let worker = KillWorker()
        let engine = KillMockEngine(worker: worker)
        let host = PhoneDSHHost(configuration: try fixture.configuration(),
                                engineFactory: { _ in engine })
        addTeardownBlock { try? await host.stop() }

        let hellos = HelloCollector(host.eventStream())
        let phases = WorkerPhaseCollector(host.eventStream())
        defer {
            hellos.stop()
            phases.stop()
        }

        try await host.start()
        try await waitForHost(host, .running)
        try await worker.waitForOpenFrames()
        _ = try await hellos.waitForCount(1)

        // The next connection is the replacement. Its API bridge stays closed
        // until the Worker announces `ready`, exactly like the real entry.
        await worker.holdAPIRequestsOnNextConnect(readyDelayMilliseconds: 40)
        engine.emitTermination()
        try await waitForHost(host, .running)
        let second = try await hellos.waitForCount(2)
        _ = try await phases.waitForWorkerReady()

        // What the Bot bind does after the readiness gate: a real API request.
        let transport = try await host.makeTransport()
        let started = Date()
        _ = try await transport.call("session/page", args: .object([
            "request": .object([
                "address": .object([
                    "kind": .string("session"),
                    "sessionId": .string("gb-main"),
                ]),
                "throughSeq": .number(-1),
                "maxMessages": .number(1),
            ]),
        ]))
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 2,
                          "the replacement connection must answer an API request "
                              + "after ready; elapsed=\(elapsed)")

        let snapshot = await host.channelSelection()
        let selection = try XCTUnwrap(snapshot)
        XCTAssertEqual(selection.currentConnectionID, selection.latestHelloConnectionID)
        XCTAssertTrue(selection.isCurrentConnectionLatestHello)
        XCTAssertEqual(selection.currentWorkerBootID, second.bootID,
                       "the transport must target the replacement HELLO's boot")
        XCTAssertEqual(selection.latestHelloCount, second.count)

        let served = await worker.servedAPIConnectionNumbers()
        XCTAssertEqual(served.last, 2,
                       "the replacement request must be served by connection 2, "
                           + "not the old Worker: served=\(served)")
        let received = await worker.receivedAPIConnectionNumbersSnapshot()
        XCTAssertEqual(received.last, 2)
        let paths = await worker.receivedAPIPathsSnapshot()
        XCTAssertTrue(paths.contains { $0.hasSuffix("session/page") }, "paths=\(paths)")
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
        scheduler.noteWorkerReady()

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

    /// Collects the reserved Worker boot-phase console lines the host forwards.
    private final class WorkerPhaseCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [PhoneDSHBootPhase] = []
        private var task: Task<Void, Never>?

        init(_ stream: AsyncStream<PhoneDSHEvent>) {
            task = Task { [weak self] in
                for await event in stream {
                    guard let self else { return }
                    guard case .console(let payload) = event,
                          let phase = PhoneDSHBootPhase.parse(payload.text),
                          phase.scope == "worker" else { continue }
                    self.lock.lock()
                    self.storage.append(phase)
                    self.lock.unlock()
                }
            }
        }

        var phases: [PhoneDSHBootPhase] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func waitForWorkerReady(timeout: TimeInterval = 20) async throws
            -> PhoneDSHBootPhase {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if let ready = phases.last(where: { $0.phase == "ready" }) {
                    return ready
                }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            throw KillError.timeout("the replacement Worker never logged the ready phase")
        }

        func stop() {
            task?.cancel()
            task = nil
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
