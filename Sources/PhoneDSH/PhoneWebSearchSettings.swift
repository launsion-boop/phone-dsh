// SPDX-License-Identifier: MIT
// phone-dsh host SDK — independent web Search / Fetch API configuration.
//
// The independent search service is deliberately separate from the model
// provider document and the model Keychain account. Non-secret settings live
// in `phone-dsh.web-search.v1`; the API key lives only in the dedicated
// Keychain service `dev.phone-dsh.probe.search`. The Worker receives a
// placeholder plus endpoint metadata, never the key.
//
// A same-host Search/Fetch API is distinguished from the model Messages API by
// the request path: `PhoneWebSearchCredentialRouter` reads the independent key
// only for the normalized `/search` and `/fetch` operation paths and delegates
// every other host/path to the model provider. A missing key, a missing
// audience or a corrupt document fails closed instead of falling back to the
// model key.

import Foundation
#if canImport(Security)
import Security
#endif
import PhoneDSHAgentCore
import PhoneDSHGateway

/// How the Worker's web capability gets a search provider.
public enum PhoneWebSearchMode: String, Codable, CaseIterable, Hashable, Sendable {
    /// Explicit fallback to the current model service's Messages search.
    case followModel = "follow-model"
    /// The official DeepSeek Search/Fetch API with its own endpoint and key.
    case searchAPI = "search-api"

    /// Expression alias for callers that spell the acronym as one word.
    public static var searchApi: PhoneWebSearchMode { .searchAPI }

    /// The DSH search provider id selected by this mode.
    public var providerID: String {
        switch self {
        case .followModel: return "deepseek-official"
        case .searchAPI: return "deepseek-search-api"
        }
    }

    /// The DSH fetch provider id selected by this mode, when one exists.
    public var fetchProviderID: String? {
        switch self {
        case .followModel: return nil
        case .searchAPI: return "deepseek-fetch-api"
        }
    }

    /// Human-readable mode name for the system settings page.
    public var displayName: String {
        switch self {
        case .followModel: return "沿用模型服务"
        case .searchAPI: return "独立 DeepSeek 搜索 API"
        }
    }
}

/// The non-secret stored shape of the independent web-search configuration.
public struct PhoneWebSearchConfiguration: Codable, Equatable, Sendable {
    /// Stored document version.
    public var version: Int
    /// Selected search mode.
    public var mode: PhoneWebSearchMode
    /// Normalized base URL (the official provider appends `/search` or `/fetch`).
    public var baseURL: String
    /// Keychain account holding this search service's API key.
    public var credentialRef: String

    public init(version: Int = 1,
                mode: PhoneWebSearchMode = .followModel,
                baseURL: String = "",
                credentialRef: String = PhoneWebSearchSettings.defaultCredentialRef) {
        self.version = version
        self.mode = mode
        self.baseURL = baseURL
        self.credentialRef = credentialRef
    }

    /// Parsed endpoint, or nil in follow-model mode and for invalid values.
    public var endpointURL: URL? {
        guard mode == .searchAPI,
              let components = URLComponents(string: baseURL),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else { return nil }
        let path = ModelGatewayCredentialRouting.normalizedPath(components.path)
        guard !path.hasSuffix("/search"), !path.hasSuffix("/fetch") else { return nil }
        return components.url
    }

    /// Path the official provider appends for a search, or the empty string in
    /// follow-model mode.
    public var searchPath: String {
        guard let url = endpointURL else { return "" }
        let base = ModelGatewayCredentialRouting.normalizedPath(url)
        return base == "/" ? "/search" : base + "/search"
    }

    /// Path the official provider appends for a fetch, or the empty string in
    /// follow-model mode.
    public var fetchPath: String {
        guard let url = endpointURL else { return "" }
        let base = ModelGatewayCredentialRouting.normalizedPath(url)
        return base == "/" ? "/fetch" : base + "/fetch"
    }

    /// Both independent operation paths that carry the search credential.
    public var operationPaths: Set<String> {
        Set([searchPath, fetchPath].filter { !$0.isEmpty })
    }

    /// The concrete Search API endpoint (`baseURL + /search`), when valid.
    public var searchEndpointURL: URL? { operationEndpointURL(appending: searchPath) }

    /// The concrete Fetch API endpoint (`baseURL + /fetch`), when valid.
    public var fetchEndpointURL: URL? { operationEndpointURL(appending: fetchPath) }

    private func operationEndpointURL(appending path: String) -> URL? {
        guard let base = endpointURL, !path.isEmpty,
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.path = path
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// DSH search provider id selected by the mode.
    public var providerID: String { mode.providerID }
}

/// One validated read of the independent web-search configuration.
public struct PhoneWebSearchSnapshot: Equatable, Sendable {
    public var configuration: PhoneWebSearchConfiguration
    public var hasCredential: Bool
    /// The normalized independent base URL, or nil in follow-model mode.
    public var effectiveBaseURL: String?

    public init(configuration: PhoneWebSearchConfiguration = PhoneWebSearchConfiguration(),
                hasCredential: Bool = false,
                effectiveBaseURL: String? = nil) {
        self.configuration = configuration
        self.hasCredential = hasCredential
        self.effectiveBaseURL = effectiveBaseURL
    }
}

/// Errors raised while validating or persisting the independent search setup.
public enum PhoneWebSearchSettingsError: Error, LocalizedError, Equatable, Sendable {
    case invalidStoredDocument(String)
    case invalidBaseURL(String)
    case operationInBaseURL(String)
    case secretStore
    /// The store cannot enumerate the dedicated search service, so it cannot
    /// prove that a removal found every legacy account. Nothing is deleted.
    case secretEnumerationUnavailable
    /// The non-secret document or deletion marker could not be read, written
    /// or removed. No key is deleted unless a durable keyless state exists.
    case documentStore
    /// The endpoint changed and the old key must not silently follow it.
    case apiKeyRequiredForNewEndpoint(String)

    public var errorDescription: String? {
        switch self {
        case .invalidStoredDocument(let reason):
            return "Stored web-search configuration is invalid: \(reason)"
        case .invalidBaseURL(_):
            return "Search API base URL must be an http(s) URL with a host and no credentials, query or fragment"
        case .operationInBaseURL(_):
            return "Search API base URL must not already end in /search or /fetch"
        case .secretStore:
            return "The independent web-search credential cleanup could not be verified; retry the operation to finish it"
        case .secretEnumerationUnavailable:
            return "The independent web-search credential service cannot be enumerated; no key was deleted"
        case .documentStore:
            return "The independent web-search metadata could not be committed or cleaned up; retry the operation to finish it"
        case .apiKeyRequiredForNewEndpoint(_):
            return "The search endpoint changed; re-enter its API key instead of reusing the previous service's key"
        }
    }
}

/// Non-secret persistence seam for the web-search document.
///
/// Production uses `UserDefaults`; tests inject a store that fails at a chosen
/// stage so the secret/document transaction ordering is exercised without a
/// real Keychain or a real preference file. Keeping this internal prevents it
/// from becoming another public wiring surface.
protocol PhoneWebSearchDocumentStore {
    func read() throws -> Data?
    func write(_ data: Data) throws
    func remove() throws
}

/// Why a deletion marker exists. Clear-key keeps the endpoint document as a
/// keyless search configuration; remove also deletes that document at the end.
enum PhoneWebSearchDeletionOperation: String, Codable, Equatable, Sendable {
    case clearKey
    case removeConfiguration
}

/// Non-secret, durable record of a deletion that has started but may not have
/// finished. It is written *before* the keyless document and before any real
/// Keychain key is deleted. While it exists, `load()` does not expose the old
/// document as a usable configuration: it first finishes the recorded
/// keyless-document commit and deletion, or leaves the marker in place and
/// fails closed so the operation can be retried.
struct PhoneWebSearchDeletionMarker: Codable, Equatable, Sendable {
    struct KeylessDocument: Codable, Equatable, Sendable {
        var mode: PhoneWebSearchMode
        var baseURL: String
        var credentialRef: String
        var retiredCredentialRefs: [String]?
    }

    var version: Int
    var operation: PhoneWebSearchDeletionOperation
    var references: [String]
    /// The document that must be durable before `references` are deleted.
    /// `nil` is only used when there was no document to begin with.
    var keylessDocument: KeylessDocument?

    init(version: Int = 1,
         operation: PhoneWebSearchDeletionOperation,
         references: Set<String>,
         keylessDocument: KeylessDocument?) {
        self.version = version
        self.operation = operation
        self.references = references.sorted()
        self.keylessDocument = keylessDocument
    }
}

/// A store that can enumerate every account in the dedicated search service.
///
/// `remove()` must not report success for the fixed slots and ledger alone:
/// older builds wrote random `search.deepseek.api.<uuid>` accounts that survive
/// reinstalls, and a missing/corrupt document must not hide them. The production
/// adapter below enumerates only `dev.phone-dsh.probe.search`; the model-provider
/// Keychain service is never queried or changed here.
public protocol PhoneWebSearchSecretStore: ModelProviderSecretStore {
    /// Every account name currently present in this dedicated service.
    func allReferences() throws -> Set<String>
}

/// Dedicated Keychain adapter for the search service.
///
/// Credential reads/writes reuse the existing model-secret implementation with
/// the independent service name; enumeration is implemented here so the
/// parallel-reviewed model store needs no reset/enumeration surface of its own.
public struct KeychainPhoneWebSearchSecretStore: PhoneWebSearchSecretStore {
    public let service: String
    private let base: KeychainModelProviderSecretStore

    public init(service: String = PhoneWebSearchSettings.defaultKeychainService) {
        self.service = service
        self.base = KeychainModelProviderSecretStore(service: service)
    }

    public func secret(for reference: String) throws -> String? {
        try base.secret(for: reference)
    }

    public func setSecret(_ secret: String, for reference: String) throws {
        try base.setSecret(secret, for: reference)
    }

    public func deleteSecret(for reference: String) throws {
        try base.deleteSecret(for: reference)
    }

    public func allReferences() throws -> Set<String> {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else {
            throw ModelProviderSettingsError.keychain(status)
        }
        // `kSecMatchLimitAll` returns an array of attribute dictionaries; a
        // single match can still arrive as a dictionary on older platforms.
        var references = Set<String>()
        if let items = item as? [[String: Any]] {
            for attributes in items {
                if let account = attributes[kSecAttrAccount as String] as? String {
                    references.insert(account)
                }
            }
        } else if let attributes = item as? [String: Any],
                  let account = attributes[kSecAttrAccount as String] as? String {
            references.insert(account)
        }
        return references
        #else
        throw ModelProviderSettingsError.keychainUnavailable
        #endif
    }
}

/// `UserDefaults`-backed document store. `write` and `remove` synchronize and
/// read back their own effect, so a call that returns success means the value
/// is observable and the preference file accepted the change; a silent
/// preference failure becomes a dedicated not-committed error instead.
struct UserDefaultsPhoneWebSearchDocumentStore: PhoneWebSearchDocumentStore {
    let defaults: UserDefaults
    let key: String
    private let synchronize: () -> Bool

    init(defaults: UserDefaults,
         key: String,
         synchronize: (() -> Bool)? = nil) {
        self.defaults = defaults
        self.key = key
        self.synchronize = synchronize ?? { defaults.synchronize() }
    }

    func read() throws -> Data? {
        defaults.data(forKey: key)
    }

    func write(_ data: Data) throws {
        let previous = defaults.data(forKey: key)
        defaults.set(data, forKey: key)
        guard synchronize() else {
            // The in-process cache may already expose the new bytes even though
            // the preference file did not accept them. Roll it back and report
            // a definitely-not-committed error; otherwise a crash/relaunch
            // would resurrect the old document after its old key was retired.
            restore(previous)
            throw PhoneWebSearchDocumentCommitError.notCommitted
        }
        guard defaults.data(forKey: key) == data else {
            restore(previous)
            throw PhoneWebSearchDocumentCommitError.notCommitted
        }
    }

    func remove() throws {
        let previous = defaults.data(forKey: key)
        defaults.removeObject(forKey: key)
        guard synchronize() else {
            restore(previous)
            throw PhoneWebSearchDocumentCommitError.notCommitted
        }
        guard defaults.data(forKey: key) == nil else {
            restore(previous)
            throw PhoneWebSearchDocumentCommitError.notCommitted
        }
    }

    private func restore(_ data: Data?) {
        if let data {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
        _ = synchronize()
    }
}

/// A definite, non-durable preference mutation. `persistLocked` maps this to
/// `DocumentCommitFailure.notCommitted` without consulting the in-process
/// read-back cache, which cannot prove durability by itself.
enum PhoneWebSearchDocumentCommitError: Error {
    case notCommitted
}

/// Load/save/remove the independent web-search document and its Keychain key.
///
/// Saves are compensated transactions. A replacement key is written to a
/// different fixed account before the document points at it, and the document
/// write is checked for observability. The previous account is *not* deleted in
/// `save()`: the document commit is the only durable proof that the new
/// identity exists, so retired accounts are reclaimed by a later `load()` (or
/// by `remove()`). A crash between the two steps leaves a harmless orphan
/// account but cannot lose the old key or point the old document at the new
/// service's key. The fixed account names plus a non-secret reference ledger
/// keep every account this module may have written discoverable even when the
/// document itself is corrupt; `remove()` additionally enumerates the dedicated
/// search service so random accounts written by older builds cannot survive a
/// lost document or ledger.
public final class PhoneWebSearchSettings {
    /// UserDefaults key for the non-secret document.
    public static let defaultsKey = "phone-dsh.web-search.v1"
    /// Non-secret accounts a crash could have written before the document
    /// committed. Kept separately from the document so recovery never mistakes
    /// a pending account for the active one.
    static let pendingDefaultsKey = defaultsKey + ".pending"
    /// Non-secret index of every account this module has used. It is not the
    /// source of truth for the active key (the document is), but it lets
    /// `remove()` find rotated accounts when the document is unreadable.
    static let referencesDefaultsKey = defaultsKey + ".references"
    /// Durable deletion marker. It is separate from the document so a failed
    /// commit can never leave old bytes that point at a key already deleted.
    static let deletionDefaultsKey = defaultsKey + ".deletion"
    /// Dedicated Keychain service for the search key; never the model service.
    public static let defaultKeychainService = "dev.phone-dsh.probe.search"
    /// Default Keychain account for the independent search key.
    public static let defaultCredentialRef = "search.deepseek.api"
    /// Second deterministic account. Two fixed slots are enough to rotate a
    /// key without ever overwriting the account the committed document points
    /// at; a slot that is no longer current may be reused.
    static let alternateCredentialRef = defaultCredentialRef + ".alt"
    /// Reserved account for a keyless clear. It is deliberately separate from
    /// the two writable key slots, so committing "no key" never points the
    /// document at a stale key left in the other slot. `save()` never writes a
    /// key here; `remove()` still covers it in case an old build wrote it.
    static let keylessCredentialRef = defaultCredentialRef + ".keyless"
    /// Accounts this build can write a real key to.
    static let writableCredentialRefs: Set<String> = [defaultCredentialRef, alternateCredentialRef]
    /// Every account name this module can identify. `remove()` always deletes
    /// the whole set, so a corrupt document cannot hide the current key.
    static let knownCredentialRefs: Set<String> = [
        defaultCredentialRef, alternateCredentialRef, keylessCredentialRef,
    ]

    /// Worker environment key selecting the official search provider.
    public static let workerProviderKey = "PDSH_WEB_SEARCH_PROVIDER"
    /// Worker environment key selecting the official fetch provider.
    public static let workerFetchProviderKey = "PDSH_WEB_FETCH_PROVIDER"
    /// Worker environment key carrying the normalized Search/Fetch API base.
    public static let workerBaseURLKey = "DEEPSEEK_SEARCH_API_BASE_URL"
    /// Worker environment key carrying the non-secret placeholder.
    public static let workerAPIKeyEnv = "DEEPSEEK_SEARCH_API_KEY"
    /// The only value the Worker ever receives in place of a real key.
    public static let placeholderAPIKey = "phone-host-injects-search-key"
    /// Process-wide store used by the app; tests construct their own.
    public static let shared = PhoneWebSearchSettings()

    private struct StoredDocument: Codable, Equatable, Sendable {
        var version: Int
        var mode: PhoneWebSearchMode
        var baseURL: String
        var credentialRef: String
        var retiredCredentialRefs: [String]?

        init(configuration: PhoneWebSearchConfiguration,
             retiredCredentialRefs: [String]?) {
            self.version = configuration.version
            self.mode = configuration.mode
            self.baseURL = configuration.baseURL
            self.credentialRef = configuration.credentialRef
            self.retiredCredentialRefs = retiredCredentialRefs
        }
    }

    private struct ValidatedBase {
        let url: URL
        let baseURL: String
    }

    /// Whether a document write is known not to have committed, or whether the
    /// store may have committed it even though the write reported an error.
    /// Only a known failure may roll the new key back; an uncertain commit
    /// keeps the key because the document may already point at it.
    private enum DocumentCommitFailure: Error {
        case notCommitted
        case uncertain
    }

    private let defaults: UserDefaults
    private let secrets: any ModelProviderSecretStore
    private let documentStore: any PhoneWebSearchDocumentStore
    private let markerStore: any PhoneWebSearchDocumentStore
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard,
                secretStore: any ModelProviderSecretStore = KeychainPhoneWebSearchSecretStore()) {
        self.defaults = defaults
        self.secrets = secretStore
        self.documentStore = UserDefaultsPhoneWebSearchDocumentStore(
            defaults: defaults,
            key: PhoneWebSearchSettings.defaultsKey)
        self.markerStore = UserDefaultsPhoneWebSearchDocumentStore(
            defaults: defaults,
            key: PhoneWebSearchSettings.deletionDefaultsKey)
    }

    /// Test seam: inject a document/marker store that fails at a chosen
    /// transaction stage. Production callers use the `defaults`/`secretStore`
    /// initializer.
    init(defaults: UserDefaults,
         secretStore: any ModelProviderSecretStore,
         documentStore: any PhoneWebSearchDocumentStore,
         markerStore: (any PhoneWebSearchDocumentStore)? = nil) {
        self.defaults = defaults
        self.secrets = secretStore
        self.documentStore = documentStore
        self.markerStore = markerStore ?? UserDefaultsPhoneWebSearchDocumentStore(
            defaults: defaults,
            key: PhoneWebSearchSettings.deletionDefaultsKey)
    }

    // MARK: - Reads

    /// Read and validate the document and report whether a key is stored.
    ///
    /// A missing document is the explicit follow-model default. A corrupt
    /// document or a Keychain read failure throws; callers that build a
    /// credential provider fail closed instead of silently using the model key.
    public func load() throws -> PhoneWebSearchSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return try loadLocked()
    }

    /// Whether a non-empty key exists for the stored independent account.
    ///
    /// Store failures report `false` (fail closed); the throwing `load()` is the
    /// surface that exposes the failure to the configuration page.
    public func hasAPIKey() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        do {
            // A deletion in progress is not a usable configuration, even if
            // the old key is still readable.
            guard try deletionMarkerLocked() == nil else { return false }
        } catch {
            return false
        }
        let stored: StoredDocument?
        do {
            stored = try storedDocumentLocked()
        } catch {
            return false
        }
        guard let stored else { return false }
        do {
            let value = try secrets.secret(for: stored.credentialRef)
            return !(value ?? "").isEmpty
        } catch {
            return false
        }
    }

    /// Non-secret Worker environment entries.
    ///
    /// Search-api mode carries the provider ids, the normalized endpoint and a
    /// placeholder. The real key never appears here.
    public func environmentEntries() throws -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        try resolveDeletionMarkerLocked()
        guard let stored = try storedDocumentLocked() else {
            return [Self.workerProviderKey: PhoneWebSearchMode.followModel.providerID]
        }
        let configuration = try configurationLocked(from: stored)
        switch configuration.mode {
        case .followModel:
            return [Self.workerProviderKey: configuration.providerID]
        case .searchAPI:
            var entries = [
                Self.workerProviderKey: configuration.providerID,
                Self.workerBaseURLKey: configuration.baseURL,
                Self.workerAPIKeyEnv: Self.placeholderAPIKey,
            ]
            if let fetchProviderID = configuration.mode.fetchProviderID {
                entries[Self.workerFetchProviderKey] = fetchProviderID
            }
            return entries
        }
    }

    /// Scheme/host/port allow-list rule for the independent Search/Fetch host.
    ///
    /// Follow-model mode owns no independent host and returns an empty set.
    public func allowedHostRules() throws -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        try resolveDeletionMarkerLocked()
        guard let stored = try storedDocumentLocked() else { return [] }
        let configuration = try configurationLocked(from: stored)
        guard configuration.mode == .searchAPI else { return [] }
        guard let url = configuration.endpointURL,
              let scheme = url.scheme?.lowercased(),
              let host = url.host, !host.isEmpty else {
            throw PhoneWebSearchSettingsError.invalidBaseURL(configuration.baseURL)
        }
        var rule = "\(scheme)://\(host.lowercased())"
        if let port = url.port { rule += ":\(port)" }
        return [rule]
    }

    // MARK: - Writes

    /// Save the non-secret configuration, optionally replacing the API key.
    ///
    /// - Parameters:
    ///   - mode: follow-model (explicit model-service fallback) or search-api.
    ///   - baseURL: normalized Search/Fetch API base; ignored in follow-model.
    ///   - apiKey: a replacement key, `nil` to keep the current key for the same
    ///     service identity, or the empty string to clear it. A changed endpoint
    ///     with an old key and no replacement throws instead of reusing the old
    ///     key across a trust boundary.
    @discardableResult
    public func save(mode: PhoneWebSearchMode,
                     baseURL: String,
                     apiKey: String? = nil) throws -> PhoneWebSearchSnapshot {
        lock.lock()
        defer { lock.unlock() }
        // Never let a new save read an old document while a deletion marker
        // still protects a key that may have been deleted.
        try resolveDeletionMarkerLocked()
        let stored = try storedDocumentLocked()
        let existing = try stored.map { try configurationLocked(from: $0) }
        let providedKey = apiKey.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let retired = Set(stored?.retiredCredentialRefs ?? [])
        reconcilePendingLocked(keeping: existing?.credentialRef)
        recordReferencesLocked(Set([existing?.credentialRef ?? Self.defaultCredentialRef])
            .union(retired))

        switch mode {
        case .followModel:
            // The stored endpoint is the last search service identity. Keeping
            // it unchanged (and ignoring the argument) while following the
            // model service prevents a later switch back from silently pairing
            // an old key with a new host.
            let normalizedBase = existing?.baseURL ?? ""
            let ref = existing?.credentialRef ?? Self.defaultCredentialRef
            let configuration = PhoneWebSearchConfiguration(version: 1,
                                                            mode: .followModel,
                                                            baseURL: normalizedBase,
                                                            credentialRef: ref)
            do {
                try persistLocked(StoredDocument(configuration: configuration,
                                                 retiredCredentialRefs: sortedRetired(retired)))
            } catch {
                throw PhoneWebSearchSettingsError.documentStore
            }
            // Deliberately no cleanup here. The document write above is the
            // commit; a later load that actually reads it reclaims retired
            // accounts. A crash or lost preference write therefore leaves the
            // old document and its key intact.
            return PhoneWebSearchSnapshot(configuration: configuration,
                                          hasCredential: false,
                                          effectiveBaseURL: nil)

        case .searchAPI:
            let validated = try validatedBase(baseURL)
            // A missing document does not imply a missing key: Keychain items
            // survive reinstalls and UserDefaults resets, and an earlier
            // pending deletion can fail. Treat the default account as the
            // candidate previous identity so a stale key is never silently
            // attached to a new endpoint. A store failure is not "no key": it
            // aborts before any Keychain or document write.
            let priorRef = existing?.credentialRef ?? Self.defaultCredentialRef
            let priorBase = existing?.baseURL
            let priorHasKey = !(try readSecretLocked(priorRef) ?? "").isEmpty
            let sameIdentity = priorBase == validated.baseURL
            let hasCommittedDocument = existing != nil

            if providedKey == nil, !sameIdentity, priorHasKey {
                throw PhoneWebSearchSettingsError.apiKeyRequiredForNewEndpoint(validated.baseURL)
            }

            let targetRef: String
            if let providedKey, !providedKey.isEmpty {
                // A key may only land on the previous account when that
                // account is the committed identity and the endpoint did not
                // move. A first save with a stale default key, or any endpoint
                // change, gets the other fixed account so an old document can
                // never resolve the new service's key during the commit
                // window.
                let priorIsWritable = Self.writableCredentialRefs.contains(priorRef)
                let mustUseFreshAccount = priorHasKey
                    || (hasCommittedDocument && !sameIdentity)
                    || !priorIsWritable
                targetRef = mustUseFreshAccount
                    ? allocateCredentialRef(avoiding: priorRef)
                    : priorRef
            } else if providedKey == nil, sameIdentity {
                targetRef = priorRef
            } else {
                // An explicit clear or a keyless move keeps the account only
                // when it cannot expose an old key. Otherwise the other fixed
                // account is committed and the old one is retired afterwards.
                targetRef = priorHasKey
                    ? allocateCredentialRef(avoiding: priorRef)
                    : priorRef
            }

            var newRetired = retired
            if priorRef != targetRef {
                newRetired.insert(priorRef)
            }
            newRetired.remove(targetRef)
            recordReferencesLocked(Set([targetRef, priorRef]))

            var pending = pendingReferencesLocked()
            let writesKey = providedKey?.isEmpty == false
            let writesFreshAccount = writesKey
                && (targetRef != priorRef || !hasCommittedDocument)
            if writesFreshAccount {
                // Record the pending account before touching the Keychain. A
                // crash after this point leaves a reference the next load can
                // reconcile; the old document still points at the old account.
                pending.insert(targetRef)
                persistPendingLocked(pending)
            }

            // Put the target account into its committed state before the
            // document points at it. A replacement key remembers the prior
            // value for rollback; an explicit clear removes any stale value
            // left on a fixed slot that is no longer current.
            let previousTargetValue: String?
            if let providedKey, !providedKey.isEmpty {
                previousTargetValue = try readSecretLocked(targetRef)
                do {
                    try writeSecretLocked(providedKey, for: targetRef)
                } catch {
                    try? restoreSecret(previousTargetValue, for: targetRef)
                    pending.remove(targetRef)
                    persistPendingLocked(pending)
                    throw PhoneWebSearchSettingsError.secretStore
                }
            } else if providedKey?.isEmpty == true {
                previousTargetValue = try readSecretLocked(targetRef)
                if previousTargetValue != nil {
                    do {
                        try writeSecretLocked(nil, for: targetRef)
                    } catch {
                        try? restoreSecret(previousTargetValue, for: targetRef)
                        pending.remove(targetRef)
                        persistPendingLocked(pending)
                        throw PhoneWebSearchSettingsError.secretStore
                    }
                }
            } else {
                previousTargetValue = nil
            }

            let configuration = PhoneWebSearchConfiguration(version: 1,
                                                            mode: .searchAPI,
                                                            baseURL: validated.baseURL,
                                                            credentialRef: targetRef)
            do {
                try persistLocked(StoredDocument(configuration: configuration,
                                                 retiredCredentialRefs: sortedRetired(newRetired)))
            } catch {
                var mayRollBack = true
                if let failure = error as? DocumentCommitFailure,
                   case .uncertain = failure {
                    mayRollBack = false
                }
                if mayRollBack,
                   providedKey?.isEmpty == false || previousTargetValue != nil {
                    try? restoreSecret(previousTargetValue, for: targetRef)
                }
                if mayRollBack {
                    pending.remove(targetRef)
                    persistPendingLocked(pending)
                }
                throw PhoneWebSearchSettingsError.documentStore
            }
            pending.remove(targetRef)
            persistPendingLocked(pending)

            // No retired-key cleanup here. `load()` reclaims them only after
            // it has read the committed document; a save that is not durable
            // therefore keeps both the old document and the old key.
            let hasCredential: Bool
            if let providedKey {
                hasCredential = !providedKey.isEmpty
            } else {
                hasCredential = sameIdentity && priorHasKey
            }
            return PhoneWebSearchSnapshot(configuration: configuration,
                                          hasCredential: hasCredential,
                                          effectiveBaseURL: validated.baseURL)
        }
    }

    /// Remove the independent document and every account it still tracks.
    ///
    /// A corrupt or unsupported document is not treated as "nothing to
    /// delete": the dedicated service is enumerated, the fixed account names and
    /// the non-secret reference ledger always cover accounts this build wrote,
    /// and raw document fields recover legacy accounts.
    ///
    /// The order is metadata-first. A durable deletion marker is written, then
    /// a keyless/disabled document replaces the old one, and only after both
    /// are durable are real keys deleted. A failure after that point keeps the
    /// marker and keyless document in place and reports an explicit error; it
    /// never restores an old document that points at a deleted key. The next
    /// `load()`, `save()` or `remove()` finishes the recorded cleanup.
    public func remove() throws {
        lock.lock()
        defer { lock.unlock() }

        // Finish a previous interrupted deletion before inspecting the old
        // document again.
        try resolveDeletionMarkerLocked()

        // Enumeration must happen before any deletion. A store without this
        // capability cannot prove the search service is empty (legacy random
        // accounts can outlive both the document and the ledger), so fail
        // explicitly instead of reporting a partial cleanup as success.
        guard let enumerable = secrets as? any PhoneWebSearchSecretStore else {
            throw PhoneWebSearchSettingsError.secretEnumerationUnavailable
        }
        let serviceReferences: Set<String>
        do {
            serviceReferences = try enumerable.allReferences()
        } catch {
            throw PhoneWebSearchSettingsError.secretStore
        }

        var references = Self.knownCredentialRefs
        references.formUnion(referencesLocked())
        references.formUnion(pendingReferencesLocked())

        let stored: StoredDocument?
        do {
            stored = try storedDocumentLocked()
        } catch let error as PhoneWebSearchSettingsError {
            guard case .invalidStoredDocument = error else { throw error }
            stored = nil
        }
        if let stored {
            references.insert(stored.credentialRef)
            references.formUnion(stored.retiredCredentialRefs ?? [])
        } else {
            // The document is corrupt, unsupported or absent. Recover every
            // credential reference still visible in its raw bytes before
            // deleting; the fixed slots and the ledger cover the rest.
            references.formUnion(try rawReferencesLocked())
        }
        references.remove("")
        // Every account in the dedicated service is ours, including ones no
        // document or ledger ever recorded. Keep an empty account here if the
        // service really contains one: a removal must empty the service.
        references.formUnion(serviceReferences)

        let tombstoneBaseURL: String
        if let stored,
           (try? validatedBase(stored.baseURL)) != nil {
            tombstoneBaseURL = stored.baseURL
        } else {
            tombstoneBaseURL = ""
        }
        let marker = PhoneWebSearchDeletionMarker(
            operation: .removeConfiguration,
            references: references,
            keylessDocument: PhoneWebSearchDeletionMarker.KeylessDocument(
                mode: .followModel,
                baseURL: tombstoneBaseURL,
                credentialRef: Self.keylessCredentialRef,
                retiredCredentialRefs: nil))

        // 1. Durable marker. It prevents a restart from reading the old
        //    document if the following document write or key deletion fails.
        try persistDeletionMarkerLocked(marker)
        // 2. Durable keyless/disabled document. No key has been deleted yet.
        try persistMarkerDocumentLocked(marker)
        // 3. Only now delete and verify the real keys.
        try deleteAndVerifyReferencesLocked(references)
        // 4. Final document cleanup. A failure leaves the marker plus keyless
        //    document, so the operation can be retried without the old key.
        do {
            try documentStore.remove()
        } catch {
            throw PhoneWebSearchSettingsError.documentStore
        }
        defaults.removeObject(forKey: Self.pendingDefaultsKey)
        defaults.removeObject(forKey: Self.referencesDefaultsKey)
        _ = defaults.synchronize()
        try clearDeletionMarkerLocked()
    }

    /// Delete the active key while keeping the endpoint configuration.
    ///
    /// The keyless document is committed before the key is deleted. If the
    /// document cannot be committed, the original document and key are left
    /// untouched. If the later delete or marker cleanup fails, the keyless
    /// document and marker remain and the next load/clear retries cleanup.
    ///
    /// A corrupt document fails closed: it never falls back to deleting the
    /// default account, because that account may not be the active one and the
    /// caller must see that the credential reference could not be determined.
    public func clearAPIKey() throws {
        lock.lock()
        defer { lock.unlock() }
        try resolveDeletionMarkerLocked()

        let stored = try storedDocumentLocked()
        guard let stored else {
            // No document means no independent identity. A stale default
            // account can only be left by a first save that never committed;
            // remove it without touching unknown document-owned references.
            reconcilePendingLocked(keeping: nil)
            let marker = PhoneWebSearchDeletionMarker(
                operation: .clearKey,
                references: [Self.defaultCredentialRef],
                keylessDocument: nil)
            try persistDeletionMarkerLocked(marker)
            try deleteAndVerifyReferencesLocked([Self.defaultCredentialRef])
            try clearDeletionMarkerLocked()
            return
        }

        let configuration = try configurationLocked(from: stored)
        reconcilePendingLocked(keeping: configuration.credentialRef)
        let oldReference = configuration.credentialRef

        // The reserved keyless slot must really be empty, otherwise the
        // committed document would still point at a readable key. Never delete
        // it here: the marker/document commit must happen first, and a stray
        // key in this reserved slot can be removed with `remove()`.
        do {
            guard try secrets.secret(for: Self.keylessCredentialRef) == nil else {
                throw PhoneWebSearchSettingsError.secretStore
            }
        } catch let error as PhoneWebSearchSettingsError {
            throw error
        } catch {
            throw PhoneWebSearchSettingsError.secretStore
        }

        var retired = Set(stored.retiredCredentialRefs ?? [])
        retired.remove(Self.keylessCredentialRef)
        retired.remove(oldReference)
        let marker = PhoneWebSearchDeletionMarker(
            operation: .clearKey,
            references: [oldReference],
            keylessDocument: PhoneWebSearchDeletionMarker.KeylessDocument(
                mode: configuration.mode,
                baseURL: configuration.baseURL,
                credentialRef: Self.keylessCredentialRef,
                retiredCredentialRefs: sortedRetired(retired)))

        try persistDeletionMarkerLocked(marker)
        try persistMarkerDocumentLocked(marker)
        try deleteAndVerifyReferencesLocked([oldReference])
        try clearDeletionMarkerLocked()
    }

    /// Wrap the model provider with path-aware routing.
    ///
    /// A corrupt/invalid independent document returns a provider that refuses
    /// every request; the model provider is not consulted, so a broken search
    /// setup can never silently fall back to the model key.
    public func makeCredentialProvider(modelProvider: any CredentialProvider) -> any CredentialProvider {
        lock.lock()
        let result: Result<PhoneWebSearchSnapshot, Error>
        do {
            result = .success(try loadLocked())
        } catch {
            result = .failure(error)
        }
        lock.unlock()

        switch result {
        case .failure(_):
            return PhoneWebSearchFailClosedCredentialProvider()
        case .success(let snapshot):
            switch snapshot.configuration.mode {
            case .followModel:
                return modelProvider
            case .searchAPI:
                guard let url = snapshot.configuration.endpointURL,
                      let host = url.host, !host.isEmpty else {
                    return PhoneWebSearchFailClosedCredentialProvider()
                }
                let scheme = url.scheme?.lowercased()
                return PhoneWebSearchCredentialRouter(
                    modelProvider: modelProvider,
                    searchHost: host,
                    searchScheme: scheme,
                    searchPort: ModelGatewayCredentialRouting.effectivePort(url, scheme: scheme),
                    operationPaths: snapshot.configuration.operationPaths,
                    credentialRef: snapshot.configuration.credentialRef,
                    secretStore: secrets)
            }
        }
    }

    // MARK: - Validation

    private func loadLocked() throws -> PhoneWebSearchSnapshot {
        try resolveDeletionMarkerLocked()
        let stored = try storedDocumentLocked()
        reconcilePendingLocked(keeping: stored?.credentialRef)
        guard let stored else {
            return PhoneWebSearchSnapshot(
                configuration: PhoneWebSearchConfiguration(mode: .followModel,
                                                           baseURL: "",
                                                           credentialRef: Self.defaultCredentialRef),
                hasCredential: false,
                effectiveBaseURL: nil)
        }
        // A valid document is also a chance to index accounts written by an
        // older build before the document can become unreadable.
        recordReferencesLocked(Set([stored.credentialRef])
            .union(stored.retiredCredentialRefs ?? []))
        let configuration = try configurationLocked(from: stored)
        cleanupRetiredLocked(Set(stored.retiredCredentialRefs ?? []),
                             keeping: configuration.credentialRef)
        let hasCredential: Bool
        switch configuration.mode {
        case .followModel:
            hasCredential = false
        case .searchAPI:
            hasCredential = !(try readSecretLocked(configuration.credentialRef) ?? "").isEmpty
        }
        return PhoneWebSearchSnapshot(configuration: configuration,
                                      hasCredential: hasCredential,
                                      effectiveBaseURL: configuration.mode == .searchAPI
                                          ? configuration.baseURL
                                          : nil)
    }

    private func configurationLocked(from stored: StoredDocument) throws -> PhoneWebSearchConfiguration {
        guard stored.version == 1 else {
            throw PhoneWebSearchSettingsError.invalidStoredDocument(
                "unsupported version \(stored.version)")
        }
        let reference = try validatedCredentialRef(stored.credentialRef)
        switch stored.mode {
        case .searchAPI:
            let validated = try validatedBase(stored.baseURL)
            return PhoneWebSearchConfiguration(version: 1,
                                                mode: .searchAPI,
                                                baseURL: validated.baseURL,
                                                credentialRef: reference)
        case .followModel:
            let trimmed = stored.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let baseURL: String
            if trimmed.isEmpty {
                baseURL = ""
            } else {
                baseURL = try validatedBase(trimmed).baseURL
            }
            return PhoneWebSearchConfiguration(version: 1,
                                                mode: .followModel,
                                                baseURL: baseURL,
                                                credentialRef: reference)
        }
    }

    private func validatedCredentialRef(_ raw: String) throws -> String {
        let reference = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reference.isEmpty,
              reference.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              reference.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw PhoneWebSearchSettingsError.invalidStoredDocument("invalid credential reference")
        }
        return reference
    }

    /// Validate and normalize an independent Search/Fetch API base.
    private func validatedBase(_ raw: String) throws -> ValidatedBase {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw PhoneWebSearchSettingsError.invalidBaseURL(raw)
        }
        let path = ModelGatewayCredentialRouting.normalizedPath(components.path)
        guard !path.hasSuffix("/search"),
              !path.hasSuffix("/fetch") else {
            throw PhoneWebSearchSettingsError.operationInBaseURL(path)
        }
        var normalized = URLComponents()
        normalized.scheme = scheme
        normalized.host = host.lowercased()
        normalized.port = components.port
        normalized.path = path == "/" ? "" : path
        guard let baseURL = normalized.string,
              let url = URL(string: baseURL), url.host != nil else {
            throw PhoneWebSearchSettingsError.invalidBaseURL(raw)
        }
        return ValidatedBase(url: url, baseURL: baseURL)
    }

    // MARK: - Persistence and secret transaction helpers

    private func deletionMarkerLocked() throws -> PhoneWebSearchDeletionMarker? {
        let data: Data?
        do {
            data = try markerStore.read()
        } catch {
            throw PhoneWebSearchSettingsError.documentStore
        }
        guard let data else { return nil }
        do {
            return try JSONDecoder().decode(PhoneWebSearchDeletionMarker.self, from: data)
        } catch {
            // A corrupt marker is never treated as "no marker": that could make
            // the caller read an old document that still names a deleted key.
            throw PhoneWebSearchSettingsError.documentStore
        }
    }

    /// Persist the deletion marker durably. The caller must not delete any key
    /// unless this returns without throwing.
    private func persistDeletionMarkerLocked(_ marker: PhoneWebSearchDeletionMarker) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(marker)
        } catch {
            throw PhoneWebSearchSettingsError.documentStore
        }
        do {
            try markerStore.write(data)
        } catch {
            throw PhoneWebSearchSettingsError.documentStore
        }
        do {
            guard try markerStore.read() == data else {
                throw PhoneWebSearchSettingsError.documentStore
            }
        } catch let error as PhoneWebSearchSettingsError {
            throw error
        } catch {
            throw PhoneWebSearchSettingsError.documentStore
        }
    }

    private func clearDeletionMarkerLocked() throws {
        do {
            try markerStore.remove()
            guard try markerStore.read() == nil else {
                throw PhoneWebSearchSettingsError.documentStore
            }
        } catch let error as PhoneWebSearchSettingsError {
            throw error
        } catch {
            throw PhoneWebSearchSettingsError.documentStore
        }
    }

    /// Commit the keyless/disabled document recorded in the marker. No key is
    /// deleted before this succeeds.
    private func persistMarkerDocumentLocked(_ marker: PhoneWebSearchDeletionMarker) throws {
        guard let payload = marker.keylessDocument else { return }
        let stored = StoredDocument(
            configuration: PhoneWebSearchConfiguration(
                version: 1,
                mode: payload.mode,
                baseURL: payload.baseURL,
                credentialRef: payload.credentialRef),
            retiredCredentialRefs: payload.retiredCredentialRefs)
        do {
            _ = try configurationLocked(from: stored)
        } catch {
            throw PhoneWebSearchSettingsError.documentStore
        }
        do {
            try persistLocked(stored)
        } catch {
            throw PhoneWebSearchSettingsError.documentStore
        }
    }

    /// Finish a deletion recorded by a previous interrupted operation.
    ///
    /// The keyless document is committed first, then the recorded keys are
    /// deleted and verified. For a full removal the document itself is removed
    /// last. Any failure leaves the marker in place (fail closed); the next
    /// call retries instead of restoring a document that may name a lost key.
    private func resolveDeletionMarkerLocked() throws {
        guard let marker = try deletionMarkerLocked() else { return }
        guard marker.version == 1 else {
            throw PhoneWebSearchSettingsError.documentStore
        }
        if marker.operation == .removeConfiguration,
           marker.keylessDocument == nil {
            // A full removal must always replace the old document before any
            // key is deleted, even if the marker bytes were damaged.
            throw PhoneWebSearchSettingsError.documentStore
        }
        try persistMarkerDocumentLocked(marker)
        try deleteAndVerifyReferencesLocked(Set(marker.references))
        switch marker.operation {
        case .clearKey:
            try clearDeletionMarkerLocked()
        case .removeConfiguration:
            do {
                try documentStore.remove()
            } catch {
                throw PhoneWebSearchSettingsError.documentStore
            }
            defaults.removeObject(forKey: Self.pendingDefaultsKey)
            defaults.removeObject(forKey: Self.referencesDefaultsKey)
            _ = defaults.synchronize()
            try clearDeletionMarkerLocked()
        }
    }

    /// Delete every identified key and verify the service really dropped it.
    /// Verification is not a commit condition that restores the old document:
    /// a read failure after a successful delete keeps the marker/keyless state
    /// and reports an explicit retryable error.
    private func deleteAndVerifyReferencesLocked(_ references: Set<String>) throws {
        let ordered = references.sorted()
        for reference in ordered {
            do {
                try secrets.deleteSecret(for: reference)
            } catch {
                throw PhoneWebSearchSettingsError.secretStore
            }
        }
        for reference in ordered {
            do {
                guard try secrets.secret(for: reference) == nil else {
                    throw PhoneWebSearchSettingsError.secretStore
                }
            } catch let error as PhoneWebSearchSettingsError {
                throw error
            } catch {
                throw PhoneWebSearchSettingsError.secretStore
            }
        }
    }

    private func storedDocumentLocked() throws -> StoredDocument? {
        let data: Data?
        do {
            data = try documentStore.read()
        } catch {
            throw PhoneWebSearchSettingsError.documentStore
        }
        guard let data else { return nil }
        let stored: StoredDocument
        do {
            stored = try JSONDecoder().decode(StoredDocument.self, from: data)
        } catch {
            throw PhoneWebSearchSettingsError.invalidStoredDocument("document is not valid JSON")
        }
        guard stored.version == 1 else {
            throw PhoneWebSearchSettingsError.invalidStoredDocument(
                "unsupported version \(stored.version)")
        }
        return stored
    }

    /// Persist the document and make the write observable before returning.
    ///
    /// A store that persists the bytes but still reports an error is treated as
    /// committed when a read-back matches: deleting or restoring the new key
    /// after that point would contradict what the document now says. A store
    /// that reports success without keeping the bytes fails here instead of
    /// letting a later cleanup delete the only usable key.
    private func persistLocked(_ stored: StoredDocument) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(stored)
        } catch {
            throw DocumentCommitFailure.notCommitted
        }
        do {
            try documentStore.write(data)
        } catch is PhoneWebSearchDocumentCommitError {
            // The store rolled its in-process value back and reported a
            // definitely non-durable write. Do not use a read-back here: the
            // preference cache cannot prove that a crash would keep the bytes.
            throw DocumentCommitFailure.notCommitted
        } catch {
            do {
                let current = try documentStore.read()
                guard current == data else { throw DocumentCommitFailure.notCommitted }
                return
            } catch let failure as DocumentCommitFailure {
                throw failure
            } catch {
                throw DocumentCommitFailure.uncertain
            }
        }
        do {
            let current = try documentStore.read()
            guard current == data else { throw DocumentCommitFailure.notCommitted }
        } catch let failure as DocumentCommitFailure {
            throw failure
        } catch {
            throw DocumentCommitFailure.uncertain
        }
    }

    /// Recover credential references from raw document bytes when normal
    /// decoding fails (corrupt JSON, unsupported version or invalid reference).
    private func rawReferencesLocked() throws -> Set<String> {
        let data: Data?
        do {
            data = try documentStore.read()
        } catch {
            throw PhoneWebSearchSettingsError.documentStore
        }
        guard let data else { return [] }
        var references = Set<String>()
        if let raw = try? JSONSerialization.jsonObject(with: data),
           let object = raw as? [String: Any] {
            if let reference = object["credentialRef"] as? String {
                references.insert(reference)
            }
            if let retired = object["retiredCredentialRefs"] as? [String] {
                references.formUnion(retired)
            }
        }
        if let text = String(data: data, encoding: .utf8) {
            let tokens = text.split(whereSeparator: { character in
                !(character.isLetter || character.isNumber
                    || character == "." || character == "_" || character == "-")
            })
            for token in tokens where token.hasPrefix(Self.defaultCredentialRef) {
                references.insert(String(token))
            }
        }
        references.remove("")
        return references
    }

    private func pendingReferencesLocked() -> Set<String> {
        Set(defaults.stringArray(forKey: Self.pendingDefaultsKey) ?? [String]())
    }

    private func persistPendingLocked(_ references: Set<String>) {
        let values = references.filter { !$0.isEmpty }.sorted()
        if values.isEmpty {
            defaults.removeObject(forKey: Self.pendingDefaultsKey)
        } else {
            defaults.set(values, forKey: Self.pendingDefaultsKey)
        }
        _ = defaults.synchronize()
    }

    private func referencesLocked() -> Set<String> {
        Set(defaults.stringArray(forKey: Self.referencesDefaultsKey) ?? [String]())
    }

    /// Record every account this module may hold a key under. This ledger is
    /// non-secret; it is the recovery index for `remove()` when the document
    /// cannot be decoded.
    private func recordReferencesLocked(_ references: Set<String>) {
        let known = referencesLocked()
        var values = known
        values.formUnion(references)
        values.formUnion(Self.knownCredentialRefs)
        values.remove("")
        guard values != known else { return }
        defaults.set(values.sorted(), forKey: Self.referencesDefaultsKey)
        _ = defaults.synchronize()
    }

    /// Delete accounts that a crash wrote before their document committed.
    /// `current` is the account the valid document points at, so it is never
    /// treated as pending. A failed delete stays pending for the next attempt.
    private func reconcilePendingLocked(keeping current: String?) {
        let pending = pendingReferencesLocked()
        guard !pending.isEmpty else { return }
        var remaining = Set<String>()
        for reference in pending {
            if let current, reference == current { continue }
            do {
                try secrets.deleteSecret(for: reference)
            } catch {
                remaining.insert(reference)
            }
        }
        persistPendingLocked(remaining)
    }

    private func readSecretLocked(_ reference: String) throws -> String? {
        do {
            return try secrets.secret(for: reference)
        } catch {
            throw PhoneWebSearchSettingsError.secretStore
        }
    }

    private func writeSecretLocked(_ value: String?, for reference: String) throws {
        do {
            if let value {
                try secrets.setSecret(value, for: reference)
            } else {
                try secrets.deleteSecret(for: reference)
            }
        } catch {
            throw PhoneWebSearchSettingsError.secretStore
        }
    }

    private func restoreSecret(_ value: String?, for reference: String) throws {
        if let value {
            try secrets.setSecret(value, for: reference)
        } else {
            try secrets.deleteSecret(for: reference)
        }
    }

    /// Delete retired accounts after a load has read the committed document.
    /// A failure is not fatal; the reference stays in the document so a later
    /// load/remove reconciles it. This is never called from `save()`.
    private func cleanupRetiredLocked(_ retired: Set<String>, keeping current: String) {
        guard !retired.isEmpty else { return }
        var remaining = Set<String>()
        for reference in retired where reference != current {
            do {
                try secrets.deleteSecret(for: reference)
            } catch {
                remaining.insert(reference)
            }
        }
        if remaining != retired {
            let stored: StoredDocument?
            do {
                stored = try storedDocumentLocked()
            } catch {
                stored = nil
            }
            if var stored {
                stored.retiredCredentialRefs = sortedRetired(remaining)
                try? persistLocked(stored)
            }
        }
    }

    private func sortedRetired(_ references: Set<String>) -> [String]? {
        let values = references.filter { !$0.isEmpty }.sorted()
        return values.isEmpty ? nil : values
    }

    /// Pick the fixed account that is not the committed one. Two slots suffice:
    /// the non-current slot may hold a retired key, which is safe to overwrite
    /// because no committed document points at it.
    private func allocateCredentialRef(avoiding current: String) -> String {
        if current != Self.defaultCredentialRef {
            return Self.defaultCredentialRef
        }
        return Self.alternateCredentialRef
    }
}

/// Refuses every credential request when the independent configuration is
/// corrupt or invalid. It never falls back to the model provider.
private struct PhoneWebSearchFailClosedCredentialProvider: CredentialProvider, Sendable {
    func credential(for scope: CredentialScope) async throws -> Credential {
        throw ProviderError.unauthorized("independent web-search configuration is invalid")
    }

    func invalidate(_ credential: Credential, for scope: CredentialScope) async {}
}

/// Routes the exact Search/Fetch operation paths on the configured search host
/// to the independent Keychain account and everything else to the model
/// provider. A same-host model request (`/v1/messages`) keeps the model key; a
/// missing search key or missing audience fails closed.
public struct PhoneWebSearchCredentialRouter: CredentialProvider, Sendable {
    private let modelProvider: any CredentialProvider
    private let searchHost: String
    private let searchScheme: String?
    private let searchPort: Int?
    private let operationPaths: Set<String>
    private let credentialRef: String
    private let secrets: any ModelProviderSecretStore

    public init(modelProvider: any CredentialProvider,
                searchHost: String,
                searchPath: String,
                credentialRef: String,
                secretStore: any ModelProviderSecretStore) {
        let normalizedSearch = ModelGatewayCredentialRouting.normalizedPath(searchPath)
        var paths = Set([normalizedSearch])
        if normalizedSearch.hasSuffix("/search") {
            // The official providers append both operation names to one base;
            // deriving the sibling keeps this minimal initializer useful for
            // both `web_search` and `web_fetch`.
            paths.insert(String(normalizedSearch.dropLast("/search".count)) + "/fetch")
        }
        self.init(modelProvider: modelProvider,
                  searchHost: searchHost,
                  operationPaths: paths,
                  credentialRef: credentialRef,
                  secretStore: secretStore)
    }

    /// Production initializer. The exact configured scheme and effective port
    /// travel with the host so a same-host request on another port cannot
    /// borrow the independent Search/Fetch key. `nil` keeps the legacy
    /// host/path-only matching used by older callers.
    public init(modelProvider: any CredentialProvider,
                searchHost: String,
                searchScheme: String? = nil,
                searchPort: Int? = nil,
                operationPaths: Set<String>,
                credentialRef: String,
                secretStore: any ModelProviderSecretStore) {
        self.modelProvider = modelProvider
        self.searchHost = Self.bareHost(searchHost)
        self.searchScheme = searchScheme?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.searchPort = searchPort
        self.operationPaths = Self.normalizedOperationPaths(operationPaths)
        self.credentialRef = credentialRef
        self.secrets = secretStore
    }

    public func credential(for scope: CredentialScope) async throws -> Credential {
        let host = Self.bareHost(scope.service)
        guard !searchHost.isEmpty, host == searchHost, matchesSearchOrigin(scope) else {
            return try await modelProvider.credential(for: scope)
        }
        guard let audience = scope.audience else {
            throw ProviderError.unauthorized(
                "web-search request on \(searchHost) has no path scope")
        }
        guard operationPaths.contains(ModelGatewayCredentialRouting.normalizedPath(audience)) else {
            return try await modelProvider.credential(for: scope)
        }
        do {
            guard let key = try secrets.secret(for: credentialRef), !key.isEmpty else {
                throw ProviderError.unauthorized(
                    "no independent web-search API key is configured on this phone")
            }
            return Credential(kind: .bearer, value: key)
        } catch let error as ProviderError {
            throw error
        } catch {
            throw ProviderError.unauthorized(
                "the independent web-search credential could not be read")
        }
    }

    public func invalidate(_ credential: Credential, for scope: CredentialScope) async {
        let host = Self.bareHost(scope.service)
        if host == searchHost,
           matchesSearchOrigin(scope),
           let audience = scope.audience,
           operationPaths.contains(ModelGatewayCredentialRouting.normalizedPath(audience)) {
            return
        }
        await modelProvider.invalidate(credential, for: scope)
    }

    /// Match the configured Search/Fetch origin when the gateway supplies it.
    /// A scope without a scheme is the legacy host/path shape and remains
    /// compatible; a supplied scheme or port must agree exactly.
    private func matchesSearchOrigin(_ scope: CredentialScope) -> Bool {
        guard let expectedScheme = searchScheme else { return true }
        let requestedScheme = scope.scheme?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let requestedScheme, requestedScheme != expectedScheme { return false }
        guard let expectedPort = searchPort else { return true }
        if let requestedPort = scope.port {
            return requestedPort == expectedPort
        }
        if let requestedScheme {
            let defaultPort = requestedScheme == "https" ? 443
                : requestedScheme == "http" ? 80 : -1
            return defaultPort == expectedPort
        }
        return true
    }

    private static func normalizedOperationPaths(_ paths: Set<String>) -> Set<String> {
        var normalized = Set<String>()
        for path in paths {
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            normalized.insert(ModelGatewayCredentialRouting.normalizedPath(trimmed))
        }
        return normalized
    }

    private static func bareHost(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let separator = value.range(of: "://") { value = String(value[separator.upperBound...]) }
        if let slash = value.firstIndex(of: "/") { value = String(value[..<slash]) }
        if let colon = value.lastIndex(of: ":"), value.filter({ $0 == ":" }).count == 1,
           value[value.index(after: colon)...].allSatisfy(\.isNumber) {
            value = String(value[..<colon])
        }
        return value
    }
}
