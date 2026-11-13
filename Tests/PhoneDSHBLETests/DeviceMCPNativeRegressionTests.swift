// SPDX-License-Identifier: MIT
import XCTest
import PhoneDSHAgentCore
import PhoneDSHLoopback
import PhoneDSHADB
@testable import PhoneDSHBLE

/// P05 regression: `/mcp/native` moved from `ADBMCPServer` (main 9b3b31e7) to the
/// composed `DeviceMCPServer`. Every Android tool, schema, error and the loopback
/// authorization must stay exactly as main served them; BLE tools are additive only.
final class DeviceMCPNativeRegressionTests: XCTestCase {
    /// Tool catalog served on main 9b3b31e7 (`ADBTools.descriptors` + `ADBPackageTools.descriptors`),
    /// in served order. Derived from `git show 9b3b31e7:Sources/PhoneDSHADB/ADB{Tools,PackageTools}.swift`.
    static let mainAndroidTools = [
        "android_connect", "android_status", "android_screenshot", "android_tap", "android_swipe",
        "android_input_text", "android_key", "android_launch_app", "android_ui_dump", "android_shell",
        "android_list_packages", "android_package_info", "android_install_apk", "android_uninstall_app",
        "android_force_stop", "android_clear_app_data", "android_set_app_enabled", "android_install_existing_app",
        "android_app_permission", "android_list_users", "android_open_uri", "android_logcat",
        "android_device_info", "android_list_apk_files", "android_delete_apk_file", "android_command_help",
    ]
    static let addedBLETools = ["ble_link_tools", "ble_link_call", "ble_link_result", "ble_devices", "ble_read", "ble_alert"]
    static let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// A fresh ADB server with isolated settings/receipts and a scripted executor (no device, no network).
    private func adbServer(enabled: Bool = true, executor: ScriptedADB) throws -> ADBMCPServer {
        let suite = "device-mcp-regression-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let settings = ADBSettings(defaults: defaults)
        try settings.save(ADBConfiguration(enabled: enabled, host: "192.0.2.1"))
        return ADBMCPServer(settings: settings, executor: executor, receiptDirectory: directory.appendingPathComponent("adb"))
    }
    /// Main's server (reference) and PR head's composed server, each over an identical, independent ADB stack.
    private func pair(enabled: Bool = true, output: ADBShellResult = ADBShellResult(stdout: Data("fixture".utf8)),
                      failure: String? = nil) throws -> (main: ADBMCPServer, mainADB: ScriptedADB, head: DeviceMCPServer, headADB: ScriptedADB) {
        let mainADB = ScriptedADB(output: output, failure: failure), headADB = ScriptedADB(output: output, failure: failure)
        let receipts = FileManager.default.temporaryDirectory.appendingPathComponent("device-mcp-regression-ble-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: receipts) }
        return (try adbServer(enabled: enabled, executor: mainADB), mainADB,
                DeviceMCPServer(receiptDirectory: receipts, adb: try adbServer(enabled: enabled, executor: headADB)), headADB)
    }
    private func body(_ method: String, params: JSONValue? = .object([:]), id: JSONValue? = .number(1)) throws -> Data {
        var fields: [String: JSONValue] = ["jsonrpc": .string("2.0"), "method": .string(method)]
        fields["params"] = params; fields["id"] = id
        return try JSONValue.object(fields).encoded()
    }
    private func post(_ body: Data, key: String? = nil) -> LoopbackRequest {
        LoopbackRequest(method: "POST", path: "/mcp/native", headers: key.map { ["X-PDSH-Idempotency-Key": $0] } ?? [:], body: body)
    }
    private func call(_ name: String, _ args: JSONValue) throws -> Data {
        try body("tools/call", params: .object(["name": .string(name), "arguments": args]))
    }
    private func assertSame(_ main: NativeMCPResponse, _ head: NativeMCPResponse, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(head.status, main.status, label, file: file, line: line)
        if main.body.isEmpty { XCTAssertTrue(head.body.isEmpty, label, file: file, line: line); return }
        XCTAssertEqual(try? JSONValue.parse(head.body), try? JSONValue.parse(main.body), label, file: file, line: line)
    }
    private func names(_ response: NativeMCPResponse) throws -> [String] {
        guard case .object(let root) = try JSONValue.parse(response.body), case .object(let result)? = root["result"],
              case .array(let tools)? = result["tools"] else { XCTFail("missing tools"); return [] }
        return tools.map { tool -> String in
            if case .object(let fields) = tool, case .string(let name)? = fields["name"] { return name }
            return ""
        }
    }
    private func tools(_ response: NativeMCPResponse) throws -> [JSONValue] {
        guard case .object(let root) = try JSONValue.parse(response.body), case .object(let result)? = root["result"],
              case .array(let tools)? = result["tools"] else { return [] }
        return tools
    }

    func testToolsListKeepsMainCatalogExactlyThenAppendsConnectedBLE() async throws {
        let (main, _, head, _) = try pair()
        let mainList = await main.handle(post(try body("tools/list")))
        let headList = await head.handle(post(try body("tools/list")))
        XCTAssertEqual(try names(mainList), Self.mainAndroidTools)
        // W5 (spec/bot/v1/README.md §2): the ADB class is configured in this
        // fixture, so Android stays exactly as main; BLE is not connected and
        // its whole group is absent until it is.
        XCTAssertEqual(try names(headList), Self.mainAndroidTools)
        let mainTools = try tools(mainList), headTools = try tools(headList)
        XCTAssertEqual(Array(headTools.prefix(mainTools.count)), mainTools, "Android names, descriptions and inputSchemas must be unchanged")
        XCTAssertEqual(Set(try names(headList)).count, headTools.count, "no duplicate tool names")
        XCTAssertFalse(try names(headList).contains { $0.hasPrefix("ssh") }, "SSH is an exec accelerator, never a native MCP tool")

        // Once the BLE class is connected/configured, the very next list
        // appends the same six tools after the untouched Android catalog.
        let adb = try adbServer(enabled: true, executor: ScriptedADB(output: ADBShellResult(stdout: Data("fixture".utf8))))
        let receiptDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("device-mcp-ble-visible-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: receiptDirectory) }
        let ble = DeviceMCPServer(receiptDirectory: receiptDirectory, adb: adb,
                                  bleToolVisibility: { true })
        let bleList = await ble.handle(post(try body("tools/list")))
        XCTAssertEqual(try names(bleList), Self.mainAndroidTools + Self.addedBLETools)
        let bleTools = try tools(bleList)
        XCTAssertEqual(Array(bleTools.prefix(mainTools.count)), mainTools)
        XCTAssertEqual(Set(try names(bleList)).count, bleTools.count, "no duplicate tool names")
    }

    func testInitializeKeepsNegotiationAndAndroidInstructions() async throws {
        let (main, _, head, _) = try pair()
        for version in ["2024-11-05", "2025-03-26", "2025-06-18", "1999-01-01"] {
            let request = post(try body("initialize", params: .object(["protocolVersion": .string(version)])))
            let mainRoot = try JSONValue.parse(await main.handle(request).body), headRoot = try JSONValue.parse(await head.handle(request).body)
            guard case .object(let m) = mainRoot, case .object(let mr)? = m["result"],
                  case .object(let h) = headRoot, case .object(let hr)? = h["result"] else { return XCTFail("initialize result") }
            XCTAssertEqual(h["id"], m["id"]); XCTAssertEqual(h["jsonrpc"], m["jsonrpc"])
            XCTAssertEqual(hr["protocolVersion"], mr["protocolVersion"], version)
            XCTAssertEqual(hr["capabilities"], mr["capabilities"], version)
            guard case .string(let mainText)? = mr["instructions"], case .string(let headText)? = hr["instructions"] else { return XCTFail("instructions") }
            XCTAssertTrue(headText.hasPrefix(mainText), "Android instructions must be served verbatim")
            // Intentional, additive #59 delta (no repo consumer reads serverInfo; the Worker names the server "phone").
            XCTAssertEqual(hr["serverInfo"], .object(["name": .string("phone-dsh-devices"), "version": .string("1.1.0")]))
            XCTAssertEqual(mr["serverInfo"], .object(["name": .string("phone-dsh-android"), "version": .string("1.0.0")]))
        }
    }

    func testProtocolErrorsAndNotificationsAreIdenticalToMain() async throws {
        let (main, _, head, _) = try pair()
        let cases: [(String, LoopbackRequest)] = [
            ("GET 405", LoopbackRequest(method: "GET", path: "/mcp/native")),
            ("invalid JSON", post(Data("{".utf8))),
            ("oversize body", post(Data(repeating: 0x20, count: 16 * 1024 + 1))),
            ("wrong jsonrpc", post(try JSONValue.object(["jsonrpc": .string("1.0"), "id": .number(1), "method": .string("ping")]).encoded())),
            ("ping", post(try body("ping"))),
            ("unknown method", post(try body("resources/list"))),
            ("null id", post(try body("tools/list", id: .null))),
            ("null id call", post(try body("tools/call", params: .object(["name": .string("android_status")]), id: .null))),
            ("initialized notification", post(try body("notifications/initialized", id: nil))),
            ("cancel unknown", post(try body("notifications/cancelled", params: .object(["requestId": .number(9)]), id: nil))),
            ("call notification", post(try body("tools/call", params: .object(["name": .string("android_status")]), id: nil))),
            ("missing tool name", post(try body("tools/call", params: .object([:])))),
            ("unknown android tool", post(try call("android_reboot", .object([:])))),
            ("SSH name is not a native tool", post(try call("ssh", .object(["host": .string("192.0.2.9"), "command": .string("id")])))),
            ("SSH exec name", post(try call("ssh_exec", .object(["command": .string("id")])))),
            ("invalid tap arguments", post(try call("android_tap", .object(["x": .number(-1), "y": .number(2)])))),
            ("extra argument rejected", post(try call("android_status", .object(["verbose": .bool(true)])))),
            ("arguments not object", post(try call("android_status", .array([])))),
            ("bad idempotency key", post(try call("android_status", .object([:])), key: "")),
        ]
        for (label, request) in cases {
            assertSame(await main.handle(request), await head.handle(request), label)
        }
    }

    func testAndroidCallsRouteToTheSameADBImplementationAndReceipts() async throws {
        let (main, mainADB, head, headADB) = try pair()
        let goldenTap = try JSONValue.parse(Data(contentsOf: Self.repoRoot.appendingPathComponent("spec/v1/golden/native-mcp/tap.json")))
        guard case .object(let tap) = goldenTap, let tapRequest = tap["request"], let tapResponse = tap["response"],
              case .string(let tapCommand)? = tap["android_command"] else { return XCTFail("tap golden") }
        let request = post(try tapRequest.encoded(), key: "tap-once")
        let headFirst = await head.handle(request)
        assertSame(await main.handle(request), headFirst, "golden tap")
        XCTAssertEqual(try JSONValue.parse(headFirst.body), tapResponse)
        // Same receipt store semantics: a replay never taps twice, and a conflicting key is refused.
        assertSame(await main.handle(request), await head.handle(request), "idempotent replay")
        let conflict = post(try call("android_tap", .object(["x": .number(1), "y": .number(2)])), key: "tap-once")
        let headConflict = await head.handle(conflict)
        assertSame(await main.handle(conflict), headConflict, "idempotency conflict")
        guard case .object(let conflictRoot) = try JSONValue.parse(headConflict.body), case .object(let error)? = conflictRoot["error"] else { return XCTFail("conflict error") }
        XCTAssertEqual(error["code"], .number(-32602))
        let mainCommands = await mainADB.commands, headCommands = await headADB.commands
        XCTAssertEqual(headCommands, [tapCommand]); XCTAssertEqual(headCommands, mainCommands)

        // Package-management golden vectors through the composed server.
        let vectors = try JSONValue.parse(Data(contentsOf: Self.repoRoot.appendingPathComponent("spec/v1/golden/native-mcp/package-management.json")))
        guard case .array(let rows) = vectors else { return XCTFail("package vectors") }
        for row in rows {
            guard case .object(let fields) = row, case .string(let stdout)? = fields["stdout"], let request = fields["request"],
                  case .string(let command)? = fields["android_command"] else { return XCTFail("vector") }
            let output = ADBShellResult(stdout: Data(stdout.utf8))
            let (main, mainADB, head, headADB) = try pair(output: output)
            let headResponse = await head.handle(post(try request.encoded()))
            assertSame(await main.handle(post(try request.encoded())), headResponse, command)
            XCTAssertEqual(try JSONValue.parse(headResponse.body), fields["response"], command)
            let m = await mainADB.commands, h = await headADB.commands
            XCTAssertEqual(h, [command]); XCTAssertEqual(h, m)
        }
    }

    func testDisabledConnectAndExecutorFailureMatchMain() async throws {
        // android_connect enables a disabled target (connect.json golden) through the composed server.
        let golden = try JSONValue.parse(Data(contentsOf: Self.repoRoot.appendingPathComponent("spec/v1/golden/native-mcp/connect.json")))
        guard case .object(let connect) = golden, let connectRequest = connect["request"] else { return XCTFail("connect golden") }
        let (main, _, head, headADB) = try pair(enabled: false)
        let disabled = post(try call("android_status", .object([:])))
        assertSame(await main.handle(disabled), await head.handle(disabled), "disabled control")
        let connectResponse = await head.handle(post(try connectRequest.encoded()))
        assertSame(await main.handle(post(try connectRequest.encoded())), connectResponse, "connect golden")
        XCTAssertEqual(try JSONValue.parse(connectResponse.body), connect["response"])
        let headCommands = await headADB.commands
        guard case .string(let connectCommand)? = connect["android_command"] else { return XCTFail("connect command") }
        XCTAssertEqual(headCommands, [connectCommand])

        // Executor failure (disconnect) yields the same isError text, not a BLE wrapper.
        let failing = try pair(failure: "connection reset")
        let shell = post(try call("android_shell", .object(["command": .string("id")])))
        let failed = await failing.head.handle(shell)
        assertSame(await failing.main.handle(shell), failed, "executor failure")
        XCTAssertTrue(String(decoding: failed.body, as: UTF8.self).contains("connection reset"))
        let nonzero = try pair(output: ADBShellResult(stderr: Data("denied".utf8), exitCode: 1))
        let exitCall = post(try call("android_shell", .object(["command": .string("false")])))
        assertSame(await nonzero.main.handle(exitCall), await nonzero.head.handle(exitCall), "nonzero exit")
    }

    func testCancellationNotificationStillReachesActiveADBCall() async throws {
        let (_, _, head, headADB) = try pair()
        await headADB.setBlocking(true)
        let running = Task { await head.handle(post(try call("android_shell", .object(["command": .string("sleep 30")])))) }
        var polls = 0
        while await headADB.commands.isEmpty, polls < 500 { polls += 1; try await Task.sleep(nanoseconds: 10_000_000) }
        let commands = await headADB.commands
        XCTAssertEqual(commands, ["sleep 30"])
        let cancel = await head.handle(post(try body("notifications/cancelled", params: .object(["requestId": .number(1)]), id: nil)))
        XCTAssertEqual(cancel.status, 202)
        let response = try await running.value
        let text = String(decoding: response.body, as: UTF8.self)
        XCTAssertTrue(text.contains("\"isError\":true"), text)
    }

    func testAuthenticatedLoopbackAndAdmissionUnchangedForComposedServer() async throws {
        let (_, _, head, headADB) = try pair()
        let server = LoopbackServer(routes: LoopbackRoutes(nativeMCP: head))
        let endpoint = try await server.start()
        addTeardownBlock { await server.stop() }
        var req = URLRequest(url: endpoint.baseURL.appendingPathComponent("mcp/native"))
        req.httpMethod = "POST"; req.httpBody = try call("android_status", .object([:]))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (_, unauthorized) = try await session.data(for: req)
        XCTAssertEqual((unauthorized as? HTTPURLResponse)?.statusCode, 401)
        req.setValue("Bearer " + endpoint.token, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (body, authorized) = try await session.data(for: req)
        XCTAssertEqual((authorized as? HTTPURLResponse)?.statusCode, 200)
        guard case .object(let root) = try JSONValue.parse(body), case .object(let result)? = root["result"] else { return XCTFail("result") }
        XCTAssertEqual(result["isError"], .bool(false))
        req.setValue("http://untrusted.invalid", forHTTPHeaderField: "Origin")
        let (_, forbidden) = try await session.data(for: req)
        XCTAssertEqual((forbidden as? HTTPURLResponse)?.statusCode, 403)
        let closed = LoopbackServer(routes: LoopbackRoutes(nativeMCP: head, admission: { .closed }))
        let closedEndpoint = try await closed.start()
        addTeardownBlock { await closed.stop() }
        req.url = closedEndpoint.baseURL.appendingPathComponent("mcp/native")
        req.setValue(nil, forHTTPHeaderField: "Origin")
        req.setValue("Bearer " + closedEndpoint.token, forHTTPHeaderField: "Authorization")
        let (_, rejected) = try await session.data(for: req)
        XCTAssertEqual((rejected as? HTTPURLResponse)?.statusCode, 503)
        req.httpBody = try call("ble_devices", .object([:]))
        let (_, rejectedBLE) = try await session.data(for: req)
        XCTAssertEqual((rejectedBLE as? HTTPURLResponse)?.statusCode, 503, "BLE calls share the same admission gate")
        let commands = await headADB.commands
        XCTAssertEqual(commands, ["getprop ro.product.model; getprop ro.build.version.release; wm size"])
    }
}

actor ScriptedADB: ADBCommandExecuting {
    private(set) var commands: [String] = []
    let output: ADBShellResult
    let failure: String?
    private var blocking = false
    init(output: ADBShellResult, failure: String? = nil) { self.output = output; self.failure = failure }
    func setBlocking(_ value: Bool) { blocking = value }
    func shell(endpoint: ADBEndpoint, command: String, timeout: TimeInterval, outputLimit: Int) async throws -> ADBShellResult {
        commands.append(command)
        if blocking { try await Task.sleep(nanoseconds: 30_000_000_000) }
        if let failure { throw ADBFailure(failure) }
        return output
    }
    func shell(endpoint: ADBEndpoint, command: String, stdin: Data, timeout: TimeInterval, outputLimit: Int) async throws -> ADBShellResult {
        try await shell(endpoint: endpoint, command: command, timeout: timeout, outputLimit: outputLimit)
    }
}
