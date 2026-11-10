// SPDX-License-Identifier: MIT

import Foundation

/// One other Bot that the current Bot may message. The app supplies only the
/// visible roster: the caller and hidden Bots are already excluded.
public struct BotTeammateSummary: Sendable, Equatable {
    public let id: String
    public let name: String
    public let description: String
    public let isMain: Bool

    public init(id: String, name: String, description: String, isMain: Bool) {
        self.id = id
        self.name = name
        self.description = description
        self.isMain = isMain
    }
}

public actor BotDomainVolatileContextProvider: BotVolatileContextProviding {
    /// Total size of the `<teammates>` sub-block, in Unicode scalars. The
    /// product rule is "under 1000"; keep one scalar of headroom so a later
    /// block separator can never push the rendered snapshot over.
    static let teammatesLimit = 999
    /// Per-entry cap for a teammate description. The total limit still wins.
    static let teammateDescriptionLimit = 200
    static let botDescriptionLimit = 300
    /// The automation block's P26 limit is 4,000 scalars. Leave room for the
    /// routine status text before appending the teammates sub-block.
    static let automationWithTeammatesLimit = 3_900

    private let memoryResolver: @Sendable (String) async throws -> BotMemory
    private let routines: RoutineMachine
    private let variantForSession: @Sendable (String, BotSessionKind) -> String
    private let personaForSession: @Sendable (String, String, BotSessionKind) -> String
    private var asyncPersonaForSession:
        (@Sendable (String, String, BotSessionKind) async throws -> String)?
    private let teammates: (@Sendable (String) async -> [BotTeammateSummary])?
    private let botDescription: (@Sendable (String) async -> String?)?
    private let now: @Sendable () -> Int64
    private let language: String

    public init(
        memory: BotMemory,
        routines: RoutineMachine,
        variant: (@Sendable (String, BotSessionKind) -> String)? = nil,
        persona: (@Sendable (String, String, BotSessionKind) -> String)? = nil,
        memoryForBot: (@Sendable (String) async throws -> BotMemory)? = nil,
        teammates: (@Sendable (String) async -> [BotTeammateSummary])? = nil,
        botDescription: (@Sendable (String) async -> String?)? = nil,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) },
        language: String = "zh"
    ) {
        memoryResolver = memoryForBot ?? { _ in memory }
        self.routines = routines
        variantForSession = Self.makeVariant(variant, language: language)
        personaForSession = persona ?? { _, _, _ in "你的名字是大肥鱼。用户问起名字时如实回答。" }
        asyncPersonaForSession = nil
        self.teammates = teammates
        self.botDescription = botDescription
        self.now = now
        self.language = language
    }

    public init(memory: BotMemory, routines: RoutineMachine,
                personaAsync: @escaping @Sendable (String, String, BotSessionKind) async throws -> String,
                memoryForBot: (@Sendable (String) async throws -> BotMemory)? = nil,
                teammates: (@Sendable (String) async -> [BotTeammateSummary])? = nil,
                botDescription: (@Sendable (String) async -> String?)? = nil,
                now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) },
                language: String = "zh") {
        memoryResolver = memoryForBot ?? { _ in memory }
        self.routines = routines
        variantForSession = Self.makeVariant(nil, language: language)
        personaForSession = { _, _, _ in "" }
        asyncPersonaForSession = personaAsync
        self.teammates = teammates
        self.botDescription = botDescription
        self.now = now
        self.language = language
    }

    private static func makeVariant(
        _ variant: (@Sendable (String, BotSessionKind) -> String)?,
        language: String
    ) -> @Sendable (String, BotSessionKind) -> String {
        if let variant { return variant }
        let en = language == "en"
        return { _, kind in
            switch kind {
            case .task:
                return en
                    ? "# 2. Task variant\n\nComplete the delegated task autonomously. Return one concise, self-contained final result to the parent. You cannot message the user directly; do not ask follow-up questions. Approval denial is final; report it instead of working around it."
                    : "# 2. 子代理变体\n\n自主完成被委派的任务，用一条简洁、自包含的最终结果回复父对话。你不能直接向用户发消息，不要追问。审批被拒绝是终局，不要绕过；如实报告。"
            case .routine:
                return en
                    ? "# 2. Routine variant\n\nYou are running a routine as a hidden turn with the same tools as a normal turn. Carry out the saved instruction autonomously. Do not surface cards (ask_user, show_next_steps, show_*), do not ask questions in the reply, and do not call SendToUser or SendToAgent; the only card this run may raise is RequestApproval. Stay quiet by default: no acknowledgement or progress narration. Your final assistant text is the routine result shown on the routine card; when the saved instruction requires silence and nothing changed, write exactly [quiet]."
                    : "# 2. 例行任务变体\n\n你正以隐藏回合运行一次例行任务，具备和正常回合相同的工具能力。自主完成已保存的指令。不要出卡片（ask_user、show_next_steps、show_*），不要在回复里问问题，也不要调用 SendToUser 或 SendToAgent；唯一可能出现的卡片是 RequestApproval。默认保持安静：不确认收到，不播报进度。最后一条助手文本就是本次结果，会显示在例行任务卡片上；保存的指令要求安静且没有新结果时，最终只写 [quiet]。"
            default:
                return ""
            }
        }
    }

    public func snapshot(botId: String, sessionId: String, kind: BotSessionKind) async throws -> BotVolatileBlocks {
        let variant = variantForSession(sessionId, kind).trimmingCharacters(in: .whitespacesAndNewlines)
        let basePersona: String
        if let asyncPersonaForSession {
            basePersona = try await asyncPersonaForSession(botId, sessionId, kind)
        } else {
            basePersona = personaForSession(botId, sessionId, kind)
        }
        let descriptionValue: String?
        if let botDescription {
            descriptionValue = await botDescription(botId)
        } else {
            descriptionValue = nil
        }
        let persona = Self.personaBlock(basePersona, description: descriptionValue)
        let botMemory = try await memoryResolver(botId)
        let memoryText = try await botMemory
            .promptBlock(language: language == "en" ? .en : .zh)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let automationStatus: String
        do {
            automationStatus = AutomationStatus.block(routines: try await routines.list(botId: botId), now: now(), lang: language)
        } catch {
            automationStatus = AutomationStatus.unreadable(error, lang: language)
        }
        let teammateValues: [BotTeammateSummary]
        if let teammates {
            teammateValues = await teammates(botId)
        } else {
            teammateValues = []
        }
        let teammateBlock = Self.teammatesBlock(
            teammateValues,
            callerId: botId,
            language: language,
            available: max(0, Self.automationWithTeammatesLimit - automationStatus.unicodeScalars.count))
        let automation = Self.appendTeammates(teammateBlock, to: automationStatus)
        return BotVolatileBlocks(
            variant: variant.isEmpty ? nil : variant,
            persona: persona.isEmpty ? nil : persona,
            memory: memoryText.isEmpty ? nil : memoryText,
            automation: automation.isEmpty ? nil : automation)
    }

    static func personaBlock(_ persona: String, description: String?) -> String {
        let trimmed = persona.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let description else { return trimmed }
        let detail = String(description.trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(botDescriptionLimit))
        guard !detail.isEmpty else { return trimmed }
        return trimmed.isEmpty ? detail : trimmed + "\n\n" + detail
    }

    /// Render the `<teammates>` sub-block. It is appended to the automation
    /// block rather than added as a new `BotVolatileBlocks` field: P26's
    /// volatile-context schema has no such key, and the last position matches
    /// the upstream block order (variant, time, persona, memory, automation).
    static func teammatesBlock(
        _ teammates: [BotTeammateSummary],
        callerId: String,
        language: String,
        available: Int = teammatesLimit
    ) -> String {
        let limit = min(teammatesLimit, available)
        guard limit > 0 else { return "" }
        let zh = language != "en"
        let lines = teammates
            .filter { !$0.id.isEmpty && $0.id != callerId }
            .map { teammate -> String in
                let name = sanitizedField(teammate.name, limit: 60)
                let description = sanitizedField(teammate.description, limit: teammateDescriptionLimit)
                let id = sanitizedField(teammate.id, limit: 120)
                let main = teammate.isMain ? (zh ? "，主 Bot" : ", main Bot") : ""
                let detail = description.isEmpty ? "" : (zh ? "：\(description)" : ": \(description)")
                return zh
                    ? "- \(name)（id: \(id)\(main)）\(detail)"
                    : "- \(name) (id: \(id)\(main))\(detail)"
            }
        guard !lines.isEmpty else { return "" }
        var rendered = "<teammates>\n"
        var used = rendered.unicodeScalars.count + "</teammates>".unicodeScalars.count
        var included = 0
        for line in lines {
            let cost = line.unicodeScalars.count + 1
            if used + cost > limit { break }
            rendered += line + "\n"
            used += cost
            included += 1
        }
        guard included > 0 else { return "" }
        rendered += "</teammates>"
        return rendered
    }

    static func appendTeammates(_ block: String, to automation: String) -> String {
        guard !block.isEmpty else { return automation }
        return automation.isEmpty ? block : automation + "\n\n" + block
    }

    private static func sanitizedField(_ value: String, limit: Int) -> String {
        let collapsed = value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(collapsed.prefix(limit))
    }
}
