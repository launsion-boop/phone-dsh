// SPDX-License-Identifier: MIT
import Foundation
import PhoneDSHAgentCore
@testable import PhoneDSHBLE

/// A device implementing exactly spec/device/v1/device-app.md §6: one session, per-file
/// offsets, replay, hash and digest check, atomic commit, idle expiry on an injected clock.
/// It speaks the Link reply shape (`{status, result:{ok,...}}`) so the installer's real
/// parser is exercised. Test-only fault injection is keyed by (tool, nth call of that tool).
final class FakeAppDevice: @unchecked Sendable {
    struct Staged { var size: Int; var sha256: String; var data = Data() }
    struct Session { var id: String; var name: String; var files: [String: Staged]; var lastActivity: TimeInterval }
    struct Installed: Equatable { var digest: String; var files: [String: Data] }

    enum Fault {
        /// The effect happens, the reply is lost.
        case lostReplyApplied
        /// The request never arrives; no effect.
        case lostRequest
        /// The link drops: the stage is gone and the reply is lost (effect of this call is not applied).
        case disconnect
        /// The call itself fails before reaching the radio (not connected, not authorized).
        case throwError
        /// The device answers a definitive `ok:false`.
        case refuse(String)
        /// The idle timeout passes before this call arrives.
        case idleExpiry
        /// Run test code (for example cancel the installing task) before the call is handled.
        case hook(() -> Void)
    }

    let idleTimeout: TimeInterval = 120
    var clock: TimeInterval = 0
    var session: Session?
    var installed: [String: Installed] = [:]
    var freeBytes = 1_000_000
    var faults: [String: [Int: Fault]] = [:]
    private(set) var counts: [String: Int] = [:]
    private(set) var log: [(tool: String, key: String, arguments: JSONValue)] = []
    private(set) var maxInFlight = 0
    private var inFlight = 0
    private var nextSession = 0xa0
    /// Called for every call before it is handled (the journal test records intents here).
    var onCall: ((String, JSONValue, String) throws -> Void)?

    func inject(_ tool: String, nth: Int, _ fault: Fault) { faults[tool, default: [:]][nth] = fault }
    func calls(_ tool: String) -> Int { counts[tool, default: 0] }
    func args(_ tool: String) -> [JSONValue] { log.filter { $0.tool == tool }.map(\.arguments) }

    var callTool: DeviceAppInstaller.CallTool {
        { [self] name, arguments, key in try await self.handle(name, arguments, key) }
    }

    func handle(_ tool: String, _ arguments: JSONValue, _ key: String) async throws -> LinkCallOutcome {
        inFlight += 1; maxInFlight = max(maxInFlight, inFlight)
        defer { inFlight -= 1 }
        counts[tool, default: 0] += 1
        let nth = counts[tool] ?? 0
        log.append((tool, key, arguments))
        try onCall?(tool, arguments, key)
        let fault = faults[tool]?[nth]
        if case .hook(let run)? = fault { run() }
        if case .throwError? = fault { throw BLEFailure("Link disconnected") }
        if case .idleExpiry? = fault { clock += idleTimeout + 1 }
        expireIfIdle()
        switch fault {
        case .lostRequest?: return lost()
        case .disconnect?: session = nil; return lost()
        case .refuse(let code)?: return reply(fail(code))
        default: break
        }
        let result = dispatch(tool, arguments)
        if case .lostReplyApplied? = fault { return lost() }
        return reply(result)
    }

    private func lost() -> LinkCallOutcome {
        .outcomeUnknown(requestID: UUID(), message: "connection lost")
    }

    private func reply(_ result: JSONValue) -> LinkCallOutcome {
        .completed(requestID: UUID(), reply: .object(["status": .string("completed"), "result": result]))
    }

    private func fail(_ code: String, next: Int? = nil) -> JSONValue {
        var object: [String: JSONValue] = ["ok": .bool(false), "code": .string(code), "message": .string("test")]
        if let next { object["next_offset"] = .number(Double(next)) }
        return .object(object)
    }

    private func ok(_ fields: [String: JSONValue] = [:]) -> JSONValue {
        var object = fields; object["ok"] = .bool(true); return .object(object)
    }

    private func expireIfIdle() {
        if let current = session, clock - current.lastActivity > idleTimeout { session = nil }
    }

    // MARK: - §5 tools

    func dispatch(_ tool: String, _ arguments: JSONValue) -> JSONValue {
        switch tool {
        case "app.info": return info()
        case "app.begin": return begin(arguments)
        case "app.put": return put(arguments)
        case "app.abort": return abort(arguments)
        case "app.commit": return commit(arguments)
        default: return fail("bad_request")
        }
    }

    private func info() -> JSONValue {
        ok(["protocol": .string("device-app-v1"),
            "apps": .array(installed.keys.sorted().map {
                .object(["name": .string($0), "title": .string($0), "version": .number(1),
                         "digest": .string(installed[$0]?.digest ?? ""), "running": .bool(false)])
            }),
            "free_bytes": .number(Double(freeBytes)), "free_mem": .number(60000), "limits": .object([:])])
    }

    private func begin(_ arguments: JSONValue) -> JSONValue {
        guard let name = arguments["name"]?.stringValue, DeviceAppRules.isValidName(name),
              let list = arguments["files"]?.arrayValue, (1...DeviceAppRules.maxFiles).contains(list.count) else { return fail("bad_request") }
        var declared: [String: Staged] = [:]
        var total = 0
        for item in list {
            guard let path = item["path"]?.stringValue, DeviceAppRules.isValidPath(path), declared[path] == nil else { return fail("forbidden_path") }
            guard let size = item["size"]?.intValue, let sha = item["sha256"]?.stringValue, size >= 0 else { return fail("bad_request") }
            guard size <= DeviceAppRules.maxFileBytes else { return fail("too_large") }
            total += size
            declared[path] = Staged(size: size, sha256: sha)
        }
        guard total <= DeviceAppRules.maxAppBytes else { return fail("too_large") }
        guard total <= freeBytes else { return fail("no_space") }
        let digest = DeviceAppRules.manifestDigest(declared.map { ($0.key, $0.value.size, $0.value.sha256) })
        if let current = session {
            let existing = DeviceAppRules.manifestDigest(current.files.map { ($0.key, $0.value.size, $0.value.sha256) })
            guard current.name == name, existing == digest else { return fail("busy") }
            session?.lastActivity = clock
            return beginReply(current)
        }
        nextSession += 1
        let created = Session(id: String(format: "%08x", nextSession), name: name, files: declared, lastActivity: clock)
        session = created
        return beginReply(created)
    }

    private func beginReply(_ current: Session) -> JSONValue {
        ok(["session": .string(current.id), "chunk_max": .number(2048),
            "next": .object(current.files.mapValues { .number(Double($0.data.count)) })])
    }

    private func put(_ arguments: JSONValue) -> JSONValue {
        guard let current = session, arguments["session"]?.stringValue == current.id else { return fail("bad_session") }
        guard let path = arguments["path"]?.stringValue, var file = current.files[path],
              let offset = arguments["offset"]?.intValue, offset >= 0,
              let text = arguments["data"]?.stringValue, let bytes = Data(base64Encoded: text), bytes.count <= 2048 else { return fail("bad_request") }
        session?.lastActivity = clock
        switch Self.putRule(declared: file.size, next: file.data.count, offset: offset, length: bytes.count,
                            sameBytes: { offset + bytes.count <= file.data.count && file.data[offset..<offset + bytes.count] == bytes }) {
        case .failure(let failure):
            return fail(failure.code, next: failure.code == "offset_mismatch" ? file.data.count : nil)
        case .success(let new):
            if new != file.data.count { file.data.append(bytes); session?.files[path] = file }
            return ok(["next_offset": .number(Double(new))])
        }
    }

    /// The §6 rule 2 decision, in the oracle's order (`too_large` first).
    static func putRule(declared: Int, next: Int, offset: Int, length: Int, sameBytes: () -> Bool) -> Result<Int, PutFailure> {
        if offset + length > declared { return .failure(PutFailure("too_large")) }
        if offset == next { return .success(next + length) }
        if offset < next, offset + length <= next, sameBytes() { return .success(next) }
        return .failure(PutFailure("offset_mismatch"))
    }
    struct PutFailure: Error, Equatable { let code: String; init(_ code: String) { self.code = code } }

    private func abort(_ arguments: JSONValue) -> JSONValue {
        guard let current = session, arguments["session"]?.stringValue == current.id else { return fail("bad_session") }
        session = nil
        return ok()
    }

    private func commit(_ arguments: JSONValue) -> JSONValue {
        guard let current = session, arguments["session"]?.stringValue == current.id else { return fail("bad_session") }
        for path in current.files.keys.sorted() {
            let file = current.files[path]!
            guard file.data.count == file.size, DeviceAppRules.sha256Hex(file.data) == file.sha256 else { return fail("hash_mismatch") }
        }
        guard current.files["main.py"] != nil, current.files["app.json"] != nil else { return fail("bad_request") }
        let digest = DeviceAppRules.manifestDigest(current.files.map { ($0.key, $0.value.size, $0.value.sha256) })
        guard arguments["digest"]?.stringValue == digest else { return fail("digest_mismatch") }
        installed[current.name] = Installed(digest: digest, files: current.files.mapValues(\.data))
        session = nil
        return ok(["name": .string(current.name), "digest": .string(digest)])
    }

    // MARK: - Test helpers

    /// Opens a session on one declared file with `staged` bytes already in it (for the put vectors).
    func seedSession(path: String, declared: Int, staged: Data) {
        session = Session(id: "000000aa", name: "vec", files: [path: Staged(size: declared, sha256: "", data: staged)], lastActivity: clock)
    }

    func corruptStaged(path: String, at index: Int) {
        guard var file = session?.files[path], index < file.data.count else { return }
        file.data[index] ^= 0xff
        session?.files[path] = file
    }
}

/// Deterministic bundle builder: `main.py` of `mainSize` bytes plus a small `app.json`.
func makeAppBundle(name: String = "clock", mainSize: Int = 5000, jsonSize: Int = 120) -> DeviceAppBundle {
    func filler(_ count: Int, _ seed: UInt8) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ Int(seed)) }) }
    let files = [DeviceAppFile(path: "main.py", bytes: filler(mainSize, 1)),
                 DeviceAppFile(path: "app.json", bytes: filler(jsonSize, 9))]
    return DeviceAppBundle(name: name, files: files, digest: DeviceAppRules.manifestDigest(of: files))
}
