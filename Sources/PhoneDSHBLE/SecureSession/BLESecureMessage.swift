// SPDX-License-Identifier: MIT
// §7.3 messages and §7.4 error codes. Shape authority:
// spec/device/v1/schema/ble-secure-message.schema.json. Every member set is
// closed; any violation is the fatal `malformed`.
import Foundation
import PhoneDSHDeviceTasks

public enum BLESecureErrorCode: String, CaseIterable, Error, Equatable, Sendable {
    case malformed, limit
    case badSequence = "bad_sequence", badChallenge = "bad_challenge", notReady = "not_ready"
    case recordMismatch = "record_mismatch", revoked, storage, timeout, `internal`
    case unknownTask = "unknown_task", invalidTransition = "invalid_transition", conflict
    case wrongOwner = "wrong_owner"

    /// Fatal codes close the session; request-level codes do not.
    public var isFatal: Bool {
        switch self {
        case .unknownTask, .invalidTransition, .conflict, .wrongOwner: return false
        default: return true
        }
    }
}

public enum BLESecureTaskPhase: String, Equatable, Sendable {
    case unknown, queued, accepted, completed, failed
}

public enum BLESecureApplyResult: String, Equatable, Sendable { case applied, duplicate }

public enum BLESecureClientMessage: Equatable, Sendable {
    case readyReq(seq: Int, device: String, phone: String, eid: String, cc: String)
    case next(seq: Int, sc: String)
    case accept(seq: Int, sc: String, id: String, idem: String)
    case complete(seq: Int, sc: String, id: String, idem: String, output: String, truncated: Bool)
    case fail(seq: Int, sc: String, id: String, idem: String, kind: DeviceTaskFailureKind, message: String)
    case status(seq: Int, sc: String, id: String, idem: String)
    /// Client-detected fatal error; `re` is always 0.
    case err(code: BLESecureErrorCode)

    public var typeName: String {
        switch self {
        case .readyReq: return "ready_req"
        case .next: return "next"
        case .accept: return "accept"
        case .complete: return "complete"
        case .fail: return "fail"
        case .status: return "status"
        case .err: return "err"
        }
    }

    public var seq: Int? {
        switch self {
        case .readyReq(let s, _, _, _, _), .next(let s, _), .accept(let s, _, _, _),
             .complete(let s, _, _, _, _, _), .fail(let s, _, _, _, _, _), .status(let s, _, _, _): return s
        case .err: return nil
        }
    }
}

public enum BLESecureServerMessage: Equatable, Sendable {
    case readyAck(device: String, phone: String, eid: String, cc: String, sc: String)
    /// `task` and `phase` are both present or both null.
    case nextR(re: Int, task: DeviceTask?, phase: BLESecureTaskPhase?)
    case r(re: Int, result: BLESecureApplyResult, phase: BLESecureTaskPhase)
    case statusR(re: Int, phase: BLESecureTaskPhase, mine: Bool, outcome: DeviceTaskOutcome?)
    case err(re: Int, code: BLESecureErrorCode)

    public var typeName: String {
        switch self {
        case .readyAck: return "ready_ack"
        case .nextR: return "next_r"
        case .r: return "r"
        case .statusR: return "status_r"
        case .err: return "err"
        }
    }

    public var re: Int {
        switch self {
        case .readyAck: return 1
        case .nextR(let re, _, _), .r(let re, _, _), .statusR(let re, _, _, _), .err(let re, _): return re
        }
    }
}

/// Decodes and encodes §7 payloads. Every rejection is `malformed`.
public enum BLESecureMessageCodec {
    public static let maxOutputBytes = 1024
    public static let maxFailureMessageBytes = 256

    // MARK: decode

    public static func decodeClient(_ payload: [UInt8]) throws -> BLESecureClientMessage {
        let (object, t) = try envelope(payload)
        func seq() throws -> Int { try integer(object, "seq", 1...65535) }
        func sc() throws -> String { try challenge(object, "sc") }
        switch t {
        case "ready_req":
            try closed(object, ["v", "t", "seq", "device", "phone", "eid", "cc"])
            let device = try string(object, "device"), phone = try string(object, "phone"), eid = try string(object, "eid")
            guard BLESecureIdentifiers.isDeviceID(device), BLESecureIdentifiers.isPhoneID(phone),
                  BLESecureIdentifiers.isEID(eid) else { throw BLESecureErrorCode.malformed }
            return .readyReq(seq: try seq(), device: device, phone: phone, eid: eid, cc: try challenge(object, "cc"))
        case "next":
            try closed(object, ["v", "t", "seq", "sc"])
            return .next(seq: try seq(), sc: try sc())
        case "accept":
            try closed(object, ["v", "t", "seq", "sc", "id", "idem"])
            return .accept(seq: try seq(), sc: try sc(), id: try taskID(object, "id"), idem: try taskID(object, "idem"))
        case "complete":
            try closed(object, ["v", "t", "seq", "sc", "id", "idem", "output", "truncated"])
            let output = try string(object, "output")
            guard output.utf8.count <= maxOutputBytes, let truncated = object["truncated"]?.boolValue else { throw BLESecureErrorCode.malformed }
            return .complete(seq: try seq(), sc: try sc(), id: try taskID(object, "id"), idem: try taskID(object, "idem"),
                             output: output, truncated: truncated)
        case "fail":
            try closed(object, ["v", "t", "seq", "sc", "id", "idem", "failure"])
            let (kind, message) = try failure(object["failure"])
            return .fail(seq: try seq(), sc: try sc(), id: try taskID(object, "id"), idem: try taskID(object, "idem"),
                         kind: kind, message: message)
        case "status":
            try closed(object, ["v", "t", "seq", "sc", "id", "idem"])
            return .status(seq: try seq(), sc: try sc(), id: try taskID(object, "id"), idem: try taskID(object, "idem"))
        case "err":
            try closed(object, ["v", "t", "re", "code"])
            guard try integer(object, "re", 0...65535) == 0 else { throw BLESecureErrorCode.malformed }
            return .err(code: try errorCode(object))
        default:
            throw BLESecureErrorCode.malformed
        }
    }

    public static func decodeServer(_ payload: [UInt8]) throws -> BLESecureServerMessage {
        let (object, t) = try envelope(payload)
        switch t {
        case "ready_ack":
            try closed(object, ["v", "t", "re", "device", "phone", "eid", "cc", "sc"])
            guard try integer(object, "re", 1...1) == 1 else { throw BLESecureErrorCode.malformed }
            let device = try string(object, "device"), phone = try string(object, "phone"), eid = try string(object, "eid")
            guard BLESecureIdentifiers.isDeviceID(device), BLESecureIdentifiers.isPhoneID(phone),
                  BLESecureIdentifiers.isEID(eid) else { throw BLESecureErrorCode.malformed }
            return .readyAck(device: device, phone: phone, eid: eid, cc: try challenge(object, "cc"), sc: try challenge(object, "sc"))
        case "next_r":
            try closed(object, ["v", "t", "re", "task", "phase"])
            let re = try integer(object, "re", 1...65535)
            guard let taskValue = object["task"], let phaseValue = object["phase"] else { throw BLESecureErrorCode.malformed }
            if taskValue.isNull && phaseValue.isNull { return .nextR(re: re, task: nil, phase: nil) }
            guard case .object = taskValue, let phaseText = phaseValue.stringValue,
                  let phase = BLESecureTaskPhase(rawValue: phaseText), phase == .queued || phase == .accepted else {
                throw BLESecureErrorCode.malformed
            }
            // The task-delegation rules (and its own unknown-member policy)
            // apply inside the task object only.
            guard let task = try? DeviceTask.decode(Data(taskValue.encoded())) else { throw BLESecureErrorCode.malformed }
            return .nextR(re: re, task: task, phase: phase)
        case "r":
            try closed(object, ["v", "t", "re", "result", "phase"])
            guard let result = object["result"]?.stringValue.flatMap(BLESecureApplyResult.init(rawValue:)),
                  let phase = object["phase"]?.stringValue.flatMap(BLESecureTaskPhase.init(rawValue:)),
                  [.accepted, .completed, .failed].contains(phase) else { throw BLESecureErrorCode.malformed }
            return .r(re: try integer(object, "re", 1...65535), result: result, phase: phase)
        case "status_r":
            let hasOutcome = object["outcome"] != nil
            try closed(object, hasOutcome ? ["v", "t", "re", "phase", "mine", "outcome"] : ["v", "t", "re", "phase", "mine"])
            guard let phase = object["phase"]?.stringValue.flatMap(BLESecureTaskPhase.init(rawValue:)),
                  let mine = object["mine"]?.boolValue else { throw BLESecureErrorCode.malformed }
            let terminal = phase == .completed || phase == .failed
            guard hasOutcome == (terminal && mine), !(mine && (phase == .unknown || phase == .queued)) else {
                throw BLESecureErrorCode.malformed
            }
            var outcome: DeviceTaskOutcome?
            if let value = object["outcome"] {
                outcome = try self.outcome(value)
                if case .completed = outcome!, phase != .completed { throw BLESecureErrorCode.malformed }
                if case .failed = outcome!, phase != .failed { throw BLESecureErrorCode.malformed }
            }
            return .statusR(re: try integer(object, "re", 1...65535), phase: phase, mine: mine, outcome: outcome)
        case "err":
            try closed(object, ["v", "t", "re", "code"])
            return .err(re: try integer(object, "re", 0...65535), code: try errorCode(object))
        default:
            throw BLESecureErrorCode.malformed
        }
    }

    // MARK: encode

    public static func encode(_ message: BLESecureClientMessage) -> [UInt8] {
        var m: [(String, BLESecureJSON)] = [("v", .number("1")), ("t", .string(message.typeName))]
        switch message {
        case .readyReq(let seq, let device, let phone, let eid, let cc):
            m += [("seq", int(seq)), ("device", .string(device)), ("phone", .string(phone)), ("eid", .string(eid)), ("cc", .string(cc))]
        case .next(let seq, let sc):
            m += [("seq", int(seq)), ("sc", .string(sc))]
        case .accept(let seq, let sc, let id, let idem), .status(let seq, let sc, let id, let idem):
            m += [("seq", int(seq)), ("sc", .string(sc)), ("id", .string(id)), ("idem", .string(idem))]
        case .complete(let seq, let sc, let id, let idem, let output, let truncated):
            m += [("seq", int(seq)), ("sc", .string(sc)), ("id", .string(id)), ("idem", .string(idem)),
                  ("output", .string(output)), ("truncated", .bool(truncated))]
        case .fail(let seq, let sc, let id, let idem, let kind, let message):
            m += [("seq", int(seq)), ("sc", .string(sc)), ("id", .string(id)), ("idem", .string(idem)),
                  ("failure", failureJSON(kind, message))]
        case .err(let code):
            m += [("re", .number("0")), ("code", .string(code.rawValue))]
        }
        return BLESecureJSON.object(m.map { .init(name: $0.0, value: $0.1) }).encoded()
    }

    public static func encode(_ message: BLESecureServerMessage) -> [UInt8] {
        var m: [(String, BLESecureJSON)] = [("v", .number("1")), ("t", .string(message.typeName)), ("re", int(message.re))]
        switch message {
        case .readyAck(let device, let phone, let eid, let cc, let sc):
            m += [("device", .string(device)), ("phone", .string(phone)), ("eid", .string(eid)), ("cc", .string(cc)), ("sc", .string(sc))]
        case .nextR(_, let task, let phase):
            let taskJSON: BLESecureJSON = task.flatMap { try? BLESecureJSON.parse(Array(JSONEncoder.sorted.encode($0))) } ?? .null
            m += [("task", taskJSON), ("phase", phase.map { .string($0.rawValue) } ?? .null)]
        case .r(_, let result, let phase):
            m += [("result", .string(result.rawValue)), ("phase", .string(phase.rawValue))]
        case .statusR(_, let phase, let mine, let outcome):
            m += [("phase", .string(phase.rawValue)), ("mine", .bool(mine))]
            if let outcome { m.append(("outcome", outcomeJSON(outcome))) }
        case .err(_, let code):
            m += [("code", .string(code.rawValue))]
        }
        return BLESecureJSON.object(m.map { .init(name: $0.0, value: $0.1) }).encoded()
    }

    /// The §9.1 outcome body: `{output,truncated}` or `{failure:{kind,message}}`.
    public static func outcomeJSON(_ outcome: DeviceTaskOutcome) -> BLESecureJSON {
        switch outcome {
        case .completed(let output, let truncated):
            return .object([.init(name: "output", value: .string(output)), .init(name: "truncated", value: .bool(truncated))])
        case .failed(let kind, let message):
            return .object([.init(name: "failure", value: failureJSON(kind, message))])
        }
    }

    static func failureJSON(_ kind: DeviceTaskFailureKind, _ message: String) -> BLESecureJSON {
        .object([.init(name: "kind", value: .string(kind.rawValue)), .init(name: "message", value: .string(message))])
    }

    // MARK: helpers

    private static func int(_ value: Int) -> BLESecureJSON { .number(String(value)) }

    private static func envelope(_ payload: [UInt8]) throws -> (BLESecureJSON, String) {
        guard let value = try? BLESecureJSON.parse(payload), case .object = value,
              value["v"]?.integerValue == 1, let t = value["t"]?.stringValue else { throw BLESecureErrorCode.malformed }
        return (value, t)
    }

    private static func closed(_ object: BLESecureJSON, _ names: [String]) throws {
        guard let present = object.memberNames, present.count == names.count,
              Set(present.map { Array($0.utf8) }) == Set(names.map { Array($0.utf8) }) else { throw BLESecureErrorCode.malformed }
    }

    private static func string(_ object: BLESecureJSON, _ name: String) throws -> String {
        guard let value = object[name]?.stringValue else { throw BLESecureErrorCode.malformed }
        return value
    }

    private static func integer(_ object: BLESecureJSON, _ name: String, _ range: ClosedRange<Int>) throws -> Int {
        guard let value = object[name]?.integerValue, range.contains(Int(value)) else { throw BLESecureErrorCode.malformed }
        return Int(value)
    }

    private static func challenge(_ object: BLESecureJSON, _ name: String) throws -> String {
        let value = try string(object, name)
        guard BLESecureIdentifiers.isChallenge(value) else { throw BLESecureErrorCode.malformed }
        return value
    }

    /// `^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$`
    static func isTaskID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        func alnum(_ b: UInt8) -> Bool { (48...57).contains(b) || (65...90).contains(b) || (97...122).contains(b) }
        guard (1...64).contains(bytes.count), alnum(bytes[0]) else { return false }
        return bytes.allSatisfy { alnum($0) || [46, 95, 58, 45].contains($0) }
    }

    private static func taskID(_ object: BLESecureJSON, _ name: String) throws -> String {
        let value = try string(object, name)
        guard isTaskID(value) else { throw BLESecureErrorCode.malformed }
        return value
    }

    private static func errorCode(_ object: BLESecureJSON) throws -> BLESecureErrorCode {
        guard let code = object["code"]?.stringValue.flatMap(BLESecureErrorCode.init(rawValue:)) else { throw BLESecureErrorCode.malformed }
        return code
    }

    private static func failure(_ value: BLESecureJSON?) throws -> (DeviceTaskFailureKind, String) {
        guard let value, case .object = value else { throw BLESecureErrorCode.malformed }
        try closed(value, ["kind", "message"])
        guard let kind = value["kind"]?.stringValue.flatMap(DeviceTaskFailureKind.init(rawValue:)),
              let message = value["message"]?.stringValue,
              message.utf8.count <= maxFailureMessageBytes else { throw BLESecureErrorCode.malformed }
        return (kind, message)
    }

    private static func outcome(_ value: BLESecureJSON) throws -> DeviceTaskOutcome {
        guard case .object = value else { throw BLESecureErrorCode.malformed }
        if value["failure"] != nil {
            try closed(value, ["failure"])
            let (kind, message) = try failure(value["failure"])
            return .failed(kind: kind, message: message)
        }
        try closed(value, ["output", "truncated"])
        let output = try string(value, "output")
        guard output.utf8.count <= maxOutputBytes, let truncated = value["truncated"]?.boolValue else { throw BLESecureErrorCode.malformed }
        return .completed(output: output, truncated: truncated)
    }
}

extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
