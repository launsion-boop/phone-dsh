// SPDX-License-Identifier: MIT

import SwiftUI
import UIKit
import PDFKit
import PhoneDSHBot

struct BotCardActions {
    var openURL: (URL) -> Void = { UIApplication.shared.open($0) }
    /// Opens one attachment path. The default does nothing; a card renders
    /// its open button only when `canOpenPath` says the host can act, so this
    /// empty default can never become a silent dead button.
    var openPath: (String) -> Void = { _ in }
    /// The host's capability answer for `openPath`. Defaults to false: a
    /// caller that has no preview implementation must not show the control.
    var canOpenPath: (String) -> Bool = { _ in false }
    var openDocument: (BotUIRow) -> Void = { _ in }
}

struct BotCardView: View {
    let row: BotUIRow
    let card: BotUICardContent
    @ObservedObject var model: BotChatModel
    let actions: BotCardActions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var settlement: BotCardSettlement? { model.settlement(for: row) }

    var body: some View {
        BotContentWidth {
            Group {
                if let settlement {
                    // No surface: a handled card is just one grey line.
                    BotCardSettledLine(settlement: settlement)
                        .transition(.opacity)
                } else {
                    cardContent
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: settlement)
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
        return isSteps ? nil : value
    }
    private var help: String? { card.body.string("helpText", "help") }
    /// The durable verdict of the projection: a newer question/steps card
    /// replaced this one, so the planner refuses it (`card_expired`). The card
    /// normally settles into its grey one-line summary through
    /// `BotChatModel.settlement`; this flag keeps the options disabled if it is
    /// ever drawn in full, so a stale card can never look tappable.
    private var superseded: Bool { card.body["status"]?.string == "superseded" }
    private var answered: Bool { card.body["status"]?.string == "answered" }
    private var accepted: Bool { model.actionStates[key] == .accepted }
    /// The card's one local tap state, including a dismissal: the close button
    /// uses its own `dismiss:<id>` key, and a refused dismissal must read the
    /// same human copy on the card instead of surfacing under the avatar.
    private var tapPhase: BotChoiceTapPhase {
        if model.actionStates["dismiss:\(row.id)"] == .pending { return .pending }
        if case .failed(let reason) = model.actionStates["dismiss:\(row.id)"] { return .failed(reason) }
        switch model.actionStates[key] {
        case .pending: return .pending
        case .accepted: return .accepted
        case .failed(let reason): return .failed(reason)
        case nil: return answered ? .accepted : .idle
        }
    }
    private var locked: Bool {
        answered || superseded || isPending || accepted
    }
    private var canDismiss: Bool { !isSteps && card.body["dismissible"]?.bool != false }

    var body: some View {
        BotCardSurface(category: .choice) {
            VStack(alignment: .leading, spacing: 0) {
                BotCardHeading(icon: isSteps ? "sparkles" : "questionmark.circle",
                               eyebrow: isSteps ? "建议下一步" : "需要你选择",
                               title: prompt, detail: isSteps ? nil : help,
                               category: .choice) {
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
            BotCardRow(label: choice.label, detail: isSteps ? nil : choice.description,
                       labelInk: choice.danger ? NativeParityTokens.error : HomeSpec.textPrimary) {
                EmptyView()
            } trailing: {
                if choice.recommended { BotCardTag(text: "建议", tone: .choice) }
                if selectedID == choice.id, accepted || isPending {
                    // The tap is already recorded locally: mark it before the
                    // durable answer round-trips.
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(BotCardCategory.choice.ink)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(BotCardCategory.choice.ink.opacity(0.75))
                }
            }
        }
        .buttonStyle(BotCardRowButtonStyle())
        .disabled(locked)
        .opacity(superseded ? 0.45 : 1)
        .accessibilityLabel(choice.recommended ? "\(choice.label)，建议" : choice.label)
        .accessibilityIdentifier("bot.choice.option.\(choice.id)")
    }

    private var isPending: Bool { tapPhase == .pending }

    /// One line under the options: the spinner while the choice is in flight,
    /// the human copy for a refusal or a failure, and the durable settlement
    /// copy. The raw reason code never reaches the screen.
    @ViewBuilder private var statusLine: some View {
        if superseded {
            Text(BotChoiceCardUI.supersededTitle)
                .botCardMeta()
                .padding(.top, 8)
        } else if isPending {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                Text(BotChoiceCardUI.pendingStatus)
                    .botCardMeta()
            }
            .padding(.top, 8)
            .accessibilityIdentifier("bot.choice.pending")
        } else if case .failed(let reason) = tapPhase {
            Text(BotChoiceCardUI.failureText(reason))
                .botCardMeta()
                .foregroundStyle(BotChoiceCardUI.refusalText(reason) == nil
                                 ? NativeParityTokens.error : HomeSpec.textSecondary)
                .padding(.top, 8)
        } else if accepted || answered {
            Label("已送出", systemImage: "checkmark")
                .botCardMeta()
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
    private var taskStatus: String? {
        row.body["status"]?.string ?? row.body["task"]?.object?["status"]?.string
    }
    private var running: Bool {
        taskStatus == "running" || steps.contains { BotCardStepState($0.state) == .active }
    }
    private var stateTag: (text: String, tone: BotCardTone) {
        switch taskStatus {
        case "waiting_approval": return ("等待审批", .warning)
        case "denied": return ("已拒绝", .danger)
        case "stopped": return ("已停止", .neutral)
        case "interrupted": return ("已中断", .danger)
        default: break
        }
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
        BotCardSurface(category: .work) {
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
    private var isDocument: Bool {
        let mime = (row.body["mimeType"]?.string ?? "").lowercased()
        let ext = (name as NSString).pathExtension.lowercased()
        return ["pdf", "md", "markdown", "html", "htm", "txt", "doc", "docx", "rtf",
                "json", "csv", "tsv", "xml", "yaml", "yml"].contains(ext)
            || mime == "application/pdf" || mime.hasPrefix("text/")
            || mime.contains("wordprocessingml") || mime.contains("msword")
    }

    var body: some View {
        if let path, actions.canOpenPath(path) {
            Button { actions.openPath(path) } label: {
                card(open: true)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("bot.attachment.open")
            .accessibilityLabel("打开 \(name)")
            .accessibilityHint("打开文件预览")
        } else {
            // No handler: the card stays readable but has no control that
            // could do nothing when tapped.
            card(open: false)
                .accessibilityElement(children: .combine)
        }
    }

    /// One card face. `open` only controls the visible affordance; the whole
    /// surface is the button when a handler exists.
    @ViewBuilder private func card(open: Bool) -> some View {
        BotCardSurface(padding: isDocument ? 0 : 12, category: isDocument ? .document : .work) {
            if isDocument {
                VStack(alignment: .leading, spacing: 0) {
                    artifactTitle
                    if let summary = row.body.string("caption", "description") {
                        Text(summary).botCardBody().lineLimit(2)
                            .padding(.horizontal, 16).padding(.top, 4)
                    }
                BotCardArtifactPreview(path: path, fileName: name, title: name,
                                       mime: row.body["mimeType"]?.string, category: .document)
                        .padding(.horizontal, 16).padding(.top, 12)
                    artifactFooter()
                }
            } else {
                HStack(spacing: 12) {
                    BotCardTile(systemImage: BotCardFileIcon.name(for: name, mime: row.body["mimeType"]?.string))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).botCardRow(weight: .medium).lineLimit(2)
                        if let detail = row.body.string("caption", "size", "description") {
                            Text(detail).botCardMeta().lineLimit(1)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if open { BotCardOpenAffordance() }
                }
            }
        }
        .contentShape(Rectangle())
    }

    private var artifactTitle: some View {
        Text(name).font(.system(size: 16, weight: .semibold))
            .foregroundStyle(HomeSpec.textPrimary).lineLimit(2)
            .padding(.horizontal, 16).padding(.top, 16)
    }

    private func artifactFooter() -> some View {
        HStack(spacing: 12) {
            BotCardFileTile(fileName: name, mime: row.body["mimeType"]?.string)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).botCardRow(weight: .medium).lineLimit(1)
                Text(BotCardFileTypeLabel.make(name: name, mime: row.body["mimeType"]?.string,
                                               size: row.body["size"]?.string))
                    .botCardMeta().lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(HomeSpec.userBubble.opacity(0.35))
    }

}

private enum BotCardFileTypeLabel {
    static func make(name: String, mime: String?, size: String?) -> String {
        let ext = (name as NSString).pathExtension.uppercased()
        let normalizedMime = (mime ?? "").lowercased()
        let type: String
        switch ext {
        case "PDF": type = "PDF"
        case "MD", "MARKDOWN", "MDOWN": type = "Markdown"
        case "HTML", "HTM": type = "HTML"
        case "TXT", "TEXT", "LOG": type = "纯文本"
        case "DOC", "DOCX": type = "Word 文档"
        case "RTF": type = "RTF 文档"
        case "JSON", "JSONL": type = "JSON 数据"
        case "CSV", "TSV": type = "CSV 表格"
        default:
            if normalizedMime.contains("pdf") { type = "PDF" }
            else if normalizedMime.contains("markdown") { type = "Markdown" }
            else if normalizedMime.contains("html") { type = "HTML" }
            else if normalizedMime.contains("wordprocessingml") || normalizedMime.contains("msword") { type = "Word 文档" }
            else if normalizedMime.contains("rtf") { type = "RTF 文档" }
            else if normalizedMime.contains("json") { type = "JSON 数据" }
            else if normalizedMime.contains("csv") { type = "CSV 表格" }
            else if normalizedMime.hasPrefix("text/") { type = "纯文本" }
            else { type = "文件" }
        }
        return [type, size].compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }.joined(separator: " · ")
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
        if let label = row.body.string("docTypeLabel", "kindLabel") {
            switch label {
            case "Document", "document", "页面": return "文档"
            case "Table", "table": return "表格"
            case "Code", "code": return "代码"
            case "Library", "library", "文件庫": return "文件库"
            default: return label
            }
        }
        switch row.body["docKind"]?.string {
        case "markdown": return "Markdown"
        case "pdf": return "PDF"
        case "code": return "代码"
        case "table": return "表格"
        default: return "文档"
        }
    }
    private var fileName: String { row.body.string("fileName") ?? title }
    private var inlinePreview: String? {
        row.body.string("content", "markdown")?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    var body: some View {
        Button { actions.openDocument(row) } label: {
            BotCardSurface(padding: 0, category: .document) {
                VStack(alignment: .leading, spacing: BotCardMetrics.blockGap) {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(HomeSpec.textPrimary)
                        .lineLimit(2)
                        .padding(.horizontal, 16)
                        .padding(.top, 18)
                    if let summary {
                        Text(summary).botCardBody().lineLimit(2)
                            .padding(.horizontal, 16)
                    }
                    BotCardArtifactPreview(path: path, fileName: fileName, title: title,
                                           mime: row.body["mimeType"]?.string,
                                           inlineContent: inlinePreview, toc: toc,
                                           category: .document)
                        .padding(.horizontal, 16)
                    HStack(spacing: 12) {
                        BotCardFileTile(fileName: fileName, mime: row.body["mimeType"]?.string)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(fileName).botCardRow(weight: .medium).lineLimit(1)
                            Text(BotCardFileTypeLabel.make(name: fileName,
                                                           mime: row.body["mimeType"]?.string,
                                                           size: row.body["size"]?.string))
                                .botCardMeta().lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(16)
                    .background(HomeSpec.userBubble.opacity(0.35))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("bot.document.open")
        .accessibilityLabel("打开 \(title)")
        .accessibilityHint("打开文档预览")
    }

}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// A compact, truthful preview. Embedded content wins; otherwise text files
/// are read through the existing resolver and 256 KiB reader. Unsupported or
/// missing content is stated plainly rather than replaced with sample copy.
private struct BotCardArtifactPreview: View {
    let path: String?
    let fileName: String
    let title: String
    let mime: String?
    var inlineContent: String? = nil
    var toc: [String] = []
    let category: BotCardCategory
    @State private var loadedText: String?
    @State private var message: String?
    @State private var pdfPreview: UIImage?

    private var content: String? {
        let supplied = [inlineContent, loadedText].compactMap { $0 }.first
        let parts = [supplied, toc.isEmpty ? nil : toc.joined(separator: "\n")].compactMap { $0 }
        guard !parts.isEmpty else { return nil }
        let source = parts.joined(separator: "\n\n")
        let readable = isMarkdown ? Self.readableMarkdown(source) : source
        var lines = readable.components(separatedBy: .newlines)
        if let first = lines.first,
           first.trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedCaseInsensitiveCompare(title.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame {
            lines.removeFirst()
        }
        return String(lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines).prefix(1_800))
    }
    private var isMarkdown: Bool {
        let ext = (fileName as NSString).pathExtension.lowercased()
        return ["md", "markdown", "mdown"].contains(ext) || (mime ?? "").lowercased().contains("markdown")
    }
    private var isHTML: Bool {
        let ext = (fileName as NSString).pathExtension.lowercased()
        return ["html", "htm"].contains(ext) || (mime ?? "").lowercased() == "text/html"
    }

    var body: some View {
        Group {
            if let image = pdfPreview {
                Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 150)
            } else if let content {
                VStack(alignment: .leading, spacing: 4) {
                    if isHTML { Text("HTML 源码预览").botCardMeta() }
                    Text(content)
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .lineSpacing(4)
                        .foregroundStyle(HomeSpec.textSecondary)
                        .lineLimit(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .mask {
                            LinearGradient(stops: [
                                .init(color: .black, location: 0),
                                .init(color: .black, location: 0.58),
                                .init(color: .clear, location: 1),
                            ], startPoint: .top, endPoint: .bottom)
                        }
                }
                .accessibilityIdentifier("bot.card.document.preview")
            } else {
                Text(message ?? (path == nil ? "暂无正文或目录预览" : "正在读取文件预览…"))
                    .font(.system(size: 12))
                    .foregroundStyle(HomeSpec.textPlaceholder)
                    .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                    .accessibilityIdentifier("bot.card.document.preview")
            }
        }
        .padding(12)
        .background(category.wash.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
        .clipped()
        .task(id: path) { await loadFilePreview() }
    }

    @MainActor
    private func loadFilePreview() async {
        loadedText = nil
        message = nil
        pdfPreview = nil
        guard inlineContent == nil, toc.isEmpty, let path else { return }
        guard let url = PreviewPathResolver.fileURL(for: path) else {
            message = "文件尚未同步到本机"
            return
        }
        if url.previewKind == .pdf {
            guard let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  fileSize <= 20 * 1024 * 1024 else {
                message = "PDF 文件较大，请打开文件查看"
                return
            }
            let imageData = await Task.detached(priority: .utility) { () -> Data? in
                guard let document = PDFDocument(url: url), let page = document.page(at: 0) else { return nil }
                let image = page.thumbnail(of: CGSize(width: 520, height: 360), for: .mediaBox)
                return image.pngData()
            }.value
            guard !Task.isCancelled else { return }
            pdfPreview = imageData.flatMap { UIImage(data: $0) }
            if pdfPreview == nil { message = "PDF 暂无可用页面预览" }
            return
        }
        switch url.previewKind {
        case .text, .markdown, .html: break
        default:
            message = "此格式请打开文件查看"
            return
        }
        do {
            let result = try await Task.detached(priority: .utility) {
                try BotDocumentFileReader.readText(at: url)
            }.value
            guard !Task.isCancelled else { return }
            loadedText = result.text
            if result.text.isEmpty { message = "文件内容为空" }
        } catch {
            message = "无法读取文件内容"
        }
    }

    private static func readableMarkdown(_ source: String) -> String {
        source.components(separatedBy: .newlines).map { line in
            var value = line.trimmingCharacters(in: .whitespaces)
            while value.first == "#" { value.removeFirst() }
            value = value.trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("- ") || value.hasPrefix("* ") { value.removeFirst(2) }
            if let range = value.range(of: "](") , value.hasPrefix("[") {
                let title = value[value.index(after: value.startIndex)..<range.lowerBound]
                value = String(title)
            }
            value = value.replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "__", with: "")
                .replacingOccurrences(of: "`", with: "")
            return value
        }.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// The visible "打开" text. The whole card is the button; this is only the
/// affordance, never a second nested control.
private struct BotCardOpenAffordance: View {
    var body: some View {
        Text("打开")
            .font(.system(size: HomeSpec.processSize, weight: .medium))
            .foregroundStyle(HomeSpec.textPrimary)
            .frame(minWidth: 44, minHeight: 44)
    }
}
