// SPDX-License-Identifier: MIT
// PhoneDSHAgentCore: DSH session journal events → `HarnessEvent`.
//
// DSH numbers durable session events densely from 0 (`event.seq`). One DSH
// event can become several harness events (an assistant message and its
// token usage), so the harness seq is `dshSeq * 8 + subIndex`. It is
// monotonic and stable across replays, and resuming after harness seq `s`
// re-maps DSH event `s / 8` and skips its first `s % 8 + 1` parts.
//
// A `tool/result` maps to two projections: the bounded, single-line
// `Kind.toolResult.summary` that UI and event-stream consumers render, and a
// complete audit text in `HarnessEvent.toolResultDetail` whose newlines and
// concluding lines the scenario `transcript.jsonl` keeps.
//
// User-role input maps too: `user/message` becomes
// `Kind.userMessage(text:source:)` and `agent/inbox/spliced` becomes
// `Kind.inboxSpliced(messages:)`, so a transcript can reconstruct what the
// model was shown. `turn/end` keeps the DSH reason label verbatim in
// `HarnessEvent.rawTurnEndKind`/`rawTurnEndCause` while
// `Kind.turnEnded(turnID:reason:)` stays the compatibility projection.

import Foundation

public enum DSHEventMapper {
    public static let partsPerEvent: UInt64 = 8

    public static func harnessSeq(dshSeq: Int, part: Int) -> UInt64 {
        UInt64(dshSeq) * partsPerEvent + UInt64(part)
    }

    /// The DSH seq and part a harness seq refers to.
    public static func position(of harnessSeq: UInt64) -> (dshSeq: Int, part: Int) {
        (Int(harnessSeq / partsPerEvent), Int(harnessSeq % partsPerEvent))
    }

    /// Audit/evidence text bound for a tool result, in UTF-8 bytes. The UI
    /// projection (``HarnessEvent/Kind/toolResult(callID:isError:summary:)``)
    /// keeps its own 280-character single-line bound; this larger bound only
    /// feeds audit consumers such as the scenario `transcript.jsonl`.
    public static let defaultAuditTextLimit = 64 * 1024

    /// Maps one wire event (`{"type","seq","time","data"}`) to harness events.
    ///
    /// - Parameters:
    ///   - sessionID: the DSH session the event belongs to. Audit consumers use
    ///     it to point an over-bound tool result at the durable session journal
    ///     below `/dsh/home/sessions/`; `nil` keeps the generic sessions-tree
    ///     pointer.
    ///   - auditTextLimit: UTF-8 byte bound of the complete tool-result text
    ///     carried by ``HarnessEvent/toolResultDetail``. The bounded single-line
    ///     `summary` is independent of it.
    public static func map(_ event: JSONValue, sessionID: String? = nil,
                           auditTextLimit: Int = defaultAuditTextLimit) -> [HarnessEvent] {
        guard let type = event["type"]?.stringValue, let seq = event["seq"]?.intValue, seq >= 0 else { return [] }
        let time = event["time"]?.numberValue.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
        let data = event["data"] ?? .null
        var kinds: [HarnessEvent.Kind] = []
        var detail: HarnessToolResultDetail?
        var rawTurnEndKind: String?
        var rawTurnEndCause: String?
        switch type {
        case "user/message":
            let text = texts(data["content"])
            if !text.isEmpty {
                kinds.append(.userMessage(text: text, source: userInputSource(data)))
            }
        case "agent/inbox/spliced":
            let inserted = (data["inserted"]?.arrayValue ?? []).compactMap { message -> HarnessUserInput? in
                let text = texts(message["content"])
                guard !text.isEmpty else { return nil }
                return HarnessUserInput(text: text, source: userInputSource(message))
            }
            if !inserted.isEmpty { kinds.append(.inboxSpliced(messages: inserted)) }
        case "turn/start":
            kinds.append(.turnStarted(turnID: turnID(data)))
        case "turn/end":
            rawTurnEndKind = data["reason"]?["kind"]?.stringValue
            rawTurnEndCause = turnEndCause(data["reason"])
            kinds.append(.turnEnded(turnID: turnID(data), reason: turnEnd(data["reason"])))
        case "step/start":
            if let step = data["step"]?.intValue { kinds.append(.progress(phase: "step", step: step, of: nil)) }
        case "assistant/message":
            let text = texts(data["message"]?["content"])
            if !text.isEmpty { kinds.append(.assistantMessage(text: text)) }
            if let usage = data["usage"] {
                kinds.append(.usage(inputTokens: usage["inputTokens"]?.intValue ?? 0,
                                    outputTokens: usage["outputTokens"]?.intValue ?? 0))
            }
        case "tool/call":
            let raw = data["arguments"]?.stringValue ?? ""
            let arguments = (try? JSONValue.parse(Data(raw.utf8))) ?? .string(raw)
            kinds.append(.toolCall(callID: data["callId"]?.stringValue ?? "",
                                   name: data["name"]?.stringValue ?? "", arguments: arguments))
        case "tool/result":
            let message = data["message"] ?? .null
            let callID = message["toolCallId"]?.stringValue ?? message["source"]?["callId"]?.stringValue ?? ""
            let isError = message["isError"]?.boolValue ?? (data["error"] != nil)
            var text = texts(message["content"])
            if text.isEmpty, let reason = data["error"]?["reason"]?.stringValue { text = reason }
            kinds.append(.toolResult(callID: callID, isError: isError, summary: truncate(text)))
            // The summary above is the bounded, single-line UI projection. The
            // audit projection below keeps the tool's line structure so the
            // scenario transcript carries verdict lines and root causes.
            if !text.isEmpty {
                detail = auditDetail(text, sessionID: sessionID, eventSeq: seq,
                                     limit: auditTextLimit)
            }
        default:
            break
        }
        return kinds.enumerated().map { index, kind in
            let toolResultDetail: HarnessToolResultDetail?
            if case .toolResult = kind { toolResultDetail = detail } else { toolResultDetail = nil }
            return HarnessEvent(seq: harnessSeq(dshSeq: seq, part: index), time: time, kind: kind,
                                toolResultDetail: toolResultDetail,
                                rawTurnEndKind: rawTurnEndKind,
                                rawTurnEndCause: rawTurnEndCause)
        }
    }

    static func turnID(_ data: JSONValue) -> String {
        data["turn"]?.intValue.map(String.init) ?? "0"
    }

    /// DSH `source.kind` of a user-role message. Unknown producers stay
    /// explicit instead of being folded into `user`: a synthetic injection must
    /// not look like a human prompt in the transcript.
    static func userInputSource(_ message: JSONValue) -> String {
        message["source"]?["kind"]?.stringValue ?? "unknown"
    }

    /// The raw cause of a DSH turn end. `aborted` nests it under
    /// `reason.reason`; `error` carries a structured `reason.error`. Objects are
    /// compact key-sorted JSON so the transcript line stays stable and
    /// round-trippable; strings are kept as-is.
    static func turnEndCause(_ reason: JSONValue?) -> String? {
        guard let cause = reason?["reason"] ?? reason?["error"], cause != .null else { return nil }
        if let string = cause.stringValue { return string }
        guard let data = try? cause.encoded() else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func turnEnd(_ reason: JSONValue?) -> HarnessTurnEnd {
        switch reason?["kind"]?.stringValue {
        case "completed": return .completed
        case "aborted", "interrupted": return .cancelled
        case "max-tokens": return .budgetExhausted("max-tokens")
        case "error": return .failed(reason?["error"]?["message"]?.stringValue ?? "error")
        case "blocked": return .failed("blocked")
        case "forked": return .completed
        case let other: return .failed(other ?? "unknown")
        }
    }

    /// Concatenated `text` blocks of a content array.
    static func texts(_ content: JSONValue?) -> String {
        (content?.arrayValue ?? []).compactMap { block in
            block["type"]?.stringValue == "text" ? block["text"]?.stringValue : nil
        }.joined()
    }

    static func truncate(_ text: String, limit: Int = 280) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count <= limit ? flat : String(flat.prefix(limit)) + "…"
    }

    /// The audit projection of a tool result: complete text with its newlines,
    /// bounded at `limit` UTF-8 bytes. Over the bound the text is cut on a
    /// character boundary and an explicit spill marker names the durable session
    /// log and the DSH event, so a reviewer can always reach the full record.
    static func auditDetail(_ text: String, sessionID: String?, eventSeq: Int,
                            limit: Int = defaultAuditTextLimit) -> HarnessToolResultDetail {
        let pointer = sessionLogPointer(sessionID: sessionID)
        if limit > 0, text.utf8.count <= limit {
            return HarnessToolResultDetail(text: text, truncated: false,
                                           eventSeq: eventSeq, sessionLogPath: pointer)
        }
        let head = limit > 0 ? utf8Prefix(of: text, limit: limit) : ""
        let marker = "\n… [tool result truncated: \(text.utf8.count) UTF-8 bytes exceed "
            + "the \(limit)-byte audit bound; complete record: \(pointer), "
            + "DSH event seq \(eventSeq)]"
        return HarnessToolResultDetail(text: head + marker, truncated: true,
                                       eventSeq: eventSeq, sessionLogPath: pointer)
    }

    /// The materialized VFS location of a DSH session journal. DSH nests the
    /// journal one workspace directory above the session id and names the file
    /// `session.<version>.jsonl`; the pointer keeps the glob so it does not
    /// invent either value.
    static func sessionLogPointer(sessionID: String?) -> String {
        guard let sessionID, !sessionID.isEmpty else {
            return "/dsh/home/sessions/*/*/session.*.jsonl"
        }
        return "/dsh/home/sessions/*/\(sessionID)/session.*.jsonl"
    }

    /// The longest prefix of `text` whose UTF-8 encoding is at most `limit`
    /// bytes. Never splits a grapheme cluster.
    static func utf8Prefix(of text: String, limit: Int) -> String {
        guard limit > 0 else { return "" }
        var bytes = 0
        var end = text.startIndex
        while end < text.endIndex {
            let next = text.index(after: end)
            let width = text[end..<next].utf8.count
            if bytes + width > limit { break }
            bytes += width
            end = next
        }
        return String(text[..<end])
    }
}
