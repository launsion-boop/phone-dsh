// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHWire: canonical JSON payloads.
//
// PLAN §2.2 (D5) and spec/v1/channel.md §4–§5. JSON frame payloads
// are UTF-8 canonical JSON: no insignificant whitespace, member names sorted by
// code point, `/` unescaped, integers only. Codable payload types below own the
// field tables of channel.md §4; `CanonicalJSON` is the one serialization path.

import Foundation

/// Canonical JSON (D5) used by every JSON payload of phone-dsh-v1.
public enum CanonicalJSON {
    /// Encodes any `Encodable` value with sorted keys, no whitespace and no
    /// escaped slashes.
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(value)
        } catch let error as PhoneWireError {
            throw error
        } catch {
            throw PhoneWireError(code: .badPayload, message: "cannot encode canonical JSON")
        }
    }

    /// Parses legal JSON and returns the same object re-encoded canonically.
    ///
    /// The input must be a JSON object (all payloads of the protocol are
    /// objects), numbers must be integers and the object must not contain a
    /// duplicate member. The root object restriction is part of the payload
    /// tables; member order and whitespace of the input are irrelevant.
    public static func canonicalize(_ json: Data) throws -> Data {
        let object = try decodeObject(json)
        return try encodeValue(.object(object))
    }

    static func decodeObject(_ json: Data) throws -> [String: JSONValue] {
        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: json)
        } catch let error as PhoneWireError {
            throw error
        } catch {
            throw PhoneWireError(code: .badPayload, message: "malformed JSON payload")
        }
        guard case .object(let object) = value else {
            throw PhoneWireError(code: .badPayload, message: "JSON payload must be an object")
        }
        return object
    }

    static func encodeValue(_ value: JSONValue) throws -> Data {
        try encode(value)
    }

    static func unsigned(_ value: JSONValue?, name: String) throws -> UInt64 {
        guard let value else {
            throw PhoneWireError(code: .badPayload, message: "missing \(name)")
        }
        switch value {
        case .unsigned(let number):
            return number
        case .integer(let number) where number >= 0:
            return UInt64(number)
        default:
            throw PhoneWireError(code: .badPayload, message: "\(name) must be a non-negative integer")
        }
    }
}

/// JSON value used internally for payloads whose member set is fixed by
/// spec/exec-bridge-v1 rather than by this module (EXEC_REQ body, EXEC_EVT).
enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case integer(Int64)
    case unsigned(UInt64)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
            return
        }
        if let value = try? container.decode(Int64.self) {
            self = .integer(value)
            return
        }
        if let value = try? container.decode(UInt64.self) {
            self = .unsigned(value)
            return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
            return
        }
        if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
            return
        }
        throw PhoneWireError(
            code: .badPayload,
            message: "JSON numbers must be integers and values must be JSON"
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .unsigned(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

/// Execution authority, channel.md §4.1.
public struct Fence: Codable, Equatable, Sendable {
    public var owner: String
    public var generation: UInt64
    public var walSeq: UInt64

    public init(owner: String, generation: UInt64, walSeq: UInt64) {
        self.owner = owner
        self.generation = generation
        self.walSeq = walSeq
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        owner = try container.decode(String.self, forKey: .owner)
        generation = try container.decode(UInt64.self, forKey: .generation)
        walSeq = try container.decode(UInt64.self, forKey: .walSeq)
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(owner, forKey: .owner)
        try container.encode(generation, forKey: .generation)
        try container.encode(walSeq, forKey: .walSeq)
    }

    /// `owner` is 1–64 characters of `[A-Za-z0-9._:-]`; both integers are
    /// non-negative by type.
    public func validate() throws {
        guard WireValidation.isValidFenceOwner(owner) else {
            throw PhoneWireError(code: .badPayload, message: "invalid fence owner")
        }
    }

    private enum CodingKeys: String, CodingKey {
        case owner, generation
        case walSeq = "wal_seq"
    }
}

/// HELLO payload for the host and the worker variants (channel.md §4.1 / D3).
public struct HelloPayload: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable {
        case host
        case worker
    }

    /// Protocol version; must be 1.
    public var proto: Int
    public var role: Role
    /// 32 lowercase hex characters.
    public var bootID: String
    public var sessionEpoch: UInt64
    public var fence: Fence
    public var caps: [String]
    /// Host member: `max(last_mseq, WAL tail) + 1` (D17).
    public var nextMseq: UInt64?
    /// Host member: the effective tail, `max(last_mseq, WAL tail)`.
    public var ackedMseq: UInt64?
    /// Host member: `durable_upto` of the last closed epoch.
    public var durableMseq: UInt64?
    /// Worker member: highest mseq assigned by this worker process.
    public var lastMseq: UInt64?

    public init(proto: Int = 1, role: Role, bootID: String, sessionEpoch: UInt64,
                fence: Fence, caps: [String], nextMseq: UInt64? = nil,
                ackedMseq: UInt64? = nil, durableMseq: UInt64? = nil,
                lastMseq: UInt64? = nil) {
        self.proto = proto
        self.role = role
        self.bootID = bootID
        self.sessionEpoch = sessionEpoch
        self.fence = fence
        self.caps = caps
        self.nextMseq = nextMseq
        self.ackedMseq = ackedMseq
        self.durableMseq = durableMseq
        self.lastMseq = lastMseq
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        proto = try container.decode(Int.self, forKey: .proto)
        role = try container.decode(Role.self, forKey: .role)
        bootID = try container.decode(String.self, forKey: .bootID)
        sessionEpoch = try container.decode(UInt64.self, forKey: .sessionEpoch)
        fence = try container.decode(Fence.self, forKey: .fence)
        caps = try container.decode([String].self, forKey: .caps)
        nextMseq = try container.decodeIfPresent(UInt64.self, forKey: .nextMseq)
        ackedMseq = try container.decodeIfPresent(UInt64.self, forKey: .ackedMseq)
        durableMseq = try container.decodeIfPresent(UInt64.self, forKey: .durableMseq)
        lastMseq = try container.decodeIfPresent(UInt64.self, forKey: .lastMseq)
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(proto, forKey: .proto)
        try container.encode(role, forKey: .role)
        try container.encode(bootID, forKey: .bootID)
        try container.encode(sessionEpoch, forKey: .sessionEpoch)
        try container.encode(fence, forKey: .fence)
        try container.encode(caps, forKey: .caps)
        try container.encodeIfPresent(nextMseq, forKey: .nextMseq)
        try container.encodeIfPresent(ackedMseq, forKey: .ackedMseq)
        try container.encodeIfPresent(durableMseq, forKey: .durableMseq)
        try container.encodeIfPresent(lastMseq, forKey: .lastMseq)
    }

    /// Validates the field tables, capability sets and identifier syntax.
    public func validate() throws {
        guard proto == 1 else {
            throw PhoneWireError(code: .protoMismatch, message: "HELLO proto is not 1")
        }
        guard WireValidation.isValidBootID(bootID) else {
            throw PhoneWireError(code: .badPayload, message: "invalid HELLO boot_id")
        }
        try fence.validate()
        let uniqueCaps = Set(caps)
        guard uniqueCaps.count == caps.count else {
            throw PhoneWireError(code: .badPayload, message: "duplicate HELLO capability")
        }
        guard caps.allSatisfy(WireValidation.isValidCapability) else {
            throw PhoneWireError(code: .badPayload, message: "invalid HELLO capability")
        }
        switch role {
        case .host:
            guard lastMseq == nil else {
                throw PhoneWireError(code: .badPayload, message: "host HELLO carries last_mseq")
            }
            guard let nextMseq, let ackedMseq, let durableMseq else {
                throw PhoneWireError(code: .badPayload, message: "host HELLO is missing mseq members")
            }
            guard nextMseq >= 1 else {
                throw PhoneWireError(code: .badPayload, message: "next_mseq must be at least 1")
            }
            guard ackedMseq < UInt64.max, nextMseq == ackedMseq + 1 else {
                throw PhoneWireError(code: .badPayload, message: "next_mseq must be acked_mseq + 1")
            }
            guard durableMseq <= ackedMseq else {
                throw PhoneWireError(code: .badPayload, message: "durable_mseq exceeds acked_mseq")
            }
            let required: Set<String> = ["channel/1", "wal/1", "exec/1"]
            guard required.isSubset(of: uniqueCaps) else {
                throw PhoneWireError(code: .protoMismatch, message: "host HELLO lacks a required capability")
            }
        case .worker:
            guard nextMseq == nil, ackedMseq == nil, durableMseq == nil else {
                throw PhoneWireError(code: .badPayload, message: "worker HELLO carries host mseq members")
            }
            guard lastMseq != nil else {
                throw PhoneWireError(code: .badPayload, message: "worker HELLO is missing last_mseq")
            }
            let required: Set<String> = ["channel/1", "vfs-sink/1", "journal/1", "api/1"]
            guard uniqueCaps == required else {
                throw PhoneWireError(code: .protoMismatch, message: "worker HELLO capability set is not exact")
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case proto, role, caps, fence
        case bootID = "boot_id"
        case sessionEpoch = "session_epoch"
        case nextMseq = "next_mseq"
        case ackedMseq = "acked_mseq"
        case durableMseq = "durable_mseq"
        case lastMseq = "last_mseq"
    }
}

/// EXEC_REQ payload (channel.md §4.2).
///
/// The exec-bridge v1 request body is kept as canonical JSON `Data` so the host
/// can forward it unchanged; the two channel members are explicit properties.
public struct ExecRequestPayload: Equatable, Sendable {
    /// exec-bridge v1 `POST /v1/exec` body, canonical object bytes, without
    /// `requires_mseq` and `idem_key`.
    public var body: Data
    /// Apply VFS mutations through this mseq before dispatch; 0 = no dependency.
    public var requiresMseq: UInt64
    /// 64 lowercase hex characters (D10).
    public var idemKey: String

    public init(body: Data, requiresMseq: UInt64, idemKey: String) throws {
        guard WireValidation.isValidIdemKey(idemKey) else {
            throw PhoneWireError(code: .badPayload, message: "invalid exec idem_key")
        }
        let object = try CanonicalJSON.decodeObject(body)
        guard object["requires_mseq"] == nil, object["idem_key"] == nil else {
            throw PhoneWireError(
                code: .badPayload,
                message: "exec body repeats a channel member"
            )
        }
        self.body = try CanonicalJSON.encodeValue(.object(object))
        self.requiresMseq = requiresMseq
        self.idemKey = idemKey
    }

    /// Decodes the combined payload, splitting the two channel members back out.
    public static func decode(_ payload: Data) throws -> ExecRequestPayload {
        var object = try CanonicalJSON.decodeObject(payload)
        let requiresValue = object.removeValue(forKey: "requires_mseq")
        let idemValue = object.removeValue(forKey: "idem_key")
        guard case .string(let idemKey) = idemValue else {
            throw PhoneWireError(code: .badPayload, message: "missing exec idem_key")
        }
        let requiresMseq = try CanonicalJSON.unsigned(requiresValue, name: "requires_mseq")
        let body = try CanonicalJSON.encodeValue(.object(object))
        return try ExecRequestPayload(body: body, requiresMseq: requiresMseq, idemKey: idemKey)
    }

    /// Encodes the combined canonical payload.
    public func encodedPayload() throws -> Data {
        var object = try CanonicalJSON.decodeObject(body)
        guard object["requires_mseq"] == nil, object["idem_key"] == nil else {
            throw PhoneWireError(
                code: .badPayload,
                message: "exec body repeats a channel member"
            )
        }
        object["requires_mseq"] = .unsigned(requiresMseq)
        object["idem_key"] = .string(idemKey)
        return try CanonicalJSON.encodeValue(.object(object))
    }
}

extension ExecRequestPayload: Codable {
    /// Decodes the combined wire object into the raw body plus the two channel
    /// members. Unknown members stay in `body`, as the exec-bridge body is
    /// forwarded unchanged.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        var object: [String: JSONValue]
        do {
            object = try container.decode([String: JSONValue].self)
        } catch let error as PhoneWireError {
            throw error
        } catch {
            throw PhoneWireError(code: .badPayload, message: "malformed EXEC_REQ payload")
        }
        let idemValue = object.removeValue(forKey: "idem_key")
        guard let idemValue, case .string(let idemKey) = idemValue else {
            throw PhoneWireError(code: .badPayload, message: "missing exec idem_key")
        }
        let requiresMseq = try CanonicalJSON.unsigned(
            object.removeValue(forKey: "requires_mseq"), name: "requires_mseq")
        let body = try CanonicalJSON.encodeValue(.object(object))
        try self.init(body: body, requiresMseq: requiresMseq, idemKey: idemKey)
    }

    /// Encodes the combined canonical payload.
    public func encode(to encoder: Encoder) throws {
        let object = try CanonicalJSON.decodeObject(encodedPayload())
        var container = encoder.singleValueContainer()
        try container.encode(object)
    }
}

/// One exec-bridge v1 event object carried by EXEC_EVT (channel.md §4.3).
///
/// The event shape is defined by `spec/exec-bridge-v1`; this type keeps the
/// object as canonical JSON so the channel codec does not duplicate that schema.
public struct ExecEventPayload: Equatable, Sendable {
    /// Canonical JSON object bytes of one event.
    public let json: Data

    public init(json: Data) throws {
        self.json = try CanonicalJSON.canonicalize(json)
    }

    public static func decode(_ payload: Data) throws -> ExecEventPayload {
        try ExecEventPayload(json: payload)
    }

    public func encodedPayload() -> Data {
        json
    }
}

/// EXEC_CTL payload (channel.md §4.4).
public struct ExecControlPayload: Codable, Equatable, Sendable {
    public enum Operation: String, Codable, Sendable {
        case cancel
        case stdin
    }

    public var execID: String
    public var op: Operation
    /// Base64 stdin bytes; required for `.stdin` and absent for `.cancel`.
    public var data: String?

    public init(execID: String, op: Operation, data: String? = nil) {
        self.execID = execID
        self.op = op
        self.data = data
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        execID = try container.decode(String.self, forKey: .execID)
        op = try container.decode(Operation.self, forKey: .op)
        data = try container.decodeIfPresent(String.self, forKey: .data)
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(execID, forKey: .execID)
        try container.encode(op, forKey: .op)
        try container.encodeIfPresent(data, forKey: .data)
    }

    public func validate() throws {
        guard WireValidation.isValidIdentifier(execID) else {
            throw PhoneWireError(code: .badPayload, message: "invalid exec_id")
        }
        switch op {
        case .cancel:
            guard data == nil else {
                throw PhoneWireError(code: .badPayload, message: "cancel carries data")
            }
        case .stdin:
            guard data != nil else {
                throw PhoneWireError(code: .badPayload, message: "stdin requires data")
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case op, data
        case execID = "exec_id"
    }
}

/// Admission state shared by LIFECYCLE and FENCE (channel.md §4.5, §4.7).
public enum Admission: String, Codable, CaseIterable, Sendable {
    case open
    case closed
}

/// LIFECYCLE payload (channel.md §4.5).
public struct LifecyclePayload: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case run
        case pause
        case stop
    }

    public var state: State
    /// Remaining execution budget in milliseconds; 0 means none.
    public var budget: UInt64
    public var admission: Admission
    public var reason: String

    public init(state: State, budget: UInt64, admission: Admission, reason: String) {
        self.state = state
        self.budget = budget
        self.admission = admission
        self.reason = reason
    }
}

/// CONSOLE payload (channel.md §4.6).
public struct ConsolePayload: Codable, Equatable, Sendable {
    public enum Level: String, Codable, Sendable {
        case debug
        case info
        case warn
        case error
    }

    public var level: Level
    public var text: String

    public init(level: Level, text: String) {
        self.level = level
        self.text = text
    }
}

/// FENCE payload (channel.md §4.7).
public struct FencePayload: Codable, Equatable, Sendable {
    public var fence: Fence
    public var admission: Admission

    public init(fence: Fence, admission: Admission) {
        self.fence = fence
        self.admission = admission
    }
}

/// Resource classes a `VFS_REFUSED` diagnostic can carry (channel.md §4.8).
public enum PhoneWireRefusalReason: String, Codable, CaseIterable, Sendable {
    /// The mutation would put one file above the single-file limit (`EFBIG`).
    case fileTooLarge = "file-too-large"
    /// The mutation would exceed the remaining VFS space (`ENOSPC`).
    case noSpace = "no-space"
    /// The mutation would exceed the workspace quota (`EDQUOT`).
    case quotaExceeded = "quota-exceeded"
}

/// ERROR payload (channel.md §4.8).
///
/// A protocol code closes the ordered channel. `VFS_REFUSED` is the one
/// resource-refusal diagnostic: it additionally carries `path`, `limit` and
/// `reason`, consumes no mseq and leaves the connection open. A host reply
/// also carries the refused `mseq` and the `accepted_bytes` prefix as
/// structured members, so the Worker can shrink and resend without parsing
/// the human-readable `message`.
public struct ErrorPayload: Codable, Equatable, Sendable {
    public var code: PhoneWireErrorCode
    public var message: String
    /// Seq of the offending frame; when present it is at least 1.
    public var refSeq: UInt64?
    /// Refused VFS path; required exactly when `code == .vfsRefused`.
    public var path: String?
    /// Policy bound in bytes; required exactly when `code == .vfsRefused`.
    public var limit: UInt64?
    /// Resource class; required exactly when `code == .vfsRefused`.
    public var reason: PhoneWireRefusalReason?
    /// Accepted prefix of the refused mutation in bytes; a host reply carries
    /// it together with `mseq` (channel.md §4.8).
    public var acceptedBytes: UInt64?
    /// The refused mutation's mseq; present exactly with `acceptedBytes`.
    public var mseq: UInt64?

    public init(code: PhoneWireErrorCode, message: String, refSeq: UInt64? = nil,
                path: String? = nil, limit: UInt64? = nil,
                reason: PhoneWireRefusalReason? = nil,
                acceptedBytes: UInt64? = nil, mseq: UInt64? = nil) {
        self.code = code
        self.message = message
        self.refSeq = refSeq
        self.path = path
        self.limit = limit
        self.reason = reason
        self.acceptedBytes = acceptedBytes
        self.mseq = mseq
    }

    /// The non-closing resource-refusal form (channel.md §4.8).
    public init(path: String, limit: UInt64, reason: PhoneWireRefusalReason,
                message: String) {
        self.init(code: .vfsRefused, message: message, path: path,
                  limit: limit, reason: reason)
    }

    /// True when this payload is a `VFS_REFUSED` diagnostic.
    public var isVFSRefused: Bool { code == .vfsRefused }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(PhoneWireErrorCode.self, forKey: .code)
        message = try container.decode(String.self, forKey: .message)
        refSeq = try container.decodeIfPresent(UInt64.self, forKey: .refSeq)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        limit = try container.decodeIfPresent(UInt64.self, forKey: .limit)
        reason = try container.decodeIfPresent(PhoneWireRefusalReason.self, forKey: .reason)
        acceptedBytes = try container.decodeIfPresent(UInt64.self, forKey: .acceptedBytes)
        mseq = try container.decodeIfPresent(UInt64.self, forKey: .mseq)
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(code, forKey: .code)
        try container.encode(message, forKey: .message)
        try container.encodeIfPresent(refSeq, forKey: .refSeq)
        try container.encodeIfPresent(path, forKey: .path)
        try container.encodeIfPresent(limit, forKey: .limit)
        try container.encodeIfPresent(reason, forKey: .reason)
        try container.encodeIfPresent(acceptedBytes, forKey: .acceptedBytes)
        try container.encodeIfPresent(mseq, forKey: .mseq)
    }

    /// Validates the code-dependent member set (channel.md §4.8).
    private func validate() throws {
        if let refSeq, refSeq < 1 {
            throw PhoneWireError(code: .badPayload, message: "ERROR ref_seq must be at least 1")
        }
        guard code == .vfsRefused else {
            guard path == nil, limit == nil, reason == nil,
                  acceptedBytes == nil, mseq == nil else {
                throw PhoneWireError(
                    code: .badPayload,
                    message: "ERROR \(code.rawValue) must not carry VFS_REFUSED members")
            }
            return
        }
        guard let path, WireValidation.isValidMutationPath(path) else {
            throw PhoneWireError(
                code: .badPayload,
                message: "VFS_REFUSED path must be a mutation path")
        }
        guard let limit, reason != nil else {
            throw PhoneWireError(
                code: .badPayload,
                message: "VFS_REFUSED requires path, limit and reason")
        }
        guard (acceptedBytes == nil) == (mseq == nil) else {
            throw PhoneWireError(
                code: .badPayload,
                message: "VFS_REFUSED accepted_bytes and mseq must be present together")
        }
        if let acceptedBytes, acceptedBytes > limit {
            throw PhoneWireError(
                code: .badPayload,
                message: "VFS_REFUSED accepted_bytes must not exceed limit")
        }
        if let mseq, mseq < 1 {
            throw PhoneWireError(
                code: .badPayload,
                message: "VFS_REFUSED mseq must be at least 1")
        }
    }

    private enum CodingKeys: String, CodingKey {
        case code, message, path, limit, reason, mseq
        case refSeq = "ref_seq"
        case acceptedBytes = "accepted_bytes"
    }
}

/// Canonical API_REQ head (channel.md §4.9).
public struct ApiRequestHead: Codable, Equatable, Sendable {
    public var method: String
    public var path: String
    public var headers: [String: String]

    public init(method: String, path: String, headers: [String: String] = [:]) {
        self.method = method
        self.path = path
        self.headers = headers
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        method = try container.decode(String.self, forKey: .method)
        path = try container.decode(String.self, forKey: .path)
        headers = try container.decode([String: String].self, forKey: .headers)
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(method, forKey: .method)
        try container.encode(path, forKey: .path)
        try container.encode(headers, forKey: .headers)
    }

    public func validate() throws {
        guard !method.isEmpty,
              method.unicodeScalars.allSatisfy({ scalar in
                  switch scalar.value {
                  case 0x41...0x5A, 0x30...0x39, 0x2D:
                      return true
                  default:
                      return false
                  }
              })
        else {
            throw PhoneWireError(code: .badPayload, message: "invalid API request method")
        }
        guard path.hasPrefix("/") else {
            throw PhoneWireError(code: .badPayload, message: "API request path must start with /")
        }
        for name in headers.keys where !WireValidation.isValidLowercaseHeaderName(name) {
            throw PhoneWireError(code: .badPayload, message: "invalid API request header name")
        }
    }

    private enum CodingKeys: String, CodingKey {
        case method, path, headers
    }
}

/// Canonical API_RES head (channel.md §4.9).
public struct ApiResponseHead: Codable, Equatable, Sendable {
    public var status: Int
    public var headers: [String: String]

    public init(status: Int, headers: [String: String] = [:]) {
        self.status = status
        self.headers = headers
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(Int.self, forKey: .status)
        headers = try container.decode([String: String].self, forKey: .headers)
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(status, forKey: .status)
        try container.encode(headers, forKey: .headers)
    }

    public func validate() throws {
        guard (100...599).contains(status) else {
            throw PhoneWireError(code: .badPayload, message: "API response status is not 100–599")
        }
        for name in headers.keys where !WireValidation.isValidLowercaseHeaderName(name) {
            throw PhoneWireError(code: .badPayload, message: "invalid API response header name")
        }
    }

    private enum CodingKeys: String, CodingKey {
        case status, headers
    }
}
