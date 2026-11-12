// SPDX-License-Identifier: MIT

import SwiftUI
import UIKit
import PhoneDSHBot

struct BotWorkCardView: View {
    let row: BotUIRow
    let card: BotUICardContent
    @ObservedObject var model: BotChatModel
    let actions: BotCardActions

    var body: some View {
        switch card.kind {
        case .progress: BotProgressCardView(row: row)
        case .checklist: BotChecklistCardView(row: row, model: model)
        case .link: BotLinkCardView(row: row, actions: actions)
        case .approval: BotApprovalCardView(row: row, model: model)
        case .automation: BotAutomationCardView(row: row)
        case .notice: BotNoticeCardView(row: row)
        default: EmptyView()
        }
    }
}

// MARK: - Progress

/// Title and state, summary, the 4pt bar, up to four steps, then the ETA.
private struct BotProgressCardView: View {
    let row: BotUIRow
    @State private var expanded = false

    private var title: String { row.body["title"]?.string ?? row.body["name"]?.string ?? "" }
    private var state: String {
        let value = row.body["state"]?.string ?? "running"
        return ["running", "done", "paused", "failed", "cancelled"].contains(value) ? value : "running"
    }
    private var steps: [BotUIProgressStep] { BotUIProgressStep.parseList(row.body["steps"]) }
    private var percent: Int? {
        if state == "done" { return 100 }
        if let declared = row.body["percent"]?.number, declared.isFinite {
            return min(100, max(0, Int(declared.rounded())))
        }
        guard !steps.isEmpty else { return nil }
        let done = steps.filter { BotCardStepState($0.state) == .done }.count
        return Int((Double(done) / Double(steps.count) * 100).rounded())
    }
    private var stateTag: (text: String, tone: BotCardTone) {
        switch state {
        case "done": return ("已完成", .success)
        case "paused": return ("已暂停", .neutral)
        case "failed": return ("失败", .danger)
        case "cancelled": return ("已取消", .neutral)
        default: return ("进行中", .neutral)
        }
    }

    var body: some View {
        BotCardSurface {
            VStack(alignment: .leading, spacing: BotCardMetrics.blockGap) {
                BotCardHeading(icon: "chart.bar", eyebrow: "进度", title: title,
                               detail: row.body.string("summary", "description")) {
                    BotCardTag(text: stateTag.text, tone: stateTag.tone)
                }
                if let percent {
                    BotCardProgressBar(percent: percent,
                                       ink: state == "failed" ? NativeParityTokens.error : HomeSpec.textPrimary)
                }
                if !steps.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array((expanded ? steps : Array(steps.prefix(4))).enumerated()),
                                id: \.element.id) { index, step in
                            if index > 0 { BotCardDivider(inset: BotCardMetrics.glyphColumn + 12) }
                            let stepState = BotCardStepState(step.state)
                            BotCardRow(label: step.label,
                                       labelInk: stepState == .pending ? HomeSpec.textSecondary : HomeSpec.textPrimary,
                                       strikethrough: stepState == .skipped) {
                                BotCardGlyph(systemImage: stepState.glyph, ink: stepState.ink)
                            } trailing: {
                                if let detail = step.detail {
                                    Text(detail).botCardMeta().monospacedDigit().lineLimit(1)
                                }
                            }
                        }
                    }
                    if steps.count > 4 {
                        Button(expanded ? "收起" : "显示全部 \(steps.count) 步") {
                            withAnimation(.easeOut(duration: 0.16)) { expanded.toggle() }
                        }
                        .buttonStyle(BotCardButtonStyle(kind: .plain))
                        .padding(.vertical, -8)
                        .accessibilityValue(expanded ? "已展开" : "已折叠")
                        .accessibilityIdentifier("bot.progress.more")
                    }
                }
                if let eta = row.body["eta"]?.string {
                    Label(eta, systemImage: "clock").botCardMeta()
                }
            }
        }
        .opacity(state == "cancelled" ? 0.72 : 1)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Checklist

/// Title with done/total, summary, check rows; once changed, a button sends
/// the result back to the Bot.
private struct BotChecklistCardView: View {
    let row: BotUIRow
    @ObservedObject var model: BotChatModel
    @State private var items: [BotUIChecklistItem]
    @State private var dirty = false

    init(row: BotUIRow, model: BotChatModel) {
        self.row = row
        self.model = model
        _items = State(initialValue: BotUIChecklistItem.parseList(row.body["items"]))
    }

    private var interactive: Bool { row.body["interactive"]?.bool != false }
    private var title: String { row.body["title"]?.string ?? "" }
    private var doneCount: Int { items.filter(\.done).count }
    private var sending: Bool { model.checklistProgress[row.id]?.sending == true }
    private var sent: Bool { model.checklistProgress[row.id]?.sent == true }
    private var message: String {
        let pending = items.filter { !$0.done && !$0.synthetic }.map(\.text)
        let head = "\(title)：已完成 \(doneCount)／\(items.count)。"
        return pending.isEmpty ? "\(head)全部完成。" : "\(head)未完成：\(pending.joined(separator: "、"))"
    }

    var body: some View {
        BotCardSurface {
            VStack(alignment: .leading, spacing: 0) {
                BotCardHeading(icon: "checkmark.square", eyebrow: "检查清单", title: title,
                               detail: row.body["summary"]?.string) {
                    Text("\(doneCount)/\(items.count)")
                        .monospacedDigit()
                        .foregroundStyle(doneCount == items.count ? HomeSpec.success : HomeSpec.textPlaceholder)
                }
                .padding(.bottom, 4)
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { BotCardDivider(inset: BotCardMetrics.glyphColumn + 12) }
                    Button {
                        guard interactive, !item.synthetic else { return }
                        items[index].done.toggle()
                        dirty = true
                        model.noteChecklistProgress(rowID: row.id, done: doneCount, total: items.count)
                    } label: {
                        BotCardRow(label: item.text,
                                   labelInk: item.done ? HomeSpec.textPlaceholder : HomeSpec.textPrimary,
                                   strikethrough: item.done) {
                            BotCardGlyph(systemImage: item.done ? "checkmark.square.fill" : "square",
                                         ink: item.done ? HomeSpec.textPrimary : HomeSpec.iconMuted)
                        } trailing: {
                            if let note = item.note {
                                Text(note).botCardMeta().lineLimit(1)
                            }
                        }
                    }
                    .buttonStyle(BotCardRowButtonStyle())
                    .disabled(!interactive || item.synthetic || sending)
                    .accessibilityLabel(item.text)
                    .accessibilityValue(item.done ? "已完成" : "未完成")
                    .accessibilityIdentifier("bot.checklist.item.\(item.id)")
                }
                if interactive && dirty {
                    Button(sent || sending ? "已发送勾选结果" : "把勾选结果发给 Bot") {
                        guard !sent, !sending else { return }
                        model.sendChecklist(row: row, done: doneCount, total: items.count, message: message)
                    }
                    .buttonStyle(BotCardButtonStyle(kind: .secondary))
                    .disabled(sent || sending)
                    .padding(.top, BotCardMetrics.blockGap)
                    .accessibilityIdentifier("bot.checklist.send")
                }
            }
        }
        .onChange(of: row.body) { _, _ in
            items = BotUIChecklistItem.parseList(row.body["items"])
            dirty = false
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Links

/// Title, then one row per link: tile, title, site and description, ↗.
private struct BotLinkCardView: View {
    let row: BotUIRow
    let actions: BotCardActions
    private var links: [BotUILink] { BotUILink.parseList(row.body["links"]) }

    var body: some View {
        BotCardSurface {
            VStack(alignment: .leading, spacing: 0) {
                BotCardHeading(icon: "link", eyebrow: "参考链接", title: row.body["title"]?.string)
                    .padding(.bottom, 4)
                ForEach(Array(links.enumerated()), id: \.element.id) { index, link in
                    if index > 0 { BotCardDivider(inset: BotCardMetrics.tile + 12) }
                    Button { actions.openURL(link.url) } label: {
                        HStack(spacing: 12) {
                            BotCardTile(systemImage: icon(for: link.kind))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(link.title)
                                    .botCardRow(weight: .medium)
                                    .lineLimit(2)
                                Text([link.site, link.description].compactMap { $0 }.joined(separator: " · "))
                                    .botCardMeta()
                                    .lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(HomeSpec.iconMuted)
                        }
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(BotCardRowButtonStyle())
                    .contextMenu {
                        Button("打开链接") { actions.openURL(link.url) }
                        Button("复制链接") { UIPasteboard.general.string = link.url.absoluteString }
                    }
                    .accessibilityIdentifier("bot.link.open.\(link.id)")
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func icon(for kind: String) -> String {
        switch kind {
        case "doc": return "doc.text"
        case "repo": return "chevron.left.forwardslash.chevron.right"
        case "article": return "text.quote"
        case "video": return "play.rectangle"
        case "tool": return "wrench.and.screwdriver"
        default: return "globe"
        }
    }
}

// MARK: - Approval

/// Pending: what will run, the command, why, and the three answers.
/// Decided: a single row with the outcome.
private struct BotApprovalCardView: View {
    let row: BotUIRow
    @ObservedObject var model: BotChatModel
    @State private var expanded = false
    @State private var copied = false

    private var ask: [String: BotJSONValue] { row.body["ask"]?.object ?? [:] }
    private var status: String { row.body["status"]?.string ?? ask["status"]?.string ?? "pending" }
    private var pending: Bool { status == "pending" }
    private var action: String { row.body.string("action", "title", "text") ?? ask["action"]?.string ?? "操作" }
    private var command: String { row.body.string("command", "target") ?? ask["target"]?.string ?? "" }
    private var detail: String? { row.body["detail"]?.string }
    private var scope: String { row.body["alwaysScope"]?.string ?? ask["alwaysScope"]?.string ?? "until" }
    private var key: String { "approval:\(row.id)" }
    private var busy: Bool { model.actionStates[key] == .pending }
    private var allowed: Bool {
        status == "allowed" || status == "allowed-session" || status == "always"
    }
    private var longCommand: Bool {
        command.count > 240 || command.split(separator: "\n", omittingEmptySubsequences: false).count > 5
    }
    private var highRisk: Bool {
        let risk = row.body["risk"]?.object
        return risk?["level"]?.string == "high" || risk?["tags"]?.array?.contains(.string("irreversible")) == true
    }
    private var statusLabel: String {
        BotApprovalReceipt.label(for: status, scope: scope)
    }

    var body: some View {
        BotCardSurface {
            if pending { pendingContent } else { decidedContent }
        }
        .accessibilityElement(children: .contain)
    }

    private var decidedContent: some View {
        HStack(spacing: 12) {
            BotCardGlyph(systemImage: allowed ? "checkmark.circle.fill" : "xmark.circle",
                         ink: allowed ? HomeSpec.success : HomeSpec.textPlaceholder)
            VStack(alignment: .leading, spacing: 2) {
                Text(statusLabel)
                    .botCardRow(weight: .medium)
                Text(command.isEmpty ? action : command)
                    .botCardMeta()
                    .monospaced(!command.isEmpty)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: BotCardMetrics.rowMinHeight)
    }

    private var pendingContent: some View {
        VStack(alignment: .leading, spacing: BotCardMetrics.blockGap) {
            BotCardHeading(icon: "checkmark.shield", eyebrow: "需要你确认",
                           title: row.body["title"]?.string ?? "允许执行这个操作吗？", detail: action) {
                if highRisk { BotCardTag(text: "高风险", tone: .danger) }
            }
            if !command.isEmpty { commandBlock }
            if let detail {
                Text(detail)
                    .botCardBody()
                    .fixedSize(horizontal: false, vertical: true)
            }
            if row.body["persistent"]?.bool == true {
                Text("用户不在场，已转为待办。")
                    .botCardMeta()
                    .accessibilityIdentifier("bot.approval.persistent")
            }
            if case .failed(let reason) = model.actionStates[key] {
                Text("未能送出：\(reason)")
                    .botCardMeta()
                    .foregroundStyle(NativeParityTokens.error)
            }
            VStack(spacing: 8) {
                Button {
                    model.decide(row: row, decision: .allowOnce)
                } label: {
                    HStack(spacing: 8) {
                        if busy { ProgressView().tint(HomeSpec.primaryButtonInk) }
                        Text("允许一次")
                    }
                }
                .buttonStyle(BotCardButtonStyle(kind: .primary))
                .accessibilityIdentifier("bot.approval.once")
                if scope != "none" {
                    Button(scope == "session" ? "本次对话都允许" : "总是允许") {
                        model.decide(row: row, decision: .always)
                    }
                    .buttonStyle(BotCardButtonStyle(kind: .secondary))
                    .accessibilityIdentifier("bot.approval.always")
                }
                Button("拒绝") { model.decide(row: row, decision: .deny) }
                    .buttonStyle(BotCardButtonStyle(kind: .plain))
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("bot.approval.deny")
            }
            .disabled(busy)
        }
    }

    /// The command in a gray block: 13pt monospaced, 将执行 and 复制 on top.
    private var commandBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("将执行").botCardMeta()
                Spacer()
                Button(copied ? "已复制" : "复制") {
                    UIPasteboard.general.string = command
                    copied = true
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(HomeSpec.textPrimary)
                .buttonStyle(.plain)
                .frame(minWidth: 44, minHeight: 28, alignment: .trailing)
                .accessibilityIdentifier("bot.approval.copy")
            }
            Group {
                if expanded && longCommand {
                    ScrollView { commandText }.frame(maxHeight: 320)
                } else {
                    commandText.lineLimit(longCommand ? 5 : nil)
                }
            }
            if longCommand {
                Button(expanded ? "收起" : "展开全部") { expanded.toggle() }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(HomeSpec.textPrimary)
                    .buttonStyle(.plain)
                    .frame(minHeight: 28)
                    .accessibilityValue(expanded ? "已展开" : "已折叠")
                    .accessibilityIdentifier("bot.approval.expand")
            }
        }
        .padding(12)
        .background(HomeSpec.page, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var commandText: some View {
        Text(command)
            .font(.system(size: 13, design: .monospaced))
            .lineSpacing(HomeSpec.lineSpacing(size: 13, lineHeight: 18))
            .foregroundStyle(HomeSpec.textPrimary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Routine

/// A routine run: name and state, schedule, what it reported, duration.
private struct BotAutomationCardView: View {
    let row: BotUIRow
    private var automation: [String: BotJSONValue] { row.body["automation"]?.object ?? [:] }
    private var status: String {
        let value = row.body["status"]?.string ?? automation["status"]?.string ?? "sent"
        return ["confirming", "running", "sent", "failed", "idle"].contains(value) ? value : "sent"
    }
    private var stateTag: (text: String, tone: BotCardTone) {
        switch status {
        case "running": return ("执行中", .neutral)
        case "confirming": return ("待确认", .neutral)
        case "failed": return ("失败", .danger)
        case "idle": return ("待执行", .neutral)
        default: return ("已完成", .success)
        }
    }
    private var name: String {
        row.body.string("title", "name", "automationId") ?? automation.string("name", "automationId") ?? ""
    }
    private var schedule: String? { row.body["schedule"]?.string ?? automation["schedule"]?.string }
    private var timezone: String? { row.body["timezone"]?.string ?? automation["timezone"]?.string }
    private var context: String? { row.body["context"]?.string ?? automation["context"]?.string }
    private var quiet: Bool {
        row.body["quiet"]?.bool ?? automation["quiet"]?.bool ?? false
    }
    private var urgent: Bool {
        row.body["urgent"]?.bool ?? automation["urgent"]?.bool ?? false
    }
    /// Schedule and the human time-zone label stay on one meta line. The raw
    /// delivery mode never appears here.
    private var meta: String? {
        var parts: [String] = []
        if let schedule, !schedule.isEmpty { parts.append(schedule) }
        if let timezone, !timezone.isEmpty {
            parts.append(BotUIFormat.routineTimeZone(timezone))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
    private var contextText: String? {
        guard let context else { return nil }
        return BotUIFormat.routineAutomationContext(context)
    }
    private var result: String? { row.body.string("text", "result") ?? automation["message"]?.string }
    private var duration: String? {
        guard let milliseconds = row.body["durationMs"]?.number ?? automation["durationMs"]?.number,
              milliseconds > 0 else { return nil }
        return String(format: milliseconds < 10_000 ? "用时 %.1f 秒" : "用时 %.0f 秒", milliseconds / 1_000)
    }

    var body: some View {
        BotCardSurface {
            VStack(alignment: .leading, spacing: BotCardMetrics.blockGap) {
                BotCardHeading(icon: "repeat", eyebrow: "例行任务", title: name,
                               detail: meta) {
                    HStack(spacing: 4) {
                        if urgent {
                            BotCardTag(text: "紧急", tone: .warning)
                        }
                        if quiet {
                            BotCardTag(text: "安静时段")
                        }
                        BotCardTag(text: stateTag.text, tone: stateTag.tone)
                    }
                }
                if let contextText {
                    Text(contextText)
                        .botCardMeta()
                        .fixedSize(horizontal: false, vertical: true)
                }
                if result != nil || duration != nil {
                    BotCardDivider()
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(result ?? stateTag.text)
                            .botCardRow()
                            .foregroundStyle(status == "failed" ? NativeParityTokens.error : HomeSpec.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let duration {
                            Text(duration).botCardMeta().monospacedDigit()
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("bot.card.automation")
    }
}

// MARK: - Notice

/// A one-line outcome in the transcript, not a card: 15pt with a glyph,
/// red for a failure, gray for a denial.
private struct BotNoticeCardView: View {
    let row: BotUIRow

    /// `tone` is a presentation hint, not a visibility gate: info notices (for
    /// example the session-continuation line) stay neutral, while error and
    /// denial notices use the danger/secondary treatments.
    private var tone: String { row.body["tone"]?.string ?? "error" }
    private var denial: Bool { ["denied", "denial"].contains(tone) }
    private var info: Bool { ["info", "success", "warning", "neutral"].contains(tone) }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: denial ? "hand.raised" : (info ? "info.circle" : "exclamationmark.circle"))
                .font(.system(size: 14, weight: .medium))
            Text(row.body["text"]?.string ?? "")
                .botCardRow()
                .foregroundStyle(denial || info ? HomeSpec.textSecondary : NativeParityTokens.error)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(denial ? HomeSpec.textPlaceholder
                         : (info ? HomeSpec.textSecondary : NativeParityTokens.error))
        .accessibilityIdentifier("bot.card.notice")
    }
}
