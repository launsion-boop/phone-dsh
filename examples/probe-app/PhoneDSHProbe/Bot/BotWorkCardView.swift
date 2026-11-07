// SPDX-License-Identifier: MIT

import SwiftUI
import UIKit

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
        return Int((Double(steps.filter { $0.state == "done" }.count) / Double(steps.count) * 100).rounded())
    }
    private var stateLabel: String {
        switch state {
        case "done": return "已完成"
        case "paused": return "已暂停"
        case "failed": return "失败"
        case "cancelled": return "已取消"
        default: return "进行中"
        }
    }
    private var tone: BotStatusTone {
        switch state {
        case "done": return .success
        case "paused": return .warning
        case "failed": return .danger
        case "cancelled": return .neutral
        default: return .accent
        }
    }

    var body: some View {
        BotCard(.work) {
            VStack(alignment: .leading, spacing: 12) {
                BotCardHeader(title: title, status: stateLabel, tone: tone)
                if let summary = row.body.string("summary", "description") {
                    Text(summary)
                        .botSecondaryFont()
                        .foregroundStyle(HomeSpec.textSecondary)
                        .lineLimit(2)
                }
                if let percent {
                    HStack(spacing: 12) {
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule().fill(NativeParityTokens.selector)
                                Capsule().fill(tone.color)
                                    .frame(width: geometry.size.width * CGFloat(percent) / 100)
                            }
                        }
                        .frame(height: 4)
                        .accessibilityLabel("完成进度 \(percent)%")
                        Text("\(percent)%")
                            .botCaptionFont()
                            .monospacedDigit()
                            .foregroundStyle(HomeSpec.textTertiary)
                    }
                }
                if !steps.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(expanded ? steps : Array(steps.prefix(4))) { step in
                            HStack(spacing: 8) {
                                Image(systemName: icon(for: step.state))
                                    .font(.system(size: 14))
                                    .foregroundStyle(color(for: step.state))
                                    .frame(width: 18)
                                Text(step.label)
                                    .botProcessFont(weight: step.state == "active" ? .medium : .regular)
                                    .foregroundStyle(step.state == "done" ? HomeSpec.textSecondary : HomeSpec.textPrimary)
                                    .strikethrough(step.state == "skipped")
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if let detail = step.detail {
                                    Text(detail)
                                        .botCaptionFont()
                                        .monospacedDigit()
                                        .foregroundStyle(HomeSpec.textTertiary)
                                        .lineLimit(1)
                                }
                            }
                            .frame(minHeight: 32)
                        }
                    }
                    if steps.count > 4 {
                        Button(expanded ? "收起" : "显示全部 \(steps.count) 步") { expanded.toggle() }
                            .buttonStyle(BotTextButtonStyle())
                        .botHitTarget()
                            .accessibilityValue(expanded ? "已展开" : "已折叠")
                            .accessibilityIdentifier("bot.progress.more")
                    }
                }
                if let eta = row.body["eta"]?.string {
                    Label(eta, systemImage: "clock")
                        .botCaptionFont()
                        .foregroundStyle(HomeSpec.textSecondary)
                }
            }
        }
        .opacity(state == "cancelled" ? 0.72 : 1)
        .accessibilityElement(children: .contain)
    }

    private func icon(for state: String) -> String {
        switch state {
        case "done": return "checkmark.circle.fill"
        case "active": return "circle.lefthalf.filled"
        case "failed": return "exclamationmark.circle"
        case "skipped": return "minus.circle"
        default: return "circle"
        }
    }

    private func color(for state: String) -> Color {
        switch state {
        case "done": return NativeParityTokens.success
        case "active": return NativeParityTokens.accent
        case "failed": return NativeParityTokens.error
        default: return HomeSpec.textTertiary
        }
    }
}

private struct BotChecklistCardView: View {
    let row: BotUIRow
    @ObservedObject var model: BotChatModel
    @State private var items: [BotUIChecklistItem]
    @State private var dirty = false
    @State private var sent = false

    init(row: BotUIRow, model: BotChatModel) {
        self.row = row
        self.model = model
        _items = State(initialValue: BotUIChecklistItem.parseList(row.body["items"]))
    }

    private var interactive: Bool { row.body["interactive"]?.bool != false }
    private var title: String { row.body["title"]?.string ?? "" }
    private var doneCount: Int { items.filter(\.done).count }
    private var message: String {
        let pending = items.filter { !$0.done && !$0.synthetic }.map(\.text)
        let head = "\(title)：已完成 \(doneCount)／\(items.count)。"
        return pending.isEmpty ? "\(head)全部完成。" : "\(head)未完成：\(pending.joined(separator: "、"))"
    }

    var body: some View {
        BotCard(.work) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    Text(title)
                        .botTitleFont()
                        .foregroundStyle(HomeSpec.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(doneCount == items.count ? "已完成" : "\(doneCount)／\(items.count) 已完成")
                        .botCaptionFont(weight: .medium)
                        .foregroundStyle(doneCount == items.count ? NativeParityTokens.success : HomeSpec.textTertiary)
                }
                if let summary = row.body["summary"]?.string {
                    Text(summary)
                        .botSecondaryFont()
                        .foregroundStyle(HomeSpec.textSecondary)
                }
                VStack(spacing: 4) {
                    ForEach($items) { $item in
                        Button {
                            guard interactive, !item.synthetic else { return }
                            item.done.toggle()
                            dirty = true
                            sent = false
                        } label: {
                            HStack(alignment: .center, spacing: 12) {
                                Image(systemName: item.done ? "checkmark.square.fill" : "square")
                                    .font(.system(size: 18))
                                    .foregroundStyle(item.done ? NativeParityTokens.accent : HomeSpec.textTertiary)
                                Text(item.text)
                                    .botProcessFont()
                                    .foregroundStyle(HomeSpec.textPrimary)
                                    .strikethrough(item.done)
                                    .opacity(item.done ? 0.55 : 1)
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if let note = item.note {
                                    Text(note)
                                        .botCaptionFont()
                                        .foregroundStyle(HomeSpec.textTertiary)
                                        .lineLimit(1)
                                }
                            }
                            .padding(.horizontal, 4)
                            .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .disabled(!interactive || item.synthetic)
                        .accessibilityLabel(item.text)
                        .accessibilityValue(item.done ? "已完成" : "未完成")
                        .accessibilityIdentifier("bot.checklist.item.\(item.id)")
                    }
                }
                if interactive && dirty {
                    Button(sent ? "已送出勾选结果" : "把勾选结果传给 Bot") {
                        guard !sent else { return }
                        sent = true
                        model.send(text: message)
                    }
                    .buttonStyle(BotTextButtonStyle())
                        .botHitTarget()
                    .disabled(sent)
                    .accessibilityIdentifier("bot.checklist.send")
                }
            }
        }
        .onChange(of: row.body) { _, _ in
            items = BotUIChecklistItem.parseList(row.body["items"])
            dirty = false
            sent = false
        }
        .accessibilityElement(children: .contain)
    }
}

private struct BotLinkCardView: View {
    let row: BotUIRow
    let actions: BotCardActions
    private var links: [BotUILink] { BotUILink.parseList(row.body["links"]) }

    var body: some View {
        BotCard(.work) {
            VStack(alignment: .leading, spacing: 8) {
                if let title = row.body["title"]?.string {
                    Text(title)
                        .botTitleFont()
                        .foregroundStyle(HomeSpec.textPrimary)
                }
                ForEach(links) { link in
                    Button { actions.openURL(link.url) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: icon(for: link.kind))
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(NativeParityTokens.labelSecondary)
                                .frame(width: 36, height: 36)
                                .background(NativeParityTokens.selector, in: RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(link.title)
                                    .botProcessFont(weight: .medium)
                                    .foregroundStyle(HomeSpec.textPrimary)
                                    .lineLimit(1)
                                Text(link.site)
                                    .botCaptionFont()
                                    .foregroundStyle(HomeSpec.textTertiary)
                                    .lineLimit(1)
                                if let description = link.description {
                                    Text(description)
                                        .botSecondaryFont()
                                        .foregroundStyle(HomeSpec.textSecondary)
                                        .lineLimit(links.count == 1 ? 2 : 1)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "arrow.up.right")
                                .foregroundStyle(HomeSpec.textTertiary)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, minHeight: 56)
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
        default: return "book"
        }
    }
}

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
    private var longCommand: Bool { command.count > 240 || command.split(separator: "\n", omittingEmptySubsequences: false).count > 5 }
    private var highRisk: Bool {
        let risk = row.body["risk"]?.object
        return risk?["level"]?.string == "high" || risk?["tags"]?.array?.contains(.string("irreversible")) == true
    }
    private var statusLabel: String {
        switch status {
        case "allowed": return "已允许一次"
        case "always": return scope == "session" ? "本次对话允许" : "已允许（总是）"
        case "denied", "never": return "已拒绝"
        case "timed-out": return "已超时（视为拒绝）"
        default: return "已处理"
        }
    }

    var body: some View {
        BotCard(.approval) {
            VStack(alignment: .leading, spacing: 12) {
                if pending {
                    pendingContent
                } else {
                    HStack(spacing: 12) {
                        Image(systemName: status == "allowed" || status == "always" ? "checkmark.circle" : "shield")
                            .foregroundStyle(status == "allowed" || status == "always" ? NativeParityTokens.success : HomeSpec.textTertiary)
                        Text(statusLabel)
                            .botProcessFont(weight: .semibold)
                            .foregroundStyle(HomeSpec.textSecondary)
                        Text(action)
                            .botSecondaryFont()
                            .foregroundStyle(HomeSpec.textSecondary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 44)
                    if !command.isEmpty {
                        Text(command)
                            .botCaptionFont()
                            .monospaced()
                            .foregroundStyle(HomeSpec.textTertiary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var pendingContent: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 18))
                .foregroundStyle(highRisk ? NativeParityTokens.warning : NativeParityTokens.labelSecondary)
                .frame(width: 32, height: 32)
                .background(NativeParityTokens.selector, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                Text("需要你确认 · 执行前审批")
                    .botCaptionFont(weight: .semibold)
                    .foregroundStyle(HomeSpec.textSecondary)
                Text(row.body["title"]?.string ?? "允许执行这个操作吗？")
                    .botTitleFont()
                    .foregroundStyle(HomeSpec.textPrimary)
                    .lineLimit(3)
                Text(action)
                    .botSecondaryFont()
                    .foregroundStyle(HomeSpec.textSecondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if highRisk { BotStatusPill(text: "高风险", tone: .warning) }
        }
        if !command.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("将执行")
                        .botCaptionFont(weight: .medium)
                        .foregroundStyle(HomeSpec.textSecondary)
                    Spacer()
                    Button(copied ? "已复制" : "复制") {
                        UIPasteboard.general.string = command
                        copied = true
                    }
                    .buttonStyle(BotTextButtonStyle())
                        .botHitTarget()
                    .accessibilityIdentifier("bot.approval.copy")
                }
                commandText
                if longCommand {
                    Button(expanded ? "收起" : "展开全部") { expanded.toggle() }
                        .buttonStyle(BotTextButtonStyle())
                        .botHitTarget()
                        .accessibilityValue(expanded ? "已展开" : "已折叠")
                        .accessibilityIdentifier("bot.approval.expand")
                }
            }
            .padding(12)
            .background(HomeSpec.surface.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
        }
        if let detail {
            Text(detail)
                .botSecondaryFont()
                .foregroundStyle(HomeSpec.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if scope == "none" {
            Text("此操作不提供常设允许，仅能拒绝或允许一次。")
                .botCaptionFont()
                .foregroundStyle(HomeSpec.textSecondary)
        }
        if case .failed(let reason) = model.actionStates[key] {
            Text("未能送出：\(reason)")
                .botSecondaryFont()
                .foregroundStyle(NativeParityTokens.error)
        }
        VStack(spacing: 8) {
            Button {
                model.decide(row: row, decision: .allowOnce)
            } label: {
                HStack {
                    if busy { ProgressView().tint(HomeSpec.primaryButtonInk) }
                    Text("允许一次")
                }
            }
            .buttonStyle(BotPrimaryButtonStyle())
            .disabled(busy)
            .accessibilityIdentifier("bot.approval.once")
            if scope != "none" {
                Button(scope == "session" ? "本次对话允许" : "总是允许") {
                    model.decide(row: row, decision: .always)
                }
                .buttonStyle(BotSecondaryButtonStyle())
                .disabled(busy)
                .accessibilityIdentifier("bot.approval.always")
            }
            Button("拒绝") { model.decide(row: row, decision: .deny) }
                .buttonStyle(BotTextButtonStyle())
                        .botHitTarget()
                .foregroundStyle(HomeSpec.textSecondary)
                .disabled(busy)
                .accessibilityIdentifier("bot.approval.deny")
        }
        .disabled(busy)
    }

    @ViewBuilder private var commandText: some View {
        if expanded && longCommand {
            ScrollView {
                Text(command)
                    .botCaptionFont()
                    .monospaced()
                    .foregroundStyle(HomeSpec.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 320)
        } else {
            Text(command)
                .botCaptionFont()
                .monospaced()
                .foregroundStyle(HomeSpec.textPrimary)
                .lineLimit(longCommand ? 5 : nil)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct BotAutomationCardView: View {
    let row: BotUIRow
    private var automation: [String: BotJSONValue] { row.body["automation"]?.object ?? [:] }
    private var status: String {
        let value = row.body["status"]?.string ?? automation["status"]?.string ?? "sent"
        return ["confirming", "running", "sent", "failed", "idle"].contains(value) ? value : "sent"
    }
    private var label: String {
        switch status {
        case "running": return "执行中"
        case "confirming": return "待确认"
        case "failed": return "失败"
        case "idle": return "待执行"
        default: return "已完成"
        }
    }
    private var tone: BotStatusTone {
        switch status {
        case "failed": return .danger
        case "sent": return .success
        case "running": return .accent
        default: return .neutral
        }
    }
    private var name: String {
        row.body.string("title", "name", "automationId") ?? automation.string("name", "automationId") ?? ""
    }

    var body: some View {
        BotCard(.inline) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    BotIconTile(systemImage: "repeat")
                    VStack(alignment: .leading, spacing: 4) {
                        Text(name)
                            .botTitleFont()
                            .foregroundStyle(HomeSpec.textPrimary)
                            .lineLimit(2)
                        if let schedule = row.body["schedule"]?.string ?? automation["schedule"]?.string {
                            Label(schedule, systemImage: "clock")
                                .botCaptionFont()
                                .foregroundStyle(HomeSpec.textSecondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    BotStatusPill(text: label, tone: tone,
                                  systemImage: status == "sent" ? "checkmark.circle" : status == "failed" ? "exclamationmark.circle" : "clock")
                }
                if let context = row.body["context"]?.string ?? automation["context"]?.string {
                    Text(context)
                        .botSecondaryFont()
                        .foregroundStyle(HomeSpec.textSecondary)
                        .lineLimit(3)
                }
                HStack(spacing: 8) {
                    Text(row.body.string("text", "result") ?? automation["message"]?.string ?? label)
                        .botSecondaryFont()
                        .foregroundStyle(status == "failed" ? NativeParityTokens.error : HomeSpec.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let milliseconds = row.body["durationMs"]?.number ?? automation["durationMs"]?.number,
                       milliseconds > 0 {
                        Text(String(format: milliseconds < 10_000 ? "%.1fs" : "%.0fs", milliseconds / 1_000))
                            .botCaptionFont()
                            .monospacedDigit()
                            .foregroundStyle(HomeSpec.textTertiary)
                    }
                }
            }
        }
        .accessibilityIdentifier("bot.card.automation")
    }
}

private struct BotNoticeCardView: View {
    let row: BotUIRow
    private var denial: Bool { ["denied", "denial"].contains(row.body["tone"]?.string ?? "") }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: denial ? "shield" : "exclamationmark.triangle")
                .foregroundStyle(denial ? HomeSpec.textTertiary : NativeParityTokens.error)
            Text(row.body["text"]?.string ?? "")
                .botSecondaryFont()
                .foregroundStyle(denial ? HomeSpec.textSecondary : NativeParityTokens.error)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("bot.card.notice")
    }
}
