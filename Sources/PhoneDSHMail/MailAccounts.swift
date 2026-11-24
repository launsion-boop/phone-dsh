// SPDX-License-Identifier: MIT
// Mail providers that accept an address plus a client authorization code
// (QQ, NetEase) or app password (Gmail) over IMAPS/SMTPS, and the on-device
// account store: addresses in UserDefaults, codes only in the Keychain.

import Foundation
#if canImport(Security)
import Security
#endif

public struct MailServer: Sendable, Equatable, Codable {
    public var host: String
    public var port: Int
}

public enum MailProvider: String, Sendable, Codable, CaseIterable, Identifiable {
    case qq
    case netease
    case gmail

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .qq: return "QQ 邮箱"
        case .netease: return "网易邮箱"
        case .gmail: return "Gmail"
        }
    }

    public var domains: [String] {
        switch self {
        case .qq: return ["qq.com", "foxmail.com", "vip.qq.com"]
        case .netease: return ["163.com", "126.com", "yeah.net"]
        case .gmail: return ["gmail.com", "googlemail.com"]
        }
    }

    /// What the provider calls the secret the user pastes.
    public var secretName: String {
        switch self {
        case .qq, .netease: return "客户端授权码"
        case .gmail: return "应用专用密码"
        }
    }

    public func servers(for address: String) -> (imap: MailServer, smtp: MailServer)? {
        guard let domain = Self.domain(of: address), domains.contains(domain) else { return nil }
        switch self {
        case .qq:
            return (MailServer(host: "imap.qq.com", port: 993), MailServer(host: "smtp.qq.com", port: 465))
        case .netease:
            return (MailServer(host: "imap.\(domain)", port: 993), MailServer(host: "smtp.\(domain)", port: 465))
        case .gmail:
            return (MailServer(host: "imap.gmail.com", port: 993), MailServer(host: "smtp.gmail.com", port: 465))
        }
    }

    public static func provider(for address: String) -> MailProvider? {
        guard let domain = domain(of: address) else { return nil }
        return allCases.first { $0.domains.contains(domain) }
    }

    static func domain(of address: String) -> String? {
        let parts = address.lowercased().split(separator: "@")
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains(".") else { return nil }
        return String(parts[1])
    }
}

public struct MailAccount: Sendable, Equatable, Codable, Identifiable {
    public var address: String
    public var provider: MailProvider
    public var id: String { address }

    public init(address: String, provider: MailProvider) {
        self.address = address.lowercased().trimmingCharacters(in: .whitespaces)
        self.provider = provider
    }
}

public protocol MailSecretStore: Sendable {
    func secret(for account: String) throws -> String?
    func setSecret(_ secret: String, for account: String) throws
    func deleteSecret(for account: String) throws
}

#if canImport(Security)
/// Device-only Keychain items (`AfterFirstUnlockThisDeviceOnly`).
public struct KeychainMailSecretStore: MailSecretStore {
    public static let defaultService = "dev.phone-dsh.probe.mail"
    public let service: String

    public init(service: String = KeychainMailSecretStore.defaultService) {
        self.service = service
    }

    public func secret(for account: String) throws -> String? {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw MailError.store }
        return String(data: data, encoding: .utf8)
    }

    public func setSecret(_ secret: String, for account: String) throws {
        let data = Data(secret.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(base(account) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = base(account)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw MailError.store }
    }

    public func deleteSecret(for account: String) throws {
        let status = SecItemDelete(base(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw MailError.store }
    }

    private func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}
#endif

/// Account list (non-secret) plus one Keychain item per address.
public final class MailAccountStore: @unchecked Sendable {
    public static let defaultsKey = "phone-dsh.mail-accounts.v1"
    #if canImport(Security)
    public static let shared = MailAccountStore()
    #endif

    private let defaults: UserDefaults
    private let secrets: any MailSecretStore
    private let lock = NSLock()

    #if canImport(Security)
    public convenience init() {
        self.init(defaults: .standard, secrets: KeychainMailSecretStore())
    }
    #endif

    public init(defaults: UserDefaults, secrets: any MailSecretStore) {
        self.defaults = defaults
        self.secrets = secrets
    }

    public func accounts() -> [MailAccount] {
        lock.lock(); defer { lock.unlock() }
        return readLocked()
    }

    public func account(_ address: String) -> MailAccount? {
        let key = address.lowercased().trimmingCharacters(in: .whitespaces)
        return accounts().first { $0.address == key }
    }

    public func secret(for account: MailAccount) throws -> String {
        guard let value = try secrets.secret(for: account.address), !value.isEmpty else { throw MailError.store }
        return value
    }

    /// Secret first, then the list: a crash never lists an account without its code.
    public func save(_ account: MailAccount, secret: String) throws {
        lock.lock(); defer { lock.unlock() }
        try secrets.setSecret(secret, for: account.address)
        var list = readLocked().filter { $0.address != account.address }
        list.append(account)
        list.sort { $0.address < $1.address }
        writeLocked(list)
    }

    /// List first, then the secret: a removed account is unusable at once.
    public func remove(_ address: String) throws {
        let key = address.lowercased()
        lock.lock(); defer { lock.unlock() }
        writeLocked(readLocked().filter { $0.address != key })
        try secrets.deleteSecret(for: key)
    }

    private func readLocked() -> [MailAccount] {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let list = try? JSONDecoder().decode([MailAccount].self, from: data) else { return [] }
        return list
    }

    private func writeLocked(_ list: [MailAccount]) {
        defaults.set(try? JSONEncoder().encode(list), forKey: Self.defaultsKey)
    }
}
