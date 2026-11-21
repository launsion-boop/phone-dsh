// SPDX-License-Identifier: MIT

import Foundation

/// Token-level Python 3 lexer for the device app static check (device-app.md §9). It produces the
/// stream the rules need (NAME, NUMBER, STRING, OP, NEWLINE, INDENT, DEDENT) and stops at the first
/// lexical error. It does not parse; it is conservative: where Python's own tokenizers differ or the
/// grammar is ambiguous it reports `lex` rather than guessing.
struct DeviceAppToken {
    enum Kind { case name, number, string, op, newline, indent, dedent }
    let kind: Kind
    let text: String
    let line: Int
    /// STRING only: the prefix contains `f`/`F`.
    var isFString = false
}

struct DeviceAppLexResult {
    var tokens: [DeviceAppToken] = []
    /// Line of the first lexical error; the tokens before it are still returned.
    var errorLine: Int?
}

enum DeviceAppPythonLexer {
    private static let stringPrefixes: Set<String> = ["r", "u", "b", "br", "rb", "f", "fr", "rf"]
    private static let operators: [String] = [
        "**=", "//=", ">>=", "<<=", "...",
        "->", ":=", "!=", "==", "<=", ">=", "+=", "-=", "*=", "/=", "%=", "@=", "&=", "|=", "^=", "**", "//", "<<", ">>", "<>",
        "+", "-", "*", "/", "%", "@", "&", "|", "^", "~", "<", ">", "(", ")", "[", "]", "{", "}", ",", ":", ".", ";", "=",
    ]
    private static let operatorScalars: [[Unicode.Scalar]] = operators.map { Array($0.unicodeScalars) }

    static func tokenize(_ source: String) -> DeviceAppLexResult {
        var lexer = Lexer(chars: Array(source.unicodeScalars))
        lexer.run()
        return lexer.result
    }

    private struct Lexer {
        let chars: [Unicode.Scalar]
        var pos = 0
        var line = 1
        var result = DeviceAppLexResult()
        var indents = [0]
        var altIndents = [0]
        var brackets: [(char: Unicode.Scalar, line: Int)] = []
        var lineHasTokens = false

        init(chars: [Unicode.Scalar]) { self.chars = chars }

        func peek(_ offset: Int = 0) -> Unicode.Scalar? {
            pos + offset < chars.count ? chars[pos + offset] : nil
        }

        mutating func fail(_ errorLine: Int) { result.errorLine = errorLine }

        mutating func emit(_ kind: DeviceAppToken.Kind, _ text: String, line: Int, isFString: Bool = false) {
            result.tokens.append(DeviceAppToken(kind: kind, text: text, line: line, isFString: isFString))
        }

        /// Consumes `\n` or `\r\n`; false when the next scalar is not a line end.
        mutating func consumeNewline() -> Bool {
            if peek() == "\n" { pos += 1; return true }
            if peek() == "\r", peek(1) == "\n" { pos += 2; return true }
            return false
        }

        mutating func run() {
            var atLineStart = true
            while true {
                if atLineStart && brackets.isEmpty {
                    var col = 0, alt = 0
                    while let c = peek() {
                        if c == " " { col += 1; alt += 1 }
                        else if c == "\t" { col = (col / 8 + 1) * 8; alt += 1 }
                        else if c == "\u{0C}" { col = 0; alt = 0 }
                        else { break }
                        pos += 1
                    }
                    guard let c = peek() else { break }
                    if c == "#" {
                        while let d = peek(), d != "\n", !(d == "\r" && peek(1) == "\n") { pos += 1 }
                        if consumeNewline() { line += 1; continue }
                        break
                    }
                    if consumeNewline() { line += 1; continue }
                    if !adjustIndentation(col: col, alt: alt) { return }
                    atLineStart = false
                    lineHasTokens = false
                }
                guard let c = peek() else { break }
                if c == " " || c == "\t" || c == "\u{0C}" { pos += 1; continue }
                if c == "#" {
                    while let d = peek(), d != "\n", !(d == "\r" && peek(1) == "\n") { pos += 1 }
                    continue
                }
                if consumeNewline() {
                    if brackets.isEmpty {
                        if lineHasTokens { emit(.newline, "\n", line: line) }
                        atLineStart = true
                        lineHasTokens = false
                    }
                    line += 1
                    continue
                }
                if c == "\r" { return fail(line) }
                if c == "\\" {
                    pos += 1
                    guard consumeNewline() else { return fail(line) }
                    line += 1
                    continue
                }
                lineHasTokens = true
                if !lexToken(c) { return }
            }
            // End of input.
            if let open = brackets.last { return fail(open.line) }
            if lineHasTokens && !atLineStart { emit(.newline, "", line: line) }
            for _ in indents.dropFirst() { emit(.dedent, "", line: line) }
        }

        mutating func adjustIndentation(col: Int, alt: Int) -> Bool {
            if col == indents.last! {
                if alt != altIndents.last! { fail(line); return false }
            } else if col > indents.last! {
                if alt <= altIndents.last! { fail(line); return false }
                indents.append(col); altIndents.append(alt)
                emit(.indent, "", line: line)
            } else {
                while col < indents.last! {
                    indents.removeLast(); altIndents.removeLast()
                    emit(.dedent, "", line: line)
                }
                if col != indents.last! || alt != altIndents.last! { fail(line); return false }
            }
            return true
        }

        static func isIdentifierStart(_ c: Unicode.Scalar) -> Bool {
            if c.isASCII { return (c.value >= 0x41 && c.value <= 0x5A) || (c.value >= 0x61 && c.value <= 0x7A) || c == "_" }
            return c.properties.isXIDStart
        }

        static func isIdentifierPart(_ c: Unicode.Scalar) -> Bool {
            if c.isASCII { return isIdentifierStart(c) || (c.value >= 0x30 && c.value <= 0x39) }
            return c.properties.isXIDContinue
        }

        static func isDigit(_ c: Unicode.Scalar?) -> Bool { c.map { $0.value >= 0x30 && $0.value <= 0x39 } ?? false }

        mutating func lexToken(_ c: Unicode.Scalar) -> Bool {
            let startLine = line
            if Self.isDigit(c) || (c == "." && Self.isDigit(peek(1))) {
                let start = pos
                lexNumber()
                emit(.number, String(String.UnicodeScalarView(chars[start..<pos])), line: startLine)
                return true
            }
            if Self.isIdentifierStart(c) {
                let start = pos
                while let d = peek(), Self.isIdentifierPart(d) { pos += 1 }
                let word = String(String.UnicodeScalarView(chars[start..<pos]))
                if let q = peek(), q == "'" || q == "\"", word.unicodeScalars.allSatisfy({ $0.isASCII }),
                   DeviceAppPythonLexer.stringPrefixes.contains(word.lowercased()) {
                    return lexString(prefix: word, start: start, startLine: startLine)
                }
                emit(.name, word, line: startLine)
                return true
            }
            if c == "'" || c == "\"" {
                return lexString(prefix: "", start: pos, startLine: startLine)
            }
            for (index, op) in DeviceAppPythonLexer.operatorScalars.enumerated() where matches(op) {
                let text = DeviceAppPythonLexer.operators[index]
                pos += op.count
                if text == "(" || text == "[" || text == "{" {
                    brackets.append((op[0], startLine))
                } else if text == ")" || text == "]" || text == "}" {
                    let open: Unicode.Scalar = text == ")" ? "(" : (text == "]" ? "[" : "{")
                    guard let top = brackets.last, top.char == open else { fail(startLine); return false }
                    brackets.removeLast()
                }
                emit(.op, text, line: startLine)
                return true
            }
            fail(startLine)
            return false
        }

        func matches(_ op: [Unicode.Scalar]) -> Bool {
            for (i, s) in op.enumerated() where peek(i) != s { return false }
            return true
        }

        mutating func lexNumber() {
            func digitsOrUnderscore(_ allowed: (Unicode.Scalar) -> Bool, _ self_: inout Lexer) {
                while let d = self_.peek(), allowed(d) || d == "_" { self_.pos += 1 }
            }
            if peek() == "0", let p = peek(1), "xXoObB".unicodeScalars.contains(p) {
                pos += 2
                let hex = p == "x" || p == "X"
                digitsOrUnderscore({ d in
                    Self.isDigit(d) || (hex && ((d.value >= 0x41 && d.value <= 0x46) || (d.value >= 0x61 && d.value <= 0x66)))
                }, &self)
                return
            }
            digitsOrUnderscore({ Self.isDigit($0) }, &self)
            if peek() == "." {
                pos += 1
                digitsOrUnderscore({ Self.isDigit($0) }, &self)
            }
            if let e = peek(), e == "e" || e == "E" {
                var look = 1
                if let s = peek(look), s == "+" || s == "-" { look += 1 }
                if Self.isDigit(peek(look)) {
                    pos += look
                    digitsOrUnderscore({ Self.isDigit($0) }, &self)
                }
            }
            if let j = peek(), j == "j" || j == "J" { pos += 1 }
        }

        mutating func lexString(prefix: String, start: Int, startLine: Int) -> Bool {
            let quote = peek()!
            let isF = prefix.lowercased().contains("f")
            let triple = peek(1) == quote && peek(2) == quote
            pos += triple ? 3 : 1
            while true {
                guard let c = peek() else { fail(startLine); return false }
                if c == "\\" {
                    pos += 1
                    guard peek() != nil else { fail(startLine); return false }
                    if consumeNewline() { line += 1 } else { pos += 1 }
                    continue
                }
                if c == quote {
                    if !triple { pos += 1; break }
                    if peek(1) == quote && peek(2) == quote { pos += 3; break }
                    pos += 1
                    continue
                }
                if c == "\n" || (c == "\r" && peek(1) == "\n") {
                    if !triple { fail(startLine); return false }
                    _ = consumeNewline()
                    line += 1
                    continue
                }
                pos += 1
            }
            emit(.string, String(String.UnicodeScalarView(chars[start..<pos])), line: startLine, isFString: isF)
            return true
        }
    }
}
