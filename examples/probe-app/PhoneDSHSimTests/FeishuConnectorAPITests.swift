// SPDX-License-Identifier: MIT

import Foundation
import ProbeKit
import XCTest

private let feishuFixtureToken = "u-fixture-1234567890-abcdefghijklmnop"
private let feishuExpiredToken = "u-expired-1234567890-abcdefghijklmnop"
private let feishuForbiddenToken = "u-forbidden-1234567890-abcdefghijklmnop"
private let feishuRateLimitedToken = "u-ratelimit-1234567890-abcdefghijklmnop"
private let feishuGarbledToken = "u-garbled-1234567890-abcdefghijklmnop"

final class FeishuConnectorAPITests: XCTestCase {
    func testAccountReadsTheSignedInPerson() async throws {
        let account = try await makeAPI().account(token: feishuFixtureToken)
        XCTAssertEqual(account.name, "张三")
        XCTAssertEqual(account.openID, "ou-caecc734c2e3328a62489fe0648c4b98779515d3")
    }

    func testFilesListDropsNonHTTPSLinksAndKeepsTypeLabels() async throws {
        let files = try await makeAPI().files(token: feishuFixtureToken)
        XCTAssertEqual(files.map(\.name), ["项目周报", "预算表", "旧截图", "附件"])
        XCTAssertEqual(files[0].url?.absoluteString, "https://feishu.cn/docx/doxcnA")
        XCTAssertEqual(files[0].typeLabel, "文档")
        XCTAssertEqual(files[1].url, nil)
        XCTAssertEqual(files[1].typeLabel, "表格")
        XCTAssertEqual(files[2].url, nil, "A javascript: URL must never become a tappable link")
        XCTAssertEqual(files[3].typeLabel, "文件")
    }

    func testMalformedTokenNeverReachesTheNetwork() async throws {
        do {
            _ = try await makeAPI().account(token: "short")
            XCTFail("Expected a malformed token to be rejected.")
        } catch let error as FeishuConnectorError {
            XCTAssertEqual(error, .unauthorized)
        }
        XCTAssertFalse(FeishuConnectorAPI.isValidToken("has space in it"))
        XCTAssertFalse(FeishuConnectorAPI.isValidToken(""))
    }

    func testTokenFailuresMapToDistinctCases() async throws {
        for (token, expected) in [
            (feishuExpiredToken, FeishuConnectorError.unauthorized),
            (feishuForbiddenToken, .forbidden),
            (feishuRateLimitedToken, .rateLimited),
            (feishuGarbledToken, .invalidResponse),
        ] {
            do {
                _ = try await makeAPI().account(token: token)
                XCTFail("Expected \(token) to fail.")
            } catch let error as FeishuConnectorError {
                XCTAssertEqual(error, expected)
            }
        }
    }

    private func makeAPI() -> FeishuConnectorAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FeishuFixtureProtocol.self]
        return FeishuConnectorAPI(session: URLSession(configuration: configuration))
    }
}

private final class FeishuFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              url.scheme == "https", url.host == "open.feishu.cn",
              request.httpMethod == "GET",
              request.value(forHTTPHeaderField: "Accept") == "application/json",
              request.value(forHTTPHeaderField: "User-Agent") == "phone-dsh",
              let authorization = request.value(forHTTPHeaderField: "Authorization")
        else { return send(400, Data(), url: request.url) }

        switch url.path {
        case "/open-apis/authen/v1/user_info":
            switch authorization {
            case "Bearer \(feishuFixtureToken)":
                return send(200, Data(#"{"code":0,"msg":"success","data":{"name":"张三","open_id":"ou-caecc734c2e3328a62489fe0648c4b98779515d3"}}"#.utf8), url: url)
            case "Bearer \(feishuExpiredToken)":
                return send(401, Data(), url: url)
            case "Bearer \(feishuForbiddenToken)":
                return send(200, Data(#"{"code":99991679,"msg":"Unauthorized"}"#.utf8), url: url)
            case "Bearer \(feishuRateLimitedToken)":
                return send(200, Data(#"{"code":99991400,"msg":"too many request"}"#.utf8), url: url)
            case "Bearer \(feishuGarbledToken)":
                return send(200, Data("not json".utf8), url: url)
            default:
                return send(400, Data(), url: url)
            }
        case "/open-apis/drive/v1/files":
            guard authorization == "Bearer \(feishuFixtureToken)",
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  Set((components.queryItems ?? []).map(\.name)) == ["page_size", "order_by", "direction"]
            else { return send(400, Data(), url: url) }
            let payload = """
            {"code":0,"msg":"success","data":{"files":[\
            {"token":"doxcnA","name":"项目周报","type":"docx","url":"https://feishu.cn/docx/doxcnA"},\
            {"token":"shtcnB","name":"预算表","type":"sheet","url":"http://insecure.example.com/sheet"},\
            {"token":"boxcnC","name":"旧截图","type":"file","url":"javascript:alert(1)"},\
            {"token":"boxcnD","name":"附件","type":"file"}\
            ],"has_more":false}}
            """
            return send(200, Data(payload.utf8), url: url)
        default:
            return send(404, Data(), url: url)
        }
    }

    override func stopLoading() {}

    private func send(_ status: Int, _ data: Data, url: URL?) {
        guard let url,
              let response = HTTPURLResponse(
                  url: url, statusCode: status, httpVersion: nil, headerFields: nil
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !data.isEmpty { client?.urlProtocol(self, didLoad: data) }
        client?.urlProtocolDidFinishLoading(self)
    }
}
