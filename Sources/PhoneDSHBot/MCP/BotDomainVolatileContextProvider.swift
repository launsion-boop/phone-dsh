// SPDX-License-Identifier: MIT

import Foundation

public actor BotDomainVolatileContextProvider: BotVolatileContextProviding {
    private let memory: BotMemory
    private let routines: RoutineMachine
    private let variantForSession: @Sendable (String, BotSessionKind) -> String
    private let personaForSession: @Sendable (String, BotSessionKind) -> String
    private var asyncPersonaForSession: (@Sendable (String, BotSessionKind) async throws -> String)?
    private let now: @Sendable () -> Int64
    private let language: String

    public init(
        memory: BotMemory,
        routines: RoutineMachine,
        variant: (@Sendable (String, BotSessionKind) -> String)? = nil,
        persona: (@Sendable (String, BotSessionKind) -> String)? = nil,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) },
        language: String = "zh"
    ) {
        self.memory = memory
        self.routines = routines
        variantForSession = Self.makeVariant(variant)
        personaForSession = persona ?? { _, _ in "你的名字是大肥鱼。用户问起名字时如实回答。" }
        asyncPersonaForSession = nil
        self.now = now
        self.language = language
    }

    public init(memory: BotMemory, routines: RoutineMachine,
                personaAsync: @escaping @Sendable (String, BotSessionKind) async throws -> String,
                now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) },
                language: String = "zh") {
        self.memory = memory
        self.routines = routines
        variantForSession = Self.makeVariant(nil)
        personaForSession = { _, _ in "" }
        asyncPersonaForSession = personaAsync
        self.now = now
        self.language = language
    }

    private static func makeVariant(
        _ variant: (@Sendable (String, BotSessionKind) -> String)?
    ) -> @Sendable (String, BotSessionKind) -> String {
        variant ?? { _, kind in
            switch kind {
            case .task:
                return "# 2. 子代理变体\n\n自主完成被委派的任务，用一条简洁、自包含的最终结果回复父对话。你不能直接向用户发消息，不要追问。审批被拒绝是终局，不要绕过；如实报告。"
            case .routine:
                return "# 2. 例行任务变体\n\n在隐藏回合自主完成保存的指令，不输出过程散文，不调用 SendToUser，只呈现有用的卡片。最后一条助手文本就是本次结果；保存的指令要求安静且没有新结果时，最终只写 [quiet]。"
            default:
                return ""
            }
        }
    }

    public func snapshot(botId: String, sessionId: String, kind: BotSessionKind) async throws -> BotVolatileBlocks {
        let variant = variantForSession(sessionId, kind).trimmingCharacters(in: .whitespacesAndNewlines)
        let persona: String
        if let asyncPersonaForSession {
            persona = try await asyncPersonaForSession(sessionId, kind).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            persona = personaForSession(sessionId, kind).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let memoryText = try await memory.promptBlock(language: language == "en" ? .en : .zh)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let automation: String
        do {
            automation = AutomationStatus.block(routines: try await routines.list(botId: botId), now: now(), lang: language)
        } catch {
            automation = AutomationStatus.unreadable(error, lang: language)
        }
        return BotVolatileBlocks(
            variant: variant.isEmpty ? nil : variant,
            persona: persona.isEmpty ? nil : persona,
            memory: memoryText.isEmpty ? nil : memoryText,
            automation: automation)
    }
}
