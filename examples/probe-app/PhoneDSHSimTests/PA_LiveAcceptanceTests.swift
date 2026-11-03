// SPDX-License-Identifier: MIT

@testable import PhoneDSHProbe
@testable import ProbeKit
import XCTest

final class PA_LiveAcceptanceTests: XCTestCase {
    @MainActor
    func testConfiguredNativeMainAnswersAConciseQuestion() async throws {
        try requireLiveAcceptance()
        let composition = AppComposition.shared
        composition.refreshModelConfiguration()
        guard composition.personalModel.isModelConfigured else {
            throw XCTSkip("请先在个人 → 模型服务中保存支持 Anthropic Messages 的模型与 Keychain 凭据")
        }
        let model = composition.personalModel
        await model.load()
        await model.send("只回答两个字：你好")
        XCTAssertNil(model.failureNotice)
        let answer = try XCTUnwrap(model.messages.last(where: { $0.role == .assistant }))
        XCTAssertFalse(answer.text.isEmpty)
        XCTAssertFalse(answer.text.contains("thinking"))
        XCTAssertFalse(answer.text.contains("```bash"))
        XCTAssertFalse(answer.text.contains("TaskRun"))
    }

    @MainActor
    func testConfiguredGitHubReadsThroughSharedConnector() async throws {
        try requireLiveAcceptance()
        let composition = AppComposition.shared
        guard await composition.registry.state(of: "github").state == .connected,
              let grant = await composition.registry.grant(of: "github"),
              let repository = grant.scope.repositories.first else {
            throw XCTSkip("请先在发现 → GitHub 中保存 PAT 并授权一个测试仓库")
        }
        let mandate = WorkMandate(mandateID: UUID(), version: 1, requestID: UUID(),
                                  principal: composition.personalModel.principal, source: .phone,
                                  goal: "读取已授权仓库", allowedActions: [.read], allowedEvidenceRefs: [],
                                  targets: MandateTargets(repository: repository, origin: .userNamed),
                                  validUntil: Date().addingTimeInterval(300))
        let result = await composition.githubBridge.invoke(
            "github.repository.get", argumentsJSON: #"{"repository":"\#(repository)"}"#,
            caller: .personalAgent(mandate: mandate))
        XCTAssertFalse(result.isError, result.contentJSON)
        XCTAssertTrue(result.contentJSON.contains(repository))
    }

    private func requireLiveAcceptance() throws {
        guard ProcessInfo.processInfo.environment["PDSH_RUN_LIVE_ACCEPTANCE"] == "1" else {
            throw XCTSkip("真实外部服务验收默认关闭；设置 PDSH_RUN_LIVE_ACCEPTANCE=1 后运行")
        }
    }
}
