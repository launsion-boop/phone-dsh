// SPDX-License-Identifier: MIT
// G2-ENG-03 host reaction: an `ERROR VFS_REFUSED` frame is recorded as a
// resource diagnostic. It must not publish the fail-loud `.error` event, must
// not close the ordered channel and must not move the host state machine to
// Failed (channel.md §4.8/§8/§10).

import Foundation
import XCTest
import PhoneDSHController
import PhoneDSH
import PhoneDSHEngine
import PhoneDSHWire
import PhoneDSHAgentCore

final class PhoneDSHVFSRefusalTests: XCTestCase {
    /// Collects the host event stream without blocking the test forever.
    private final class EventCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [PhoneDSHEvent] = []
        private var task: Task<Void, Never>?

        init(_ stream: AsyncStream<PhoneDSHEvent>) {
            task = Task { [weak self] in
                for await event in stream {
                    guard let self else { return }
                    self.lock.lock()
                    self.storage.append(event)
                    self.lock.unlock()
                }
            }
        }

        var events: [PhoneDSHEvent] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func stop() {
            task?.cancel()
            task = nil
        }

        deinit { task?.cancel() }
    }

    private func makeHost(_ fixture: FacadeFixture,
                          worker: MockWorker) throws -> PhoneDSHHost {
        PhoneDSHHost(configuration: try fixture.configuration(),
                     engineFactory: { _ in MockEngine(worker: worker) })
    }

    func testVFSRefusedIsADiagnosticAndTheHostStaysRunning() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let worker = MockWorker()
        let host = try makeHost(fixture, worker: worker)
        try await host.start()
        let collector = EventCollector(host.eventStream())
        defer { collector.stop() }
        try await worker.waitForOpenFrames()

        let refusal = ErrorPayload(path: "/dsh/workspace/big.bin",
                                   limit: 15 * 1024 * 1024,
                                   reason: .fileTooLarge,
                                   message: "EFBIG: VFS refused /dsh/workspace/big.bin")
        try await worker.sendError(refusal)

        // Diagnostics, not a connection error: the count and the record.
        try await waitUntil {
            await host.diagnostics().vfsRefusals == 1
        }
        let diagnostics = await host.diagnostics()
        XCTAssertEqual(diagnostics.vfsRefusals, 1)
        XCTAssertEqual(diagnostics.lastVFSRefusal?.path, "/dsh/workspace/big.bin")
        XCTAssertEqual(diagnostics.lastVFSRefusal?.limit, 15 * 1024 * 1024)
        XCTAssertEqual(diagnostics.lastVFSRefusal?.reason, .fileTooLarge)
        XCTAssertNil(diagnostics.lastError, "a resource refusal is not a fail-loud error")

        let state = await host.state
        XCTAssertEqual(state, .running, "VFS_REFUSED never enters Failed")
        XCTAssertNotEqual(diagnostics.state, .failed)
        XCTAssertEqual(diagnostics.hostState, .running,
                       "the controller is not failed by a resource refusal")

        // The connection is still open: a later CONSOLE frame is dispatched.
        try await worker.sendConsole("pdsh-vfs: EFBIG still connected", level: .error)
        try await waitUntil {
            collector.events.contains {
                if case .console(let payload) = $0 {
                    return payload.text == "pdsh-vfs: EFBIG still connected"
                }
                return false
            }
        }
        // ... and it never surfaced as the fail-loud event.
        XCTAssertFalse(collector.events.contains {
            if case .error = $0 { return true }
            return false
        }, "VFS_REFUSED must not publish PhoneDSHEvent.error")
        let stateAfter = await host.state
        XCTAssertEqual(stateAfter, .running)
        try await host.stop()
    }

    func testProtocolErrorStillPublishesFailLoudEvent() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let worker = MockWorker()
        let host = try makeHost(fixture, worker: worker)
        try await host.start()
        let collector = EventCollector(host.eventStream())
        defer { collector.stop() }
        try await worker.waitForOpenFrames()

        try await worker.sendError(ErrorPayload(code: .badPayload,
                                                message: "malformed payload"))
        try await waitUntil {
            collector.events.contains {
                if case .error(let message) = $0 { return message.contains("BAD_PAYLOAD") }
                return false
            }
        }
        let diagnostics = await host.diagnostics()
        XCTAssertEqual(diagnostics.vfsRefusals, 0)
        XCTAssertNil(diagnostics.lastVFSRefusal)
        try await host.stop()
    }
}
