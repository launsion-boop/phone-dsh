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
