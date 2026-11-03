// SPDX-License-Identifier: MIT

import Foundation
import ProbeKit

final class InMemoryConnectorCredentials: ConnectorCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func saveCredential(_ credential: String, for reference: String) throws {
        lock.lock()
        values[reference] = credential
        lock.unlock()
    }

    func deleteCredential(for reference: String) throws {
        lock.lock()
        values.removeValue(forKey: reference)
        lock.unlock()
    }

    func withCredential<T>(for reference: String,
                           _ body: @Sendable (String) throws -> T) throws -> T? {
        lock.lock()
        let value = values[reference]
        lock.unlock()
        guard let value else { return nil }
        return try body(value)
    }

    func contains(_ reference: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return values[reference] != nil
    }
}

struct ConnectorRequestSnapshot: Equatable {
    let method: String
    let url: String
    let hasAuthorization: Bool
    let body: String?
}

actor MockConnectorHTTPTransport: ConnectorHTTPTransport {
    private struct Stub {
        let status: Int
        let headers: [String: String]
        let body: String
        let failure: ConnectorHTTPError?
    }

    private var stubs: [String: [Stub]] = [:]
    private var requests: [ConnectorRequestSnapshot] = []

    func stub(_ path: String, method: String = "GET", status: Int = 200,
              headers: [String: String] = [:], json: String = "{}",
              failure: ConnectorHTTPError? = nil, append: Bool = false) {
        let key = "\(method) \(path)"
        let stub = Stub(status: status, headers: headers, body: json, failure: failure)
        if append { stubs[key, default: []].append(stub) } else { stubs[key] = [stub] }
    }

    func send(_ request: URLRequest) async throws -> ConnectorHTTPResponse {
        let url = request.url?.absoluteString ?? ""
        requests.append(ConnectorRequestSnapshot(method: request.httpMethod ?? "GET", url: url,
                                                 hasAuthorization: request.value(forHTTPHeaderField: "Authorization") != nil,
                                                 body: request.httpBody.map { String(decoding: $0, as: UTF8.self) }))
        let key = "\(request.httpMethod ?? "GET") \(request.url?.path ?? "")"
        guard var candidates = stubs[key], let stub = candidates.first else {
            throw ConnectorHTTPError.networkUnavailable
        }
        if candidates.count > 1 {
            candidates.removeFirst()
            stubs[key] = candidates
        }
        if let failure = stub.failure { throw failure }
        return ConnectorHTTPResponse(statusCode: stub.status, headers: stub.headers, data: Data(stub.body.utf8))
    }

    func snapshot() -> [ConnectorRequestSnapshot] { requests }
}

final class InMemoryConnectorStore: ConnectorRegistryPersisting, ConnectorKeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshotValue = ConnectorRegistrySnapshot()
    private var values: [String: String] = [:]

    func load() throws -> ConnectorRegistrySnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshotValue
    }

    func save(record: ConnectorRecord, grant: ConnectorGrant?, credentialRef: String?) throws {
        lock.lock()
        snapshotValue.records[record.connectorID] = record
        if let grant { snapshotValue.grants[record.connectorID] = grant }
        if let credentialRef { snapshotValue.credentialRefs[record.connectorID] = credentialRef }
        lock.unlock()
    }

    func save(record: ConnectorRecord) throws {
        lock.lock()
        snapshotValue.records[record.connectorID] = record
        lock.unlock()
    }

    func revoke(_ connectorID: String) throws {
        lock.lock()
        snapshotValue.records.removeValue(forKey: connectorID)
        snapshotValue.grants.removeValue(forKey: connectorID)
        snapshotValue.credentialRefs.removeValue(forKey: connectorID)
        lock.unlock()
    }

    func string(forKey key: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func setString(_ value: String?, forKey key: String) throws {
        lock.lock()
        values[key] = value
        lock.unlock()
    }
}

actor AllowingWriteGate: WriteGate {
    private(set) var calls = 0
    var allow = true

    func authorize(tool: ConnectorToolDescriptor, argumentsJSON: String,
                   caller: ToolCaller, grant: ConnectorGrant) async -> GateDecision {
        calls += 1
        if !allow { return .deny(GateDenial(code: "test_denied", message: "测试门禁拒绝")) }
        let mandateID: UUID
        if case .personalAgent(let mandate) = caller { mandateID = mandate.mandateID } else { mandateID = UUID() }
        return .allow(OperationIntent(toolName: tool.internalName, argumentsJSON: argumentsJSON,
                                      digest: "test-digest", mandateID: mandateID))
    }
}

actor RecordingOperationLedger: OperationLedger {
    private(set) var records: [UUID: OperationRecord] = [:]
    private(set) var prepareCount = 0

    func prepare(_ intent: OperationIntent) async throws -> OperationRecord {
        prepareCount += 1
        let record = OperationRecord(id: intent.id, intent: intent)
        records[intent.id] = record
        return record
    }

    func markCommitting(_ id: UUID) async throws { update(id, phase: .committing) }
    func commit(_ id: UUID, receipt: ProviderReceipt) async throws {
        update(id, phase: .committed)
        records[id]?.receipt = receipt
    }
    func markUnknown(_ id: UUID, reason: String) async throws {
        update(id, phase: .unknown)
        records[id]?.failureReason = reason
    }
    func pending() async -> [OperationRecord] {
        records.values.filter { [.prepared, .committing, .unknown, .undoWindow].contains($0.phase) }
    }
    private func update(_ id: UUID, phase: OperationPhase) {
        records[id]?.phase = phase
        records[id]?.updatedAt = Date()
    }
}

func connectedGitHubRegistry(credentials: InMemoryConnectorCredentials,
                             repositories: [String] = ["owner/repo"]) async throws -> PersistentConnectorRegistry {
    let registry = try PersistentConnectorRegistry(store: InMemoryConnectorStore(), credentials: credentials)
    let grant = ConnectorGrant(connectorID: "github", version: 1,
                               allowedActions: [.read, .githubComment, .githubCreateIssue],
                               scope: GrantScope(repositories: repositories))
    _ = try await registry.connect("github", grant: grant, credentialRef: "github.pat") {}
    return registry
}

func readMandate(actions: Set<MandateAction> = [.read]) -> WorkMandate {
    WorkMandate(mandateID: UUID(), version: 1, requestID: UUID(), principal: "test",
                source: .phone, goal: "test", allowedActions: actions,
                allowedEvidenceRefs: [],
                targets: MandateTargets(repository: "owner/repo", origin: .userNamed),
                validUntil: Date().addingTimeInterval(300))
}

let githubRepositoryJSON = #"{"full_name":"owner/repo","private":false,"html_url":"https://github.com/owner/repo","default_branch":"main"}"#
let githubIssueJSON = #"{"number":7,"title":"Issue","state":"open","body":"body","html_url":"https://github.com/owner/repo/issues/7","user":{"login":"octo"},"created_at":"2026-11-03T00:00:00Z","updated_at":"2026-11-03T00:00:00Z"}"#
let githubPullJSON = #"{"number":7,"title":"PR","state":"open","body":"body","html_url":"https://github.com/owner/repo/pull/7","head":{"ref":"feature","sha":"abcdef1234567890"},"base":{"ref":"main","sha":"1234567890abcdef"},"user":{"login":"octo"},"draft":false}"#
