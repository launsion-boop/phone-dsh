// SPDX-License-Identifier: MIT

import Foundation

/// First violation of the static check (device-app.md §9). `line` is 0 for `size` and `exit_path`.
public struct DeviceAppCheckFailure: Equatable, Sendable, Error {
    public enum Code: String, Sendable, CaseIterable {
        case size, lex, fstring, `import`, name, underscore, perm, except, exit_path
    }

    public let code: Code
    public let path: String
    public let line: Int

    public init(code: Code, path: String, line: Int) {
        self.code = code; self.path = path; self.line = line
    }
}

/// Token-level static check of a device app (device-app.md §9). Conservative: it can reject a
/// harmless program and never accepts what the rules list. It does not prove the program valid.
public enum DeviceAppValidator {
    private static let baseModules: Set<String> = [
        "time", "math", "random", "json", "gc", "struct", "array", "micropython", "lcd", "keys", "ui", "audio", "battery",
    ]
    private static let forbiddenNames: Set<String> = [
        "exec", "eval", "compile", "execfile", "open", "__import__", "getattr", "setattr", "delattr", "globals",
        "locals", "vars", "dir", "breakpoint", "input", "__builtins__", "machine", "os", "sys", "socket",
        "network", "bluetooth", "_thread", "esp32", "_passport", "apprt", "settings",
    ]
    private static let micNames: Set<String> = ["record_wav", "readinto", "mic_gain"]

    private struct Hit {
        let path: String
        let line: Int
        let rule: Int
        let code: DeviceAppCheckFailure.Code
    }

    /// Returns nil when the program passes, else the first violation: `size` (line 0) first, then
    /// token violations ordered by path, line and rule number, `exit_path` only when nothing else failed.
    public static func check(files: [String: String], perms: [String]) -> DeviceAppCheckFailure? {
        let paths = files.keys.sorted { Array($0.unicodeScalars.map(\.value)).lexicographicallyPrecedes($1.unicodeScalars.map(\.value)) }
        for path in paths {
            let text = files[path]!
            if text.utf8.count > DeviceAppRules.fileMaxBytes || text.unicodeScalars.contains("\u{0}") {
                return DeviceAppCheckFailure(code: .size, path: path, line: 0)
            }
        }
        let siblings = Set(paths.filter { $0.hasSuffix(".py") && !$0.contains("/") }.map { String($0.dropLast(3)) })
        let allowed = baseModules.union(siblings)
        let granted = Set(perms)
        var hits: [Hit] = []
        var exitPath = false
        for path in paths where path.hasSuffix(".py") {
            let lexed = DeviceAppPythonLexer.tokenize(files[path]!)
            if let line = lexed.errorLine { hits.append(Hit(path: path, line: line, rule: 1, code: .lex)) }
            if scan(lexed.tokens, path: path, allowed: allowed, perms: granted, hits: &hits) { exitPath = true }
        }
        if let first = hits.min(by: { ($0.path, $0.line, $0.rule) < ($1.path, $1.line, $1.rule) }) {
            return DeviceAppCheckFailure(code: first.code, path: first.path, line: first.line)
        }
        return exitPath ? nil : DeviceAppCheckFailure(code: .exit_path, path: "main.py", line: 0)
    }

    /// Identifiers compare after NFKC, as CPython normalises them; `ｅxec` must not slip through.
    private static func normalized(_ s: String) -> String {
        s.unicodeScalars.allSatisfy(\.isASCII) ? s : s.precomposedStringWithCompatibilityMapping
    }

    /// Applies rules 2-8 to one file's tokens; returns whether the file has a `keys.get/pressed` use.
    private static func scan(_ toks: [DeviceAppToken], path: String, allowed: Set<String>, perms: Set<String>, hits: inout [Hit]) -> Bool {
        func add(_ line: Int, _ rule: Int, _ code: DeviceAppCheckFailure.Code) {
            hits.append(Hit(path: path, line: line, rule: rule, code: code))
        }
        func isOp(_ i: Int, _ s: String) -> Bool { i < toks.count && toks[i].kind == .op && toks[i].text == s }
        func isName(_ i: Int, _ s: String? = nil) -> Bool {
            i < toks.count && toks[i].kind == .name && (s == nil || normalized(toks[i].text) == s)
        }
        func isSeparator(_ i: Int) -> Bool {
            toks[i].kind == .newline || toks[i].kind == .indent || toks[i].kind == .dedent
        }
        let n = toks.count
        var exitPath = false
        var prevStart = true
        var i = 0
        while i < n {
            let t = toks[i]
            if t.kind == .string && t.isFString { add(t.line, 2, .fstring) }
            if t.kind == .name {
                let s = normalized(t.text)
                if prevStart && (s == "import" || s == "from") {
                    var j = i + 1
                    if s == "from" {
                        if isOp(j, ".") || isOp(j, "...") {
                            add(t.line, 3, .import)
                        } else if j < n, toks[j].kind == .name, !allowed.contains(normalized(toks[j].text)) {
                            add(t.line, 3, .import)
                        }
                        while j < n, !isName(j, "import"), !isSeparator(j) { j += 1 }
                        if isOp(j + 1, "*") { add(t.line, 3, .import) }
                    } else {
                        while j < n {
                            guard toks[j].kind == .name else { break }
                            if !allowed.contains(normalized(toks[j].text)) { add(toks[j].line, 3, .import) }
                            j += 1
                            while j + 1 < n, isOp(j, "."), toks[j + 1].kind == .name { j += 2 }
                            if j + 1 < n, isName(j, "as") { j += 2 }
                            if isOp(j, ",") { j += 1; continue }
                            break
                        }
                    }
                }
                if forbiddenNames.contains(s) { add(t.line, 4, .name) }
                if s.hasPrefix("__"), s.hasSuffix("__"), s.unicodeScalars.count > 4, s != "__name__", s != "__init__" { add(t.line, 5, .underscore) }
                if i > 0, isOp(i - 1, "."), s.hasPrefix("_") { add(t.line, 5, .underscore) }
                if s == "audio", !perms.contains("audio") { add(t.line, 6, .perm) }
                if s == "battery", !perms.contains("battery") { add(t.line, 6, .perm) }
                if micNames.contains(s), !perms.contains("mic") { add(t.line, 6, .perm) }
                if s == "except" {
                    var j = i + 1
                    var depth = 0
                    var bad = isOp(j, ":")
                    while j < n, !isSeparator(j) {
                        let tj = toks[j]
                        if tj.kind == .op, ["(", "[", "{"].contains(tj.text) { depth += 1 }
                        else if tj.kind == .op, [")", "]", "}"].contains(tj.text) { depth -= 1 }
                        else if tj.kind == .op, tj.text == ":", depth == 0 { break }
                        else if tj.kind == .name {
                            let name = normalized(tj.text)
                            if name == "BaseException" || name == "KeyboardInterrupt" { bad = true }
                        }
                        j += 1
                    }
                    if bad { add(t.line, 7, .except) }
                }
                if s == "keys", isOp(i + 1, "."), i + 2 < n, toks[i + 2].kind == .name,
                   ["get", "pressed"].contains(normalized(toks[i + 2].text)) {
                    exitPath = true
                }
            }
            prevStart = isSeparator(i) || (t.kind == .op && (t.text == ";" || t.text == ":"))
            i += 1
        }
        return exitPath
    }
}
