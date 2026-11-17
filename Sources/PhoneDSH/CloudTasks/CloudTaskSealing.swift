// SPDX-License-Identifier: MIT
// phone-dsh SDK — PhoneDSH: phone task sealing keys, key store and install identity.
//
// spec/v1/cloud-tasks.md §2–§3. HPKE base mode, DHKEM(P-256, HKDF-SHA256) /
// HKDF-SHA256 / AES-128-GCM, opened with CryptoKit. The phone only opens; it
// never seals. The private key lives in one Keychain item per `key_id` and is
// never exported; the cloud only ever sees the public point.

import CryptoKit
import Foundation
#if canImport(Security)
import Security
#endif

/// One sealing key pair of this install.
public struct CloudTaskKey: Equatable, Sendable {
    public let keyID: String
    /// The 32-byte P-256 private scalar.
    public let privateScalar: Data
    /// When the key was made; the newest key is the one registered.
    public let createdAtMs: Int64

    public init(keyID: String, privateScalar: Data, createdAtMs: Int64) {
        self.keyID = keyID
        self.privateScalar = privateScalar
        self.createdAtMs = createdAtMs
    }

    /// A fresh P-256 key with a new `key_id` (`k-` + lowercase UUID).
    public static func generate(nowMs: Int64) -> CloudTaskKey {
        CloudTaskKey(keyID: "k-" + UUID().uuidString.lowercased(),
                     privateScalar: P256.KeyAgreement.PrivateKey().rawRepresentation, createdAtMs: nowMs)
    }

    /// The uncompressed public point (`0x04 ‖ X ‖ Y`), or `nil` for a scalar that is not a P-256 key.
    public var publicKey: Data? {
        (try? P256.KeyAgreement.PrivateKey(rawRepresentation: privateScalar))?.publicKey.x963Representation
    }

    /// The `key` member of the registration.
    public var deviceKey: CloudTaskDeviceKey? {
        publicKey.map { CloudTaskDeviceKey(keyID: keyID, publicKey: $0) }
    }
}

public enum CloudTaskSealingError: Error, Equatable, Sendable {
    /// The stored scalar is not a P-256 private key.
    case badKey
    /// HPKE refused: wrong key, altered ciphertext or tag, or another AAD.
    case notOpened
    /// It opened to something that is not 1–16384 bytes of UTF-8.
    case notText
}

public enum CloudTaskSealing {
    static let ciphersuite = HPKE.Ciphersuite(kem: .P256_HKDF_SHA256, kdf: .HKDF_SHA256, aead: .AES_GCM_128)

    /// Opens `sealed` with the §3 `aad` and returns the task text.
    public static func open(_ sealed: CloudTaskSealed, privateScalar: Data, aad: Data) throws -> String {
        guard let privateKey = try? P256.KeyAgreement.PrivateKey(rawRepresentation: privateScalar) else {
            throw CloudTaskSealingError.badKey
        }
        let plaintext: Data
        do {
            var recipient = try HPKE.Recipient(privateKey: privateKey, ciphersuite: ciphersuite,
                                               info: Data(CloudTasks.info.utf8), encapsulatedKey: sealed.enc)
            plaintext = try recipient.open(sealed.ct, authenticating: aad)
        } catch {
            throw CloudTaskSealingError.notOpened
        }
        guard (1...CloudTasks.maxTextBytes).contains(plaintext.count),
              let text = String(data: plaintext, encoding: .utf8) else {
            throw CloudTaskSealingError.notText
        }
        return text
    }
}

// MARK: - Key store

public enum CloudTaskKeyStoreError: Error, Equatable, Sendable {
    /// The Keychain answered this status (for example before first unlock).
    case keychain(Int32)
    case unavailable
    case corrupt
}

/// Where the private keys live. Throwing means the store cannot be read or
/// written right now (the phone has not been unlocked since boot); a missing
/// key is `nil`, not an error.
public protocol CloudTaskKeyStore: Sendable {
    func key(id: String) throws -> CloudTaskKey?
    func keys() throws -> [CloudTaskKey]
    func save(_ key: CloudTaskKey) throws
    func delete(id: String) throws
}

extension CloudTaskKeyStore {
    /// The newest key: the one this install registers.
    func currentKey() throws -> CloudTaskKey? {
        try keys().max { ($0.createdAtMs, $0.keyID) < ($1.createdAtMs, $1.keyID) }
    }
}

/// Test and preview store.
public final class InMemoryCloudTaskKeyStore: CloudTaskKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: CloudTaskKey] = [:]
    private var failure: CloudTaskKeyStoreError?

    public init(_ keys: [CloudTaskKey] = []) {
        for key in keys { stored[key.keyID] = key }
    }

    /// Makes every call throw (`nil` restores the store): the locked-phone case.
    public func setFailure(_ error: CloudTaskKeyStoreError?) {
        lock.lock(); defer { lock.unlock() }
        failure = error
    }

    private func guarded<T>(_ body: () -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        if let failure { throw failure }
        return body()
    }

    public func key(id: String) throws -> CloudTaskKey? { try guarded { stored[id] } }
    public func keys() throws -> [CloudTaskKey] { try guarded { Array(stored.values) } }
    public func save(_ key: CloudTaskKey) throws { try guarded { stored[key.keyID] = key } }
    public func delete(id: String) throws { try guarded { stored[id] = nil } }
}

/// Keychain items `dev.phone-dsh.cloud-tasks` / `<key_id>`,
/// `AfterFirstUnlockThisDeviceOnly` (§3). The item value is the 8-byte
/// big-endian creation time followed by the 32-byte scalar.
public struct KeychainCloudTaskKeyStore: CloudTaskKeyStore {
    public let service: String

    public init(service: String = CloudTasks.keychainService) {
        self.service = service
    }

    static func pack(_ key: CloudTaskKey) -> Data {
        var data = Data()
        withUnsafeBytes(of: UInt64(max(0, key.createdAtMs)).bigEndian) { data.append(contentsOf: $0) }
        data.append(key.privateScalar)
        return data
    }

    static func unpack(_ data: Data, keyID: String) -> CloudTaskKey? {
        guard data.count == 40 else { return nil }
        let created = data.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        guard created <= UInt64(Int64.max) else { return nil }
        return CloudTaskKey(keyID: keyID, privateScalar: Data(data.dropFirst(8)), createdAtMs: Int64(created))
    }

    #if canImport(Security)
    private func query(_ account: String?) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service]
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }
    #endif

    public func key(id: String) throws -> CloudTaskKey? {
        #if canImport(Security)
        var query = self.query(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw CloudTaskKeyStoreError.keychain(status) }
        guard let key = Self.unpack(data, keyID: id) else { throw CloudTaskKeyStoreError.corrupt }
        return key
        #else
        throw CloudTaskKeyStoreError.unavailable
        #endif
    }

    public func keys() throws -> [CloudTaskKey] {
        #if canImport(Security)
        var query = self.query(nil)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let list = items as? [[String: Any]] else {
            throw CloudTaskKeyStoreError.keychain(status)
        }
        return try list.compactMap { attributes in
            guard let account = attributes[kSecAttrAccount as String] as? String else { return nil }
            return try key(id: account)
        }
        #else
        throw CloudTaskKeyStoreError.unavailable
        #endif
    }

    public func save(_ key: CloudTaskKey) throws {
        #if canImport(Security)
        let data = Self.pack(key)
        let status = SecItemUpdate(query(key.keyID) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(key.keyID)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(add as CFDictionary, nil)
            guard added == errSecSuccess else { throw CloudTaskKeyStoreError.keychain(added) }
        } else if status != errSecSuccess {
            throw CloudTaskKeyStoreError.keychain(status)
        }
        #else
        throw CloudTaskKeyStoreError.unavailable
        #endif
    }

    public func delete(id: String) throws {
        #if canImport(Security)
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CloudTaskKeyStoreError.keychain(status)
        }
        #else
        throw CloudTaskKeyStoreError.unavailable
        #endif
    }
}

// MARK: - Install identity and switch

/// The two preferences of the feature (§2, §7).
public struct CloudTaskPreferences: @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The user's switch; absent means off.
    public var isEnabled: Bool {
        (defaults.object(forKey: CloudTasks.enabledPreferenceKey) as? Bool) == true
    }

    public func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: CloudTasks.enabledPreferenceKey)
    }

    /// The install's cloud device id, created on first use. `nil` when the
    /// stored value is not `dev-` + a lowercase UUIDv4: the key is shared with
    /// the Bot cloud scheduler, so a foreign value is left alone, not replaced.
    public func deviceID() -> String? {
        if let stored = defaults.object(forKey: CloudTasks.deviceIDPreferenceKey) {
            return CloudTaskJSON.isDeviceID(stored) ? stored as? String : nil
        }
        let created = Self.newDeviceID()
        defaults.set(created, forKey: CloudTasks.deviceIDPreferenceKey)
        return created
    }

    /// The stored device id, without creating one.
    func existingDeviceID() -> String? {
        let stored = defaults.object(forKey: CloudTasks.deviceIDPreferenceKey)
        return CloudTaskJSON.isDeviceID(stored) ? stored as? String : nil
    }

    static func newDeviceID() -> String {
        "dev-" + UUID().uuidString.lowercased()
    }
}
