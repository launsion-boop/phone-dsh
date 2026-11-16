// SPDX-License-Identifier: MIT
// phone-dsh Bot eval runner — prove the eval target compiles the production
// App sources rather than a copied "simplified Bot".

import Foundation
import XCTest
@testable import BotEvalApp
import PhoneDSHBot

final class BotEvalCompositionTests: XCTestCase {
    func testBotEvalAppSourcesAreSymlinksToProduction() throws {
        let harness = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sources = harness.appendingPathComponent("Sources/BotEvalApp", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(
            at: sources, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThanOrEqual(files.count, 10,
            "the eval target must link the production Bot sources")
        for file in files {
            if file.lastPathComponent == "BotWorkspaceModelImage+macOS.swift" {
                // The only non-symlink source: a documented macOS-only shim
                // for the iOS UIKit/Photos image bridge. It must stay guarded
                // and fail closed; no other copied source is allowed.
                let text = try String(contentsOf: file, encoding: .utf8)
                XCTAssertTrue(text.contains("#if !canImport(UIKit)"),
                              "the macOS shim must be compiled only without UIKit")
                XCTAssertTrue(text.contains("BotWorkspaceModelImage"),
                              "the shim must provide the production call shape")
                continue
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeSymbolicLink,
                           "\(file.lastPathComponent) must be a symlink, not a copied source")
            let resolved = file.resolvingSymlinksInPath().path
            XCTAssertTrue(
                resolved.contains("/examples/probe-app/")
                    || resolved.hasSuffix("/scripts/ci/bot-e2e/app/Sources/BotTurnProcessShim.swift"),
                "\(file.lastPathComponent) resolves outside the production App sources: \(resolved)")
        }
        XCTAssertTrue(BotRuntimeComposition.workerTokenPlaceholder.hasPrefix("phone-host-injects"),
                      "the production composition must be the linked one")
    }

    /// The information page re-reads the host authority when it appears. A
    /// routine created after an earlier snapshot must be visible on the next
    /// load even though the service instance is the same; the page side uses
    /// this same production service/driver.
    func testInfoServiceSeesARoutineCreatedAfterAnEarlierLoad() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bot-info-refresh-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try SQLiteDomainStore(fileURL: root.appendingPathComponent("domain.sqlite"))
        let machine = RoutineMachine(store: SQLiteRoutineStore(domainStore: store))
        let environment = BotProductionEnvironment(
            domain: store, botID: "main", sessionID: "main",
            routineMachine: machine,
            memory: BotMemory(
                store: SQLiteBotMemoryDocumentStore(eventLog: store, botID: "main"),
                botID: "main"),
            grants: BotGrantStore(domainStore: store))
        let service = BotProductionInfoService(environment: environment)
        let before = try await service.load()
        XCTAssertTrue(before.routines.isEmpty, "fixture precondition: no routine yet")
        _ = try await machine.create(
            botId: "main", title: "刷新后的 Routine", prompt: "work",
            schedule: .interval(everyMinutes: 5, timezone: "UTC"),
            now: 5_000, id: "routine-refresh")
        let after = try await service.load()
        XCTAssertEqual(after.routines.map(\.id), ["routine-refresh"])
        XCTAssertTrue(after.routines[0].enabled)
        try await store.close()
    }

    /// Regression: the composition's gateway and BotMCPRuntime must use the
    /// same injected clock. The eval baseline can be hours ahead of the wall
    /// clock; a wall-clock gateway then stores an identity whose expiry is
    /// already past for the runtime, so the next real tool call is rejected as
    /// unattributed. With the shared clock the registration stays valid.
    @MainActor
    func testCompositionSharesInjectedClockWithIdentityGateway() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bot-clock-regression-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let wall = Int64(Date().timeIntervalSince1970 * 1_000)
        let deterministicNoon = wall + 8 * 60 * 60 * 1_000
        let store = try SQLiteDomainStore(
            fileURL: root.appendingPathComponent("domain.sqlite"),
            now: { deterministicNoon })
        let profileStore = BotProfileStore(directory: root.appendingPathComponent("profiles"))
        let launch = try await BotRuntimeComposition.prepare(
            store: store, profileStore: profileStore, now: { deterministicNoon })
        let runtime = launch.composition.runtime
        let session = "clock-regression"
        let issued = try await runtime.issueSessionToken(
            botId: "main", sessionId: session, kind: .chat)
        _ = try await runtime.registerIdentity(
            runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: session,
            callId: "clock-regression", name: "bash",
            arguments: .object(["command": .string("printf clock")]), sessionToken: issued.token)
        let identity = await runtime.identityForApproval(
            runtimeId: BotMCPRuntime.defaultRuntimeID, callId: "clock-regression")
        XCTAssertNotNil(identity,
                        "gateway/runtime clocks diverged: an identity registered on the eval clock was pruned as expired")
        XCTAssertEqual(identity?.callId, "clock-regression")
        try await store.close()
    }

    /// The scheduler clock is an eval input, not the wall clock. Starting a
    /// scenario in the production quiet window (23:00–08:00) defers a
    /// non-urgent routine to 08:00 and makes `advance_clock` wait forever on a
    /// nightly run. The deterministic baseline is local noon.
    func testSchedulerClockStartsOutsideProductionQuietHours() {
        let clock = EvalSchedulerClock()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let hour = calendar.component(.hour, from: Date(timeIntervalSince1970: Double(clock.now) / 1_000))
        XCTAssertEqual(hour, 12, "the eval scheduler clock must start at local noon")
        XCTAssertFalse(RoutineQuietHours.contains(clock.now, settings: ProactiveSettingsStore.productionDefault),
                       "the eval baseline must not start inside the quiet window")
    }
}
