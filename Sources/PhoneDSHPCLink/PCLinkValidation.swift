// SPDX-License-Identifier: MIT
// PhoneDSHPCLink: normative value validation (§2.1, §2.2, §3.1, §5.6, §6).

import Foundation

public enum PCLinkValidation {
    // MARK: - Names

    /// 1–64 UTF-8 bytes, NFC, no C0/C1/Cf character. Rejects a non-NFC value
    /// rather than silently normalizing it (§2.1).
    public static func name(_ value: String) throws {
        let bytes = value.utf8.count
        guard bytes >= 1, bytes <= 64 else {
            throw PCLinkError.badFrame("name must be 1-64 UTF-8 bytes (got \(bytes))")
        }
        // Swift `String` equality is canonical-equivalence based, so
        // comparing strings would accept a decomposed value. Compare the
        // exact UTF-8 bytes instead.
        guard Array(value.utf8) == Array(value.precomposedStringWithCanonicalMapping.utf8) else {
            throw PCLinkError.badFrame("name is not NFC")
        }
        for scalar in value.unicodeScalars {
            if scalar.value < 0x20 || (scalar.value >= 0x7F && scalar.value <= 0x9F) {
                throw PCLinkError.badFrame("name contains a C0/C1 control character")
            }
            if scalar.properties.generalCategory == .format {
                throw PCLinkError.badFrame("name contains a Unicode format character")
            }
        }
    }

    // MARK: - Display text / error messages

    /// PCLink-owned display text (`message` in relay/rpc/session errors and
    /// closes) keeps its byte cap and rejects a decoded U+0000. It is not a
    /// DSH passthrough value (§2.3).
    public static func displayText(_ value: String, field: String,
                                   minimumBytes: Int = 0, maximumBytes: Int) throws {
        let bytes = value.utf8.count
        guard bytes >= minimumBytes, bytes <= maximumBytes else {
            throw PCLinkError.badFrame("\(field) byte length")
        }
        if value.unicodeScalars.contains(where: { $0.value == 0 }) {
            throw PCLinkError.badFrame("\(field) contains U+0000")
        }
    }

    // MARK: - Machine ids / fingerprints

    public static func machineId(_ value: String) -> Bool {
        guard value.utf8.count == 26 else { return false }
        return value.utf8.allSatisfy { byte in
            (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x32 && byte <= 0x37)
        }
    }

    public static func requireMachineId(_ value: String, field: String = "machineId") throws {
        guard machineId(value) else { throw PCLinkError.badFrame("\(field) is not a machineId") }
    }

    public static func fingerprint(for machineId: String) throws -> String {
        guard PCLinkValidation.machineId(machineId) else { throw PCLinkError.badFrame("bad machineId") }
        let chars = Array(machineId.prefix(12))
        return "\(String(chars[0..<4]))-\(String(chars[4..<8]))-\(String(chars[8..<12]))"
    }

    /// Normalizes the operator-typed fingerprint: ignore `-`, whitespace and
    /// case. Returns the 12-character canonical lowercase value.
    public static func normalizeFingerprint(_ input: String) throws -> String {
        var result = ""
        for scalar in input.unicodeScalars {
            if scalar == "-" { continue }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { continue }
            let lower = String(scalar).lowercased()
            guard lower.unicodeScalars.count == 1,
                  let value = lower.unicodeScalars.first,
                  (value.value >= 0x61 && value.value <= 0x7A)
                    || (value.value >= 0x32 && value.value <= 0x37) else {
                throw PCLinkError.badFrame("invalid fingerprint character")
            }
            result.append(Character(String(value)))
        }
        guard result.utf8.count == 12 else {
            throw PCLinkError.badFrame("fingerprint must be 12 characters")
        }
        return result
    }

    public static func fingerprintMatches(input: String, machineId: String) -> Bool {
        guard let normalized = try? normalizeFingerprint(input),
              let expected = try? fingerprint(for: machineId) else { return false }
        return expected.replacingOccurrences(of: "-", with: "") == normalized
    }

    // MARK: - Origins

    /// Lowercase ASCII http(s) origin: no userinfo, path, query, fragment,
    /// uppercase character, default port, trailing slash or more than 128
    /// characters (§3.1).
    public static func origin(_ value: String) throws {
        guard value.utf8.count <= 128 else {
            throw PCLinkError.badFrame("origin exceeds 128 characters")
        }
        guard value.utf8.allSatisfy({ $0 < 0x80 }) else {
            throw PCLinkError.badFrame("origin must be ASCII")
        }
        guard value == value.lowercased() else {
            throw PCLinkError.badFrame("origin must be lowercase")
        }
        guard let components = URLComponents(string: value),
              let scheme = components.scheme,
              scheme == "https" || scheme == "http",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.path.isEmpty || components.path == "/" && !value.hasSuffix("/"),
              components.query == nil, components.fragment == nil else {
            throw PCLinkError.badFrame("origin is not a normalized ASCII origin")
        }
        guard value.hasPrefix("\(scheme)://") else {
            throw PCLinkError.badFrame("origin is not in scheme://host form")
        }
        let authority = String(value.dropFirst(scheme.count + 3))
        guard authority == host || authority.hasPrefix(host + ":") else {
            throw PCLinkError.badFrame("origin authority is malformed")
        }
        if authority.count > host.count {
            let portText = String(authority.dropFirst(host.count + 1))
            guard !portText.isEmpty,
                  portText.utf8.count <= 5,
                  portText.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
                  let port = Int(portText),
                  port >= 1, port <= 65_535 else {
                throw PCLinkError.badFrame("origin port is invalid")
            }
            if (scheme == "https" && port == 443) || (scheme == "http" && port == 80) {
                throw PCLinkError.badFrame("origin must omit the default port")
            }
        }
        // Reject anything the schema host pattern rejects.
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789.-")
        guard host.unicodeScalars.allSatisfy({ allowed.contains(Character($0)) }) else {
            throw PCLinkError.badFrame("origin host has an invalid character")
        }
        guard !host.hasPrefix("."), !host.hasSuffix("."), !host.contains("..") else {
            throw PCLinkError.badFrame("origin host is malformed")
        }
    }

    public static func websocketURL(for origin: String) throws -> URL {
        try self.origin(origin)
        let scheme = origin.hasPrefix("https://") ? "wss" : "ws"
        let rest = origin.dropFirst(origin.hasPrefix("https://") ? 8 : 7)
        guard let url = URL(string: "\(scheme)://\(rest)/") else {
            throw PCLinkError.badFrame("cannot derive the relay WebSocket URL")
        }
        return url
    }

    // MARK: - Protocol ids and endpoints

    public static func sessionId(_ value: String) -> Bool {
        guard value.utf8.count == 22 else { return false }
        return value.utf8.allSatisfy { byte in
            (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                || (byte >= 0x30 && byte <= 0x39) || byte == 0x2D || byte == 0x5F
        }
    }

    public static func correlationId(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...64).contains(bytes.count) else { return false }
        return bytes.allSatisfy { byte in
            (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                || (byte >= 0x30 && byte <= 0x39) || byte == 0x2E || byte == 0x5F
                || byte == 0x3A || byte == 0x2D
        }
    }

    /// `$?ns[/method]`, exact strings, no case folding (§6.1).
    public static func endpoint(_ value: String) -> Bool {
        let pattern = #"^\$?[A-Za-z][A-Za-z0-9.]*(/[A-Za-z][A-Za-z0-9.]*)?$"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }

    // MARK: - SemVer (§5.6)

    public struct SemVer: Comparable, Equatable, Sendable, CustomStringConvertible {
        public var major: Int
        public var minor: Int
        public var patch: Int
        public var prerelease: [String]

        public init(major: Int, minor: Int, patch: Int, prerelease: [String] = []) {
            self.major = major
            self.minor = minor
            self.patch = patch
            self.prerelease = prerelease
        }

        public static func parse(_ text: String) -> SemVer? {
            let pattern = #"^([0-9]+)\.([0-9]+)\.([0-9]+)(?:-([0-9A-Za-z.-]+))?$"#
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  match.range.location != NSNotFound else { return nil }
            func group(_ index: Int) -> String? {
                let range = match.range(at: index)
                guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return nil }
                return String(text[swiftRange])
            }
            guard let majorText = group(1), let minorText = group(2), let patchText = group(3),
                  let major = Int(majorText), let minor = Int(minorText), let patch = Int(patchText),
                  String(major) == majorText, String(minor) == minorText, String(patch) == patchText else {
                return nil
            }
            var prerelease: [String] = []
            if let text = group(4) {
                prerelease = text.components(separatedBy: ".")
                guard !prerelease.isEmpty else { return nil }
                for identifier in prerelease {
                    guard !identifier.isEmpty else { return nil }
                    if identifier.allSatisfy({ $0.isNumber }) {
                        // Numeric identifiers must not have leading zeroes.
                        guard identifier == "0" || !identifier.hasPrefix("0") else { return nil }
                    }
                }
            }
            return SemVer(major: major, minor: minor, patch: patch, prerelease: prerelease)
        }

        public var description: String {
            let base = "\(major).\(minor).\(patch)"
            return prerelease.isEmpty ? base : base + "-" + prerelease.joined(separator: ".")
        }

        public static func < (lhs: SemVer, rhs: SemVer) -> Bool {
            if lhs.major != rhs.major { return lhs.major < rhs.major }
            if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
            if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
            if lhs.prerelease.isEmpty { return false }
            if rhs.prerelease.isEmpty { return true }
            for (left, right) in zip(lhs.prerelease, rhs.prerelease) {
                if left == right { continue }
                let leftNumeric = left.allSatisfy(\.isNumber)
                let rightNumeric = right.allSatisfy(\.isNumber)
                if leftNumeric && rightNumeric {
                    return (Int(left) ?? 0) < (Int(right) ?? 0)
                }
                if leftNumeric { return true }
                if rightNumeric { return false }
                return left < right
            }
            return lhs.prerelease.count < rhs.prerelease.count
        }
    }

    public static let testedDSHRange = ">=0.2.2-rc.1 <0.3.0"
    public static let testedDSHMinimum = SemVer(major: 0, minor: 2, patch: 2, prerelease: ["rc", "1"])
    public static let testedDSHMaximumExclusive = SemVer(major: 0, minor: 3, patch: 0)

    public static func dshVersionInTestedRange(_ version: SemVer) -> Bool {
        version >= testedDSHMinimum && version < testedDSHMaximumExclusive
    }

    // MARK: - Timestamps

    /// RFC 3339 UTC with second precision and a trailing `Z`.
    public static func timestamp(_ value: String) -> Bool {
        let pattern = #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"#
        guard value.range(of: pattern, options: .regularExpression) != nil else { return false }
        let parts = value.dropLast().components(separatedBy: "T")
        guard parts.count == 2 else { return false }
        let date = parts[0].split(separator: "-").compactMap { Int($0) }
        let time = parts[1].split(separator: ":").compactMap { Int($0) }
        guard date.count == 3, time.count == 3 else { return false }
        let year = date[0], month = date[1], day = date[2]
        guard year >= 1, (1...12).contains(month), (1...31).contains(day),
              (0...23).contains(time[0]), (0...59).contains(time[1]), (0...59).contains(time[2]) else {
            return false
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let dateValue = calendar.date(from: DateComponents(year: year, month: month, day: day)) else {
            return false
        }
        let components = calendar.dateComponents([.year, .month, .day], from: dateValue)
        return components.year == year && components.month == month && components.day == day
    }

    public static func nowTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return formatter.string(from: Date())
    }
}
