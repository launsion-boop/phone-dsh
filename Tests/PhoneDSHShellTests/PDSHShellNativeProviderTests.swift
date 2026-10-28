// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — linked native provider contract tests (PLAN §2.1/§2.4).
//
// These are the accelerator-side acceptance tests for the production C ABI:
// the advertised names must be exactly the names the linked library executes,
// `phone` / `ctx` exist only with an injected PhoneToolBridge, and the linked
// provider runs each advertised command through the real Rust library.

import Foundation
import XCTest
import PhoneDSHAgentCore
import PhoneDSHShell

private struct NativeRunResult {
    var stdout = Data()
    var stderr = Data()
    var exitCode: Int32?
    var exitCount = 0
    var truncated = false

    var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

private func collectNative(_ stream: AsyncThrowingStream<ExecEvent, Error>) async throws
    -> NativeRunResult {
    var result = NativeRunResult()
    for try await event in stream {
        switch event {
        case .stdout(_, let data):
            result.stdout.append(data)
        case .stderr(_, let data):
            result.stderr.append(data)
        case .exit(let code, _, let truncated):
            result.exitCode = code
            result.exitCount += 1
            result.truncated = truncated
        }
    }
    return result
}

private final class NativeProviderTree {
    let root: URL
    let workspace: URL
    let home: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-native-\(UUID().uuidString)", isDirectory: true)
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

    func provider(toolBridge: (any PhoneToolBridge)? = nil,
                  limits: PDSHShellLimits = .default) -> PDSHShellProvider {
        PDSHShellProvider(workspaceRoot: root, limits: limits, toolBridge: toolBridge)
    }
}

private actor NativeBridgeRecorder {
    private(set) var calls: [(name: String, arguments: String)] = []

    func record(name: String, arguments: String) {
        calls.append((name, arguments))
    }
}

final class PDSHShellNativeProviderTests: XCTestCase {
    func testUnconfiguredProviderAdvertisesNothing() {
        let provider = PDSHShellProvider()
        XCTAssertTrue(provider.acceleratorNames.isEmpty)
        XCTAssertTrue(provider.helloCapabilities.accelerators.isEmpty)
        XCTAssertTrue(provider.helloCapabilities.confine.isEmpty)
        XCTAssertTrue(provider.channelCapabilities.isEmpty)
    }

    func testHelloAndChannelCapsAreTheSameSet() throws {
        let tree = try NativeProviderTree()
        let provider = tree.provider()
        XCTAssertEqual(provider.channelCapabilities,
                       provider.helloCapabilities.acceleratorCapabilities)
        XCTAssertEqual(provider.helloCapabilities.accelerators, provider.acceleratorNames)
    }
}

#if PDSH_WITH_XZSHELL

final class PDSHShellLinkedNativeProviderTests: XCTestCase {
    func testBridgePresenceControlsTheAdvertisedNames() throws {
        let tree = try NativeProviderTree()
        let withoutBridge = tree.provider()
        XCTAssertEqual(Set(withoutBridge.acceleratorNames),
                       Set(["jaq", "jq", "rg", "ts-parse", "ts-query"]))
        XCTAssertFalse(withoutBridge.acceleratorNames.contains("phone"))
        XCTAssertFalse(withoutBridge.acceleratorNames.contains("ctx"))
        XCTAssertEqual(withoutBridge.helloCapabilities.version, "0.1.0")
        XCTAssertEqual(withoutBridge.helloCapabilities.limits?.maxOutputBytes, 1_048_576)

        let withBridge = tree.provider(toolBridge: ClosurePhoneToolBridge { _, _ in "{}" })
        XCTAssertEqual(Set(withBridge.acceleratorNames),
                       Set(["ctx", "jaq", "jq", "phone", "rg", "ts-parse", "ts-query"]))
        XCTAssertEqual(withBridge.channelCapabilities,
                       withBridge.helloCapabilities.acceleratorCapabilities)
        XCTAssertEqual(Set(withBridge.channelCapabilities),
                       Set(withBridge.acceleratorNames.map { "accelerator:\($0)" }))
    }

    func testEveryAdvertisedAcceleratorRuns() async throws {
        let tree = try NativeProviderTree()
        try tree.write("a.txt", "alpha\nneedle here\n")
        try tree.write("in.json", "{\"a\":1}\n")
        try tree.write("a.rs", "fn main() {}\n")
        let recorder = NativeBridgeRecorder()
        let provider = tree.provider(toolBridge: ClosurePhoneToolBridge { name, arguments in
            await recorder.record(name: name, arguments: arguments)
            return "{\"ok\":true}"
        })

        let commands: [(String, [String])] = [
            ("rg", ["rg", "--json", "needle"]),
            ("jaq", ["jaq", "-c", ".a", "in.json"]),
            ("jq", ["jq", "-c", ".a", "in.json"]),
            ("ts-parse", ["ts-parse", "a.rs"]),
            ("ts-query", ["ts-query", "--captures", "a.rs", "(identifier) @id"]),
            ("phone", ["phone", "contacts.search", "{\"q\":\"ann\"}"]),
            ("ctx", ["ctx", "weather", "in", "Oslo"]),
        ]
        for (name, argv) in commands {
            XCTAssertTrue(provider.acceleratorNames.contains(name), "missing \(name)")
            let result = try await collectNative(provider.run(ExecRequest(
                execID: "native-\(name)", argv: argv, cwd: "/dsh/workspace")))
            XCTAssertEqual(result.exitCode, 0, "\(name) stderr: \(result.stderrText)")
            XCTAssertEqual(result.exitCount, 1, "\(name) must end with exactly one exit")
        }

        let calls = await recorder.calls
        XCTAssertEqual(calls.map { $0.name }, ["phone.contacts.search", "ctx.query"])
    }

    func testPhoneWithoutBridgeIsUnsupportedBeforeStarting() async throws {
        let tree = try NativeProviderTree()
        let provider = tree.provider()
        do {
            _ = try await collectNative(provider.run(ExecRequest(
                execID: "phone-without-bridge", argv: ["phone", "contacts.search", "{}"],
                cwd: "/dsh/workspace")))
            XCTFail("phone without a bridge must not run")
        } catch let error as PDSHShellError {
            XCTAssertEqual(error, .unsupportedCommand("phone"))
        }
    }

    func testLinkedBudgetTruncationIsReported() async throws {
        let tree = try NativeProviderTree()
        var text = ""
        for index in 0..<200 {
            text += "needle line \(index) padded to exceed the budget\n"
        }
        try tree.write("big.txt", text)
        let provider = tree.provider(limits: PDSHShellLimits(maxOutputBytes: 200))
        let result = try await collectNative(provider.run(ExecRequest(
            execID: "native-budget", argv: ["rg", "--json", "needle"], cwd: "/dsh/workspace")))
        XCTAssertEqual(result.exitCode, 0, "stderr: \(result.stderrText)")
        XCTAssertTrue(result.truncated)
        XCTAssertTrue(result.stdoutText.contains("pdsh-shell truncated"))
    }
}

#else

final class PDSHShellStubNativeProviderTests: XCTestCase {
    func testStubAdvertisesNothingEvenWithABridge() throws {
        let tree = try NativeProviderTree()
        let provider = tree.provider(toolBridge: ClosurePhoneToolBridge { _, _ in "{}" })
        XCTAssertTrue(provider.acceleratorNames.isEmpty)
        XCTAssertTrue(provider.helloCapabilities.accelerators.isEmpty)
        XCTAssertTrue(provider.channelCapabilities.isEmpty)
        XCTAssertEqual(provider.helloCapabilities.version, "not linked")
    }
}

#endif
