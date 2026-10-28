// SPDX-License-Identifier: MIT
// W4-SWIFT checks for PhoneDSHShell (PLAN §2.1/§2.4, D12).
//
// With PDSH_WITH_XZSHELL=1 the linked tests drive the real Rust pdsh-shell library
// through the provider: `rg --json` over a fixture tree, a `jaq` filter,
// cancellation mid-run, timeout, output truncation and the capability JSON.
// Without the switch the stub tests prove the module still builds and fails
// loudly instead of claiming accelerators.

import Foundation
import XCTest
import PhoneDSHAgentCore
import PhoneDSHShell

/// Result of draining one provider stream.
private struct XZRunResult {
    var stdout = Data()
    var stderr = Data()
    var exitCode: Int32?
    var signal: Int32?
    var exitCount = 0
    var truncated = false
    var lastEventWasExit = false

    var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

private func collect(_ stream: AsyncThrowingStream<ExecEvent, Error>) async throws -> XZRunResult {
    var result = XZRunResult()
    for try await event in stream {
        result.lastEventWasExit = false
        switch event {
        case .stdout(_, let data):
            result.stdout.append(data)
        case .stderr(_, let data):
            result.stderr.append(data)
        case .exit(let code, let signal, let truncated):
            result.exitCode = code
            result.signal = signal
            result.truncated = truncated
            result.exitCount += 1
            result.lastEventWasExit = true
        }
    }
    return result
}

/// One throw-away workspace tree with the two materialized mounts.
private final class PDSHShellTestTree {
    let root: URL
    let workspace: URL
    let home: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-shell-swift-\(UUID().uuidString)", isDirectory: true)
        workspace = root.appendingPathComponent("materialized/workspace", isDirectory: true)
        home = root.appendingPathComponent("materialized/home", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func write(_ relative: String, _ text: String) throws {
        let url = workspace.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func provider(limits: PDSHShellLimits = .default,
                  toolBridge: (any PhoneToolBridge)? = nil) -> PDSHShellProvider {
        PDSHShellProvider(materializedWorkspace: workspace,
                         materializedHome: home,
                         limits: limits,
                         toolBridge: toolBridge)
    }
}

// MARK: - Common contract

final class PDSHShellProviderTests: XCTestCase {
    func testEnvironmentAndTierContract() {
        let provider = PDSHShellProvider()
        XCTAssertTrue(provider.capabilities.environment.contains("pdsh-shell"))
        XCTAssertFalse(provider.capabilities.network)
        XCTAssertTrue(provider.capabilities.persistentWorkspace)
        XCTAssertEqual(Set(provider.capabilities.tiers), Set([.interactive, .session]))
        XCTAssertTrue(provider.helloCapabilities.readOnly)
    }

    func testProviderEqualityIsConfigurable() throws {
        let tree = try PDSHShellTestTree()
        XCTAssertEqual(tree.provider(), tree.provider())
        XCTAssertEqual(tree.provider(), tree.provider(limits: .default))
        let other = try PDSHShellTestTree()
        XCTAssertNotEqual(tree.provider(), other.provider())
        XCTAssertTrue(tree.provider() != tree.provider(
            toolBridge: ClosurePhoneToolBridge { _, _ in "{}" }))
    }

    func testDefaultFileLimitFollowsTheSingleFileBudget() {
        // budgets.md §4, 8 GiB tier: the accelerator read limit follows the
        // host single_file_limit, not the per-mutation wire cap.
        XCTAssertEqual(PDSHShellLimits.defaultMaxFileBytes, 64 * 1024 * 1024)
        XCTAssertEqual(PDSHShellLimits.default.maxFileBytes,
                       PDSHShellLimits.defaultMaxFileBytes)
        let configured = PDSHShellLimits(maxFileBytes: 128 * 1024 * 1024)
        XCTAssertEqual(configured.maxFileBytes, 128 * 1024 * 1024,
                       "the host-configured limit still overrides the default")
    }
}

#if PDSH_WITH_XZSHELL

// MARK: - Linked provider (real Rust pdsh-shell)

final class PDSHShellLinkedProviderTests: XCTestCase {
    func testHelloAdvertisesTheLibraryCapabilitiesAndConfine() throws {
        let tree = try PDSHShellTestTree()
        let provider = tree.provider()
        let hello = provider.helloCapabilities

        XCTAssertEqual(hello.version, "0.1.0")
        // Without a PhoneToolBridge the library does not register phone/ctx,
        // so the provider must not advertise them either.
        XCTAssertEqual(Set(hello.accelerators),
                       Set(["jaq", "jq", "rg", "ts-parse", "ts-query"]))
        XCTAssertEqual(hello.accelerators, provider.acceleratorNames)
        XCTAssertEqual(hello.accelerators.sorted(), hello.accelerators,
                       "pdsh_caps_json_with_bridge advertises the accelerators sorted")
        for required in ["rg", "jaq", "ts-parse", "ts-query"] {
            XCTAssertTrue(hello.accelerators.contains(required), "missing \(required)")
        }
        XCTAssertFalse(hello.accelerators.contains("phone"))
        XCTAssertFalse(hello.accelerators.contains("ctx"))
        XCTAssertFalse(hello.accelerators.contains("bash"))
        XCTAssertFalse(hello.accelerators.contains("echo"))

        let bridged = tree.provider(toolBridge: ClosurePhoneToolBridge { _, _ in "{}" })
        XCTAssertEqual(Set(bridged.helloCapabilities.accelerators),
                       Set(["ctx", "jaq", "jq", "phone", "rg", "ts-parse", "ts-query"]))

        XCTAssertEqual(hello.confine, ["read-only", "workspace-write"])
        XCTAssertTrue(hello.readOnly)
        XCTAssertEqual(hello.limits?.timeout, 30_000)
        XCTAssertEqual(hello.limits?.maxOutputBytes, 1_048_576)
        XCTAssertEqual(hello.limits?.maxFiles, 10_000)
        XCTAssertEqual(hello.limits?.maxFileBytes, 15 * 1024 * 1024)

        let workspaceMount = try XCTUnwrap(
            hello.mounts.first { $0.guestPath == "/dsh/workspace" })
        XCTAssertEqual(workspaceMount.hostPath,
                       tree.workspace.standardizedFileURL.path)
        XCTAssertTrue(workspaceMount.readOnly)
        let homeMount = try XCTUnwrap(hello.mounts.first { $0.guestPath == "/dsh/home" })
        XCTAssertEqual(homeMount.hostPath, tree.home.standardizedFileURL.path)

        XCTAssertEqual(provider.channelCapabilities,
                       provider.channelAcceleratorNames.map { "accelerator:\($0)" })
        XCTAssertEqual(Set(provider.channelAcceleratorNames),
                       Set(["jaq", "jq", "rg", "ts-parse", "ts-query"]),
                       "without a PhoneToolBridge the host may only advertise commands it can run")
        XCTAssertFalse(provider.channelCapabilities.contains("accelerator:phone"))
        XCTAssertFalse(provider.channelCapabilities.contains("accelerator:ctx"))
        XCTAssertEqual(PDSHShellProvider.availableAccelerators,
                       [.rg, .jaq, .jq, .tsParse, .tsQuery],
                       "phone/ctx require a bridge and are not unconditionally available")
        XCTAssertEqual(hello, tree.provider().helloCapabilities)
    }

    func testChannelCapsIncludeBridgeCommandsOnlyWithAnInjectedBridge() throws {
        let tree = try PDSHShellTestTree()
        let provider = tree.provider()
        XCTAssertEqual(Set(provider.channelAcceleratorNames),
                       Set(["jaq", "jq", "rg", "ts-parse", "ts-query"]))

        let bridged = tree.provider(toolBridge: ClosurePhoneToolBridge { _, _ in "{}" })
        XCTAssertEqual(Set(bridged.channelAcceleratorNames),
                       Set(provider.acceleratorNames))
        XCTAssertEqual(Set(bridged.channelCapabilities),
                       Set(provider.acceleratorNames.map { "accelerator:\($0)" }))
    }

    func testWorkspaceRootInitializerMountsTheMaterializedCopies() throws {
        let tree = try PDSHShellTestTree()
        let provider = PDSHShellProvider(workspaceRoot: tree.root)
        let workspaceMount = try XCTUnwrap(
            provider.helloCapabilities.mounts.first { $0.guestPath == "/dsh/workspace" })
        XCTAssertEqual(workspaceMount.hostPath,
                       tree.workspace.standardizedFileURL.path)
        let homeMount = try XCTUnwrap(
            provider.helloCapabilities.mounts.first { $0.guestPath == "/dsh/home" })
        XCTAssertEqual(homeMount.hostPath, tree.home.standardizedFileURL.path)
    }

    func testRgJSONLinesThroughTheProvider() async throws {
        let tree = try PDSHShellTestTree()
        try tree.write("src/one.txt", "alpha\nneedle here\n")
        try tree.write("src/two.txt", "nothing\nneedle again\n")
        try tree.write("notes.md", "no match in this file\n")
        let provider = tree.provider()

        let result = try await collect(provider.run(ExecRequest(
            execID: "rg-1", argv: ["rg", "--json", "needle"],
            cwd: "/dsh/workspace", env: ["TERM": "xterm-256color"])))
        XCTAssertEqual(result.exitCode, 0, "stderr: \(result.stderrText)")
        XCTAssertNil(result.signal)
        XCTAssertEqual(result.exitCount, 1)
        XCTAssertTrue(result.lastEventWasExit)
        XCTAssertFalse(result.truncated)

        let records = try result.stdoutText
            .split(separator: "\n")
            .map { line -> [String: Any] in
                let data = Data(line.utf8)
                return try XCTUnwrap(
                    JSONSerialization.jsonObject(with: data) as? [String: Any])
            }
        XCTAssertEqual(records.first?["type"] as? String, "begin")
        XCTAssertEqual(records.last?["type"] as? String, "summary")

        let matches = records.filter { $0["type"] as? String == "match" }
        XCTAssertEqual(matches.count, 2)
        let paths = Set(matches.compactMap {
            (($0["data"] as? [String: Any])?["path"] as? [String: Any])?["text"] as? String
        })
        XCTAssertEqual(paths, Set(["src/one.txt", "src/two.txt"]))
        let texts = matches.compactMap {
            (($0["data"] as? [String: Any])?["lines"] as? [String: Any])?["text"] as? String
        }
        XCTAssertTrue(texts.allSatisfy { $0.contains("needle") })
    }

    func testJaqFilterThroughTheProvider() async throws {
        let tree = try PDSHShellTestTree()
        try tree.write("in.json", "{\"a\":1,\"b\":[2,3]}\n")
        let provider = tree.provider()

        let compact = try await collect(provider.run(ExecRequest(
            execID: "jaq-1", argv: ["jaq", "-c", ".a", "in.json"],
            cwd: "/dsh/workspace")))
        XCTAssertEqual(compact.exitCode, 0, "stderr: \(compact.stderrText)")
        XCTAssertEqual(compact.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines), "1")

        let sum = try await collect(provider.run(ExecRequest(
            execID: "jaq-2", argv: ["jaq", "-c", ".b | add", "in.json"],
            cwd: "/dsh/workspace")))
        XCTAssertEqual(sum.exitCode, 0, "stderr: \(sum.stderrText)")
        XCTAssertEqual(sum.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines), "5")
    }

    func testPhoneAndCtxAcceleratorsForwardToTheInjectedBridge() async throws {
        let tree = try PDSHShellTestTree()
        let recorder = PDSHShellBridgeRecorder()
        let bridge = ClosurePhoneToolBridge { name, arguments in
            await recorder.record(name: name, arguments: arguments)
            return "{\"ok\":true}"
        }
        let provider = tree.provider(toolBridge: bridge)

        let phone = try await collect(provider.run(ExecRequest(
            execID: "phone-1", argv: ["phone", "contacts.search", "{\"q\":\"ann\"}"],
            cwd: "/dsh/workspace")))
        XCTAssertEqual(phone.exitCode, 0, "stderr: \(phone.stderrText)")
        XCTAssertTrue(phone.stdoutText.contains("{\"ok\":true}"))

        let ctx = try await collect(provider.run(ExecRequest(
            execID: "ctx-1", argv: ["ctx", "weather", "in", "Oslo"],
            cwd: "/dsh/workspace")))
        XCTAssertEqual(ctx.exitCode, 0, "stderr: \(ctx.stderrText)")
        XCTAssertTrue(ctx.stdoutText.contains("{\"ok\":true}"))

        let calls = await recorder.calls
        XCTAssertEqual(calls.map(\.name), ["phone.contacts.search", "ctx.query"])
        XCTAssertEqual(calls.first?.arguments, "{\"q\":\"ann\"}")
        XCTAssertEqual(calls.last?.arguments, "{\"q\":\"weather in Oslo\"}")
    }

    func testCancelMidRunReportsCancelledExit() async throws {
        let tree = try PDSHShellTestTree()
        let gate = PDSHShellBridgeGate()
        let provider = tree.provider(toolBridge: PDSHShellGatedBridge(gate: gate))
        let stream = provider.run(ExecRequest(execID: "cancel-1",
                                              argv: ["phone", "slow.tool", "{}"],
                                              cwd: "/dsh/workspace"))
        let collecting = Task { try await collect(stream) }

        await gate.waitUntilEntered()
        await provider.cancel(execID: "cancel-1")
        await gate.release()

        let result = try await collecting.value
        XCTAssertEqual(result.exitCount, 1)
        XCTAssertTrue(result.lastEventWasExit)
        XCTAssertEqual(result.exitCode, 130, "a cancelled accelerator exits 130")
        XCTAssertNil(result.signal)
    }

    func testTimeoutIsReportedAsTimedOutAndNeverQuiescent() async throws {
        let tree = try PDSHShellTestTree()
        let provider = tree.provider(
            limits: PDSHShellLimits(timeoutMilliseconds: 25),
            toolBridge: PDSHShellSlowBridge())
        let result = try await collect(provider.run(ExecRequest(
            execID: "timeout-1", argv: ["phone", "slow.tool", "{}"],
            cwd: "/dsh/workspace")))
        XCTAssertEqual(result.exitCount, 1)
        XCTAssertTrue(result.lastEventWasExit)
        XCTAssertEqual(result.exitCode, 124,
                       "the FFI deadline cancel exits 124, not a normal exit")
        XCTAssertNil(result.signal)
    }

    func testOutputTruncationIsReportedOnTheExitEvent() async throws {
        let tree = try PDSHShellTestTree()
        var text = ""
        for index in 0..<200 {
            text += "needle line \(index) padded to make the output large\n"
        }
        try tree.write("big.txt", text)
        let provider = tree.provider(limits: PDSHShellLimits(maxOutputBytes: 200))
        let result = try await collect(provider.run(ExecRequest(
            execID: "truncate-1", argv: ["rg", "--json", "needle"],
            cwd: "/dsh/workspace")))
        XCTAssertEqual(result.exitCode, 0, "stderr: \(result.stderrText)")
        XCTAssertTrue(result.truncated)
        XCTAssertTrue(result.stdoutText.contains("pdsh-shell truncated"),
                      "the Rust sink inserts its truncation marker")
        XCTAssertLessThan(result.stdout.count, 1_024)
        XCTAssertGreaterThan(result.stdout.count, 200)
    }

    func testRejectsCommandsOutsideTheAdvertisedAccelerators() async throws {
        let tree = try PDSHShellTestTree()
        let provider = tree.provider()
        do {
            _ = try await collect(provider.run(ExecRequest(
                execID: "bash-1", argv: ["bash", "-c", "rm -rf /"],
                cwd: "/dsh/workspace")))
            XCTFail("a general shell must not be forwarded to the provider")
        } catch let error as PDSHShellError {
            XCTAssertEqual(error, .unsupportedCommand("bash"))
        }
    }

    func testRejectsACwdOutsideTheMounts() async throws {
        let tree = try PDSHShellTestTree()
        let provider = tree.provider()
        do {
            _ = try await collect(provider.run(ExecRequest(
                execID: "escape-1", argv: ["rg", "x"], cwd: "/etc")))
            XCTFail("cwd outside the mounts must fail")
        } catch let error as PDSHShellError {
            if case .invalidRequest = error { } else {
                XCTFail("unexpected error \(error)")
            }
        }
    }

    func testHostCwdUnderTheMaterializedWorkspaceIsMappedToTheGuestPath() async throws {
        let tree = try PDSHShellTestTree()
        try tree.write("host.txt", "needle from a host cwd\n")
        let provider = tree.provider()
        let result = try await collect(provider.run(ExecRequest(
            execID: "host-cwd-1", argv: ["rg", "--files"],
            cwd: tree.workspace.path)))
        XCTAssertEqual(result.exitCode, 0, "stderr: \(result.stderrText)")
        XCTAssertTrue(result.stdoutText.contains("host.txt"))
    }

    func testUnconfiguredProviderFailsLoudly() async throws {
        let provider = PDSHShellProvider()
        do {
            _ = try await collect(provider.run(ExecRequest(
                execID: "none-1", argv: ["rg", "x"], cwd: "/dsh/workspace")))
            XCTFail("a provider without a materialized workspace must fail")
        } catch let error as PDSHShellError {
            XCTAssertEqual(error, .notConfigured)
        }
        await provider.cancel(execID: "none-1")
    }
}

/// Records the tool calls the `phone` / `ctx` accelerators forward.
private actor PDSHShellBridgeRecorder {
    struct Call: Sendable, Equatable {
        var name: String
        var arguments: String
    }

    private(set) var calls: [Call] = []

    func record(name: String, arguments: String) {
        calls.append(Call(name: name, arguments: arguments))
    }
}

/// Gate that lets a test hold the `phone` accelerator inside its host bridge.
private actor PDSHShellBridgeGate {    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func markEntered() {
        entered = true
        for waiter in entryWaiters { waiter.resume() }
        entryWaiters.removeAll()
    }

    func waitForRelease() async {
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func release() {
        for waiter in releaseWaiters { waiter.resume() }
        releaseWaiters.removeAll()
    }
}

private struct PDSHShellGatedBridge: PhoneToolBridge {
    let gate: PDSHShellBridgeGate

    func callTool(name: String, arguments: String) async throws -> String {
        await gate.markEntered()
        await gate.waitForRelease()
        return "{\"tool\":\"\(name)\",\"ok\":true}"
    }
}

private struct PDSHShellSlowBridge: PhoneToolBridge {
    func callTool(name: String, arguments: String) async throws -> String {
        try? await Task.sleep(nanoseconds: 200_000_000)
        return "{\"tool\":\"\(name)\",\"ok\":true}"
    }
}

#else

// MARK: - Stub provider (no Rust library linked)

final class PDSHShellStubProviderTests: XCTestCase {
    func testStubAdvertisesNoAccelerators() throws {
        let provider = PDSHShellProvider()
        XCTAssertTrue(PDSHShellProvider.availableAccelerators.isEmpty)
        XCTAssertTrue(provider.acceleratorNames.isEmpty)
        XCTAssertTrue(provider.helloCapabilities.accelerators.isEmpty)
        XCTAssertTrue(provider.helloCapabilities.confine.isEmpty)
        XCTAssertEqual(provider.helloCapabilities.version, "not linked")
        XCTAssertEqual(provider.capabilities.environment, "pdsh-shell not linked")
        XCTAssertTrue(provider.channelCapabilities.isEmpty)

        let tree = try PDSHShellTestTree()
        let configured = tree.provider()
        XCTAssertTrue(configured.channelAcceleratorNames.isEmpty)
        // The mount configuration is still reported; nothing is executed.
        XCTAssertEqual(configured.helloCapabilities.mounts.count, 2)
    }

    func testStubFailsEveryExecWithNotLinked() async throws {
        let tree = try PDSHShellTestTree()
        let provider = tree.provider()
        let request = ExecRequest(execID: "exec-1", argv: ["rg", "needle"],
                                  cwd: "/dsh/workspace")
        do {
            for try await _ in provider.run(request) {
                XCTFail("the pdsh-shell stub must not emit events")
            }
            XCTFail("the pdsh-shell stub must fail")
        } catch let error as PDSHShellError {
            XCTAssertEqual(error, .notLinked)
            XCTAssertTrue(error.localizedDescription.contains("pdsh-shell not linked"))
        }
    }

    func testStubCancelIsSafe() async {
        await PDSHShellProvider().cancel(execID: "exec-1")
        await PDSHShellProvider(materializedWorkspace: URL(fileURLWithPath: "/tmp"),
                              toolBridge: ClosurePhoneToolBridge { _, _ in "{}" })
            .cancel(execID: "exec-2")
    }
}

#endif
