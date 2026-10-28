// SPDX-License-Identifier: MIT
// PhoneDSHConfiguration and PhoneDSHDiagnostics additions for W2-FACADE.

import Foundation
import XCTest
import PhoneDSHController
import PhoneDSH
import PhoneDSHGateway
import PhoneDSHLoopback
import PhoneDSHAgentCore

final class PhoneDSHConfigurationTests: XCTestCase {
    private func origin() throws -> URL {
        try XCTUnwrap(URL(string: "http://127.0.0.1:8080"))
    }

    func testFacadeFieldsAreConfigured() throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let mcp = URL(string: "http://127.0.0.1:9999")!
        let configuration = PhoneDSHConfiguration(
            workspaceRoot: fixture.workspace,
            token: "test-token",
            origin: try origin(),
            deviceTier: .sixGB,
            bundle: fixture.bundle,
            allowedModelHosts: ["deepseek.com"],
            egressAllowHosts: ["api.business.test"],
            replaySafeModelEndpoints: ["https://deepseek.com/v1/chat/completions"],
            mcpLoopbackURL: mcp,
            budgets: .sixGB,
            plannedRestartInterval: 120,
            drainDeadline: 7,
            helloTimeout: 12)

        XCTAssertEqual(configuration.bundle, fixture.bundle)
        XCTAssertEqual(configuration.allowedModelHosts, ["deepseek.com"])
        XCTAssertEqual(configuration.gateway.allowedUpstreamHosts,
                       ["deepseek.com", "api.business.test"])
        let resolvedGateway = configuration.resolvedGatewayConfiguration()
        XCTAssertEqual(resolvedGateway.allowedUpstreamHosts,
                       ["deepseek.com", "api.business.test"])
        XCTAssertEqual(resolvedGateway.replaySafeModelEndpoints,
                       ["https://deepseek.com/v1/chat/completions"])
        XCTAssertEqual(configuration.mcpLoopbackURL, mcp)
        XCTAssertEqual(configuration.budgets, .sixGB)
        XCTAssertEqual(configuration.plannedRestartInterval, 120)
        XCTAssertEqual(configuration.drainDeadline, 7)
        XCTAssertEqual(configuration.helloTimeout, 12)
        XCTAssertEqual(configuration.engine.origin, try origin())
        XCTAssertEqual(configuration.loopback.token, "test-token")
        XCTAssertEqual(configuration.log.root, fixture.workspace)
    }

    func testDefaultFlagsFollowTheBudgetTable() throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let configuration = PhoneDSHConfiguration(
            workspaceRoot: fixture.workspace,
            token: "test-token",
            origin: try origin(),
            deviceTier: .eightGB,
            bundle: fixture.bundle)
        XCTAssertEqual(configuration.budgets, BudgetTable.eightGB)
        XCTAssertEqual(configuration.plannedRestartInterval,
                       TimeInterval(BudgetTable.eightGB.plannedRestartIntervalSeconds))
        XCTAssertEqual(configuration.drainDeadline, HostStateMachine.drainDeadlineSeconds)
        XCTAssertEqual(configuration.acceleratorNames, [])
        XCTAssertNil(configuration.execProvider)
        XCTAssertTrue(configuration.bundle?.exists() == true)
    }

    func testConfigurationEqualityUsesProviderIdentity() throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let first = PhoneDSHConfiguration(workspaceRoot: fixture.workspace,
                                          token: "t", origin: try origin(),
                                          bundle: fixture.bundle)
        let second = PhoneDSHConfiguration(workspaceRoot: fixture.workspace,
                                           token: "t", origin: try origin(),
                                           bundle: fixture.bundle)
        XCTAssertEqual(first, second)
        let different = PhoneDSHConfiguration(workspaceRoot: fixture.workspace,
                                              token: "u", origin: try origin(),
                                              bundle: fixture.bundle)
        XCTAssertNotEqual(first, different)
    }

    func testBundleLocationDerivesConventionalNames() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-bundle-\(UUID().uuidString)", isDirectory: true)
        let location = PhoneDSHBundleLocation(staticDirectory: root)
        XCTAssertEqual(location.workerEntry.lastPathComponent, "worker-entry.js")
        XCTAssertEqual(location.imageArchive.lastPathComponent, "image.tar.gz")
        XCTAssertEqual(location.lazyDirectory.lastPathComponent, "lazy")
        XCTAssertFalse(location.exists())
    }

    func testDiagnosticsExtendedDefaults() {
        let diagnostics = PhoneDSHDiagnostics(
            state: .stopped,
            bootID: String(repeating: "a", count: 32),
            fence: FenceToken(owner: "phone", generation: 0, walSeq: 0),
            budget: PhoneDSHBudgetSnapshot(table: .eightGB))
        XCTAssertEqual(diagnostics.hostState, nil)
        XCTAssertEqual(diagnostics.admission, .closed)
        XCTAssertEqual(diagnostics.fence?.owner, "phone")
        XCTAssertEqual(diagnostics.budget?.table, .eightGB)
        XCTAssertEqual(diagnostics.nextEpoch, 1)
        XCTAssertEqual(diagnostics.sideEffectEntries, 0)
        XCTAssertNil(diagnostics.ledgerPersistenceError)
    }

    func testTurnInactivityTimeoutIsValidatedConfiguration() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let configured = try fixture.configuration(turnInactivityTimeout: 2.5)
        XCTAssertEqual(configured.turnInactivityTimeout, 2.5)

        let defaults = try fixture.configuration()
        XCTAssertEqual(defaults.turnInactivityTimeout,
                       PhoneDSHConfiguration.defaultTurnInactivityTimeout)
        XCTAssertGreaterThan(defaults.turnInactivityTimeout, 0)

        // An unusable threshold fails the start loudly instead of silently
        // disabling (or instantly tripping) the watchdog.
        for bad in [0, -1, Double.infinity, Double.nan] {
            let configuration = try fixture.configuration(turnInactivityTimeout: bad)
            let host = PhoneDSHHost(configuration: configuration,
                                    engineFactory: { _ in
                                        MockEngine(worker: MockWorker())
                                    })
            do {
                try await host.start()
                XCTFail("turnInactivityTimeout=\(bad) must be rejected")
            } catch let error as PhoneDSHError {
                guard case .invalidConfiguration(let detail) = error else {
                    return XCTFail("unexpected error \(error) for \(bad)")
                }
                XCTAssertTrue(detail.contains("turnInactivityTimeout"))
            }
        }
    }

    func testBudgetSnapshotHeadroom() {
        let snapshot = PhoneDSHBudgetSnapshot(table: .eightGB,
                                              vfsLogicalBytesUsed: 10 * 1024 * 1024)
        XCTAssertEqual(snapshot.vfsHeadroomBytes,
                       BudgetTable.eightGB.vfsLogicalBytes - 10 * 1024 * 1024)
        XCTAssertTrue(snapshot.isWithinVFSLimit)
        let over = PhoneDSHBudgetSnapshot(table: .eightGB,
                                          vfsLogicalBytesUsed: BudgetTable.eightGB.vfsLogicalBytes + 1)
        XCTAssertFalse(over.isWithinVFSLimit)
        XCTAssertEqual(over.vfsHeadroomBytes, 0)
    }
}
