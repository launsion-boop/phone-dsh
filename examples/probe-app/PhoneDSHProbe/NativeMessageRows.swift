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
    @Environment(\.homeListRow) private var inListCard

    // HomeSpec: a bare row is a 15/24 process row with an 18pt glyph; inside
    // a list card it drops to 14/22 with a 16pt glyph and an 8pt gap.
    private var font: Font { .system(size: inListCard ? HomeSpec.listItemSize : HomeSpec.processSize) }
    private var ink: Color {
        if running { return HomeSpec.textSecondary }
        return inListCard ? HomeSpec.textTertiary : HomeSpec.textSecondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                guard expandable else { return }
                withAnimation(.easeOut(duration: 0.16)) { expanded.toggle() }
            } label: {
                HStack(spacing: 0) {
                    ZStack {
                        if expanded { NativeChatIcon(name: .chevronDown, size: 14).rotationEffect(.degrees(180)) }
                        else { NativeChatIcon(name: icon, size: inListCard ? 14 : 16) }
                    }
                    .frame(width: inListCard ? 16 : HomeSpec.processIcon,
                           height: inListCard ? 16 : HomeSpec.processIcon)
                    .padding(.trailing, inListCard ? 8 : 6)
                    Text(title)
                        .font(font)
                        .fixedSize(horizontal: true, vertical: false)
                    if !summary.isEmpty && (showsSummaryWhenExpanded || !expanded) {
                        Circle()
                            .fill(HomeSpec.textPlaceholder)
                            .frame(width: 2, height: 2)
                            .padding(.horizontal, 6)
                        ShimmerText(text: summary, active: running,
                                    font: font, color: ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(ink)
                .frame(height: inListCard ? HomeSpec.listRowHeight : HomeSpec.processRowHeight)
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
    @State private var expanded = NativeChatPreferences.shared.transcriptView == .verbose
    @State private var preferences = NativeChatPreferences.shared

    private var summary: String {
        NativeRowSummaryCache.shared.thinkingSummary(for: item)
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
            NativeMarkdownBody(markdown: item.text.isEmpty ? "…" : item.text, variant: .compact,
                               cacheItemID: item.id, cacheRevision: item.renderRevision)
                .padding(.leading, 22)
                .padding(.vertical, 4)
        }
        .onChange(of: item.streaming) { _, streaming in
            if !streaming && preferences.collapseTiming == .completion
                && preferences.transcriptView != .verbose { expanded = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: .nativeChatNewInput)) { _ in
            if preferences.collapseTiming == .nextInput && preferences.transcriptView != .verbose {
                expanded = false
            }
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
