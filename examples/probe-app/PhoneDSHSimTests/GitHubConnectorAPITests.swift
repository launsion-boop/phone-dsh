// SPDX-License-Identifier: MIT

import Foundation
import ProbeKit
import XCTest

private let githubFixtureToken = "github_pat_fixture_1234567890_abcdefghijklmnop"
private let githubExpiredToken = "github_pat_expired_1234567890_abcdefghijklmnop"
private let githubRateLimitedToken = "github_pat_ratelimit_1234567890_abcdefghijklmnop"

final class GitHubConnectorAPITests: XCTestCase {
    func testAccountUsesAuthenticatedGet() async throws {
        let account = try await makeAPI().account(token: githubFixtureToken)
        XCTAssertEqual(account.login, "octocat")
    }

    func testRepositoryPagesFollowOnlyTheNextRelation() async throws {
        let first = try await makeAPI().repositories(page: 1, token: githubFixtureToken)
        XCTAssertEqual(first.repositories.map(\.fullName), ["octo/hello"])
        XCTAssertEqual(first.repositories.first?.htmlURL.absoluteString, "https://github.com/octo/hello")
        XCTAssertEqual(first.nextPage, 2)

        let second = try await makeAPI().repositories(page: 2, token: githubFixtureToken)
        XCTAssertEqual(second.repositories.map(\.fullName), ["octo/world"])
        XCTAssertNil(second.nextPage)
    }

    func testRepositoryLinkRejectsCredentials() async throws {
        do {
            _ = try await makeAPI().repositories(page: 3, token: githubFixtureToken)
            XCTFail("Expected a repository link with credentials to be rejected.")
        } catch let error as GitHubConnectorError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    func testExpiredTokenRequiresReconnect() async throws {
        do {
            _ = try await makeAPI().account(token: githubExpiredToken)
            XCTFail("Expected the expired fixture token to be rejected.")
        } catch let error as GitHubConnectorError {
            XCTAssertEqual(error, .unauthorized)
        }
    }

    func testRateLimitIsDistinctFromForbidden() async throws {
        do {
            _ = try await makeAPI().account(token: githubRateLimitedToken)
            XCTFail("Expected the rate-limited fixture token to be rejected.")
        } catch let error as GitHubConnectorError {
            XCTAssertEqual(error, .rateLimited)
        }
    }

    private func makeAPI() -> GitHubConnectorAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitHubFixtureProtocol.self]
        return GitHubConnectorAPI(session: URLSession(configuration: configuration))
    }
}

private final class GitHubFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        guard url.scheme == "https",
              url.host == "api.github.com",
              request.httpMethod == "GET",
              request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json",
              request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28",
              request.value(forHTTPHeaderField: "User-Agent") == "phone-dsh",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let authorization = request.value(forHTTPHeaderField: "Authorization")
        else { return send(400, "{}", url: url) }

        if components.path == "/user" {
            if authorization == "Bearer \(githubFixtureToken)" {
                return send(200, #"{"login":"octocat"}"#, url: url)
            }
            if authorization == "Bearer \(githubExpiredToken)" {
                return send(401, "{}", url: url)
            }
            if authorization == "Bearer \(githubRateLimitedToken)" {
                return send(403, "{}", headers: ["x-ratelimit-remaining": "0"], url: url)
            }
            return send(401, "{}", url: url)
        }

        guard components.path == "/user/repos",
              authorization == "Bearer \(githubFixtureToken)",
              let page = Self.page(from: components)
        else { return send(400, "{}", url: url) }

        switch page {
        case 1:
            let link = "<https://evil.example/collect?page=9>; rel=\"next\", <https://evil.example/last?page=3>; rel=\"last\""
            send(200, #"[{"id":1,"name":"hello","full_name":"octo/hello","html_url":"https://github.com/octo/hello"}]"#,
                 headers: ["Link": link], url: url)
        case 2:
            send(200, #"[{"id":2,"name":"world","full_name":"octo/world","html_url":"https://github.com/octo/world"}]"#,
                 url: url)
        case 3:
            send(200, #"[{"id":3,"name":"bad","full_name":"octo/bad","html_url":"https://user:pass@github.com/octo/bad"}]"#,
                 url: url)
        default:
            send(400, "{}", url: url)
        }
    }

    override func stopLoading() {}

    private static func page(from components: URLComponents) -> Int? {
        let query = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }
        )
        guard query["per_page"] == "30", query["sort"] == "updated" else { return nil }
        return query["page"].flatMap(Int.init)
    }

    private func send(
        _ status: Int, _ body: String, headers: [String: String] = [:], url: URL
    ) {
        guard let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: nil, headerFields: headers
        ) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
