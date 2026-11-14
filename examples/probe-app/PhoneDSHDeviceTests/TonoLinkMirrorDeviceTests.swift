// SPDX-License-Identifier: MIT
// Physical-device checks for starting the AirPlay mirror to the TonoLink board without the user.
// Hosted in the app, so they drive the app's own `IPhoneAgentHost` (board HID over USB, the
// board's AirPlay stream, and UI-Venus from the app's settings). Needs a phone plugged into a
// board, AssistiveTouch on, and `TEST_RUNNER_PDSH_TONOLINK_MIRROR_TEST=1`.
import UIKit
import XCTest
@testable import PhoneDSHBLE
@testable import PhoneDSHProbe

@MainActor
final class TonoLinkMirrorDeviceTests: XCTestCase {
    private func requireFixture() throws {
        let environment = ProcessInfo.processInfo.environment
        guard (environment["TEST_RUNNER_PDSH_TONOLINK_MIRROR_TEST"] ?? environment["PDSH_TONOLINK_MIRROR_TEST"]) == "1" else {
            throw XCTSkip("pass TEST_RUNNER_PDSH_TONOLINK_MIRROR_TEST=1 with a phone plugged into a TonoLink board")
        }
    }

    private func note(_ line: String) { print("PDSH-MIRROR \(line)") }

    private func attach(_ jpeg: Data, _ name: String) {
        guard let image = UIImage(data: jpeg) else { return }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Read-only: what the board and the stream say right now. No tap is sent.
    func testProbeState() async throws {
        try requireFixture()
        let host = IPhoneAgentHost.shared
        host.screen.start()
        let status = try? await host.hands.call("GET", "/v1/phone/status", timeout: 5)
        note("status=\(status.map { "\($0)" } ?? "unreachable")")
        note("mirror_active=\(await host.hands.mirrorActive()) layout=\(host.hands.layout)")

        let deadline = ContinuousClock.now + .seconds(6)
        while ContinuousClock.now < deadline {
            if let shot = try? await host.screen.snapshot() {
                note("frame \(shot.width)x\(shot.height) #\(shot.frame)")
                attach(shot.jpeg, "probe-screen")
                return
            }
            try await Task.sleep(for: .milliseconds(300))
        }
        note("no frame: \(host.screen.currentStats.status)")
    }

    /// The product path on its own: nothing is mirroring and the route is learned; the next task's
    /// `prepare()` brings the mirror back with no one at the phone.
    func testPrepareRestartsADroppedMirror() async throws {
        try requireFixture()
        let host = IPhoneAgentHost.shared
        host.screen.start()
        let boardBefore = await host.hands.mirrorActive()
        try XCTSkipIf(boardBefore, "already mirroring; end it first")
        try XCTSkipUnless(host.hands.layout.mirrorRouteLearned == true, "route not learned on this phone")
        note("layout=\(host.hands.layout)")
        let mark = host.screen.frameCount
        let started = ContinuousClock.now
        try await host.prepare()
        note("prepare restarted the mirror in \(ContinuousClock.now - started)")
        let boardAfter = await host.hands.mirrorActive()
        XCTAssertTrue(boardAfter)
        let fresh = try? await host.screen.snapshot(newerThan: mark, fresh: 2, timeout: .seconds(5))
        XCTAssertNotNil(fresh, "no new picture after the restart")
        if let fresh { attach(fresh.jpeg, "restarted") }
        try? await host.hands.disableHID()
    }

    /// Re-learning, on the product path only: the route is invalidated (as a missed restart does),
    /// the next `prepare()` with the mirror on learns it again from the screen, then a dropped
    /// mirror is restarted by the next `prepare()` with the re-learned route.
    func testPrepareRelearnsAnInvalidatedRouteThenRestarts() async throws {
        try requireFixture()
        let host = IPhoneAgentHost.shared
        host.screen.start()
        let mirroring = await host.hands.mirrorActive()
        try XCTSkipUnless(mirroring, "start the mirror to the board once by hand first")

        host.hands.layout.markMirrorRouteLearned()
        host.invalidateMirrorRoute("device test")
        XCTAssertFalse(TonoLinkPhoneLayout.load().mirrorRouteUsable, "the invalidation was not saved")

        let learnStarted = Date()
        try await host.prepare()
        let learned = TonoLinkPhoneLayout.load()
        note("relearned in \(Date().timeIntervalSince(learnStarted)) s: \(learned)")
        XCTAssertTrue(learned.mirrorRouteUsable, "prepare() did not learn the route again")
        XCTAssertFalse(learned.mirrorRouteNeedsLearning())
        XCTAssertGreaterThanOrEqual(learned.mirrorRouteLearnedAt ?? .distantPast, learnStarted)
        let stillMirroring = await host.hands.mirrorActive()
        XCTAssertTrue(stillMirroring, "learning must leave the mirror running")

        // Drop the mirror along the re-learned route.
        try await host.hands.home(); try await Task.sleep(for: .milliseconds(1500))
        try await host.hands.openMirrorList()
        try await host.hands.tap(try XCTUnwrap(learned.mirrorStop))
        var stopped = false
        for _ in 0..<20 where !stopped {
            try await Task.sleep(for: .milliseconds(500))
            stopped = !(await host.hands.mirrorActive())
        }
        XCTAssertTrue(stopped, "停止镜像 on the re-learned route did not end the mirror")
        try? await host.hands.key("esc")
        try await Task.sleep(for: .seconds(2))

        let mark = host.screen.frameCount
        let restartStarted = ContinuousClock.now
        try await host.prepare()
        note("restarted in \(ContinuousClock.now - restartStarted)")
        let restored = await host.hands.mirrorActive()
        XCTAssertTrue(restored)
        let fresh = try? await host.screen.snapshot(newerThan: mark, fresh: 2, timeout: .seconds(5))
        XCTAssertNotNil(fresh, "no new picture after the restart")
        if let fresh { attach(fresh.jpeg, "restarted") }
        try? await host.hands.disableHID()
    }

    private func shot(_ host: IPhoneAgentHost, _ name: String) async {
        if let frame = try? await host.screen.snapshot() { attach(frame.jpeg, name) }
    }

    /// The whole user story on a real phone: learn the route once from the visible screen, end the
    /// mirror, then let the agent's own `prepare()` bring it back without anyone touching the phone.
    func testLearnRouteThenRestartMirrorUnattended() async throws {
        try requireFixture()
        let host = IPhoneAgentHost.shared
        host.screen.start()
        try await host.hands.ensureHID()
        var visible = false
        for _ in 0..<20 where !visible {
            visible = (try? await host.screen.snapshot()) != nil
            if !visible { try await Task.sleep(for: .milliseconds(300)) }
        }
        try XCTSkipUnless(visible, "the phone is not mirroring to the board; start it once by hand first")
        await shot(host, "1-before")
        // The wrong-receiver guard rests on iOS reporting the mirror as a second screen.

        // 1. Learn.
        let learned: String
        do { learned = try await host.learnMirrorRoute() } catch {
            for (index, step) in host.learnTrace.enumerated() { note("learn step \(index): \(step.name)"); attach(step.jpeg, "learn-\(index)") }
            await shot(host, "learn-failed-now")
            note("after failure mirror_active=\(await host.hands.mirrorActive())")
            throw error
        }
        for (index, step) in host.learnTrace.enumerated() { note("learn step \(index): \(step.name)"); attach(step.jpeg, "learn-\(index)") }
        note("learned: \(learned)")
        note("layout=\(host.hands.layout)")
        XCTAssertEqual(TonoLinkPhoneLayout.load().mirrorRouteLearned, true, "the learned route was not saved")
        try await Task.sleep(for: .seconds(2))
        await shot(host, "2-after-learning")
        let stillMirroring = await host.hands.mirrorActive()
        XCTAssertTrue(stillMirroring, "learning must leave the mirror running")

        // 2. End the mirror the way a user would, along the learned route: 屏幕镜像 → 停止镜像.
        let layout = host.hands.layout
        let stop = try XCTUnwrap(layout.mirrorStop)
        try await host.hands.home(); try await Task.sleep(for: .milliseconds(1500))
        try await host.hands.openMirrorList()
        await shot(host, "3-device-list")
        try await host.hands.tap(stop)
        var stopped = false
        for _ in 0..<20 where !stopped {
            try await Task.sleep(for: .milliseconds(500))
            let boardActive = await host.hands.mirrorActive()
            stopped = !boardActive
        }
        note("mirror stopped=\(stopped)")
        XCTAssertTrue(stopped, "停止镜像 did not end the mirror")
        try? await host.hands.key("esc")
        try await Task.sleep(for: .seconds(2))

        // 3. Nobody touches the phone: the next task's preparation restarts the mirror blind.
        let started = ContinuousClock.now
        do {
            try await host.prepare()
        } catch {
            note("prepare failed: \(error)")
            return XCTFail("the mirror did not come back by itself: \(error)")
        }
        note("restarted in \(ContinuousClock.now - started), row=\(host.hands.layout.mirrorTarget)")
        await shot(host, "4-restarted")
        let restored = await host.hands.mirrorActive()
        XCTAssertTrue(restored)
        _ = try? await host.home()
        try? await host.hands.disableHID()
    }
}
