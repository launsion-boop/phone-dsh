// SPDX-License-Identifier: MIT
// phone-dsh SDK — PhoneDSH: tono-account wire rules.
//
// The pure half of spec/v1/tono-account.md: phone and code normalization,
// the four request encodings, token-response validation, outcome classes, the
// stored session record and the access-token clock. No I/O lives here, so the
// shared cases (`spec/v1/golden/tono-account/cases.json`) drive exactly these
// functions. Nothing in this file logs, and no value type prints a secret.

import Foundation

public enum TonoAccountProtocol {
    public static let accountOrigin = URL(string: "https://account.tonoai.cn")!
    public static let clientID = "phone-dsh-ios"
    public static let otpGrantType = "urn:tono:params:oauth:grant-type:phone-otp"
    public static let defaultAccessLifetimeSeconds = 7200
    public static let refreshSkewSeconds = 300
    public static let reverifyAfterSeconds: Int64 = 15_552_000
    public static let tokenMaxLength = 4096
    public static let recordVersion = 1

    // MARK: - Input normalization

    /// §2.1: `+86` and 11 ASCII digits starting with `1`, after removing ASCII
    /// spaces, `-` and line breaks. `nil` for anything else.
    public static func canonicalPhone(_ raw: String) -> String? {
        var compact = ""
        for scalar in raw.unicodeScalars {
            switch scalar {
            case " ", "-", "\n", "\r", "\t": continue
            default: compact.unicodeScalars.append(scalar)
            }
        }
        if compact.hasPrefix("+86") { compact.removeFirst(3) }
        guard compact.utf8.count == 11, compact.hasPrefix("1"),
              compact.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        return "+86" + compact
    }

    /// §2.2: 4–8 ASCII digits after trimming whitespace.
    public static func canonicalCode(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (4...8).contains(trimmed.utf8.count),
              trimmed.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        return trimmed
    }

    /// The last four digits of a phone number, or `nil`.
    static func phoneHint(_ phone: String?) -> String? {
        guard let phone, phone.utf8.count >= 4 else { return nil }
        let tail = String(phone.suffix(4))
        guard tail.utf8.count == 4, tail.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        return tail
    }

    // MARK: - Requests

    /// What the device says about itself at sign-in. No personal device name
    /// is sent: the app passes a model family, not the user's device label.
    public struct DeviceInfo: Equatable, Sendable {
        public var platform: String
        public var deviceName: String
        public var appVersion: String
        public var osVersion: String

        public init(platform: String, deviceName: String, appVersion: String, osVersion: String) {
            self.platform = platform
            self.deviceName = deviceName
            self.appVersion = appVersion
            self.osVersion = osVersion
        }

        /// This process: `ios` (or `macos` in host tests), a generic model
        /// name, the bundle's short version and the OS version.
        public static func current(bundle: Bundle = .main) -> DeviceInfo {
            let version = ProcessInfo.processInfo.operatingSystemVersion
            let os = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
            let app = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
            #if os(iOS)
            return DeviceInfo(platform: "ios", deviceName: "iPhone", appVersion: app, osVersion: os)
            #else
            return DeviceInfo(platform: "macos", deviceName: "Mac", appVersion: app, osVersion: os)
            #endif
        }

        var json: [String: String] {
            ["platform": platform, "device_name": deviceName,
             "app_version": appVersion, "os_version": osVersion]
        }
    }

    public static func sendCodeRequest(phone: String, origin: URL = accountOrigin) -> URLRequest {
        jsonRequest(origin: origin, path: "/v1/auth/otp/send",
                    body: ["phone": phone, "purpose": "login", "client_id": clientID])
    }

    public static func signInRequest(phone: String,
                                     challengeID: String,
                                     code: String,
                                     device: DeviceInfo,
                                     origin: URL = accountOrigin) -> URLRequest {
        jsonRequest(origin: origin, path: "/v1/oauth/token",
                    body: ["grant_type": otpGrantType, "client_id": clientID, "phone": phone,
                           "challenge_id": challengeID, "code": code, "device_info": device.json])
    }

    public static func refreshRequest(refreshToken: String, origin: URL = accountOrigin) -> URLRequest {
        var request = URLRequest(url: endpoint(origin, "/v1/oauth/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(formEncode([("grant_type", "refresh_token"),
                                            ("client_id", clientID),
                                            ("refresh_token", refreshToken)]).utf8)
        return request
    }

    public static func signOutRequest(accessToken: String, origin: URL = accountOrigin) -> URLRequest {
        var request = URLRequest(url: endpoint(origin, "/v1/auth/logout"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data()
        return request
    }

    /// §2.3 form encoding: unreserved bytes kept, every other UTF-8 byte `%XX`.
    public static func formEncode(_ pairs: [(String, String)]) -> String {
        pairs.map { "\(percentEncode($0.0))=\(percentEncode($0.1))" }.joined(separator: "&")
    }

    static func percentEncode(_ value: String) -> String {
        var out = ""
        for byte in value.utf8 {
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x2E, 0x5F, 0x7E:
                out.unicodeScalars.append(Unicode.Scalar(byte))
            default:
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    private static func endpoint(_ origin: URL, _ path: String) -> URL {
        var text = origin.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        return URL(string: text + path)!
    }

    private static func jsonRequest(origin: URL, path: String, body: [String: Any]) -> URLRequest {
        var request = URLRequest(url: endpoint(origin, path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body,
                                                       options: [.sortedKeys, .withoutEscapingSlashes])
        return request
    }

    // MARK: - Responses

    /// A validated token response. `description` never prints a token.
    public struct TokenGrant: Equatable, Sendable, CustomStringConvertible {
        public var accessToken: String
        public var refreshToken: String
        public var expiresIn: Int
        public var userID: String?
        public var phoneHint: String?

        public var description: String {
            "TokenGrant(expiresIn: \(expiresIn), phoneHint: \(phoneHint ?? "nil"))"
        }
    }

    /// §2 token-response rules; `nil` when the body is not a valid grant.
    public static func parseTokenResponse(_ body: Data) -> TokenGrant? {
        guard case .object(let object)? = TonoJSONValue.parse(body),
              case .string(let access)? = object["access_token"], isValidToken(access),
              !access.hasPrefix("pdsk_"),
              case .string(let refresh)? = object["refresh_token"], isValidToken(refresh) else {
            return nil
        }
        var expiresIn = defaultAccessLifetimeSeconds
        if let raw = object["expires_in"] {
            guard case .integer(let value) = raw, value >= 1, value <= Int64(Int32.max) else { return nil }
            expiresIn = Int(value)
        }
        if let raw = object["token_type"] {
            guard case .string(let type) = raw, type.lowercased() == "bearer" else { return nil }
        }
        var userID: String?
        var phone: String?
        if case .object(let user)? = object["user"] {
            if case .string(let id)? = user["id"] { userID = id }
            if case .string(let value)? = user["phone"] { phone = value }
        }
        return TokenGrant(accessToken: access, refreshToken: refresh, expiresIn: expiresIn,
                          userID: userID, phoneHint: phoneHint(phone))
    }

    /// 1–4096 visible ASCII characters, no space or control.
    public static func isValidToken(_ value: String) -> Bool {
        let bytes = value.utf8
        return !bytes.isEmpty && bytes.count <= tokenMaxLength && bytes.allSatisfy { $0 >= 0x21 && $0 <= 0x7E }
    }

    public enum OTPOutcome: Equatable, Sendable {
        case challenge(String)
        case protocolError
        case rejected
        case rateLimited(retryAfterSeconds: Int?)
        case transient
    }

    public enum LoginOutcome: Equatable, Sendable {
        case signedIn(TokenGrant)
        case protocolError
        case invalidCode
        case rejected
        case rateLimited(retryAfterSeconds: Int?)
        case transient
    }

    public enum RefreshOutcome: Equatable, Sendable {
        case rotated(TokenGrant)
        case sessionEnded
        case transient
    }

    /// One answer from the account service; `nil` for a transport error.
    public struct Answer: Sendable {
        public var status: Int
        public var headers: [String: String]
        public var body: Data

        public init(status: Int, headers: [String: String], body: Data) {
            self.status = status
            self.headers = headers
            self.body = body
        }
    }

    public static func classifySendCode(_ answer: Answer?) -> OTPOutcome {
        guard let answer else { return .transient }
        switch answer.status {
        case 200...299:
            guard case .object(let object)? = TonoJSONValue.parse(answer.body),
                  case .string(let id)? = object["challenge_id"], !id.isEmpty else { return .protocolError }
            return .challenge(id)
        case 400, 401, 403: return .rejected
        case 429: return .rateLimited(retryAfterSeconds: retryAfterSeconds(answer.headers))
        default: return .transient
        }
    }

    public static func classifySignIn(_ answer: Answer?) -> LoginOutcome {
        guard let answer else { return .transient }
        switch answer.status {
        case 200...299:
            guard let grant = parseTokenResponse(answer.body) else { return .protocolError }
            return .signedIn(grant)
        case 400, 401: return .invalidCode
        case 403: return .rejected
        case 429: return .rateLimited(retryAfterSeconds: retryAfterSeconds(answer.headers))
        default: return .transient
        }
    }

    public static func classifyRefresh(_ answer: Answer?) -> RefreshOutcome {
        guard let answer else { return .transient }
        switch answer.status {
        case 200...299:
            guard let grant = parseTokenResponse(answer.body) else { return .sessionEnded }
            return .rotated(grant)
        case 400, 401, 403: return .sessionEnded
        default: return .transient
        }
    }

    /// `Retry-After` as whole seconds for a 429, or `nil`.
    static func retryAfterSeconds(_ headers: [String: String]) -> Int? {
        guard let raw = headers.first(where: { $0.key.lowercased() == "retry-after" })?.value else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 9,
              trimmed.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        return Int(trimmed)
    }

    // MARK: - Stored record (P18)

    /// §3 session record. `description` never prints the refresh token.
    public struct SessionRecord: Equatable, Sendable, CustomStringConvertible {
        public var refreshToken: String
        public var loginAtMs: Int64
        public var userID: String?
        public var phoneHint: String?

        public init(refreshToken: String, loginAtMs: Int64, userID: String?, phoneHint: String?) {
            self.refreshToken = refreshToken
            self.loginAtMs = loginAtMs
            self.userID = userID
            self.phoneHint = phoneHint
        }

        public var description: String {
            "SessionRecord(loginAtMs: \(loginAtMs), phoneHint: \(phoneHint ?? "nil"))"
        }
    }

    public static func decodeRecord(_ data: Data) -> SessionRecord? {
        guard case .object(let object)? = TonoJSONValue.parse(data),
              case .integer(let version)? = object["version"], version == Int64(recordVersion),
              case .string(let refresh)? = object["refresh_token"], isValidToken(refresh),
              case .integer(let loginAt)? = object["login_at_ms"], loginAt >= 0 else { return nil }
        var userID: String?
        var hint: String?
        if case .string(let value)? = object["user_id"] { userID = value }
        if case .string(let value)? = object["phone_hint"] { hint = value }
        return SessionRecord(refreshToken: refresh, loginAtMs: loginAt, userID: userID, phoneHint: hint)
    }

    public static func encodeRecord(_ record: SessionRecord) -> Data {
        let object: [String: Any] = [
            "version": recordVersion,
            "refresh_token": record.refreshToken,
            "login_at_ms": record.loginAtMs,
            "user_id": record.userID as Any? ?? NSNull(),
            "phone_hint": record.phoneHint as Any? ?? NSNull(),
        ]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    // MARK: - Clock

    public enum ClockDecision: Equatable, Sendable {
        case use
        case refresh
        case reverifyRequired
    }

    /// §3 clock rule.
    public static func clockDecision(issuedAtMs: Int64,
                                     expiresIn: Int,
                                     loginAtMs: Int64,
                                     nowMs: Int64) -> ClockDecision {
        if nowMs - loginAtMs >= reverifyAfterSeconds * 1000 { return .reverifyRequired }
        if nowMs < issuedAtMs { return .refresh }
        let lifetimeMs = Int64(expiresIn) * 1000
        let skewMs = min(Int64(refreshSkewSeconds) * 1000, lifetimeMs / 2)
        return nowMs < issuedAtMs + lifetimeMs - skewMs ? .use : .refresh
    }
}

/// A JSON value that keeps integers, fractions, booleans and strings apart, so
/// `7200`, `7200.5`, `"7200"` and `true` are four different answers.
enum TonoJSONValue: Decodable, Equatable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([TonoJSONValue])
    case object([String: TonoJSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Int64.self) { self = .integer(value); return }
        if let value = try? container.decode(Double.self) { self = .number(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode([TonoJSONValue].self) { self = .array(value); return }
        self = .object(try container.decode([String: TonoJSONValue].self))
    }

    static func parse(_ data: Data) -> TonoJSONValue? {
        try? JSONDecoder().decode(TonoJSONValue.self, from: data)
    }
}
