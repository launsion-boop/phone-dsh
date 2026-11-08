// SPDX-License-Identifier: MIT

import Foundation

struct BotMemoryTokenAnalysis {
    var counts: [String: Double] = [:]
    var order: [String] = []

    mutating func add(_ term: String, weight: Double = 1) {
        if counts[term] == nil {
            order.append(term)
        }
        counts[term, default: 0] += weight
    }

    mutating func setQueryTerm(_ term: String, weight: Double) {
        if counts[term] == nil {
            order.append(term)
        }
        counts[term] = weight
    }
}

struct BotMemoryQueryAnalysis {
    let normalizedQuery: String
    let tokens: BotMemoryTokenAnalysis
    let cjkCharacters: Int
    let latinWords: Int
}

enum BotMemoryTokenizer {
    private struct Run {
        enum Kind {
            case cjk
            case latin
        }

        let kind: Kind
        var text: String
    }

    static func normalize(_ value: String) -> String {
        value.precomposedStringWithCompatibilityMapping.lowercased()
    }

    private static func isCJK(_ scalar: UnicodeScalar) -> Bool {
        let value = scalar.value
        return (0x3400...0x4DBF).contains(value)
            || (0x4E00...0x9FFF).contains(value)
            || (0xF900...0xFAFF).contains(value)
            || (0x3040...0x30FF).contains(value)
            || (0xAC00...0xD7AF).contains(value)
    }

    private static func isLatinOrDigit(_ scalar: UnicodeScalar) -> Bool {
        ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar)
    }

    private static func isLatinExtender(_ scalar: UnicodeScalar) -> Bool {
        scalar == "-" || scalar == "_" || scalar == "'"
    }

    private static func runs(_ value: String) -> [Run] {
        var result: [Run] = []
        var current: Run?
        func flush() {
            if let current, !current.text.isEmpty {
                result.append(current)
            }
            current = nil
        }
        for scalar in normalize(value).unicodeScalars {
            let kind: Run.Kind?
            if isCJK(scalar) {
                kind = .cjk
            } else if isLatinOrDigit(scalar) {
                kind = .latin
            } else {
                kind = nil
            }
            guard let kind else {
                if current?.kind == .latin, isLatinExtender(scalar) {
                    current?.text.append(contentsOf: String(scalar))
                } else {
                    flush()
                }
                continue
            }
            if current?.kind != kind {
                flush()
                current = Run(kind: kind, text: "")
            }
            current?.text.append(contentsOf: String(scalar))
        }
        flush()
        return result
    }

    static func analyzeText(_ value: String) -> BotMemoryTokenAnalysis {
        var analysis = BotMemoryTokenAnalysis()
        for run in runs(value) {
            switch run.kind {
            case .latin:
                analysis.add("w:\(run.text)")
                if run.text.contains(where: { $0 == "-" || $0 == "_" || $0 == "'" }) {
                    let parts = run.text.components(separatedBy: CharacterSet(charactersIn: "-_'"))
                    for part in parts where !part.isEmpty {
                        analysis.add("w:\(part)")
                    }
                }
            case .cjk:
                let characters = run.text.unicodeScalars.map(String.init)
                for character in characters {
                    analysis.add("u:\(character)")
                }
                if characters.count >= 2 {
                    for index in 0...(characters.count - 2) {
                        analysis.add("b:\(characters[index])\(characters[index + 1])")
                    }
                }
                if characters.count >= 3 {
                    for index in 0...(characters.count - 3) {
                        analysis.add("t:\(characters[index])\(characters[index + 1])\(characters[index + 2])")
                    }
                }
            }
        }
        return analysis
    }

    static func analyzeQuery(_ value: String) -> BotMemoryQueryAnalysis {
        let normalizedQuery = normalize(value).trimmingCharacters(in: .whitespacesAndNewlines)
        var analysis = BotMemoryTokenAnalysis()
        var cjkCharacters = 0
        var latinWords = 0
        for run in runs(value) {
            switch run.kind {
            case .latin:
                latinWords += 1
                analysis.setQueryTerm("w:\(run.text)", weight: 1)
            case .cjk:
                let characters = run.text.unicodeScalars.map(String.init)
                cjkCharacters += characters.count
                if characters.count == 1 {
                    analysis.setQueryTerm("u:\(characters[0])", weight: 1)
                } else if characters.count == 2 {
                    analysis.setQueryTerm("b:\(characters[0])\(characters[1])", weight: 1)
                } else {
                    for index in 0...(characters.count - 2) {
                        analysis.setQueryTerm("b:\(characters[index])\(characters[index + 1])", weight: 1)
                    }
                    for index in 0...(characters.count - 3) {
                        analysis.setQueryTerm(
                            "t:\(characters[index])\(characters[index + 1])\(characters[index + 2])",
                            weight: 1.3
                        )
                    }
                }
            }
        }
        return BotMemoryQueryAnalysis(
            normalizedQuery: normalizedQuery,
            tokens: analysis,
            cjkCharacters: cjkCharacters,
            latinWords: latinWords
        )
    }
}
