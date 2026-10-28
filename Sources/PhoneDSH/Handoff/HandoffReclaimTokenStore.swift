// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSH: reclaim-token storage seam.
//
// handoff.md §2/§5: the 128-bit `reclaim_token` is the only credential of the
// return path. It is never written to the workspace, the WAL, an ordinary
// file, a URL, the ordered channel or a log. This module defines the seam the
// App implements with its secure vault. The in-memory actor below is for one
// process and tests only; an App that needs cold-process reclaim injects the
// Keychain (or equivalent secure-vault) store.
//
// The stored value also carries the non-secret remote fence, endpoint and a
// stable workspace identifier. Those bind the token to the remote and workspace
// that issued it; they are not credentials and may live beside the token in the
// App's vault. A vault shared by several workspaces must never apply one
// workspace's token to another: the identifier is checked before any network
// request or segment apply.

import Foundation
import PhoneDSHLog
import PhoneDSHWire

/// One reclaim credential: the secret token plus the non-secret CAS evidence.
public struct HandoffReclaimToken: Codable, Equatable, Sendable {
    /// 32 lowercase hex characters; secret, never logged.
    public var token: String
    /// The `{owner:"remote", generation, wal_seq}` returned by the CAS. `nil`
    /// only for the legacy in-memory `store(token:)` overload.
    public var remoteFence: Fence?
    /// HTTPS endpoint that issued the token. Used to refuse a token from
    /// another remote when the App shares one vault across workspaces.
    public var endpoint: String?
    /// Non-secret SHA-256 of the canonical workspace root. `nil` is an old
    /// credential (or a manually built one); ``ReclaimClient`` refuses it
    /// rather than risk applying another workspace's segments.
    public var workspaceIdentifier: String?

    public init(token: String, remoteFence: Fence? = nil, endpoint: String? = nil,
                workspaceIdentifier: String? = nil) {
        self.token = token
        self.remoteFence = remoteFence
        self.endpoint = endpoint
        self.workspaceIdentifier = workspaceIdentifier
    }

    /// Stable, non-secret workspace binding. The canonical root path is hashed
    /// so the vault holds no absolute path and a normal process restart sees
    /// the same value.
    public static func workspaceIdentifier(for root: URL) -> String {
        let path = root.standardizedFileURL.resolvingSymlinksInPath().path
        return SHA256.hash(Data(path.utf8))
    }

    enum CodingKeys: String, CodingKey {
        case token
        case remoteFence
        case endpoint
        case workspaceIdentifier = "workspace_identifier"
    }
}

/// Persistence seam for the reclaim token.
///
/// Only the App's secure storage implements durable conformance. The protocol
/// deliberately has no file URL or workspace root parameter, so a caller
/// cannot route the token into the workspace or the WAL.
public protocol HandoffReclaimTokenStore: Sendable {
    /// Stores one credential. A newer handoff replaces the previous one only
    /// when the vault accepts it atomically.
    func store(_ token: HandoffReclaimToken) async throws
    /// Returns the credential, or `nil` when the vault is empty.
    func load() async throws -> HandoffReclaimToken?
    /// Removes the credential after a successful reclaim (or an explicit
    /// user-requested reset of the local vault entry).
    func remove() async throws
}

/// Process-lifetime store used as the default and by tests.
///
/// This is **not** cold-process persistence. An App that needs reclaim after a
/// process death injects a secure-vault implementation into
/// ``PhoneDSHHost/init(configuration:engineFactory:handoffTransport:reclaimTokenStore:)``.
public actor InMemoryHandoffReclaimTokenStore: HandoffReclaimTokenStore {
    private var token: HandoffReclaimToken?

    public init(_ initial: HandoffReclaimToken? = nil) {
        self.token = initial
    }

    public func store(_ token: HandoffReclaimToken) async throws {
        self.token = token
    }

    public func load() async throws -> HandoffReclaimToken? {
        token
    }

    public func remove() async throws {
        token = nil
    }
}

#if canImport(Security)
import Security

/// Keychain-backed store with `ThisDeviceOnly` accessibility.
///
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` keeps the token out of
/// backups and off other devices. On macOS that accessibility only applies to
/// the data-protection keychain, so every query pins
/// `kSecUseDataProtectionKeychain`; otherwise the item could silently land in
/// the legacy file keychain. The Keychain item is keyed by `service` and
/// `account`; the non-secret endpoint/fence/workspace identifier travel with it
/// so a shared vault cannot hand a token to a different remote or workspace.
/// `store(_:)` updates an existing item in place (add only when absent, update
/// again on a duplicate-add race), so a failure never deletes the previous
/// token before the replacement is accepted. Apps that host several
/// workspaces should still give each workspace its own `account`; a shared
/// account can only hold the newest token, and a credential for another
/// workspace is refused rather than applied. This is a reference
/// implementation an App may instantiate and inject; the library never writes
/// the token to disk itself.
public struct KeychainHandoffReclaimTokenStore: HandoffReclaimTokenStore {
    public let service: String
    public let account: String

    public init(service: String = "phone-dsh.handoff.reclaim",
                account: String) {
        self.service = service
        self.account = account
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    public func store(_ token: HandoffReclaimToken) async throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(token)
        } catch {
            throw HandoffError.reclaimTokenStoreFailed(
                "cannot encode the reclaim credential")
        }
        let query = baseQuery()
        let value: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String:
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        // Update first: an existing token must never be deleted before its
        // replacement is accepted, or a failure in the middle would lose the
        // only return credential. `errSecDuplicateItem` from a racing add is
        // resolved by updating the just-created item instead of deleting it.
        let updateStatus = SecItemUpdate(query as CFDictionary,
                                         value as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var attributes = query
            attributes.merge(value) { _, new in new }
            let addStatus = SecItemAdd(attributes as CFDictionary, nil)
            if addStatus == errSecDuplicateItem {
                let retryStatus = SecItemUpdate(query as CFDictionary,
                                                value as CFDictionary)
                guard retryStatus == errSecSuccess else {
                    throw HandoffError.reclaimTokenStoreFailed(
                        "Keychain update after a duplicate add failed with status \(retryStatus)")
                }
                return
            }
            guard addStatus == errSecSuccess else {
                throw HandoffError.reclaimTokenStoreFailed(
                    "Keychain add failed with status \(addStatus)")
            }
        default:
            throw HandoffError.reclaimTokenStoreFailed(
                "Keychain update failed with status \(updateStatus)")
        }
    }

    public func load() async throws -> HandoffReclaimToken? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw HandoffError.reclaimTokenStoreFailed(
                "Keychain read failed with status \(status)")
        }
        do {
            return try JSONDecoder().decode(HandoffReclaimToken.self, from: data)
        } catch {
            throw HandoffError.reclaimTokenStoreFailed(
                "the Keychain reclaim credential is corrupt")
        }
    }

    public func remove() async throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw HandoffError.reclaimTokenStoreFailed(
                "Keychain delete failed with status \(status)")
        }
    }
}
#endif
