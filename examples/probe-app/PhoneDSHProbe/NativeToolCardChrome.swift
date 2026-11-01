// SPDX-License-Identifier: MIT
//
// NativeToolCardChrome — the shared, layout-only body of an expanded tool card.
//
// Official baseline: deepseek-harness 7be5505b0b (0.2.1-rc.2), 402pt viewport,
// CSS px == iOS pt. Values are read from the shipped web-app CSS:
//   ToolRow.module.css:181-247      IN/OUT card: margin 4/0/4/4, 0.5px border-l1,
//                                   radius 16, bg markdown-code-block, section
//                                   padding 12/16, max-height 150, gap 14,
//                                   0.5px border-l2 divider, 11/16 mono
//   CodeCard.module.css:10-60       banner: padding 10/18/8/22, font 11/18,
//                                   language + title tertiary, actions gap 4,
//                                   action target 24x24
//   DiffBlock.module.css:5-64       body padding 6/0/20, line padding 0 22,
//                                   min-height 1lh, 11/19 mono, inset 3px bar
//   ReadBlock.module.css:1-19       gutter digits + 12 gap, right aligned, tertiary
//   ExitCodeBadge.module.css:1-14   capsule padding 1/8, radius 999, 11/17 w500,
//                                   4px error dot, gap 5, margin-left 8
//
// See docs/receipts/ios-session-audit/06-tools.md §2.3 for the table these
// numbers come from. This file owns geometry only: callers pass the header slot
// and the body slot, so no tool model, state machine, or fetch leaks in.

import SwiftUI

// MARK: - Metrics

/// Official expanded-card geometry (402pt). Kept in one place so a value change
/// is a single edit and the pixel contract stays auditable against the report.
enum NativeToolCardMetrics {
    // Shell (ToolRow.module.css:181-189): radius 16, 0.5 hairline, margin 4/0/4/4.
    static let cornerRadius: CGFloat = NativeParityTokens.radiusLG // 16
    static let borderWidth: CGFloat = 0.5
    static let outerTop: CGFloat = 4, outerBottom: CGFloat = 4, outerLeading: CGFloat = 4

    // Banner / toolbar (CodeCard.module.css:10-21): padding 10/18/8/22, 11/18.
    static let headerTop: CGFloat = 10, headerBottom: CGFloat = 8
    static let headerLeading: CGFloat = 22, headerTrailing: CGFloat = 18, headerGap: CGFloat = 12
    static let headerFontSize: CGFloat = NativeParityTokens.codeSize // 11
    static let headerLineHeight: CGFloat = 18
    /// SF's 11pt line box is ~13.1pt, so the official 18pt leading adds ~4.9.
    static let headerLineSpacing: CGFloat = 4.9
    static let actionTarget: CGFloat = 24 // copy / wrap buttons

    // Code body (DiffBlock/ReadBlock: 11/19 mono).
    static let codeFontSize: CGFloat = NativeParityTokens.codeSize // 11
    static let codeLineHeight: CGFloat = 19
    static let bodyHorizontal: CGFloat = 22
    static let bodyTop: CGFloat = 6, bodyBottom: CGFloat = 20
    static let lineNumberGap: CGFloat = 12
    /// Monospaced 11pt advance; used only to size the digit gutter.
    static let monoDigitAdvance: CGFloat = 6.6
    static let diffBar: CGFloat = 3

    // IN/OUT sections (ToolRow.module.css:200-230): padding 12/16, gap 14, 150 cap.
    static let ioHorizontal: CGFloat = 16, ioVertical: CGFloat = 12, ioGap: CGFloat = 14
    static let ioMaxHeight: CGFloat = 150
    static let ioFontSize: CGFloat = 11
    static let ioLineHeight: CGFloat = 16
    /// SF's 11pt line box is ~13.1pt, so the official 16pt leading adds ~2.9.
    static let ioLineSpacing: CGFloat = 2.9

    // Caps that the official blocks fold at (headTailCap, locales read/diff/search).
    static let readFoldCap = 8 // CHAT_READ_MAX_LINES
    static let searchFoldCap = 8 // CHAT_SEARCH_MAX_LINES
    static let diffFoldCap = 9 // CHAT_DIFF_MAX_LINES
    static let terminalMaxHeight: CGFloat = 224

    // Official copy (`diff.expandRest` / `read.expandRest` / `terminal.expandRest`).
    static func foldLabel(hidden: Int) -> String { "… 其余 \(hidden) 行" }
    static func foldAccessibilityLabel(hidden: Int) -> String { "展开其余 \(hidden) 行" }
}

// MARK: - Header model

/// The banner above a card body: a language tag, a label, an optional trailing
/// status and an optional copy action (`CodeCard` header).
struct NativeToolCardHeaderModel {
    var label: String
    var language: String?
    var status: String?
    var copyText: String?

    init(label: String, language: String? = nil, status: String? = nil, copyText: String? = nil) {
        self.label = label
        self.language = language
        self.status = status
        self.copyText = copyText
    }
}

// MARK: - Card shell

/// Rounded, hairline-bordered `#F9FAFB` card with the official 4/0/4/4 flow
/// margin. The header stays fixed; only the body scrolls when `maxHeight` is set.
///
/// Layout only: `onCopy` is a slot because the pasteboard write belongs to the
/// host (this file may not import UIKit).
struct NativeToolCardChrome<Content: View>: View {
    var header: NativeToolCardHeaderModel?
    /// Vertical cap for the scrolling body (`nil` = natural height, as official
    /// read/diff/search cards are, because they fold by line count instead).
    var maxHeight: CGFloat?
    var onCopy: ((String) -> Void)?
    var appliesOuterMargins = true
    @ViewBuilder let content: () -> Content

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: NativeToolCardMetrics.cornerRadius, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let header {
                NativeToolCardHeaderRow(model: header, onCopy: onCopy)
            }
            if let maxHeight {
                ScrollView(.vertical) {
                    content()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: maxHeight)
            } else {
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NativeParityTokens.codeBlock)
        .clipShape(shape)
        .overlay(shape.strokeBorder(NativeParityTokens.borderL1, lineWidth: NativeToolCardMetrics.borderWidth))
        .padding(EdgeInsets(top: appliesOuterMargins ? NativeToolCardMetrics.outerTop : 0,
                            leading: appliesOuterMargins ? NativeToolCardMetrics.outerLeading : 0,
                            bottom: appliesOuterMargins ? NativeToolCardMetrics.outerBottom : 0,
                            trailing: 0))
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Header row

/// Banner: `padding 10/18/8/22`, 11/18, language + label tertiary, actions 24x24.
struct NativeToolCardHeaderRow: View {
    let model: NativeToolCardHeaderModel
    var onCopy: ((String) -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: NativeToolCardMetrics.headerGap) {
            HStack(alignment: .firstTextBaseline, spacing: NativeToolCardMetrics.headerGap) {
                if let language = model.language, !language.isEmpty {
                    Text(language)
                        .font(.system(size: NativeToolCardMetrics.headerFontSize, design: .monospaced))
                        .foregroundStyle(NativeParityTokens.labelTertiary)
                        .fixedSize(horizontal: true, vertical: false)
                }
                Text(model.label)
                    .font(.system(size: NativeToolCardMetrics.headerFontSize))
                    .foregroundStyle(NativeParityTokens.labelTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            if let status = model.status, !status.isEmpty {
                Text(status)
                    .font(.system(size: NativeToolCardMetrics.headerFontSize))
                    .foregroundStyle(NativeParityTokens.labelTertiary)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.trailing, 8)
            }
            if let copyText = model.copyText {
                NativeToolCardCopyButton(text: copyText, onCopy: onCopy)
            }
        }
        .lineSpacing(NativeToolCardMetrics.headerLineSpacing)
        .padding(EdgeInsets(top: NativeToolCardMetrics.headerTop,
                            leading: NativeToolCardMetrics.headerLeading,
                            bottom: NativeToolCardMetrics.headerBottom,
                            trailing: NativeToolCardMetrics.headerTrailing))
        .accessibilityElement(children: .contain)
    }
}

/// 24x24 copy target; shows a check for a moment after the copy slot is invoked.
struct NativeToolCardCopyButton: View {
    let text: String
    var onCopy: ((String) -> Void)?
    @State private var copied = false

    var body: some View {
        Button {
            onCopy?(text)
            withAnimation(.easeOut(duration: 0.12)) { copied = true }
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                withAnimation(.easeOut(duration: 0.12)) { copied = false }
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(NativeParityTokens.labelTertiary)
                .frame(width: NativeToolCardMetrics.actionTarget,
                       height: NativeToolCardMetrics.actionTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(copied ? "已复制" : "复制")
    }
}

// MARK: - Exit-code capsule

/// Official `Tag tone="neutral"` exit capsule: 1/8 padding, radius 999, 11/17
/// w500, `#F5F6F7` fill, secondary ink, 4pt error dot, 5 gap, 8 leading margin.
/// The caller decides when the capsule exists: `exit 0` and background jobs
/// never show one (ToolRow.tsx:247, terminal-card-model.ts:107-113).
struct NativeToolCardExitBadge: View {
    var code: Int?
    var signal: String?

    init(code: Int?, signal: String? = nil) {
        self.code = code
        self.signal = signal
    }

    private var label: String? {
        if let signal, !signal.isEmpty, signal != "null" { return "信号 \(signal)" }
        guard let code else { return "未正常退出" }
        return code == 0 ? nil : "退出码 \(code)"
    }

    var body: some View {
        if let label {
            HStack(spacing: 5) {
                Circle()
                    .fill(NativeParityTokens.error)
                    .frame(width: 4, height: 4)
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(NativeParityTokens.labelSecondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 1)
            .background(NativeParityTokens.selector, in: Capsule())
            .padding(.leading, 8)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(label)
        }
    }
}

// MARK: - Code rows

/// One rendered row of a code body: a gutter number, a diff kind, the text.
struct NativeToolCardLine: Equatable {
    enum Kind: Equatable {
        /// read / search / terminal payload rows.
        case plain
        /// diff context row (rendered with the official two-space prefix).
        case context
        case added
        case removed
        /// diff file header (label-secondary, weight 500).
        case path
    }

    var number: Int?
    var text: String
    var kind: Kind

    init(number: Int? = nil, _ text: String, kind: Kind = .plain) {
        self.number = number
        self.text = text
        self.kind = kind
    }

    /// Official `::before` prefixes: `"+ "`, `"- "`, `"  "` for context, none otherwise.
    var displayText: String {
        switch kind {
        case .added: "+ " + text
        case .removed: "- " + text
        case .context: "  " + text
        case .plain, .path: text
        }
    }
}

/// Code body with the official line treatment: optional digit gutter (12 gap),
/// diff colors with a 3pt inset bar, and the 8/9-line head-tail fold that the
/// official `headTailCap` performs (`hidden` rows collapse behind `… 其余 N 行`).
struct NativeToolCardCodeList: View {
    let lines: [NativeToolCardLine]
    var foldCap: Int?
    var showsLineNumbers = false
    /// `true` = `white-space: pre-wrap`; `false` = `pre` plus horizontal scroll.
    var wraps = true
    var inset = true
    /// ReadBlock payloads use `label-primary` (ReadBlock.module.css:22) while diff
    /// context and terminal/search text use `label-secondary`.
    var textColor: Color = NativeParityTokens.labelSecondary
    @State private var expanded = false

    private var codeFont: Font {
        .system(size: NativeToolCardMetrics.codeFontSize, design: .monospaced)
    }

    private var hidden: Int {
        guard let foldCap, !expanded, lines.count > foldCap else { return 0 }
        return lines.count - foldCap
    }

    private var headLines: [NativeToolCardLine] {
        guard hidden > 0, let foldCap else { return lines }
        return Array(lines.prefix(Int((Double(foldCap) / 2).rounded(.up))))
    }

    private var tailLines: [NativeToolCardLine] {
        guard hidden > 0, let foldCap else { return [] }
        return Array(lines.suffix(foldCap - headLines.count))
    }

    private var gutterWidth: CGFloat {
        let digits = max(2, String(lines.last?.number ?? lines.count).count)
        return CGFloat(digits) * NativeToolCardMetrics.monoDigitAdvance
    }

    private var leadingInset: CGFloat {
        let gutter = showsLineNumbers ? gutterWidth + NativeToolCardMetrics.lineNumberGap : 0
        return NativeToolCardMetrics.bodyHorizontal + (inset ? gutter : 0)
    }

    var body: some View {
        if wraps {
            column
        } else {
            ScrollView(.horizontal, showsIndicators: false) { column }
        }
    }

    private var column: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(headLines.enumerated()), id: \.offset) { _, line in row(line) }
            if hidden > 0 { foldButton }
            ForEach(Array(tailLines.enumerated()), id: \.offset) { _, line in row(line) }
        }
        .padding(.top, NativeToolCardMetrics.bodyTop)
        .padding(.bottom, NativeToolCardMetrics.bodyBottom)
    }

    private var foldButton: some View {
        Button {
            withAnimation(.easeOut(duration: 0.16)) { expanded = true }
        } label: {
            Text(NativeToolCardMetrics.foldLabel(hidden: hidden))
                .font(codeFont)
                .foregroundStyle(NativeParityTokens.labelTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, leadingInset)
                .padding(.trailing, NativeToolCardMetrics.bodyHorizontal)
                .frame(minHeight: NativeToolCardMetrics.codeLineHeight, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(NativeToolCardMetrics.foldAccessibilityLabel(hidden: hidden))
    }

    private func row(_ line: NativeToolCardLine) -> some View {
        HStack(alignment: .top, spacing: 0) {
            if showsLineNumbers {
                Text(line.number.map(String.init) ?? "")
                    .foregroundStyle(NativeParityTokens.labelTertiary)
                    .frame(width: gutterWidth, alignment: .trailing)
                    .padding(.trailing, NativeToolCardMetrics.lineNumberGap)
            }
            Text(line.displayText)
                .foregroundStyle(foreground(line))
                .textSelection(.enabled)
                .fixedSize(horizontal: !wraps, vertical: true)
                .frame(maxWidth: wraps ? .infinity : nil, alignment: .leading)
        }
        .font(codeFont)
        .lineSpacing(NativeParityTokens.codeLineSpacing)
        .frame(minHeight: NativeToolCardMetrics.codeLineHeight, alignment: .topLeading)
        .padding(.horizontal, NativeToolCardMetrics.bodyHorizontal)
        .background(background(line))
        .overlay(alignment: .leading) {
            if line.kind == .added || line.kind == .removed {
                Rectangle()
                    .fill(foreground(line))
                    .frame(width: NativeToolCardMetrics.diffBar)
            }
        }
    }

    private func foreground(_ line: NativeToolCardLine) -> Color {
        switch line.kind {
        case .added: NativeParityTokens.success
        case .removed: NativeParityTokens.error
        case .path, .context, .plain: textColor
        }
    }

    private func background(_ line: NativeToolCardLine) -> Color {
        switch line.kind {
        case .added:
            NativeParityTokens.rgba(light: 0x22C55E, lightAlpha: 0.08,
                                    dark: 0x22C55E, darkAlpha: 0.12)
        case .removed:
            NativeParityTokens.rgba(light: 0xEC1313, lightAlpha: 0.08,
                                    dark: 0xEC1313, darkAlpha: 0.12)
        case .path, .context, .plain: .clear
        }
    }
}

// MARK: - IN/OUT sections

/// One IN/OUT section of the generic card: caption gutter label (14 gap), 11/16
/// mono payload, 12/16 padding, independent 150pt scroll.
struct NativeToolCardIOSection: View {
    let label: String
    let text: String
    var isError = false

    var body: some View {
        HStack(alignment: .top, spacing: NativeToolCardMetrics.ioGap) {
            Text(label)
                .font(.system(size: NativeToolCardMetrics.ioFontSize))
                .foregroundStyle(NativeParityTokens.labelCaption)
                .fixedSize(horizontal: true, vertical: false)
            ScrollView(.vertical) {
                Text(text)
                    .font(.system(size: NativeToolCardMetrics.ioFontSize, design: .monospaced))
                    .lineSpacing(NativeToolCardMetrics.ioLineSpacing)
                    .foregroundStyle(isError ? NativeParityTokens.error : NativeParityTokens.labelSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: NativeToolCardMetrics.ioMaxHeight)
        }
        .padding(EdgeInsets(top: NativeToolCardMetrics.ioVertical,
                            leading: NativeToolCardMetrics.ioHorizontal,
                            bottom: NativeToolCardMetrics.ioVertical,
                            trailing: NativeToolCardMetrics.ioHorizontal))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

/// The official 0.5pt `border-l2` hairline between two card sections.
struct NativeToolCardHairline: View {
    var color: Color = NativeParityTokens.borderL2

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(height: NativeToolCardMetrics.borderWidth)
            .accessibilityHidden(true)
    }
}

#if DEBUG
private struct NativeToolCardChromePreview: View {
    private var diffLines: [NativeToolCardLine] {
        [NativeToolCardLine(number: 1, "@@ Sources/App.swift → Sources/App.swift", kind: .path)]
            + (1...12).map { index in
                NativeToolCardLine(number: index,
                                   index == 3 ? "let chrome = NativeToolCardChrome()" : "print(\(index))",
                                   kind: index == 3 ? .added : (index == 4 ? .removed : .context))
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NativeToolCardChrome(header: NativeToolCardHeaderModel(label: "diff", language: "swift", copyText: "…"),
                                 maxHeight: NativeToolCardMetrics.terminalMaxHeight) {
                NativeToolCardCodeList(lines: diffLines, foldCap: NativeToolCardMetrics.diffFoldCap)
            }
            NativeToolCardChrome(maxHeight: nil) {
                NativeToolCardIOSection(label: "输入", text: "{ \"path\": \"Package.swift\" }")
                NativeToolCardHairline()
                NativeToolCardIOSection(label: "输出", text: "error: not found", isError: true)
            }
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                NativeToolCardExitBadge(code: 1)
            }
        }
        .padding(NativeParityTokens.transcriptSide)
        .background(NativeParityTokens.surface)
    }
}

struct NativeToolCardChromePreviewProvider: PreviewProvider {
    static var previews: some View { NativeToolCardChromePreview() }
}
#endif
