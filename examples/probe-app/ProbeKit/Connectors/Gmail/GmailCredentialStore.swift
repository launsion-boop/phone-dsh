// SPDX-License-Identifier: MIT

import Foundation
import Security

public protocol GmailTokenStore: Sendable {
    func read<T>(_ body: (GmailTokenSet?) throws -> T) throws -> T
    func write(_ tokens: GmailTokenSet?) throws
}

public struct GmailKeychainTokenStore: GmailTokenStore {
    public let service: String
    public let account: String

    public init(service: String = "dev.phone-dsh.probe.gmail.oauth", account: String = "default") {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecUseDataProtectionKeychain as String: true]
    }

    public func read<T>(_ body: (GmailTokenSet?) throws -> T) throws -> T {
        var query = self.query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return try body(nil) }
        guard status == errSecSuccess, let data = item as? Data else { throw GmailError.disconnected }
        let tokens = try? GmailJSON.decoder.decode(GmailTokenSet.self, from: data)
        return try body(tokens)
    }

    public func write(_ tokens: GmailTokenSet?) throws {
        guard let tokens else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw GmailError.transport }
            return
        }
        let data = try GmailJSON.encoder.encode(tokens)
        let attributes = [kSecValueData as String: data]
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess || added == errSecDuplicateItem else { throw GmailError.transport }
            if added == errSecDuplicateItem {
                let retry = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
                guard retry == errSecSuccess else { throw GmailError.transport }
            }
        } else if updated != errSecSuccess {
            throw GmailError.transport
        }
    }
}
