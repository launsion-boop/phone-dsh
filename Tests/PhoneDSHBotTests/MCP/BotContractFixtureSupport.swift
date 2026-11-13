// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

/// Loader and matcher for the D13 contract fixtures. Tests must read the
/// shared files from `spec/bot/v1/golden/`; they never copy a case into code.
enum BotContractFixture {
    struct FixtureError: Error, CustomStringConvertible {
        let description: String
    }

    static func object(_ name: String) throws -> [String: Any] {
        try BotGoldenFixture.mergedObject(name)
    }

    static func array(_ value: Any?, _ at: String) throws -> [[String: Any]] {
        guard let raw = value as? [Any] else {
            throw FixtureError(description: "\(at) must be an array")
        }
        return try raw.enumerated().map { index, item in
            guard let object = item as? [String: Any] else {
                throw FixtureError(description: "\(at)[\(index)] must be an object")
            }
            return object
        }
    }

    static func object(_ value: Any?, _ at: String) throws -> [String: Any] {
        guard let object = value as? [String: Any] else {
            throw FixtureError(description: "\(at) must be an object")
        }
        return object
    }

    static func string(_ value: Any?, _ at: String) throws -> String {
        guard let text = value as? String else {
            throw FixtureError(description: "\(at) must be a string")
        }
        return text
    }

    static func optionalString(_ value: Any?) -> String? { value as? String }

    static func int(_ value: Any?, _ at: String) throws -> Int {
        guard let number = value as? NSNumber else {
            throw FixtureError(description: "\(at) must be a number")
        }
        return number.intValue
    }

    static func bool(_ value: Any?, _ at: String) throws -> Bool {
        guard let flag = value as? Bool else {
            throw FixtureError(description: "\(at) must be a boolean")
        }
        return flag
    }

    static func json(_ value: Any) throws -> BotJSONValue {
        if JSONSerialization.isValidJSONObject(value) {
            let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            return try BotJSONValue.parse(data)
        }
        // A scalar/null needs an array wrapper because JSONSerialization only
        // accepts an object or array at the top level.
        let data = try JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys])
        guard case .array(let values) = try BotJSONValue.parse(data), let first = values.first else {
            throw FixtureError(description: "cannot encode scalar JSON")
        }
        return first
    }

    static func digest(_ arguments: BotJSONValue) throws -> String {
        try BotArgumentsDigest.string(for: arguments)
    }

    /// Recursive subset match: expected object keys must all match, expected
    /// arrays must have the same length and match element-wise, scalars are
    /// equal. This keeps fixtures about the frozen fields while the tests stay
    /// in charge of their own setup.
    static func subset(_ actual: BotJSONValue, _ expected: BotJSONValue,
                       path: String = "$") -> String? {
        switch (actual, expected) {
        case let (.object(lhs), .object(rhs)):
            for (key, value) in rhs {
                guard let candidate = lhs[key] else { return "\(path).\(key) missing" }
                if let failure = subset(candidate, value, path: "\(path).\(key)") { return failure }
            }
            return nil
        case let (.array(lhs), .array(rhs)):
            guard lhs.count == rhs.count else {
                return "\(path) count \(lhs.count) != expected \(rhs.count)"
            }
            for (index, value) in rhs.enumerated() {
                if let failure = subset(lhs[index], value, path: "\(path)[\(index)]") { return failure }
            }
            return nil
        case let (.number(lhs), .number(rhs)):
            return lhs == rhs ? nil : "\(path) \(lhs) != expected \(rhs)"
        case let (.string(lhs), .string(rhs)):
            return lhs == rhs ? nil : "\(path) \(lhs.debugDescription) != expected \(rhs.debugDescription)"
        case let (.bool(lhs), .bool(rhs)):
            return lhs == rhs ? nil : "\(path) \(lhs) != expected \(rhs)"
        case (.null, .null):
            return nil
        default:
            return "\(path) type/value mismatch: \(actual) != expected \(expected)"
        }
    }

    static func assertSubset(_ actual: BotJSONValue, _ expected: BotJSONValue,
                             _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        if let failure = subset(actual, expected) {
            XCTFail("\(label): \(failure)", file: file, line: line)
        }
    }

    static func assertError(_ value: BotJSONValue, _ expected: BotJSONValue,
                            _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        guard case .object(let fields) = value, let error = fields["error"] else {
            XCTFail("\(label): missing JSON-RPC error: \(value)", file: file, line: line)
            return
        }
        assertSubset(error, expected, "\(label).error", file: file, line: line)
    }
}

/// Native forwarder used by the RPC fixture. It answers the three methods the
/// fixture exercises and returns nil for everything else, mirroring a native
/// server that does not own a name.
final class ContractNativeForwarder: BotNativeMCPForwarding, @unchecked Sendable {
    private let lock = NSLock()
    private var seenHeaders: [[String: String]] = []

    var headersSeen: [[String: String]] { lock.withLock { seenHeaders } }

    func handle(_ request: BotJSONValue, headers: [String: String]) async -> BotJSONValue? {
        lock.withLock { seenHeaders.append(headers) }
        guard case .object(let object) = request,
              case .string(let method)? = object["method"] else { return nil }
        switch method {
        case "initialize":
            let raw = try? BotContractFixture.object("mcp-rpc-cases.phone")
            let instructions = ((raw?["native"] as? [String: Any])?["instructions"] as? String) ?? ""
            return .object([
                "jsonrpc": .string("2.0"), "id": object["id"] ?? .null,
                "result": .object([
                    "protocolVersion": .string("2025-11-25"),
                    "capabilities": .object([:]),
                    "serverInfo": .object(["name": .string("native"), "version": .string("1")]),
                    "instructions": .string(instructions),
                ]),
            ])
        case "tools/list":
            let raw = try? BotContractFixture.object("mcp-rpc-cases.phone")
            let native = (raw?["native"] as? [String: Any])?["tools"] as? [Any] ?? []
            return .object([
                "jsonrpc": .string("2.0"), "id": object["id"] ?? .null,
                "result": .object(["tools": (try? BotContractFixture.json(native)) ?? .array([])]),
            ])
        case "tools/call":
            guard case .string(let name)? = object["params"]?["name"] else { return nil }
            guard name == "native_echo" else { return nil }
            let text = object["params"]?["arguments"]?["text"] ?? .null
            return .object([
                "jsonrpc": .string("2.0"), "id": object["id"] ?? .null,
                "result": .object([
                    "nativeEcho": .object(["text": text]),
                    "nativeSawIdempotencyKey": .string(headers["x-pdsh-idempotency-key"] ?? ""),
                ]),
            ])
        case "native/ping":
            return .object([
                "jsonrpc": .string("2.0"), "id": object["id"] ?? .null,
                "result": .object(["native": .bool(true)]),
            ])
        default:
            return nil
        }
    }
}
