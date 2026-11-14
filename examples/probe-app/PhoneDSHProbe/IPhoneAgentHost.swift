// SPDX-License-Identifier: MIT
// Runs UI-Venus phone tasks on this iPhone with no computer: the board's AirPlay stream
// (`TonoLinkScreen`, decoded here) is the screen, the board's BLE HID (`TonoLinkPhoneHands`, driven
// over USB) is the finger, and the OpenAI-compatible service in UI-Venus settings is the model.
// Device voice reaches it as a tool call inside the device's fixed DSH session.

import Foundation
import OSLog
import PhoneDSHBLE
import PhoneDSHLoopback
import PhoneDSHVenus

/// The app's one native MCP endpoint: `iphone_agent_run` in front of the BLE tools (which fall
/// through to ADB). Both the Worker's direct `/mcp/native` and the Bot listener's forwarder use this
/// same instance, so one receipt store and one in-flight task guard serve every caller.
@MainActor enum PhoneNativeMCP {
    #if DEBUG
    /// DEBUG builds record what reaches the native tools (`GET /debug/native-mcp`).
    static let server: any NativeMCPServing = NativeMCPDebugRecorder(IPhoneAgentMCPServer(
        fallback: DeviceMCPServer.shared, executor: IPhoneAgentHost.shared))
    #else
    static let server: any NativeMCPServing = IPhoneAgentMCPServer(
        fallback: DeviceMCPServer.shared, executor: IPhoneAgentHost.shared)
    #endif
}

#if DEBUG
/// DEBUG-only: keeps the last 20 native MCP requests (method, tool, whether the journal key
/// header arrived, arguments) so a developer can see what the Worker actually sent.
final class NativeMCPDebugRecorder: NativeMCPServing, @unchecked Sendable {
    static weak var current: NativeMCPDebugRecorder?
    private let inner: any NativeMCPServing
    private let lock = NSLock()
    private var entries: [[String: Any]] = []
    init(_ inner: any NativeMCPServing) { self.inner = inner; Self.current = self }

    func handle(_ request: LoopbackRequest) async -> NativeMCPResponse {
        let message = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
        let params = message?["params"] as? [String: Any]
        let args = params?["arguments"].flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
        var entry: [String: Any] = [
            "at": ISO8601DateFormatter().string(from: Date()), "method": message?["method"] as? String ?? "?",
            "tool": params?["name"] as? String ?? "",
            "has_key": request.headers.contains { $0.key.lowercased() == "x-pdsh-idempotency-key" && !$0.value.isEmpty },
            "headers": request.headers.keys.map { $0.lowercased() }.sorted(),
            // Not secret; shows whether the Worker's client accepts the long-call SSE answer.
            "accept": request.headers.first { $0.key.lowercased() == "accept" }?.value ?? "",
            "arguments": args.map { String(decoding: $0.prefix(300), as: UTF8.self) } ?? "",
        ]
        let response = await inner.handle(request)
        entry["status"] = response.status
        entry["result"] = String(decoding: response.body.prefix(400), as: UTF8.self)
        lock.withLock { entries.append(entry); if entries.count > 20 { entries.removeFirst() } }
        return response
    }
    func cancelPendingOperations() async { await inner.cancelPendingOperations() }
    func snapshot() -> [[String: Any]] { lock.withLock { entries } }
}
#endif

@MainActor final class IPhoneAgentHost: IPhoneAgentDevice, IPhoneAgentTaskExecuting {
    static let shared = IPhoneAgentHost()
    let screen = TonoLinkScreen.shared
    let hands = TonoLinkPhoneHands()
    private(set) var running: String?
    private(set) var lastResult: [String: Any] = [:]
    private let logger = Logger(subsystem: "dev.phone-dsh.voice", category: "iphone-agent")

    /// English names find apps in Spotlight without the pasteboard.
    static let appQuery = ["设置": "Settings", "电话": "Phone", "信息": "Messages", "相机": "Camera", "照片": "Photos",
                           "时钟": "Clock", "天气": "Weather", "地图": "Maps", "备忘录": "Notes", "日历": "Calendar",
                           "计算器": "Calculator", "提醒事项": "Reminders", "音乐": "Music", "邮件": "Mail",
                           "微信": "WeChat", "支付宝": "Alipay", "哔哩哔哩": "bilibili", "B站": "bilibili",
                           "京东": "JD", "高德地图": "Amap", "百度地图": "Baidu Maps", "网易云音乐": "NetEase Cloud Music"]

    /// Spotlight query for an app: its English name when known, else pinyin for Chinese names
    /// (Spotlight matches "xiaohongshu" to 小红书) — the board's keyboard types ASCII only.
    static func searchQuery(for app: String) -> String {
        if let english = appQuery[app] { return english }
        guard !app.allSatisfy(\.isASCII) else { return app }
        let latin = app.applyingTransform(.mandarinToLatin, reverse: false)?.applyingTransform(.stripDiacritics, reverse: false) ?? app
        let ascii = String(latin.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) })
        return ascii.isEmpty ? app : ascii
    }

    /// Keeps the viewer connected from launch: iOS sends a keyframe only when mirroring starts.
    func start() { screen.start() }

    func run(_ task: String) async throws -> IPhoneAgentResult {
        guard running == nil else { throw IPhoneAgentError("上一个手机任务还在执行") }
        running = task
        defer { running = nil }
        let folder = Self.runFolder()
        let agent = IPhoneAgent(device: self)
        agent.onStep = { [logger] step in
            logger.info("step \(step.index, privacy: .public) \(step.action, privacy: .public) → \(step.executed, privacy: .public)")
            try? step.screenshot.write(to: folder.appendingPathComponent(String(format: "step%02d.jpg", step.index)))
            Self.append("[\(step.index)] \(String(format: "%.1f", step.modelSeconds))s \(step.action) → \(step.executed)", to: folder)
        }
        Self.append("task: \(task)", to: folder)
        do {
            let result = try await agent.run(task)
            do { try await hands.disableHID() }
            catch { Self.append("hid detach failed: \(error.localizedDescription)", to: folder) }
            Self.append("result: \(result.answer) finished=\(result.finished) steps=\(result.steps.count) \(Int(result.seconds))s", to: folder)
            lastResult = ["task": task, "answer": result.answer, "finished": result.finished, "steps": result.steps.count,
                          "seconds": Int(result.seconds), "run": folder.lastPathComponent]
            return result
        } catch {
            do { try await hands.disableHID() }
            catch { Self.append("hid detach failed: \(error.localizedDescription)", to: folder) }
            Self.append("error: \(error)", to: folder)
            lastResult = ["task": task, "error": "\(error)", "run": folder.lastPathComponent]
            throw error
        }
    }

    // MARK: IPhoneAgentDevice

    func prepare() async throws {
        screen.start()
        try await hands.ensureHID()
        // The board decides whether a mirror is running: the viewer keeps the last decoded frame
        // after a mirror ends, so a frame on hand is not proof of a live screen.
        let status: [String: Any]
        do { status = try await hands.phoneStatus() }
        catch { throw IPhoneAgentError("连不上板子（USB 网络），请确认板子插在手机上：\(error.localizedDescription)") }
        let mirroring = (status["airplay"] as? [String: Any])?["mirror_active"] as? Bool == true
        if mirroring {
            // A viewer that just connected gets the board's cached GOP within a moment.
            let warmup = ContinuousClock.now + .seconds(4)
            while ContinuousClock.now < warmup {
                if (try? await screen.snapshot()) != nil {
                    await checkAssistiveButtonMoved()
                    await learnMirrorRouteIfNeeded()
                    return
                }
                try await Task.sleep(for: .milliseconds(250))
            }
            // Never touch Control Center here: the mirror is running and only the picture is late.
            throw IPhoneAgentError("板子在接收镜像但还没有画面（\(screen.currentStats.status)），请稍后重试")
        }
        // No mirror session. Only a phone whose route was learned on its own screen is tapped blind;
        // another phone's coordinates could land on anything.
        guard hands.layout.mirrorRouteUsable else {
            throw IPhoneAgentError("看不到手机画面：第一次需要你在控制中心 → 屏幕镜像里选择「\(await hands.airplayName() ?? "TonoLink USB")」，之后断开会自动重连")
        }
        try await restartMirror()
    }

    /// Starts the mirror to the board along the learned route, blind, in one try: Home (so Control
    /// Center, the device list or a menu left open cannot shift the taps), AssistiveTouch →
    /// 控制中心 → 屏幕镜像 → the board's row as it sits when nothing is mirroring. The app cannot
    /// see which receiver a tap picked (iOS reports neither a second screen nor, once the app's
    /// own audio is up, the AirPlay route), so it never taps a second guess; a miss ends at Home
    /// with a message.
    func restartMirror() async throws {
        var menuOpen = false
        if TonoLinkTapProbe.available {
            // This app is in front, so Control Center and menus are closed: no Home. The first tap
            // checks that the button is still where the route was learned (it may have been dragged
            // while the mirror was down) before any further blind tap.
            switch try await assistiveButtonCheckedByTap() {
            case .menuOpened:
                menuOpen = true
            case .moved:
                invalidateMirrorRoute("AssistiveTouch button moved while mirroring was down")
                throw IPhoneAgentError("辅助触控小圆点的位置变了，没有自动投屏：请在控制中心 → 屏幕镜像里选择「\(await hands.airplayName() ?? "TonoLink USB")」一次，之后会自动重新学习")
            case .unknown:
                break
            }
        }
        if !menuOpen { try await hands.home(); try await Task.sleep(for: .milliseconds(1500)) }
        let mark = screen.frameCount
        try await hands.startMirroring(menuOpen: menuOpen)
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if await hands.mirrorActive() {
                try await waitForFrames(after: mark)
                try? await closeControlCenter()
                return
            }
            try await Task.sleep(for: .milliseconds(400))
        }
        try? await hands.home()
        invalidateMirrorRoute("restart missed")
        throw IPhoneAgentError("自动投屏没有成功，这条路线已作废：请在控制中心 → 屏幕镜像里选择「\(await hands.airplayName() ?? "TonoLink USB")」，投屏后会自动重新学习")
    }

    /// When the button was last confirmed on screen (task start, Home or learning).
    private var lastButtonCheck: ContinuousClock.Instant?
    /// Back-to-back tasks do not pay for a check each; a drag is still found at the next task.
    static let buttonCheckInterval: Duration = .seconds(60)

    /// Finds a dragged AssistiveTouch button before it breaks anything: with the screen visible at
    /// the start of a task, look for the button and compare it with the saved place. The menu, and
    /// 控制中心 in it, opens next to the button, so a moved button invalidates the learned route,
    /// which `learnMirrorRouteIfNeeded()` then learns again right away. `prepare()` has attached the
    /// board's keyboard first, which hides the software keyboard, so the button is not caught in
    /// its temporary place above it. A move must be seen twice in a row: one wrong UI-Venus answer
    /// must not throw a good route away.
    func checkAssistiveButtonMoved() async {
        guard hands.layout.mirrorRouteUsable else { return }
        if let last = lastButtonCheck, ContinuousClock.now - last < Self.buttonCheckInterval { return }
        lastButtonCheck = .now
        let saved = hands.layout.assistiveButton
        guard let first = try? await locate(Self.assistiveButton, waitForChange: false), Self.far(first, saved) else { return }
        try? await Task.sleep(for: .milliseconds(400))
        guard let second = try? await locate(Self.assistiveButton, waitForChange: false),
              !Self.far(first, second), Self.far(second, saved) else { return }
        hands.layout.assistiveButton = second
        hands.layout.save()
        invalidateMirrorRoute("AssistiveTouch button moved from (\(Int(saved.x)),\(Int(saved.y))) to (\(Int(second.x)),\(Int(second.y)))")
    }

    /// Device tests drag the button twice within a minute.
    func resetButtonCheckForTesting() { lastButtonCheck = nil }

    enum ButtonTap { case menuOpened, moved, unknown }

    /// With this app in front and the mirror down: taps the saved AssistiveTouch position over an
    /// invisible window of this app (`TonoLinkTapProbe`). Measured on an iPhone: a press on the
    /// button reaches AssistiveTouch and opens its menu, the window gets nothing; a press anywhere
    /// else lands on the window, which swallows it. `.unknown` when the window could not be shown.
    func assistiveButtonCheckedByTap() async throws -> ButtonTap {
        let probe = TonoLinkTapProbe()
        guard probe.show() else { return .unknown }
        defer { probe.hide() }
        try await Task.sleep(for: .milliseconds(300))
        try await hands.tap(hands.layout.assistiveButton)
        try await Task.sleep(for: .milliseconds(900))
        return probe.touches.isEmpty ? .menuOpened : .moved
    }

    /// The saved route no longer fits this phone: stop replaying it and learn it again.
    func invalidateMirrorRoute(_ reason: String) {
        guard hands.layout.mirrorRouteLearned == true else { return }
        hands.layout.invalidateMirrorRoute()
        hands.layout.save()
        learnAttempted = false
        logger.info("mirror route invalidated: \(reason, privacy: .public)")
    }

    /// Frames decoded after `mark`: the viewer still holds the last picture of the ended mirror.
    private func waitForFrames(after mark: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if (try? await screen.snapshot(newerThan: mark, fresh: 2, timeout: .seconds(1))) != nil { return }
            try await Task.sleep(for: .milliseconds(300))
        }
        throw IPhoneAgentError("板子在接收镜像但还没有画面（\(screen.currentStats.status)），请稍后重试")
    }

    /// One learning attempt per route generation: a failed attempt is not repeated before every task
    /// of this launch, but an invalidated route gets a new attempt.
    private var learnAttempted = false

    /// Learns the route when it is missing, invalidated or a week old, the first time the screen is
    /// visible, so the next dropped mirror can be restarted without the user. Never fails the task.
    func learnMirrorRouteIfNeeded() async {
        guard hands.layout.mirrorRouteNeedsLearning(), !learnAttempted else { return }
        learnAttempted = true
        do {
            let route = try await learnMirrorRoute()
            logger.info("mirror route learned: \(route, privacy: .public)")
        }
        catch { logger.error("mirror route not learned: \(String(describing: error), privacy: .public)") }
    }

    static let controlCenterItem = "the 控制中心 (Control Center) item inside the open AssistiveTouch menu panel: an icon of two toggle switches labelled 控制中心. Not the floating round button itself"
    static let mirrorTile = "the 屏幕镜像 (Screen Mirroring) button in the open Control Center: a rounded tile with an icon of two overlapping rectangles"
    /// Board-row-to-停止镜像 gap (0–1000) below which only the divider and 停止镜像 follow the board.
    static let boardIsLastRowGap = 120.0
    static let mirrorStopItem = "the 停止镜像 (Stop Mirroring) item at the bottom of the open 屏幕镜像 device list"
    static func mirrorRow(_ name: String) -> String {
        "the row labelled \"\(name)\" in the open 屏幕镜像 (Screen Mirroring) device list"
    }
    /// Control Center covers and blurs the whole screen; the device list replaces most of it.
    static let controlCenterOpened = 12.0
    /// The device list is a small popover over Control Center: about 4 measured on an iPhone.
    static let mirrorListOpened = 2.0

    /// Taps `point` and returns the next screen only if it changed by at least `atLeast` (mean,
    /// 0–255). UI-Venus answers with some point even when the thing is not there, so every step of a
    /// blind route is accepted only when the tap visibly opened what it should.
    private func tapAndSee(_ point: TonoLinkPoint, atLeast: Double) async throws -> IPhoneFrame? {
        let before = try await screen.snapshot()
        try await hands.tap(point)
        try await Task.sleep(for: .milliseconds(900))
        let after = try? await screen.snapshot(newerThan: before.frame, fresh: 2, timeout: .seconds(3))
        let difference = after.flatMap { IPhoneScreenDiff.mean(before.jpeg, $0.jpeg) }
        learnTrace.append((name: "tap (\(Int(point.x)),\(Int(point.y))) diff=\(difference.map { String(format: "%.1f", $0) } ?? "no new frame")",
                           jpeg: after?.jpeg ?? before.jpeg))
        guard let after, let difference, difference >= atLeast else { return nil }
        try await Task.sleep(for: .milliseconds(500))   // let the panel finish animating
        let settled = (try? await screen.snapshot()) ?? after
        return IPhoneFrame(jpeg: settled.jpeg, width: settled.width, height: settled.height, frame: settled.frame)
    }

    static func far(_ a: TonoLinkPoint, _ b: TonoLinkPoint) -> Bool { abs(a.x - b.x) > 60 || abs(a.y - b.y) > 60 }

    /// Learns where AssistiveTouch → 控制中心 → 屏幕镜像 → the board's row are on this phone, from the
    /// live mirror, and saves them for `startMirroring()`. Each step must visibly open the next panel.
    /// It never taps the board's row and closes Control Center afterwards, so the running mirror
    /// is left as it was. Needs mirroring on: the screen is what it reads.
    /// What each step of the last `learnMirrorRoute()` saw, for diagnosis (memory only).
    var learnTrace: [(name: String, jpeg: Data)] = []

    @discardableResult
    func learnMirrorRoute() async throws -> String {
        learnTrace = []
        _ = try await screen.snapshot()
        try await hands.ensureHID()
        // The floating button is wherever the user last dragged it: find it on screen, not in the
        // saved layout.
        guard let button = try await locate(Self.assistiveButton, waitForChange: false) else {
            throw IPhoneAgentError("学习投屏路线失败：屏幕上没有辅助触控的小圆点（设置 → 辅助功能 → 触控 → 辅助触控）")
        }
        guard let menu = try await tapAndSee(button, atLeast: Self.menuOpened) else {
            throw IPhoneAgentError("学习投屏路线失败：点小圆点没有打开辅助触控菜单")
        }
        guard let found = try await IPhoneGrounding.locate(Self.controlCenterItem, in: menu) else {
            try? await hands.key("esc")
            throw IPhoneAgentError("学习投屏路线失败：辅助触控菜单里没有「控制中心」，请在 设置 → 辅助功能 → 触控 → 辅助触控 → 自定顶层菜单 里加上它")
        }
        let controlCenter = TonoLinkPoint(found.x, found.y)
        guard Self.far(controlCenter, button),
              let center = try await tapAndSee(controlCenter, atLeast: Self.controlCenterOpened) else {
            try? await hands.key("esc")
            throw IPhoneAgentError("学习投屏路线失败：没能从辅助触控菜单打开控制中心")
        }
        guard let tilePoint = try await IPhoneGrounding.locate(Self.mirrorTile, in: center) else {
            try? await closeControlCenter()
            throw IPhoneAgentError("学习投屏路线失败：控制中心里没有找到「屏幕镜像」")
        }
        let tile = TonoLinkPoint(tilePoint.x, tilePoint.y)
        guard let list = try await tapAndSee(tile, atLeast: Self.mirrorListOpened) else {
            try? await closeControlCenter()
            throw IPhoneAgentError("学习投屏路线失败：点「屏幕镜像」没有打开设备列表（或投屏因此断开了）")
        }
        let name = await hands.airplayName() ?? "TonoLink USB"
        let rowPoint = try await IPhoneGrounding.locate(Self.mirrorRow(name), in: list)
        let stopPoint = try await IPhoneGrounding.locate(Self.mirrorStopItem, in: list)
        try? await closeControlCenter()
        guard let rowPoint else { throw IPhoneAgentError("学习投屏路线失败：设备列表里没有找到「\(name)」") }
        guard let stopPoint else { throw IPhoneAgentError("学习投屏路线失败：设备列表里没有「停止镜像」") }
        let active = TonoLinkPoint(rowPoint.x, rowPoint.y), stop = TonoLinkPoint(stopPoint.x, stopPoint.y)
        guard stop.y - active.y > 30 else {
            throw IPhoneAgentError("学习投屏路线失败：「停止镜像」不在板子那一行下面")
        }
        // Measured on an iPhone (iOS 27.2): with nothing mirroring the list has no 停止镜像 section and
        // keeps its bottom edge, so every device row moves down by that section's height. Tapping
        // the board's running-mirror position then picked the receiver above it (the user's Mac);
        // tapping where 停止镜像 was picked the board. That holds when the board is the last row, i.e.
        // only the divider and 停止镜像 lie below it (measured gap 91 of 1000; one more row adds ~63).
        // With another receiver below the board the idle position cannot be read off the two labelled
        // anchors, and asking UI-Venus for "the last row" proved unreliable, so no blind route is kept.
        guard stop.y - active.y <= Self.boardIsLastRowGap else {
            throw IPhoneAgentError("学习投屏路线失败：设备列表里板子下面还有别的接收设备，无法安全地自动重连；断开后请在控制中心手动选择板子")
        }
        let row = TonoLinkPoint(active.x, stop.y)
        hands.layout.assistiveButton = button
        hands.layout.assistiveControlCenter = controlCenter
        hands.layout.mirrorButton = tile
        hands.layout.mirrorTarget = row
        hands.layout.mirrorStop = stop
        hands.layout.markMirrorRouteLearned()
        hands.layout.save()
        lastButtonCheck = .now
        return "button (\(Int(button.x)),\(Int(button.y))) → 控制中心 (\(Int(controlCenter.x)),\(Int(controlCenter.y)))"
            + " → 屏幕镜像 (\(Int(tile.x)),\(Int(tile.y))) → \(name) (\(Int(row.x)),\(Int(row.y)))"
            + "（不投屏时），停止镜像 (\(Int(stop.x)),\(Int(stop.y)))"
    }

    /// Leaves the device list and Control Center without touching the mirror: Escape closes the
    /// list; Home through AssistiveTouch closes Control Center.
    /// Measured on the phone (TonoLinkMirrorDeviceTests.testWhatClosesControlCenter): `esc` leaves
    /// Control Center open, and the AssistiveTouch button opens its menu on top of it, so Home
    /// through that menu missed and the next task started under Control Center. A swipe up from
    /// the bottom edge closes it.
    private func closeControlCenter() async throws {
        try? await hands.key("esc")
        try await Task.sleep(for: .milliseconds(500))
        try await hands.swipe(from: TonoLinkPoint(500, 990), to: TonoLinkPoint(500, 450), ms: 300)
        try await Task.sleep(for: .milliseconds(800))
    }

    func screenshot(after frame: Int?) async throws -> IPhoneFrame {
        let shot = try await screen.snapshot(newerThan: frame)
        return IPhoneFrame(jpeg: shot.jpeg, width: shot.width, height: shot.height, frame: shot.frame)
    }

    func perform(_ action: IPhoneAction) async throws -> String {
        try await hands.ensureHID()
        let p = action.points.map { TonoLinkPoint($0.x, $0.y) }
        let needs = ["click": 1, "tap": 1, "doubleclick": 1, "longpress": 1, "drag": 2, "swipe": 2][action.name] ?? 0
        guard p.count >= needs else { throw IPhoneAgentError("\(action.raw.prefix(80)) has no coordinates") }
        switch action.name {
        case "click", "tap":
            try await hands.tap(p[0]); return "tap (\(Int(p[0].x)),\(Int(p[0].y)))"
        case "doubleclick":
            try await hands.doubleTap(p[0].x, p[0].y); return "double tap"
        case "longpress":
            try await hands.longPress(p[0].x, p[0].y); return "long press"
        case "drag", "swipe":
            try await hands.swipe(from: p[0], to: p[1], ms: action.name == "drag" ? 1000 : 400)
            return "swipe (\(Int(p[0].x)),\(Int(p[0].y)))→(\(Int(p[1].x)),\(Int(p[1].y)))"
        case "scroll":
            // direction = which side's content to reveal: down → finger moves up.
            let x = min(max(p.first?.x ?? 500, 100), 900), y = min(max(p.first?.y ?? 500, 250), 750)
            let (a, b): (TonoLinkPoint, TonoLinkPoint) = switch action.direction ?? "down" {
            case "up": (.init(x, 300), .init(x, 750))
            case "left": (.init(150, y), .init(850, y))
            case "right": (.init(850, y), .init(150, y))
            default: (.init(x, 750), .init(x, 300))
            }
            try await hands.swipe(from: a, to: b, ms: 450); return "scroll \(action.direction ?? "down")"
        case "type":
            try await hands.type(action.text); return "type \(action.text.count) chars"
        case "presshome":
            return try await home()
        case "pressenter":
            try await hands.key("enter"); return "enter"
        case "launchapp", "launch":
            // Never guess: an empty name used to open 设置 and send the model hunting for the wrong app.
            guard !action.text.isEmpty else { throw IPhoneAgentError("LaunchApp needs the app's name, e.g. LaunchApp(app='小红书')") }
            let app = action.text
            let query = Self.searchQuery(for: app)
            // Like xiaozhi-link: Home, open Search (every home page has the 搜索 button above the dock),
            // type the name, Return opens Spotlight's top hit. The model checks the result on the next screenshot.
            _ = try await home()
            try await Task.sleep(for: .milliseconds(800))
            do { _ = try await tapLocated(Self.searchButton, waitForChange: true) } catch {
                try await hands.swipe(from: TonoLinkPoint(500, 380), to: TonoLinkPoint(500, 700), ms: 350)
            }
            try await Task.sleep(for: .milliseconds(1000))
            try await hands.type(query)
            try await Task.sleep(for: .milliseconds(900))
            let typed = try? await screen.snapshot()
            try await hands.key("enter")
            // With the Pinyin keyboard active the letters sit in its candidate bar and Return only
            // commits them; Spotlight is then still on screen. An app takes a moment to appear on the
            // mirror, so wait for it (up to 2.5 s) before deciding: a second Return in an opened app is a keypress there.
            if let typed, !(try await waitForChange(since: typed, atLeast: Self.stillSpotlight, within: .milliseconds(2500))) {
                try await hands.key("enter")
                return "searched \(query) in Spotlight and pressed Return twice (the first only committed the keyboard's input)"
            }
            return "searched \(query) in Spotlight and pressed Return (top hit)"
        case "wait":
            try await Task.sleep(for: .milliseconds(1500)); return "wait"
        case "pressback", "pressrecent", "getscreenshot":
            throw IPhoneAgentError("\(action.raw.prefix(40)) is not available on this iPhone; to go back tap the visible \"<\" back button")
        default:
            throw IPhoneAgentError("unsupported action: \(action.raw.prefix(120))")
        }
    }

    // MARK: system gestures located on the current screen

    /// Below this mean difference the screen after Return is still Spotlight, not a launched app.
    static let stillSpotlight = 15.0

    static let assistiveButton = "the AssistiveTouch floating button: a round, semi-transparent grey button with a white ring, usually at the left or right edge of the screen"
    static let searchButton = "the 搜索 (Search) button: a small pill labelled 搜索 with a magnifier, just above the dock at the bottom of the home screen"
    static let assistiveHome = "the 主屏幕 (Home) item inside the open AssistiveTouch menu (a dark rounded panel with several labelled icons): the icon labelled 主屏幕. Not the floating round button itself"

    /// Taps the element UI-Venus finds on a fresh screenshot.
    func tapLocated(_ target: String, waitForChange: Bool = false) async throws -> TonoLinkPoint {
        guard let point = try await locate(target, waitForChange: waitForChange) else { throw IPhoneAgentError("屏幕上找不到：\(target)") }
        try await hands.tap(point)
        return point
    }

    /// Home through AssistiveTouch → 主屏幕. The button sits wherever the user left it, and on some
    /// screens a tap there reaches the app instead (钱包's own floating buttons sit right under it).
    /// So the menu must be seen to open (the screen changes a lot) before 主屏幕 is tapped: a blind
    /// second tap used to land on whatever was underneath, on the home screen the 钱包 icon.
    func home() async throws -> String {
        var button = hands.layout.assistiveButton
        var item = try await openAssistiveMenu(at: button)
        if item == nil {
            // The first click may only have woken the pointer: once more at the same place.
            item = try await openAssistiveMenu(at: button)
        }
        if item == nil, let found = try await locate(Self.assistiveButton, waitForChange: false),
           abs(found.x - button.x) > 30 || abs(found.y - button.y) > 30 {
            button = found
            item = try await openAssistiveMenu(at: button)
        }
        guard let item else {
            throw IPhoneAgentError("Home did not work: the AssistiveTouch menu did not open on this screen "
                + "(a button of the app may sit under it, or a system prompt is in front). Close what is open with "
                + "its own visible button (取消 / 完成 / 关闭 / <) first; for a permission prompt use CallUser.")
        }
        try await hands.tap(item)
        // The menu opens next to the button, so a moved button moves 控制中心 too.
        if Self.far(button, hands.layout.assistiveButton) { invalidateMirrorRoute("AssistiveTouch button moved") }
        lastButtonCheck = .now
        hands.layout.assistiveButton = button
        hands.layout.assistiveHome = item
        hands.layout.save()
        return "home via AssistiveTouch (\(Int(button.x)),\(Int(button.y))) → (\(Int(item.x)),\(Int(item.y)))"
    }

    /// Taps the AssistiveTouch button; returns the menu's 主屏幕 item only if the menu visibly opened.
    private func openAssistiveMenu(at button: TonoLinkPoint) async throws -> TonoLinkPoint? {
        let before = try await screen.snapshot()
        try await hands.tap(button)
        try await Task.sleep(for: .milliseconds(700))
        let after = try await screen.snapshot(newerThan: before.frame, fresh: 2, timeout: .seconds(2))
        guard let difference = IPhoneScreenDiff.mean(before.jpeg, after.jpeg), difference >= Self.menuOpened else {
            return nil
        }
        let frame = IPhoneFrame(jpeg: after.jpeg, width: after.width, height: after.height, frame: after.frame)
        guard let point = try await IPhoneGrounding.locate(Self.assistiveHome, in: frame) else {
            try? await hands.key("esc")   // a menu opened but it is not AssistiveTouch's: close it
            return nil
        }
        return TonoLinkPoint(point.x, point.y)
    }

    /// True once the screen differs from `shot` by at least `atLeast` (mean, 0–255) within `within`.
    private func waitForChange(since shot: TonoLinkScreenShot, atLeast: Double, within: Duration) async throws -> Bool {
        let deadline = ContinuousClock.now + within
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(300))
            guard let now = try? await screen.snapshot(),
                  let difference = IPhoneScreenDiff.mean(shot.jpeg, now.jpeg) else { continue }
            if difference >= atLeast { return true }
        }
        return false
    }

    /// The AssistiveTouch menu darkens and covers about half the screen: far above this mean difference.
    static let menuOpened = 6.0

    func locate(_ target: String, waitForChange: Bool) async throws -> TonoLinkPoint? {
        let shot = try await screen.snapshot(newerThan: waitForChange ? screen.frameCount : nil, fresh: 3, timeout: .seconds(2))
        let frame = IPhoneFrame(jpeg: shot.jpeg, width: shot.width, height: shot.height, frame: shot.frame)
        return try await IPhoneGrounding.locate(target, in: frame).map { TonoLinkPoint($0.x, $0.y) }
    }

    // MARK: run logs (Documents/iphone-agent/<time>/)

    static func runFolder() -> URL {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iphone-agent").appendingPathComponent(formatter.string(from: Date()))
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func append(_ line: String, to folder: URL) {
        let file = folder.appendingPathComponent("log.txt")
        let data = Data((ISO8601DateFormatter().string(from: Date()) + " " + line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: file) { handle.seekToEndOfFile(); handle.write(data); try? handle.close() }
        else { try? data.write(to: file) }
    }

    #if DEBUG
    // MARK: relay debug routes (only while the developer relay is switched on)

    func route(_ request: TonoLinkRelayRequest) async -> TonoLinkRelayResponse? {
        switch (request.method, request.path) {
        case ("POST", "/debug/chat"):
            // DEBUG: submit one message to the current chat, exactly as the composer does.
            let text = String(decoding: request.body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return .error(400, "body: message text") }
            let accepted = await ChatModel.shared.send(text)
            return .json(200, ["accepted": accepted])
        case ("GET", "/debug/transcript"):
            let n = Int(request.queryValue("n") ?? "") ?? 12
            let items = ChatModel.shared.items.suffix(max(1, min(n, 200))).map { item in
                ["kind": "\(item.kind)", "title": item.title, "text": String(item.text.prefix(2000))]
            }
            return .json(200, ["turn_running": ChatModel.shared.turnRunning, "items": Array(items)])
        case ("GET", "/debug/voice"):
            return .json(200, TonoLinkVoiceHost.shared.debugSnapshot)
        case ("POST", "/debug/voice/wake"):
            // As if the board heard 你好小智: 我在, then the board records one turn.
            TonoLinkVoiceHost.shared.beginTurn(wake: 0, source: "debug")
            return .json(200, ["ok": true])
        case ("POST", "/debug/voice/say"):
            let text = String(decoding: request.body, as: UTF8.self)
            guard let credential = await TonoLinkVoiceHost.shared.credential() else { return .error(409, "no cloud credential") }
            do { try await TonoLinkVoiceHost.shared.speakAloud(text, credential: credential) } catch { return .error(502, error.localizedDescription) }
            return .json(200, ["ok": true])
        case ("POST", "/debug/voice/opus"):
            // Body: `[len u16 LE][Opus 20 ms]…`; `?chat=1` also sends the text to the chat and speaks the reply.
            return .json(200, await TonoLinkVoiceHost.shared.debugRecognize(request.body, chat: request.queryValue("chat") == "1"))
        case ("GET", "/debug/ble"):
            // What the Bluetooth devices page shows, for named or connected devices.
            let store = BLEDeviceStore.shared
            let rows = store.devices.filter { $0.name != "未命名 BLE 设备" || $0.state != "未连接" }.map { d -> [String: Any] in
                ["id": d.id.uuidString, "name": d.name, "state": d.state, "link": d.linkState, "link_id": d.linkIdentity,
                 "tools": d.linkTools, "granted": d.grantedTools.sorted(), "read": d.allowRead, "alert": d.allowAlert]
            }
            return .json(200, ["status": store.status, "trust": store.trustConnectedDevices, "devices": rows])
        case ("POST", "/debug/ble/scan"):
            BLEDeviceStore.shared.scan()   // the page's scan button
            return .json(200, ["ok": true])
        case ("POST", "/debug/ble/connect"):
            // The board row's 连接 button: the same store call the page makes.
            let want = request.queryValue("name") ?? "PhoneAgent"
            guard let device = BLEDeviceStore.shared.devices.first(where: { $0.name.localizedCaseInsensitiveContains(want) }) else {
                return .error(404, "no listed device named \(want); POST /debug/ble/scan first")
            }
            BLEDeviceStore.shared.connect(device.id)
            return .json(200, ["id": device.id.uuidString, "name": device.name])
        case ("GET", "/debug/native-mcp"):
            return .json(200, ["requests": NativeMCPDebugRecorder.current?.snapshot() ?? []])
        case ("GET", "/agent/status"):
            var status: [String: Any] = ["running": running ?? "", "last": lastResult, "layout": [
                "assistive_button": [hands.layout.assistiveButton.x, hands.layout.assistiveButton.y]]]
            if let data = try? JSONEncoder().encode(screen.currentStats), let stats = try? JSONSerialization.jsonObject(with: data) {
                status["screen"] = stats
            }
            return .json(200, status)
        case ("GET", "/agent/screen.jpg"):
            do {
                let shot = try await screen.snapshot()
                return TonoLinkRelayResponse(status: 200, contentType: "image/jpeg", body: shot.jpeg)
            } catch { return .error(503, "\(error)") }
        case ("POST", "/agent/run"):
            let task = String(decoding: request.body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !task.isEmpty else { return .error(400, "body: task text") }
            do {
                let result = try await run(task)
                return .json(200, ["answer": result.answer, "finished": result.finished, "steps": result.steps.map { "\($0.action) → \($0.executed)" },
                                   "seconds": Int(result.seconds)])
            } catch { return .error(500, "\(error)") }
        case ("POST", "/agent/act"):
            var action = IPhoneAction.parse(String(decoding: request.body, as: UTF8.self))
            action.points = action.points.map { IPhoneAction.normalized($0, width: 1000, height: 1000) }
            do { return .json(200, ["did": try await perform(action)]) } catch { return .error(500, "\(error)") }
        case ("POST", "/agent/home"):
            do { try await hands.ensureHID(); return .json(200, ["did": try await home()]) }
            catch { return .error(500, "\(error)") }
        case ("POST", "/agent/locate"):
            let target = String(decoding: request.body, as: UTF8.self)
            do {
                let frame = try await screenshot(after: nil)
                let p = try await IPhoneGrounding.locate(target, in: frame)
                return .json(200, ["point": p.map { [$0.x, $0.y] } ?? []])
            } catch { return .error(500, "\(error)") }
        case ("POST", "/agent/learn-mirror"):
            do { return .json(200, ["did": try await learnMirrorRoute()]) } catch { return .error(500, "\(error)") }
        case ("POST", "/agent/mirror"):
            do { try await hands.ensureHID(); try await restartMirror(); return .json(200, ["ok": true]) }
            catch { return .error(500, "\(error)") }
        default:
            return nil
        }
    }
    #endif
}
