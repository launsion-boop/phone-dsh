// SPDX-License-Identifier: MIT

import Foundation

public struct BotDeviceToolProvider: Sendable {
    public typealias Executor = @Sendable (String, BotJSONValue, BotResolvedToolCall) async throws -> BotJSONValue

    public static let tools: Set<String> = ["bluetooth.scan", "network.browse"]

    private let authorizer: BotExecutionAuthorizer
    private let executor: Executor

    public init(authorizer: BotExecutionAuthorizer, executor: @escaping Executor) {
        self.authorizer = authorizer
        self.executor = executor
    }

    public func bluetoothScan(duration: Int = 5, call: BotResolvedToolCall) async throws -> BotJSONValue {
        guard (1...15).contains(duration) else { throw BotMCPError.invalidRequest("duration must be 1…15") }
        return try await execute("bluetooth.scan", arguments: .object(["duration": .number(Double(duration))]), call: call)
    }

    public func browseNetwork(call: BotResolvedToolCall) async throws -> BotJSONValue {
        try await execute("network.browse", arguments: .object([:]), call: call)
    }

    public func execute(_ tool: String, arguments: BotJSONValue,
                        call: BotResolvedToolCall) async throws -> BotJSONValue {
        guard Self.tools.contains(tool) else { throw BotMCPError.unknownTool(tool) }
        let qualifiedName = call.attribution.name.components(separatedBy: "__").last ?? call.attribution.name
        let registeredName = qualifiedName.hasPrefix("phone.")
            ? String(qualifiedName.dropFirst(5)) : qualifiedName
        guard registeredName == tool else { throw BotMCPError.unauthorized }
        let effect = Self.discoveryEffect(for: tool)
        let argsDigest = try BotArgumentsDigest.string(for: arguments)
        let decision = await authorizer.authorizeExecution(
            principal: BotExecutionPrincipal(gateway: call.principal), effects: [effect],
            source: "bot-device-provider", argsDigest: argsDigest)
        guard decision.allowed else {
            throw BotMCPError.unavailable("device-discovery-\(decision.reason)")
        }
        let response = try await executor(tool, arguments, call)
        guard let ok = response["ok"]?.boolValue else {
            throw BotMCPError.unavailable("PhoneCapabilityBridge returned an invalid envelope")
        }
        if ok {
            guard let items = response["data"]?["items"]?.arrayValue,
                  response["data"]?["count"]?.intValue == items.count else {
                throw BotMCPError.unavailable("device discovery returned an invalid result")
            }
            for item in items where item["name"]?.stringValue == nil && item["id"]?.stringValue == nil {
                throw BotMCPError.unavailable("discovery result is not a stable device identity")
            }
        }
        return response
    }

    public static func discoveryEffect(for tool: String) -> BotToolEffect {
        BotToolEffect(
            tool: tool, operation: "device.discovery.read",
            resource: tool, target: tool, mutability: .read, policy: .ask,
            label: tool == "bluetooth.scan" ? "Scan nearby Bluetooth devices" : "Browse the local network",
            detail: "Discovery is read-only. Peripheral identifiers and service names are not paired device identities.")
    }
}
