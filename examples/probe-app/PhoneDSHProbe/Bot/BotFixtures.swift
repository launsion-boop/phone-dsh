// SPDX-License-Identifier: MIT

#if DEBUG
import Foundation
import PhoneDSHAgentCore
import PhoneDSHBot
import SwiftUI

enum BotUIFixtureCase: String, CaseIterable, Identifiable {
    case chat, question, steps, task, attachment, document, progress, checklist, link
    case approval, automation, error, denial, overflow, failClosed
    case empty, runningThinking, runningTool
    case composerAttachments, infoAppearance
    case info, infoEmpty, infoError, infoLong

    var id: String { rawValue }

    static let p0Cards: [BotUIFixtureCase] = [
        .question, .steps, .task, .attachment, .document, .progress,
        .checklist, .link, .approval, .automation, .error, .denial,
    ]
}

enum BotUIFixtures {
    static func widget(_ type: String, _ values: [String: BotJSONValue]) -> BotUIBody {
        var stored = values
        stored["cardType"] = .string(type)
        return BotUIBody(type: "widget", values: stored)
    }

    static func cardRow(_ id: String, body: BotUIBody, seq: Int = 2) -> BotUIRow {
        BotUIRow.fixture(id: id, seq: seq, body: body)
    }

    /// One DSH session event shaped exactly like the live frames the runtime
    /// forwards, so the fixture drives the same presentation factory.
    static func liveEvent(_ type: String, turn: Int, seq: Int,
                          data: [String: JSONValue] = [:]) -> JSONValue {
        var values: [String: JSONValue] = ["turn": .number(Double(turn))]
        for (key, value) in data { values[key] = value }
        return .object([
            "type": .string(type),
            "seq": .number(Double(seq)),
            "time": .number(Date().timeIntervalSince1970 * 1_000),
            "data": .object(values),
        ])
    }

    static func rows(for fixture: BotUIFixtureCase) -> [BotUIRow] {
        let intro = BotUIRow.text(id: "intro-\(fixture.rawValue)", seq: 1, role: "assistant",
                                  text: "Fixture：\(fixture.rawValue)")
        let body: BotUIBody
        switch fixture {
        case .question:
            body = widget("question", [
                "question": "要把这份整理好的内容保存到哪里？",
                "helpText": "推荐保存到文档库，之后可以继续编辑。",
                "options": [
                    ["id": "library", "label": "保存到文档库", "description": "保留版本并方便之后查找", "recommended": true],
                    ["id": "pdf", "label": "导出 PDF", "description": "生成适合分享的固定版面"],
                    ["id": "later", "label": "稍后决定"],
                ],
            ])
        case .steps:
            body = widget("steps", [
                "helpText": "选择下一步继续；自由输入请用下方输入框发普通消息。",
                "steps": [
                    ["id": "review", "label": "查看验收结果", "description": "先确认测试和截图证据", "recommended": true],
                    ["id": "pr", "label": "创建 Pull Request"],
                    ["id": "pause", "label": "暂停，稍后继续", "style": "default"],
                ],
            ])
        case .task:
            body = widget("task", [
                "title": "整理并验证发布材料",
                "status": "running",
                "tasks": [
                    ["id": "source", "label": "收集来源", "state": "done"],
                    ["id": "verify", "label": "运行验证", "state": "active"],
                    ["id": "report", "label": "生成报告", "state": "pending"],
                ],
            ])
        case .attachment:
            body = BotUIBody(type: "attachment", values: [
                "cardType": "attachment", "path": "/tmp/phone-dsh-report.pdf",
                "fileName": "phone-dsh-report.pdf", "caption": "验收报告 · 128 kB", "mimeType": "application/pdf",
            ])
        case .document:
            body = widget("document", [
                "title": "phoneDSH Bot 验收报告",
                "summary": "汇总交互、卡片和两种外观的模拟器证据。",
                "docKind": "markdown", "docTypeLabel": "Markdown",
                "fileName": "acceptance.md", "size": "18 kB",
                "content": "# phoneDSH Bot 验收报告\n\n## 交互\n\nSteering、停止和迟到输出。\n\n## 卡片\n\n所有 P0 卡片。",
                "toc": ["交互", "卡片", "剩余风险"],
            ])
        case .progress:
            body = widget("progress", [
                "title": "生成发布验收材料", "state": "running", "percent": 42,
                "summary": "已完成数据核对，正在生成两种外观的截图。", "eta": "约 2 分钟", "cardKey": "fixture-progress",
                "steps": [
                    ["id": "p0", "label": "读取契约与共享向量", "state": "done", "detail": "完成"],
                    ["id": "p1", "label": "编译并运行模拟器", "state": "active", "detail": "12/24"],
                    ["id": "p2", "label": "检查长文本与动态字体", "state": "pending"],
                    ["id": "p3", "label": "汇总剩余风险", "state": "pending"],
                    ["id": "p4", "label": "创建 PR", "state": "pending"],
                ],
            ])
        case .checklist:
            body = widget("checklist", [
                "title": "发布前检查", "summary": "本地勾选不会改写卡片；可手动把结果送回对话。",
                "items": [
                    ["id": "c0", "text": "运行指定 CI 门禁", "done": true],
                    ["id": "c1", "text": "检查浅色与深色截图", "done": true],
                    ["id": "c2", "text": "验证重复点击和迟到结果", "note": "今天"],
                    ["id": "c3", "text": "记录未验证项目", "note": "必填"],
                ],
            ])
        case .link:
            body = widget("link", [
                "title": "参考资料",
                "links": [
                    ["id": "docs", "url": "https://example.test/docs/cards", "title": "卡片内容模型",
                     "site": "example.test", "description": "字段、空状态和超限规则。", "kind": "doc"],
                    ["id": "pr", "url": "https://example.test/repo/pull/9", "title": "WP9 SwiftUI 交互层",
                     "site": "example.test", "kind": "repo"],
                ],
            ])
        case .approval:
            body = BotUIBody(type: "approval", values: [
                "approvalID": "approval-fixture", "digest": "sha256:fixture", "status": "pending",
                "title": "允许执行这个操作吗？", "action": "删除旧的临时报告",
                "command": "rm -f /tmp/phone-dsh-old-report.pdf",
                "detail": "文件位于临时目录，删除后无法在页面内恢复。",
                "alwaysScope": "until", "risk": ["level": "high", "tags": ["irreversible"]],
            ])
        case .automation:
            body = BotUIBody(type: "automation", values: [
                "title": "晨间简报", "status": "sent", "schedule": "每天 07:30 · Asia/Shanghai",
                "context": "held · 非紧急", "result": "已整理 3 项需要你处理的工作。", "durationMs": 1_240,
            ])
        case .error:
            body = BotUIBody(type: "notice", values: ["tone": "error", "text": "生成报告失败：模拟器暂时不可用。"])
        case .denial:
            body = BotUIBody(type: "notice", values: ["tone": "denied", "text": "已拒绝这次操作，未执行任何更改。"])
        case .overflow:
            return [intro, cardRow("overflow-progress", body: widget("progress", [
                "title": "这是一个故意很长的工作标题，用来验证窄屏和动态字体下标题不会挤压状态或破坏卡片布局",
                "state": "running", "percent": 68,
                "summary": .string(String(repeating: "长摘要需要限制在两行以内，不能让整页失去阅读节奏。", count: 8)),
                "steps": .array((0..<8).map { index in
                    .object([
                        "id": .string("step-\(index)"),
                        "label": .string("第 \(index + 1) 步：\(String(repeating: "检查长步骤布局", count: 3))"),
                        "state": .string(index < 4 ? "done" : index == 4 ? "active" : "pending"),
                        "detail": .string("\(index + 1)/8"),
                    ])
                }),
            ]), seq: 2), cardRow("overflow-approval", body: BotUIBody(type: "approval", values: [
                "approvalID": "approval-overflow", "digest": "sha256:overflow", "status": "pending",
                "action": "执行多行命令",
                "command": .string((1...12).map { "echo line-\($0)" }.joined(separator: "\n")),
                "alwaysScope": "none",
            ]), seq: 3)]
        case .failClosed:
            return [
                cardRow("p1-table", body: widget("table", ["columns": [], "rows": []]), seq: 2),
                cardRow("p1-callout", body: widget("callout", ["body": "不应显示"]), seq: 3),
                cardRow("p1-info", body: widget("info", ["label": "不应显示", "value": "不应显示"]), seq: 4),
                cardRow("p1-payload", body: widget("payload", ["payloads": []]), seq: 5),
                cardRow("p1-library", body: widget("library", ["title": "不应显示"]), seq: 6),
                cardRow("unknown", body: widget("unknown", ["title": "不应显示"]), seq: 7),
                cardRow("empty-progress", body: widget("progress", ["state": "running"]), seq: 8),
            ]
        case .empty:
            return []
        case .runningThinking, .runningTool:
            return [BotUIRow.text(id: "\(fixture.rawValue)-user", seq: 1, role: "user",
                                  text: "帮我检查一下构建结果。")]
        case .chat:
            return [
                BotUIRow.text(id: "chat-user", seq: 1, role: "user", text: "继续整理发布材料，有审批时先告诉我。"),
                BotUIRow.text(id: "chat-assistant", seq: 2, role: "assistant", text: "好的。我会保留当前对话，发送的新消息会 steering 到正在运行的回合。"),
            ]
        case .composerAttachments:
            var user = BotUIRow.fixture(
                id: "attachments-user", seq: 1, kind: "sendMessage", role: "user",
                body: BotUIBody(type: "text", values: [
                    "text": "帮我看看这两个文件，顺便整理成一页摘要。",
                    "attachments": .array([
                        BotUIAttachment.fixture(name: "周报.pdf", size: 2048,
                                                mimeType: "application/pdf", kind: "pdf").jsonValue,
                        BotUIAttachment.fixture(name: "photo.jpg", size: 1_234_567,
                                                mimeType: "image/jpeg", kind: "image").jsonValue,
                    ]),
                ]))
            user.provenance.trust = "owner_direct"
            return [
                user,
                BotUIRow.text(id: "attachments-assistant", seq: 2, role: "assistant",
                              text: "收到。我会先读 PDF，再看图片，然后把要点整理成一页摘要。"),
            ]
        case .infoAppearance, .info, .infoEmpty, .infoError, .infoLong:
            return []
        }
        return [intro, cardRow("card-\(fixture.rawValue)", body: body)]
    }

    static var composerAttachments: [BotDraftAttachment] {
        [
            .fixture(name: "设计稿.png", size: 842_000, mimeType: "image/png", kind: "image"),
            .fixture(name: "验收记录.pdf", size: 12_400, mimeType: "application/pdf", kind: "pdf"),
            .fixture(name: "release-notes.md", size: 3_100, mimeType: "text/markdown", kind: "markdown"),
        ]
    }

    static func appearance(for fixture: BotUIFixtureCase) -> BotFishAppearance {
        guard fixture == .infoAppearance else { return .classic }
        var value = BotFishAppearance.classic
        value.color = .purple
        value.hairstyle = .twinTail
        value.autoColor = false
        value.autoHairstyle = false
        return value
    }

    static func infoSnapshot(for fixture: BotUIFixtureCase = .info) -> BotInfoSnapshot {
        if fixture == .infoLong {
            return BotInfoSnapshot(botName: "大肥鱼 · 一个用于验证长名称的 Bot", memories: [
                BotMemoryFact(id: "long-memory", text: String(repeating: "用户希望所有验收报告都包含实际执行的命令、结果、未验证项和剩余风险；", count: 8),
                              tier: "profile", scope: "agent", source: "user-turn", learnedAt: Date(timeIntervalSince1970: 1_760_000_000)),
            ], routines: [
                BotRoutineInfo(id: "long-routine", title: String(repeating: "很长的例行任务名称", count: 5),
                               schedule: "每周一至周五 07:30", timeZone: "Asia/Shanghai", delivery: "interrupt",
                               quiet: true, urgent: true, urgentReason: "发布窗口有明确截止时间",
                               lastResult: String(repeating: "运行结果很长，需要自然换行，同时不能暴露后台 session 的过程。", count: 6), enabled: true),
            ], approvals: [
                BotApprovalRecord(id: "long-approval", parameterSummary: String(repeating: "只显示参数摘要，不显示完整敏感参数；", count: 8),
                                  decision: "允许一次", decidedAt: Date(timeIntervalSince1970: 1_760_000_100)),
            ])
        }
        return BotInfoSnapshot(botName: "大肥鱼", memories: [
            BotMemoryFact(id: "memory-1", text: "验收报告必须区分模拟器与真机证据。", tier: "profile", scope: "agent",
                          source: "user-turn", learnedAt: Date(timeIntervalSince1970: 1_760_000_000)),
            BotMemoryFact(id: "memory-2", text: "默认使用中文。", tier: "log", scope: "user",
                          source: "user-turn", learnedAt: Date(timeIntervalSince1970: 1_760_000_050)),
        ], routines: [
            BotRoutineInfo(id: "routine-1", title: "晨间简报", schedule: "每天 07:30", timeZone: "Asia/Shanghai",
                           delivery: "held", quiet: true, urgent: false, urgentReason: nil,
                           lastResult: "上次完成：整理了 3 项待处理工作。", enabled: true),
            BotRoutineInfo(id: "routine-2", title: "发布窗口检查", schedule: "每周五 16:00", timeZone: "Asia/Shanghai",
                           delivery: "interrupt", quiet: false, urgent: true, urgentReason: "发布截止",
                           lastResult: "上次完成：没有新阻塞。", enabled: false),
        ], approvals: [
            BotApprovalRecord(id: "record-1", parameterSummary: "删除 /tmp 中的旧验收报告（参数摘要）",
                              decision: "拒绝", decidedAt: Date(timeIntervalSince1970: 1_760_000_100)),
            BotApprovalRecord(id: "record-2", parameterSummary: "创建本周发布报告（参数摘要）",
                              decision: "允许一次", decidedAt: Date(timeIntervalSince1970: 1_760_000_200)),
        ])
    }
}

struct BotUIFixtureRootView: View {
    let fixture: BotUIFixtureCase
    let diagnostics: Bool
    @StateObject private var chatModel: BotChatModel
    @StateObject private var infoModel: BotInfoModel
    @State private var showInfo = false
    @State private var infoSection: BotInfoSection?
    @State private var hostActions: [String] = []

    init(fixture: BotUIFixtureCase, diagnostics: Bool = false) {
        self.fixture = fixture
        self.diagnostics = diagnostics
        let chat = BotChatModel(
            rows: BotUIFixtures.rows(for: fixture),
            fixtureHistory: fixture == .failClosed || fixture == .empty
                ? [] : [BotUIRow.text(id: "older-fixture", seq: 0, role: "assistant", text: "更早的历史消息")],
            fixtureActions: true
        )
        switch fixture {
        case .runningThinking:
            chat.receive(.event(BotUIFixtures.liveEvent("turn/start", turn: 1, seq: 1)))
        case .runningTool:
            chat.receive(.event(BotUIFixtures.liveEvent("turn/start", turn: 1, seq: 1)))
            chat.receive(.event(BotUIFixtures.liveEvent("tool/call", turn: 1, seq: 2, data: [
                "callId": .string("fixture-call"),
                "name": .string("bash"),
                "arguments": .string("{\"command\":\"xcodebuild build\",\"description\":\"运行构建\"}"),
            ])))
        default:
            break
        }
        _chatModel = StateObject(wrappedValue: chat)
        _infoModel = StateObject(wrappedValue: BotInfoModel(
            snapshot: fixture == .infoEmpty ? BotInfoSnapshot(botName: "大肥鱼", memories: [], routines: [], approvals: [])
                : BotUIFixtures.infoSnapshot(for: fixture),
            fixtureError: fixture == .infoError ? "fixture.read_failed" : nil,
            appearance: BotUIFixtures.appearance(for: fixture)
        ))
    }

    var body: some View {
        Group {
            switch fixture {
            case .infoAppearance, .info, .infoEmpty, .infoError, .infoLong:
                BotInfoPage(model: infoModel)
            default:
                VStack(spacing: 0) {
                    BotChatPage(model: chatModel, cardActions: cardActions,
                                onOpenInfo: {
                                    infoSection = nil
                                    showInfo = true
                                },
                                onOpenInfoSection: { section in
                                    infoSection = section
                                    showInfo = true
                                },
                                initialAttachments: fixture == .composerAttachments
                                    ? BotUIFixtures.composerAttachments : [],
                                initialAttachmentNotice: fixture == .composerAttachments
                                    ? "附件「录屏.mov」未附加：文件超过 25 MiB（48.2 MB）。" : nil)
                    if diagnostics {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("actions=\(chatModel.actionLog.joined(separator: ","));host=\(hostActions.joined(separator: ","))")
                                .accessibilityIdentifier("bot.fixture.actions")
                            Text("running=\(chatModel.runningTurnID ?? "none");stream=\(chatModel.streamingText ?? "none")")
                                .accessibilityIdentifier("bot.fixture.runtime")
                            Text("visible=\(chatModel.visibleRows.count);attention=\(chatModel.needsAttentionCount)")
                                .accessibilityIdentifier("bot.fixture.visible")
                            Text("fish=\(chatModel.fishState.rawValue);activity=\(chatModel.activity?.status.rawValue ?? "none");detail=\(chatModel.activity?.detail ?? "")")
                                .accessibilityIdentifier("bot.fixture.presentation")
                        }
                        .font(.system(size: 10, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                        .background(HomeSpec.surface)
                    }
                }
                .sheet(isPresented: $showInfo) {
                    BotInfoPage(model: infoModel, initialSection: infoSection)
                        .id(infoSection)
                }
            }
        }
    }

    private var cardActions: BotCardActions {
        BotCardActions(openURL: { hostActions.append("url:\($0.absoluteString)") },
                       openPath: { hostActions.append("path:\($0)") })
    }
}

enum BotUIFixtureCheckError: Error, CustomStringConvertible {
    case failed(String)
    var description: String {
        if case .failed(let message) = self { return message }
        return "Unknown fixture check failure"
    }
}

@MainActor
enum BotUIFixtureChecks {
    static func run(cardPayloadURL: URL, rowProtocolURL: URL) async throws -> [String] {
        var passed: [String] = []
        try checkGoldenCards(at: cardPayloadURL)
        passed.append("shared-card-payload-decoding")
        try checkRowProtocol(at: rowProtocolURL)
        passed.append("shared-row-protocol-decoding")

        let model = BotChatModel(rows: BotUIFixtures.rows(for: .progress), fixtureActions: true)
        var updated = BotUIFixtures.rows(for: .progress)[1]
        updated.id = "progress-updated"
        updated.seq = 3
        updated.updatedSeq = 3
        updated.body.values["percent"] = 100
        model.upsert(updated)
        try require(model.visibleRows.filter { $0.body.cardType == "progress" }.count == 1,
                    "progress cardKey appended a second row")
        passed.append("progress-cardKey-in-place")

        model.beginTurn(turnID: "cancel-check")
        model.receiveStream(turnID: "cancel-check", text: "early")
        model.stop()
        model.receiveStream(turnID: "cancel-check", text: "late", final: true)
        try require(model.streamingText == nil && !model.visibleRows.contains { $0.body["text"]?.string == "late" },
                    "late stream survived cancellation")
        passed.append("stop-drops-late-output")

        let streamModel = BotChatModel(fixtureActions: true)
        streamModel.beginTurn(turnID: "rate-check")
        for index in 0..<20 {
            streamModel.receiveStream(turnID: "rate-check", text: "delta-\(index)")
        }
        try await Task.sleep(nanoseconds: 350_000_000)
        let deliveries = streamModel.actionLog.filter { $0 == "stream" }.count
        try require((1...4).contains(deliveries), "stream delivered \(deliveries) frames in 350ms")
        try require(streamModel.streamingText == "delta-19", "stream did not retain latest text")
        streamModel.stop()
        passed.append("stream-max-10hz-latest-wins")

        let deepLinkModel = BotChatModel(rows: BotUIFixtures.rows(for: .question), fixtureActions: true)
        let good = URL(string: "phonedsh://bot/main/row/card-question")!
        let bad = URL(string: "phonedsh://bot/main/row/missing")!
        try require(deepLinkModel.openDeepLink(good) && !deepLinkModel.openDeepLink(bad),
                    "deep link did not resolve exactly")
        passed.append("deep-link-exact-row")

        let hidden = BotChatModel(rows: BotUIFixtures.rows(for: .failClosed), fixtureActions: true)
        try require(hidden.visibleRows.isEmpty, "P1/unknown/incomplete row rendered")
        passed.append("fail-closed-P1-unknown-incomplete")

        let attachmentOnly = BotUIRow.fixture(
            id: "attachment-only", kind: "sendMessage", role: "user",
            body: BotUIBody(type: "text", values: [
                "text": "",
                "attachments": .array([
                    BotUIAttachment.fixture(name: "a.pdf", size: 2048,
                                            mimeType: "application/pdf", kind: "pdf").jsonValue,
                ]),
            ]))
        try require(BotUIRendering.isRenderable(attachmentOnly),
                    "attachment-only user row was hidden")
        try require(BotUIAttachment.parseList(attachmentOnly.body["attachments"]).count == 1,
                    "attachment metadata did not decode")
        passed.append("user-row-attachment-only")

        let incomplete: [(String, BotUIBody)] = [
            ("question", BotUIFixtures.widget("question", [:])),
            ("steps", BotUIFixtures.widget("steps", [:])),
            ("task", BotUIFixtures.widget("task", ["status": "running"])),
            ("attachment", BotUIBody(type: "attachment", values: ["caption": "无文件"])),
            ("document", BotUIFixtures.widget("document", ["docKind": "markdown"])),
            ("progress", BotUIFixtures.widget("progress", ["state": "running"])),
            ("checklist", BotUIFixtures.widget("checklist", ["title": "空清单", "items": []])),
            ("link", BotUIFixtures.widget("link", ["links": [["url": "javascript:alert(1)"]]])),
            ("approval", BotUIBody(type: "approval", values: ["approvalID": "a1", "action": "执行", "status": "pending"])),
            ("automation", BotUIBody(type: "automation", values: ["status": "sent"])),
            ("notice", BotUIBody(type: "notice", values: ["tone": "error", "text": ""])),
        ]
        for (name, body) in incomplete {
            let row = BotUIRow.fixture(id: "invalid-\(name)", body: body)
            try require(!BotUIRendering.isRenderable(row), "incomplete P0 \(name) rendered")
        }
        passed.append("fail-closed-every-P0")
        return passed
    }

    private static func checkGoldenCards(at url: URL) throws {
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let vectors = root?["valid"] as? [[String: Any]] ?? []
        try require(!vectors.isEmpty, "card-payload golden is empty")
        for vector in vectors {
            guard let result = vector["result"] as? [String: Any], result["ok"] as? Bool == true,
                  var card = result["card"] as? [String: Any],
                  let cardType = card["cardType"] as? String else { continue }
            card["type"] = cardType == "attachment" ? "attachment" : "widget"
            let data = try JSONSerialization.data(withJSONObject: card)
            let body = try JSONDecoder().decode(BotUIBody.self, from: data)
            let row = BotUIRow.fixture(id: "golden-\(cardType)", body: body)
            if ["table", "callout", "info", "payload", "library"].contains(cardType) {
                try require(!BotUIRendering.isRenderable(row), "P1 \(cardType) rendered")
            } else {
                try require(BotUIRendering.isRenderable(row), "P0 \(cardType) failed to render from shared golden")
            }
        }
    }

    private static func checkRowProtocol(at url: URL) throws {
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        guard let valid = root?["valid"] as? [String: Any] else {
            throw BotUIFixtureCheckError.failed("row-protocol valid fixture missing")
        }
        let rowData = try JSONSerialization.data(withJSONObject: valid["row"] as Any)
        let row = try JSONDecoder().decode(BotUIRow.self, from: rowData)
        try require(BotUIRendering.surface(row) == "bubble", "shared text row did not decode")
        let widgetData = try JSONSerialization.data(withJSONObject: valid["widgetRow"] as Any)
        let widget = try JSONDecoder().decode(BotUIRow.self, from: widgetData)
        try require(BotUIRendering.surface(widget) == "progress-card", "shared progress row did not decode")
        let actionData = try JSONSerialization.data(withJSONObject: valid["action"] as Any)
        let action = try JSONDecoder().decode(BotUIUserAction.self, from: actionData)
        let encoded = try JSONEncoder().encode(action)
        let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        try require(object?["kind"] as? String == "chat" && object?["text"] as? String == "继续",
                    "shared chat action did not round trip")
        let resultData = try JSONSerialization.data(withJSONObject: valid["result"] as Any)
        let result = try JSONDecoder().decode(BotUIActionResult.self, from: resultData)
        try require(result == .accepted(eventID: "evt-2"), "shared action result did not decode")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw BotUIFixtureCheckError.failed(message) }
    }
}

#Preview("Question") { BotUIFixtureRootView(fixture: .question) }
#Preview("Progress · Dark", traits: .fixedLayout(width: 390, height: 844)) {
    BotUIFixtureRootView(fixture: .progress).preferredColorScheme(.dark)
}
#Preview("Bot Info") { BotUIFixtureRootView(fixture: .info) }
#endif
