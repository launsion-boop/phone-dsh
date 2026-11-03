// SPDX-License-Identifier: MIT

import Foundation
@testable import ProbeKit
import XCTest

final class PA_GmailScopeGateTests: XCTestCase {
    private struct Receipt: Decodable { let id: String }

    private func fixture() -> (GmailClient, PA_GmailTransport) {
        let store = PA_GmailTokenStore(PA_GmailTokens())
        let transport = PA_GmailTransport()
        return (GmailClient(tokens: PA_GmailManager(store: store, transport: transport,
                                                    scopes: [GmailScope.readOnly, GmailScope.compose]),
                            transport: transport), transport)
    }

    func testDraftOnlyGrantRejectsBothSendEndpointsBeforeHTTP() async throws {
        let (client, transport) = fixture()
        let grant = PA_GmailGrant(actions: [.read, .gmailCreateDraft],
                                  scopes: [GmailScope.readOnly, GmailScope.compose])
        for path in ["/gmail/v1/users/me/messages/send", "/gmail/v1/users/me/drafts/send"] {
            do {
                let _: Receipt = try await client.post(path: path, body: ["raw": "opaque"], grant: grant,
                                                       requiredAction: .gmailSendNew)
                XCTFail("draft-only grant must not send")
            } catch {
                XCTAssertTrue(error is GmailError)
            }
        }
        let requestCount = await transport.requests.count
        XCTAssertEqual(requestCount, 0)
    }

    func testForwardIsSeparateAndDeniedByDefault() async throws {
        let (client, transport) = fixture()
        let grant = PA_GmailGrant(actions: [.read, .gmailCreateDraft, .gmailReplyInThread, .gmailSendNew],
                                  scopes: [GmailScope.readOnly, GmailScope.compose])
        do {
            let _: Receipt = try await client.post(path: "/gmail/v1/users/me/messages/send",
                                                   body: ["raw": "opaque"], grant: grant,
                                                   requiredAction: .gmailForward)
            XCTFail("forward must require its own grant")
        } catch {
            XCTAssertTrue(error is GmailError)
        }
        let requestCount = await transport.requests.count
        XCTAssertEqual(requestCount, 0)
    }

    func testDraftCreateDoesNotAcquireSendCapability() async throws {
        let (client, transport) = fixture()
        let grant = PA_GmailGrant(actions: [.read, .gmailCreateDraft],
                                  scopes: [GmailScope.readOnly, GmailScope.compose])
        let ledger = PA_GmailLedger()
        let coordinator = GmailWriteCoordinator(client: client, gate: PA_GmailAllowGate(), ledger: ledger,
                                                undoWindow: PA_GmailImmediateUndo())
        let bridge = GmailToolBridge(client: client, grants: PA_GmailGrantProvider(grant), writes: coordinator)
        await transport.enqueueJSON("POST /gmail/v1/users/me/drafts",
                                    "{\"id\":\"draft1\",\"message\":{\"id\":\"m1\"}}")
        let draft = PA_GmailDraft()
        let arguments = String(decoding: try GmailJSON.encoder.encode(draft), as: UTF8.self)
        let created = await bridge.invoke("gmail.draft.create", argumentsJSON: arguments,
                                          caller: .personalAgent(mandate: PA_GmailMandate(actions: [.gmailCreateDraft])))
        XCTAssertFalse(created.isError, created.contentJSON)
        let send = await bridge.invoke("gmail.message.send", argumentsJSON: sendArguments(),
                                       caller: .personalAgent(mandate: PA_GmailMandate(
                                        actions: [.gmailSendNew], recipients: ["friend@example.com"])))
        XCTAssertTrue(send.isError)
        let sendRequests = await transport.requests(for: "/gmail/v1/users/me/messages/send")
        XCTAssertEqual(sendRequests.count, 0)
    }

    func testUndoWindowCancellationMakesNoProviderCall() async throws {
        let (client, transport) = fixture()
        let coordinator = GmailWriteCoordinator(client: client, gate: PA_GmailAllowGate(), ledger: PA_GmailLedger())
        let input = GmailSendInput(kind: .new, draft: PA_GmailDraft())
        let grant = PA_GmailGrant(actions: [.read, .gmailSendNew],
                                  scopes: [GmailScope.readOnly, GmailScope.compose])
        let mandate = PA_GmailMandate(actions: [.gmailSendNew], recipients: ["friend@example.com"])
        let task = Task<ProviderReceipt, Error> {
            try await coordinator.send(input, caller: .personalAgent(mandate: mandate), grant: grant,
                                       argumentsJSON: sendArguments())
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("cancelled undo window must not send")
        } catch {}
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 0)
    }

    func testEvidenceAndForwardTargetsCannotEscapeMandate() async throws {
        let (client, transport) = fixture()
        let coordinator = GmailWriteCoordinator(client: client, gate: PA_GmailAllowGate(), ledger: PA_GmailLedger(),
                                                undoWindow: PA_GmailImmediateUndo())
        let grant = PA_GmailGrant(actions: [.read, .gmailSendNew, .gmailForward],
                                  scopes: [GmailScope.readOnly, GmailScope.compose])
        var draft = PA_GmailDraft(threadID: "thread1")
        draft.evidenceRefs = ["unapproved"]
        let send = GmailSendInput(kind: .new, draft: draft)
        let sendMandate = PA_GmailMandate(actions: [.gmailSendNew], recipients: ["friend@example.com"])
        do {
            _ = try await coordinator.send(send, caller: .personalAgent(mandate: sendMandate), grant: grant,
                                           argumentsJSON: sendArguments())
            XCTFail("unapproved evidence must be rejected")
        } catch {}
        let forward = GmailSendInput(kind: .forward, draft: PA_GmailDraft(threadID: "thread1"))
        let forwardMandate = PA_GmailMandate(actions: [.gmailForward], recipients: ["friend@example.com"])
        do {
            _ = try await coordinator.send(forward, caller: .personalAgent(mandate: forwardMandate), grant: grant,
                                           argumentsJSON: sendArguments())
            XCTFail("unselected source thread must be rejected")
        } catch {}
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 0)
    }

    func testGrantIsRecheckedAfterUndoWindow() async throws {
        let (client, transport) = fixture()
        let grant = PA_GmailGrant(actions: [.read, .gmailSendNew],
                                  scopes: [GmailScope.readOnly, GmailScope.compose])
        let revoked = ConnectorGrant(connectorID: "gmail", version: 2, allowedActions: grant.allowedActions,
                                     scope: grant.scope, rateLimit: grant.rateLimit, paused: true)
        let coordinator = GmailWriteCoordinator(client: client, gate: PA_GmailAllowGate(), ledger: PA_GmailLedger(),
                                                undoWindow: PA_GmailImmediateUndo(),
                                                grants: PA_GmailGrantProvider(revoked))
        let input = GmailSendInput(kind: .new, draft: PA_GmailDraft())
        let mandate = PA_GmailMandate(actions: [.gmailSendNew], recipients: ["friend@example.com"])
        do {
            _ = try await coordinator.send(input, caller: .personalAgent(mandate: mandate), grant: grant,
                                           argumentsJSON: sendArguments())
            XCTFail("stale grant must not send")
        } catch {}
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 0)
    }

    private func sendArguments() -> String {
        let input = GmailSendInput(kind: .new, draft: PA_GmailDraft())
        return String(decoding: (try! GmailJSON.encoder.encode(input)), as: UTF8.self)
    }
}
