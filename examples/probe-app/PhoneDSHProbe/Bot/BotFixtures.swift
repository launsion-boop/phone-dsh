// SPDX-License-Identifier: MIT

#if DEBUG
import Foundation
import PhoneDSHAgentCore
import PhoneDSHBot
import SwiftUI

enum BotUIFixtureCase: String, CaseIterable, Identifiable {
    case chat, question, steps, task, attachment, document, progress, checklist, link
    case approval, automation, error, denial, overflow, failClosed
    case empty, runningThinking, runningTool, agentComm
    case drawer, drawerAdd, drawerManage, reactionLive, reactionHeader
    case composerAttachments, infoAppearance
    case info, infoEmpty, infoError, infoLong, infoGrants, infoRoutines, infoReconcile
    case infoPresence

    var id: String { rawValue }

    static let p0Cards: [BotUIFixtureCase] = [
        .question, .steps, .task, .attachment, .document, .progress,
        .checklist, .link, .approval, .automation, .error, .denial,
    ]
}

extension BotRuntimeContext {
    /// Fixture rows carry the historical record id `main`; it is a concrete id
    /// here, never a production routing default.
    static let fixture = BotRuntimeContext(botID: "main", botName: "大肥鱼")
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
        case .agentComm:
            let outbound = BotUIRow.fixture(
                id: "comm-outbound", seq: 2, kind: "sendMessage", role: "assistant",
                body: BotUIBody(type: "text", values: [
                    "text": "请把发布材料整理成一页。",
                    "agentComm": .object([
                        "direction": .string("outbound"),
                        "targetId": .string("agent-peer"),
                        "targetName": .string("小海"),
                        "message": .string("请把发布材料整理成一页。"),
                        "delivery": .string("now"),
                    ]),
                ]))
            let inbound = BotUIRow.fixture(
                id: "comm-inbound", seq: 3, kind: "message", role: "user",
                body: BotUIBody(type: "text", values: [
                    "text": "已整理好，附件在发布目录。",
                    "agentComm": .object([
                        "direction": .string("inbound"),
                        "fromAgentId": .string("agent-peer"),
                        "fromAgentName": .string("小海"),
                        "replyText": .string("已整理好，附件在发布目录。"),
                    ]),
                ]))
            return [
                BotUIRow.text(id: "comm-user", seq: 1, role: "user",
                              text: "让小海帮忙整理发布材料。"),
                outbound, inbound,
            ]
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
        case .infoAppearance, .info, .infoEmpty, .infoError, .infoLong,
             .infoGrants, .infoRoutines, .infoReconcile, .infoPresence:
            return []
        case .drawer, .drawerAdd, .drawerManage, .reactionLive, .reactionHeader:
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

    /// A visibly different peer identity for the agent-comm fixture, so the
    /// row avatar is proven to come from the other Bot's profile.
    static func peerAppearance(_ botID: String) -> BotFishAppearance? {
        guard botID == "agent-peer" else { return nil }
        var value = BotFishAppearance.classic
        value.color = .purple
        value.hairstyle = .twinTail
        value.autoColor = false
        value.autoHairstyle = false
        return value
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
        if fixture == .infoReconcile {
            let full = infoSnapshot(for: .info)
            return BotInfoSnapshot(
                botName: full.botName, memories: full.memories,
                routines: full.routines.filter { $0.id == "routine-2" },
                approvals: full.approvals, grants: full.grants,
                reconciliations: full.reconciliations)
        }
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
            ], presence: RoutinePresence(
                level: .scheduledNotification,
                deferred: [RoutinePresenceDelay(
                    routineId: "long-routine", title: String(repeating: "很长的例行任务名称", count: 3),
                    scheduledFor: 1_760_003_600_000, deferredUntil: 1_760_006_800_000)],
                scheduledNotificationCount: 2),
               proactiveSettings: ProactiveSettings(
                    mode: .on, dnd: false, quietStart: "23:00", quietEnd: "08:00",
                    timeZone: "Asia/Shanghai"))
        }
        return BotInfoSnapshot(botName: "大肥鱼", memories: [
            BotMemoryFact(id: "memory-1", text: "验收报告必须区分模拟器与真机证据。", tier: "profile", scope: "agent",
                          source: "user-turn", learnedAt: Date(timeIntervalSince1970: 1_760_000_000)),
            BotMemoryFact(id: "memory-2", text: "默认使用中文。", tier: "log", scope: "user",
                          source: "user-turn", learnedAt: Date(timeIntervalSince1970: 1_760_000_050)),
        ], routines: [
            BotRoutineInfo(id: "routine-1", title: "晨间简报", schedule: "每天 07:30", timeZone: "Asia/Shanghai",
                           delivery: "held", quiet: true, urgent: false, urgentReason: nil,
                           lastResult: "上次完成：整理了 3 项待处理工作。", enabled: true,
                           creator: "用户回合 · bot-fixture-1",
                           completionCriteria: "列出三项最重要的变化；没有变化时写「无变化」。",
                           routineConstraints: "不要调用 SendToUser；没有变化时回复 [quiet]。",
                           runStatus: "started", runID: "run-fixture-1"),
            BotRoutineInfo(id: "routine-2", title: "发布窗口检查", schedule: "每周五 16:00", timeZone: "Asia/Shanghai",
                           delivery: "interrupt", quiet: false, urgent: true, urgentReason: "发布截止",
                           lastResult: "上次执行结果未知：结果是已发送还是未发送无法确认。", enabled: false,
                           creator: "经用户确认 · routine:run-2",
                           completionCriteria: "确认发布窗口没有新的阻塞。",
                           routineConstraints: "只在发布窗口期间通知。",
                           runStatus: "needs-reconciliation", runID: "run-fixture-2"),
        ], approvals: [
            BotApprovalRecord(id: "record-1", parameterSummary: "删除 /tmp 中的旧验收报告（参数摘要）",
                              decision: "拒绝", decidedAt: Date(timeIntervalSince1970: 1_760_000_100)),
            BotApprovalRecord(id: "record-2", parameterSummary: "创建本周发布报告（参数摘要）",
                              decision: "允许一次", decidedAt: Date(timeIntervalSince1970: 1_760_000_200)),
        ], grants: [
            BotGrantInfo(id: "grant-1", tool: "write", operation: "write.file",
                         resource: "/dsh/workspace/.dshbot/agents/main/reports/**",
                         scope: "until", sessionID: "gb-main",
                         createdAt: Date(timeIntervalSince1970: 1_760_000_300), source: "approval-card"),
            BotGrantInfo(id: "grant-2", tool: "bash", operation: "network-egress",
                         resource: "curl https://api.example.test/*",
                         scope: "session", sessionID: "gb-main",
                         createdAt: Date(timeIntervalSince1970: 1_760_000_400), source: "approval-card"),
        ], reconciliations: [
            BotReconciliationInfo(
                routineID: "routine-2", routineTitle: "发布窗口检查", attempt: 3, runID: "run-fixture-2",
                error: "投递结果未知：连接在确认前中断",
                effectSummary: "routine.deliver · routine-2:3 · unknown-outcome"),
        ], presence: RoutinePresence(
            level: .scheduledNotification,
            deferred: [RoutinePresenceDelay(
                routineId: "routine-1", title: "晨间简报",
                scheduledFor: 1_760_018_400_000, deferredUntil: 1_760_021_600_000)],
            scheduledNotificationCount: 1),
           proactiveSettings: ProactiveSettings(
                mode: .on, dnd: false, quietStart: "23:00", quietEnd: "08:00",
                timeZone: "Asia/Shanghai"))
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
            context: .fixture,
            fixtureHistory: fixture == .failClosed || fixture == .empty
                ? [] : [BotUIRow.text(id: "older-fixture", seq: 0, role: "assistant", text: "更早的历史消息")],
            fixtureActions: true
        )
        switch fixture {
        case .infoPresence:
            break
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
            case .infoGrants:
                BotInfoPage(model: infoModel, initialSection: .grants)
            case .infoRoutines, .infoReconcile:
                BotInfoPage(model: infoModel, initialSection: .routines)
            case .infoPresence:
                NavigationStack {
                    List {
                        Section {
                            BotPresenceSection(model: infoModel)
                        } header: {
                            Text("在场")
                        } footer: {
                            Text("截图夹具只展示信息页的在场区，组件与真实页面相同。")
                        }
                        Section {
                            BotDisruptionSection(model: infoModel)
                        } header: {
                            Text("打扰")
                        } footer: {
                            Text("设置对所有 Bot 生效，改动立即持久化。")
                        }
                    }
                    .homeGroupedList()
                    .navigationTitle("Bot 信息")
                    .navigationBarTitleDisplayMode(.inline)
                }
            case .drawer, .drawerAdd, .drawerManage, .reactionLive, .reactionHeader:
                BotDrawerFixtureRootView(fixture: fixture)
            default:
                VStack(spacing: 0) {
                    BotChatPage(model: chatModel,
                                isMainBot: fixture == .chat || fixture == .empty
                                    || fixture == .agentComm || fixture == .reactionLive
                                    || fixture == .reactionHeader,
                                cardActions: cardActions,
                                onOpenInfo: {
                                    infoSection = nil
                                    showInfo = true
                                },
                                onOpenInfoSection: { section in
                                    infoSection = section
                                    showInfo = true
                                },
                                peerAppearance: BotUIFixtures.peerAppearance,
                                peerIsMainBot: { $0 == "main" },
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


/// Capture-only shell for the four drawer fixtures. It keeps the real
/// `BotChatPage` + `BotDrawerPanel` + `BotRosterModel` code and reproduces
/// only NativeShell's slide/scrim mechanics, which the capture target does
/// not link.
private struct BotDrawerFixtureRequest: Identifiable {
    let id = UUID()
    let botID: String
}

struct BotDrawerFixtureRootView: View {
    let fixture: BotUIFixtureCase

    @State private var roster: BotRosterModel?
    @State private var chatModels: [String: BotChatModel] = [:]
    @State private var drawerOpen: Bool
    @State private var dragOffset: CGFloat = 0
    @State private var showingManage: Bool
    @State private var appearanceRequest: BotDrawerFixtureRequest?
    @State private var setupError: String?
    @State private var loaded = false

    init(fixture: BotUIFixtureCase) {
        self.fixture = fixture
        _showingManage = State(initialValue: fixture == .drawerManage)
        _drawerOpen = State(initialValue: fixture != .reactionHeader)
    }

    var body: some View {
        GeometryReader { proxy in
            let insets = proxy.safeAreaInsets
            ZStack(alignment: .topLeading) {
                page(size: CGSize(width: proxy.size.width,
                                  height: max(0, proxy.size.height - insets.top - insets.bottom)))
                    .padding(.top, insets.top)
                    .padding(.bottom, insets.bottom)
                if drawerOpen {
                    Color.black
                        .opacity(0.28 * progress)
                        .contentShape(Rectangle())
                        .onTapGesture { close() }
                        .gesture(closeDrag)
                        .transition(.opacity)
                }
                BotDrawerPanel(
                    isOpen: Binding(get: { drawerOpen }, set: { drawerOpen = $0 }),
                    topInset: insets.top,
                    bottomInset: insets.bottom,
                    roster: roster,
                    error: setupError,
                    actions: actions,
                    initiallyShowingAdd: fixture == .drawerAdd)
                    .offset(x: drawerOpen ? min(0, dragOffset) : -(320 + 32))
                    .shadow(color: .black.opacity(drawerOpen ? 0.12 : 0), radius: 20, x: 6)
                    .simultaneousGesture(drawerOpen ? closeDrag : nil)
                    .allowsHitTesting(drawerOpen)
                    .accessibilityHidden(!drawerOpen)
            }
            .ignoresSafeArea()
        }
        .task { await setup() }
        .sheet(isPresented: $showingManage) {
            if let roster {
                BotManageList(roster: roster, actions: actions)
            } else {
                ProgressView("正在准备 Bot…")
                    .padding()
            }
        }
        .sheet(item: $appearanceRequest) { request in
            appearancePage(for: request.botID)
                .homeSheetChrome()
        }
    }

    @ViewBuilder
    private func page(size: CGSize) -> some View {
        if let roster, let selected = roster.selectedBotID,
           let model = chatModels[selected] {
            BotChatPage(
                model: model,
                isMainBot: selected == roster.mainBotID,
                onOpenInfo: {},
                onOpenInfoSection: { _ in },
                onSelectBot: { botID in
                    Task { await roster.select(botID) }
                },
                peerAppearance: { roster.appearance(for: $0) },
                peerIsMainBot: { $0 == roster.mainBotID },
                peerReaction: { roster.entry(for: $0)?.reaction },
                openDrawer: {
                    withAnimation(.easeInOut(duration: 0.28)) { drawerOpen = true }
                })
                .id(selected)
                .frame(width: size.width, height: size.height)
        } else {
            VStack(spacing: 12) {
                ProgressView()
                Text(setupError ?? "正在准备 Bot…")
                    .font(.system(size: 13))
                    .foregroundStyle(HomeSpec.textSecondary)
            }
            .frame(width: size.width, height: size.height)
            .background(HomeSpec.page)
        }
    }

    @ViewBuilder
    private func appearancePage(for botID: String) -> some View {
        if let roster, let profile = roster.profile(for: botID) {
            let model = BotInfoModel(
                snapshot: BotInfoSnapshot(botName: profile.name, memories: [], routines: [], approvals: []),
                appearance: BotFishAppearance.resolve(profile))
            BotInfoPage(model: model, isMainBot: profile.id == roster.mainBotID)
        } else {
            Text("这个 Bot 已经不存在。")
                .padding()
        }
    }

    private var actions: BotDrawerActions {
        guard let roster else { return BotDrawerActions() }
        var value = BotDrawerActions()
        value.select = { botID in
            Task { await roster.select(botID) }
        }
        value.create = { name, color, hairstyle in
            let created = try await roster.create(
                name: name, description: "", color: color, hairstyle: hairstyle)
            await MainActor.run {
                chatModels[created.id] = BotChatModel(
                    rows: [], context: BotRuntimeContext(botID: created.id, botName: created.name),
                    fixtureActions: true)
            }
            return created
        }
        value.rename = { botID, name in
            try await roster.rename(botID, to: name)
        }
        value.setMain = { botID in
            await roster.setMain(botID)
        }
        value.setHidden = { botID, hidden in
            await roster.setHidden(botID, hidden: hidden)
        }
        value.delete = { botID in
            _ = try await roster.deleteProfile(botID)
        }
        value.manage = { showingManage = true }
        value.appearance = { botID in
            if showingManage {
                showingManage = false
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    appearanceRequest = BotDrawerFixtureRequest(botID: botID)
                }
            } else {
                appearanceRequest = BotDrawerFixtureRequest(botID: botID)
            }
        }
        value.retry = { Task { await roster.refresh() } }
        value.close = {
            withAnimation(.easeInOut(duration: 0.22)) { drawerOpen = false }
        }
        return value
    }

    private var progress: CGFloat {
        guard drawerOpen else { return 0 }
        return max(0, 1 + dragOffset / 320)
    }

    private var closeDrag: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                dragOffset = min(0, value.translation.width)
            }
            .onEnded { value in
                let projected = value.predictedEndTranslation.width
                if value.translation.width < -160 || projected < -160 {
                    dragOffset = 0
                    withAnimation(.easeInOut(duration: 0.22)) { drawerOpen = false }
                } else {
                    withAnimation(.easeInOut(duration: 0.22)) { dragOffset = 0 }
                }
            }
    }

    private func close() {
        dragOffset = 0
        withAnimation(.easeInOut(duration: 0.22)) { drawerOpen = false }
    }

    @MainActor
    private func setup() async {
        guard !loaded else { return }
        loaded = true
        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("phone-dsh-bot-drawer-\(fixture.rawValue)", isDirectory: true)
            try? FileManager.default.removeItem(at: directory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let store = BotProfileStore(directory: directory)
            let now = Int64(Date().timeIntervalSince1970 * 1_000)

            let main = try await store.createBot(
                name: "大肥鱼", fishColor: .blue, fishHairstyle: .long,
                description: "手机上的主 Bot，负责跟进所有任务。")
            let second = try await store.createBot(
                name: "小海", fishColor: .purple, fishHairstyle: .twinTail,
                description: "整理发布材料，先跑完构建再交给我。")
            let third = try await store.createBot(
                name: "阿星", fishColor: .green, fishHairstyle: .bob,
                description: "负责检查截图和长文本。")
            try await store.incrementUnread(id: second.id, by: 3)
            try? await store.touch(id: second.id, at: now - 5 * 60 * 1_000)
            try await store.incrementUnread(id: third.id, by: 120)
            try? await store.touch(id: third.id, at: now - 2 * 3_600 * 1_000)

            var hidden: BotProfile?
            if fixture == .drawerManage || fixture == .drawerAdd {
                hidden = try await store.createBot(
                    name: "夜航", fishColor: .teal, fishHairstyle: .sideBraid,
                    description: "一个已经隐藏的 Bot，只在管理列表里出现。")
                if let hidden { try await store.setHidden(id: hidden.id, hidden: true) }
            }

            let snapshot = try await store.roster()
            let defaults = UserDefaults(suiteName: "phone.dsh.bot.drawer.fixture")!
            defaults.removeObject(forKey: BotSelectionDefaults.key)
            let roster = BotRosterModel(
                roster: snapshot, selectedBotID: main.id, store: store,
                selectionStore: BotSelectionStore(selected: main.id), defaults: defaults)
            roster.start()

            var models: [String: BotChatModel] = [:]
            for bot in snapshot.bots {
                let rows: [BotUIRow] = (fixture == .reactionLive || fixture == .reactionHeader) ? [] : [
                    BotUIRow.text(id: "drawer-user-\(bot.id)", botID: bot.id, seq: 1,
                                  role: "user", text: "把今天的发布材料整理一下。"),
                    BotUIRow.text(id: "drawer-assistant-\(bot.id)", botID: bot.id, seq: 2,
                                  role: "assistant", text: "好的，我会先核对构建结果，再整理成一页。"),
                ]
                let model = BotChatModel(
                    rows: rows,
                    context: BotRuntimeContext(botID: bot.id, botName: bot.name),
                    fixtureActions: true)
                model.setMainBot(bot.id == snapshot.mainBotID)
                models[bot.id] = model
            }

            if (fixture == .reactionLive || fixture == .reactionHeader), let model = models[main.id] {
                model.receive(.event(BotUIFixtures.liveEvent("turn/start", turn: 1, seq: 1)))
                model.receive(.event(BotUIFixtures.liveEvent("tool/call", turn: 1, seq: 2, data: [
                    "callId": .string("fixture-fish-action"),
                    "name": .string("FishAction"),
                    "arguments": .string("{\"action\":\"stretching\"}"),
                ])))
                roster.setRuntimeState(
                    BotRosterRuntimeState(
                        fishState: model.fishState, activity: model.activity,
                        isRunning: model.runningTurnID != nil,
                        pendingApprovalCount: model.pendingApprovalCount,
                        reaction: model.reaction),
                    for: main.id)
            } else {
                roster.setRuntimeState(
                    BotRosterRuntimeState(
                        fishState: .working,
                        activity: BotActivity(status: .toolRunning, detail: "执行指令 · xcodebuild build"),
                        isRunning: true),
                    for: main.id)
            }
            roster.setRuntimeState(BotRosterRuntimeState(fishState: .idle), for: second.id)
            roster.setRuntimeState(BotRosterRuntimeState(fishState: .idle), for: third.id)
            if let hidden {
                roster.setRuntimeState(BotRosterRuntimeState(fishState: .idle), for: hidden.id)
            }

            self.roster = roster
            self.chatModels = models
        } catch {
            setupError = "准备 fixture 失败：\(error.localizedDescription)"
        }
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
        // Let the first fixture render before the timing-sensitive stream
        // check. A cold simulator launch spends its first moments loading the
        // layered avatar, which used to leave too little of the coalescer's
        // delivery window for its task to run.
        try await Task.sleep(nanoseconds: 300_000_000)
        var passed: [String] = []
        try checkGoldenCards(at: cardPayloadURL)
        passed.append("shared-card-payload-decoding")
        try checkRowProtocol(at: rowProtocolURL)
        passed.append("shared-row-protocol-decoding")

        let model = BotChatModel(rows: BotUIFixtures.rows(for: .progress), context: .fixture, fixtureActions: true)
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

        let streamModel = BotChatModel(context: .fixture, fixtureActions: true)
        streamModel.beginTurn(turnID: "rate-check")
        for index in 0..<20 {
            streamModel.receiveStream(turnID: "rate-check", text: "delta-\(index)")
        }
        try await Task.sleep(nanoseconds: 800_000_000)
        let deliveries = streamModel.actionLog.filter { $0 == "stream" }.count
        try require((1...8).contains(deliveries), "stream delivered \(deliveries) frames in 800ms")
        try require(streamModel.streamingText == "delta-19", "stream did not retain latest text")
        streamModel.stop()
        passed.append("stream-max-10hz-latest-wins")

        // Bot page visibility: the watch loop reads once on start and once on
        // resume, but does not poll while the page is hidden. This drives the
        // real BotChatModel loop, not a copy of its predicate.
        let watchCounter = BotWatchCounter()
        let pauseModel = BotChatModel(
            context: .fixture,
            driver: BotChatDriver(
                history: { _, _ in BotUIHistoryPage(rows: [], nextCursor: nil, hasMore: false) },
                watch: { cursor in
                    await watchCounter.increment()
                    return BotUIRowBatch(rows: [], deletes: [], cursor: cursor, reset: false)
                },
                perform: { _ in .rejected(reason: "fixture") },
                stopCurrentTurn: { _ in }))
        var watchTask = Task { await pauseModel.watchLoop() }
        try await Task.sleep(nanoseconds: 300_000_000)
        let visibleReads = await watchCounter.value
        try require(visibleReads >= 1, "watch loop did not read on start")
        pauseModel.setPageActive(false)
        try await Task.sleep(nanoseconds: 1_200_000_000)
        let pausedReads = await watchCounter.value
        pauseModel.setPageActive(false)
        try await Task.sleep(nanoseconds: 900_000_000)
        let stillPausedReads = await watchCounter.value
        try require(stillPausedReads == pausedReads,
                    "watch loop polled while the Bot page was hidden")
        watchTask.cancel()
        pauseModel.setPageActive(true)
        watchTask = Task { await pauseModel.watchLoop() }
        try await Task.sleep(nanoseconds: 300_000_000)
        let resumedReads = await watchCounter.value
        try require(resumedReads > pausedReads,
                    "watch loop did not catch up immediately on resume")
        watchTask.cancel()
        pauseModel.setPageActive(false)
        passed.append("bot-page-polling-pauses-and-resumes")

        let deepLinkModel = BotChatModel(rows: BotUIFixtures.rows(for: .question), context: .fixture, fixtureActions: true)
        let good = URL(string: "phonedsh://bot/main/row/card-question")!
        let bad = URL(string: "phonedsh://bot/main/row/missing")!
        try require(deepLinkModel.openDeepLink(good) && !deepLinkModel.openDeepLink(bad),
                    "deep link did not resolve exactly")
        passed.append("deep-link-exact-row")

        let hidden = BotChatModel(rows: BotUIFixtures.rows(for: .failClosed), context: .fixture, fixtureActions: true)
        try require(hidden.visibleRows.isEmpty, "P1/unknown/incomplete row rendered")
        passed.append("fail-closed-P1-unknown-incomplete")

        // Main-Bot pointer routing: every legacy `main` default is gone.
        let pointerRoster = BotRoster(bots: [
            BotProfile(id: "main", name: "旧主 Bot"),
            BotProfile(id: "agent-b", name: "新主 Bot"),
        ], mainBotID: "agent-b")
        try require(BotMainPointerRouting.restoredSelection("main", in: pointerRoster) == "main",
                    "an existing record id must win over the pointer")
        try require(BotMainPointerRouting.restoredSelection("missing", in: pointerRoster) == "agent-b",
                    "dangling selection did not fall back to the main pointer")
        try require(BotMainPointerRouting.deviceTaskRecipient(in: pointerRoster) == "agent-b",
                    "device task result did not route to the main pointer")
        try require(BotMainPointerRouting.defaultRoutineBotID(in: pointerRoster) == "agent-b",
                    "default routine ownership did not use the main pointer")
        let noLegacyMainRoster = BotRoster(bots: [
            BotProfile(id: "agent-a", name: "A"),
            BotProfile(id: "agent-b", name: "B"),
        ], mainBotID: "agent-b")
        try require(BotMainPointerRouting.deepLinkBotID("main", in: noLegacyMainRoster) == "agent-b",
                    "legacy main deep link did not resolve through the pointer")
        try require(BotMainPointerRouting.deepLinkBotID("agent-b", in: pointerRoster) == "agent-b",
                    "existing deep link Bot did not resolve")
        passed.append("main-pointer-routing")

        // Unread: the selected Bot never bumps itself; the peer does.
        let outboundRecord = BotTeamAgentCommRecord(
            rowID: "agent-outbound-x", botID: "main", direction: .outbound,
            role: "assistant", text: "hi",
            toAgent: BotAgentRef(id: "agent-b", name: "B"),
            threadID: "thread-x", requestID: "call-x")
        try require(BotUnreadRules.recipient(for: outboundRecord) == "agent-b",
                    "outbound unread recipient is not the target")
        try require(BotUnreadRules.shouldIncrement(recipient: "agent-b", selectedBotID: "main"),
                    "non-selected target did not get an unread bump")
        try require(!BotUnreadRules.shouldIncrement(recipient: "agent-b", selectedBotID: "agent-b"),
                    "selected target received an unread bump")
        let inboundRecord = BotTeamAgentCommRecord(
            rowID: "t1u", botID: "main", direction: .inbound, role: "user", text: "reply",
            fromAgent: BotAgentRef(id: "agent-b", name: "B"),
            threadID: "thread-x", requestID: "call-x")
        try require(BotUnreadRules.recipient(for: inboundRecord) == "main",
                    "inbound unread recipient is not the sender")
        try require(BotUnreadRules.shouldIncrementForDelivery(to: "agent-b", selectedBotID: "main"),
                    "non-selected routine/device delivery did not bump unread")
        try require(!BotUnreadRules.shouldIncrementForDelivery(to: "main", selectedBotID: "main"),
                    "selected routine/device delivery bumped unread")
        passed.append("unread-rules")

        // Team delivery now / busy / queued routing.
        try require(BotTeamDeliveryPolicy.decide(delivery: "now", targetBusy: false) == .openVisibleTurn,
                    "idle now delivery did not open a visible turn")
        try require(BotTeamDeliveryPolicy.decide(delivery: "now", targetBusy: true) == .queueHeldAndWakeAfterBusy,
                    "busy now delivery did not queue and wake")
        try require(BotTeamDeliveryPolicy.decide(delivery: "queued", targetBusy: true) == .queueHeldOnly,
                    "queued delivery woke the target")
        try require(BotTeamDeliveryPolicy.decide(delivery: "queued", targetBusy: false) == .queueHeldOnly,
                    "queued delivery opened a turn")
        passed.append("team-delivery-now-busy-queued")

        // Delete cascade order and rollback: the profile record is last, and a
        // failure rolls back executed steps in reverse without deleting it.
        var deletionLog: [String] = []
        var rollbackLog: [String] = []
        let deletionPlan = BotDeletionPlan(steps: [
            BotDeletionStep(name: "abort-turns") {
                deletionLog.append("abort-turns")
            } rollback: {
                rollbackLog.append("abort-turns")
            },
            BotDeletionStep(name: "revoke-auth") {
                deletionLog.append("revoke-auth")
            } rollback: {
                rollbackLog.append("revoke-auth")
            },
            BotDeletionStep(name: "erase-memory") {
                deletionLog.append("erase-memory")
                throw BotUIFixtureCheckError.failed("memory unavailable")
            },
            BotDeletionStep(name: "delete-profile") { deletionLog.append("delete-profile") },
        ])
        do {
            _ = try await deletionPlan.run()
            try require(false, "failing delete plan reported success")
        } catch let failure as BotDeletionFailure {
            try require(failure.step == "erase-memory", "delete failure named the wrong step")
            try require(failure.executed == ["abort-turns", "revoke-auth"],
                        "delete failure executed list is wrong: \(failure.executed)")
        }
        try require(deletionLog == ["abort-turns", "revoke-auth", "erase-memory"],
                    "delete cascade reached the profile record after a failure: \(deletionLog)")
        try require(rollbackLog == ["revoke-auth", "abort-turns"],
                    "delete rollback did not run in reverse: \(rollbackLog)")
        var successfulLog: [String] = []
        let successfulPlan = BotDeletionPlan(steps: BotDeletionPlan.orderedStepNames.map { name in
            BotDeletionStep(name: name) { successfulLog.append(name) }
        })
        let completed = try await successfulPlan.run()
        try require(completed == BotDeletionPlan.orderedStepNames,
                    "delete cascade order differs from the contract")
        try require(successfulLog.last == "teardown-caches",
                    "caches were not torn down after the profile record")
        passed.append("delete-cascade-order-rollback")

        // Drawer projection: main first, hidden excluded from visibleEntries,
        // unread unchanged, and the add dialog validation matches the store.
        let drawerProfiles = [
            BotProfile(id: "agent-second", name: "小海", unreadCount: 3),
            BotProfile(id: "agent-main", name: "大肥鱼", pinned: true),
            BotProfile(id: "agent-hidden", name: "夜航", hiddenByUser: true),
        ]
        let drawerRoster = BotRoster(bots: drawerProfiles, mainBotID: "agent-main")
        let drawerStore = BotProfileStore(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("bot-ui-drawer-check-\(UUID().uuidString)", isDirectory: true))
        let drawerModel = BotRosterModel(
            roster: drawerRoster, selectedBotID: "agent-main", store: drawerStore,
            selectionStore: BotSelectionStore(selected: "agent-main"),
            defaults: UserDefaults(suiteName: "bot-ui-drawer-check")!)
        try require(drawerModel.entries.map(\.id) == ["agent-main", "agent-second", "agent-hidden"],
                    "drawer entries are not main-first insertion order")
        try require(drawerModel.visibleEntries.map(\.id) == ["agent-main", "agent-second"],
                    "hidden Bot is still visible in the drawer")
        let sixty = String(repeating: "长", count: 60)
        let sixtyOne = String(repeating: "长", count: 61)
        try require(BotAddValidation.problem(for: "   ") != nil, "blank name passed validation")
        try require(BotAddValidation.problem(for: sixty) == nil,
                    "60-character name failed validation")
        try require(BotAddValidation.problem(for: sixtyOne) != nil,
                    "61-character name passed validation")
        // Every edit goes through the TextField setter, so typing and paste
        // both cap at 60 UTF-16 units without splitting a grapheme cluster.
        try require(BotAddValidation.capped(sixtyOne) == sixty,
                    "typing cap did not truncate to 60 UTF-16 units")
        let family = "👨‍👩‍👧‍👦"
        try require(BotAddValidation.capped(String(repeating: family, count: 6))
                        == String(repeating: family, count: 5),
                    "typing cap split an emoji grapheme cluster")
        let combining = "e\u{0301}"
        try require(BotAddValidation.capped(String(repeating: combining, count: 31))
                        == String(repeating: combining, count: 30),
                    "typing cap split a combining-character grapheme")
        // The dialog can no longer produce an overlong value, so verify the
        // model layer directly: the same edited value must still be rejected
        // by BotRosterModel.create -> BotProfileStore.validateName.
        let editedTooLong = "小舟" + sixtyOne
        let cappedEdited = BotAddValidation.capped(editedTooLong)
        try require(cappedEdited == "小舟" + String(repeating: "长", count: 58),
                    "edited draft was not capped to 60 UTF-16 units")
        try require(BotAddValidation.problem(for: cappedEdited) == nil,
                    "capped edited draft failed UI validation")
        do {
            _ = try await drawerModel.create(name: editedTooLong)
            try require(false, "fixture create accepted an edited 63-character name")
        } catch let error as BotProfileStoreError {
            try require(error == .invalidName(editedTooLong),
                        "fixture create rejected with the wrong error: \(error)")
        }
        try require(drawerModel.bots.count == drawerProfiles.count,
                    "rejected fixture create changed the roster")
        try require(BotAddValidation.trimmed("  小海 ") == "小海", "name was not trimmed")
        passed.append("bot-drawer-main-first-hidden-excluded")
        passed.append("bot-add-validation")
        passed.append("bot-add-name-typing-cap")
        passed.append("bot-add-edited-too-long-rejected")

        // FishAction never reaches a process row even though the session log
        // still holds the real tool/call event.
        let fishCallEvent: JSONValue = .object([
            "type": .string("tool/call"),
            "seq": .number(3),
            "time": .number(Double(BotLiveFishProjection.now)),
            "data": .object([
                "callId": .string("fixture-fish"),
                "name": .string("FishAction"),
                "arguments": .string("{\"action\":\"waving\"}"),
            ]),
        ])
        try require(BotTurnProcessProjector.processItems([fishCallEvent]).isEmpty,
                    "FishAction leaked into the turn process rows")
        try require(!BotDisplayContract.isToolCallVisible(named: "mcp__phone__FishAction"),
                    "FishAction qualified name escaped the display contract")
        passed.append("fish-action-hidden-from-process-rows")

        // Live frame projection: text deltas feed model.delta, a failed turn
        // feeds error, and a FishAction tool call becomes a visible reaction.
        var liveFish = BotLiveFishProjection(botID: "agent-main")
        liveFish.receive(.event(BotUIFixtures.liveEvent("turn/start", turn: 1, seq: 1)))
        liveFish.receive(.streamStart)
        liveFish.receive(.textDelta("正在整理"))
        let streaming = liveFish.presentation()
        try require(streaming.fishState == .speaking,
                    "textDelta did not reach the director: \(streaming.fishState)")
        var failingFish = BotLiveFishProjection(botID: "agent-main")
        failingFish.receive(.event(BotUIFixtures.liveEvent("turn/start", turn: 1, seq: 1)))
        failingFish.receive(.event(BotUIFixtures.liveEvent("turn/end", turn: 1, seq: 2, data: [
            "reason": .object(["kind": .string("error"), "error": .string("fixture failure")]),
        ])))
        let failed = failingFish.presentation()
        try require(failed.fishState == .sad,
                    "failed turn did not map to sad (state=\(failed.fishState.rawValue), oneShot=\(failed.oneShot != nil), records=\(failingFish.records.count))")
        try require(failed.oneShot != nil, "failed turn did not keep a one-shot")
        var reactionFish = BotLiveFishProjection(botID: "agent-main")
        reactionFish.receive(.event(fishCallEvent))
        try require(reactionFish.presentation().reaction?.name == "waving",
                    "FishAction tool call did not become a reaction")
        passed.append("live-fish-delta-error-reaction")

        // Agent-comm row minimal rendering and peer switching metadata.
        let commRow = BotUIRow.fixture(
            id: "agent-outbound-render", seq: 2, kind: "sendMessage", role: "assistant",
            body: BotUIBody(type: "text", values: [
                "text": "帮我看一下这个",
                "agentComm": .object([
                    "direction": .string("outbound"),
                    "targetId": .string("agent-b"),
                    "targetName": .string("B"),
                    "message": .string("帮我看一下这个"),
                ]),
            ]))
        let presentation = BotAgentCommRendering.presentation(for: commRow)
        try require(presentation?.text == "已传消息给 B", "agent-comm row text is wrong")
        try require(presentation?.peerID == "agent-b", "agent-comm row lost the peer id")
        try require(BotAgentCommRendering.summaryText(count: 3, peerName: "B").contains("3"),
                    "agent-comm summary lost the message count")
        passed.append("agent-comm-row-minimal-render")

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

/// Counts real watch-loop iterations for the visibility pause check without
/// sharing mutable state across the driver's async closure.
private actor BotWatchCounter {
    private(set) var value = 0

    func increment() { value += 1 }
}

#Preview("Question") { BotUIFixtureRootView(fixture: .question) }
#Preview("Progress · Dark", traits: .fixedLayout(width: 390, height: 844)) {
    BotUIFixtureRootView(fixture: .progress).preferredColorScheme(.dark)
}
#Preview("Bot Info") { BotUIFixtureRootView(fixture: .info) }
#endif
