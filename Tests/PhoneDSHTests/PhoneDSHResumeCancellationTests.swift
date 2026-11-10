// SPDX-License-Identifier: MIT
// A resume that is overtaken by a background transition must release its gate
// and leave the controller ready for the next foreground resume.

import Foundation
import XCTest
@testable import PhoneDSH
import PhoneDSHEngine

final class PhoneDSHResumeCancellationTests: XCTestCase {
    private func makeHost(_ fixture: FacadeFixture, engine: MockEngine,
                          configuration: PhoneDSHConfiguration) -> PhoneDSHHost {
        PhoneDSHHost(configuration: configuration, engineFactory: { _ in engine })
    }

    func testBackgroundCancelsResumeReleasesGateAndNextResumeSucceeds() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let engine = MockEngine(worker: MockWorker())
        var configuration = try fixture.configuration(helloTimeout: 10)
        configuration.resumeBootReadyTimeout = 1
        configuration.resumeHelloTimeout = 5
        configuration.resumeVisibilityTimeout = 0
        let host = makeHost(fixture, engine: engine, configuration: configuration)
        try await host.start()
        try await host.park()

        engine.setBootHangs(true)
        let started = Date()
        let resume = Task { try await host.resume() }
        try await waitUntil(timeout: 5) { engine.bootCount >= 2 }

        await host.setForeground(false)
        do {
            try await resume.value
            XCTFail("a background transition must cancel the resume")
        } catch let error as PhoneDSHError {
            XCTAssertEqual(error, .resumeCancelled)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2,
                          "the background must abort the boot before its wall-clock budget")
        let cancelledState = await host.state
        XCTAssertEqual(cancelledState, .stopped,
                       "the cancelled resume must release its exclusive gate")

        engine.setBootHangs(false)
        await host.setForeground(true)
        try await host.resume()
        let resumedState = await host.state
        XCTAssertEqual(resumedState, .running,
                       "the next foreground resume continues the interrupted boot")
        try await host.stop()
    }

    func testEachWorkerBootGetsAFreshD6BootID() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let engine = MockEngine(worker: MockWorker())
        var configuration = try fixture.configuration(helloTimeout: 10)
        configuration.resumeBootReadyTimeout = 5
        configuration.resumeHelloTimeout = 5
        configuration.resumeVisibilityTimeout = 0
        let host = makeHost(fixture, engine: engine, configuration: configuration)
        try await host.start()
        let first = try XCTUnwrap(engine.lastConfiguration?.bootID)
        try await host.park()
        try await host.resume()
        let second = try XCTUnwrap(engine.lastConfiguration?.bootID)
        XCTAssertNotEqual(first, second,
                          "a resumed Worker is a new process and needs a fresh boot_id")
        XCTAssertEqual(second.count, 32)
        try await host.stop()
    }
}
