// SPDX-License-Identifier: MIT
// phone-dsh host SDK — host-side access and credentials for the Worker's
// Streamable HTTP MCP registry.
//
// The Worker keeps one registry (`/dsh/home/mcp.json`). This module never
// duplicates that registry: it stores the user's explicit exact-origin/path
// grant for one serverName plus the dedicated MCP Keychain values. The gateway
// consults the resulting `MCPEgressPolicy` per request, so adding a server in
// the Web MCP tab does not widen `ChatSettings.egressAllow` or admit `*`.
//
// Header values never enter `mcp.json`, the Worker environment, UserDefaults,
// a report or a log. The Worker only places `phone-host-injects-mcp-key` in a
// host-managed header; `ModelGateway` drops that placeholder and
// `PhoneMCPCredentialProvider` injects the real header for the exact URL.

#if canImport(Security)
import Security
#endif
import Foundation
import PhoneDSHAgentCore
import PhoneDSHGateway

/// One non-secret MCP grant. `headers` contains header names only; values live
/// in the dedicated Keychain account named by `serverName`.
public struct PhoneMCPAccessGrant: Codable, Equatable, Sendable {
    public var serverName: String
    public var url: String
    public var headers: [String]
    /// Non-secret identity of the dedicated Keychain account holding this
    /// grant's header values. `nil` is the legacy account `mcp.<serverName>`.
    /// Rotation writes a fresh account and commits this reference only after
    /// the value exists, so an interrupted write can never move a new token
    /// onto an old URL.
    public var secretID: String?

    public init(serverName: String,
                url: String,
                headers: [String] = [],
                secretID: String? = nil) {
        self.serverName = serverName
        self.url = url
        self.headers = headers
        self.secretID = secretID
    }
}

/// One validated read of the host-side MCP access document.
public struct PhoneMCPAccessSnapshot: Equatable, Sendable {
    public var grants: [PhoneMCPAccessGrant]
    /// Server names whose Keychain value could not be read for status. They are
    /// still fail-closed in the runtime policy.
    public var unreadableSecrets: Set<String>

    public init(grants: [PhoneMCPAccessGrant] = [],
                unreadableSecrets: Set<String> = []) {
        self.grants = grants
        self.unreadableSecrets = unreadableSecrets
    }
}

/// Errors raised while validating or persisting the MCP access document.
public enum PhoneMCPAccessError: Error, LocalizedError, Equatable, Sendable {
    case invalidServerName(String)
    case invalidURL(String)
    case invalidHeader(String)
    case invalidStoredDocument(String)
    case duplicateURL(String)
    case stagedGrantUnresolved(String)
    case secretStore
    case documentStore

    public var errorDescription: String? {
        switch self {
        case .invalidServerName:
            return "MCP 服务器名称无效。只允许 A-Z a-z 0-9 _ -，最长 32 个字符。"
        case .invalidURL:
            return "MCP 地址必须是绝对 http(s) URL，且不能内嵌用户名或密码。"
        case .invalidHeader:
            return "MCP 认证头名称无效。"
        case .invalidStoredDocument:
            return "MCP 访问配置已损坏，无法读取。"
        case .duplicateURL(let existing):
            return "这个精确 MCP 地址已由服务器“\(existing)”使用。请编辑已有服务器，或先移除它再添加新的认证行；同一 URL 不能对应两套密钥。"
        case .stagedGrantUnresolved(let name):
            return "服务器“\(name)”上一次保存的结果尚未确认。请刷新 MCP 列表，确认后再保存。"
        case .secretStore:
            return "无法读取或清理 MCP 密钥。请解锁设备后重试。"
        case .documentStore:
            return "MCP 访问配置未能保存或清理。请重试；旧配置和密钥会保持原样。"
        }
    }
}

/// Build the host launch credential provider and admission policy.
public enum MCPHostConfiguration {
    /// Wrap the model/search provider with the exact MCP router.
    ///
    /// The returned policy must also be installed on
    /// `PhoneDSHConfiguration.egressAuthorizer`; the Web host does this so a
    /// later native/Web grant updates the same live object.
    @discardableResult
    public static func apply(to plan: inout ModelProviderLaunchPlan,
                             settings: PhoneMCPAccessSettings = .shared,
                             policy: MCPEgressPolicy? = nil) -> MCPEgressPolicy {
        let policy = policy ?? MCPEgressPolicy()
        // The App passes the controller's live object so grants/revokes update
        // the same gateway admission and credential router without a restart.
        settings.apply(to: policy)
        plan.credentialProvider = PhoneMCPCredentialProvider(
            policy: policy,
            base: plan.credentialProvider)
        return policy
    }
}

/// Runtime exact-origin/path policy shared by the gateway and the credential
/// router. It starts empty and is updated in place when the user adds, edits
/// or removes an MCP server, so no host restart is needed merely to admit a
/// newly added endpoint.
public final class MCPEgressPolicy: EgressHostAuthorizing, @unchecked Sendable {
    struct Route: Equatable, Sendable {
        var serverName: String
        var scheme: String
        var host: String
        var port: Int?
        var path: String
        var headers: [String: String]
    }

    private let lock = NSLock()
    private var routes: [String: Route] = [:]

    public init() {}

    /// Runtime URLs currently admitted (no header values).
    public var authorizedURLs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return routes.values.sorted { $0.serverName < $1.serverName }.map { Self.urlString($0) }
    }

    public func clear() {
        lock.lock()
        routes.removeAll()
        lock.unlock()
    }

    public func revoke(serverName: String) {
        lock.lock()
        routes.removeValue(forKey: serverName)
        lock.unlock()
    }

    /// One atomically installed route. `headers` carries real values only in
    /// memory; callers must never log this value.
    struct RouteInput: Sendable {
        var serverName: String
        var url: URL
        var headers: [String: String]
    }

    /// Add or replace one server's exact route. A second serverName for the
    /// same scheme/host/port/path is refused: the Worker request carries only
    /// the URL, so two Keychain values for one route would be ambiguous.
    func grant(serverName: String,
               url: URL,
               headers: [String: String]) throws {
        let route = try Self.route(serverName: serverName, url: url, headers: headers)
        let candidate = Candidate(scheme: route.scheme,
                                  host: route.host,
                                  port: route.port,
                                  path: route.path)
        lock.lock()
        defer { lock.unlock() }
        if let existing = routes.values.first(where: {
            $0.serverName != serverName && Self.matches($0, candidate)
        }) {
            throw PhoneMCPAccessError.duplicateURL(existing.serverName)
        }
        routes[serverName] = route
    }

    /// Install a complete snapshot in one lock acquisition. Rebuilding the
    /// document must never expose an intermediate empty route map to a
    /// concurrent gateway request.
    func replaceRoutes(_ inputs: [RouteInput]) {
        var next: [String: Route] = [:]
        for input in inputs.sorted(by: { $0.serverName < $1.serverName }) {
            guard let route = try? Self.route(serverName: input.serverName,
                                              url: input.url,
                                              headers: input.headers) else { continue }
            let candidate = Candidate(scheme: route.scheme,
                                      host: route.host,
                                      port: route.port,
                                      path: route.path)
            // Legacy documents may contain duplicates. The first sorted
            // serverName keeps the route deterministically; new saves are
            // refused before they reach this method.
            if next.values.contains(where: { Self.matches($0, candidate) }) {
                continue
            }
            next[route.serverName] = route
        }
        lock.lock()
        routes = next
        lock.unlock()
    }

    /// Gateway admission: only the configured scheme/host/effective-port/path.
    public func allowsEgressHost(_ url: URL) -> Bool {
        route(for: url) != nil
    }

    func route(for url: URL) -> Route? {
        guard let candidate = Self.candidate(url) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return routes.values
            .sorted { $0.serverName < $1.serverName }
            .first { Self.matches($0, candidate) }
    }

    func route(for scope: CredentialScope) -> Route? {
        guard let scheme = scope.scheme?.lowercased() else { return nil }
        let candidate = Candidate(scheme: scheme,
                                  host: scope.service.lowercased(),
                                  port: Self.effectivePort(explicit: scope.port, scheme: scheme),
                                  path: ModelGatewayCredentialRouting.normalizedPath(
                                    scope.audience ?? "/"))
        lock.lock()
        defer { lock.unlock() }
        return routes.values
            .sorted { $0.serverName < $1.serverName }
            .first { Self.matches($0, candidate) }
    }

    /// Stable non-secret identity of one exact credential scope.
    static func routeKey(for url: URL) -> String? {
        guard let candidate = candidate(url) else { return nil }
        return "\(candidate.scheme)://\(candidate.host):\(candidate.port ?? 0)\(candidate.path)"
    }

    private struct Candidate {
        var scheme: String
        var host: String
        var port: Int?
        var path: String
    }

    private static func candidate(_ url: URL) -> Candidate? {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        return Candidate(scheme: scheme,
                         host: host,
                         port: effectivePort(explicit: url.port, scheme: scheme),
                         path: ModelGatewayCredentialRouting.normalizedPath(url))
    }

    private static func route(serverName: String,
                              url: URL,
                              headers: [String: String]) throws -> Route {
        guard let candidate = candidate(url) else {
            throw PhoneMCPAccessError.invalidURL(url.absoluteString)
        }
        return Route(serverName: serverName,
                     scheme: candidate.scheme,
                     host: candidate.host,
                     port: candidate.port,
                     path: candidate.path,
                     headers: headers)
    }

    private static func matches(_ route: Route, _ candidate: Candidate) -> Bool {
        route.scheme == candidate.scheme
            && route.host == candidate.host
            && effectivePort(explicit: route.port, scheme: route.scheme)
                == effectivePort(explicit: candidate.port, scheme: candidate.scheme)
            && route.path == candidate.path
    }

    private static func effectivePort(explicit: Int?, scheme: String) -> Int? {
        if let explicit { return explicit }
        switch scheme {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }

    private static func urlString(_ route: Route) -> String {
        var text = "\(route.scheme)://\(route.host)"
        if let port = route.port { text += ":\(port)" }
        text += route.path == "/" ? "/" : route.path
        return text
    }
}

/// Credential router for MCP. The exact registered URL wins over the model and
/// search providers, so a same-host MCP path never receives the model key. An
/// exact MCP route with no stored value returns `.none`: the Worker's
/// placeholder is dropped and no authentication is sent.
public struct PhoneMCPCredentialProvider: CredentialProvider, Sendable {
    private let policy: MCPEgressPolicy
    private let base: any CredentialProvider

    public init(policy: MCPEgressPolicy, base: any CredentialProvider) {
        self.policy = policy
        self.base = base
    }

    public func credential(for scope: CredentialScope) async throws -> Credential {
        guard let route = policy.route(for: scope) else {
            return try await base.credential(for: scope)
        }
        return route.headers.isEmpty ? .none : Credential(kind: .headers(route.headers), value: "")
    }

    public func invalidate(_ credential: Credential, for scope: CredentialScope) async {
        guard policy.route(for: scope) == nil else { return }
        await base.invalidate(credential, for: scope)
    }
}

/// Non-secret persistence seam for the MCP grant document. Production uses
/// `UserDefaults`; tests inject a store that fails at a chosen stage so the
/// secret/document transaction ordering is exercised without a real preference
/// file or Keychain.
protocol PhoneMCPAccessDocumentStore {
    func read() throws -> Data?
    func write(_ data: Data) throws
}

private struct UserDefaultsMCPAccessDocumentStore: PhoneMCPAccessDocumentStore {
    let defaults: UserDefaults
    let key: String

    func read() throws -> Data? {
        defaults.data(forKey: key)
    }

    func write(_ data: Data) throws {
        defaults.set(data, forKey: key)
    }
}

/// Load/save the non-secret MCP grant document and its dedicated Keychain
/// service. The document is keyed by serverName; it is not a second server
/// registry and never carries a header value.
public final class PhoneMCPAccessSettings {
    public static let defaultsKey = "phone-dsh.mcp-access.v1"
    /// Dedicated Keychain service for MCP header values. Never the model or
    /// search service.
    public static let defaultKeychainService = "dev.phone-dsh.probe.mcp"
    public static let shared = PhoneMCPAccessSettings()

    private struct StoredDocument: Codable, Equatable {
        var version: Int
        var grants: [PhoneMCPAccessGrant]
        /// Legacy server-name pending deletions from the first document
        /// version; still cleaned so an interrupted remove is retried.
        var pendingDeletions: [String]?
        /// Keychain accounts written before their grant reference was
        /// committed. A crash at this point leaves the old grant usable; the
        /// next load deletes these unreferenced accounts.
        var pendingSecretWrites: [String]?
        /// Replaced Keychain accounts whose removal is still owed after a
        /// successful grant/revoke document commit.
        var pendingSecretDeletions: [String]?
        /// A grant written for an in-flight Worker `phone/mcpUpsert`. The
        /// previous grant (and its Keychain account) stays authoritative on
        /// disk until the bridge/native caller commits or rolls back. A crash
        /// therefore leaves enough information to restore the old URL from
        /// the materialized `mcp.json` on the next host start.
        var stagedGrants: [StagedGrant]?
    }

    private struct StagedGrant: Codable, Equatable {
        var serverName: String
        var previousGrant: PhoneMCPAccessGrant?
        /// Accounts written by an intermediate edit in the same open
        /// transaction. They are removed on commit or rollback; they are never
        /// read by the live route.
        var replacedAccounts: [String]?
        /// Set when the page, bridge or timeout loses the upsert result. The
        /// stage is no longer owned by an in-memory rollback token, so the
        /// next successful registry read may resolve it. It is not a verdict:
        /// the staged previous grant and Keychain account stay on disk until
        /// the authoritative registry proves commit or rollback.
        var abandoned: Bool?
    }

    private let documentStore: any PhoneMCPAccessDocumentStore
    private let secrets: any ModelProviderSecretStore
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard,
                secretStore: any ModelProviderSecretStore =
                    KeychainModelProviderSecretStore(
                        service: PhoneMCPAccessSettings.defaultKeychainService)) {
        self.documentStore = UserDefaultsMCPAccessDocumentStore(
            defaults: defaults,
            key: Self.defaultsKey)
        self.secrets = secretStore
    }

    /// Test seam: inject a document store that fails at a chosen stage.
    init(documentStore: any PhoneMCPAccessDocumentStore,
         secretStore: any ModelProviderSecretStore) {
        self.documentStore = documentStore
        self.secrets = secretStore
    }

    /// Read the committed grants without exposing any header value.
    public func load() throws -> PhoneMCPAccessSnapshot {
        lock.lock()
        defer { lock.unlock() }
        var document = try readDocumentLocked()
        try finishPendingLocked(&document, throwOnFailure: false)
        var unreadable = Set<String>()
        for grant in document.grants {
            do { _ = try readSecretMapLocked(account: Self.secretAccount(for: grant)) }
            catch { unreadable.insert(grant.serverName) }
        }
        return PhoneMCPAccessSnapshot(grants: document.grants,
                                      unreadableSecrets: unreadable)
    }

    /// Add or update one server's exact grant. Existing values are kept only
    /// for headers that remain on the row; `values` replaces the ones supplied
    /// by the native editor.
    ///
    /// Secret ordering is crash-safe: a new per-grant Keychain account is
    /// recorded as pending, written, and only then named by the committed
    /// grant document. The previous account is *not* deleted here: it remains
    /// the rollback target until the caller commits after the Worker
    /// `phone/mcpUpsert` succeeded. A crash before that commit therefore
    /// leaves both the old account and enough staging information for the next
    /// host start to restore the old URL from the materialized registry.
    @discardableResult
    public func grant(serverName: String,
                      url: String,
                      headers: [String],
                      values: [String: String] = [:]) throws -> PhoneMCPAccessGrant {
        let name = try Self.validatedServerName(serverName)
        let normalized = try Self.normalizedURL(url)
        let headerNames = try Self.validatedHeaders(headers)
        lock.lock()
        defer { lock.unlock() }
        var document = try readDocumentLocked()

        let previousGrant = document.grants.first { $0.serverName == name }
        let previousAccount = previousGrant.map { Self.secretAccount(for: $0) }
        // Fail closed before the pending journal or any Keychain deletion. A
        // transient read failure must never be interpreted as "no old value"
        // and silently replace a stored endpoint token with an empty grant.
        let previous: [String: String]
        if let previousAccount {
            previous = try readSecretMapLocked(account: previousAccount)
        } else {
            previous = [:]
        }

        try finishPendingLocked(&document)
        // An ownerless (abandoned) stage has no trustworthy rollback base: the
        // current grant may or may not have reached the Worker. Refuse before
        // writing a new Keychain account or journal entry; a successful list
        // must commit/rollback the old stage first.
        if document.stagedGrants?.first(where: { $0.serverName == name })?.abandoned == true {
            throw PhoneMCPAccessError.stagedGrantUnresolved(name)
        }
        // The Worker request carries the URL, not serverName. Two rows for the
        // same exact origin/path would therefore race for one credential slot;
        // refuse the second row instead of picking a token at random.
        if let existing = document.grants.first(where: {
            $0.serverName != name && Self.sameRoute($0.url, normalized.absoluteString)
        }) {
            throw PhoneMCPAccessError.duplicateURL(existing.serverName)
        }
        // A changed origin/path is a new trust boundary: do not carry the old
        // device token to a different server. Only values explicitly supplied
        // by the editor survive an endpoint move.
        let endpointChanged = previousGrant.map {
            !Self.sameEndpoint($0.url, normalized.absoluteString)
        } ?? false
        var nextSecrets = (endpointChanged ? [String: String]() : previous)
            .filter { headerNames.contains($0.key) }
        for header in headerNames {
            if let value = values[header] {
                if value.isEmpty {
                    nextSecrets.removeValue(forKey: header)
                } else {
                    nextSecrets[header] = value
                }
            }
        }

        let secretID: String? = nextSecrets.isEmpty
            ? nil
            : UUID().uuidString.lowercased()
        let nextAccount = secretID.map {
            SecretAccount(name: name, secretID: $0)
        }
        if let nextAccount {
            // State A: record the account before writing it, so a crash after
            // the Keychain write but before the grant commit is cleaned up.
            var writes = Set(document.pendingSecretWrites ?? [])
            writes.insert(nextAccount.rawValue)
            document.pendingSecretWrites = writes.sorted()
            try writeDocumentLocked(document)
            do {
                try writeSecretMapLocked(nextSecrets, account: nextAccount)
            } catch {
                throw PhoneMCPAccessError.secretStore
            }
        }

        let grant = PhoneMCPAccessGrant(serverName: name,
                                        url: normalized.absoluteString,
                                        headers: headerNames,
                                        secretID: secretID)
        // Keep the previous account on disk until commit. It is the exact
        // value a rollback (or a crash-recovery rollback from mcp.json) reuses.
        var staged = document.stagedGrants ?? []
        if let index = staged.firstIndex(where: { $0.serverName == name }) {
            // A live stage is still owned by its original transaction. Keep its
            // last committed `previousGrant` as the rollback base and collect
            // the intermediate current account for cleanup on commit/rollback.
            var replaced = Set(staged[index].replacedAccounts ?? [])
            let rollbackAccount = staged[index].previousGrant
                .map { Self.secretAccount(for: $0).rawValue }
            if let previousAccount,
               previousAccount.rawValue != rollbackAccount {
                replaced.insert(previousAccount.rawValue)
            }
            staged[index].replacedAccounts = replaced.isEmpty ? nil : replaced.sorted()
            staged[index].abandoned = nil
        } else {
            staged.append(StagedGrant(serverName: name,
                                      previousGrant: previousGrant,
                                      replacedAccounts: nil,
                                      abandoned: nil))
        }
        staged.sort { $0.serverName < $1.serverName }
        document.stagedGrants = staged.isEmpty ? nil : staged
        if let nextAccount {
            document.pendingSecretWrites?.removeAll { $0 == nextAccount.rawValue }
            if document.pendingSecretWrites?.isEmpty == true {
                document.pendingSecretWrites = nil
            }
        }
        document.grants.removeAll { $0.serverName == name }
        document.grants.append(grant)
        document.grants.sort { $0.serverName < $1.serverName }
        document.pendingDeletions?.removeAll { $0 == name }

        do {
            try writeDocumentLocked(document)
        } catch {
            // State A (or the old committed document) remains authoritative;
            // the old account was never removed. The pending write is retried
            // and deleted by the next load.
            throw PhoneMCPAccessError.documentStore
        }
        // Only journaled cleanup from earlier operations is retried here. The
        // previous account stays until an explicit commit.
        try? finishPendingLocked(&document, throwOnFailure: false)
        return grant
    }

    /// Close a grant transaction after the Worker `phone/mcpUpsert` succeeded.
    /// This is the first point at which the previous account may be removed.
    @discardableResult
    public func commitGrant(serverName: String,
                            expectedURL: String,
                            expectedHeaders: [String]) throws -> Bool {
        let name = try Self.validatedServerName(serverName)
        let expected = try Self.normalizedURL(expectedURL).absoluteString
        let headers = try Self.validatedHeaders(expectedHeaders)
        lock.lock()
        defer { lock.unlock() }
        var document = try readDocumentLocked()
        try finishPendingLocked(&document, throwOnFailure: false)
        var staged = document.stagedGrants ?? []
        guard let index = staged.firstIndex(where: { $0.serverName == name }) else {
            return false
        }
        guard let current = document.grants.first(where: { $0.serverName == name }),
              Self.sameEndpoint(current.url, expected),
              current.headers == headers else {
            // A newer edit owns the row now; leave its staging untouched.
            return false
        }
        let stage = staged.remove(at: index)
        document.stagedGrants = staged.isEmpty
            ? nil
            : staged.sorted(by: { $0.serverName < $1.serverName })
        var deletions = Set(stage.replacedAccounts ?? [])
        if let previous = stage.previousGrant {
            let account = Self.secretAccount(for: previous).rawValue
            if account != Self.secretAccount(for: current).rawValue {
                deletions.insert(account)
            }
        }
        if current.secretID == nil {
            // The committed row intentionally has no value map. Remove the
            // legacy per-server account so clearing a header cannot leave an
            // old token behind for `apply` to read.
            deletions.insert(Self.secretAccount(for: current).rawValue)
        }
        Self.addPendingDeletions(deletions, to: &document)
        try writeDocumentLocked(document)
        // Cleanup is retryable and must not make an already committed upsert
        // look failed.
        try? finishPendingLocked(&document, throwOnFailure: false)
        return true
    }

    /// Restore the grant that was current when the transaction opened. The old
    /// account is reused by reference, so no secret has to be rewritten from a
    /// memory-only snapshot.
    @discardableResult
    public func rollbackGrant(serverName: String,
                              expectedURL: String,
                              expectedHeaders: [String]) throws -> Bool {
        let name = try Self.validatedServerName(serverName)
        let expected = try Self.normalizedURL(expectedURL).absoluteString
        let headers = try Self.validatedHeaders(expectedHeaders)
        lock.lock()
        defer { lock.unlock() }
        var document = try readDocumentLocked()
        try finishPendingLocked(&document, throwOnFailure: false)
        var staged = document.stagedGrants ?? []
        guard let index = staged.firstIndex(where: { $0.serverName == name }) else {
            return false
        }
        guard let current = document.grants.first(where: { $0.serverName == name }),
              Self.sameEndpoint(current.url, expected),
              current.headers == headers else {
            return false
        }
        let stage = staged.remove(at: index)
        document.stagedGrants = staged.isEmpty
            ? nil
            : staged.sorted(by: { $0.serverName < $1.serverName })
        var deletions = Set(stage.replacedAccounts ?? [])
        let restoredAccount = stage.previousGrant
            .map { Self.secretAccount(for: $0).rawValue }
        let currentAccount = Self.secretAccount(for: current).rawValue
        if currentAccount != restoredAccount {
            deletions.insert(currentAccount)
        }
        document.grants.removeAll { $0.serverName == name }
        if let previous = stage.previousGrant {
            document.grants.append(previous)
            document.grants.sort { $0.serverName < $1.serverName }
            deletions.remove(Self.secretAccount(for: previous).rawValue)
        }
        Self.addPendingDeletions(deletions, to: &document)
        try writeDocumentLocked(document)
        try? finishPendingLocked(&document, throwOnFailure: false)
        return true
    }

    /// Remove the grant first, then delete its Keychain value. A deletion that
    /// fails stays pending and is retried by the next load/revoke; the route is
    /// already gone, so it cannot be used in the meantime.
    public func revoke(serverName: String) throws {
        _ = try Self.validatedServerName(serverName)
        lock.lock()
        defer { lock.unlock() }
        var document = try readDocumentLocked()
        var staged = document.stagedGrants ?? []
        let stage = staged.first { $0.serverName == serverName }
        staged.removeAll { $0.serverName == serverName }
        document.stagedGrants = staged.isEmpty
            ? nil
            : staged.sorted(by: { $0.serverName < $1.serverName })
        var removedAccounts = Set(document.grants
            .filter { $0.serverName == serverName }
            .map { Self.secretAccount(for: $0).rawValue })
        if let stage {
            removedAccounts.formUnion(stage.replacedAccounts ?? [])
            if let previous = stage.previousGrant {
                removedAccounts.insert(Self.secretAccount(for: previous).rawValue)
            }
        }
        document.grants.removeAll { $0.serverName == serverName }
        Self.addPendingDeletions(removedAccounts, to: &document)
        try writeDocumentLocked(document)
        try finishPendingLocked(&document)
    }

    /// Remove grants and Keychain values for servers no longer present in the
    /// Worker registry. Only call this after a successful `phone/mcpList`.
    @discardableResult
    public func reconcile(existingServerNames: Set<String>) throws -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return try reconcileLocked(existingServers: nil,
                                   existingServerNames: existingServerNames,
                                   protecting: [],
                                   resolveStaged: false)
    }

    /// Reconcile by server identity and exact URL. A row whose URL changed
    /// (or whose server row disappeared) loses the old grant and Keychain value.
    /// An open transaction is skipped so a list snapshot taken before the
    /// in-flight upsert cannot delete the grant it is about to use.
    @discardableResult
    public func reconcile(existingServers: [String: String],
                          protecting: Set<String> = []) throws -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return try reconcileLocked(existingServers: existingServers,
                                   existingServerNames: nil,
                                   protecting: protecting,
                                   resolveStaged: false)
    }

    private func reconcileLocked(existingServers: [String: String]?,
                                 existingServerNames: Set<String>?,
                                 protecting: Set<String>,
                                 resolveStaged: Bool) throws -> [String] {
        var document = try readDocumentLocked()
        try finishPendingLocked(&document, throwOnFailure: false)
        var staged = document.stagedGrants ?? []
        var kept: [PhoneMCPAccessGrant] = []
        var removed: [String] = []
        var deletions = Set<String>()
        var changed = false

        for grant in document.grants {
            if protecting.contains(grant.serverName) {
                kept.append(grant)
                continue
            }
            let expectedURL: String?
            if let existingServers {
                expectedURL = existingServers[grant.serverName].flatMap {
                    (try? Self.normalizedURL($0))?.absoluteString
                }
            } else if let existingServerNames {
                expectedURL = existingServerNames.contains(grant.serverName)
                    ? grant.url : nil
            } else {
                expectedURL = nil
            }
            let stageIndex = staged.firstIndex { $0.serverName == grant.serverName }
            let stage = stageIndex.map { staged[$0] }

            if !resolveStaged, let stage, stage.abandoned != true {
                // A normal list/sync is not allowed to close or roll back an
                // open save. Staging whose owner disappeared is different: the
                // next successful registry read may resolve it, because no
                // in-memory token can still commit or roll it back.
                kept.append(grant)
                continue
            }

            let registryMatchesCurrent = expectedURL.map {
                Self.sameEndpoint($0, grant.url)
            } ?? false
            if registryMatchesCurrent {
                if let stageIndex, let stage {
                    // The registry already contains this exact URL: the
                    // upsert committed but the bridge reply/commit was lost.
                    staged.remove(at: stageIndex)
                    deletions.formUnion(stage.replacedAccounts ?? [])
                    if let previous = stage.previousGrant {
                        let account = Self.secretAccount(for: previous).rawValue
                        if account != Self.secretAccount(for: grant).rawValue {
                            deletions.insert(account)
                        }
                    }
                    if grant.secretID == nil {
                        // The registry agrees that this row has no value map;
                        // clear any legacy account left from an older format.
                        deletions.insert(Self.secretAccount(for: grant).rawValue)
                    }
                    changed = true
                }
                kept.append(grant)
                continue
            }

            // The registry does not contain this exact current grant.
            if let stageIndex, let stage,
               let expectedURL,
               let previous = stage.previousGrant,
               Self.sameEndpoint(previous.url, expectedURL) {
                // The process stopped after `grant` but before the Worker
                // upsert. The registry still points at the old row, so restore
                // the old grant by reusing its still-present Keychain account.
                staged.remove(at: stageIndex)
                deletions.formUnion(stage.replacedAccounts ?? [])
                let currentAccount = Self.secretAccount(for: grant).rawValue
                if currentAccount != Self.secretAccount(for: previous).rawValue {
                    deletions.insert(currentAccount)
                }
                kept.append(previous)
                removed.append(grant.serverName)
                changed = true
                continue
            }

            if let stageIndex, let stage {
                staged.remove(at: stageIndex)
                deletions.formUnion(stage.replacedAccounts ?? [])
                if let previous = stage.previousGrant {
                    let account = Self.secretAccount(for: previous).rawValue
                    if account != Self.secretAccount(for: grant).rawValue {
                        deletions.insert(account)
                    }
                }
                changed = true
            }
            deletions.insert(Self.secretAccount(for: grant).rawValue)
            removed.append(grant.serverName)
            changed = true
        }

        let currentNames = Set(kept.map(\.serverName))
        let beforeStageCount = staged.count
        staged.removeAll { !currentNames.contains($0.serverName) }
        if staged.count != beforeStageCount {
            changed = true
        }
        document.grants = kept.sorted { $0.serverName < $1.serverName }
        document.stagedGrants = staged.isEmpty
            ? nil
            : staged.sorted(by: { $0.serverName < $1.serverName })
        Self.addPendingDeletions(deletions, to: &document)
        if changed {
            try writeDocumentLocked(document)
        }
        try finishPendingLocked(&document)
        return removed
    }

    private static func addPendingDeletions(_ accounts: Set<String>,
                                             to document: inout StoredDocument) {
        guard !accounts.isEmpty else { return }
        var pending = Set(document.pendingSecretDeletions ?? [])
        pending.formUnion(accounts)
        document.pendingSecretDeletions = pending.sorted()
    }

    /// Reconcile committed grants with the host-side materialized
    /// `/dsh/home/mcp.json` at host start. A missing or unreadable file is not
    /// proof that the registry is empty, so it leaves the grants untouched.
    public func reconcile(materializedHome: URL) {
        let file = materializedHome.appendingPathComponent("mcp.json",
                                                           isDirectory: false)
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              let servers = dictionary["servers"] as? [[String: Any]] else {
            return
        }
        var existing: [String: String] = [:]
        for server in servers {
            guard let name = server["serverName"] as? String,
                  let url = server["url"] as? String else { continue }
            existing[name] = url
        }
        lock.lock()
        defer { lock.unlock() }
        _ = try? reconcileLocked(existingServers: existing,
                                 existingServerNames: nil,
                                 protecting: [],
                                 resolveStaged: true)
    }

    /// Mark staging whose in-memory owner disappeared as abandoned without
    /// deciding commit or rollback. The staged previous grant and its Keychain
    /// account stay on disk; the next successful `phone/mcpList` or
    /// materialized-registry reconcile decides. Throws (and therefore keeps
    /// the caller's transaction token) when the mark cannot be persisted, so a
    /// page exit can never silently turn into a blind rollback.
    public func markStagedGrantsAbandoned(serverNames: Set<String>) throws {
        guard !serverNames.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        var document = try readDocumentLocked()
        try finishPendingLocked(&document, throwOnFailure: false)
        guard var staged = document.stagedGrants, !staged.isEmpty else { return }
        var changed = false
        for index in staged.indices where serverNames.contains(staged[index].serverName) {
            if staged[index].abandoned != true {
                staged[index].abandoned = true
                changed = true
            }
        }
        guard changed else { return }
        document.stagedGrants = staged
        try writeDocumentLocked(document)
    }

    /// The grant `rollbackGrant` would actually restore: the staging's
    /// `previousGrant`, not the current (new) grant. Callers must use this as
    /// the rollback proof so an older abandoned stage cannot make them restore
    /// the wrong endpoint.
    public func stagedPreviousGrant(serverName: String) throws -> PhoneMCPAccessGrant? {
        lock.lock()
        defer { lock.unlock() }
        let document = try readDocumentLocked()
        return document.stagedGrants?
            .first { $0.serverName == serverName }?
            .previousGrant
    }

    /// Whether an unresolved staging slot exists for this server. A `false`
    /// result means there is nothing left for rollback/commit to close.
    public func hasStagedGrant(serverName: String) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let document = try readDocumentLocked()
        return document.stagedGrants?.contains { $0.serverName == serverName } ?? false
    }

    /// Replace `policy` with the committed grants and the currently readable
    /// Keychain values. A read failure produces a route with no headers, never
    /// a fallback to the model key.
    public func apply(to policy: MCPEgressPolicy) {
        let snapshot = (try? load()) ?? PhoneMCPAccessSnapshot()
        var inputs: [MCPEgressPolicy.RouteInput] = []
        for grant in snapshot.grants {
            guard let url = URL(string: grant.url) else { continue }
            let secrets = (try? readSecretMap(account: Self.secretAccount(for: grant))) ?? [:]
            let headers = secrets.filter {
                grant.headers.contains($0.key) && !$0.value.isEmpty
            }
            inputs.append(MCPEgressPolicy.RouteInput(serverName: grant.serverName,
                                                     url: url,
                                                     headers: headers))
        }
        // Build every route first and swap them under one lock, so a gateway
        // request never observes the document half-applied.
        policy.replaceRoutes(inputs)
    }

    /// Build a fresh policy for one host start.
    public func makePolicy() -> MCPEgressPolicy {
        let policy = MCPEgressPolicy()
        apply(to: policy)
        return policy
    }

    /// Header names with a stored value, for the native editor.
    public func storedHeaderNames(serverName: String) -> Set<String> {
        guard let grant = (try? load())?.grants.first(where: { $0.serverName == serverName }) else {
            return []
        }
        return Set(((try? readSecretMap(account: Self.secretAccount(for: grant)))
            ?? [String: String]()).keys)
    }

    /// Values for one server's Keychain map, for the native editor and
    /// in-process status checks. Callers must never render, log or persist this
    /// dictionary.
    public func secretValues(for serverName: String) -> [String: String]? {
        guard let grant = (try? load())?.grants.first(where: { $0.serverName == serverName }) else {
            return nil
        }
        return try? readSecretMap(account: Self.secretAccount(for: grant))
    }

    // MARK: - Validation

    public static func validatedServerName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 32,
              name.range(of: "^[A-Za-z0-9_-]{1,32}$", options: .regularExpression) != nil else {
            throw PhoneMCPAccessError.invalidServerName(raw)
        }
        return name
    }

    public static func normalizedURL(_ raw: String) throws -> URL {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil,
              components.password == nil else {
            throw PhoneMCPAccessError.invalidURL(raw)
        }
        var normalized = URLComponents()
        normalized.scheme = scheme
        normalized.host = host.lowercased()
        // Match what the Worker's `new URL(...).toString()` persists: an
        // explicit scheme-default port is not part of its canonical URL.
        // Keeping `:443`/`:80` here would make every phone/mcpList or host
        // restart look like an endpoint change and revoke a valid grant.
        if let port = components.port,
           !((scheme == "https" && port == 443) || (scheme == "http" && port == 80)) {
            normalized.port = port
        }
        normalized.path = ModelGatewayCredentialRouting.normalizedPath(components.path)
        normalized.query = components.query
        guard let url = normalized.url else {
            throw PhoneMCPAccessError.invalidURL(raw)
        }
        return url
    }

    /// Stable identity of the exact HTTP endpoint used by grant/commit/
    /// rollback/settle/resolve: scheme, lowercased host, effective port,
    /// normalized path and the actual query. The fragment never participates.
    /// Unlike `sameRoute`, the query is part of endpoint identity because it
    /// changes the row the Worker upserts; the gateway credential scope stays
    /// path-only.
    public static func canonicalEndpointKey(_ raw: String) -> String? {
        guard let url = try? normalizedURL(raw),
              let scheme = url.scheme,
              let host = url.host else { return nil }
        let port = ModelGatewayCredentialRouting.effectivePort(url, scheme: scheme) ?? 0
        let path = ModelGatewayCredentialRouting.normalizedPath(url)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .percentEncodedQuery ?? ""
        return "\(scheme)://\(host):\(port)\(path)\(query.isEmpty ? "" : "?\(query)")"
    }

    /// Whether two URLs name the same exact HTTP endpoint under the canonical
    /// comparison above.
    public static func sameEndpoint(_ lhs: String, _ rhs: String) -> Bool {
        guard let left = canonicalEndpointKey(lhs),
              let right = canonicalEndpointKey(rhs) else { return false }
        return left == right
    }

    /// Compare the non-secret credential scope of two URLs (query ignored),
    /// matching the gateway's exact scheme/host/effective-port/path route.
    private static func sameRoute(_ lhs: String, _ rhs: String) -> Bool {
        guard let left = URL(string: lhs), let right = URL(string: rhs),
              let leftKey = MCPEgressPolicy.routeKey(for: left),
              let rightKey = MCPEgressPolicy.routeKey(for: right) else { return false }
        return leftKey == rightKey
    }

    static func validatedSecretID(_ raw: String) throws {
        guard raw.range(of: "^[A-Za-z0-9-]{1,64}$",
                        options: .regularExpression) != nil else {
            throw PhoneMCPAccessError.invalidStoredDocument("invalid secret id")
        }
    }

    private static func validatedAccountReference(_ raw: String) -> Bool {
        raw.range(of: "^mcp\\.[A-Za-z0-9_-]{1,32}(\\.[A-Za-z0-9-]{1,64})?$",
                   options: .regularExpression) != nil
    }

    public static func validatedHeaders(_ raw: [String]) throws -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for header in raw {
            let name = header.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty,
                  name.range(of: "^[!#$%&'*+\\-.^_`|~0-9A-Za-z]+$",
                             options: .regularExpression) != nil else {
                throw PhoneMCPAccessError.invalidHeader(header)
            }
            let lower = name.lowercased()
            guard !["host", "content-length", "transfer-encoding", "connection"]
                .contains(lower) else {
                throw PhoneMCPAccessError.invalidHeader(header)
            }
            if seen.insert(lower).inserted { result.append(name) }
        }
        result.sort { $0.lowercased() < $1.lowercased() }
        return result
    }

    // MARK: - Persistence

    private func readDocumentLocked() throws -> StoredDocument {
        let data: Data?
        do { data = try documentStore.read() } catch {
            throw PhoneMCPAccessError.documentStore
        }
        guard let data else {
            return StoredDocument(version: 1, grants: [], pendingDeletions: nil,
                                  pendingSecretWrites: nil, pendingSecretDeletions: nil,
                                  stagedGrants: nil)
        }
        var document: StoredDocument
        do {
            document = try JSONDecoder().decode(StoredDocument.self, from: data)
        } catch {
            throw PhoneMCPAccessError.invalidStoredDocument("not valid JSON")
        }
        guard document.version == 1 else {
            throw PhoneMCPAccessError.invalidStoredDocument("unsupported version")
        }
        for index in document.grants.indices {
            let grant = document.grants[index]
            _ = try Self.validatedServerName(grant.serverName)
            // Normalize legacy documents on read too: a URL stored with an
            // explicit scheme-default port compares equal to the Worker's
            // canonical URL and is not revoked merely for that spelling.
            document.grants[index].url = try Self.normalizedURL(grant.url).absoluteString
            _ = try Self.validatedHeaders(grant.headers)
            if let secretID = grant.secretID {
                try Self.validatedSecretID(secretID)
            }
        }
        if var staged = document.stagedGrants {
            for index in staged.indices {
                var stage = staged[index]
                _ = try Self.validatedServerName(stage.serverName)
                if var previous = stage.previousGrant {
                    _ = try Self.validatedServerName(previous.serverName)
                    guard previous.serverName == stage.serverName else {
                        throw PhoneMCPAccessError.invalidStoredDocument("staged grant name mismatch")
                    }
                    previous.url = try Self.normalizedURL(previous.url).absoluteString
                    _ = try Self.validatedHeaders(previous.headers)
                    if let secretID = previous.secretID {
                        try Self.validatedSecretID(secretID)
                    }
                    stage.previousGrant = previous
                }
                for account in stage.replacedAccounts ?? [] {
                    guard Self.validatedAccountReference(account) else {
                        throw PhoneMCPAccessError.invalidStoredDocument("invalid staged account")
                    }
                }
                staged[index] = stage
            }
            document.stagedGrants = staged
        }
        return document
    }

    private func writeDocumentLocked(_ document: StoredDocument) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do { data = try encoder.encode(document) } catch {
            throw PhoneMCPAccessError.documentStore
        }
        do {
            try documentStore.write(data)
        } catch {
            throw PhoneMCPAccessError.documentStore
        }
        do {
            guard try documentStore.read() == data else {
                throw PhoneMCPAccessError.documentStore
            }
        } catch let error as PhoneMCPAccessError {
            throw error
        } catch {
            throw PhoneMCPAccessError.documentStore
        }
    }

    private func finishPendingLocked(_ document: inout StoredDocument,
                                     throwOnFailure: Bool = true) throws {
        var failed = false
        var changed = false

        if let pending = document.pendingDeletions, !pending.isEmpty {
            var remaining = Set<String>()
            for name in pending {
                do {
                    try secrets.deleteSecret(for: SecretAccount(name: name).rawValue)
                } catch {
                    remaining.insert(name)
                }
            }
            let next = remaining.isEmpty ? nil : remaining.sorted()
            if next != document.pendingDeletions {
                document.pendingDeletions = next
                changed = true
            }
            failed = failed || !remaining.isEmpty
        }

        if let pending = document.pendingSecretWrites, !pending.isEmpty {
            var remaining = Set<String>()
            for account in pending {
                do { try secrets.deleteSecret(for: account) }
                catch { remaining.insert(account) }
            }
            let next = remaining.isEmpty ? nil : remaining.sorted()
            if next != document.pendingSecretWrites {
                document.pendingSecretWrites = next
                changed = true
            }
            failed = failed || !remaining.isEmpty
        }

        if let pending = document.pendingSecretDeletions, !pending.isEmpty {
            var remaining = Set<String>()
            for account in pending {
                do { try secrets.deleteSecret(for: account) }
                catch { remaining.insert(account) }
            }
            let next = remaining.isEmpty ? nil : remaining.sorted()
            if next != document.pendingSecretDeletions {
                document.pendingSecretDeletions = next
                changed = true
            }
            failed = failed || !remaining.isEmpty
        }

        if changed {
            try writeDocumentLocked(document)
        }
        if failed && throwOnFailure {
            throw PhoneMCPAccessError.secretStore
        }
    }

    private func readSecretMap(account: SecretAccount) throws -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return try readSecretMapLocked(account: account)
    }

    private func readSecretMapLocked(account: SecretAccount) throws -> [String: String] {
        let raw: String?
        do {
            raw = try secrets.secret(for: account.rawValue)
        } catch {
            throw PhoneMCPAccessError.secretStore
        }
        guard let raw, !raw.isEmpty else { return [:] }
        guard let data = raw.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else {
            throw PhoneMCPAccessError.secretStore
        }
        return map
    }

    private func writeSecretMapLocked(_ map: [String: String],
                                      account: SecretAccount) throws {
        if map.isEmpty {
            try secrets.deleteSecret(for: account.rawValue)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(map),
              let raw = String(data: data, encoding: .utf8) else {
            throw PhoneMCPAccessError.secretStore
        }
        try secrets.setSecret(raw, for: account.rawValue)
    }

    private static func secretAccount(for grant: PhoneMCPAccessGrant) -> SecretAccount {
        SecretAccount(name: grant.serverName, secretID: grant.secretID)
    }

    /// Keychain account for one server's (or one rotated grant's) header-value
    /// map. `serverName` and `secretID` are validated so neither can escape the
    /// namespace; the optional id keeps a new secret from overwriting the
    /// account an older URL still references.
    private struct SecretAccount: Equatable {
        var name: String
        var secretID: String?
        var rawValue: String {
            if let secretID { return "mcp." + name + "." + secretID }
            return "mcp." + name
        }
    }

}
