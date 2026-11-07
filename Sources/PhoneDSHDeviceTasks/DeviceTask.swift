// SPDX-License-Identifier: MIT
import Foundation

public enum DeviceTaskError: Error, Equatable, Sendable {
    case invalidTask
    case invalidDeviceIdentity
    case idempotencyConflict
    case storageFull
    case corruptJournal
    case unauthorized
    case deviceBusy
}

public struct DeviceTask: Codable, Equatable, Sendable {
    public struct Body: Codable, Equatable, Sendable {
        public let type: String
        public let text: String
    }
    public let id: String
    public let idempotencyKey: String
    public let requester: String
    public let createdAt: String
    public let deadline: String?
    public let body: Body

    enum CodingKeys: String, CodingKey {
        case id, requester, deadline, body
        case idempotencyKey = "idempotency_key"
        case createdAt = "created_at"
    }

    /// `decodeIfPresent` intentionally treats absent and null identically;
    /// the wire contract permits only the former for an omitted deadline.
    private struct DeadlinePresence: Decodable {
        let isNull: Bool
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            if values.contains(.deadline) {
                isNull = try values.decodeNil(forKey: .deadline)
            } else {
                isNull = false
            }
        }
    }

    public static func decode(_ data: Data) throws -> DeviceTask {
        var unique = UniqueJSONKeys(data)
        // Scan the original strings before Foundation dictionaries can merge
        // scalar-distinct, canonically equivalent keys and hide a NUL value.
        guard unique.check(rejectNUL: true) else { throw DeviceTaskError.invalidTask }
        guard let deadline = try? JSONDecoder().decode(DeadlinePresence.self, from: data), !deadline.isNull else {
            throw DeviceTaskError.invalidTask
        }
        let task: DeviceTask
        do { task = try JSONDecoder().decode(DeviceTask.self, from: data) }
        catch { throw DeviceTaskError.invalidTask }
        guard validID(task.id), validID(task.idempotencyKey),
              (1...128).contains(task.requester.utf8.count),
              task.requester.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              task.body.type == "goal", (1...768).contains(task.body.text.utf8.count),
              task.body.text.unicodeScalars.allSatisfy({ scalar in
                  !CharacterSet.controlCharacters.contains(scalar) || [9, 10, 13].contains(scalar.value)
              }), let created = parseTime(task.createdAt) else { throw DeviceTaskError.invalidTask }
        if let deadline = task.deadline {
            guard let end = parseTime(deadline), end > created else { throw DeviceTaskError.invalidTask }
        }
        return task
    }

    public var deadlineDate: Date? { deadline.flatMap(Self.parseTime) }

    static func validID(_ value: String) -> Bool {
        guard (1...64).contains(value.utf8.count), let first = value.utf8.first, isAlphaNumeric(first) else { return false }
        return value.utf8.allSatisfy { isAlphaNumeric($0) || [46, 95, 58, 45].contains($0) }
    }

    private static func isAlphaNumeric(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
    }

    private static func parseTime(_ value: String) -> Date? {
        guard (20...35).contains(value.utf8.count),
              value.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,3})?Z$"#, options: .regularExpression) != nil else { return nil }
        let bytes = Array(value.utf8)
        func number(_ start: Int, _ count: Int) -> Int {
            bytes[start..<(start + count)].reduce(0) { $0 * 10 + Int($1 - 48) }
        }
        let year = number(0, 4), month = number(5, 2), day = number(8, 2)
        let hour = number(11, 2), minute = number(14, 2), second = number(17, 2)
        guard year >= 1, (1...12).contains(month), hour <= 23, minute <= 59, second <= 59 else { return nil }
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1...days[month - 1]).contains(day) else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = value.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

public enum DeviceTaskFailureKind: String, Codable, Sendable {
    case denied, unavailable, expired, failed, unknownOutcome = "unknown_outcome"
}

public enum DeviceTaskOutcome: Codable, Equatable, Sendable {
    case completed(output: String, truncated: Bool)
    case failed(kind: DeviceTaskFailureKind, message: String)

    private enum CodingKeys: String, CodingKey { case kind, output, truncated, message; case failureKind = "failure_kind" }
    private enum Kind: String, Codable { case completed, failed }

    var isTransportSafe: Bool {
        switch self {
        case .completed(let output, _): return output.utf8.count <= 1024 && !output.unicodeScalars.contains { $0.value == 0 }
        case .failed(_, let message): return message.utf8.count <= 256 && !message.unicodeScalars.contains { $0.value == 0 }
        }
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .kind) {
        case .completed:
            self = .completed(output: try values.decode(String.self, forKey: .output),
                              truncated: try values.decode(Bool.self, forKey: .truncated))
        case .failed:
            self = .failed(kind: try values.decode(DeviceTaskFailureKind.self, forKey: .failureKind),
                           message: try values.decode(String.self, forKey: .message))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .completed(let output, let truncated):
            try values.encode(Kind.completed, forKey: .kind)
            try values.encode(output, forKey: .output)
            try values.encode(truncated, forKey: .truncated)
        case .failed(let kind, let message):
            try values.encode(Kind.failed, forKey: .kind)
            try values.encode(kind, forKey: .failureKind)
            try values.encode(message, forKey: .message)
        }
    }

    /// Limits output by UTF-8 bytes without splitting a Unicode scalar.
    public static func boundedOutput(_ text: String) -> Self {
        guard !text.unicodeScalars.contains(where: { $0.value == 0 }) else {
            return .failed(kind: .failed, message: "Model output contains an unsupported NUL character.")
        }
        var result = ""
        var bytes = 0
        for scalar in text.unicodeScalars {
            let value = String(scalar)
            let count = value.utf8.count
            if bytes + count > 1024 { return .completed(output: result, truncated: true) }
            result.unicodeScalars.append(scalar)
            bytes += count
        }
        return .completed(output: result, truncated: false)
    }
}
