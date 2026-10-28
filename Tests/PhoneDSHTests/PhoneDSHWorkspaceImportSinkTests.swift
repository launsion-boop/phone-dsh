// SPDX-License-Identifier: MIT
// Wire-contract tests for the native -> Worker directory import sink.
//
// These use a recording DSHRemoteTransport and assert the exact endpoint names,
// the `{request: {...}}` envelope, manifest fields, base64 bytes, commit
// parsing, and malformed-response rejection. This is not an end-to-end Worker
// test; the real VFS write path is covered by the plugin's Node test.

import Foundation
import XCTest

import PhoneDSHAgentCore
import PhoneDSHEngine
import PhoneDSH

private enum RecordingTransportError: Error, Equatable {
    case noResponse
}

private actor RecordingTransport: DSHRemoteTransport {
    struct Call: Sendable, Equatable {
        let endpoint: String
        let args: JSONValue
    }

    private var responses: [JSONValue]
    private(set) var calls: [Call] = []

    init(_ responses: [JSONValue]) {
        self.responses = responses
    }

    func call(_ endpoint: String, args: JSONValue) async throws -> JSONValue {
        calls.append(Call(endpoint: endpoint, args: args))
        guard !responses.isEmpty else { throw RecordingTransportError.noResponse }
        return responses.removeFirst()
    }

    func openMux() async throws -> any DSHMuxConnection {
        throw RecordingTransportError.noResponse
    }

    func authenticationFailed() async {}
}

final class PhoneDSHWorkspaceImportSinkTests: XCTestCase {
    private let manifest = WebEngineDirectoryImportManifest(
        sessionID: "session-1",
        targetDirectory: "/dsh/workspace",
        entryName: "notes",
        directories: ["docs", "docs/empty"],
        files: [
            WebEngineDirectoryImportFile(path: "docs/a.bin", size: 3),
            WebEngineDirectoryImportFile(path: "root.txt", size: 2),
        ],
        totalBytes: 5)

    private func writeCall(_ calls: [RecordingTransport.Call], at index: Int) -> [String: JSONValue] {
        guard index < calls.count else {
            XCTFail("missing transport call at index \(index)")
            return [:]
        }
        let call = calls[index]
        guard case .object(let envelope) = call.args,
              case .object(let request)? = envelope["request"] else {
            XCTFail("request is not wrapped in {request: {...}}")
            return [:]
        }
        return request
    }

    func testBeginSendsManifestInARequestEnvelope() async throws {
        let transport = RecordingTransport([.object(["importId": .string("import-1")])])
        let sink = PhoneDSHWorkspaceImportSink(transport: transport)

        let importID = try await sink.begin(manifest)
        XCTAssertEqual(importID, "import-1")
        let calls = await transport.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].endpoint, "phone/importBegin")
        let request = writeCall(calls, at: 0)
        XCTAssertEqual(request["v"]?.intValue, 1)
        XCTAssertEqual(request["sessionId"]?.stringValue, "session-1")
        XCTAssertEqual(request["targetDirectory"]?.stringValue, "/dsh/workspace")
        XCTAssertEqual(request["entryName"]?.stringValue, "notes")
        XCTAssertEqual(request["directories"]?.arrayValue?.compactMap(\.stringValue), ["docs", "docs/empty"])
        XCTAssertEqual(request["totalBytes"]?.intValue, 5)
        guard case .array(let files)? = request["files"] else {
            XCTFail("files is not an array")
            return
        }
        XCTAssertEqual(files.count, 2)
        guard case .object(let first) = files[0] else {
            XCTFail("first file is not an object")
            return
        }
        XCTAssertEqual(first["path"]?.stringValue, "docs/a.bin")
        XCTAssertEqual(first["size"]?.intValue, 3)
    }

    func testWriteSendsBase64OffsetAndSessionAndChecksReceived() async throws {
        let data = Data([0, 1, 2, 255])
        let transport = RecordingTransport([
            .object(["importId": .string("import-1")]),
            .object(["received": .number(11)]),
        ])
        let sink = PhoneDSHWorkspaceImportSink(transport: transport)
        _ = try await sink.begin(manifest)
        try await sink.write(importID: "import-1", path: "docs/a.bin", offset: 7, data: data)

        let calls = await transport.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[1].endpoint, "phone/importWrite")
        let request = writeCall(calls, at: 1)
        XCTAssertEqual(request["v"]?.intValue, 1)
        XCTAssertEqual(request["sessionId"]?.stringValue, "session-1")
        XCTAssertEqual(request["importId"]?.stringValue, "import-1")
        XCTAssertEqual(request["path"]?.stringValue, "docs/a.bin")
        XCTAssertEqual(request["offset"]?.intValue, 7)
        let encoded = try XCTUnwrap(request["dataBase64"]?.stringValue)
        XCTAssertEqual(Data(base64Encoded: encoded), data)
    }

    func testWriteRejectsAMismatchedReceivedCount() async throws {
        let transport = RecordingTransport([
            .object(["importId": .string("import-1")]),
            .object(["received": .number(1)]),
        ])
        let sink = PhoneDSHWorkspaceImportSink(transport: transport)
        _ = try await sink.begin(manifest)
        do {
            try await sink.write(importID: "import-1", path: "docs/a.bin", offset: 0, data: Data([1, 2]))
            XCTFail("a mismatched received count must fail")
        } catch {
            guard let typed = error as? PhoneDSHWorkspaceImportSinkError,
                  case .malformedResponse = typed else {
                XCTFail("expected malformedResponse, got \(error)")
                return
            }
        }
    }

    func testCommitParsesTheObservedResult() async throws {
        let transport = RecordingTransport([
            .object(["importId": .string("import-1")]),
            .object([
                "workspacePath": .string("imports/notes"),
                "absolutePath": .string("/dsh/workspace/imports/notes"),
                "fileCount": .number(2),
                "totalBytes": .number(5),
            ]),
        ])
        let sink = PhoneDSHWorkspaceImportSink(transport: transport)
        _ = try await sink.begin(manifest)
        let result = try await sink.commit(importID: "import-1")

        let calls = await transport.calls
        XCTAssertEqual(calls[1].endpoint, "phone/importCommit")
        let request = writeCall(calls, at: 1)
        XCTAssertEqual(request["sessionId"]?.stringValue, "session-1")
        XCTAssertEqual(request["importId"]?.stringValue, "import-1")
        XCTAssertEqual(result.workspacePath, "imports/notes")
        XCTAssertEqual(result.absolutePath, "/dsh/workspace/imports/notes")
        XCTAssertEqual(result.fileCount, 2)
        XCTAssertEqual(result.totalBytes, 5)
    }

    func testAbortSendsTheScopedImport() async throws {
        let transport = RecordingTransport([
            .object(["importId": .string("import-1")]),
            .object(["aborted": .bool(true)]),
        ])
        let sink = PhoneDSHWorkspaceImportSink(transport: transport)
        _ = try await sink.begin(manifest)
        await sink.abort(importID: "import-1")

        let calls = await transport.calls
        XCTAssertEqual(calls[1].endpoint, "phone/importAbort")
        let request = writeCall(calls, at: 1)
        XCTAssertEqual(request["sessionId"]?.stringValue, "session-1")
        XCTAssertEqual(request["importId"]?.stringValue, "import-1")
    }

    func testMissingOrWrongResponseFieldsAreMalformed() async throws {
        let beginTransport = RecordingTransport([.object([:])])
        let beginSink = PhoneDSHWorkspaceImportSink(transport: beginTransport)
        do {
            _ = try await beginSink.begin(manifest)
            XCTFail("a begin response without importId must fail")
        } catch {
            XCTAssertEqual(error as? PhoneDSHWorkspaceImportSinkError, .malformedResponse("importId"))
        }

        let commitTransport = RecordingTransport([
            .object(["importId": .string("import-1")]),
            .object([
                "workspacePath": .string("imports/notes"),
                "absolutePath": .string("/dsh/workspace/imports/notes"),
                "fileCount": .string("two"),
                "totalBytes": .number(5),
            ]),
        ])
        let commitSink = PhoneDSHWorkspaceImportSink(transport: commitTransport)
        _ = try await commitSink.begin(manifest)
        do {
            _ = try await commitSink.commit(importID: "import-1")
            XCTFail("a non-numeric fileCount must fail")
        } catch {
            XCTAssertEqual(error as? PhoneDSHWorkspaceImportSinkError, .malformedResponse("fileCount"))
        }

        let writeTransport = RecordingTransport([
            .object(["importId": .string("import-1")]),
            .object([:]),
        ])
        let writeSink = PhoneDSHWorkspaceImportSink(transport: writeTransport)
        _ = try await writeSink.begin(manifest)
        do {
            try await writeSink.write(importID: "import-1", path: "docs/a.bin", offset: 0, data: Data([1]))
            XCTFail("a write response without received must fail")
        } catch {
            XCTAssertEqual(error as? PhoneDSHWorkspaceImportSinkError, .malformedResponse("received"))
        }
    }
}
