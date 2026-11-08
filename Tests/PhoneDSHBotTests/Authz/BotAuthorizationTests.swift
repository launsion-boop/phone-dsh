// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

private func assertTrue(_ expression: @autoclosure () async throws -> Bool) async rethrows {
    let value = try await expression()
    XCTAssertTrue(value)
}

private func assertFalse(_ expression: @autoclosure () async throws -> Bool) async rethrows {
    let value = try await expression()
    XCTAssertFalse(value)
}

private func assertEqual<T: Equatable>(_ lhs: @autoclosure () async throws -> T,
                                       _ rhs: @autoclosure () async throws -> T) async rethrows {
    let left = try await lhs()
    let right = try await rhs()
    XCTAssertEqual(left, right)
}

final class BotAuthorizationTests: XCTestCase {
    private let effect = BotToolEffect(tool: "memory", operation: "memory.forget",
                                       resource: "memory:user&fact=shared", mutability: .destructive,
                                       policy: .ask, label: "secret label", detail: "secret detail")
    private let principal = BotExecutionPrincipal(botId: "main", sessionId: "s1")

    func testUnattributedEmptyAndMalformedCallsFailClosed() async throws {
        let store = BotGrantStore(now: { 1_000 })
        let authorizer = BotExecutionAuthorizer(grants: store)
        await assertFalse(await authorizer.authorizeExecution(principal: nil, effects: [effect]).allowed)
        await assertFalse(await authorizer.authorizeExecution(
            principal: BotExecutionPrincipal(botId: nil), effects: [effect]).allowed)
        await assertFalse(await authorizer.authorizeExecution(
            principal: BotExecutionPrincipal(botId: "main", certain: false), effects: [effect]).allowed)
        await assertFalse(await authorizer.authorizeExecution(principal: principal, effects: []).allowed)
        let malformed = BotToolEffect(tool: "", operation: "x", resource: "secret",
                                      mutability: .write, policy: .ask)
        await assertFalse(await authorizer.authorizeExecution(principal: principal, effects: [malformed]).allowed)
        await assertFalse(await authorizer.authorizeExecution(principal: principal, effects: [effect],
                                                           argsDigest: "not-a-digest").allowed)
    }

    func testOnceGrantIsConsumedAndCannotBeReused() async throws {
        let clock = BotTestClock(10_000)
        let store = BotGrantStore(now: { clock.now() })
        let authorizer = BotExecutionAuthorizer(grants: store)
        await assertFalse(await authorizer.authorizeExecution(principal: principal, effects: [effect]).allowed)
        let grant = try await store.add(BotGrant(botId: "main", tool: effect.tool,
                                                operation: effect.operation, resource: effect.resource,
                                                scope: .once, decision: .allow))
        XCTAssertEqual(grant.expiresAt, 130_000)
        await assertTrue(await authorizer.authorizeExecution(principal: principal, effects: [effect]).allowed)
        await assertEqual(await store.list().count, 0)
        await assertFalse(await authorizer.authorizeExecution(principal: principal, effects: [effect]).allowed)
    }

    func testConcurrentOnceAuthorizationHasOneWinner() async throws {
        let store = BotGrantStore(now: { 1_000 })
        _ = try await store.add(BotGrant(botId: "main", tool: effect.tool,
                                        operation: effect.operation, resource: effect.resource,
                                        scope: .once, decision: .allow))
        let authorizer = BotExecutionAuthorizer(grants: store)
        async let first = authorizer.authorizeExecution(principal: principal, effects: [effect])
        async let second = authorizer.authorizeExecution(principal: principal, effects: [effect])
        let results = await [first, second]
        XCTAssertEqual(results.filter(\.allowed).count, 1)
        XCTAssertEqual(results.filter { !$0.allowed }.count, 1)
        await assertEqual(await store.list().count, 0)
    }

    func testGrantExpiryRevocationAndSessionIsolation() async throws {
        let clock = BotTestClock(1_000)
        let store = BotGrantStore(now: { clock.now() })
        let authorizer = BotExecutionAuthorizer(grants: store)
        let expiring = try await store.add(BotGrant(botId: "main", tool: effect.tool,
                                                   operation: effect.operation, resource: effect.resource,
                                                   scope: .once, decision: .allow))
        clock.advance(120_000)
        await assertFalse(await authorizer.authorizeExecution(principal: principal, effects: [effect]).allowed)
        await assertEqual(await store.list().count, 0)

        let revoked = try await store.add(BotGrant(id: expiring.id, botId: "main", tool: effect.tool,
                                                  operation: effect.operation, resource: effect.resource,
                                                  scope: .until, decision: .allow))
        try await assertTrue(try await store.revoke(id: revoked.id))
        await assertFalse(await authorizer.authorizeExecution(principal: principal, effects: [effect]).allowed)

        _ = try await store.add(BotGrant(botId: "main", tool: effect.tool,
                                        operation: effect.operation, resource: effect.resource,
                                        scope: .session, sessionId: "s1", decision: .allow))
        await assertTrue(await authorizer.authorizeExecution(principal: principal, effects: [effect]).allowed)
        let otherSession = BotExecutionPrincipal(botId: "main", sessionId: "s2")
        await assertFalse(await authorizer.authorizeExecution(principal: otherSession, effects: [effect]).allowed)
        try await assertEqual(try await store.revokeSession("s1", botId: "main"), 1)
        await assertFalse(await authorizer.authorizeExecution(principal: principal, effects: [effect]).allowed)
    }

    func testDenyWinsOverAutoAndAllowAndBotsAreIsolated() async throws {
        let store = BotGrantStore(now: { 1_000 })
        let auto = BotToolEffect(tool: effect.tool, operation: effect.operation,
                                 resource: effect.resource, mutability: .write, policy: .auto)
        _ = try await store.add(BotGrant(botId: "main", tool: auto.tool, operation: auto.operation,
                                        resource: auto.resource, scope: .until, decision: .allow))
        _ = try await store.add(BotGrant(botId: "main", tool: auto.tool, operation: auto.operation,
                                        resource: auto.resource, scope: .until, decision: .deny))
        let denied = await BotExecutionAuthorizer(grants: store)
            .authorizeExecution(principal: principal, effects: [auto])
        XCTAssertFalse(denied.allowed)
        XCTAssertTrue(denied.denied)
        XCTAssertEqual(denied.reason, "standing-deny")

        let isolated = BotGrantStore(now: { 1_000 })
        _ = try await isolated.add(BotGrant(botId: "other", tool: effect.tool,
                                           operation: effect.operation, resource: effect.resource,
                                           scope: .until, decision: .allow))
        await assertFalse(await BotExecutionAuthorizer(grants: isolated)
            .authorizeExecution(principal: principal, effects: [effect]).allowed)
    }

    func testFailedMultiEffectDecisionDoesNotConsumeOnce() async throws {
        let store = BotGrantStore(now: { 1_000 })
        let second = BotToolEffect(tool: "local", operation: "write", resource: "path=/tmp/report",
                                   mutability: .write, policy: .ask)
        _ = try await store.add(BotGrant(id: "once-1", botId: "main", tool: effect.tool,
                                        operation: effect.operation, resource: effect.resource,
                                        scope: .once, decision: .allow))
        let authorizer = BotExecutionAuthorizer(grants: store)
        await assertFalse(await authorizer.authorizeExecution(principal: principal,
                                                           effects: [effect, second]).allowed)
        await assertEqual(await store.list().map(\.id), ["once-1"])
        _ = try await store.add(BotGrant(id: "once-2", botId: "main", tool: second.tool,
                                        operation: second.operation, resource: second.resource,
                                        scope: .once, decision: .allow))
        await assertTrue(await authorizer.authorizeExecution(principal: principal,
                                                          effects: [effect, second]).allowed)
        await assertEqual(await store.list().count, 0)
    }

    func testAuditUsesDurableEffectEventWithoutSecrets() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("phonedsh-wp4-audit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let eventStore = try SQLiteDomainStore(fileURL: root.appendingPathComponent("domain.sqlite"),
                                               now: { 1_000 })
        let store = BotGrantStore(now: { 1_000 }, audit: BotAuditLog(eventLog: eventStore))
        let secret = "super-secret-value-that-must-not-leak"
        let auto = BotToolEffect(tool: "memory", operation: "memory.write",
                                 resource: "memory:agent&fact=\(secret)", mutability: .write,
                                 policy: .auto, label: secret, detail: secret)
        let digest = try BotArgumentsDigest.string(for: .object(["fact": .string(secret)]))
        let result = await BotExecutionAuthorizer(grants: store).authorizeExecution(
            principal: principal, effects: [auto], source: "memory", argsDigest: digest)
        XCTAssertTrue(result.allowed)
        let events = try await eventStore.events(after: 0, limit: 10)
        XCTAssertEqual(events.map(\.type), [BotGrantSnapshot.eventType, "effect.attempted"])
        let event = try XCTUnwrap(events.last)
        XCTAssertEqual(event.commitSeq, 2)
        XCTAssertEqual(event.origin, .local(source: "effect-runner"))
        XCTAssertEqual(event.principal.kind, "chat")
        XCTAssertEqual(event.principal.sessionId, "s1")
        XCTAssertFalse(event.eventId.isEmpty)
        XCTAssertFalse(event.traceId.isEmpty)
        let record = try JSONDecoder().decode(BotAuditRecord.self, from: event.data.encoded())
        XCTAssertEqual(record.event, "tool-execution")
        XCTAssertEqual(record.effects.count, 1)
        XCTAssertEqual(record.effects[0].argsDigest, digest)
        XCTAssertEqual(record.effects[0].resourceDigest,
                       BotArgumentsDigest.digest(ofUTF8: auto.resource))
        let encoded = String(data: try JSONEncoder().encode(event), encoding: .utf8)!
        XCTAssertFalse(encoded.contains(secret))
        XCTAssertFalse(encoded.contains("memory:agent&fact="))
        XCTAssertTrue(encoded.contains(digest))
        try await eventStore.close()
    }

    func testSQLiteAuditPermissionsGrantEventsAndNoJSONL() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("phonedsh-wp4-audit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("domain.sqlite")
        let eventStore = try SQLiteDomainStore(fileURL: file, now: { 1_000 })
        let grants = BotGrantStore(now: { 1_000 }, audit: BotAuditLog(eventLog: eventStore))
        _ = try await grants.add(BotGrant(id: "grant-once", botId: "main", tool: effect.tool,
                                         operation: effect.operation, resource: effect.resource,
                                         scope: .once, decision: .allow))
        try await assertTrue(try await grants.consume(id: "grant-once"))
        _ = try await grants.add(BotGrant(id: "grant-until", botId: "main", tool: effect.tool,
                                         operation: effect.operation, resource: effect.resource,
                                         scope: .until, decision: .allow))
        try await assertTrue(try await grants.revoke(id: "grant-until"))
        try await eventStore.close()

        let reopened = try SQLiteDomainStore(fileURL: file, now: { 2_000 })
        let events = try await reopened.events(after: 0, limit: 10)
        let auditEvents = events.filter { $0.type.hasPrefix("grant.") }
        XCTAssertEqual(auditEvents.map(\.type),
                       ["grant.added", "grant.consumed", "grant.added", "grant.revoked"])
        XCTAssertEqual(events.filter { $0.type == BotGrantSnapshot.eventType }.count, 5)
        XCTAssertEqual(events.map(\.commitSeq), (1...9).map(Optional.some))
        XCTAssertEqual(Set(events.map(\.eventId)).count, 9)
        XCTAssertEqual(Set(events.map(\.traceId)).count, 9)
        for event in events {
            XCTAssertEqual(event.origin, .local(source: "ipc"))
            XCTAssertEqual(event.principal.kind, "ipc")
        }
        for event in auditEvents {
            let record = try JSONDecoder().decode(BotAuditRecord.self, from: event.data.encoded())
            XCTAssertEqual(record.event, event.type)
            XCTAssertEqual(record.grants.count, 1)
            let encoded = String(data: try JSONEncoder().encode(event), encoding: .utf8)!
            XCTAssertFalse(encoded.contains(effect.resource))
            XCTAssertFalse(encoded.contains(effect.label))
            XCTAssertFalse(encoded.contains(effect.detail))
        }

        let manager = FileManager.default
        let directoryMode = try manager.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber
        let databaseMode = try manager.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(directoryMode.map { $0.intValue & 0o777 }, 0o700)
        XCTAssertEqual(databaseMode.map { $0.intValue & 0o777 }, 0o600)
        let walURL = URL(fileURLWithPath: file.path + "-wal")
        if manager.fileExists(atPath: walURL.path) {
            let mode = try manager.attributesOfItem(atPath: walURL.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(mode.map { $0.intValue & 0o777 }, 0o600)
        }
        let paths = try manager.subpathsOfDirectory(atPath: root.path)
        XCTAssertFalse(paths.contains { $0.hasSuffix(".jsonl") })
        XCTAssertFalse(paths.contains("authz"))
        try await reopened.close()
    }

    func testAuditAppendFailureReturnsFalse() async throws {
        let log = BotAuditLog(eventLog: UnimplementedBotEventLog())
        let record = BotAuditRecord(at: 1_000, source: "test", decision: .allow,
                                    principal: BotAuditPrincipal(botId: "main", kind: "ipc", certain: true),
                                    reason: "test")
        await assertFalse(await log.append(record))
    }
}
