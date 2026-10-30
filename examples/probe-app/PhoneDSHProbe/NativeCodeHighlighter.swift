// SPDX-License-Identifier: MIT

import SwiftUI

// Small native token highlighter; unknown grammars remain plain source.
enum NativeCodeHighlighter {
    private static let keywords: Set<String> = [
        "actor", "as", "async", "await", "break", "case", "catch", "class", "const", "continue",
        "def", "default", "defer", "do", "else", "enum", "export", "extends", "false", "final",
        "finally", "for", "from", "func", "function", "guard", "if", "implements", "import", "in",
        "init", "interface", "internal", "is", "let", "namespace", "new", "nil", "nonisolated",
        "null", "open", "operator", "override", "package", "private", "protocol", "public", "raise",
        "return", "self", "static", "struct", "super", "switch", "this", "throw", "throws", "true",
        "try", "typealias", "typeof", "using", "var", "void", "where", "while", "yield",
    ]

    static func attributed(_ source: String, language: String) -> AttributedString {
        var result = AttributedString(source)
        result.font = .system(size: 13, design: .monospaced)
        result.foregroundColor = NativeChatTheme.secondary
        let full = NSRange(source.startIndex..<source.endIndex, in: source)
        apply(pattern: #""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'"#, color: NativeChatTheme.success, to: &result, in: source, range: full)
        apply(pattern: #"//[^\n]*|/\*[\s\S]*?\*/|#[^\n]*"#, color: NativeChatTheme.caption, to: &result, in: source, range: full)
        apply(pattern: #"\b(?:0x[0-9a-fA-F]+|\d+(?:\.\d+)?)\b"#, color: NativeChatTheme.warning, to: &result, in: source, range: full)
        apply(pattern: #"\b[A-Za-z_][A-Za-z0-9_]*\b"#, to: &result, in: source, range: full) { word in
            keywords.contains(word.lowercased()) ? NativeChatTheme.accent : nil
        }
        return result
    }

    private static func apply(pattern: String, color: Color? = nil,
                              to result: inout AttributedString, in source: String, range: NSRange,
                              selector: ((String) -> Color?)? = nil) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        for match in regex.matches(in: source, range: range) {
            guard let swiftRange = Range(match.range, in: source),
                  let attributedRange = Range<AttributedString.Index>(swiftRange, in: result) else { continue }
            let word = String(source[swiftRange])
            if let selected = selector?(word) ?? color {
                result[attributedRange].foregroundColor = selected
            }
        }
    }
}
