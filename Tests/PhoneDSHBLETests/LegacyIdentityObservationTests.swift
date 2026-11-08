// SPDX-License-Identifier: MIT
import CoreBluetooth
import Foundation
import Observation
import PhoneDSHAgentCore
import XCTest
@testable import PhoneDSHBLE

#if DEBUG
/// Local ordering only: no identity RPC, authenticated peer or hardware is simulated.
final class LegacyIdentityObservationTests: XCTestCase {
    private func rows(_ name: String) throws -> [[String: Any]] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("spec/device/v1/golden/\(name).jsonl")
        return try String(contentsOf: url, encoding: .utf8).split(whereSeparator: \.isNewline).map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    /// Every access forwards to a unique real UserDefaults suite. Hooks only
    /// schedule synchronous reentry; they do not implement storage behavior.
    private final class ForwardingDefaults: UserDefaults, @unchecked Sendable {
        let backing: UserDefaults
        var reads = 0, writes = 0
        var beforeRead: ((Int) -> Void)?
        var beforeSet: (() -> Void)?
        var afterSet: (() -> Void)?
        var maskReadback = false
        init?(suite: String) {
            guard let backing = UserDefaults(suiteName: suite) else { return nil }
            self.backing = backing
            super.init(suiteName: suite)
        }
        override func object(forKey key: String) -> Any? {
            reads += 1
            beforeRead?(reads)
            if maskReadback && reads == 2 { return 42 }
            return backing.object(forKey: key)
        }
        override func set(_ value: Any?, forKey key: String) {
            writes += 1
            beforeSet?()
            backing.set(value, forKey: key)
            afterSet?()
        }
    }

    @MainActor private final class Monitor {
        var notifications = 0
        var actions = 0
        var onFirst: (() -> Void)?
        func devices(_ store: BLEDeviceStore) {
            withObservationTracking { _ = store.devices } onChange: {
                MainActor.assumeIsolated {
                    self.notifications += 1
                    // Re-arm before a single action, so nested publications are counted.
                    if self.notifications < 9 { self.devices(store) }
                    if self.actions == 0, let action = self.onFirst {
                        self.actions += 1
                        action()
                    }
                }
            }
        }
        func status(_ store: BLEDeviceStore) {
            withObservationTracking { _ = store.status } onChange: {
                MainActor.assumeIsolated {
                    self.notifications += 1
                    if self.notifications < 9 { self.status(store) }
                    if self.actions == 0, let action = self.onFirst {
                        self.actions += 1
                        action()
                    }
                }
            }
        }
    }

    @MainActor private final class Run {
        let a = UUID(), b = UUID()
        let suite: String
        let defaults: ForwardingDefaults
        let adapter: BLEDeviceStore.TestAdapter
        let store: BLEDeviceStore
        let devicesMonitor = Monitor(), statusMonitor = Monitor()
        var hookFires = 0, lifecycleActions = 0, lifecycleTransitions = 0
        var hook: (() -> Void)?

        init() throws {
            suite = "PhoneDSH.IdentityObservation." + UUID().uuidString
            defaults = try XCTUnwrap(ForwardingDefaults(suite: suite))
            adapter = BLEDeviceStore.TestAdapter()
            adapter.identityDefaults = defaults
            store = BLEDeviceStore(testAdapter: adapter, testDevices: [
                .init(id: a, name: "A", rssi: -40), .init(id: b, name: "B", rssi: -50),
            ])
        }
        func cleanup() { defaults.backing.removePersistentDomain(forName: suite) }
        func device(_ id: UUID) throws -> BLEDeviceStore.Device {
            try XCTUnwrap(store.devices.first { $0.id == id })
        }
        func connect(_ id: UUID, installClient: Bool = true) {
            store.connect(id); store.testDidConnect(id)
            store.testReplaceIdentityChannel(id)
            if installClient { store.testInstallIdentityClient(id, reuse: false) }
        }
        func setPending(_ id: UUID, _ label: String) { store.testSetIdentityPending(id, label: label) }
        func fire() {
            guard hookFires == 0 else { return }
            hookFires += 1; hook?()
        }
        func currentRevision(_ id: UUID) -> ObjectIdentifier? { store.testIdentityRevision(id) }
        func transition(_ id: UUID, _ operation: () -> Void) {
            let previous = currentRevision(id)
            operation()
            let next = currentRevision(id)
            if previous != next { lifecycleTransitions += 1 }
        }
        func disconnectAndAssert(_ id: UUID) {
            let before = adapter.commands.filter { if case .disconnect(let device) = $0 { return device == id }; return false }.count
            transition(id) { store.disconnect(id) }
            XCTAssertEqual(store.testPhase(id), "closing")
            XCTAssertEqual(adapter.commands.filter { if case .disconnect(let device) = $0 { return device == id }; return false }.count, before + 1)
            XCTAssertNil(store.testIdentityClient(id))
            XCTAssertNil(store.testIdentityChannel(id))
        }
        func runAction(_ action: String, pending: String) throws {
            switch action {
            case "none", "fail-readback", "no-client", "no-pending", "missing-device": break
            case "disconnect":
                lifecycleActions += 1; disconnectAndAssert(a)
            case "disconnect-b":
                lifecycleActions += 1; disconnectAndAssert(b)
            case "replace-channel":
                lifecycleActions += 1
                let previous = store.testIdentityChannel(a)
                transition(a) { store.testReplaceIdentityChannel(a) }
                XCTAssertNotEqual(previous, store.testIdentityChannel(a))
            case "reinstall-client":
                lifecycleActions += 1
                let previous = store.testIdentityClient(a)
                XCTAssertNotNil(previous)
                transition(a) { store.testInstallIdentityClient(a, reuse: true) }
                XCTAssertEqual(previous, store.testIdentityClient(a))
            case "pending-aba":
                lifecycleActions += 1
                let middle = "legacy:temporary"
                transition(a) { setPending(a, middle) }
                XCTAssertEqual(try device(a).pendingIdentity, middle)
                transition(a) { setPending(a, pending) }
            case "pending-nfd":
                lifecycleActions += 1
                transition(a) { setPending(a, "ble:cafe\u{301}") }
            case "confirm-a": store.trustPendingIdentity(a)
            case "confirm-b", "confirm-b-then-retry": store.trustPendingIdentity(b)
            case "disconnect-then-confirm-a":
                lifecycleActions += 1; disconnectAndAssert(a)
                store.trustPendingIdentity(a)
            case "radio-off":
                lifecycleActions += 1; transition(a) { store.testManagerState(.poweredOff) }
                XCTAssertEqual(store.testPhase(a), "quarantined")
                XCTAssertNil(store.testIdentityClient(a)); XCTAssertNil(store.testIdentityChannel(a))
            default: XCTFail("Unknown frozen action \(action)")
            }
        }
    }

    /// A real PDSHLinkClient uses this controlled physical transport. It
    /// returns valid protocol bytes and may suspend exactly one exchange.
    @MainActor private final class ControlledTransport: PDSHLinkTransport {
        var pausedOpcode: UInt8?
        var held: CheckedContinuation<Data, Error>?
        var heldResponse: Data?
        var opcodes: [UInt8] = []
        private var upload = Data(), result = Data()

        func exchange(opcode: UInt8, body: Data) async throws -> Data {
            opcodes.append(opcode)
            let bytes = [UInt8](body)
            let response: Data
            switch opcode {
            case 1:
                var ack = Data(repeating: 0, count: 25)
                ack[1] = 2; ack[2] = 1; ack[5] = 0x10; ack[24] = 2
                ack.append(contentsOf: Array("PDSH".utf8) + [1, 0, 0, 16])
                response = ack
            case 0x54:
                guard bytes.count >= 24, Int(bytes.u16(18)) == upload.count else { throw BLEFailure("bad upload") }
                upload.append(body.dropFirst(24))
                var ack = Data([0]); ack.put(UInt16(upload.count)); response = ack
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
                upload.removeAll()
                response = Data([0, 1])
            case 0x56:
                guard bytes.count >= 18 else { throw BLEFailure("short query") }
                let offset = Int(bytes.u16(16))
                guard offset < result.count else { throw BLEFailure("bad result offset") }
                var part = Data([0, 2]); part.put(UInt16(result.count)); part.put(UInt16(offset))
                part.append(result[offset..<min(offset + 499, result.count)])
                response = part
            default: throw BLEFailure("unexpected opcode")
            }
            guard pausedOpcode == opcode else { return response }
            pausedOpcode = nil
            heldResponse = response
            return try await withCheckedThrowingContinuation { held = $0 }
        }
        func release(error: Error? = nil) {
            guard let continuation = held else { return }
            held = nil
            let response = heldResponse; heldResponse = nil
            if let error { continuation.resume(throwing: error) }
            else if let response { continuation.resume(returning: response) }
            else { continuation.resume(throwing: BLEFailure("missing controlled response")) }
        }
    }

    @MainActor private func waitForHeld(_ transport: ControlledTransport) async throws {
        for _ in 0..<200 {
            if transport.held != nil { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw BLEFailure("Timed out waiting for controlled Link exchange")
    }

    private func assertScalars(_ actual: String, _ expected: String, _ id: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.unicodeScalars.map(\.value), expected.unicodeScalars.map(\.value), id, file: file, line: line)
    }
    private func assertVisible(_ actual: Any?, _ expected: Any, _ id: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        if let strings = expected as? [String] {
            guard let actual = actual as? [String] else { XCTFail("\(id): expected string array", file: file, line: line); return }
            XCTAssertEqual(actual.map { $0.unicodeScalars.map(\.value) },
                           strings.map { $0.unicodeScalars.map(\.value) }, id, file: file, line: line)
        } else {
            guard let actual else { XCTFail("\(id): expected visible value", file: file, line: line); return }
            XCTAssertTrue(NSDictionary(dictionary: ["value": actual]).isEqual(to: ["value": expected]), id, file: file, line: line)
        }
    }

    @MainActor func testOriginalConfirmationVectors() throws {
        let vectors = try rows("legacy-identity-confirmation")
        XCTAssertEqual(vectors.count, 11)
        XCTAssertEqual(Set(vectors.compactMap { $0["id"] as? String }).count, vectors.count)
        for row in vectors {
            let id = try XCTUnwrap(row["id"] as? String)
            let interruption = try XCTUnwrap(row["interruption"] as? String)
            let run = try Run()
            defer { run.cleanup() }
            run.store.testRadioOn(); run.connect(run.a)
            let label = "ble:legacy-confirmation"
            run.setPending(run.a, label)
            run.defaults.backing.set(["legacy:old"], forKey: BLETrustedIdentities.key)
            run.defaults.reads = 0; run.defaults.writes = 0
            run.statusMonitor.status(run.store)
            if interruption == "stale-proof" {
                let completion = try XCTUnwrap(run.store.testCaptureIdentityProof(run.a), id)
                run.store.testInstallIdentityClient(run.a, reuse: true)
                completion("ble:" + String(repeating: "a", count: 64))
                XCTAssertEqual(run.defaults.reads, 0, id)
                XCTAssertEqual(run.defaults.writes, 0, id)
            } else {
                let writeResult = try XCTUnwrap(row["write_result"] as? Bool)
                run.defaults.maskReadback = !writeResult
                var hookCount = 0
                run.defaults.beforeRead = { count in
                    guard count == 2, interruption != "none" else { return }
                    hookCount += 1
                    switch interruption {
                    case "disconnect": run.store.disconnect(run.a)
                    case "replace-channel": run.store.testReplaceIdentityChannel(run.a)
                    case "reinstall-client": run.store.testInstallIdentityClient(run.a, reuse: true)
                    case "replace-pending": run.setPending(run.a, "legacy:replacement")
                    default: XCTFail("Unknown interruption \(interruption)")
                    }
                }
                run.store.trustPendingIdentity(run.a)
                XCTAssertEqual(run.defaults.reads, 2, id)
                XCTAssertEqual(run.defaults.writes, 1, id)
                XCTAssertEqual(hookCount, interruption == "none" ? 0 : 1, id)
                assertVisible(run.defaults.backing.object(forKey: BLETrustedIdentities.key),
                              ["legacy:old", label], id)
            }
            let a = try run.device(run.a)
            XCTAssertEqual(!a.taskIdentity.isEmpty, row["update_current"] as? Bool, id)
            if !a.taskIdentity.isEmpty { assertScalars(a.taskIdentity, label, id) }
            XCTAssertEqual(!a.identityError.isEmpty, row["report_failure"] as? Bool, id)
            let expectedPending: String
            if interruption == "replace-pending" { expectedPending = "legacy:replacement" }
            else if interruption == "none" && row["write_result"] as? Bool == false { expectedPending = label }
            else { expectedPending = "" }
            assertScalars(a.pendingIdentity, expectedPending, id)
            XCTAssertFalse(a.allowDeviceTasks, id)
            XCTAssertEqual(run.statusMonitor.notifications, 0, id)
            XCTAssertEqual(run.store.status, "蓝牙已就绪，请点击扫描", id)
        }
    }

    @MainActor func testInstallingClientOrChannelCannotAdmitStillVisibleOldPending() throws {
        for channel in [false, true] {
            let run = try Run()
            defer { run.cleanup() }
            run.store.testRadioOn(); run.connect(run.a)
            run.setPending(run.a, "legacy:old-pending")
            run.defaults.backing.set(["legacy:old"], forKey: BLETrustedIdentities.key)
            run.defaults.reads = 0; run.defaults.writes = 0
            var seenPending = ""
            run.devicesMonitor.onFirst = {
                seenPending = (try? run.device(run.a).pendingIdentity) ?? ""
                run.store.trustPendingIdentity(run.a)
            }
            run.devicesMonitor.devices(run.store)
            if channel { run.store.testReplaceIdentityChannel(run.a) }
            else { run.store.testInstallIdentityClient(run.a, reuse: true) }
            XCTAssertEqual(run.devicesMonitor.actions, 1)
            XCTAssertEqual(seenPending, "legacy:old-pending")
            XCTAssertEqual(run.defaults.reads, 0)
            XCTAssertEqual(run.defaults.writes, 0)
            let device = try run.device(run.a)
            XCTAssertTrue(device.pendingIdentity.isEmpty)
            XCTAssertTrue(device.taskIdentity.isEmpty)
            XCTAssertFalse(device.allowDeviceTasks)
            assertVisible(run.defaults.backing.object(forKey: BLETrustedIdentities.key), ["legacy:old"], "installation")
        }
    }

    @MainActor func testNestedConfirmationDoesNotOverwriteLaterPending() throws {
        for valid in [true, false] {
            let run = try Run()
            defer { run.cleanup() }
            run.store.testRadioOn(); run.connect(run.a)
            let first = "legacy:first", later = "legacy:later"
            run.setPending(run.a, first)
            run.defaults.backing.set(valid ? ["legacy:old"] as Any : 42 as Any,
                                     forKey: BLETrustedIdentities.key)
            run.defaults.reads = 0; run.defaults.writes = 0
            run.statusMonitor.status(run.store)
            run.devicesMonitor.onFirst = {
                run.store.trustPendingIdentity(run.a)
                run.setPending(run.a, later)
            }
            run.devicesMonitor.devices(run.store)
            run.store.trustPendingIdentity(run.a)
            let device = try run.device(run.a)
            XCTAssertEqual(run.devicesMonitor.actions, 1)
            XCTAssertLessThanOrEqual(run.devicesMonitor.notifications, 8)
            XCTAssertEqual(device.pendingIdentity, later)
            XCTAssertTrue(device.taskIdentity.isEmpty)
            XCTAssertTrue(device.identityError.isEmpty)
            XCTAssertFalse(device.allowDeviceTasks)
            XCTAssertEqual(run.defaults.reads, valid ? 3 : 2)
            XCTAssertEqual(run.defaults.writes, valid ? 1 : 0)
            assertVisible(run.defaults.backing.object(forKey: BLETrustedIdentities.key),
                          valid ? ["legacy:old", first] as Any : 42 as Any, "nested")
            XCTAssertEqual(run.statusMonitor.notifications, 0)
        }
    }

    @MainActor func testStaleToolsListCannotReplaceNewIdentityGeneration() async throws {
        for change in ["same-client", "new-client", "pending-only"] {
            let run = try Run()
            defer { run.cleanup() }
            run.store.testRadioOn(); run.connect(run.a)
            let owner = try XCTUnwrap(run.store.testOwner(run.a))
            let channel = try XCTUnwrap(run.store.testIdentityChannel(run.a))
            let transport = ControlledTransport()
            defer { transport.release() }
            let client = PDSHLinkClient(transport: transport)
            let peer = try await client.handshake()
            let stillOwner = {
                run.store.testOwner(run.a) == owner && run.store.testPhase(run.a) == "connected" &&
                run.store.testIdentityChannel(run.a) == channel
            }
            // Positive control: the actual discovery and valid response install
            // this client before exercising a second, delayed discovery.
            try await run.store.discoverLinkTools(run.a, client: client, bootID: peer.bootID, isCurrent: stillOwner)
            XCTAssertEqual(run.store.testIdentityClient(run.a), ObjectIdentifier(client), change)
            XCTAssertEqual(try run.device(run.a).linkTools, ["light.get"], change)
            transport.pausedOpcode = 0x56
            let old = Task { @MainActor in
                try await run.store.discoverLinkTools(run.a, client: client, bootID: peer.bootID, isCurrent: stillOwner)
            }
            try await waitForHeld(transport)
            if change == "same-client" { run.store.testInstallIdentityClient(run.a, reuse: true) }
            if change == "new-client" { run.store.testInstallIdentityClient(run.a, reuse: false) }
            run.setPending(run.a, "legacy:new-generation")
            let revision = try XCTUnwrap(run.store.testIdentityRevision(run.a))
            let currentClient = try XCTUnwrap(run.store.testIdentityClient(run.a))
            if change == "new-client" { XCTAssertNotEqual(currentClient, ObjectIdentifier(client), change) }
            else { XCTAssertEqual(currentClient, ObjectIdentifier(client), change) }
            let before = try run.device(run.a)
            run.adapter.commands.removeAll()
            transport.release()
            _ = try? await old.value
            let after = try run.device(run.a)
            XCTAssertEqual(run.store.testOwner(run.a), owner, change)
            XCTAssertEqual(run.store.testIdentityChannel(run.a), channel, change)
            XCTAssertEqual(run.store.testIdentityClient(run.a), currentClient, change)
            XCTAssertEqual(run.store.testIdentityRevision(run.a), revision, change)
            XCTAssertEqual(after.pendingIdentity, "legacy:new-generation", change)
            XCTAssertEqual(after.taskIdentity, before.taskIdentity, change)
            XCTAssertEqual(after.identityError, before.identityError, change)
            XCTAssertEqual(after.linkState, before.linkState, change)
            XCTAssertEqual(after.linkTools, before.linkTools, change)
            XCTAssertFalse(after.allowDeviceTasks, change)
            XCTAssertFalse(run.adapter.commands.contains { if case .disconnect = $0 { return true }; return false }, change)
            XCTAssertEqual(transport.opcodes.filter { $0 == 0x55 }.count, 2, change)
        }
    }

    @MainActor func testLocalProofFailureOnlyPropagatesForCurrentUncancelledContext() async throws {
        for scenario in ["current", "cancelled", "disconnect", "same-client", "new-client", "channel", "pending"] {
            let run = try Run()
            defer { run.cleanup() }
            run.store.testRadioOn(); run.connect(run.a)
            run.setPending(run.a, "legacy:initial")
            let deliver = try XCTUnwrap(run.store.testCaptureIdentityProofFailure(run.a), scenario)
            switch scenario {
            case "disconnect": run.store.disconnect(run.a)
            case "same-client": run.store.testInstallIdentityClient(run.a, reuse: true)
            case "new-client": run.store.testInstallIdentityClient(run.a, reuse: false)
            case "channel": run.store.testReplaceIdentityChannel(run.a)
            case "pending": run.setPending(run.a, "legacy:replacement")
            default: break
            }
            let before = try run.device(run.a)
            let owner = run.store.testOwner(run.a), channel = run.store.testIdentityChannel(run.a)
            let client = run.store.testIdentityClient(run.a), revision = run.store.testIdentityRevision(run.a)
            let status = run.store.status
            run.statusMonitor.status(run.store)
            run.defaults.reads = 0; run.defaults.writes = 0
            run.adapter.commands.removeAll()
            if scenario == "cancelled" {
                let task = Task { @MainActor in
                    withUnsafeCurrentTask { $0?.cancel() }
                    do { try deliver(BLEFailure("local proof failure")); return "" }
                    catch { return error.localizedDescription }
                }
                let outcome = await task.value
                XCTAssertEqual(outcome, "", scenario)
            } else if scenario == "current" {
                XCTAssertThrowsError(try deliver(BLEFailure("local proof failure")), scenario) { error in
                    XCTAssertEqual((error as? BLEFailure)?.message, "local proof failure")
                }
            } else {
                XCTAssertNoThrow(try deliver(BLEFailure("local proof failure")), scenario)
            }
            let after = try run.device(run.a)
            XCTAssertEqual(after.pendingIdentity, before.pendingIdentity, scenario)
            XCTAssertEqual(after.taskIdentity, before.taskIdentity, scenario)
            XCTAssertEqual(after.identityError, before.identityError, scenario)
            XCTAssertFalse(after.allowDeviceTasks, scenario)
            XCTAssertEqual(run.store.testOwner(run.a), owner, scenario)
            XCTAssertEqual(run.store.testIdentityChannel(run.a), channel, scenario)
            XCTAssertEqual(run.store.testIdentityClient(run.a), client, scenario)
            XCTAssertEqual(run.store.testIdentityRevision(run.a), revision, scenario)
            XCTAssertEqual(run.store.status, status, scenario)
            XCTAssertEqual(run.statusMonitor.notifications, 0, scenario)
            XCTAssertEqual(run.defaults.reads, 0, scenario); XCTAssertEqual(run.defaults.writes, 0, scenario)
            XCTAssertFalse(run.adapter.commands.contains { if case .disconnect = $0 { return true }; return false }, scenario)
        }
    }

    @MainActor func testPowerOffBeforeManagerCallbackSuppressesHandshakeFailure() async throws {
        let run = try Run()
        defer { run.cleanup() }
        run.store.testRadioOn(); run.connect(run.a)
        let owner = run.store.testOwner(run.a), channel = run.store.testIdentityChannel(run.a)
        let revision = run.store.testIdentityRevision(run.a), status = run.store.status
        let transport = ControlledTransport()
        defer { transport.release() }
        transport.pausedOpcode = 1
        let task = try XCTUnwrap(run.store.testStartIdentityLinkHandshake(run.a, transport: transport))
        try await waitForHeld(transport)
        run.statusMonitor.status(run.store)
        run.adapter.commands.removeAll()
        // Only the fake physical state changes here; no manager callback is
        // invented or attributed to a platform operation.
        run.adapter.poweredOn = false
        transport.release(error: BLEFailure("obsolete handshake failure"))
        await task.value
        XCTAssertEqual(run.store.testOwner(run.a), owner)
        XCTAssertEqual(run.store.testIdentityChannel(run.a), channel)
        XCTAssertEqual(run.store.testIdentityRevision(run.a), revision)
        XCTAssertEqual(run.store.testPhase(run.a), "connected")
        XCTAssertEqual(run.store.status, status)
        XCTAssertEqual(run.statusMonitor.notifications, 0)
        XCTAssertFalse(run.adapter.commands.contains { if case .disconnect = $0 { return true }; return false })
    }

    @MainActor func testUnavailableManagerCannotPublishOldHandshakeFailure() async throws {
        let run = try Run()
        defer { run.cleanup() }
        run.store.testRadioOn(); run.connect(run.a)
        let transport = ControlledTransport()
        defer { transport.release() }
        transport.pausedOpcode = 1
        let task = try XCTUnwrap(run.store.testStartIdentityLinkHandshake(run.a, transport: transport))
        try await waitForHeld(transport)
        run.statusMonitor.status(run.store)
        run.adapter.commands.removeAll()
        run.store.testManagerState(.poweredOff)
        XCTAssertEqual(run.store.testPhase(run.a), "quarantined")
        XCTAssertEqual(run.store.status, "蓝牙不可用，状态：4")
        XCTAssertEqual(run.statusMonitor.notifications, 1)
        let revision = run.store.testIdentityRevision(run.a)
        transport.release(error: BLEFailure("obsolete handshake failure"))
        await task.value
        XCTAssertEqual(run.store.testPhase(run.a), "quarantined")
        XCTAssertEqual(run.store.status, "蓝牙不可用，状态：4")
        XCTAssertEqual(run.statusMonitor.notifications, 1)
        XCTAssertEqual(run.store.testIdentityRevision(run.a), revision)
        XCTAssertNil(run.store.testIdentityChannel(run.a)); XCTAssertNil(run.store.testIdentityClient(run.a))
        XCTAssertFalse(run.adapter.commands.contains { if case .disconnect = $0 { return true }; return false })
    }

    @MainActor func testHandshakeFailureRespectsReplacementAndStatusReentry() async throws {
        for scenario in ["current", "stale-client", "status-replacement"] {
            let run = try Run()
            defer { run.cleanup() }
            run.store.testRadioOn(); run.connect(run.a)
            let owner = try XCTUnwrap(run.store.testOwner(run.a))
            let channel = try XCTUnwrap(run.store.testIdentityChannel(run.a))
            let baseline = run.store.status
            let transport = ControlledTransport()
            defer { transport.release() }
            transport.pausedOpcode = 1
            let task = try XCTUnwrap(run.store.testStartIdentityLinkHandshake(run.a, transport: transport), scenario)
            try await waitForHeld(transport)
            if scenario == "stale-client" {
                run.store.testInstallIdentityClient(run.a, reuse: true)
                run.setPending(run.a, "legacy:new-generation")
            }
            let client = run.store.testIdentityClient(run.a)
            let revision = run.store.testIdentityRevision(run.a)
            if scenario == "status-replacement" {
                run.statusMonitor.onFirst = { run.store.testReplaceIdentityChannel(run.a) }
            }
            run.statusMonitor.status(run.store)
            run.adapter.commands.removeAll()
            transport.release(error: BLEFailure("controlled handshake failure"))
            await task.value
            XCTAssertEqual(run.store.testOwner(run.a), owner, scenario)
            let disconnects = run.adapter.commands.filter {
                if case .disconnect(let id) = $0 { return id == run.a }; return false
            }.count
            if scenario == "current" {
                XCTAssertEqual(run.statusMonitor.notifications, 1, scenario)
                XCTAssertEqual(run.store.status, "controlled handshake failure", scenario)
                XCTAssertEqual(run.store.testPhase(run.a), "closing", scenario)
                XCTAssertEqual(disconnects, 1, scenario)
            } else {
                XCTAssertEqual(run.store.status, baseline, scenario)
                XCTAssertEqual(run.store.testPhase(run.a), "connected", scenario)
                XCTAssertEqual(disconnects, 0, scenario)
                if scenario == "stale-client" {
                    XCTAssertEqual(run.statusMonitor.notifications, 0, scenario)
                    XCTAssertEqual(run.store.testIdentityClient(run.a), client, scenario)
                    XCTAssertEqual(run.store.testIdentityRevision(run.a), revision, scenario)
                    XCTAssertEqual(try run.device(run.a).pendingIdentity, "legacy:new-generation", scenario)
                } else {
                    XCTAssertEqual(run.statusMonitor.notifications, 1, scenario)
                    XCTAssertEqual(run.statusMonitor.actions, 1, scenario)
                    XCTAssertNotEqual(run.store.testIdentityChannel(run.a), channel, scenario)
                }
            }
        }
    }

    @MainActor func testChannelDiscoveryStopsOldNotifySubmissionsAfterReplacement() throws {
        for scenario in ["normal", "install-new", "install-same", "notify-new", "notify-same"] {
            let run = try Run()
            defer { run.cleanup() }
            run.store.testRadioOn(); run.connect(run.a)
            let owner = try XCTUnwrap(run.store.testOwner(run.a))
            let baseline = run.store.status
            let oldLinkState = try run.device(run.a).linkState
            run.adapter.commands.removeAll()
            run.statusMonitor.status(run.store)
            var actions = 0
            var replacementChannel: ObjectIdentifier?
            var replacementRevision: ObjectIdentifier?
            let replace: () -> Void = {
                actions += 1
                let previousChannel = run.store.testIdentityChannel(run.a)
                let previousRevision = run.store.testIdentityInstallationRevision(run.a)
                XCTAssertNotNil(previousChannel, scenario)
                XCTAssertNotNil(previousRevision, scenario)
                if scenario.hasSuffix("-same") { run.store.testReinstallCurrentIdentityChannel(run.a) }
                else { run.store.testReplaceIdentityChannel(run.a) }
                replacementChannel = run.store.testIdentityChannel(run.a)
                replacementRevision = run.store.testIdentityInstallationRevision(run.a)
                XCTAssertNotNil(replacementChannel, scenario)
                if scenario.hasSuffix("-same") { XCTAssertEqual(replacementChannel, previousChannel, scenario) }
                else { XCTAssertNotEqual(replacementChannel, previousChannel, scenario) }
                XCTAssertNotEqual(replacementRevision, previousRevision, scenario)
            }
            if scenario.hasPrefix("install-") {
                run.devicesMonitor.onFirst = replace
                run.devicesMonitor.devices(run.store)
            } else if scenario.hasPrefix("notify-") {
                run.adapter.afterNotify = { id in
                    guard id == run.a, actions == 0 else { return }
                    replace()
                }
            }
            // This is the shared production discovery-to-channel/notify
            // path; only CB identities and physical submissions are faked.
            let endpoints = try XCTUnwrap(run.store.testDiscoverIdentityChannelAndNotify(run.a), scenario)
            XCTAssertNotEqual(endpoints.tx, endpoints.audio, scenario)
            let notifications = run.adapter.commands.filter {
                if case .notify(let id) = $0 { return id == run.a }; return false
            }.count
            let expected = scenario == "normal" ? 2 : (scenario.hasPrefix("notify-") ? 1 : 0)
            XCTAssertEqual(notifications, expected, scenario)
            let expectedEndpoints: [ObjectIdentifier] = scenario == "normal" ? [endpoints.tx, endpoints.audio]
                : (scenario.hasPrefix("notify-") ? [endpoints.tx] : [])
            XCTAssertEqual(run.adapter.notifyEndpoints, expectedEndpoints, scenario)
            XCTAssertEqual(actions, scenario == "normal" ? 0 : 1, scenario)
            XCTAssertEqual(run.store.testOwner(run.a), owner, scenario)
            XCTAssertEqual(run.store.testPhase(run.a), "connected", scenario)
            XCTAssertEqual(run.store.status, baseline, scenario)
            XCTAssertEqual(run.statusMonitor.notifications, 0, scenario)
            XCTAssertFalse(run.adapter.commands.contains { if case .disconnect = $0 { return true }; return false }, scenario)
            if scenario == "normal" {
                XCTAssertEqual(try run.device(run.a).linkState, "等待加密、绑定与订阅", scenario)
            } else {
                XCTAssertEqual(run.store.testIdentityChannel(run.a), replacementChannel, scenario)
                XCTAssertEqual(run.store.testIdentityInstallationRevision(run.a), replacementRevision, scenario)
                XCTAssertEqual(try run.device(run.a).linkState, oldLinkState, scenario)
            }
            if scenario.hasPrefix("install-") {
                XCTAssertEqual(run.devicesMonitor.actions, 1, scenario)
                XCTAssertLessThanOrEqual(run.devicesMonitor.notifications, 8, scenario)
            }
        }
    }

    @MainActor func testReinstalledSameChannelRejectsOldCallbacks() async throws {
        let run = try Run()
        defer { run.cleanup() }
        run.store.testRadioOn(); run.connect(run.a)
        let deviceID = "ce6ec956-1111-4222-8333-123456789abc"
        run.store.testPrepareLink(run.a, bootID: 0, deviceID: deviceID)
        let owner = try XCTUnwrap(run.store.testOwner(run.a))
        let channel = try XCTUnwrap(run.store.testIdentityChannel(run.a))
        let oldRevision = try XCTUnwrap(run.store.testIdentityInstallationRevision(run.a))
        let oldFailure = try XCTUnwrap(run.store.testCaptureIdentityChannelFailure(run.a))
        let oldEvent = try XCTUnwrap(run.store.testCaptureIdentityChannelEvent(run.a))
        run.store.testReinstallCurrentIdentityChannel(run.a)
        let newRevision = try XCTUnwrap(run.store.testIdentityInstallationRevision(run.a))
        XCTAssertNotEqual(oldRevision, newRevision)
        XCTAssertEqual(run.store.testIdentityChannel(run.a), channel)
        let newFailure = try XCTUnwrap(run.store.testCaptureIdentityChannelFailure(run.a))
        let newEvent = try XCTUnwrap(run.store.testCaptureIdentityChannelEvent(run.a))
        // Re-establish the new installation's boot/device data through the
        // real client and tools/list; never write store internals directly.
        let transport = ControlledTransport()
        defer { transport.release() }
        let client = PDSHLinkClient(transport: transport)
        let peer = try await client.handshake()
        try await run.store.discoverLinkTools(run.a, client: client, bootID: peer.bootID) {
            run.store.testOwner(run.a) == owner && run.store.testIdentityChannel(run.a) == channel &&
            run.store.testIdentityInstallationRevision(run.a) == newRevision
        }
        let payload = Data("{\"boot_id\":0,\"device_id\":\"\(deviceID)\",\"event_id\":\"00000000-00000001\",\"seq\":1,\"type\":\"status\",\"payload\":{}}".utf8)
        run.adapter.commands.removeAll()
        oldFailure(); oldEvent(payload)
        XCTAssertEqual(run.store.testOwner(run.a), owner)
        XCTAssertEqual(run.store.testIdentityChannel(run.a), channel)
        XCTAssertEqual(run.store.testIdentityInstallationRevision(run.a), newRevision)
        XCTAssertEqual(run.store.testPhase(run.a), "connected")
        XCTAssertEqual(run.store.testLinkDeliveries(run.a), 0)
        XCTAssertFalse(run.adapter.commands.contains { if case .disconnect = $0 { return true }; return false })
        newEvent(payload)
        XCTAssertEqual(run.store.testLinkDeliveries(run.a), 1)
        newFailure()
        XCTAssertEqual(run.store.testPhase(run.a), "closing")
        XCTAssertEqual(run.adapter.commands.filter { if case .disconnect(let id) = $0 { return id == run.a }; return false }.count, 1)
    }

    @MainActor func testReplacedChannelCallbacksCannotAffectCurrentChannel() throws {
        let run = try Run()
        defer { run.cleanup() }
        run.store.testRadioOn(); run.connect(run.a)
        let deviceID = "ce6ec956-1111-4222-8333-123456789abc"
        run.store.testPrepareLink(run.a, bootID: 1, deviceID: deviceID)
        let originalOwner = try XCTUnwrap(run.store.testOwner(run.a))
        let originalChannel = try XCTUnwrap(run.store.testIdentityChannel(run.a))
        // The seam retains the actual old channel and invokes its original
        // callbacks; a deallocated weak capture must not make this pass.
        let oldFailure = try XCTUnwrap(run.store.testCaptureIdentityChannelFailure(run.a))
        let oldEvent = try XCTUnwrap(run.store.testCaptureIdentityChannelEvent(run.a))
        run.adapter.commands.removeAll()
        run.store.testPrepareLink(run.a, bootID: 1, deviceID: deviceID)
        let newChannel = try XCTUnwrap(run.store.testIdentityChannel(run.a))
        XCTAssertNotEqual(originalChannel, newChannel)
        XCTAssertEqual(run.store.testOwner(run.a), originalOwner)
        XCTAssertEqual(run.store.testPhase(run.a), "connected")
        let newEvent = try XCTUnwrap(run.store.testCaptureIdentityChannelEvent(run.a))
        let newFailure = try XCTUnwrap(run.store.testCaptureIdentityChannelFailure(run.a))
        let payload = Data("{\"boot_id\":1,\"device_id\":\"\(deviceID)\",\"event_id\":\"00000001-00000001\",\"seq\":1,\"type\":\"status\",\"payload\":{}}".utf8)
        oldFailure()
        oldEvent(payload)
        XCTAssertEqual(run.store.testOwner(run.a), originalOwner)
        XCTAssertEqual(run.store.testIdentityChannel(run.a), newChannel)
        XCTAssertEqual(run.store.testPhase(run.a), "connected")
        XCTAssertEqual(run.store.testLinkDeliveries(run.a), 0)
        XCTAssertFalse(run.adapter.commands.contains { if case .disconnect = $0 { return true }; return false })
        // Positive controls use those same production callbacks on the live
        // channel: event is delivered and failure performs one real submission.
        newEvent(payload)
        XCTAssertEqual(run.store.testLinkDeliveries(run.a), 1)
        newFailure()
        XCTAssertEqual(run.store.testPhase(run.a), "closing")
        XCTAssertEqual(run.adapter.commands.filter { if case .disconnect(let id) = $0 { return id == run.a }; return false }.count, 1)
    }

    @MainActor func testSharedObservationVectors() throws {
        let vectors = try rows("legacy-identity-observation")
        XCTAssertEqual(vectors.count, 40)
        XCTAssertEqual(Set(vectors.compactMap { $0["id"] as? String }).count, vectors.count)
        for row in vectors {
            let id = try XCTUnwrap(row["id"] as? String)
            let action = try XCTUnwrap(row["action"] as? String)
            let hook = try XCTUnwrap(row["hook"] as? String)
            let pending = try XCTUnwrap(row["pending"] as? String)
            let bInitial = try XCTUnwrap(row["b_initial"] as? String)
            let proof = try XCTUnwrap(row["proof_result"] as? String)
            let run = try Run()
            defer { run.cleanup() }
            run.store.testRadioOn()
            run.connect(run.a, installClient: action != "no-client")
            if !bInitial.isEmpty { run.connect(run.b); run.setPending(run.b, bInitial) }
            if !pending.isEmpty { run.setPending(run.a, pending) }
            run.defaults.backing.set(try XCTUnwrap(row["initial"]), forKey: BLETrustedIdentities.key)
            run.defaults.reads = 0; run.defaults.writes = 0
            XCTAssertEqual(run.store.status, row["status_before"] as? String, id)
            run.statusMonitor.status(run.store)
            run.hook = { do { try run.runAction(action, pending: pending) } catch { XCTFail("\(id): \(error)") } }
            if hook == "device-will-change" { run.devicesMonitor.onFirst = { run.fire() }; run.devicesMonitor.devices(run.store) }
            if hook == "initial-read" { run.defaults.beforeRead = { count in if count == 1 { run.fire() } } }
            if hook == "readback" { run.defaults.beforeRead = { count in if count == 2 { run.fire() } } }
            if hook == "set-before" { run.defaults.beforeSet = { run.fire() } }
            if hook == "set-after" { run.defaults.afterSet = { run.fire() } }
            run.defaults.maskReadback = action == "fail-readback"
            if !proof.isEmpty {
                let completion = try XCTUnwrap(run.store.testCaptureIdentityProof(run.a), id)
                if hook == "proof-completion" { run.fire() }
                completion(proof)
            } else {
                if hook == "precondition" { run.fire() }
                run.store.trustPendingIdentity(action == "missing-device" ? UUID() : run.a)
            }
            if action == "confirm-b-then-retry" { run.store.trustPendingIdentity(run.b) }
            let a = try run.device(run.a), b = try run.device(run.b)
            assertScalars(a.pendingIdentity, try XCTUnwrap(row["a_pending"] as? String), id)
            assertScalars(a.taskIdentity, try XCTUnwrap(row["a_recorded"] as? String), id)
            assertScalars(a.identityError, try XCTUnwrap(row["a_error"] as? String), id)
            assertScalars(b.pendingIdentity, try XCTUnwrap(row["b_pending"] as? String), id)
            assertScalars(b.taskIdentity, try XCTUnwrap(row["b_recorded"] as? String), id)
            assertScalars(b.identityError, try XCTUnwrap(row["b_error"] as? String), id)
            XCTAssertEqual(a.allowDeviceTasks, row["task_grant"] as? Bool, id)
            XCTAssertFalse(b.allowDeviceTasks, id)
            switch try XCTUnwrap(row["result"] as? String) {
            case "recorded": XCTAssertFalse(a.taskIdentity.isEmpty, id)
            case "error": XCTAssertFalse(a.identityError.isEmpty, id)
            case "proof-pending": XCTAssertFalse(a.pendingIdentity.isEmpty, id)
            case "no-op": XCTAssertTrue(a.taskIdentity.isEmpty && a.identityError.isEmpty, id)
            case "stale": break // Exact current fields and the lifecycle hook are asserted independently.
            default: XCTFail("Unknown fixture result: \(id)")
            }
            XCTAssertEqual(run.store.status, row["status_after"] as? String, id)
            XCTAssertEqual(run.defaults.reads, row["read_calls"] as? Int, id)
            XCTAssertEqual(run.defaults.writes, row["set_calls"] as? Int, id)
            XCTAssertEqual(run.hookFires, row["hook_fires"] as? Int, id)
            XCTAssertEqual(run.lifecycleActions, row["lifecycle_actions"] as? Int, id)
            XCTAssertEqual(run.lifecycleTransitions, row["lifecycle_transitions"] as? Int, id)
            XCTAssertEqual(run.statusMonitor.notifications, row["status_notifications"] as? Int, id)
            XCTAssertLessThanOrEqual(run.devicesMonitor.notifications, try XCTUnwrap(row["observation_calls_max"] as? Int), id)
            assertVisible(run.defaults.backing.object(forKey: BLETrustedIdentities.key), try XCTUnwrap(row["expected_preference"]), id)
            // Exercise the real task-grant boundary only after all fixture
            // measurements; it must reject and cannot invoke a target RPC.
            XCTAssertThrowsError(try run.store.grantDeviceTasks(run.a, enabled: true), id)
            XCTAssertFalse(try run.device(run.a).allowDeviceTasks, id)
        }
    }
}
#endif
