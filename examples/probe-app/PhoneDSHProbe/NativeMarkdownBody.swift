// SPDX-License-Identifier: MIT
import SwiftUI

/// A small native block renderer for the Markdown preview. Inline emphasis and
/// links use Foundation's Markdown parser; block boundaries remain explicit so
/// headings, paragraphs, lists, fences and tables do not collapse into one run.
struct NativeMarkdownBody: View {
    private let blocks: [NativeMarkdownBlock]

    init(markdown: String) {
        blocks = NativeMarkdownParser.parse(markdown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                render(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // 版心由外层给,这里不再自留一圈内边距(那会让正文比版心多缩 16)。
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func render(_ block: NativeMarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            inline(text)
                .font(headingFont(level))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let text):
            inline(text)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        case .list(let ordered, let items):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(ordered ? "\(index + 1)." : "•")
                            .foregroundStyle(.secondary)
                            .frame(minWidth: ordered ? 24 : 12, alignment: .trailing)
                        inline(item)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .code(let language, let source):
            DSSCodeBlock(source: source, language: language)
        case .table(let header, let rows):
            ScrollView(.horizontal) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    tableRow(header, isHeader: true)
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        tableRow(row, isHeader: false)
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            .accessibilityElement(children: .contain)
        }
    }

    private func tableRow(_ cells: [String], isHeader: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                inline(cell)
                    .font(isHeader ? .subheadline.weight(.semibold) : .subheadline)
                    .frame(minWidth: 96, maxWidth: 240, alignment: .leading)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                    .overlay(alignment: .trailing) {
                        Rectangle().fill(.quaternary).frame(width: 1)
                    }
            }
        }
        .background(isHeader ? Color.secondary.opacity(0.12) : Color.clear)
        .overlay(alignment: .bottom) {
            Rectangle().fill(.quaternary).frame(height: 1)
        }
    }

    private func inline(_ source: String) -> Text {
        if let value = try? AttributedString(markdown: source) { return Text(value) }
        return Text(source)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .largeTitle.weight(.bold)
        case 2: .title2.weight(.bold)
        case 3: .title3.weight(.semibold)
        case 4: .headline
        default: .subheadline.weight(.semibold)
        }
    }
}

private enum NativeMarkdownBlock {
    case heading(Int, String)
    case paragraph(String)
    case list(ordered: Bool, items: [String])
    case code(language: String, source: String)
    case table(header: [String], rows: [[String]])
}

private enum NativeMarkdownParser {
    static func parse(_ markdown: String) -> [NativeMarkdownBlock] {
        let lines = markdown.components(separatedBy: .newlines)
        var result: [NativeMarkdownBlock] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { index += 1; continue }

            if let fence = fencePrefix(in: trimmed) {
                index += 1
                var code: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    if candidate.hasPrefix(fence.marker) { index += 1; break }
                    code.append(lines[index])
                    index += 1
                }
                result.append(.code(language: fence.language, source: code.joined(separator: "\n")))
                continue
            }

            if let heading = heading(in: trimmed) {
                result.append(.heading(heading.level, heading.text))
                index += 1
                continue
            }

            if index + 1 < lines.count,
               line.contains("|"),
               let separator = tableSeparator(lines[index + 1]) {
                let header = tableCells(line)
                index += 2
                var rows: [[String]] = []
                while index < lines.count, lines[index].contains("|"), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(padded(tableCells(lines[index]), to: header.count))
                    index += 1
                }
                _ = separator // Alignment markers are syntactically validated; cells use native leading alignment.
                result.append(.table(header: header, rows: rows))
                continue
            }

            if let first = listItem(in: line) {
                var items = [first.text]
                index += 1
                while index < lines.count, let next = listItem(in: lines[index]), next.ordered == first.ordered {
                    items.append(next.text)
                    index += 1
                }
                result.append(.list(ordered: first.ordered, items: items))
                continue
            }

            var paragraph = [line.trimmingCharacters(in: .whitespaces)]
            index += 1
            while index < lines.count {
                let next = lines[index]
                let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
                if nextTrimmed.isEmpty || startsBlock(nextTrimmed, line: next, nextLine: lines[safe: index + 1]) { break }
                paragraph.append(nextTrimmed)
                index += 1
            }
            result.append(.paragraph(paragraph.joined(separator: " ")))
        }
        return result
    }

    private static func startsBlock(_ trimmed: String, line: String, nextLine: String?) -> Bool {
        fencePrefix(in: trimmed) != nil || heading(in: trimmed) != nil || listItem(in: line) != nil
            || (line.contains("|") && nextLine.map { tableSeparator($0) != nil } == true)
    }

    private static func heading(in line: String) -> (level: Int, text: String)? {
        let count = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(count), line.dropFirst(count).first?.isWhitespace == true else { return nil }
        let text = line.dropFirst(count).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (count, text)
    }

    private static func fencePrefix(in line: String) -> (marker: String, language: String)? {
        let marker = line.hasPrefix("```") ? "```" : (line.hasPrefix("~~~") ? "~~~" : nil)
        guard let marker else { return nil }
        let language = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
        return (marker, language)
    }

    private static func listItem(in line: String) -> (ordered: Bool, text: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if let first = trimmed.first, ["-", "*", "+"].contains(first),
           trimmed.dropFirst().first?.isWhitespace == true {
            return (false, trimmed.dropFirst().trimmingCharacters(in: .whitespaces))
        }
        let digits = trimmed.prefix(while: { $0.isNumber })
        guard !digits.isEmpty, let marker = trimmed.dropFirst(digits.count).first,
              marker == "." || marker == ")",
              trimmed.dropFirst(digits.count + 1).first?.isWhitespace == true else { return nil }
        return (true, trimmed.dropFirst(digits.count + 1).trimmingCharacters(in: .whitespaces))
    }

    private static func tableSeparator(_ line: String) -> [String]? {
        let cells = tableCells(line)
        guard !cells.isEmpty, cells.allSatisfy({ cell in
            let value = cell.trimmingCharacters(in: .whitespaces)
            return value.contains("-") && value.allSatisfy { $0 == "-" || $0 == ":" }
        }) else { return nil }
        return cells
    }

    private static func tableCells(_ line: String) -> [String] {
        var cells = line.split(separator: "|", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        if line.trimmingCharacters(in: .whitespaces).hasPrefix("|"), !cells.isEmpty { cells.removeFirst() }
        if line.trimmingCharacters(in: .whitespaces).hasSuffix("|"), !cells.isEmpty { cells.removeLast() }
        return cells
    }

    private static func padded(_ cells: [String], to count: Int) -> [String] {
        Array(cells.prefix(count)) + Array(repeating: "", count: max(0, count - cells.count))
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
