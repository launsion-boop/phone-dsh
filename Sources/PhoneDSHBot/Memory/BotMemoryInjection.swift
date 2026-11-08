// SPDX-License-Identifier: MIT

import Foundation

public struct BotMemoryLimits: Codable, Sendable, Equatable {
    public let profile: Int
    public let notes: Int
    public let log: Int
    public let total: Int

    public init(profile: Int, notes: Int, log: Int, total: Int) {
        self.profile = profile
        self.notes = notes
        self.log = log
        self.total = total
    }

    public static let standard = BotMemoryLimits(profile: 2_000, notes: 1_000, log: 1_500, total: 4_000)
}

public struct BotMemoryInjection: Codable, Sendable, Equatable {
    public let text: String
    public let limits: BotMemoryLimits

    public init(text: String, limits: BotMemoryLimits = .standard) {
        self.text = text
        self.limits = limits
    }
}

public struct BotMemoryScopeInput: Sendable {
    public let scope: BotMemoryScope
    public let root: String
    public let facts: [BotMemoryFact]

    public init(scope: BotMemoryScope, root: String, facts: [BotMemoryFact]) {
        self.scope = scope
        self.root = root
        self.facts = facts
    }
}

public enum BotMemoryInjector {
    public static let inlineLogFactLimit = 12
    public static let minimumLogFacts = 3

    public static func render(
        scopes: [BotMemoryScopeInput],
        budget: Int = BotMemoryLimits.standard.total,
        language: BotMemoryPromptLanguage = .zh,
        now: Int64? = nil
    ) -> BotMemoryInjection {
        let nowMS = now ?? Int64(Date().timeIntervalSince1970 * 1_000)
        let header = memoryHeader(scopes, language)
        let logFloor = logSliceFloor(scopes, language, now: nowMS)
        var caps = Caps(
            profile: BotMemoryLimits.standard.profile,
            notes: BotMemoryLimits.standard.notes,
            log: max(BotMemoryLimits.standard.log, logFloor)
        )
        var text = header + renderMemoryBody(scopes, caps, language, now: nowMS)
        while BotMemoryText.utf16Count(text) > budget {
            if caps.log > logFloor {
                caps.log = max(logFloor, caps.log - 250)
            } else if caps.notes > 0 {
                caps.notes = max(0, caps.notes - 250)
            } else if caps.profile > 0 {
                caps.profile = max(0, caps.profile - 250)
            } else {
                break
            }
            text = header + renderMemoryBody(scopes, caps, language, now: nowMS)
        }
        if BotMemoryText.utf16Count(text) > budget {
            let cut = BotMemoryText.utf16Prefix(text, max(0, budget - 1))
            text = BotMemoryText.trimEnd(cut) + "…"
        }
        return BotMemoryInjection(text: text)
    }

    private struct Caps {
        var profile: Int
        var notes: Int
        var log: Int
    }

    private struct Texts {
        let heading: String
        let intro: String
        let split: String
        let lives: String
        let scopeShared: String
        let scopeThis: String
        let rootFormat: String
        let rootJoin: String
        let sentenceEnd: String
        let beforeRoots: String
        let sharedLine: String
        let singleLine: String
        let updateLine: String
        let bounded: String
        let empty: String
        let omitted: String
        let recentLogLabel: String
        let logTruncated: String
        let profileOmitted: String
        let profileMaintenance: String
        let agentLabel: String
        let userLabel: String
    }

    private static let en = Texts(
        heading: "## Memory",
        intro: "Durable facts you have learned about the user and their world. They persist across conversations; rely on them and do not re-ask.",
        split: "Memory is split into two stores:",
        lives: "Memory lives",
        scopeShared: "shared `user` scope",
        scopeThis: "this bot's scope",
        rootFormat: "%SCOPE% at `%ROOT%`",
        rootJoin: " and ",
        sentenceEnd: ".",
        beforeRoots: " ",
        sharedLine: "`scope: \"user\"` is shared by every one of the user's bots; the default `scope: \"agent\"` belongs to this bot alone. `RecallMemory` searches both scopes and labels every hit.",
        singleLine: "Call `RecallMemory` to search older facts; use `UpdateMemory` to change memory.",
        updateLine: "`UpdateMemory` action \"write\" records one fact with tier profile|log|note (default log) and scope agent|user; action \"forget\" removes every fact in that scope whose recorded text exactly matches (all matching entries). A correction is a forget of the exact old text plus a write of the new fact — there is no implicit replacement.",
        bounded: "This block is bounded (profile ≤ %PROFILE% chars per scope, notes ≤ %NOTES%, recent log ≤ %LOG_FACTS% newest facts or %LOG% chars, whichever is smaller; total ≤ %TOTAL%): older facts are not listed here — call RecallMemory to reach them. The profile keeps the newest entries that fit.",
        empty: "(empty)",
        omitted: "(omitted here — call RecallMemory to read this scope)",
        recentLogLabel: "**recent log (newest first)**",
        logTruncated: "(recent log truncated: showing the newest %SHOWN% of %TOTAL% entries; older log entries are not injected — call `RecallMemory` to search them.)",
        profileOmitted: "> %N% earlier entries are not listed; use RecallMemory to search them.",
        profileMaintenance: "> The profile is at 80% of its limit. Tidy it up: forget outdated or duplicate entries and merge/rewrite them if needed.",
        agentLabel: "This bot's memory",
        userLabel: "Shared user memory (scope \"user\")"
    )

    private static let zh = Texts(
        heading: "## 记忆",
        intro: "你了解到的关于用户及其世界的持久事实。它们会跨对话保留；依靠它们，不要重复询问。",
        split: "记忆分成两个存储：",
        lives: "记忆存放于",
        scopeShared: "共享的 `user` scope",
        scopeThis: "这个 Bot 的 scope",
        rootFormat: "%SCOPE%（`%ROOT%`）",
        rootJoin: "、",
        sentenceEnd: "。",
        beforeRoots: "",
        sharedLine: "`scope: \"user\"` 是所有 Bot 共享的；默认的 `scope: \"agent\"` 只属于这个 Bot。`RecallMemory` 会搜索两个 scope，并标注每一条的来源。",
        singleLine: "调用 `RecallMemory` 搜索较早的事实；用 `UpdateMemory` 修改记忆。",
        updateLine: "`UpdateMemory` 的 action \"write\" 记录一条事实，层级为 profile|log|note（默认 log），scope 为 agent|user；action \"forget\" 删除同一 scope 内文本完全匹配的所有事实（每一行完全相符的都算）。更正 = 忘掉精确旧文本 + 写入新事实——没有隐式替换。",
        bounded: "这个区块有长度上限（每个 scope 的 profile ≤ %PROFILE% 字符、notes ≤ %NOTES%、最近的 log ≤ %LOG_FACTS% 条 / %LOG% 字符，取较小者；总计 ≤ %TOTAL%）：较早的事实不会列在这里——调用 RecallMemory 取回。profile 会保留放得下的最新条目。",
        empty: "（空）",
        omitted: "（此处省略——调用 RecallMemory 读取这个 scope）",
        recentLogLabel: "**最近的 log（新到旧）**",
        logTruncated: "（最近的 log 已截断：只列出最新 %SHOWN% / %TOTAL% 条；较旧的 log 不会注入——调用 `RecallMemory` 搜索。）",
        profileOmitted: "> 較早的 %N% 條未列出，可用 RecallMemory 查詢。",
        profileMaintenance: "> profile 已達到上限的 80%；請整理：用 forget 刪除過時和重複的條目，必要時合併後重寫。",
        agentLabel: "这个 Bot 的记忆",
        userLabel: "共享的用户记忆（scope \"user\"）"
    )

    private static func texts(_ language: BotMemoryPromptLanguage) -> Texts {
        language == .en ? en : zh
    }

    private static func memoryHeader(
        _ scopes: [BotMemoryScopeInput],
        _ language: BotMemoryPromptLanguage
    ) -> String {
        let t = texts(language)
        let hasUser = scopes.contains { $0.scope == .user }
        let roots = scopes.map { input in
            t.rootFormat
                .replacingOccurrences(of: "%SCOPE%", with: input.scope == .user ? t.scopeShared : t.scopeThis)
                .replacingOccurrences(of: "%ROOT%", with: input.root)
        }.joined(separator: t.rootJoin)
        var lines = [
            t.heading,
            "",
            t.intro,
            "\(hasUser ? t.split : t.lives)\(t.beforeRoots)\(roots)\(t.sentenceEnd)",
            hasUser ? t.sharedLine : t.singleLine,
            t.updateLine,
            t.bounded
                .replacingOccurrences(of: "%PROFILE%", with: "2,000")
                .replacingOccurrences(of: "%NOTES%", with: "1,000")
                .replacingOccurrences(of: "%LOG_FACTS%", with: "12")
                .replacingOccurrences(of: "%LOG%", with: "1,500")
                .replacingOccurrences(of: "%TOTAL%", with: "4,000")
        ]
        lines.append("")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func sectionBody(
        _ body: String,
        cap: Int,
        _ language: BotMemoryPromptLanguage
    ) -> String {
        let t = texts(language)
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return t.empty }
        if cap == 0 { return t.omitted }
        return BotMemoryText.clip(text, cap)
    }

    private static func conditionSuffix(_ fact: BotMemoryFact) -> String {
        let applicable = BotMemoryNormalizer.normalizeConditionText(fact.applicableWhen)
        let notApplicable = BotMemoryNormalizer.normalizeConditionText(fact.notApplicableWhen)
        if applicable.isEmpty && notApplicable.isEmpty { return "" }
        var parts: [String] = []
        if !applicable.isEmpty { parts.append("適用：\(applicable)") }
        if !notApplicable.isEmpty { parts.append("不適用：\(notApplicable)") }
        return "（\(parts.joined(separator: "；"))）"
    }

    private static func activeFacts(
        _ input: BotMemoryScopeInput,
        tier: BotMemoryTier,
        now: Int64
    ) -> [BotMemoryFact] {
        input.facts.filter { $0.tier == tier && BotMemoryVisibility.isVisible($0, now: now) }
    }

    private static func chronological(_ facts: [BotMemoryFact]) -> [BotMemoryFact] {
        facts.enumerated().sorted { left, right in
            if left.element.learnedAtMS != right.element.learnedAtMS {
                return left.element.learnedAtMS < right.element.learnedAtMS
            }
            return left.offset < right.offset
        }.map(\.element)
    }

    private static func factViewLine(_ fact: BotMemoryFact, includeConditions: Bool) -> String {
        "- \(fact.text)\(includeConditions ? conditionSuffix(fact) : "")"
    }

    private static func fitNewestLines(_ lines: [String], budget: Int) -> (selected: [String], omitted: Int) {
        if lines.isEmpty { return ([], 0) }
        var selected: [String] = []
        var used = 0
        let cap = max(0, budget)
        for line in lines.reversed() {
            let cost = BotMemoryText.utf16Count(line) + (selected.isEmpty ? 0 : 1)
            if used + cost > cap {
                if selected.isEmpty && cap > 0 {
                    let clipped = BotMemoryText.clip(line, cap)
                    if !clipped.isEmpty { selected.insert(clipped, at: 0) }
                }
                break
            }
            selected.insert(line, at: 0)
            used += cost
        }
        return (selected, lines.count - selected.count)
    }

    private static func buildProfileBlock(
        _ facts: [BotMemoryFact],
        cap: Int,
        language: BotMemoryPromptLanguage
    ) -> String {
        let t = texts(language)
        let lines = chronological(facts).map { factViewLine($0, includeConditions: true) }
        let header = "# Profile"
        let base = "\(header)\n\n"
        let storedChars = BotMemoryText.utf16Count(base) + BotMemoryText.utf16Count(lines.joined(separator: "\n"))
        let showHint = storedChars >= Int(ceil(Double(BotMemoryLimits.standard.profile) * 0.8))
        let hint = showHint ? t.profileMaintenance : ""
        var selected: [String] = []
        var omitted = 0
        for _ in 0..<4 {
            let omittedLine = omitted > 0 ? t.profileOmitted.replacingOccurrences(of: "%N%", with: String(omitted)) : ""
            let reserve = (hint.isEmpty ? 0 : BotMemoryText.utf16Count(hint) + 1)
                + (omittedLine.isEmpty ? 0 : BotMemoryText.utf16Count(omittedLine) + 1)
            let fitted = fitNewestLines(lines, budget: cap - BotMemoryText.utf16Count(base) - reserve)
            selected = fitted.selected
            if fitted.omitted == omitted { break }
            omitted = fitted.omitted
        }
        var chunks = [header]
        if !selected.isEmpty {
            chunks.append("")
            chunks.append(contentsOf: selected)
        }
        if omitted > 0 {
            chunks.append("")
            chunks.append(t.profileOmitted.replacingOccurrences(of: "%N%", with: String(omitted)))
        }
        if !hint.isEmpty {
            chunks.append("")
            chunks.append(hint)
        }
        return chunks.joined(separator: "\n")
    }

    private static func buildNotesBlock(_ facts: [BotMemoryFact], now: Int64) -> String {
        let ordered = chronological(facts)
        func line(for fact: BotMemoryFact) -> String {
            let key = fact.key?.isEmpty == false ? fact.key! : dayString(fact.learnedAtMS, fallback: now)
            return "- **\(key)**: \(fact.text)\(conditionSuffix(fact))"
        }
        let l2 = ordered.filter { $0.l2 == true }
        let plain = ordered.filter { $0.l2 != true }
        var chunks: [String] = []
        if !l2.isEmpty {
            chunks.append("## L2 notes")
            chunks.append("")
            chunks.append(contentsOf: l2.map(line))
            chunks.append("")
            chunks.append("<!-- /L2 notes -->")
        }
        if !plain.isEmpty {
            if !chunks.isEmpty { chunks.append("") }
            chunks.append(contentsOf: plain.map(line))
        }
        return chunks.joined(separator: "\n")
    }

    private static func recentLogs(_ input: BotMemoryScopeInput, now: Int64) -> [BotMemoryFact] {
        input.facts.enumerated().filter { _, fact in
            fact.tier == .log && BotMemoryVisibility.isVisible(fact, now: now)
        }.sorted { left, right in
            if left.element.learnedAtMS != right.element.learnedAtMS {
                return left.element.learnedAtMS > right.element.learnedAtMS
            }
            return left.offset > right.offset
        }.map(\.element)
    }

    private static func renderRecentLog(
        _ input: BotMemoryScopeInput,
        maxFacts: Int?,
        maxChars: Int?,
        language: BotMemoryPromptLanguage,
        now: Int64
    ) -> String {
        let t = texts(language)
        if maxChars == 0 { return t.omitted }
        let all = recentLogs(input, now: now)
        if all.isEmpty { return t.empty }
        let factLimit: Int
        if let maxFacts, maxFacts > 0 {
            factLimit = maxFacts
        } else {
            factLimit = all.count
        }
        var lines: [String] = []
        var used = 0
        var clipped = false
        for fact in all {
            if lines.count >= factLimit { break }
            let day = dayString(fact.learnedAtMS, fallback: now)
            var line = "- [\(day)] \(fact.text)\(conditionSuffix(fact))"
            let remaining = maxChars.map { $0 - used } ?? Int.max
            if BotMemoryText.utf16Count(line) + (lines.isEmpty ? 0 : 1) > remaining {
                if lines.isEmpty {
                    line = BotMemoryText.clip(line, max(16, remaining))
                    clipped = true
                }
                break
            }
            lines.append(line)
            used += BotMemoryText.utf16Count(line) + 1
        }
        if lines.isEmpty { return t.omitted }
        let text = lines.joined(separator: "\n")
        if !clipped && lines.count >= all.count { return text }
        let truncation = t.logTruncated
            .replacingOccurrences(of: "%SHOWN%", with: String(lines.count))
            .replacingOccurrences(of: "%TOTAL%", with: String(all.count))
        return "\(text)\n\(truncation)"
    }

    private static func logSliceFloor(
        _ scopes: [BotMemoryScopeInput],
        _ language: BotMemoryPromptLanguage,
        now: Int64
    ) -> Int {
        var floor = 0
        for input in scopes {
            let all = recentLogs(input, now: now)
            if all.isEmpty { continue }
            let shown = min(minimumLogFacts, all.count)
            let text = renderRecentLog(
                input,
                maxFacts: shown,
                maxChars: nil,
                language: language,
                now: now
            )
            floor = max(floor, BotMemoryText.utf16Count(text))
        }
        return floor
    }

    private static func renderMemoryBody(
        _ scopes: [BotMemoryScopeInput],
        _ caps: Caps,
        _ language: BotMemoryPromptLanguage,
        now: Int64
    ) -> String {
        let t = texts(language)
        var parts: [String] = []
        for input in scopes {
            let profileBody = buildProfileBlock(
                activeFacts(input, tier: .profile, now: now),
                cap: caps.profile,
                language: language
            )
            let notesBody = buildNotesBlock(activeFacts(input, tier: .note, now: now), now: now)
            parts.append("### \(input.scope == .user ? t.userLabel : t.agentLabel)")
            parts.append("")
            parts.append("**profile.md**")
            parts.append("")
            parts.append(sectionBody(profileBody, cap: caps.profile, language))
            parts.append("")
            parts.append("**notes.md**")
            parts.append("")
            parts.append(sectionBody(notesBody, cap: caps.notes, language))
            parts.append("")
            parts.append(t.recentLogLabel)
            parts.append("")
            parts.append(renderRecentLog(
                input,
                maxFacts: inlineLogFactLimit,
                maxChars: caps.log,
                language: language,
                now: now
            ))
            parts.append("")
        }
        return parts.joined(separator: "\n")
    }

    private static func dayString(_ learnedAtMS: Int64, fallback: Int64) -> String {
        let timestamp = learnedAtMS == 0 ? fallback : learnedAtMS
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withFullDate]
        return formatter.string(from: Date(timeIntervalSince1970: Double(timestamp) / 1_000))
    }
}

enum BotMemoryVisibility {
    static func isActive(_ fact: BotMemoryFact, now: Int64) -> Bool {
        if let supersededBy = fact.supersededBy, !supersededBy.isEmpty { return false }
        if let expiresAt = fact.expiresAt, expiresAt > 0, expiresAt <= now { return false }
        return true
    }

    static func isVisible(_ fact: BotMemoryFact, now: Int64) -> Bool {
        fact.archived != true && isActive(fact, now: now)
    }
}
