// SPDX-License-Identifier: MIT
import Foundation
import PhoneDSHAgentCore

public enum DeviceAppInstallError: Error, Equatable, Sendable {
    /// The bundle broke a §2 limit (or its declared digest is wrong); nothing was sent.
    case invalidBundle(String)
    /// The device answered `ok:false` with its §8 code.
    case deviceRefused(tool: String, code: String)
    /// The board refused the call before running it (ble-link.md rule 7).
    case notExecuted(tool: String, stage: String, status: String)
    /// The call could not be made at all (not connected, not authorized, busy).
    case callFailed(tool: String, message: String)
    /// The Link was busy with another call: this call was never sent.
    case linkBusy(tool: String)
    /// A reply broke the §5/§6 shape.
    case protocolViolation(String)
    /// `app.commit` replied, but with a digest other than the declared one.
    case digestMismatch(reported: String)
    /// `app.commit` had an unknown outcome and `app.info` says it is not installed.
    case commitNotInstalled
    /// `app.commit` had an unknown outcome and `app.info` could not be read either.
    case commitOutcomeUnknown
    /// More session resynchronizations than allowed.
    case tooManyResumes
}

public struct DeviceAppInstallResult: Equatable, Sendable {
    public let name: String
    public let digest: String
    /// How many times the session was re-established with `app.begin` after a lost reply.
    public let resumes: Int
    /// True when `app.commit` itself had no reply and `app.info` proved the install.
    public let confirmedByInfo: Bool
    /// Number of Link calls made (begin, put, commit, info, abort).
    public let calls: Int
}

/// Drives `app.begin → app.put* → app.commit` strictly serially through an injected
/// Link call (spec/device/v1/device-app.md §6, §7). It holds no approval logic: the
/// caller passes a bundle the user already confirmed, and nothing here may be reached
/// from an agent-origin `ble_link_call`.
///
/// - Staging calls (`begin`, `put`, `abort`) use a fresh journal key each. A lost reply
///   is repaired by `app.begin` with the same name and digest (the device returns the
///   session and its per-file next offsets), never by repeating the lost call.
/// - `app.commit` is durable: it is sent once with one key. If its outcome is unknown,
///   `app.info` decides by digest. It is never sent again.
public struct DeviceAppInstaller: Sendable {
    public typealias CallTool = @Sendable (_ name: String, _ arguments: JSONValue, _ idempotencyKey: String) async throws -> LinkCallOutcome
    public typealias PruneStaging = @Sendable (_ keys: [String]) -> Void

    let callTool: CallTool
    let pruneStaging: PruneStaging
    public let installID: UUID
    public let maxResumes: Int
    public let infoAttempts: Int

    public init(installID: UUID = UUID(), maxResumes: Int = 8, infoAttempts: Int = 3,
                pruneStaging: @escaping PruneStaging = { _ in },
                callTool: @escaping CallTool) {
        self.installID = installID
        self.maxResumes = maxResumes
        self.infoAttempts = infoAttempts
        self.pruneStaging = pruneStaging
        self.callTool = callTool
    }

    /// The installer bound to the real Link entry as the user origin (device panel / host).
    /// Staging intents are pruned from the same journal at the end of every install.
    public static func live(deviceID: UUID, installID: UUID = UUID()) -> DeviceAppInstaller {
        live(deviceID: deviceID, installID: installID, store: nil, journal: nil)
    }

    static func live(deviceID: UUID, installID: UUID,
                     store: BLEDeviceStore?, journal: LinkToolJournal?) -> DeviceAppInstaller {
        let journal = journal ?? LinkToolStorage.defaultJournal
        return DeviceAppInstaller(
            installID: installID,
            pruneStaging: { _ = journal.removeStagingIntents(keys: $0) },
            callTool: { name, arguments, key in
                if let store {
                    return try await callLinkTool(deviceID: deviceID, name: name, arguments: arguments,
                                                  idempotencyKey: key, origin: .user, store: store, journal: journal)
                }
                return try await callLinkTool(deviceID: deviceID, name: name, arguments: arguments,
                                              idempotencyKey: key, origin: .user)
            })
    }

    public func key(call number: Int) -> String {
        "devapp.\(installID.uuidString.lowercased()).\(number)"
    }

    @discardableResult
    public func install(_ bundle: DeviceAppBundle) async throws -> DeviceAppInstallResult {
        if let problem = DeviceAppRules.validate(bundle) { throw DeviceAppInstallError.invalidBundle(problem) }
        let run = Run(installer: self, bundle: bundle)
        do {
            let result = try await run.perform()
            pruneStaging(run.stagingKeys)
            return result
        } catch {
            // Failure or cancellation: drop the stage on the device (best effort) and our intents.
            if !run.committed { await run.abortBestEffort() }
            pruneStaging(run.stagingKeys)
            throw error
        }
    }

    // MARK: - One install

    private enum Step {
        case ok(JSONValue)
        case lost
        case refused(code: String)
    }

    private final class Run {
        let installer: DeviceAppInstaller
        let bundle: DeviceAppBundle
        let files: [DeviceAppFile]
        var number = 0
        var stagingKeys: [String] = []
        var session: String?
        var chunk = DeviceAppRules.maxChunkBytes
        var resumes = 0
        var calls = 0
        var committed = false

        init(installer: DeviceAppInstaller, bundle: DeviceAppBundle) {
            self.installer = installer
            self.bundle = bundle
            self.files = bundle.files.sorted { Array($0.path.utf8).lexicographicallyPrecedes(Array($1.path.utf8)) }
        }

        func call(_ tool: String, _ arguments: JSONValue) async throws -> Step {
            try Task.checkCancellation()
            number += 1
            calls += 1
            let key = installer.key(call: number)
            if DeviceAppTools.staging.contains(tool) { stagingKeys.append(key) }
            let outcome: LinkCallOutcome
            do {
                outcome = try await installer.callTool(tool, arguments, key)
            } catch is CancellationError {
                throw CancellationError()
            } catch is LinkBusy {
                throw DeviceAppInstallError.linkBusy(tool: tool)
            } catch {
                throw DeviceAppInstallError.callFailed(tool: tool, message: String(describing: error))
            }
            switch outcome {
            case .outcomeUnknown, .running:
                return .lost
            case .notExecuted(_, let stage, let status):
                throw DeviceAppInstallError.notExecuted(tool: tool, stage: stage, status: status)
            case .completed(_, let reply):
                switch reply["status"]?.stringValue {
                case "outcome_unknown":
                    return .lost
                case "completed":
                    guard let result = reply["result"], case .object = result, let ok = result["ok"]?.boolValue else {
                        throw DeviceAppInstallError.protocolViolation("\(tool): result is not an object with ok")
                    }
                    if ok { return .ok(result) }
                    return .refused(code: result["code"]?.stringValue ?? "bad_request")
                case "failed":
                    if let result = reply["result"], result["ok"]?.boolValue == false {
                        return .refused(code: result["code"]?.stringValue ?? "bad_request")
                    }
                    return .refused(code: "bad_request")
                default:
                    throw DeviceAppInstallError.protocolViolation("\(tool): unknown reply status")
                }
            }
        }

        func fileList() -> JSONValue {
            .array(files.map {
                .object(["path": .string($0.path), "size": .number(Double($0.bytes.count)), "sha256": .string($0.sha256)])
            })
        }

        /// `app.begin` with the same name and files: new session, or the existing one with
        /// the device's per-file next offsets. Repeats on a lost reply.
        func establish() async throws -> [String: Int] {
            while true {
                let step = try await call(DeviceAppTools.begin,
                                          .object(["name": .string(bundle.name), "files": fileList()]))
                switch step {
                case .lost:
                    try spendResume()
                case .refused(let code):
                    throw DeviceAppInstallError.deviceRefused(tool: DeviceAppTools.begin, code: code)
                case .ok(let result):
                    guard let id = result["session"]?.stringValue, Self.isSessionID(id),
                          let max = result["chunk_max"]?.intValue, (1...DeviceAppRules.maxChunkBytes).contains(max),
                          case .object(let table)? = result["next"] else {
                        throw DeviceAppInstallError.protocolViolation("app.begin: bad session, chunk_max or next")
                    }
                    var next: [String: Int] = [:]
                    for file in files {
                        guard let offset = table[file.path]?.intValue, (0...file.bytes.count).contains(offset) else {
                            throw DeviceAppInstallError.protocolViolation("app.begin: bad next offset for \(file.path)")
                        }
                        next[file.path] = offset
                    }
                    session = id
                    chunk = max
                    return next
                }
            }
        }

        static func isSessionID(_ value: String) -> Bool {
            value.utf8.count == 8 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }

        func spendResume() throws {
            resumes += 1
            guard resumes <= installer.maxResumes else { throw DeviceAppInstallError.tooManyResumes }
        }

        func perform() async throws -> DeviceAppInstallResult {
            var next = try await establish()
            while let file = files.first(where: { (next[$0.path] ?? 0) < $0.bytes.count }), let id = session {
                let offset = next[file.path] ?? 0
                let end = min(offset + chunk, file.bytes.count)
                let data = file.bytes.subdata(in: offset..<end)
                let step = try await call(DeviceAppTools.put, .object([
                    "session": .string(id), "path": .string(file.path),
                    "offset": .number(Double(offset)), "data": .string(data.base64EncodedString()),
                ]))
                switch step {
                case .ok(let result):
                    guard result["next_offset"]?.intValue == end else {
                        throw DeviceAppInstallError.protocolViolation("app.put: next_offset is not \(end)")
                    }
                    next[file.path] = end
                case .lost:
                    try spendResume()
                    next = try await establish()
                case .refused(let code) where code == "bad_session":
                    // The device dropped the stage (idle timeout, disconnect): start the stage again.
                    try spendResume()
                    next = try await establish()
                case .refused(let code):
                    throw DeviceAppInstallError.deviceRefused(tool: DeviceAppTools.put, code: code)
                }
            }
            return try await commit()
        }

        func commit() async throws -> DeviceAppInstallResult {
            guard let id = session else { throw DeviceAppInstallError.protocolViolation("no session") }
            // One key, one send. It is never repeated, whatever the outcome.
            // A call that failed after the request may have been sent (disconnect) is a lost
            // reply, settled by `app.info`; only `LinkBusy` proves it was never sent.
            let step: Step
            do {
                step = try await call(DeviceAppTools.commit,
                                      .object(["session": .string(id), "digest": .string(bundle.digest)]))
            } catch DeviceAppInstallError.callFailed {
                step = .lost
            }
            switch step {
            case .ok(let result):
                committed = true
                guard result["digest"]?.stringValue == bundle.digest else {
                    throw DeviceAppInstallError.digestMismatch(reported: result["digest"]?.stringValue ?? "")
                }
                return finish(confirmedByInfo: false)
            case .refused(let code):
                throw DeviceAppInstallError.deviceRefused(tool: DeviceAppTools.commit, code: code)
            case .lost:
                for _ in 0..<installer.infoAttempts {
                    let reply: Step
                    do { reply = try await call(DeviceAppTools.info, .object([:])) } catch DeviceAppInstallError.callFailed {
                        reply = .lost
                    }
                    switch reply {
                    case .ok(let result):
                        let installed = (result["apps"]?.arrayValue ?? []).contains {
                            $0["name"]?.stringValue == bundle.name && $0["digest"]?.stringValue == bundle.digest
                        }
                        guard installed else { throw DeviceAppInstallError.commitNotInstalled }
                        committed = true
                        return finish(confirmedByInfo: true)
                    case .lost:
                        continue
                    case .refused(let code):
                        throw DeviceAppInstallError.deviceRefused(tool: DeviceAppTools.info, code: code)
                    }
                }
                // Unresolved: the commit may still have happened. Do not abort a session that
                // may be committing, and do not claim either result.
                committed = true
                throw DeviceAppInstallError.commitOutcomeUnknown
            }
        }

        func finish(confirmedByInfo: Bool) -> DeviceAppInstallResult {
            DeviceAppInstallResult(name: bundle.name, digest: bundle.digest, resumes: resumes,
                                   confirmedByInfo: confirmedByInfo, calls: calls)
        }

        func abortBestEffort() async {
            guard let id = session else { return }
            number += 1
            let key = installer.key(call: number)
            stagingKeys.append(key)
            _ = try? await installer.callTool(DeviceAppTools.abort, .object(["session": .string(id)]), key)
        }
    }
}
