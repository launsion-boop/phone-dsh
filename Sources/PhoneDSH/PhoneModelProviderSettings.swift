// SPDX-License-Identifier: MIT
// phone-dsh host SDK — user-editable model/API/provider configuration.
//
// Provider definitions are non-secret and live in one UserDefaults JSON
// document. The API key never enters that document: each profile names a
// Keychain account (`credentialRef`) and only the secret store sees the value.
// The selected profile produces both the host credential provider and the
// non-secret Worker environment (`PDSH_MODEL_PROVIDER_JSON`) the Web settings
// page projects read-only.

#if canImport(Security)
import Security
#endif
import Foundation
import PhoneDSHAgentCore
import PhoneDSHGateway

/// One model service the phone can send model traffic to.
///
/// The id is the stable identity in the stored document; `credentialRef` is the
/// Keychain account that holds this profile's API key. Neither field is a
/// secret by itself, and the key is never part of a profile value.
public struct ProviderModelDefinition: Codable, Equatable, Sendable {
    public var id: String
    public var name: String?
    public var contextWindow: Int?
    public var maxTokens: Int?
    public var textInput: Bool
    public var imageInput: Bool
    public var reasoningEffort: String?

    public init(id: String, name: String? = nil, contextWindow: Int? = nil, maxTokens: Int? = nil,
                textInput: Bool = true, imageInput: Bool = false, reasoningEffort: String? = nil) {
        self.id = id
        self.name = name
        self.contextWindow = contextWindow
        self.maxTokens = maxTokens
        self.textInput = textInput
        self.imageInput = imageInput
        self.reasoningEffort = reasoningEffort
    }
}

public struct ProviderProfile: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var displayName: String
    public var baseURL: String
    public var model: String
    public var reasoningEffort: String?
    public var credentialRef: String
    public var models: [ProviderModelDefinition]?

    public var modelDefinitions: [ProviderModelDefinition] {
        models ?? [ProviderModelDefinition(id: model, reasoningEffort: reasoningEffort)]
    }

    public init(id: String,
                displayName: String,
                baseURL: String,
                model: String,
                reasoningEffort: String? = nil,
                credentialRef: String? = nil,
                models: [ProviderModelDefinition]? = nil) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.model = model
        self.reasoningEffort = reasoningEffort
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        self.credentialRef = credentialRef ?? "provider.\(trimmedID.isEmpty ? "default" : trimmedID)"
        self.models = models
    }

    /// Parsed endpoint, or nil when the stored value is not a valid HTTP(S)
    /// endpoint. This mirrors `normalized` so a legacy value preserved only for
    /// repair fails closed everywhere: no userinfo, query or fragment may be
    /// published to the Worker or receive the key.
    public var endpointURL: URL? {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
        return url
    }

    /// Gateway host rule for this endpoint: scheme, host and explicit port.
    /// A scheme's default port is omitted because URL normalization removes it
    /// from the Worker's target URL; keeping `:443`/`:80` here would make the
    /// gateway reject the profile's own model requests.
    public var allowedModelHost: String? {
        guard let url = endpointURL, let scheme = url.scheme?.lowercased(), let host = url.host else { return nil }
        let defaultPort = scheme == "https" ? 443 : 80
        if let port = url.port, port != defaultPort { return "\(scheme)://\(host):\(port)" }
        return "\(scheme)://\(host)"
    }

    /// Bare host used by the credential provider's scope matching.
    public var modelHost: String? { endpointURL?.host?.lowercased() }
}

/// The non-secret shape published to the Worker's read-only settings tab.
///
/// Deliberately excludes `credentialRef` and every field that could hold a
/// secret. The Web page only needs to describe the active service.
private struct PublicProviderProfile: Codable, Equatable, Sendable {
    let id: String
    let displayName: String
    let baseURL: String
    let model: String
    let models: [ProviderModelDefinition]
    let reasoningEffort: String?

    init(_ profile: ProviderProfile) {
        self.id = profile.id
        self.displayName = profile.displayName
        self.baseURL = profile.baseURL
        self.model = profile.model
        self.models = profile.modelDefinitions
        self.reasoningEffort = profile.reasoningEffort
    }
}

private struct PublicProviderDocument: Codable, Equatable, Sendable {
    let version: Int
    let selectedId: String?
    let providers: [PublicProviderProfile]

    init(selectedId: String?, profiles: [ProviderProfile]) {
        self.version = 1
        self.selectedId = selectedId
        self.providers = profiles.map(PublicProviderProfile.init)
    }
}

private struct StoredProviderDocument: Codable, Equatable, Sendable {
    var version: Int
    var selectedId: String?
    var providers: [ProviderProfile]
}

/// One atomic read of the stored provider document.
public struct ModelProviderSettingsSnapshot: Equatable, Sendable {
    public var profiles: [ProviderProfile]
    public var selectedID: String?

    public init(profiles: [ProviderProfile] = [], selectedID: String? = nil) {
        self.profiles = profiles
        self.selectedID = selectedID
    }

    /// The selected profile; the first profile is the implicit default when the
    /// document predates explicit selection.
    public var selected: ProviderProfile? {
        if let selectedID, let profile = profiles.first(where: { $0.id == selectedID }) { return profile }
        return profiles.first
    }
}

/// Host-side values a caller applies to `PhoneDSHConfiguration` before start.
///
/// `credentialProvider` is the only place the real Keychain value is read; the
/// environment contains non-secret endpoint/model metadata only.
public struct ModelProviderLaunchPlan {
    public var allowedModelHosts: Set<String>
    public var credentialProvider: any CredentialProvider
    public var environment: [String: String]

    public init(allowedModelHosts: Set<String> = [],
                credentialProvider: any CredentialProvider = StaticCredentialProvider([:]),
                environment: [String: String] = [:]) {
        self.allowedModelHosts = allowedModelHosts
        self.credentialProvider = credentialProvider
        self.environment = environment
    }
}

/// What the native editor intends to do with a profile's stored key.
///
/// `.unreadable` on the status below is deliberately absent here: a caller that
/// cannot read the current key must not guess "missing" and must not offer
/// replace/delete, so it always uses `.keep`.
public enum ModelProviderSecretIntent: Equatable, Sendable {
    case keep
    case replace(String)
    case delete

    /// The `apiKey:` argument the settings store expects for this intent.
    public var apiKeyArgument: String? {
        switch self {
        case .keep: return nil
        case .replace(let key): return key
        case .delete: return ""
        }
    }
}

/// Whether a profile's API key is present, absent, or cannot be read.
///
/// The third state exists so the native page can refuse to overwrite or delete
/// a credential when the Keychain read failed for a transient or device-locked
/// reason; "unreadable" is not "no key".
public enum ModelProviderAPIKeyStatus: Equatable, Sendable {
    case missing
    case present
    case unreadable
}

/// Errors raised while validating, persisting or resolving a provider.
public enum ModelProviderSettingsError: Error, LocalizedError, Equatable, Sendable {
    case emptyID
    case invalidID(String)
    case emptyDisplayName
    case emptyModel
    case invalidBaseURL(String)
    case unknownProvider(String)
    case duplicateProviderID(String)
    case invalidStoredDocument(String)
    case noSelectedProvider
    case keychainUnavailable
    case keychain(Int32)

    public var errorDescription: String? {
        switch self {
        case .emptyID: return "服务标识不能为空"
        case .invalidID(let id): return "服务标识不能包含空白或控制字符：\(id)"
        case .emptyDisplayName: return "请填写服务名称"
        case .emptyModel: return "请填写模型名称"
        case .invalidBaseURL(let value): return "服务 URL 必须是带主机名的 http(s) 地址：\(value)"
        case .unknownProvider(let id): return "没有找到服务：\(id)"
        case .duplicateProviderID(let id): return "服务标识重复：\(id)"
        case .invalidStoredDocument(let reason): return "已保存的模型配置无效：\(reason)"
        case .noSelectedProvider: return "尚未选择模型服务"
        case .keychainUnavailable: return "此设备无法使用钥匙串"
        case .keychain(let status): return "无法访问钥匙串（错误 \(status)）。请重启 App 后重试，或直接输入新密钥覆盖。"
        }
    }
}

/// Where a profile's API key is stored. The production implementation is the
/// device Keychain; tests inject an in-memory store so they never touch it.
public protocol ModelProviderSecretStore: Sendable {
    func secret(for reference: String) throws -> String?
    func setSecret(_ secret: String, for reference: String) throws
    func deleteSecret(for reference: String) throws
}

/// Device-only Keychain store using the same accessibility class as the chat
/// settings it replaces: `AfterFirstUnlockThisDeviceOnly`.
public struct KeychainModelProviderSecretStore: ModelProviderSecretStore {
    public let service: String

    public init(service: String = "dev.phone-dsh.probe.chat") {
        self.service = service
    }

    private func query(for reference: String) -> [String: Any] {
        #if canImport(Security)
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: reference]
        #else
        return [:]
        #endif
    }

    public func secret(for reference: String) throws -> String? {
        #if canImport(Security)
        var query = query(for: reference)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw ModelProviderSettingsError.keychain(status)
        }
        return String(decoding: data, as: UTF8.self)
        #else
        throw ModelProviderSettingsError.keychainUnavailable
        #endif
    }

    public func setSecret(_ secret: String, for reference: String) throws {
        #if canImport(Security)
        if secret.isEmpty {
            try deleteSecret(for: reference)
            return
        }
        let data = Data(secret.utf8)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(query(for: reference) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(for: reference)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(add as CFDictionary, nil)
            guard added == errSecSuccess || added == errSecDuplicateItem else {
                throw ModelProviderSettingsError.keychain(added)
            }
        } else if status != errSecSuccess {
            throw ModelProviderSettingsError.keychain(status)
        }
        #else
        throw ModelProviderSettingsError.keychainUnavailable
        #endif
    }

    public func deleteSecret(for reference: String) throws {
        #if canImport(Security)
        let status = SecItemDelete(query(for: reference) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ModelProviderSettingsError.keychain(status)
        }
        #else
        throw ModelProviderSettingsError.keychainUnavailable
        #endif
    }
}

/// The configured model origin: scheme, lowercased host and effective port.
/// A provider uses it to prove that a credential lookup is for the endpoint
/// the user configured, not merely for another path or port on the same host.
private struct ModelProviderEndpointOrigin: Equatable, Sendable {
    let scheme: String
    let host: String
    let port: Int

    init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        self.scheme = scheme
        self.host = host
        self.port = url.port ?? (scheme == "https" ? 443 : 80)
    }

    /// Match a gateway scope. A scope with no scheme or port predates the
    /// origin extension and can only be checked by host/path, so it stays
    /// compatible; whenever either field is present it must agree, including
    /// the scheme's default port when `port` itself is omitted.
    func matches(_ scope: CredentialScope) -> Bool {
        guard ModelProviderCredentialProvider.bareHost(scope.service) == host else { return false }
        if let rawScheme = scope.scheme {
            let requested = rawScheme.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard requested == scheme else { return false }
        }
        if let requestedPort = scope.port {
            guard requestedPort == port else { return false }
        } else if let rawScheme = scope.scheme {
            let requested = rawScheme.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let defaultPort = requested == "https" ? 443 : requested == "http" ? 80 : -1
            guard defaultPort == port else { return false }
        }
        return true
    }
}

/// The concrete operation paths a configured model base can produce for the
/// protocols DSH ships. The base is a prefix, not an arbitrary host: Anthropic
/// Messages places resources below `base[/v1]`, OpenAI-compatible protocols
/// append their operation below the configured base, and the account/listing
/// route uses `/models` at the origin. Search/Fetch has its own router and is
/// deliberately absent here.
private struct ModelProviderEndpointPaths: Equatable, Sendable {
    private let exact: Set<String>
    private let prefixes: [String]

    init(basePath: String) {
        let base = ModelGatewayCredentialRouting.normalizedPath(basePath)
        let root: String
        if base == "/" {
            root = "/v1"
        } else if base.hasSuffix("/v1") {
            root = base
        } else {
            root = base + "/v1"
        }

        var exact: Set<String> = [
            // Anthropic Messages/Models/Files (the version is not duplicated
            // when the configured base already ends in /v1).
            root + "/messages",
            root + "/messages/count_tokens",
            root + "/models",
            root + "/files",
            // OpenAI-compatible chat, legacy completions and Responses.
            base + "/chat/completions",
            base + "/completions",
            base + "/responses",
            base + "/models",
            // Account/listing route at the origin (DSH's DeepSeek account
            // catalog reads `GET /models` regardless of the Messages prefix).
            "/models",
        ]
        // A base that is already `/v1` makes the Anthropic and OpenAI entries
        // identical; the Set handles that without special-casing a vendor.
        // Prefixes are matched one path segment at a time below, so they are
        // stored without the trailing separator that `normalizedPath` removes.
        // An exact operation route stays in `exact`; a prefix only admits its
        // own descendants, never a sibling whose name merely starts with it.
        var prefixes: Set<String> = [
            root + "/files",
            root + "/models",
            base + "/files",
            base + "/models",
            base + "/responses",
            "/models",
        ]
        exact = Set(exact.map { ModelGatewayCredentialRouting.normalizedPath($0) })
        prefixes = Set(prefixes.map { ModelGatewayCredentialRouting.normalizedPath($0) })
        self.exact = exact
        self.prefixes = prefixes.sorted()
    }

    func admits(_ rawPath: String) -> Bool {
        let path = ModelGatewayCredentialRouting.normalizedPath(rawPath)
        if exact.contains(path) { return true }
        // `/v1/models/deepseek` is below the models route, while
        // `/v1/models-mcp` and `/v1/filesystem` are different operations.
        return prefixes.contains { path.hasPrefix($0 + "/") }
    }
}

/// Resolves the selected profile's key only for the configured model origin
/// and a real model-protocol operation path. Allow-listed egress hosts receive
/// no credential; a same-host path/port that is not the model endpoint also
/// receives no model key (it can still proceed anonymously), and every other
/// host is refused.
public struct ModelProviderCredentialProvider: CredentialProvider, Sendable {
    private let modelHost: String
    private let modelOrigin: ModelProviderEndpointOrigin?
    private let modelPaths: ModelProviderEndpointPaths
    private let credentialRef: String
    private let secrets: any ModelProviderSecretStore
    private let anonymousHosts: Set<String>
    /// True only for the deprecated initializer shape without a parsed model
    /// endpoint. Production always supplies `modelEndpoint`, so its provider
    /// has no host-only fallback that could re-open the MCP path leak.
    private let allowsLegacyHostOnlyLookup: Bool

    /// - Parameter modelEndpoint: the selected profile's base URL. When it is
    ///   present, the key is scoped to its scheme/host/port and the protocol
    ///   paths derived from its base path. Callers that only have a bare host
    ///   keep the old initializer shape and its host-only lookup; the gateway
    ///   and `makeCredentialProvider` always pass the parsed endpoint.
    public init(modelHost: String,
                credentialRef: String,
                secretStore: any ModelProviderSecretStore,
                egressAllowHosts: Set<String>,
                modelEndpoint: URL? = nil) {
        self.modelOrigin = modelEndpoint.flatMap(ModelProviderEndpointOrigin.init)
        self.modelHost = self.modelOrigin?.host
            ?? ModelProviderCredentialProvider.bareHost(modelHost)
        self.modelPaths = ModelProviderEndpointPaths(basePath: modelEndpoint?.path ?? "/")
        self.allowsLegacyHostOnlyLookup = modelEndpoint == nil
        self.credentialRef = credentialRef
        self.secrets = secretStore
        self.anonymousHosts = Set(egressAllowHosts.map(Self.bareHost))
    }

    public func credential(for scope: CredentialScope) async throws -> Credential {
        let host = Self.bareHost(scope.service)
        if host == modelHost {
            // A scope that carries no path, scheme or port is the pre-scope
            // compatibility shape used by the deprecated host-only
            // initializer. A provider built from a configured endpoint must
            // never release the model key without a proven path and origin.
            if scope.audience == nil, scope.scheme == nil, scope.port == nil {
                return allowsLegacyHostOnlyLookup ? try modelCredential() : Credential.none
            }
            let originMatches = modelOrigin?.matches(scope) ?? true
            guard let audience = scope.audience,
                  modelPaths.admits(audience),
                  originMatches else {
                // The gateway admitted this origin because it is a model or
                // egress host, but this is not a model-protocol request. Never
                // turn a same-host MCP/other path into a model-key request.
                return Credential.none
            }
            return try modelCredential()
        }
        if anonymousHosts.contains(where: { Self.entryAdmits($0, host: host) }) {
            return Credential.none
        }
        throw ProviderError.unauthorized("host \(scope.service) is not on the configured allow-list")
    }

    public func invalidate(_ credential: Credential, for scope: CredentialScope) async {}

    private func modelCredential() throws -> Credential {
        guard let key = try secrets.secret(for: credentialRef), !key.isEmpty else {
            throw ProviderError.unauthorized("no model API key is configured on this phone")
        }
        return Credential(kind: .apiKey(header: "x-api-key"), value: key)
    }

    /// Same wildcard grammar as the gateway: `*` admits every host,
    /// `*.example.com` the apex and its subdomains, anything else exactly.
    public static func entryAdmits(_ entry: String, host: String) -> Bool {
        if entry == "*" { return true }
        if entry.hasPrefix("*.") {
            let suffix = String(entry.dropFirst(2))
            return !suffix.isEmpty && (host == suffix || host.hasSuffix("." + suffix))
        }
        return entry == host
    }

    public static func bareHost(_ raw: String) -> String {
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

/// The host's provider catalog: load/upsert/remove/select over one UserDefaults
/// document, with API keys delegated to a Keychain-backed secret store.
///
/// The store is the migration point for the pre-provider document as well:
/// the old `chat.model.baseURL`/`chat.model.name` defaults, the
/// `model-api-key` Keychain account and the `PDSH_MODEL_*` launch environment
/// become one default profile on the first load. The key is copied to the
/// normal `provider.default` account before the document commits, and the old
/// account is removed only afterwards, so an interrupted migration always
/// keeps a complete copy of the key.
public final class PhoneModelProviderSettings {
    /// UserDefaults key for the non-secret provider document.
    public static let defaultsKey = "phone-dsh.model-providers.v1"
    /// Worker environment variable carrying the read-only provider projection.
    public static let workerEnvironmentKey = "PDSH_MODEL_PROVIDER_JSON"
    /// Worker environment variable carrying the official Messages-search base.
    /// It derives from the selected model service, so search uses the same host
    /// and Keychain credential instead of a second secret or endpoint.
    public static let searchBaseURLEnvironmentKey = "DEEPSEEK_SEARCH_BASE_URL"
    /// Process-wide store used by the app; tests construct their own.
    public static let shared = PhoneModelProviderSettings()

    /// Accounts that are no longer referenced by the committed document. A
    /// crash between the document write and the Keychain delete leaves an
    /// orphan here; the next load removes it. This sidecar never contains a key.
    static let pendingSecretDeletionsKey = "phone-dsh.model-providers.pending-deletions"

    /// Pre-provider persistence, kept only so an upgrade preserves the user's
    /// existing endpoint, model and key.
    static let legacyBaseURLKey = "chat.model.baseURL"
    static let legacyModelKey = "chat.model.name"
    static let legacyCredentialRef = "model-api-key"

    private static let fallbackBaseURL = "https://api.deepseek.com/anthropic"
    private static let fallbackModel = "deepseek-flash"
    /// Account the first migration writes the legacy key to before the new
    /// document commits. The no-document recovery path must protect it as
    /// well, because a crash can happen after that write and before the commit.
    private static let migrationTargetCredentialRef = "provider.default"

    private let defaults: UserDefaults
    private let secrets: any ModelProviderSecretStore
    private let environment: [String: String]

    public init(defaults: UserDefaults = .standard,
                secretStore: any ModelProviderSecretStore = KeychainModelProviderSecretStore(),
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.defaults = defaults
        self.secrets = secretStore
        self.environment = environment
    }

    /// Read and validate the stored document.
    ///
    /// A missing document is migrated from the legacy defaults/Keychain/env
    /// once; if the old key cannot be read or the migration cannot write its
    /// new state, the legacy profile is still returned so an existing install
    /// keeps its endpoint and key. When the stored legacy endpoint cannot be
    /// normalized, the raw values are returned uncommitted so the user can
    /// repair them without the key being migrated to an unrelated host.
    public func load() throws -> ModelProviderSettingsSnapshot {
        if defaults.data(forKey: Self.defaultsKey) != nil {
            let snapshot = try decodeStoredDocument()
            flushPendingSecretDeletions(referencedBy: snapshot)
            return snapshot
        }
        guard let legacy = legacyConfiguration() else {
            // There is no document and no legacy source at all: no old
            // defaults/env values and the legacy Keychain account really does
            // not exist (a thrown read error is reported as `keyReadFailed`
            // above). Any pending account was therefore written by an
            // interrupted first create (the secret is written before the
            // document), so it is an orphan: reconcile it even on this
            // no-document path instead of waiting for a future document write.
            flushPendingSecretDeletions(referencedBy: ModelProviderSettingsSnapshot())
            return ModelProviderSettingsSnapshot()
        }
        // A failed Keychain read is not "there is no key". Do not migrate or
        // delete the legacy defaults/account until the old account can be read
        // again; keep returning the legacy profile meanwhile.
        guard !legacy.keyReadFailed else {
            return legacy.fallbackSnapshot
        }
        // `requiresRepair` covers legacy values that exist but cannot be
        // normalized (for example an old settings page saved an arbitrary base
        // URL). The migration cannot succeed, but the old account and values
        // are still the user's only copy. Return them without writing a
        // document, and reconcile only genuinely orphaned accounts: never the
        // legacy account or the account a migration would target.
        guard !legacy.requiresRepair else {
            flushPendingSecretDeletions(
                referencedBy: legacy.fallbackSnapshot,
                protecting: [Self.legacyCredentialRef, Self.migrationTargetCredentialRef])
            return legacy.fallbackSnapshot
        }
        do {
            return try migrateLegacyConfiguration(legacy)
        } catch {
            // The document was not committed. Keep the old account usable and
            // let the next load retry; never delete the legacy key here.
            return legacy.fallbackSnapshot
        }
    }

    /// Insert a new profile, refusing an id that is already stored.
    ///
    /// `upsert` intentionally replaces an existing id for edits. The add-service
    /// path must not use it: a typed duplicate id would otherwise replace
    /// another profile's endpoint/model while reusing (or orphaning) its key.
    @discardableResult
    public func create(_ profile: ProviderProfile, apiKey: String? = nil) throws -> ProviderProfile {
        let normalizedProfile = try normalized(profile)
        if try load().profiles.contains(where: { $0.id == normalizedProfile.id }) {
            throw ModelProviderSettingsError.duplicateProviderID(normalizedProfile.id)
        }
        return try upsert(normalizedProfile, apiKey: apiKey)
    }

    /// Insert or replace one profile by id, optionally replacing its key.
    ///
    /// - Parameters:
    ///   - profile: the profile to validate and persist.
    ///   - apiKey: a replacement key, `nil` to keep the current one, or the empty
    ///     string to delete it. The key is written only to the secret store.
    /// - Returns: the validated profile as stored.
    ///
    /// When `credentialRef` changes and `apiKey` is `nil`, the current secret
    /// is copied from the old account to the new one before the document
    /// commits, so "keep the current one" does not lose it.
    ///
    /// A replacement key is written before the document, so a failed document
    /// write can restore the previous secret and never loses the old key. A
    /// key deletion is applied after the document, so a crash leaves an extra
    /// secret rather than a document pointing at a deleted key. A replaced
    /// credential account is deleted only after the new document commits; if
    /// that delete fails it becomes a pending orphan removed by a later load.
    @discardableResult
    public func upsert(_ profile: ProviderProfile, apiKey: String? = nil) throws -> ProviderProfile {
        let normalizedProfile = try normalized(profile)
        var snapshot = try load()
        let previous = snapshot.profiles.first(where: { $0.id == normalizedProfile.id })
        let referencedBefore = Set(snapshot.profiles.map(\.credentialRef))
        if let index = snapshot.profiles.firstIndex(where: { $0.id == normalizedProfile.id }) {
            snapshot.profiles[index] = normalizedProfile
        } else {
            snapshot.profiles.append(normalizedProfile)
        }
        if snapshot.selectedID == nil { snapshot.selectedID = normalizedProfile.id }
        // The snapshot may still carry the raw legacy profile from a pending
        // repair. Reject it before writing any secret: a document write would
        // otherwise fail and force a rollback of the new key.
        try validate(snapshot)

        let targetRef = normalizedProfile.credentialRef
        let replacement = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let movedFromRef: String? = {
            guard let previous, previous.credentialRef != targetRef else { return nil }
            return previous.credentialRef
        }()

        var pending = pendingSecretDeletions()
        if let movedFromRef {
            pending.insert(movedFromRef)
        }
        // A key written to an account the current document does not reference
        // yet would be an orphan if this process dies before the document
        // write. Record it first; a committed profile clears it.
        let willWriteTarget = (replacement?.isEmpty == false) || movedFromRef != nil
        if willWriteTarget, !referencedBefore.contains(targetRef) {
            pending.insert(targetRef)
        }
        savePendingSecretDeletions(pending)

        var previousSecret: SecretSnapshot?
        if let replacement, !replacement.isEmpty {
            previousSecret = SecretSnapshot(reference: targetRef,
                                            value: try secrets.secret(for: targetRef))
            try secrets.setSecret(replacement, for: targetRef)
        } else if let movedFromRef {
            // `apiKey == nil` keeps the current secret. A credential-ref change
            // moves that secret to the new account before the document points
            // at it; a read/write failure aborts with the old document intact.
            let movedSecret = try secrets.secret(for: movedFromRef)
            if let movedSecret, !movedSecret.isEmpty {
                previousSecret = SecretSnapshot(reference: targetRef,
                                                value: try secrets.secret(for: targetRef))
                try secrets.setSecret(movedSecret, for: targetRef)
            }
        }
        do {
            try persist(snapshot)
        } catch {
            if let previousSecret { restoreSecret(previousSecret) }
            throw error
        }

        var cleanupError: Error?
        if let replacement, replacement.isEmpty {
            do {
                try secrets.deleteSecret(for: targetRef)
            } catch {
                // The profile change is already committed. Surface the failed
                // key deletion so the user can retry instead of believing the
                // key is gone.
                cleanupError = error
            }
        }
        flushPendingSecretDeletions(referencedBy: snapshot)
        if let cleanupError { throw cleanupError }
        return normalizedProfile
    }

    /// Remove one profile and its Keychain item. The selection falls back to the
    /// first remaining profile.
    ///
    /// The document is committed before the secret is deleted. If the process
    /// dies or the Keychain delete fails, the only leftover is an unreferenced
    /// key, which `load()` reconciles from the pending-orphan sidecar. A crash
    /// can therefore never leave a profile pointing at a deleted key.
    public func remove(id: String) throws {
        var snapshot = try load()
        guard let index = snapshot.profiles.firstIndex(where: { $0.id == id }) else {
            throw ModelProviderSettingsError.unknownProvider(id)
        }
        let removed = snapshot.profiles.remove(at: index)
        if snapshot.selectedID == removed.id { snapshot.selectedID = snapshot.profiles.first?.id }
        markPendingSecretDeletions([removed.credentialRef])
        try persist(snapshot)
        flushPendingSecretDeletions(referencedBy: snapshot)
    }

    /// Make an existing profile the default for the next host start.
    public func select(id: String) throws {
        var snapshot = try load()
        guard snapshot.profiles.contains(where: { $0.id == id }) else {
            throw ModelProviderSettingsError.unknownProvider(id)
        }
        snapshot.selectedID = id
        try persist(snapshot)
    }

    /// The stored profile with this id, validated.
    public func profile(id: String) throws -> ProviderProfile {
        guard let profile = try load().profiles.first(where: { $0.id == id }) else {
            throw ModelProviderSettingsError.unknownProvider(id)
        }
        return profile
    }

    /// Read the key for one profile. Callers must not log or persist the value.
    public func apiKey(for id: String) throws -> String? {
        let profile = try profile(id: id)
        return try secrets.secret(for: profile.credentialRef)
    }

    /// Whether a non-empty key exists, without exposing the value.
    ///
    /// A Keychain read failure is thrown, not reported as `false`: callers that
    /// only need a presence indicator for UI should use `apiKeyStatus(for:)`,
    /// which keeps "no key" and "cannot read the key" distinct.
    public func hasAPIKey(for id: String) throws -> Bool {
        guard let key = try apiKey(for: id) else { return false }
        return !key.isEmpty
    }

    /// Three-state key presence for the configuration UI.
    ///
    /// `.unreadable` means the store failed; it is never collapsed into
    /// `.missing`, because replacing or deleting a key that may still exist
    /// would destroy the user's credential.
    public func apiKeyStatus(for id: String) throws -> ModelProviderAPIKeyStatus {
        let profile = try profile(id: id)
        do {
            guard let key = try secrets.secret(for: profile.credentialRef), !key.isEmpty else {
                return .missing
            }
            return .present
        } catch {
            return .unreadable
        }
    }

    /// Resolve what the editor's key fields mean on save.
    ///
    /// A typed/imported key always wins over a delete toggle that was left on
    /// while the user entered a replacement; the payload and the store therefore
    /// follow one rule instead of silently discarding the new key.
    public static func secretIntent(enteredKey: String,
                                    deleteStoredKey: Bool) -> ModelProviderSecretIntent {
        let trimmed = enteredKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return .replace(trimmed) }
        if deleteStoredKey { return .delete }
        return .keep
    }

    /// Delete one profile's key while keeping the profile selectable.
    public func removeAPIKey(for id: String) throws {
        let profile = try profile(id: id)
        try secrets.deleteSecret(for: profile.credentialRef)
    }

    /// Build a provider that injects no model key but still admits the
    /// configured anonymous egress hosts. The app uses it before any profile
    /// is configured, so the complete Web surface can boot and public fetches
    /// keep working while model requests fail closed.
    public func makeEgressOnlyCredentialProvider(egressAllowHosts: Set<String> = []) -> any CredentialProvider {
        ModelProviderCredentialProvider(modelHost: "",
                                        credentialRef: "",
                                        secretStore: secrets,
                                        egressAllowHosts: egressAllowHosts)
    }

    /// Build the origin- and path-scoped credential provider for the selected
    /// profile. The profile's parsed endpoint carries the scheme, host, port
    /// and base path the provider needs; a profile that cannot produce one
    /// fails here instead of falling back to a bare-host credential.
    public func makeCredentialProvider(egressAllowHosts: Set<String> = []) throws -> any CredentialProvider {
        let profile = try selectedProfile()
        guard let host = profile.modelHost, let endpoint = profile.endpointURL else {
            throw ModelProviderSettingsError.invalidBaseURL(profile.baseURL)
        }
        return ModelProviderCredentialProvider(modelHost: host,
                                               credentialRef: profile.credentialRef,
                                               secretStore: secrets,
                                               egressAllowHosts: egressAllowHosts,
                                               modelEndpoint: endpoint)
    }

    /// Non-secret Worker environment entries for the selected profile.
    ///
    /// `PDSH_MODEL_PROVIDER_JSON` contains ids, display names, endpoints and
    /// model ids only; the API key and its Keychain account never appear here.
    public func environmentEntries() throws -> [String: String] {
        let snapshot = try load()
        guard let profile = snapshot.selected else {
            throw ModelProviderSettingsError.noSelectedProvider
        }
        guard let url = profile.endpointURL else {
            throw ModelProviderSettingsError.invalidBaseURL(profile.baseURL)
        }
        let document = PublicProviderDocument(selectedId: profile.id, profiles: snapshot.profiles)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(document)
        guard let json = String(data: data, encoding: .utf8) else {
            throw ModelProviderSettingsError.invalidStoredDocument("provider projection is not UTF-8")
        }
        var environment = [
            "DEEPSEEK_BASE_URL": url.absoluteString,
            "PDSH_MODEL_NAME": profile.model,
            Self.workerEnvironmentKey: json,
        ]
        if let searchBase = Self.searchBaseURL(for: url) {
            environment[Self.searchBaseURLEnvironmentKey] = searchBase
        }
        return environment
    }

    /// The official Messages-search base for a selected model endpoint.
    ///
    /// The search provider appends `/messages` and its shipped default is the
    /// model provider's base plus `/v1`. Deriving the same relation for the
    /// selected profile keeps one host/credential authority: the Worker sends
    /// the placeholder through the host `/v1/http` route and the gateway
    /// injects the real Keychain key for that host. A path already ending in
    /// `/v1` is reused; otherwise `/v1` is appended.
    static func searchBaseURL(for modelBaseURL: URL) -> String? {
        guard var components = URLComponents(url: modelBaseURL,
                                             resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty else { return nil }
        var path = components.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        if !path.hasSuffix("/v1") {
            path += "/v1"
        }
        components.path = path
        components.query = nil
        components.fragment = nil
        return components.string
    }

    /// Apply the selected profile's non-secret Worker environment in place.
    public func apply(to environment: inout [String: String]) throws {
        environment.merge(try environmentEntries()) { _, new in new }
    }

    /// Apply the full host launch plan (allow-list, credential provider and
    /// non-secret Worker environment) for the selected profile.
    public func apply(to plan: inout ModelProviderLaunchPlan,
                      egressAllowHosts: Set<String> = []) throws {
        let profile = try selectedProfile()
        guard let rule = profile.allowedModelHost else {
            throw ModelProviderSettingsError.invalidBaseURL(profile.baseURL)
        }
        plan.allowedModelHosts = [rule]
        plan.credentialProvider = try makeCredentialProvider(egressAllowHosts: egressAllowHosts)
        plan.environment = try environmentEntries()
    }

    // MARK: - Legacy migration

    /// The legacy values and the profile they become on the first load.
    private struct LegacyConfiguration {
        /// The committed profile: a normal `provider.<id>` Keychain account.
        let snapshot: ModelProviderSettingsSnapshot
        /// What `load()` returns if the new document cannot be committed. It
        /// keeps pointing at the old account so an existing install still has
        /// its key.
        let fallbackSnapshot: ModelProviderSettingsSnapshot
        let apiKey: String?
        /// True when the legacy Keychain account could not be read. The profile
        /// may still be usable with the old account, but migrating now would
        /// drop its key, so `load()` must not commit anything.
        let keyReadFailed: Bool
        /// True when legacy values exist but cannot be normalized (typically a
        /// base URL the old settings page saved without validation). There is
        /// nothing safe to migrate, but the old values and account must be
        /// returned untouched so the user's key survives for a later repair.
        let requiresRepair: Bool
    }

    /// Build the migration snapshot without mutating any store.
    ///
    /// The key is copied to the normal `provider.default` account only after
    /// the old account was read. The old account is deleted by the pending
    /// orphan reconciliation after the new document commits, so an interrupted
    /// migration always leaves at least one complete copy of the key.
    private func legacyConfiguration() -> LegacyConfiguration? {
        let legacyBaseURL = nonEmpty(defaults.string(forKey: Self.legacyBaseURLKey))
        let legacyModel = nonEmpty(defaults.string(forKey: Self.legacyModelKey))
        let envBaseURL = nonEmpty(environment["PDSH_MODEL_BASE_URL"])
        let envModel = nonEmpty(environment["PDSH_MODEL_NAME"])
        let envKey = nonEmpty(environment["PDSH_MODEL_API_KEY"])

        var storedKey: String?
        var keyReadFailed = false
        do {
            storedKey = try secrets.secret(for: Self.legacyCredentialRef)
        } catch {
            // nil from the store means "not found"; a thrown error means the
            // old account may still hold a key we cannot see. Never fall back
            // to the environment key (which could replace the account) and
            // never commit a migration that would orphan the stored key.
            keyReadFailed = true
        }
        let key: String? = keyReadFailed ? nil : (nonEmpty(storedKey) ?? envKey)

        let baseURL = legacyBaseURL ?? envBaseURL
        let model = legacyModel ?? envModel
        guard keyReadFailed || baseURL != nil || model != nil || key != nil else { return nil }

        let candidate = ProviderProfile(id: "default",
                                        displayName: "默认模型服务",
                                        baseURL: baseURL ?? Self.fallbackBaseURL,
                                        model: model ?? Self.fallbackModel,
                                        reasoningEffort: nil,
                                        credentialRef: Self.migrationTargetCredentialRef)
        guard let profile = try? normalized(candidate) else {
            // Legacy values exist (the guard above passed) but cannot be
            // normalized, usually because the old settings page stored an
            // arbitrary/invalid base URL. Do not fall back to the built-in
            // endpoint: that would point the user's existing key at a host it
            // was never meant for. Return the raw legacy values against the old
            // Keychain account, and let `load()` keep them uncommitted so the
            // key survives until the user repairs the endpoint.
            var preserved = candidate
            preserved.credentialRef = Self.legacyCredentialRef
            let preservedSnapshot = ModelProviderSettingsSnapshot(profiles: [preserved],
                                                                  selectedID: preserved.id)
            return LegacyConfiguration(snapshot: preservedSnapshot,
                                       fallbackSnapshot: preservedSnapshot,
                                       apiKey: key,
                                       keyReadFailed: keyReadFailed,
                                       requiresRepair: true)
        }
        var fallbackProfile = profile
        fallbackProfile.credentialRef = Self.legacyCredentialRef
        return LegacyConfiguration(
            snapshot: ModelProviderSettingsSnapshot(profiles: [profile], selectedID: profile.id),
            fallbackSnapshot: ModelProviderSettingsSnapshot(profiles: [fallbackProfile],
                                                            selectedID: fallbackProfile.id),
            apiKey: key,
            keyReadFailed: keyReadFailed,
            requiresRepair: false)
    }

    /// Commit the legacy profile. The new key is written first; the document
    /// commits next; the old Keychain account is deleted only after both, via
    /// the pending-orphan sidecar. A failure before the commit restores or
    /// removes the new account and leaves the old key untouched.
    private func migrateLegacyConfiguration(_ legacy: LegacyConfiguration) throws -> ModelProviderSettingsSnapshot {
        let profile = legacy.snapshot.profiles[0]
        let targetRef = profile.credentialRef

        if let key = legacy.apiKey {
            let previousPending = pendingSecretDeletions()
            markPendingSecretDeletions([Self.legacyCredentialRef, targetRef])
            let previousNewSecret: String?
            do {
                // A read failure is not "the target account is empty": treating
                // it as empty would make the rollback below delete a key.
                previousNewSecret = try secrets.secret(for: targetRef)
            } catch {
                savePendingSecretDeletions(previousPending)
                throw error
            }
            do {
                try secrets.setSecret(key, for: targetRef)
                try persist(legacy.snapshot)
            } catch {
                if let previousNewSecret {
                    try? secrets.setSecret(previousNewSecret, for: targetRef)
                } else {
                    try? secrets.deleteSecret(for: targetRef)
                }
                // The document was not committed; the legacy account must not
                // stay queued for deletion by an unrelated later write.
                savePendingSecretDeletions(previousPending)
                throw error
            }
            flushPendingSecretDeletions(referencedBy: legacy.snapshot)
        } else {
            try persist(legacy.snapshot)
        }
        return legacy.snapshot
    }

    // MARK: - Validation and persistence

    private func selectedProfile() throws -> ProviderProfile {
        guard let profile = try load().selected else {
            throw ModelProviderSettingsError.noSelectedProvider
        }
        return profile
    }

    /// The value restored if a document write fails after a secret write.
    private struct SecretSnapshot {
        let reference: String
        let value: String?
    }

    private func restoreSecret(_ snapshot: SecretSnapshot) {
        do {
            if let value = snapshot.value {
                try secrets.setSecret(value, for: snapshot.reference)
            } else {
                try secrets.deleteSecret(for: snapshot.reference)
            }
        } catch {
            // Best effort: the caller still receives the original persist
            // error and the document was not replaced.
        }
    }

    private func decodeStoredDocument() throws -> ModelProviderSettingsSnapshot {
        guard let data = defaults.data(forKey: Self.defaultsKey) else {
            return ModelProviderSettingsSnapshot()
        }
        let document: StoredProviderDocument
        do {
            document = try JSONDecoder().decode(StoredProviderDocument.self, from: data)
        } catch {
            throw ModelProviderSettingsError.invalidStoredDocument(error.localizedDescription)
        }
        guard document.version == 1 else {
            throw ModelProviderSettingsError.invalidStoredDocument("unsupported version \(document.version)")
        }
        var seen = Set<String>()
        var profiles: [ProviderProfile] = []
        for raw in document.providers {
            let profile = try normalized(raw)
            guard seen.insert(profile.id).inserted else {
                throw ModelProviderSettingsError.duplicateProviderID(profile.id)
            }
            profiles.append(profile)
        }
        if let selected = document.selectedId, !profiles.contains(where: { $0.id == selected }) {
            throw ModelProviderSettingsError.invalidStoredDocument("selected provider \(selected) does not exist")
        }
        return ModelProviderSettingsSnapshot(profiles: profiles, selectedID: document.selectedId)
    }

    /// A snapshot returned by the repair path keeps a raw, unnormalized legacy
    /// profile so the user can fix it. That is a view, never a document:
    /// committing it would make `decodeStoredDocument()` reject the whole store
    /// on the next load and the user could not repair it.
    private func validate(_ snapshot: ModelProviderSettingsSnapshot) throws {
        for profile in snapshot.profiles {
            _ = try normalized(profile)
        }
    }

    private func persist(_ snapshot: ModelProviderSettingsSnapshot) throws {
        try validate(snapshot)
        let document = StoredProviderDocument(version: 1,
                                              selectedId: snapshot.selectedID,
                                              providers: snapshot.profiles)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        defaults.set(try encoder.encode(document), forKey: Self.defaultsKey)
        // The new document is the authority now. These two fields are never
        // needed again, and removing them makes the migration one-way.
        defaults.removeObject(forKey: Self.legacyBaseURLKey)
        defaults.removeObject(forKey: Self.legacyModelKey)
    }

    // MARK: - Orphan reconciliation

    private func pendingSecretDeletions() -> Set<String> {
        Set(defaults.stringArray(forKey: Self.pendingSecretDeletionsKey) ?? [])
    }

    private func savePendingSecretDeletions(_ references: Set<String>) {
        if references.isEmpty {
            defaults.removeObject(forKey: Self.pendingSecretDeletionsKey)
        } else {
            defaults.set(references.sorted(), forKey: Self.pendingSecretDeletionsKey)
        }
    }

    private func markPendingSecretDeletions(_ references: Set<String>) {
        guard !references.isEmpty else { return }
        savePendingSecretDeletions(pendingSecretDeletions().union(references))
    }

    /// Delete accounts that the committed document no longer references.
    /// Referenced accounts are removed from the pending set without touching
    /// their value; a failed delete stays pending for the next load. Loading
    /// must succeed even when Keychain is temporarily unavailable.
    ///
    /// `protecting` lets the no-document recovery path keep accounts that may
    /// belong to an unfinished legacy migration even though no committed
    /// snapshot references them yet. Only accounts without that ownership
    /// evidence are deleted.
    private func flushPendingSecretDeletions(referencedBy snapshot: ModelProviderSettingsSnapshot,
                                             protecting protectedReferences: Set<String> = []) {
        var pending = pendingSecretDeletions()
        guard !pending.isEmpty else { return }
        let referenced = Set(snapshot.profiles.map(\.credentialRef)).union(protectedReferences)
        pending = pending.filter { reference in
            if referenced.contains(reference) { return false }
            do {
                try secrets.deleteSecret(for: reference)
                return false
            } catch {
                return true
            }
        }
        savePendingSecretDeletions(pending)
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func normalized(_ raw: ProviderProfile) throws -> ProviderProfile {
        let id = raw.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw ModelProviderSettingsError.emptyID }
        guard id.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              id.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw ModelProviderSettingsError.invalidID(id)
        }
        let displayName = raw.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayName.isEmpty else { throw ModelProviderSettingsError.emptyDisplayName }
        let model = raw.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw ModelProviderSettingsError.emptyModel }
        let baseURL = raw.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: baseURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw ModelProviderSettingsError.invalidBaseURL(baseURL)
        }
        let credentialRef = raw.credentialRef.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !credentialRef.isEmpty else {
            throw ModelProviderSettingsError.invalidID("credential reference for \(id) is empty")
        }
        let reasoning = raw.reasoningEffort?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ProviderProfile(id: id,
                               displayName: displayName,
                               baseURL: baseURL,
                               model: model,
                               reasoningEffort: (reasoning?.isEmpty == true) ? nil : reasoning,
                               credentialRef: credentialRef)
    }
}
