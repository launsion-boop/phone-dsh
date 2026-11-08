// SPDX-License-Identifier: MIT
import XCTest
import PhoneDSHAgentCore
import PhoneDSHLoopback
@testable import PhoneDSHADB

final class ADBMCPTests: XCTestCase {
    func fixture(enabled: Bool = true, executor: RecordingADB = RecordingADB(), receipts: URL? = nil) throws -> (ADBMCPServer, RecordingADB) {
        let suite = "phone-dsh-adb-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let settings = ADBSettings(defaults: defaults)
        try settings.save(ADBConfiguration(enabled: enabled, host: "192.0.2.1"))
        let directory = receipts ?? FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (ADBMCPServer(settings: settings, executor: executor, receiptDirectory: directory), executor)
    }
    func request(_ method: String, params: [String: JSONValue] = [:], key: String? = nil, id: JSONValue? = .number(1)) throws -> LoopbackRequest {
        var fields: [String: JSONValue] = ["jsonrpc": .string("2.0"), "method": .string(method), "params": .object(params)]
        fields["id"] = id
        return LoopbackRequest(method: "POST", path: "/mcp/native", headers: key.map { ["X-PDSH-Idempotency-Key": $0] } ?? [:],
                               body: try JSONValue.object(fields).encoded())
    }
    func call(_ name: String, _ args: [String: JSONValue] = [:], key: String? = nil) throws -> LoopbackRequest {
        try request("tools/call", params: ["name": .string(name), "arguments": .object(args)], key: key)
    }
    func result(_ response: NativeMCPResponse) throws -> JSONValue {
        try XCTUnwrap(JSONValue.parse(response.body).fields["result"])
    }
    func testMCPInitializeListAndUnsupportedMethods() async throws {
        let (server, _) = try fixture()
        let initialized = try result(await server.handle(request("initialize", params: ["protocolVersion": .string("2025-03-26")])))
        XCTAssertEqual(initialized.fields["protocolVersion"], .string("2025-03-26"))
        let listed = try result(await server.handle(request("tools/list")))
        guard case .array(let tools) = listed.fields["tools"] else { return XCTFail("missing tools") }
        XCTAssertEqual(tools.count, 26)
        XCTAssertTrue(tools.contains { $0.fields["name"] == .string("android_screenshot") })
        let notification = await server.handle(try request("notifications/initialized", id: nil))
        XCTAssertEqual(notification.status, 202)
        let get = await server.handle(LoopbackRequest(method: "GET", path: "/mcp/native"))
        XCTAssertEqual(get.status, 405)
        let unknown = try JSONValue.parse(await server.handle(request("unknown")).body)
        XCTAssertEqual(unknown.fields["error"]?.fields["code"], .number(-32601))
    }
    func testToolCallAndIdempotentReplayNeverRepeatTap() async throws {
        let (server, recorder) = try fixture()
        let req = try call("android_tap", ["x": .number(12), "y": .number(34)], key: "tap-once")
        let first = try result(await server.handle(req))
        let second = try result(await server.handle(req))
        XCTAssertEqual(first, second)
        let commands = await recorder.commands
        XCTAssertEqual(commands, ["input tap 12 34"])
        let conflict = try JSONValue.parse(await server.handle(call("android_tap", ["x": .number(1), "y": .number(2)], key: "tap-once")).body)
        XCTAssertNotNil(conflict.fields["error"])
    }
    func testNativeMCPHTTPGolden() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let golden = try JSONValue.parse(Data(contentsOf: root.appendingPathComponent("spec/v1/golden/native-mcp/tap.json"))).fields
        let (server, recorder) = try fixture()
        let req = LoopbackRequest(method: golden["method"]!.text!, path: golden["path"]!.text!, body: try golden["request"]!.encoded())
        let response = await server.handle(req)
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(try JSONValue.parse(response.body), golden["response"])
        let commands = await recorder.commands
        XCTAssertEqual(commands, [golden["android_command"]!.text!])
    }
    func testConnectGoldenFromDisabledState() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let golden = try JSONValue.parse(Data(contentsOf: root.appendingPathComponent("spec/v1/golden/native-mcp/connect.json"))).fields
        let (server, _) = try fixture(enabled: false)
        let req = LoopbackRequest(method: "POST", path: "/mcp/native", body: try golden["request"]!.encoded())
        let response = await server.handle(req)
        XCTAssertEqual(try JSONValue.parse(response.body), golden["response"])
    }

    func testConnectEnablesDisabledControlAndPersistsTarget() async throws {
        let (server, recorder) = try fixture(enabled: false)
        for args: [String: JSONValue] in [["host": .string("")], ["host": .string("192.0.2.2"), "port": .number(0)],
                                         ["host": .string("192.0.2.2"), "port": .number(1.5)]] {
            let bad = try result(await server.handle(call("android_connect", args)))
            XCTAssertEqual(bad.fields["isError"], .bool(true))
        }
        let args: [String: JSONValue] = ["host": .string("192.0.2.2"), "port": .number(5556)]
        let connected = try result(await server.handle(call("android_connect", args, key: "connect-once")))
        XCTAssertEqual(connected.fields["isError"], .bool(false))
        let replay = try result(await server.handle(call("android_connect", args, key: "connect-once")))
        XCTAssertEqual(replay, connected)
        let status = try result(await server.handle(call("android_status")))
        XCTAssertEqual(status.fields["isError"], .bool(false))
        let commands = await recorder.commands
        XCTAssertEqual(commands.count, 2)
        let endpoints = await recorder.endpoints
        XCTAssertEqual(endpoints, [try ADBEndpoint(host: "192.0.2.2", port: 5556), try ADBEndpoint(host: "192.0.2.2", port: 5556)])
    }

    func testDisabledDeviceAndInvalidArgumentsNeverReachADB() async throws {
        let (disabled, recorder) = try fixture(enabled: false)
        let value = try result(await disabled.handle(call("android_status")))
        XCTAssertEqual(value.fields["isError"], .bool(true))
        let (server, _) = try fixture(executor: recorder)
        for args: [String: JSONValue] in [["x": .number(-1), "y": .number(2)], ["x": .number(1.5), "y": .number(2)],
                                         ["x": .number(1), "y": .number(2), "host": .string("other")], ["x": .bool(true), "y": .number(2)]] {
            let bad = try result(await server.handle(call("android_tap", args)))
            XCTAssertEqual(bad.fields["isError"], .bool(true))
        }
        let commands = await recorder.commands
        XCTAssertTrue(commands.isEmpty)
    }
    func testPersistentReceiptSurvivesServerRestartAndUnknownIntentFailsClosed() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let (first, recorder) = try fixture(receipts: directory)
        let req = try call("android_key", ["key": .string("HOME")], key: "survives-restart")
        let firstResult = try result(await first.handle(req))
        let (second, _) = try fixture(executor: recorder, receipts: directory)
        let replayed = try result(await second.handle(req))
        XCTAssertEqual(firstResult, replayed)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let saved = try JSONDecoder().decode(ADBReceipt.self, from: Data(contentsOf: files[0]))
        try ADBReceiptStore(directory: directory).save("survives-restart", ADBReceipt(fingerprint: saved.fingerprint))
        let (third, _) = try fixture(executor: recorder, receipts: directory)
        let unknown = try result(await third.handle(req))
        XCTAssertEqual(unknown.fields["isError"], .bool(true))
        let commands = await recorder.commands
        XCTAssertEqual(commands, ["input keyevent KEYCODE_HOME"])
    }
    func testScreenshotIsMCPImageWithUnmodifiedPNGBytes() async throws {
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aF1sAAAAASUVORK5CYII=")!
        let (server, _) = try fixture(executor: RecordingADB(output: ADBShellResult(stdout: png)))
        let value = try result(await server.handle(call("android_screenshot")))
        guard case .array(let content) = value.fields["content"] else { return XCTFail("missing image") }
        XCTAssertEqual(content.first?.fields["type"], .string("image"))
        XCTAssertEqual(content.first?.fields["mimeType"], .string("image/png"))
        XCTAssertEqual(content.first?.fields["data"], .string(png.base64EncodedString()))
        let (bad, _) = try fixture(executor: RecordingADB(output: ADBShellResult(stdout: Data("not png".utf8))))
        let invalid = try result(await bad.handle(call("android_screenshot")))
        XCTAssertEqual(invalid.fields["isError"], .bool(true))
    }
    func testCommandEscapingAndInputLimits() throws {
        let text = "hello';$(id) & bye"
        let plan = try ADBTools.plan(name: "android_input_text", arguments: .object(["text": .string(text)]))
        XCTAssertEqual(plan.command, "input text 'hello'\\'';$(id)%s&%sbye'")
        for text in ["中文", "line\nfeed", "literal%s"] {
            XCTAssertThrowsError(try ADBTools.plan(name: "android_input_text", arguments: .object(["text": .string(text)])))
        }
        XCTAssertThrowsError(try ADBTools.plan(name: "android_launch_app", arguments: .object(["packageName": .string("x;reboot")])) )
        XCTAssertThrowsError(try ADBTools.plan(name: "android_key", arguments: .object(["key": .string("HOME;id")])) )
        XCTAssertThrowsError(try ADBTools.plan(name: "android_shell", arguments: .object(["command": .string("id"), "timeoutMs": .number(120001)])))
        XCTAssertThrowsError(try ADBEndpoint(host: "http://phone.invalid", port: 5555))
        XCTAssertThrowsError(try ADBEndpoint(host: "phone", port: 0))
    }
    func testMCPSerializesActionsAndCancellationSettles() async throws {
        let recorder = RecordingADB(delay: true)
        let (server, _) = try fixture(executor: recorder)
        let req = try call("android_shell", ["command": .string("sleep 30")], key: "cancel-once")
        let running = Task { await server.handle(req) }
        while await recorder.commands.isEmpty { await Task.yield() }
        let competing = try result(await server.handle(call("android_tap", ["x": .number(1), "y": .number(2)])))
        XCTAssertEqual(competing.fields["isError"], .bool(true))
        _ = await server.handle(try request("notifications/cancelled", params: ["requestId": .number(1)], id: nil))
        let cancelled = try result(await running.value)
        XCTAssertEqual(cancelled.fields["isError"], .bool(true))
        _ = await server.handle(req)
        let commands = await recorder.commands
        XCTAssertEqual(commands.count, 1)
    }
    func testAuthenticatedLoopbackMCPAndAdmission() async throws {
        let (mcp, recorder) = try fixture()
        let server = LoopbackServer(routes: LoopbackRoutes(nativeMCP: mcp))
        let endpoint = try await server.start()
        addTeardownBlock { await server.stop() }
        var req = URLRequest(url: endpoint.baseURL.appendingPathComponent("mcp/native"))
        req.httpMethod = "POST"; req.httpBody = try call("android_status").body
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (_, unauthorized) = try await session.data(for: req)
        XCTAssertEqual((unauthorized as? HTTPURLResponse)?.statusCode, 401)
        req.setValue("Bearer " + endpoint.token, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (body, authorized) = try await session.data(for: req)
        XCTAssertEqual((authorized as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(try JSONValue.parse(body).fields["result"]?.fields["isError"], .bool(false))
        req.setValue("http://untrusted.invalid", forHTTPHeaderField: "Origin")
        let (_, forbidden) = try await session.data(for: req)
        XCTAssertEqual((forbidden as? HTTPURLResponse)?.statusCode, 403)
        let closed = LoopbackServer(routes: LoopbackRoutes(nativeMCP: mcp, admission: { .closed }))
        let closedEndpoint = try await closed.start()
        addTeardownBlock { await closed.stop() }
        req.url = closedEndpoint.baseURL.appendingPathComponent("mcp/native")
        req.setValue(nil, forHTTPHeaderField: "Origin")
        req.setValue("Bearer " + closedEndpoint.token, forHTTPHeaderField: "Authorization")
        let (_, rejected) = try await session.data(for: req)
        XCTAssertEqual((rejected as? HTTPURLResponse)?.statusCode, 503)
        let commands = await recorder.commands
        XCTAssertEqual(commands.count, 1)
    }

    #if os(macOS)
    func testOfficialDSHMCPClientRegistersAndCallsNativeAndroidTools() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let plugins = root.appendingPathComponent("plugins")
        guard FileManager.default.fileExists(atPath: plugins.appendingPathComponent("node_modules/@deepseek-ai/dsh-mcp-client/package.json").path) else {
            throw XCTSkip("Run npm ci in plugins to verify the official DSH MCP client")
        }
        let (mcp, recorder) = try fixture()
        let server = LoopbackServer(routes: LoopbackRoutes(nativeMCP: mcp))
        let endpoint = try await server.start()
        addTeardownBlock { await server.stop() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.currentDirectoryURL = plugins
        process.arguments = ["node", "--input-type=module", "--eval", #"""
        import assert from 'node:assert/strict'
        import { Context } from '@deepseek-ai/cordis'
        import SystemPrompt from '@deepseek-ai/dsh-system-prompt'
        import ToolRuntime from '@deepseek-ai/dsh-tools'
        import * as nativeToolExecutor from '@deepseek-ai/dsh-tool-executor-native'
        import { ToolCallId } from '@deepseek-ai/dsh-llm'
        import * as mcp from '@deepseek-ai/dsh-mcp-client'
        const ctx = new Context()
        try {
          await ctx.plugin(SystemPrompt)
          await ctx.plugin(ToolRuntime)
          await ctx.plugin(nativeToolExecutor)
          await ctx.plugin(mcp, { serverName: 'phone', transport: 'streamable-http',
            url: process.env.ADB_TEST_URL, headers: { Authorization: `Bearer ${process.env.ADB_TEST_TOKEN}` },
            failOnStartupError: true, toolCallTimeoutMs: 5000 })
          const names = ctx.tools.schemas().map(t => t.name)
          assert.equal(names.filter(n => n.startsWith('mcp__phone__android_')).length, 26)
          const { results } = await ctx.tools.execute({
            calls: [{ type: 'tool-call', id: ToolCallId('android-native-test'),
              name: 'mcp__phone__android_tap', arguments: JSON.stringify({ x: 20, y: 30 }) }],
            signal: new AbortController().signal,
          })
          assert.equal(results.length, 1)
          const [{ result }] = results
          assert.equal(result.isError, false, JSON.stringify(result))
          assert.match(JSON.stringify(result.content), /fixture/)
          console.log('official DSH tool call passed')
        } finally { await ctx.fiber.dispose() }
        """#]
        var environment = ProcessInfo.processInfo.environment
        environment["ADB_TEST_URL"] = endpoint.baseURL.appendingPathComponent("mcp/native").absoluteString
        environment["ADB_TEST_TOKEN"] = endpoint.token
        process.environment = environment
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        let deadline = Task {
            do { try await Task.sleep(nanoseconds: 20_000_000_000); if process.isRunning { process.terminate() } }
            catch {}
        }
        defer { deadline.cancel() }
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in continuation.resume(returning: process.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(status, 0, output)
        XCTAssertTrue(output.contains("official DSH tool call passed"), output)
        let commands = await recorder.commands
        XCTAssertEqual(commands, ["input tap 20 30"])
    }
    #endif
}

actor RecordingADB: ADBCommandExecuting {
    var commands: [String] = []
    var endpoints: [ADBEndpoint] = []
    var inputs: [Data] = []
    let output: ADBShellResult
    let delay: Bool
    init(output: ADBShellResult = ADBShellResult(stdout: Data("fixture".utf8)), delay: Bool = false) {
        self.output = output; self.delay = delay
    }
    func transfer(endpoint: ADBEndpoint, command: String, input: FileHandle?, output: FileHandle?, byteLimit: Int, timeout: TimeInterval) async throws -> ADBShellResult {
        if let input { inputs.append(try input.readToEnd() ?? Data()) }
        if let output { try output.write(contentsOf: self.output.stdout) }
        return try await shell(endpoint: endpoint, command: command, timeout: timeout, outputLimit: byteLimit)
    }
    func shell(endpoint: ADBEndpoint, command: String, timeout: TimeInterval, outputLimit: Int) async throws -> ADBShellResult {
        commands.append(command)
        endpoints.append(endpoint)
        if delay { try await Task.sleep(nanoseconds: 30_000_000_000) }
        return output
    }
    func shell(endpoint: ADBEndpoint, command: String, stdin: Data, timeout: TimeInterval, outputLimit: Int) async throws -> ADBShellResult {
        inputs.append(stdin)
        return try await shell(endpoint: endpoint, command: command, timeout: timeout, outputLimit: outputLimit)
    }
}
