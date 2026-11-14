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

    /// Drag the AssistiveTouch button with the board's pointer, as a user would with a finger;
    /// the next task's `prepare()` must notice, invalidate the route and learn it again with the
    /// button in its new place. Then the button is dragged back and learned again, so the phone is
    /// left as it was.
    func testDraggedAssistiveButtonIsFoundAtTheNextTask() async throws {
        try requireFixture()
        let host = IPhoneAgentHost.shared
        host.screen.start()
        let mirroring = await host.hands.mirrorActive()
        try XCTSkipUnless(mirroring, "start the mirror to the board once by hand first")
        try await host.hands.ensureHID()
        try await Task.sleep(for: .milliseconds(800))
        if !host.hands.layout.mirrorRouteUsable || host.hands.layout.mirrorRouteNeedsLearning() {
            note("learning first: \(try await host.learnMirrorRoute())")
        }
        let original = host.hands.layout.assistiveButton
        let originalLearnedAt = try XCTUnwrap(host.hands.layout.mirrorRouteLearnedAt)
        // The other side of the screen, a little higher.
        let target = TonoLinkPoint(original.x > 500 ? 80 : 920, min(max(original.y - 250, 300), 700))

        func drag(_ from: TonoLinkPoint, _ to: TonoLinkPoint) async throws -> TonoLinkPoint? {
            try await host.hands.swipe(from: from, to: to, ms: 1200)
            try await Task.sleep(for: .seconds(2))   // the button settles against the nearest edge
            return try await host.locate(IPhoneAgentHost.assistiveButton, waitForChange: false)
        }

        guard let moved = try await drag(original, target), IPhoneAgentHost.far(moved, original) else {
            await shot(host, "drag-did-not-move")
            throw XCTSkip("the pointer drag did not move the AssistiveTouch button on this phone")
        }
        note("button dragged \(original) -> \(moved)")
        await shot(host, "1-dragged")

        let started = ContinuousClock.now
        try await host.prepare()
        let afterMove = TonoLinkPhoneLayout.load()
        note("prepare() after the drag took \(ContinuousClock.now - started): \(afterMove)")
        XCTAssertFalse(IPhoneAgentHost.far(afterMove.assistiveButton, moved), "the moved button was not noticed")
        XCTAssertTrue(afterMove.mirrorRouteUsable, "the route was not learned again")
        XCTAssertGreaterThan(afterMove.mirrorRouteLearnedAt ?? .distantPast, originalLearnedAt, "the route was not re-learned")
        let stillMirroring = await host.hands.mirrorActive()
        XCTAssertTrue(stillMirroring)

        // Put the button back where the user had it (pushed against the same edge, where it snaps),
        // and let the next task learn that again.
        let home = TonoLinkPoint(original.x > 500 ? 995 : 5, original.y)
        if let back = try await drag(afterMove.assistiveButton, home) { note("button dragged back to \(back)") }
        host.resetButtonCheckForTesting()
        try await host.prepare()
        let restored = TonoLinkPhoneLayout.load()
        note("after dragging back: \(restored)")
        XCTAssertFalse(IPhoneAgentHost.far(restored.assistiveButton, original), "the button is not back where it was")
        XCTAssertTrue(restored.mirrorRouteUsable)
        try? await host.hands.disableHID()
    }

    /// Puts the AssistiveTouch button at `TEST_RUNNER_PDSH_BUTTON_AT=x,y` (pushed to that edge) and
    /// lets `prepare()` learn the route again. Used to restore a phone after a drag test.
    func testPutAssistiveButtonBack() async throws {
        try requireFixture()
        let env = ProcessInfo.processInfo.environment
        let parts = (env["TEST_RUNNER_PDSH_BUTTON_AT"] ?? env["PDSH_BUTTON_AT"] ?? "").split(separator: ",").compactMap { Double($0) }
        try XCTSkipUnless(parts.count == 2, "pass TEST_RUNNER_PDSH_BUTTON_AT=x,y")
        let host = IPhoneAgentHost.shared
        host.screen.start()
        let mirroring = await host.hands.mirrorActive()
        try XCTSkipUnless(mirroring, "needs the mirror to see the button")
        try await host.hands.ensureHID()
        try await Task.sleep(for: .milliseconds(800))
        let target = TonoLinkPoint(parts[0], parts[1])
        // A long pointer drag does not land where it was aimed; correct by the measured miss.
        var aim = TonoLinkPoint(target.x > 500 ? 995 : 5, target.y)
        for attempt in 1...4 {
            let located = try await host.locate(IPhoneAgentHost.assistiveButton, waitForChange: false)
            let current = try XCTUnwrap(located)
            if abs(current.y - target.y) <= 30 && abs(current.x - target.x) <= 60 { note("button back at \(current)"); break }
            try await host.hands.swipe(from: current, to: aim, ms: 1200)
            try await Task.sleep(for: .seconds(2))
            let after = try await host.locate(IPhoneAgentHost.assistiveButton, waitForChange: false)
            note("attempt \(attempt): \(current) -> \(String(describing: after)) aiming \(aim), wanted \(target)")
            if let after { aim = TonoLinkPoint(aim.x, min(max(aim.y + (target.y - after.y), 60), 990)) }
        }
        await shot(host, "button-back")
        host.resetButtonCheckForTesting()
        try await host.prepare()
        note("layout now \(TonoLinkPhoneLayout.load())")
        try? await host.hands.disableHID()
    }

    // MARK: - Mirror down, app in front

    /// One console line to the board over USB (`POST /cmd`, the board's own console).
    private func boardConsole(_ line: String) async throws {
        var request = URLRequest(url: TonoLinkUSB.baseURL.appendingPathComponent("cmd"), timeoutInterval: 8)
        request.httpMethod = "POST"
        request.httpBody = Data(line.utf8)
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, "board console \(line)")
    }

    /// Ends the mirror from the board's side (its receiver goes off and on again), the way a cable
    /// or receiver drop does: the phone stays in this app.
    private func dropMirrorFromBoard(_ host: IPhoneAgentHost) async throws {
        try await boardConsole("airplay off")
        var stopped = false
        for _ in 0..<20 where !stopped {
            try await Task.sleep(for: .milliseconds(500))
            stopped = !(await host.hands.mirrorActive())
        }
        XCTAssertTrue(stopped, "airplay off did not end the mirror")
        try await boardConsole("airplay on")
        try await Task.sleep(for: .seconds(3))   // the receiver advertises again
    }

    /// Mirror on, route learned and fresh, app in front.
    private func mirroringWithLearnedRoute(_ host: IPhoneAgentHost) async throws {
        host.screen.start()
        let mirroring = await host.hands.mirrorActive()
        try XCTSkipUnless(mirroring, "start the mirror to the board once by hand first")
        try XCTSkipUnless(TonoLinkTapProbe.available, "this app is not in front")
        try await host.hands.ensureHID()
        try await Task.sleep(for: .milliseconds(800))
        if !host.hands.layout.mirrorRouteUsable || host.hands.layout.mirrorRouteNeedsLearning() {
            note("learning first: \(try await host.learnMirrorRoute())")
            try XCTSkipUnless(TonoLinkTapProbe.available, "learning left this app (Control Center closed to Home)")
        }
    }

    /// Taps `point` over the catching window: true when AssistiveTouch took the press (its menu is
    /// then open and is closed again by a press outside it).
    private func buttonAt(_ host: IPhoneAgentHost, _ point: TonoLinkPoint) async throws -> Bool {
        let probe = TonoLinkTapProbe()
        // Without the window every press would look like "AssistiveTouch took it".
        guard probe.show() else { throw XCTSkip("this app is no longer in front; the probe cannot run") }
        defer { probe.hide() }
        try await Task.sleep(for: .milliseconds(300))
        try await host.hands.tap(point)
        try await Task.sleep(for: .milliseconds(900))
        guard probe.touches.isEmpty else { return false }
        probe.reset()
        try await host.hands.tap(TonoLinkPoint(500, 120))   // outside the menu: closes it
        try await Task.sleep(for: .milliseconds(700))
        return true
    }

    /// Walks the probe along one screen edge: where the button rests after a drag. Starts below
    /// y 260: on this iPhone the status bar is a column on the right edge (about y 90–220), and a
    /// press there goes to the system, which the probe would read as "AssistiveTouch took it".
    private func findButton(_ host: IPhoneAgentHost, edgeX: Double) async throws -> TonoLinkPoint? {
        for y in stride(from: 260.0, through: 950.0, by: 40.0) {
            let point = TonoLinkPoint(edgeX, y)
            if try await buttonAt(host, point) { return point }
        }
        return nil
    }

    /// Locates the button on either edge with the probe alone.
    private func findButtonOnEitherEdge(_ host: IPhoneAgentHost) async throws -> TonoLinkPoint? {
        if let right = try await findButton(host, edgeX: 916) { return right }
        return try await findButton(host, edgeX: 88)
    }

    /// Drags in hops of at most 250 (0–1000): the board takes at most 64 steps per batch, and a
    /// long relative move needs more. The button stays where each hop releases it.
    private func dragButton(_ host: IPhoneAgentHost, from: TonoLinkPoint, to: TonoLinkPoint) async throws {
        let distance = max(abs(to.x - from.x), abs(to.y - from.y))
        let hops = max(1, Int((distance / 250).rounded(.up)))
        var start = from
        for hop in 1...hops {
            let f = Double(hop) / Double(hops)
            let end = TonoLinkPoint(from.x + (to.x - from.x) * f, from.y + (to.y - from.y) * f)
            try await host.hands.swipe(from: start, to: end, ms: 700)
            try await Task.sleep(for: .milliseconds(900))
            start = end
        }
        try await Task.sleep(for: .seconds(1.5))
    }

    /// Puts the button back at `original` with the screen dark: find it, drag it toward the same
    /// edge at a corrected height, find it again. Long drags land imprecisely, so up to 6 rounds.
    @discardableResult
    private func restoreButtonBlind(_ host: IPhoneAgentHost, to original: TonoLinkPoint) async throws -> TonoLinkPoint? {
        var found = try await findButtonOnEitherEdge(host)
        note("restore: button found at \(String(describing: found))")
        var aimY = original.y
        for attempt in 1...6 {
            guard let from = found else { return nil }
            if abs(from.x - original.x) < 100 && abs(from.y - original.y) <= 40 { return from }
            try await dragButton(host, from: from, to: TonoLinkPoint(original.x > 500 ? 995 : 5, aimY))
            found = try await findButtonOnEitherEdge(host)
            note("restore attempt \(attempt): now \(String(describing: found)), aimed y \(aimY)")
            if let found, abs(found.x - original.x) < 100 { aimY = min(max(aimY + (original.y - found.y), 60), 990) }
        }
        return found
    }

    /// One hop-split drag `TEST_RUNNER_PDSH_DRAG=fx,fy,tx,ty`, for restoring a phone step by step
    /// while watching it with `devicectl device capture screenshot`.
    func testDragOnce() async throws {
        try requireFixture()
        let parts = (ProcessInfo.processInfo.environment["TEST_RUNNER_PDSH_DRAG"] ?? ProcessInfo.processInfo.environment["PDSH_DRAG"] ?? "").split(separator: ",").compactMap { Double($0) }
        try XCTSkipUnless(parts.count == 4, "pass TEST_RUNNER_PDSH_DRAG=fx,fy,tx,ty")
        let host = IPhoneAgentHost.shared
        try await host.hands.ensureHID()
        try await Task.sleep(for: .milliseconds(800))
        try await dragButton(host, from: TonoLinkPoint(parts[0], parts[1]), to: TonoLinkPoint(parts[2], parts[3]))
        try? await host.hands.disableHID()
    }

    /// Puts the phone back after a failed drag test: button at `TEST_RUNNER_PDSH_BUTTON_AT`
    /// (default 917,815) with the screen dark, the saved route re-marked, mirror restarted.
    func testRestoreButtonAndMirrorBlind() async throws {
        try requireFixture()
        let host = IPhoneAgentHost.shared
        host.screen.start()
        try XCTSkipUnless(TonoLinkTapProbe.available, "this app is not in front")
        let env = ProcessInfo.processInfo.environment
        let parts = (env["TEST_RUNNER_PDSH_BUTTON_AT"] ?? env["PDSH_BUTTON_AT"] ?? "917,815").split(separator: ",").compactMap { Double($0) }
        let original = TonoLinkPoint(parts[0], parts[1])
        try await host.hands.ensureHID()
        try await Task.sleep(for: .milliseconds(800))
        let restored = try await restoreButtonBlind(host, to: original)
        note("button now \(String(describing: restored))")
        let back = try await buttonAt(host, original)
        XCTAssertTrue(back, "the button is not back at \(original)")
        guard back else { return }
        var layout = host.hands.layout
        layout.assistiveButton = original
        layout.markMirrorRouteLearned()
        host.hands.layout = layout
        layout.save()
        let mirroring = await host.hands.mirrorActive()
        if !mirroring { try await host.prepare() }
        let after = await host.hands.mirrorActive()
        XCTAssertTrue(after, "the mirror did not come back")
        try? await host.hands.disableHID()
    }

    /// Happy path: the mirror drops while this app is in front; the next `prepare()` checks the
    /// button with one press over the catching window and restarts the mirror from the open menu.
    func testRestartChecksTheButtonWhenTheAppIsInFront() async throws {
        try requireFixture()
        let host = IPhoneAgentHost.shared
        try await mirroringWithLearnedRoute(host)
        try await dropMirrorFromBoard(host)
        XCTAssertTrue(TonoLinkTapProbe.available, "the app must still be in front after the drop")
        let mark = host.screen.frameCount
        let started = ContinuousClock.now
        try await host.prepare()
        note("restarted through the probe path in \(ContinuousClock.now - started)")
        let restored = await host.hands.mirrorActive()
        XCTAssertTrue(restored)
        let fresh = try? await host.screen.snapshot(newerThan: mark, fresh: 2, timeout: .seconds(5))
        XCTAssertNotNil(fresh, "no new picture after the restart")
        if let fresh { attach(fresh.jpeg, "restarted") }
        try? await host.hands.disableHID()
    }

    /// The button is dragged while the mirror is down: the next `prepare()` must find out with its
    /// first press, invalidate the route and stop without opening Control Center. The phone is then
    /// put back: the button dragged home (located by the probe, no screen), the route re-marked,
    /// and `prepare()` restarts the mirror.
    func testButtonDraggedWhileTheMirrorIsDownIsCaught() async throws {
        try requireFixture()
        let host = IPhoneAgentHost.shared
        try await mirroringWithLearnedRoute(host)
        let original = host.hands.layout.assistiveButton
        let saved = host.hands.layout
        try await dropMirrorFromBoard(host)

        // Drag it away with the screen dark.
        try await host.hands.swipe(from: original, to: TonoLinkPoint(original.x > 500 ? 5 : 995, min(max(original.y - 250, 300), 700)), ms: 1200)
        try await Task.sleep(for: .seconds(2))
        let stillThere = try await buttonAt(host, original)
        try XCTSkipIf(stillThere, "the pointer drag did not move the button")

        var caught: Error?
        do { try await host.prepare() } catch { caught = error }
        note("prepare() after the drag: \(String(describing: caught))")
        XCTAssertTrue("\(caught.map { "\($0)" } ?? "")".contains("小圆点"), "the moved button was not reported")
        XCTAssertFalse(TonoLinkPhoneLayout.load().mirrorRouteUsable, "the route was not invalidated")
        let mirroringAfterCatch = await host.hands.mirrorActive()
        XCTAssertFalse(mirroringAfterCatch, "nothing may have been started blind")
        XCTAssertTrue(TonoLinkTapProbe.available, "the check must not leave this app (no Control Center)")

        // Put the button back where it was, located by the probe alone.
        try await restoreButtonBlind(host, to: original)
        let back = try await buttonAt(host, original)
        XCTAssertTrue(back, "the button is not back at \(original)")
        var layout = saved
        layout.markMirrorRouteLearned()
        host.hands.layout = layout
        layout.save()
        try await host.prepare()
        let mirroringAgain = await host.hands.mirrorActive()
        XCTAssertTrue(mirroringAgain, "the mirror did not come back after the button was put back")
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
