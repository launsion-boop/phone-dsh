// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSH

struct TonoLiveFeishuClient {
    struct Snapshot: Decodable {
        let connection: Connection?
        let approvedApps: [AppChoice]
        let scopeRecipe: Recipe
        let currentAttempt: Attempt?
        let executionPermissions: Permissions

        var readableConnection: Connection? {
            guard connection?.state == "connected",
                  executionPermissions.availableActions.contains("document_text")
            else { return nil }
            return connection
        }
    }

    struct Connection: Decodable {
        let connectionRef: UUID
        let accountName: String
        let state: String
        let credentialBackend: String
        let compatibleConnectionRef: LegacyReference?

        struct LegacyReference: Decodable {
            let id: UUID
        }
    }

    struct AppChoice: Decodable, Identifiable {
        let choiceRef: UUID
        let choiceVersion: String
        let name: String
        let available: Bool

        var id: UUID { choiceRef }
    }

    struct Recipe: Decodable {
        let recipeRef: String
        let recipeVersion: String
        let requested: [String]
    }

    struct Permissions: Decodable {
        let availableActions: [String]
    }

    struct Attempt: Decodable {
        enum Phase: String, Decodable {
            case registeringApp = "registering_app"
            case authorizingUser = "authorizing_user"
            case awaitingConfirmation = "awaiting_confirmation"
            case connected, failed, expired, cancelled, uncertain
        }

        let attemptId: UUID
        let phase: Phase
        let verificationUrl: URL?
        let expiresAt: Date
        let nextPollAt: Date?
        let readerIdentity: Reader?
        let recovery: Recovery

        struct Reader: Decodable {
            let userName: String
        }

        struct Recovery: Decodable {
            let operationRef: UUID?
        }

        var verificationLink: URL? {
            guard let url = verificationUrl,
                  url.scheme == "https", url.user == nil, url.password == nil,
                  url.port == nil || url.port == 443,
                  let host = url.host, ["open.feishu.cn", "accounts.feishu.cn"].contains(host)
            else { return nil }
            return url
        }
    }

    enum Failure: Error {
        case signedOut
        case rejected(Int)
        case invalidResponse
    }

    enum Action: String {
        case advance, confirm, cancel, recover
    }

    private struct Receipt: Decodable {
        let snapshot: Snapshot
    }

    private struct Document: Decodable {
        let connectionRef: UUID
        let documentId: String
        let text: String
    }

    private struct LegacyDocument: Decodable {
        let operation: String
        let result: Content

        struct Content: Decodable {
            let documentId: String?
            let content: String
        }
    }

    private let origin = URL(string: "https://app.tonoai.cn")!
    private let account = TonoAccountSession.shared
    private let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)

    func snapshot() async throws -> Snapshot {
        try await request("/api/v1/feishu/snapshot")
    }

    func start(recipe: Recipe, choice: AppChoice?, key: UUID) async throws -> Snapshot {
        var application = ["mode": "create_new"]
        if let choice {
            application = ["mode": "select", "choice_ref": pathID(choice.choiceRef),
                           "choice_version": choice.choiceVersion]
        }
        return try await request("/api/v1/feishu/authorization-attempts", method: "POST", key: key, body: [
            "application": application, "recipe_ref": recipe.recipeRef, "recipe_version": recipe.recipeVersion,
        ])
    }

    func update(_ attempt: Attempt, action: Action, key: UUID) async throws -> Snapshot {
        var body: [String: Any] = [:]
        if action == .recover, let ref = attempt.recovery.operationRef {
            body["operation_ref"] = pathID(ref)
        }
        return try await request("/api/v1/feishu/authorization-attempts/\(pathID(attempt.attemptId))/\(action.rawValue)",
                                 method: "POST", key: key, body: body)
    }

    func recover(key: UUID) async throws -> Snapshot {
        let receipt: Receipt = try await request("/api/v1/feishu/operations/by-key", key: key)
        return receipt.snapshot
    }

    func read(_ id: String, connection: Connection) async throws -> String {
        if connection.credentialBackend == "open_connector", let legacy = connection.compatibleConnectionRef {
            let operation = "feishu.get_document_content"
            let result: LegacyDocument = try await request(
                "/api/v1/app-connections/by-id/\(pathID(legacy.id))/operations/read",
                method: "POST", body: ["operation": operation, "payload": ["documentId": id]]
            )
            guard result.operation == operation, result.result.documentId.map({ $0 == id }) ?? true
            else { throw Failure.invalidResponse }
            return result.result.content
        }
        guard connection.credentialBackend == "managed" else { throw Failure.invalidResponse }
        let result: Document = try await request(
            "/api/v1/feishu/connections/\(pathID(connection.connectionRef))/reads",
            method: "POST", key: UUID(), body: ["operation": "document_text", "selector": ["document_id": id]]
        )
        guard result.documentId == id, result.connectionRef == connection.connectionRef
        else { throw Failure.invalidResponse }
        return result.text
    }

    static func documentID(_ input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let id: String
        if let url = URL(string: value), let host = url.host,
           url.scheme == "https", host == "feishu.cn" || host.hasSuffix(".feishu.cn"),
           url.pathComponents.count == 3, url.pathComponents[1] == "docx" {
            id = url.pathComponents[2]
        } else {
            id = value
        }
        guard id.range(of: "^[A-Za-z0-9]{1,160}$", options: .regularExpression) != nil
        else { return nil }
        return id
    }

    private func pathID(_ id: UUID) -> String { id.uuidString.lowercased() }

    private func request<Value: Decodable>(
        _ path: String, method: String = "GET", key: UUID? = nil, body: [String: Any]? = nil
    ) async throws -> Value {
        guard let token = try await account.accessToken() else { throw Failure.signedOut }
        var request = URLRequest(url: origin.appending(path: path), cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 25)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let key { request.setValue(pathID(key), forHTTPHeaderField: "Idempotency-Key") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw Failure.rejected(response.statusCode) }
        guard data.count <= 1024 * 1024 else { throw Failure.invalidResponse }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions.insert(.withFractionalSeconds)
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions.remove(.withFractionalSeconds)
            guard let date = formatter.date(from: value) else { throw Failure.invalidResponse }
            return date
        }
        return try decoder.decode(Value.self, from: data)
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
