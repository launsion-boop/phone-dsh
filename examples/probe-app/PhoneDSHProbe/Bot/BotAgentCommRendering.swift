// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSHBot

// MARK: - Agent-comm row rendering

/// The minimal one-line rendering of an agent-comm row. The full visual pass
/// belongs to the sidebar wave; this carries the information the phone
/// transcript needs today.
struct BotAgentCommPresentation: Equatable {
    enum Tone: Equatable { case outbound, inbound, incoming, reply, failed }
    var tone: Tone
    var peerID: String?
    var peerName: String?
    var text: String
    var detail: String?
}

enum BotAgentCommRendering {
    static func presentation(for row: BotUIRow) -> BotAgentCommPresentation? {
        let comm = row.body["agentComm"]?.object
        let fromAgent = row.body["fromAgent"]?.object
        let toAgent = row.body["toAgent"]?.object
        guard comm != nil || fromAgent != nil || toAgent != nil else { return nil }

        let direction = comm?["direction"]?.string ?? row.body["direction"]?.string ?? "outbound"
        let fromID = comm?["fromAgentId"]?.string ?? fromAgent?["id"]?.string
        let fromName = comm?["fromAgentName"]?.string ?? fromAgent?["name"]?.string
        let toID = comm?["targetId"]?.string ?? toAgent?["id"]?.string
        let toName = comm?["targetName"]?.string ?? toAgent?["name"]?.string
        let message = comm?["message"]?.string ?? row.body["text"]?.string ?? ""
        let reply = comm?["replyText"]?.string ?? ""
        let error = comm?["error"]?.string ?? row.body["error"]?.string

        switch direction {
        case "inbound":
            let name = fromName ?? "队友"
            let body = reply.isEmpty ? "已收到回复" : reply
            return BotAgentCommPresentation(
                tone: error == nil ? .inbound : .failed, peerID: fromID, peerName: name,
                text: "\(name) 回复", detail: error ?? clipped(body))
        case "incoming":
            let name = fromName ?? "队友"
            return BotAgentCommPresentation(
                tone: .incoming, peerID: fromID, peerName: name,
                text: "\(name) 传来消息", detail: clipped(message))
        case "reply":
            let name = toName ?? "队友"
            return BotAgentCommPresentation(
                tone: .reply, peerID: toID, peerName: name,
                text: "已回复 \(name)", detail: clipped(message))
        default:
            let name = toName ?? "队友"
            return BotAgentCommPresentation(
                tone: error == nil ? .outbound : .failed, peerID: toID, peerName: name,
                text: "已传消息给 \(name)", detail: error ?? clipped(message))
        }
    }

    /// The sidebar-friendly summary for a run of rows on one thread.
    static func summaryText(count: Int, peerName: String?) -> String {
        let name = peerName ?? "队友"
        if count <= 1 { return "与 \(name) 的消息" }
        return "与 \(name) 的 \(count) 条消息往来"
    }

    static func clipped(_ value: String, limit: Int = 80) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "…"
    }
}
