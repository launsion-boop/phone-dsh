// SPDX-License-Identifier: MIT

import Foundation
import Markdown

// Native block and inline projections of CommonMark/GFM plus DSH TeX extensions.
enum NativeMarkdownVariant: Hashable {
    case body, compact
}

indirect enum NativeMarkdownInline: Hashable {
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

struct NativeMarkdownListItem: Equatable {
    var checked: Bool?
    var blocks: [NativeMarkdownBlock]
}

enum NativeMarkdownTableAlignment: Equatable {
    case left, center, right
}

indirect enum NativeMarkdownBlock: Equatable {
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

/// Characters fed to `Document(parsing:)`, across every parse (full,
/// incremental prefix and streaming tail). The simulator perf guard reads it
/// to prove the streaming parse stays linear instead of re-parsing the whole
/// message at every delta.
enum NativeMarkdownParseWork {
    private static let lock = NSLock()
    private static var characters = 0

    static var parsedCharacters: Int {
        lock.lock(); defer { lock.unlock() }
        return characters
    }

    static func record(_ count: Int) {
        guard count > 0 else { return }
        lock.lock(); characters += count; lock.unlock()
    }

    static func reset() {
        lock.lock(); characters = 0; lock.unlock()
    }
}

enum NativeMarkdownParser {
    static func parse(_ source: String, streaming: Bool = false) -> [NativeMarkdownBlock] {
        NativeMarkdownParseWork.record(source.utf8.count)
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

/// Incremental streaming parser.
///
/// Streaming Markdown is append-only, and a blank line outside every open
/// block construct ends the preceding block. This parser freezes the blocks of
/// a stable prefix at such a boundary and re-parses only the tail. Anything the
/// line scanner cannot prove safe (an open fence, indented code, a list that
/// has not clearly ended, HTML blocks that survive blank lines, `$$` math) keeps
/// the boundary frozen, so the result at every step is exactly
/// `NativeMarkdownParser.parse(fullText, streaming: true)`.
///
/// Link reference definitions are document-wide: a definition in the tail can
/// change the meaning of a link in an earlier, already-frozen paragraph. Once
/// one is seen (or even starts on an incomplete last line) the parser falls
/// back to a full parse for the rest of the message. Tables cannot span a blank
/// line and therefore cannot cross a boundary.
struct NativeMarkdownIncrementalParser {
    private(set) var blocks: [NativeMarkdownBlock] = []
    private var frozen: [NativeMarkdownBlock] = []
    private var tailBlocks: [NativeMarkdownBlock] = []
    private var tail = ""
    private var fullText = ""
    private var fullMode = false
    /// True only while `tailBlocks` is one paragraph whose text is `tail`
    /// minus CommonMark's stripped trailing whitespace. A plain delta then
    /// appends one text node instead of re-parsing the growing paragraph,
    /// which keeps a very long unbroken line linear too.
    private var plainTail = false
    /// The paragraph's parser-visible text (trailing spaces stripped).
    private var plainText = ""
    /// Trailing whitespace held back until a later chunk makes it internal.
    private var plainPending = ""
    private var scanner = NativeMarkdownBoundaryScanner()
    private(set) var plainAppendCount = 0
    private(set) var tailParseCount = 0

    mutating func append(_ chunk: String) -> [NativeMarkdownBlock] {
        guard !chunk.isEmpty else { return blocks }
        fullText += chunk
        if fullMode {
            blocks = NativeMarkdownParser.parse(fullText, streaming: true)
            return blocks
        }
        let canAppendPlain = plainTail && Self.isPlainText(chunk)
        tail += chunk
        let boundary = scanner.feed(chunk)
        if scanner.requiresFullParse {
            // From here on the document has document-wide link definitions.
            fullMode = true
            frozen = []
            tail = ""
            tailBlocks = []
            plainTail = false
            plainText = ""
            plainPending = ""
            blocks = NativeMarkdownParser.parse(fullText, streaming: true)
            return blocks
        }
        if canAppendPlain, boundary == nil, !tail.isEmpty,
           Self.isSingleTextParagraph(tailBlocks.last) {
            // CommonMark strips trailing spaces at a paragraph end but keeps
            // them when more text follows. Materialize only the settled part
            // and carry the trailing run to the next chunk.
            let combined = plainPending + chunk
            let scalars = combined.unicodeScalars
            var split = scalars.endIndex
            while split > scalars.startIndex {
                let previous = scalars.index(before: split)
                let scalar = scalars[previous]
                guard scalar == " " || scalar == "\t" else { break }
                split = previous
            }
            let content = String(combined[..<split])
            plainPending = String(combined[split...])
            // Drop every reference the parser holds before growing the
            // buffer so the append can stay in place instead of copying the
            // whole paragraph.
            blocks = []
            tailBlocks[tailBlocks.count - 1] = .paragraph([])
            plainText += content
            tailBlocks[tailBlocks.count - 1] = .paragraph([.text(plainText)])
            blocks = frozen + tailBlocks
            plainAppendCount += 1
            return blocks
        }
        if let boundary, boundary > 0, boundary <= tail.utf8.count {
            let split = tail.utf8.index(tail.utf8.startIndex, offsetBy: boundary)
            let prefix = String(tail[..<split])
            frozen.append(contentsOf: NativeMarkdownParser.parse(prefix, streaming: true))
            tail = String(tail[split...])
        }
        tailParseCount += 1
        tailBlocks = tail.isEmpty ? [] : NativeMarkdownParser.parse(tail, streaming: true)
        plainTail = false
        if !tail.isEmpty, Self.isPlainText(tail),
           Self.isPlainParagraph(tailBlocks, source: tail) {
            plainTail = true
            plainText = Self.paragraphText(tailBlocks) ?? ""
            plainPending = String(tail.dropFirst(plainText.count))
        } else {
            plainText = ""
            plainPending = ""
        }
        blocks = frozen + tailBlocks
        return blocks
    }

    /// Inline Markdown cannot start on these characters, and a line break can
    /// turn the paragraph into a block construct. Rejecting them keeps the
    /// append-only fast path provably equivalent to a full parse.
    private static func isPlainText(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            if scalar == "\n" || scalar == "\r" || scalar == "\t" || scalar == "`"
                || scalar == "*" || scalar == "_" || scalar == "~" || scalar == "["
                || scalar == "]" || scalar == "<" || scalar == ">" || scalar == "&"
                || scalar == "\\" || scalar == "$" || scalar == "!" {
                return false
            }
        }
        return true
    }

    /// Shape check without binding (and retaining) the previous text value:
    /// a bound `inline` local would keep the buffer non-unique and turn the
    /// next in-place append into a full copy.
    private static func isSingleTextParagraph(_ block: NativeMarkdownBlock?) -> Bool {
        guard case .paragraph(let inline)? = block, inline.count == 1,
              case .text = inline[0] else { return false }
        return true
    }

    private static func paragraphText(_ blocks: [NativeMarkdownBlock]) -> String? {
        guard blocks.count == 1,
              case .paragraph(let inline) = blocks[0],
              inline.count == 1,
              case .text(let text) = inline[0] else { return nil }
        return text
    }

    /// A plain paragraph is one text node whose only possible difference from
    /// the source is the trailing-whitespace run CommonMark strips.
    private static func isPlainParagraph(_ blocks: [NativeMarkdownBlock],
                                         source: String) -> Bool {
        guard let text = paragraphText(blocks), source.hasPrefix(text) else { return false }
        return source.dropFirst(text.count).allSatisfy { $0 == " " }
    }
}

/// Line scanner that decides which blank lines are safe freeze boundaries.
///
/// It only needs to answer one question ("is every block construct closed
/// here?"), so it tracks the conservative subset of CommonMark/GFM that can
/// absorb a following blank line: fenced code, indented code, lists, HTML
/// blocks whose end is not a blank line, and `$$` math. It never rewrites the
/// text; false `unsafe` answers only cost a larger tail parse.
private struct NativeMarkdownBoundaryScanner {
    private struct Fence {
        var marker: Unicode.Scalar
        var count: Int
    }

    private var fence: Fence?
    private var mathOpen = false
    private var htmlEnd: String?
    private var indentedCode = false
    private var listActive = false
    private var afterBlank = true
    private var pending: [UInt8] = []
    /// No newline exists before this offset; resuming the search there keeps
    /// a long unbroken line from being rescanned on every 40-byte delta.
    private var pendingSearchStart = 0
    private var processedBytes = 0
    private var boundary: Int?
    private(set) var requiresFullParse = false

    /// Feeds an appended chunk. Returns the byte offset in the *current tail*
    /// of the latest safe boundary, if the scanner just found one. The caller
    /// slices the tail there; this scanner keeps its offset bookkeeping in
    /// sync so the next feed resumes at the same place.
    mutating func feed(_ chunk: String) -> Int? {
        pending.append(contentsOf: chunk.utf8)
        var lineStart = 0
        var search = min(max(0, pendingSearchStart), pending.count)
        while search < pending.count,
              let newline = pending[search...].firstIndex(of: 0x0A) {
            let lineBytes = Array(pending[lineStart..<newline])
            process(lineBytes: lineBytes, startOffset: processedBytes)
            processedBytes += (newline - lineStart) + 1
            lineStart = newline + 1
            search = lineStart
        }
        pendingSearchStart = pending.count
        if lineStart > 0 {
            pending.removeFirst(lineStart)
            pendingSearchStart = pending.count
        }
        // A definition can be the incomplete last line at EOF; swift-markdown
        // still parses it as a definition, and it changes earlier links. Only
        // this line's start matters, and a label is at most 999 characters, so
        // inspect a bounded prefix: decoding the whole growing pending buffer
        // would make a long unbroken paragraph quadratic.
        if !requiresFullParse, fence == nil, htmlEnd == nil, !indentedCode, !pending.isEmpty {
            let text = String(decoding: pending.prefix(2_048), as: UTF8.self)
            if looksLikeReferenceDefinition(text) {
                requiresFullParse = true
            }
        }
        guard let value = boundary else { return nil }
        boundary = nil
        processedBytes -= value
        return value
    }

    private mutating func process(lineBytes: [UInt8], startOffset: Int) {
        var bytes = lineBytes
        if bytes.last == 0x0D { bytes.removeLast() }
        let text = String(decoding: bytes, as: UTF8.self)
        let blank = text.allSatisfy { $0 == " " || $0 == "\t" }
        let indent = indentation(of: text)

        if let open = fence {
            if isClosingFence(text, open: open) { fence = nil }
            afterBlank = false
            return
        }
        if mathOpen {
            if text.trimmingCharacters(in: .whitespaces) == "$$" { mathOpen = false }
            afterBlank = false
            return
        }
        if let end = htmlEnd {
            if text.range(of: end, options: [.caseInsensitive]) != nil { htmlEnd = nil }
            afterBlank = false
            return
        }
        if blank {
            afterBlank = true
            // Indented code and lists can absorb a following blank line, so
            // the boundary waits until their end is proven on a later line.
            if !indentedCode && !listActive {
                boundary = startOffset + bytes.count + 1
            }
            return
        }
        if indentedCode {
            if indent >= 4 {
                afterBlank = false
                return
            }
            // A non-indented line ends the code block at the blank line above.
            boundary = startOffset
            indentedCode = false
        }
        let wasAfterBlank = afterBlank
        if listActive && wasAfterBlank {
            // After a blank line a list only continues with content that is
            // indented, a new list marker, or a lazy blockquote/fence marker.
            // Anything else at column zero is a new top-level block: the blank
            // line above ends the list, so freezing there is safe.
            if indent == 0, !isListMarker(text), !text.hasPrefix(">"),
               openingFence(text) == nil, htmlBlockEnd(text) == nil {
                boundary = startOffset
                listActive = false
            }
        }
        afterBlank = false

        if let open = openingFence(text) {
            fence = open
            return
        }
        if text.trimmingCharacters(in: .whitespaces) == "$$" {
            mathOpen = true
            return
        }
        if let end = htmlBlockEnd(text) {
            htmlEnd = end
            return
        }
        if indent >= 4, !listActive, wasAfterBlank {
            indentedCode = true
            return
        }
        // Document-wide link definitions invalidate every frozen prefix.
        if looksLikeReferenceDefinition(text) {
            requiresFullParse = true
        }
        if !listActive, isListMarker(text) {
            listActive = true
        }
    }

    private func indentation(of text: String) -> Int {
        var width = 0
        for scalar in text.unicodeScalars {
            if scalar == " " {
                width += 1
            } else if scalar == "\t" {
                width += 4
            } else {
                break
            }
        }
        return width
    }

    private func isListMarker(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        var index = 0
        while index < scalars.count, scalars[index] == " ", index < 4 { index += 1 }
        guard index < scalars.count else { return false }
        let first = scalars[index]
        if first == "-" || first == "+" || first == "*" {
            let next = index + 1
            return next >= scalars.count || scalars[next] == " " || scalars[next] == "\t"
        }
        if first.value >= 48, first.value <= 57 {
            var cursor = index
            while cursor < scalars.count, scalars[cursor].value >= 48,
                  scalars[cursor].value <= 57, cursor - index < 9 {
                cursor += 1
            }
            guard cursor > index, cursor < scalars.count,
                  scalars[cursor] == "." || scalars[cursor] == ")" else { return false }
            let next = cursor + 1
            return next >= scalars.count || scalars[next] == " " || scalars[next] == "\t"
        }
        return false
    }

    private func openingFence(_ text: String) -> Fence? {
        let scalars = Array(text.unicodeScalars)
        var index = 0
        while index < scalars.count, scalars[index] == " ", index < 4 { index += 1 }
        guard index < scalars.count else { return nil }
        let marker = scalars[index]
        guard marker == "`" || marker == "~" else { return nil }
        var count = 0
        while index + count < scalars.count, scalars[index + count] == marker {
            count += 1
        }
        guard count >= 3 else { return nil }
        return Fence(marker: marker, count: count)
    }

    private func isClosingFence(_ text: String, open: Fence) -> Bool {
        let scalars = Array(text.unicodeScalars)
        var index = 0
        while index < scalars.count, scalars[index] == " ", index < 4 { index += 1 }
        var count = 0
        while index + count < scalars.count, scalars[index + count] == open.marker {
            count += 1
        }
        guard count >= open.count else { return false }
        let rest = scalars[(index + count)...]
        return rest.allSatisfy { $0 == " " || $0 == "\t" }
    }

    /// Returns the terminator for HTML block kinds 1-5 (the kinds that survive
    /// a blank line). Kinds 6-7 end at a blank line, so a blank-line boundary is
    /// already outside them.
    private func htmlBlockEnd(_ text: String) -> String? {
        let indent = indentation(of: text)
        guard indent <= 3 else { return nil }
        let line = text.drop { $0 == " " || $0 == "\t" }
        guard line.first == "<" else { return nil }
        let lower = line.lowercased()

        func tagFollows(_ prefix: String) -> Bool {
            guard lower.hasPrefix(prefix) else { return false }
            let rest = lower.dropFirst(prefix.count)
            return rest.isEmpty || rest.first == ">" || rest.first == " "
                || rest.first == "\t"
        }

        for tag in ["script", "pre", "style", "textarea"] where tagFollows("<\(tag)") {
            let close = "</\(tag)>"
            return lower.contains(close) ? nil : close
        }
        if lower.hasPrefix("<!--") {
            return lower.contains("-->") ? nil : "-->"
        }
        if lower.hasPrefix("<?") {
            return lower.contains("?>") ? nil : "?>"
        }
        if lower.hasPrefix("<![cdata[") {
            return lower.contains("]]>") ? nil : "]]>"
        }
        let scalars = Array(line.unicodeScalars)
        if scalars.count >= 3, scalars[0] == "<", scalars[1] == "!",
           scalars[2].value >= 65, scalars[2].value <= 90 {
            return lower.contains(">") ? nil : ">"
        }
        return nil
    }

    /// True when the line can start a document-wide link reference definition.
    /// Container markers (blockquote, list marker, up to three spaces) are
    /// skipped; a false positive only forces a full parse.
    private func looksLikeReferenceDefinition(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == ">" || scalar == " " || scalar == "\t" {
                index += 1
                continue
            }
            if scalar == "-" || scalar == "+" || scalar == "*" {
                let next = index + 1
                if next < scalars.count, scalars[next] == " " || scalars[next] == "\t" {
                    index = next + 1
                    continue
                }
                break
            }
            if scalar.value >= 48, scalar.value <= 57 {
                var cursor = index
                while cursor < scalars.count, scalars[cursor].value >= 48,
                      scalars[cursor].value <= 57 {
                    cursor += 1
                }
                if cursor < scalars.count, scalars[cursor] == "." || scalars[cursor] == ")" {
                    cursor += 1
                    if cursor < scalars.count, scalars[cursor] == " " || scalars[cursor] == "\t" {
                        index = cursor + 1
                        continue
                    }
                }
                break
            }
            break
        }
        guard index + 2 < scalars.count, scalars[index] == "[" else { return false }
        var cursor = index + 1
        while cursor < scalars.count {
            if scalars[cursor] == "\\" {
                // A backslash escape can hide a `]` inside the label.
                cursor += 2
                continue
            }
            if scalars[cursor] == "]" || scalars[cursor] == "[" { break }
            cursor += 1
        }
        guard cursor + 1 < scalars.count, scalars[cursor] == "]",
              scalars[cursor + 1] == ":" else { return false }
        return true
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
