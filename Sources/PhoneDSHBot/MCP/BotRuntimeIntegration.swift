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

/// Maps the App workspace root to the host URL of a file resource. The key is
/// workspace-relative; absolute roots and `..` escapes are refused so a
/// recheck can never read outside the Bot workspace.
public struct BotWorkspaceFileURLResolver: BotFileURLResolving {
    public let workspaceRoot: URL

    public init(workspaceRoot: URL) { self.workspaceRoot = workspaceRoot }

    public func fileURL(for resource: BotFileResourceIdentity, botID: String) -> URL? {
        guard resource.kind == "file", !resource.key.isEmpty else { return nil }
        let key = resource.key.hasPrefix("/")
            ? String(resource.key.dropFirst()) : resource.key
        guard !key.split(separator: "/").contains("..") else { return nil }
        let root = workspaceRoot.standardizedFileURL
        let url = root.appendingPathComponent(key).standardizedFileURL
        guard url.path == root.path || url.path.hasPrefix(root.path + "/") else { return nil }
        return url
    }
}

/// Adapts P's raw-byte file rechecker to L's provenance recheck seam. Only a
/// `content-sha256` baseline over file bytes is comparable; anything else is
/// honestly `notPerformed` instead of a false current/changed.
public struct BotProvenanceFileRecheckAdapter: BotProvenanceRechecking {
    private let rechecker: BotFileSourceRechecker

    public init(rechecker: BotFileSourceRechecker) { self.rechecker = rechecker }

    public func recheck(resource: BotResourceIdentity,
                        baseline: BotProvenanceSourceVersion,
                        botID: String?) async -> BotProvenanceRecheckOutcome {
        guard resource.kind == .file else { return .notPerformed }
        let identity = BotFileResourceIdentity(
            key: resource.key, owner: resource.owner, scope: resource.scope)
        let fileBaseline: BotFileBaseline?
        if case let .known(known) = baseline, known.basis == .contentSHA256 {
            // G-1 r13: only a baseline that says `subject: file-bytes` may be
            // compared with raw file bytes. Everything else is conservatively
            // record text, so a textual digest can never masquerade as a file
            // version (P reports unchanged only when sha256(raw) == token).
            switch known.subject {
            case .fileBytes: fileBaseline = .fileBytes(known.value)
            default: fileBaseline = .recordText(known.value)
            }
        } else {
            fileBaseline = nil
        }
        let result = await rechecker.recheck(
            identity, botID: botID ?? "", baseline: fileBaseline)
        switch result {
        case let .unchanged(_, at):
            return .same(atMS: at)
        case let .changed(_, current, at):
            return .changed(
                version: .known(BotKnownProvenanceSourceVersion(
                    basis: .contentSHA256, value: current.value,
                    observedAtMS: at, basisRef: nil, subject: .fileBytes)),
                atMS: at)
        case let .denied(reason):
            return .denied(detail: reason.rawValue)
        case let .unavailable(reason):
            return .unavailable(detail: reason.rawValue)
        case .notPerformed:
            return .notPerformed
        }
    }
}
