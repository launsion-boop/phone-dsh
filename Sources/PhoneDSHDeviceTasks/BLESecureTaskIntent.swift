// SPDX-License-Identifier: MIT
// secure-session-v1 §9.2 transition intents (`ble-secure-ops`) and the §9.3
// lost-reply recovery decision. The journal format v1 is unchanged; the BLE
// task device identity is `ble:` + the enrolled device key fingerprint.
import CryptoKit
import Foundation

/// The exact request arguments of a secure transition.
public enum BLESecureTransitionArguments: Equatable, Sendable {
    case accept(id: String, idem: String)
    case complete(id: String, idem: String, output: String, truncated: Bool)
    case fail(id: String, idem: String, kind: DeviceTaskFailureKind, message: String)

    public var action: BLESecureTaskIntent.Action {
        switch self { case .accept: return .accept; case .complete: return .complete; case .fail: return .fail }
    }
    public var id: String {
        switch self { case .accept(let i, _), .complete(let i, _, _, _), .fail(let i, _, _, _): return i }
    }
    public var idem: String {
        switch self { case .accept(_, let k), .complete(_, let k, _, _), .fail(_, let k, _, _): return k }
    }

    /// Canonical UTF-8 JSON (§9.2): keys sorted, no insignificant whitespace,
    /// non-ASCII and `/` literal, `"` and `\` escaped, `\b \t \n \f \r`, other
    /// controls `\u00xx` lowercase.
    public var canonicalJSON: [UInt8] {
        var out: [UInt8] = []
        func string(_ s: String) {
            let hex = Array("0123456789abcdef".utf8)
            out.append(34)
            for scalar in s.unicodeScalars {
                switch scalar.value {
                case 0x22: out += [92, 34]
                case 0x5C: out += [92, 92]
                case 0x08: out += [92, 98]
                case 0x09: out += [92, 116]
                case 0x0A: out += [92, 110]
                case 0x0C: out += [92, 102]
                case 0x0D: out += [92, 114]
                case 0..<0x20: out += [92, 117, 48, 48, hex[Int(scalar.value >> 4)], hex[Int(scalar.value & 15)]]
                default: out += Array(String(scalar).utf8)
                }
            }
            out.append(34)
        }
        func key(_ k: String, first: Bool = false) { if !first { out.append(44) }; string(k); out.append(58) }
        out.append(123)
        switch self {
        case .accept(let id, let idem):
            key("id", first: true); string(id); key("idem"); string(idem)
        case .complete(let id, let idem, let output, let truncated):
            key("id", first: true); string(id); key("idem"); string(idem)
            key("output"); string(output); key("truncated"); out += Array((truncated ? "true" : "false").utf8)
        case .fail(let id, let idem, let kind, let message):
            // "failure" sorts before "id"; inside it "kind" before "message".
            key("failure", first: true); out.append(123)
            key("kind", first: true); string(kind.rawValue); key("message"); string(message); out.append(125)
            key("id"); string(id); key("idem"); string(idem)
        }
        out.append(125)
        return out
    }

    public var sha256: String { SHA256.hash(data: canonicalJSON).map { String(format: "%02x", $0) }.joined() }

    /// Arguments reconstructed solely from a persisted parent record; complete
    /// and fail require the matching terminal outcome.
    public static func reconstruct(record: DeviceTaskRecord, action: BLESecureTaskIntent.Action) throws -> Self {
        let id = record.task.id, idem = record.task.idempotencyKey
        switch action {
        case .accept: return .accept(id: id, idem: idem)
        case .complete:
            guard record.phase == .terminal, case .completed(let output, let truncated) = record.outcome else { throw DeviceTaskError.corruptJournal }
            return .complete(id: id, idem: idem, output: output, truncated: truncated)
        case .fail:
            guard record.phase == .terminal, case .failed(let kind, let message) = record.outcome else { throw DeviceTaskError.corruptJournal }
            return .fail(id: id, idem: idem, kind: kind, message: message)
        }
    }
}

/// The secure-session binding of the executor (§9.2, §9.3). The executor
/// durably installs the `ble-secure-ops` intent before every call. `fresh` is
/// true only in the call that installed it; otherwise the binding MUST first
/// query `status` and may resend the identical persisted arguments only as the
/// very next request. A binding never sends anything without an intent.
public protocol BLESecureTaskInbox: DeviceTaskInbox {
    /// The current phone key (`phone:` + 64 hex) the intent is bound to.
    var phoneID: String { get }
    func transition(_ arguments: BLESecureTransitionArguments, intent: BLESecureTaskIntent, fresh: Bool) async throws
}

public extension BLESecureTaskInbox {
    func accept(id: String) async throws { throw DeviceTaskError.unauthorized }
    func report(id: String, outcome: DeviceTaskOutcome) async throws { throw DeviceTaskError.unauthorized }
}

/// Why a secure transition did not complete. Every case keeps the intent.
public enum BLESecureTaskInboxError: Error, Equatable, Sendable {
    /// A definitive device answer (§8.2 request-level error, §9.3 unresolved):
    /// never resend; the user must see it.
    case unresolved(String)
    /// No authoritative answer (no ready session, timeout, fatal close):
    /// query again with `status` in a later ready session.
    case retryLater
    /// The grant's accept window has ended; the parent stays `received` and
    /// its intent is reconciled in a later grant.
    case windowClosed
    /// The grant or the connection generation ended.
    case grantEnded
}

/// `schema/ble-secure-task-intent.schema.json`.
public struct BLESecureTaskIntent: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable { case accept, complete, fail }
    public let v: Int
    public let msgID: String
    public let deviceID: String
    public let phoneID: String
    public let taskID: String
    public let action: Action
    public let idem: String
    public let argumentsSHA256: String

    enum CodingKeys: String, CodingKey {
        case v, action, idem
        case msgID = "msg_id", deviceID = "device_id", phoneID = "phone_id", taskID = "task_id"
        case argumentsSHA256 = "arguments_sha256"
    }

    static let keys: Set<String> = ["v", "msg_id", "device_id", "phone_id", "task_id", "action", "idem", "arguments_sha256"]

    public static func isSecureDeviceID(_ value: String) -> Bool { prefixedHex(value, "ble:") }
    public static func isPhoneID(_ value: String) -> Bool { prefixedHex(value, "phone:") }

    private static func prefixedHex(_ value: String, _ prefix: String) -> Bool {
        guard value.hasPrefix(prefix) else { return false }
        let rest = Array(value.utf8.dropFirst(prefix.utf8.count))
        return rest.count == 64 && rest.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    public static func make(deviceID: String, phoneID: String, arguments: BLESecureTransitionArguments) throws -> BLESecureTaskIntent {
        guard isSecureDeviceID(deviceID), isPhoneID(phoneID), DeviceTask.validID(arguments.id),
              DeviceTask.validID(arguments.idem) else { throw DeviceTaskError.invalidTask }
        return BLESecureTaskIntent(v: 1, msgID: DeviceTaskJournal.msgID(deviceID: deviceID, key: arguments.idem),
                                   deviceID: deviceID, phoneID: phoneID, taskID: arguments.id,
                                   action: arguments.action, idem: arguments.idem, argumentsSHA256: arguments.sha256)
    }

    /// Strict decoding: unique keys, exactly the schema key set, v 1, patterns.
    public static func decode(_ data: Data) throws -> BLESecureTaskIntent {
        var unique = UniqueJSONKeys(data)
        guard unique.check(rejectNUL: true),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == keys, object.count == keys.count,
              let intent = try? JSONDecoder().decode(BLESecureTaskIntent.self, from: data),
              intent.v == 1, isSecureDeviceID(intent.deviceID), isPhoneID(intent.phoneID),
              DeviceTask.validID(intent.taskID), DeviceTask.validID(intent.idem),
              intent.msgID.utf8.count == 64, intent.argumentsSHA256.utf8.count == 64,
              (intent.msgID + intent.argumentsSHA256).utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { throw DeviceTaskError.corruptJournal }
        return intent
    }

    var fileName: String { msgID + "-" + action.rawValue + ".json" }
}

/// §9.3: what a `status` answer authorizes for a persisted intent.
public enum BLESecureRecoveryDecision: String, Equatable, Sendable {
    /// The device state proves this exact transition happened.
    case applied
    /// The device state proves it did not happen and the precondition holds:
    /// resend the identical persisted arguments.
    case resend
    /// Definitive mismatch: keep the intent, never resend, user-visible.
    case unresolved
    /// No authoritative answer: keep the intent, query in a later session.
    case retryQuery = "retry_query"
}

/// The phone's view of a `status` exchange in a ready session.
public enum BLESecureStatusObservation: Equatable, Sendable {
    /// No session, timeout or the session failed before an answer.
    case none
    /// An `err` reply (request-level or fatal) with its code.
    case error(code: String)
    case status(phase: String, mine: Bool, outcome: DeviceTaskOutcome?)
}

public enum BLESecureRecovery {
    public static func decide(intent: BLESecureTaskIntent, currentPhoneID: String,
                              arguments: BLESecureTransitionArguments,
                              observation: BLESecureStatusObservation) -> BLESecureRecoveryDecision {
        // After a phone key reset the intent belongs to another key (§9.3).
        guard intent.phoneID == currentPhoneID, intent.action == arguments.action,
              intent.argumentsSHA256 == arguments.sha256 else { return .unresolved }
        return decide(arguments: arguments, observation: observation)
    }

    public static func decide(arguments: BLESecureTransitionArguments,
                              observation: BLESecureStatusObservation) -> BLESecureRecoveryDecision {
        switch observation {
        case .none: return .retryQuery
        case .error(let code): return code == "conflict" ? .unresolved : .retryQuery
        case .status(let phase, let mine, let outcome):
            switch arguments {
            case .accept:
                if phase == "accepted" && mine { return .applied }
                if phase == "queued" { return .resend }
                return .unresolved
            case .complete(_, _, let output, let truncated):
                if (phase == "completed" || phase == "failed") && mine {
                    return phase == "completed" && outcome == .completed(output: output, truncated: truncated) ? .applied : .unresolved
                }
                return phase == "accepted" && mine ? .resend : .unresolved
            case .fail(_, _, let kind, let message):
                if (phase == "completed" || phase == "failed") && mine {
                    return phase == "failed" && outcome == .failed(kind: kind, message: message) ? .applied : .unresolved
                }
                return phase == "accepted" && mine ? .resend : .unresolved
            }
        }
    }
}
