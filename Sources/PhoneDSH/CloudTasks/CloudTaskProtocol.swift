// SPDX-License-Identifier: MIT
// phone-dsh SDK — PhoneDSH: phone task queue wire shapes (phone side).
//
// spec/v1/cloud-tasks.md, revision `cloud-tasks-v1.3`. Pure values: the closed
// request validators, the typed bodies the phone sends, the open decoders for
// what the cloud answers (unknown members are ignored, the named ones are
// required), the sealing AAD and the push recogniser. The
// shared cases (`spec/v1/golden/cloud-tasks/cases.json`) judge all of it.
// Nothing here touches the network, the Keychain or a clock.

import Foundation
import PhoneDSHGateway

/// Constants of the phone task queue contract.
public enum CloudTasks {
    public static let revision = "cloud-tasks-v1.3"
    /// The cloud origin of tono-account.md §1; the only host this feature contacts.
    public static let origin = URL(string: TonoCloudResponsePolicy.cloudOrigin)!
    public static let suite = "hpke-p256-sha256-aes128gcm"
    /// HPKE `info` and the first AAD line.
    public static let info = "pdsh-phone-task/v1"
    public static let maxTextBytes = 16_384
    public static let minTtlMs: Int64 = 60_000
    public static let maxTtlMs: Int64 = 604_800_000
    public static let maxPending = 256
    public static let maxDevices = 8
    /// Pull `limit` and acks per call.
    public static let batchMax = 16
    /// §7: a task with less than this left is acknowledged `expired`.
    public static let minRemainingMs: Int64 = 1_000
    public static let maxInteger: Int64 = 9_007_199_254_740_991

    /// Preference key of the install's cloud device id (shared with the Bot cloud scheduler).
    public static let deviceIDPreferenceKey = "phone-dsh.bot.cloud.device-id.v1"
    /// Preference key of the user's switch; absent means off.
    public static let enabledPreferenceKey = "phone-dsh.cloud-tasks.enabled.v1"
    /// Keychain service of the private keys; the account is the `key_id`.
    public static let keychainService = "dev.phone-dsh.cloud-tasks"

    public static let pushVersion = 1
    public static let pushKind = "phone-tasks"

    /// §8: true only for `{"pdsh":{"v":1,"kind":"phone-tasks"}}`. Any other
    /// version or kind — and any payload without `pdsh` — is not ours and is ignored.
    public static func isTaskPush(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let pdsh = userInfo["pdsh"] as? [AnyHashable: Any],
              CloudTaskJSON.integer(pdsh["v"]) == Int64(pushVersion),
              pdsh["kind"] as? String == pushKind else { return false }
        return true
    }

    /// §3 AAD: seven lines joined by `\n`, no trailing newline.
    public static func aad(deviceID: String, keyID: String, requestID: String,
                           target: CloudTaskTarget, expiresAtMs: Int64) -> Data {
        Data([info, deviceID, keyID, requestID, target.kind.rawValue, target.id, String(expiresAtMs)]
            .joined(separator: "\n").utf8)
    }
}

/// Why a body is not a message of this contract.
public struct CloudTaskWireError: Error, Equatable, Sendable, CustomStringConvertible {
    public let reason: String
    public init(_ reason: String) { self.reason = reason }
    public var description: String { "cloud-tasks wire: \(reason)" }
}

// MARK: - Strict JSON helpers

enum CloudTaskJSON {
    /// A JSON integer (not a bool, not a float) within 0 … 2^53−1.
    static func integer(_ value: Any?, low: Int64 = 0, high: Int64 = CloudTasks.maxInteger) -> Int64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              !CFNumberIsFloatType(number) else { return nil }
        let integer = number.int64Value
        guard NSNumber(value: integer) == number, integer >= low, integer <= high else { return nil }
        return integer
    }

    static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    /// The object, only if it has exactly `required` plus any of `optional`.
    static func closed(_ value: Any?, _ required: [String], optional: [String] = [],
                       _ what: String) throws -> [String: Any] {
        guard let object = value as? [String: Any] else { throw CloudTaskWireError("\(what): not an object") }
        let keys = Set(object.keys)
        guard Set(required).isSubset(of: keys), keys.isSubset(of: Set(required).union(optional)) else {
            throw CloudTaskWireError("\(what): members")
        }
        return object
    }

    /// A response object: unknown members are ignored (§1).
    static func open(_ value: Any?, _ what: String) throws -> [String: Any] {
        guard let object = value as? [String: Any] else { throw CloudTaskWireError("\(what): not an object") }
        return object
    }

    private static func isIDByte(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
            || byte == 0x2E || byte == 0x5F || byte == 0x3A || byte == 0x2D
    }

    /// `[A-Za-z0-9._:-]{1,128}`.
    static func isID(_ value: Any?) -> Bool {
        guard let text = value as? String else { return false }
        let bytes = Array(text.utf8)
        return (1...128).contains(bytes.count) && bytes.allSatisfy(isIDByte)
    }

    static func id(_ value: Any?, _ what: String) throws -> String {
        guard isID(value), let text = value as? String else { throw CloudTaskWireError("\(what): id") }
        return text
    }

    static func isLowerHex(_ text: String, _ range: ClosedRange<Int>) -> Bool {
        let bytes = Array(text.utf8)
        return range.contains(bytes.count)
            && bytes.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }

    /// `dev-` + a lowercase UUIDv4.
    static func isDeviceID(_ value: Any?) -> Bool {
        guard let text = value as? String, text.hasPrefix("dev-") else { return false }
        let bytes = Array(text.utf8.dropFirst(4))
        guard bytes.count == 36 else { return false }
        for (index, byte) in bytes.enumerated() {
            switch index {
            case 8, 13, 18, 23: if byte != 0x2D { return false }
            case 14: if byte != 0x34 { return false }
            case 19: if !"89ab".utf8.contains(byte) { return false }
            default: if !((byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x66)) { return false }
            }
        }
        return true
    }

    /// base64url without padding; `nil` for padding, another alphabet or an impossible length.
    static func base64URLDecode(_ value: Any?) -> Data? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        let bytes = Array(text.utf8)
        guard bytes.count % 4 != 1, bytes.allSatisfy({
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A)
                || $0 == 0x2D || $0 == 0x5F
        }) else { return nil }
        var standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        standard += String(repeating: "=", count: (4 - bytes.count % 4) % 4)
        return Data(base64Encoded: standard)
    }

    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func parse(_ data: Data) throws -> Any {
        guard let value = try? JSONSerialization.jsonObject(with: data) else {
            throw CloudTaskWireError("not JSON")
        }
        return value
    }

    static func encode(_ object: [String: Any]) -> Data {
        // The objects built here hold only strings, integers, NSNull, arrays and dictionaries.
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }
}

// MARK: - Shared members

public struct CloudTaskTarget: Equatable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case dshSession = "dsh-session"
        case bot
    }

    public var kind: Kind
    /// The session id (`dsh-session`) or the bot id (`bot`).
    public var id: String

    public init(kind: Kind, id: String) {
        self.kind = kind
        self.id = id
    }

    /// - Parameter closed: true for a request body, false for a response (§1).
    init(json: Any?, closed: Bool = true) throws {
        let object = closed ? try CloudTaskJSON.closed(json, ["kind", "id"], "target")
                            : try CloudTaskJSON.open(json, "target")
        guard let kind = (object["kind"] as? String).flatMap(Kind.init(rawValue:)) else {
            throw CloudTaskWireError("target kind")
        }
        self.init(kind: kind, id: try CloudTaskJSON.id(object["id"], "target"))
    }
}

/// `sealed`: the 65-byte encapsulated key and ciphertext ‖ tag (17–16400 bytes).
public struct CloudTaskSealed: Equatable, Sendable {
    public static let encapsulatedKeyBytes = 65
    public static let ciphertextBytes = 17...(CloudTasks.maxTextBytes + 16)

    public var enc: Data
    public var ct: Data

    public init(enc: Data, ct: Data) {
        self.enc = enc
        self.ct = ct
    }

    /// - Parameter closed: true for a request body, false for a response (§1).
    init(json: Any?, closed: Bool = true) throws {
        let object = closed ? try CloudTaskJSON.closed(json, ["enc", "ct"], "sealed")
                            : try CloudTaskJSON.open(json, "sealed")
        guard let enc = CloudTaskJSON.base64URLDecode(object["enc"]), enc.count == Self.encapsulatedKeyBytes else {
            throw CloudTaskWireError("sealed enc")
        }
        guard let ct = CloudTaskJSON.base64URLDecode(object["ct"]), Self.ciphertextBytes.contains(ct.count) else {
            throw CloudTaskWireError("sealed ct")
        }
        self.init(enc: enc, ct: ct)
    }
}

// MARK: - Bodies the phone sends

/// The public half of the key tasks are sealed to.
public struct CloudTaskDeviceKey: Equatable, Sendable {
    public var keyID: String
    /// Uncompressed P-256 point, `0x04 ‖ X ‖ Y` (65 bytes).
    public var publicKey: Data

    public init(keyID: String, publicKey: Data) {
        self.keyID = keyID
        self.publicKey = publicKey
    }

    init(json: Any?) throws {
        let object = try CloudTaskJSON.closed(json, ["key_id", "suite", "public_key"], "key")
        let keyID = try CloudTaskJSON.id(object["key_id"], "key_id")
        guard object["suite"] as? String == CloudTasks.suite else { throw CloudTaskWireError("suite") }
        guard let point = CloudTaskJSON.base64URLDecode(object["public_key"]),
              point.count == 65, point.first == 4 else { throw CloudTaskWireError("public key") }
        self.init(keyID: keyID, publicKey: point)
    }

    var json: [String: Any] {
        ["key_id": keyID, "suite": CloudTasks.suite, "public_key": CloudTaskJSON.base64URLEncode(publicKey)]
    }
}

/// The APNs address of this install; never returned by the cloud.
public struct CloudTaskPush: Equatable, Sendable {
    public enum Environment: String, Sendable {
        case development, production
    }

    public var environment: Environment
    /// The app's bundle id (`apns-topic`).
    public var topic: String
    /// The device token as 64–200 lowercase hex characters.
    public var token: String

    public init(environment: Environment, topic: String, token: String) {
        self.environment = environment
        self.topic = topic
        self.token = token
    }

    /// From the bytes `didRegisterForRemoteNotificationsWithDeviceToken` delivers.
    public init(environment: Environment, topic: String, deviceToken: Data) {
        self.init(environment: environment, topic: topic,
                  token: deviceToken.map { String(format: "%02x", $0) }.joined())
    }

    init(json: Any?) throws {
        let object = try CloudTaskJSON.closed(json, ["provider", "environment", "topic", "token"], "push")
        guard object["provider"] as? String == "apns" else { throw CloudTaskWireError("push provider") }
        guard let environment = (object["environment"] as? String).flatMap(Environment.init(rawValue:)) else {
            throw CloudTaskWireError("push environment")
        }
        guard let topic = object["topic"] as? String, (1...155).contains(topic.utf8.count),
              topic.utf8.allSatisfy({ byte in
                  (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A)
                      || (byte >= 0x61 && byte <= 0x7A) || byte == 0x2E || byte == 0x2D
              }) else { throw CloudTaskWireError("push topic") }
        guard let token = object["token"] as? String, CloudTaskJSON.isLowerHex(token, 64...200) else {
            throw CloudTaskWireError("push token")
        }
        self.init(environment: environment, topic: topic, token: token)
    }

    var json: [String: Any] {
        ["provider": "apns", "environment": environment.rawValue, "topic": topic, "token": token]
    }
}

/// `phone-device/v1` (§2).
public struct CloudTaskDeviceRegistration: Equatable, Sendable {
    public static let schema = "phone-device/v1"

    public enum Platform: String, Sendable {
        case ios, android
    }

    public var platform: Platform
    public var appVersion: String
    public var key: CloudTaskDeviceKey
    public var push: CloudTaskPush?

    public init(platform: Platform = .ios, appVersion: String, key: CloudTaskDeviceKey, push: CloudTaskPush?) {
        self.platform = platform
        self.appVersion = appVersion
        self.key = key
        self.push = push
    }

    /// Decodes a body that passes the contract's rules; anything else throws.
    public init(json: Any) throws {
        let object = try CloudTaskJSON.closed(json, ["schema", "platform", "app_version", "key", "push"], "device")
        guard object["schema"] as? String == Self.schema else { throw CloudTaskWireError("unknown schema") }
        guard let platform = (object["platform"] as? String).flatMap(Platform.init(rawValue:)) else {
            throw CloudTaskWireError("platform")
        }
        guard let version = object["app_version"] as? String, (1...32).contains(version.unicodeScalars.count) else {
            throw CloudTaskWireError("app_version")
        }
        let key = try CloudTaskDeviceKey(json: object["key"])
        var push: CloudTaskPush?
        if !(object["push"] is NSNull) {
            push = try CloudTaskPush(json: object["push"])
            guard platform == .ios else { throw CloudTaskWireError("push provider") }
        }
        self.init(platform: platform, appVersion: version, key: key, push: push)
    }

    var json: [String: Any] {
        ["schema": Self.schema, "platform": platform.rawValue, "app_version": appVersion,
         "key": key.json, "push": push.map { $0.json as Any } ?? NSNull()]
    }

    /// The request body. Throws instead of producing a body the contract rejects.
    public func encoded() throws -> Data {
        let object = json
        _ = try Self(json: object)
        return CloudTaskJSON.encode(object)
    }
}

/// One entry of `phone-task-ack/v1` (§6).
public struct CloudTaskAck: Equatable, Sendable {
    public enum RejectReason: String, Sendable, CaseIterable {
        case invalid, conflict
        case targetMissing = "target_missing"
        case decryptFailed = "decrypt_failed"
        case keyUnknown = "key_unknown"
    }

    public enum FailReason: String, Sendable, CaseIterable {
        case targetMissing = "target_missing"
        case notAuthorized = "not_authorized"
        case retryExhausted = "retry_exhausted"
        case runFailed = "run_failed"
        case expired, cancelled
    }

    public enum State: Equatable, Sendable {
        /// The admission journal durably holds the task under this `admissionId` (64 lowercase hex).
        case admitted(admissionID: String)
        case rejected(RejectReason)
        case expired
        case completed
        case failed(FailReason)
        case unknown

        public var name: String {
            switch self {
            case .admitted: return "admitted"
            case .rejected: return "rejected"
            case .expired: return "expired"
            case .completed: return "completed"
            case .failed: return "failed"
            case .unknown: return "unknown"
            }
        }

        /// True for the acks that follow admission (`completed` / `failed` / `unknown`).
        public var isTerminalReport: Bool {
            switch self {
            case .completed, .failed, .unknown: return true
            case .admitted, .rejected, .expired: return false
            }
        }
    }

    public var taskID: String
    public var state: State

    public init(taskID: String, state: State) {
        self.taskID = taskID
        self.state = state
    }

    init(json: Any?) throws {
        guard let raw = json as? [String: Any] else { throw CloudTaskWireError("ack") }
        let state: State
        switch raw["state"] as? String {
        case "admitted":
            let object = try CloudTaskJSON.closed(raw, ["task_id", "state", "admission_id"], "ack")
            guard let id = object["admission_id"] as? String, CloudTaskJSON.isLowerHex(id, 64...64) else {
                throw CloudTaskWireError("admission_id")
            }
            state = .admitted(admissionID: id)
        case "rejected":
            let object = try CloudTaskJSON.closed(raw, ["task_id", "state", "reason"], "ack")
            guard let reason = (object["reason"] as? String).flatMap(RejectReason.init(rawValue:)) else {
                throw CloudTaskWireError("reason")
            }
            state = .rejected(reason)
        case "failed":
            let object = try CloudTaskJSON.closed(raw, ["task_id", "state", "reason"], "ack")
            guard let reason = (object["reason"] as? String).flatMap(FailReason.init(rawValue:)) else {
                throw CloudTaskWireError("reason")
            }
            state = .failed(reason)
        case "expired":
            _ = try CloudTaskJSON.closed(raw, ["task_id", "state"], "ack"); state = .expired
        case "completed":
            _ = try CloudTaskJSON.closed(raw, ["task_id", "state"], "ack"); state = .completed
        case "unknown":
            _ = try CloudTaskJSON.closed(raw, ["task_id", "state"], "ack"); state = .unknown
        default:
            throw CloudTaskWireError("ack state")
        }
        self.init(taskID: try CloudTaskJSON.id(raw["task_id"], "task_id"), state: state)
    }

    var json: [String: Any] {
        var object: [String: Any] = ["task_id": taskID, "state": state.name]
        switch state {
        case .admitted(let admissionID): object["admission_id"] = admissionID
        case .rejected(let reason): object["reason"] = reason.rawValue
        case .failed(let reason): object["reason"] = reason.rawValue
        case .expired, .completed, .unknown: break
        }
        return object
    }
}

/// `phone-task-ack/v1` (§5): 1–16 acks of one device.
public struct CloudTaskAckBatch: Equatable, Sendable {
    public static let schema = "phone-task-ack/v1"

    public var deviceID: String
    public var acks: [CloudTaskAck]

    public init(deviceID: String, acks: [CloudTaskAck]) {
        self.deviceID = deviceID
        self.acks = acks
    }

    /// Decodes a body that passes the contract's rules; anything else throws.
    public init(json: Any) throws {
        let object = try CloudTaskJSON.closed(json, ["schema", "device_id", "acks"], "ack body")
        guard object["schema"] as? String == Self.schema else { throw CloudTaskWireError("unknown schema") }
        guard CloudTaskJSON.isDeviceID(object["device_id"]), let deviceID = object["device_id"] as? String else {
            throw CloudTaskWireError("device_id")
        }
        guard let acks = object["acks"] as? [Any], (1...CloudTasks.batchMax).contains(acks.count) else {
            throw CloudTaskWireError("acks")
        }
        self.init(deviceID: deviceID, acks: try acks.map { try CloudTaskAck(json: $0) })
    }

    var json: [String: Any] {
        ["schema": Self.schema, "device_id": deviceID, "acks": acks.map(\.json)]
    }

    /// The request body. Throws instead of producing a body the contract rejects.
    public func encoded() throws -> Data {
        let object = json
        _ = try Self(json: object)
        return CloudTaskJSON.encode(object)
    }
}

/// The request-body rules of the contract (`messages` in the shared cases).
public enum CloudTaskWire {
    /// Throws unless `json` is a valid request body of this contract. The
    /// phone sends only `phone-device/v1` and `phone-task-ack/v1`;
    /// `phone-task-submit/v1` is the submitter's body and is judged here only
    /// so the whole shared list runs through one validator.
    public static func validateRequest(_ json: Any) throws {
        guard let object = json as? [String: Any] else { throw CloudTaskWireError("not an object") }
        switch object["schema"] as? String {
        case CloudTaskDeviceRegistration.schema:
            _ = try CloudTaskDeviceRegistration(json: object)
        case CloudTaskAckBatch.schema:
            _ = try CloudTaskAckBatch(json: object)
        case "phone-task-submit/v1":
            let body = try CloudTaskJSON.closed(object, ["schema", "device_id", "request_id", "key_id", "target",
                                                         "expires_at_ms", "sealed"], "submit")
            guard CloudTaskJSON.isDeviceID(body["device_id"]) else { throw CloudTaskWireError("device_id") }
            _ = try CloudTaskJSON.id(body["request_id"], "request_id")
            _ = try CloudTaskJSON.id(body["key_id"], "key_id")
            _ = try CloudTaskTarget(json: body["target"])
            guard CloudTaskJSON.integer(body["expires_at_ms"]) != nil else { throw CloudTaskWireError("expires_at_ms") }
            _ = try CloudTaskSealed(json: body["sealed"])
        default:
            throw CloudTaskWireError("unknown schema")
        }
    }

    public static func validateRequest(data: Data) throws {
        try validateRequest(try CloudTaskJSON.parse(data))
    }
}

// MARK: - Bodies the cloud answers (open: unknown members ignored)

/// One leased task of a pull (§5).
public struct CloudTaskPulled: Equatable, Sendable {
    public struct Lease: Equatable, Sendable {
        public var leaseID: String
        public var attempt: Int64
        public var expiresAtMs: Int64
    }

    public var taskID: String
    public var requestID: String
    public var keyID: String
    public var target: CloudTaskTarget
    public var expiresAtMs: Int64
    public var createdAtMs: Int64
    public var sealed: CloudTaskSealed
    public var lease: Lease

    public init(taskID: String, requestID: String, keyID: String, target: CloudTaskTarget, expiresAtMs: Int64,
                createdAtMs: Int64, sealed: CloudTaskSealed, lease: Lease) {
        self.taskID = taskID
        self.requestID = requestID
        self.keyID = keyID
        self.target = target
        self.expiresAtMs = expiresAtMs
        self.createdAtMs = createdAtMs
        self.sealed = sealed
        self.lease = lease
    }

    init(json: Any?) throws {
        let object = try CloudTaskJSON.open(json, "task")
        let lease = try CloudTaskJSON.open(object["lease"], "lease")
        guard let expires = CloudTaskJSON.integer(object["expires_at_ms"]),
              let created = CloudTaskJSON.integer(object["created_at_ms"]),
              let attempt = CloudTaskJSON.integer(lease["attempt"], low: 1),
              let leaseExpires = CloudTaskJSON.integer(lease["expires_at_ms"]) else {
            throw CloudTaskWireError("task integers")
        }
        self.init(taskID: try CloudTaskJSON.id(object["task_id"], "task_id"),
                  requestID: try CloudTaskJSON.id(object["request_id"], "request_id"),
                  keyID: try CloudTaskJSON.id(object["key_id"], "key_id"),
                  target: try CloudTaskTarget(json: object["target"], closed: false),
                  expiresAtMs: expires, createdAtMs: created,
                  sealed: try CloudTaskSealed(json: object["sealed"], closed: false),
                  lease: Lease(leaseID: try CloudTaskJSON.id(lease["lease_id"], "lease_id"),
                               attempt: attempt, expiresAtMs: leaseExpires))
    }
}

/// `phone-task-pull/v1`.
public struct CloudTaskPullResponse: Equatable, Sendable {
    public static let schema = "phone-task-pull/v1"

    /// One element of `tasks` (§5).
    public enum Element: Equatable, Sendable {
        case task(CloudTaskPulled)
        /// Not decodable, but its `task_id` is a valid id: acknowledged `rejected` / `invalid`.
        case undecodable(taskID: String)
        /// Not decodable and without a usable `task_id`: skipped, no ack.
        case skipped
    }

    /// The elements in the order the cloud sent them.
    public var elements: [Element]
    /// The cloud's clock, the authority for task expiry; `nil` when the answer did not carry a usable one.
    public var serverTimeMs: Int64?

    public init(elements: [Element], serverTimeMs: Int64?) {
        self.elements = elements
        self.serverTimeMs = serverTimeMs
    }

    public var tasks: [CloudTaskPulled] {
        elements.compactMap { if case .task(let task) = $0 { return task } else { return nil } }
    }

    /// §5: one element that cannot be decoded never fails the pull.
    public static func decodeElement(_ json: Any?) -> Element {
        if let task = try? CloudTaskPulled(json: json) { return .task(task) }
        let taskID = (json as? [String: Any])?["task_id"]
        if CloudTaskJSON.isID(taskID), let taskID = taskID as? String { return .undecodable(taskID: taskID) }
        return .skipped
    }

    public static func decode(_ data: Data) throws -> CloudTaskPullResponse {
        let object = try CloudTaskJSON.open(try CloudTaskJSON.parse(data), "pull")
        guard object["schema"] as? String == schema else { throw CloudTaskWireError("unknown schema") }
        guard let tasks = object["tasks"] as? [Any] else { throw CloudTaskWireError("pull") }
        return CloudTaskPullResponse(elements: tasks.map(decodeElement),
                                     serverTimeMs: CloudTaskJSON.integer(object["server_time_ms"]))
    }
}

/// One entry of `phone-task-ack-result/v1`, in request order.
public struct CloudTaskAckResult: Equatable, Sendable {
    public var taskID: String
    public var accepted: Bool
    public var duplicate: Bool
    /// The task's state after the call: a §6 state or `not_found`.
    public var state: String

    public init(taskID: String, accepted: Bool, duplicate: Bool, state: String) {
        self.taskID = taskID
        self.accepted = accepted
        self.duplicate = duplicate
        self.state = state
    }
}

/// `phone-task-ack-result/v1`.
public struct CloudTaskAckResponse: Equatable, Sendable {
    public static let schema = "phone-task-ack-result/v1"
    public var results: [CloudTaskAckResult]
    public var serverTimeMs: Int64

    public static func decode(_ data: Data) throws -> CloudTaskAckResponse {
        let object = try CloudTaskJSON.open(try CloudTaskJSON.parse(data), "ack result")
        guard object["schema"] as? String == schema else { throw CloudTaskWireError("unknown schema") }
        guard let raw = object["results"] as? [Any],
              let time = CloudTaskJSON.integer(object["server_time_ms"]) else { throw CloudTaskWireError("ack result") }
        let results = try raw.map { item -> CloudTaskAckResult in
            let entry = try CloudTaskJSON.open(item, "result")
            guard let accepted = CloudTaskJSON.bool(entry["accepted"]),
                  let duplicate = CloudTaskJSON.bool(entry["duplicate"]),
                  let state = entry["state"] as? String else {
                throw CloudTaskWireError("result")
            }
            return CloudTaskAckResult(taskID: try CloudTaskJSON.id(entry["task_id"], "task_id"),
                                      accepted: accepted, duplicate: duplicate, state: state)
        }
        return CloudTaskAckResponse(results: results, serverTimeMs: time)
    }
}

/// `phone-device-ack/v1`.
public struct CloudTaskDeviceAck: Equatable, Sendable {
    public static let schema = "phone-device-ack/v1"
    public var deviceID: String
    public var keyID: String
    public var serverTimeMs: Int64

    public static func decode(_ data: Data) throws -> CloudTaskDeviceAck {
        let object = try CloudTaskJSON.open(try CloudTaskJSON.parse(data), "device ack")
        guard object["schema"] as? String == schema, CloudTaskJSON.isDeviceID(object["device_id"]),
              let deviceID = object["device_id"] as? String,
              let time = CloudTaskJSON.integer(object["server_time_ms"]) else { throw CloudTaskWireError("device ack") }
        return CloudTaskDeviceAck(deviceID: deviceID, keyID: try CloudTaskJSON.id(object["key_id"], "key_id"),
                                  serverTimeMs: time)
    }
}

/// `{"error":{"code","message"},"server_time_ms"}` (§1). The phone acts on `code` and the status only.
public struct CloudTaskErrorBody: Equatable, Sendable {
    public var code: String
    public var message: String
    public var serverTimeMs: Int64

    /// `nil` when the body is not this contract's error object (for example another service's 404 page).
    public static func decode(_ data: Data) -> CloudTaskErrorBody? {
        guard let value = try? CloudTaskJSON.parse(data),
              let object = try? CloudTaskJSON.open(value, "error body"),
              let error = try? CloudTaskJSON.open(object["error"], "error"),
              let code = error["code"] as? String, let message = error["message"] as? String,
              let time = CloudTaskJSON.integer(object["server_time_ms"]) else { return nil }
        return CloudTaskErrorBody(code: code, message: message, serverTimeMs: time)
    }
}
