// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — one selectable text surface per assistant message.
//
// SwiftUI's `.textSelection` is per-Text and cannot cross the Markdown
// widgets (code cards, tables), so a message made of a VStack of blocks has
// no document-like selection. This renders the whole message into ONE
// NSAttributedString in a non-editable, selectable UITextView: long-press /
// double-tap give the native selection handles, and a drag crosses
// paragraphs, lists, code and tables because they are all one text storage.
//
// While a selection is live a streaming update is buffered (assigning
// attributedText would clear it) and applied once the selection collapses.

import SwiftUI
import UIKit

/// Builds one attributed string from the app's Markdown blocks.
enum MarkdownTextBuilder {
    static func build(_ markdown: String,
                      baseSize: CGFloat = 17,
                      codeSize: CGFloat = 15) -> NSAttributedString {
        let base = UIFont.systemFont(ofSize: baseSize)
        let code = UIFont.monospacedSystemFont(ofSize: codeSize, weight: .regular)
        let textColor = UIColor.label
        let secondary = UIColor.secondaryLabel
        let linkColor = UIColor(named: "AccentColor") ?? .link
        let codeBackground = UIColor.secondarySystemFill

        let out = NSMutableAttributedString()
        let blocks = NativeMarkdownParser.parse(markdown)

        func newline() {
            guard out.length > 0, !out.string.hasSuffix("\n") else { return }
            out.append(NSAttributedString(string: "\n", attributes: [.font: base]))
        }

        for block in blocks {
            newline()
            switch block {
            case .heading(let level, let text):
                let sizes: [CGFloat] = [28, 22, 20, 19, 17, 17]
                let size = sizes[min(max(level, 1), 6) - 1]
                let style = NSMutableParagraphStyle()
                style.paragraphSpacingBefore = 10
                style.paragraphSpacing = 6
                appendInline(text, to: out,
                             base: .systemFont(ofSize: size, weight: .bold),
                             code: code, codeBackground: codeBackground,
                             textColor: textColor, linkColor: linkColor,
                             style: style)
            case .paragraph(let text):
                let style = NSMutableParagraphStyle()
                style.lineSpacing = 3
                style.paragraphSpacing = 9
                appendInline(text, to: out, base: base, code: code,
                             codeBackground: codeBackground, textColor: textColor,
                             linkColor: linkColor, style: style)
            case .list(let ordered, let items):
                for (index, item) in items.enumerated() {
                    let style = NSMutableParagraphStyle()
                    style.lineSpacing = 3
                    style.paragraphSpacing = 3
                    style.firstLineHeadIndent = 2
                    style.headIndent = 20
                    let marker = ordered ? "\(index + 1). " : "• "
                    out.append(NSAttributedString(string: marker, attributes: [
                        .font: base, .foregroundColor: secondary, .paragraphStyle: style,
                    ]))
                    appendInline(item, to: out, base: base, code: code,
                                 codeBackground: codeBackground, textColor: textColor,
                                 linkColor: linkColor, style: style)
                    if index < items.count - 1 {
                        out.append(NSAttributedString(string: "\n", attributes: [
                            .font: base, .paragraphStyle: style,
                        ]))
                    }
                }
            case .code(_, let source):
                let style = NSMutableParagraphStyle()
                style.lineSpacing = 2
                style.paragraphSpacingBefore = 6
                style.paragraphSpacing = 8
                style.firstLineHeadIndent = 8
                style.headIndent = 8
                let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
                for (index, line) in lines.enumerated() {
                    out.append(NSAttributedString(string: String(line), attributes: [
                        .font: code, .foregroundColor: textColor,
                        .backgroundColor: codeBackground, .paragraphStyle: style,
                    ]))
                    if index < lines.count - 1 {
                        out.append(NSAttributedString(string: "\n", attributes: [
                            .font: code, .backgroundColor: codeBackground,
                            .paragraphStyle: style,
                        ]))
                    }
                }
            case .table(let header, let rows):
                let tableFont = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
                let style = NSMutableParagraphStyle()
                style.defaultTabInterval = 72
                var rowTexts: [NSAttributedString] = []
                for (index, row) in ([header] + rows).enumerated() {
                    let text = row.joined(separator: "\t")
                    rowTexts.append(NSAttributedString(string: text, attributes: [
                        .font: index == 0
                            ? UIFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
                            : tableFont,
                        .foregroundColor: textColor,
                        .paragraphStyle: style,
                    ]))
                }
                for (index, row) in rowTexts.enumerated() {
                    out.append(row)
                    if index < rowTexts.count - 1 {
                        out.append(NSAttributedString(string: "\n", attributes: [
                            .font: tableFont, .paragraphStyle: style,
                        ]))
                    }
                }
            }
        }
        while out.string.hasSuffix("\n") {
            out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1))
        }
        return out
    }

    /// Walks the inline Markdown runs of one block and appends them.
    private static func appendInline(_ source: String,
                                     to out: NSMutableAttributedString,
                                     base: UIFont, code: UIFont,
                                     codeBackground: UIColor,
                                     textColor: UIColor, linkColor: UIColor,
                                     style: NSParagraphStyle) {
        guard let parsed = try? AttributedString(markdown: source) else {
            out.append(NSAttributedString(string: source, attributes: [
                .font: base, .foregroundColor: textColor, .paragraphStyle: style,
            ]))
            return
        }
        for run in parsed.runs {
            let text = String(parsed[run.range].characters)
            guard !text.isEmpty else { continue }
            let inline = run.inlinePresentationIntent ?? []
            var attributes: [NSAttributedString.Key: Any] = [
                .font: base, .foregroundColor: textColor, .paragraphStyle: style,
            ]
            if inline.contains(.stronglyEmphasized) {
                attributes[.font] = base.with(.traitBold)
            }
            if inline.contains(.emphasized) {
                attributes[.font] = (attributes[.font] as? UIFont ?? base).with(.traitItalic)
            }
            if inline.contains(.code) {
                attributes[.font] = code
                attributes[.backgroundColor] = codeBackground
            }
            if inline.contains(.strikethrough) {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let link = run.link {
                attributes[.link] = link
                attributes[.foregroundColor] = linkColor
            }
            out.append(NSAttributedString(string: text, attributes: attributes))
        }
    }
}

private extension UIFont {
    func with(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(
            fontDescriptor.symbolicTraits.union(traits)) else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}

/// One assistant message as a single selectable text surface.
struct SelectableMarkdownText: UIViewRepresentable {
    let markdown: String
    /// Return true when the app handled the link (a workspace file); false
    /// lets the system open it.
    var onOpenURL: ((URL) -> Bool)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(usingTextLayoutManager: true)
        view.delegate = context.coordinator
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.textContainer.widthTracksTextView = true
        view.contentInsetAdjustmentBehavior = .never
        view.dataDetectorTypes = []
        view.linkTextAttributes = [:]
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        context.coordinator.textView = view
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.apply(markdown, to: view)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView,
                      context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        let height = uiView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)).height
        return CGSize(width: width, height: ceil(height))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: SelectableMarkdownText
        weak var textView: UITextView?
        private var appliedMarkdown: String?
        private var pendingMarkdown: String?
        private var isApplying = false

        init(_ parent: SelectableMarkdownText) { self.parent = parent }

        func apply(_ markdown: String, to view: UITextView) {
            guard markdown != appliedMarkdown else { return }
            // Do not clear a live selection while the answer streams in.
            if view.selectedRange.length > 0 {
                pendingMarkdown = markdown
                return
            }
            render(markdown, in: view)
        }

        private func render(_ markdown: String, in view: UITextView) {
            isApplying = true
            view.attributedText = MarkdownTextBuilder.build(markdown)
            isApplying = false
            appliedMarkdown = markdown
            pendingMarkdown = nil
            view.invalidateIntrinsicContentSize()
        }

        func textViewDidChangeSelection(_ view: UITextView) {
            guard !isApplying, view.selectedRange.length == 0,
                  let pending = pendingMarkdown else { return }
            render(pending, in: view)
        }

        func textView(_ view: UITextView, editMenuForTextIn range: NSRange,
                      suggestedActions: [UIMenuElement]) -> UIMenu? {
            var actions = suggestedActions
            actions.append(UIAction(title: "复制全文") { [weak self] _ in
                guard let self else { return }
                UIPasteboard.general.string = self.parent.markdown
            })
            return UIMenu(children: actions)
        }

        func textView(_ view: UITextView, primaryActionFor textItem: UITextItem,
                      defaultAction: UIAction) -> UIAction? {
            guard case .link(let url) = textItem.content else { return defaultAction }
            guard let handled = parent.onOpenURL?(url), handled else { return defaultAction }
            return nil
        }
    }
}
