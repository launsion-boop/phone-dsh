// SPDX-License-Identifier: MIT
//
// S1-C.2: default head+tail folding for a large tool output.
//
// The existing cards already bounded code/diff/read payloads by line count and
// scrolled the generic IN/OUT text inside a 150pt view, but the generic text
// still laid out every line of the full output. This helper caps what is laid
// out by default: at most 200 lines / 8 KiB, head and tail around a visible
// "N lines / N bytes hidden" marker; tapping the marker lays out the full text.
//
// The pure fold model is separate from the view so the boundary is unit-tested
// without a render pass.

import SwiftUI

/// The folded representation of one recorded tool output.
struct NativeToolOutputFold: Equatable {
    static let maximumLines = 200
    static let maximumBytes = 8 * 1024

    let collapsedText: String
    let hiddenLineCount: Int
    let hiddenByteCount: Int

    var isFolded: Bool { hiddenLineCount > 0 || hiddenByteCount > 0 }

    init(text: String,
         maximumLines: Int = NativeToolOutputFold.maximumLines,
         maximumBytes: Int = NativeToolOutputFold.maximumBytes) {
        let lines = text.components(separatedBy: "\n")
        var headText = text
        var tailText = ""
        var hiddenLines = 0
        if maximumLines > 0, lines.count > maximumLines {
            let headCount = max(1, maximumLines / 2)
            let tailCount = max(0, maximumLines - headCount)
            headText = lines.prefix(headCount).joined(separator: "\n")
            tailText = tailCount == 0 ? "" : lines.suffix(tailCount).joined(separator: "\n")
            hiddenLines = max(0, lines.count - headCount - tailCount)
        }

        var hiddenBytes = 0
        if maximumBytes > 0 {
            let visibleBytes = headText.utf8.count + tailText.utf8.count
            if visibleBytes > maximumBytes {
                let headBudget = max(1, maximumBytes / 2)
                let tailBudget = max(0, maximumBytes - headBudget)
                let head = Self.bytePrefix(headText, maximumBytes: headBudget)
                let tailSource = tailText.isEmpty
                    ? String(headText.dropFirst(head.count))
                    : tailText
                let tail = tailBudget == 0
                    ? ""
                    : Self.byteSuffix(tailSource, maximumBytes: tailBudget)
                hiddenBytes = max(0, visibleBytes - head.utf8.count - tail.utf8.count)
                headText = head
                tailText = tail
            }
        }

        hiddenLineCount = hiddenLines
        hiddenByteCount = hiddenBytes

        var parts: [String] = []
        if !headText.isEmpty { parts.append(headText) }
        if hiddenLines > 0 || hiddenBytes > 0 {
            var hidden: [String] = []
            if hiddenLines > 0 { hidden.append("\(hiddenLines) 行") }
            if hiddenBytes > 0 { hidden.append("\(hiddenBytes) 字节") }
            parts.append("… 其余 \(hidden.joined(separator: " / "))未显示 …")
        }
        if !tailText.isEmpty { parts.append(tailText) }
        collapsedText = parts.joined(separator: "\n")
    }

    /// The longest character-aligned prefix within `maximumBytes`.
    static func bytePrefix(_ text: String, maximumBytes: Int) -> String {
        guard maximumBytes > 0 else { return "" }
        var used = 0
        var end = text.startIndex
        for character in text {
            let size = String(character).utf8.count
            guard used + size <= maximumBytes else { break }
            used += size
            end = text.index(after: end)
        }
        return String(text[..<end])
    }

    /// The longest character-aligned suffix within `maximumBytes`.
    static func byteSuffix(_ text: String, maximumBytes: Int) -> String {
        guard maximumBytes > 0 else { return "" }
        var used = 0
        var start = text.endIndex
        while start > text.startIndex {
            let previous = text.index(before: start)
            let size = String(text[previous..<start]).utf8.count
            guard used + size <= maximumBytes else { break }
            used += size
            start = previous
        }
        return String(text[start...])
    }
}

/// The generic IN/OUT text body with the head+tail fold applied.
struct NativeToolOutputText: View {
    let text: String
    var isError = false
    var color: Color = NativeParityTokens.labelSecondary
    var font: Font = .system(size: NativeToolCardMetrics.ioFontSize, design: .monospaced)
    var lineSpacing: CGFloat = NativeToolCardMetrics.ioLineSpacing

    @State private var expanded = false
    @State private var fold: NativeToolOutputFold

    init(text: String,
         isError: Bool = false,
         color: Color = NativeParityTokens.labelSecondary,
         font: Font = .system(size: NativeToolCardMetrics.ioFontSize, design: .monospaced),
         lineSpacing: CGFloat = NativeToolCardMetrics.ioLineSpacing) {
        self.text = text
        self.isError = isError
        self.color = color
        self.font = font
        self.lineSpacing = lineSpacing
        _fold = State(initialValue: NativeToolOutputFold(text: text))
    }

    private var resolvedFold: NativeToolOutputFold { fold }

    private var visibleText: String {
        expanded ? text : resolvedFold.collapsedText
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(visibleText)
                .font(font)
                .lineSpacing(lineSpacing)
                .foregroundStyle(isError ? NativeParityTokens.error : color)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if resolvedFold.isFolded {
                Button {
                    withAnimation(.easeOut(duration: 0.16)) { expanded.toggle() }
                } label: {
                    Text(expanded ? "收起全文" : "显示全文")
                        .font(.system(size: NativeToolCardMetrics.headerFontSize))
                        .foregroundStyle(NativeParityTokens.labelTertiary)
                        .frame(minHeight: NativeToolCardMetrics.codeLineHeight,
                               alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
                .accessibilityLabel(expanded ? "收起工具输出" : "显示完整工具输出")
            }
        }
        .onChange(of: text) { _, _ in fold = NativeToolOutputFold(text: text) }
    }
}
