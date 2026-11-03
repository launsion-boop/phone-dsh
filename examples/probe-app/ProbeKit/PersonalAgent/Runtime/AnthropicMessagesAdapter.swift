// SPDX-License-Identifier: MIT

import Foundation

public enum AnthropicMessageRole: String, Codable, Sendable {
    case user
    case assistant
}

public enum AnthropicContentBlock: Sendable, Equatable {
    case text(String)
    case toolUse(id: String, name: String, inputJSON: String)
    case toolResult(toolCallID: String, content: String, isError: Bool)
}

public struct AnthropicMessage: Sendable, Equatable {
    public let role: AnthropicMessageRole
    public let content: [AnthropicContentBlock]

    public init(role: AnthropicMessageRole, content: [AnthropicContentBlock]) {
        self.role = role
        self.content = content
    }

    public static func text(_ text: String, role: AnthropicMessageRole = .user) -> AnthropicMessage {
        AnthropicMessage(role: role, content: [.text(text)])
    }
}

public struct AnthropicTool: Sendable, Equatable {
    public let name: String
    public let description: String
    public let inputSchemaJSON: String

    public init(name: String, description: String, inputSchemaJSON: String) {
        self.name = name
        self.description = description
        self.inputSchemaJSON = inputSchemaJSON
    }
}

public enum AnthropicToolChoice: Sendable, Equatable {
    case auto
    case any
    case none
    case tool(String)
}

public struct AnthropicMessagesRequest: Sendable, Equatable {
    public let model: String
    public let system: String
    public let messages: [AnthropicMessage]
    public let tools: [AnthropicTool]
    public let toolChoice: AnthropicToolChoice?
    public let maxTokens: Int
    public let stream: Bool

    public init(model: String, system: String, messages: [AnthropicMessage], tools: [AnthropicTool] = [],
                toolChoice: AnthropicToolChoice? = nil, maxTokens: Int = 2_048, stream: Bool = true) {
        self.model = model
        self.system = system
        self.messages = messages
        self.tools = tools
        self.toolChoice = toolChoice
        self.maxTokens = maxTokens
        self.stream = stream
    }

    public func bodyData() throws -> Data {
        guard !model.isEmpty, maxTokens > 0, !messages.isEmpty else {
            throw MainFailure.invalidResponse("invalid Anthropic Messages request")
        }
        var object: [String: Any] = [
            "model": model,
            "system": system,
            "messages": try messages.map(Self.messageObject),
            "max_tokens": maxTokens,
            "stream": stream,
        ]
        if !tools.isEmpty {
            object["tools"] = try tools.map(Self.toolObject)
            if let toolChoice { object["tool_choice"] = Self.toolChoiceObject(toolChoice) }
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func messageObject(_ message: AnthropicMessage) throws -> [String: Any] {
        [
            "role": message.role.rawValue,
            "content": try message.content.map(contentObject),
        ]
    }

    private static func contentObject(_ block: AnthropicContentBlock) throws -> [String: Any] {
        switch block {
        case .text(let text):
            return ["type": "text", "text": text]
        case .toolUse(let id, let name, let inputJSON):
            let input = try MainRuntimeJSON.object(from: inputJSON)
            return ["type": "tool_use", "id": id, "name": name, "input": input]
        case .toolResult(let toolCallID, let content, let isError):
            var object: [String: Any] = [
                "type": "tool_result",
                "tool_use_id": toolCallID,
                "content": content,
            ]
            if isError { object["is_error"] = true }
            return object
        }
    }

    private static func toolObject(_ tool: AnthropicTool) throws -> [String: Any] {
        [
            "name": tool.name,
            "description": tool.description,
            "input_schema": try MainRuntimeJSON.object(from: tool.inputSchemaJSON),
        ]
    }

    private static func toolChoiceObject(_ choice: AnthropicToolChoice) -> [String: Any] {
        switch choice {
        case .auto: return ["type": "auto"]
        case .any: return ["type": "any"]
        case .none: return ["type": "none"]
        case .tool(let name): return ["type": "tool", "name": name]
        }
    }
}

public struct AnthropicMessagesAdapter: Sendable {
    public init() {}

    public func makeRequest(model: String, context: MainAssembledContext,
                            tools: [AnthropicTool] = [], toolChoice: AnthropicToolChoice? = nil,
                            maxTokens: Int = 2_048) -> AnthropicMessagesRequest {
        AnthropicMessagesRequest(model: model, system: context.systemPrompt,
                                 messages: context.messages, tools: tools,
                                 toolChoice: toolChoice ?? (tools.isEmpty ? nil : .auto),
                                 maxTokens: maxTokens)
    }

    public func messagesEndpoint(baseURL: URL) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              components.host?.isEmpty == false else {
            throw MainFailure.notConfigured
        }
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        var path = components.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix("/v1/messages") {
            components.path = path
        } else if path.hasSuffix("/v1") {
            components.path = path + "/messages"
        } else {
            components.path = path + "/v1/messages"
        }
        guard let url = components.url else { throw MainFailure.notConfigured }
        return url
    }
}

enum MainRuntimeJSON {
    static func object(from string: String) throws -> [String: Any] {
        guard let data = string.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MainFailure.invalidResponse("tool input or schema is not a JSON object")
        }
        return object
    }

    static func string(from object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let string = String(data: data, encoding: .utf8) else {
            throw MainFailure.invalidResponse("JSON is not UTF-8")
        }
        return string
    }

    static func boundedString(_ error: Error) -> String {
        String(error.localizedDescription
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .prefix(512))
    }
}
