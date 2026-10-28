// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSH: native importer -> Worker Remote wire adapter.
//
// This adapter only maps `WebEngineDirectoryImportSink` calls to the existing
// ordered-channel transport. It never reads credentials, never touches the
// filesystem and never creates a session or workspace: the Worker service
// validates and writes inside the session's existing VFS.
//
// Every request travels as `{request: {...}}`, matching the surface-phone
// `phone/createSchedule` precedent. A missing or wrongly typed response field
// is `malformedResponse`; no default value is invented.

import Foundation
import PhoneDSHAgentCore
import PhoneDSHEngine

/// Wire-contract failures from a Worker import response.
public enum PhoneDSHWorkspaceImportSinkError: Error, Equatable, Sendable {
    /// The response did not contain the required field or its type was wrong.
    case malformedResponse(String)
}

extension PhoneDSHWorkspaceImportSinkError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .malformedResponse(let field):
            return "The Worker import response is malformed: \(field)"
        }
    }
}

/// `WebEngineDirectoryImportSink` over the app's existing `DSHRemoteTransport`.
public struct PhoneDSHWorkspaceImportSink: WebEngineDirectoryImportSink {
    private let transport: any DSHRemoteTransport
    /**
     * The session id from `begin`. The sink protocol carries it only on the
     * manifest, while every Worker request names it; the box keeps the mapping
     * without widening the public sink contract. The native importer runs one
     * import at a time.
     */
    private let session = ImportSession()

    /// - Parameter transport: the same ordered-channel transport the App uses
    ///   for its DSH sessions (`PhoneDSHHost.makeTransport()`).
    public init(transport: any DSHRemoteTransport) {
        self.transport = transport
    }

    public func begin(_ manifest: WebEngineDirectoryImportManifest) async throws -> String {
        let files = manifest.files.map { file in
            JSONValue.object([
                "path": .string(file.path),
                "size": .number(Double(file.size)),
            ])
        }
        let value = try await transport.call("phone/importBegin", args: request([
            "v": .number(1),
            "sessionId": .string(manifest.sessionID),
            "targetDirectory": .string(manifest.targetDirectory),
            "entryName": .string(manifest.entryName),
            "directories": .array(manifest.directories.map { .string($0) }),
            "files": .array(files),
            "totalBytes": .number(Double(manifest.totalBytes)),
        ]))
        guard let importID = value["importId"]?.stringValue, !importID.isEmpty else {
            throw PhoneDSHWorkspaceImportSinkError.malformedResponse("importId")
        }
        session.set(manifest.sessionID)
        return importID
    }

    public func write(importID: String, path: String, offset: Int, data: Data) async throws {
        let sessionID = try requireSession()
        let value = try await transport.call("phone/importWrite", args: request([
            "v": .number(1),
            "sessionId": .string(sessionID),
            "importId": .string(importID),
            "path": .string(path),
            "offset": .number(Double(offset)),
            "dataBase64": .string(data.base64EncodedString()),
        ]))
        let received = try integer(value["received"], "received")
        let expected = offset + data.count
        guard received == expected else {
            throw PhoneDSHWorkspaceImportSinkError.malformedResponse(
                "received \(received) does not match the \(expected) cumulative bytes")
        }
    }

    public func commit(importID: String) async throws -> WebEngineDirectoryImportResult {
        let sessionID = try requireSession()
        let value = try await transport.call("phone/importCommit", args: request([
            "v": .number(1),
            "sessionId": .string(sessionID),
            "importId": .string(importID),
        ]))
        guard let workspacePath = value["workspacePath"]?.stringValue, !workspacePath.isEmpty else {
            throw PhoneDSHWorkspaceImportSinkError.malformedResponse("workspacePath")
        }
        guard let absolutePath = value["absolutePath"]?.stringValue, !absolutePath.isEmpty else {
            throw PhoneDSHWorkspaceImportSinkError.malformedResponse("absolutePath")
        }
        let fileCount = try integer(value["fileCount"], "fileCount")
        let totalBytes = try integer(value["totalBytes"], "totalBytes")
        return WebEngineDirectoryImportResult(workspacePath: workspacePath,
                                              absolutePath: absolutePath,
                                              fileCount: fileCount,
                                              totalBytes: totalBytes)
    }

    public func abort(importID: String) async {
        // The protocol is deliberately non-throwing: the importer already has
        // the original failure and abort must not replace it.
        guard let sessionID = session.value else { return }
        _ = try? await transport.call("phone/importAbort", args: request([
            "v": .number(1),
            "sessionId": .string(sessionID),
            "importId": .string(importID),
        ]))
    }

    private func request(_ fields: [String: JSONValue]) -> JSONValue {
        .object(["request": .object(fields)])
    }

    private func requireSession() throws -> String {
        guard let value = session.value, !value.isEmpty else {
            throw PhoneDSHWorkspaceImportSinkError.malformedResponse("sessionId (begin must run first)")
        }
        return value
    }

    private func integer(_ value: JSONValue?, _ field: String) throws -> Int {
        guard case .number(let number)? = value,
              number.isFinite,
              number.rounded() == number,
              let integer = Int(exactly: number),
              integer >= 0 else {
            throw PhoneDSHWorkspaceImportSinkError.malformedResponse(field)
        }
        return integer
    }
}

/// Thread-safe session id remembered from the manifest; the sink is Sendable.
private final class ImportSession: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    var value: String? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ sessionID: String) {
        lock.lock()
        stored = sessionID
        lock.unlock()
    }
}
