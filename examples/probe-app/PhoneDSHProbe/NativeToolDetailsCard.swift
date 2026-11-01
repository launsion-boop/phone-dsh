// SPDX-License-Identifier: MIT
//
// NativeToolDetailsCard — the generic recorded-result card shared by the 37
// `details-row` toolview keys (goal, schedule, job, subagent, team, terminal,
// session, lsp, workflow, cordis, todo) and every other key with only durable
// output to show. Official baseline: deepseek-harness 7be5505b0b (0.2.1-rc.2),
// 402pt viewport, CSS px == iOS pt. Sources: ui-tool ToolDetails.tsx +
// ToolDetails.module.css (geometry), models/{details,control-details,
// inspection-details}-model.ts (shapes), locales `detail.*` (copy),
// docs/receipts/ios-session-audit/06-tools.md §2.3 / T-04.
// One renderer serves every key; `NativeToolDetailsShape` supplies the
// per-cluster field vocabulary (wire key → official Chinese label).

import Foundation
import SwiftUI

// MARK: - Metrics

/// Official details-card geometry. Card-level padding is 12 (brief); the
/// per-item padding is the official 10 x 14 (ToolDetails.module.css:19-27).
enum NativeToolDetailsMetrics {
    // Shell: 16 radius, 0.5 hairline, 12 card inset, official 10x14 item padding.
    static let cornerRadius: CGFloat = 16, borderWidth: CGFloat = 0.5, padding: CGFloat = 12
    static let itemPaddingVertical: CGFloat = 10, itemPaddingHorizontal: CGFloat = 14
    static let listMaxHeight: CGFloat = 320

    // Type: 12/18 labels, 13/20 values, 8 gap.
    static let labelSize: CGFloat = 12, labelLineHeight: CGFloat = 18
    static let valueSize: CGFloat = 13, valueLineHeight: CGFloat = 20
    static let gap: CGFloat = 8

    /// `grid-template-columns: 5.5em minmax(0,1fr); gap: 12px`, row gap 4.
    static let fieldColumnWidth: CGFloat = 72, fieldGap: CGFloat = 12, fieldRowGap: CGFloat = 4

    /// SF's 12pt line box is ~14.3pt and the 13pt one ~15.5pt, so the official
    /// 18/20pt leadings add ~3.7 and ~4.5.
    static let labelLineSpacing: CGFloat = 3.7, valueLineSpacing: CGFloat = 4.5

    /// `--dsw-alias-state-business-primary` (#4176E6 / #7AAAFF) and `-warn-primary` (amber #F59E0B).
    static let business = NativeParityTokens.color(light: 0x4176E6, dark: 0x7AAAFF)
    static let warnPrimary = NativeParityTokens.color(light: 0xF59E0B, dark: 0xF59E0B)

    // Official copy (`detail.empty`, `detail.recordedResult`).
    static let defaultEmpty = "暂无结果", defaultCaption = "调用结果"
}

// MARK: - Tone and status

enum NativeToolDetailsTone {
    case neutral, info, success, warning, error

    var color: Color {
        switch self {
        case .neutral: NativeParityTokens.labelCaption
        case .info: NativeToolDetailsMetrics.business
        case .success: NativeParityTokens.success
        case .warning: NativeToolDetailsMetrics.warnPrimary
        case .error: NativeParityTokens.error
        }
    }
}

/// Card-level lifecycle of the call that produced this result.
enum NativeToolDetailsStatus {
    case ok, error, stopped, running, preparing

    /// Official `row.*` copy.
    var label: String {
        switch self {
        case .ok: "已完成"
        case .error: "失败"
        case .stopped: "已停止"
        case .running: "运行中"
        case .preparing: "正在准备调用"
        }
    }

    var tone: NativeToolDetailsTone {
        switch self {
        case .ok: .success
        case .error: .error
        case .stopped: .warning
        case .running: .info
        case .preparing: .neutral
        }
    }
}

/// Per-item progress symbol: ✓ / ▷ / 10x10 empty box (`detail.todo.*`).
enum NativeToolDetailsItemStatus {
    case completed, inProgress, pending

    var label: String {
        switch self {
        case .completed: "已完成"
        case .inProgress: "进行中"
        case .pending: "待处理"
        }
    }
}

/// Per-item delta symbol and copy (`todo.diff.*Item`).
enum NativeToolDetailsChange {
    case added, removed, updated

    var label: String {
        switch self {
        case .added: "新增"
        case .removed: "移除"
        case .updated: "状态变化"
        }
    }
}

// MARK: - Model

struct NativeToolDetailsField {
    var label: String
    var value: String
}

struct NativeToolDetailsBadge {
    var label: String
    var tone: NativeToolDetailsTone
}

struct NativeToolDetailsCode {
    var text: String
    var language: String?
}

struct NativeToolDetailsLocation {
    var path: String
    var line: Int?
}

/// One recorded entity, receipt, or collapsible group of related values.
struct NativeToolDetailsItem {
    var title: String?
    var subtitle: String?
    var description: String?
    var badge: NativeToolDetailsBadge?
    var status: NativeToolDetailsItemStatus?
    var previousStatus: String?
    var change: NativeToolDetailsChange?
    var fields: [NativeToolDetailsField] = []
    var code: NativeToolDetailsCode?
    var location: NativeToolDetailsLocation?
    var groups: [NativeToolDetailsGroup] = []
}

struct NativeToolDetailsGroup {
    var label: String
    var items: [NativeToolDetailsItem]
}

/// Local, view-agnostic details model (the Swift twin of `ToolDetailsModel`).
struct NativeToolDetailsModel {
    var shape: NativeToolDetailsShape = .generic
    var title: String?
    var status: NativeToolDetailsStatus?
    var summary: String?
    var caption: String?
    var empty: String?
    var items: [NativeToolDetailsItem] = []
    var unchanged: NativeToolDetailsGroup?
}

// MARK: - Field shapes

/// The field vocabulary of each recorded-result cluster. Unknown extension keys
/// keep the raw wire key, exactly like `detailLabel` (detail-model-shared.ts:89).
enum NativeToolDetailsShape {
    case goal, schedule, job, subagent, team, terminal, session, lsp, workflow, cordis, todo, generic

    init(toolKey: String) {
        if toolKey.hasSuffix("_goal") { self = .goal }
        else if toolKey.hasPrefix("schedule_") { self = .schedule }
        else if toolKey.hasPrefix("job_") { self = .job }
        else if toolKey.hasPrefix("team_task_") || toolKey == "spawn_teammate" { self = .team }
        else if ["subagent", "list_agents", "list_subagent_models", "send_message",
                 "interrupt_agent", "wait_agent"].contains(toolKey) { self = .subagent }
        else if toolKey.hasPrefix("terminal_") { self = .terminal }
        else if toolKey.hasPrefix("session_") { self = .session }
        else if toolKey == "lsp" { self = .lsp }
        else if toolKey == "workflow" || toolKey == "ralph" { self = .workflow }
        else if toolKey.hasPrefix("cordis_") { self = .cordis }
        else if toolKey == "todo_write" { self = .todo }
        else { self = .generic }
    }

    /// Only the `detailList` adapters state the 调用结果 caption; the goal and
    /// schedule adapters return items without one (details-card-model.ts:49-190).
    var hasRecordedResultCaption: Bool {
        switch self {
        case .goal, .schedule: false
        default: true
        }
    }

    /// Official empty-state copy for the cluster (`detail.*.empty`).
    var defaultEmpty: String {
        switch self {
        case .goal: "没有目标"
        case .schedule: "没有定时任务"
        case .todo: "任务清单为空"
        default: NativeToolDetailsMetrics.defaultEmpty
        }
    }

    /// Cluster-specific labels that override or extend the shared vocabulary.
    private var overrides: [String: String] {
        switch self {
        case .goal: ["rounds": "执行轮次", "reason": "受阻原因", "state": "状态"]
        case .schedule: ["when": "计划时间", "frequency": "重复", "state": "状态"]
        case .job: ["state": "状态", "type": "类型", "exitCode": "退出码"]
        case .subagent: ["agent": "智能体 ID", "parent": "父级", "depth": "层级", "role": "角色"]
        case .team: ["task": "任务内容", "ownerName": "负责人", "writeScopes": "文件范围", "blockedBy": "前置任务"]
        case .terminal: ["pid": "进程 ID", "exitCode": "退出码", "signal": "信号", "type": "类型"]
        case .session: ["turn": "轮次", "seq": "事件序号", "callId": "调用 ID", "time": "时间"]
        case .lsp: ["file": "文件", "line": "行", "column": "列"]
        case .workflow: ["step": "步骤", "callId": "调用 ID", "result": "结果"]
        case .cordis: ["currentPackageId": "当前包", "nextPackageId": "待运行的包",
                       "registrations": "注册项", "props": "属性"]
        case .todo: ["content": "内容", "status": "状态"]
        case .generic: [:]
        }
    }

    /// Shared `detail.field.*` vocabulary, official Chinese strings.
    private static let wireLabels: [String: String] = [
        "id": "ID", "revision": "版本", "platform": "平台", "provider": "提供方", "model": "模型",
        "role": "角色", "context": "上下文", "ownerName": "负责人", "ready": "可开始",
        "blockedBy": "前置任务", "writeScopes": "文件范围", "writeScopeWarnings": "提示",
        "diagnostics": "诊断", "methods": "方法", "inputSchema": "输入 Schema", "outputSchema": "输出 Schema",
        "latestRun": "最近运行", "packages": "版本包", "registrations": "注册项", "props": "属性",
        "data": "数据", "source": "来源", "arguments": "输入", "content": "内容", "message": "消息",
        "messageId": "消息 ID", "status": "状态", "root": "根节点", "pid": "进程 ID", "type": "类型",
        "time": "时间", "seq": "事件序号", "turn": "轮次", "step": "步骤", "callId": "调用 ID",
        "agentsStarted": "启动智能体数", "output": "输出", "result": "结果", "subject": "主题",
        "parent": "父级", "depth": "层级", "exitCode": "退出码", "signal": "信号",
        "previousStatus": "中断前状态", "agent": "智能体 ID", "job": "任务 ID", "task": "任务内容",
        "processGroup": "进程组", "availability": "可用状态", "bestMatch": "最相关事件",
        "target": "目标事件", "surface": "记录状态", "path": "路径", "name": "名称",
    ]

    /// Official label for a recorded field key.
    func label(for key: String) -> String { overrides[key] ?? Self.wireLabels[key] ?? key }

    /// A labeled field from a wire key/value pair.
    func field(_ key: String, _ value: String) -> NativeToolDetailsField {
        NativeToolDetailsField(label: label(for: key), value: value)
    }

    /// Map a recorded object's fields through this shape's vocabulary.
    func fields(_ pairs: [(String, String)]) -> [NativeToolDetailsField] {
        pairs.map { field($0.0, $0.1) }
    }
}

extension NativeToolDetailsModel {
    /// Build a card for one recorded-result key; field-only results collapse into
    /// a single item so callers never hand-build the trivial case.
    static func make(toolKey: String,
                     title: String? = nil,
                     status: NativeToolDetailsStatus? = nil,
                     items: [NativeToolDetailsItem] = [],
                     fields: [NativeToolDetailsField] = [],
                     summary: String? = nil,
                     caption: String? = nil,
                     empty: String? = nil) -> NativeToolDetailsModel {
        let shape = NativeToolDetailsShape(toolKey: toolKey)
        var model = NativeToolDetailsModel(shape: shape, title: title, status: status, summary: summary,
                                           caption: caption, empty: empty, items: items)
        if model.items.isEmpty && !fields.isEmpty {
            model.items = [NativeToolDetailsItem(fields: fields)]
        }
        if model.items.isEmpty { model.empty = empty ?? shape.defaultEmpty }
        if model.caption == nil, !model.items.isEmpty, shape.hasRecordedResultCaption {
            model.caption = NativeToolDetailsMetrics.defaultCaption
        }
        return model
    }
}

// MARK: - Type helpers

private extension View {
    /// Caption-tier text: 12/18, official `label-caption` by default.
    func detailsLabel(_ color: Color = NativeParityTokens.labelCaption) -> some View {
        font(.system(size: NativeToolDetailsMetrics.labelSize))
            .lineSpacing(NativeToolDetailsMetrics.labelLineSpacing)
            .foregroundStyle(color)
    }

    /// Value-tier text: 13/20, official `label-secondary` by default.
    func detailsValue(_ color: Color = NativeParityTokens.labelSecondary,
                      weight: Font.Weight = .regular) -> some View {
        font(.system(size: NativeToolDetailsMetrics.valueSize, weight: weight))
            .lineSpacing(NativeToolDetailsMetrics.valueLineSpacing)
            .foregroundStyle(color)
    }
}

// MARK: - Card

/// The generic recorded-result card: title row, status badge, field rows,
/// grouped list items and the empty state. The only interactions are opening a
/// recorded file location and toggling a group.
struct NativeToolDetailsCard: View {
    let model: NativeToolDetailsModel
    var onOpenFile: ((String, Int?) -> Void)?

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: NativeToolDetailsMetrics.cornerRadius, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.title != nil || model.status != nil { titleRow }
            if let caption = model.caption, !model.items.isEmpty { captionRow(caption) }
            if model.items.isEmpty { emptyRow } else { itemList }
            if let unchanged = model.unchanged {
                NativeToolDetailsGroupView(group: unchanged, onOpenFile: onOpenFile)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NativeParityTokens.codeBlock)
        .clipShape(shape)
        .overlay(shape.strokeBorder(NativeParityTokens.borderL1,
                                   lineWidth: NativeToolDetailsMetrics.borderWidth))
        .padding(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 0))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.title ?? NativeToolDetailsMetrics.defaultCaption)
    }

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: NativeToolDetailsMetrics.gap) {
            if let title = model.title {
                Text(title)
                    .detailsValue(NativeParityTokens.labelSecondary, weight: .medium)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
            }
            Spacer(minLength: 0)
            if let status = model.status {
                NativeToolDetailsStatusBadge(status: status)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, NativeToolDetailsMetrics.padding)
        .padding(.top, NativeToolDetailsMetrics.padding)
        .padding(.bottom, 4)
    }

    private func captionRow(_ caption: String) -> some View {
        Text(caption)
            .detailsLabel()
            .padding(.horizontal, NativeToolDetailsMetrics.padding)
            .padding(.bottom, 6)
            .accessibilityHidden(true)
    }

    private var emptyRow: some View {
        Text(model.empty ?? NativeToolDetailsMetrics.defaultEmpty)
            .detailsLabel()
            .padding(NativeToolDetailsMetrics.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var itemList: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(model.items.enumerated()), id: \.offset) { index, item in
                    if index > 0 { NativeToolDetailsHairline() }
                    NativeToolDetailsItemRow(item: item, onOpenFile: onOpenFile)
                }
            }
        }
        .frame(maxHeight: NativeToolDetailsMetrics.listMaxHeight)
    }
}

// MARK: - Item

private struct NativeToolDetailsItemRow: View {
    let item: NativeToolDetailsItem
    var onOpenFile: ((String, Int?) -> Void)?

    private var hasHeading: Bool {
        item.title != nil || item.badge != nil || item.status != nil || item.change != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if hasHeading { heading }
            if let subtitle = item.subtitle {
                Text(subtitle).detailsLabel(NativeParityTokens.labelTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 3)
            }
            if let description = item.description {
                Text(description).detailsValue(NativeParityTokens.labelCaption)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
            if !item.fields.isEmpty { fieldList }
            if let code = item.code { codeBlock(code) }
            ForEach(Array(item.groups.enumerated()), id: \.offset) { _, group in
                NativeToolDetailsGroupView(group: group, onOpenFile: onOpenFile)
            }
        }
        .padding(.horizontal, NativeToolDetailsMetrics.itemPaddingHorizontal)
        .padding(.vertical, NativeToolDetailsMetrics.itemPaddingVertical)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private var heading: some View {
        HStack(alignment: .firstTextBaseline, spacing: NativeToolDetailsMetrics.gap) {
            // Gated so an absent symbol never reserves an HStack gap.
            if item.change != nil || item.status != nil { statusSymbol }
            if item.title != nil {
                if let location = item.location, let onOpenFile {
                    Button { onOpenFile(location.path, location.line) } label: { titleText }
                        .buttonStyle(.plain)
                        .layoutPriority(1)
                } else {
                    titleText.layoutPriority(1)
                }
            }
            if let badge = item.badge {
                badgeView(badge).fixedSize(horizontal: true, vertical: false)
            }
            Spacer(minLength: 0)
            if let status = item.status {
                statusText(status)
                    .detailsLabel()
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    private var titleText: some View {
        Text(item.title ?? "")
            .detailsValue(item.change == .removed
                          ? NativeParityTokens.labelTertiary : NativeParityTokens.labelSecondary)
            .strikethrough(item.change == .removed)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Official 14x18 symbol box: `+` / `−` / ✓ / ▷ / 10x10 pending box.
    @ViewBuilder private var statusSymbol: some View {
        if item.change == .added {
            Text("+").font(.system(size: 14))
                .foregroundStyle(NativeParityTokens.success)
                .frame(width: 14, height: 18, alignment: .center)
        } else if item.change == .removed {
            Text("−").font(.system(size: 14))
                .foregroundStyle(NativeParityTokens.error)
                .frame(width: 14, height: 18, alignment: .center)
        } else if let status = item.status {
            switch status {
            case .completed:
                Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(NativeParityTokens.labelTertiary)
                    .frame(width: 14, height: 18, alignment: .center)
            case .inProgress:
                Image(systemName: "play").font(.system(size: 10))
                    .foregroundStyle(NativeParityTokens.labelTertiary)
                    .frame(width: 14, height: 18, alignment: .center)
            case .pending:
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .strokeBorder(NativeParityTokens.labelTertiary, lineWidth: 1)
                    .frame(width: 10, height: 10)
                    .frame(width: 14, height: 18, alignment: .center)
            }
        }
    }

    private func badgeView(_ badge: NativeToolDetailsBadge) -> some View {
        HStack(spacing: 5) {
            Circle().fill(badge.tone.color).frame(width: 5, height: 5)
            Text(badge.label).detailsLabel(badge.tone.color)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(badge.label)
    }

    @ViewBuilder private func statusText(_ status: NativeToolDetailsItemStatus) -> some View {
        if let previous = item.previousStatus {
            Text("\(previous) → \(status.label)")
        } else if item.change == .updated {
            Text("\(status.label) · \(NativeToolDetailsChange.updated.label)")
        } else {
            Text(status.label)
        }
    }

    private var fieldList: some View {
        VStack(alignment: .leading, spacing: NativeToolDetailsMetrics.fieldRowGap) {
            ForEach(Array(item.fields.enumerated()), id: \.offset) { _, field in
                HStack(alignment: .top, spacing: NativeToolDetailsMetrics.fieldGap) {
                    Text(field.label)
                        .detailsLabel()
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: NativeToolDetailsMetrics.fieldColumnWidth, alignment: .leading)
                    Text(field.value)
                        .detailsValue()
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.top, hasHeading ? 6 : 0)
    }

    private func codeBlock(_ code: NativeToolDetailsCode) -> some View {
        NativeToolCardChrome(maxHeight: 240, appliesOuterMargins: false) {
            NativeToolCardCodeList(lines: code.text.components(separatedBy: "\n").map { NativeToolCardLine($0) })
        }
        .padding(.top, NativeToolDetailsMetrics.gap)
        .accessibilityLabel(code.language ?? "代码")
    }
}

// MARK: - Group

/// A `<details>` group: 0.5pt l2 rule above, 8pt top padding, 6pt chevron gap,
/// collapsed until tapped, children indented 20pt.
private struct NativeToolDetailsGroupView: View {
    let group: NativeToolDetailsGroup
    var onOpenFile: ((String, Int?) -> Void)?
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NativeToolDetailsHairline().padding(.top, NativeToolDetailsMetrics.gap)
            Button {
                withAnimation(.easeOut(duration: 0.16)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10))
                        .foregroundStyle(NativeParityTokens.labelTertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(group.label)
                        .detailsLabel()
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.top, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(group.label)
            .accessibilityValue(expanded ? "已展开" : "已折叠")
            if expanded {
                ForEach(Array(group.items.enumerated()), id: \.offset) { _, item in
                    NativeToolDetailsItemRow(item: item, onOpenFile: onOpenFile)
                        .padding(.leading, 20)
                        .padding(.top, 6)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Status badge and hairline

private struct NativeToolDetailsStatusBadge: View {
    let status: NativeToolDetailsStatus

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(status.tone.color).frame(width: 5, height: 5)
            Text(status.label).detailsLabel(status.tone.color)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(status.label)
    }
}

private struct NativeToolDetailsHairline: View {
    var body: some View {
        Rectangle()
            .fill(NativeParityTokens.borderL2)
            .frame(height: NativeToolDetailsMetrics.borderWidth)
            .accessibilityHidden(true)
    }
}

#if DEBUG
private struct NativeToolDetailsCardPreview: View {
    private var jobs: NativeToolDetailsModel {
        let shape = NativeToolDetailsShape(toolKey: "job_list")
        return .make(toolKey: "job_list", title: "查看后台任务", status: .ok, items: [
            NativeToolDetailsItem(title: "npm run dev", subtitle: "job_1",
                                  badge: NativeToolDetailsBadge(label: "运行中", tone: .info),
                                  fields: shape.fields([("type", "bash"), ("pid", "4821")])),
            NativeToolDetailsItem(title: "vite build", subtitle: "job_2",
                                  badge: NativeToolDetailsBadge(label: "失败", tone: .error),
                                  fields: shape.fields([("type", "bash"), ("exitCode", "1")])),
        ], summary: "2 个后台任务")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NativeToolDetailsCard(model: jobs)
            NativeToolDetailsCard(model: .make(toolKey: "get_goal", title: "查看目标", status: .running,
                                               fields: NativeToolDetailsShape(toolKey: "get_goal")
                                                   .fields([("state", "进行中"), ("rounds", "3 / 12")])))
            NativeToolDetailsCard(model: .make(toolKey: "schedule_list", title: "查看定时任务", status: .stopped))
        }
        .padding(NativeParityTokens.transcriptSide)
        .background(NativeParityTokens.surface)
    }
}

struct NativeToolDetailsCardPreviewProvider: PreviewProvider {
    static var previews: some View { NativeToolDetailsCardPreview() }
}
#endif
