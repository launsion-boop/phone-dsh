// SPDX-License-Identifier: MIT
// phone-dsh — durable composer queue state for the native chat page.
//
// Official `QueueDock` renders only `inbox["next-turn"]` and correlates a local
// pending submission with its durable row by `source.rpcId`. This file keeps
// that logic UI-free so the simulator suite can exercise it without SwiftUI.

import Foundation
import Observation
import PhoneDSHAgentCore

/// Value types and pure merge/filter rules for the composer queue.
public enum ComposerQueue {
    public enum State: String, Equatable, Sendable {
        case queued
        case sending
    }

    /// One durable `session/projections.inbox["next-turn"]` entry. `id` is the
    /// DSH inbox id used by `session/updateQueue`; `requestID` is the prompt
    /// RPC id (`source.rpcId`) used to retire the matching local line.
    public struct Item: Identifiable, Equatable, Sendable {
        public let id: String
        public let sessionID: String
        public let lane: String
        public let text: String
        /// False when the inbox content contains an image/file part. DSH only
        /// accepts text edits, so the edit action must stay disabled.
        public let isPlainText: Bool
        public let requestID: String?

        public init(id: String, sessionID: String, lane: String, text: String,
                    isPlainText: Bool, requestID: String?) {
            self.id = id
            self.sessionID = sessionID
            self.lane = lane
            self.text = text
            self.isPlainText = isPlainText
            self.requestID = requestID
        }

        public var editable: Bool {
            isPlainText && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        func replacingText(_ text: String) -> Item {
            Item(id: id, sessionID: sessionID, lane: lane, text: text,
                 isPlainText: isPlainText, requestID: requestID)
        }
    }

    /// One optimistic local queue line. It has no inbox id until the matching
    /// durable row lands, so every action stays disabled in that window.
    public struct LocalLine: Identifiable, Equatable, Sendable {
        public let id: String
        public let text: String
        public let state: State
        public let requestID: String?

        public init(id: String, text: String, state: State, requestID: String?) {
            self.id = id
            self.text = text
            self.state = state
            self.requestID = requestID
        }
    }

    /// One rendered dock row: a durable inbox item or a not-yet-echoed local
    /// line. Durable rows keep their inbox id so edit/remove/steer can target
    /// the exact server entry.
    public struct Row: Identifiable, Equatable, Sendable {
        public let id: String
        public let text: String
        public let state: State
        public let item: Item?
        /// True only while the agent is running and the item is on `next-turn`.
        public let canSteer: Bool

        public var editable: Bool { item?.editable ?? false }
    }

    public enum Action: Equatable, Sendable {
        case edit(String)
        case remove
        case steer

        var kind: String {
            switch self {
            case .edit: return "edit"
            case .remove: return "remove"
            case .steer: return "steer"
            }
        }

        var failureTitle: String {
            switch self {
            case .edit: return "编辑排队消息失败"
            case .remove: return "删除排队消息失败"
            case .steer: return "插话发送失败"
            }
        }
    }

    public struct ActionResult: Equatable, Sendable {
        public let succeeded: Bool
        /// Non-nil only for failures the person must see. Steer failures with
        /// `steer-unavailable` / `queue-item-not-found` converge silently, as
        /// official `QueueDock` does.
        public let visibleError: String?

        public init(succeeded: Bool, visibleError: String?) {
            self.succeeded = succeeded
            self.visibleError = visibleError
        }
    }

    /// Decodes only the `next-turn` lane; `next-step` entries are already being
    /// consumed by the current step and never belong in the composer dock.
    public static func decodeInbox(_ inbox: JSONValue?, sessionID: String) -> [Item] {
        guard let lane = inbox?["next-turn"]?.arrayValue else { return [] }
        return lane.compactMap { raw in
            guard let id = raw["id"]?.stringValue else { return nil }
            let content = raw["content"]?.arrayValue ?? []
            let text = content.compactMap { part -> String? in
                guard part["type"]?.stringValue == "text" else { return nil }
                return part["text"]?.stringValue
            }.joined(separator: "\n")
            let plainText = !content.isEmpty
                && content.allSatisfy { $0["type"]?.stringValue == "text" }
            return Item(id: id,
                        sessionID: sessionID,
                        lane: "next-turn",
                        text: text,
                        isPlainText: plainText,
                        requestID: raw["source"]?["rpcId"]?.stringValue)
        }
    }

    /// Merges durable rows with local lines. A local line whose `rpcId` has
    /// ever appeared in the inbox is retired and the durable row keeps its
    /// identity. Matching is by request id only: equal text from two different
    /// submissions must remain two rows.
    public static func rows(durable: [Item],
                            local: [LocalLine],
                            acknowledgedRequestIDs: Set<String>,
                            running: Bool) -> [Row] {
        let nextTurn = durable.filter { $0.lane == "next-turn" }
        var rows = nextTurn.map { item in
            Row(id: "durable:\(item.id)", text: item.text, state: .queued, item: item,
                canSteer: running && item.lane == "next-turn")
        }
        for line in local {
            if let requestID = line.requestID, !requestID.isEmpty,
               acknowledgedRequestIDs.contains(requestID)
                || nextTurn.contains(where: { $0.requestID == requestID }) {
                continue
            }
            // A dispatching local line owns the independent pending row above
            // the composer; the dock only shows lines still waiting to land.
            guard line.state == .queued else { continue }
            rows.append(Row(id: "local:\(line.id)", text: line.text, state: .queued,
                            item: nil, canSteer: false))
        }
        return rows
    }

    public static func errorCode(_ error: Error) -> String? {
        (error as? DSHRemoteError)?.code
    }

    /// Official `QueueDock` treats these steer failures as convergence: another
    /// turn claimed the entry, or steering is no longer legal. Refresh the
    /// inbox instead of notifying.
    public static func isSilentSteerFailure(_ action: Action, error: Error) -> Bool {
        guard case .steer = action, let code = errorCode(error) else { return false }
        return code == "session/steer-unavailable" || code == "session/queue-item-not-found"
    }

    public static func friendlyMessage(for error: Error, code: String?) -> String {
        switch code {
        case "session/queue-item-not-found":
            return "这条消息已经不在队列里了"
        case "session/steer-unavailable":
            return "现在不能插话发送"
        case "session/attachment-invalid":
            return "包含非文本内容，不能编辑"
        case "gateway/bad-request":
            return "消息内容为空或格式不对"
        default:
            if let remote = error as? DSHRemoteError, !remote.message.isEmpty {
                return remote.message
            }
            return error.localizedDescription
        }
    }
}

/// Chat-page queue state. It deliberately lives outside `DSHManagementModel`
/// so the composer reads only `next-turn` and keeps `source.rpcId`, while the
/// legacy (currently unreachable) `SessionQueuePage` keeps its own behaviour.
@MainActor
@Observable
public final class ComposerQueueStore {
    public private(set) var sessionID: String?
    public private(set) var items: [ComposerQueue.Item] = []
    /// Last edit/remove/other-steer failure, kept for the chat page's notice.
    public private(set) var lastError: String?

    private var acknowledgedRequestIDs: Set<String> = []
    private var refreshSequence = 0

    public init() {}

    public func prepare(for sessionID: String?) {
        guard self.sessionID != sessionID else { return }
        self.sessionID = sessionID
        items = []
        acknowledgedRequestIDs = []
        lastError = nil
        // Never let an older in-flight projection overwrite a new session.
        refreshSequence += 1
    }

    public func reset() {
        prepare(for: nil)
    }

    public func rows(for sessionID: String?,
                     local: [ComposerQueue.LocalLine],
                     running: Bool) -> [ComposerQueue.Row] {
        let current = sessionID != nil && sessionID == self.sessionID
        return ComposerQueue.rows(durable: current ? items : [],
                                  local: local,
                                  acknowledgedRequestIDs: current ? acknowledgedRequestIDs : [],
                                  running: running)
    }

    /// Reads `inbox["next-turn"]` and records every observed `rpcId` so a local
    /// line cannot reappear after its durable row is claimed. A failed refresh
    /// keeps the last rows; the next lifecycle trigger retries.
    @discardableResult
    public func refresh(sessionID: String, using transport: any DSHRemoteTransport) async -> Bool {
        if self.sessionID == nil { prepare(for: sessionID) }
        // An in-flight refresh must never switch the store back to a session the
        // person already left.
        guard self.sessionID == sessionID else { return false }
        refreshSequence += 1
        let sequence = refreshSequence
        do {
            let result = try await transport.call(
                "session/projections",
                args: .object(["request": .object(["sessionId": .string(sessionID)])]))
            guard self.sessionID == sessionID, refreshSequence == sequence else { return false }
            let decoded = ComposerQueue.decodeInbox(result["values"]?["inbox"], sessionID: sessionID)
            items = decoded
            acknowledgedRequestIDs.formUnion(decoded.compactMap(\.requestID))
            return true
        } catch {
            return false
        }
    }

    /// Runs one `session/updateQueue` action, then re-reads the inbox on every
    /// outcome. A `queue-item-not-found` removes the local row immediately so a
    /// consumed entry cannot linger as a ghost even if the follow-up refresh
    /// fails.
    @discardableResult
    public func perform(_ action: ComposerQueue.Action,
                        on item: ComposerQueue.Item,
                        sessionID: String,
                        using transport: any DSHRemoteTransport) async -> ComposerQueue.ActionResult {
        if self.sessionID == nil { prepare(for: sessionID) }
        guard self.sessionID == sessionID else {
            return ComposerQueue.ActionResult(succeeded: false, visibleError: nil)
        }
        lastError = nil
        var value: [String: JSONValue] = ["kind": .string(action.kind)]
        if case .edit(let text) = action {
            value["content"] = .array([.object(["type": .string("text"), "text": .string(text)])])
        }
        do {
            _ = try await transport.call(
                "session/updateQueue",
                args: .object(["request": .object([
                    "sessionId": .string(sessionID),
                    "itemId": .string(item.id),
                    "action": .object(value),
                ])]))
            // The person may have switched sessions while the RPC was in
            // flight; that session's queue must not be touched or resurrected.
            guard self.sessionID == sessionID else {
                return ComposerQueue.ActionResult(succeeded: false, visibleError: nil)
            }
            applyLocally(action, on: item)
            await refresh(sessionID: sessionID, using: transport)
            return ComposerQueue.ActionResult(succeeded: true, visibleError: nil)
        } catch {
            guard self.sessionID == sessionID else {
                return ComposerQueue.ActionResult(succeeded: false, visibleError: nil)
            }
            let silent = ComposerQueue.isSilentSteerFailure(action, error: error)
            if ComposerQueue.errorCode(error) == "session/queue-item-not-found" {
                items.removeAll { $0.id == item.id }
            }
            await refresh(sessionID: sessionID, using: transport)
            if silent {
                return ComposerQueue.ActionResult(succeeded: false, visibleError: nil)
            }
            let message = "\(action.failureTitle)：\(ComposerQueue.friendlyMessage(for: error, code: ComposerQueue.errorCode(error)))"
            lastError = message
            return ComposerQueue.ActionResult(succeeded: false, visibleError: message)
        }
    }

    private func applyLocally(_ action: ComposerQueue.Action, on item: ComposerQueue.Item) {
        switch action {
        case .edit(let text):
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                items[index] = items[index].replacingText(text)
            }
        case .remove, .steer:
            // A steered entry moves to `next-step`, which the dock never shows.
            items.removeAll { $0.id == item.id }
        }
    }
}
