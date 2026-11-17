// SPDX-License-Identifier: MIT

import XCTest
import PhoneDSHAgentCore
@testable import PhoneDSHShell

private final class FakeContactsQuery: PhoneBotContactsQuerying, @unchecked Sendable {
    private(set) var sessions: [String] = []
    func runContactsCommand(arguments: [String], callerSessionID: String) async
        -> PhoneRecordCommandResult {
        sessions.append(callerSessionID)
        return PhoneRecordCommandResult(
            stdout: #"{"ok":true,"tool":"contacts.search","data":{"caller":"\#(callerSessionID)"}}"#,
            exitCode: 0)
    }
}

private final class FakeContactsClassifier: PhoneContactsSessionClassifying, @unchecked Sendable {
    let result: PhoneContactsCaller
    init(_ result: PhoneContactsCaller) { self.result = result }
    func classifyContactsCaller(callerSessionID: String) async -> PhoneContactsCaller { result }
}

private final class FakeOrdinaryBridge: PhoneToolBridge, @unchecked Sendable {
    let handles: Set<String> = ["contacts.search"]
    let supportsContext = false
    private(set) var calls: [(String, String)] = []
    func callTool(name: String, arguments: String) async throws -> String {
        calls.append((name, arguments))
        return #"{"ok":true,"tool":"contacts.search","data":{"ordinary":true}}"#
    }
}

final class PDSHShellContactsContextTests: XCTestCase {
    private func provider(query: FakeContactsQuery,
                          classifier: FakeContactsClassifier,
                          ordinary: FakeOrdinaryBridge) -> PDSHShellProvider {
        PDSHShellProvider(toolBridge: ordinary,
                          botContactsQuery: query,
                          contactsSessionClassifier: classifier)
    }

    private func collect(_ stream: AsyncThrowingStream<ExecEvent, Error>) async throws
        -> (stdout: String, stderr: String, exit: Int32) {
        var out = Data(); var err = Data(); var exit: Int32 = -1
        for try await event in stream {
            switch event {
            case .stdout(_, let data): out.append(data)
            case .stderr(_, let data): err.append(data)
            case .exit(let code, _, _): exit = code ?? -1
            }
        }
        return (String(decoding: out, as: UTF8.self),
                String(decoding: err, as: UTF8.self), exit)
    }

    private func request(session: String?) -> ExecRequest {
        ExecRequest(execID: "contacts-1",
                    argv: ["phone", "contacts", "search", #"{"query":"A07"}"#],
                    cwd: "/dsh/workspace",
                    env: session.map { ["PDSH_TOOL_CALL_SESSION": $0] } ?? [:])
    }

    func testBotSessionUsesBotContactsQuery() async throws {
        let query = FakeContactsQuery()
        let ordinary = FakeOrdinaryBridge()
        let shell = provider(query: query, classifier: FakeContactsClassifier(.bot(botID: "bot-a")),
                             ordinary: ordinary)
        let result = try await collect(shell.run(request(session: "gb-bot-a")))
        XCTAssertEqual(result.exit, 0)
        XCTAssertTrue(result.stdout.contains(#""caller":"gb-bot-a""#))
        XCTAssertEqual(query.sessions, ["gb-bot-a"])
        XCTAssertTrue(ordinary.calls.isEmpty)
    }

    func testVerifiedOrdinarySessionUsesOldBridge() async throws {
        let query = FakeContactsQuery()
        let ordinary = FakeOrdinaryBridge()
        let shell = provider(query: query, classifier: FakeContactsClassifier(.ordinary),
                             ordinary: ordinary)
        let result = try await collect(shell.run(request(session: "ordinary-session")))
        XCTAssertEqual(result.exit, 0)
        XCTAssertTrue(result.stdout.contains(#""ordinary":true"#))
        XCTAssertTrue(query.sessions.isEmpty)
        XCTAssertEqual(ordinary.calls.count, 1)
    }

    func testInvalidOrMissingSessionFailsClosed() async throws {
        let query = FakeContactsQuery()
        let ordinary = FakeOrdinaryBridge()
        let shell = provider(query: query,
                             classifier: FakeContactsClassifier(.invalid(reason: "forged")),
                             ordinary: ordinary)
        let invalid = try await collect(shell.run(request(session: "forged")))
        XCTAssertEqual(invalid.exit, 1)
        XCTAssertFalse(invalid.stdout.contains(#""ordinary":true"#))
        XCTAssertTrue(query.sessions.isEmpty)
        XCTAssertTrue(ordinary.calls.isEmpty)

        let missing = try await collect(shell.run(request(session: nil)))
        XCTAssertEqual(missing.exit, 1)
        XCTAssertTrue(query.sessions.isEmpty)
        XCTAssertTrue(ordinary.calls.isEmpty)
    }
}
