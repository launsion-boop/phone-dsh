// SPDX-License-Identifier: MIT

import Foundation
import ProbeKit
import XCTest

/// Incremental connector queries used by the ReadySweep connector step.
///
/// These drive the real `GmailAPI` / `GitHubConnectorAPI` clients over a stub
/// URL protocol: no network, no copied fixture, and the assertions are on the
/// actual request (metadata-only, cursor/header/limit) and decoded metadata.
final class ConnectorAPIDeltaTests: XCTestCase {
    func testGmailHistoryLoadsMetadataOnlyAndReturnsNextCursor() async throws {
        let api = makeGmailAPI()
        let delta = try await api.history(startHistoryId: "1000", limit: 20, token: "fixture")
        XCTAssertEqual(delta.historyId, "1015")
        XCTAssertEqual(delta.count, 3)
        XCTAssertEqual(delta.messages.map(\.id), ["message1", "message3", "message4"])
        XCTAssertEqual(delta.messages.map(\.sender), ["QA <qa@example.com>", "", "Ops <ops@example.com>"])
        XCTAssertEqual(delta.messages.first?.subject, "Fixture one")
        XCTAssertEqual(GmailDeltaRecorder.shared.fullBodyRequests, 0)
        XCTAssertEqual(GmailDeltaRecorder.shared.metadataRequests,
                       ["message1", "message3", "message4"])
        let listing = try XCTUnwrap(GmailDeltaRecorder.shared.listingQuery)
        XCTAssertEqual(listing["startHistoryId"], "1000")
        XCTAssertEqual(listing["historyTypes"], "messageAdded")
        XCTAssertEqual(listing["labelId"], "INBOX")
        XCTAssertEqual(listing["maxResults"], "20")
    }

    func testGmailHistoryCapsItemsAtTwentyEvenWhenTheCallerAsksForMore() async throws {
        let api = makeGmailAPI()
        let delta = try await api.history(startHistoryId: "3000", limit: 500, token: "fixture")
        XCTAssertEqual(GmailDeltaRecorder.shared.listingQuery?["maxResults"], "20")
        XCTAssertEqual(delta.messages.count, 20)
        XCTAssertEqual(delta.count, delta.messages.count)
        XCTAssertEqual(Set(delta.messages.map(\.id)).count, delta.messages.count)
    }

    func testGmailExpiredHistoryCursorIsReportedAsNotFound() async throws {
        let api = makeGmailAPI()
        do {
            _ = try await api.history(startHistoryId: "2000", limit: 20, token: "fixture")
            XCTFail("expected an expired history cursor to be reported")
        } catch let error as GmailError {
            XCTAssertEqual(error, .notFound)
        }
    }

    func testGmailHistoryRejectsAnInvalidCursorBeforeAnyRequest() async throws {
        let api = makeGmailAPI()
        for value in ["", "0", "not-a-number", "18446744073709551616"] {
            do {
                _ = try await api.history(startHistoryId: value, token: "fixture")
                XCTFail("expected \(value) to be rejected")
            } catch let error as GmailError {
                XCTAssertEqual(error, .invalidResponse)
            }
        }
        XCTAssertNil(GmailDeltaRecorder.shared.listingQuery)
    }

    func testGmailMailboxCarriesTheHistoryBaseline() async throws {
        let api = makeGmailAPI()
        let mailbox = try await api.mailbox(token: "fixture")
        XCTAssertEqual(mailbox.emailAddress, "person@example.com")
        XCTAssertEqual(mailbox.historyId, "1000")
    }

    func testGmailUnauthorizedStaysADistinctAuthorizationFailure() async throws {
        let api = makeGmailAPI()
        do {
            _ = try await api.history(startHistoryId: "1000", token: "expired")
            XCTFail("expected the token to be rejected")
        } catch let error as GmailError {
            XCTAssertEqual(error, .unauthorized)
        }
    }

    func testGitHubNotificationsSendWatermarksAndDecodeMetadataOnly() async throws {
        let api = makeGitHubAPI()
        let page = try await api.notifications(
            since: "2026-11-20T00:00:00Z",
            ifModifiedSince: "Wed, 19 Nov 2026 12:00:00 GMT",
            limit: 20,
            token: "ghu_fixture_1234567890")
        XCTAssertFalse(page.notModified)
        XCTAssertEqual(page.lastModified, "Thu, 20 Nov 2026 12:00:00 GMT")
        XCTAssertEqual(page.notifications.map(\.id), ["1001", "1002"])
        let first = try XCTUnwrap(page.notifications.first)
        XCTAssertEqual(first.repositoryFullName, "octo/repo")
        XCTAssertEqual(first.title, "Deploy finished")
        XCTAssertEqual(first.type, "CheckSuite")
        XCTAssertEqual(first.unread, true)
        XCTAssertNotNil(first.updatedAt)
        let request = try XCTUnwrap(GitHubDeltaRecorder.shared.lastRequest)
        XCTAssertEqual(request.query["since"], "2026-11-20T00:00:00Z")
        XCTAssertEqual(request.query["per_page"], "20")
        XCTAssertEqual(request.query["all"], "true")
        XCTAssertEqual(request.query["participating"], "false")
        XCTAssertEqual(request.ifModifiedSince, "Wed, 19 Nov 2026 12:00:00 GMT")
        XCTAssertEqual(request.bearer, "Bearer ghu_fixture_1234567890")
    }

    func testGitHubNotModifiedKeepsTheCursorAndEmitsNothing() async throws {
        let api = makeGitHubAPI()
        let page = try await api.notifications(
            since: "2026-11-20T00:00:00Z",
            ifModifiedSince: "Wed, 19 Nov 2026 12:00:00 GMT",
            token: "ghu_notmodified_1234567890")
        XCTAssertTrue(page.notModified)
        XCTAssertTrue(page.notifications.isEmpty)
        XCTAssertEqual(page.lastModified, "Thu, 20 Nov 2026 12:00:00 GMT")
    }

    func testGitHubNotificationsRejectUnsafeWatermarksBeforeAnyRequest() async throws {
        let api = makeGitHubAPI()
        do {
            _ = try await api.notifications(since: "2026-11-20\r\nX-Evil: 1",
                                            ifModifiedSince: nil,
                                            token: "ghu_fixture_1234567890")
            XCTFail("expected an unsafe since value to be rejected")
        } catch let error as GitHubConnectorError {
            XCTAssertEqual(error, .invalidResponse)
        }
        do {
            _ = try await api.notifications(since: nil,
                                            ifModifiedSince: "Wed,\n19 Nov 2026",
                                            token: "ghu_fixture_1234567890")
            XCTFail("expected an unsafe header value to be rejected")
        } catch let error as GitHubConnectorError {
            XCTAssertEqual(error, .invalidResponse)
        }
        XCTAssertNil(GitHubDeltaRecorder.shared.lastRequest)
    }

    func testGitHubNotificationsCapMetadataAtTwenty() async throws {
        let api = makeGitHubAPI()
        let page = try await api.notifications(
            since: nil, ifModifiedSince: nil, limit: 500,
            token: "ghu_many_1234567890")
        XCTAssertEqual(GitHubDeltaRecorder.shared.lastRequest?.query["per_page"], "20")
        XCTAssertEqual(page.notifications.count, 20)
        XCTAssertEqual(Set(page.notifications.map(\.id)).count, 20)
    }

    func testGitHubUnauthorizedStaysADistinctAuthorizationFailure() async throws {
        let api = makeGitHubAPI()
        do {
            _ = try await api.notifications(since: nil, ifModifiedSince: nil,
                                            token: "ghu_expired_1234567890")
            XCTFail("expected the token to be rejected")
        } catch let error as GitHubConnectorError {
            XCTAssertEqual(error, .unauthorized)
        }
    }

    private func makeGmailAPI() -> GmailAPI {
        GmailDeltaRecorder.shared.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GmailDeltaFixtureProtocol.self]
        return GmailAPI(session: URLSession(configuration: configuration))
    }

    private func makeGitHubAPI() -> GitHubConnectorAPI {
        GitHubDeltaRecorder.shared.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitHubDeltaFixtureProtocol.self]
        return GitHubConnectorAPI(session: URLSession(configuration: configuration))
    }
}

// MARK: - Gmail fixture

/// Thread-safe request evidence; the URL protocol runs on URLSession's threads.
final class GmailDeltaRecorder: @unchecked Sendable {
    static let shared = GmailDeltaRecorder()

    private let lock = NSLock()
    private var metadata: [String] = []
    private var fullBody = 0
    private var listing: [String: String]?

    var metadataRequests: [String] { lock.withLock { metadata } }
    var fullBodyRequests: Int { lock.withLock { fullBody } }
    var listingQuery: [String: String]? { lock.withLock { listing } }

    func noteMetadata(_ id: String) {
        lock.withLock {
            if !metadata.contains(id) { metadata.append(id) }
        }
    }

    func noteFullBody() { lock.withLock { fullBody += 1 } }
    func noteListing(_ query: [String: String]) { lock.withLock { listing = query } }

    func reset() {
        lock.withLock {
            metadata = []
            fullBody = 0
            listing = nil
        }
    }
}

private final class GmailDeltaFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, url.scheme == "https", url.host == "gmail.googleapis.com",
              request.httpMethod == "GET",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return fail() }

        let query = components.queryItems ?? []
        let queryMap = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })
        let status: Int
        let payload: String
        if request.value(forHTTPHeaderField: "Authorization") == "Bearer expired" {
            status = 401
            payload = "{}"
        } else if components.path == "/gmail/v1/users/me/history" {
            GmailDeltaRecorder.shared.noteListing(queryMap)
            if queryMap["startHistoryId"] == "2000" {
                status = 404
                payload = "{}"
            } else if queryMap["maxResults"] == "20",
                      queryMap["historyTypes"] == "messageAdded",
                      queryMap["labelId"] == "INBOX" {
                status = 200
                payload = queryMap["startHistoryId"] == "3000"
                    ? Self.bulkListingPayload
                    : Self.listingPayload
            } else {
                return fail()
            }
        } else if components.path == "/gmail/v1/users/me/profile" {
            status = 200
            payload = #"{"emailAddress":"person@example.com","historyId":"1000"}"#
        } else if components.path.hasPrefix("/gmail/v1/users/me/messages/") {
            let id = String(components.path.dropFirst("/gmail/v1/users/me/messages/".count))
            if queryMap["format"] == "metadata" {
                GmailDeltaRecorder.shared.noteMetadata(id)
                status = 200
                payload = Self.metadataPayload(id)
            } else {
                GmailDeltaRecorder.shared.noteFullBody()
                status = 200
                payload = #"{"id":"\#(id)"}"#
            }
        } else {
            return fail()
        }
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                             headerFields: nil) else { return fail() }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func fail() { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)) }

    private static let listingPayload = """
        {"history":[
          {"id":"1005","messagesAdded":[
            {"message":{"id":"message1","labelIds":["INBOX","UNREAD"]}},
            {"message":{"id":"message2","labelIds":["CATEGORY_PROMOTIONS"]}},
            {"message":{"id":"message3"}}
          ]},
          {"id":"1015","messagesAdded":[
            {"message":{"id":"message4","labelIds":["INBOX"]}}
          ]}
        ],"nextPageToken":"next-page"}
        """

    private static var bulkListingPayload: String {
        let added = (0..<25).map { index in
            #"{"message":{"id":"bulk-\#(index)","labelIds":["INBOX"]}}"#
        }.joined(separator: ",")
        return #"{"history":[{"id":"3010","messagesAdded":[\#(added)]}]}"#
    }

    private static func metadataPayload(_ id: String) -> String {
        let from: String
        let subject: String
        switch id {
        case "message1":
            from = "QA <qa@example.com>"
            subject = "Fixture one"
        case "message4":
            from = "Ops <ops@example.com>"
            subject = "Deploy"
        default:
            from = ""
            subject = ""
        }
        return """
            {"id":"\(id)","internalDate":"1763000000000","payload":{"headers":[
              {"name":"From","value":"\(from)"},
              {"name":"Subject","value":"\(subject)"}
            ]}}
            """
    }
}

// MARK: - GitHub fixture

final class GitHubDeltaRecorder: @unchecked Sendable {
    struct Request {
        let query: [String: String]
        let ifModifiedSince: String?
        let bearer: String?
    }

    static let shared = GitHubDeltaRecorder()
    private let lock = NSLock()
    private var stored: [Request] = []

    var lastRequest: Request? { lock.withLock { stored.last } }

    func append(_ request: Request) { lock.withLock { stored.append(request) } }
    func reset() { lock.withLock { stored = [] } }
}

private final class GitHubDeltaFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, url.scheme == "https", url.host == "api.github.com",
              request.httpMethod == "GET",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return fail() }
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map {
            ($0.name, $0.value ?? "")
        })
        let bearer = request.value(forHTTPHeaderField: "Authorization")
        GitHubDeltaRecorder.shared.append(.init(
            query: query,
            ifModifiedSince: request.value(forHTTPHeaderField: "If-Modified-Since"),
            bearer: bearer))
        let status: Int
        let payload: String
        let headers: [String: String]?
        switch bearer {
        case "Bearer ghu_expired_1234567890":
            status = 401
            payload = "{}"
            headers = nil
        case "Bearer ghu_notmodified_1234567890":
            status = 304
            payload = ""
            headers = ["Last-Modified": "Thu, 20 Nov 2026 12:00:00 GMT"]
        case "Bearer ghu_many_1234567890" where query["per_page"] == "20":
            status = 200
            payload = Self.manyPayload
            headers = ["Last-Modified": "Thu, 20 Nov 2026 12:00:00 GMT"]
        case "Bearer ghu_fixture_1234567890" where query["per_page"] == "20":
            status = 200
            payload = Self.notificationPayload
            headers = ["Last-Modified": "Thu, 20 Nov 2026 12:00:00 GMT"]
        default:
            return fail()
        }
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                             headerFields: headers) else { return fail() }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func fail() { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)) }

    private static let notificationPayload = """
        [
          {"id":"1001","unread":true,"reason":"subscribed","updated_at":"2026-11-20T10:00:00Z",
           "subject":{"title":"Deploy finished","type":"CheckSuite"},
           "repository":{"full_name":"octo/repo"}},
          {"id":"1002","unread":false,"updated_at":"2026-11-20T09:00:00Z",
           "subject":{"title":"Review requested","type":"PullRequest"},
           "repository":{"full_name":"octo/repo"}}
        ]
        """

    private static var manyPayload: String {
        let rows = (0..<25).map { index in
            """
            {"id":"many-\(index)","unread":true,"updated_at":"2026-11-20T10:00:00Z",
             "subject":{"title":"Item \(index)","type":"Issue"},
             "repository":{"full_name":"octo/repo"}}
            """
        }.joined(separator: ",")
        return "[\(rows)]"
    }
}
