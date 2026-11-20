// SPDX-License-Identifier: MIT

import Foundation
import ProbeKit
import XCTest

final class GmailAPITests: XCTestCase {
    func testSearchPreservesGmailQueryAndLoadsOnlyMetadata() async throws {
        let page = try await makeAPI().search("from:qa+tag@example.com & subject:测试", token: "fixture")
        XCTAssertEqual(page.messages.map(\.id), ["message2", "message1"])
        XCTAssertEqual(page.messages.first?.sender, "QA <qa@example.com>")
        XCTAssertEqual(page.messages.last?.subject, "Fixture")
        XCTAssertEqual(page.nextPageToken, "more")
    }

    func testNestedMultipartUsesPlainTextAndSkipsAttachedText() async throws {
        let message = try await makeAPI().message(id: "message1", token: "fixture")
        XCTAssertEqual(message.body, .plain("正文 +/"))
        XCTAssertEqual(message.summary.subject, "Fixture")
    }

    func testHTMLOnlyMailIsKeptSeparateFromPlainText() async throws {
        let message = try await makeAPI().message(id: "message2", token: "fixture")
        XCTAssertEqual(message.body, .html("<p>HTML only</p>"))
    }

    func testUnauthorizedProfileRequiresReauthorization() async throws {
        do {
            _ = try await makeAPI().accountEmail(token: "expired")
            XCTFail("Expected Gmail to reject the token.")
        } catch let error as GmailError {
            XCTAssertEqual(error, .unauthorized)
        }
    }

    func testForbiddenProfileIsDistinctFromAnExpiredToken() async throws {
        do {
            _ = try await makeAPI().accountEmail(token: "denied")
            XCTFail("Expected Gmail to deny the request.")
        } catch let error as GmailError {
            XCTAssertEqual(error, .forbidden)
        }
    }

    func testMessageIDCannotEscapeTheMessagesPath() async throws {
        do {
            _ = try await makeAPI().message(id: "../../profile", token: "fixture")
            XCTFail("Expected a malformed message id to be rejected before any request.")
        } catch let error as GmailError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    func testReplyUsesReplyToAndSendsInOriginalConversation() async throws {
        let api = makeAPI()
        let message = try await api.message(id: "replyfixture", token: "fixture")
        let target = try XCTUnwrap(message.replyTarget)
        XCTAssertEqual(target.recipient, "replies@example.com")
        XCTAssertEqual(target.subject, "Re: Fixture")
        try await api.sendReply(
            to: target, from: "reader@example.com", body: "收到。", token: "fixture"
        )
    }

    private func makeAPI() -> GmailAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GmailFixtureProtocol.self]
        return GmailAPI(session: URLSession(configuration: configuration))
    }
}

private final class GmailFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, url.scheme == "https", url.host == "gmail.googleapis.com",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return fail() }

        if request.httpMethod == "POST" {
            guard url.path == "/gmail/v1/users/me/messages/send",
                  request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture",
                  Self.isThreadedReply(request)
            else { return fail() }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{}".utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        guard request.httpMethod == "GET" else { return fail() }

        let status: Int
        let payload: String
        if url.path == "/gmail/v1/users/me/profile",
           request.value(forHTTPHeaderField: "Authorization") == "Bearer expired" {
            status = 401
            payload = "{}"
        } else if url.path == "/gmail/v1/users/me/profile",
                  request.value(forHTTPHeaderField: "Authorization") == "Bearer denied" {
            status = 403
            payload = "{}"
        } else {
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture",
                  let fixture = Self.response(components)
            else { return fail() }
            status = 200
            payload = fixture
        }
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)
        else { return fail() }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func isThreadedReply(_ request: URLRequest) -> Bool {
        let data: Data
        if let body = request.httpBody {
            data = body
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            var body = Data()
            var count = stream.read(&buffer, maxLength: buffer.count)
            while count > 0 {
                body.append(contentsOf: buffer.prefix(count))
                count = stream.read(&buffer, maxLength: buffer.count)
            }
            guard count == 0 else { return false }
            data = body
        } else {
            return false
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: String],
              json["threadId"] == "thread1", let raw = json["raw"]
        else { return false }
        let base64 = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padded = base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let mime = Data(base64Encoded: padded).flatMap({ String(data: $0, encoding: .utf8) })
        else { return false }
        return mime.contains("From: reader@example.com\r\n")
            && mime.contains("To: replies@example.com\r\n")
            && mime.contains("Subject: Re: Fixture\r\n")
            && mime.contains("In-Reply-To: <fixture@example.com>\r\n")
            && mime.contains("References: <fixture@example.com>\r\n")
            && mime.contains("\r\n\r\n" + Data("收到。".utf8).base64EncodedString() + "\r\n")
    }

    override func stopLoading() {}

    private func fail() { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)) }

    private static func response(_ components: URLComponents) -> String? {
        if components.path == "/gmail/v1/users/me/messages/replyfixture" {
            return #"""
            {"id":"replyfixture","threadId":"thread1","payload":{"headers":[
                {"name":"From","value":"Sender <sender@example.com>"},
                {"name":"Reply-To","value":"Replies <replies@example.com>"},
                {"name":"Message-ID","value":"<fixture@example.com>"},
                {"name":"Subject","value":"Fixture"}
            ]}}
            """#
        }
        let query = components.queryItems ?? []
        if components.path == "/gmail/v1/users/me/messages" {
            guard components.percentEncodedQuery?.contains("%2B") == true,
                  query.contains(URLQueryItem(name: "q", value: "from:qa+tag@example.com & subject:测试"))
            else { return nil }
            return #"{"messages":[{"id":"message2"},{"id":"message1"}],"nextPageToken":"more"}"#
        }
        let id = components.path.split(separator: "/").last.map(String.init) ?? ""
        guard ["message1", "message2"].contains(id) else { return nil }
        if query.contains(URLQueryItem(name: "format", value: "metadata")) {
            guard query.contains(URLQueryItem(name: "metadataHeaders", value: "From")),
                  query.contains(URLQueryItem(name: "metadataHeaders", value: "Subject")) else { return nil }
            return #"{"id":"\#(id)","payload":{"headers":[{"name":"From","value":"QA <qa@example.com>"},{"name":"Subject","value":"Fixture"}]}}"#
        }
        guard query.contains(URLQueryItem(name: "format", value: "full")) else { return nil }
        let html = encoded("<p>HTML only</p>")
        if id == "message2" {
            return #"{"id":"message2","payload":{"mimeType":"text/html","body":{"data":"\#(html)"}}}"#
        }
        let plain = encoded("正文 +/")
        let attachment = encoded("Attachment text must not become the message body.")
        return """
            {"id":"message1","payload":{"mimeType":"multipart/mixed","headers":[{"name":"Subject","value":"Fixture"}],"parts":[
              {"mimeType":"text/plain","filename":"attachment.txt","body":{"data":"\(attachment)"}},
              {"mimeType":"multipart/alternative","parts":[
                {"mimeType":"text/html","body":{"data":"\(html)"}},
                {"mimeType":"text/plain","body":{"data":"\(plain)"}}
              ]}
            ]}}
            """
    }

    private static func encoded(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
