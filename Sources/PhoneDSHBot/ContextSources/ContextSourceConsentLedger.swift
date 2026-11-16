// SPDX-License-Identifier: MIT

import Foundation

/// One per-source consent record. The JSON shape is frozen by
/// `spec/bot/v2/context-consent.schema.json`; the host is the only writer.
public struct BotContextSourceConsent: Codable, Sendable, Equatable {
    public var source: BotContextSourceKind
    public var authorization: BotSourceAuthorization
    public var permissionRevision: Int
    public var updatedAt: Int64
    public var updatedBy: BotSourceAuthorizationActor
    /// The Apple framework state. `restricted` is allowed here even though the
    /// consent state has no such value.
    public var osAuthorization: BotSourceAuthorization?
    public var detail: String?
    public var ownerBotID: String?

    public init(source: BotContextSourceKind,
                authorization: BotSourceAuthorization = .notDetermined,
                permissionRevision: Int = 0,
                updatedAt: Int64 = 0,
                updatedBy: BotSourceAuthorizationActor = .system,
                osAuthorization: BotSourceAuthorization? = nil,
                detail: String? = nil,
                ownerBotID: String? = nil) {
        self.source = source
        self.authorization = authorization
        self.permissionRevision = max(0, permissionRevision)
        self.updatedAt = max(0, updatedAt)
        self.updatedBy = updatedBy
        self.osAuthorization = osAuthorization
        self.detail = detail.map { String($0.prefix(120)) }
        self.ownerBotID = ownerBotID.map { String($0.prefix(128)) }
    }

    public var state: BotSourceAuthorizationState {
        BotSourceAuthorizationState(
            source: source, authorization: authorization,
            permissionRevision: permissionRevision, updatedAt: updatedAt,
            updatedBy: updatedBy, osAuthorization: osAuthorization, detail: detail,
            ownerBotID: ownerBotID)
    }

    private enum CodingKeys: String, CodingKey {
        case source, owner_bot_id, state, os_state, generation, updated_at_ms, by, reason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.allKeys.allSatisfy({
            [.source, .owner_bot_id, .state, .os_state, .generation, .updated_at_ms, .by, .reason]
                .contains($0)
        }) else {
            throw DecodingError.dataCorruptedError(
                forKey: .source, in: container,
                debugDescription: "consent entry has unknown members")
        }
        source = try container.decode(BotContextSourceKind.self, forKey: .source)
        ownerBotID = try container.decodeIfPresent(String.self, forKey: .owner_bot_id)
        authorization = try container.decode(BotSourceAuthorization.self, forKey: .state)
        guard authorization.isConsentState else {
            throw DecodingError.dataCorruptedError(
                forKey: .state, in: container,
                debugDescription: "restricted is an OS state, not a consent state")
        }
        if let os = try container.decodeIfPresent(BotSourceAuthorization.self, forKey: .os_state) {
            guard os != .revoked else {
                throw DecodingError.dataCorruptedError(
                    forKey: .os_state, in: container,
                    debugDescription: "revoked is not an OS state")
            }
            osAuthorization = os
        } else {
            osAuthorization = nil
        }
        permissionRevision = try container.decode(Int.self, forKey: .generation)
        updatedAt = try container.decode(Int64.self, forKey: .updated_at_ms)
        updatedBy = try container.decode(BotSourceAuthorizationActor.self, forKey: .by)
        detail = try container.decodeIfPresent(String.self, forKey: .reason)
        guard permissionRevision >= 0, updatedAt >= 0,
              ownerBotID.map({ !$0.isEmpty && $0.unicodeScalars.count <= 128 }) ?? true,
              detail.map({ !$0.isEmpty && $0.unicodeScalars.count <= 120 }) ?? true else {
            throw DecodingError.dataCorruptedError(
                forKey: .generation, in: container,
                debugDescription: "consent entry values are outside the frozen bounds")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(source, forKey: .source)
        try container.encodeIfPresent(ownerBotID, forKey: .owner_bot_id)
        try container.encode(authorization, forKey: .state)
        try container.encodeIfPresent(osAuthorization, forKey: .os_state)
        try container.encode(permissionRevision, forKey: .generation)
        try container.encode(updatedAt, forKey: .updated_at_ms)
        try container.encode(updatedBy, forKey: .by)
        try container.encodeIfPresent(detail, forKey: .reason)
    }
}

/// One Bot's subscription to one source. Revocation removes the subscription;
/// the durable consent event remains the audit record.
public struct BotContextSourceSubscription: Codable, Sendable, Equatable {
    public var botID: String
    public var source: BotContextSourceKind
    public var subscribedAt: Int64
    public var permissionRevision: Int

    public init(botID: String, source: BotContextSourceKind,
                subscribedAt: Int64, permissionRevision: Int) {
        self.botID = botID
        self.source = source
        self.subscribedAt = max(0, subscribedAt)
        self.permissionRevision = max(0, permissionRevision)
    }

    private enum CodingKeys: String, CodingKey {
        case bot_id, source, subscribed_at_ms, consent_generation
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.allKeys.allSatisfy({
            [.bot_id, .source, .subscribed_at_ms, .consent_generation].contains($0)
        }) else {
            throw DecodingError.dataCorruptedError(
                forKey: .bot_id, in: container,
                debugDescription: "subscription has unknown members")
        }
        botID = try container.decode(String.self, forKey: .bot_id)
        source = try container.decode(BotContextSourceKind.self, forKey: .source)
        subscribedAt = try container.decode(Int64.self, forKey: .subscribed_at_ms)
        permissionRevision = try container.decode(Int.self, forKey: .consent_generation)
        guard !botID.isEmpty, botID.unicodeScalars.count <= 128,
              subscribedAt >= 0, permissionRevision >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .bot_id, in: container,
                debugDescription: "subscription values are outside the frozen bounds")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(botID, forKey: .bot_id)
        try container.encode(source, forKey: .source)
        try container.encode(subscribedAt, forKey: .subscribed_at_ms)
        try container.encode(permissionRevision, forKey: .consent_generation)
    }
}

/// Versioned consent document matching the frozen key/schema.
public struct BotContextConsentDocument: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public var v: Int
    public var consents: [BotContextSourceConsent]
    public var subscriptions: [BotContextSourceSubscription]

    public init(v: Int = BotContextConsentDocument.currentVersion,
                consents: [BotContextSourceConsent] = [],
                subscriptions: [BotContextSourceSubscription] = []) {
        self.v = v
        self.consents = consents
        self.subscriptions = subscriptions
    }

    private enum CodingKeys: String, CodingKey { case v, consents, subscriptions }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.allKeys.allSatisfy({ [.v, .consents, .subscriptions].contains($0) }) else {
            throw DecodingError.dataCorruptedError(
                forKey: .v, in: container,
                debugDescription: "consent document has unknown members")
        }
        v = try container.decode(Int.self, forKey: .v)
        consents = try container.decodeIfPresent([BotContextSourceConsent].self, forKey: .consents) ?? []
        subscriptions = try container
            .decodeIfPresent([BotContextSourceSubscription].self, forKey: .subscriptions) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(v, forKey: .v)
        try container.encode(consents, forKey: .consents)
        try container.encode(subscriptions, forKey: .subscriptions)
    }

    /// Rejects duplicate sources/subscriptions, unknown versions and counts
    /// beyond the frozen maxima. A malformed document is never normalized into
    /// a permissive one.
    public func validated() throws -> BotContextConsentDocument {
        guard v == Self.currentVersion else {
            throw BotContextSourceError.invalidRequest("unsupported consent document version \(v)")
        }
        guard consents.count <= 16, subscriptions.count <= 32 else {
            throw BotContextSourceError.invalidRequest("consent document exceeds its entry limit")
        }
        var seenSources: Set<BotContextSourceKind> = []
        for consent in consents {
            guard seenSources.insert(consent.source).inserted else {
                throw BotContextSourceError.invalidRequest("duplicate consent for \(consent.source.rawValue)")
            }
            guard consent.authorization.isConsentState,
                  consent.permissionRevision >= 0,
                  consent.updatedAt >= 0 else {
                throw BotContextSourceError.invalidRequest("invalid consent entry")
            }
        }
        var seenSubscriptions: Set<String> = []
        for subscription in subscriptions {
            let key = subscription.botID + "\u{0}" + subscription.source.rawValue
            guard !subscription.botID.isEmpty, subscription.botID.unicodeScalars.count <= 128,
                  seenSubscriptions.insert(key).inserted,
                  subscription.permissionRevision >= 0 else {
                throw BotContextSourceError.invalidRequest("duplicate or invalid subscription")
            }
        }
        return self
    }
}

/// Durable port for the consent document. The concrete store uses the frozen
/// UserDefaults key; the ledger never invents a second persistence mechanism.
public protocol BotContextSourceConsentPersisting: Sendable {
    func load() async throws -> BotContextConsentDocument?
    func save(_ document: BotContextConsentDocument) async throws
}

public actor InMemoryBotContextSourceConsentStore: BotContextSourceConsentPersisting {
    private var document: BotContextConsentDocument?

    public init(document: BotContextConsentDocument? = nil) {
        self.document = document
    }

    public func load() async throws -> BotContextConsentDocument? { document }
    public func save(_ document: BotContextConsentDocument) async throws { self.document = document }
    public func current() -> BotContextConsentDocument? { document }
}

/// The frozen P18 key (`spec/bot/v2/context-sources.md` §2). A corrupt or
/// unknown-version value is returned as a load error; the ledger then rebuilds
/// safe defaults and the next save overwrites it. It is never read as
/// authorized.
public actor UserDefaultsBotContextSourceConsentStore: BotContextSourceConsentPersisting {
    public static let key = "phone-dsh.bot.context-source-consent.v1"
    private let defaults: UserDefaults
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        decoder = JSONDecoder()
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }

    public func load() async throws -> BotContextConsentDocument? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try decoder.decode(BotContextConsentDocument.self, from: data).validated()
    }

    public func save(_ document: BotContextConsentDocument) async throws {
        let validated = try document.validated()
        let data = try encoder.encode(validated)
        defaults.set(data, forKey: Self.key)
    }
}

/// The single writer for per-source consent and per-Bot subscriptions.
public actor BotContextConsentLedger {
    private let store: any BotContextSourceConsentPersisting
    private let now: @Sendable () -> Int64
    private var consents: [BotContextSourceKind: BotContextSourceConsent] = [:]
    private var subscriptions: [String: Set<BotContextSourceKind>] = [:]
    private var subscriptionRecords: [BotContextSourceSubscription] = []
    private var loaded = false
    private var loadError: String?

    public init(store: any BotContextSourceConsentPersisting,
                sources: [BotContextSourceKind] = BotContextSourceKind.allCases,
                now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }) {
        self.store = store
        self.now = now
        for source in sources {
            consents[source] = BotContextSourceConsent(source: source)
        }
    }

    @discardableResult
    public func load() async -> String? {
        guard !loaded else { return loadError }
        loaded = true
        do {
            guard let raw = try await store.load() else { return nil }
            let document = try raw.validated()
            resetToSafeDefaults()
            for consent in document.consents {
                consents[consent.source] = consent
            }
            for subscription in document.subscriptions {
                guard let consent = consents[subscription.source],
                      consent.authorization.allowsReading,
                      consent.permissionRevision == subscription.permissionRevision else {
                    continue
                }
                if subscriptions[subscription.botID, default: []].insert(subscription.source).inserted {
                    subscriptionRecords.append(subscription)
                }
            }
            return nil
        } catch {
            loadError = String(describing: error)
            resetToSafeDefaults()
            return loadError
        }
    }

    public func document() -> BotContextConsentDocument {
        BotContextConsentDocument(
            consents: BotContextSourceKind.allCases.compactMap { consents[$0] },
            subscriptions: subscriptionRecords.sorted {
                ($0.botID, $0.source.rawValue) < ($1.botID, $1.source.rawValue)
            })
    }

    public func state(for source: BotContextSourceKind) -> BotSourceAuthorizationState {
        (consents[source] ?? BotContextSourceConsent(source: source)).state
    }

    public func states() -> [BotSourceAuthorizationState] {
        BotContextSourceKind.allCases.map { state(for: $0) }
    }

    /// One atomic snapshot for a read view: state and subscriptions come from
    /// the same ledger revision, so a concurrent grant/revoke cannot produce a
    /// mixed-generation view.
    public func snapshot() -> (
        states: [BotContextSourceKind: BotSourceAuthorizationState],
        subscriptions: [String: Set<BotContextSourceKind>],
        subscriptionRevisions: [String: [BotContextSourceKind: Int]]
    ) {
        var states: [BotContextSourceKind: BotSourceAuthorizationState] = [:]
        for source in BotContextSourceKind.allCases {
            states[source] = state(for: source)
        }
        var revisions: [String: [BotContextSourceKind: Int]] = [:]
        for record in subscriptionRecords {
            revisions[record.botID, default: [:]][record.source] = record.permissionRevision
        }
        return (states, subscriptions, revisions)
    }

    public func isSubscribed(botID: String, source: BotContextSourceKind) -> Bool {
        guard let consent = consents[source], consent.authorization.allowsReading else { return false }
        guard subscriptions[botID]?.contains(source) == true else { return false }
        return subscriptionRecord(botID: botID, source: source)?.permissionRevision == consent.permissionRevision
    }

    public func subscriptions(for botID: String) -> [BotContextSourceKind] {
        BotContextSourceKind.allCases.filter { isSubscribed(botID: botID, source: $0) }
    }

    public func subscribedBots(for source: BotContextSourceKind) -> [String] {
        subscriptions.filter { $0.value.contains(source) && isSubscribed(botID: $0.key, source: source) }
            .keys.sorted()
    }

    public func subscriptionStart(botID: String, source: BotContextSourceKind) -> Int64? {
        guard isSubscribed(botID: botID, source: source) else { return nil }
        return subscriptionRecord(botID: botID, source: source)?.subscribedAt
    }

    /// Mirrors an OS status change. Denial/restriction demotes an authorized
    /// source; an OS grant never opts the user in and never resurrects a source
    /// the user explicitly revoked.
    @discardableResult
    public func noteOSStatus(source: BotContextSourceKind,
                             status: BotSourceAuthorization) async throws -> BotSourceAuthorizationState {
        guard var consent = consents[source] else {
            throw BotContextSourceError.notRegistered(source)
        }
        guard status != .revoked else {
            throw BotContextSourceError.invalidRequest("revoked is not an OS status")
        }
        consent.osAuthorization = status
        consent.updatedAt = now()
        consent.updatedBy = .os
        if status == .denied || status == .restricted {
            if consent.authorization.allowsReading {
                consent.authorization = .denied
                consent.permissionRevision += 1
                consent.detail = "os-restricted"
                let previousSubscriptions = subscriptions
                let previousRecords = subscriptionRecords
                subscriptions = subscriptions.mapValues { $0.subtracting([source]) }
                subscriptionRecords = subscriptionRecords.filter { $0.source != source }
                do {
                    try await persist(replacing: consent)
                } catch {
                    subscriptions = previousSubscriptions
                    subscriptionRecords = previousRecords
                    throw error
                }
                return state(for: source)
            }
            if consent.authorization == .notDetermined {
                consent.authorization = .denied
                consent.detail = "os-denied"
            }
        }
        try await persist(replacing: consent)
        return state(for: source)
    }

    /// Explicit user opt-in after the OS status is already allowing.
    @discardableResult
    public func grant(source: BotContextSourceKind,
                      by actor: BotSourceAuthorizationActor = .user,
                      authorization: BotSourceAuthorization = .authorized,
                      detail: String? = nil) async throws -> BotSourceAuthorizationState {
        guard var consent = consents[source] else {
            throw BotContextSourceError.notRegistered(source)
        }
        guard authorization.allowsReading, authorization.isConsentState else {
            throw BotContextSourceError.invalidRequest("grant requires authorized or limited")
        }
        guard consent.authorization != .revoked || actor == .user else {
            throw BotContextSourceError.revoked(source)
        }
        consent.authorization = authorization
        consent.permissionRevision += 1
        consent.updatedAt = now()
        consent.updatedBy = actor
        consent.detail = detail
        try await persist(replacing: consent)
        return state(for: source)
    }

    @discardableResult
    public func revoke(source: BotContextSourceKind,
                       by actor: BotSourceAuthorizationActor = .user,
                       reason: String) async throws -> BotSourceAuthorizationState {
        guard var consent = consents[source] else {
            throw BotContextSourceError.notRegistered(source)
        }
        consent.authorization = .revoked
        consent.permissionRevision += 1
        consent.updatedAt = now()
        consent.updatedBy = actor
        consent.detail = String(reason.prefix(120))
        let nextSubscriptions = subscriptions.mapValues { $0.subtracting([source]) }
        let nextRecords = subscriptionRecords.filter { $0.source != source }
        let previous = (consents, subscriptions, subscriptionRecords)
        consents[source] = consent
        subscriptions = nextSubscriptions
        subscriptionRecords = nextRecords
        do {
            try await persistDocument()
            return state(for: source)
        } catch {
            consents = previous.0
            subscriptions = previous.1
            subscriptionRecords = previous.2
            throw error
        }
    }

    public func subscribe(botID: String, source: BotContextSourceKind) async throws {
        let trimmed = botID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.unicodeScalars.count <= 128 else {
            throw BotContextSourceError.invalidRequest("botID must be 1...128 characters")
        }
        guard let consent = consents[source], consent.authorization.allowsReading else {
            throw BotContextSourceError.notAuthorized(source, permissionRevision: state(for: source).permissionRevision)
        }
        if isSubscribed(botID: trimmed, source: source) { return }
        let record = BotContextSourceSubscription(
            botID: trimmed, source: source, subscribedAt: now(),
            permissionRevision: consent.permissionRevision)
        let previousSubscriptions = subscriptions
        let previousRecords = subscriptionRecords
        subscriptions[trimmed, default: []].insert(source)
        subscriptionRecords.removeAll { $0.botID == trimmed && $0.source == source }
        subscriptionRecords.append(record)
        do {
            try await persistDocument()
        } catch {
            subscriptions = previousSubscriptions
            subscriptionRecords = previousRecords
            throw error
        }
    }

    public func unsubscribe(botID: String, source: BotContextSourceKind) async throws {
        let before = subscriptions[botID]?.contains(source) == true
        guard before else { return }
        let previousSubscriptions = subscriptions
        let previousRecords = subscriptionRecords
        subscriptions[botID]?.remove(source)
        if subscriptions[botID]?.isEmpty == true { subscriptions.removeValue(forKey: botID) }
        subscriptionRecords.removeAll { $0.botID == botID && $0.source == source }
        do {
            try await persistDocument()
        } catch {
            subscriptions = previousSubscriptions
            subscriptionRecords = previousRecords
            throw error
        }
    }

    private func subscriptionRecord(botID: String, source: BotContextSourceKind) -> BotContextSourceSubscription? {
        subscriptionRecords.first { $0.botID == botID && $0.source == source }
    }

    private func persist(replacing consent: BotContextSourceConsent) async throws {
        guard let previous = consents[consent.source] else {
            throw BotContextSourceError.notRegistered(consent.source)
        }
        consents[consent.source] = consent
        do {
            try await persistDocument()
        } catch {
            consents[consent.source] = previous
            throw error
        }
    }

    private func persistDocument() async throws {
        try await store.save(document())
    }

    private func resetToSafeDefaults() {
        consents = [:]
        for source in BotContextSourceKind.allCases {
            consents[source] = BotContextSourceConsent(source: source)
        }
        subscriptions = [:]
        subscriptionRecords = []
    }
}
