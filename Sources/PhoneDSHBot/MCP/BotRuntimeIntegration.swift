// SPDX-License-Identifier: MIT

import Foundation

/// One observable stage of the G-2 decision-material pipeline. The host is the
/// single trace carrier; the model-facing tool text never contains these
/// tokens.
public enum BotMaterialTraceStage: String, Codable, Sendable, Equatable {
    /// The host selected bounded materials for a turn/step or a delivery.
    case retrieved
    /// The selected block was placed into the model request (Worker-side
    /// runtime-context snapshot; recorded from the session follow when the
    /// transport exposes it, never synthesized here).
    case injected
    /// A tool/delivery argument referenced a material that was already in the
    /// injected block.
    case adopted
}

public struct BotMaterialTraceEvent: Codable, Sendable, Equatable {
    public var stage: BotMaterialTraceStage
    public var blockID: String?
    public var turnID: String?
    public var sessionID: String
    public var botID: String
    public var materialRefs: [String]
    public var atMS: Int64

    public init(stage: BotMaterialTraceStage, blockID: String?, turnID: String?,
                sessionID: String, botID: String, materialRefs: [String], atMS: Int64) {
        self.stage = stage
        self.blockID = blockID
        self.turnID = turnID
        self.sessionID = sessionID
        self.botID = botID
        self.materialRefs = materialRefs
        self.atMS = atMS
    }
}

/// The composition-owned sink for the three stages. Tests read the same log;
/// there is no second trace store.
public protocol BotMaterialTraceRecording: Sendable {
    func note(_ event: BotMaterialTraceEvent) async
}

/// Bounded in-memory trace. The ring keeps the last 512 events so a long
/// session cannot grow without limit; the launch hands this to the acceptance
/// harness.
public actor BotMaterialTraceLog: BotMaterialTraceRecording {
    public static let capacity = 512
    private var events: [BotMaterialTraceEvent] = []

    public init() {}

    public func note(_ event: BotMaterialTraceEvent) {
        events.append(event)
        if events.count > Self.capacity {
            events.removeFirst(events.count - Self.capacity)
        }
    }

    public func snapshot() -> [BotMaterialTraceEvent] { events }

    public func stages(sessionID: String) -> [BotMaterialTraceStage] {
        events.filter { $0.sessionID == sessionID }.map(\.stage)
    }

    public func reset() { events.removeAll() }
}

/// The host-side authorization revision a decision request is bound to. The
/// composition supplies it (host incarnation + grant revision + roster); the
/// decision service only compares it, it never snapshots authorization.
public typealias BotPermissionRevisionEvaluator =
    @Sendable (String, String, BotDecisionRecipient?) async -> String

/// The single name of the internal additive tool the Worker pre-step provider
/// calls. The Bot catalog and the runtime both reference this constant so the
/// name cannot drift.
public enum BotDecisionTool {
    public static let name = "BotDecisionContext"
}
