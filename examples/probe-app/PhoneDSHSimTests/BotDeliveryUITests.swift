// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSHBot
import XCTest

@MainActor
final class BotDeliveryUITests: XCTestCase {
    private let now: Int64 = 1_794_801_600_000 // 2026-11-16 12:00 Asia/Shanghai

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    // MARK: - Source inspector

    func testFallbackSourceIsHonestAndShowsNoInternalId() {
        let row = BotUIRow.text(id: "row-fallback", seq: 1, role: "assistant",
                                text: "这条建议来自 Bot。", eventID: "evt-9f3a")
        let model = BotProvenanceInspectorModel(row: row, nowMS: now)
        XCTAssertTrue(model.isFallback)
        XCTAssertEqual(model.sources.count, 1)
        let source = model.sources[0]
        XCTAssertEqual(source.label, "Bot 生成的内容")
        XCTAssertEqual(source.state, .unknown)
        XCTAssertEqual(source.verification, .unknown)
        XCTAssertFalse(source.label.contains("evt-"))
        XCTAssertFalse(source.label.contains("record://"))
        guard case .limited(let reason) = model.availability else {
            return XCTFail("a lone row provenance must be limited, not available")
        }
        XCTAssertFalse(reason.contains("evt-"))
        XCTAssertNil(model.banner)
    }

    func testInternalLookingLabelIsReplacedAndDegrades() {
        let source: BotJSONValue = .object([
            "label": .string("record://session/main#3"),
            "kind": .string("user_message"),
            "trust": .string("user"),
            "verification": .string("verified"),
            "state": .string("current"),
        ])
        let row = rowWithSources([source])
        let model = BotProvenanceInspectorModel(
            row: row,
            inspection: BotSourceInspection(
                sources: BotProvenanceSource.parseList(row.body["sources"]),
                checkedAtMS: now),
            nowMS: now)
        XCTAssertEqual(model.sources.count, 1)
        XCTAssertEqual(model.sources[0].label, "未命名依据")
        XCTAssertTrue(model.sources[0].hasUnsafeLabel)
        XCTAssertFalse(model.sources[0].label.contains("record://"))
        guard case .limited(let reason) = model.availability else {
            return XCTFail("an unreadable label must degrade the panel")
        }
        XCTAssertTrue(reason.contains("不可读"))
    }

    func testRevokedSourceHasDangerBannerAndReason() {
        let source: BotJSONValue = .object([
            "label": .string("你上周发的排班表"),
            "kind": .string("file"),
            "trust": .string("user"),
            "verification": .string("verified"),
            "state": .string("revoked"),
            "state_reason": .string("文件访问权限已撤回"),
            "observed_at": .number(Double(now - 86_400_000)),
        ])
        let row = rowWithSources([source])
        let model = BotProvenanceInspectorModel(
            row: row,
            inspection: BotSourceInspection(
                sources: BotProvenanceSource.parseList(row.body["sources"]),
                checkedAtMS: now),
            nowMS: now)
        let banner = model.banner
        XCTAssertEqual(banner?.text, "这条依据已不可读")
        XCTAssertEqual(banner?.detail, "文件访问权限已撤回")
        XCTAssertEqual(banner?.tone, .danger)
        XCTAssertEqual(model.sources[0].state, .revoked)
        XCTAssertEqual(model.sources[0].stateReason, "文件访问权限已撤回")
    }

    func testChangedSourceIsWarningAndCurrentSourceIsQuiet() {
        let changed: BotJSONValue = .object([
            "label": .string("报销规范 10 月版"),
            "verification": .string("verified"),
            "state": .string("changed"),
            "state_reason": .string("来源出现了更新版本"),
        ])
        let current: BotJSONValue = .object([
            "label": .string("你 11 月 10 日的原话"),
            "verification": .string("verified"),
            "state": .string("current"),
        ])
        let row = rowWithSources([changed, current])
        let model = BotProvenanceInspectorModel(
            row: row,
            inspection: BotSourceInspection(
                sources: BotProvenanceSource.parseList(row.body["sources"]),
                checkedAtMS: now),
            nowMS: now)
        XCTAssertEqual(model.banner?.text, "这条依据可查看，但不是当前有效")
        XCTAssertEqual(model.banner?.tone, .warning)
        XCTAssertEqual(model.sources[0].state, .changed)
        XCTAssertEqual(model.sources[1].state, .current)
        guard case .available = model.availability else {
            return XCTFail("readable, current entries make the source view available")
        }
    }

    /// R5: a historical version stays readable and comparable; it is marked
    /// non-current, not hidden or treated as a permission failure.
    func testHistoricalSourceIsReadableButNotCurrent() {
        let historical: BotJSONValue = .object([
            "label": .string("报销规范 10 月版"),
            "kind": .string("file"),
            "trust": .string("observation"),
            "verification": .string("verified"),
            "state": .string("changed"),
            "state_detail": .string("来源已有更新版本"),
            "observed_at": .number(Double(now - 3 * 86_400_000)),
        ])
        let row = rowWithSources([historical])
        let model = BotProvenanceInspectorModel(
            row: row,
            inspection: BotSourceInspection(
                sources: BotProvenanceSource.parseList(row.body["sources"]),
                checkedAtMS: now),
            nowMS: now)
        let source = model.sources[0]
        XCTAssertTrue(source.isReadable, "a historical version is still readable")
        XCTAssertFalse(source.isCurrent)
        XCTAssertTrue(source.isHistorical)
        XCTAssertEqual(source.accessLabel, "历史版本，可查看")
        XCTAssertEqual(model.historicalCount, 1)
        XCTAssertEqual(model.unreadableCount, 0)
        XCTAssertEqual(model.banner?.text, "这条依据可查看，但不是当前有效")
        XCTAssertEqual(model.banner?.tone, .warning)
        guard case .available = model.availability else {
            return XCTFail("a readable historical source must not be hidden as unavailable")
        }
    }

    func testUnreadableSourceIsDistinctFromHistorical() {
        let revoked: BotJSONValue = .object([
            "label": .string("已撤回的资料"),
            "trust": .string("observation"),
            "verification": .string("unknown"),
            "state": .string("revoked"),
            "state_detail": .string("授权已撤回"),
        ])
        let row = rowWithSources([revoked])
        let model = BotProvenanceInspectorModel(
            row: row,
            inspection: BotSourceInspection(
                sources: BotProvenanceSource.parseList(row.body["sources"]),
                checkedAtMS: now),
            nowMS: now)
        let source = model.sources[0]
        XCTAssertFalse(source.isReadable)
        XCTAssertFalse(source.isHistorical)
        XCTAssertEqual(source.accessLabel, "当前不可读")
        XCTAssertEqual(model.unreadableCount, 1)
        XCTAssertEqual(model.banner?.tone, .danger)
        XCTAssertEqual(model.banner?.text, "这条依据已不可读")
    }

    func testTimeLabelsAreDeterministic() {
        XCTAssertEqual(BotProvenanceTime.label(now - 3_600_000, nowMS: now, calendar: calendar),
                       "今天 11:00")
        XCTAssertEqual(BotProvenanceTime.label(now - 86_400_000, nowMS: now, calendar: calendar),
                       "昨天 12:00")
        XCTAssertEqual(BotProvenanceTime.label(now - 6 * 86_400_000, nowMS: now, calendar: calendar),
                       "11月10日 12:00")
        XCTAssertEqual(BotProvenanceTime.label(now + 86_400_000, nowMS: now, calendar: calendar),
                       "时间异常")
        XCTAssertNil(BotProvenanceTime.label(nil, nowMS: now, calendar: calendar))
    }

    func testSourceEntryIsHiddenForOwnerAndLocalRows() {
        let owner = BotUIRow.text(id: "owner-row", seq: 1, role: "user", text: "你好")
        let assistant = BotUIRow.text(id: "assistant-row", seq: 2, role: "assistant", text: "在")
        let local = BotUIRow.text(id: "local-abc", seq: 3, role: "user", text: "发送中")
        guard case .unavailable = BotProvenanceEntry.availability(for: owner) else {
            return XCTFail("owner text has no source inspector")
        }
        guard case .available = BotProvenanceEntry.availability(for: assistant) else {
            return XCTFail("assistant output must expose its source entry")
        }
        guard case .unavailable = BotProvenanceEntry.availability(for: local) else {
            return XCTFail("a local echo has no durable source")
        }
    }

    // MARK: - Delivery draft and approval binding

    func testDraftSelectionInvalidatesOldApprovalDigest() throws {
        let row = approvalRow(selected: ["r1"], resources: [
            resource(id: "r1", name: "会议纪要.md", selected: true, state: "current"),
            resource(id: "r2", name: "上次待办.txt", selected: false, state: "current"),
        ], revision: 2, digest: "sha256:" + String(repeating: "a", count: 64))
        guard case .ready(let draft) = BotDeliveryDraft.parse(row: row) else {
            return XCTFail("draft should parse")
        }
        var session = BotDeliverySelectionSession(row: row, draft: draft)
        let binding = try XCTUnwrap(BotDeliveryApprovalBinding.parse(row: row))
        XCTAssertEqual(session.approvalAvailability(binding: binding), .usable)
        XCTAssertFalse(session.hasChanges)

        XCTAssertTrue(session.toggle("r2"))
        XCTAssertTrue(session.hasChanges)
        XCTAssertEqual(session.approvalAvailability(binding: binding),
                       .blocked("选择已改变，需要重新确认"))

        let intent = try XCTUnwrap(session.beginSubmit())
        XCTAssertEqual(intent.expectedRevision, 2)
        XCTAssertEqual(intent.selectedResourceIDs, ["r1", "r2"])
        XCTAssertEqual(session.approvalAvailability(binding: binding),
                       .blocked("正在更新选择，更新后才能确认"))
        session.markAccepted()
        XCTAssertEqual(session.approvalAvailability(binding: binding),
                       .blocked("正在更新草稿，完成后才能确认"))

        var next = draft
        next.revision = 3
        next.resources[1].selected = true
        XCTAssertTrue(session.applyDurable(next))
        XCTAssertFalse(session.hasChanges)
        XCTAssertEqual(session.approvalAvailability(binding: binding),
                       .blocked("草稿已更新，请查看最新内容"))
        var nextBinding = binding
        nextBinding.draftRevision = 3
        nextBinding.digest = "sha256:" + String(repeating: "b", count: 64)
        XCTAssertEqual(session.approvalAvailability(binding: nextBinding), .usable)
    }

    func testFailedSelectionKeepsChangesButBlocksApproval() throws {
        let row = approvalRow(selected: ["r1"], resources: [
            resource(id: "r1", name: "纪要.md", selected: true, state: "current"),
            resource(id: "r2", name: "附件.pdf", selected: false, state: "current"),
        ], revision: 1, digest: "sha256:" + String(repeating: "d", count: 64))
        guard case .ready(let draft) = BotDeliveryDraft.parse(row: row) else {
            return XCTFail("draft should parse")
        }
        var session = BotDeliverySelectionSession(row: row, draft: draft)
        session.toggle("r2")
        _ = session.beginSubmit()
        session.markFailed("draft_revision_mismatch")
        XCTAssertEqual(session.approvalAvailability(binding: BotDeliveryApprovalBinding.parse(row: row)),
                       .blocked("选择没有更新成功，请重试或撤销改动"))
        XCTAssertTrue(session.hasChanges)
        session.resetWorking()
        XCTAssertFalse(session.hasChanges)
        XCTAssertEqual(session.approvalAvailability(binding: BotDeliveryApprovalBinding.parse(row: row)),
                       .usable)
    }

    func testRevokedSelectedResourceIsDroppedFromIntentAndCannotBeReadded() throws {
        let row = approvalRow(selected: ["r1", "r2"], resources: [
            resource(id: "r1", name: "有效资料.md", selected: true, state: "current"),
            resource(id: "r2", name: "已撤权.txt", selected: true, state: "revoked",
                     stateReason: "权限已撤回"),
        ], revision: 4, digest: "sha256:" + String(repeating: "c", count: 64))
        guard case .ready(let draft) = BotDeliveryDraft.parse(row: row) else {
            return XCTFail("draft should parse")
        }
        var session = BotDeliverySelectionSession(row: row, draft: draft)
        XCTAssertEqual(session.availability(for: "r2"), .blocked("权限已撤回"))
        XCTAssertEqual(session.eligibleWorking, ["r1"])
        XCTAssertEqual(session.droppedInvalidCount, 1)
        XCTAssertTrue(session.hasChanges)
        let intent = try XCTUnwrap(session.beginSubmit())
        XCTAssertEqual(intent.selectedResourceIDs, ["r1"])
        XCTAssertFalse(session.toggle("r2"))
    }

    /// G-2 r5: a changed/unknown resource is selectable but visibly not
    /// current; only revoked/erased/unavailable are barred.
    func testChangedResourceIsSelectableButMarkedHistorical() {
        let row = approvalRow(selected: ["r1"], resources: [
            resource(id: "r1", name: "旧版规范.md", selected: true, state: "changed",
                     stateReason: "已有 11 月新版"),
        ], revision: 1, digest: "sha256:" + String(repeating: "a", count: 64))
        guard case .ready(let draft) = BotDeliveryDraft.parse(row: row) else {
            return XCTFail("draft should parse")
        }
        let resource = draft.resources[0]
        XCTAssertTrue(resource.isSelectable)
        XCTAssertFalse(resource.isCurrent)
        XCTAssertTrue(resource.isHistorical)
        XCTAssertEqual(resource.selectionNote, "历史版本，仍可选择")
        XCTAssertEqual(resource.stateReason, "已有 11 月新版")
        var session = BotDeliverySelectionSession(row: row, draft: draft)
        XCTAssertEqual(session.availability(for: "r1"), .selectable)
        XCTAssertFalse(session.hasChanges)
        XCTAssertTrue(session.toggle("r1"))
        XCTAssertTrue(session.hasChanges)
    }

    func testUnknownResourceIsSelectableButMarkedUncertain() {
        let row = approvalRow(selected: [], resources: [
            resource(id: "r1", name: "来源待核.md", selected: false, state: "unknown"),
        ], revision: 1, digest: "sha256:" + String(repeating: "b", count: 64))
        guard case .ready(let draft) = BotDeliveryDraft.parse(row: row) else {
            return XCTFail("draft should parse")
        }
        XCTAssertTrue(draft.resources[0].isSelectable)
        XCTAssertEqual(draft.resources[0].selectionNote, "时效未知，仍可选择")
        var session = BotDeliverySelectionSession(row: row, draft: draft)
        XCTAssertTrue(session.toggle("r1"))
        XCTAssertTrue(session.hasChanges)
    }

    func testMissingRevisionFailsClosed() {
        let body: BotUIBody = BotUIBody(type: "approval", values: [
            "approvalID": .string("approval-1"),
            "digest": .string("sha256:" + String(repeating: "d", count: 64)),
            "action": .string("发送"),
            "status": .string("pending"),
            "delivery": .object(["draft_id": .string("d1")]),
        ])
        let row = BotUIRow.fixture(id: "approval-bad", seq: 1, body: body)
        guard case .invalid(let reason) = BotDeliveryDraft.parse(row: row) else {
            return XCTFail("missing revision must fail closed")
        }
        XCTAssertTrue(reason.contains("版本"))
    }

    func testMalformedResourceDisablesSelection() {
        let row = approvalRow(selected: [], resources: [
            .object(["id": .string("r1")]), // no name
        ], revision: 1, digest: "sha256:" + String(repeating: "d", count: 64))
        guard case .ready(let draft) = BotDeliveryDraft.parse(row: row) else {
            return XCTFail("a draft with one malformed candidate stays visible")
        }
        XCTAssertTrue(draft.hasMalformedResources)
        let session = BotDeliverySelectionSession(row: row, draft: draft)
        XCTAssertFalse(session.canEdit)
        XCTAssertEqual(session.availability(for: "r1"), .blocked("这项资料已不可用"))
        XCTAssertTrue(session.hint?.contains("信息不完整") == true)
    }

    // MARK: - Feedback

    func testFeedbackEligibilityRejectsLocalOwnerAndAllowsAssistantArtifact() throws {
        let local = BotUIRow.text(id: "local-1", seq: 1, role: "assistant", text: "流式")
        if case .eligible = BotFeedbackArtifactRule.availability(for: local) {
            XCTFail("local echoes are not durable artifacts")
        }
        let owner = BotUIRow.text(id: "owner-1", seq: 2, role: "user", text: "你好")
        if case .eligible = BotFeedbackArtifactRule.availability(for: owner) {
            XCTFail("owner messages are not feedback targets")
        }
        let assistant = BotUIRow.text(id: "answer-1", seq: 3, role: "assistant",
                                      text: "建议周三前提交报销。")
        guard case .eligible(let artifact) = BotFeedbackArtifactRule.availability(for: assistant) else {
            return XCTFail("assistant output is a real artifact")
        }
        XCTAssertEqual(artifact.label, "建议周三前提交报销。")
        XCTAssertTrue(artifact.offers(.adopt))
        XCTAssertTrue(artifact.offers(.suppress))
        XCTAssertTrue(artifact.offers(.undo))
    }

    func testQuestionCardOffersNoAdopt() {
        let body: BotUIBody = BotUIBody(type: "widget", values: [
            "cardType": .string("question"),
            "question": .string("选哪个？"),
            "options": .array([.object(["id": .string("o0"), "label": .string("A")])]),
        ])
        let row = BotUIRow.fixture(id: "question-1", seq: 1, body: body)
        guard case .eligible(let artifact) = BotFeedbackArtifactRule.availability(for: row) else {
            return XCTFail("a suggestion card is an artifact")
        }
        XCTAssertFalse(artifact.offers(.adopt))
        XCTAssertTrue(artifact.offers(.correct))
        XCTAssertTrue(artifact.offers(.suppress))
    }

    func testFeedbackRecordAndUndoBindToAcceptedEvent() throws {
        let assistant = BotUIRow.text(id: "answer-2", seq: 1, role: "assistant",
                                      text: "你爱喝美式。")
        guard case .eligible(let artifact) = BotFeedbackArtifactRule.availability(for: assistant) else {
            return XCTFail("assistant output is a real artifact")
        }
        var state = BotFeedbackState()
        XCTAssertEqual(state.display(for: artifact.rowID), .none)
        XCTAssertTrue(state.begin(rowID: artifact.rowID, verdict: .adopt))
        XCTAssertEqual(state.display(for: artifact.rowID), .pending)
        XCTAssertEqual(state.availability(for: artifact, verdict: .adopt), .pending)
        state.accept(rowID: artifact.rowID, verdict: .adopt,
                     feedbackID: "feedback-evt-1", atMS: now)
        XCTAssertEqual(state.display(for: artifact.rowID), .recorded(.adopt))
        XCTAssertEqual(state.availability(for: artifact, verdict: .adopt),
                       .recorded("采纳"))
        XCTAssertTrue(state.canUndo(for: artifact.rowID))
        XCTAssertEqual(state.undoFeedbackID(for: artifact.rowID), "feedback-evt-1")

        XCTAssertTrue(state.begin(rowID: artifact.rowID, verdict: .undo))
        state.accept(rowID: artifact.rowID, verdict: .undo,
                     feedbackID: "feedback-evt-2", atMS: now + 1_000,
                     undoTarget: "feedback-evt-1")
        XCTAssertEqual(state.display(for: artifact.rowID), .undone)
        XCTAssertFalse(state.canUndo(for: artifact.rowID))
        XCTAssertEqual(state.latest(for: artifact.rowID)?.verdict, .undo)
    }

    func testFeedbackFailureCanBeRetriedAndDoesNotBlockComposer() throws {
        let assistant = BotUIRow.text(id: "answer-3", seq: 1, role: "assistant",
                                      text: "差旅前记得值机。")
        guard case .eligible(let artifact) = BotFeedbackArtifactRule.availability(for: assistant) else {
            return XCTFail("assistant output is a real artifact")
        }
        var state = BotFeedbackState()
        XCTAssertTrue(state.begin(rowID: artifact.rowID, verdict: .correct))
        state.fail(rowID: artifact.rowID, verdict: .correct, reason: "transport_timeout")
        XCTAssertEqual(state.failure(for: artifact.rowID), "transport_timeout")
        XCTAssertEqual(state.display(for: artifact.rowID), .none)
        XCTAssertTrue(state.begin(rowID: artifact.rowID, verdict: .correct))
        state.accept(rowID: artifact.rowID, verdict: .correct,
                     feedbackID: "feedback-evt-3", atMS: now)
        XCTAssertEqual(state.display(for: artifact.rowID), .recorded(.correct))
    }

    func testDuplicateVerdictIsRecordedNotResent() throws {
        let assistant = BotUIRow.text(id: "answer-4", seq: 1, role: "assistant",
                                      text: "明天有雨。")
        guard case .eligible(let artifact) = BotFeedbackArtifactRule.availability(for: assistant) else {
            return XCTFail("assistant output is a real artifact")
        }
        var state = BotFeedbackState()
        state.accept(rowID: artifact.rowID, verdict: .suppress,
                     feedbackID: "feedback-evt-4", atMS: now)
        XCTAssertEqual(state.availability(for: artifact, verdict: .suppress),
                       .recorded("这类别推了"))
        XCTAssertFalse(state.begin(rowID: artifact.rowID, verdict: .suppress))
    }


    // MARK: - Production model wiring

    func testSelectionSubmissionIsAtomicAndOldApprovalStaysBlocked() async throws {
        var selections: [BotDeliverySelectionIntent] = []
        let row = approvalRow(selected: ["r1"], resources: [
            resource(id: "r1", name: "会议纪要.md", selected: true, state: "current"),
            resource(id: "r2", name: "上次待办.txt", selected: false, state: "current"),
        ], revision: 2, digest: "sha256:" + String(repeating: "a", count: 64))
        let driver = BotChatDriver(
            history: { _, _ in BotUIHistoryPage(rows: [], nextCursor: nil, hasMore: false) },
            watch: { _ in BotUIRowBatch(rows: [], deletes: [], cursor: 0, reset: false) },
            perform: { _ in .rejected(reason: "unused") },
            stopCurrentTurn: { _ in },
            selectDeliveryResources: { intent in
                selections.append(intent)
                return .accepted(eventID: "evt-selection-1")
            },
            recordFeedback: { _ in .rejected(reason: "unused") })
        let model = BotChatModel(rows: [row], context: BotRuntimeContext(botID: "main", botName: "大肥鱼"),
                                 driver: driver)
        XCTAssertEqual(model.deliverySession(for: row)?.draft.revision, 2)
        XCTAssertEqual(model.deliveryApprovalAvailability(for: row), .usable)

        model.toggleDeliveryResource(row: row, resourceID: "r2")
        XCTAssertEqual(model.deliveryApprovalAvailability(for: row),
                       .blocked("选择已改变，需要重新确认"))
        model.submitDeliverySelection(row: row)
        try await waitFor { selections.count == 1 }
        XCTAssertEqual(selections[0].expectedRevision, 2)
        XCTAssertEqual(selections[0].selectedResourceIDs, ["r1", "r2"])
        XCTAssertEqual(model.deliverySession(for: row)?.phase, .awaitingDurable)
        XCTAssertEqual(model.deliveryApprovalAvailability(for: row),
                       .blocked("正在更新草稿，完成后才能确认"))

        var next = approvalRow(selected: ["r1", "r2"], resources: [
            resource(id: "r1", name: "会议纪要.md", selected: true, state: "current"),
            resource(id: "r2", name: "上次待办.txt", selected: true, state: "current"),
        ], revision: 3, digest: "sha256:" + String(repeating: "b", count: 64))
        next.updatedSeq = 2
        model.apply(BotUIRowBatch(rows: [next], deletes: [], cursor: 2, reset: false))
        XCTAssertEqual(model.deliverySession(for: row)?.draft.revision, 3)
        XCTAssertEqual(model.deliverySession(for: row)?.phase, .idle)
        XCTAssertEqual(model.deliveryApprovalAvailability(for: row),
                       .blocked("草稿已更新，请查看最新内容"))
    }

    func testFeedbackIsBoundToAcceptedEventAndUndoReusesIt() async throws {
        var intents: [BotFeedbackIntent] = []
        let row = BotUIRow.text(id: "answer-model", seq: 1, role: "assistant",
                                text: "建议周三前提交报销。")
        let driver = BotChatDriver(
            history: { _, _ in BotUIHistoryPage(rows: [], nextCursor: nil, hasMore: false) },
            watch: { _ in BotUIRowBatch(rows: [], deletes: [], cursor: 0, reset: false) },
            perform: { _ in .rejected(reason: "unused") },
            stopCurrentTurn: { _ in },
            selectDeliveryResources: { _ in .rejected(reason: "unused") },
            recordFeedback: { intent in
                intents.append(intent)
                return .accepted(eventID: "evt-feedback-\(intents.count)")
            })
        let model = BotChatModel(rows: [row], context: BotRuntimeContext(botID: "main", botName: "大肥鱼"),
                                 driver: driver)
        XCTAssertNotNil(model.feedbackArtifact(for: row))
        model.sendFeedback(row: row, verdict: .adopt)
        try await waitFor { model.feedbackState.display(for: row.id) == .recorded(.adopt) }
        XCTAssertEqual(intents.count, 1)
        XCTAssertEqual(intents[0].verdict, .adopt)
        XCTAssertEqual(intents[0].scope, .artifact)
        XCTAssertNil(intents[0].feedbackID)

        model.sendFeedback(row: row, verdict: .undo)
        try await waitFor { model.feedbackState.display(for: row.id) == .undone }
        XCTAssertEqual(intents.count, 2)
        XCTAssertEqual(intents[1].verdict, .undo)
        XCTAssertEqual(intents[1].feedbackID, "evt-feedback-1")
    }

    func testSuppressCarriesExplicitUserScope() async throws {
        var intents: [BotFeedbackIntent] = []
        let row = BotUIRow.text(id: "answer-suppress", seq: 1, role: "assistant",
                                text: "以后这类周报不用再推。")
        let driver = BotChatDriver(
            history: { _, _ in BotUIHistoryPage(rows: [], nextCursor: nil, hasMore: false) },
            watch: { _ in BotUIRowBatch(rows: [], deletes: [], cursor: 0, reset: false) },
            perform: { _ in .rejected(reason: "unused") },
            stopCurrentTurn: { _ in },
            selectDeliveryResources: { _ in .rejected(reason: "unused") },
            recordFeedback: { intent in
                intents.append(intent)
                return .accepted(eventID: "evt-suppress-1")
            })
        let model = BotChatModel(rows: [row], context: BotRuntimeContext(botID: "main", botName: "大肥鱼"),
                                 driver: driver)
        model.sendFeedback(row: row, verdict: .suppress, scope: .user)
        try await waitFor { intents.count == 1 }
        XCTAssertEqual(intents[0].scope, .user)
        XCTAssertEqual(intents[0].verdict, .suppress)
    }

    func testSendWhileApprovalPendingKeepsApprovalAndLocalEcho() async throws {
        var performed: [String] = []
        let row = approvalRow(selected: [], resources: [], revision: 1,
                              digest: "sha256:" + String(repeating: "d", count: 64))
        let driver = BotChatDriver(
            history: { _, _ in BotUIHistoryPage(rows: [], nextCursor: nil, hasMore: false) },
            watch: { _ in BotUIRowBatch(rows: [], deletes: [], cursor: 0, reset: false) },
            perform: { action in
                if case .approval(_, _, _, let decision, _) = action {
                    performed.append("approval:\(decision.rawValue)")
                } else {
                    performed.append("chat")
                }
                return .accepted(eventID: "evt-\(performed.count)")
            },
            stopCurrentTurn: { _ in },
            selectDeliveryResources: { _ in .rejected(reason: "unused") },
            recordFeedback: { _ in .rejected(reason: "unused") })
        let model = BotChatModel(rows: [row], context: BotRuntimeContext(botID: "main", botName: "大肥鱼"),
                                 driver: driver)
        XCTAssertEqual(model.pendingApprovalCount, 1)
        model.send(text: "先继续，这个审批不用了。")
        XCTAssertEqual(model.pendingApprovalCount, 1)
        try await waitFor { performed == ["chat"] }
        XCTAssertEqual(performed, ["chat"])
        XCTAssertFalse(model.actionLog.contains("approval:deny"),
                       "a normal send must not emit an approval decision")
        XCTAssertEqual(model.pendingApprovalCount, 1)
        XCTAssertTrue(model.rows.contains { $0.id.hasPrefix("local-") })
    }

    func testSourceInspectionUsesDriverResult() async throws {
        let driver = BotChatDriver(
            history: { _, _ in BotUIHistoryPage(rows: [], nextCursor: nil, hasMore: false) },
            watch: { _ in BotUIRowBatch(rows: [], deletes: [], cursor: 0, reset: false) },
            perform: { _ in .rejected(reason: "unused") },
            stopCurrentTurn: { _ in },
            inspectSources: { request in
                XCTAssertEqual(request.botID, "main")
                XCTAssertEqual(request.eventIDs, ["evt-source-1"])
                return .available(BotSourceInspection(
                    sources: [BotProvenanceSource(
                        id: "source-0", label: "你 11 月 10 日的原话", kind: .userMessage,
                        trust: .user, reason: "这是唯一依据", observedAtMS: self.now,
                        verification: .verified, state: .current, stateReason: nil,
                        versionLabel: nil)],
                    checkedAtMS: self.now))
            },
            selectDeliveryResources: { _ in .rejected(reason: "unused") },
            recordFeedback: { _ in .rejected(reason: "unused") })
        let row = BotUIRow.text(id: "answer-source", seq: 1, role: "assistant",
                                text: "你爱喝美式。", eventID: "evt-source-1")
        let model = BotChatModel(rows: [row], context: BotRuntimeContext(botID: "main", botName: "大肥鱼"),
                                 driver: driver)
        let result = await model.inspectSources(for: row)
        guard case .available(let inspection) = result else {
            return XCTFail("driver source inspection should be available")
        }
        XCTAssertEqual(inspection.sources.first?.label, "你 11 月 10 日的原话")
    }

    private func waitFor(timeout: TimeInterval = 2,
                         _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("condition not met within \(timeout)s")
    }

    // MARK: - Helpers

    private func rowWithSources(_ sources: [BotJSONValue]) -> BotUIRow {
        let body = BotUIBody(type: "text", values: [
            "text": .string("这条建议引用了资料。"),
            "sources": .array(sources),
        ])
        var row = BotUIRow.fixture(id: "row-sources", seq: 1, role: "assistant", body: body)
        row.provenance.trust = "model"
        return row
    }

    private func resource(id: String, name: String, selected: Bool, state: String,
                          stateReason: String? = nil) -> BotJSONValue {
        var values: [String: BotJSONValue] = [
            "id": .string(id),
            "name": .string(name),
            "selected": .bool(selected),
            "state": .string(state),
            "reason": .string("和这次交付相关"),
            "source": .object([
                "label": .string("你之前发过的资料"),
                "kind": .string("file"),
                "trust": .string("user"),
                "verification": .string("verified"),
                "state": .string(state),
            ]),
        ]
        if let stateReason { values["state_reason"] = .string(stateReason) }
        return .object(values)
    }

    private func approvalRow(selected: [String], resources: [BotJSONValue],
                             revision: Int, digest: String) -> BotUIRow {
        let body = BotUIBody(type: "approval", values: [
            "approvalID": .string("approval-1"),
            "digest": .string(digest),
            "action": .string("发送会议资料"),
            "status": .string("pending"),
            "delivery": .object([
                "draft_id": .string("draft-1"),
                "revision": .number(Double(revision)),
                "parameters": .array([
                    .object(["label": .string("收件人"), "value": .string("张三")]),
                ]),
                "resources": .array(resources),
            ]),
        ])
        _ = selected
        return BotUIRow.fixture(id: "approval-1", seq: 1, body: body)
    }
}
