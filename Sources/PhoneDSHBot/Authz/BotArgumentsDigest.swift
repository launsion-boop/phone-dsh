// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import PhoneDSHAgentCore

public enum BotArgumentsDigest {
    public static func string(for arguments: BotJSONValue = .object([:])) throws -> String {
        let data = try arguments.encoded()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func resourceSuffix(for arguments: BotJSONValue = .object([:])) throws -> String {
        "args=" + String(try string(for: arguments).prefix(16))
    }

    public static func digest(ofUTF8 text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    internal static func validated(_ value: String) throws -> String {
        let digest = value.lowercased()
        guard digest.count == 64, digest.allSatisfy({ $0.isHexDigit }) else {
            throw BotAttributionError.invalidInput("argsDigest")
        }
        return digest
    }
}
