// SPDX-License-Identifier: MIT

import Foundation

/// Local-only observability for the "prose list instead of a card" regression.
///
/// The denominator is deliberately a conservative heuristic: a turn counts as
/// having options only when its final assistant text ends in a 2-4 item
/// numbered/bulleted list. That is good enough to notice a long-term drop, but
/// it is not used to render UI or to authorize anything. No content or counts
/// leave the device.
enum BotNextStepsMetrics {
    struct Snapshot: Equatable {
        let turnsWithOptions: Int
        let turnsWithStepsCard: Int
        var usageRate: Double {
            guard turnsWithOptions > 0 else { return 0 }
            return Double(turnsWithStepsCard) / Double(turnsWithOptions)
        }
    }

    private static let key = "dev.phone-dsh.bot.next-steps-usage.v1"

    static func recordTurn(rows: [BotUIRow]) {
        guard let lastUser = rows.lastIndex(where: { $0.role == "user" }) else { return }
        let turnRows = rows[(lastUser + 1)...]
        guard let finalText = turnRows.last(where: {
            $0.role == "assistant" && $0.body.type == "text"
        })?.body["text"]?.string else { return }
        let hasOptions = endsWithOptionList(finalText)
        // "Usage rate" is measured only over eligible turns: a card on a turn
        // with no prose options is not a denominator escape hatch.
        guard hasOptions else { return }
        let hasCard = turnRows.contains { $0.body.cardType == "steps" }
        var counts = load()
        counts["turns_with_options", default: 0] += 1
        if hasCard { counts["turns_with_next_steps", default: 0] += 1 }
        write(counts)
    }

    static func snapshot() -> Snapshot {
        let counts = load()
        return Snapshot(turnsWithOptions: counts["turns_with_options"] ?? 0,
                        turnsWithStepsCard: counts["turns_with_next_steps"] ?? 0)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    /// True only for a trailing 2-4 item list. Code blocks, tables and ordinary
    /// numbered instructions in the middle of a reply do not count.
    static func endsWithOptionList(_ text: String) -> Bool {
        var trailing = 0
        var sawContentBefore = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false).reversed() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if isListLine(line) {
                trailing += 1
                if trailing > 4 { return false }
                continue
            }
            sawContentBefore = true
            break
        }
        return sawContentBefore && (2...4).contains(trailing)
    }

    private static func isListLine(_ line: String) -> Bool {
        let body: Substring
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
            body = line.dropFirst(2)
        } else {
            let digits = line.prefix(2)
            guard digits.first?.isNumber == true, line.count > digits.count else { return false }
            let rest = line.dropFirst(digits.count)
            guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return false }
            body = rest.dropFirst(2)
        }
        return body.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
    }

    private static func load() -> [String: Int] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: Int] ?? [:]
    }

    private static func write(_ counts: [String: Int]) {
        UserDefaults.standard.set(counts, forKey: key)
    }
}
