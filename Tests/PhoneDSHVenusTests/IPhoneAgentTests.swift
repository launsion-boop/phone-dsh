// SPDX-License-Identifier: MIT
import XCTest
import CoreGraphics
import Foundation
import ImageIO
import PhoneDSH
@testable import PhoneDSHVenus

private final class AgentSecrets: ModelProviderSecretStore, @unchecked Sendable {
    var value: String?
    func secret(for reference: String) throws -> String? { value }
    func setSecret(_ secret: String, for reference: String) throws { value = secret }
    func deleteSecret(for reference: String) throws { value = nil }
}

/// Answers chat completions from a script, one reply per call; records the request bodies.
private final class ScriptedModel: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var replies: [String] = []
    static var bodies: [[String: Any]] = []
    static func reset(_ replies: [String]) { lock.withLock { self.replies = replies; bodies = [] } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; body.append(contentsOf: buffer.prefix(n)) }
        }
        let reply: String = Self.lock.withLock {
            Self.bodies.append((try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:])
            return Self.replies.isEmpty ? "<action>Finished(content='done')</action>" : Self.replies.removeFirst()
        }
        let object: [String: Any] = ["choices": [["finish_reason": "stop", "message": ["content": reply]]]]
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                                              headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: object))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor private final class FakePhone: IPhoneAgentDevice {
    var prepared = 0
    var actions: [IPhoneAction] = []
    var afterFrames: [Int?] = []
    var frame = 0
    var failNext = false
    func prepare() async throws { prepared += 1 }
    func screenshot(after frame: Int?) async throws -> IPhoneFrame {
        afterFrames.append(frame); self.frame += 10
        return IPhoneFrame(jpeg: Data([0xff, 0xd8, 0xff]), width: 600, height: 1300, frame: self.frame)
    }
    func perform(_ action: IPhoneAction) async throws -> String {
        actions.append(action)
        if failNext { failNext = false; throw IPhoneAgentError("pointer lost") }
        return "did \(action.name)"
    }
}

@MainActor final class IPhoneAgentTests: XCTestCase {
    private func client() throws -> VenusClient {
        let settings = VenusSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!, secrets: AgentSecrets())
        try settings.save(VenusConfiguration(baseURL: "https://vision.example/v1"), key: "agent-fixture-key")
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ScriptedModel.self]
        return VenusClient(settings: settings, session: URLSession(configuration: config))
    }

    func testParsesVenusActions() {
        let click = IPhoneAction.parse("<think>open it</think>\n<action>Click(point=(120, 845))</action>")
        XCTAssertEqual(click.name, "click"); XCTAssertEqual(click.points, [.init(120, 845)])
        let swipe = IPhoneAction.parse("<action>Swipe(start=[500,800], end=(500,200))</action>")
        XCTAssertEqual(swipe.name, "swipe"); XCTAssertEqual(swipe.points.count, 2)
        XCTAssertEqual(IPhoneAction.parse("<action>Type(content='电池')</action>").text, "电池")
        XCTAssertEqual(IPhoneAction.parse("<action>LaunchApp(app=\"Settings\")</action>").text, "Settings")
        XCTAssertEqual(IPhoneAction.parse("<action>Finished(content='电量 80%')</action>").name, "finished")
        XCTAssertEqual(IPhoneAction.parse("Scroll(point=(500,500), direction='down')").direction, "down")
    }

    func testPixelCoordinatesAreNormalized() {
        let p = IPhoneAction.normalized(.init(1170, 2532), width: 1170, height: 2532)
        XCTAssertEqual(p.x, 1000, accuracy: 0.01); XCTAssertEqual(p.y, 1000, accuracy: 0.01)
        XCTAssertEqual(IPhoneAction.normalized(.init(400, 700), width: 600, height: 1300), .init(400, 700))
    }

    func testLoopActsUntilFinishedAndWaitsForNewFrames() async throws {
        ScriptedModel.reset(["<think>t</think><action>Click(point=(100,200))</action>",
                             "<action>LaunchApp(app='Settings')</action>",
                             "<action>Finished(content='电量 81%')</action>"])
        let phone = FakePhone()
        let agent = IPhoneAgent(device: phone, client: try client(), settle: .zero)
        let result = try await agent.run("看看电量")
        XCTAssertTrue(result.finished)
        XCTAssertEqual(result.answer, "电量 81%")
        XCTAssertEqual(phone.prepared, 1)
        XCTAssertEqual(phone.actions.map(\.name), ["click", "launchapp"])
        XCTAssertEqual(phone.afterFrames, [nil, 10, 20], "each screenshot after an action waits for frames newer than the last one")
        XCTAssertEqual(result.steps.count, 3)
        // Third request: system + 2 earlier turns (user/assistant each) + current screenshot; the
        // LaunchApp hint is the feedback for the next screenshot.
        let messages = ScriptedModel.lock.withLock { ScriptedModel.bodies[2]["messages"] as? [[String: Any]] } ?? []
        XCTAssertEqual(messages.count, 6)
        XCTAssertEqual(ScriptedModel.lock.withLock { ScriptedModel.bodies[2]["model"] as? String }, "ui-venus-2-9b")
        let last = messages.last?["content"] as? [[String: Any]]
        XCTAssertTrue((last?.first?["text"] as? String ?? "").contains("opened the top result"))
    }

    func testFailedActionIsReportedToTheModelNotRetried() async throws {
        ScriptedModel.reset(["<action>Click(point=(100,200))</action>", "<action>CallUser(content='请解锁手机')</action>"])
        let phone = FakePhone(); phone.failNext = true
        let result = try await IPhoneAgent(device: phone, client: try client(), settle: .zero).run("打开微信")
        XCTAssertFalse(result.finished)
        XCTAssertTrue(result.answer.contains("请解锁手机"))
        XCTAssertEqual(phone.actions.count, 1)
        let messages = ScriptedModel.lock.withLock { ScriptedModel.bodies[1]["messages"] as? [[String: Any]] } ?? []
        let last = messages.last?["content"] as? [[String: Any]]
        XCTAssertTrue((last?.first?["text"] as? String ?? "").contains("not executed: pointer lost"))
    }
}

@MainActor final class IPhoneActionFallbackTests: XCTestCase {
    func testJSONFallbackActionAfterThought() {
        let reply = "Thought: scroll a bit.\nAction: {\"action_type\": \"scroll\", \"start_coordinate\": [499, 874], \"end_coordinate\": [499, 500]}"
        let action = IPhoneAction.parse(reply)
        XCTAssertEqual(action.name, "swipe")
        XCTAssertEqual(action.points, [.init(499, 874), .init(499, 500)])
        XCTAssertEqual(IPhoneAction.parse("Thought: x\nAction: Click(point=(1,2))").name, "click")
    }
}

@MainActor private final class HangingPhone: IPhoneAgentDevice {
    func prepare() async throws {}
    func screenshot(after frame: Int?) async throws -> IPhoneFrame { IPhoneFrame(jpeg: Data([0xff]), width: 10, height: 10, frame: 1) }
    func perform(_ action: IPhoneAction) async throws -> String {
        try await Task.sleep(for: .seconds(30)); return "late"
    }
}

@MainActor final class IPhoneAgentDeadlineTests: XCTestCase {
    func testStalledActionTimesOutAndIsReportedToTheModel() async throws {
        let settings = VenusSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!, secrets: AgentSecrets())
        try settings.save(VenusConfiguration(baseURL: "https://vision.example/v1"), key: "agent-fixture-key")
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ScriptedModel.self]
        ScriptedModel.reset(["<action>Click(point=(1,1))</action>", "<action>Finished(content='ok')</action>"])
        let agent = IPhoneAgent(device: HangingPhone(), client: VenusClient(settings: settings, session: URLSession(configuration: config)), settle: .zero)
        agent.stepTimeout = .milliseconds(300)
        let started = ContinuousClock.now
        let result = try await agent.run("x")
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))
        XCTAssertTrue(result.steps[0].executed.contains("超时"))
    }
}

// MARK: - Guards against flailing (tonolink-board.md §6)

private func solidJPEG(_ gray: CGFloat) -> Data {
    let width = 60, height = 130
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    context.setFillColor(gray: gray, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

/// A phone whose screen is fixed per step (`screens`), to drive the effect check.
@MainActor private final class StillPhone: IPhoneAgentDevice {
    var screens: [Data]
    var actions: [IPhoneAction] = []
    private var frame = 0
    init(screens: [Data]) { self.screens = screens }
    func prepare() async throws {}
    func screenshot(after frame: Int?) async throws -> IPhoneFrame {
        self.frame += 10
        let jpeg = screens.count > 1 ? screens.removeFirst() : screens[0]
        return IPhoneFrame(jpeg: jpeg, width: 60, height: 130, frame: self.frame)
    }
    func perform(_ action: IPhoneAction) async throws -> String { actions.append(action); return "did \(action.name)" }
}

@MainActor final class IPhoneAgentGuardTests: XCTestCase {
    private func client() throws -> VenusClient {
        let settings = VenusSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!, secrets: AgentSecrets())
        try settings.save(VenusConfiguration(baseURL: "https://vision.example/v1"), key: "agent-fixture-key")
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ScriptedModel.self]
        return VenusClient(settings: settings, session: URLSession(configuration: config))
    }

    func testScreenDiffSeparatesSameFromDifferent() throws {
        let white = solidJPEG(1), black = solidJPEG(0)
        XCTAssertLessThan(try XCTUnwrap(IPhoneScreenDiff.mean(white, white)), IPhoneScreenDiff.unchanged)
        XCTAssertGreaterThan(try XCTUnwrap(IPhoneScreenDiff.mean(white, black)), 200)
        XCTAssertNil(IPhoneScreenDiff.mean(Data([0xff, 0xd8, 0xff]), white), "an undecodable frame gives no verdict")
    }

    func testLoopGuardNudgesOnceThenStops() {
        var guardian = IPhoneLoopGuard()
        let home = IPhoneAction.parse("<action>PressHome()</action>")
        XCTAssertEqual(guardian.record(home), .proceed)
        XCTAssertEqual(guardian.record(home), .proceed)
        guard case .nudge = guardian.record(home) else { return XCTFail("third repeat nudges") }
        XCTAssertEqual(guardian.record(home), .proceed, "a fresh window after the nudge")
        XCTAssertEqual(guardian.record(home), .proceed)
        guard case .stop(let answer) = guardian.record(home) else { return XCTFail("repeating after the nudge stops") }
        XCTAssertTrue(answer.hasPrefix("卡住了"))
    }

    func testPingPongIsALoopButNearbyTapsAreTheSameAction() {
        var guardian = IPhoneLoopGuard()
        let back = IPhoneAction.parse("<action>Click(point=(206, 185))</action>")
        let row = IPhoneAction.parse("<action>Click(point=(895, 427))</action>")
        let rowAgain = IPhoneAction.parse("<action>Click(point=(890, 420))</action>")
        XCTAssertEqual(guardian.record(back), .proceed)
        XCTAssertEqual(guardian.record(row), .proceed)
        XCTAssertEqual(guardian.record(back), .proceed)
        guard case .nudge = guardian.record(rowAgain) else { return XCTFail("A, B, A, B nudges") }
        var distinct = IPhoneLoopGuard()
        for x in [100, 300, 500, 700, 900] {
            XCTAssertEqual(distinct.record(IPhoneAction.parse("<action>Click(point=(\(x), 500))</action>")), .proceed)
        }
    }

    func testPingPongRunStopsEarlyWithAnHonestAnswer() async throws {
        let back = "<action>Click(point=(206, 185))</action>", row = "<action>Click(point=(895, 427))</action>"
        ScriptedModel.reset([back, row, back, row, back, row, back, row, back, row])
        let phone = StillPhone(screens: [solidJPEG(1), solidJPEG(0)])
        phone.screens = (0..<20).map { solidJPEG($0 % 2 == 0 ? 1 : 0) }
        let result = try await IPhoneAgent(device: phone, client: try client(), settle: .zero).run("查看电池电量")
        XCTAssertFalse(result.finished)
        XCTAssertTrue(result.answer.hasPrefix("卡住了"), result.answer)
        XCTAssertLessThan(result.steps.count, 15, "it stops instead of using every step")
        XCTAssertEqual(phone.actions.count, 6, "the nudged repeat is not performed")
        let nudged = ScriptedModel.lock.withLock { ScriptedModel.bodies[4]["messages"] as? [[String: Any]] } ?? []
        let text = (nudged.last?["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        XCTAssertTrue(text.contains("reply Answer or Finished now"), text)
    }

    func testModelIsToldWhenAnActionChangedNothing() async throws {
        ScriptedModel.reset(["<action>PressHome()</action>", "<action>Finished(content='ok')</action>"])
        let phone = StillPhone(screens: [solidJPEG(0.5)])
        _ = try await IPhoneAgent(device: phone, client: try client(), settle: .zero).run("回到主屏幕")
        let second = ScriptedModel.lock.withLock { ScriptedModel.bodies[1]["messages"] as? [[String: Any]] } ?? []
        let text = (second.last?["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        XCTAssertTrue(text.contains("looks unchanged after your previous action (PressHome())"), text)
    }
}

@MainActor final class IPhoneActionReplyShapeTests: XCTestCase {
    /// The degenerate JSON reply seen on the device: the app name must come through.
    func testJSONLaunchAppKeepsTheAppName() {
        let reply = #"The user wants to open the Xiaohongshu app. {"action_type": "LaunchApp", "app_name": "小红书"}"#
        let action = IPhoneAction.parse(reply)
        XCTAssertEqual(action.name, "launchapp")
        XCTAssertEqual(action.text, "小红书")
        XCTAssertEqual(IPhoneAction.parse(#"{"action_type": "Type", "text": "电池"}"#).text, "电池")
    }

    /// `stop: ["</action>"]` drops the closing tag; the action is still found.
    func testUnterminatedActionTagIsParsed() {
        let action = IPhoneAction.parse("<think>open it</think>\n<action>Click(point=(120, 845))")
        XCTAssertEqual(action.name, "click")
        XCTAssertEqual(action.points, [.init(120, 845)])
        XCTAssertEqual(IPhoneAction.parse("<think>t</think><action>LaunchApp(app='小红书')").text, "小红书")
    }
}
