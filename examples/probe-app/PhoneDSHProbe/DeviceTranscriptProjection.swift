// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSHAgentCore

struct DeviceTranscriptItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case user, device, context, assistant, reasoning, image, toolCall
        case toolResult(isError: Bool)
        case systemEvent, turnError, maxTokens, unknown, status
    }

    enum ToolState: Equatable {
        case running, ok, error, stopped
    }

    struct Attachment: Equatable {
        var name: String
        var isImage: Bool
    }

    let id: String
    let kind: Kind
    var title: String
    var text: String
    var streaming = false
    var timestamp: Date?
    var turn: Int?
    var step: Int?
    var callID: String?
    var toolName: String?
    var argumentsRaw: String?
    var arguments: JSONValue?
    var toolOutput: String?
    var toolState: ToolState?
    var attachments: [Attachment] = []

    init(id: String = UUID().uuidString, kind: Kind, title: String, text: String, streaming: Bool = false) {
        self.id = id
        self.kind = kind
        self.title = title
        self.text = text
        self.streaming = streaming
    }
}

enum DeviceTranscriptProjector {
    static func items(from records: [JSONValue], sessionID: String) -> [DeviceTranscriptItem] {
        var result: [DeviceTranscriptItem] = []
        var calls: [String: Int] = [:]
        for event in records {
            guard let seq = event["seq"]?.intValue, let type = event["type"]?.stringValue else { continue }
            let data = event["data"] ?? .null
            let id = "\(sessionID):\(seq)"
            let time = event["time"]?.numberValue.map { Date(timeIntervalSince1970: $0 / 1_000) }
            let turn = data["turn"]?.intValue
            let step = data["step"]?.intValue
            switch type {
            case "user/message", "agent/steering/message":
                let content = data["content"]
                let text = deviceText(content)
                let attachments = deviceAttachments(content)
                guard !text.isEmpty || !attachments.isEmpty else { continue }
                let isDevice = Self.isDeviceOrigin(data)
                let isContext: Bool
                if type == "agent/steering/message" {
                    isContext = false
                } else if isDevice {
                    isContext = false
                } else if case .context = DSHMessageSourceClassifier.classify(data) {
                    isContext = true
                } else {
                    isContext = false
                }
                let kind: DeviceTranscriptItem.Kind = isDevice ? .device : (isContext ? .context : .user)
                let title: String = isDevice ? "设备" : (isContext ? "设备上下文" : "你")
                var item = DeviceTranscriptItem(id: id, kind: kind, title: title, text: text)
                item.timestamp = time
                item.turn = turn
                item.step = step
                item.attachments = attachments
                result.append(item)
            case "assistant/message":
                for (index, block) in (data["message"]?["content"]?.arrayValue ?? []).enumerated() {
                    let blockType = block["type"]?.stringValue ?? "unknown"
                    let kind: DeviceTranscriptItem.Kind
                    let text: String
                    switch blockType {
                    case "text": kind = .assistant; text = block["text"]?.stringValue ?? ""
                    case "reasoning": kind = .reasoning; text = block["text"]?.stringValue ?? ""
                    case "image": kind = .image; text = ""
                    case "tool-call": continue
                    default: kind = .unknown; text = deviceJSON(block)
                    }
                    guard kind == .image || kind == .unknown || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    var item = DeviceTranscriptItem(id: "\(id):block-\(index)", kind: kind,
                                                    title: kind == .reasoning ? "思考" : "Assistant", text: text)
                    item.timestamp = time
                    item.turn = turn
                    item.step = step
                    if kind == .image { item.attachments = deviceAttachments(.array([block])) }
                    result.append(item)
                }
            case "tool/call":
                let callID = data["callId"]?.stringValue ?? ""
                let name = data["name"]?.stringValue ?? "tool"
                let raw = data["arguments"]?.stringValue ?? deviceJSON(data["arguments"])
                let arguments = raw.data(using: .utf8).flatMap { try? JSONValue.parse($0) } ?? data["arguments"]
                var item = DeviceTranscriptItem(id: id, kind: .toolCall, title: name, text: deviceJSON(arguments))
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
                let output = deviceToolResultText(message["content"], error: data["error"])
                let isError = message["isError"]?.boolValue ?? (data["error"] != nil)
                if let index = calls[callID] {
                    result[index].toolOutput = output
                    result[index].toolState = data["error"]?["code"]?.stringValue == "interrupted" ? .stopped : (isError ? .error : .ok)
                } else {
                    var item = DeviceTranscriptItem(id: id, kind: .toolResult(isError: isError),
                                                    title: isError ? "工具失败" : "工具结果", text: output)
                    item.timestamp = time
                    item.turn = turn
                    item.step = step
                    item.callID = callID
                    item.toolName = message["source"]?["name"]?.stringValue
                    item.toolOutput = output
                    item.toolState = isError ? .error : .ok
                    result.append(item)
                }
            case "turn/end":
                let reason = data["reason"]
                if reason?["kind"]?.stringValue == "max-tokens" {
                    result.append(DeviceTranscriptItem(id: id, kind: .maxTokens, title: "输出已达到上限",
                                                       text: "回答被截断；请在设备上继续处理。"))
                } else if reason?["kind"]?.stringValue == "error" {
                    result.append(DeviceTranscriptItem(id: id, kind: .turnError, title: "本轮执行失败",
                                                       text: reason?["error"]?["message"]?.stringValue ?? "模型服务出错了"))
                }
                if ["aborted", "interrupted", "error"].contains(reason?["kind"]?.stringValue ?? "") {
                    for index in result.indices where result[index].turn == turn && result[index].toolState == .running {
                        result[index].toolState = .stopped
                    }
                }
            case "llm/retry", "llm/retry-started":
                result.append(DeviceTranscriptItem(id: id, kind: .systemEvent, title: "模型请求重试",
                                                   text: data["failure"]?["message"]?.stringValue ?? data["reason"]?.stringValue ?? "正在重试模型请求"))
            default:
                continue
            }
        }
        return result
    }
}

extension DeviceTranscriptProjector {
    /// Device-origin input is a first-class participant in the fixed session;
    /// the phone user and the device must not collapse into one bubble.
    static func isDeviceOrigin(_ data: JSONValue) -> Bool {
        let source = data["source"] ?? .null
        let kind = source["kind"]?.stringValue?.lowercased() ?? ""
        if kind == "device" || kind == "device-message" || kind == "device-voice" { return true }
        if source["deviceId"]?.stringValue != nil || data["deviceId"]?.stringValue != nil { return true }
        if source["origin"]?.stringValue?.lowercased() == "device" { return true }
        return false
    }
}

private func deviceText(_ content: JSONValue?) -> String {
    (content?.arrayValue ?? []).compactMap { block in
        block["type"]?.stringValue == "text" ? block["text"]?.stringValue : nil
    }.joined()
}

private func deviceAttachments(_ content: JSONValue?) -> [DeviceTranscriptItem.Attachment] {
    (content?.arrayValue ?? []).compactMap { block in
        guard let type = block["type"]?.stringValue, type == "image" || type == "file" else { return nil }
        let attachment = block["attachment"] ?? .null
        let name = attachment["name"]?.stringValue ?? attachment["path"]?.stringValue
            ?? block["name"]?.stringValue ?? (type == "image" ? "图片" : "文件")
        return DeviceTranscriptItem.Attachment(name: name, isImage: type == "image")
    }
}

private func deviceToolResultText(_ content: JSONValue?, error: JSONValue?) -> String {
    var parts = (content?.arrayValue ?? []).map { block in
        block["type"]?.stringValue == "text" ? block["text"]?.stringValue ?? "" : deviceJSON(block)
    }
    if parts.isEmpty, let reason = error?["reason"]?.stringValue { parts.append(reason) }
    if parts.isEmpty, let name = error?["name"]?.stringValue {
        parts.append("\(name): \(error?["code"]?.stringValue ?? "error")")
    }
    return parts.joined(separator: "\n")
}

func deviceJSON(_ value: JSONValue?) -> String {
    guard let value, let data = try? value.encoded() else { return "" }
    if let object = try? JSONSerialization.jsonObject(with: data),
       let pretty = try? JSONSerialization.data(withJSONObject: object,
                                                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
        return String(data: pretty, encoding: .utf8) ?? ""
    }
    return String(data: data, encoding: .utf8) ?? ""
}
