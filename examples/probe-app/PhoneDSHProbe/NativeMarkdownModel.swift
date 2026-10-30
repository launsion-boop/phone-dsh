// SPDX-License-Identifier: MIT

import Foundation
import Markdown

// Native block and inline projections of CommonMark/GFM plus DSH TeX extensions.
enum NativeMarkdownVariant {
    case body, compact
}

indirect enum NativeMarkdownInline {
    case text(String)
    case strong([NativeMarkdownInline])
    case emphasis([NativeMarkdownInline])
    case delete([NativeMarkdownInline])
    case code(String)
    case link(destination: String, children: [NativeMarkdownInline])
    case image(source: String, alt: String)
    case math(String)
    case footnote(String)
    case html(String)
}

struct NativeMarkdownListItem {
    var checked: Bool?
    var blocks: [NativeMarkdownBlock]
}

enum NativeMarkdownTableAlignment {
    case left, center, right
}

indirect enum NativeMarkdownBlock {
    case heading(level: Int, content: [NativeMarkdownInline])
    case paragraph([NativeMarkdownInline])
    case list(ordered: Bool, start: Int, items: [NativeMarkdownListItem])
    case blockquote([NativeMarkdownBlock])
    case code(language: String, source: String)
    case table(header: [[NativeMarkdownInline]], rows: [[[NativeMarkdownInline]]], alignments: [NativeMarkdownTableAlignment?])
    case image(source: String, alt: String, title: String)
    case math(String)
    case thematicBreak
}

enum NativeMarkdownParser {
    static func parse(_ source: String, streaming: Bool = false) -> [NativeMarkdownBlock] {
        var preprocessor = NativeMarkdownPreprocessor(source: source, streaming: streaming)
        let document = Document(parsing: preprocessor.process())
        var parser = NativeMarkdownASTParser(math: preprocessor.math)
        var blocks = parser.blocks(document.children)
        if !preprocessor.footnotes.isEmpty {
            let definitions = preprocessor.footnotes.sorted { $0.key < $1.key }
            blocks.append(.paragraph([.strong([.text("脚注")])]))
            for (identifier, content) in definitions {
                var inline: [NativeMarkdownInline] = [.text("[\(identifier)] ")]
                inline.append(contentsOf: parser.inlines(Document(parsing: content).children))
                blocks.append(.paragraph(inline))
            }
        }
        return blocks
    }
}

private struct NativeMarkdownPreprocessor {
    let source: String
    let streaming: Bool
    var math: [String: String] = [:]
    var footnotes: [String: String] = [:]

    init(source: String, streaming: Bool) {
        self.source = source
        self.streaming = streaming
    }

    mutating func process() -> String {
        var text = source
        if !streaming {
            extractFootnotes(from: &text)
            text = replaceDisplayMath(in: text)
            text = replaceInlineMath(in: text)
        }
        return text
    }

    private mutating func extractFootnotes(from text: inout String) {
        var retained: [String] = []
        for line in text.components(separatedBy: .newlines) {
            if let match = line.wholeMatch(of: /^\[\^([^\]]+)\]:\s*(.*)$/) {
                let identifier = String(match.output.1)
                footnotes[identifier] = String(match.output.2)
            } else {
                retained.append(line)
            }
        }
        text = retained.joined(separator: "\n")
        for identifier in footnotes.keys {
            text = text.replacingOccurrences(of: "[^\(identifier)]", with: "DSHFOOTNOTE\(identifier)END")
        }
    }

    private mutating func replaceDisplayMath(in text: String) -> String {
        var result = text
        result = replacing(pattern: #"(?s)\$\$(.+?)\$\$"#, in: result) { "\n```math\n\($0)\n```\n" }
        result = replacing(pattern: #"(?s)\\\[(.+?)\\\]"#, in: result) { "\n```math\n\($0)\n```\n" }
        return result
    }

    private mutating func replaceInlineMath(in text: String) -> String {
        var result = text
        for pattern in [#"(?s)\\\((.+?)\\\)"#, #"(?s)(?<!\$)\$([^\$\n]+?)\$(?!\$)"#] {
            result = replacing(pattern: pattern, in: result) { latex in
                let key = "__DSH_MATH_\(math.count)__"
                math[key] = latex
                return "`\(key)`"
            }
        }
        return result
    }

    private func replacing(pattern: String, in input: String, transform: (String) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return input }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        var output = ""
        var cursor = input.startIndex
        for match in regex.matches(in: input, range: range) {
            guard let whole = Range(match.range, in: input),
                  let capture = Range(match.range(at: 1), in: input) else { continue }
            output += input[cursor..<whole.lowerBound]
            output += transform(String(input[capture]))
            cursor = whole.upperBound
        }
        output += input[cursor...]
        return output
    }
}

private struct NativeMarkdownASTParser {
    let math: [String: String]

    func blocks<S: Sequence>(_ children: S) -> [NativeMarkdownBlock] where S.Element == Markup {
        children.compactMap(block)
    }

    func block(_ markup: Markup) -> NativeMarkdownBlock? {
        if let value = markup as? Heading { return .heading(level: value.level, content: inlines(value.children)) }
        if let value = markup as? Paragraph {
            if value.childCount == 1, let image = value.children.first as? Markdown.Image {
                return .image(source: image.source ?? "", alt: image.plainText, title: image.title ?? "")
            }
            return .paragraph(inlines(value.children))
        }
        if let value = markup as? CodeBlock {
            if value.language == "math" { return .math(value.code) }
            return .code(language: value.language ?? "", source: value.code)
        }
        if let value = markup as? OrderedList {
            return .list(ordered: true, start: Int(value.startIndex), items: value.children.map(listItem))
        }
        if let value = markup as? UnorderedList {
            return .list(ordered: false, start: 1, items: value.children.map(listItem))
        }
        if let value = markup as? BlockQuote { return .blockquote(blocks(value.children)) }
        if markup is ThematicBreak { return .thematicBreak }
        if let value = markup as? Markdown.Table {
            let header = value.head.children.map { inlines(($0 as? Markdown.Table.Cell)?.children ?? $0.children) }
            let rows = value.body.rows.map { row -> [[NativeMarkdownInline]] in
                row.children.map { inlines(($0 as? Markdown.Table.Cell)?.children ?? $0.children) }
            }
            let alignments = value.columnAlignments.map { alignment -> NativeMarkdownTableAlignment? in
                switch alignment {
                case .left: .left
                case .center: .center
                case .right: .right
                case nil: nil
                }
            }
            return .table(header: header, rows: Array(rows), alignments: alignments)
        }
        if let value = markup as? HTMLBlock { return .paragraph([.html(value.rawHTML)]) }
        return nil
    }

    func listItem(_ markup: Markup) -> NativeMarkdownListItem {
        guard let item = markup as? ListItem else { return NativeMarkdownListItem(checked: nil, blocks: []) }
        let checked: Bool?
        switch item.checkbox {
        case .checked: checked = true
        case .unchecked: checked = false
        case nil: checked = nil
        }
        return NativeMarkdownListItem(checked: checked, blocks: blocks(item.children))
    }

    func inlines<S: Sequence>(_ children: S) -> [NativeMarkdownInline] where S.Element == Markup {
        children.flatMap(inline)
    }

    private func inline(_ markup: Markup) -> [NativeMarkdownInline] {
        if let value = markup as? Markdown.Text {
            return footnoteParts(value.string)
        }
        if let value = markup as? Strong { return [.strong(inlines(value.children))] }
        if let value = markup as? Emphasis { return [.emphasis(inlines(value.children))] }
        if let value = markup as? Strikethrough { return [.delete(inlines(value.children))] }
        if let value = markup as? InlineCode {
            if let latex = math[value.code] { return [.math(latex)] }
            return [.code(value.code)]
        }
        if let value = markup as? Markdown.Link {
            return [.link(destination: value.destination ?? "", children: inlines(value.children))]
        }
        if let value = markup as? Markdown.Image {
            return [.image(source: value.source ?? "", alt: value.plainText)]
        }
        if let value = markup as? InlineHTML { return [.html(value.rawHTML)] }
        if markup is SoftBreak { return [.text(" ")] }
        if markup is LineBreak { return [.text("\n")] }
        return []
    }

    private func footnoteParts(_ text: String) -> [NativeMarkdownInline] {
        guard let regex = try? NSRegularExpression(pattern: #"DSHFOOTNOTE(.+?)END"#) else { return [.text(text)] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var result: [NativeMarkdownInline] = []
        var cursor = text.startIndex
        for match in regex.matches(in: text, range: range) {
            guard let whole = Range(match.range, in: text), let id = Range(match.range(at: 1), in: text) else { continue }
            if cursor < whole.lowerBound { result.append(.text(String(text[cursor..<whole.lowerBound]))) }
            result.append(.footnote(String(text[id])))
            cursor = whole.upperBound
        }
        if result.isEmpty { return [.text(text)] }
        if cursor < text.endIndex { result.append(.text(String(text[cursor...]))) }
        return result
    }
}
