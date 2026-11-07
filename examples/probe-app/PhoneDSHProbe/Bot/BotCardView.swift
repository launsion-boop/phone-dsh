// SPDX-License-Identifier: MIT

import SwiftUI
import UIKit

struct BotCardActions {
    var openURL: (URL) -> Void = { UIApplication.shared.open($0) }
    var openPath: (String) -> Void = { _ in }
    var openDocument: (BotUIRow) -> Void = { _ in }
}

struct BotCardView: View {
    let row: BotUIRow
    let card: BotUICardContent
    @ObservedObject var model: BotChatModel
    let actions: BotCardActions

    var body: some View {
        switch card.kind {
        case .question, .steps:
            BotChoiceCardView(row: row, card: card, model: model)
        case .task:
            BotTaskCardView(row: row)
        case .attachment:
            BotAttachmentCardView(row: row, actions: actions)
        case .document:
            BotDocumentCardView(row: row, actions: actions)
        case .progress, .checklist, .link, .approval, .automation, .notice:
            BotWorkCardView(row: row, card: card, model: model, actions: actions)
        }
    }
}

private struct BotChoiceCardView: View {
    let row: BotUIRow
    let card: BotUICardContent
    @ObservedObject var model: BotChatModel
    @State private var selectedID: String?

    private var isSteps: Bool { card.kind == .steps }
    private var key: String { "card:\(row.id)" }
    private var choices: [BotUIChoice] {
        BotUIChoice.parseList(card.body[isSteps ? "steps" : "options"])
    }
    private var prompt: String {
        card.body.string("question", "prompt") ?? (isSteps ? "建议下一步" : "")
    }
    private var help: String? { card.body.string("helpText", "help") }
    private var muted: Bool { model.mutedCardIDs.contains(row.id) }
    private var answered: Bool { card.body["status"]?.string == "answered" }
    private var locked: Bool {
        answered || muted || model.actionStates[key] == .pending || model.actionStates[key] == .accepted
    }
    private var canDismiss: Bool {
        !isSteps && card.body["dismissible"]?.bool != false
    }

    var body: some View {
        BotCard(.conversation) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 6) {
                        if isSteps {
                            Label("建议下一步", systemImage: "sparkles")
                                .botCaptionFont(weight: .semibold)
                                .foregroundStyle(HomeSpec.textSecondary)
                        }
                        if !prompt.isEmpty && !(isSteps && prompt == "建议下一步") {
                            Text(prompt)
                                .botTitleFont()
                                .foregroundStyle(HomeSpec.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let help {
                            Text(help)
                                .botSecondaryFont()
                                .foregroundStyle(HomeSpec.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if canDismiss && !isSteps {
                        Button { model.dismiss(row: row) } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .medium))
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(HomeSpec.textSecondary)
                        .disabled(locked)
                        .accessibilityLabel("关闭卡片")
                        .accessibilityIdentifier("bot.choice.dismiss")
                    }
                }

                VStack(spacing: 8) {
                    ForEach(choices) { choice in
                        Button {
                            selectedID = choice.id
                            model.answer(row: row, optionID: choice.id)
                        } label: {
                            HStack(alignment: .center, spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(choice.label)
                                        .botProcessFont(weight: .medium)
                                        .foregroundStyle(choice.danger ? NativeParityTokens.error : HomeSpec.textPrimary)
                                        .lineLimit(2)
                                    if let description = choice.description {
                                        Text(description)
                                            .botSecondaryFont()
                                            .foregroundStyle(HomeSpec.textSecondary)
                                            .lineLimit(2)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                if model.actionStates[key] == .accepted && selectedID == choice.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(NativeParityTokens.success)
                                } else if choice.recommended {
                                    Text("建议")
                                        .botCaptionFont(weight: .medium)
                                        .foregroundStyle(NativeParityTokens.accent)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(HomeSpec.surface, in: Capsule())
                                } else {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 13))
                                        .foregroundStyle(HomeSpec.textTertiary)
                                }
                            }
                            .padding(.horizontal, 12)
                            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                            .background(choice.recommended ? NativeParityTokens.accent.opacity(0.06) : NativeParityTokens.selector,
                                        in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .disabled(locked)
                        .opacity(muted && selectedID != choice.id ? 0.55 : 1)
                        .accessibilityLabel(choice.recommended ? "\(choice.label)，建议" : choice.label)
                        .accessibilityIdentifier("bot.choice.option.\(choice.id)")
                    }
                }

                if model.actionStates[key] == .accepted || answered {
                    Label("已送出", systemImage: "checkmark")
                        .botSecondaryFont()
                        .foregroundStyle(HomeSpec.textSecondary)
                } else if muted {
                    Text("已略过")
                        .botSecondaryFont()
                        .foregroundStyle(HomeSpec.textSecondary)
                } else if case .failed(let reason) = model.actionStates[key] {
                    Text("未能送出：\(reason)")
                        .botSecondaryFont()
                        .foregroundStyle(NativeParityTokens.error)
                }

            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct BotTaskCardView: View {
    let row: BotUIRow
    @State private var expanded = false

    private var steps: [BotUIProgressStep] {
        let raw = row.body["tasks"] ?? row.body["steps"]
        return BotUIProgressStep.parseList(raw).map { step in
            var normalized = step
            if ["running", "in_progress", "working"].contains(step.state) { normalized.state = "active" }
            if ["completed", "complete", "success", "ok", "sent"].contains(step.state) { normalized.state = "done" }
            if ["error", "failure", "blocked"].contains(step.state) { normalized.state = "failed" }
            return normalized
        }
    }

    private var title: String { row.body.string("title", "text", "question") ?? "后台任务" }
    private var doneCount: Int { steps.filter { $0.state == "done" }.count }
    private var failed: Bool { steps.contains { $0.state == "failed" } }
    private var running: Bool {
        let status = row.body["status"]?.string ?? row.body["task"]?.object?["status"]?.string
        return status == "running" || steps.contains { $0.state == "active" }
    }

    var body: some View {
        BotCard(.work) {
            VStack(alignment: .leading, spacing: 8) {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 12) {
                        Image(systemName: failed ? "exclamationmark.circle" : running ? "clock" : "checkmark.circle")
                            .foregroundStyle(failed ? NativeParityTokens.error : running ? NativeParityTokens.accent : NativeParityTokens.success)
                        Text(title)
                            .botTitleFont()
                            .foregroundStyle(HomeSpec.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if !steps.isEmpty {
                            Text("\(doneCount)/\(steps.count)")
                                .botCaptionFont(weight: .medium)
                                .foregroundStyle(HomeSpec.textSecondary)
                        }
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .foregroundStyle(HomeSpec.textTertiary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .contentShape(Rectangle())
                .accessibilityValue(expanded ? "已展开" : "已折叠")
                .accessibilityIdentifier("bot.task.toggle")
                if expanded && !steps.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(steps) { step in
                            HStack(spacing: 8) {
                                Image(systemName: step.state == "done" ? "checkmark.circle" : step.state == "failed" ? "exclamationmark.circle" : "circle")
                                    .foregroundStyle(step.state == "failed" ? NativeParityTokens.error : HomeSpec.textSecondary)
                                Text(step.label)
                                    .botSecondaryFont()
                                    .foregroundStyle(HomeSpec.textSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(minHeight: 32)
                        }
                    }
                    .accessibilityIdentifier("bot.task.steps")
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct BotAttachmentCardView: View {
    let row: BotUIRow
    let actions: BotCardActions

    private var path: String? { row.body["path"]?.string }
    private var name: String {
        if let explicit = row.body.string("fileName", "name") { return explicit }
        return path?.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? path ?? ""
    }
    private var icon: String {
        let mime = row.body["mimeType"]?.string ?? ""
        let ext = (name as NSString).pathExtension.lowercased()
        if mime.hasPrefix("image/") || ["png", "jpg", "jpeg", "gif", "heic"].contains(ext) { return "photo" }
        if mime.contains("pdf") || ext == "pdf" { return "doc.richtext" }
        if mime.hasPrefix("video/") { return "play.rectangle" }
        if mime.hasPrefix("audio/") { return "waveform" }
        if ["zip", "tar", "gz"].contains(ext) { return "archivebox" }
        return "doc"
    }

    var body: some View {
        BotCard(.object) {
            HStack(spacing: 12) {
                BotIconTile(systemImage: icon)
                VStack(alignment: .leading, spacing: 4) {
                    Text(name)
                        .botTitleFont()
                        .foregroundStyle(HomeSpec.textPrimary)
                        .lineLimit(2)
                    if let detail = row.body.string("caption", "size", "description") {
                        Text(detail)
                            .botSecondaryFont()
                            .foregroundStyle(HomeSpec.textSecondary)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let path {
                    Button("打开") { actions.openPath(path) }
                        .buttonStyle(.plain)
                        .foregroundStyle(NativeParityTokens.labelSecondary)
                        .frame(width: 64, height: 44)
                        .contentShape(Rectangle())
                        .accessibilityIdentifier("bot.attachment.open")
                }
            }
            .frame(maxWidth: .infinity, minHeight: 52)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct BotDocumentCardView: View {
    let row: BotUIRow
    let actions: BotCardActions
    @State private var expanded = false

    private var path: String? { row.body.string("path", "url") }
    private var title: String {
        row.body.string("title", "name", "fileName")
            ?? path?.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init)
            ?? row.body["summary"]?.string ?? ""
    }
    private var toc: [String] {
        (row.body["toc"]?.array ?? []).prefix(6).compactMap { value in
            value.string ?? value.object?.string("title", "label", "text")
        }
    }
    private var typeLabel: String {
        if let label = row.body.string("docTypeLabel", "kindLabel") { return label }
        switch row.body["docKind"]?.string {
        case "markdown": return "Markdown"
        case "pdf": return "PDF"
        case "code": return "代码"
        case "table": return "表格"
        default: return "页面"
        }
    }

    var body: some View {
        BotCard(.object) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(typeLabel, systemImage: "doc.text")
                        .botCaptionFont(weight: .medium)
                        .foregroundStyle(HomeSpec.textSecondary)
                    Spacer()
                    Button("打开") { actions.openDocument(row) }
                        .buttonStyle(BotTextButtonStyle())
                        .botHitTarget()
                        .accessibilityIdentifier("bot.document.open")
                }
                Text(title)
                    .botTitleFont()
                    .foregroundStyle(HomeSpec.textPrimary)
                    .lineLimit(expanded ? nil : 2)
                if let summary = row.body.string("summary", "description", "caption") {
                    Text(summary)
                        .botProcessFont()
                        .foregroundStyle(HomeSpec.textSecondary)
                        .lineLimit(expanded ? nil : 2)
                }
                if !toc.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("本页内容")
                            .botCaptionFont(weight: .semibold)
                            .foregroundStyle(HomeSpec.textSecondary)
                        ForEach(Array(toc.enumerated()), id: \.offset) { index, item in
                            HStack(alignment: .top, spacing: 8) {
                                Text("\(index + 1).")
                                    .foregroundStyle(HomeSpec.textTertiary)
                                Text(item)
                                    .foregroundStyle(HomeSpec.textSecondary)
                                    .lineLimit(1)
                            }
                            .botSecondaryFont()
                        }
                    }
                    .padding(12)
                    .background(NativeParityTokens.selector.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
                }
                HStack(spacing: 8) {
                    Image(systemName: "doc.text")
                    Text(row.body.string("fileName") ?? title)
                        .lineLimit(1)
                    Spacer()
                    if let size = row.body["size"]?.string { Text(size) }
                }
                .botCaptionFont()
                .foregroundStyle(HomeSpec.textTertiary)
                if title.count > 80 || (row.body["summary"]?.string?.count ?? 0) > 160 {
                    Button(expanded ? "收起" : "展开") { expanded.toggle() }
                        .buttonStyle(BotTextButtonStyle())
                        .botHitTarget()
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}
