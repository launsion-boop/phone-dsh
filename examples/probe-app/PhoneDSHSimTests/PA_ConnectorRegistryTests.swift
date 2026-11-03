// SPDX-License-Identifier: MIT

import Foundation
import ProbeKit
import XCTest

final class PA_ConnectorRegistryTests: XCTestCase {
    func testVerificationRequiredAndRevokeIsImmediate() async throws {
        let credentials = InMemoryConnectorCredentials()
        try credentials.saveCredential("test-only-secret", for: "github.pat")
        let store = InMemoryConnectorStore()
        let registry = try PersistentConnectorRegistry(store: store, credentials: credentials)
        let grant = ConnectorGrant(connectorID: "github", version: 1, allowedActions: [.read],
                                   scope: GrantScope(repositories: ["owner/repo"]))
        do {
            _ = try await registry.connect("github", grant: grant, credentialRef: "github.pat") {
                throw ConnectorVerificationFailure(state: .expired, issue: "expired")
            }
            XCTFail("failed verification must not connect")
        } catch {}
        let expired = await registry.state(of: "github")
        let expiredGrant = await registry.grant(of: "github")
        XCTAssertEqual(expired.state, .expired)
        XCTAssertNil(expiredGrant)

        _ = try await registry.connect("github", grant: grant, credentialRef: "github.pat") {}
        let connected = await registry.state(of: "github")
        XCTAssertEqual(connected.state, .connected)
        try await registry.revoke("github")
        let revoked = await registry.state(of: "github")
        let revokedGrant = await registry.grant(of: "github")
        XCTAssertEqual(revoked.state, .revoked)
        XCTAssertNil(revokedGrant)
        XCTAssertFalse(credentials.contains("github.pat"))

        let reloaded = try PersistentConnectorRegistry(store: store, credentials: credentials)
        let persistedRevocation = await reloaded.state(of: "github")
        XCTAssertEqual(persistedRevocation.state, .revoked)
    }

    func testSQLitePersistenceContainsNoCredential() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("domain.sqlite")
        let credentials = InMemoryConnectorCredentials()
        try credentials.saveCredential("test-only-secret", for: "github.pat")
        let store = try SQLiteConnectorStore(databaseURL: database)
        let registry = try PersistentConnectorRegistry(store: store, credentials: credentials)
        let grant = ConnectorGrant(connectorID: "github", version: 1, allowedActions: [.read],
                                   scope: GrantScope(repositories: ["owner/repo"]))
        _ = try await registry.connect("github", grant: grant, credentialRef: "github.pat") {}
        try store.setString("cursor", forKey: "followup:test")

        let reloaded = try PersistentConnectorRegistry(store: store, credentials: credentials)
        let persisted = await reloaded.state(of: "github")
        XCTAssertEqual(persisted.state, .connected)
        XCTAssertEqual(try store.string(forKey: "followup:test"), "cursor")
        for suffix in ["", "-wal", "-shm"] {
            let url = URL(fileURLWithPath: database.path + suffix)
            guard let data = FileManager.default.contents(atPath: url.path) else { continue }
            XCTAssertNil(data.range(of: Data("test-only-secret".utf8)))
        }
    }
}
