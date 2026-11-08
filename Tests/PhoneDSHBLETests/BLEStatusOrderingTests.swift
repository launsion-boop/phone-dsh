// SPDX-License-Identifier: MIT
import CoreBluetooth
import Foundation
import Observation
import XCTest
@testable import PhoneDSHBLE

#if DEBUG
/// The input is a local physical callback, never an invented OS request token.
final class BLEStatusOrderingTests: XCTestCase {
    private struct Injection: Decodable {
        let checkpoint: String
        let event: String
    }
    private struct Expected: Decodable {
        var status: String
        var phases: [String: String]
        var disconnects: [String: Int]
        var statusNotifications: Int?
        var other: String?
    }
    private struct Vector: Decodable {
        let id: String, setup: String, event: String
        let injections: [Injection]
        let expect: Expected
    }
    private struct Mutation: Decodable {
        let base: String
        let path: [String]
        let value: JSONValue
    }
    private enum JSONValue: Decodable {
        case string(String), integer(Int)
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self) { self = .string(string); return }
            self = .integer(try container.decode(Int.self))
        }
    }
    /// Observation unregisters an onChange after it returns. A synchronous
    /// nested mutation can invoke that same registration again while it is
    /// still on the stack. Consume each registration once; a new registration
    /// is installed before the nested action so its event is still observed.
    @MainActor private final class ObservationTicket {
        private var consumed = false
        func take() -> Bool {
            guard !consumed else { return false }
            consumed = true
            return true
        }
    }
    @MainActor private final class SameValueObserver {
        let store: BLEDeviceStore
        var calls = 0
        init(_ store: BLEDeviceStore) { self.store = store }
        func watch() {
            let ticket = ObservationTicket()
            withObservationTracking { _ = store.status } onChange: { [weak self] in
                MainActor.assumeIsolated {
                    guard ticket.take(), let self else { return }
                    self.calls += 1
                    guard self.calls < 8 else { XCTFail("same-value status recursively notified"); return }
                    self.watch()
                    self.store.testManagerState(.poweredOn)
                }
            }
        }
    }
    private var golden: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("spec/device/v1/golden")
    }
    private func lines<T: Decodable>(_ name: String, as type: T.Type) throws -> [T] {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try String(contentsOf: golden.appendingPathComponent(name), encoding: .utf8)
            .split(whereSeparator: \.isNewline).map { try decoder.decode(type, from: Data($0.utf8)) }
    }

    @MainActor private final class Run {
        static let ready = "蓝牙已就绪，请点击扫描"
        let ids: [String: UUID]
        let suite: String
        let defaults: UserDefaults
        let adapter: BLEDeviceStore.TestAdapter
        let store: BLEDeviceStore
        let vector: Vector
        var peers: [String: AnyObject] = [:]
        var deadlines: [String: BLEDeviceStore.TestTimerProbe] = [:]
        var tx: BLEDeviceStore.TestCharacteristic?
        var audio: BLEDeviceStore.TestCharacteristic?
        var baselineStatus = ""
        var stack: [String] = []
        var fired: [Int: Int] = [:]
        var statusNotifications = 0
        var physicalCountAtPowerOff: Int?
        var failure: Error?

        init(_ vector: Vector) throws {
            let ids: [String: UUID] = [
                "A": UUID(uuidString: "ce6ec956-1111-4222-8333-123456789abc")!,
                "B": UUID(uuidString: "ce6ec956-1111-4222-8333-123456789abd")!,
                "C": UUID(uuidString: "ce6ec956-1111-4222-8333-123456789abe")!,
            ]
            let suite = "PhoneDSH.StatusOrdering." + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let adapter = BLEDeviceStore.TestAdapter()
            self.vector = vector
            self.ids = ids; self.suite = suite; self.defaults = defaults; self.adapter = adapter
            adapter.identityDefaults = defaults
            store = BLEDeviceStore(testAdapter: adapter, testDevices: ids.map {
                BLEDeviceStore.Device(id: $0.value, name: $0.key, rssi: -40)
            })
            for (name, id) in ids { peers[name] = try XCTUnwrap(store.testPhysicalPeer(id)) }
        }
        func cleanup() { defaults.removePersistentDomain(forName: suite) }
        func error(_ text: String) -> NSError {
            NSError(domain: "status-order.fixture", code: 17, userInfo: [NSLocalizedDescriptionKey: text])
        }
        func id(_ name: String) throws -> UUID { try XCTUnwrap(ids[name]) }
        func peer(_ name: String) throws -> AnyObject { try XCTUnwrap(peers[name]) }
        func device(_ name: String) throws -> BLEDeviceStore.Device {
            let target = try id(name)
            return try XCTUnwrap(store.devices.first { $0.id == target })
        }
        func connect(_ name: String) throws {
            let target = try id(name)
            store.connect(target)
            let timer = try XCTUnwrap(store.testCaptureConnectionTimeout(target))
            XCTAssertEqual(timer.state, "active", vector.id)
            deadlines[name] = timer
            store.testDidConnect(target)
            XCTAssertEqual(store.testPhase(target), "connected", vector.id)
            XCTAssertTrue(adapter.discoverySubmissions.contains { $0.id == target && $0.service == nil }, vector.id)
            store.grant(target, read: true, alert: true)
            let value = try device(name)
            XCTAssertTrue(value.allowRead, vector.id); XCTAssertTrue(value.allowAlert, vector.id)
        }
        func setup() throws {
            store.testRadioOn()
            if vector.setup == "ab-discovering-status-prior" {
                try connect("C")
                store.testDiscoveryServices(try id("C"), peer: try peer("C"), services: nil, error: error("PRIOR"))
                XCTAssertEqual(store.status, "PRIOR", vector.id)
            }
            try connect("A"); try connect("B")
            if vector.setup == "abc-discovering" { try connect("C") }
            if vector.setup == "a-closing-b-discovering" {
                store.disconnect(try id("A"))
                XCTAssertEqual(store.testPhase(try id("A")), "closing", vector.id)
            }
            if vector.setup == "a-link-b-discovering" { try prepareLink() }
            baselineStatus = store.status
            XCTAssertEqual(baselineStatus, vector.setup == "ab-discovering-status-prior" ? "PRIOR" : Self.ready, vector.id)
            adapter.commands.removeAll(); adapter.discoverySubmissions.removeAll(); adapter.notifyEndpoints.removeAll()
            observeStatus()
            if vector.injections.contains(where: { $0.checkpoint == "a-close-devices-will-change" }) { observeDevices() }
        }
        func prepareLink() throws {
            let physical = try peer("A"), target = try id("A")
            let service = BLEDeviceStore.TestService(parent: physical, uuid: PDSHLink.service)
            let rx = BLEDeviceStore.TestCharacteristic(parent: service, uuid: PDSHLink.rx, properties: [.write])
            let tx = BLEDeviceStore.TestCharacteristic(parent: service, uuid: PDSHLink.tx, properties: [.notify])
            let audio = BLEDeviceStore.TestCharacteristic(parent: service, uuid: PDSHLink.audioUp, properties: [.notify])
            store.testDiscoveryServices(target, peer: physical, services: [service])
            store.testDiscoveryCharacteristics(target, peer: physical, service: service, characteristics: [rx, tx, audio])
            let installed = try XCTUnwrap(store.testDiscoveryLinkEndpoints(target))
            XCTAssertTrue(installed.service === service && installed.rx === rx && installed.tx === tx && installed.audio === audio, vector.id)
            XCTAssertNotNil(store.testIdentityChannel(target), vector.id)
            self.tx = tx; self.audio = audio
        }
        func observeStatus() {
            let ticket = ObservationTicket()
            withObservationTracking { _ = store.status } onChange: { [weak self] in
                MainActor.assumeIsolated {
                    guard ticket.take(), let self else { return }
                    self.statusNotifications += 1
                    guard self.statusNotifications <= 12 else { XCTFail("unbounded status reentry: \(self.vector.id)"); return }
                    self.observeStatus()
                    let event = self.stack.last ?? ""
                    let prefix = event == "manager-powered-on" ? "manager" : (event.hasPrefix("a-") ? "a" : (event.hasPrefix("b-") ? "b" : "c"))
                    self.inject("\(prefix)-status-will-change")
                }
            }
        }
        func observeDevices() {
            withObservationTracking { _ = store.devices } onChange: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.stack.last == "a-error-a" { self.inject("a-close-devices-will-change") }
                }
            }
        }
        func inject(_ checkpoint: String) {
            for (index, item) in vector.injections.enumerated() where item.checkpoint == checkpoint && fired[index, default: 0] == 0 {
                fired[index, default: 0] += 1
                do { try deliver(item.event) } catch { failure = error; XCTFail("\(vector.id) nested: \(error)") }
            }
        }
        func deliver(_ event: String) throws {
            stack.append(event); defer { stack.removeLast() }
            switch event {
            case "a-error-a", "a-stale-error-a":
                store.testDiscoveryServices(try id("A"), peer: try peer("A"), services: nil, error: error("A"))
            case "b-error-b", "b-error-ready":
                store.testDiscoveryServices(try id("B"), peer: try peer("B"), services: nil, error: error(event == "b-error-ready" ? Self.ready : "B"))
            case "c-error-a":
                store.testDiscoveryServices(try id("C"), peer: try peer("C"), services: nil, error: error("A"))
            case "a-discovery-timeout":
                let timer = try XCTUnwrap(deadlines["A"]); XCTAssertEqual(timer.state, "active", vector.id); timer.invoke()
            case "a-link-notification-error-a":
                store.testDiscoveryNotification(try id("A"), peer: try peer("A"), characteristic: try XCTUnwrap(tx), notifying: false, error: error("A"))
            case "manager-powered-on": store.testManagerState(.poweredOn)
            case "physical-power-off": physicalCountAtPowerOff = adapter.commands.count; adapter.poweredOn = false
            default: throw BLEFailure("unknown status event \(event)")
            }
        }
        func observed() throws -> Expected {
            let status: String
            switch store.status { case Self.ready: status = "READY"; case "A", "B", "PRIOR": status = store.status; default: status = "unexpected:\(store.status)" }
            var phases: [String: String] = [:], disconnects: [String: Int] = [:]
            for name in vector.expect.phases.keys {
                let target = try id(name), phase = store.testPhase(target)
                phases[name] = phase
                disconnects[name] = adapter.commands.filter { if case .disconnect(let peer) = $0 { return peer == target }; return false }.count
                let value = try device(name)
                let allowed = phase == "connected"
                XCTAssertEqual(value.allowRead, allowed, "\(vector.id) \(name) read")
                XCTAssertEqual(value.allowAlert, allowed, "\(vector.id) \(name) alert")
                XCTAssertEqual(store.testDeclarations(target).read, allowed)
                XCTAssertEqual(store.testDeclarations(target).alert, allowed)
                XCTAssertFalse(value.allowDeviceTasks); XCTAssertFalse(value.supportsDeviceTasks)
            }
            var other: String?
            switch vector.expect.other {
            case "all-owner-unavailable":
                if phases["A"] == "quarantined", phases["B"] == "quarantined",
                   deadlines["A"]?.state == "cancelled", deadlines["B"]?.state == "cancelled",
                   let count = physicalCountAtPowerOff, adapter.commands.count == count,
                   store.testIdentityChannel(try id("A")) == nil, store.testIdentityChannel(try id("B")) == nil { other = "all-owner-unavailable" }
            case "a-timeout-teardown":
                if deadlines["A"]?.state == "cancelled", disconnects["A"] == 1 { other = "a-timeout-teardown" }
            case "a-link-teardown":
                if store.testIdentityChannel(try id("A")) == nil, store.testDiscoveryRawLinkStorageEmpty(try id("A")), adapter.notifyEndpoints.isEmpty { other = "a-link-teardown" }
            case nil: break
            default: throw BLEFailure("unknown supplemental check")
            }
            return Expected(status: status, phases: phases, disconnects: disconnects,
                            statusNotifications: vector.expect.statusNotifications == nil ? nil : statusNotifications, other: other)
        }
    }

    private func matches(_ actual: Expected, _ expected: Expected) -> Bool {
        actual.status == expected.status && actual.phases == expected.phases && actual.disconnects == expected.disconnects &&
        actual.statusNotifications == expected.statusNotifications && actual.other == expected.other
    }
    private func mutate(_ expected: Expected, _ mutation: Mutation) throws -> Expected {
        var changed = expected
        switch mutation.value {
        case .string(let value):
            if mutation.path == ["status"] { changed.status = value }
            else if mutation.path.count == 2, mutation.path[0] == "phases" { changed.phases[mutation.path[1]] = value }
            else { throw BLEFailure("unknown status mutation path: \(mutation.path)") }
        case .integer(let value):
            if mutation.path == ["status_notifications"] { changed.statusNotifications = value }
            else if mutation.path.count == 2, mutation.path[0] == "disconnects" { changed.disconnects[mutation.path[1]] = value }
            else { throw BLEFailure("unknown status mutation path: \(mutation.path)") }
        }
        return changed
    }
    @MainActor func testFrozenVectorsAndAllSemanticMutations() throws {
        let vectors = try lines("standard-gatt-status-order.jsonl", as: Vector.self)
        let mutations = try lines("standard-gatt-status-mutations.jsonl", as: Mutation.self)
        XCTAssertEqual(vectors.count, 10); XCTAssertEqual(mutations.count, 10)
        var observed: [String: Expected] = [:]
        for vector in vectors {
            let run = try Run(vector); defer { run.cleanup() }
            try run.setup(); try run.deliver(vector.event)
            if let error = run.failure { throw error }
            XCTAssertEqual(run.fired.count, vector.injections.count, "missing injection: \(vector.id)")
            XCTAssertTrue(run.fired.values.allSatisfy { $0 == 1 }, vector.id)
            let actual = try run.observed(); observed[vector.id] = actual
            XCTAssertTrue(matches(actual, vector.expect), "\(vector.id): actual=\(actual), expected=\(vector.expect)")
        }
        for mutation in mutations {
            let original = try XCTUnwrap(vectors.first { $0.id == mutation.base })
            let actual = try XCTUnwrap(observed[mutation.base])
            let changed = try mutate(original.expect, mutation)
            XCTAssertTrue(matches(actual, original.expect), "original failed: \(mutation.base)")
            XCTAssertFalse(matches(actual, changed), "actual comparator accepted mutation \(mutation.base) \(mutation.path)")
        }
    }

    @MainActor private func freshRun(_ setup: String = "ab-discovering") throws -> Run {
        let vector = Vector(id: "focused", setup: setup, event: "a-error-a", injections: [],
                            expect: Expected(status: "A", phases: ["A": "connected", "B": "connected"],
                                             disconnects: ["A": 0, "B": 0], statusNotifications: nil, other: nil))
        let run = try Run(vector); try run.setup(); return run
    }

    @MainActor func testStaleConnectFailureCannotStealIntentButStillQuarantines() throws {
        let run = try freshRun(); defer { run.cleanup() }
        let a = try run.id("A"), b = try run.id("B"), aPeer = try run.peer("A")
        run.store.disconnect(b)
        XCTAssertEqual(run.store.testPhase(b), "closing")
        run.adapter.commands.removeAll()
        var fired = 0
        withObservationTracking { _ = run.store.status } onChange: {
            MainActor.assumeIsolated {
                guard fired == 0 else { return }
                fired += 1
                run.store.testDidFail(b, error: run.error("STALE"))
            }
        }
        run.store.testDiscoveryServices(a, peer: aPeer, services: nil, error: run.error("A"))
        XCTAssertEqual(fired, 1)
        XCTAssertEqual(run.store.status, "A")
        XCTAssertEqual(run.store.testPhase(a), "closing")
        XCTAssertEqual(run.store.testPhase(b), "quarantined")
        XCTAssertEqual(run.adapter.commands.filter { $0 == .disconnect(a) }.count, 1)
        XCTAssertEqual(run.adapter.commands.filter { $0 == .disconnect(b) }.count, 0)
    }

    @MainActor func testSubmittedConnectingFailureWinsAsNewIntent() throws {
        let a = UUID(), b = UUID(), adapter = BLEDeviceStore.TestAdapter()
        let store = BLEDeviceStore(testAdapter: adapter, testDevices: [.init(id: a, name: "A", rssi: -40), .init(id: b, name: "B", rssi: -40)])
        store.testRadioOn(); store.connect(a); store.testDidConnect(a)
        let peer = try XCTUnwrap(store.testPhysicalPeer(a))
        store.connect(b)
        XCTAssertEqual(store.testPhase(b), "connecting")
        XCTAssertTrue(adapter.commands.contains(.connect(b)))
        adapter.commands.removeAll()
        var fired = 0
        let aError = NSError(domain: "status-focused", code: 1, userInfo: [NSLocalizedDescriptionKey: "A"])
        let bError = NSError(domain: "status-focused", code: 2, userInfo: [NSLocalizedDescriptionKey: "B"])
        withObservationTracking { _ = store.status } onChange: {
            MainActor.assumeIsolated { guard fired == 0 else { return }; fired += 1; store.testDidFail(b, error: bError) }
        }
        store.testDiscoveryServices(a, peer: peer, services: nil, error: aError)
        XCTAssertEqual(fired, 1)
        XCTAssertEqual(store.status, "B")
        XCTAssertEqual(store.testPhase(a), "closing")
        XCTAssertEqual(store.testPhase(b), "quarantined")
        XCTAssertEqual(adapter.commands.filter { $0 == .disconnect(a) }.count, 1)
        XCTAssertEqual(adapter.commands.filter { $0 == .disconnect(b) }.count, 0)
    }

    @MainActor func testSameValueIntentIsSilentButInvalidatesPendingText() throws {
        let run = try freshRun(); defer { run.cleanup() }
        let b = try run.id("B"), bPeer = try run.peer("B")
        let observer = SameValueObserver(run.store); observer.watch()
        run.store.testManagerState(.poweredOn)
        XCTAssertEqual(observer.calls, 0, "same current status must not recursively notify")
        run.store.testDiscoveryServices(b, peer: bPeer, services: nil, error: run.error("B"))
        XCTAssertEqual(observer.calls, 1)
        XCTAssertEqual(run.statusNotifications, 1)
        XCTAssertEqual(run.store.status, Run.ready)
        XCTAssertEqual(run.store.testPhase(b), "closing")
        XCTAssertEqual(run.adapter.commands.filter { $0 == .disconnect(b) }.count, 1)
    }

    @MainActor func testScanStatusLosesWithoutSkippingScan() throws {
        let run = try freshRun(); defer { run.store.stopScan(); run.cleanup() }
        let b = try run.id("B"), bPeer = try run.peer("B")
        var fired = 0
        withObservationTracking { _ = run.store.status } onChange: {
            MainActor.assumeIsolated {
                guard fired == 0 else { return }
                fired += 1
                run.store.testDiscoveryServices(b, peer: bPeer, services: nil, error: run.error("B"))
            }
        }
        run.store.scan()
        XCTAssertEqual(fired, 1)
        XCTAssertEqual(run.store.status, "B")
        XCTAssertTrue(run.store.scanning)
        XCTAssertEqual(run.adapter.commands.filter { $0 == .scan }.count, 1)
        XCTAssertEqual(run.adapter.commands.filter { $0 == .disconnect(b) }.count, 1)
    }

    @MainActor func testScanInitializationAndUnavailableManagerUseRealAdmission() throws {
        let adapter = BLEDeviceStore.TestAdapter(), store = BLEDeviceStore(testAdapter: adapter, testDevices: [])
        adapter.managerInitialized = false
        store.scan()
        XCTAssertTrue(adapter.managerInitialized)
        XCTAssertEqual(store.status, "正在初始化蓝牙")
        XCTAssertFalse(store.scanning)
        XCTAssertFalse(adapter.commands.contains(.scan))
        adapter.poweredOn = false; adapter.managerState = .poweredOff
        store.scan()
        XCTAssertEqual(store.status, "请在系统设置中开启蓝牙并授权")
        XCTAssertFalse(store.scanning)
        XCTAssertFalse(adapter.commands.contains(.scan))
    }

    @MainActor func testNotificationErrorCannotCloseReinstalledSameChannel() throws {
        let run = try freshRun("a-link-b-discovering"); defer { run.cleanup() }
        let a = try run.id("A"), physical = try run.peer("A"), tx = try XCTUnwrap(run.tx)
        let channel = try XCTUnwrap(run.store.testIdentityChannel(a))
        let installation = try XCTUnwrap(run.store.testIdentityInstallationRevision(a))
        let endpoints = try XCTUnwrap(run.store.testDiscoveryLinkEndpoints(a))
        var fired = 0
        withObservationTracking { _ = run.store.status } onChange: {
            MainActor.assumeIsolated {
                guard fired == 0 else { return }
                fired += 1
                run.store.testReinstallCurrentIdentityChannel(a)
            }
        }
        run.store.testDiscoveryNotification(a, peer: physical, characteristic: tx, notifying: false, error: run.error("A"))
        XCTAssertEqual(fired, 1)
        XCTAssertEqual(run.store.status, Run.ready)
        XCTAssertEqual(run.store.testPhase(a), "connected")
        XCTAssertEqual(run.store.testIdentityChannel(a), channel, "same physical channel object must be reinstalled")
        XCTAssertNotEqual(run.store.testIdentityInstallationRevision(a), installation, "installation identity must change")
        let retained = try XCTUnwrap(run.store.testDiscoveryLinkEndpoints(a))
        XCTAssertTrue(retained.service === endpoints.service && retained.rx === endpoints.rx && retained.tx === endpoints.tx && retained.audio === endpoints.audio)
        XCTAssertFalse(run.adapter.commands.contains(.disconnect(a)))
    }

    @MainActor func testCurrentNotificationErrorStillPublishesAndDisconnects() throws {
        let run = try freshRun("a-link-b-discovering"); defer { run.cleanup() }
        let a = try run.id("A"), physical = try run.peer("A"), tx = try XCTUnwrap(run.tx)
        XCTAssertNotNil(run.store.testIdentityChannel(a))
        run.store.testDiscoveryNotification(a, peer: physical, characteristic: tx, notifying: false, error: run.error("A"))
        XCTAssertEqual(run.store.status, "A")
        XCTAssertEqual(run.store.testPhase(a), "closing")
        XCTAssertNil(run.store.testIdentityChannel(a))
        XCTAssertEqual(run.adapter.commands.filter { $0 == .disconnect(a) }.count, 1)
    }

    @MainActor func testRealHandshakeFailureLosesStatusButClosesChannel() async throws {
        let run = try freshRun("a-link-b-discovering"); defer { run.adapter.onLinkWrite = nil; run.cleanup() }
        let a = try run.id("A"), b = try run.id("B"), aPeer = try run.peer("A"), bPeer = try run.peer("B")
        let endpoints = try XCTUnwrap(run.store.testDiscoveryLinkEndpoints(a))
        let tx = try XCTUnwrap(run.tx), audio = try XCTUnwrap(run.audio)
        var decoder = PDSHLink.Reassembler(), transportError: Error?, delivered = false, fired = 0
        run.adapter.onLinkWrite = { id, bytes in
            guard id == a else { return }
            do {
                let frame = try decoder.push(bytes)
                let response = try frame.map { try PDSHLink.Envelope(opcode: 0xff, requestID: $0.requestID, body: Data([1])).segments(writeLimit: 20) }
                Task { @MainActor in
                    run.store.testLinkWriteComplete(a, physical: aPeer, endpoint: endpoints.rx, error: nil)
                    if let response {
                        delivered = true
                        for part in response { run.store.testLinkSegment(a, physical: aPeer, endpoint: endpoints.tx, data: part) }
                    }
                }
            } catch { transportError = error }
        }
        withObservationTracking { _ = run.store.status } onChange: {
            MainActor.assumeIsolated {
                guard fired == 0 else { return }
                fired += 1
                run.store.testDiscoveryServices(b, peer: bPeer, services: nil, error: run.error("B"))
            }
        }
        run.store.testDiscoveryNotification(a, peer: aPeer, characteristic: tx, notifying: true)
        run.store.testDiscoveryNotification(a, peer: aPeer, characteristic: audio, notifying: true)
        for _ in 0..<400 {
            if run.store.testPhase(a) == "closing" || transportError != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        if let transportError { throw transportError }
        XCTAssertTrue(delivered, "NAK must traverse actual Link physical transport")
        XCTAssertEqual(fired, 1)
        XCTAssertEqual(run.store.status, "B")
        XCTAssertEqual(run.store.testPhase(a), "closing")
        XCTAssertEqual(run.store.testPhase(b), "closing")
        XCTAssertNil(run.store.testIdentityChannel(a))
        XCTAssertEqual(run.adapter.commands.filter { $0 == .disconnect(a) }.count, 1)
        XCTAssertEqual(run.adapter.commands.filter { $0 == .disconnect(b) }.count, 1)
    }
}
#endif
