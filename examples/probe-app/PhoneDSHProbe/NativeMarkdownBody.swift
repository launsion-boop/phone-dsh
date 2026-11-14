// SPDX-License-Identifier: MIT

import ProbeKit
import SwiftMath
import SwiftUI
import UIKit

struct NativeMarkdownBody: View {
    let markdown: String
    let streaming: Bool
    let variant: NativeMarkdownVariant
    let fileIndex: WorkspaceFileIndex
    let onOpenFile: ((String) -> Void)?
    /// Transcript item identity for the parse cache. Empty means the caller is
    /// a preview/standalone surface and the cache falls back to a content hash.
    let cacheItemID: String
    let cacheRevision: Int

    init(markdown: String, streaming: Bool = false, variant: NativeMarkdownVariant = .body,
         fileIndex: WorkspaceFileIndex = .empty, onOpenFile: ((String) -> Void)? = nil,
         cacheItemID: String = "", cacheRevision: Int = 0) {
        self.markdown = markdown
        self.streaming = streaming
        self.variant = variant
        self.fileIndex = fileIndex
        self.onOpenFile = onOpenFile
        self.cacheItemID = cacheItemID
        self.cacheRevision = cacheRevision
    }

    var body: some View {
        let blocks = NativeMarkdownParseCache.shared.blocks(
            for: markdown, itemID: cacheItemID,
            revision: cacheRevision, streaming: streaming)
        LazyVStack(alignment: .leading, spacing: variant == .compact ? 4 : NativeChatTheme.messageParagraphSpacing) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                NativeMarkdownBlockView(block: block, variant: variant,
                                        fileIndex: fileIndex, onOpenFile: onOpenFile)
            }
        }
        .lineSpacing(variant == .compact ? 0 : NativeChatTheme.messageLineSpacing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}

private struct NativeMarkdownBlockView: View {
    let block: NativeMarkdownBlock
    let variant: NativeMarkdownVariant
    let fileIndex: WorkspaceFileIndex
    let onOpenFile: ((String) -> Void)?

    var body: some View {
        switch block {
        case .heading(let level, let content):
            NativeMarkdownInlineText(content: content, variant: variant, headingLevel: level,
                                     fileIndex: fileIndex, onOpenFile: onOpenFile)
                .font(headingFont(level))
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let content):
            NativeMarkdownInlineText(content: content, variant: variant,
                                     fileIndex: fileIndex, onOpenFile: onOpenFile)
                .font(variant == .compact ? NativeChatTheme.secondaryFont() : NativeChatTheme.messageBodyFont())
                .foregroundStyle(variant == .compact ? NativeChatTheme.tertiary : NativeChatTheme.primary)
                .fixedSize(horizontal: false, vertical: true)
        case .list(let ordered, let start, let items):
            VStack(alignment: .leading, spacing: variant == .compact ? 2 : NativeChatTheme.messageListSpacing) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: variant == .compact ? 8 : 10) {
                        Group {
                            if let checked = item.checked {
                                Image(systemName: checked ? "checkmark.square.fill" : "square")
                            } else {
                                Text(ordered ? "\(start + index)." : "•")
                            }
                        }
                        .font(variant == .compact ? NativeChatTheme.secondaryFont() : NativeChatTheme.messageBodyFont())
                        .foregroundStyle(NativeChatTheme.secondary)
                        .frame(minWidth: ordered ? 24 : 18, alignment: .trailing)
                        .padding(.top, 1)
                        VStack(alignment: .leading, spacing: variant == .compact ? 2 : NativeChatTheme.messageListSpacing) {
                            ForEach(Array(item.blocks.enumerated()), id: \.offset) { _, child in
                                NativeMarkdownBlockView(block: child, variant: variant,
                                                        fileIndex: fileIndex, onOpenFile: onOpenFile)
                            }
                        }
                    }
                }
            }
            .padding(.leading, variant == .compact ? 4 : 8)
        case .blockquote(let children):
            VStack(alignment: .leading, spacing: variant == .compact ? 4 : 12) {
                ForEach(Array(children.enumerated()), id: \.offset) { _, child in
                    NativeMarkdownBlockView(block: child, variant: variant,
                                            fileIndex: fileIndex, onOpenFile: onOpenFile)
                }
            }
            .padding(.leading, variant == .compact ? 8 : 14)
            .overlay(alignment: .leading) {
                Rectangle().fill(NativeChatTheme.caption).frame(width: 2)
            }
        case .code(let language, let source):
            DSSCodeBlock(source: source.hasSuffix("\n") ? String(source.dropLast()) : source,
                         language: language)
        case .table(let header, let rows, let alignments):
            NativeMarkdownTable(header: header, rows: rows, alignments: alignments, variant: variant,
                                fileIndex: fileIndex, onOpenFile: onOpenFile)
        case .image(let source, let alt, let title):
            NativeMarkdownImage(source: source, alt: alt, title: title)
        case .math(let latex):
            ScrollView(.horizontal) {
                NativeMathView(latex: latex, display: true, compact: variant == .compact)
            }
        case .thematicBreak:
            Rectangle()
                .fill(NativeChatTheme.border)
                .frame(height: 0.5)
                .padding(.vertical, variant == .compact ? 4 : 16)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        if variant == .compact { return NativeChatTheme.secondaryFont().weight(.semibold) }
        switch level {
        case 1: return .system(size: 24, weight: .bold)
        case 2: return .system(size: 22, weight: .bold)
        case 3: return .system(size: 20, weight: .semibold)
        case 4: return .system(size: 17, weight: .semibold)
        default: return NativeChatTheme.bodyFont().weight(.semibold)
        }
    }
}

struct NativeMarkdownTable: View {
    let header: [[NativeMarkdownInline]]
    let rows: [[[NativeMarkdownInline]]]
    let alignments: [NativeMarkdownTableAlignment?]
    let variant: NativeMarkdownVariant
    let fileIndex: WorkspaceFileIndex
    let onOpenFile: ((String) -> Void)?

    private var columnCount: Int {
        max(header.count, rows.map(\.count).max() ?? 0)
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            grid
            cards
        }
    }

    private var grid: some View {
        VStack(alignment: .leading, spacing: 0) {
            NativeMarkdownTableRow(cells: header, header: true, variant: variant, alignments: alignments,
                                   fileIndex: fileIndex, onOpenFile: onOpenFile)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                NativeMarkdownTableRow(cells: row, header: false, variant: variant, alignments: alignments,
                                       fileIndex: fileIndex, onOpenFile: onOpenFile)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("native-markdown-table-grid")
    }

    private var cards: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(0..<columnCount, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(fieldTitle(index))
                                .font(NativeChatTheme.captionFont().weight(.medium))
                                .foregroundStyle(NativeChatTheme.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            NativeMarkdownInlineText(content: row[safe: index] ?? [], variant: variant,
                                                     fileIndex: fileIndex, onOpenFile: onOpenFile)
                                .font(variant == .compact
                                      ? NativeChatTheme.secondaryFont() : NativeChatTheme.messageBodyFont())
                                .foregroundStyle(NativeChatTheme.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(NativeChatTheme.selector,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("native-markdown-table-cards")
    }

    private func fieldTitle(_ index: Int) -> String {
        let text = NativeMarkdownInlineText.plainText(header[safe: index] ?? [])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "列 \(index + 1)" : text
    }
}

private struct NativeMarkdownTableRow: View {
    let cells: [[NativeMarkdownInline]]
    let header: Bool
    let variant: NativeMarkdownVariant
    let alignments: [NativeMarkdownTableAlignment?]
    let fileIndex: WorkspaceFileIndex
    let onOpenFile: ((String) -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                NativeMarkdownInlineText(content: cell, variant: variant,
                                         fileIndex: fileIndex, onOpenFile: onOpenFile)
                    .font(variant == .compact
                          ? NativeChatTheme.secondaryFont().weight(header ? .semibold : .regular)
                          : NativeChatTheme.messageBodyFont().weight(header ? .semibold : .regular))
                    .multilineTextAlignment(textAlignment(index))
                    .frame(minWidth: 100, maxWidth: 320, alignment: frameAlignment(index))
                    .padding(.horizontal, variant == .compact ? 8 : 16)
                    .padding(.vertical, variant == .compact ? 4 : 10)
                    .overlay(alignment: .bottom) { Rectangle().fill(NativeChatTheme.border).frame(height: 0.5) }
            }
        }
        .background(header ? NativeChatTheme.selector : .clear)
    }

    private func textAlignment(_ index: Int) -> TextAlignment {
        switch alignments[safe: index] ?? nil {
        case .center: .center
        case .right: .trailing
        default: .leading
        }
    }

    private func frameAlignment(_ index: Int) -> Alignment {
        switch alignments[safe: index] ?? nil {
        case .center: .center
        case .right: .trailing
        default: .leading
        }
    }
}

private struct NativeMarkdownInlineText: View {
    let content: [NativeMarkdownInline]
    let variant: NativeMarkdownVariant
    var headingLevel: Int?
    let fileIndex: WorkspaceFileIndex
    let onOpenFile: ((String) -> Void)?
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if Self.needsRenderCache(content) {
            cachedText(for: renderCacheKey)
        } else {
            text(content)
        }
    }

    /// Only the inline forms that build an AttributedString or a math image are
    /// worth caching; plain/strong/emphasis paragraphs are cheap `Text` additions.
    private static func needsRenderCache(_ inline: [NativeMarkdownInline]) -> Bool {
        for part in inline {
            switch part {
            case .code, .link, .math:
                return true
            case .strong(let children), .emphasis(let children), .delete(let children):
                if needsRenderCache(children) { return true }
            default:
                break
            }
        }
        return false
    }

    /// The key carries every input that changes the built Text: the inline
    /// AST, the workspace index revision (a code span's link target), the
    /// theme/colour scheme, the resolved font sizes and preference revision,
    /// plus display scale (math images are rasterized per scale).
    private var renderCacheKey: NativeInlineTextKey {
        let preferences = NativeChatPreferences.shared
        return NativeInlineTextKey(
            content: content,
            compact: variant == .compact,
            fileIndexRevision: fileIndex.revision,
            preferencesRevision: preferences.revision,
            codeFontSize: preferences.fontSize(for: .code),
            textFontSize: preferences.fontSize(for: .text),
            displayScale: displayScale,
            colorScheme: colorScheme == .dark ? 2 : (colorScheme == .light ? 1 : 0))
    }

    private func cachedText(for key: NativeInlineTextKey) -> Text {
        let cache = NativeInlineTextCache.shared.cache
        if let cached = cache.value(forKey: key) { return cached }
        let rendered = text(content)
        cache.insert(rendered, forKey: key,
                     cost: 256 + Self.plainText(content).utf8.count * 8)
        return rendered
    }

    private func text(_ inline: [NativeMarkdownInline]) -> Text {
        inline.reduce(Text("")) { result, part in result + render(part) }
    }

    private func render(_ part: NativeMarkdownInline) -> Text {
        switch part {
        case .text(let value): return Text(value)
        case .strong(let children): return text(children).bold()
        case .emphasis(let children): return text(children).italic()
        case .delete(let children): return text(children).strikethrough()
        case .code(let value):
            if let url = nativeFileMention(value) {
                var attributed = AttributedString(value)
                attributed.link = url
                attributed.foregroundColor = NativeChatTheme.accent
                attributed.font = .system(size: variant == .compact ? 13 : CGFloat(NativeChatPreferences.shared.fontSize(for: .code) + 1), design: .monospaced)
                return Text(attributed)
            }
            var attributed = AttributedString(value)
            attributed.font = .system(size: variant == .compact ? 13 : CGFloat(NativeChatPreferences.shared.fontSize(for: .code) + 1), design: .monospaced)
            attributed.backgroundColor = NativeChatTheme.inlineCode
            return Text(attributed)
        case .link(let destination, let children):
            let label = Self.plainText(children)
            guard let url = nativeMarkdownURL(destination) else { return text(children) }
            var attributed = AttributedString(label)
            attributed.link = url
            attributed.foregroundColor = NativeChatTheme.accent
            attributed.underlineStyle = .single
            return Text(attributed)
        case .image(_, let alt):
            return Text(alt).italic().foregroundColor(NativeChatTheme.tertiary)
        case .math(let latex):
            let result = NativeMathImageCache.shared.result(
                latex: latex,
                fontSize: variant == .compact ? 13 : CGFloat(NativeChatPreferences.shared.fontSize(for: .text)),
                displayScale: displayScale,
                colorScheme: colorScheme)
            switch result {
            case .success(let image, _, let descent):
                return Text(Image(uiImage: image)).baselineOffset(-descent)
            case .failure:
                return Text(latex)
            }
        case .footnote(let identifier):
            return Text("[\(identifier)]").font(.system(size: 9)).baselineOffset(6)
        case .html(let value): return Text(value)
        }
    }

    fileprivate static func plainText(_ inline: [NativeMarkdownInline]) -> String {
        inline.map { part in
            switch part {
            case .text(let value), .code(let value), .math(let value), .html(let value): value
            case .strong(let children), .emphasis(let children), .delete(let children): Self.plainText(children)
            case .link(_, let children): Self.plainText(children)
            case .image(_, let alt): alt
            case .footnote(let id): "[\(id)]"
            }
        }.joined()
    }

    private func nativeFileMention(_ value: String) -> URL? {
        guard let path = fileIndex.mention(for: value) else { return nil }
        return nativeMarkdownURL(path)
    }
}

private struct NativeInlineTextKey: Hashable {
    let content: [NativeMarkdownInline]
    let compact: Bool
    let fileIndexRevision: Int
    let preferencesRevision: Int
    let codeFontSize: Int
    let textFontSize: Int
    let displayScale: CGFloat
    let colorScheme: Int
}

private final class NativeInlineTextCache {
    static let shared = NativeInlineTextCache()
    static let countLimit = 512
    static let totalCostLimit = 4 * 1024 * 1024

    let cache = NativeBoundedCache<NativeInlineTextKey, Text>(
        name: "NativeInlineTextCache",
        countLimit: NativeInlineTextCache.countLimit,
        totalCostLimit: NativeInlineTextCache.totalCostLimit)
}

private func nativeMarkdownURL(_ destination: String) -> URL? {
    guard let url = URL(string: destination) else { return nil }
    if let scheme = url.scheme?.lowercased() {
        return ["http", "https", "mailto", "file", "sandbox", "dsh-resource"].contains(scheme) ? url : nil
    }
    return destination.isEmpty ? nil : url
}

private struct NativeMathView: UIViewRepresentable {
    let latex: String
    let display: Bool
    let compact: Bool

    func makeUIView(context: Context) -> MTMathUILabel {
        let view = MTMathUILabel()
        view.labelMode = display ? .display : .text
        view.fontSize = compact ? 13 : CGFloat(NativeChatPreferences.shared.fontSize(for: .text))
        view.latex = latex
        view.displayErrorInline = false
        return view
    }

    func updateUIView(_ view: MTMathUILabel, context: Context) {
        view.fontSize = compact ? 13 : CGFloat(NativeChatPreferences.shared.fontSize(for: .text))
        view.labelMode = display ? .display : .text
        view.latex = latex
        view.textColor = UIColor(NativeChatTheme.primary)
    }
}

private struct NativeMarkdownImage: View {
    let source: String
    let alt: String
    let title: String
    @State private var presented = false

    var body: some View {
        if let url = URL(string: source), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    Button { presented = true } label: {
                        image.resizable().aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 640, maxHeight: 360)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                case .failure: fallback
                default: ProgressView().frame(maxWidth: .infinity, minHeight: 80)
                }
            }
            .sheet(isPresented: $presented) { fullScreenRemote(url) }
        } else if let image = localImage {
            Button { presented = true } label: {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 640, maxHeight: 360)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $presented) {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
                    .ignoresSafeArea().background(.black)
            }
        } else { fallback }
    }

    private var fallback: some View {
        Text(alt).italic().foregroundStyle(NativeChatTheme.tertiary)
    }

    private var localImage: UIImage? {
        let cleaned = source.split(whereSeparator: { $0 == "?" || $0 == "#" }).map(String.init).first ?? source
        let decoded = cleaned.removingPercentEncoding ?? cleaned
        guard !decoded.isEmpty, !decoded.split(separator: "/").contains("..") else { return nil }
        let relative = decoded.hasPrefix("/dsh/workspace/") ? String(decoded.dropFirst("/dsh/workspace/".count)) : decoded
        guard let url = PreviewPathResolver.fileURL(for: relative),
              let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    private func fullScreenRemote(_ url: URL) -> some View {
        AsyncImage(url: url) { image in
            image.resizable().aspectRatio(contentMode: .fit)
        } placeholder: { ProgressView() }
        .ignoresSafeArea().background(.black)
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
