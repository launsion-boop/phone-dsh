// SPDX-License-Identifier: MIT
// phone-dsh — PhoneDSHBLE: wire pieces for updating a TonoLink board's
// firmware over the iPhone's wired USB NCM link (no Wi-Fi, no computer).
//
// Firmware contract (tonolink `agent/venus-demo`):
// - BLE ctrl `cmd` (write, encrypted): `<seq> usb_net <32 hex>` enables NCM and
//   sets the per-session token; the `status` notify answers `ack <seq> ok`.
// - TCP 192.168.247.1:8768: frames are `u16be len (kind + payload) | u8 kind |
//   payload`. Kind 0 + the 32-character token authenticates; the board answers
//   kind 0 `ok`. Kind 3 is ping, 4 pong. The board drops a socket that is idle
//   for 5 s, and only an authenticated live socket makes the token valid.
// - HTTP :8767 `POST /ota` (`X-CRC32`, `X-USB-Token`), then, after the reboot
//   and within 120 s, `POST /ota/confirm` (`X-USB-Token`, `X-ELF-SHA256`) from a
//   new USB session, or the image rolls back. Since venus-demo a0a95ef the USB
//   session alone authorizes `/ota`, `/ota/confirm` and `POST /v1/wifi`; older
//   firmware also needs the LAN bearer token, which is therefore optional here.
import Foundation

public enum TonoLinkUSB {
    public static let host = "192.168.247.1"
    public static let socketPort: UInt16 = 8768
    public static let httpPort = 8767
    public static var baseURL: URL {
        var components = URLComponents()
        components.scheme = "http"; components.host = host; components.port = httpPort
        return components.url!
    }
    /// The board closes an idle :8768 socket after 5 s (`SO_RCVTIMEO`).
    public static let keepAliveInterval: Duration = .seconds(1)
    /// `VERIFY_TIMEOUT_S` in `pa_ota_verify.c`.
    public static let confirmWindow: Duration = .seconds(120)
}

/// BLE control service characteristics shared by the S3 and SiFli firmware.
public enum TonoLinkCtrlService {
    public static let service = "5DBD66EC-9E78-42D4-854F-DE5EBBFFA363"
    public static let cmd = "2D0EA61C-DCAC-48A2-816C-8DFF5022E6DE"
    public static let status = "4DF6DE7E-42FA-4F5E-92DE-BAD8AC1DE887"
    /// Board microphone frames (notify), used only when a caller sets `onAudio`.
    public static let audio = "7A1C9E52-3B6D-4F08-9C2E-5D4B8A61F0A3"
}

public struct TonoLinkUSBOTAError: LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

// MARK: - Tokens

public enum TonoLinkTokens {
    /// A fresh per-session USB token: 16 random bytes as 32 lowercase hex characters.
    public static func makeUSBToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
    }

    public static func isUSBToken(_ token: String) -> Bool { isHex(token, count: 32) }

    /// Normalizes a pasted LAN bearer token (64 hex characters). Whitespace and a
    /// leading `Bearer ` are tolerated; anything else is rejected.
    public static func normalizedLANToken(_ text: String) -> String? {
        var token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.lowercased().hasPrefix("bearer ") { token = String(token.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
        return isHex(token, count: 64) ? token : nil
    }

    static func isHex(_ text: String, count: Int) -> Bool {
        text.utf8.count == count && text.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }
}

// MARK: - BLE ctrl lines

public struct TonoLinkCtrlAck: Equatable, Sendable {
    public let seq: UInt16
    /// nil for `ok`, otherwise the firmware's error name (`range`, `unsupported`, …).
    public let error: String?
    public var ok: Bool { error == nil }

    /// Parses one `status` notification. Status (`st …`) and other lines return nil.
    public static func parse(_ data: Data) -> TonoLinkCtrlAck? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 3, parts[0] == "ack", let seq = UInt16(parts[1]) else { return nil }
        if parts.count == 3, parts[2] == "ok" { return TonoLinkCtrlAck(seq: seq, error: nil) }
        if parts.count == 4, parts[2] == "err" { return TonoLinkCtrlAck(seq: seq, error: String(parts[3])) }
        return nil
    }
}

public enum TonoLinkCtrlCommand {
    /// `<seq> usb_net <token>`; `off` disables NCM.
    public static func usbNet(seq: UInt16, token: String) throws -> Data {
        guard token == "off" || TonoLinkTokens.isUSBToken(token) else { throw TonoLinkUSBOTAError("USB token must be 32 hex characters") }
        return Data("\(seq) usb_net \(token)".utf8)
    }
}

// MARK: - :8768 frames

public enum TonoLinkUSBFrame {
    public static let maxFrame = 1025   // kind + payload, `MAX_FRAME` in usb_network.c
    public static let auth: UInt8 = 0, ping: UInt8 = 3, pong: UInt8 = 4

    public static func encode(kind: UInt8, payload: Data = Data()) throws -> Data {
        let length = payload.count + 1
        guard length <= maxFrame else { throw TonoLinkUSBOTAError("USB frame too large") }
        return Data([UInt8(length >> 8), UInt8(length & 0xff), kind]) + payload
    }

    public static func authenticate(token: String) throws -> Data {
        guard TonoLinkTokens.isUSBToken(token) else { throw TonoLinkUSBOTAError("USB token must be 32 hex characters") }
        return try encode(kind: auth, payload: Data(token.utf8))
    }

    public static func isAuthAck(kind: UInt8, payload: Data) -> Bool { kind == auth && payload == Data("ok".utf8) }

    /// Reassembles frames from a TCP byte stream.
    public struct Decoder {
        private var buffer = Data()
        public init() {}
        public mutating func append(_ data: Data) throws -> [(kind: UInt8, payload: Data)] {
            buffer.append(data)
            var frames: [(kind: UInt8, payload: Data)] = []
            while buffer.count >= 2 {
                let start = buffer.startIndex
                let length = Int(buffer[start]) << 8 | Int(buffer[start + 1])
                guard length > 0, length <= maxFrame else { throw TonoLinkUSBOTAError("invalid USB frame length \(length)") }
                guard buffer.count >= 2 + length else { break }
                frames.append((buffer[start + 2], Data(buffer[(start + 3)..<(start + 2 + length)])))
                buffer = Data(buffer[(start + 2 + length)...])
            }
            return frames
        }
    }
}

// MARK: - Firmware image

public enum TonoLinkCRC32 {
    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }
    /// zlib CRC-32; equals the firmware's `esp_rom_crc32_le(0, …)`.
    public static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { bytes in
            for byte in bytes { crc = table[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8) }
        }
        return crc ^ 0xFFFF_FFFF
    }
    public static func header(_ crc: UInt32) -> String { String(format: "%08x", crc) }
}

/// An ESP32 app image (`agent_s3.bin`). The `esp_app_desc_t` sits right after
/// the 24-byte image header and the first 8-byte segment header.
public struct TonoLinkFirmwareImage: Equatable {
    public let data: Data
    public let version: String
    public let projectName: String
    public let buildDate: String
    /// `app_elf_sha256` as lowercase hex; `/ota/state` reports the running one.
    public let elfSHA256: String
    public let crc32: UInt32

    static let descOffset = 32
    static let descMagic: UInt32 = 0xABCD_5432

    public init(data: Data) throws {
        guard data.count > 4096, data.count <= 8 * 1024 * 1024 else { throw TonoLinkUSBOTAError("image size \(data.count) is not a plausible app image") }
        let bytes = [UInt8](data.prefix(256))
        guard bytes[0] == 0xE9 else { throw TonoLinkUSBOTAError("not an ESP app image (magic \(String(format: "%02x", bytes[0])))") }
        let d = Self.descOffset
        let magic = UInt32(bytes[d]) | UInt32(bytes[d + 1]) << 8 | UInt32(bytes[d + 2]) << 16 | UInt32(bytes[d + 3]) << 24
        guard magic == Self.descMagic else { throw TonoLinkUSBOTAError("ESP app description missing") }
        func text(_ offset: Int, _ length: Int) -> String {
            let field = bytes[(d + offset)..<(d + offset + length)]
            return String(decoding: field.prefix { $0 != 0 }, as: UTF8.self)
        }
        self.data = data
        version = text(16, 32)
        projectName = text(48, 32)
        buildDate = "\(text(96, 16)) \(text(80, 16))"
        elfSHA256 = bytes[(d + 144)..<(d + 176)].map { String(format: "%02x", $0) }.joined()
        crc32 = TonoLinkCRC32.checksum(data)
    }
}

// MARK: - HTTP

public struct TonoLinkOTAState: Codable, Equatable, Sendable {
    public let version: String
    public let slot: String
    public let boot: String
    public let elfSHA256: String
    /// `valid`, `pending` or `untracked`.
    public let state: String
    public let transport: String
    public let resetReason: Int
    public let needsUSBConfirmation: Bool

    enum CodingKeys: String, CodingKey {
        case version, slot, boot, state, transport
        case elfSHA256 = "elf_sha256"
        case resetReason = "reset_reason"
        case needsUSBConfirmation = "needs_usb_confirmation"
    }

    public init(version: String, slot: String, boot: String, elfSHA256: String, state: String,
                transport: String, resetReason: Int, needsUSBConfirmation: Bool) {
        self.version = version; self.slot = slot; self.boot = boot; self.elfSHA256 = elfSHA256; self.state = state
        self.transport = transport; self.resetReason = resetReason; self.needsUSBConfirmation = needsUSBConfirmation
    }

    public static func decode(_ data: Data) throws -> TonoLinkOTAState {
        do { return try JSONDecoder().decode(TonoLinkOTAState.self, from: data) }
        catch { throw TonoLinkUSBOTAError("unreadable /ota/state: \(String(decoding: data.prefix(200), as: UTF8.self))") }
    }

    public var isConfirmed: Bool { state == "valid" && !needsUSBConfirmation }
}

public enum TonoLinkOTARequest {
    public static func state(base: URL = TonoLinkUSB.baseURL) -> URLRequest {
        var request = URLRequest(url: base.appendingPathComponent("ota/state"), timeoutInterval: 5)
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        return request
    }

    public static func upload(image: TonoLinkFirmwareImage, lanToken: String?, usbToken: String,
                              base: URL = TonoLinkUSB.baseURL) -> URLRequest {
        var request = URLRequest(url: base.appendingPathComponent("ota"), timeoutInterval: 60)
        request.httpMethod = "POST"
        authorize(&request, lanToken: lanToken)
        request.setValue(TonoLinkCRC32.header(image.crc32), forHTTPHeaderField: "X-CRC32")
        request.setValue(usbToken, forHTTPHeaderField: "X-USB-Token")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        return request
    }

    public static func confirm(elfSHA256: String, lanToken: String?, usbToken: String,
                               base: URL = TonoLinkUSB.baseURL) -> URLRequest {
        var request = URLRequest(url: base.appendingPathComponent("ota/confirm"), timeoutInterval: 10)
        request.httpMethod = "POST"
        authorize(&request, lanToken: lanToken)
        request.setValue(usbToken, forHTTPHeaderField: "X-USB-Token")
        request.setValue(elfSHA256, forHTTPHeaderField: "X-ELF-SHA256")
        request.httpBody = Data()
        return request
    }

    public static func wifiState(base: URL = TonoLinkUSB.baseURL) -> URLRequest {
        var request = URLRequest(url: base.appendingPathComponent("v1/wifi"), timeoutInterval: 5)
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        return request
    }

    public static func setWiFi(_ credentials: TonoLinkWiFiCredentials, lanToken: String?, usbToken: String,
                               base: URL = TonoLinkUSB.baseURL) throws -> URLRequest {
        var request = URLRequest(url: base.appendingPathComponent("v1/wifi"), timeoutInterval: 15)
        request.httpMethod = "POST"
        authorize(&request, lanToken: lanToken)
        request.setValue(usbToken, forHTTPHeaderField: "X-USB-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(credentials)
        return request
    }

    /// The bearer header is only sent when a LAN token is known; on USB the
    /// session token alone authorizes the recovery routes on current firmware.
    private static func authorize(_ request: inout URLRequest, lanToken: String?) {
        if let lanToken { request.setValue("Bearer \(lanToken)", forHTTPHeaderField: "Authorization") }
    }
}

// MARK: - Wi-Fi

public struct TonoLinkWiFiState: Codable, Equatable, Sendable {
    public let ssid: String
    public let connected: Bool
    public let ip: String
    public let rssi: Int

    public init(ssid: String, connected: Bool, ip: String, rssi: Int) {
        self.ssid = ssid; self.connected = connected; self.ip = ip; self.rssi = rssi
    }

    public static func decode(_ data: Data) throws -> TonoLinkWiFiState {
        do { return try JSONDecoder().decode(TonoLinkWiFiState.self, from: data) }
        catch { throw TonoLinkUSBOTAError("unreadable /v1/wifi: \(String(decoding: data.prefix(200), as: UTF8.self))") }
    }
}

public struct TonoLinkWiFiCredentials: Codable, Equatable, Sendable {
    public let ssid: String
    public let password: String

    /// Firmware limits: SSID 1–32 bytes, password 0–64 bytes (`route_wifi.c`).
    public init(ssid: String, password: String) throws {
        guard (1...32).contains(ssid.utf8.count) else { throw TonoLinkUSBOTAError("Wi-Fi name must be 1–32 bytes") }
        guard password.utf8.count <= 64 else { throw TonoLinkUSBOTAError("Wi-Fi password must be at most 64 bytes") }
        self.ssid = ssid; self.password = password
    }
}
