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
        BotContentWidth {
            cardContent
        }
    }

    @ViewBuilder private var cardContent: some View {
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

// MARK: - Choice (question · steps)

/// The question (or 建议下一步) on top, one row per option split by
/// hairlines; 建议 is a tag, the picked option a check.
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
    private var prompt: String? {
        let value = card.body.string("question", "prompt")
        return isSteps && value == "建议下一步" ? nil : value
    }
    private var help: String? { card.body.string("helpText", "help") }
    private var muted: Bool { model.mutedCardIDs.contains(row.id) }
    private var answered: Bool { card.body["status"]?.string == "answered" }
    private var accepted: Bool { model.actionStates[key] == .accepted }
    private var locked: Bool {
        answered || muted || model.actionStates[key] == .pending || accepted
    }
    private var canDismiss: Bool { !isSteps && card.body["dismissible"]?.bool != false }

    var body: some View {
        BotCardSurface {
            VStack(alignment: .leading, spacing: 0) {
                BotCardHeading(icon: isSteps ? "sparkles" : "questionmark.circle",
                               eyebrow: isSteps ? "建议下一步" : "需要你选择",
                               title: prompt, detail: help) {
                    if canDismiss { dismissButton }
                }
                .padding(.bottom, choices.isEmpty ? 0 : 4)
                ForEach(Array(choices.enumerated()), id: \.element.id) { index, choice in
                    if index > 0 { BotCardDivider() }
                    option(choice)
                }
                statusLine
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var dismissButton: some View {
        Button { model.dismiss(row: row) } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(HomeSpec.textSecondary)
                .frame(width: 22, height: 22)
                .background(HomeSpec.userBubble, in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(locked)
        .padding(.vertical, -12)
        .padding(.trailing, -12)
        .accessibilityLabel("关闭卡片")
        .accessibilityIdentifier("bot.choice.dismiss")
    }

    private func option(_ choice: BotUIChoice) -> some View {
        Button {
            selectedID = choice.id
            model.answer(row: row, optionID: choice.id)
        } label: {
            BotCardRow(label: choice.label, detail: choice.description,
                       labelInk: choice.danger ? NativeParityTokens.error : HomeSpec.textPrimary) {
                EmptyView()
            } trailing: {
                if accepted && selectedID == choice.id {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(HomeSpec.textPrimary)
                } else if choice.recommended {
                    BotCardTag(text: "建议")
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(HomeSpec.iconMuted)
                }
            }
        }
        .buttonStyle(BotCardRowButtonStyle())
        .disabled(locked)
        .opacity(muted && selectedID != choice.id ? 0.45 : 1)
        .accessibilityLabel(choice.recommended ? "\(choice.label)，建议" : choice.label)
        .accessibilityIdentifier("bot.choice.option.\(choice.id)")
    }

    @ViewBuilder private var statusLine: some View {
        if accepted || answered {
            Label("已送出", systemImage: "checkmark")
                .botCardMeta()
                .padding(.top, 8)
        } else if muted {
            Text("已略过")
                .botCardMeta()
                .padding(.top, 8)
        } else if case .failed(let reason) = model.actionStates[key] {
            Text("未能送出：\(reason)")
                .botCardMeta()
                .foregroundStyle(NativeParityTokens.error)
                .padding(.top, 8)
        }
    }
}

// MARK: - Task

/// A background task: title with its state, folded step list.
private struct BotTaskCardView: View {
    let row: BotUIRow
    @State private var expanded = false

    private var steps: [BotUIProgressStep] { BotUIProgressStep.parseList(row.body["tasks"] ?? row.body["steps"]) }
    private var title: String { row.body.string("title", "text", "question") ?? "后台任务" }
    private var doneCount: Int { steps.filter { BotCardStepState($0.state) == .done }.count }
    private var failed: Bool { steps.contains { BotCardStepState($0.state) == .failed } }
    private var running: Bool {
        let status = row.body["status"]?.string ?? row.body["task"]?.object?["status"]?.string
        return status == "running" || steps.contains { BotCardStepState($0.state) == .active }
    }
    private var stateTag: (text: String, tone: BotCardTone) {
        if failed { return ("失败", .danger) }
        if running { return ("进行中", .neutral) }
        return ("已完成", .success)
    }

    private var verification: [String: BotJSONValue]? { row.body["verification"]?.object }
    private var verificationVerdict: String? {
        guard let raw = verification?["verdict"]?.string else { return nil }
        return ["passed", "failed", "uncertain"].contains(raw) ? raw : nil
    }
    private var verificationTone: BotCardTone {
        switch verificationVerdict {
        case "passed": return .success
        case "failed": return .danger
        default: return .warning
        }
    }
    private var verificationLabel: String {
        switch verificationVerdict {
        case "passed": return "验证通过"
        case "failed": return "验证未通过"
        default: return "验证不确定"
        }
    }
    private var verificationSummary: String? {
        verification?["summary"]?.string
    }
    private var verificationRefCount: Int {
        verification?["refs"]?.array?.count ?? 0
    }

    var body: some View {
        BotCardSurface {
            VStack(alignment: .leading, spacing: 0) {
                BotCardHeading(icon: "checklist", eyebrow: "后台任务", title: title) {
                    BotCardTag(text: stateTag.text, tone: stateTag.tone)
                }
                if let verificationVerdict {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Image(systemName: verificationVerdict == "passed"
                                  ? "checkmark.seal" : verificationVerdict == "failed"
                                  ? "xmark.octagon" : "questionmark.circle")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(verificationTone.ink)
                            Text(verificationLabel)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(verificationTone.ink)
                            if verificationRefCount > 0 {
                                Text("依据 \(verificationRefCount) 条记录")
                                    .botCardMeta()
                            }
                        }
                        if let verificationSummary, !verificationSummary.isEmpty {
                            Text(verificationSummary)
                                .botCardMeta()
                                .lineLimit(3)
                        }
                    }
                    .padding(.top, 8)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("bot.task.verification")
                }
                if !steps.isEmpty {
                    Button { withAnimation(.easeOut(duration: 0.16)) { expanded.toggle() } } label: {
                        HStack(spacing: 4) {
                            Text(expanded ? "收起步骤" : "查看步骤")
                            Text("\(doneCount)/\(steps.count)").monospacedDigit()
                            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 11, weight: .semibold))
                            Spacer(minLength: 0)
                        }
                        .botCardMeta()
                        // Keep the dense 13pt visual while meeting the 44pt
                        // minimum touch target from bot-chat.md §2.
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(BotCardRowButtonStyle())
                    .padding(.top, 4)
                    .accessibilityValue(expanded ? "已展开" : "已折叠")
                    .accessibilityIdentifier("bot.task.toggle")
                    if expanded {
                        VStack(spacing: 0) {
                            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                                if index > 0 { BotCardDivider(inset: BotCardMetrics.glyphColumn + 12) }
                                let state = BotCardStepState(step.state)
                                BotCardRow(label: step.label, detail: step.detail,
                                           labelInk: state == .pending ? HomeSpec.textSecondary : HomeSpec.textPrimary) {
                                    BotCardGlyph(systemImage: state.glyph, ink: state.ink)
                                } trailing: { EmptyView() }
                            }
                        }
                        .accessibilityIdentifier("bot.task.steps")
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Attachment

/// One file: tile, name and caption, 打开 on the right.
private struct BotAttachmentCardView: View {
    let row: BotUIRow
    let actions: BotCardActions

    private var path: String? { row.body["path"]?.string }
    private var name: String {
        if let explicit = row.body.string("fileName", "name") { return explicit }
        return path?.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? path ?? ""
    }
    private var icon: String { BotCardFileIcon.name(for: name, mime: row.body["mimeType"]?.string) }

    var body: some View {
        BotCardSurface {
            HStack(spacing: 12) {
                BotCardTile(systemImage: icon)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .botCardRow(weight: .medium)
                        .lineLimit(2)
                    if let detail = row.body.string("caption", "size", "description") {
                        Text(detail)
                            .botCardMeta()
                            .lineLimit(1)
                    }
                }
                if let path {
                    Button("打开") { actions.openPath(path) }
                        .buttonStyle(BotCardButtonStyle(kind: .plain))
                        .accessibilityIdentifier("bot.attachment.open")
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

enum BotCardFileIcon {
    static func name(for fileName: String, mime: String?) -> String {
        let mime = mime ?? ""
        let ext = (fileName as NSString).pathExtension.lowercased()
        if mime.hasPrefix("image/") || ["png", "jpg", "jpeg", "gif", "heic"].contains(ext) { return "photo" }
        if mime.contains("pdf") || ext == "pdf" { return "doc.richtext" }
        if mime.hasPrefix("video/") { return "play.rectangle" }
        if mime.hasPrefix("audio/") { return "waveform" }
        if ["zip", "tar", "gz"].contains(ext) { return "archivebox" }
        if ["md", "markdown", "txt"].contains(ext) { return "doc.text" }
        return "doc"
    }
}

// MARK: - Document

/// A document: kind, title, summary, contents list, file row with 打开.
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
    private var summary: String? { row.body.string("summary", "description", "caption") }
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
    private var fileName: String { row.body.string("fileName") ?? title }

    var body: some View {
        BotCardSurface {
            VStack(alignment: .leading, spacing: BotCardMetrics.blockGap) {
                BotCardHeading(icon: "doc.text", eyebrow: "文档 · \(typeLabel)", title: title)
                if let summary {
                    Text(summary)
                        .botCardBody()
                        .lineLimit(expanded ? nil : 3)
                        .fixedSize(horizontal: false, vertical: true)
                        .onTapGesture { expanded.toggle() }
                }
                if !toc.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("本页内容").botCardMeta()
                        ForEach(Array(toc.enumerated()), id: \.offset) { index, item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("\(index + 1)")
                                    .botCardMeta()
                                    .monospacedDigit()
                                    .frame(width: 14, alignment: .trailing)
                                Text(item)
                                    .botCardRow()
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                BotCardDivider()
                HStack(spacing: 12) {
                    BotCardTile(systemImage: BotCardFileIcon.name(for: fileName, mime: nil))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(fileName)
                            .botCardRow(weight: .medium)
                            .lineLimit(1)
                        if let size = row.body["size"]?.string {
                            Text(size).botCardMeta()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button("打开") { actions.openDocument(row) }
                        .buttonStyle(BotCardButtonStyle(kind: .plain))
                        .accessibilityIdentifier("bot.document.open")
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}
