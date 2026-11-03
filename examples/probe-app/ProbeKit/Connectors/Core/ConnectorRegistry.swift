// SPDX-License-Identifier: MIT

import Foundation

public struct ConnectorRegistrySnapshot: Sendable {
    public var records: [String: ConnectorRecord]
    public var grants: [String: ConnectorGrant]
    public var credentialRefs: [String: String]

    public init(records: [String: ConnectorRecord] = [:],
                grants: [String: ConnectorGrant] = [:],
                credentialRefs: [String: String] = [:]) {
        self.records = records
        self.grants = grants
        self.credentialRefs = credentialRefs
    }
}

public protocol ConnectorRegistryPersisting: Sendable {
    func load() throws -> ConnectorRegistrySnapshot
    func save(record: ConnectorRecord, grant: ConnectorGrant?, credentialRef: String?) throws
    func save(record: ConnectorRecord) throws
    func revoke(_ connectorID: String) throws
}

public protocol ConnectorKeyValueStore: Sendable {
    func string(forKey key: String) throws -> String?
    func setString(_ value: String?, forKey key: String) throws
}

public struct ConnectorVerificationFailure: Error, Sendable {
    public let state: ConnectorState
    public let issue: String

    public init(state: ConnectorState, issue: String) {
        self.state = state
        self.issue = issue
    }
}

public enum ConnectorRegistryError: Error, Equatable, Sendable {
    case invalidTransition
    case verificationFailed(String)
    case persistenceFailed
}

private final class ConnectorUpdateBroadcaster: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: ConnectorRecord]
    private var continuations: [UUID: AsyncStream<ConnectorRecord>.Continuation] = [:]

    init(records: [String: ConnectorRecord]) { self.records = records }

    func updates() -> AsyncStream<ConnectorRecord> {
        let id = UUID()
        lock.lock()
        let current = records.values.sorted { $0.connectorID < $1.connectorID }
        let stream = AsyncStream<ConnectorRecord> { continuation in
            continuations[id] = continuation
            for record in current { continuation.yield(record) }
            continuation.onTermination = { @Sendable _ in self.remove(id) }
        }
        lock.unlock()
        return stream
    }

    func publish(_ record: ConnectorRecord) {
        lock.lock()
        records[record.connectorID] = record
        let current = continuations.values
        lock.unlock()
        for continuation in current { continuation.yield(record) }
    }

    private func remove(_ id: UUID) {
        lock.lock()
        continuations.removeValue(forKey: id)
        lock.unlock()
    }
}

public actor PersistentConnectorRegistry: ConnectorRegistry {
    private let store: any ConnectorRegistryPersisting
    private let credentials: (any ConnectorCredentialStore)?
    private var records: [String: ConnectorRecord]
    private var grants: [String: ConnectorGrant]
    private var credentialRefs: [String: String]
    private let broadcaster: ConnectorUpdateBroadcaster

    public init(store: any ConnectorRegistryPersisting,
                credentials: (any ConnectorCredentialStore)? = nil) throws {
        self.store = store
        self.credentials = credentials
        let snapshot = try store.load()
        records = snapshot.records
        grants = snapshot.grants
        credentialRefs = snapshot.credentialRefs
        broadcaster = ConnectorUpdateBroadcaster(records: snapshot.records)
    }

    public func state(of connectorID: String) async -> ConnectorRecord {
        records[connectorID] ?? ConnectorRecord(connectorID: connectorID, state: .disconnected)
    }

    public func grant(of connectorID: String) async -> ConnectorGrant? {
        grants[connectorID]
    }

    public nonisolated func updates() -> AsyncStream<ConnectorRecord> {
        broadcaster.updates()
    }

    @discardableResult
    public func connect(_ connectorID: String,
                        grant: ConnectorGrant,
                        credentialRef: String,
                        verify: @Sendable () async throws -> Void) async throws -> ConnectorRecord {
        let previous = records[connectorID] ?? ConnectorRecord(connectorID: connectorID, state: .disconnected)
        guard previous.state != .connecting else { throw ConnectorRegistryError.invalidTransition }
        let connecting = ConnectorRecord(connectorID: connectorID, state: .connecting)
        try persist(connecting)
        do {
            try await verify()
            let connected = ConnectorRecord(connectorID: connectorID, state: .connected,
                                            lastVerifiedAt: Date())
            try store.save(record: connected, grant: grant, credentialRef: credentialRef)
            records[connectorID] = connected
            grants[connectorID] = grant
            credentialRefs[connectorID] = credentialRef
            broadcaster.publish(connected)
            return connected
        } catch {
            let failure = error as? ConnectorVerificationFailure
            let failed = ConnectorRecord(connectorID: connectorID,
                                         state: failure?.state ?? .needsAttention,
                                         issue: failure?.issue ?? "连接器凭据或目标范围核验失败")
            try? persist(failed)
            throw ConnectorRegistryError.verificationFailed(failed.issue ?? "连接器核验失败")
        }
    }

    public func markNeedsAttention(_ connectorID: String, issue: String) throws {
        guard records[connectorID] != nil else { throw ConnectorRegistryError.invalidTransition }
        try persist(ConnectorRecord(connectorID: connectorID, state: .needsAttention, issue: issue))
    }

    public func markExpired(_ connectorID: String, issue: String = "连接器凭据已过期") throws {
        guard records[connectorID] != nil else { throw ConnectorRegistryError.invalidTransition }
        try persist(ConnectorRecord(connectorID: connectorID, state: .expired, issue: issue))
    }

    public func revoke(_ connectorID: String) async throws {
        if let reference = credentialRefs[connectorID] {
            try credentials?.deleteCredential(for: reference)
        }
        try store.revoke(connectorID)
        grants.removeValue(forKey: connectorID)
        credentialRefs.removeValue(forKey: connectorID)
        let revoked = ConnectorRecord(connectorID: connectorID, state: .revoked)
        try store.save(record: revoked)
        records[connectorID] = revoked
        broadcaster.publish(revoked)
    }

    private func persist(_ record: ConnectorRecord) throws {
        try store.save(record: record)
        records[record.connectorID] = record
        broadcaster.publish(record)
    }
}

public final class ConnectorAttentionSource: AttentionSource {
    public let owner: AttentionOwner = .discover
    private let registry: any ConnectorRegistry

    public init(registry: any ConnectorRegistry) {
        self.registry = registry
    }

    public func items() -> AsyncStream<[AttentionItem]> {
        AsyncStream { continuation in
            let task = Task {
                var items: [String: AttentionItem] = [:]
                for await record in registry.updates() {
                    if [.needsAttention, .expired, .error].contains(record.state) {
                        items[record.connectorID] = AttentionItem(
                            title: "\(record.connectorID) 需要处理",
                            reason: record.issue ?? "连接器需要重新授权",
                            route: .discover(.connector(record.connectorID)))
                    } else {
                        items.removeValue(forKey: record.connectorID)
                    }
                    continuation.yield(items.values.sorted { $0.title < $1.title })
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}
