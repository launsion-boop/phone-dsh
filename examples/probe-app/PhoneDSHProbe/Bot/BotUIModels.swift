// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSHBot
import UniformTypeIdentifiers

enum BotJSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: BotJSONValue])
    case array([BotJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Int.self) { self = .number(Double(value)); return }
        if let value = try? container.decode(Double.self) { self = .number(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode([String: BotJSONValue].self) { self = .object(value); return }
        if let value = try? container.decode([BotJSONValue].self) { self = .array(value); return }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported Bot JSON value")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var number: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    var int: Int? {
        guard let number, number.isFinite, number.rounded() == number else { return nil }
        return Int(exactly: number)
    }

    var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var object: [String: BotJSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var array: [BotJSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }
}

extension BotJSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral,
    ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(floatLiteral value: Double) { self = .number(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(arrayLiteral elements: BotJSONValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, BotJSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
    init(nilLiteral: ()) { self = .null }
}

struct BotUIBody: Codable, Equatable {
    var type: String
    var values: [String: BotJSONValue]

    init(type: String, values: [String: BotJSONValue] = [:]) {
        self.type = type
        var stored = values
        stored["type"] = .string(type)
        self.values = stored
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: BotUIDynamicKey.self)
        var values: [String: BotJSONValue] = [:]
        for key in container.allKeys {
            values[key.stringValue] = try container.decode(BotJSONValue.self, forKey: key)
        }
        guard let type = values["type"]?.string, !type.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: BotUIDynamicKey("type"), in: container,
                                                   debugDescription: "Bot row body.type is required")
        }
        self.init(type: type, values: values)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: BotUIDynamicKey.self)
        for (key, value) in values {
            try container.encode(value, forKey: BotUIDynamicKey(key))
        }
    }

    subscript(key: String) -> BotJSONValue? { values[key] }
    var cardType: String? { self["cardType"]?.string }
    var cardKey: String? { self["cardKey"]?.string }
}

private struct BotUIDynamicKey: CodingKey, Hashable {
    var stringValue: String
    var intValue: Int?

    init(_ value: String) {
        stringValue = value
        intValue = nil
    }

    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

struct BotUIProvenance: Codable, Equatable {
    var eventIDs: [String]
    var trust: String
    var tainted: Bool
}

struct BotUIRow: Codable, Equatable, Identifiable {
    var id: String
    var botID: String
    var seq: Int
    var updatedSeq: Int
    var kind: String
    var role: String?
    var body: BotUIBody
    var provenance: BotUIProvenance
    var streaming: Bool
    var createdAt: Int
    var chatActionNonce: String? = nil

    private enum CodingKeys: String, CodingKey {
        case id, botID, seq, updatedSeq, kind, role, body, provenance, streaming, createdAt
    }

    static func fixture(id: String, botID: String = "main", seq: Int = 0,
                        kind: String = "event", role: String? = nil,
                        body: BotUIBody, eventID: String? = nil) -> BotUIRow {
        BotUIRow(id: id, botID: botID, seq: seq, updatedSeq: seq, kind: kind, role: role,
                 body: body,
                 provenance: BotUIProvenance(eventIDs: [eventID ?? "evt-\(id)"], trust: "model", tainted: false),
                 streaming: false, createdAt: 1_760_000_000_000 + seq * 1_000)
    }

    static func text(id: String, botID: String = "main", seq: Int = 0,
                     role: String, text: String, eventID: String? = nil) -> BotUIRow {
        var row = fixture(id: id, botID: botID, seq: seq, kind: role == "user" ? "sendMessage" : "message",
                          role: role, body: BotUIBody(type: "text", values: ["text": .string(text)]),
                          eventID: eventID)
        row.provenance.trust = role == "user" ? "owner_direct" : "model"
        return row
    }
}

/// One file attached to a user chat message. The durable row projection puts
/// this metadata in `body.attachments`; the composer uses the same shape for
/// the optimistic local row, so the transcript card does not wait for import.
struct BotUIAttachment: Codable, Equatable, Hashable, Identifiable, Sendable {
    var name: String
    var path: String
    var size: Int64
    var mimeType: String
    var kind: String

    var id: String { path.isEmpty ? "\(name)#\(size)" : path }

    init(name: String, path: String = "", size: Int64, mimeType: String = "", kind: String) {
        self.name = name
        self.path = path
        self.size = size
        self.mimeType = mimeType
        self.kind = kind
    }

    init(_ attachment: BotAttachment) {
        self.init(name: attachment.name, path: attachment.path, size: attachment.size,
                  mimeType: attachment.mimeType, kind: attachment.kind)
    }

    var sizeLabel: String {
        let value = max(0, size)
        if value < 1024 { return "\(value) B" }
        if value < 1024 * 1024 {
            let kb = Double(value) / 1024
            return String(format: kb < 10 ? "%.1f KB" : "%.0f KB", kb)
        }
        return String(format: "%.1f MB", Double(value) / (1024 * 1024))
    }

    /// A local file the user picked, described with the same policy the import
    /// path uses. Returns nil when the file cannot be read or is empty.
    static func local(url: URL, fallbackMIMEType: String? = nil) -> BotUIAttachment? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values?.isRegularFile != false, let size = values?.fileSize, size > 0 else { return nil }
        let name = url.lastPathComponent.isEmpty ? "file" : url.lastPathComponent
        let mimeType = fallbackMIMEType
            ?? UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        return BotUIAttachment(
            name: name, path: "",
            size: Int64(size), mimeType: mimeType,
            kind: BotAttachmentPolicy.kind(name: name, mimeType: mimeType))
    }

    var jsonValue: BotJSONValue {
        .object([
            "name": .string(name),
            "path": .string(path),
            "size": .number(Double(size)),
            "mimeType": .string(mimeType),
            "kind": .string(kind),
        ])
    }

    static func fixture(name: String, size: Int64, mimeType: String, kind: String,
                        path: String = "") -> BotUIAttachment {
        BotUIAttachment(name: name, path: path, size: size, mimeType: mimeType, kind: kind)
    }

    var iconName: String {
        switch kind {
        case "image": return "photo"
        case "audio": return "waveform"
        case "video": return "video"
        case "pdf", "document": return "doc.text"
        case "markdown", "table", "json": return "tablecells"
        case "archive": return "archivebox"
        default: return "paperclip"
        }
    }

    var kindLabel: String {
        switch kind {
        case "image": return "图片"
        case "audio": return "音频"
        case "video": return "视频"
        case "pdf": return "PDF"
        case "document": return "文档"
        case "markdown": return "Markdown"
        case "table": return "表格"
        case "json": return "JSON"
        case "archive": return "压缩包"
        default: return "文件"
        }
    }

    static func parseList(_ value: BotJSONValue?) -> [BotUIAttachment] {
        guard let items = value?.array else { return [] }
        return items.prefix(BotAttachmentPolicy.maxCount).compactMap { item in
            guard let object = item.object,
                  let name = object.string("name", "fileName"), !name.isEmpty else { return nil }
            return BotUIAttachment(
                name: name,
                path: object["path"]?.string ?? "",
                size: Int64(max(0, object["size"]?.number ?? 0)),
                mimeType: object["mimeType"]?.string ?? "",
                kind: object["kind"]?.string
                    ?? BotAttachmentPolicy.kind(name: name, mimeType: object["mimeType"]?.string ?? ""))
        }
    }
}

struct BotUIRowBatch: Codable, Equatable {
    var rows: [BotUIRow]
    var deletes: [String]
    var cursor: Int
    var reset: Bool
}

enum BotUIApprovalDecision: String, Codable {
    case allowOnce
    case always
    case deny
}

enum BotUIUserAction: Codable, Equatable {
    case chat(nonce: String, botID: String, text: String, attachments: [BotAttachment]?)
    case cardAnswer(nonce: String, botID: String, cardID: String, optionID: String)
    case cardDismiss(nonce: String, botID: String, cardID: String)
    case approval(nonce: String, botID: String, approvalID: String,
                  decision: BotUIApprovalDecision, digest: String)
    case stopTask(nonce: String, botID: String, threadID: String)

    private enum Keys: String, CodingKey {
        case nonce, botID, kind, text, cardID, optionID
        case approvalID, decision, digest, threadID, attachments
    }

    var nonce: String {
        switch self {
        case .chat(let nonce, _, _, _), .cardAnswer(let nonce, _, _, _),
             .cardDismiss(let nonce, _, _), .approval(let nonce, _, _, _, _),
             .stopTask(let nonce, _, _): nonce
        }
    }

    var botID: String {
        switch self {
        case .chat(_, let botID, _, _), .cardAnswer(_, let botID, _, _),
             .cardDismiss(_, let botID, _), .approval(_, let botID, _, _, _),
             .stopTask(_, let botID, _): botID
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        let raw = try decoder.container(keyedBy: BotUIDynamicKey.self)
        let nonce = try container.decode(String.self, forKey: .nonce)
        let botID = try container.decode(String.self, forKey: .botID)
        let kind = try container.decode(String.self, forKey: .kind)
        if kind == "cardAnswer",
           raw.contains(BotUIDynamicKey("text")) || raw.contains(BotUIDynamicKey("customText")) {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "cardAnswer must not contain text or customText; free-form replies use chat"))
        }
        switch kind {
        case "chat":
            self = .chat(nonce: nonce, botID: botID,
                          text: try container.decodeIfPresent(String.self, forKey: .text) ?? "",
                          attachments: try container.decodeIfPresent([BotAttachment].self, forKey: .attachments))
        case "cardAnswer":
            self = .cardAnswer(nonce: nonce, botID: botID,
                               cardID: try container.decode(String.self, forKey: .cardID),
                               optionID: try container.decode(String.self, forKey: .optionID))
        case "cardDismiss":
            self = .cardDismiss(nonce: nonce, botID: botID,
                                cardID: try container.decode(String.self, forKey: .cardID))
        case "approval":
            self = .approval(nonce: nonce, botID: botID,
                             approvalID: try container.decode(String.self, forKey: .approvalID),
                             decision: try container.decode(BotUIApprovalDecision.self, forKey: .decision),
                             digest: try container.decode(String.self, forKey: .digest))
        case "stopTask":
            self = .stopTask(nonce: nonce, botID: botID,
                             threadID: try container.decode(String.self, forKey: .threadID))
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container,
                                                   debugDescription: "Unknown Bot user action")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case .chat(let nonce, let botID, let text, let attachments):
            try container.encode(nonce, forKey: .nonce)
            try container.encode(botID, forKey: .botID)
            try container.encode("chat", forKey: .kind)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(attachments, forKey: .attachments)
        case .cardAnswer(let nonce, let botID, let cardID, let optionID):
            try container.encode(nonce, forKey: .nonce)
            try container.encode(botID, forKey: .botID)
            try container.encode("cardAnswer", forKey: .kind)
            try container.encode(cardID, forKey: .cardID)
            try container.encode(optionID, forKey: .optionID)
        case .cardDismiss(let nonce, let botID, let cardID):
            try container.encode(nonce, forKey: .nonce)
            try container.encode(botID, forKey: .botID)
            try container.encode("cardDismiss", forKey: .kind)
            try container.encode(cardID, forKey: .cardID)
        case .approval(let nonce, let botID, let approvalID, let decision, let digest):
            try container.encode(nonce, forKey: .nonce)
            try container.encode(botID, forKey: .botID)
            try container.encode("approval", forKey: .kind)
            try container.encode(approvalID, forKey: .approvalID)
            try container.encode(decision, forKey: .decision)
            try container.encode(digest, forKey: .digest)
        case .stopTask(let nonce, let botID, let threadID):
            try container.encode(nonce, forKey: .nonce)
            try container.encode(botID, forKey: .botID)
            try container.encode("stopTask", forKey: .kind)
            try container.encode(threadID, forKey: .threadID)
        }
    }
}

enum BotUIActionResult: Codable, Equatable {
    case accepted(eventID: String)
    case duplicate(eventID: String)
    case stale(reason: String)
    case rejected(reason: String)

    var eventID: String? {
        switch self {
        case .accepted(let eventID), .duplicate(let eventID): eventID
        default: nil
        }
    }

    var reason: String? {
        switch self {
        case .stale(let reason), .rejected(let reason): reason
        default: nil
        }
    }

    var succeeded: Bool { eventID != nil }

    private enum Keys: String, CodingKey { case status, eventID, reason }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        switch try container.decode(String.self, forKey: .status) {
        case "accepted": self = .accepted(eventID: try container.decode(String.self, forKey: .eventID))
        case "duplicate": self = .duplicate(eventID: try container.decode(String.self, forKey: .eventID))
        case "stale": self = .stale(reason: try container.decode(String.self, forKey: .reason))
        case "rejected": self = .rejected(reason: try container.decode(String.self, forKey: .reason))
        default:
            throw DecodingError.dataCorruptedError(forKey: .status, in: container,
                                                   debugDescription: "Unknown Bot action result")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case .accepted(let eventID):
            try container.encode("accepted", forKey: .status)
            try container.encode(eventID, forKey: .eventID)
        case .duplicate(let eventID):
            try container.encode("duplicate", forKey: .status)
            try container.encode(eventID, forKey: .eventID)
        case .stale(let reason):
            try container.encode("stale", forKey: .status)
            try container.encode(reason, forKey: .reason)
        case .rejected(let reason):
            try container.encode("rejected", forKey: .status)
            try container.encode(reason, forKey: .reason)
        }
    }
}

struct BotUIHistoryPage {
    var rows: [BotUIRow]
    var nextCursor: String?
    var hasMore: Bool
}

struct BotChatDriver {
    var history: (String?, Int) async throws -> BotUIHistoryPage
    var watch: (Int) async throws -> BotUIRowBatch
    var perform: (BotUIUserAction) async -> BotUIActionResult
    var stopCurrentTurn: (String?) async -> Void
    /// Tool steps of finished turns, keyed by DSH turn number.
    var turnProcesses: () async -> [Int: BotTurnProcess] = { [:] }
    /// Live frames of the running main-chat turn.
    var liveFrames: () async -> AsyncStream<BotLiveFrame> = { AsyncStream { $0.finish() } }
    /// The durable presentation (fish state + current-turn activity) projected
    /// by the runtime. Live frames refine it while a turn is running.
    var presentation: () async throws -> BotRuntimePresentation = { BotRuntimePresentation() }
}

struct BotRuntimeContext: Equatable {
    var botID: String
    var botName: String
    var followingCount: Int?

    init(botID: String, botName: String, followingCount: Int? = nil) {
        self.botID = botID
        self.botName = botName
        self.followingCount = followingCount
    }

    /// The context of the roster's main Bot pointer, never a literal id.
    static func mainBot(in roster: BotRoster) -> BotRuntimeContext? {
        guard let bot = BotMainPointerRouting.mainBot(in: roster) else { return nil }
        return BotRuntimeContext(botID: bot.id, botName: bot.name)
    }
}

struct BotDeepLink: Equatable {
    enum Destination: Equatable {
        case row(String)
        case routine(String)
    }

    var botID: String
    var destination: Destination

    var rowID: String? {
        if case .row(let id) = destination { return id }
        return nil
    }

    var routineID: String? {
        if case .routine(let id) = destination { return id }
        return nil
    }

    init?(url: URL) {
        guard url.scheme == "phonedsh", url.host == "bot" else { return nil }
        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count == 3, !components[0].isEmpty, !components[2].isEmpty else { return nil }
        botID = components[0]
        switch components[1] {
        case "row": destination = .row(components[2])
        case "routine": destination = .routine(components[2])
        default: return nil
        }
    }
}

struct BotUIChoice: Equatable, Identifiable {
    var id: String
    var label: String
    var value: String
    var description: String?
    var recommended: Bool
    var danger: Bool

    /// Mirrors dsh-bot `WidgetCard.normaliseChoice`: a bare string is a choice,
    /// and a choice without an id gets the stable `"<index>:<label>"` id, so a
    /// next-steps card from the shared card-payload golden (labels only)
    /// renders and answers exactly as on the desktop.
    static func parse(_ value: BotJSONValue, index: Int) -> BotUIChoice? {
        if let raw = value.string {
            let label = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else { return nil }
            return BotUIChoice(id: "\(index):\(label)", label: label, value: label,
                               description: nil, recommended: false, danger: false)
        }
        guard let object = value.object,
              let rawLabel = object.string("label", "text", "title", "value"),
              !rawLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let label = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let explicitID = object.string("id", "optionID") ?? ""
        let id = explicitID.isEmpty ? "\(index):\(rawLabel)" : explicitID
        let style = object["style"]?.string?.lowercased() ?? "default"
        return BotUIChoice(id: id, label: label,
                           value: object["value"]?.string ?? label,
                           description: object.string("description", "detail"),
                           recommended: (object["recommended"]?.bool == true || style == "primary") && style != "danger",
                           danger: style == "danger")
    }

    static func parseList(_ value: BotJSONValue?, limit: Int = 4) -> [BotUIChoice] {
        guard let values = value?.array else { return [] }
        var choices = values.prefix(limit).enumerated().compactMap { parse($0.element, index: $0.offset) }
        let recommendedIndex = choices.firstIndex(where: { $0.recommended && !$0.danger })
        for index in choices.indices {
            choices[index].recommended = index == recommendedIndex
        }
        return choices
    }
}

struct BotUIProgressStep: Equatable, Identifiable {
    var id: String
    var label: String
    var state: String
    var detail: String?

    static func parseList(_ value: BotJSONValue?) -> [BotUIProgressStep] {
        guard let values = value?.array else { return [] }
        let allowed = Set(["pending", "active", "done", "failed", "skipped"])
        return values.prefix(8).enumerated().compactMap { index, value in
            if let label = value.string, !label.isEmpty {
                return BotUIProgressStep(id: "step-\(index)", label: label, state: "pending", detail: nil)
            }
            guard let object = value.object,
                  let label = object.string("label", "title", "text"), !label.isEmpty else { return nil }
            let rawState = object["state"]?.string ?? object["status"]?.string ?? "pending"
            let aliases = [
                "in_progress": "active", "running": "active", "working": "active",
                "complete": "done", "completed": "done", "success": "done", "ok": "done", "sent": "done",
                "error": "failed", "failure": "failed", "blocked": "failed",
            ]
            let state = aliases[rawState] ?? rawState
            return BotUIProgressStep(id: object["id"]?.string ?? "step-\(index)", label: label,
                                     state: allowed.contains(state) ? state : "pending",
                                     detail: object.string("detail", "meta", "note"))
        }
    }
}

struct BotUIChecklistItem: Equatable, Identifiable {
    var id: String
    var text: String
    var done: Bool
    var note: String?
    var synthetic: Bool

    static func parseList(_ value: BotJSONValue?) -> [BotUIChecklistItem] {
        guard let values = value?.array else { return [] }
        return values.prefix(12).enumerated().compactMap { index, value in
            if let text = value.string, !text.isEmpty {
                return BotUIChecklistItem(id: "item-\(index)", text: text, done: false, note: nil, synthetic: false)
            }
            guard let object = value.object,
                  let text = object.string("text", "content", "label", "title"), !text.isEmpty else { return nil }
            return BotUIChecklistItem(id: object["id"]?.string ?? "item-\(index)", text: text,
                                      done: object["done"]?.bool == true,
                                      note: object.string("note", "meta", "due"),
                                      synthetic: object["synthetic"]?.bool == true)
        }
    }
}

struct BotUILink: Equatable, Identifiable {
    var id: String
    var url: URL
    var title: String
    var site: String
    var description: String?
    var kind: String

    static func parseList(_ value: BotJSONValue?) -> [BotUILink] {
        guard let values = value?.array else { return [] }
        return values.prefix(4).enumerated().compactMap { index, value in
            guard let object = value.object, let rawURL = object["url"]?.string,
                  rawURL.count <= 2_048, let url = URL(string: rawURL),
                  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  let host = url.host, !host.isEmpty else { return nil }
            let site = object["site"]?.string ?? host.replacingOccurrences(of: #"^www\."#, with: "",
                                                                            options: .regularExpression)
            return BotUILink(id: object["id"]?.string ?? "link-\(index)", url: url,
                             title: object.string("title", "name", "label") ?? site,
                             site: site, description: object.string("description", "summary", "note"),
                             kind: object["kind"]?.string ?? "other")
        }
    }
}

enum BotUICardKind: String {
    case question, steps, task, attachment, document, progress, checklist, link
    case approval, automation, notice
}

struct BotUICardContent {
    var kind: BotUICardKind
    var body: BotUIBody

    static func parse(row: BotUIRow) -> BotUICardContent? {
        let body = row.body
        switch body.type {
        case "widget":
            guard let rawKind = body.cardType, let kind = BotUICardKind(rawValue: rawKind),
                  [.question, .steps, .task, .document, .progress, .checklist, .link].contains(kind) else { return nil }
            return valid(kind: kind, body: body) ? BotUICardContent(kind: kind, body: body) : nil
        case "attachment":
            if let declared = body.cardType, declared != "attachment" { return nil }
            return valid(kind: .attachment, body: body) ? BotUICardContent(kind: .attachment, body: body) : nil
        case "approval":
            return valid(kind: .approval, body: body) ? BotUICardContent(kind: .approval, body: body) : nil
        case "automation":
            return valid(kind: .automation, body: body) ? BotUICardContent(kind: .automation, body: body) : nil
        case "notice":
            return valid(kind: .notice, body: body) ? BotUICardContent(kind: .notice, body: body) : nil
        default:
            return nil
        }
    }

    private static func valid(kind: BotUICardKind, body: BotUIBody) -> Bool {
        switch kind {
        case .question, .steps:
            let choices = BotUIChoice.parseList(body[kind == .question ? "options" : "steps"])
            let prompt = body.string("question", "prompt", "helpText", "help") ?? ""
            return !choices.isEmpty || !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .task:
            let title = body.string("title", "text", "question") ?? ""
            let steps = body["tasks"]?.array ?? body["steps"]?.array ?? []
            return !title.isEmpty || !steps.isEmpty
        case .attachment:
            return !(body.string("fileName", "name", "path") ?? "").isEmpty
        case .document:
            return !(body.string("title", "name", "fileName", "path", "url", "summary", "content") ?? "").isEmpty
        case .progress:
            return !(body["title"]?.string ?? body["name"]?.string ?? "").isEmpty
        case .checklist:
            return !(body["title"]?.string ?? "").isEmpty && !BotUIChecklistItem.parseList(body["items"]).isEmpty
        case .link:
            return !BotUILink.parseList(body["links"]).isEmpty
        case .approval:
            let status = body["status"]?.string ?? body["ask"]?.object?["status"]?.string ?? "pending"
            let action = body.string("action", "title", "text") ?? body["ask"]?.object?["action"]?.string ?? ""
            if status == "pending" {
                let id = body.string("approvalID", "requestId", "id") ?? body["ask"]?.object?["requestId"]?.string
                let digest = body["digest"]?.string
                return id?.isEmpty == false && digest?.isEmpty == false && !action.isEmpty
            }
            return !action.isEmpty
        case .automation:
            let name = body.string("title", "name", "automationId") ?? body["automation"]?.object?.string("name", "automationId")
            return name?.isEmpty == false
        case .notice:
            let tone = body["tone"]?.string ?? "error"
            return ["error", "denied", "denial"].contains(tone)
                && !(body["text"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

enum BotUIRendering {
    static func isRenderable(_ row: BotUIRow) -> Bool {
        if row.body.type == "deleted" { return false }
        if row.body.type == "text" {
            let hasText = !(row.body["text"]?.string ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasAttachments = row.role == "user"
                && !BotUIAttachment.parseList(row.body["attachments"]).isEmpty
            return ["message", "sendMessage"].contains(row.kind)
                && ["user", "assistant"].contains(row.role ?? "")
                && (hasText || hasAttachments)
        }
        return BotUICardContent.parse(row: row) != nil
    }

    static func surface(_ row: BotUIRow) -> String {
        if isRenderable(row) == false { return "hidden" }
        if row.body.type == "text" { return "bubble" }
        guard let kind = BotUICardContent.parse(row: row)?.kind else { return "hidden" }
        switch kind {
        case .question, .steps: return "widget-card"
        case .task: return "agent-thread-row"
        case .attachment: return "attachment-card"
        case .document: return "document-card"
        case .progress: return "progress-card"
        case .checklist: return "checklist-card"
        case .link: return "link-card"
        case .approval: return "approval-card"
        case .automation: return "automation-row"
        case .notice: return "notice"
        }
    }

    static func copyText(_ row: BotUIRow) -> String {
        if let text = row.body["text"]?.string, !text.isEmpty { return text }
        return row.body.string("title", "question", "prompt", "name", "fileName", "path", "summary") ?? row.id
    }
}

extension BotUIBody {
    func string(_ keys: String...) -> String? {
        for key in keys {
            if let value = self[key]?.string, !value.isEmpty { return value }
        }
        return nil
    }
}

extension Dictionary where Key == String, Value == BotJSONValue {
    func string(_ keys: String...) -> String? {
        for key in keys {
            if let value = self[key]?.string, !value.isEmpty { return value }
        }
        return nil
    }
}
