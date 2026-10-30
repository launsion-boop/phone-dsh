// SPDX-License-Identifier: MIT

import SwiftUI
import UIKit
import SwiftMath

struct NativeMarkdownBody: View {
    let markdown: String
    let streaming: Bool
    let variant: NativeMarkdownVariant
    let workspaceFiles: [WorkspaceFile]
    let onOpenFile: ((String) -> Void)?

    @State private var blocks: [NativeMarkdownBlock]

    init(markdown: String, streaming: Bool = false, variant: NativeMarkdownVariant = .body,
         workspaceFiles: [WorkspaceFile] = [], onOpenFile: ((String) -> Void)? = nil) {
        self.markdown = markdown
        self.streaming = streaming
        self.variant = variant
        self.workspaceFiles = workspaceFiles
        self.onOpenFile = onOpenFile
        _blocks = State(initialValue: NativeMarkdownParser.parse(markdown, streaming: streaming))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: variant == .compact ? 4 : NativeChatTheme.messageParagraphSpacing) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                NativeMarkdownBlockView(block: block, variant: variant,
                                        workspaceFiles: workspaceFiles, onOpenFile: onOpenFile)
            }
        }
        .lineSpacing(variant == .compact ? 0 : NativeChatTheme.messageLineSpacing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .onChange(of: markdown) { _, value in
            blocks = NativeMarkdownParser.parse(value, streaming: streaming)
        }
        .onChange(of: streaming) { _, value in
            blocks = NativeMarkdownParser.parse(markdown, streaming: value)
        }
    }
}

private struct NativeMarkdownBlockView: View {
    let block: NativeMarkdownBlock
    let variant: NativeMarkdownVariant
    let workspaceFiles: [WorkspaceFile]
    let onOpenFile: ((String) -> Void)?

    var body: some View {
        switch block {
        case .heading(let level, let content):
            NativeMarkdownInlineText(content: content, variant: variant, headingLevel: level,
                                     workspaceFiles: workspaceFiles, onOpenFile: onOpenFile)
                .font(headingFont(level))
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let content):
            NativeMarkdownInlineText(content: content, variant: variant,
                                     workspaceFiles: workspaceFiles, onOpenFile: onOpenFile)
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
                                                        workspaceFiles: workspaceFiles, onOpenFile: onOpenFile)
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
                                            workspaceFiles: workspaceFiles, onOpenFile: onOpenFile)
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
                                workspaceFiles: workspaceFiles, onOpenFile: onOpenFile)
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
    let workspaceFiles: [WorkspaceFile]
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
                                   workspaceFiles: workspaceFiles, onOpenFile: onOpenFile)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                NativeMarkdownTableRow(cells: row, header: false, variant: variant, alignments: alignments,
                                       workspaceFiles: workspaceFiles, onOpenFile: onOpenFile)
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
                                                     workspaceFiles: workspaceFiles, onOpenFile: onOpenFile)
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
    let workspaceFiles: [WorkspaceFile]
    let onOpenFile: ((String) -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                NativeMarkdownInlineText(content: cell, variant: variant,
                                         workspaceFiles: workspaceFiles, onOpenFile: onOpenFile)
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
    let workspaceFiles: [WorkspaceFile]
    let onOpenFile: ((String) -> Void)?

    var body: some View { text(content) }

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
            var renderer = MathImage(latex: latex, fontSize: variant == .compact ? 13 : CGFloat(NativeChatPreferences.shared.fontSize(for: .text)),
                                     textColor: UIColor(NativeChatTheme.primary), labelMode: .text, textAlignment: .left)
            let (error, image, layout) = renderer.asImage()
            guard error == nil, let image else { return Text(latex) }
            return Text(Image(uiImage: image)).baselineOffset(-(layout?.descent ?? 0))
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
        let matches = workspaceFiles.filter { $0.relativePath == value || $0.relativePath.split(separator: "/").last.map(String.init) == value }
        guard matches.count == 1 else { return nil }
        return nativeMarkdownURL(matches[0].relativePath)
    }
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
        let url = ChatModel.shared.workspaceRoot.appendingPathComponent(relative)
        guard let data = try? Data(contentsOf: url) else { return nil }
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
