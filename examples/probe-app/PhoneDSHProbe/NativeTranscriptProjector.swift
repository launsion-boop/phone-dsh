// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSHAgentCore

// Durable DSH journal events to native presentation facts.
enum NativeTranscriptProjector {
    static func items(from records: [JSONValue], sessionID: String) -> [ChatItem] {
        var result: [ChatItem] = []
        var calls: [String: Int] = [:]
        for event in records {
            guard let seq = event["seq"]?.intValue,
                  let type = event["type"]?.stringValue else { continue }
            let data = event["data"] ?? .null
            let id = "\(sessionID):\(seq)"
            let time = event["time"]?.numberValue.map { Date(timeIntervalSince1970: $0 / 1_000) }
            let turn = data["turn"]?.intValue
            let step = data["step"]?.intValue
            switch type {
            case "user/message", "agent/steering/message":
                let content = data["content"]
                let text = nativeText(content, includeImages: false)
                let attachments = nativeAttachments(content)
                guard !text.isEmpty || !attachments.isEmpty else { continue }
                let kind: ChatItem.Kind
                let title: String
                if type == "agent/steering/message" {
                    kind = .user
                    title = "You (steering)"
                } else {
                    switch DSHMessageSourceClassifier.classify(data) {
                    case .user:
                        kind = .user
                        title = "You"
                    case .context(let source):
                        kind = .context
                        title = "DSH context · \(source)"
                    }
                }
                var item = ChatItem(id: id, kind: kind, title: title, text: text)
                item.timestamp = time
                item.turn = turn
                item.step = step
                item.attachments = attachments
                result.append(item)
            case "assistant/message":
                let message = data["message"] ?? .null
                let usage = NativeTurnUsage(value: data["usage"])
                for (index, block) in (message["content"]?.arrayValue ?? []).enumerated() {
                    let blockType = block["type"]?.stringValue ?? "unknown"
                    let kind: ChatItem.Kind
                    let text: String
                    switch blockType {
                    case "text": kind = .assistant; text = block["text"]?.stringValue ?? ""
                    case "reasoning": kind = .reasoning; text = block["text"]?.stringValue ?? ""
                    case "image": kind = .image; text = ""
                    case "tool-call": continue
                    default: kind = .unknown; text = nativeJSON(block)
                    }
                    guard kind == .image || kind == .unknown || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    var item = ChatItem(id: "\(id):block-\(index)", kind: kind,
                                        title: kind == .reasoning ? "思考" : "Assistant", text: text)
                    item.timestamp = time
                    item.messageID = message["id"]?.stringValue
                    item.turn = turn
                    item.step = step
                    item.turnUsage = usage
                    item.rawBlock = block
                    if kind == .image { item.attachments = nativeAttachments(.array([block])) }
                    result.append(item)
                }
            case "tool/call":
                let callID = data["callId"]?.stringValue ?? ""
                let name = data["name"]?.stringValue ?? "tool"
                let raw = data["arguments"]?.stringValue ?? nativeJSON(data["arguments"])
                let arguments = raw.data(using: .utf8).flatMap { try? JSONValue.parse($0) } ?? data["arguments"]
                var item = ChatItem(id: id, kind: .toolCall, title: "Tool call: \(name)", text: nativeJSON(arguments))
                item.timestamp = time
                item.turn = turn
                item.step = step
                item.callID = callID
                item.toolName = name
                item.argumentsRaw = raw
                item.arguments = arguments
                item.toolState = .running
                if !callID.isEmpty { calls[callID] = result.count }
                result.append(item)
            case "tool/result":
                let message = data["message"] ?? .null
                let callID = message["toolCallId"]?.stringValue ?? message["source"]?["callId"]?.stringValue ?? ""
                let output = nativeToolResultText(message["content"], error: data["error"])
                let isError = message["isError"]?.boolValue ?? (data["error"] != nil)
                if let index = calls[callID] {
                    result[index].toolOutput = output
                    result[index].toolMetadata = data["meta"]
                    result[index].toolState = isError ? .error : .ok
                    if data["error"]?["code"]?.stringValue == "interrupted" { result[index].toolState = .stopped }
                } else {
                    var item = ChatItem(id: id, kind: .toolResult(isError: isError),
                                        title: isError ? "Tool error" : "Tool result", text: output)
                    item.timestamp = time
                    item.turn = turn
                    item.step = step
                    item.callID = callID
                    item.toolName = message["source"]?["name"]?.stringValue
                    item.toolOutput = output
                    item.toolMetadata = data["meta"]
                    item.toolState = isError ? .error : .ok
                    result.append(item)
                }
            case "turn/end":
                let reason = data["reason"]
                if reason?["kind"]?.stringValue == "max-tokens" {
                    var item = ChatItem(id: id, kind: .maxTokens, title: "已达到输出 token 上限",
                                        text: "回答被截断，已有输出保留在对话中。发送“继续”可让模型接着输出。")
                    item.timestamp = time
                    item.turn = turn
                    result.append(item)
                } else if reason?["kind"]?.stringValue == "error" {
                    var item = ChatItem(id: id, kind: .turnError, title: "本轮执行失败",
                                        text: reason?["error"]?["message"]?.stringValue ?? "模型服务出错了")
                    item.timestamp = time
                    item.turn = turn
                    result.append(item)
                }
                if ["aborted", "interrupted", "error"].contains(reason?["kind"]?.stringValue ?? "") {
                    for index in result.indices where result[index].turn == turn && result[index].toolState == .running {
                        result[index].toolState = .stopped
                    }
                }
            case "llm/retry", "llm/retry-started":
                var item = ChatItem(id: id, kind: .systemEvent, title: "模型请求重试",
                                    text: data["failure"]?["message"]?.stringValue ?? data["reason"]?.stringValue ?? "正在重试模型请求")
                item.timestamp = time
                item.turn = turn
                item.step = step
                result.append(item)
            case let value where value.hasPrefix("compaction/"):
                var item = ChatItem(id: id, kind: .systemEvent, title: "上下文已整理",
                                    text: data["summary"]?.stringValue ?? "较早的对话已整理为摘要。")
                item.timestamp = time
                item.turn = turn
                result.append(item)
            default:
                continue
            }
        }
        return result
    }

    static func changes(forTurn turn: Int, in items: [ChatItem]) -> NativeChangedFiles? {
        var files: [NativeChangedFile] = []
        var positions: [String: Int] = [:]
        for item in items where item.turn == turn && item.kind == .toolCall && item.toolState == .ok {
            guard let name = item.toolName, ["write", "edit", "str_replace_editor"].contains(name),
                  let args = item.arguments?.objectValue else { continue }
            let path = (args["file_path"] ?? args["path"])?.stringValue ?? ""
            guard !path.isEmpty else { continue }
            var oldText: String?
            var newText: String?
            if name == "write" {
                newText = args["content"]?.stringValue
            } else if name == "edit" {
                oldText = args["old_string"]?.stringValue
                newText = args["new_string"]?.stringValue
            } else {
                switch args["command"]?.stringValue {
                case "create": newText = args["file_text"]?.stringValue ?? ""
                case "str_replace": oldText = args["old_str"]?.stringValue; newText = args["new_str"]?.stringValue ?? ""
                case "insert": newText = args["new_str"]?.stringValue
                default: break
                }
            }
            if let diffs = item.toolMetadata?["diffs"]?.arrayValue, let first = diffs.first {
                oldText = first["oldText"]?.stringValue
                newText = first["newText"]?.stringValue
            }
            guard let newText else { continue }
            let counts = nativeLineCounts(old: oldText, new: newText)
            let display = item.toolMetadata?["path"]?.stringValue ?? path
            let file = NativeChangedFile(path: path, display: display, added: counts.added,
                                         deleted: counts.deleted, oldText: oldText, newText: newText)
            if let index = positions[path] { files[index] = file } else {
                positions[path] = files.count
                files.append(file)
            }
        }
        return files.isEmpty ? nil : NativeChangedFiles(files: files)
    }

    static func usage(forTurn turn: Int, in items: [ChatItem]) -> NativeTurnUsage? {
        var total: NativeTurnUsage?
        var settledMessages = Set<String>()
        for item in items where item.turn == turn {
            guard let usage = item.turnUsage else { continue }
            if let messageID = item.messageID {
                guard settledMessages.insert(messageID).inserted else { continue }
            }
            if total == nil { total = usage } else { total?.add(usage) }
        }
        return total
    }

    private static func nativeAttachments(_ content: JSONValue?) -> [NativeMessageAttachment] {
        (content?.arrayValue ?? []).compactMap { block in
            guard let type = block["type"]?.stringValue else { return nil }
            let kind: NativeMessageAttachment.Kind
            switch type {
            case "image": kind = .image
            case "file": kind = .file
            default: return nil
            }
            let attachment = block["attachment"] ?? .null
            let name = attachment["name"]?.stringValue ?? attachment["path"]?.stringValue
                ?? block["name"]?.stringValue ?? (kind == .image ? "图片" : "文件")
            let path = attachment["path"]?.stringValue ?? block["path"]?.stringValue
            return NativeMessageAttachment(kind: kind, name: name, path: path,
                                           mimeType: attachment["mediaType"]?.stringValue,
                                           payload: attachment)
        }
    }

    private static func nativeToolResultText(_ content: JSONValue?, error: JSONValue?) -> String {
        var parts: [String] = []
        for block in content?.arrayValue ?? [] {
            if block["type"]?.stringValue == "text" { parts.append(block["text"]?.stringValue ?? "") }
            else { parts.append(nativePrettyJSON(block)) }
        }
        if parts.isEmpty, let reason = error?["reason"]?.stringValue { parts.append(reason) }
        if parts.isEmpty, let name = error?["name"]?.stringValue {
            parts.append("\(name): \(error?["code"]?.stringValue ?? "error")")
        }
        return parts.joined(separator: "\n")
    }

    private static func nativeLineCounts(old: String?, new: String) -> (added: Int, deleted: Int) {
        let oldLines = (old ?? "").components(separatedBy: .newlines)
        let newLines = new.components(separatedBy: .newlines)
        var table = Array(repeating: Array(repeating: 0, count: newLines.count + 1), count: oldLines.count + 1)
        if oldLines.count > 0, newLines.count > 0 {
            for i in stride(from: oldLines.count - 1, through: 0, by: -1) {
                for j in stride(from: newLines.count - 1, through: 0, by: -1) {
                    table[i][j] = oldLines[i] == newLines[j]
                        ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
                }
            }
        }
        let common = table[0][0]
        return (newLines.count - common, oldLines.count - common)
    }
}

func nativeText(_ content: JSONValue?, includeImages: Bool = true) -> String {
    (content?.arrayValue ?? []).compactMap { block in
        switch block["type"]?.stringValue {
        case "text": return block["text"]?.stringValue
        case "image" where includeImages: return "[图片]"
        default: return nil
        }
    }.joined()
}

func nativeJSON(_ value: JSONValue?) -> String {
    guard let value, let data = try? value.encoded() else { return "" }
    return String(data: data, encoding: .utf8) ?? ""
}

func nativePrettyJSON(_ value: JSONValue?) -> String {
    guard let value, let data = try? value.encoded(),
          let object = try? JSONSerialization.jsonObject(with: data),
          let pretty = try? JSONSerialization.data(withJSONObject: object,
                                                   options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
        return nativeJSON(value)
    }
    return String(data: pretty, encoding: .utf8) ?? nativeJSON(value)
}
