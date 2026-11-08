// SPDX-License-Identifier: MIT
import CoreBluetooth
import Foundation
import Observation
import PhoneDSHAgentCore
import XCTest
@testable import PhoneDSHBLE

#if DEBUG
/// Frozen P07/P09 local grant-order vectors. The hardware test adapter is not
/// evidence that CoreBluetooth attributes a callback to an application token.
final class StandardGattGrantOrderingTests: XCTestCase {
    private enum Scenario: String, CaseIterable, Decodable, Hashable {
        case readGrantRevoke = "read-grant-revoke"
        case readRevokeGrant = "read-revoke-grant"
        case alertGrantRevoke = "alert-grant-revoke"
        case alertRevokeGrant = "alert-revoke-grant"
        case crossFields = "cross-fields"
        case bothReadRevoke = "both-read-revoke"
        case bothAlertRevoke = "both-alert-revoke"
        case crossDeviceGrant = "cross-device-grant"
        case crossDeviceRevoke = "cross-device-revoke"
        case alertRevokeAdmission = "alert-revoke-admission"
        case alertGrantAdmission = "alert-grant-admission"
        case otherWriteRevoke = "other-write-revoke"
        case clearDuringGrant = "clear-during-grant"
        case retryAfterBarrier = "retry-after-barrier"
        case cancelPendingConnect = "cancel-pending-connect"
        case radioOff = "radio-off"
        case pendingNil = "pending-nil"
        case pendingSame = "pending-same"
        case pendingAlert = "pending-alert"
        case staleTimerNewOwner = "stale-timer-new-owner"
        case notificationAmbiguous = "notification-ambiguous"
        case timeoutNoBarrier = "timeout-no-barrier"
        case idleGrantConnectClear = "idle-grant-connect-clear"
        case connectingGrant = "connecting-grant"
        case cancelBeforeConnectSubmit = "cancel-before-connect-submit"
        case readRevokeAdmission = "read-revoke-admission"
        case newPendingDuringGrant = "new-pending-during-grant"
        case grantDuringClosing = "grant-during-closing"
        case connectCancelDidFail = "connect-cancel-didfail"
        case radioReset = "radio-reset"
        case notificationUnknown = "notification-unknown"
        case pendingTimeout = "pending-timeout"
        case pendingCancel = "pending-cancel"
        case unexpectedCentral = "unexpected-central"
        case unknownCharacteristic = "unknown-characteristic"
        case newConnectDiscovery = "new-connect-discovery"
        case duplicateClosingGrant = "duplicate-closing-grant"
        case cancelBeforeValue = "cancel-before-value"
        case valueBeforeCancel = "value-before-cancel"
        case linkEventWhileRead = "link-event-while-read"
        case cancelBeforeGrant = "cancel-before-grant"
        case grantBeforeCancel = "grant-before-cancel"
        case cancelBeforeRadioOff = "cancel-before-radio-off"
        case valueBeforeTimeout = "value-before-timeout"
        case cancelBeforeReadReserve = "cancel-before-read-reserve"
        case cancelAfterReadReserve = "cancel-after-read-reserve"
        case linkEventWhileClosing = "link-event-while-closing"
        case naturalDisconnectBarrier = "natural-disconnect-barrier"
        case idleRadioOffOn = "idle-radio-off-on"
        case idleRadioReset = "idle-radio-reset"
    }

    private struct Vector: Decodable {
        let scenario: Scenario
        let aRead: Bool
        let aAlert: Bool
        let bRead: Bool
        let bAlert: Bool
        var phase: String
        let bPhase: String
        var pending: String
        let pendingError: String
        let pendingValue: String
        let oldReadTimer: String
        let innerAdmission: String
        let unavailableVisible: Bool
        let readSubmissions: Int
        let alertSubmissions: Int
        let connectSubmissions: Int
        let disconnectSubmissions: Int
        let discoverySubmissions: Int
        let linkSubmissions: Int
        var linkDeliveries: Int
        var otherClosingCommands: Int
        let otherUnavailableCommands: Int
    }

    /// Snapshot values are read from the actual store and physical adapter;
    /// they are observations, never an independent copy of its state machine.
    private struct Snapshot {
        var aRead: Bool
        var aAlert: Bool
        var bRead: Bool
        var bAlert: Bool
        var phase: String
        var bPhase: String
        var pending: String
        var pendingError: String
        var pendingValue: String
        var oldReadTimer: String
        var innerAdmission: String
        var unavailableVisible: Bool
        var readSubmissions: Int
        var alertSubmissions: Int
        var connectSubmissions: Int
        var disconnectSubmissions: Int
        var discoverySubmissions: Int
        var linkSubmissions: Int
        var linkDeliveries: Int
        var otherClosingCommands: Int
        var otherUnavailableCommands: Int
    }

    private func vectors() throws -> [Vector] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("spec/device/v1/golden/standard-gatt-grant-order.jsonl")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try String(contentsOf: url, encoding: .utf8).split(whereSeparator: \.isNewline)
            .map { try decoder.decode(Vector.self, from: Data($0.utf8)) }
    }

    func testFixtureInventoryIsExhaustive() throws {
        let rows = try vectors()
        XCTAssertEqual(rows.count, 50)
        XCTAssertEqual(Set(rows.map(\.scenario)), Set(Scenario.allCases))
        XCTAssertEqual(Set(rows.map(\.scenario)).count, rows.count)
    }

    private func errorCategory(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        guard let failure = error as? BLEFailure else { return "unexpected: \(error)" }
        switch failure.message {
        case "Device permissions changed": return "permission-changed"
        case "Bluetooth read timed out": return "timeout"
        case "Bluetooth unavailable": return "bluetooth-unavailable"
        case "Device disconnected": return "disconnected"
        default: return "unexpected: \(failure.message)"
        }
    }

    private func validateBatteryResult(_ text: String, start: Date, end: Date,
                                       file: StaticString = #filePath, line: UInt = #line) {
        let prefix = "37 % @ "
        guard text.hasPrefix(prefix) else {
            XCTFail("Expected production Battery Level value, unit and timestamp, got \(text)", file: file, line: line)
            return
        }
        let timestamp = String(text.dropFirst(prefix.count))
        guard let date = ISO8601DateFormatter().date(from: timestamp) else {
            XCTFail("Invalid production ISO-8601 timestamp: \(timestamp)", file: file, line: line)
            return
        }
        XCTAssertGreaterThanOrEqual(date, start.addingTimeInterval(-1), file: file, line: line)
        XCTAssertLessThanOrEqual(date, end.addingTimeInterval(1), file: file, line: line)
    }

    /// Keep every fixture field checked. In particular, an absent-or-cancelled
    /// timer is a permitted union, not an active timer or a synthetic success.
    private func assertMatches(_ actual: Snapshot, _ row: Vector,
                               file: StaticString = #filePath, line: UInt = #line) {
        let name = row.scenario.rawValue
        XCTAssertTrue(matches(actual, row), "full frozen fixture must match actual store: \(name)", file: file, line: line)
        XCTAssertEqual(actual.aRead, row.aRead, name, file: file, line: line)
        XCTAssertEqual(actual.aAlert, row.aAlert, name, file: file, line: line)
        XCTAssertEqual(actual.bRead, row.bRead, name, file: file, line: line)
        XCTAssertEqual(actual.bAlert, row.bAlert, name, file: file, line: line)
        XCTAssertEqual(actual.phase, row.phase, name, file: file, line: line)
        XCTAssertEqual(actual.bPhase, row.bPhase, name, file: file, line: line)
        XCTAssertEqual(actual.pending, row.pending, name, file: file, line: line)
        XCTAssertEqual(actual.pendingError, row.pendingError, name, file: file, line: line)
        XCTAssertEqual(actual.pendingValue, row.pendingValue, name, file: file, line: line)
        if row.oldReadTimer == "absent-or-cancelled" {
            XCTAssertTrue(["none", "cancelled"].contains(actual.oldReadTimer), name, file: file, line: line)
        } else {
            XCTAssertEqual(actual.oldReadTimer, row.oldReadTimer, name, file: file, line: line)
        }
        XCTAssertEqual(actual.innerAdmission, row.innerAdmission, name, file: file, line: line)
        XCTAssertEqual(actual.unavailableVisible, row.unavailableVisible, name, file: file, line: line)
        XCTAssertEqual(actual.readSubmissions, row.readSubmissions, name, file: file, line: line)
        XCTAssertEqual(actual.alertSubmissions, row.alertSubmissions, name, file: file, line: line)
        XCTAssertEqual(actual.connectSubmissions, row.connectSubmissions, name, file: file, line: line)
        XCTAssertEqual(actual.disconnectSubmissions, row.disconnectSubmissions, name, file: file, line: line)
        XCTAssertEqual(actual.discoverySubmissions, row.discoverySubmissions, name, file: file, line: line)
        XCTAssertEqual(actual.linkSubmissions, row.linkSubmissions, name, file: file, line: line)
        XCTAssertEqual(actual.linkDeliveries, row.linkDeliveries, name, file: file, line: line)
        XCTAssertEqual(actual.otherClosingCommands, row.otherClosingCommands, name, file: file, line: line)
        XCTAssertEqual(actual.otherUnavailableCommands, row.otherUnavailableCommands, name, file: file, line: line)
    }

    private func matches(_ actual: Snapshot, _ row: Vector) -> Bool {
        let timerMatches = row.oldReadTimer == "absent-or-cancelled"
            ? ["none", "cancelled"].contains(actual.oldReadTimer) : actual.oldReadTimer == row.oldReadTimer
        let checks = [
            actual.aRead == row.aRead, actual.aAlert == row.aAlert, actual.bRead == row.bRead, actual.bAlert == row.bAlert,
            actual.phase == row.phase, actual.bPhase == row.bPhase, actual.pending == row.pending,
            actual.pendingError == row.pendingError, actual.pendingValue == row.pendingValue, timerMatches,
            actual.innerAdmission == row.innerAdmission, actual.unavailableVisible == row.unavailableVisible,
            actual.readSubmissions == row.readSubmissions, actual.alertSubmissions == row.alertSubmissions,
            actual.connectSubmissions == row.connectSubmissions, actual.disconnectSubmissions == row.disconnectSubmissions,
            actual.discoverySubmissions == row.discoverySubmissions, actual.linkSubmissions == row.linkSubmissions,
            actual.linkDeliveries == row.linkDeliveries, actual.otherClosingCommands == row.otherClosingCommands,
            actual.otherUnavailableCommands == row.otherUnavailableCommands,
        ]
        return checks.allSatisfy { $0 }
    }

    @MainActor private final class ReadProbe {
        var result: Result<String, Error>?
        var completions = 0
        var task: Task<Void, Never>?
        var token: ObjectIdentifier?
        var continuation: CheckedContinuation<String, Error>?

        func start(_ store: BLEDeviceStore, id: UUID) {
            task = Task { @MainActor in
                do { result = .success(try await store.read(id, profile: .battery)) }
                catch { result = .failure(error) }
                completions += 1
            }
        }

        /// Capture a real continuation before entering a synchronous observer.
        /// Only the store's production pending transition may install it.
        func prepareContinuation() {
            task = Task { @MainActor in
                do {
                    let value = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                        self.continuation = continuation
                    }
                    result = .success(value)
                } catch { result = .failure(error) }
                completions += 1
            }
        }
    }

    @MainActor private final class ObservationProbe {
        var calls = 0
        var actionCalls = 0
        var innerAdmission = "not-tested"

        func watch(_ store: BLEDeviceStore, _ action: @escaping @MainActor () -> Void) {
            withObservationTracking { _ = store.devices } onChange: {
                MainActor.assumeIsolated {
                    self.calls += 1
                    // Finite synchronous reentry; still count nested notifications.
                    if self.calls == 1 { self.actionCalls += 1; action() }
                }
            }
        }
    }

    @MainActor private final class Run {
        let a = UUID()
        let b = UUID()
        let adapter: BLEDeviceStore.TestAdapter
        let store: BLEDeviceStore
        let observation = ObservationProbe()
        var oldRead: ReadProbe?
        var newRead: ReadProbe?
        var oldTimer: BLEDeviceStore.TestTimerProbe?
        var otherUnavailableCommands = 0
        var otherClosingCommands = 0
        var beganAt = Date()
        var endedAt = Date()

        init() {
            let a = self.a, b = self.b
            let adapter = BLEDeviceStore.TestAdapter()
            self.adapter = adapter
            self.store = BLEDeviceStore(testAdapter: adapter, testDevices: [
                .init(id: a, name: "A", rssi: -40),
                .init(id: b, name: "B", rssi: -50),
            ])
        }

        /// Uses the normal store's connect, connection callback and discovery
        /// path. The adapter replaces only physical endpoints and submissions.
        func connectAndDiscover(_ id: UUID) {
            store.connect(id)
            store.testDidConnect(id)
            store.testDiscover(id, profiles: [.battery, .alert])
        }

        func startRead(_ id: UUID) async throws -> ReadProbe {
            let probe = ReadProbe()
            probe.start(store, id: id)
            for _ in 0..<200 {
                if store.testPending(id) {
                    probe.token = store.testPendingToken(id)
                    return probe
                }
                if let result = probe.result {
                    throw BLEFailure("Read did not become pending: \(result)")
                }
                try await Task.sleep(for: .milliseconds(5))
            }
            probe.task?.cancel()
            throw BLEFailure("Timed out waiting for real store read to become pending")
        }

        func waitForCompletion(_ probe: ReadProbe) async throws {
            for _ in 0..<200 {
                if probe.result != nil { return }
                try await Task.sleep(for: .milliseconds(5))
            }
            throw BLEFailure("Timed out waiting for read continuation")
        }

        func waitForPhase(_ id: UUID, _ phase: String) async throws {
            for _ in 0..<200 {
                if store.testPhase(id) == phase { return }
                try await Task.sleep(for: .milliseconds(5))
            }
            throw BLEFailure("Timed out waiting for local phase \(phase)")
        }

        func resetSubmissions() { adapter.commands.removeAll() }

        func attemptReadDenied() async {
            let probe = ReadProbe()
            probe.start(store, id: a)
            for _ in 0..<200 {
                if let result = probe.result {
                    switch result { case .failure: observation.innerAdmission = "denied"; case .success: observation.innerAdmission = "allowed" }
                    return
                }
                if store.testPending(a) {
                    observation.innerAdmission = "allowed"
                    probe.task?.cancel()
                    return
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
            observation.innerAdmission = "timed-out"
            probe.task?.cancel()
        }

        func attemptClosingOperations() async {
            let before = adapter.commands.count
            let priorAdmission = observation.innerAdmission
            await attemptReadDenied()
            let readAdmission = observation.innerAdmission
            _ = try? store.alert(a, level: 1)
            store.testAttemptLink(a)
            store.testAttemptDiscovery(a)
            store.testAttemptNotify(a)
            let attempts = adapter.commands.dropFirst(before)
            otherClosingCommands = attempts.filter {
                switch $0 { case .notify, .other: return true; default: return false }
            }.count
            XCTAssertEqual(readAdmission, "denied", "closing must deny real read")
            observation.innerAdmission = priorAdmission
        }

        func attemptUnavailableOperations() async {
            let before = adapter.commands.count
            store.scan(); store.stopScan()
            store.testAttemptDiscovery(a); store.testAttemptLink(a); store.testAttemptNotify(a)
            await attemptReadDenied()
            _ = try? store.alert(a, level: 1)
            let attempts = adapter.commands.dropFirst(before)
            otherUnavailableCommands = attempts.filter {
                switch $0 { case .scan, .stopScan, .notify, .other: return true; default: return false }
            }.count
        }

        func prepare(_ scenario: Scenario) async throws {
            let radioWhileIdle = scenario == .idleRadioOffOn || scenario == .idleRadioReset
            if !radioWhileIdle { connectAndDiscover(b) }
            let idle: Set<Scenario> = [.idleGrantConnectClear, .cancelBeforeConnectSubmit, .idleRadioOffOn, .idleRadioReset]
            let connecting: Set<Scenario> = [.cancelPendingConnect, .connectingGrant, .connectCancelDidFail, .newConnectDiscovery]
            if !idle.contains(scenario) {
                store.connect(a)
                if !connecting.contains(scenario) {
                    store.testDidConnect(a)
                    store.testDiscover(a, profiles: [.battery, .alert])
                }
            }

            let readInitially: Set<Scenario> = [
                .readRevokeGrant, .otherWriteRevoke, .readRevokeAdmission,
                .newPendingDuringGrant, .notificationAmbiguous, .notificationUnknown,
                .staleTimerNewOwner, .valueBeforeCancel, .cancelBeforeValue,
                .linkEventWhileRead, .valueBeforeTimeout, .cancelBeforeReadReserve,
                .cancelAfterReadReserve,
            ]
            let alertInitially: Set<Scenario> = [.alertRevokeGrant, .alertRevokeAdmission]
            let bothInitially: Set<Scenario> = [
                .radioOff, .radioReset, .pendingNil, .pendingSame, .pendingAlert,
                .pendingTimeout, .pendingCancel, .unexpectedCentral, .unknownCharacteristic,
                .cancelBeforeGrant, .grantBeforeCancel, .cancelBeforeRadioOff,
            ]
            if readInitially.contains(scenario) { store.grant(a, read: true) }
            if alertInitially.contains(scenario) { store.grant(a, alert: true) }
            if bothInitially.contains(scenario) { store.grant(a, read: true, alert: true) }
            if scenario == .crossDeviceRevoke { store.grant(b, read: true) }
            if scenario == .radioOff || scenario == .radioReset || scenario == .cancelBeforeRadioOff {
                store.grant(b, read: true, alert: true)
            }
            if scenario == .idleGrantConnectClear { store.grant(a, read: true, alert: true) }
            if radioWhileIdle {
                store.grant(a, read: true, alert: true)
                store.grant(b, read: true, alert: true)
            }
            if scenario == .naturalDisconnectBarrier { store.grant(a, read: true, alert: true) }

            let needsOldRead: Set<Scenario> = [
                .radioOff, .radioReset, .pendingNil, .pendingSame, .pendingAlert,
                .pendingTimeout, .pendingCancel, .unknownCharacteristic,
                .cancelBeforeValue, .valueBeforeCancel, .linkEventWhileRead,
                .cancelBeforeGrant, .grantBeforeCancel, .cancelBeforeRadioOff,
                .valueBeforeTimeout, .linkEventWhileClosing, .staleTimerNewOwner,
            ]
            if scenario == .linkEventWhileClosing { store.grant(a, read: true) }
            if needsOldRead.contains(scenario) {
                oldRead = try await startRead(a)
                oldTimer = store.testCaptureReadTimeout()
            }

            let closing: Set<Scenario> = [.retryAfterBarrier, .timeoutNoBarrier, .grantDuringClosing, .duplicateClosingGrant]
            if closing.contains(scenario) { store.disconnect(a) }
            resetSubmissions()
        }

        /// Exercises the public alert gate; the test adapter records only the
        /// physical submission. The Observation callback itself is synchronous.
        func attemptAlert() {
            do {
                _ = try store.alert(a, level: 1)
                observation.innerAdmission = "allowed"
            } catch {
                observation.innerAdmission = "denied"
            }
        }

        func performSimple(_ scenario: Scenario) throws -> Bool {
            switch scenario {
            case .readGrantRevoke:
                observation.watch(store) { self.store.grant(self.a, read: false) }
                store.grant(a, read: true)
            case .readRevokeGrant:
                observation.watch(store) { self.store.grant(self.a, read: true) }
                store.grant(a, read: false)
            case .alertGrantRevoke:
                observation.watch(store) { self.store.grant(self.a, alert: false) }
                store.grant(a, alert: true)
            case .alertRevokeGrant:
                observation.watch(store) { self.store.grant(self.a, alert: true) }
                store.grant(a, alert: false)
            case .crossFields:
                observation.watch(store) { self.store.grant(self.a, alert: true) }
                store.grant(a, read: true)
            case .bothReadRevoke:
                observation.watch(store) { self.store.grant(self.a, read: false) }
                store.grant(a, read: true, alert: true)
            case .bothAlertRevoke:
                observation.watch(store) { self.store.grant(self.a, alert: false) }
                store.grant(a, read: true, alert: true)
            case .crossDeviceGrant:
                observation.watch(store) { self.store.grant(self.b, read: true) }
                store.grant(a, read: true)
            case .crossDeviceRevoke:
                observation.watch(store) { self.store.grant(self.b, read: false) }
                store.grant(a, read: true)
            case .alertRevokeAdmission:
                // Establish that the physical path works before the reentrant
                // attempt, so a missing fake characteristic cannot fake denial.
                _ = try store.alert(a, level: 1)
                resetSubmissions()
                observation.watch(store) { self.attemptAlert() }
                store.grant(a, alert: false)
            case .alertGrantAdmission:
                observation.watch(store) { self.attemptAlert() }
                store.grant(a, alert: true)
                _ = try store.alert(a, level: 1)
            case .otherWriteRevoke:
                observation.watch(store) { self.store.grant(self.a, read: false) }
                store.testUnrelatedUpdate(a)
            case .clearDuringGrant:
                observation.watch(store) { self.store.disconnect(self.a) }
                store.grant(a, read: true)
            case .readRevokeAdmission:
                try store.testReadAdmission(a, profile: .battery)
                observation.watch(store) {
                    do { try self.store.testReadAdmission(self.a, profile: .battery); self.observation.innerAdmission = "allowed" }
                    catch { self.observation.innerAdmission = "denied" }
                }
                store.grant(a, read: false)
            default:
                return false
            }
            return true
        }

        func performNonRace(_ scenario: Scenario) async throws -> Bool {
            switch scenario {
            case .retryAfterBarrier:
                let oldOwner = store.testOwner(a)
                var inside = false
                store.testDidDisconnect(a, during: {
                    inside = true
                    self.store.connect(self.a)
                    XCTAssertEqual(self.adapter.commands.filter { if case .connect = $0 { return true }; return false }.count, 0)
                    XCTAssertEqual(self.store.testPhase(self.a), "closing")
                })
                XCTAssertTrue(inside, "must exercise the live callback before it returns")
                // Retirement is scheduled by the same production callback and
                // cannot make a reconnect possible while its stack is active.
                XCTAssertEqual(store.testPhase(a), "closing")
                try await waitForPhase(a, "idle")
                store.connect(a)
                XCTAssertNotEqual(store.testOwner(a), oldOwner)
                observation.innerAdmission = "denied"
            case .naturalDisconnectBarrier:
                let oldOwner = store.testOwner(a)
                var entered = false
                store.testDidDisconnect(a, during: {
                    entered = true
                    self.store.connect(self.a)
                    XCTAssertEqual(self.store.testPhase(self.a), "closing")
                    XCTAssertFalse(self.adapter.commands.contains { if case .connect = $0 { return true }; return false })
                    let device = self.store.devices.first { $0.id == self.a }
                    XCTAssertEqual(device?.allowRead, false)
                    XCTAssertEqual(device?.allowAlert, false)
                })
                XCTAssertTrue(entered, "must test reentry before natural callback returns")
                XCTAssertEqual(store.testPhase(a), "closing", "callback retirement must be deferred")
                try await waitForPhase(a, "idle")
                store.connect(a)
                XCTAssertNotEqual(store.testOwner(a), oldOwner)
                observation.innerAdmission = "denied"
            case .idleRadioOffOn, .idleRadioReset:
                store.testRadioUnavailable(reset: scenario == .idleRadioReset)
                store.scan(); store.stopScan()
                let before = adapter.commands.count
                store.connect(a)
                observation.innerAdmission = adapter.commands.count == before ? "denied" : "allowed"
                otherUnavailableCommands = adapter.commands.filter {
                    switch $0 { case .scan, .stopScan, .notify, .other: return true; default: return false }
                }.count
                store.testRadioOn()
                if scenario == .idleRadioReset {
                    let beforeRediscovery = adapter.commands.count
                    store.connect(a)
                    XCTAssertEqual(adapter.commands.count, beforeRediscovery, "invalidated peripheral must not be reused")
                    store.testRediscover(a)
                }
                store.connect(a)
            case .cancelPendingConnect:
                store.disconnect(a)
                store.testDidConnect(a)
                let before = adapter.commands.count
                store.connect(a)
                observation.innerAdmission = adapter.commands.count == before ? "denied" : "allowed"
            case .radioOff, .radioReset:
                store.testRadioUnavailable(reset: scenario == .radioReset)
                if let oldRead { try await waitForCompletion(oldRead) }
                await attemptUnavailableOperations()
                store.testRadioOn()
                let before = adapter.commands.count
                store.connect(a)
                if adapter.commands.count != before { observation.innerAdmission = "allowed" }
            case .pendingNil:
                store.grant(a)
            case .pendingSame:
                store.grant(a, read: true)
            case .pendingAlert:
                store.grant(a, alert: false)
            case .staleTimerNewOwner:
                guard let oldTimer, let oldRead else { throw BLEFailure("Expected old read and timer") }
                let previousOwner = store.testOwner(a)
                store.grant(a, read: true)
                try await waitForCompletion(oldRead)
                XCTAssertEqual(oldRead.completions, 1)
                store.testDidDisconnect(a)
                try await waitForPhase(a, "idle")
                connectAndDiscover(a)
                XCTAssertNotEqual(store.testOwner(a), previousOwner)
                store.grant(a, read: true)
                newRead = try await startRead(a)
                let newToken = store.testPendingToken(a)
                resetSubmissions()
                oldTimer.invoke()
                XCTAssertEqual(store.testPendingToken(a), newToken, "old timer must not finish the new read")
            case .newPendingDuringGrant:
                let probe = ReadProbe()
                probe.prepareContinuation()
                for _ in 0..<200 {
                    if probe.continuation != nil { break }
                    try await Task.sleep(for: .milliseconds(5))
                }
                guard let continuation = probe.continuation else { throw BLEFailure("Could not capture a real continuation") }
                newRead = probe
                observation.watch(store) {
                    do {
                        try self.store.testInstallPending(self.a, profile: .battery, continuation: continuation)
                        probe.continuation = nil
                        probe.token = self.store.testPendingToken(self.a)
                    } catch {
                        probe.continuation = nil
                        continuation.resume(throwing: error)
                        XCTFail("Could not install pending read through the production transition: \(error)")
                    }
                }
                store.grant(a, alert: true)
                if probe.continuation != nil {
                    probe.continuation = nil
                    continuation.resume(throwing: BLEFailure("Observation did not run"))
                }
            case .notificationAmbiguous, .notificationUnknown:
                try store.testReadAdmission(a, profile: .battery)
                if scenario == .notificationAmbiguous {
                    store.testNotification(a, profile: .battery, notifying: true)
                } else {
                    store.testNotification(a, profile: .battery, notifying: false,
                                           error: BLEFailure("notification state unavailable"))
                }
                await attemptReadDenied()
            case .idleGrantConnectClear:
                var checked = false
                adapter.beforeConnect = { id in
                    guard id == self.a else { return }
                    checked = true
                    let device = self.store.devices.first { $0.id == id }
                    XCTAssertEqual(device?.allowRead, false)
                    XCTAssertEqual(device?.allowAlert, false)
                    XCTAssertEqual(self.store.testPhase(id), "connecting")
                }
                store.connect(a)
                XCTAssertTrue(checked, "connect adapter must observe cleared grants")
                adapter.beforeConnect = nil
            case .connectingGrant:
                store.grant(a, read: true)
                await attemptReadDenied()
            case .cancelBeforeConnectSubmit:
                observation.watch(store) { self.store.disconnect(self.a) }
                store.connect(a)
            case .grantDuringClosing:
                store.grant(a, read: true)
                await attemptReadDenied()
            case .connectCancelDidFail:
                store.disconnect(a)
                store.testDidFail(a)
                let before = adapter.commands.count
                store.connect(a)
                observation.innerAdmission = adapter.commands.count == before ? "denied" : "allowed"
            case .pendingCancel:
                oldRead?.task?.cancel()
            case .unexpectedCentral:
                store.testDidConnect(a)
                let before = adapter.commands.count
                store.connect(a)
                await attemptReadDenied()
                if adapter.commands.count != before { observation.innerAdmission = "allowed" }
            case .unknownCharacteristic:
                store.testValue(a, profile: nil, data: Data())
                if let oldRead { try await waitForCompletion(oldRead) }
                let before = adapter.commands.count
                store.connect(a)
                await attemptReadDenied()
                if adapter.commands.count != before { observation.innerAdmission = "allowed" }
            case .newConnectDiscovery:
                store.testDidConnect(a)
            case .duplicateClosingGrant:
                store.grant(a, read: true)
                let tracker = ObservationProbe()
                tracker.watch(store) { XCTFail("a no-op closing grant emitted another notification") }
                store.grant(a, read: true)
                XCTAssertEqual(tracker.calls, 0)
                await attemptReadDenied()
            default:
                return false
            }
            if let oldRead, [.pendingNil, .pendingSame, .pendingAlert, .pendingCancel].contains(scenario) {
                try await waitForCompletion(oldRead)
            }
            return true
        }

        /// Cancellation handlers execute on the cancelling thread. Keep the
        /// main actor in this stack until Task.cancel has returned so a later
        /// actor hop cannot masquerade as the immediate outcome claim.
        func cancelOffMain(_ task: Task<Void, Never>) -> Bool {
            let returned = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async {
                task.cancel()
                returned.signal()
            }
            return returned.wait(timeout: .now() + 2) == .success
        }

        func performRace(_ scenario: Scenario) async throws -> Bool {
            switch scenario {
            case .pendingTimeout:
                guard let oldTimer else { throw BLEFailure("Expected captured read timer") }
                oldTimer.invoke()
            case .cancelBeforeValue:
                guard let task = oldRead?.task else { throw BLEFailure("Missing read task") }
                XCTAssertTrue(cancelOffMain(task), "background cancellation did not return")
                store.testValue(a, profile: .battery, data: Data([37]))
            case .valueBeforeCancel:
                store.testValue(a, profile: .battery, data: Data([37]))
                oldRead?.task?.cancel()
            case .cancelBeforeGrant:
                guard let task = oldRead?.task else { throw BLEFailure("Missing read task") }
                XCTAssertTrue(cancelOffMain(task), "background cancellation did not return")
                store.grant(a, read: true)
            case .grantBeforeCancel:
                guard let task = oldRead?.task else { throw BLEFailure("Missing read task") }
                adapter.afterReadOutcomeClaim = {
                    XCTAssertTrue(self.cancelOffMain(task), "background cancellation did not return")
                }
                store.grant(a, read: true)
                adapter.afterReadOutcomeClaim = nil
            case .cancelBeforeRadioOff:
                guard let task = oldRead?.task else { throw BLEFailure("Missing read task") }
                XCTAssertTrue(cancelOffMain(task), "background cancellation did not return")
                store.testRadioUnavailable(reset: false)
            case .valueBeforeTimeout:
                guard let oldTimer else { throw BLEFailure("Expected captured read timer") }
                store.testValue(a, profile: .battery, data: Data([37]))
                oldTimer.invoke()
            case .cancelBeforeReadReserve, .cancelAfterReadReserve:
                let probe = ReadProbe()
                let hook = {
                    guard let task = probe.task else { XCTFail("read task was not installed"); return }
                    self.oldTimer = self.store.testCaptureReadTimeout()
                    XCTAssertTrue(self.cancelOffMain(task), "background cancellation did not return")
                }
                if scenario == .cancelBeforeReadReserve { adapter.beforeReadReserve = hook }
                else { adapter.afterReadReserve = hook }
                oldRead = probe
                probe.start(store, id: a)
                try await waitForCompletion(probe)
                adapter.beforeReadReserve = nil; adapter.afterReadReserve = nil
            default:
                return false
            }
            if let oldRead { try await waitForCompletion(oldRead) }
            return true
        }

        func performRemaining(_ scenario: Scenario) async throws -> Bool {
            switch scenario {
            case .timeoutNoBarrier:
                guard let timeout = store.testCaptureClosingTimeout(a) else {
                    throw BLEFailure("Missing actual closing timeout handler")
                }
                timeout.invoke()
                let before = adapter.commands.count
                store.connect(a)
                observation.innerAdmission = adapter.commands.count == before ? "denied" : "allowed"
            case .linkEventWhileRead, .linkEventWhileClosing:
                let deviceID = "ce6ec956-1111-4222-8333-123456789abc"
                store.testPrepareLink(a, bootID: 1, deviceID: deviceID)
                if scenario == .linkEventWhileClosing {
                    guard let oldRead else { throw BLEFailure("Missing Link scenario read") }
                    store.grant(a, read: true)
                    try await waitForCompletion(oldRead)
                    XCTAssertEqual(oldRead.completions, 1)
                    resetSubmissions()
                }
                let json = "{\"boot_id\":1,\"device_id\":\"\(deviceID)\",\"event_id\":\"00000001-00000001\",\"seq\":1,\"type\":\"status\",\"payload\":{}}"
                let envelope = PDSHLink.Envelope(opcode: 0x6c, requestID: 0, body: Data(json.utf8))
                for segment in try envelope.segments(writeLimit: 20) {
                    store.testLinkEvent(a, segment: segment)
                }
            default:
                return false
            }
            return true
        }
    }

    @MainActor private func snapshot(_ run: Run, row: Vector) throws -> Snapshot {
        let a = try XCTUnwrap(run.store.devices.first { $0.id == run.a })
        let b = try XCTUnwrap(run.store.devices.first { $0.id == run.b })
        let currentToken = run.store.testPendingToken(run.a)
        var pending = "none", pendingError = "none", pendingValue = "none"
        if let currentToken {
            if currentToken == run.newRead?.token { pending = "new-pending" }
            else if currentToken == run.oldRead?.token { pending = "same-pending" }
            else { pending = "unexpected-pending" }
        }
        if let probe = run.oldRead, let result = probe.result {
            XCTAssertEqual(probe.completions, 1, "read continuation must complete once")
            switch result {
            case .success(let value):
                if currentToken == nil { pending = "completed-once" }
                validateBatteryResult(value, start: run.beganAt, end: run.endedAt)
                pendingValue = "expected"
            case .failure(let error):
                if currentToken == nil { pending = "failed-once" }
                pendingError = errorCategory(error)
            }
        }
        let commands = run.adapter.commands
        func count(_ predicate: (BLEDeviceStore.TestCommand) -> Bool) -> Int { commands.filter(predicate).count }
        return Snapshot(
            aRead: a.allowRead, aAlert: a.allowAlert, bRead: b.allowRead, bAlert: b.allowAlert,
            phase: run.store.testPhase(run.a), bPhase: run.store.testPhase(run.b),
            pending: pending, pendingError: pendingError, pendingValue: pendingValue,
            oldReadTimer: run.oldTimer?.state ?? "none", innerAdmission: run.observation.innerAdmission,
            unavailableVisible: ["正在等待系统断开，暂不可重连", "连接状态无法确认，暂不可用"].contains(a.state),
            readSubmissions: count { if case .read = $0 { return true }; return false },
            alertSubmissions: count { if case .alert = $0 { return true }; return false },
            connectSubmissions: count { if case .connect = $0 { return true }; return false },
            disconnectSubmissions: count { if case .disconnect = $0 { return true }; return false },
            discoverySubmissions: count { if case .discoverServices = $0 { return true }; if case .discoverCharacteristics = $0 { return true }; return false },
            linkSubmissions: count { if case .link = $0 { return true }; return false },
            linkDeliveries: run.store.testLinkDeliveries(run.a), otherClosingCommands: run.otherClosingCommands,
            otherUnavailableCommands: run.otherUnavailableCommands)
    }

    @MainActor func testSharedStandardGattScenariosThroughRealStore() async throws {
        let rows = try vectors()
        XCTAssertEqual(rows.count, 50)
        let watched: Set<Scenario> = [
            .readGrantRevoke, .readRevokeGrant, .alertGrantRevoke, .alertRevokeGrant,
            .crossFields, .bothReadRevoke, .bothAlertRevoke, .crossDeviceGrant,
            .crossDeviceRevoke, .alertRevokeAdmission, .alertGrantAdmission,
            .otherWriteRevoke, .clearDuringGrant, .readRevokeAdmission,
            .newPendingDuringGrant, .cancelBeforeConnectSubmit,
        ]
        for row in rows {
            let run = Run()
            do {
                try await run.prepare(row.scenario)
                let handled: Bool
                if try run.performSimple(row.scenario) {
                    handled = true
                } else if try await run.performNonRace(row.scenario) {
                    handled = true
                } else if try await run.performRace(row.scenario) {
                    handled = true
                } else {
                    handled = try await run.performRemaining(row.scenario)
                }
                guard handled else {
                    XCTFail("Unimplemented fixture scenario: \(row.scenario.rawValue)")
                    run.oldRead?.task?.cancel(); run.newRead?.task?.cancel()
                    continue
                }
                if watched.contains(row.scenario) {
                    XCTAssertEqual(run.observation.actionCalls, 1, row.scenario.rawValue)
                    XCTAssertLessThanOrEqual(run.observation.calls, 8, row.scenario.rawValue)
                }
                if row.innerAdmission == "denied" && run.observation.innerAdmission == "not-tested" {
                    await run.attemptReadDenied()
                }
                if ["closing", "quarantined"].contains(run.store.testPhase(run.a)) {
                    await run.attemptClosingOperations()
                }
                run.endedAt = Date()
                let actual = try snapshot(run, row: row)
                assertMatches(actual, row)

                // Mutation checks compare the real observed result against
                // safety-critical wrong expectations, not a fake state model.
                if row.scenario == .linkEventWhileClosing {
                    var mutated = row; mutated.linkDeliveries = 1
                    XCTAssertFalse(matches(actual, mutated), "a fabricated late Link delivery must not match")
                }
                if row.scenario == .cancelBeforeReadReserve {
                    var mutated = row; mutated.phase = "closing"
                    XCTAssertFalse(matches(actual, mutated), "unsent cancellation must not match closing")
                    mutated = row; mutated.pending = "completed-once"
                    XCTAssertFalse(matches(actual, mutated), "cancellation must not match a successful completion")
                }
                if row.scenario == .pendingTimeout {
                    var mutated = row; mutated.otherClosingCommands = 1
                    XCTAssertFalse(matches(actual, mutated), "a GATT command during closing must not match")
                }
                if run.store.testPending(run.a) {
                    run.store.disconnect(run.a)
                    if let probe = run.newRead ?? run.oldRead { try await run.waitForCompletion(probe) }
                }
                run.oldRead?.task?.cancel(); run.newRead?.task?.cancel()
            } catch {
                run.oldRead?.task?.cancel(); run.newRead?.task?.cancel()
                XCTFail("\(row.scenario.rawValue): \(error)")
            }
        }
    }

    @MainActor func testConnectingObserverDeclarationsMatchDisplayedGrants() async throws {
        let run = Run()
        run.connectAndDiscover(run.b)
        let observer = ObservationProbe()
        observer.watch(run.store) {
            run.store.grant(run.a, read: true, alert: true)
        }
        run.store.connect(run.a)
        XCTAssertEqual(observer.actionCalls, 1)
        XCTAssertEqual(run.store.testPhase(run.a), "connecting")
        let device = try XCTUnwrap(run.store.devices.first { $0.id == run.a })
        let declared = run.store.testDeclarations(run.a)
        XCTAssertTrue(device.allowRead)
        XCTAssertTrue(device.allowAlert)
        XCTAssertEqual(device.allowRead, declared.read)
        XCTAssertEqual(device.allowAlert, declared.alert)
        XCTAssertEqual(run.adapter.commands.filter { if case .connect(let id) = $0 { return id == run.a }; return false }.count, 1)
        XCTAssertThrowsError(try run.store.testReadAdmission(run.a, profile: .battery), "connecting grants must not admit GATT")
    }

    @MainActor func testDisconnectRetiresAfterCallbackAndPreservesNestedDeclarations() async throws {
        let run = Run()
        run.connectAndDiscover(run.a)
        run.store.grant(run.a, read: true, alert: true)
        run.store.disconnect(run.a)
        run.resetSubmissions()
        let observer = ObservationProbe()
        var callbackReturned = false
        observer.watch(run.store) {
            XCTAssertTrue(callbackReturned, "retirement notification must follow the callback return")
            run.store.grant(run.a, read: true, alert: true)
        }
        run.store.testDidDisconnect(run.a, during: {
            XCTAssertFalse(callbackReturned)
            run.store.connect(run.a)
            XCTAssertEqual(run.store.testPhase(run.a), "closing")
            XCTAssertFalse(run.adapter.commands.contains { if case .connect = $0 { return true }; return false })
        })
        callbackReturned = true
        XCTAssertEqual(run.store.testPhase(run.a), "closing", "the delegate wrapper must return before retirement")
        try await run.waitForPhase(run.a, "idle")
        XCTAssertEqual(observer.actionCalls, 1)
        let device = try XCTUnwrap(run.store.devices.first { $0.id == run.a })
        let declared = run.store.testDeclarations(run.a)
        XCTAssertTrue(device.allowRead)
        XCTAssertTrue(device.allowAlert)
        XCTAssertEqual(device.allowRead, declared.read)
        XCTAssertEqual(device.allowAlert, declared.alert)
        XCTAssertFalse(run.adapter.commands.contains { if case .connect = $0 { return true }; return false })
    }

    @MainActor func testNaturalDisconnectFailsPendingOnceAndWaitsForCallbackReturn() async throws {
        let run = Run()
        run.connectAndDiscover(run.a)
        run.store.grant(run.a, read: true, alert: true)
        let read = try await run.startRead(run.a)
        let timer = try XCTUnwrap(run.store.testCaptureReadTimeout())
        run.resetSubmissions()
        var callbackEntered = false
        run.store.testDidDisconnect(run.a, during: {
            callbackEntered = true
            XCTAssertFalse(run.store.testPending(run.a))
            XCTAssertEqual(timer.state, "cancelled")
            XCTAssertEqual(run.store.testPhase(run.a), "closing")
            run.store.connect(run.a)
            XCTAssertFalse(run.adapter.commands.contains { if case .connect = $0 { return true }; return false })
        })
        XCTAssertTrue(callbackEntered)
        XCTAssertEqual(run.store.testPhase(run.a), "closing")
        try await run.waitForCompletion(read)
        XCTAssertEqual(read.completions, 1)
        guard case .failure(let error)? = read.result else {
            XCTFail("natural disconnect must fail the old read")
            return
        }
        XCTAssertEqual(errorCategory(error), "disconnected")
        XCTAssertEqual(timer.state, "cancelled")
        try await run.waitForPhase(run.a, "idle")
        run.store.connect(run.a)
        XCTAssertEqual(run.adapter.commands.filter { if case .connect(let id) = $0 { return id == run.a }; return false }.count, 1)
        XCTAssertFalse(run.adapter.commands.contains { if case .disconnect = $0 { return true }; return false },
                       "a natural disconnect is not a submitted cancellation")
    }

    @MainActor func testIdleRadioOffReentrantDeclarationCannotAuthorizeOrSurviveConnect() async throws {
        let run = Run()
        run.store.grant(run.a, read: true, alert: true)
        run.store.grant(run.b, read: true, alert: true)
        run.resetSubmissions()
        let observer = ObservationProbe()
        observer.watch(run.store) { run.store.grant(run.a, read: true) }
        run.store.testRadioUnavailable(reset: false)
        XCTAssertEqual(observer.actionCalls, 1)
        let a = try XCTUnwrap(run.store.devices.first { $0.id == run.a })
        let b = try XCTUnwrap(run.store.devices.first { $0.id == run.b })
        let declared = run.store.testDeclarations(run.a)
        // A new explicit idle declaration may be displayed; it is not
        // admission while radio is off and is reset at the next connect.
        XCTAssertTrue(a.allowRead)
        XCTAssertTrue(declared.read)
        XCTAssertFalse(a.allowAlert)
        XCTAssertFalse(b.allowRead)
        XCTAssertFalse(b.allowAlert)
        XCTAssertThrowsError(try run.store.testReadAdmission(run.a, profile: .battery))
        XCTAssertTrue(run.adapter.commands.isEmpty, "radio-off must not send a CoreBluetooth command")
        run.store.testRadioOn()
        var checked = false
        run.adapter.beforeConnect = { id in
            guard id == run.a else { return }
            checked = true
            let current = run.store.devices.first { $0.id == id }
            let declarations = run.store.testDeclarations(id)
            XCTAssertEqual(current?.allowRead, false)
            XCTAssertEqual(current?.allowAlert, false)
            XCTAssertFalse(declarations.read)
            XCTAssertFalse(declarations.alert)
        }
        run.store.connect(run.a)
        XCTAssertTrue(checked)
        XCTAssertEqual(run.store.testPhase(run.a), "connecting")
    }

    @MainActor func testIdleManagerStatesRequireRediscoveryOnlyWhenPeersInvalidated() throws {
        let cases: [(CBManagerState, Bool)] = [
            (.unknown, true), (.unauthorized, true), (.unsupported, true), (.poweredOff, false),
        ]
        for (state, invalidatesPeers) in cases {
            let run = Run()
            let originalA = try XCTUnwrap(run.adapter.validPeers[run.a])
            let originalB = try XCTUnwrap(run.adapter.validPeers[run.b])
            run.store.grant(run.a, read: true, alert: true)
            run.store.grant(run.b, read: true, alert: true)
            run.resetSubmissions()
            run.store.testManagerState(state)
            XCTAssertEqual(run.store.testPhase(run.a), "idle", "\(state)")
            XCTAssertEqual(run.store.testPhase(run.b), "idle", "\(state)")
            let a = try XCTUnwrap(run.store.devices.first { $0.id == run.a })
            let b = try XCTUnwrap(run.store.devices.first { $0.id == run.b })
            XCTAssertFalse(a.allowRead, "\(state)"); XCTAssertFalse(a.allowAlert, "\(state)")
            XCTAssertFalse(b.allowRead, "\(state)"); XCTAssertFalse(b.allowAlert, "\(state)")
            run.store.connect(run.a)
            run.store.scan(); run.store.stopScan()
            XCTAssertTrue(run.adapter.commands.isEmpty, "no physical command while manager is unavailable: \(state)")

            if invalidatesPeers {
                XCTAssertNil(run.adapter.validPeers[run.a], "\(state)")
                XCTAssertNil(run.adapter.validPeers[run.b], "\(state)")
            } else {
                XCTAssertTrue(run.adapter.validPeers[run.a] === originalA, "\(state)")
                XCTAssertTrue(run.adapter.validPeers[run.b] === originalB, "\(state)")
            }
            run.store.testRadioOn()
            if invalidatesPeers {
                run.store.connect(run.a)
                run.store.connect(run.b)
                XCTAssertFalse(run.adapter.commands.contains { if case .connect = $0 { return true }; return false },
                               "invalidated peer cannot be reused: \(state)")
                run.store.testRediscover(run.a)
                let rediscovered = try XCTUnwrap(run.adapter.validPeers[run.a])
                XCTAssertFalse(rediscovered === originalA, "rediscovery must install a new simulated physical identity: \(state)")
                XCTAssertNil(run.adapter.validPeers[run.b], "A rediscovery must not restore B: \(state)")
            }
            run.store.connect(run.a)
            XCTAssertEqual(run.store.testPhase(run.a), "connecting", "\(state)")
            XCTAssertEqual(run.adapter.commands.filter { if case .connect(let id) = $0 { return id == run.a }; return false }.count, 1, "\(state)")
            XCTAssertFalse(run.adapter.commands.contains { if case .connect(let id) = $0 { return id == run.b }; return false }, "\(state)")
        }
    }

    @MainActor func testSameUUIDFromDifferentPhysicalPeerFailsClosed() async throws {
        let run = Run()
        run.connectAndDiscover(run.a)
        run.connectAndDiscover(run.b)
        run.store.grant(run.a, read: true, alert: true)
        run.store.grant(run.b, read: true, alert: true)
        let read = try await run.startRead(run.a)
        let timer = try XCTUnwrap(run.store.testCaptureReadTimeout())
        let bOwner = run.store.testOwner(run.b)
        run.resetSubmissions()

        // This supplies the same peripheral UUID with a different physical
        // identity through the delegate's production attribution check. It
        // does not claim that the OS supplies a generation/request token.
        run.store.testUnassignablePeer(run.a)
        try await run.waitForCompletion(read)
        XCTAssertEqual(read.completions, 1)
        guard case .failure(let error)? = read.result else {
            XCTFail("an unassignable peer must fail the old read")
            return
        }
        XCTAssertEqual(errorCategory(error), "disconnected")
        XCTAssertEqual(timer.state, "cancelled")
        XCTAssertEqual(run.store.testPhase(run.a), "quarantined")
        XCTAssertEqual(run.store.testPhase(run.b), "connected")
        XCTAssertEqual(run.store.testOwner(run.b), bOwner)
        let a = try XCTUnwrap(run.store.devices.first { $0.id == run.a })
        let b = try XCTUnwrap(run.store.devices.first { $0.id == run.b })
        XCTAssertFalse(a.allowRead); XCTAssertFalse(a.allowAlert)
        XCTAssertTrue(b.allowRead); XCTAssertTrue(b.allowAlert)
        XCTAssertThrowsError(try run.store.testReadAdmission(run.a, profile: .battery))
        XCTAssertThrowsError(try run.store.alert(run.a, level: 1))
        run.store.connect(run.a)
        XCTAssertEqual(run.adapter.commands.filter { if case .disconnect(let id) = $0 { return id == run.a }; return false }.count, 1)
        XCTAssertFalse(run.adapter.commands.contains { if case .connect = $0 { return true }; return false })
    }

    @MainActor func testNotificationErrorKeepsReadAmbiguousWithoutAffectingOtherPeer() async throws {
        let run = Run()
        run.connectAndDiscover(run.a)
        run.connectAndDiscover(run.b)
        run.store.grant(run.a, read: true)
        run.store.grant(run.b, read: true)
        try run.store.testReadAdmission(run.a, profile: .battery)
        try run.store.testReadAdmission(run.b, profile: .battery)
        run.resetSubmissions()
        run.store.testNotification(run.a, profile: .battery, notifying: false,
                                   error: BLEFailure("notification state unavailable"))
        XCTAssertEqual(run.store.testPhase(run.a), "connected")
        XCTAssertThrowsError(try run.store.testReadAdmission(run.a, profile: .battery))
        try run.store.testReadAdmission(run.b, profile: .battery)
        await run.attemptReadDenied()
        XCTAssertEqual(run.observation.innerAdmission, "denied")
        XCTAssertFalse(run.adapter.commands.contains { if case .read = $0 { return true }; return false })
        // A later disabled notification state does not establish that a prior
        // in-flight notification was drained.
        run.store.testNotification(run.a, profile: .battery, notifying: false)
        XCTAssertThrowsError(try run.store.testReadAdmission(run.a, profile: .battery))
    }

    @MainActor func testUnassignableNotificationFailsOnlyItsCurrentPeer() async throws {
        for scenario in ["different-peer", "unknown-characteristic"] {
            let run = Run()
            run.connectAndDiscover(run.a)
            run.connectAndDiscover(run.b)
            run.store.grant(run.a, read: true, alert: true)
            run.store.grant(run.b, read: true, alert: true)
            let bOwner = run.store.testOwner(run.b)
            let read = try await run.startRead(run.a)
            let timer = try XCTUnwrap(run.store.testCaptureReadTimeout())
            run.resetSubmissions()
            if scenario == "different-peer" {
                run.store.testNotification(run.a, profile: .battery, matchingPeer: false, notifying: true)
            } else {
                run.store.testNotification(run.a, profile: nil, notifying: true)
            }
            try await run.waitForCompletion(read)
            XCTAssertEqual(read.completions, 1, scenario)
            guard case .failure(let error)? = read.result else {
                XCTFail("unassignable notification must fail the pending read: \(scenario)")
                continue
            }
            XCTAssertEqual(errorCategory(error), "disconnected", scenario)
            XCTAssertEqual(timer.state, "cancelled", scenario)
            XCTAssertEqual(run.store.testPhase(run.a), "quarantined", scenario)
            XCTAssertEqual(run.store.testPhase(run.b), "connected", scenario)
            XCTAssertEqual(run.store.testOwner(run.b), bOwner, scenario)
            let a = try XCTUnwrap(run.store.devices.first { $0.id == run.a })
            let b = try XCTUnwrap(run.store.devices.first { $0.id == run.b })
            XCTAssertFalse(a.allowRead, scenario); XCTAssertFalse(a.allowAlert, scenario)
            XCTAssertTrue(b.allowRead, scenario); XCTAssertTrue(b.allowAlert, scenario)
            XCTAssertThrowsError(try run.store.testReadAdmission(run.a, profile: .battery), scenario)
            XCTAssertEqual(run.adapter.commands.filter { if case .disconnect(let id) = $0 { return id == run.a }; return false }.count, 1, scenario)
            XCTAssertFalse(run.adapter.commands.contains { if case .read = $0 { return true }; return false }, scenario)
        }
    }

    @MainActor func testDiscoveredLinkNotificationWithoutChannelFailsClosed() async throws {
        let run = Run()
        run.connectAndDiscover(run.a)
        run.connectAndDiscover(run.b)
        run.store.grant(run.a, read: true, alert: true)
        run.store.grant(run.b, read: true, alert: true)
        let bOwner = run.store.testOwner(run.b)
        // This setup injects a physical Link TX discovery into the shared
        // production source classifier; it does not install a fake channel.
        run.store.testDiscoverIncompleteLink(run.a)
        let read = try await run.startRead(run.a)
        let timer = try XCTUnwrap(run.store.testCaptureReadTimeout())
        run.resetSubmissions()
        XCTAssertTrue(run.store.testIncompleteLinkNotification(run.a), "must discover an actual simulated Link characteristic first")
        try await run.waitForCompletion(read)
        XCTAssertEqual(read.completions, 1)
        guard case .failure(let error)? = read.result else {
            XCTFail("an unassignable Link notification must fail the pending read")
            return
        }
        XCTAssertEqual(errorCategory(error), "disconnected")
        XCTAssertEqual(timer.state, "cancelled")
        XCTAssertEqual(run.store.testPhase(run.a), "quarantined")
        XCTAssertEqual(run.store.testPhase(run.b), "connected")
        XCTAssertEqual(run.store.testOwner(run.b), bOwner)
        let a = try XCTUnwrap(run.store.devices.first { $0.id == run.a })
        let b = try XCTUnwrap(run.store.devices.first { $0.id == run.b })
        XCTAssertFalse(a.allowRead); XCTAssertFalse(a.allowAlert)
        XCTAssertTrue(b.allowRead); XCTAssertTrue(b.allowAlert)
        XCTAssertEqual(run.store.testLinkDeliveries(run.a), 0)
        XCTAssertEqual(run.adapter.commands.filter { if case .disconnect(let id) = $0 { return id == run.a }; return false }.count, 1)
        XCTAssertFalse(run.adapter.commands.contains { if case .read = $0 { return true }; return false })
    }

    @MainActor func testReconnectRequiresFreshDiscoveryEvenAfterNewGrants() async throws {
        let run = Run()
        run.connectAndDiscover(run.a)
        run.store.grant(run.a, read: true, alert: true)
        try run.store.testReadAdmission(run.a, profile: .battery)
        _ = try run.store.alert(run.a, level: 1)
        let oldOwner = run.store.testOwner(run.a)

        run.store.disconnect(run.a)
        run.store.testDidDisconnect(run.a)
        try await run.waitForPhase(run.a, "idle")
        run.store.connect(run.a)
        run.store.testDidConnect(run.a)
        XCTAssertNotEqual(run.store.testOwner(run.a), oldOwner)
        run.store.grant(run.a, read: true, alert: true)
        run.resetSubmissions()

        XCTAssertThrowsError(try run.store.testReadAdmission(run.a, profile: .battery))
        await run.attemptReadDenied()
        XCTAssertEqual(run.observation.innerAdmission, "denied")
        XCTAssertThrowsError(try run.store.alert(run.a, level: 1))
        XCTAssertFalse(run.adapter.commands.contains {
            switch $0 { case .read, .alert: return true; default: return false }
        }, "old characteristic identities must not be reused")

        run.store.testDiscover(run.a, profiles: [.battery, .alert])
        try run.store.testReadAdmission(run.a, profile: .battery)
        _ = try run.store.alert(run.a, level: 1)
        let start = Date()
        let read = try await run.startRead(run.a)
        run.store.testValue(run.a, profile: .battery, data: Data([37]))
        try await run.waitForCompletion(read)
        let end = Date()
        XCTAssertEqual(read.completions, 1)
        guard case .success(let value)? = read.result else {
            XCTFail("freshly discovered Battery Level read must complete")
            return
        }
        validateBatteryResult(value, start: start, end: end)
        XCTAssertEqual(run.adapter.commands.filter { if case .read(let id, .battery) = $0 { return id == run.a }; return false }.count, 1)
        XCTAssertEqual(run.adapter.commands.filter { if case .alert(let id, 1) = $0 { return id == run.a }; return false }.count, 1)
    }

    @MainActor func testUnexpectedConnectOrFailureWhileConnectedOrClosingFailsClosed() async throws {
        for scenario in ["connect-while-closing", "fail-while-connected", "fail-while-closing"] {
            let run = Run()
            run.connectAndDiscover(run.a)
            run.connectAndDiscover(run.b)
            run.store.grant(run.a, read: true, alert: true)
            run.store.grant(run.b, read: true, alert: true)
            let read = try await run.startRead(run.a)
            let timer = try XCTUnwrap(run.store.testCaptureReadTimeout())
            let bOwner = run.store.testOwner(run.b)
            if scenario != "fail-while-connected" {
                run.store.disconnect(run.a)
                try await run.waitForCompletion(read)
                XCTAssertEqual(run.store.testPhase(run.a), "closing", scenario)
            }
            run.resetSubmissions()
            if scenario == "connect-while-closing" { run.store.testDidConnect(run.a) }
            else { run.store.testDidFail(run.a) }
            try await run.waitForCompletion(read)
            XCTAssertEqual(read.completions, 1, scenario)
            guard case .failure(let error)? = read.result else {
                XCTFail("unexpected callback must leave the old read failed: \(scenario)")
                continue
            }
            XCTAssertEqual(errorCategory(error), "disconnected", scenario)
            XCTAssertEqual(timer.state, "cancelled", scenario)
            XCTAssertEqual(run.store.testPhase(run.a), "quarantined", scenario)
            XCTAssertEqual(run.store.testPhase(run.b), "connected", scenario)
            XCTAssertEqual(run.store.testOwner(run.b), bOwner, scenario)
            let a = try XCTUnwrap(run.store.devices.first { $0.id == run.a })
            let b = try XCTUnwrap(run.store.devices.first { $0.id == run.b })
            XCTAssertFalse(a.allowRead, scenario); XCTAssertFalse(a.allowAlert, scenario)
            XCTAssertTrue(b.allowRead, scenario); XCTAssertTrue(b.allowAlert, scenario)
            XCTAssertThrowsError(try run.store.testReadAdmission(run.a, profile: .battery), scenario)
            run.store.connect(run.a)
            XCTAssertFalse(run.adapter.commands.contains { if case .connect = $0 { return true }; return false }, scenario)
            let disconnects = run.adapter.commands.filter { if case .disconnect(let id) = $0 { return id == run.a }; return false }.count
            XCTAssertEqual(disconnects, scenario == "fail-while-closing" ? 0 : 1, scenario)
        }
    }

    /// The real client and store perform normal handshake/tools discovery and
    /// query-only result requests; only the physical transport is controlled.
    @MainActor private final class PausedLinkTransport: PDSHLinkTransport {
        var holdQueries = false
        var opcodes: [UInt8] = []
        var held: [CheckedContinuation<Data, Error>] = []
        private var upload = Data()
        private var result = Data()

        func exchange(opcode: UInt8, body: Data) async throws -> Data {
            opcodes.append(opcode)
            let bytes = [UInt8](body)
            switch opcode {
            case 1:
                var ack = Data(repeating: 0, count: 25)
                ack[1] = 2; ack[2] = 1; ack[5] = 0x10; ack[24] = 2
                ack.append(contentsOf: Array("PDSH".utf8) + [1, 0, 0, 16])
                return ack
            case 0x54:
                guard bytes.count >= 24, Int(bytes.u16(18)) == upload.count else { throw BLEFailure("bad upload") }
                upload.append(body.dropFirst(24))
                var response = Data([0]); response.put(UInt16(upload.count)); return response
            case 0x55:
                let request = try JSONValue.parse(upload)
                guard request["name"]?.stringValue == "tools/list", let requestID = request["request_id"]?.stringValue else {
                    throw BLEFailure("unexpected commit")
                }
                result = try JSONValue.object([
                    "request_id": .string(requestID), "status": .string("completed"),
                    "result": .object(["device_id": .string("ce6ec956-1111-4222-8333-123456789abc"),
                                       "boot_id": .number(0), "tools": .array([.object(["name": .string("light.get")])])])
                ]).encoded()
                return Data([0, 1])
            case 0x56:
                if holdQueries {
                    return try await withCheckedThrowingContinuation { held.append($0) }
                }
                guard bytes.count >= 18 else { throw BLEFailure("short query") }
                let offset = Int(bytes.u16(16))
                guard offset < result.count else { throw BLEFailure("bad result offset") }
                var response = Data([0, 2]); response.put(UInt16(result.count)); response.put(UInt16(offset))
                response.append(result[offset..<min(offset + 499, result.count)])
                return response
            default: throw BLEFailure("unexpected opcode")
            }
        }

        func releaseAll() {
            let continuations = held
            held.removeAll()
            // A missing receipt remains outcome_unknown; no commit is retried.
            for continuation in continuations { continuation.resume(returning: Data([0, 0, 0, 0, 0, 0])) }
        }
    }

    @MainActor private func installLink(_ run: Run, transport: PausedLinkTransport) async throws {
        let owner = try XCTUnwrap(run.store.testOwner(run.a))
        let client = PDSHLinkClient(transport: transport)
        let peer = try await client.handshake()
        try await run.store.discoverLinkTools(run.a, client: client, bootID: peer.bootID) {
            run.store.testOwner(run.a) == owner && run.store.testPhase(run.a) == "connected"
        }
        run.store.grantLinkTool(run.a, name: "light.get", enabled: true)
        XCTAssertTrue(try XCTUnwrap(run.store.devices.first { $0.id == run.a }).grantedTools.contains("light.get"))
    }

    @MainActor private func waitForHeldQuery(_ transport: PausedLinkTransport) async throws {
        for _ in 0..<200 {
            if !transport.held.isEmpty { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw BLEFailure("Timed out waiting for real Link query")
    }

    @MainActor func testOldLinkCompletionDoesNotReleaseNewOwnerBusy() async throws {
        let run = Run()
        let oldTransport = PausedLinkTransport(), newTransport = PausedLinkTransport()
        defer { oldTransport.releaseAll(); newTransport.releaseAll() }
        run.connectAndDiscover(run.a)
        try await installLink(run, transport: oldTransport)
        oldTransport.holdQueries = true
        let oldRequest = UUID()
        let oldTask = Task { @MainActor in try await run.store.queryLink(run.a, requestID: oldRequest, name: "light.get") }
        try await waitForHeldQuery(oldTransport)
        let oldOwner = run.store.testOwner(run.a)

        run.store.disconnect(run.a)
        run.store.testDidDisconnect(run.a)
        try await run.waitForPhase(run.a, "idle")
        run.connectAndDiscover(run.a)
        XCTAssertNotEqual(run.store.testOwner(run.a), oldOwner)
        run.resetSubmissions()
        try run.store.grantDeviceTasks(run.a, enabled: false)
        XCTAssertEqual(run.store.testPhase(run.a), "connected", "old busy state must not disconnect the replacement")
        XCTAssertFalse(run.adapter.commands.contains { if case .disconnect = $0 { return true }; return false })
        try await installLink(run, transport: newTransport)
        newTransport.holdQueries = true
        let newTask = Task { @MainActor in try await run.store.queryLink(run.a, requestID: UUID(), name: "light.get") }
        try await waitForHeldQuery(newTransport)

        oldTransport.releaseAll()
        _ = try? await oldTask.value
        var thirdResult: Result<JSONValue?, Error>?
        let third = Task { @MainActor in
            do { thirdResult = .success(try await run.store.queryLink(run.a, requestID: UUID(), name: "light.get")) }
            catch { thirdResult = .failure(error) }
        }
        for _ in 0..<200 {
            if thirdResult != nil || newTransport.held.count > 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        guard case .failure(let error)? = thirdResult else {
            third.cancel()
            XCTFail("old completion allowed a concurrent query on the new owner")
            return
        }
        XCTAssertTrue(error.localizedDescription.lowercased().contains("busy"))
        XCTAssertEqual(newTransport.held.count, 1, "new owner's query must remain exclusively busy")
        run.resetSubmissions()
        run.store.cancelLinkOperations()
        XCTAssertEqual(run.store.testPhase(run.a), "closing")
        XCTAssertEqual(run.adapter.commands.filter { if case .disconnect(let id) = $0 { return id == run.a }; return false }.count, 1)
        XCTAssertEqual(oldTransport.opcodes.filter { $0 == 0x55 }.count, 1, "only tools/list setup commits")
        XCTAssertEqual(newTransport.opcodes.filter { $0 == 0x55 }.count, 1, "query path must not replay a commit")
        newTransport.releaseAll()
        _ = try? await newTask.value
    }
}
#endif
