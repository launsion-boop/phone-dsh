// SPDX-License-Identifier: MIT

import Foundation
#if canImport(Security)
import Security
#endif

public enum ConnectorCredentialError: Error, Equatable, Sendable {
    case unavailable
    case keychain(OSStatus)
}

/// Credentials cross this boundary only inside a request-building closure.
public protocol ConnectorCredentialStore: Sendable {
    func saveCredential(_ credential: String, for reference: String) throws
    func deleteCredential(for reference: String) throws
    func withCredential<T>(for reference: String,
                           _ body: @Sendable (String) throws -> T) throws -> T?
}

public struct KeychainConnectorCredentialStore: ConnectorCredentialStore {
    public let service: String

    public init(service: String = "dev.phone-dsh.probe.connectors") {
        self.service = service
    }

    private func query(for reference: String) -> [String: Any] {
        #if canImport(Security)
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference,
        ]
        #else
        return [:]
        #endif
    }

    public func saveCredential(_ credential: String, for reference: String) throws {
        #if canImport(Security)
        guard !credential.isEmpty else {
            try deleteCredential(for: reference)
            return
        }
        let data = Data(credential.utf8)
        let status = SecItemUpdate(query(for: reference) as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(for: reference)
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess || addStatus == errSecDuplicateItem else {
                throw ConnectorCredentialError.keychain(addStatus)
            }
        } else if status != errSecSuccess {
            throw ConnectorCredentialError.keychain(status)
        }
        #else
        throw ConnectorCredentialError.unavailable
        #endif
    }

    public func deleteCredential(for reference: String) throws {
        #if canImport(Security)
        let status = SecItemDelete(query(for: reference) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ConnectorCredentialError.keychain(status)
        }
        #else
        throw ConnectorCredentialError.unavailable
        #endif
    }

    public func withCredential<T>(for reference: String,
                                  _ body: @Sendable (String) throws -> T) throws -> T? {
        #if canImport(Security)
        var query = query(for: reference)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw ConnectorCredentialError.keychain(status)
        }
        let credential = String(decoding: data, as: UTF8.self)
        return try body(credential)
        #else
        throw ConnectorCredentialError.unavailable
        #endif
    }
}
