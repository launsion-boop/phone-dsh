// SPDX-License-Identifier: MIT

import Foundation

/// In-process bridge from the Bot MCP endpoint to the native (Android/ADB)
/// MCP server. The Bot server is the Worker's only `phone` server; tools that
/// are not part of the Bot catalog are forwarded unchanged so both tool
/// families appear under one `mcp__phone__` namespace.
public protocol BotNativeMCPForwarding: Sendable {
    /// Handles one JSON-RPC request and returns the matching response object,
    /// or nil when the native server produced no JSON body. The original HTTP
    /// headers are forwarded so `X-PDSH-Idempotency-Key` keeps its meaning.
    func handle(_ request: BotJSONValue, headers: [String: String]) async -> BotJSONValue?
}

public actor BotMCPHandler {
    public static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26"]

    private let runtime: BotMCPRuntime
    private let runtimeId: String
    private var nativeMCP: (any BotNativeMCPForwarding)?
    public nonisolated let mcpSessionId: String

    public init(runtime: BotMCPRuntime, runtimeId: String = BotMCPRuntime.defaultRuntimeID) {
        self.runtime = runtime
        self.runtimeId = runtimeId
        mcpSessionId = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    /// Attaches the native MCP handler after the App has chosen its
    /// `nativeMCP`. Calling it again replaces the forwarder.
    public func attachNativeMCP(_ forwarder: any BotNativeMCPForwarding) {
        nativeMCP = forwarder
    }

    public func rpc(method: String, params: BotJSONValue, id: BotJSONValue,
                    headers: [String: String] = [:]) async -> BotJSONValue {
        switch method {
        case "initialize":
            let requested = params["protocolVersion"]?.stringValue ?? ""
            var result: [String: BotJSONValue] = [
                "protocolVersion": .string(Self.protocolVersions.contains(requested) ? requested : Self.protocolVersions[0]),
                "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object(["name": .string("phone"), "version": .string("1.0.0")]),
            ]
            if let native = await nativeInstructions(protocolVersion: requested) {
                result["instructions"] = .string(native)
            }
            return self.result(id, .object(result))
        case "ping": return result(id, .object([:]))
        case "tools/list":
            do {
                var tools = try BotToolCatalog.allDefinitions.map(encode)
                var names = Set(tools.compactMap { $0["name"]?.stringValue })
                if let native = await nativeTools() {
                    for tool in native where names.insert(tool["name"]?.stringValue ?? "").inserted {
                        tools.append(tool)
                    }
                }
                return result(id, .object(["tools": .array(tools)]))
            } catch {
                return rpcError(id, code: -32603, message: "tool catalog encoding failed")
            }
        case "tools/call":
            guard case .object(let object) = params, case .string(let name)? = object["name"] else {
                return rpcError(id, code: -32602, message: "tools/call requires name")
            }
            let arguments = object["arguments"] ?? .object([:])
            guard case .object = arguments else { return rpcError(id, code: -32602, message: "arguments must be an object") }
            let bareName = Self.bareToolName(name)
            guard BotToolCatalog.isRegistered(bareName) else {
                if let forwarded = await forwardNative(method: method, params: params, id: id,
                                                       headers: headers) {
                    return forwarded
                }
                return rpcError(id, code: -32602, message: "unknown tool: \(bareName)")
            }
            let call = await runtime.execute(
                name: bareName, arguments: arguments,
                context: BotMCPRequestContext(runtimeId: runtimeId, callId: Self.callId(id)))
            do { return result(id, try encode(call)) } catch {
                return rpcError(id, code: -32603, message: "tool result encoding failed")
            }
        default:
            if let forwarded = await forwardNative(method: method, params: params, id: id,
                                                   headers: headers) {
                return forwarded
            }
            return rpcError(id, code: -32601, message: "method not found: \(method)")
        }
    }

    public func registerIdentity(_ request: BotJSONValue) async -> BotJSONValue {
        guard case .object(let object) = request,
              case .string(let registeredRuntime)? = object["runtimeId"], registeredRuntime == runtimeId,
              case .string(let session)? = object["sessionId"],
              case .string(let call)? = object["callId"],
              case .string(let name)? = object["name"] else {
            return .object(["ok": .bool(false), "error": .string("invalid identity registration")])
        }
        let arguments = object["arguments"] ?? .object([:])
        do {
            if object["arguments"] != nil, let suppliedDigest = object["argsDigest"]?.stringValue {
                let actual = try BotArgumentsDigest.string(for: arguments)
                guard suppliedDigest == actual else {
                    return .object(["ok": .bool(false), "error": .string("argument digest mismatch")])
                }
            }
            let registration = try await runtime.registerIdentity(
                runtimeId: runtimeId, sessionId: session, callId: call, name: name,
                arguments: arguments, argsDigest: object["argsDigest"]?.stringValue)
            return .object(["ok": .bool(true), "id": .string(registration.id)])
        } catch let error as BotMCPError {
            return .object(["ok": .bool(false), "error": .string(Self.registrationError(error))])
        } catch BotGatewayError.unknownSession {
            return .object(["ok": .bool(false), "error": .string("unknown_session")])
        } catch {
            return .object(["ok": .bool(false), "error": .string("identity registration refused")])
        }
    }

    public func cancelIdentity(_ request: BotJSONValue) async -> BotJSONValue {
        guard case .object(let object) = request, case .string(let id)? = object["id"] else {
            return .object(["ok": .bool(false)])
        }
        return .object(["ok": .bool(await runtime.cancelIdentity(id: id))])
    }

    public func approval(_ request: BotJSONValue) async -> BotJSONValue {
        guard case .object(let object) = request,
              case .string(let sessionId)? = object["sessionId"], !sessionId.isEmpty,
              case .string(let callId)? = object["callId"],
              case .string(let name)? = object["tool"],
              case .string(let argsDigest)? = object["argsDigest"],
              case .string(let alwaysScope)? = object["alwaysScope"] else {
            return BotApprovalOutcome(ok: false, allowed: false, message: "invalid approval request").jsonValue
        }
        let action = object["action"]?.stringValue ?? name
        let detail = object["detail"]?.stringValue ?? ""
        let command = object["command"]?.stringValue ?? ""
        var effects: [BotToolEffect]?
        if case .array(let rawEffects)? = object["effects"] {
            effects = rawEffects.compactMap(Self.effect)
        }
        return await runtime.approve(
            runtimeId: runtimeId, sessionId: sessionId, callId: callId, name: name,
            action: action, detail: detail, command: command,
            argsDigest: argsDigest, alwaysScope: alwaysScope,
            askAction: object["askAction"]?.stringValue ?? "tool-call",
            suppliedEffects: effects).jsonValue
    }

    public func resolveApproval(approvalId: String, decision: BotApprovalDecision,
                                digest: String) async -> BotApprovalResolution {
        await runtime.approvals.resolve(approvalId: approvalId, decision: decision, digest: digest)
    }

    // MARK: - Native MCP forwarding

    private func forwardNative(method: String, params: BotJSONValue,
                               id: BotJSONValue, headers: [String: String]) async -> BotJSONValue? {
        guard let nativeMCP else { return nil }
        let response = await nativeMCP.handle(.object([
            "jsonrpc": .string("2.0"), "id": id, "method": .string(method), "params": params,
        ]), headers: headers)
        guard case .object(let object)? = response else { return nil }
        if let error = object["error"] {
            return .object(["jsonrpc": .string("2.0"), "id": id, "error": error])
        }
        guard let result = object["result"] else { return nil }
        return self.result(id, result)
    }

    private func nativeTools() async -> [BotJSONValue]? {
        guard let nativeMCP else { return nil }
        let response = await nativeMCP.handle(.object([
            "jsonrpc": .string("2.0"), "id": .string("native-tools-list"),
            "method": .string("tools/list"), "params": .object([:]),
        ]), headers: [:])
        guard case .object(let object)? = response,
              case .array(let tools)? = object["result"]?["tools"] else { return nil }
        return tools
    }

    private func nativeInstructions(protocolVersion: String) async -> String? {
        guard let nativeMCP else { return nil }
        let response = await nativeMCP.handle(.object([
            "jsonrpc": .string("2.0"), "id": .string("native-initialize"),
            "method": .string("initialize"),
            "params": .object(["protocolVersion": .string(protocolVersion)]),
        ]), headers: [:])
        guard case .object(let object)? = response,
              case .string(let instructions)? = object["result"]?["instructions"],
              !instructions.isEmpty else { return nil }
        return instructions
    }

    private func result(_ id: BotJSONValue, _ value: BotJSONValue) -> BotJSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "result": value])
    }

    private func rpcError(_ id: BotJSONValue, code: Int, message: String) -> BotJSONValue {
        .object([
            "jsonrpc": .string("2.0"), "id": id,
            "error": .object(["code": .number(Double(code)), "message": .string(message)]),
        ])
    }

    private func encode<T: Encodable>(_ value: T) throws -> BotJSONValue {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try BotJSONValue.parse(encoder.encode(value))
    }

    private static func registrationError(_ error: BotMCPError) -> String {
        switch error {
        case .unknownTool: return "unknown_tool"
        case .unauthorized: return "unauthorized"
        case .invalidRequest: return "invalid_request"
        case .unattributed: return "unattributed"
        case .crossSessionDenied: return "cross_session_denied"
        case .timeout: return "timeout"
        case .unavailable: return "unavailable"
        }
    }

    private static func bareToolName(_ name: String) -> String {
        guard name.hasPrefix("mcp__") else { return name }
        return name.components(separatedBy: "__").last ?? name
    }

    private static func effect(_ value: BotJSONValue) -> BotToolEffect? {
        guard case .object(let object) = value,
              case .string(let tool)? = object["tool"],
              case .string(let operation)? = object["operation"],
              case .string(let resource)? = object["resource"],
              case .string(let mutability)? = object["mutability"],
              let kind = BotToolMutability(rawValue: mutability),
              case .string(let policy)? = object["policy"],
              let policyValue = BotToolPolicy(rawValue: policy) else { return nil }
        return BotToolEffect(
            tool: tool, operation: operation, resource: resource,
            target: object["target"]?.stringValue,
            mutability: kind, policy: policyValue,
            label: object["label"]?.stringValue ?? "",
            detail: object["detail"]?.stringValue ?? "",
            ui: object["ui"]?.boolValue ?? false,
            execution: object["execution"]?.stringValue,
            known: object["known"]?.boolValue ?? true,
            isMcp: object["isMcp"]?.boolValue ?? true)
    }

    private static func callId(_ id: BotJSONValue) -> String {
        switch id {
        case .string(let value): return value
        case .number(let value): return value.rounded() == value ? String(Int(value)) : String(value)
        default: return UUID().uuidString.lowercased()
        }
    }
}
