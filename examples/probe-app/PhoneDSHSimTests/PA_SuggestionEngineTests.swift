// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import ProbeKit

final class PA_SuggestionEngineTests: XCTestCase {
    func testGenerationRequestIncludesTurnAnswerRecentContextAndTaskState() async throws {
        let transport = PA_RuntimeScriptedTransport(replies: [
            pa_runtimeTextResponse("A. 检查未解决的审批\nB. 查看后续任务"),
        ])
        let snapshot = MainConversationSnapshot(
            currentText: "",
            mandate: pa_runtimeMandate(),
            pendingQuestions: [PendingQuestion(text: "是否继续发布？", choices: ["继续", "暂停"])],
            messages: [
                MainConversationMessage(sequence: 1, role: .user, text: "上一轮调查构建失败"),
                MainConversationMessage(sequence: 2, role: .assistant, text: "已定位到签名配置"),
            ],
            rollingSummary: MainConversationSummary(coveredRange: 0...0, revision: 1,
                                                    sourceCursor: "2", text: "项目正在准备发布"),
            userConstraints: ["不要直接推送"],
            currentArtifacts: [MainArtifactContext(id: "build", title: "构建报告", locator: "artifact://build")],
            pendingReconciliations: ["发布结果尚未对账"])
        let generator = NativeSuggestionGenerator(
            clientResolver: PA_RuntimeFixedResolver(transport: transport),
            contextProvider: MainStaticContextProvider(base: snapshot))
        let turn = pa_runtimeTurn(mandate: nil, text: "本轮请整理发布步骤")

        let options = try await generator.generate(turn: turn, answer: AssistantMessage(text: "已整理好三个步骤"))

        XCTAssertEqual(options, ["检查未解决的审批", "查看后续任务"])
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.model, "test-model")
        XCTAssertEqual(request.maxTokens, 256)
        XCTAssertTrue(request.tools.isEmpty)
        XCTAssertTrue(request.system.contains("Return NONE or an empty response"))
        XCTAssertTrue(request.system.contains("do not provide them merely to fill a card"))
        XCTAssertEqual(request.messages.count, 1)
        guard case .text(let prompt) = request.messages[0].content.first else {
            return XCTFail("expected one text prompt")
        }
        for expected in [
            "本轮请整理发布步骤", "已整理好三个步骤", "上一轮调查构建失败", "已定位到签名配置",
            "项目正在准备发布", "inspect the current task", "是否继续发布？", "发布结果尚未对账",
            "构建报告", "不要直接推送",
        ] {
            XCTAssertTrue(prompt.contains(expected), "request is missing context: \(expected)")
        }
    }

    func testParsesLetteredAndNumberedOptions() async throws {
        let transport = PA_RuntimeScriptedTransport(replies: [
            pa_runtimeTextResponse("A. 查看差异\nB) 运行测试\nC: 创建草稿"),
            pa_runtimeTextResponse("1. 查看差异\n2) 运行测试\n3、创建草稿"),
        ])
        let generator = NativeSuggestionGenerator(
            clientResolver: PA_RuntimeFixedResolver(transport: transport))
        let turn = pa_runtimeTurn(mandate: nil)
        let answer = AssistantMessage(text: "完成")

        let lettered = try await generator.generate(turn: turn, answer: answer)
        let numbered = try await generator.generate(turn: turn, answer: answer)

        XCTAssertEqual(lettered, ["查看差异", "运行测试", "创建草稿"])
        XCTAssertEqual(numbered, lettered)
    }

    func testMalformedOrFailedGenerationReturnsEmptyWithoutFixedFallback() async throws {
        let malformed = PA_RuntimeScriptedTransport(replies: [
            pa_runtimeTextResponse("这里有一些建议：\nA. 查看差异"),
            pa_runtimeTextResponse("A. 一\nB. 二\nC. 三\nD. 四"),
            PA_RuntimeTransportReply(events: [], error: MainFailure.provider("offline")),
        ])
        let generator = NativeSuggestionGenerator(
            clientResolver: PA_RuntimeFixedResolver(transport: malformed))
        let turn = pa_runtimeTurn(mandate: nil)
        let answer = AssistantMessage(text: "完成")

        for _ in 0..<3 {
            let options = try await generator.generate(turn: turn, answer: answer)
            XCTAssertTrue(options.isEmpty)
            XCTAssertNotEqual(options, ["继续", "重试", "查看详情"])
        }

        let failing = NativeSuggestionGenerator(
            clientResolver: PA_RuntimeFailingResolver(failure: .notConfigured))
        let unresolved = try await failing.generate(turn: turn, answer: answer)
        XCTAssertTrue(unresolved.isEmpty)
    }

    func testExplicitNoSuggestionAndEmptyOutputStayEmpty() async throws {
        let transport = PA_RuntimeScriptedTransport(replies: [
            pa_runtimeTextResponse("NONE"),
            pa_runtimeTextResponse("无建议"),
            PA_RuntimeTransportReply(events: [
                .messageStart,
                .messageDelta(stopReason: "end_turn"),
                .messageStop,
            ]),
        ])
        let generator = NativeSuggestionGenerator(
            clientResolver: PA_RuntimeFixedResolver(transport: transport))
        let turn = pa_runtimeTurn(mandate: nil, text: "谢谢")
        let answer = AssistantMessage(text: "不客气")

        for _ in 0..<3 {
            let options = try await generator.generate(turn: turn, answer: answer)
            XCTAssertTrue(options.isEmpty)
        }
    }

    func testNoValueTurnDoesNotInventSuggestions() async throws {
        let transport = PA_RuntimeScriptedTransport(replies: [pa_runtimeTextResponse("NONE")])
        let generator = NativeSuggestionGenerator(
            clientResolver: PA_RuntimeFixedResolver(transport: transport),
            contextProvider: MainStaticContextProvider(base: MainConversationSnapshot(
                currentText: "", messages: [
                    MainConversationMessage(sequence: 1, role: .user, text: "今天的日期是什么？"),
                    MainConversationMessage(sequence: 2, role: .assistant, text: "已经回答日期"),
                ])))

        let options = try await generator.generate(
            turn: pa_runtimeTurn(mandate: nil, text: "明白了"),
            answer: AssistantMessage(text: "好的，问题已解决。"))

        XCTAssertEqual(options, [])
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testDismissedSuggestionDoesNotReturnAfterStoreReopens() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let turnID = UUID()
        let store = SuggestionStore(rootDirectory: root)
        try await store.save(turnID: turnID, options: ["查看报告"])
        try await store.dismiss(turnID: turnID)

        let reopened = SuggestionStore(rootDirectory: root)
        let options = await reopened.options(for: turnID)
        let dismissed = await reopened.isDismissed(turnID: turnID)
        XCTAssertNil(options)
        XCTAssertTrue(dismissed)

        try await reopened.save(turnID: turnID, options: ["迟到的生成结果"])
        let afterLateSave = await reopened.options(for: turnID)
        XCTAssertNil(afterLateSave)
    }

    func testStoreRestoresSavedOptionsFromFile() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstTurn = UUID()
        let emptyTurn = UUID()
        let store = SuggestionStore(rootDirectory: root)
        try await store.save(turnID: firstTurn, options: ["检查 PR", "起草回复"])
        try await store.save(turnID: emptyTurn, options: [])

        let reopened = SuggestionStore(rootDirectory: root)
        let firstOptions = await reopened.options(for: firstTurn)
        let emptyOptions = await reopened.options(for: emptyTurn)
        let missingOptions = await reopened.options(for: UUID())
        let dismissed = await reopened.isDismissed(turnID: firstTurn)
        XCTAssertEqual(firstOptions, ["检查 PR", "起草回复"])
        XCTAssertEqual(emptyOptions, [])
        XCTAssertNil(missingOptions)
        XCTAssertFalse(dismissed)
    }

    func testStoreWriteFailureThrowsWithoutUpdatingMemory() async throws {
        let parent = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("not-a-directory")
        try Data("file".utf8).write(to: root)
        let store = SuggestionStore(rootDirectory: root)
        let turnID = UUID()

        do {
            try await store.save(turnID: turnID, options: ["不会保存"])
            XCTFail("expected the file write to fail")
        } catch {}
        let options = await store.options(for: turnID)
        XCTAssertNil(options)

        do {
            try await store.dismiss(turnID: turnID)
            XCTFail("expected the file write to fail")
        } catch {}
        let dismissed = await store.isDismissed(turnID: turnID)
        XCTAssertFalse(dismissed)
    }

    private func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PA_SuggestionEngineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
