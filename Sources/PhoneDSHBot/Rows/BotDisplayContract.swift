// SPDX-License-Identifier: MIT

import Foundation

enum BotRowJSON {
    static func object(_ value: BotJSONValue?) -> [String: BotJSONValue]? {
        guard case .object(let object) = value else { return nil }
        return object
    }

    static func array(_ value: BotJSONValue?) -> [BotJSONValue]? {
        guard case .array(let array) = value else { return nil }
        return array
    }

    static func string(_ object: [String: BotJSONValue], _ key: String) -> String? {
        guard case .string(let value) = object[key] else { return nil }
        return value
    }

    static func bool(_ object: [String: BotJSONValue], _ key: String) -> Bool? {
        guard case .bool(let value) = object[key] else { return nil }
        return value
    }

    static func int(_ object: [String: BotJSONValue], _ key: String) -> Int? {
        guard case .number(let value) = object[key], value.isFinite,
              value.rounded() == value, value >= Double(Int.min), value <= Double(Int.max) else { return nil }
        return Int(value)
    }

    static func nonEmptyString(_ object: [String: BotJSONValue], _ keys: [String]) -> String? {
        for key in keys {
            if let value = string(object, key), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }

    static func hasItems(_ object: [String: BotJSONValue], _ keys: [String]) -> Bool {
        keys.contains { key in
            guard let values = array(object[key]) else { return false }
            return !values.isEmpty
        }
    }
}

public enum BotDisplayProfile: Sendable {
    case upstreamReference
    case phoneP0
}

public struct BotWireRecord: Codable, Sendable, Equatable {
    public var kind: String
    public var type: String
    public var role: String?

    public init(kind: String, type: String, role: String? = nil) {
        self.kind = kind
        self.type = type
        self.role = role
    }
}

public struct BotDisplayProjection: Sendable, Equatable {
    public var surface: String
    public var renderable: Bool
    public var wire: BotWireRecord

    public init(surface: String, renderable: Bool, wire: BotWireRecord) {
        self.surface = surface
        self.renderable = renderable
        self.wire = wire
    }
}

public enum BotDisplayContract {
    public static let hidden = "hidden"
    public static let p1CardTypes: Set<BotWidgetCardType> = [.table, .callout, .info, .payload, .library]

    public static func project(_ input: [String: BotJSONValue],
                               profile: BotDisplayProfile = .phoneP0) -> BotDisplayProjection {
        let kind = BotRowJSON.string(input, "kind") ?? "message"
        switch kind {
        case "message":
            if input["toAgent"] != nil || input["fromAgent"] != nil || BotRowJSON.bool(input, "agentComm") == true {
                return projection("agent-comm", hasText(input, keys: ["text", "content"]),
                                  BotWireRecord(kind: "message", type: "text", role: BotRowJSON.string(input, "role")))
            }
            let role = BotRowJSON.string(input, "role")
            let isUser = role == "user"
            // Attachment-only user messages have an empty bubble text but must
            // still render the row (the attachments are shown as cards).
            let hasBody = hasText(input, keys: ["text", "content"])
                || BotRowJSON.hasItems(input, ["attachments"])
            return projection("bubble", hasBody,
                              BotWireRecord(kind: isUser ? "message" : "send-message", type: "text", role: role))
        case "card", "attachment", "file", "info-row", "payload-row", "task-thread", "team-bot":
            return cardProjection(input, kind: kind, profile: profile)
        case "approval":
            let status = BotRowJSON.string(input, "status") ?? "pending"
            let hasData = input["ask"] != nil || BotRowJSON.nonEmptyString(input, ["action", "text", "status"]) != nil
            return projection("approval-card", status != "pending" && hasData,
                              BotWireRecord(kind: "send-message", type: "local-tool-permission"))
        case "routine-run", "automation", "automation-run":
            let automation = BotRowJSON.object(input["automation"]) ?? [:]
            let hasData = BotRowJSON.nonEmptyString(automation, ["name", "automationId"]) != nil
                || BotRowJSON.nonEmptyString(input, ["title", "name", "automationId"]) != nil
            return projection("automation-row", hasData, BotWireRecord(kind: "message", type: "text"))
        case "system-event":
            let event = BotRowJSON.string(input, "event") ?? ""
            let visible = ["outbound", "inbound", "summary", "renamed"].contains(event)
            let hasData = event == "renamed"
                ? BotRowJSON.nonEmptyString(input, ["botName"]) != nil
                : BotRowJSON.nonEmptyString(input, ["botName", "text"]) != nil
            return projection(visible ? "system-event" : hidden, visible && hasData,
                              BotWireRecord(kind: "event", type: event.isEmpty ? "unknown" : event))
        case "notice":
            let tone = BotRowJSON.string(input, "tone") ?? ""
            let visible = ["error", "denied", "denial"].contains(tone) && BotRowJSON.bool(input, "contextOnly") != true
            return projection(visible ? "notice" : hidden, visible && hasText(input, keys: ["text"]),
                              BotWireRecord(kind: "event", type: "notice"))
        case "tool-call":
            return projection(hidden, false, BotWireRecord(kind: "event", type: "tool-call"))
        case "deleted":
            return projection(hidden, false, BotWireRecord(kind: "event", type: "deleted"))
        case "separator":
            return projection("separator", profile == .upstreamReference,
                              BotWireRecord(kind: "event", type: "separator"))
        default:
            return projection(hidden, false, BotWireRecord(kind: "event", type: kind))
        }
    }

    public static func project(_ row: BotRow,
                               profile: BotDisplayProfile = .phoneP0) -> BotDisplayProjection {
        var input = row.body.additionalProperties
        if let cardType = row.body.cardType { input["cardType"] = .string(cardType.rawValue) }
        if let cardKey = row.body.cardKey { input["cardKey"] = .string(cardKey) }
        if let role = row.role { input["role"] = .string(role) }
        switch row.body.type {
        case .text:
            input["kind"] = .string("message")
            if row.kind == .message && row.role == nil { input["role"] = .string("user") }
        case .widget:
            input["kind"] = .string("card")
        case .attachment:
            input["kind"] = .string("card")
            input["cardType"] = .string("attachment")
        case .approval:
            input["kind"] = .string("approval")
        case .automation:
            input["kind"] = .string("routine-run")
        case .notice:
            input["kind"] = .string(input["event"] == nil ? "notice" : "system-event")
        case .deleted:
            input["kind"] = .string("deleted")
        }
        return project(input, profile: profile)
    }

    private static func cardProjection(_ input: [String: BotJSONValue], kind: String,
                                       profile: BotDisplayProfile) -> BotDisplayProjection {
        let rawType = BotRowJSON.string(input, "cardType") ?? defaultCardType(for: kind) ?? ""
        let surface: String
        let wireType: String
        let hasData: Bool
        switch rawType {
        case "question", "steps":
            surface = "widget-card"
            wireType = "widget"
            hasData = BotRowJSON.nonEmptyString(input, ["question", "prompt", "helpText", "help"]) != nil
                || BotRowJSON.hasItems(input, ["options", "steps"])
        case "attachment", "file":
            surface = "attachment-card"
            wireType = "attachment"
            hasData = BotRowJSON.nonEmptyString(input, ["fileName", "name", "path"]) != nil
        case "document", "library":
            surface = "document-card"
            wireType = "widget"
            hasData = BotRowJSON.nonEmptyString(input, ["title", "name", "path", "url", "summary"]) != nil
        case "progress":
            surface = "progress-card"
            wireType = "widget"
            hasData = BotRowJSON.nonEmptyString(input, ["title", "name"]) != nil
        case "checklist":
            surface = "checklist-card"
            wireType = "widget"
            hasData = BotRowJSON.nonEmptyString(input, ["title"]) != nil && BotRowJSON.hasItems(input, ["items"])
        case "link":
            surface = "link-card"
            wireType = "widget"
            hasData = BotRowJSON.hasItems(input, ["links"])
        case "task":
            surface = "agent-thread-row"
            wireType = "widget"
            hasData = BotRowJSON.nonEmptyString(input, ["title", "text"]) != nil
                || BotRowJSON.hasItems(input, ["tasks", "steps"])
        case "table":
            surface = "table-card"
            wireType = "widget"
            hasData = (BotRowJSON.array(input["columns"])?.count ?? 0) > 1 && BotRowJSON.hasItems(input, ["rows"])
        case "callout":
            surface = "callout"
            wireType = "widget"
            hasData = BotRowJSON.nonEmptyString(input, ["body", "title"]) != nil
        case "info":
            surface = "info-row"
            wireType = "connector"
            hasData = BotRowJSON.nonEmptyString(input, ["label", "value", "title", "text"]) != nil
                || BotRowJSON.hasItems(input, ["rows"])
        case "payload":
            surface = "payload-row"
            wireType = "text"
            hasData = BotRowJSON.hasItems(input, ["payloads", "items", "attachments"])
        case "team-bot":
            surface = "team-bot-row"
            wireType = "widget"
            hasData = BotRowJSON.nonEmptyString(input, ["name", "title", "teamBotName", "description"]) != nil
        default:
            return projection(hidden, false, BotWireRecord(kind: "send-message", type: "widget"))
        }
        if profile == .phoneP0 && (p1CardTypes.rawValues.contains(rawType) || rawType == "team-bot") {
            return projection(hidden, false, BotWireRecord(kind: "send-message", type: wireType))
        }
        return projection(surface, hasData, BotWireRecord(kind: "send-message", type: wireType))
    }

    private static func defaultCardType(for kind: String) -> String? {
        switch kind {
        case "attachment", "file": return "attachment"
        case "info-row": return "info"
        case "payload-row": return "payload"
        case "task-thread": return "task"
        case "team-bot": return "team-bot"
        default: return nil
        }
    }

    private static func hasText(_ input: [String: BotJSONValue], keys: [String]) -> Bool {
        BotRowJSON.nonEmptyString(input, keys) != nil
    }

    private static func projection(_ surface: String, _ renderable: Bool,
                                   _ wire: BotWireRecord) -> BotDisplayProjection {
        BotDisplayProjection(surface: renderable || surface != hidden ? surface : hidden,
                             renderable: renderable, wire: wire)
    }
}

private extension Set where Element == BotWidgetCardType {
    var rawValues: Set<String> { Set<String>(map { $0.rawValue }) }
}
