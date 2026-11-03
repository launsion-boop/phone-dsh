// SPDX-License-Identifier: MIT

import Foundation
@testable import ProbeKit
import XCTest

final class PA_GmailClientTests: XCTestCase {
    private func fixture() -> (GmailClient, PA_GmailTransport) {
        let store = PA_GmailTokenStore(PA_GmailTokens())
        let transport = PA_GmailTransport()
        return (GmailClient(tokens: PA_GmailManager(store: store, transport: transport), transport: transport), transport)
    }

    func testSearchUsesBoundedQueryAndMetadataFirst() async throws {
        let (client, transport) = fixture()
        await transport.enqueueJSON("GET /gmail/v1/users/me/messages", "{\"messages\":[{\"id\":\"m1\"}]}")
        await transport.enqueueJSON("GET /gmail/v1/users/me/messages/m1", PA_GmailMessageJSON(body: "hidden"))
        let since = Date(timeIntervalSince1970: 1_700_000_000)
        let result = try await client.search(GmailSearchQuery(since: since, unreadOnly: true,
                                                              sender: "sender@example.com", subject: "Hello", limit: 1))
        XCTAssertEqual(result.messages.count, 1)
        XCTAssertNil(result.messages[0].body)
        let list = await transport.requests(for: "/gmail/v1/users/me/messages")
        XCTAssertEqual(list[0].query["maxResults"], "1")
        XCTAssertTrue(list[0].query["q"]?.contains("is:unread") == true)
        XCTAssertTrue(list[0].query["q"]?.contains("from:") == true)
        let metadata = await transport.requests(for: "/gmail/v1/users/me/messages/m1")
        XCTAssertEqual(metadata[0].query["format"], "metadata")
        XCTAssertTrue(metadata[0].repeatedQuery["metadataHeaders"]?.contains("Subject") == true)
        XCTAssertEqual(metadata[0].headers["Authorization"], "Bearer test-access-token")
        XCTAssertFalse(try metadata[0].url().absoluteString.contains("test-access-token"))
    }

    func testBodyIsFetchedOnlyOnDemand() async throws {
        let (client, transport) = fixture()
        await transport.enqueueJSON("GET /gmail/v1/users/me/messages/m1", PA_GmailMessageJSON(body: "Plain body"))
        let message = try await client.message(id: "m1", includeBody: true)
        XCTAssertEqual(message.body, "Plain body")
        let requests = await transport.requests(for: "/gmail/v1/users/me/messages/m1")
        XCTAssertEqual(requests[0].query["format"], "full")
    }

    func testResultLimitAndErrorMapping() async throws {
        let (client, transport) = fixture()
        do {
            _ = try await client.search(GmailSearchQuery(limit: 51))
            XCTFail("limit above bound must fail")
        } catch {
            XCTAssertEqual(error as? GmailError, .invalidArguments("limit 必须在 1...50"))
        }
        let rejectedRequests = await transport.requests
        XCTAssertEqual(rejectedRequests.count, 0)
        await transport.enqueueJSON("GET /gmail/v1/users/me/messages/m1", status: 403, "{}")
        do {
            _ = try await client.message(id: "m1", includeBody: false)
            XCTFail("403 must fail")
        } catch {
            XCTAssertEqual(error as? GmailError,
                           .permissionDenied("Gmail 当前账号或 scope 不允许此操作"))
        }
    }

    func testDualBridgeUsesSameReadClient() async throws {
        let (client, transport) = fixture()
        let bridge = GmailToolBridge(client: client, grants: PA_GmailGrantProvider(PA_GmailGrant()))
        await transport.enqueueJSON("GET /gmail/v1/users/me/messages/m1", PA_GmailMessageJSON())
        let dsh = try await bridge.callTool(name: "gmail.message.get", arguments: "{\"id\":\"m1\"}")
        XCTAssertTrue(dsh.contains("\"ok\":true"))
        await transport.enqueueJSON("GET /gmail/v1/users/me/messages/m1", PA_GmailMessageJSON())
        let chat = await bridge.invoke("gmail.message.get", argumentsJSON: "{\"id\":\"m1\"}",
                                       caller: .personalAgent(mandate: PA_GmailMandate()))
        XCTAssertFalse(chat.isError)
        let requests = await transport.requests(for: "/gmail/v1/users/me/messages/m1")
        XCTAssertEqual(requests.count, 2)
    }
}
