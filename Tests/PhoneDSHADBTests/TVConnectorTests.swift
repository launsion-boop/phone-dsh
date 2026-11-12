// SPDX-License-Identifier: MIT
import Foundation
import XCTest
@testable import PhoneDSHADB

// MARK: - Test double

/// Checker that throws the scripted failures in order and then succeeds. Every
/// call is recorded so a test can prove `.unreachable` is not retried.
private final class TVScriptedConnectionChecker: TVConnectionChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var pendingFailures: [ADBFailure]
    private let result: TVDeviceSummary
    private var dialed: [(host: String, port: UInt16)] = []

    init(failures: [ADBFailure] = [], result: TVDeviceSummary) {
        self.pendingFailures = failures
        self.result = result
    }

    var callCount: Int {
        lock.withLock { dialed.count }
    }

    var endpoints: [(host: String, port: UInt16)] {
        lock.withLock { dialed }
    }

    func summary(host: String, port: UInt16) async throws -> TVDeviceSummary {
        let failure: ADBFailure? = lock.withLock {
            dialed.append((host, port))
            return pendingFailures.isEmpty ? nil : pendingFailures.removeFirst()
        }
        if let failure { throw failure }
        return result
    }
}

/// Returns one fixed shell result, recording the command it was asked to run.
private final class TVFixedShellExecutor: ADBCommandExecuting, @unchecked Sendable {
    private let result: ADBShellResult
    private let lock = NSLock()
    private var recorded: [String] = []

    init(result: ADBShellResult) { self.result = result }

    var commands: [String] { lock.withLock { recorded } }

    func shell(endpoint: ADBEndpoint, command: String, timeout: TimeInterval,
               outputLimit: Int) async throws -> ADBShellResult {
        lock.withLock { recorded.append(command) }
        return result
    }
}

// MARK: - Tests

final class TVConnectorTests: XCTestCase {
    private let sampleSummary = TVDeviceSummary(
        model: "XBR-55X90J", release: "11", display: "3840x2160",
        serial: "TV-SERIAL-0001", mac: "02:00:00:00:00:01")

    func testRetriesUnauthorizedThenReportsConnected() async throws {
        let (directory, _, _) = try makeIsolatedDirectory()
        let checker = TVScriptedConnectionChecker(
            failures: [ADBFailure("authorize the TV", kind: .unauthorized),
                       ADBFailure("still unauthorized", kind: .unauthorized)],
            result: sampleSummary)
        let connector = TVConnector(checker: checker, directory: directory,
                                    authorizeTimeout: .seconds(10),
                                    retryInterval: .milliseconds(20))

        let phases = await collectPhases(connector.connect(host: "192.0.2.70", port: 5555))

        XCTAssertEqual(phases.first, .probing)
        XCTAssertEqual(phases.last, .connected(sampleSummary.model))
        XCTAssertEqual(phases.count, 4, "probing + two authorization waits + connected")

        let authorizationWaits = phases.compactMap { phase -> Duration? in
            guard case .awaitingAuthorization(let elapsed) = phase else { return nil }
            return elapsed
        }
        XCTAssertFalse(authorizationWaits.isEmpty,
                       "an unauthorized attempt must surface awaitingAuthorization")
        XCTAssertTrue(authorizationWaits.allSatisfy { $0 >= .zero })

        XCTAssertFalse(phases.contains { phase in
            if case .failed = phase { return true }
            return false
        }, "a recovering attempt must not end in a failed phase")

        XCTAssertEqual(checker.callCount, 3)
        XCTAssertEqual(checker.endpoints.map { "\($0.host):\($0.port)" },
                       Array(repeating: "192.0.2.70:5555", count: 3))
    }

    func testUnreachableEndsAttemptWithoutRetry() async throws {
        let (directory, _, _) = try makeIsolatedDirectory()
        let checker = TVScriptedConnectionChecker(
            failures: [ADBFailure("no route to host", kind: .unreachable)],
            result: sampleSummary)
        let connector = TVConnector(checker: checker, directory: directory,
                                    authorizeTimeout: .seconds(10),
                                    retryInterval: .milliseconds(20))

        let phases = await collectPhases(connector.connect(host: "192.0.2.71", port: 5555))

        XCTAssertEqual(phases.count, 2)
        XCTAssertEqual(phases.first, .probing)
        guard case .some(.failed(let kind, let message)) = phases.last else {
            XCTFail("expected a failed phase, got \(String(describing: phases.last))")
            return
        }
        XCTAssertEqual(kind, .unreachable)
        XCTAssertEqual(message, "no route to host")
        XCTAssertEqual(checker.callCount, 1, "only unauthorized failures are retried")
        XCTAssertTrue(directory.records().isEmpty)
    }

    func testConnectedAttemptWritesRecordToDirectory() async throws {
        let (directory, defaults, _) = try makeIsolatedDirectory()
        let checker = TVScriptedConnectionChecker(result: sampleSummary)
        let connector = TVConnector(checker: checker, directory: directory,
                                    authorizeTimeout: .seconds(10),
                                    retryInterval: .milliseconds(20))

        let phases = await collectPhases(connector.connect(host: "192.0.2.72", port: 6095))

        XCTAssertEqual(phases.last, .connected(sampleSummary.model))

        let records = directory.records()
        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first { $0.serial == sampleSummary.serial })
        XCTAssertEqual(record.model, sampleSummary.model)
        XCTAssertEqual(record.host, "192.0.2.72")
        XCTAssertEqual(record.port, 6095)
        XCTAssertEqual(record.mac, sampleSummary.mac)
        XCTAssertEqual(record.lastSeen.timeIntervalSinceNow, 0, accuracy: 10)
        XCTAssertEqual(directory.lastEndpoint()?.host, "192.0.2.72")
        XCTAssertEqual(directory.lastEndpoint()?.port, 6095)

        XCTAssertNotNil(defaults.data(forKey: "phone-dsh.tv-discovery.devices.v1"))
        XCTAssertNotNil(defaults.data(forKey: "phone-dsh.tv-discovery.last-endpoint.v1"))
    }

    func testCheckerAcceptsNonZeroExitWhenOnlyOptionalFieldsAreMissing() async throws {
        // No wlan0 and no `ip`: the last command in the chain exits 1, but the
        // identity properties are readable, so the TV must still connect.
        let stdout = "\nXBR-55X90J\n11\nPhysical size: 3840x2160\n"
        let executor = TVFixedShellExecutor(
            result: ADBShellResult(stdout: Data(stdout.utf8),
                                   stderr: Data("ip: not found".utf8), exitCode: 1))

        let summary = try await ADBShellTVChecker(executor: executor)
            .summary(host: "192.0.2.73", port: 5555)

        XCTAssertEqual(summary.model, "XBR-55X90J")
        XCTAssertEqual(summary.release, "11")
        XCTAssertEqual(summary.display, "3840x2160")
        XCTAssertTrue(summary.serial.isEmpty, "an empty ro.serialno is not a connection failure")
        XCTAssertNil(summary.mac)
    }

    func testCheckerRejectsAnEmptyIdentity() async {
        let executor = TVFixedShellExecutor(
            result: ADBShellResult(stdout: Data(), stderr: Data("closed".utf8), exitCode: 1))

        do {
            _ = try await ADBShellTVChecker(executor: executor)
                .summary(host: "192.0.2.74", port: 5555)
            XCTFail("a probe with no identity must not report a connected TV")
        } catch let failure as ADBFailure {
            XCTAssertEqual(failure.kind, .device)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: Helpers

    /// A per-test `UserDefaults` suite; nothing is written to `.standard`.
    private func makeIsolatedDirectory() throws
        -> (directory: TVDeviceDirectory, defaults: UserDefaults, suite: String) {
        let suite = "phone-dsh.tv-connector-tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
        }
        return (TVDeviceDirectory(defaults: defaults), defaults, suite)
    }

    /// Drains the phase stream, giving up after `timeout` so an implementation
    /// that never terminates fails the assertions instead of hanging the suite.
    private func collectPhases(_ stream: AsyncStream<TVConnectPhase>,
                               timeout: Duration = .seconds(10)) async -> [TVConnectPhase] {
        await withTaskGroup(of: (finished: Bool, phases: [TVConnectPhase]).self) { group in
            group.addTask {
                var phases: [TVConnectPhase] = []
                for await phase in stream {
                    phases.append(phase)
                }
                return (finished: true, phases: phases)
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return (finished: false, phases: [])
            }
            while let result = await group.next() {
                group.cancelAll()
                return result.finished ? result.phases : []
            }
            return []
        }
    }
}
