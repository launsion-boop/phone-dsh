// SPDX-License-Identifier: MIT

import Foundation

/// The frozen turn-origin classification from
/// `spec/bot/v1/README.md` §4.1. The only input is the DSH
/// `user/message.data.source.rpcId` minted by the host; message text never
/// participates.
public enum BotTurnOriginKind: String, Codable, Sendable, Equatable, CaseIterable {
    case user
    case held
    case agent
    case routine
    case task
    case taskWake = "task-wake"
    case unknown
}

/// One resolved turn origin. `hidden`, `held` and `memorySource` are derived
/// from `kind`, which itself comes from the frozen prefix table; nothing else
/// may re-derive them from the message text.
public struct BotTurnOrigin: Sendable, Equatable {
    /// The prefix table, in match order. It mirrors the valid vectors in
    /// `spec/bot/v1/golden/turn-origin.phone.json`; that file drives the
    /// conformance tests instead of a second hand-written expectation list.
    static let prefixes: [(prefix: String, kind: BotTurnOriginKind)] = [
        ("user-action:", .user),
        ("bot-", .user),
        ("held:", .held),
        ("agent:", .agent),
        ("routine:", .routine),
        ("task-turn:", .task),
        ("task-settled:", .taskWake),
        ("task-interrupted:", .taskWake),
    ]

    public let rpcId: String?
    public let kind: BotTurnOriginKind

    public var hidden: Bool {
        switch kind {
        case .routine, .task, .taskWake: return true
        case .user, .held, .agent, .unknown: return false
        }
    }

    public var held: Bool { kind == .held }

    public var memorySource: BotMemorySourceKind {
        switch kind {
        case .user: return .userTurn
        case .held, .agent, .unknown: return .agentMessage
        case .routine: return .routine
        case .task: return .task
        case .taskWake: return .hiddenWake
        }
    }

    public init(rpcId: String?) {
        self.rpcId = rpcId
        guard let rpcId, !rpcId.isEmpty else {
            kind = .unknown
            return
        }
        for (prefix, candidate) in Self.prefixes where rpcId.hasPrefix(prefix) {
            let payload = rpcId.dropFirst(prefix.count)
            // The contract requires at least one non-whitespace payload
            // character; a bare prefix or whitespace-only payload is unknown.
            if payload.unicodeScalars.contains(where: {
                !CharacterSet.whitespacesAndNewlines.contains($0)
            }) {
                kind = candidate
            } else {
                kind = .unknown
            }
            return
        }
        kind = .unknown
    }

    public static func parse(rpcId: String?) -> BotTurnOrigin {
        BotTurnOrigin(rpcId: rpcId)
    }

    /// Resolve the origin recorded on a DSH `user/message` event. Missing or
    /// non-object `source` is unknown, never hidden.
    public static func from(source: [String: BotJSONValue]?) -> BotTurnOrigin {
        guard let source, case .string(let rpcId)? = source["rpcId"] else {
            return BotTurnOrigin(rpcId: nil)
        }
        return BotTurnOrigin(rpcId: rpcId)
    }

    // MARK: - Host-minted request ids

    public static func userActionRequestId(nonce: String) -> String {
        "user-action:\(nonce)"
    }

    public static func visibleRequestId(uuid: UUID = UUID()) -> String {
        "bot-\(uuid.uuidString.lowercased())"
    }

    public static func heldRequestId(digest: String) -> String {
        "held:\(digest)"
    }

    public static func agentRequestId(callId: String) -> String {
        "agent:\(callId)"
    }

    public static func routineRequestId(runId: String) -> String {
        "routine:\(runId)"
    }

    public static func taskTurnRequestId(taskId: String) -> String {
        "task-turn:\(taskId)"
    }

    public static func taskSettledRequestId(taskId: String) -> String {
        "task-settled:\(taskId)"
    }

    public static func taskInterruptedRequestId(taskId: String) -> String {
        "task-interrupted:\(taskId)"
    }

    /// The `user-action:` nonce, or nil for every other request id. Used by
    /// the held-delivery bookkeeping, not to classify the turn.
    public static func userActionNonce(from rpcId: String?) -> String? {
        guard let rpcId, rpcId.hasPrefix("user-action:") else { return nil }
        let nonce = String(rpcId.dropFirst("user-action:".count))
        guard nonce.unicodeScalars.contains(where: {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        }) else { return nil }
        return nonce
    }
}
