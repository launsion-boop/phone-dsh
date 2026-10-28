// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — native MCP transaction control on the simulator.
//
// These tests use the production `MCPControlController` and
// `PhoneMCPAccessSettings` without a Web host. They cover the bridge's
// transaction semantics that do not need WKWebView: a list/sync snapshot must
// not revoke an in-flight grant, rollback reuses the staged Keychain account,
// an unknown page exit/timeout keeps abandoned staging for the real registry,
// a committed row's cleanup failure can never re-enable rollback, a new edit
// cannot overwrite an abandoned stage until the authoritative registry resolves
// it (then it rolls back to the current previous grant), a `false` rollback is
// never reported as restored, and a revoke whose Keychain cleanup fails still
// drops the live route.

import Foundation
import XCTest
import ProbeKit
import PhoneDSH

@MainActor
final class MCPControlTransactionSimTests: XCTestCase {
    private let url = URL(string: "https://mcp.example.com/mcp")!
    private let movedURL = URL(string: "https://other.example.com/mcp")!
    private let token = "Bearer mcp-transaction-token"

    private struct Harness {
        let defaults: UserDefaults
        let suite: String
        let settings: PhoneMCPAccessSettings
        let secrets: SimMCPSecretStore
        let controller: MCPControlController
    }

    private func makeHarness() -> Harness {
        let suite = "MCPControlTransactionSimTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let secrets = SimMCPSecretStore()
        let settings = PhoneMCPAccessSettings(defaults: defaults, secretStore: secrets)
        let controller = MCPControlController(settings: settings,
                                              policy: MCPEgressPolicy())
        return Harness(defaults: defaults,
                       suite: suite,
                       settings: settings,
                       secrets: secrets,
                       controller: controller)
    }

    func testSyncSkipsAServerWithAnOpenGrantTransaction() async throws {
        let harness = makeHarness()
        defer { harness.defaults.removePersistentDomain(forName: harness.suite) }
        let name = "mcp"

        let granted = try await harness.controller.handle([
            "v": 1,
            "action": "grant",
            "serverName": name,
            "url": url.absoluteString,
            "headers": [String: Any](),
        ])
        let transaction = try XCTUnwrap(granted["transaction"] as? String)
        XCTAssertTrue(harness.controller.policy.allowsEgressHost(url))

        // The initial list snapshot may return before the Worker upsert. It
        // does not contain the row, but must not delete the in-flight grant.
        _ = try await harness.controller.handle([
            "v": 1,
            "action": "sync",
            "servers": [[String: Any]](),
        ])
        XCTAssertEqual(try harness.settings.load().grants.map(\.serverName), [name])
        XCTAssertTrue(harness.controller.policy.allowsEgressHost(url))

        _ = try await harness.controller.handle(["v": 1, "action": "commit",
                                                 "transaction": transaction])
        _ = try await harness.controller.handle([
            "v": 1,
            "action": "sync",
            "servers": [[String: Any]](),
        ])
        XCTAssertTrue(try harness.settings.load().grants.isEmpty)
        XCTAssertFalse(harness.controller.policy.allowsEgressHost(url))
    }

    func testListReconcileDoesNotRollBackAStagedNativeSave() throws {
        let harness = makeHarness()
        defer { harness.defaults.removePersistentDomain(forName: harness.suite) }
        let name = "mcp"

        let old = try harness.controller.grant(serverName: name,
                                               url: url.absoluteString,
                                               headers: ["Authorization"],
                                               values: ["Authorization": token])
        _ = try harness.controller.commit(serverName: name,
                                          expectedURL: old.url,
                                          expectedHeaders: old.headers)

        // A native sheet save has written the new grant but is awaiting
        // phone/mcpUpsert. It has no Web transaction token, yet a list started
        // earlier must not roll the row back to the old URL.
        let moved = try harness.controller.grant(serverName: name,
                                                 url: movedURL.absoluteString,
                                                 headers: ["Authorization"],
                                                 values: ["Authorization": "Bearer replacement"])
        _ = try harness.controller.reconcile(existingServers: [name: url.absoluteString])
        XCTAssertEqual(try harness.settings.load().grants.first?.url,
                       moved.url)
        XCTAssertEqual(harness.settings.secretValues(for: name)?["Authorization"],
                       "Bearer replacement")
        XCTAssertTrue(harness.controller.policy.allowsEgressHost(movedURL))

        _ = try harness.controller.commit(serverName: name,
                                          expectedURL: moved.url,
                                          expectedHeaders: moved.headers)
        XCTAssertFalse(harness.controller.policy.allowsEgressHost(url))
        XCTAssertTrue(harness.controller.policy.allowsEgressHost(movedURL))
    }

    func testRollbackReusesTheStagedOldKeychainAccount() async throws {
        let harness = makeHarness()
        defer { harness.defaults.removePersistentDomain(forName: harness.suite) }
        let name = "mcp"

        let old = try harness.controller.grant(serverName: name,
                                               url: url.absoluteString,
                                               headers: ["Authorization"],
                                               values: ["Authorization": token])
        _ = try harness.controller.commit(serverName: name,
                                          expectedURL: old.url,
                                          expectedHeaders: old.headers)
        XCTAssertEqual(harness.settings.secretValues(for: name)?["Authorization"], token)

        let moved = try await harness.controller.handle([
            "v": 1,
            "action": "grant",
            "serverName": name,
            "url": movedURL.absoluteString,
            "headers": ["Authorization": "MCP_TOKEN"],
        ])
        let transaction = try XCTUnwrap(moved["transaction"] as? String)
        XCTAssertEqual(moved["needsValues"] as? Bool, true,
                       "a changed trust boundary needs its own value")
        XCTAssertTrue(harness.controller.policy.allowsEgressHost(movedURL))
        // `secretValues` returns nil only when the server has no grant at all.
        // A grant with declared header names but no stored value map returns an
        // empty map, so assert the absence of the old header value instead of
        // the absence of the dictionary object.
        let movedSecrets = harness.settings.secretValues(for: name) ?? [:]
        XCTAssertTrue(movedSecrets.isEmpty,
                      "a new trust boundary starts without the old value map")
        XCTAssertNil(movedSecrets["Authorization"],
                     "a new trust boundary starts without the old Authorization value")
        XCTAssertTrue(harness.settings.storedHeaderNames(serverName: name).isEmpty)

        _ = try await harness.controller.handle(["v": 1, "action": "rollback",
                                                 "transaction": transaction])
        XCTAssertTrue(harness.controller.policy.allowsEgressHost(url))
        XCTAssertFalse(harness.controller.policy.allowsEgressHost(movedURL))
        XCTAssertEqual(try harness.settings.load().grants.first?.url,
                       url.absoluteString)
        XCTAssertEqual(harness.settings.secretValues(for: name)?["Authorization"],
                       token,
                       "rollback reuses the old account instead of rewriting it")
    }

    func testSettleCommitsAnUpsertWhoseCommitReplyWasLost() async throws {
        let harness = makeHarness()
        defer { harness.defaults.removePersistentDomain(forName: harness.suite) }
        let name = "mcp"

        let granted = try await harness.controller.handle([
            "v": 1,
            "action": "grant",
            "serverName": name,
            "url": url.absoluteString,
            "headers": ["Authorization": "MCP_TOKEN"],
        ])
        let transaction = try XCTUnwrap(granted["transaction"] as? String)
        XCTAssertTrue(harness.controller.policy.allowsEgressHost(url))

        // The Worker persisted the row, but its upsert reply never reached the
        // page. The page queried the real registry; the row is spelled with a
        // trailing slash and explicit default port, which must still match the
        // canonical grant instead of looking like the old URL.
        let settle = try await harness.controller.handle([
            "v": 1,
            "action": "settle",
            "transaction": transaction,
            "registryURL": "https://MCP.EXAMPLE.COM:443/mcp/",
        ])
        XCTAssertEqual(settle["committed"] as? Bool, true)
        XCTAssertEqual(try harness.settings.load().grants.first?.url,
                       url.absoluteString)
        XCTAssertTrue(harness.controller.policy.allowsEgressHost(url))

        // The delayed commit reply is idempotent and cannot resurrect/undo it.
        _ = try await harness.controller.handle(["v": 1, "action": "commit",
                                                 "transaction": transaction])
        XCTAssertEqual(try harness.settings.load().grants.first?.url,
                       url.absoluteString)
        XCTAssertTrue(harness.controller.policy.allowsEgressHost(url))
    }

    func testSettleRollsBackAnUpsertWhoseRegistryStillShowsTheOldRow() async throws {
        let harness = makeHarness()
        defer { harness.defaults.removePersistentDomain(forName: harness.suite) }
        let name = "mcp"

        let old = try harness.controller.grant(serverName: name,
                                               url: url.absoluteString,
                                               headers: ["Authorization"],
                                               values: ["Authorization": token])
        _ = try harness.controller.commit(serverName: name,
                                          expectedURL: old.url,
                                          expectedHeaders: old.headers)
        let moved = try await harness.controller.handle([
            "v": 1,
            "action": "grant",
            "serverName": name,
            "url": movedURL.absoluteString,
            "headers": ["Authorization"],
        ])
        let transaction = try XCTUnwrap(moved["transaction"] as? String)
        let settle = try await harness.controller.handle([
            "v": 1,
            "action": "settle",
            "transaction": transaction,
            "registryURL": url.absoluteString,
        ])
        XCTAssertEqual(settle["committed"] as? Bool, false)
        XCTAssertTrue(harness.controller.policy.allowsEgressHost(url))
        XCTAssertFalse(harness.controller.policy.allowsEgressHost(movedURL))
        XCTAssertEqual(harness.settings.secretValues(for: name)?["Authorization"], token)
    }

    func testSettleAfterAnAbandonedStageRestoresTheCurrentRegistryRowNotTheOlderOne() async throws {
        let harness = makeHarness()
        defer { harness.defaults.removePersistentDomain(forName: harness.suite) }
        let name = "mcp"

        let old = try harness.controller.grant(serverName: name,
                                               url: url.absoluteString,
                                               headers: ["Authorization"],
                                               values: ["Authorization": token])
        _ = try harness.controller.commit(serverName: name,
                                          expectedURL: old.url,
                                          expectedHeaders: old.headers)
        let replacement = "Bearer replacement"
        _ = try harness.controller.grant(serverName: name,
                                         url: movedURL.absoluteString,
                                         headers: ["Authorization"],
                                         values: ["Authorization": replacement])
        // The A→B save lost its verdict (page exit) and is now ownerless.
        try harness.settings.markStagedGrantsAbandoned(serverNames: [name])

        // An ownerless stage cannot be overwritten: the new save must be
        // refused until the real registry resolves A→B.
        let thirdURL = URL(string: "https://third.example.com/mcp")!
        do {
            _ = try await harness.controller.handle([
                "v": 1,
                "action": "grant",
                "serverName": name,
                "url": thirdURL.absoluteString,
                "headers": ["Authorization"],
            ])
            XCTFail("an abandoned stage must require a registry resolution")
        } catch {
            // `MCPControlController` lives in the ProbeKit framework, which
            // statically links the PhoneDSH package; this hostless test bundle
            // links its own copy. A thrown PhoneMCPAccessError therefore does
            // not reliably cast to the test bundle's nominal type, so compare
            // the exact case and associated value instead of type identity
            // across the framework boundary. The user-facing message is
            // covered by the in-target MCPSettingsModelTests.
            let expectedError = PhoneMCPAccessError.stagedGrantUnresolved(name)
            XCTAssertEqual(String(describing: error),
                           String(describing: expectedError))
        }
        XCTAssertTrue(try harness.settings.hasStagedGrant(serverName: name),
                      "a refused save must keep the abandoned stage")
        XCTAssertEqual(try harness.settings.load().grants.first?.url,
                       movedURL.absoluteString)
        XCTAssertEqual(try harness.settings.stagedPreviousGrant(serverName: name)?.url,
                       url.absoluteString)
        XCTAssertEqual(harness.settings.secretValues(for: name)?["Authorization"],
                       replacement,
                       "a refused save must keep B's staged Keychain value")

        // A real list naming B commits the old stage; the new C edit then uses
        // B, not A, as its rollback base.
        _ = try await harness.controller.handle([
            "v": 1,
            "action": "sync",
            "servers": [[
                "serverName": name,
                "url": movedURL.absoluteString,
            ]],
        ])
        XCTAssertFalse(try harness.settings.hasStagedGrant(serverName: name))
        XCTAssertEqual(try harness.settings.load().grants.first?.url,
                       movedURL.absoluteString)
        XCTAssertEqual(harness.settings.secretValues(for: name)?["Authorization"],
                       replacement,
                       "the authoritative list commits B and keeps its staged account")
        XCTAssertFalse(harness.secrets.allValues().contains { $0.contains(token) },
                       "committing B cleans A's older abandoned account")

        let latest = try await harness.controller.handle([
            "v": 1,
            "action": "grant",
            "serverName": name,
            "url": thirdURL.absoluteString,
            "headers": ["Authorization"],
        ])
        let transaction = try XCTUnwrap(latest["transaction"] as? String)
        XCTAssertEqual(try harness.settings.stagedPreviousGrant(serverName: name)?.url,
                       movedURL.absoluteString)

        // The Worker registry still names B, so only C may be rolled back.
        let settle = try await harness.controller.handle([
            "v": 1,
            "action": "settle",
            "transaction": transaction,
            "registryURL": "https://OTHER.example.com:443/mcp/",
        ])
        XCTAssertEqual(settle["resolved"] as? String, "rolled-back")
        XCTAssertEqual(settle["committed"] as? Bool, false)
        XCTAssertTrue(harness.controller.policy.allowsEgressHost(movedURL))
        XCTAssertFalse(harness.controller.policy.allowsEgressHost(url))
        XCTAssertFalse(harness.controller.policy.allowsEgressHost(thirdURL))
        XCTAssertEqual(try harness.settings.load().grants.first?.url,
                       movedURL.absoluteString)
        XCTAssertEqual(harness.settings.secretValues(for: name)?["Authorization"],
                       replacement,
                       "rollback restores B's staged account, not the older A account")
        XCTAssertFalse(harness.secrets.allValues().contains { $0.contains(token) },
                       "the older abandoned A account is cleaned, not resurrected")
        XCTAssertFalse(try harness.settings.hasStagedGrant(serverName: name))
    }

    func testSettleRollbackFalseIsNotReportedAsRolledBack() async throws {
        let harness = makeHarness()
        defer { harness.defaults.removePersistentDomain(forName: harness.suite) }
        let name = "mcp"

        let old = try harness.controller.grant(serverName: name,
                                               url: url.absoluteString,
                                               headers: ["Authorization"],
                                               values: ["Authorization": token])
        _ = try harness.controller.commit(serverName: name,
                                          expectedURL: old.url,
                                          expectedHeaders: old.headers)
        let moved = try await harness.controller.handle([
            "v": 1,
            "action": "grant",
            "serverName": name,
            "url": movedURL.absoluteString,
            "headers": ["Authorization"],
        ])
        let transaction = try XCTUnwrap(moved["transaction"] as? String)

        // A newer live edit takes the slot before settle, so rollbackGrant
        // returns false for this transaction's expected URL. The registry still
        // names the original A row, which is the actual staging base.
        let thirdURL = URL(string: "https://third.example.com/mcp")!
        _ = try harness.controller.grant(serverName: name,
                                         url: thirdURL.absoluteString,
                                         headers: ["Authorization"],
                                         values: ["Authorization": "Bearer newest"])
        let settle = try await harness.controller.handle([
            "v": 1,
            "action": "settle",
            "transaction": transaction,
            "registryURL": url.absoluteString,
        ])
        XCTAssertEqual(settle["resolved"] as? String, "unknown")
        XCTAssertEqual(settle["committed"] as? Bool, false)
        XCTAssertEqual(settle["rollbackPending"] as? Bool, true)
        XCTAssertEqual(try harness.settings.load().grants.first?.url,
                       thirdURL.absoluteString,
                       "a failed rollback must not be reported as restored")
        XCTAssertTrue(try harness.settings.hasStagedGrant(serverName: name))

        // The failed rollback made the stage ownerless and released its retry
        // token. The next real registry list must resolve it immediately; it
        // must not be skipped as if an open transaction still owned it.
        _ = try await harness.controller.handle([
            "v": 1,
            "action": "sync",
            "servers": [[
                "serverName": name,
                "url": url.absoluteString,
            ]],
        ])
        XCTAssertTrue(harness.controller.policy.allowsEgressHost(url))
        XCTAssertFalse(harness.controller.policy.allowsEgressHost(movedURL))
        XCTAssertFalse(harness.controller.policy.allowsEgressHost(thirdURL))
        XCTAssertEqual(try harness.settings.load().grants.first?.url,
                       url.absoluteString)
        XCTAssertEqual(harness.settings.secretValues(for: name)?["Authorization"], token)
        XCTAssertFalse(try harness.settings.hasStagedGrant(serverName: name))
    }

    func testSettleRollbackPendingLetsTheNextRegistryCommitTheCurrentRow() async throws {
        let harness = makeHarness()
        defer { harness.defaults.removePersistentDomain(forName: harness.suite) }
        let name = "mcp"

        let old = try harness.controller.grant(serverName: name,
                                               url: url.absoluteString,
                                               headers: ["Authorization"],
                                               values: ["Authorization": token])
        _ = try harness.controller.commit(serverName: name,
                                          expectedURL: old.url,
                                          expectedHeaders: old.headers)
        let moved = try await harness.controller.handle([
            "v": 1,
            "action": "grant",
            "serverName": name,
            "url": movedURL.absoluteString,
            "headers": ["Authorization"],
        ])
        let transaction = try XCTUnwrap(moved["transaction"] as? String)

        // A newer edit owns the current grant, so the old transaction's
        // rollback returns false. Its abandoned stage must not protect the row
        // from the next authoritative registry read.
        let thirdURL = URL(string: "https://third.example.com/mcp")!
        let newest = "Bearer newest"
        _ = try harness.controller.grant(serverName: name,
                                         url: thirdURL.absoluteString,
                                         headers: ["Authorization"],
                                         values: ["Authorization": newest])
        let settle = try await harness.controller.handle([
            "v": 1,
            "action": "settle",
            "transaction": transaction,
            "registryURL": url.absoluteString,
        ])
        XCTAssertEqual(settle["resolved"] as? String, "unknown")
        XCTAssertEqual(settle["rollbackPending"] as? Bool, true)
        XCTAssertTrue(try harness.settings.hasStagedGrant(serverName: name))

        // The registry already names the current C row: commit it, clean the
        // old A account and close the abandoned stage.
        _ = try await harness.controller.handle([
            "v": 1,
            "action": "sync",
            "servers": [[
                "serverName": name,
                "url": thirdURL.absoluteString,
            ]],
        ])
        XCTAssertTrue(harness.controller.policy.allowsEgressHost(thirdURL))
        XCTAssertFalse(harness.controller.policy.allowsEgressHost(url))
        XCTAssertFalse(harness.controller.policy.allowsEgressHost(movedURL))
        XCTAssertEqual(try harness.settings.load().grants.first?.url,
                       thirdURL.absoluteString)
        XCTAssertEqual(harness.settings.secretValues(for: name)?["Authorization"], newest)
        XCTAssertFalse(try harness.settings.hasStagedGrant(serverName: name))
        XCTAssertFalse(harness.secrets.allValues().contains { $0.contains(token) },
                       "the abandoned previous account is cleaned on commit")
    }

    func testSettleWithoutProofKeepsStagingForTheNextRegistryList() async throws {
        let harness = makeHarness()
        defer { harness.defaults.removePersistentDomain(forName: harness.suite) }
        let name = "mcp"

        let old = try harness.controller.grant(serverName: name,
                                               url: url.absoluteString,
                                               headers: ["Authorization"],
                                               values: ["Authorization": token])
        _ = try harness.controller.commit(serverName: name,
                                          expectedURL: old.url,
                                          expectedHeaders: old.headers)
        let moved = try await harness.controller.handle([
            "v": 1,
            "action": "grant",
            "serverName": name,
            "url": movedURL.absoluteString,
            "headers": ["Authorization"],
        ])
        let transaction = try XCTUnwrap(moved["transaction"] as? String)
        // A third URL proves neither the desired row nor the previous row.
        let settle = try await harness.controller.handle([
            "v": 1,
            "action": "settle",
            "transaction": transaction,
            "registryURL": "https://third.example.com/mcp",
        ])
        XCTAssertEqual(settle["resolved"] as? String, "unknown")
        XCTAssertEqual(settle["committed"] as? Bool, false)
        XCTAssertTrue(harness.controller.policy.allowsEgressHost(movedURL),
                      "an inconclusive settle must not roll back or infer the old row")
        XCTAssertEqual(try harness.settings.load().grants.first?.url,
                       movedURL.absoluteString)

        // The stage is ownerless now; the next real registry read (old row)
        // performs the rollback.
        _ = try await harness.controller.handle([
            "v": 1,
            "action": "sync",
            "servers": [[
                "serverName": name,
                "url": url.absoluteString,
            ]],
        ])
        XCTAssertTrue(harness.controller.policy.allowsEgressHost(url))
        XCTAssertFalse(harness.controller.policy.allowsEgressHost(movedURL))
        XCTAssertEqual(harness.settings.secretValues(for: name)?["Authorization"], token)
    }

    func testExpiredTransactionBecomesAbandonedAndARealRegistryListCommitsIt() async throws {
        let harness = makeHarness()
        defer { harness.defaults.removePersistentDomain(forName: harness.suite) }
        let name = "mcp"

        let old = try harness.controller.grant(serverName: name,
                                               url: url.absoluteString,
                                               headers: ["Authorization"],
                                               values: ["Authorization": token])
        _ = try harness.controller.commit(serverName: name,
                                          expectedURL: old.url,
                                          expectedHeaders: old.headers)
        _ = try await harness.controller.handle([
            "v": 1,
            "action": "grant",
            "serverName": name,
            "url": movedURL.absoluteString,
            "headers": ["Authorization"],
        ])
        XCTAssertTrue(harness.controller.policy.allowsEgressHost(movedURL))

        // Expiry has no upsert verdict, so it must not roll back. The staging
        // becomes ownerless; the current desired row stays live until a real
        // registry read decides.
        harness.controller.expireOpenTransactions(now: Date().addingTimeInterval(10_000))
        XCTAssertTrue(harness.controller.policy.allowsEgressHost(movedURL),
                      "expiry is not proof that the Worker write failed")
        XCTAssertEqual(try harness.settings.load().grants.first?.url,
                       movedURL.absoluteString)

        // The next successful list names the moved row (with a trailing slash
        // for good measure): canonical comparison commits the abandoned stage.
        _ = try harness.controller.reconcile(existingServers: [
            name: movedURL.absoluteString + "/",
        ])
        XCTAssertTrue(harness.controller.policy.allowsEgressHost(movedURL))
        XCTAssertFalse(harness.controller.policy.allowsEgressHost(url))
        XCTAssertEqual(try harness.settings.load().grants.first?.url,
                       movedURL.absoluteString)
        XCTAssertFalse(try harness.settings.load().grants.isEmpty)
    }

    func testExpiredTransactionRollsBackOnlyAfterTheRegistryConfirmsTheOldRow() async throws {
        let harness = makeHarness()
        defer { harness.defaults.removePersistentDomain(forName: harness.suite) }
        let name = "mcp"

        let old = try harness.controller.grant(serverName: name,
                                               url: url.absoluteString,
                                               headers: ["Authorization"],
                                               values: ["Authorization": token])
        _ = try harness.controller.commit(serverName: name,
                                          expectedURL: old.url,
                                          expectedHeaders: old.headers)
        _ = try await harness.controller.handle([
            "v": 1,
            "action": "grant",
            "serverName": name,
            "url": movedURL.absoluteString,
            "headers": ["Authorization"],
        ])
        harness.controller.expireOpenTransactions(now: Date().addingTimeInterval(10_000))

        _ = try harness.controller.reconcile(existingServers: [name: url.absoluteString])
        XCTAssertTrue(harness.controller.policy.allowsEgressHost(url))
        XCTAssertFalse(harness.controller.policy.allowsEgressHost(movedURL))
        XCTAssertEqual(try harness.settings.load().grants.first?.url, url.absoluteString)
        XCTAssertEqual(harness.settings.secretValues(for: name)?["Authorization"], token)
    }

    func testAbandonOnPageExitKeepsStagingAndTheNextListCommitsTheCommittedRow() async throws {
        let harness = makeHarness()
        defer { harness.defaults.removePersistentDomain(forName: harness.suite) }
        let name = "mcp"

        let old = try harness.controller.grant(serverName: name,
                                               url: url.absoluteString,
                                               headers: ["Authorization"],
                                               values: ["Authorization": token])
        _ = try harness.controller.commit(serverName: name,
                                          expectedURL: old.url,
                                          expectedHeaders: old.headers)
        _ = try await harness.controller.handle([
            "v": 1,
            "action": "grant",
            "serverName": name,
            "url": movedURL.absoluteString,
            "headers": ["Authorization"],
        ])
        XCTAssertTrue(harness.controller.policy.allowsEgressHost(movedURL))

        // The page vanishes after the Worker upsert committed but before its
        // commit reply arrived. Do not blind-rollback the committed row.
        _ = try await harness.controller.handle(["v": 1, "action": "abandon"])
        XCTAssertTrue(harness.controller.policy.allowsEgressHost(movedURL))
        XCTAssertEqual(try harness.settings.load().grants.first?.url,
                       movedURL.absoluteString)

        // The next real list is the authority and commits the abandoned stage.
        _ = try await harness.controller.handle([
            "v": 1,
            "action": "sync",
            "servers": [[
                "serverName": name,
                "url": movedURL.absoluteString,
            ]],
        ])
        XCTAssertTrue(harness.controller.policy.allowsEgressHost(movedURL))
        XCTAssertFalse(harness.controller.policy.allowsEgressHost(url))
        let oldValueStillStored = harness.settings.secretValues(for: name)?
            .values.contains { $0 == token } ?? false
        XCTAssertFalse(oldValueStillStored,
                       "the abandoned previous account is removed once the registry commits")
    }

    func testAbandonOnPageExitRollsBackAfterTheRegistryConfirmsThePreviousRow() async throws {
        let harness = makeHarness()
        defer { harness.defaults.removePersistentDomain(forName: harness.suite) }
        let name = "mcp"

        let old = try harness.controller.grant(serverName: name,
                                               url: url.absoluteString,
                                               headers: ["Authorization"],
                                               values: ["Authorization": token])
        _ = try harness.controller.commit(serverName: name,
                                          expectedURL: old.url,
                                          expectedHeaders: old.headers)
        _ = try await harness.controller.handle([
            "v": 1,
            "action": "grant",
            "serverName": name,
            "url": movedURL.absoluteString,
            "headers": ["Authorization"],
        ])
        _ = try await harness.controller.handle(["v": 1, "action": "abandon"])

        // Only positive proof of the old row permits a rollback.
        _ = try await harness.controller.handle([
            "v": 1,
            "action": "sync",
            "servers": [[
                "serverName": name,
                "url": url.absoluteString,
            ]],
        ])
        XCTAssertTrue(harness.controller.policy.allowsEgressHost(url))
        XCTAssertFalse(harness.controller.policy.allowsEgressHost(movedURL))
        XCTAssertEqual(harness.settings.secretValues(for: name)?["Authorization"], token)
    }

    func testRollbackFailureKeepsTheTransactionOwnerForRetry() async throws {
        let harness = makeHarness()
        defer { harness.defaults.removePersistentDomain(forName: harness.suite) }
        let name = "mcp"

        let old = try harness.controller.grant(serverName: name,
                                               url: url.absoluteString,
                                               headers: ["Authorization"],
                                               values: ["Authorization": token])
        _ = try harness.controller.commit(serverName: name,
                                          expectedURL: old.url,
                                          expectedHeaders: old.headers)
        let moved = try await harness.controller.handle([
            "v": 1,
            "action": "grant",
            "serverName": name,
            "url": movedURL.absoluteString,
            "headers": ["Authorization"],
        ])
        let transaction = try XCTUnwrap(moved["transaction"] as? String)
        let valid = try XCTUnwrap(
            harness.defaults.data(forKey: PhoneMCPAccessSettings.defaultsKey))

        // Force the rollback document read to fail. The token must not be
        // removed before the rollback succeeded.
        harness.defaults.set(Data("{ not json".utf8),
                             forKey: PhoneMCPAccessSettings.defaultsKey)
        do {
            _ = try await harness.controller.handle([
                "v": 1,
                "action": "rollback",
                "transaction": transaction,
            ])
            XCTFail("the rollback must surface the document failure")
        } catch {
            // expected
        }

        harness.defaults.set(valid, forKey: PhoneMCPAccessSettings.defaultsKey)
        _ = try await harness.controller.handle([
            "v": 1,
            "action": "rollback",
            "transaction": transaction,
        ])
        XCTAssertTrue(harness.controller.policy.allowsEgressHost(url))
        XCTAssertFalse(harness.controller.policy.allowsEgressHost(movedURL))
        XCTAssertEqual(harness.settings.secretValues(for: name)?["Authorization"], token)
    }

    func testCommitCleanupFailureCancelsRollbackAndLeavesRecoverableStaging() async throws {
        let harness = makeHarness()
        defer { harness.defaults.removePersistentDomain(forName: harness.suite) }
        let name = "mcp"

        let old = try harness.controller.grant(serverName: name,
                                               url: url.absoluteString,
                                               headers: ["Authorization"],
                                               values: ["Authorization": token])
        _ = try harness.controller.commit(serverName: name,
                                          expectedURL: old.url,
                                          expectedHeaders: old.headers)
        XCTAssertEqual(harness.settings.secretValues(for: name)?["Authorization"], token)

        // A native save first writes the moved row and its own Keychain
        // account. The Web save of the same endpoint then rotates that account
        // once more; its transaction snapshot names the live account so a
        // retry after the document recovers can close exactly this staging and
        // keep the live account instead of deleting every account for the row.
        let movedValue = "Bearer moved-token"
        _ = try harness.controller.grant(serverName: name,
                                         url: movedURL.absoluteString,
                                         headers: ["Authorization"],
                                         values: ["Authorization": movedValue])
        let moved = try await harness.controller.handle([
            "v": 1,
            "action": "grant",
            "serverName": name,
            "url": movedURL.absoluteString,
            // The Web bridge sends header-name -> env-name, exactly what the
            // production `grantNativeMCP` posts. Passing a bare array here
            // drops the header, so the Web save below cannot rotate the live
            // account and the cleanup proof would have no live value at all.
            "headers": ["Authorization": "MCP_TOKEN"],
        ])
        let transaction = try XCTUnwrap(moved["transaction"] as? String)
        XCTAssertEqual(moved["hostManagedHeaders"] as? [String], ["Authorization"])
        XCTAssertEqual(moved["needsValues"] as? Bool, false)
        let valid = try XCTUnwrap(
            harness.defaults.data(forKey: PhoneMCPAccessSettings.defaultsKey))

        // Simulate a document-store failure while committing the already
        // Worker-committed row.
        harness.defaults.set(Data("{ not json".utf8),
                             forKey: PhoneMCPAccessSettings.defaultsKey)
        let commit = try await harness.controller.handle([
            "v": 1,
            "action": "commit",
            "transaction": transaction,
        ])
        XCTAssertEqual(commit["cleanupPending"] as? Bool, true)
        XCTAssertEqual(commit["committed"] as? Bool, false)
        XCTAssertEqual(commit["commitPending"] as? Bool, true)

        // An unreadable grant document cannot produce a live route: the policy
        // is rebuilt from the committed document and must fail closed. The
        // commit failure still removed the rollback owner, so pagehide/expiry
        // cannot undo the Worker row; it also cannot re-admit the route.
        _ = try await harness.controller.handle(["v": 1, "action": "abandon"])
        harness.controller.expireOpenTransactions(now: Date().addingTimeInterval(10_000))
        XCTAssertFalse(harness.controller.policy.allowsEgressHost(movedURL))
        XCTAssertFalse(harness.controller.policy.allowsEgressHost(url))
        XCTAssertTrue(harness.controller.policy.authorizedURLs.isEmpty,
                      "a corrupt document must fail closed instead of keeping a live route")

        harness.defaults.set(valid, forKey: PhoneMCPAccessSettings.defaultsKey)
        harness.controller.refreshPolicy()
        // The failed commit wrote neither a partial document nor an ownerless
        // stage. With the real document back, the current moved grant and its
        // staging are readable; the next real list decides the cleanup.
        XCTAssertEqual(try harness.settings.load().grants.first?.url,
                       movedURL.absoluteString)
        XCTAssertTrue(try harness.settings.hasStagedGrant(serverName: name))
        XCTAssertTrue(harness.controller.policy.allowsEgressHost(movedURL))
        XCTAssertFalse(harness.controller.policy.allowsEgressHost(url))

        // A bridge sync runs retryPendingCommits in its defer after the real
        // registry reconcile. The registry names the moved row, so this must
        // finish the pending commit: close staging, delete the old and replaced
        // accounts, and keep the live account.
        _ = try await harness.controller.handle([
            "v": 1,
            "action": "sync",
            "servers": [[
                "serverName": name,
                "url": movedURL.absoluteString,
            ]],
        ])
        XCTAssertEqual(try harness.settings.load().grants.first?.url,
                       movedURL.absoluteString)
        XCTAssertTrue(harness.controller.policy.allowsEgressHost(movedURL))
        XCTAssertFalse(harness.controller.policy.allowsEgressHost(url))
        XCTAssertFalse(try harness.settings.hasStagedGrant(serverName: name))
        XCTAssertEqual(harness.settings.secretValues(for: name)?["Authorization"],
                       movedValue,
                       "the live per-grant Keychain account survived cleanup")
        let storedValues = harness.secrets.allValues()
        XCTAssertFalse(storedValues.contains { $0.contains(token) },
                       "the pending commit must remove the previous Keychain account")
        XCTAssertEqual(storedValues.count, 1,
                       "only the live account remains after cleanup")
    }

    func testStaleCommitCleanupDoesNotTouchANewerNativeSave() async throws {
        let harness = makeHarness()
        defer { harness.defaults.removePersistentDomain(forName: harness.suite) }
        let name = "mcp"

        let old = try harness.controller.grant(serverName: name,
                                               url: url.absoluteString,
                                               headers: ["Authorization"],
                                               values: ["Authorization": token])
        _ = try harness.controller.commit(serverName: name,
                                          expectedURL: old.url,
                                          expectedHeaders: old.headers)
        let moved = try await harness.controller.handle([
            "v": 1,
            "action": "grant",
            "serverName": name,
            "url": movedURL.absoluteString,
            "headers": ["Authorization"],
        ])
        let transaction = try XCTUnwrap(moved["transaction"] as? String)
        let valid = try XCTUnwrap(
            harness.defaults.data(forKey: PhoneMCPAccessSettings.defaultsKey))

        // Leave a committed row's cleanup token pending after a store failure.
        harness.defaults.set(Data("{ not json".utf8),
                             forKey: PhoneMCPAccessSettings.defaultsKey)
        _ = try await harness.controller.handle([
            "v": 1,
            "action": "commit",
            "transaction": transaction,
        ])
        harness.defaults.set(valid, forKey: PhoneMCPAccessSettings.defaultsKey)

        // The native sheet saves directly through the shared settings, so the
        // controller never sees that the row's staging now belongs to C.
        let thirdURL = URL(string: "https://third.example.com/mcp")!
        _ = try harness.settings.grant(serverName: name,
                                       url: thirdURL.absoluteString,
                                       headers: ["Authorization"],
                                       values: ["Authorization": "Bearer newest"])
        harness.controller.retryPendingCommitsForClose()

        // The stale token must be dropped without committing C or marking C's
        // staging abandoned. A further save proves the stage is still usable.
        XCTAssertEqual(try harness.settings.load().grants.first?.url,
                       thirdURL.absoluteString)
        XCTAssertTrue(try harness.settings.hasStagedGrant(serverName: name))
        let fourthURL = URL(string: "https://fourth.example.com/mcp")!
        _ = try harness.settings.grant(serverName: name,
                                       url: fourthURL.absoluteString,
                                       headers: ["Authorization"],
                                       values: ["Authorization": "Bearer latest"])
        XCTAssertEqual(try harness.settings.load().grants.first?.url,
                       fourthURL.absoluteString)
    }

    func testTransactionTableEvictionRollsBackInsteadOfDroppingTheToken() async throws {
        let harness = makeHarness()
        defer { harness.defaults.removePersistentDomain(forName: harness.suite) }
        var firstToken: String?
        var firstURL: URL?
        for index in 0..<33 {
            let target = URL(string: "https://mcp-\(index).example.com/mcp")!
            let reply = try await harness.controller.handle([
                "v": 1,
                "action": "grant",
                "serverName": "mcp-\(index)",
                "url": target.absoluteString,
                "headers": [String: Any](),
            ])
            if index == 0 {
                firstToken = reply["transaction"] as? String
                firstURL = target
            }
        }
        let droppedURL = try XCTUnwrap(firstURL)
        XCTAssertNotNil(firstToken)
        XCTAssertFalse(harness.controller.policy.allowsEgressHost(droppedURL),
                       "the evicted transaction was rolled back before its token was forgotten")
        let remaining = try harness.settings.load().grants
        XCTAssertFalse(remaining.contains { $0.serverName == "mcp-0" })
    }

    func testControllerInitializationResolvesStagingFromTheMaterializedRegistry() throws {
        let suite = "MCPControlTransactionSimTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = SimMCPSecretStore()
        let settings = PhoneMCPAccessSettings(defaults: defaults, secretStore: secrets)

        let old = try settings.grant(serverName: "mcp",
                                     url: url.absoluteString,
                                     headers: ["Authorization"],
                                     values: ["Authorization": token])
        _ = try settings.commitGrant(serverName: old.serverName,
                                     expectedURL: old.url,
                                     expectedHeaders: old.headers)
        _ = try settings.grant(serverName: "mcp",
                               url: movedURL.absoluteString,
                               headers: ["Authorization"],
                               values: ["Authorization": "Bearer replacement"])

        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-controller-init-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let registry = #"{"version":1,"servers":[{"serverName":"mcp","url":"\#(url.absoluteString)"}]}"#
        try Data(registry.utf8).write(to: home.appendingPathComponent("mcp.json"))

        let policy = MCPEgressPolicy()
        let controller = MCPControlController(settings: settings,
                                              policy: policy,
                                              materializedHome: home)
        XCTAssertTrue(controller.policy.allowsEgressHost(url))
        XCTAssertFalse(controller.policy.allowsEgressHost(movedURL))
        XCTAssertEqual(try settings.load().grants.first?.url, url.absoluteString)
        XCTAssertEqual(settings.secretValues(for: "mcp")?["Authorization"], token)
    }

    func testRevokeKeychainCleanupFailureStillDropsTheLiveRoute() async throws {
        let harness = makeHarness()
        defer { harness.defaults.removePersistentDomain(forName: harness.suite) }
        let name = "mcp"

        let granted = try harness.controller.grant(serverName: name,
                                                   url: url.absoluteString,
                                                   headers: ["Authorization"],
                                                   values: ["Authorization": token])
        _ = try harness.controller.commit(serverName: name,
                                          expectedURL: granted.url,
                                          expectedHeaders: granted.headers)
        XCTAssertTrue(harness.controller.policy.allowsEgressHost(url))
        harness.secrets.failOneDelete()

        let reply = try await harness.controller.handle([
            "v": 1,
            "action": "revoke",
            "serverName": name,
        ])
        XCTAssertEqual(reply["cleanupPending"] as? Bool, true,
                       "a Keychain cleanup failure is a retryable status, not a failed revoke")

        // The live policy comes from the committed document, so the route is
        // gone even though the Keychain deletion failed and was retried.
        XCTAssertFalse(harness.controller.policy.allowsEgressHost(url))
        XCTAssertTrue(try harness.settings.load().grants.isEmpty)
        XCTAssertFalse(harness.secrets.allValues().contains { $0.contains(token) })
    }
}
