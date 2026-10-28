// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — production Web→native MCP control seam.
//
// The complete DSH Web MCP tab posts grant/commit/rollback/revoke/sync/open
// messages here. The controller owns the one live `MCPEgressPolicy`, the one
// `PhoneMCPAccessSettings` document and the in-process rollback snapshots.
// Header values never cross the WKWebView bridge: it accepts header names only
// and the native sheet writes/reads values through the dedicated Keychain.
//
// `MCPControlBridge` is the WKScriptMessageHandlerWithReply the app installs on
// its real Web engine. The simulator suite installs this same class on the real
// production `WebHostConfiguration` engine, so the bridge/message path is not a
// test-only copy.

import Foundation
import WebKit
import PhoneDSH

/// One reversible Web-side grant. The snapshot stays in host memory only. The
/// previous Keychain account stays on disk (see `PhoneMCPAccessSettings`), so a
/// failed upsert rolls back by reference instead of carrying a secret in this
/// object.
private struct MCPGrantSnapshot {
    let serverName: String
    let resultURL: String
    let resultHeaders: [String]
    /// Non-secret account identity of the grant this token created. A later
    /// native/Web save rotates it, so a stale cleanup token can detect that it
    /// no longer owns the row's staging.
    let resultSecretID: String?
    let createdAt: Date
}

/// Non-secret fields the Web tab can hand to the native editor when a row
/// needs a value only the native Keychain can hold.
public struct MCPControlDraftHeader: Equatable, Sendable {
    public var name: String
    public var envName: String

    public init(name: String, envName: String) {
        self.name = name
        self.envName = envName
    }
}

public struct MCPControlDraft: Equatable, Sendable {
    public var serverName: String
    public var url: String
    public var headers: [MCPControlDraftHeader]
    public var enabled: Bool
    public var toolCallTimeoutMs: Int

    public init(serverName: String,
                url: String,
                headers: [MCPControlDraftHeader],
                enabled: Bool,
                toolCallTimeoutMs: Int) {
        self.serverName = serverName
        self.url = url
        self.headers = headers
        self.enabled = enabled
        self.toolCallTimeoutMs = toolCallTimeoutMs
    }
}

/// Host-side controller shared by the App Web surface and the simulator test.
@MainActor
public final class MCPControlController {
    public let settings: PhoneMCPAccessSettings
    public let policy: MCPEgressPolicy
    private let presentSettings: @MainActor (MCPControlDraft?) -> Void
    private var transactions: [String: MCPGrantSnapshot] = [:]
    /// Worker-committed rows whose native cleanup failed. These tokens have no
    /// rollback ability; they are retried until the durable staging closes,
    /// while a page exit/materialized restart can also resolve the stage.
    private var commitPending: [String: MCPGrantSnapshot] = [:]
    private let maximumTransactions = 32
    /// A page that vanishes between grant and commit/reply must not leave an
    /// exact egress route and a staged Keychain account open forever.
    private let transactionTimeout: TimeInterval
    private var expiryTask: Task<Void, Never>?

    public init(settings: PhoneMCPAccessSettings = .shared,
                policy: MCPEgressPolicy? = nil,
                materializedHome: URL? = nil,
                transactionTimeout: TimeInterval = 300,
                presentSettings: @escaping @MainActor (MCPControlDraft?) -> Void = { _ in }) {
        self.settings = settings
        // Resolve a staging record left by a process that stopped between
        // grant and upsert before this controller exposes any live route.
        if let materializedHome {
            settings.reconcile(materializedHome: materializedHome)
        }
        let livePolicy = policy ?? MCPEgressPolicy()
        settings.apply(to: livePolicy)
        self.policy = livePolicy
        self.transactionTimeout = max(1, transactionTimeout)
        self.presentSettings = presentSettings
        // Lazy expiry at the next bridge call is not enough: after a page
        // crash there may be no next call. This timer is cancelled by the
        // weak capture when the controller goes away.
        expiryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled, let self else { return }
                self.expireOpenTransactions()
                self.retryPendingCommits()
            }
        }
    }

    /// Reload the committed document into the live policy.
    public func refreshPolicy() {
        settings.apply(to: policy)
    }

    /// A page exit, WebContent crash or bridge removal loses the upsert reply.
    /// That is not proof that the Worker write failed, so do not roll back:
    /// mark the durable staging ownerless and let the next real
    /// `phone/mcpList` or materialized-registry reconcile decide. The token is
    /// kept when the mark cannot be persisted, so a later timer call retries.
    public func abandonOpenTransactions() {
        markTransactionsAbandoned(Array(transactions.keys))
    }

    /// Expire transactions older than the finite timeout the same way: an
    /// unknown result becomes abandoned staging, never a blind rollback.
    /// Exposed with an injectable date for tests; production calls it from the
    /// bridge timer and every message.
    public func expireOpenTransactions(now: Date = Date()) {
        let expired = transactions
            .filter { now.timeIntervalSince($0.value.createdAt) >= transactionTimeout }
            .sorted { $0.value.createdAt < $1.value.createdAt }
            .map(\.key)
        markTransactionsAbandoned(expired)
    }

    /// Retry native cleanup for rows whose Worker upsert is already committed.
    /// These tokens never appear in `transactions`, so no page exit/timeout can
    /// roll them back.
    private func retryPendingCommits() {
        for (token, snapshot) in commitPending.sorted(by: { $0.key < $1.key }) {
            let current: PhoneMCPAccessGrant?
            do {
                current = try settings.load().grants.first {
                    $0.serverName == snapshot.serverName
                }
            } catch {
                // The document is unreadable, so a newer save cannot have
                // taken the stage either. Keep this token for the next retry.
                continue
            }
            guard let current,
                  PhoneMCPAccessSettings.canonicalEndpointKey(current.url)
                    == PhoneMCPAccessSettings.canonicalEndpointKey(snapshot.resultURL),
                  current.headers == snapshot.resultHeaders,
                  current.secretID == snapshot.resultSecretID else {
                // A newer save/revoke owns this server now. Dropping this
                // token must not commit or mark abandoned the new stage.
                commitPending.removeValue(forKey: token)
                continue
            }
            do {
                if try commit(serverName: snapshot.serverName,
                              expectedURL: snapshot.resultURL,
                              expectedHeaders: snapshot.resultHeaders) {
                    commitPending.removeValue(forKey: token)
                } else if markStagingAbandoned([snapshot.serverName]) {
                    // The durable stage is ownerless now; the next successful
                    // registry read finishes the cleanup instead of this token.
                    commitPending.removeValue(forKey: token)
                }
            } catch {
                // Keep retrying while the stage is still protected from
                // reconcile. Once it can be marked ownerless, the registry or
                // materialized start becomes the recovery owner.
                if markStagingAbandoned([snapshot.serverName]) {
                    commitPending.removeValue(forKey: token)
                }
            }
        }
    }

    /// One cleanup attempt while the host detaches the page handler. The timer
    /// or the next materialized registry read remains the fallback.
    public func retryPendingCommitsForClose() {
        retryPendingCommits()
    }

    @discardableResult
    private func markStagingAbandoned(_ names: Set<String>) -> Bool {
        guard !names.isEmpty else { return true }
        do {
            try settings.markStagedGrantsAbandoned(serverNames: names)
            return true
        } catch {
            return false
        }
    }

    private func markTransactionsAbandoned(_ tokens: [String]) {
        guard !tokens.isEmpty else { return }
        let names = Set(tokens.compactMap { transactions[$0]?.serverName })
        guard !names.isEmpty else { return }
        // Keep the tokens as the retry owner when the durable mark cannot be
        // persisted. Rows stay unrolled-back; a later bridge message/timer
        // tries the durable mark again.
        if markStagingAbandoned(names) {
            for token in tokens {
                transactions.removeValue(forKey: token)
            }
        }
    }

    /// Add or update one row from the native editor, including values that
    /// never cross the Web bridge. The previous account stays staged until
    /// `commit` after the Worker upsert.
    @discardableResult
    public func grant(serverName: String,
                      url: String,
                      headers: [String],
                      values: [String: String] = [:]) throws -> PhoneMCPAccessGrant {
        let grant = try settings.grant(serverName: serverName,
                                       url: url,
                                       headers: headers,
                                       values: values)
        // The new edit reuses the durable slot, so a cleanup token from a
        // previous committed edit of this row no longer owns it.
        commitPending = commitPending.filter {
            $0.value.serverName != grant.serverName
        }
        refreshPolicy()
        return grant
    }

    /// Close the native/Web transaction after the Worker row is committed.
    @discardableResult
    public func commit(serverName: String,
                       expectedURL: String,
                       expectedHeaders: [String]) throws -> Bool {
        defer { refreshPolicy() }
        return try settings.commitGrant(serverName: serverName,
                                        expectedURL: expectedURL,
                                        expectedHeaders: expectedHeaders)
    }

    /// Restore the staged previous grant after a failed Worker upsert.
    @discardableResult
    public func rollback(serverName: String,
                         expectedURL: String,
                         expectedHeaders: [String]) throws -> Bool {
        defer { refreshPolicy() }
        return try settings.rollbackGrant(serverName: serverName,
                                          expectedURL: expectedURL,
                                          expectedHeaders: expectedHeaders)
    }

    public func revoke(serverName: String) throws {
        // `settings.revoke` removes the document grant before it retries the
        // Keychain deletion. Even when that deletion fails, the live policy
        // must be rebuilt from the committed document (fail closed).
        defer { refreshPolicy() }
        try settings.revoke(serverName: serverName)
        // A successful revoke removes the whole staging slot, including any
        // cleanup this token still owed.
        commitPending = commitPending.filter {
            $0.value.serverName != serverName
        }
    }

    @discardableResult
    public func reconcile(existingServers: [String: String],
                          protecting: Set<String> = []) throws -> [String] {
        defer { refreshPolicy() }
        return try settings.reconcile(existingServers: existingServers,
                                      protecting: protecting)
    }

    /// Handle one page bridge message. Only non-secret row metadata is accepted.
    public func handle(_ body: Any) async throws -> [String: Any] {
        guard let message = body as? [String: Any],
              (message["v"] as? Int) == 1,
              let action = message["action"] as? String else {
            throw PhoneDSHError.invalidState("invalid MCP bridge message")
        }
        expireOpenTransactions()
        defer { retryPendingCommits() }
        switch action {
        case "open":
            presentSettings(Self.draft(from: message["draft"]))
            return ["ok": true]
        case "grant":
            guard let serverName = message["serverName"] as? String,
                  let url = message["url"] as? String else {
                throw PhoneDSHError.invalidState("MCP grant is missing serverName or url")
            }
            let name = try PhoneMCPAccessSettings.validatedServerName(serverName)
            let headers = (message["headers"] as? [String: Any]).map { Array($0.keys) } ?? []
            // A second edit of the same row supersedes the first transaction;
            // a new row cannot evict its oldest transaction without first
            // closing that transaction's grant/Keychain staging.
            try closeTransactions(for: name)
            try makeRoomForTransaction()
            let grant = try settings.grant(serverName: name,
                                           url: url,
                                           headers: headers)
            // The new edit reuses the durable slot and carries the old account
            // forward, so a cleanup token from a previous committed edit of
            // this row is obsolete. Dropping it here prevents that token from
            // later marking the new in-flight staging abandoned.
            commitPending = commitPending.filter {
                $0.value.serverName != grant.serverName
            }
            refreshPolicy()
            let token = UUID().uuidString.lowercased()
            transactions[token] = MCPGrantSnapshot(serverName: grant.serverName,
                                                   resultURL: grant.url,
                                                   resultHeaders: grant.headers,
                                                   resultSecretID: grant.secretID,
                                                   createdAt: Date())
            let stored = settings.secretValues(for: grant.serverName) ?? [:]
            let needsValues = grant.headers.contains { header in
                (stored[header] ?? "").isEmpty
            }
            return ["ok": true,
                    "hostManagedHeaders": grant.headers,
                    "url": grant.url,
                    "transaction": token,
                    "needsValues": needsValues]
        case "commit":
            guard let token = message["transaction"] as? String else {
                return ["ok": true, "committed": true, "cleanupPending": false]
            }
            if transactions[token] == nil, commitPending[token] != nil {
                retryPendingCommits()
                return ["ok": true,
                        "committed": true,
                        "cleanupPending": commitPending[token] != nil,
                        "commitPending": commitPending[token] != nil]
            }
            guard let snapshot = transactions.removeValue(forKey: token) else {
                // Abandon/expiry already marked the stage ownerless (or a
                // settle resolved it). Cleanup cannot be claimed as done; the
                // next real registry read resolves the durable stage.
                return ["ok": true,
                        "committed": false,
                        "cleanupPending": true,
                        "commitPending": true]
            }
            // The Worker row is authoritative now. Drop the rollback owner
            // *before* touching the document, so a commit/cleanup failure can
            // never let pagehide/timeout roll back a committed Worker row.
            do {
                let committed = try commit(serverName: snapshot.serverName,
                                           expectedURL: snapshot.resultURL,
                                           expectedHeaders: snapshot.resultHeaders)
                if !committed,
                   !markStagingAbandoned([snapshot.serverName]) {
                    // The stage could not be made ownerless; keep a token with
                    // no rollback path so cleanup is retried.
                    commitPending[token] = snapshot
                }
                return ["ok": true,
                        "committed": committed,
                        "cleanupPending": !committed,
                        "commitPending": !committed && commitPending[token] != nil]
            } catch {
                // Keep a retry token that has no rollback path. Durable staging
                // also remains for the next registry/materialized reconcile.
                _ = markStagingAbandoned([snapshot.serverName])
                if commitPending[token] == nil {
                    commitPending[token] = snapshot
                }
                return ["ok": true,
                        "committed": false,
                        "cleanupPending": true,
                        "commitPending": true]
            }
        case "rollback":
            guard let token = message["transaction"] as? String,
                  let snapshot = transactions[token] else {
                throw PhoneDSHError.invalidState("unknown MCP grant transaction")
            }
            let rolledBack = try rollback(serverName: snapshot.serverName,
                                          expectedURL: snapshot.resultURL,
                                          expectedHeaders: snapshot.resultHeaders)
            guard rolledBack else {
                // `false` means the document did not restore this stage (for
                // example a newer edit owns it). Keep the token as the retry
                // owner instead of reporting a rollback that did not happen.
                _ = markStagingAbandoned([snapshot.serverName])
                throw PhoneDSHError.invalidState(
                    "MCP rollback did not restore the staged grant")
            }
            // Only a successful rollback may drop the token; a document-store
            // failure keeps it as the retry owner.
            transactions.removeValue(forKey: token)
            return ["ok": true]
        case "revoke":
            guard let serverName = message["serverName"] as? String else {
                throw PhoneDSHError.invalidState("MCP revoke is missing serverName")
            }
            do {
                try revoke(serverName: serverName)
            } catch PhoneMCPAccessError.secretStore {
                // The document grant is already removed and the live policy
                // was rebuilt in `defer`; only Keychain cleanup is pending.
                return ["ok": true, "cleanupPending": true]
            }
            return ["ok": true]
        case "sync":
            guard let rows = message["servers"] as? [[String: Any]] else {
                return ["ok": true]
            }
            var existing: [String: String] = [:]
            for row in rows {
                guard let name = row["serverName"] as? String,
                      let url = row["url"] as? String else { continue }
                existing[name] = url
            }
            // A list snapshot taken while a save is between `grant` and
            // `commit`/`rollback` must not revoke that in-flight row. A lost
            // upsert reply is settled explicitly with `settle` after the page
            // queries the registry, not by an unrelated refresh.
            let open = Set(transactions.values.map(\.serverName))
            do {
                _ = try reconcile(existingServers: existing, protecting: open)
            } catch PhoneMCPAccessError.secretStore {
                // The document reconcile committed; only Keychain cleanup is
                // pending. The live policy was already rebuilt in `defer`.
                return ["ok": true, "cleanupPending": true]
            }
            return ["ok": true]
        case "settle":
            // The page queried the real registry after an upsert reply was
            // lost. Compare canonical endpoints (scheme/host/effective
            // port/normalized path/query): a matching current row commits, a
            // confirmed *previous* row rolls back, and anything else keeps the
            // durable staging because it cannot be inferred.
            guard let token = message["transaction"] as? String else {
                return ["ok": true, "committed": false, "resolved": "unknown"]
            }
            if commitPending[token] != nil {
                retryPendingCommits()
                return ["ok": true,
                        "committed": true,
                        "resolved": "commitPending",
                        "cleanupPending": commitPending[token] != nil]
            }
            guard let snapshot = transactions[token] else {
                return ["ok": true, "committed": false, "resolved": "unknown"]
            }
            let registryURL = message["registryURL"] as? String
            let registryKey = registryURL.flatMap {
                PhoneMCPAccessSettings.canonicalEndpointKey($0)
            }
            let desiredKey = PhoneMCPAccessSettings.canonicalEndpointKey(snapshot.resultURL)
            // The only valid rollback proof is the grant `rollbackGrant` will
            // actually restore: the durable staging's `previousGrant`, not the
            // URL that happened to be current when the page sent `grant`.
            let previousGrant: PhoneMCPAccessGrant?
            do {
                guard try settings.hasStagedGrant(serverName: snapshot.serverName) else {
                    transactions.removeValue(forKey: token)
                    return ["ok": true, "committed": false, "resolved": "unknown"]
                }
                previousGrant = try settings.stagedPreviousGrant(
                    serverName: snapshot.serverName)
            } catch {
                if markStagingAbandoned([snapshot.serverName]) {
                    transactions.removeValue(forKey: token)
                }
                return ["ok": true, "committed": false, "resolved": "unknown"]
            }
            let previousKey = previousGrant.flatMap {
                PhoneMCPAccessSettings.canonicalEndpointKey($0.url)
            }
            if let registryKey, let desiredKey, registryKey == desiredKey {
                // The registry proves the Worker write committed. Cancel the
                // rollback owner before cleanup; a cleanup failure is a
                // commit-pending status, not a reason to roll back.
                transactions.removeValue(forKey: token)
                do {
                    let committed = try commit(serverName: snapshot.serverName,
                                               expectedURL: snapshot.resultURL,
                                               expectedHeaders: snapshot.resultHeaders)
                    if !committed,
                       !markStagingAbandoned([snapshot.serverName]) {
                        commitPending[token] = snapshot
                    }
                    return ["ok": true,
                            "committed": true,
                            "resolved": committed ? "committed" : "commitPending",
                            "cleanupPending": !committed]
                } catch {
                    commitPending[token] = snapshot
                    _ = markStagingAbandoned([snapshot.serverName])
                    return ["ok": true,
                            "committed": true,
                            "resolved": "commitPending",
                            "cleanupPending": true]
                }
            }
            // Rollback needs positive proof: the registry still names the
            // exact previous grant, or this was a new row and the registry
            // confirms no row exists. An absent old row or an unexpected URL
            // is unknown, not permission to roll back.
            let confirmedPrevious = previousKey != nil && registryKey == previousKey
            let confirmedAbsentNewRow = previousKey == nil && registryURL == nil
            guard confirmedPrevious || confirmedAbsentNewRow else {
                // Inconclusive: no rollback, and no rollback owner either. Mark
                // the durable stage ownerless so the next successful registry
                // read can decide; keep the token if the mark cannot persist.
                if markStagingAbandoned([snapshot.serverName]) {
                    transactions.removeValue(forKey: token)
                }
                return ["ok": true, "committed": false, "resolved": "unknown"]
            }
            do {
                let rolledBack = try rollback(
                    serverName: snapshot.serverName,
                    expectedURL: snapshot.resultURL,
                    expectedHeaders: snapshot.resultHeaders)
                guard rolledBack else {
                    // `false` is not a rollback. Make the durable stage
                    // ownerless and drop this rollback owner once that mark is
                    // persisted: the next real list, not a later timeout, must
                    // decide. If the mark fails, keep the token as retry owner.
                    if markStagingAbandoned([snapshot.serverName]) {
                        transactions.removeValue(forKey: token)
                    }
                    return ["ok": true,
                            "committed": false,
                            "resolved": "unknown",
                            "rollbackPending": true]
                }
                transactions.removeValue(forKey: token)
                return ["ok": true, "committed": false, "resolved": "rolled-back"]
            } catch {
                // A failing document store also prevents the ownerless mark, so
                // the token stays the retry owner. If only the rollback failed,
                // the persisted abandoned stage is enough for the next registry
                // read and the token must not keep protecting it from sync.
                if markStagingAbandoned([snapshot.serverName]) {
                    transactions.removeValue(forKey: token)
                }
                return ["ok": true,
                        "committed": false,
                        "resolved": "unknown",
                        "rollbackPending": true]
            }
        case "abandon":
            // Page lifecycle (`pagehide`, crash recovery, bridge removal) has
            // no upsert result. Mark staging ownerless instead of rolling back
            // a row the Worker may already have committed. A single
            // transaction is used when a failed registry query cannot decide.
            if let token = message["transaction"] as? String {
                markTransactionsAbandoned([token])
            } else {
                abandonOpenTransactions()
            }
            return ["ok": true]
        default:
            throw PhoneDSHError.invalidState("unsupported MCP bridge action")
        }
    }

    private static func draft(from raw: Any?) -> MCPControlDraft? {
        guard let value = raw as? [String: Any],
              let serverName = value["serverName"] as? String,
              let url = value["url"] as? String else { return nil }
        let headerMap = value["headersFromEnv"] as? [String: Any] ?? [:]
        let headers = headerMap.keys.sorted().map { header in
            MCPControlDraftHeader(name: header,
                                  envName: headerMap[header] as? String ?? "")
        }
        return MCPControlDraft(serverName: serverName,
                               url: url,
                               headers: headers,
                               enabled: value["enabled"] as? Bool ?? true,
                               toolCallTimeoutMs: value["toolCallTimeoutMs"] as? Int ?? 60_000)
    }

    private func rollbackTransaction(_ token: String) throws {
        guard let snapshot = transactions[token] else { return }
        let rolledBack = try rollback(serverName: snapshot.serverName,
                                      expectedURL: snapshot.resultURL,
                                      expectedHeaders: snapshot.resultHeaders)
        guard rolledBack else {
            throw PhoneDSHError.invalidState(
                "MCP rollback did not restore the staged grant")
        }
        transactions.removeValue(forKey: token)
    }

    private func closeTransactions(for serverName: String) throws {
        let matching = transactions
            .filter { $0.value.serverName == serverName }
            .sorted { $0.value.createdAt < $1.value.createdAt }
            .map(\.key)
        for token in matching {
            // A failed rollback keeps the token; do not start a new edit that
            // would orphan the old grant/staging.
            try rollbackTransaction(token)
        }
    }

    /// Evict the oldest transaction by rolling it back *before* removing its
    /// token, so a full table can never drop the bookkeeping that owns a live
    /// egress grant or a staged Keychain account.
    private func makeRoomForTransaction() throws {
        while transactions.count >= maximumTransactions {
            guard let oldest = transactions.min(by: { $0.value.createdAt < $1.value.createdAt }),
                  let snapshot = transactions[oldest.key] else { return }
            let rolledBack = try rollback(serverName: snapshot.serverName,
                                          expectedURL: snapshot.resultURL,
                                          expectedHeaders: snapshot.resultHeaders)
            guard rolledBack else {
                throw PhoneDSHError.invalidState(
                    "MCP rollback did not restore the staged grant")
            }
            transactions.removeValue(forKey: oldest.key)
        }
    }

}

/// The real WKScriptMessageHandlerWithReply installed on the App's Web engine.
@MainActor
public final class MCPControlBridge: NSObject, WKScriptMessageHandlerWithReply {
    public static let messageHandlerName = "pdshMcpControl"

    private let controller: MCPControlController

    public init(controller: MCPControlController) {
        self.controller = controller
        super.init()
    }

    /// Script installed on the real Web engine. It runs before the page loads
    /// and marks in-flight grant transactions ownerless when the page
    /// navigates away or is reloaded. It deliberately does not roll them back:
    /// the page may have lost a successful upsert reply, so only the next real
    /// registry/materialized read decides. A WebContent crash is covered by
    /// the host removing the bridge and by the controller's finite timeout.
    public static func pageLifecycleScript() -> String {
        """
        (function () {
          function abandon() {
            try {
              var handlers = window.webkit && window.webkit.messageHandlers;
              var handler = handlers && handlers.\(messageHandlerName);
              if (handler && typeof handler.postMessage === 'function') {
                void handler.postMessage({ v: 1, action: 'abandon' });
              }
            } catch (e) {}
          }
          window.addEventListener('pagehide', abandon);
        })();
        """
    }

    /// Detach from the page. The host calls this before removing the message
    /// handler so an in-flight grant becomes ownerless instead of outliving
    /// its page; already committed rows only retry their native cleanup.
    public func close() {
        controller.abandonOpenTransactions()
        controller.retryPendingCommitsForClose()
    }

    public func userContentController(_ userContentController: WKUserContentController,
                                      didReceive message: WKScriptMessage,
                                      replyHandler: @escaping (Any?, String?) -> Void) {
        guard message.frameInfo.isMainFrame else {
            replyHandler(nil, "MCP bridge is main-frame only")
            return
        }
        Task { @MainActor in
            do {
                let reply = try await self.controller.handle(message.body)
                replyHandler(reply, nil)
            } catch let error as PhoneMCPAccessError {
                replyHandler(nil, error.errorDescription ?? "MCP access failed")
            } catch {
                replyHandler(nil, "MCP access failed")
            }
        }
    }
}
