// SPDX-License-Identifier: MIT
// phone-dsh — PhoneDSHBLE/Xiaozhi: the device report (spec/device/v1/xiaozhi-firmware.md §3)
// and the OTA response rewrite (§2.4). Pure functions; the shared vectors are
// spec/device/v1/golden/xiaozhi-ota.jsonl.
#if DEBUG
import Foundation

/// What one xiaozhi version check tells the relay about the board. Every
/// value is self-reported by the device and is not an identity.
public struct XiaozhiDeviceReport: Equatable, Sendable {
    public var mac: String?
    public var version: String?
    public var elfSha256: String?
    public var boardType: String?

    public init(mac: String?, version: String?, elfSha256: String?, boardType: String?) {
        self.mac = mac; self.version = version; self.elfSha256 = elfSha256; self.boardType = boardType
    }

    public enum Parsed: Equatable, Sendable {
        case report(XiaozhiDeviceReport)
        /// The request has a body and it is not a JSON object (relay answers 400).
        case invalidBody
    }

    /// `headers` names are matched case-insensitively. A nil or empty `body` is a report with no body fields.
    public static func parse(headers: [String: String], body: Data?) -> Parsed {
        let mac = headerValue("device-id", in: headers).flatMap(normalizedMAC)
        var version: String?
        var elf: String?
        var board: String?
        if let body, !body.isEmpty {
            guard case .object(let members)? = XiaozhiJSON.parse(body) else { return .invalidBody }
            if case .object(let application)? = member("application", in: members) {
                if case .string(let text)? = member("version", in: application) { version = text }
                if case .string(let text)? = member("elf_sha256", in: application), isLowerHex64(text) { elf = text }
            }
            if case .object(let boardMembers)? = member("board", in: members),
               case .string(let text)? = member("type", in: boardMembers) { board = text }
        }
        return .report(XiaozhiDeviceReport(mac: mac, version: version, elfSha256: elf, boardType: board))
    }

    /// `aa:bb:cc:dd:ee:ff` after lowercasing, else nil.
    public static func normalizedMAC(_ raw: String) -> String? {
        let lower = raw.lowercased()
        let parts = lower.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6, parts.allSatisfy({ $0.utf8.count == 2 && $0.utf8.allSatisfy(isLowerHexByte) }) else { return nil }
        return lower
    }

    static func isLowerHex64(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy(isLowerHexByte)
    }

    private static func isLowerHexByte(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x61...0x66).contains(byte)
    }

    private static func headerValue(_ name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.lowercased() == name }?.value
    }

    private static func member(_ key: String, in members: [XiaozhiJSON.Member]) -> XiaozhiJSON? {
        members.first { $0.key == key }?.value
    }
}

public enum XiaozhiOTADecision: String, Equatable, Sendable {
    case passthrough
    case hold
    case offer
}

public enum XiaozhiOTARewrite {
    public typealias Staged = (mac: String, sha256: String, elfSha256: String)

    /// §2.4, first matching rule wins. `base` is `http://<Wi-Fi IPv4>:8781`.
    public static func apply(status: Int, body: Data, report: XiaozhiDeviceReport, staged: Staged?,
                             base: String) -> (decision: XiaozhiOTADecision, body: Data) {
        let unchanged = (decision: XiaozhiOTADecision.passthrough, body: body)
        // 1
        guard let staged, let mac = report.mac, staged.mac == mac else { return unchanged }
        // 2
        guard status == 200, case .object(var members)? = XiaozhiJSON.parse(body) else { return unchanged }
        // 3
        guard let version = report.version, isDottedVersion(version) else { return unchanged }

        let firmware: XiaozhiJSON
        let decision: XiaozhiOTADecision
        if let elf = report.elfSha256, elf == staged.elfSha256 {   // 4
            decision = .hold
            firmware = .object([.init(key: "version", value: .string(version)), .init(key: "url", value: .string(""))])
        } else {                                                    // 5
            decision = .offer
            firmware = .object([.init(key: "version", value: .string(version + ".1")),
                                .init(key: "url", value: .string("\(base)/xiaozhi/firmware/\(staged.sha256).bin"))])
        }
        if let existing = members.firstIndex(where: { $0.key == "firmware" }) {
            members[existing].value = firmware
        } else {
            members.append(.init(key: "firmware", value: firmware))
        }
        return (decision, XiaozhiJSON.object(members).serialized())
    }

    /// Dot-separated non-negative integers (ASCII digits).
    static func isDottedVersion(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.allSatisfy { !$0.isEmpty && $0.utf8.allSatisfy { (0x30...0x39).contains($0) } }
    }
}
#endif
