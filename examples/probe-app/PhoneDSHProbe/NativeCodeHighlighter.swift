// SPDX-License-Identifier: MIT

import ProbeKit
import SwiftUI

// Small native token highlighter; unknown grammars remain plain source.
enum NativeCodeHighlighter {
    /// Cached tokens are resolved colors, so the theme is part of the key.
    /// The palette's colors are dynamic; bump this when the token roles change.
    static let themeKey = "native-v1"
    static let countLimit = 256
    static let totalCostLimit = 16 * 1024 * 1024

    private static let keywords: Set<String> = [
        "actor", "as", "async", "await", "break", "case", "catch", "class", "const", "continue",
        "def", "default", "defer", "do", "else", "enum", "export", "extends", "false", "final",
        "finally", "for", "from", "func", "function", "guard", "if", "implements", "import", "in",
        "init", "interface", "internal", "is", "let", "namespace", "new", "nil", "nonisolated",
        "null", "open", "operator", "override", "package", "private", "protocol", "public", "raise",
        "return", "self", "static", "struct", "super", "switch", "this", "throw", "throws", "true",
        "try", "typealias", "typeof", "using", "var", "void", "where", "while", "yield",
    ]

    private static let stringRegex = try! NSRegularExpression(
        pattern: #""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'"#)
    private static let commentRegex = try! NSRegularExpression(
        pattern: #"//[^\n]*|/\*[\s\S]*?\*/|#[^\n]*"#)
    private static let numberRegex = try! NSRegularExpression(
        pattern: #"\b(?:0x[0-9a-fA-F]+|\d+(?:\.\d+)?)\b"#)
    private static let wordRegex = try! NSRegularExpression(
        pattern: #"\b[A-Za-z_][A-Za-z0-9_]*\b"#)

    static let cache = NativeBoundedCache<String, AttributedString>(
        name: "NativeCodeHighlighter",
        countLimit: countLimit,
        totalCostLimit: totalCostLimit)

    /// Number of token passes actually performed (cache misses). Tests use it
    /// to prove repeated renders of the same block do not recompute.
    private(set) static var computeCount = 0

    static func attributed(_ source: String, language: String) -> AttributedString {
        let key = "\(NativeStableHash.fnv1a64(source)):\(language.lowercased()):\(themeKey)"
        if let cached = cache.value(forKey: key) {
            return cached
        }
        computeCount += 1
        var result = AttributedString(source)
        result.font = .system(size: 13, design: .monospaced)
        result.foregroundColor = NativeChatTheme.secondary
        let full = NSRange(source.startIndex..<source.endIndex, in: source)
        apply(regex: stringRegex, color: NativeChatTheme.success, to: &result, in: source, range: full)
        apply(regex: commentRegex, color: NativeChatTheme.caption, to: &result, in: source, range: full)
        apply(regex: numberRegex, color: NativeChatTheme.warning, to: &result, in: source, range: full)
        apply(regex: wordRegex, to: &result, in: source, range: full) { word in
            keywords.contains(word.lowercased()) ? NativeChatTheme.accent : nil
        }
        cache.insert(result, forKey: key, cost: source.utf8.count * 2 + 256)
        return result
    }

    static func resetForTesting() {
        cache.removeAll()
        computeCount = 0
    }

    private static func apply(regex: NSRegularExpression, color: Color? = nil,
                              to result: inout AttributedString, in source: String, range: NSRange,
                              selector: ((String) -> Color?)? = nil) {
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
