// SPDX-License-Identifier: MIT

import Foundation

public enum AnthropicStreamEvent: Sendable, Equatable {
    case messageStart
    case textDelta(index: Int, text: String)
    case toolUseStart(index: Int, id: String, name: String, inputJSON: String)
    case toolInputDelta(index: Int, partialJSON: String)
    case contentBlockStop(index: Int)
    case messageDelta(stopReason: String?)
    case messageStop
    case ping
    case providerError(String)
    case unknown(String)
}

public struct AnthropicToolUse: Sendable, Equatable {
    public let id: String
    public let name: String
    public let inputJSON: String
    public let index: Int

    public init(id: String, name: String, inputJSON: String, index: Int) {
        self.id = id
        self.name = name
        self.inputJSON = inputJSON
        self.index = index
    }
}

public struct AnthropicSSEParser: Sendable {
    public static let maximumEventBytes = 4 * 1024 * 1024

    private var buffer = Data()
    private var eventName = ""
    private var dataLines: [String] = []
    private var pendingEventBytes = 0
    public private(set) var unknownEventCount = 0

    public init() {}

    public mutating func consume(_ chunk: Data) throws -> [AnthropicStreamEvent] {
        buffer.append(chunk)
        guard buffer.count <= Self.maximumEventBytes || buffer.contains(0x0A) else {
            throw MainFailure.invalidResponse("SSE event exceeds the byte limit")
        }
        var events: [AnthropicStreamEvent] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            if line.last == 0x0D { line.removeLast() }
            guard let text = String(data: line, encoding: .utf8) else {
                throw MainFailure.invalidResponse("SSE contains invalid UTF-8")
            }
            if let event = try consumeLine(text) { events.append(event) }
        }
        return events
    }

    public mutating func finish() throws -> [AnthropicStreamEvent] {
        guard buffer.isEmpty else {
            throw MainFailure.invalidResponse("unexpected EOF in an SSE line")
        }
        guard eventName.isEmpty, dataLines.isEmpty else {
            throw MainFailure.invalidResponse("unexpected EOF in an SSE event")
        }
        return []
    }

    private mutating func consumeLine(_ line: String) throws -> AnthropicStreamEvent? {
        if line.isEmpty {
            return try dispatchEvent()
        }
        if line.hasPrefix(":") { return nil }
        let field: String
        let value: String
        if let colon = line.firstIndex(of: ":") {
            field = String(line[..<colon])
            var remainder = line[line.index(after: colon)...]
            if remainder.first == " " { remainder = remainder.dropFirst() }
            value = String(remainder)
        } else {
            field = line
            value = ""
        }
        switch field {
        case "event":
            eventName = value
        case "data":
            dataLines.append(value)
            pendingEventBytes += value.utf8.count + 1
            guard pendingEventBytes <= Self.maximumEventBytes else {
                throw MainFailure.invalidResponse("SSE event exceeds the byte limit")
            }
        case "id", "retry":
            break
        default:
            break
        }
        return nil
    }

    private mutating func dispatchEvent() throws -> AnthropicStreamEvent? {
        defer {
            eventName = ""
            dataLines = []
            pendingEventBytes = 0
        }
        guard !eventName.isEmpty || !dataLines.isEmpty else { return nil }
        let name = eventName.isEmpty ? "message" : eventName
        let payload = dataLines.joined(separator: "\n")
        if name == "ping" && payload.isEmpty { return .ping }
        guard let data = payload.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MainFailure.invalidResponse("SSE event data is not a JSON object")
        }
        let type = object["type"] as? String ?? name
        switch name {
        case "message_start":
            return .messageStart
        case "content_block_start":
            let index = try Self.index(object)
            guard let block = object["content_block"] as? [String: Any],
                  let blockType = block["type"] as? String else {
                throw MainFailure.invalidResponse("content_block_start has no content block")
            }
            switch blockType {
            case "tool_use":
                guard let id = block["id"] as? String, !id.isEmpty,
                      let toolName = block["name"] as? String, !toolName.isEmpty else {
                    throw MainFailure.invalidResponse("tool_use has no id or name")
                }
                let input = block["input"] as? [String: Any] ?? [:]
                return .toolUseStart(index: index, id: id, name: toolName,
                                     inputJSON: try MainRuntimeJSON.string(from: input))
            case "text", "thinking":
                return nil
            default:
                unknownEventCount += 1
                return .unknown("content_block_start.\(blockType)")
            }
        case "content_block_delta":
            let index = try Self.index(object)
            guard let delta = object["delta"] as? [String: Any],
                  let deltaType = delta["type"] as? String else {
                throw MainFailure.invalidResponse("content_block_delta has no delta")
            }
            switch deltaType {
            case "text_delta":
                guard let text = delta["text"] as? String else {
                    throw MainFailure.invalidResponse("text_delta has no text")
                }
                return .textDelta(index: index, text: text)
            case "input_json_delta":
                guard let partial = delta["partial_json"] as? String else {
                    throw MainFailure.invalidResponse("input_json_delta has no partial_json")
                }
                return .toolInputDelta(index: index, partialJSON: partial)
            case "thinking_delta", "signature_delta":
                return nil
            default:
                unknownEventCount += 1
                return .unknown("content_block_delta.\(deltaType)")
            }
        case "content_block_stop":
            return .contentBlockStop(index: try Self.index(object))
        case "message_delta":
            let delta = object["delta"] as? [String: Any]
            return .messageDelta(stopReason: delta?["stop_reason"] as? String)
        case "message_stop":
            return .messageStop
        case "ping":
            return .ping
        case "error":
            let error = object["error"] as? [String: Any]
            let message = error?["message"] as? String ?? object["message"] as? String ?? type
            return .providerError(String(message.prefix(512)))
        default:
            unknownEventCount += 1
            return .unknown(name)
        }
    }

    private static func index(_ object: [String: Any]) throws -> Int {
        guard let index = object["index"] as? Int, index >= 0 else {
            throw MainFailure.invalidResponse("content block has no valid index")
        }
        return index
    }
}

public struct AnthropicResponseAccumulator: Sendable {
    private struct ToolBuilder: Sendable {
        let id: String
        let name: String
        var inputJSON: String
        var stopped = false
    }

    private var textByIndex: [Int: String] = [:]
    private var toolsByIndex: [Int: ToolBuilder] = [:]
    private var blockOrder: [Int] = []
    public private(set) var stopReason: String?
    public private(set) var receivedMessageStop = false
    public private(set) var unknownEventCount = 0

    public init() {}

    public var text: String {
        blockOrder.compactMap { textByIndex[$0] }.joined()
    }

    public var toolUses: [AnthropicToolUse] {
        blockOrder.compactMap { index in
            guard let tool = toolsByIndex[index] else { return nil }
            return AnthropicToolUse(id: tool.id, name: tool.name,
                                    inputJSON: tool.inputJSON, index: index)
        }
    }

    public mutating func apply(_ event: AnthropicStreamEvent) throws {
        switch event {
        case .messageStart, .ping:
            break
        case .textDelta(let index, let text):
            if !blockOrder.contains(index) { blockOrder.append(index) }
            textByIndex[index, default: ""] += text
        case .toolUseStart(let index, let id, let name, let inputJSON):
            guard toolsByIndex[index] == nil, textByIndex[index] == nil else {
                throw MainFailure.invalidResponse("duplicate content block index \(index)")
            }
            blockOrder.append(index)
            toolsByIndex[index] = ToolBuilder(id: id, name: name, inputJSON: inputJSON)
        case .toolInputDelta(let index, let partialJSON):
            guard toolsByIndex[index] != nil else {
                throw MainFailure.invalidResponse("tool input delta has no tool_use block")
            }
            if toolsByIndex[index]?.inputJSON == "{}" {
                toolsByIndex[index]?.inputJSON = partialJSON
            } else {
                toolsByIndex[index]?.inputJSON += partialJSON
            }
        case .contentBlockStop(let index):
            if toolsByIndex[index] != nil {
                toolsByIndex[index]?.stopped = true
            } else if textByIndex[index] == nil {
                throw MainFailure.invalidResponse("content_block_stop has no start event")
            }
        case .messageDelta(let reason):
            if let reason { stopReason = reason }
        case .messageStop:
            receivedMessageStop = true
        case .providerError(let message):
            throw MainFailure.provider(message)
        case .unknown:
            unknownEventCount += 1
        }
    }

    public func validated() throws {
        guard receivedMessageStop else {
            throw MainFailure.provider("recoverable upstream stream failure: unexpected EOF before message_stop")
        }
        for (index, tool) in toolsByIndex {
            guard tool.stopped else {
                throw MainFailure.invalidResponse("tool_use block \(index) was not stopped")
            }
            _ = try MainRuntimeJSON.object(from: tool.inputJSON)
        }
    }

    public func assistantMessage() -> AnthropicMessage {
        let content: [AnthropicContentBlock] = blockOrder.compactMap { index in
            if let text = textByIndex[index], !text.isEmpty { return .text(text) }
            if let tool = toolsByIndex[index] {
                return .toolUse(id: tool.id, name: tool.name, inputJSON: tool.inputJSON)
            }
            return nil
        }
        return AnthropicMessage(role: .assistant, content: content)
    }
}
