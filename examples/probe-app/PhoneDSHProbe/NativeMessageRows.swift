// SPDX-License-Identifier: MIT

import SwiftUI

struct NativeDisclosureRow<Content: View>: View {
    let icon: NativeChatIcon.Name
    let title: String
    var summary: String = ""
    var running = false
    var expandable = true
    var showsSummaryWhenExpanded = false
    @Binding var expanded: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                guard expandable else { return }
                withAnimation(.easeOut(duration: 0.16)) { expanded.toggle() }
            } label: {
                HStack(spacing: 0) {
                    ZStack {
                        if expanded { NativeChatIcon(name: .chevronDown, size: 14).rotationEffect(.degrees(180)) }
                        else { NativeChatIcon(name: icon, size: 14) }
                    }
                    .frame(width: 16, height: 16)
                    .padding(.trailing, 6)
                    Text(title)
                        .font(NativeChatTheme.secondaryFont())
                        .fixedSize(horizontal: true, vertical: false)
                    if !summary.isEmpty && (showsSummaryWhenExpanded || !expanded) {
                        Circle()
                            .fill(NativeChatTheme.caption)
                            .frame(width: 2, height: 2)
                            .padding(.horizontal, 8)
                        ShimmerText(text: summary, active: running,
                                    font: NativeChatTheme.secondaryFont(), color: NativeChatTheme.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(running ? NativeChatTheme.secondary : NativeChatTheme.tertiary)
                .frame(height: 24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!expandable)
            .accessibilityLabel(title)
            .accessibilityValue(running ? "运行中" : (expanded ? "已展开" : "已折叠"))
            if expanded { content() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct NativeThinkingRow: View {
    let item: ChatItem
    @State private var expanded = false

    private var summary: String {
        let raw = item.streaming ? Self.streamingSummary(item.text) : (item.text.components(separatedBy: "\n").first ?? "")
        return raw.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func streamingSummary(_ text: String) -> String {
        var summary = ""
        for paragraph in text.components(separatedBy: "\n\n") {
            if let newline = paragraph.firstIndex(of: "\n") {
                let first = paragraph[..<newline].trimmingCharacters(in: .whitespaces)
                if !first.isEmpty { summary = first }
            }
        }
        return summary
    }

    var body: some View {
        NativeDisclosureRow(icon: .think, title: "思考", summary: summary,
                            running: item.streaming, expanded: $expanded) {
            NativeMarkdownBody(markdown: item.text.isEmpty ? "…" : item.text, variant: .compact)
                .padding(.leading, 22)
                .padding(.vertical, 4)
        }
    }
}

struct NativeSystemEventRow: View {
    let item: ChatItem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(item.kind == .turnError ? NativeChatTheme.danger : NativeChatTheme.warning)
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(NativeChatTheme.secondaryFont().weight(.medium))
                if !item.text.isEmpty {
                    Text(item.text)
                        .font(NativeChatTheme.captionFont())
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .foregroundStyle(item.kind == .turnError ? NativeChatTheme.danger : NativeChatTheme.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

struct NativeAttachmentList: View {
    let attachments: [NativeMessageAttachment]
    var onOpenFile: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(attachments.enumerated()), id: \.offset) { _, attachment in
                Button {
                    if let path = attachment.path { onOpenFile(path) }
                } label: {
                    HStack(spacing: 10) {
                        Group {
                            if let path = attachment.path { FileTypeGlyph.icon(for: path, size: 28) }
                            else { FileTypeGlyph.icon(for: attachment.kind == .image ? "image.png" : "file", size: 28) }
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(attachment.name)
                                .font(NativeChatTheme.secondaryFont().weight(.medium))
                                .lineLimit(1)
                            Text(attachment.mimeType ?? (attachment.kind == .image ? "图片" : "文件"))
                                .font(.system(size: 10))
                                .foregroundStyle(NativeChatTheme.tertiary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                    .background(NativeChatTheme.selector,
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(attachment.path == nil)
            }
        }
    }
}
