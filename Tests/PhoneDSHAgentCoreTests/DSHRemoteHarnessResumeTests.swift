// SPDX-License-Identifier: MIT
// phone-dsh: DSH Remote session create/resume semantics.

import XCTest
import PhoneDSHAgentCore

final class DSHRemoteHarnessResumeTests: XCTestCase {
    func testOpeningExistingSessionValidatesWithoutCallingCreate() async throws {
        let transport = RecordingSessionTransport(page: .object(["records": .array([]), "hasMore": .bool(false)]))
        let harness = DSHRemoteHarness(transport: transport)

        let session = try await harness.openSession(HarnessSessionRequest(
            sessionID: "session-existing", workspace: "/dsh/workspace"))

        XCTAssertEqual(session.id, "session-existing")
        let calls = await transport.recordedCalls()
        XCTAssertEqual(calls.map(\.endpoint), ["session/page"])
        XCTAssertEqual(calls.first?.args["request"]?["address"]?["sessionId"]?.stringValue,
                       "session-existing")
        XCTAssertEqual(calls.first?.args["request"]?["throughSeq"]?.numberValue, -1)
    }

    func testMissingExistingSessionFailsInsteadOfCreatingReplacement() async throws {
        let transport = RecordingSessionTransport(page: .null, missingSession: true)
        let harness = DSHRemoteHarness(transport: transport)

        do {
            _ = try await harness.openSession(HarnessSessionRequest(sessionID: "missing-session"))
            XCTFail("opening a missing id must fail")
        } catch let error as ProviderError {
            XCTAssertEqual(error, .invalidRequest("session_not_found"))
        }
        let calls = await transport.recordedCalls()
        XCTAssertEqual(calls.map(\.endpoint), ["session/page"])
    }

    func testOpeningNewSessionStillUsesCreate() async throws {
        let transport = RecordingSessionTransport(
            page: .object(["sessionId": .string("session-new")]))
        let harness = DSHRemoteHarness(transport: transport)

        let session = try await harness.openSession(HarnessSessionRequest(workspace: "/dsh/workspace"))

        XCTAssertEqual(session.id, "session-new")
        let calls = await transport.recordedCalls()
        XCTAssertEqual(calls.map(\.endpoint), ["session/create"])
        XCTAssertEqual(calls.first?.args["request"]?["cwd"]?.stringValue, "/dsh/workspace")
    }
}

private actor RecordingSessionTransport: DSHRemoteTransport {
    struct Call: Sendable {
        var endpoint: String
        var args: JSONValue
    }

    private let page: JSONValue
    private let missingSession: Bool
    private var calls: [Call] = []

    init(page: JSONValue, missingSession: Bool = false) {
        self.page = page
        self.missingSession = missingSession
    }

    func call(_ endpoint: String, args: JSONValue) async throws -> JSONValue {
        calls.append(Call(endpoint: endpoint, args: args))
        if endpoint == "session/page", missingSession {
            throw DSHRemoteError(code: "session/not-found", message: "missing")
        }
        return page
    }

    func openMux() async throws -> any DSHMuxConnection {
        throw ProviderError.unsupported("the resume unit tests do not open a mux")
    }

    func authenticationFailed() async {}

    func recordedCalls() -> [Call] { calls }
}
