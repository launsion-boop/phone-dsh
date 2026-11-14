// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

private func recoveryAssertTrue(_ expression: @autoclosure () async throws -> Bool) async rethrows {
    let value = try await expression()
    XCTAssertTrue(value)
}

private func recoveryAssertFalse(_ expression: @autoclosure () async throws -> Bool) async rethrows {
    let value = try await expression()
    XCTAssertFalse(value)
}

private func recoveryAssertEqual<T: Equatable>(_ lhs: @autoclosure () async throws -> T,
                                               _ rhs: @autoclosure () async throws -> T) async rethrows {
    let left = try await lhs()
    let right = try await rhs()
    XCTAssertEqual(left, right)
}

private func recoveryAssertNotNil<T>(_ expression: @autoclosure () async throws -> T?) async rethrows {
    let value = try await expression()
    XCTAssertNotNil(value)
}

final class BotGrantRecoveryTests: XCTestCase {
    private let principal = BotExecutionPrincipal(botId: "main", sessionId: "s1")
    private let effect = BotToolEffect(tool: "memory", operation: "memory.forget",
                                       resource: "memory:user&fact=shared", mutability: .destructive,
                                       policy: .ask, label: "private label", detail: "private detail")

    func testImageGrantIsStoredAndMatchedByItsStableModelResource() async throws {
        let store = BotGrantStore(now: { 10_000 })
        _ = try await store.add(BotGrant(
            botId: "main", tool: "attach_to_model", operation: "model.image.attach",
            resource: "model:image", scope: .session, sessionId: "s1", decision: .allow))
        let nextImage = BotToolEffect(
            tool: "attach_to_model", operation: "model.image.attach",
            resource: "attachment=/dsh/workspace/another-photo.jpg",
            mutability: .externalSend, policy: .ask, grantResource: "model:image")
        let found = await store.find(botId: "main", sessionId: "s1", effect: nextImage)
        XCTAssertEqual(found?.resource, "model:image")
        // Bash has no stable grant scope; it stays exact-resource.
        let bash = BotToolEffect(
            tool: "bash", operation: "rm-destructive",
            resource: "/dsh/workspace/another-photo.jpg",
            mutability: .destructive, policy: .ask)
        let bashFound = await store.find(botId: "main", sessionId: "s1", effect: bash)
        XCTAssertNil(bashFound)
    }

    func testEveryOperationGetsAStableStandingGrant() async throws {
        let store = BotGrantStore(now: { 10_000 })
        _ = try await store.add(BotGrant(
            botId: "main", tool: "bash", operation: "rm-destructive",
            resource: "operation:rm-destructive", scope: .session,
            sessionId: "s1", decision: .allow))
        let next = BotToolEffect(
            tool: "bash", operation: "rm-destructive",
            resource: "/dsh/workspace/another-file",
            mutability: .destructive, policy: .ask)
        XCTAssertEqual(next.stableGrantResource, "operation:rm-destructive")
        let found = await store.find(botId: "main", sessionId: "s1", effect: next)
        XCTAssertEqual(found?.resource, "operation:rm-destructive")
        let otherOperation = BotToolEffect(
            tool: "bash", operation: "git-destructive",
            resource: "/dsh/workspace/another-file",
            mutability: .destructive, policy: .ask)
        let otherFound = await store.find(botId: "main", sessionId: "s1",
                                           effect: otherOperation)
        XCTAssertNil(otherFound)
    }

    func testLegacyWildcardStandingGrantStillMatches() async throws {
        let store = BotGrantStore(now: { 10_000 })
        _ = try await store.add(BotGrant(
            botId: "main", tool: "bash", operation: "rm-destructive",
            resource: "*", scope: .until, decision: .allow))
        let next = BotToolEffect(
            tool: "bash", operation: "rm-destructive",
            resource: "/dsh/workspace/any-other-file",
            mutability: .destructive, policy: .ask)
        let found = await store.find(botId: "main", sessionId: "s1", effect: next)
        XCTAssertEqual(found?.resource, "*")
    }

    func testSpecificDenyStillBeatsTheStableStandingGrant() async throws {
        let store = BotGrantStore(now: { 10_000 })
        _ = try await store.add(BotGrant(
            botId: "main", tool: "bash", operation: "rm-destructive",
            resource: "operation:rm-destructive", scope: .session,
            sessionId: "s1", decision: .allow))
        _ = try await store.add(BotGrant(
            botId: "main", tool: "bash", operation: "rm-destructive",
            resource: "/dsh/workspace/protected", scope: .until,
            decision: .deny))
        let protected = BotToolEffect(
            tool: "bash", operation: "rm-destructive",
            resource: "/dsh/workspace/protected",
            mutability: .destructive, policy: .ask)
        let protectedFound = await store.find(botId: "main", sessionId: "s1",
                                               effect: protected)
        XCTAssertEqual(protectedFound?.decision, .deny)
        let other = BotToolEffect(
            tool: "bash", operation: "rm-destructive",
            resource: "/dsh/workspace/other",
            mutability: .destructive, policy: .ask)
        let otherFound = await store.find(botId: "main", sessionId: "s1", effect: other)
        XCTAssertEqual(otherFound?.decision, .allow)
    }

    func testColdRestartRestoresStandingDenyAndAuditRemainsDigestOnly() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("domain.sqlite")
        let domain = try SQLiteDomainStore(fileURL: file, now: { 1_000 })
        let store = BotGrantStore(now: { 1_000 }, audit: BotAuditLog(eventLog: domain))
        let secretResource = "memory:user&fact=private-standing-deny"
        let auto = BotToolEffect(tool: "memory", operation: "memory.forget",
                                 resource: secretResource, mutability: .write, policy: .auto)
        let deny = try await store.add(BotGrant(id: "standing-deny", botId: "main", tool: auto.tool,
                                                operation: auto.operation, resource: auto.resource,
                                                scope: .until, decision: .deny))
        try await domain.close()

        let reopened = try SQLiteDomainStore(fileURL: file, now: { 2_000 })
        let eventsBeforeExecution = try await reopened.events(after: 0, limit: 20)
        let snapshots = eventsBeforeExecution.filter { $0.type == BotGrantSnapshot.eventType }
        XCTAssertEqual(snapshots.count, 2)
        let restored = try BotGrantSnapshot.decode(try XCTUnwrap(snapshots.last), now: 2_000)
        XCTAssertEqual(restored, [deny])
        let auditEvents = eventsBeforeExecution.filter { $0.type == "grant.added" }
        XCTAssertEqual(auditEvents.count, 1)
        let auditJSON = String(data: try JSONEncoder().encode(auditEvents[0]), encoding: .utf8)!
        XCTAssertFalse(auditJSON.contains(secretResource))
        XCTAssertTrue(auditJSON.contains(BotArgumentsDigest.digest(ofUTF8: secretResource)))

        let recoveredStore = BotGrantStore(now: { 2_000 }, audit: BotAuditLog(eventLog: reopened))
        let decision = await BotExecutionAuthorizer(grants: recoveredStore).authorizeExecution(
            principal: principal, effects: [auto])
        XCTAssertFalse(decision.allowed)
        XCTAssertTrue(decision.denied)
        XCTAssertEqual(decision.reason, "standing-deny")
        XCTAssertEqual(decision.grants.map(\.id), ["standing-deny"])
        try await reopened.close()
    }

    func testColdRestartPreservesSessionUntilScopeAndTTL() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("domain.sqlite")
        let clock = BotTestClock(10_000)
        let untilEffect = BotToolEffect(tool: "local", operation: "write", resource: "path=/tmp/until",
                                        mutability: .write, policy: .ask)
        let domain = try SQLiteDomainStore(fileURL: file, now: { clock.now() })
        let store = BotGrantStore(domainStore: domain, now: { clock.now() })
        let session = try await store.add(BotGrant(id: "session-allow", botId: "main", tool: effect.tool,
                                                   operation: effect.operation, resource: effect.resource,
                                                   scope: .session, sessionId: "s1", decision: .allow))
        let until = try await store.add(BotGrant(id: "until-allow", botId: "main", tool: untilEffect.tool,
                                                 operation: untilEffect.operation, resource: untilEffect.resource,
                                                 scope: .until, decision: .allow))
        XCTAssertEqual(session.expiresAt, 10_000 + BotGrantStore.sessionTTLMilliseconds)
        XCTAssertEqual(until.expiresAt, 10_000 + BotGrantStore.untilTTLMilliseconds)
        try await domain.close()

        clock.advance(10_000)
        let reopened = try SQLiteDomainStore(fileURL: file, now: { clock.now() })
        let recovered = BotGrantStore(domainStore: reopened, now: { clock.now() })
        try await recovered.recover()
        let authorizer = BotExecutionAuthorizer(grants: recovered)
        await recoveryAssertTrue(await authorizer.authorizeExecution(principal: principal, effects: [effect]).allowed)
        await recoveryAssertTrue(await authorizer.authorizeExecution(principal: principal, effects: [untilEffect]).allowed)
        let otherSession = BotExecutionPrincipal(botId: "main", sessionId: "s2")
        await recoveryAssertFalse(await authorizer.authorizeExecution(principal: otherSession, effects: [effect]).allowed)
        try await reopened.close()

        clock.advance(BotGrantStore.sessionTTLMilliseconds)
        let afterSessionExpiry = try SQLiteDomainStore(fileURL: file, now: { clock.now() })
        let expiredSessionStore = BotGrantStore(domainStore: afterSessionExpiry, now: { clock.now() })
        try await expiredSessionStore.recover()
        await assertRecoveredIDs(expiredSessionStore, ["until-allow"])
        await recoveryAssertFalse(await BotExecutionAuthorizer(grants: expiredSessionStore)
            .authorizeExecution(principal: principal, effects: [effect]).allowed)
        try await afterSessionExpiry.close()

        clock.advance(BotGrantStore.untilTTLMilliseconds)
        let afterUntilExpiry = try SQLiteDomainStore(fileURL: file, now: { clock.now() })
        let expiredUntilStore = BotGrantStore(domainStore: afterUntilExpiry, now: { clock.now() })
        try await expiredUntilStore.recover()
        await assertRecoveredIDs(expiredUntilStore, [])
        await recoveryAssertFalse(await BotExecutionAuthorizer(grants: expiredUntilStore)
            .authorizeExecution(principal: principal, effects: [untilEffect]).allowed)
        try await afterUntilExpiry.close()
    }

    func testOnceAndRevokeDoNotRollBackAcrossColdRestart() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("domain.sqlite")
        let revokedEffect = BotToolEffect(tool: "local", operation: "write", resource: "path=/tmp/revoked",
                                          mutability: .write, policy: .ask)
        let domain = try SQLiteDomainStore(fileURL: file, now: { 1_000 })
        let store = BotGrantStore(domainStore: domain, now: { 1_000 })
        _ = try await store.add(BotGrant(id: "once", botId: "main", tool: effect.tool,
                                         operation: effect.operation, resource: effect.resource,
                                         scope: .once, decision: .allow))
        _ = try await store.add(BotGrant(id: "revoked", botId: "main", tool: revokedEffect.tool,
                                         operation: revokedEffect.operation, resource: revokedEffect.resource,
                                         scope: .until, decision: .allow))
        try await recoveryAssertTrue(try await store.consume(id: "once"))
        try await recoveryAssertTrue(try await store.revoke(id: "revoked"))
        try await domain.close()

        let reopened = try SQLiteDomainStore(fileURL: file, now: { 2_000 })
        let recovered = BotGrantStore(domainStore: reopened, now: { 2_000 })
        try await recovered.recover()
        await assertRecoveredIDs(recovered, [])
        let authorizer = BotExecutionAuthorizer(grants: recovered)
        await recoveryAssertFalse(await authorizer.authorizeExecution(principal: principal, effects: [effect]).allowed)
        await recoveryAssertFalse(await authorizer.authorizeExecution(principal: principal,
                                                           effects: [revokedEffect]).allowed)
        try await reopened.close()
    }

    func testExtendIsDurableAndKeepsOriginalGrantIdentity() async throws {
        let log = BotGrantTestEventLog()
        let store = BotGrantStore(eventLog: log, now: { 1_000 })
        let first = try await store.add(BotGrant(id: "standing", botId: "main", tool: effect.tool,
                                                 operation: effect.operation, resource: effect.resource,
                                                 scope: .until, expiresAt: 50_000, createdAt: 1_000,
                                                 decision: .allow))
        let extended = try await store.add(BotGrant(botId: "main", tool: effect.tool,
                                                    operation: effect.operation, resource: effect.resource,
                                                    scope: .until, expiresAt: 80_000, createdAt: 2_000,
                                                    decision: .allow))
        XCTAssertEqual(extended.id, first.id)
        XCTAssertEqual(extended.createdAt, first.createdAt)
        XCTAssertEqual(extended.expiresAt, 80_000)

        let reopened = BotGrantStore(eventLog: log, now: { 3_000 })
        try await reopened.recover()
        let restored = await reopened.list()
        XCTAssertEqual(restored, [extended])
    }

    func testMissingCorruptAndUnsupportedSnapshotsFailClosed() async throws {
        let auto = BotToolEffect(tool: effect.tool, operation: effect.operation,
                                 resource: effect.resource, mutability: .write, policy: .auto)

        let missingLog = BotGrantTestEventLog()
        await missingLog.seed(botGrantTestEvent())
        let missing = BotGrantStore(eventLog: missingLog, now: { 2_000 })
        do {
            try await missing.recover()
            XCTFail("a non-empty event stream without a snapshot must fail")
        } catch {
            XCTAssertEqual(error as? BotGrantRecoveryError, .missingSnapshot)
        }
        let missingDecision = await BotExecutionAuthorizer(grants: missing)
            .authorizeExecution(principal: principal, effects: [auto])
        XCTAssertFalse(missingDecision.allowed)
        XCTAssertEqual(missingDecision.reason, "grant-recovery-failed")

        let corruptLog = BotGrantTestEventLog()
        await corruptLog.seed(try BotGrantSnapshot.event(grants: [], at: 1_000))
        await corruptLog.seed(botGrantTestEvent(type: BotGrantSnapshot.eventType,
                                                data: .object(["grants": .string("not-an-array")])) )
        let corrupt = BotGrantStore(eventLog: corruptLog, now: { 2_000 })
        do {
            try await corrupt.recover()
            XCTFail("the latest corrupt snapshot must not fall back to an older valid snapshot")
        } catch {
            guard case .invalidSnapshot = error as? BotGrantRecoveryError else {
                return XCTFail("unexpected recovery error: \(error)")
            }
        }
        let corruptDecision = await BotExecutionAuthorizer(grants: corrupt)
            .authorizeExecution(principal: principal, effects: [auto])
        XCTAssertFalse(corruptDecision.allowed)
        XCTAssertEqual(corruptDecision.reason, "grant-recovery-failed")

        let unsupportedLog = BotGrantTestEventLog()
        await unsupportedLog.seed(botGrantTestEvent(schemaVersion: 2,
                                                    type: BotGrantSnapshot.eventType,
                                                    data: .object(["grants": .array([])])))
        let unsupported = BotGrantStore(eventLog: unsupportedLog, now: { 2_000 })
        do {
            try await unsupported.recover()
            XCTFail("a future snapshot envelope must fail closed")
        } catch {
            XCTAssertEqual(error as? BotGrantRecoveryError, .unsupportedSnapshot(2))
        }
    }

    func testPersistenceFailuresDoNotPublishGrantChanges() async throws {
        let log = BotGrantTestEventLog()
        let store = BotGrantStore(eventLog: log, now: { 1_000 })
        try await store.recover()

        await log.failNextAppend()
        do {
            _ = try await store.add(BotGrant(id: "standing", botId: "main", tool: effect.tool,
                                             operation: effect.operation, resource: effect.resource,
                                             scope: .until, expiresAt: 50_000, decision: .allow))
            XCTFail("failed add must be reported")
        } catch {
            XCTAssertEqual(error as? BotGrantTestError, .injectedPersistenceFailure)
        }
        await assertRecoveredIDs(store, [])

        _ = try await store.add(BotGrant(id: "standing", botId: "main", tool: effect.tool,
                                         operation: effect.operation, resource: effect.resource,
                                         scope: .until, expiresAt: 50_000, decision: .allow))
        await log.failNextAppend()
        do {
            _ = try await store.add(BotGrant(botId: "main", tool: effect.tool,
                                             operation: effect.operation, resource: effect.resource,
                                             scope: .until, expiresAt: 80_000, decision: .allow))
            XCTFail("failed extend must be reported")
        } catch {
            XCTAssertEqual(error as? BotGrantTestError, .injectedPersistenceFailure)
        }
        await recoveryAssertEqual(await store.list().first?.expiresAt, 50_000)

        _ = try await store.add(BotGrant(id: "once", botId: "main", tool: "local",
                                         operation: "write", resource: "path=/tmp/once",
                                         scope: .once, decision: .allow))
        let onceEffect = BotToolEffect(tool: "local", operation: "write", resource: "path=/tmp/once",
                                       mutability: .write, policy: .ask)
        await log.failNextAppend()
        do {
            _ = try await store.consume(id: "once")
            XCTFail("failed consume must be reported")
        } catch {
            XCTAssertEqual(error as? BotGrantTestError, .injectedPersistenceFailure)
        }
        await recoveryAssertNotNil(await store.find(botId: "main", sessionId: "s1", effect: onceEffect))

        await log.failNextAppend()
        do {
            _ = try await store.revoke(id: "standing")
            XCTFail("failed revoke must be reported")
        } catch {
            XCTAssertEqual(error as? BotGrantTestError, .injectedPersistenceFailure)
        }
        let ids = await store.list().map(\.id)
        XCTAssertEqual(Set(ids), Set(["standing", "once"]))
    }

    func testConcurrentPersistentConsumeHasOneWinner() async throws {
        let log = BotGrantTestEventLog(snapshotDelayNanoseconds: 50_000_000)
        let store = BotGrantStore(eventLog: log, now: { 1_000 })
        _ = try await store.add(BotGrant(id: "once", botId: "main", tool: effect.tool,
                                         operation: effect.operation, resource: effect.resource,
                                         scope: .once, decision: .allow))
        let authorizer = BotExecutionAuthorizer(grants: store)
        async let first = authorizer.authorizeExecution(principal: principal, effects: [effect])
        async let second = authorizer.authorizeExecution(principal: principal, effects: [effect])
        let results = await [first, second]
        XCTAssertEqual(results.filter(\.allowed).count, 1)
        await assertRecoveredIDs(store, [])
        let events = await log.allEvents()
        let lastSnapshot = try XCTUnwrap(events.last { $0.type == BotGrantSnapshot.eventType })
        XCTAssertEqual(try BotGrantSnapshot.decode(lastSnapshot, now: 1_000), [])
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("phonedsh-authz-recovery-\(UUID().uuidString)", isDirectory: true)
    }

    private func assertRecoveredIDs(_ store: BotGrantStore, _ expected: [String],
                                    file: StaticString = #filePath, line: UInt = #line) async {
        let ids = await store.list().map(\.id).sorted()
        XCTAssertEqual(ids, expected.sorted(), file: file, line: line)
    }
}
