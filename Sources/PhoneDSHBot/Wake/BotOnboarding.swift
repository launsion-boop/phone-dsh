// SPDX-License-Identifier: MIT

import Foundation

/// The one-time opening turn for a newly created Bot.
///
/// The item is a durable held message, not a new turn-origin or session kind:
/// `WakeInbox` dedupes it by `requestId`, and `wakeWithHeldMessages` opens a
/// normal visible chat turn (or folds it into the user's first turn) exactly
/// like every other held delivery.
public enum BotOnboarding {
    /// Bump only when the opening instruction changes. A new Bot starts at the
    /// current version; existing Bots are never re-enqueued by a session claim.
    public static let version = 1

    public static let prompt = """
    这是你被创建后的第一次开场，只做一次。

    先读你自己的描述和本轮 runtime-context 里的事实：名字、职责、队友名单、记忆索引、已启用的例行任务。然后判断你现在确实能做的两三件事。

    回复要求：
    1. 用 show_next_steps 给出 2–3 个真实可执行的建议动作，选项值写成用户会直接说的话；
    2. 正文一句话说明你是谁、能做什么，不复述描述原文，不罗列工具清单；
    3. 不要问「接下来做什么」，用卡片代替提问；
    4. 本回合不受“回复最多 2 句”的长度限制，但也别超过 3 句。

    之后按正常回合流程走，不要再重发开场卡。
    """

    public static func hasPending(in inbox: WakeInbox) async -> Bool {
        ((try? await inbox.items()) ?? []).contains {
            $0.kind == "onboarding" && $0.state == .pending
        }
    }

    public static func item(botID: String, now: Int64) throws -> WakeInboxItem {
        let trimmed = botID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RoutineError.invalidHeldItem("onboarding requires a bot id")
        }
        let digest = BotArgumentsDigest.digest(
            ofUTF8: "onboarding:\(trimmed):\(version)")
        return try WakeInboxItem(
            id: "onboarding-\(trimmed)-v\(version)",
            kind: "onboarding",
            fromAgentName: "Phone DSH",
            title: "创建后的开场",
            text: prompt,
            requestId: BotTurnOrigin.heldRequestId(digest: digest),
            createdAt: now)
    }
}
