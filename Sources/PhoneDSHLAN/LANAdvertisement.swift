// SPDX-License-Identifier: MIT
import Foundation

/// Untrusted DNS-SD discovery data. Validation does not authenticate the device.
public struct LANDeviceCandidate: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let url: URL

    public init?(service: String, host: String, port: Int, txt: Data) {
        guard (1...63).contains(service.utf8.count), (1...65535).contains(port),
              Self.validProfile(txt), let hostname = Self.hostname(host) else { return nil }
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = hostname
        if port != 443 { parts.port = port }
        parts.path = "/mcp"
        guard let url = parts.url else { return nil }
        self.id = "\(service)@\(hostname):\(port)"
        self.name = service
        self.url = url
    }

    private static func hostname(_ value: String) -> String? {
        guard value.utf8.count <= 254, value.utf8.allSatisfy({ $0 < 128 }) else { return nil }
        let host = (value.hasSuffix(".") ? String(value.dropLast()) : value).lowercased()
        guard !host.isEmpty, host.utf8.count <= 253 else { return nil }
        for label in host.split(separator: ".", omittingEmptySubsequences: false) {
            let bytes = Array(label.utf8)
            guard (1...63).contains(bytes.count), let first = bytes.first, let last = bytes.last,
                  isAlphaNumeric(first), isAlphaNumeric(last),
                  bytes.allSatisfy({ isAlphaNumeric($0) || $0 == 45 }) else { return nil }
        }
        // Numeric final labels can be interpreted as IPv4 by URL consumers,
        // or cause the Worker's URL parser to reject an otherwise valid name.
        guard let finalLabel = host.split(separator: ".").last else { return nil }
        let bytes = finalLabel.utf8
        let decimal = bytes.allSatisfy { (48...57).contains($0) }
        let hexadecimal = finalLabel.hasPrefix("0x") && bytes.dropFirst(2).allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
        guard !decimal, !hexadecimal else { return nil }
        return host
    }

    private static func isAlphaNumeric(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (97...122).contains(byte)
    }

    private static func validProfile(_ txt: Data) -> Bool {
        let bytes = Array(txt)
        var index = 0
        var seen = false
        var valid = false
        while index < bytes.count {
            let length = Int(bytes[index]); index += 1
            guard index + length <= bytes.count else { return false }
            let entry = bytes[index..<(index + length)]; index += length
            let separator = entry.firstIndex(of: 61)
            let keyBytes = entry[..<(separator ?? entry.endIndex)]
            guard let key = String(bytes: keyBytes, encoding: .utf8) else { continue }
            if key.lowercased() == "profile" {
                guard !seen, let separator else { return false }
                seen = true
                let value = entry[entry.index(after: separator)...]
                valid = String(bytes: value, encoding: .utf8) == "pdsh-mcp-1"
            }
        }
        return seen && valid
    }
}
