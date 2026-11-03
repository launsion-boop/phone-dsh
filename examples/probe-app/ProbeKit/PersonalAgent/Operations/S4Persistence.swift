// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation

enum S4Persistence {
    static let maximumBytes = 16 * 1_024 * 1_024

    static func load<Value: Decodable>(_ type: Value.Type, from url: URL) throws -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard data.count <= maximumBytes else { throw S4PersistenceError.fileTooLarge }
        return try decoder.decode(type, from: data)
    }

    static func save<Value: Encodable>(_ value: Value, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try encoder.encode(value)
        guard data.count <= maximumBytes else { throw S4PersistenceError.fileTooLarge }
        try data.write(to: url, options: .atomic)
    }

    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func canonicalJSON(_ value: Any) throws -> String {
        guard JSONSerialization.isValidJSONObject(value) else { throw S4PersistenceError.invalidJSON }
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        guard let string = String(data: data, encoding: .utf8) else { throw S4PersistenceError.invalidJSON }
        return string
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

enum S4PersistenceError: Error, Equatable {
    case fileTooLarge
    case invalidJSON
}
