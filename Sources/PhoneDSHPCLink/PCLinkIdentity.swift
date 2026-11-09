// SPDX-License-Identifier: MIT
// PhoneDSHPCLink: phone identity and Keychain persistence (§2.2).

import Foundation
import Security

public struct PCLinkIdentity: Equatable, Sendable {
    public let seed: Data
    public let publicKey: Data
    public let machineId: String

    public init(seed: Data) throws {
        guard seed.count == 32 else {
            throw PCLinkCryptoError.invalidKeyLength(expected: 32, actual: seed.count)
        }
        self.seed = seed
        self.publicKey = try PCLinkCrypto.ed25519PublicKey(seed: seed)
        self.machineId = PCLinkBase32.machineId(fromPublicKey: publicKey)
    }

    public static func generate() throws -> PCLinkIdentity {
        try PCLinkIdentity(seed: PCLinkRandom.bytes(32))
    }

    /// `machineId[0:12]` displayed as `xxxx-xxxx-xxxx`.
    public var fingerprint: String {
        (try? PCLinkValidation.fingerprint(for: machineId)) ?? machineId
    }

    public func sign(_ message: Data) throws -> Data {
        try PCLinkCrypto.ed25519Sign(seed: seed, message: message)
    }
}

public protocol PCLinkIdentityStore: Sendable {
    func loadSeed() throws -> Data?
    func saveSeed(_ seed: Data) throws
    func deleteSeed() throws
}

public struct PCLinkKeychainError: Error, Equatable, CustomStringConvertible, Sendable {
    public var operation: String
    public var status: OSStatus

    public init(operation: String, status: OSStatus) {
        self.operation = operation
        self.status = status
    }

    public var description: String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return "Keychain \(operation) failed: \(message) (OSStatus \(status))"
    }
    public var errorDescription: String? { description }

    /// The simulator/unsigned/sandboxed host has no accessible keychain item.
    public var isUnavailableInEnvironment: Bool {
        status == errSecMissingEntitlement || status == errSecNotAvailable
            || status == errSecIO || status == errSecInteractionNotAllowed
            || status == errSecAuthFailed
            // The DSH/CI sandbox reports its denial as 100001 (outside the
            // Security OSStatus range) instead of errSecMissingEntitlement.
            || status == 100001
    }
}

/// Phone identity seed in the Keychain: service `dsh-pclink`, account
/// `identity-v1`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, not
/// synchronizable. Ed25519 is not a Secure Enclave algorithm, so this is
/// software Keychain key material.
public struct PCLinkKeychainIdentityStore: PCLinkIdentityStore {
    public let service: String
    public let account: String

    public init(service: String = "dsh-pclink", account: String = "identity-v1") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func loadSeed() throws -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                throw PCLinkKeychainError(operation: "load", status: errSecDecode)
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw PCLinkKeychainError(operation: "load", status: status)
        }
    }

    public func saveSeed(_ seed: Data) throws {
        guard seed.count == 32 else {
            throw PCLinkCryptoError.invalidKeyLength(expected: 32, actual: seed.count)
        }
        var add = baseQuery
        add[kSecValueData as String] = seed
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrSynchronizable as String] = false
        let status = SecItemAdd(add as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let update: [String: Any] = [kSecValueData as String: seed]
            let updateStatus = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw PCLinkKeychainError(operation: "update", status: updateStatus)
            }
        default:
            throw PCLinkKeychainError(operation: "save", status: status)
        }
    }

    public func deleteSeed() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PCLinkKeychainError(operation: "delete", status: status)
        }
    }
}
