// SPDX-License-Identifier: MIT
import CoreBluetooth
import CoreFoundation
import Foundation
import Observation
import PhoneDSHAgentCore
import XCTest
@testable import PhoneDSHBLE

#if DEBUG
/// Frozen local deadline ordering exercised through real store paths. A physical
/// object in this adapter is not a CoreBluetooth callback-attribution token.
final class StandardGattDiscoveryDeadlineTests: XCTestCase {
    @MainActor private final class PhysicalPeer {
        let id: UUID
        let deviceID: String
        unowned let store: BLEDeviceStore
        let tx: AnyObject, rx: AnyObject, physical: AnyObject
        var decoder = PDSHLink.Reassembler()
        var upload = Data(), result = Data()
        var resultRequest: UUID?
        var holdNextQuery = false, holdNextAck = false
        var heldAck: (() -> Void)?
        var writeCount = 0
        var heldResponse: [Data]?
        var failed: Error?
        var submittedOpcodes: [UInt8] = []
        init(id: UUID, store: BLEDeviceStore, physical: AnyObject, tx: AnyObject, rx: AnyObject) {
            self.id = id; self.deviceID = id.uuidString.lowercased(); self.store = store; self.physical = physical; self.tx = tx; self.rx = rx
        }
        func wrote(_ data: Data) {
            writeCount += 1
            do {
                let frame = try decoder.push(data)
                let response = try frame.map(makeResponse)
                let acknowledge = {
                    self.store.testLinkWriteComplete(self.id, physical: self.physical, endpoint: self.rx, error: nil)
                    guard let frame, let response else { return }
                    do {
                        let segments = try PDSHLink.Envelope(opcode: frame.opcode | 0x80,
                                                             requestID: frame.requestID, body: response).segments(writeLimit: 20)
                        if frame.opcode == 0x56 && self.holdNextQuery {
                            self.holdNextQuery = false; self.heldResponse = segments
                        } else { for segment in segments { self.store.testLinkSegment(self.id, physical: self.physical, endpoint: self.tx, data: segment) } }
                    } catch { self.failed = error }
                }
                if holdNextAck { holdNextAck = false; heldAck = acknowledge }
                else { Task { @MainActor in acknowledge() } }
            } catch { failed = error }
        }
        func makeResponse(_ frame: PDSHLink.Envelope) throws -> Data {
            submittedOpcodes.append(frame.opcode)
            let bytes = [UInt8](frame.body)
            switch frame.opcode {
            case 1:
                var ack = Data(repeating: 0, count: 25)
                ack[1] = 2; ack[2] = 1; ack[5] = 0x10; ack[19] = 1; ack[24] = 2
                ack.append(contentsOf: Array("PDSH".utf8) + [1, 0, 0, 16]); return ack
            case 0x54:
                guard bytes.count >= 24, Int(bytes.u16(18)) == upload.count else { throw BLEFailure("bad physical upload") }
                upload.append(frame.body.dropFirst(24))
                var reply = Data([0]); reply.put(UInt16(upload.count)); return reply
            case 0x55:
                let request = try JSONValue.parse(upload)
                guard request["name"]?.stringValue == "tools/list", let id = request["request_id"]?.stringValue else { throw BLEFailure("unexpected physical RPC") }
                result = try JSONValue.object(["request_id": .string(id), "status": .string("completed"),
                    "result": .object(["device_id": .string(deviceID),
                        "boot_id": .number(1), "tools": .array([.object(["name": .string("light.get")])])])]).encoded()
                upload.removeAll(); return Data([0, 1])
            case 0x56:
                guard bytes.count >= 18 else { throw BLEFailure("short physical query") }
                if let resultRequest {
                    result = try JSONValue.object(["request_id": .string(resultRequest.uuidString.lowercased()),
                        "status": .string("completed"), "result": .object(["value": .number(42)])]).encoded()
                }
                let offset = Int(bytes.u16(16))
                guard offset < result.count else { throw BLEFailure("bad physical query offset") }
                var reply = Data([0, 2]); reply.put(UInt16(result.count)); reply.put(UInt16(offset))
                reply.append(result[offset..<min(offset + 499, result.count)]); return reply
            default: throw BLEFailure("unexpected physical opcode")
            }
        }
        func deliverHeld() {
            let frames = heldResponse ?? []; heldResponse = nil
            for frame in frames { store.testLinkSegment(id, physical: physical, endpoint: tx, data: frame) }
        }
    }

    private var golden: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("spec/device/v1/golden")
    }
    private func lines(_ name: String) throws -> [[String: Any]] {
        try String(contentsOf: golden.appendingPathComponent(name), encoding: .utf8)
            .split(whereSeparator: \.isNewline).map {
                try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
            }
    }
    private func same(_ a: Any, _ b: Any) -> Bool {
        if let a = a as? String, let b = b as? String { return a.unicodeScalars.elementsEqual(b.unicodeScalars) }
        if let a = a as? [Any], let b = b as? [Any] { return a.count == b.count && zip(a, b).allSatisfy { same($0.0, $0.1) } }
        if let a = a as? [String: Any], let b = b as? [String: Any] {
            return a.count == b.count && a.allSatisfy { key, value in b[key].map { same(value, $0) } ?? false }
        }
        if a is NSNull, b is NSNull { return true }
        guard let a = a as? NSNumber, let b = b as? NSNumber else { return false }
        return (CFGetTypeID(a) == CFBooleanGetTypeID()) == (CFGetTypeID(b) == CFBooleanGetTypeID()) && a == b
    }
    private func matches(_ actual: [String: Any], _ expected: [String: Any]) -> Bool {
        expected.allSatisfy { key, value in actual[key].map { same($0, value) } ?? false }
    }
    func testComparatorRejectsTypeConfusion() {
        XCTAssertFalse(same(true, 1)); XCTAssertFalse(same(false, 0)); XCTAssertFalse(same("é", "e\u{301}"))
        XCTAssertFalse(same("1", ["1"])); XCTAssertFalse(same(NSNull(), ["x": 1]))
        XCTAssertTrue(same(["x": [1, 2], "b": true], ["x": [1, 2], "b": true]))
    }

    @MainActor private final class ReadProbe {
        var task: Task<Void, Never>?, result: Result<String, Error>?
        var completions = 0
        func start(_ store: BLEDeviceStore, id: UUID) {
            task = Task { @MainActor in
                do { result = .success(try await store.read(id, profile: .battery)) }
                catch { result = .failure(error) }
                completions += 1
            }
        }
    }
    @MainActor private final class LinkProbe {
        var task: Task<Void, Never>?, result: Result<JSONValue?, Error>?
        var completions = 0
        func start(_ store: BLEDeviceStore, id: UUID, request: UUID) {
            task = Task { @MainActor in
                do { result = .success(try await store.queryLink(id, requestID: request, name: "light.get")) }
                catch { result = .failure(error) }
                completions += 1
            }
        }
    }
    @MainActor private final class Run {
        static let ready = "蓝牙已就绪，请点击扫描"
        static let timeoutText = "连接或服务发现超时"
        let a = UUID(uuidString: "ce6ec956-1111-4222-8333-123456789abc")!
        let b = UUID(uuidString: "ce6ec956-1111-4222-8333-123456789abd")!
        let request = UUID(uuidString: "98765432-1234-4234-8234-123456789abc")!
        let suite: String, defaults: UserDefaults, adapter: BLEDeviceStore.TestAdapter, store: BLEDeviceStore
        var aPeer: AnyObject!, bPeer: AnyObject!
        var aTemp: BLEDeviceStore.TestService!, aTempValue: BLEDeviceStore.TestCharacteristic!
        var bBattery: BLEDeviceStore.TestService!, bTemp: BLEDeviceStore.TestService!, bAlert: BLEDeviceStore.TestService!
        var bValue: BLEDeviceStore.TestCharacteristic!, bAlertValue: BLEDeviceStore.TestCharacteristic!
        var aBattery: BLEDeviceStore.TestService!, aBatteryValue: BLEDeviceStore.TestCharacteristic!
        var aLink: BLEDeviceStore.TestService!, rx: BLEDeviceStore.TestCharacteristic!, tx: BLEDeviceStore.TestCharacteristic!, audio: BLEDeviceStore.TestCharacteristic!
        var aTimer: BLEDeviceStore.TestTimerProbe!, bTimer: BLEDeviceStore.TestTimerProbe!, newTimer: BLEDeviceStore.TestTimerProbe?
        var aTimerID: ObjectIdentifier?, newTimerID: ObjectIdentifier?, bTimerID: ObjectIdentifier?, bOwner: ObjectIdentifier?, bChannel: ObjectIdentifier?, bClient: ObjectIdentifier?
        var bDevice: BLEDeviceStore.Device!, bEndpoint: AnyObject?, bAlertEndpoint: AnyObject?, bPeerIdentity: AnyObject?
        var bReadDeclaration = false, bAlertDeclaration = false
        var read: ReadProbe?, link: LinkProbe?, physical: PhysicalPeer?
        var nested: [String: Any]?, injected = 0, powerIndex: Int?
        var beforeOpcodes: [UInt8] = [], linkCountAfterResult: Int?
        var setup: String
        init(_ setup: String) throws {
            self.setup = setup
            suite = "PhoneDSH.Deadline." + UUID().uuidString
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            adapter = BLEDeviceStore.TestAdapter(); adapter.identityDefaults = defaults
            store = BLEDeviceStore(testAdapter: adapter, testDevices: [.init(id: a, name: "A", rssi: -40), .init(id: b, name: "B", rssi: -50)])
            aPeer = try XCTUnwrap(store.testPhysicalPeer(a)); bPeer = try XCTUnwrap(store.testPhysicalPeer(b))
            aTemp = .init(parent: aPeer, uuid: "181A"); aTempValue = .init(parent: aTemp, uuid: "2A6E", properties: [.read])
            aBattery = .init(parent: aPeer, uuid: "180F"); aBatteryValue = .init(parent: aBattery, uuid: "2A19", properties: [.read])
            bBattery = .init(parent: bPeer, uuid: "180F"); bTemp = .init(parent: bPeer, uuid: "181A")
            bValue = .init(parent: bBattery, uuid: "2A19", properties: [.read])
            bAlert = .init(parent: bPeer, uuid: "1802")
            bAlertValue = .init(parent: bAlert, uuid: "2A06", properties: [.writeWithoutResponse])
            aLink = .init(parent: aPeer, uuid: PDSHLink.service)
            rx = .init(parent: aLink, uuid: PDSHLink.rx, properties: [.write])
            tx = .init(parent: aLink, uuid: PDSHLink.tx, properties: [.notify])
            audio = .init(parent: aLink, uuid: PDSHLink.audioUp, properties: [.notify])
        }
        func cleanup() {
            // Retire real per-owner timers and continuations rather than leave
            // test stores alive until the 20-second production deadline.
            injected = max(injected, 1); onStatus = nil
            adapter.afterReadOutcomeClaim = nil; adapter.afterReadValueClaim = nil
            adapter.beforeDisconnectSubmit = nil; adapter.onLinkWrite = nil
            read?.task?.cancel(); link?.task?.cancel()
            store.testRadioUnavailable(reset: false)
            defaults.removePersistentDomain(forName: suite)
        }
        func device(_ id: UUID) throws -> BLEDeviceStore.Device { try XCTUnwrap(store.devices.first { $0.id == id }) }
        func wait(_ condition: () -> Bool, _ label: String) async throws {
            for _ in 0..<400 { if condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
            throw BLEFailure("Timed out: \(label)")
        }
        func begin() async throws {
            store.testRadioOn(); XCTAssertEqual(store.status, Self.ready)
            store.connect(b); bTimer = try XCTUnwrap(store.testCaptureConnectionTimeout(b))
            bTimerID = try XCTUnwrap(store.testConnectionDeadlineToken(b)); XCTAssertEqual(bTimer.state, "active")
            store.testDidConnect(b)
            store.testDiscoveryServices(b, peer: bPeer, services: [bBattery, bTemp, bAlert])
            store.testDiscoveryCharacteristics(b, peer: bPeer, service: bBattery, characteristics: [bValue])
            store.testDiscoveryCharacteristics(b, peer: bPeer, service: bAlert, characteristics: [bAlertValue])
            store.grant(b, read: true, alert: true); try store.testReadAdmission(b, profile: .battery)
            let declarations = store.testDeclarations(b)
            bReadDeclaration = declarations.read; bAlertDeclaration = declarations.alert
            XCTAssertTrue(bReadDeclaration); XCTAssertTrue(bAlertDeclaration)
            let alertResult = try store.alert(b, level: 1)
            XCTAssertTrue(alertResult.hasPrefix("submitted_unconfirmed:"))
            XCTAssertEqual(adapter.commands.filter { $0 == .alert(b, 1) }.count, 1)
            bOwner = try XCTUnwrap(store.testOwner(b)); bDevice = try device(b)
            bEndpoint = try XCTUnwrap(store.testDiscoveryProfileEndpoint(b, profile: .battery)); XCTAssertTrue(bEndpoint === bValue)
            bAlertEndpoint = try XCTUnwrap(store.testDiscoveryProfileEndpoint(b, profile: .alert)); XCTAssertTrue(bAlertEndpoint === bAlertValue)
            bPeerIdentity = bPeer; bChannel = store.testIdentityChannel(b); bClient = store.testIdentityClient(b)
            store.connect(a); aTimer = try XCTUnwrap(store.testCaptureConnectionTimeout(a))
            aTimerID = try XCTUnwrap(store.testConnectionDeadlineToken(a)); XCTAssertEqual(aTimer.state, "active")
            if setup != "connecting" {
                store.testDidConnect(a)
                var services: [BLEDeviceStore.TestService] = [aTemp]
                if setup == "read-pending" || setup == "read-cancel-claimed" || setup == "read-link-pending" { services.insert(aBattery, at: 0) }
                if setup == "link-pending" || setup == "read-link-pending" { services.insert(aLink, at: 0) }
                store.testDiscoveryServices(a, peer: aPeer, services: services)
                if setup == "link-pending" || setup == "read-link-pending" { try await prepareLink(startQuery: setup == "link-pending") }
                if setup == "read-pending" || setup == "read-cancel-claimed" || setup == "read-link-pending" {
                    store.testDiscoveryCharacteristics(a, peer: aPeer, service: aBattery, characteristics: [aBatteryValue])
                    store.grant(a, read: true)
                    let probe = ReadProbe(); read = probe; probe.start(store, id: a)
                    try await wait({ self.store.testPending(self.a) || probe.result != nil }, "read pending")
                    XCTAssertTrue(store.testPending(a)); XCTAssertNil(probe.result)
                    if setup == "read-cancel-claimed" {
                        let task = try XCTUnwrap(probe.task), done = DispatchSemaphore(value: 0)
                        DispatchQueue.global(qos: .userInitiated).async { task.cancel(); done.signal() }
                        XCTAssertEqual(done.wait(timeout: .now() + 2), .success)
                        XCTAssertEqual(store.testReadClaim(a), "cancelled")
                    }
                }
                if setup == "reconnected" {
                    let oldOwner = store.testOwner(a); store.disconnect(a); store.testDidDisconnect(a)
                    try await wait({ self.store.testPhase(self.a) == "idle" }, "disconnect retirement")
                    store.connect(a); newTimer = try XCTUnwrap(store.testCaptureConnectionTimeout(a))
                    let newID = try XCTUnwrap(store.testConnectionDeadlineToken(a)); newTimerID = newID
                    XCTAssertNotEqual(oldOwner, store.testOwner(a)); XCTAssertNotEqual(aTimerID, newID)
                    XCTAssertEqual(aTimer.state, "cancelled"); XCTAssertEqual(newTimer?.state, "active")
                    store.testDidConnect(a)
                    store.testDiscoveryServices(a, peer: aPeer, services: [aTemp])
                }
            }
            XCTAssertEqual(store.status, Self.ready); XCTAssertEqual(bTimer.state, "active")
            XCTAssertFalse(try device(a).profiles.contains(.temperature))
            adapter.commands.removeAll(); adapter.discoverySubmissions.removeAll(); adapter.notifyEndpoints.removeAll()
        }
        func prepareLink(startQuery: Bool = true) async throws {
            store.testDiscoveryCharacteristics(a, peer: aPeer, service: aLink, characteristics: [rx, tx, audio])
            let endpoints = try XCTUnwrap(store.testDiscoveryLinkEndpoints(a))
            XCTAssertTrue(endpoints.service === aLink && endpoints.rx === rx && endpoints.tx === tx && endpoints.audio === audio)
            let physical = PhysicalPeer(id: a, store: store, physical: aPeer, tx: tx, rx: rx)
            self.physical = physical
            adapter.onLinkWrite = { _, bytes in physical.wrote(bytes) }
            store.testDiscoveryNotification(a, peer: aPeer, characteristic: tx, notifying: true)
            store.testDiscoveryNotification(a, peer: aPeer, characteristic: audio, notifying: true)
            try await wait({ self.store.testIdentityClient(self.a) != nil || physical.failed != nil }, "Link HELLO/tools/list")
            if let error = physical.failed { throw error }
            XCTAssertNotNil(store.testIdentityClient(a))
            store.grantLinkTool(a, name: "light.get", enabled: true)
            try store.authorizeLink(a, name: "light.get", arguments: nil)
            guard startQuery else { return }
            beforeOpcodes = physical.submittedOpcodes
            physical.resultRequest = request; physical.holdNextQuery = true
            let probe = LinkProbe(); link = probe; probe.start(store, id: a, request: request)
            try await wait({ physical.heldResponse != nil && self.store.testLinkExchangePending(self.a) }, "Link query pending")
            XCTAssertNil(probe.result)
            XCTAssertEqual(physical.submittedOpcodes.filter { $0 == 0x55 }.count, beforeOpcodes.filter { $0 == 0x55 }.count)
            XCTAssertEqual(physical.submittedOpcodes.filter { $0 == 0x56 }.count, beforeOpcodes.filter { $0 == 0x56 }.count + 1)
        }
        func flipPower() { powerIndex = adapter.commands.count; adapter.poweredOn = false }
        func managerOff() { powerIndex = adapter.commands.count; store.testManagerState(.poweredOff) }
        func fireFinal() { store.testDiscoveryCharacteristics(a, peer: aPeer, service: aTemp, characteristics: [aTempValue]) }
        func fireRead() { store.testPhysicalValue(a, physical: aPeer, endpoint: aBatteryValue, data: Data([37])) }
        func execute(_ event: String) throws {
            switch event {
            case "old-timer", "timeout": aTimer.invoke()
            case "final": fireFinal()
            case "read-value": fireRead()
            case "poweroff": flipPower()
            case "manager-off": managerOff()
            case "b-error":
                store.testDiscoveryCharacteristics(b, peer: bPeer, service: bTemp, characteristics: nil,
                    error: NSError(domain: "deadline.fixture", code: 7, userInfo: [NSLocalizedDescriptionKey: "B-ERROR"]))
            default: throw BLEFailure("Unknown deadline nested event \(event)")
            }
        }
        func countDisconnect(_ id: UUID) -> Int {
            adapter.commands.filter { if case .disconnect(let target) = $0 { return target == id }; return false }.count
        }
        func otherState() throws -> String {
            let value = try device(b), endpoint = store.testDiscoveryProfileEndpoint(b, profile: .battery)
            let alertEndpoint = store.testDiscoveryProfileEndpoint(b, profile: .alert)
            let declarations = store.testDeclarations(b)
            let unchanged = store.testPhase(b) == "connected" && store.testOwner(b) == bOwner &&
                store.testPhysicalPeer(b) === bPeerIdentity && endpoint === bEndpoint &&
                alertEndpoint === bAlertEndpoint && declarations.read == bReadDeclaration && declarations.alert == bAlertDeclaration &&
                store.testIdentityChannel(b) == bChannel && store.testIdentityClient(b) == bClient &&
                store.testConnectionDeadlineToken(b) == bTimerID && bTimer.state == "active" &&
                value.state == bDevice.state && value.linkState == bDevice.linkState && value.profiles == bDevice.profiles &&
                value.allowRead == bDevice.allowRead && value.allowAlert == bDevice.allowAlert &&
                value.pendingIdentity == bDevice.pendingIdentity && value.taskIdentity == bDevice.taskIdentity &&
                value.grantedTools == bDevice.grantedTools && value.allowDeviceTasks == bDevice.allowDeviceTasks &&
                value.supportsDeviceTasks == bDevice.supportsDeviceTasks && value.linkTools == bDevice.linkTools &&
                value.linkToolDescriptors == bDevice.linkToolDescriptors && value.homeOrigins == bDevice.homeOrigins &&
                value.events == bDevice.events && value.readings == bDevice.readings && value.identityError == bDevice.identityError
            if unchanged {
                if adapter.poweredOn && !store.testPending(a) && !store.testPending(b) {
                    XCTAssertNoThrow(try store.testReadAdmission(b, profile: .battery))
                } else if !adapter.poweredOn {
                    XCTAssertThrowsError(try store.testReadAdmission(b, profile: .battery))
                }
                return "unchanged"
            }
            if store.testPhase(b) == "closing", bTimer.state == "cancelled", countDisconnect(b) == 1,
               !value.allowRead, !value.allowAlert, !declarations.read, !declarations.alert,
               endpoint == nil, alertEndpoint == nil, store.testIdentityChannel(b) == nil,
               store.testIdentityClient(b) == nil {
                XCTAssertThrowsError(try store.alert(b, level: 1))
                return "b-closing"
            }
            if store.testPhase(a) == "quarantined", store.testPhase(b) == "quarantined",
               bTimer.state == "cancelled", !value.allowRead, !value.allowAlert, !declarations.read, !declarations.alert,
               endpoint == nil, alertEndpoint == nil,
               store.testIdentityChannel(b) == nil, store.testIdentityClient(b) == nil {
                let aDevice = try device(a)
                let aDeclarations = store.testDeclarations(a)
                guard !aDevice.allowRead, !aDevice.allowAlert, !aDevice.allowDeviceTasks,
                      !aDeclarations.read, !aDeclarations.alert,
                      StandardBLEProfile.allCases.allSatisfy({ store.testDiscoveryProfileEndpoint(a, profile: $0) == nil }),
                      store.testIdentityChannel(a) == nil, store.testIdentityClient(a) == nil,
                      store.testDiscoveryRawLinkStorageEmpty(a) else { return "changed" }
                let commandCount = adapter.commands.count
                XCTAssertThrowsError(try store.testReadAdmission(a, profile: .battery))
                XCTAssertThrowsError(try store.alert(a, level: 1))
                XCTAssertThrowsError(try store.alert(b, level: 1))
                XCTAssertEqual(adapter.commands.count, commandCount, "quarantined admission must not submit a physical command")
                return "all-quarantined"
            }
            return "changed"
        }
        func partialSnapshot() throws -> [String: Any] {
            let endpoint = store.testDiscoveryProfileEndpoint(a, profile: .temperature)
            if endpoint != nil { XCTAssertTrue(endpoint === aTempValue) }
            return ["phase": store.testPhase(a), "final_endpoint": endpoint != nil, "old_timer": aTimer.state,
                    "disconnects": countDisconnect(a), "other": try otherState()]
        }
        func snapshot() throws -> [String: Any] {
            var result = try partialSnapshot()
            let endpoint = store.testDiscoveryProfileEndpoint(a, profile: .temperature)
            XCTAssertEqual(try device(a).profiles.contains(.temperature), endpoint != nil)
            let readState: String
            if let read {
                switch read.result {
                case .success(let value)?: XCTAssertTrue(value.hasPrefix("37 % @ ")); readState = "value-once"
                case .failure(let error)?:
                    if error is CancellationError { readState = "cancelled-once" }
                    else if let error = error as? BLEFailure, error.message == "Device disconnected" { readState = "disconnected-once" }
                    else { readState = "unexpected-error" }
                case nil: readState = "pending"
                }
                XCTAssertEqual(read.completions, 1)
            } else { readState = "none" }
            let linkState: String
            if let link {
                switch link.result {
                case .success(let result)?:
                    guard let value = result else { throw BLEFailure("nil query means still running") }
                    XCTAssertEqual(value, expectedLinkResult)
                    linkState = "value-once"
                case .failure(let error)?:
                    let message = (error as? BLEFailure)?.message ?? error.localizedDescription
                    linkState = message.contains("outcome_unknown") ? "unknown-once" : "unexpected-error"
                case nil: linkState = "pending"
                }
                XCTAssertEqual(link.completions, 1)
            } else { linkState = "none" }
            let status: String
            switch store.status {
            case Self.ready: status = "prior"
            case Self.timeoutText: status = "timeout"
            case "B-ERROR": status = "b-error"
            case "蓝牙不可用，状态：4": status = "manager-off"
            default: status = "unexpected:" + store.status
            }
            let extra = adapter.discoverySubmissions.filter { $0.id == a }.count
            let afterOff = powerIndex.map { adapter.commands.count - $0 } ?? 0
            result.merge(["read": readState, "link": linkState, "status": status, "b_timer": bTimer.state,
                          "new_timer": newTimer?.state ?? "none", "extra_discovery_requests": extra,
                          "physical_commands_after_poweroff": afterOff]) { _, new in new }
            return result
        }
        var expectedLinkResult: JSONValue {
            .object(["request_id": .string(request.uuidString.lowercased()), "status": .string("completed"),
                     "result": .object(["value": .number(42)])])
        }
        var onStatus: (() -> Void)? {
            get { statusAction }
            set { statusAction = newValue }
        }
        private var statusAction: (() -> Void)? {
            get { statusActionBox.action }
            set { statusActionBox.action = newValue }
        }
        private var statusActionBox: StatusBox { statusBox }
        private final class StatusBox { var action: (() -> Void)?; var count = 0 }
        private final class Ticket { var consumed = false }
        private let statusBox = StatusBox()
        var statusNotifications: Int { statusBox.count }
        func watchStatus() {
            let ticket = Ticket()
            withObservationTracking { _ = store.status } onChange: {
                MainActor.assumeIsolated {
                    guard !ticket.consumed else { return }; ticket.consumed = true
                    self.statusBox.count += 1
                    guard self.statusBox.count < 12 else { XCTFail("Unbounded status notification"); return }
                    self.watchStatus()
                    self.statusAction?()
                }
            }
        }
    }
    @MainActor private func run(_ row: [String: Any]) async throws -> ([String: Any], [String: Any]?) {
        let setup = try XCTUnwrap(row["setup"] as? String), outer = try XCTUnwrap(row["outer"] as? String)
        let run = try Run(setup); defer { run.cleanup() }
        try await run.begin(); run.watchStatus()
        let injections = try XCTUnwrap(row["inject"] as? [[String: Any]])
        XCTAssertLessThanOrEqual(injections.count, 1)
        if let injection = injections.first {
            let point = try XCTUnwrap(injection["point"] as? String), event = try XCTUnwrap(injection["event"] as? String)
            let trigger = {
                guard run.injected == 0 else { return }
                run.injected += 1
                do { try run.execute(event); run.nested = try run.partialSnapshot() }
                catch { XCTFail("nested \(point): \(error)") }
            }
            switch point {
            case "final-devices-will-change", "timeout-devices-will-change":
                withObservationTracking { _ = run.store.devices } onChange: { MainActor.assumeIsolated { trigger() } }
            case "timeout-status-will-change": run.onStatus = trigger
            case "after-read-value-claim": run.adapter.afterReadValueClaim = trigger
            case "after-read-outcome-claim": run.adapter.afterReadOutcomeClaim = trigger
            default: throw BLEFailure("Unknown injection point \(point)")
            }
        }
        switch outer {
        case "final-then-old-timer": run.fireFinal(); run.aTimer.invoke()
        case "final": run.fireFinal()
        case "timeout-then-final": run.aTimer.invoke(); run.fireFinal()
        case "timeout": run.aTimer.invoke()
        case "read-value": run.fireRead()
        case "link-response-then-timeout":
            let physical = try XCTUnwrap(run.physical), probe = try XCTUnwrap(run.link)
            physical.deliverHeld()
            try await run.wait({ probe.result != nil }, "completed Link query")
            guard case .success(let result)? = probe.result, let result else { throw BLEFailure("Link query did not produce terminal receipt") }
            XCTAssertEqual(result, run.expectedLinkResult); XCTAssertEqual(probe.completions, 1)
            run.linkCountAfterResult = physical.submittedOpcodes.count
            run.aTimer.invoke()
        case "old-timer": run.aTimer.invoke()
        case "poweroff-then-timeout": run.flipPower(); run.aTimer.invoke()
        case "timeout-then-services":
            run.aTimer.invoke(); run.store.testDiscoveryServices(run.a, peer: run.aPeer, services: [run.aTemp])
        case "final-then-poweroff-old-timer": run.fireFinal(); run.flipPower(); run.aTimer.invoke()
        default: throw BLEFailure("Unknown deadline outer event \(outer)")
        }
        if let read = run.read { try await run.wait({ read.result != nil }, "read completion") }
        if let link = run.link {
            try await run.wait({ link.result != nil }, "Link completion")
            if let physical = run.physical {
                let before = physical.submittedOpcodes; let completions = link.completions
                physical.deliverHeld(); await Task.yield()
                XCTAssertEqual(link.completions, completions, "late response completed Link twice")
                XCTAssertEqual(physical.submittedOpcodes, before, "late response replayed Link request")
                XCTAssertEqual(physical.submittedOpcodes.filter { $0 == 0x55 }.count, run.beforeOpcodes.filter { $0 == 0x55 }.count)
                XCTAssertEqual(physical.submittedOpcodes.filter { $0 == 0x56 }.count, run.beforeOpcodes.filter { $0 == 0x56 }.count + 1)
                if let count = run.linkCountAfterResult { XCTAssertEqual(physical.submittedOpcodes.count, count) }
            }
        }
        if !injections.isEmpty { XCTAssertEqual(run.injected, 1, "actual synchronous injection must execute exactly once") }
        if outer == "final-then-old-timer" || outer == "old-timer" || outer == "final-then-poweroff-old-timer" {
            XCTAssertEqual(run.statusNotifications, 0, "inert old timer cannot publish")
        }
        if setup == "reconnected" {
            XCTAssertNotEqual(run.store.testConnectionDeadlineToken(run.a), run.aTimerID)
            XCTAssertEqual(run.store.testConnectionDeadlineToken(run.a), run.newTimerID)
            XCTAssertEqual(run.newTimer?.state, "active")
        }
        return (try run.snapshot(), run.nested)
    }
    /// Real manager callbacks must not let a superseded timeout submit a
    /// disconnect after the system has become unavailable and available again.
    @MainActor func testReadClaimManagerOffThenOnCannotReviveOldClose() async throws {
        let run = try Run("read-pending"); defer { run.cleanup() }
        try await run.begin(); run.watchStatus()
        var fired = 0
        run.adapter.afterReadOutcomeClaim = {
            fired += 1
            run.managerOff()
            run.store.testManagerState(.poweredOn)
        }
        run.aTimer.invoke()
        let read = try XCTUnwrap(run.read)
        try await run.wait({ read.result != nil }, "off-on read completion")
        XCTAssertEqual(fired, 1)
        let actual = try run.snapshot()
        XCTAssertEqual(actual["phase"] as? String, "quarantined")
        XCTAssertEqual(actual["other"] as? String, "all-quarantined")
        XCTAssertEqual(actual["read"] as? String, "disconnected-once")
        XCTAssertEqual(actual["disconnects"] as? Int, 0)
        XCTAssertEqual(actual["physical_commands_after_poweroff"] as? Int, 0)
        XCTAssertEqual(actual["status"] as? String, "prior")
        XCTAssertEqual(run.statusNotifications, 2, "manager off and on each publish, timeout must not")
    }

    /// An eligible physical callback can observe off without a manager
    /// callback; restoring the physical bit cannot revive the old status.
    @MainActor func testReadClaimObservedPowerOffThenPhysicalOnCannotReviveTimeout() async throws {
        let run = try Run("read-pending"); defer { run.cleanup() }
        try await run.begin(); run.watchStatus()
        var fired = 0
        run.adapter.afterReadOutcomeClaim = {
            fired += 1
            run.flipPower()
            run.store.testServicesModified(run.b, invalidated: [])
            run.adapter.poweredOn = true
        }
        run.aTimer.invoke()
        let read = try XCTUnwrap(run.read)
        try await run.wait({ read.result != nil }, "observed-off read completion")
        XCTAssertEqual(fired, 1)
        let actual = try run.snapshot()
        XCTAssertEqual(actual["phase"] as? String, "quarantined")
        XCTAssertEqual(actual["other"] as? String, "all-quarantined")
        XCTAssertEqual(actual["read"] as? String, "disconnected-once")
        XCTAssertEqual(actual["disconnects"] as? Int, 0)
        XCTAssertEqual(actual["physical_commands_after_poweroff"] as? Int, 0)
        XCTAssertEqual(actual["status"] as? String, "prior")
        XCTAssertEqual(run.statusNotifications, 0, "no manager status callback or stale timeout status")
    }

    /// An actual duplicate didConnect while timeout owns close must not submit
    /// a second disconnect or skip the original read/channel cleanup.
    @MainActor func testUnexpectedDidConnectDuringTimeoutReadClaimClosesOnlyOnce() async throws {
        let run = try Run("read-link-pending"); defer { run.cleanup() }
        try await run.begin()
        XCTAssertNotNil(run.store.testIdentityChannel(run.a))
        var fired = 0
        run.adapter.afterReadOutcomeClaim = {
            fired += 1; run.store.testDidConnect(run.a)
            XCTAssertEqual(run.store.testPhase(run.a), "quarantined")
            XCTAssertEqual(run.countDisconnect(run.a), 1)
        }
        run.aTimer.invoke()
        let read = try XCTUnwrap(run.read)
        try await run.wait({ read.result != nil }, "duplicate didConnect read cleanup")
        XCTAssertEqual(fired, 1); XCTAssertEqual(run.countDisconnect(run.a), 1)
        XCTAssertEqual(run.store.testPhase(run.a), "quarantined")
        XCTAssertEqual(run.aTimer.state, "cancelled"); XCTAssertEqual(run.bTimer.state, "active")
        XCTAssertEqual(try run.otherState(), "unchanged")
        XCTAssertNil(run.store.testIdentityChannel(run.a)); XCTAssertNil(run.store.testIdentityClient(run.a))
        XCTAssertTrue(run.store.testDiscoveryRawLinkStorageEmpty(run.a))
        XCTAssertNil(run.store.testDiscoveryProfileEndpoint(run.a, profile: .battery))
        XCTAssertFalse(run.store.testPending(run.a)); XCTAssertEqual(read.completions, 1)
        guard case .failure(let error)? = read.result else { return XCTFail("read must fail") }
        XCTAssertEqual((error as? BLEFailure)?.message, "Device disconnected")
    }

    /// Both an already connected and a submitted connecting attempt can see
    /// an off/on manager sequence immediately before the physical cancel.
    @MainActor func testOffOnBeforePhysicalDisconnectCannotReviveTimeout() async throws {
        for setup in ["basic", "connecting"] {
            let run = try Run(setup); defer { run.cleanup() }
            try await run.begin(); run.watchStatus()
            var fired = 0
            run.adapter.beforeDisconnectSubmit = { id in
                guard id == run.a, fired == 0 else { return }
                fired += 1; run.managerOff(); run.store.testManagerState(.poweredOn)
            }
            run.aTimer.invoke()
            XCTAssertEqual(fired, 1, setup)
            let actual = try run.snapshot()
            XCTAssertEqual(actual["phase"] as? String, "quarantined", setup)
            XCTAssertEqual(actual["other"] as? String, "all-quarantined", setup)
            XCTAssertEqual(actual["disconnects"] as? Int, 0, setup)
            XCTAssertEqual(actual["physical_commands_after_poweroff"] as? Int, 0, setup)
            XCTAssertEqual(actual["status"] as? String, "prior", setup)
            XCTAssertEqual(run.statusNotifications, 2, setup)
        }
    }

    @MainActor func testAllSharedDeadlineVectorsAndSemanticMutations() async throws {
        let rows = try lines("standard-gatt-discovery-deadline.jsonl")
        let mutations = try lines("standard-gatt-discovery-deadline-mutations.jsonl").filter { $0["category"] as? String == "semantic" }
        XCTAssertEqual(rows.count, 19); XCTAssertEqual(Set(rows.compactMap { $0["id"] as? String }).count, 19)
        XCTAssertEqual(mutations.count, 22)
        var tested = Set<String>()
        for row in rows {
            let id = try XCTUnwrap(row["id"] as? String)
            do {
                let (actual, nested) = try await run(row)
                let expected = try XCTUnwrap(row["expect"] as? [String: Any])
                XCTAssertTrue(matches(actual, expected), "\(id): actual \(actual), expected \(expected)")
                let injections = try XCTUnwrap(row["inject"] as? [[String: Any]])
                if let injectedExpected = injections.first?["expect"] as? [String: Any] {
                    let observed = try XCTUnwrap(nested, "\(id): missing nested checkpoint")
                    XCTAssertTrue(matches(observed, injectedExpected), "\(id): nested actual \(observed), expected \(injectedExpected)")
                }
                for mutation in mutations where mutation["base"] as? String == id {
                    let name = try XCTUnwrap(mutation["name"] as? String), path = try XCTUnwrap(mutation["path"] as? [Any])
                    let field = try XCTUnwrap(path.last as? String), value = try XCTUnwrap(mutation["value"])
                    let isNested = path.first as? String == "inject"
                    var mutated = isNested ? try XCTUnwrap(injections.first?["expect"] as? [String: Any]) : expected
                    mutated[field] = value
                    let observed = isNested ? try XCTUnwrap(nested) : actual
                    XCTAssertFalse(matches(observed, mutated), "real comparator accepted mutation \(name)")
                    tested.insert(name)
                }
            } catch { XCTFail("\(id): \(error)") }
        }
        XCTAssertEqual(tested, Set(mutations.compactMap { $0["name"] as? String }))
    }
}
#endif
