// SPDX-License-Identifier: MIT

import Foundation
@testable import ProbeKit
import XCTest

final class PA_GmailTokenStore: GmailTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: GmailTokenSet?

    init(_ value: GmailTokenSet? = nil) { self.value = value }

    func read<T>(_ body: (GmailTokenSet?) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(value)
    }

    func write(_ tokens: GmailTokenSet?) throws {
        lock.lock()
        value = tokens
        lock.unlock()
    }

    var snapshot: GmailTokenSet? { (try? read { $0 }) ?? nil }
}

actor PA_GmailTransport: GmailHTTPTransport {
    private var responses: [String: [Result<GmailHTTPResponse, Error>]] = [:]
    private(set) var requests: [GmailHTTPRequest] = []

    func enqueue(_ path: String, result: Result<GmailHTTPResponse, Error>) {
        responses[path, default: []].append(result)
    }

    func enqueueJSON(_ path: String, status: Int = 200, _ json: String) {
        enqueue(path, result: .success(GmailHTTPResponse(statusCode: status, data: Data(json.utf8))))
    }

    func send(_ request: GmailHTTPRequest) async throws -> GmailHTTPResponse {
        requests.append(request)
        let key = "\(request.method) \(request.path)"
        guard var queue = responses[key], !queue.isEmpty else {
            return GmailHTTPResponse(statusCode: 500, data: Data("{\"error\":\"unstubbed\"}".utf8))
        }
        let result = queue.removeFirst()
        responses[key] = queue
        return try result.get()
    }

    func requests(for path: String) -> [GmailHTTPRequest] { requests.filter { $0.path == path } }
}

actor PA_GmailGrantProvider: GmailGrantProviding {
    var grant: ConnectorGrant?
    init(_ grant: ConnectorGrant?) { self.grant = grant }
    func gmailGrant() async -> ConnectorGrant? { grant }
}

struct PA_GmailAllowGate: WriteGate {
    func authorize(tool: ConnectorToolDescriptor, argumentsJSON: String,
                   caller: ToolCaller, grant: ConnectorGrant) async -> GateDecision {
        let mandateID: UUID
        if case .personalAgent(let mandate) = caller { mandateID = mandate.mandateID } else { mandateID = UUID() }
        return .allow(OperationIntent(toolName: tool.internalName, argumentsJSON: argumentsJSON,
                                      digest: "host-gate-digest", mandateID: mandateID))
    }
}

actor PA_GmailLedger: OperationLedger {
    private(set) var records: [UUID: OperationRecord] = [:]

    func seed(_ record: OperationRecord) { records[record.id] = record }

    func prepare(_ intent: OperationIntent) throws -> OperationRecord {
        let record = OperationRecord(id: intent.id, intent: intent)
        records[record.id] = record
        return record
    }

    func markCommitting(_ id: UUID) throws { update(id, phase: .committing) }
    func commit(_ id: UUID, receipt: ProviderReceipt) throws {
        update(id, phase: .committed)
        records[id]?.receipt = receipt
    }
    func markUnknown(_ id: UUID, reason: String) throws {
        update(id, phase: .unknown)
        records[id]?.failureReason = reason
    }
    func reconcile(_ id: UUID, receipt: ProviderReceipt?) throws -> OperationRecord {
        if let receipt {
            update(id, phase: .reconciled)
            records[id]?.receipt = receipt
        } else {
            update(id, phase: .unknown)
        }
        return records[id]!
    }
    func pending() -> [OperationRecord] {
        records.values.filter { [.prepared, .undoWindow, .committing, .unknown].contains($0.phase) }
    }
    func record(_ id: UUID) -> OperationRecord? { records[id] }
    var all: [OperationRecord] { records.values.sorted { $0.createdAt < $1.createdAt } }

    private func update(_ id: UUID, phase: OperationPhase) {
        records[id]?.phase = phase
        records[id]?.updatedAt = Date()
    }
}

struct PA_GmailImmediateUndo: GmailUndoWindow {
    func wait() async throws {}
}

actor PA_GmailReadingMock: GmailReading {
    var searchResults: [GmailSearchResult] = []
    var historyResults: [Result<GmailHistoryChange, Error>] = []
    var messages: [String: GmailMessage] = [:]
    var threads: [String: GmailThread] = [:]
    var historyIDs: [String] = []
    private(set) var sendSearchQueries: [GmailSearchQuery] = []

    func enqueueSearch(_ result: GmailSearchResult) { searchResults.append(result) }
    func enqueueHistory(_ result: Result<GmailHistoryChange, Error>) { historyResults.append(result) }
    func setThread(_ thread: GmailThread) { threads[thread.id] = thread }

    func search(_ query: GmailSearchQuery) async throws -> GmailSearchResult {
        sendSearchQueries.append(query)
        guard !searchResults.isEmpty else { return GmailSearchResult(messages: [], nextPageToken: nil) }
        return searchResults.removeFirst()
    }

    func message(id: String, includeBody: Bool) async throws -> GmailMessage {
        guard let message = messages[id] else { throw GmailError.httpStatus(404) }
        return message
    }

    func thread(id: String, includeBody: Bool) async throws -> GmailThread {
        guard let thread = threads[id] else { throw GmailError.httpStatus(404) }
        return thread
    }

    func history(startHistoryID: String) async throws -> GmailHistoryChange {
        historyIDs.append(startHistoryID)
        guard !historyResults.isEmpty else { return GmailHistoryChange(messagesAdded: [], historyID: startHistoryID) }
        return try historyResults.removeFirst().get()
    }

    func profile() async throws -> GmailProfile { GmailProfile(emailAddress: "owner@example.com", historyID: "1") }
}

func PA_GmailTokens(expired: Bool = false) -> GmailTokenSet {
    GmailTokenSet(accessToken: "test-access-token", refreshToken: "test-refresh-token",
                  expiresAt: Date().addingTimeInterval(expired ? -60 : 3600), scopes: [GmailScope.readOnly])
}

func PA_GmailConfiguration(scopes: [String] = [GmailScope.readOnly]) -> GmailOAuthConfiguration {
    GmailOAuthConfiguration(clientID: "test-client.apps.googleusercontent.com",
                            redirectURI: URL(string: "dev.phone-dsh.probe:/oauth/gmail")!, scopes: scopes)
}

func PA_GmailManager(store: PA_GmailTokenStore, transport: PA_GmailTransport,
                     scopes: [String] = [GmailScope.readOnly]) -> GmailTokenManager {
    GmailTokenManager(configuration: PA_GmailConfiguration(scopes: scopes), store: store, transport: transport)
}

func PA_GmailGrant(actions: Set<MandateAction> = [.read],
                   scopes: [String] = [GmailScope.readOnly]) -> ConnectorGrant {
    ConnectorGrant(connectorID: "gmail", version: 1, allowedActions: actions,
                   scope: GrantScope(gmailAccount: "owner@example.com", rawScopes: scopes))
}

func PA_GmailMandate(actions: Set<MandateAction> = [.read], threadIDs: [String] = [],
                     recipients: [String] = [], evidence: Set<EvidenceRef> = [],
                     origin: TargetOrigin = .userNamed) -> WorkMandate {
    WorkMandate(mandateID: UUID(), version: 1, requestID: UUID(), principal: "owner@example.com", source: .phone,
                goal: "Gmail test", allowedActions: actions, allowedEvidenceRefs: evidence,
                targets: MandateTargets(gmailThreadIDs: threadIDs, recipientIdentities: recipients, origin: origin),
                validUntil: Date().addingTimeInterval(3600))
}

func PA_GmailMessage(id: String, threadID: String = "thread1", historyID: String = "10",
                     operationID: String? = nil, digest: String? = nil) -> GmailMessage {
    GmailMessage(id: id, threadID: threadID, historyID: historyID,
                 internalDate: Date(timeIntervalSince1970: 1_700_000_000), snippet: "snippet",
                 subject: "Subject \(id)", from: "sender@example.com", to: ["owner@example.com"],
                 rfc822MessageID: nil, operationID: operationID, requestDigest: digest, body: nil,
                 link: URL(string: "https://mail.google.com/mail/#all/\(id)")!)
}

func PA_GmailDraft(recipients: [String] = ["friend@example.com"], threadID: String? = nil) -> GmailDraftInput {
    GmailDraftInput(recipients: recipients, subject: "Hello", body: "Body", threadID: threadID)
}

func PA_GmailMessageJSON(_ id: String = "m1", body: String? = nil) -> String {
    let bodyFields = body.map {
        ",\"mimeType\":\"text/plain\",\"body\":{\"data\":\"\(GmailOAuthFlow.base64URL(Data($0.utf8)))\"}"
    } ?? ",\"mimeType\":\"text/plain\",\"body\":{}"
    return """
    {"id":"\(id)","threadId":"thread1","historyId":"10","internalDate":"1700000000000",
     "snippet":"snippet","payload":{"headers":[
       {"name":"Subject","value":"Hello"},{"name":"From","value":"sender@example.com"},
       {"name":"To","value":"owner@example.com"},{"name":"Message-ID","value":"<m1@example.com>"}
     ]\(bodyFields)}}
    """
}

func PA_GmailError(_ result: ToolInvocationResult) -> [String: Any]? {
    let data = Data(result.contentJSON.utf8)
    return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? nil
}
