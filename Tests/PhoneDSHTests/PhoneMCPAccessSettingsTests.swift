// SPDX-License-Identifier: MIT
// Host-side MCP access: exact origin/path admission, dedicated Keychain
// separation, and document/secret transaction ordering. The Keychain is an
// in-memory store, so this suite never touches the device.

import Foundation
import XCTest
import PhoneDSHAgentCore
import PhoneDSHGateway
@testable import PhoneDSH

final class PhoneMCPAccessSettingsTests: XCTestCase {
    private static let mcpURL = "https://mcp.example.com:8443/mcp"
    private static let token = "Bearer mcp-device-token-never-in-document"

    private var suiteName = ""
    private var defaults: UserDefaults!
    private var secrets: InMemoryMCPScretStore!
    private var settings: PhoneMCPAccessSettings!

    override func setUp() {
        super.setUp()
        suiteName = "PhoneMCPAccessSettingsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        secrets = InMemoryMCPScretStore()
        settings = PhoneMCPAccessSettings(defaults: defaults, secretStore: secrets)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        secrets = nil
        settings = nil
        super.tearDown()
    }

    func testGrantAdmitsOnlyTheExactOriginAndPathAndRoutesOnlyThatScope() async throws {
        let grant = try settings.grant(serverName: "mcp",
                                       url: Self.mcpURL,
                                       headers: ["Authorization"],
                                       values: ["Authorization": Self.token])
        let secretID = try XCTUnwrap(grant.secretID)
        let account = "mcp.mcp.\(secretID)"
        let snapshot = try settings.load()
        XCTAssertEqual(snapshot.grants.map(\.serverName), ["mcp"])
        XCTAssertEqual(snapshot.grants.first?.headers, ["Authorization"])
        let document = try XCTUnwrap(defaults.data(forKey: PhoneMCPAccessSettings.defaultsKey))
        let json = try XCTUnwrap(String(data: document, encoding: .utf8))
        XCTAssertFalse(json.contains(Self.token))
        XCTAssertFalse(json.contains("Authorization:"))
        XCTAssertEqual(secrets.value(for: account),
                       #"{"Authorization":"\#(Self.token)"}"#)

        let policy = settings.makePolicy()
        XCTAssertTrue(policy.allowsEgressHost(URL(string: Self.mcpURL)!))
        XCTAssertTrue(policy.allowsEgressHost(URL(string: "https://MCP.EXAMPLE.COM:8443/mcp")!))
        XCTAssertFalse(policy.allowsEgressHost(URL(string: "https://mcp.example.com:8443/mcp/tools")!),
                       "a sibling path is not covered by the exact grant")
        XCTAssertFalse(policy.allowsEgressHost(URL(string: "https://mcp.example.com/mcp")!),
                       "a different effective port is not covered")
        XCTAssertFalse(policy.allowsEgressHost(URL(string: "http://mcp.example.com:8443/mcp")!),
                       "a different scheme is not covered")
        XCTAssertFalse(policy.allowsEgressHost(URL(string: "https://other.example.com:8443/mcp")!))
        XCTAssertTrue(policy.allowsEgressHost(URL(string: "https://mcp.example.com:8443/mcp?x=1")!),
                      "the grant scopes the origin and path; the query does not widen a sibling path")

        let base = RecordingCredentialProvider(value: "model-key")
        let provider = PhoneMCPCredentialProvider(policy: policy, base: base)
        let mcpScope = ModelGatewayCredentialRouting.scope(for: URL(string: Self.mcpURL)!)
        let credential = try await provider.credential(for: mcpScope)
        XCTAssertEqual(credential.kind, .headers(["Authorization": Self.token]))
        XCTAssertEqual(credential.value, "")

        // Same host, different path: the MCP router must not answer with the
        // MCP value. The model provider remains authoritative for its own path
        // (task A tightens that provider's path scope).
        let modelCredential = try await provider.credential(
            for: ModelGatewayCredentialRouting.scope(
                for: URL(string: "https://mcp.example.com:8443/v1/messages")!))
        XCTAssertEqual(modelCredential.kind, .apiKey(header: "x-api-key"))
        XCTAssertEqual(modelCredential.value, "model-key")
        XCTAssertEqual(base.scopes, [CredentialScope(service: "mcp.example.com",
                                                     audience: "/v1/messages",
                                                     scheme: "https",
                                                     port: 8443)])
    }

    func testSecondServerNameForTheSameExactURLIsRefusedBeforeAnySecretWrite() throws {
        let first = try settings.grant(serverName: "mcp",
                                       url: Self.mcpURL,
                                       headers: ["Authorization"],
                                       values: ["Authorization": Self.token])
        try settings.commitGrant(serverName: first.serverName,
                                 expectedURL: first.url,
                                 expectedHeaders: first.headers)
        let before = try XCTUnwrap(defaults.data(forKey: PhoneMCPAccessSettings.defaultsKey))

        XCTAssertThrowsError(try settings.grant(
            serverName: "other",
            url: Self.mcpURL,
            headers: ["Authorization"],
            values: ["Authorization": "Bearer other-token"])) { error in
            XCTAssertEqual(error as? PhoneMCPAccessError, .duplicateURL("mcp"))
        }
        XCTAssertEqual(defaults.data(forKey: PhoneMCPAccessSettings.defaultsKey), before,
                       "a refused duplicate must not touch the grant document")
        XCTAssertEqual(settings.secretValues(for: "mcp")?["Authorization"], Self.token)
        XCTAssertNil(settings.secretValues(for: "other"))
        XCTAssertEqual(settings.makePolicy().authorizedURLs.count, 1,
                       "one exact route has exactly one credential slot")
    }

    func testEndpointChangeKeepsTheOldValueUntilTheUpsertCommits() throws {
        let old = try settings.grant(serverName: "mcp",
                                     url: Self.mcpURL,
                                     headers: ["Authorization"],
                                     values: ["Authorization": Self.token])
        let oldSecretID = try XCTUnwrap(old.secretID)
        let oldAccount = "mcp.mcp.\(oldSecretID)"
        try settings.commitGrant(serverName: "mcp",
                                 expectedURL: old.url,
                                 expectedHeaders: old.headers)
        let new = try settings.grant(serverName: "mcp",
                                     url: "https://other.example.com/mcp",
                                     headers: ["Authorization"])
        XCTAssertNil(new.secretID, "an unauthenticated endpoint has no secret account")
        XCTAssertEqual(secrets.value(for: oldAccount)?.contains("mcp-device-token"), true,
                       "the old account stays available until the Worker upsert commits")
        XCTAssertEqual(try settings.load().grants.first?.url,
                       "https://other.example.com/mcp")

        XCTAssertTrue(try settings.commitGrant(serverName: "mcp",
                                               expectedURL: new.url,
                                               expectedHeaders: new.headers))
        XCTAssertNil(secrets.value(for: oldAccount),
                     "a committed endpoint move must drop the old account")
        XCTAssertEqual(secrets.allValues().contains { $0.contains(Self.token) }, false)
    }

    func testRevokeRemovesGrantAndDedicatedKeychainValue() throws {
        let granted = try settings.grant(serverName: "mcp",
                                         url: Self.mcpURL,
                                         headers: ["Authorization"],
                                         values: ["Authorization": Self.token])
        let secretID = try XCTUnwrap(granted.secretID)
        let account = "mcp.mcp.\(secretID)"
        XCTAssertEqual(secrets.value(for: account)?.contains("mcp-device-token"), true)

        try settings.revoke(serverName: "mcp")
        XCTAssertTrue(try settings.load().grants.isEmpty)
        XCTAssertNil(secrets.value(for: account))
        XCTAssertFalse(settings.makePolicy().allowsEgressHost(URL(string: Self.mcpURL)!))
        XCTAssertEqual(PhoneMCPAccessSettings.defaultKeychainService,
                       "dev.phone-dsh.probe.mcp")
        XCTAssertNotEqual(PhoneMCPAccessSettings.defaultKeychainService,
                          PhoneWebSearchSettings.defaultKeychainService)
    }

    func testFailedIntentDocumentCommitNeverWritesTheNewKeychainValue() throws {
        let old = try settings.grant(serverName: "mcp",
                                     url: Self.mcpURL,
                                     headers: ["Authorization"],
                                     values: ["Authorization": Self.token])
        try settings.commitGrant(serverName: "mcp",
                                 expectedURL: old.url,
                                 expectedHeaders: old.headers)
        let oldSecretID = try XCTUnwrap(old.secretID)
        let oldAccount = "mcp.mcp.\(oldSecretID)"
        let failing = FailingMCPDocumentStore(
            data: try XCTUnwrap(defaults.data(forKey: PhoneMCPAccessSettings.defaultsKey)))
        failing.failWrites = true
        let transactional = PhoneMCPAccessSettings(documentStore: failing,
                                                   secretStore: secrets)
        XCTAssertThrowsError(try transactional.grant(
            serverName: "mcp",
            url: "https://mcp.example.com:8443/other",
            headers: ["Authorization"],
            values: ["Authorization": "Bearer replacement"])) { error in
            XCTAssertEqual(error as? PhoneMCPAccessError, .documentStore)
        }
        XCTAssertEqual(secrets.value(for: oldAccount)?.contains("mcp-device-token"), true,
                       "a failed intent commit must not touch the old endpoint's key")
        XCTAssertEqual(secrets.allValues().contains { $0.contains("replacement") }, false)
        XCTAssertEqual(try transactional.load().grants.first?.url, Self.mcpURL)
    }

    func testCrashBetweenSecretWriteAndGrantCommitKeepsTheOldURLAuthoritative() async throws {
        let old = try settings.grant(serverName: "mcp",
                                     url: Self.mcpURL,
                                     headers: ["Authorization"],
                                     values: ["Authorization": Self.token])
        try settings.commitGrant(serverName: "mcp",
                                 expectedURL: old.url,
                                 expectedHeaders: old.headers)
        let oldSecretID = try XCTUnwrap(old.secretID)
        let oldAccount = "mcp.mcp.\(oldSecretID)"
        let store = FailingMCPDocumentStore(
            data: try XCTUnwrap(defaults.data(forKey: PhoneMCPAccessSettings.defaultsKey)))
        // The first write records the pending new account; the second is the
        // grant commit. Fail it after the new Keychain value was written.
        store.failWriteNumber = 2
        let crashing = PhoneMCPAccessSettings(documentStore: store, secretStore: secrets)
        XCTAssertThrowsError(try crashing.grant(
            serverName: "mcp",
            url: "https://mcp.example.com:8443/other",
            headers: ["Authorization"],
            values: ["Authorization": "Bearer replacement"])) { error in
            XCTAssertEqual(error as? PhoneMCPAccessError, .documentStore)
        }

        // A fresh process loads the still-old grant, deletes the unreferenced
        // pending account, and never injects the replacement into the old URL.
        let reloaded = PhoneMCPAccessSettings(documentStore: store, secretStore: secrets)
        let snapshot = try reloaded.load()
        XCTAssertEqual(snapshot.grants.first?.url, Self.mcpURL)
        XCTAssertEqual(secrets.value(for: oldAccount)?.contains("replacement"), false)
        XCTAssertEqual(secrets.value(for: oldAccount)?.contains("mcp-device-token"), true)
        XCTAssertEqual(secrets.allValues().contains { $0.contains("replacement") }, false,
                       "the pending new account is cleaned instead of being read by the old URL")
        let policy = reloaded.makePolicy()
        let provider = PhoneMCPCredentialProvider(
            policy: policy,
            base: RecordingCredentialProvider(value: "model-key"))
        let credential = try await provider.credential(
            for: ModelGatewayCredentialRouting.scope(for: URL(string: Self.mcpURL)!))
        XCTAssertEqual(credential.kind, .headers(["Authorization": Self.token]))
    }

    func testSecretReadFailureLeavesTheOldGrantAndKeychainValueUntouched() throws {
        let old = try settings.grant(serverName: "mcp",
                                     url: Self.mcpURL,
                                     headers: ["Authorization"],
                                     values: ["Authorization": Self.token])
        try settings.commitGrant(serverName: "mcp",
                                 expectedURL: old.url,
                                 expectedHeaders: old.headers)
        let oldSecretID = try XCTUnwrap(old.secretID)
        let oldAccount = "mcp.mcp.\(oldSecretID)"
        let before = try XCTUnwrap(defaults.data(forKey: PhoneMCPAccessSettings.defaultsKey))
        secrets.failReadOnceFor = oldAccount

        XCTAssertThrowsError(try settings.grant(serverName: "mcp",
                                                url: Self.mcpURL,
                                                headers: ["Authorization"])) { error in
            XCTAssertEqual(error as? PhoneMCPAccessError, .secretStore)
        }
        XCTAssertEqual(defaults.data(forKey: PhoneMCPAccessSettings.defaultsKey), before,
                       "a failed previous-value read must not write a pending/reset document")
        XCTAssertEqual(secrets.value(for: oldAccount)?.contains("mcp-device-token"), true)
        XCTAssertEqual(try settings.load().grants.first?.url, Self.mcpURL)
        XCTAssertEqual(settings.secretValues(for: "mcp")?["Authorization"], Self.token)
    }

    func testCrashAfterGrantBeforeUpsertRestoresTheOldURLFromTheRegistry() throws {
        let old = try settings.grant(serverName: "mcp",
                                     url: Self.mcpURL,
                                     headers: ["Authorization"],
                                     values: ["Authorization": Self.token])
        try settings.commitGrant(serverName: "mcp",
                                 expectedURL: old.url,
                                 expectedHeaders: old.headers)
        let oldSecretID = try XCTUnwrap(old.secretID)
        let oldAccount = "mcp.mcp.\(oldSecretID)"

        // A native/Web save writes the new URL and its new Keychain account,
        // but the process dies before phone/mcpUpsert commits the row.
        let moved = try settings.grant(serverName: "mcp",
                                       url: "https://other.example.com/mcp",
                                       headers: ["Authorization"],
                                       values: ["Authorization": "Bearer replacement"])
        XCTAssertNotNil(moved.secretID)
        XCTAssertEqual(settings.secretValues(for: "mcp")?["Authorization"],
                       "Bearer replacement")
        XCTAssertEqual(secrets.value(for: oldAccount)?.contains("mcp-device-token"), true)

        let plain = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-crash-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: plain) }
        let registry = #"{"version":1,"servers":[{"serverName":"mcp","url":"\#(Self.mcpURL)"}]}"#
        try Data(registry.utf8).write(to: plain.appendingPathComponent("mcp.json"))

        // Fresh process, same document and Keychain: the Worker registry still
        // names the old URL, so the staged grant is rolled back without asking
        // any in-memory snapshot to rewrite a secret.
        let reloaded = PhoneMCPAccessSettings(defaults: defaults, secretStore: secrets)
        reloaded.reconcile(materializedHome: plain)
        XCTAssertEqual(try reloaded.load().grants.first?.url, Self.mcpURL)
        XCTAssertEqual(reloaded.secretValues(for: "mcp")?["Authorization"], Self.token)
        XCTAssertEqual(secrets.value(for: oldAccount)?.contains("mcp-device-token"), true)
        XCTAssertEqual(secrets.allValues().contains { $0.contains("replacement") }, false,
                       "the new endpoint's account is deleted on crash recovery")
        let policy = reloaded.makePolicy()
        XCTAssertTrue(policy.allowsEgressHost(URL(string: Self.mcpURL)!))
        XCTAssertFalse(policy.allowsEgressHost(URL(string: "https://other.example.com/mcp")!))
    }

    func testCrashAfterUpsertFinalizesTheStagedGrantAndDeletesTheOldValue() throws {
        let old = try settings.grant(serverName: "mcp",
                                     url: Self.mcpURL,
                                     headers: ["Authorization"],
                                     values: ["Authorization": Self.token])
        try settings.commitGrant(serverName: "mcp",
                                 expectedURL: old.url,
                                 expectedHeaders: old.headers)
        let oldSecretID = try XCTUnwrap(old.secretID)
        let oldAccount = "mcp.mcp.\(oldSecretID)"

        let movedURL = "https://other.example.com/mcp"
        let moved = try settings.grant(serverName: "mcp",
                                       url: movedURL,
                                       headers: ["Authorization"],
                                       values: ["Authorization": "Bearer replacement"])
        XCTAssertNotNil(moved.secretID)

        let plain = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-committed-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: plain) }
        let registry = #"{"version":1,"servers":[{"serverName":"mcp","url":"\#(movedURL)"}]}"#
        try Data(registry.utf8).write(to: plain.appendingPathComponent("mcp.json"))

        let reloaded = PhoneMCPAccessSettings(defaults: defaults, secretStore: secrets)
        reloaded.reconcile(materializedHome: plain)
        XCTAssertEqual(try reloaded.load().grants.first?.url, movedURL)
        XCTAssertEqual(reloaded.secretValues(for: "mcp")?["Authorization"],
                       "Bearer replacement")
        XCTAssertNil(secrets.value(for: oldAccount),
                     "the old account is removed once the registry proves the upsert committed")
        XCTAssertFalse(secrets.allValues().contains { $0.contains(Self.token) })
    }

    func testAbandonedStagingCommitsWhenTheRegistryNamesTheCanonicalDesiredURL() throws {
        let old = try settings.grant(serverName: "mcp",
                                     url: Self.mcpURL,
                                     headers: ["Authorization"],
                                     values: ["Authorization": Self.token])
        try settings.commitGrant(serverName: "mcp",
                                 expectedURL: old.url,
                                 expectedHeaders: old.headers)
        let oldSecretID = try XCTUnwrap(old.secretID)
        let oldAccount = "mcp.mcp.\(oldSecretID)"
        let movedURL = "https://other.example.com/mcp"
        let moved = try settings.grant(serverName: "mcp",
                                       url: movedURL,
                                       headers: ["Authorization"],
                                       values: ["Authorization": "Bearer replacement"])
        let movedSecretID = try XCTUnwrap(moved.secretID)
        let movedAccount = "mcp.mcp.\(movedSecretID)"

        // A page exit/timeout marks the stage ownerless; it does not decide.
        try settings.markStagedGrantsAbandoned(serverNames: ["mcp"])
        XCTAssertEqual(try settings.load().grants.first?.url, movedURL)

        let removed = try settings.reconcile(existingServers: [
            "mcp": "https://OTHER.example.com:443/mcp/",
        ])
        XCTAssertEqual(removed, [])
        XCTAssertEqual(try settings.load().grants.first?.url, movedURL)
        XCTAssertEqual(settings.secretValues(for: "mcp")?["Authorization"],
                       "Bearer replacement")
        XCTAssertNil(secrets.value(for: oldAccount),
                     "the abandoned previous account is removed after commit")
        XCTAssertNotNil(secrets.value(for: movedAccount))
    }

    func testAbandonedStagingRollsBackOnlyWhenTheRegistryConfirmsThePreviousRow() throws {
        let old = try settings.grant(serverName: "mcp",
                                     url: Self.mcpURL,
                                     headers: ["Authorization"],
                                     values: ["Authorization": Self.token])
        try settings.commitGrant(serverName: "mcp",
                                 expectedURL: old.url,
                                 expectedHeaders: old.headers)
        let moved = try settings.grant(serverName: "mcp",
                                       url: "https://other.example.com/mcp",
                                       headers: ["Authorization"],
                                       values: ["Authorization": "Bearer replacement"])
        let movedSecretID = try XCTUnwrap(moved.secretID)
        let movedAccount = "mcp.mcp.\(movedSecretID)"
        try settings.markStagedGrantsAbandoned(serverNames: ["mcp"])

        let removed = try settings.reconcile(existingServers: [
            "mcp": "https://MCP.EXAMPLE.COM:8443/mcp/",
        ])
        XCTAssertEqual(removed, ["mcp"])
        XCTAssertEqual(try settings.load().grants.first?.url, Self.mcpURL)
        XCTAssertEqual(settings.secretValues(for: "mcp")?["Authorization"], Self.token)
        XCTAssertNil(secrets.value(for: movedAccount))
    }

    func testNewEditOnAnAbandonedStageRequiresRegistryResolution() throws {
        let old = try settings.grant(serverName: "mcp",
                                     url: Self.mcpURL,
                                     headers: ["Authorization"],
                                     values: ["Authorization": Self.token])
        try settings.commitGrant(serverName: old.serverName,
                                 expectedURL: old.url,
                                 expectedHeaders: old.headers)
        let oldAccount = "mcp.mcp.\(try XCTUnwrap(old.secretID))"

        let movedURL = "https://other.example.com/mcp"
        let moved = try settings.grant(serverName: "mcp",
                                       url: movedURL,
                                       headers: ["Authorization"],
                                       values: ["Authorization": "Bearer replacement"])
        let movedAccount = "mcp.mcp.\(try XCTUnwrap(moved.secretID))"
        try settings.markStagedGrantsAbandoned(serverNames: ["mcp"])

        // The abandoned A→B stage has no trustworthy rollback target: B may
        // or may not have reached the Worker. A new C save must be refused
        // until a successful registry read resolves the old stage.
        XCTAssertThrowsError(try settings.grant(
            serverName: "mcp",
            url: "https://third.example.com/mcp",
            headers: ["Authorization"],
            values: ["Authorization": "Bearer latest"])) { error in
            XCTAssertEqual(error as? PhoneMCPAccessError,
                           .stagedGrantUnresolved("mcp"))
        }
        XCTAssertEqual(try settings.load().grants.first?.url, movedURL)
        XCTAssertEqual(settings.secretValues(for: "mcp")?["Authorization"],
                       "Bearer replacement")
        XCTAssertEqual(try settings.stagedPreviousGrant(serverName: "mcp")?.url,
                       Self.mcpURL)
        XCTAssertNotNil(secrets.value(for: oldAccount),
                        "the refused edit must not delete the staged old account")
        XCTAssertFalse(secrets.allValues().contains { $0.contains("latest") },
                       "a refused edit must not write its new Keychain value")

        // The real registry names B: commit the abandoned stage, then the new
        // edit can use B as its rollback base.
        XCTAssertEqual(try settings.reconcile(existingServers: ["mcp": movedURL]), [])
        XCTAssertFalse(try settings.hasStagedGrant(serverName: "mcp"))
        XCTAssertNil(secrets.value(for: oldAccount))
        XCTAssertNotNil(secrets.value(for: movedAccount))

        let latestURL = "https://third.example.com/mcp"
        let latest = try settings.grant(serverName: "mcp",
                                        url: latestURL,
                                        headers: ["Authorization"],
                                        values: ["Authorization": "Bearer latest"])
        let latestAccount = "mcp.mcp.\(try XCTUnwrap(latest.secretID))"
        XCTAssertEqual(try settings.stagedPreviousGrant(serverName: "mcp")?.url,
                       movedURL)
        XCTAssertTrue(try settings.rollbackGrant(serverName: "mcp",
                                                 expectedURL: latest.url,
                                                 expectedHeaders: latest.headers))
        XCTAssertEqual(try settings.load().grants.first?.url, movedURL)
        XCTAssertEqual(settings.secretValues(for: "mcp")?["Authorization"],
                       "Bearer replacement")
        XCTAssertNil(secrets.value(for: latestAccount))
        XCTAssertNotNil(secrets.value(for: movedAccount))
        XCTAssertFalse(try settings.hasStagedGrant(serverName: "mcp"))
    }

    func testRollbackReturnsFalseForANewerEditAndLeavesItsStagingResolvable() throws {
        let old = try settings.grant(serverName: "mcp",
                                     url: Self.mcpURL,
                                     headers: ["Authorization"],
                                     values: ["Authorization": Self.token])
        try settings.commitGrant(serverName: old.serverName,
                                 expectedURL: old.url,
                                 expectedHeaders: old.headers)

        let movedURL = "https://other.example.com/mcp"
        let moved = try settings.grant(serverName: "mcp",
                                       url: movedURL,
                                       headers: ["Authorization"],
                                       values: ["Authorization": "Bearer replacement"])
        try settings.commitGrant(serverName: moved.serverName,
                                 expectedURL: moved.url,
                                 expectedHeaders: moved.headers)

        let latestURL = "https://third.example.com/mcp"
        let latest = try settings.grant(serverName: "mcp",
                                        url: latestURL,
                                        headers: ["Authorization"],
                                        values: ["Authorization": "Bearer latest"])

        // A newer edit owns the slot. Rolling back the older expected URL must
        // report `false`, not claim that it restored anything.
        let newestURL = "https://fourth.example.com/mcp"
        let newest = try settings.grant(serverName: "mcp",
                                        url: newestURL,
                                        headers: ["Authorization"],
                                        values: ["Authorization": "Bearer newest"])
        XCTAssertEqual(try settings.stagedPreviousGrant(serverName: "mcp")?.url,
                       movedURL,
                       "a live stage keeps the last committed grant as its base")
        XCTAssertFalse(try settings.rollbackGrant(serverName: "mcp",
                                                  expectedURL: latest.url,
                                                  expectedHeaders: latest.headers))
        XCTAssertEqual(try settings.load().grants.first?.url, newestURL)
        XCTAssertTrue(try settings.hasStagedGrant(serverName: "mcp"))

        // Mark ownerless, then let the authoritative registry decide: it still
        // names B, so the newer D edit rolls back to B and keeps B's account.
        try settings.markStagedGrantsAbandoned(serverNames: ["mcp"])
        XCTAssertEqual(try settings.reconcile(existingServers: ["mcp": movedURL]),
                       ["mcp"])
        XCTAssertEqual(try settings.load().grants.first?.url, movedURL)
        XCTAssertEqual(settings.secretValues(for: "mcp")?["Authorization"],
                       "Bearer replacement")
        XCTAssertFalse(secrets.allValues().contains { $0.contains("latest") })
        XCTAssertFalse(secrets.allValues().contains { $0.contains("newest") })
        XCTAssertFalse(secrets.allValues().contains { $0.contains(Self.token) })
        XCTAssertEqual(newest.serverName, "mcp")
    }

    func testMaterializedStartCommitsAnAbandonedStagingRow() throws {
        let old = try settings.grant(serverName: "mcp",
                                     url: Self.mcpURL,
                                     headers: ["Authorization"],
                                     values: ["Authorization": Self.token])
        try settings.commitGrant(serverName: "mcp",
                                 expectedURL: old.url,
                                 expectedHeaders: old.headers)
        let oldSecretID = try XCTUnwrap(old.secretID)
        let oldAccount = "mcp.mcp.\(oldSecretID)"
        let moved = try settings.grant(serverName: "mcp",
                                       url: "https://other.example.com/mcp",
                                       headers: ["Authorization"],
                                       values: ["Authorization": "Bearer replacement"])
        try settings.markStagedGrantsAbandoned(serverNames: ["mcp"])

        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-abandoned-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let registry = #"{"version":1,"servers":[{"serverName":"mcp","url":"https://OTHER.example.com:443/mcp/"}]}"#
        try Data(registry.utf8).write(to: home.appendingPathComponent("mcp.json"))

        // Fresh process, same document/Keychain: the materialized registry is
        // the authority and commits the abandoned stage instead of rolling it
        // back or protecting it forever.
        let reloaded = PhoneMCPAccessSettings(defaults: defaults, secretStore: secrets)
        reloaded.reconcile(materializedHome: home)
        XCTAssertEqual(try reloaded.load().grants.first?.url, moved.url)
        XCTAssertEqual(reloaded.secretValues(for: "mcp")?["Authorization"],
                       "Bearer replacement")
        XCTAssertNil(secrets.value(for: oldAccount))
    }

    func testCommitUsesCanonicalEndpointAndQueryButIgnoresFragments() throws {
        let granted = try settings.grant(serverName: "mcp",
                                         url: "https://mcp.example.com/mcp?x=1#fragment",
                                         headers: ["Authorization"],
                                         values: ["Authorization": Self.token])
        XCTAssertEqual(granted.url, "https://mcp.example.com/mcp?x=1")
        XCTAssertTrue(try settings.commitGrant(
            serverName: "mcp",
            expectedURL: "https://MCP.EXAMPLE.COM:443/mcp/?x=1#ignored",
            expectedHeaders: ["Authorization"]),
            "trailing slash, explicit default port and fragment do not change the endpoint")

        // The query is part of the endpoint identity for resolve. A different
        // query is not the committed row, so an abandoned stage is dropped
        // instead of being mistaken for a match.
        _ = try settings.grant(serverName: "mcp",
                               url: "https://mcp.example.com/mcp?x=1",
                               headers: ["Authorization"])
        try settings.markStagedGrantsAbandoned(serverNames: ["mcp"])
        _ = try settings.reconcile(existingServers: [
            "mcp": "https://mcp.example.com/mcp?x=2",
        ])
        XCTAssertTrue(try settings.load().grants.isEmpty)
        XCTAssertFalse(secrets.allValues().contains { $0.contains(Self.token) })
    }

    func testRollbackDocumentFailureKeepsStagingAndSucceedsOnRetry() throws {
        let store = FailingMCPDocumentStore()
        let transactional = PhoneMCPAccessSettings(documentStore: store,
                                                   secretStore: secrets)
        let old = try transactional.grant(serverName: "mcp",
                                          url: Self.mcpURL,
                                          headers: ["Authorization"],
                                          values: ["Authorization": Self.token])
        try transactional.commitGrant(serverName: "mcp",
                                      expectedURL: old.url,
                                      expectedHeaders: old.headers)
        let moved = try transactional.grant(serverName: "mcp",
                                            url: "https://other.example.com/mcp",
                                            headers: ["Authorization"],
                                            values: ["Authorization": "Bearer replacement"])

        store.failWrites = true
        XCTAssertThrowsError(try transactional.rollbackGrant(
            serverName: "mcp",
            expectedURL: moved.url,
            expectedHeaders: moved.headers)) { error in
            XCTAssertEqual(error as? PhoneMCPAccessError, .documentStore)
        }
        // The failed write did not persist the rollback: the staged previous
        // grant and the failed endpoint's account are both still recoverable.
        XCTAssertEqual(try transactional.load().grants.first?.url, moved.url)
        XCTAssertEqual(transactional.secretValues(for: "mcp")?["Authorization"],
                       "Bearer replacement")

        store.failWrites = false
        XCTAssertTrue(try transactional.rollbackGrant(
            serverName: "mcp",
            expectedURL: moved.url,
            expectedHeaders: moved.headers))
        XCTAssertEqual(try transactional.load().grants.first?.url, Self.mcpURL)
        XCTAssertEqual(transactional.secretValues(for: "mcp")?["Authorization"],
                       Self.token)
        XCTAssertFalse(secrets.allValues().contains { $0.contains("replacement") })
    }

    func testExplicitSchemeDefaultPortsAreCanonicalAndDoNotSelfRevoke() throws {
        let https = try settings.grant(serverName: "https-default",
                                       url: "https://mcp.example.com:443/mcp",
                                       headers: ["Authorization"],
                                       values: ["Authorization": "Bearer https-default"])
        try settings.commitGrant(serverName: https.serverName,
                                 expectedURL: https.url,
                                 expectedHeaders: https.headers)
        let http = try settings.grant(serverName: "http-default",
                                      url: "http://lan.example.com:80/mcp",
                                      headers: ["Authorization"],
                                      values: ["Authorization": "Bearer http-default"])
        try settings.commitGrant(serverName: http.serverName,
                                 expectedURL: http.url,
                                 expectedHeaders: http.headers)
        let snapshot = try settings.load()
        XCTAssertEqual(snapshot.grants.first { $0.serverName == "https-default" }?.url,
                       "https://mcp.example.com/mcp")
        XCTAssertEqual(snapshot.grants.first { $0.serverName == "http-default" }?.url,
                       "http://lan.example.com/mcp")
        // The Worker persists `new URL(...).toString()`, which drops the
        // scheme-default port. This must not be treated as an endpoint move.
        XCTAssertEqual(try settings.reconcile(existingServers: [
            "https-default": "https://mcp.example.com/mcp",
            "http-default": "http://lan.example.com/mcp",
        ]), [])
        XCTAssertEqual(settings.secretValues(for: "https-default")?["Authorization"],
                       "Bearer https-default",
                       "a canonical default-port URL must not delete its Keychain value")
        XCTAssertEqual(settings.secretValues(for: "http-default")?["Authorization"],
                       "Bearer http-default")
        let policy = settings.makePolicy()
        XCTAssertTrue(policy.allowsEgressHost(
            URL(string: "https://mcp.example.com:443/mcp")!))
        XCTAssertTrue(policy.allowsEgressHost(
            URL(string: "http://lan.example.com:80/mcp")!))
    }

    func testInterruptedRevokeRetriesTheKeychainDeletion() throws {
        let granted = try settings.grant(serverName: "mcp",
                                         url: Self.mcpURL,
                                         headers: ["Authorization"],
                                         values: ["Authorization": Self.token])
        let secretID = try XCTUnwrap(granted.secretID)
        let account = "mcp.mcp.\(secretID)"
        secrets.failDeleteOnceFor = account
        XCTAssertThrowsError(try settings.revoke(serverName: "mcp")) { error in
            XCTAssertEqual(error as? PhoneMCPAccessError, .secretStore)
        }
        // The grant is already gone (fail closed), but the failed Keychain
        // deletion is journaled and the old account still exists.
        let interrupted = try storedDocument()
        XCTAssertTrue((interrupted["grants"] as? [Any])?.isEmpty == true)
        XCTAssertEqual(interrupted["pendingSecretDeletions"] as? [String], [account])
        XCTAssertEqual(secrets.value(for: account)?.contains("mcp-device-token"), true)

        // The first `load()` retries the recorded deletion. The grant stays
        // revoked and the journal is cleared only after the Keychain delete wins.
        let snapshot = try settings.load()
        XCTAssertTrue(snapshot.grants.isEmpty)
        let completed = try storedDocument()
        XCTAssertEqual(completed["pendingSecretDeletions"] as? [String] ?? [], [])
        XCTAssertNil(secrets.value(for: account))
        XCTAssertFalse(settings.makePolicy().allowsEgressHost(URL(string: Self.mcpURL)!))

        // A later load is idempotent: still no grant, no value and no route.
        XCTAssertTrue(try settings.load().grants.isEmpty)
        XCTAssertNil(secrets.value(for: account))
        XCTAssertFalse(settings.makePolicy().allowsEgressHost(URL(string: Self.mcpURL)!))
    }

    private func storedDocument() throws -> [String: Any] {
        let data = try XCTUnwrap(defaults.data(forKey: PhoneMCPAccessSettings.defaultsKey))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testUrlReconcileDropsAGrantForAServerWhoseUrlMoved() throws {
        let moved = try settings.grant(serverName: "moved", url: Self.mcpURL, headers: [])
        try settings.commitGrant(serverName: moved.serverName,
                                 expectedURL: moved.url,
                                 expectedHeaders: moved.headers)
        let kept = try settings.grant(serverName: "kept",
                                      url: "https://kept.example.com/mcp",
                                      headers: [])
        try settings.commitGrant(serverName: kept.serverName,
                                 expectedURL: kept.url,
                                 expectedHeaders: kept.headers)
        let removed = try settings.reconcile(existingServers: [
            "moved": "https://moved.example.com/mcp",
            "kept": "https://kept.example.com/mcp/",
        ])
        XCTAssertEqual(removed, ["moved"])
        XCTAssertEqual(try settings.load().grants.map(\.serverName), ["kept"])
    }

    func testMaterializedRegistryReconcileLeavesAMissingFileAlone() throws {
        try settings.grant(serverName: "kept", url: Self.mcpURL, headers: [])
        let plain = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-materialized-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: plain) }

        settings.reconcile(materializedHome: plain)
        XCTAssertEqual(try settings.load().grants.map(\.serverName), ["kept"],
                       "a missing materialized file is not an empty registry")

        try Data(#"{"version":1,"servers":[]}"#.utf8)
            .write(to: plain.appendingPathComponent("mcp.json"))
        settings.reconcile(materializedHome: plain)
        XCTAssertTrue(try settings.load().grants.isEmpty)
    }

    func testReconcileRevokesRowsRemovedFromTheWorkerRegistry() throws {
        let kept = try settings.grant(serverName: "kept", url: Self.mcpURL, headers: [])
        try settings.commitGrant(serverName: kept.serverName,
                                 expectedURL: kept.url,
                                 expectedHeaders: kept.headers)
        let gone = try settings.grant(serverName: "gone",
                                      url: "https://gone.example.com/mcp",
                                      headers: ["Authorization"],
                                      values: ["Authorization": "Bearer gone"])
        try settings.commitGrant(serverName: gone.serverName,
                                 expectedURL: gone.url,
                                 expectedHeaders: gone.headers)
        let removed = try settings.reconcile(existingServerNames: ["kept"])
        XCTAssertEqual(removed, ["gone"])
        XCTAssertEqual(try settings.load().grants.map(\.serverName), ["kept"])
        XCTAssertEqual(secrets.allValues().contains { $0.contains("Bearer gone") }, false)
    }
}

private final class InMemoryMCPScretStore: ModelProviderSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    var failDeleteOnceFor: String?
    var failReadOnceFor: String?

    func allValues() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(values.values)
    }

    func secret(for reference: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        if failReadOnceFor == reference {
            failReadOnceFor = nil
            throw ModelProviderSettingsError.keychain(-1)
        }
        return values[reference]
    }

    func setSecret(_ secret: String, for reference: String) throws {
        lock.lock()
        values[reference] = secret
        lock.unlock()
    }

    func deleteSecret(for reference: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if failDeleteOnceFor == reference {
            failDeleteOnceFor = nil
            throw ModelProviderSettingsError.keychain(-1)
        }
        values.removeValue(forKey: reference)
    }

    func value(for reference: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[reference]
    }
}

private final class FailingMCPDocumentStore: PhoneMCPAccessDocumentStore, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var writes = 0
    var failWrites = false
    /// Fail exactly this write number (1-based); used to stop after the
    /// pending-secret intent but before the grant commit.
    var failWriteNumber: Int?

    init(data: Data? = nil) {
        self.data = data
    }

    func read() throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return data
    }

    func write(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        writes += 1
        if failWrites || writes == failWriteNumber {
            throw PhoneMCPAccessError.documentStore
        }
        self.data = data
    }
}

private final class RecordingCredentialProvider: CredentialProvider, @unchecked Sendable {
    let value: String
    private let lock = NSLock()
    private(set) var scopes: [CredentialScope] = []

    init(value: String) {
        self.value = value
    }

    func credential(for scope: CredentialScope) async throws -> Credential {
        lock.lock()
        scopes.append(scope)
        lock.unlock()
        return Credential(kind: .apiKey(header: "x-api-key"), value: value)
    }

    func invalidate(_ credential: Credential, for scope: CredentialScope) async {}
}
