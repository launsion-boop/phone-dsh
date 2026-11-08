// SPDX-License-Identifier: MIT
// §4.1 phone key. One P-256 signing key per installation, reached only
// through the opaque BLESecureSigner interface; the private key is never
// exported to logs, files, the Worker or the model.
import CryptoKit
import Foundation
import Security

/// The phone key as the rest of the session sees it: its fingerprint and an
/// opaque signer.
public struct BLESecurePhoneKey: Sendable {
    public let fingerprint: String
    public let signer: BLESecureSigner
    /// True for a Secure Enclave key; false for the permitted software Keychain
    /// key, which the UI must label "软件密钥" (§15.3).
    public let isHardwareBacked: Bool

    public init(signer: BLESecureSigner, isHardwareBacked: Bool) throws {
        self.fingerprint = try BLESecureIdentifiers.fingerprint(publicKey: signer.publicKey)
        self.signer = signer
        self.isHardwareBacked = isHardwareBacked
    }

    #if DEBUG
    /// Fixture seam: the shared enrollment vectors name fingerprints without
    /// private keys.
    init(testingFingerprint: String, signer: BLESecureSigner) {
        fingerprint = testingFingerprint
        self.signer = signer
        isHardwareBacked = false
    }
    #endif

    public var phoneID: String { BLESecureIdentifiers.phoneID(fingerprint: fingerprint) }
    public var token: String { BLESecureIdentifiers.phoneToken(fingerprint: fingerprint) }
}

/// Injectable key storage. `load` returns nil only when the item is reported
/// absent; a transient failure (locked device) throws and is never loss.
public protocol BLESecurePhoneKeyStore: Sendable {
    func load() throws -> BLESecurePhoneKey?
    func generate() throws -> BLESecurePhoneKey
    func delete() throws
}

public struct BLESecureKeychainError: Error, Equatable, Sendable {
    public let status: OSStatus
}

/// Keychain store: kSecClassKey, tag `pdsh.ble.session.phone-key.v1`,
/// permanent, AfterFirstUnlockThisDeviceOnly, not synchronizable, not
/// extractable. Secure Enclave whenever available (v2 §4.1). Every signature
/// goes through SecKeyCreateSignature via BLESecureSigner, the TLS client's
/// opaque signing hook; the private key never enters TLS memory.
///
/// Not exercised by the command-line test suite (no real Keychain there); the
/// in-memory store covers the seam.
public struct BLESecureKeychainKeyStore: BLESecurePhoneKeyStore {
    public static let tag = Data("pdsh.ble.session.phone-key.v1".utf8)
    public init() {}

    private var query: [String: Any] {
        [kSecClass as String: kSecClassKey,
         kSecAttrApplicationTag as String: Self.tag,
         kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
         kSecAttrSynchronizable as String: false]
    }

    public func load() throws -> BLESecurePhoneKey? {
        var q = query
        q[kSecReturnRef as String] = true
        q[kSecReturnAttributes as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let attributes = item as? [String: Any],
              let ref = attributes[kSecValueRef as String] else { throw BLESecureKeychainError(status: status) }
        let key = ref as! SecKey
        let token = attributes[kSecAttrTokenID as String] as? String
        return try BLESecurePhoneKey(signer: try SecKeySigner(key), isHardwareBacked: token == (kSecAttrTokenIDSecureEnclave as String))
    }

    public func generate() throws -> BLESecurePhoneKey {
        // v2 §4.1: a Secure Enclave key wherever one exists; a non-extractable
        // software key only without one. No silent software fallback.
        if SecureEnclave.isAvailable { return try create(secureEnclave: true) }
        return try create(secureEnclave: false)
    }

    private func create(secureEnclave: Bool) throws -> BLESecurePhoneKey {
        var error: Unmanaged<CFError>?
        var privateAttributes: [String: Any] = [
            kSecAttrIsPermanent as String: true,
            kSecAttrApplicationTag as String: Self.tag,
            kSecAttrIsExtractable as String: false,
        ]
        if secureEnclave {
            guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                                                               .privateKeyUsage, &error) else {
                throw BLESecureKeychainError(status: errSecParam)
            }
            privateAttributes[kSecAttrAccessControl as String] = access
        } else {
            privateAttributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
        var attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrSynchronizable as String: false,
            kSecPrivateKeyAttrs as String: privateAttributes,
        ]
        if secureEnclave { attributes[kSecAttrTokenID as String] = kSecAttrTokenIDSecureEnclave }
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw BLESecureKeychainError(status: errSecParam)
        }
        return try BLESecurePhoneKey(signer: try SecKeySigner(key), isHardwareBacked: secureEnclave)
    }

    public func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw BLESecureKeychainError(status: status) }
    }
}

/// Signs through a Keychain / Secure Enclave reference; never exports it.
struct SecKeySigner: BLESecureSigner, @unchecked Sendable {
    private let key: SecKey
    let publicKey: [UInt8]

    init(_ key: SecKey) throws {
        self.key = key
        var error: Unmanaged<CFError>?
        guard let pub = SecKeyCopyPublicKey(key),
              let data = SecKeyCopyExternalRepresentation(pub, &error) as Data? else { throw BLESecureKeychainError(status: errSecParam) }
        publicKey = Array(data)
    }

    func sign(_ message: [UInt8]) throws -> [UInt8] {
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, Data(message) as CFData, &error) as Data? else {
            throw BLESecureKeychainError(status: errSecParam)
        }
        return Array(signature)
    }
}

/// In-memory store for tests and previews; never persists.
public final class BLESecureMemoryKeyStore: BLESecurePhoneKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: BLESecurePhoneKey?
    private var factory: () throws -> BLESecurePhoneKey
    /// When set, `load` throws it (a transient Keychain failure).
    public var transientError: Error?

    public init(key: BLESecurePhoneKey? = nil,
                factory: @escaping () throws -> BLESecurePhoneKey = { try BLESecurePhoneKey(signer: BLESecureSoftwareSigner(), isHardwareBacked: false) }) {
        self.key = key
        self.factory = factory
    }

    public func load() throws -> BLESecurePhoneKey? {
        lock.lock(); defer { lock.unlock() }
        if let transientError { throw transientError }
        return key
    }

    public func generate() throws -> BLESecurePhoneKey {
        lock.lock(); defer { lock.unlock() }
        let made = try factory()
        key = made
        return made
    }

    public func delete() throws {
        lock.lock(); defer { lock.unlock() }
        key = nil
    }
}
