// SPDX-License-Identifier: MIT
// App-side listener-recovery wiring: every path that can continue a Worker
// asks the listener to heal first. The fake stands in for the production Bot
// composition so the suite can observe the three call sites without a Worker.

import XCTest
import PhoneDSHBot

@MainActor
private final class FakeBotMCPListener: BotMCPListenerEnsuring {
    var url: URL?
    private(set) var ensureCount = 0
    private var results: [BotMCPListenerRecovery] = []

    init(url: URL) {
        self.url = url
    }

    func queue(_ result: BotMCPListenerRecovery) {
        results.append(result)
    }

    func ensureListening() async -> BotMCPListenerRecovery {
        ensureCount += 1
        let result: BotMCPListenerRecovery
        if results.isEmpty, let url {
            result = .listening(url)
        } else if results.isEmpty {
            result = .unavailable("fake has no endpoint")
        } else {
            result = results.removeFirst()
        }
        if let recovered = result.url {
            url = recovered
        }
        return result
    }
}

@MainActor
final class BotMCPListenerSupervisorTests: XCTestCase {
    private let original = URL(string: "http://127.0.0.1:41000/mcp")!
    private let moved = URL(string: "http://127.0.0.1:41001/mcp")!

    func testForegroundResumeAndEngineStartEachHealTheListener() async {
        let fake = FakeBotMCPListener(url: original)
        let supervisor = BotMCPListenerSupervisor(listener: fake)

        _ = await supervisor.foregroundBecameActive()
        _ = await supervisor.willResumeHost()
        _ = await supervisor.willStartEngine()

        XCTAssertEqual(fake.ensureCount, 3)
        XCTAssertEqual(supervisor.triggers, [.foreground, .resume, .engineStart])
        XCTAssertEqual(supervisor.endpoint, original)
    }

    func testSamePortRebindKeepsTheRunningHostUsable() async {
        let fake = FakeBotMCPListener(url: original)
        let supervisor = BotMCPListenerSupervisor(listener: fake)
        supervisor.recordHostBuild()

        fake.queue(.rebound(original))
        _ = await supervisor.willResumeHost()

        XCTAssertEqual(supervisor.endpoint, original)
        XCTAssertTrue(supervisor.hostEndpointIsCurrent,
                      "a same-port rebind leaves the URL handed to the Worker valid")
    }

    func testNewPortMarksTheCapturedWorkerURLStale() async {
        let fake = FakeBotMCPListener(url: original)
        let supervisor = BotMCPListenerSupervisor(listener: fake)
        supervisor.recordHostBuild()

        fake.queue(.rebound(moved))
        _ = await supervisor.foregroundBecameActive()

        XCTAssertEqual(supervisor.endpoint, moved)
        XCTAssertFalse(supervisor.hostEndpointIsCurrent,
                       "a new port requires rebuilding the Host that captured the old URL")
    }

    func testUnavailableKeepsTheLastKnownEndpointSoARebuildIsNotFaked() async {
        let fake = FakeBotMCPListener(url: original)
        let supervisor = BotMCPListenerSupervisor(listener: fake)
        supervisor.recordHostBuild()

        fake.queue(.unavailable("both ports failed"))
        let result = await supervisor.willResumeHost()

        guard case .unavailable = result else {
            return XCTFail("expected unavailable, got \(result)")
        }
        XCTAssertEqual(supervisor.endpoint, original)
    }
}
