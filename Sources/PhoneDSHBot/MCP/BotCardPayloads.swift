// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation

public enum BotCardPayloadError: Error, Sendable, Equatable {
    case invalid(String)
}

public enum BotCardPayloads {
    public static func build(tool: String, arguments: BotJSONValue) throws -> BotJSONValue {
        guard case .object(let args) = arguments else { throw BotCardPayloadError.invalid("arguments must be an object") }
        _ = try contentCardFinal(tool: tool, arguments: arguments)
        let card: BotJSONValue
        switch tool {
        case "ask_user": card = try question(args)
        case "show_next_steps": card = try steps(args)
        case "show_attachment": card = try attachment(args)
        case "show_document": card = try document(args)
        case "show_progress": card = try progress(args)
        case "show_checklist": card = try checklist(args)
        case "show_link": card = try links(args)
        default: throw BotCardPayloadError.invalid("unknown or non-P0 card tool: \(tool)")
        }
        return .object(["ok": .bool(true), "card": card])
    }

    /// P26: `final` is input-only control metadata. It is validated as a JSON
    /// boolean and intentionally stripped from the card payload, so every
    /// existing `card.presented`/golden byte stays unchanged. Tools without the
    /// flag (including ask_user/show_next_steps) always return false.
    public static func contentCardFinal(tool: String, arguments: BotJSONValue) throws -> Bool {
        guard BotToolCatalog.contentCardNames.contains(tool) else { return false }
        guard case .object(let args) = arguments else {
            throw BotCardPayloadError.invalid("arguments must be an object")
        }
        guard let raw = args["final"] else { return false }
        guard case .bool(let flag) = raw else {
            throw BotCardPayloadError.invalid("final 必须是 boolean。")
        }
        return flag
    }

    private static func question(_ args: [String: BotJSONValue]) throws -> BotJSONValue {
        let question = try requiredString(args, "question")
        let rawOptions = try requiredArray(args, "options")
        guard (2...4).contains(rawOptions.count) else { throw BotCardPayloadError.invalid("ask_user 需要 2–4 个 options。") }
        let options = try rawOptions.enumerated().compactMap { index, value -> BotJSONValue? in
            let option = try normalizedChoice(value, path: "options[\(index)]")
            return isSyntheticOther(option) ? nil : .object(option)
        }
        guard (2...4).contains(options.count) else { throw BotCardPayloadError.invalid("ask_user 需要 2–4 个有效 options。") }
        var card: [String: BotJSONValue] = [
            "cardType": .string("question"), "question": .string(question),
            "options": .array(assignOptionIDs(normalizeRecommendations(options))),
        ]
        if let help = try optionalString(args, "helpText") { card["helpText"] = .string(help) }
        return .object(card)
    }

    private static func steps(_ args: [String: BotJSONValue]) throws -> BotJSONValue {
        let rawSteps = try requiredArray(args, "steps")
        guard (2...4).contains(rawSteps.count) else { throw BotCardPayloadError.invalid("show_next_steps 需要 2–4 个 steps。") }
        let steps = try rawSteps.enumerated().compactMap { index, value -> BotJSONValue? in
            if case .string(let rawLabel) = value {
                let label = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !label.isEmpty else { throw BotCardPayloadError.invalid("steps[\(index)] 不能为空。") }
                let step: [String: BotJSONValue] = ["label": .string(label)]
                return isSyntheticOther(step) ? nil : .object(step)
            }
            let step = try normalizedChoice(value, path: "steps[\(index)]")
            return isSyntheticOther(step) ? nil : .object(step)
        }
        guard (2...4).contains(steps.count) else { throw BotCardPayloadError.invalid("show_next_steps 需要 2–4 个有效 steps。") }
        return .object(["cardType": .string("steps"),
                        "steps": .array(assignOptionIDs(normalizeRecommendations(steps)))])
    }

    private static func normalizedChoice(_ value: BotJSONValue, path: String) throws -> [String: BotJSONValue] {
        let raw = try object(value, path: path)
        var normalized: [String: BotJSONValue] = ["label": .string(try requiredString(raw, "label"))]
        if let value = try optionalString(raw, "value") { normalized["value"] = .string(value) }
        if let description = try optionalString(raw, "description") { normalized["description"] = .string(description) }
        if let rawStyle = raw["style"] {
            guard case .string(let style) = rawStyle else { throw BotCardPayloadError.invalid("\(path).style 不合法。") }
            let lowered = style.lowercased()
            normalized["style"] = .string(["primary", "default", "danger"].contains(lowered) ? lowered : "default")
        }
        if bool(raw["recommended"]) == true { normalized["recommended"] = .bool(true) }
        return normalized
    }

    private static func normalizeRecommendations(_ values: [BotJSONValue]) -> [BotJSONValue] {
        let first = values.firstIndex { value in
            guard case .object(let choice) = value else { return false }
            return string(choice["style"]) != "danger"
                && (bool(choice["recommended"]) == true || string(choice["style"]) == "primary")
        }
        var ordered = values
        if let first {
            let recommended = ordered.remove(at: first)
            ordered.insert(recommended, at: 0)
        }
        return ordered.enumerated().map { index, value in
            guard case .object(var choice) = value else { return value }
            if index == 0, first != nil {
                choice["recommended"] = .bool(true)
            } else {
                choice.removeValue(forKey: "recommended")
                if string(choice["style"]) == "primary" { choice["style"] = .string("default") }
            }
            return .object(choice)
        }
    }

    /// The host owns option identity: models only supply labels, values, styles and prose.
    /// Numbering happens after normalization so the first rendered choice is always `o0`.
    private static func assignOptionIDs(_ values: [BotJSONValue]) -> [BotJSONValue] {
        values.enumerated().map { index, value in
            guard case .object(var choice) = value else { return value }
            choice["id"] = .string("o\(index)")
            return .object(choice)
        }
    }

    private static func isSyntheticOther(_ choice: [String: BotJSONValue]) -> Bool {
        guard let label = string(choice["label"])?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }
        return ["其他", "其它", "other"].contains(label)
    }

    private static func attachment(_ args: [String: BotJSONValue]) throws -> BotJSONValue {
        let path = try requiredString(args, "path")
        var card: [String: BotJSONValue] = ["cardType": .string("attachment"), "path": .string(path)]
        if let caption = try optionalString(args, "caption") { card["caption"] = .string(caption) }
        return .object(card)
    }

    private static func document(_ args: [String: BotJSONValue]) throws -> BotJSONValue {
        let path = try optionalString(args, "path")
        let content = try optionalString(args, "content")
        guard path != nil || content != nil else {
            throw BotCardPayloadError.invalid("show_document 需要 path 或 content。")
        }
        let title = try optionalString(args, "title")
            ?? path.map { ($0 as NSString).lastPathComponent }
            ?? firstHeading(content ?? "") ?? "文档"
        let kind = try optionalString(args, "kind") ?? (path?.lowercased().hasSuffix(".pdf") == true ? "pdf" : "markdown")
        let labels = [
            "document": "文档", "markdown": "Markdown", "table": "表格",
            "pdf": "PDF", "code": "代码", "library": "文件库",
        ]
        var card: [String: BotJSONValue] = [
            "cardType": .string("document"),
            "title": .string(title),
            "docKind": .string(kind),
            "docTypeLabel": .string(try optionalString(args, "kindLabel") ?? labels[kind] ?? kind),
        ]
        if let summary = try optionalString(args, "summary") { card["summary"] = .string(summary) }
        if let path { card["path"] = .string(path) }
        if let content { card["content"] = .string(content) }
        if let fileName = try optionalString(args, "fileName") {
            card["fileName"] = .string(fileName)
        } else if let path {
            card["fileName"] = .string((path as NSString).lastPathComponent)
        }
        if let size = try optionalString(args, "size") { card["size"] = .string(size) }
        if let rawTOC = args["toc"] {
            guard case .array(let values) = rawTOC else { throw BotCardPayloadError.invalid("toc 必须是字符串数组。") }
            let toc = try values.map { value -> String in
                guard case .string(let heading) = value, !heading.isEmpty else {
                    throw BotCardPayloadError.invalid("toc 必须是字符串数组。")
                }
                return heading
            }
            card["toc"] = .array(Array(toc.prefix(6)).map(BotJSONValue.string))
        } else if let headings = markdownHeadings(content ?? "") {
            card["toc"] = .array(headings)
        }
        if let parse = args["parseHeadings"] { card["parseHeadings"] = .bool(try boolean(parse, path: "parseHeadings")) }
        return .object(card)
    }

    private static func progress(_ args: [String: BotJSONValue]) throws -> BotJSONValue {
        guard let title = try optionalString(args, "title") else {
            throw BotCardPayloadError.invalid("show_progress 需要 title。")
        }
        guard title.utf16.count <= 80 else { throw BotCardPayloadError.invalid("show_progress title 最多 80 字。") }
        let state = try optionalString(args, "state") ?? "running"
        guard ["running", "done", "paused", "failed", "cancelled"].contains(state) else {
            throw BotCardPayloadError.invalid("show_progress state 不合法。")
        }
        var steps: [BotJSONValue] = []
        if let raw = args["steps"] {
            guard case .array(let values) = raw, values.count <= 8 else {
                throw BotCardPayloadError.invalid("show_progress steps 最多 8 项。")
            }
            steps = try values.enumerated().map { index, value in
                var step = try object(value, path: "steps[\(index)]")
                let label = try requiredString(step, "label")
                let stepState = string(step["state"]) ?? "pending"
                guard ["pending", "active", "done", "failed", "skipped"].contains(stepState) else {
                    throw BotCardPayloadError.invalid("steps[\(index)].state 不合法。")
                }
                var normalized: [String: BotJSONValue] = [
                    "id": .string("step-\(index)"), "label": .string(label), "state": .string(stepState),
                ]
                if let detail = try optionalString(step, "detail") { normalized["detail"] = .string(detail) }
                step = normalized
                return .object(normalized)
            }
        }
        if !steps.contains(where: { string($0["state"]) == "active" }),
           let firstPending = steps.firstIndex(where: { string($0["state"]) == "pending" }) {
            var step = try object(steps[firstPending], path: "steps")
            step["state"] = .string("active")
            steps[firstPending] = .object(step)
        }
        let percent: Int
        if let explicit = args["percent"] {
            let value = try integer(explicit, path: "percent")
            guard (0...100).contains(value) else { throw BotCardPayloadError.invalid("percent 必须在 0…100。") }
            percent = value
        } else if state == "done" {
            percent = 100
        } else if !steps.isEmpty {
            let complete = steps.filter { ["done", "skipped"].contains(string($0["state"]) ?? "") }.count
            percent = Int((Double(complete) / Double(steps.count) * 100).rounded())
        } else {
            percent = 0
        }
        let cardKey = try optionalString(args, "cardKey") ?? "progress:" + digest(title)
        guard cardKey.utf16.count <= 64, !cardKey.isEmpty else {
            throw BotCardPayloadError.invalid("cardKey 最多 64 字且不能为空。")
        }
        var card: [String: BotJSONValue] = [
            "cardType": .string("progress"), "title": .string(title), "state": .string(state),
            "cardKey": .string(cardKey), "percent": .number(Double(state == "done" ? 100 : percent)),
        ]
        if !steps.isEmpty { card["steps"] = .array(steps) }
        if let summary = try optionalString(args, "summary") { card["summary"] = .string(summary) }
        if let eta = try optionalString(args, "eta") { card["eta"] = .string(eta) }
        return .object(card)
    }

    private static func checklist(_ args: [String: BotJSONValue]) throws -> BotJSONValue {
        let title = try requiredString(args, "title")
        let values = try requiredArray(args, "items")
        guard (1...12).contains(values.count) else { throw BotCardPayloadError.invalid("show_checklist 需要 1–12 个 items。") }
        let items = try values.enumerated().map { index, value -> BotJSONValue in
            let item = try object(value, path: "items[\(index)]")
            let text = try requiredString(item, "text")
            var normalized: [String: BotJSONValue] = [
                "id": .string("item-\(index)"), "text": .string(text),
                "done": .bool(bool(item["done"]) ?? false),
            ]
            if let note = try optionalString(item, "note") { normalized["note"] = .string(note) }
            return .object(normalized)
        }
        var card: [String: BotJSONValue] = [
            "cardType": .string("checklist"), "title": .string(title), "items": .array(items),
        ]
        if let summary = try optionalString(args, "summary") { card["summary"] = .string(summary) }
        if let interactive = args["interactive"] {
            card["interactive"] = .bool(try boolean(interactive, path: "interactive"))
        }
        return .object(card)
    }

    private static func links(_ args: [String: BotJSONValue]) throws -> BotJSONValue {
        let values = try requiredArray(args, "links")
        guard values.count <= 4 else { throw BotCardPayloadError.invalid("show_link 最多 4 个 links。") }
        let links = try values.enumerated().compactMap { index, value -> BotJSONValue? in
            let link = try object(value, path: "links[\(index)]")
            guard let raw = string(link["url"]), let url = URL(string: raw),
                  let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
                  url.host != nil, raw.utf16.count <= 2_048 else { return nil }
            let site = string(link["site"]) ?? url.host!
            var normalized: [String: BotJSONValue] = [
                "url": .string(raw), "title": .string(string(link["title"]) ?? site), "site": .string(site),
                "kind": .string(string(link["kind"]) ?? "other"),
            ]
            if let description = try optionalString(link, "description") {
                normalized["description"] = .string(description)
            }
            return .object(normalized)
        }
        guard !links.isEmpty else {
            throw BotCardPayloadError.invalid("show_link 需要至少一個合法的 http(s) links[] {url}。")
        }
        var card: [String: BotJSONValue] = ["cardType": .string("link"), "links": .array(links)]
        if let title = try optionalString(args, "title") { card["title"] = .string(title) }
        return .object(card)
    }

    private static func requiredString(_ object: [String: BotJSONValue], _ key: String) throws -> String {
        guard let value = try optionalString(object, key) else {
            throw BotCardPayloadError.invalid("\(key) 不能为空。")
        }
        return value
    }

    private static func optionalString(_ object: [String: BotJSONValue], _ key: String) throws -> String? {
        guard let raw = object[key] else { return nil }
        guard case .string(let value) = raw else { throw BotCardPayloadError.invalid("\(key) 必须是字符串。") }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func requiredArray(_ object: [String: BotJSONValue], _ key: String) throws -> [BotJSONValue] {
        guard case .array(let values)? = object[key] else { throw BotCardPayloadError.invalid("\(key) 必须是数组。") }
        return values
    }

    private static func object(_ value: BotJSONValue, path: String) throws -> [String: BotJSONValue] {
        guard case .object(let object) = value else { throw BotCardPayloadError.invalid("\(path) 必须是对象。") }
        return object
    }

    private static func string(_ value: BotJSONValue?) -> String? {
        guard case .string(let text)? = value else { return nil }
        return text
    }

    private static func bool(_ value: BotJSONValue?) -> Bool? {
        guard case .bool(let flag)? = value else { return nil }
        return flag
    }

    private static func boolean(_ value: BotJSONValue, path: String) throws -> Bool {
        guard case .bool(let flag) = value else { throw BotCardPayloadError.invalid("\(path) 必须是 boolean。") }
        return flag
    }

    private static func integer(_ value: BotJSONValue, path: String) throws -> Int {
        guard case .number(let number) = value, number.isFinite, number.rounded() == number else {
            throw BotCardPayloadError.invalid("\(path) 必须是整数。")
        }
        return Int(number)
    }

    private static func firstHeading(_ markdown: String) -> String? {
        markdownHeadings(markdown)?.first?.stringValue
    }

    private static func markdownHeadings(_ markdown: String) -> [BotJSONValue]? {
        let headings = markdown.split(whereSeparator: \.isNewline).compactMap { line -> BotJSONValue? in
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("#") else { return nil }
            let value = text.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : .string(value)
        }
        return headings.isEmpty ? nil : Array(headings.prefix(6))
    }

    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24).description
    }
}

private extension BotJSONValue {
    subscript(key: String) -> BotJSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }
}
