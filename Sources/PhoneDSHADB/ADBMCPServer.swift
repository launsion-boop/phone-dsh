// SPDX-License-Identifier: MIT
import Foundation
import CryptoKit
import PhoneDSHAgentCore
import PhoneDSHLoopback

/// Stateless Streamable HTTP MCP on the host's authenticated `/mcp/native`.
/// The official DSH MCP client registers these as mcp__phone__android_*.
public actor ADBMCPServer: NativeMCPServing {
    public static let shared = ADBMCPServer()
    private let settings: ADBSettings
    private let executor: any ADBCommandExecuting
    private let receiptStore: ADBReceiptStore
    private var workspaceDirectory: URL?
    private var active: (id: JSONValue, task: Task<JSONValue, Never>)?
    private struct Receipt {
        var fingerprint: Data
        var result: JSONValue?
        var size: Int = 0
    }
    private var receipts: [String: Receipt] = [:]
    private var order: [String] = []
    private var receiptBytes = 0

    public init(settings: ADBSettings = .shared, executor: any ADBCommandExecuting = ADBClient(), receiptDirectory: URL? = nil, workspaceDirectory: URL? = nil) {
        self.settings = settings; self.executor = executor
        self.workspaceDirectory = workspaceDirectory
        self.receiptStore = ADBReceiptStore(directory: receiptDirectory ?? ADBReceiptStore.defaultDirectory)
    }

    public func setWorkspaceDirectory(_ directory: URL) throws {
        guard active == nil else { throw ADBFailure("Wait for the current Android operation before changing its workspace") }
        workspaceDirectory = directory
    }

    /// Save while idle; changing a target must not redirect an in-flight action.
    public func configure(_ configuration: ADBConfiguration) throws {
        guard active == nil else { throw ADBFailure("Wait for the current Android operation or cancel it before changing the connection") }
        try settings.save(configuration)
    }
    public func cancel() { active?.task.cancel() }
    public func cancelPendingOperations() async {
        guard let task = active?.task else { return }
        task.cancel()
        _ = await task.value
    }
    public func checkConnection(_ configuration: ADBConfiguration) async throws -> String {
        guard active == nil else { throw ADBFailure("An Android operation is already running", kind: .busy) }
        let endpoint = try configuration.endpoint()
        let task = Task<JSONValue, Never> { [executor] in
            do {
                let result = try await executor.shell(endpoint: endpoint, command: "getprop ro.product.model; getprop ro.build.version.release; wm size", timeout: 30, outputLimit: 65536)
                guard result.exitCode == 0 else { throw ADBFailure(String(decoding: result.stderr, as: UTF8.self)) }
                return .string(String(decoding: result.stdout, as: UTF8.self))
            } catch { return .object(["error": .string(error.localizedDescription)]) }
        }
        active = (.string("native-connection-check"), task)
        let result = await task.value
        active = nil
        if let error = result.fields["error"]?.text { throw ADBFailure(error) }
        return result.text ?? ""
    }

    public func handle(_ request: LoopbackRequest) async -> NativeMCPResponse {
        guard request.method == "POST" else { return NativeMCPResponse(status: 405) }
        guard request.body.count <= 16 * 1024,
              let message = try? JSONValue.parse(request.body), case .object(let fields) = message,
              fields["jsonrpc"] == .string("2.0"), let method = fields["method"]?.text else {
            return rpcError(id: .null, code: -32600, message: "Invalid JSON-RPC request")
        }
        let params = fields["params"]?.fields ?? [:]
        guard let id = fields["id"] else {
            if method == "notifications/cancelled", params["requestId"] == active?.id { active?.task.cancel() }
            return NativeMCPResponse(status: 202)
        }
        switch id { case .string, .number: break; default: return rpcError(id: .null, code: -32600, message: "Invalid request ID") }
        switch method {
        case "initialize":
            let supported = ["2024-11-05", "2025-03-26", "2025-06-18"]
            let requested = params["protocolVersion"]?.text ?? ""
            return response(id: id, result: .object([
                "protocolVersion": .string(supported.contains(requested) ? requested : "2025-03-26"),
                "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object(["name": .string("phone-dsh-android"), "version": .string("1.0.0")]),
                "instructions": .string("Android tools connect directly from iPhone over LAN TCP/IP ADB. Use android_connect with the user-provided host and optional port to enable control and save or change the target, including when control is disabled; do not ask the user to visit Settings. android_shell supports arbitrary commands within Android ADB shell permissions. For file transfers use the Worker bash commands adb push LOCAL REMOTE and adb pull REMOTE [LOCAL] (single files; /dsh/transfers/NAME streams up to 1 GiB on iPhone disk, /dsh/workspace/NAME uses the smaller Worker budget; pull defaults to /dsh/transfers; use bash timeoutMs=3600000 for large transfers; after a timeout call Worker adb stat LOCAL before retrying and distinguish running from saved); do not run adb inside android_shell. Use android_list_packages for installed apps and android_list_apk_files for installer files. Uninstall uses packageName. Install requires source=workspace or device; workspace APKs require /dsh/workspace/...apk and sha256sum. Use android_command_help to discover device-supported commands; android_shell runs on Android, without an adb shell prefix. Use a screenshot before choosing pixels. No automatic retries."),
            ]))
        case "ping": return response(id: id, result: .object([:]))
        case "tools/list": return response(id: id, result: .object(["tools": .array(ADBTools.descriptors)]))
        case "tools/call":
            guard let name = params["name"]?.text else { return rpcError(id: id, code: -32602, message: "Tool name required") }
            let arguments = params["arguments"] ?? .object([:])
            let plan: ADBTools.Plan
            let endpoint: ADBEndpoint
            do { plan = try ADBTools.plan(name: name, arguments: arguments); endpoint = try (plan.connection ?? settings.load()).endpoint() }
            catch { return response(id: id, result: ADBTools.textResult(error.localizedDescription, error: true)) }
            // A retry of the same journaled tool call must never tap/type twice.
            let key = request.headers.first(where: { $0.key.lowercased() == "x-pdsh-idempotency-key" })?.value
            let fingerprint = Data(SHA256.hash(data: (try? JSONValue.object(["name": .string(name), "arguments": arguments,
                "host": .string(endpoint.host), "port": .number(Double(endpoint.port))]).encoded()) ?? Data()))
            if let key, receipts[key] == nil {
                do {
                    if let saved = try receiptStore.load(key) {
                        guard saved.fingerprint == fingerprint else { return rpcError(id: id, code: -32602, message: "Idempotency key conflict") }
                        return response(id: id, result: saved.result ?? ADBTools.textResult("An earlier attempt at this Android operation was interrupted. Its outcome is unknown; inspect device state before issuing a new action.", error: true))
                    }
                } catch { return response(id: id, result: ADBTools.textResult("Cannot read Android operation receipt; refusing to repeat an uncertain action.", error: true)) }
            }
            if let key, let receipt = receipts[key] {
                guard receipt.fingerprint == fingerprint else { return rpcError(id: id, code: -32602, message: "Idempotency key conflict") }
                return response(id: id, result: receipt.result ?? ADBTools.textResult("This Android operation was already admitted; its result is pending or no longer retained. Inspect device state before issuing a new action.", error: true))
            }
            guard active == nil else {
                // The MCP result is still plain text; the failure is typed so a
                // retryable conflict is distinguishable from a device error.
                let busy = ADBFailure("An Android operation is already running; wait for it before the next action.", kind: .busy)
                return response(id: id, result: ADBTools.textResult(busy.localizedDescription, error: true))
            }
            if let key {
                guard key.count <= 256, !key.isEmpty, receipts.count < 4096 else {
                    return rpcError(id: id, code: -32602, message: "Invalid idempotency key or receipt capacity reached; restart the app")
                }
                do { try receiptStore.save(key, ADBReceipt(fingerprint: fingerprint)) }
                catch { return response(id: id, result: ADBTools.textResult("Cannot persist Android operation intent; no command was sent.", error: true)) }
                receipts[key] = Receipt(fingerprint: fingerprint)
            }
            let task = Task<JSONValue, Never> { [executor, workspaceDirectory, settings] in
                do {
                    try Task.checkCancellation()
                    if let configuration = plan.connection { try settings.save(configuration) }
                    let result: ADBShellResult
                    if let path = plan.workspaceAPK, let sha256 = plan.sha256 {
                        let data = try ADBWorkspaceAPK.read(path: path, root: workspaceDirectory, sha256: sha256)
                        try Task.checkCancellation()
                        result = try await executor.shell(endpoint: endpoint, command: plan.command + " -S \(data.count) -",
                                                          stdin: data, timeout: plan.timeout, outputLimit: plan.outputLimit)
                    } else {
                        result = try await executor.shell(endpoint: endpoint, command: plan.command, timeout: plan.timeout, outputLimit: plan.outputLimit)
                    }
                    return try ADBTools.result(result, plan: plan)
                } catch {
                    return ADBTools.textResult(error.localizedDescription + "\nIf the connection was interrupted, the Android action may already have occurred. Inspect state before repeating it.", error: true)
                }
            }
            active = (id, task)
            var result = await task.value
            active = nil
            if let key {
                do { try receiptStore.save(key, ADBReceipt(fingerprint: fingerprint, result: result)) }
                catch { result = ADBTools.textResult("Android operation ended, but its result could not be persisted. Inspect device state before repeating it.", error: true) }
                let size = (try? result.encoded().count) ?? 0
                receipts[key] = Receipt(fingerprint: fingerprint, result: result, size: size)
                receiptBytes += size; order.append(key)
                while receiptBytes > 16 * 1024 * 1024, !order.isEmpty {
                    let old = order.removeFirst()
                    receiptBytes -= receipts[old]?.size ?? 0
                    receipts[old]?.result = nil; receipts[old]?.size = 0
                }
            }
            return response(id: id, result: result)
        default: return rpcError(id: id, code: -32601, message: "Method not found")
        }
    }

    private func response(id: JSONValue, result: JSONValue) -> NativeMCPResponse {
        NativeMCPResponse(body: (try? JSONValue.object(["jsonrpc": .string("2.0"), "id": id, "result": result]).encoded()) ?? Data())
    }
    private func rpcError(id: JSONValue, code: Int, message: String) -> NativeMCPResponse {
        NativeMCPResponse(body: (try? JSONValue.object(["jsonrpc": .string("2.0"), "id": id,
            "error": .object(["code": .number(Double(code)), "message": .string(message)])]).encoded()) ?? Data())
    }
}
