// SPDX-License-Identifier: MIT
import XCTest
import Foundation
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
