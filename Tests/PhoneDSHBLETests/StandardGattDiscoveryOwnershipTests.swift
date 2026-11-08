// SPDX-License-Identifier: MIT
import CoreBluetooth
import CoreFoundation
import Foundation
import Observation
import PhoneDSHAgentCore
import XCTest
@testable import PhoneDSHBLE

#if DEBUG
/// Executes the frozen discovery object/event vectors through the real store.
/// Physical reference names are not OS callback or radio-attempt tokens.
final class StandardGattDiscoveryOwnershipTests: XCTestCase {
    private func json(_ name: String) throws -> Any {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("spec/device/v1/golden/\(name).json")))
    }
    private func vectors() throws -> [[String: Any]] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("spec/device/v1/golden/standard-gatt-discovery-ownership.jsonl")
        return try String(contentsOf: url, encoding: .utf8).split(whereSeparator: \.isNewline).map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }
    private func string(_ object: [String: Any], _ key: String) throws -> String { try XCTUnwrap(object[key] as? String, "missing \(key)") }
    private func dict(_ object: [String: Any], _ key: String) throws -> [String: Any] { try XCTUnwrap(object[key] as? [String: Any], "missing \(key)") }
    private func array(_ object: [String: Any], _ key: String) throws -> [[String: Any]] { try XCTUnwrap(object[key] as? [[String: Any]], "missing \(key)") }

    /// Compare real snapshots to only the declared expected keys, preserving
    /// array order, numeric types and Unicode scalar spellings.
    private func sameValue(_ left: Any, _ right: Any) -> Bool {
        if let l = left as? String, let r = right as? String { return l.unicodeScalars.elementsEqual(r.unicodeScalars) }
        if let l = left as? [Any], let r = right as? [Any] { return l.count == r.count && zip(l, r).allSatisfy { sameValue($0.0, $0.1) } }
        if let l = left as? [String: Any], let r = right as? [String: Any] {
            return l.count == r.count && l.allSatisfy { key, value in r[key].map { sameValue(value, $0) } ?? false }
        }
        if left is NSNull, right is NSNull { return true }
        guard let l = left as? NSNumber, let r = right as? NSNumber else { return false }
        let lIsBool = CFGetTypeID(l) == CFBooleanGetTypeID()
        let rIsBool = CFGetTypeID(r) == CFBooleanGetTypeID()
        return lIsBool == rIsBool && l == r
    }
    private func matches(_ actual: [String: Any], _ expected: [String: Any]) -> Bool {
        expected.allSatisfy { key, value in actual[key].map { sameValue($0, value) } ?? false }
    }

    @MainActor private final class ReadProbe {
        var task: Task<Void, Never>?
        var result: Result<String, Error>?
        var completions = 0
        var wasPending = false
        func start(_ store: BLEDeviceStore, id: UUID) {
            task = Task { @MainActor in
                do { result = .success(try await store.read(id, profile: .battery)) }
                catch { result = .failure(error) }
                completions += 1
            }
        }
    }
    @MainActor private final class Meter {
        var devices = 0, status = 0, actionCount = 0, statusActionCount = 0
        var deviceAction: (() -> Void)?, statusAction: (() -> Void)?
        func watchDevices(_ store: BLEDeviceStore) {
            withObservationTracking { _ = store.devices } onChange: {
                MainActor.assumeIsolated {
                    self.devices += 1
                    if self.devices < 100 { self.watchDevices(store) }
                    if self.actionCount == 0, let action = self.deviceAction { self.actionCount += 1; action() }
                }
            }
        }
        func watchStatus(_ store: BLEDeviceStore) {
            withObservationTracking { _ = store.status } onChange: {
                MainActor.assumeIsolated {
                    self.status += 1
                    if self.status < 100 { self.watchStatus(store) }
                    if self.statusActionCount == 0, let action = self.statusAction { self.statusActionCount += 1; action() }
                }
            }
        }
    }
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

    @MainActor private final class Run {
        let a = UUID(uuidString: "ce6ec956-1111-4222-8333-123456789abc")!
        let b = UUID(uuidString: "ce6ec956-1111-4222-8333-123456789abd")!
        let unknown = UUID(uuidString: "ce6ec956-1111-4222-8333-123456789abe")!
        let suite: String
        let defaults: UserDefaults
        let adapter: BLEDeviceStore.TestAdapter
        let store: BLEDeviceStore
        let meter = Meter()
        var objects: [String: AnyObject] = [:]
        var names: [ObjectIdentifier: String] = [:]
        var peers: [UUID: PhysicalPeer] = [:]
        var deadline: BLEDeviceStore.TestTimerProbe?
        var deadlineToken: ObjectIdentifier?
        var bDeadline: BLEDeviceStore.TestTimerProbe?
        var bOwner: ObjectIdentifier?, bChannel: ObjectIdentifier?, bClient: ObjectIdentifier?
        var bIdentity = "", bPendingIdentity = "", bState = "", bLinkState = "", bProfiles: [StandardBLEProfile] = []
        var bTools: Set<String> = []
        var bPeer: AnyObject?, bBatteryEndpoint: AnyObject?, bAlertEndpoint: AnyObject?
        var baselinePreferences: [[UInt32]] = []
        var reads: [ReadProbe] = []
        var activeRead: ReadProbe?
        var retiredReadCompletions = 0
        var injectedSnapshots: [Int: [String: Any]] = [:]
        var injectedActions: [Int: Int] = [:]
        var started = Date(), ended = Date()

        init(_ row: [String: Any]) throws {
            suite = "PhoneDSH.DiscoveryOwnership." + UUID().uuidString
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            adapter = BLEDeviceStore.TestAdapter(); adapter.identityDefaults = defaults
            store = BLEDeviceStore(testAdapter: adapter, testDevices: [
                .init(id: a, name: "A", rssi: -40), .init(id: b, name: "B", rssi: -50)
            ])
            let definitions = try XCTUnwrap(row["objects"] as? [String: [String: Any]])
            objects["A"] = try XCTUnwrap(store.testPhysicalPeer(a)); objects["B"] = try XCTUnwrap(store.testPhysicalPeer(b))
            objects["A2"] = NSObject(); objects["X"] = NSObject()
            for (name, item) in definitions where item["kind"] as? String == "service" {
                let parent = (item["parent"] as? String).flatMap { objects[$0] }
                let service = BLEDeviceStore.TestService(parent: parent, uuid: try XCTUnwrap(item["uuid"] as? String),
                                                         primary: try XCTUnwrap(item["primary"] as? Bool))
                objects[name] = service
            }
            for (name, item) in definitions where item["kind"] as? String == "characteristic" {
                let parent = (item["parent"] as? String).flatMap { objects[$0] }
                let characteristic = BLEDeviceStore.TestCharacteristic(parent: parent, uuid: try XCTUnwrap(item["uuid"] as? String),
                    properties: Self.properties(try XCTUnwrap(item["properties"] as? [String])))
                objects[name] = characteristic
            }
            for (name, value) in objects { names[ObjectIdentifier(value)] = name }
        }
        static func properties(_ names: [String]) -> CBCharacteristicProperties {
            var result: CBCharacteristicProperties = []
            for name in names {
                switch name {
                case "read": result.insert(.read)
                case "write": result.insert(.write)
                case "writeWithoutResponse": result.insert(.writeWithoutResponse)
                case "notify": result.insert(.notify)
                default: XCTFail("unknown physical characteristic property \(name)")
                }
            }
            return result
        }
        func device(_ id: UUID) throws -> BLEDeviceStore.Device { try XCTUnwrap(store.devices.first { $0.id == id }) }
        func peer(_ name: String) throws -> AnyObject { try XCTUnwrap(objects[name], name) }
        func service(_ name: String) throws -> BLEDeviceStore.TestService { try XCTUnwrap(objects[name] as? BLEDeviceStore.TestService, name) }
        func characteristic(_ name: String) throws -> BLEDeviceStore.TestCharacteristic { try XCTUnwrap(objects[name] as? BLEDeviceStore.TestCharacteristic, name) }
        func objectName(_ object: AnyObject) -> String { names[ObjectIdentifier(object)] ?? "<unknown-object>" }
        func endpointName(_ object: ObjectIdentifier) -> String { names[object] ?? "<unknown-endpoint>" }
        func id(_ name: String) -> UUID { name == "B" ? b : (name == "X" ? unknown : a) }
        func cleanup() { defaults.removePersistentDomain(forName: suite) }
        func wait(_ condition: () -> Bool, label: String) async throws {
            for _ in 0..<400 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(5))
            }
            throw BLEFailure("Timed out waiting for \(label)")
        }
        func cancelOffMain(_ task: Task<Void, Never>) -> Bool {
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async { task.cancel(); done.signal() }
            return done.wait(timeout: .now() + 2) == .success
        }
        func attachPhysicalPeer(_ id: UUID) throws -> PhysicalPeer {
            let physical = try XCTUnwrap(store.testLinkPhysicalPeer(id))
            let tx = try XCTUnwrap(store.testLinkTXEndpoint(id)), rx = try XCTUnwrap(store.testLinkRXEndpoint(id))
            let fake = PhysicalPeer(id: id, store: store, physical: physical, tx: tx, rx: rx)
            peers[id] = fake
            adapter.onLinkWrite = { [weak self] device, bytes in self?.peers[device]?.wrote(bytes) }
            return fake
        }
        func setup() async throws {
            defaults.set(["legacy:café", "legacy:cafe\u{301}"], forKey: BLETrustedIdentities.key)
            store.testRadioOn(); store.connect(b)
            bDeadline = try XCTUnwrap(store.testCaptureConnectionTimeout(b))
            XCTAssertEqual(bDeadline?.state, "active")
            store.testDidConnect(b)
            let bPeer = try peer("B")
            store.testDiscoveryServices(b, peer: bPeer, services: try [service("Bbat"), service("Balert"), service("Blink")])
            store.testDiscoveryCharacteristics(b, peer: bPeer, service: try service("Bbat"), characteristics: try [characteristic("BbatValue")])
            store.testDiscoveryCharacteristics(b, peer: bPeer, service: try service("Balert"), characteristics: try [characteristic("BalertValue")])
            store.testDiscoveryCharacteristics(b, peer: bPeer, service: try service("Blink"), characteristics: try [characteristic("Brx"), characteristic("Btx"), characteristic("Baudio")])
            XCTAssertEqual(bDeadline?.state, "cancelled")
            let fake = try attachPhysicalPeer(b)
            store.testDiscoveryNotification(b, peer: bPeer, characteristic: try characteristic("Btx"), notifying: true)
            store.testDiscoveryNotification(b, peer: bPeer, characteristic: try characteristic("Baudio"), notifying: true)
            try await wait({ self.store.testIdentityClient(self.b) != nil || fake.failed != nil }, label: "B real Link handshake/tools-list")
            if let error = fake.failed { throw error }
            XCTAssertNotNil(store.testIdentityClient(b))
            let completed = try XCTUnwrap(store.testCaptureIdentityProof(b))
            completed("ble:" + String(repeating: "b", count: 64))
            store.trustPendingIdentity(b)
            store.grant(b, read: true, alert: true)
            try store.testReadAdmission(b, profile: .battery)
            _ = try store.alert(b, level: 1)
            let bValue = try device(b)
            XCTAssertTrue(bValue.allowRead); XCTAssertTrue(bValue.allowAlert)
            XCTAssertFalse(bValue.taskIdentity.isEmpty); XCTAssertTrue(bValue.pendingIdentity.isEmpty)
            self.bPeer = try peer("B")
            bBatteryEndpoint = try XCTUnwrap(store.testDiscoveryProfileEndpoint(b, profile: .battery))
            bAlertEndpoint = try XCTUnwrap(store.testDiscoveryProfileEndpoint(b, profile: .alert))
            XCTAssertTrue(bBatteryEndpoint === objects["BbatValue"])
            XCTAssertTrue(bAlertEndpoint === objects["BalertValue"])
            bOwner = store.testOwner(b); bChannel = store.testIdentityChannel(b); bClient = store.testIdentityClient(b)
            bIdentity = bValue.taskIdentity; bPendingIdentity = bValue.pendingIdentity; bState = bValue.state; bLinkState = bValue.linkState
            bProfiles = bValue.profiles; bTools = bValue.grantedTools
            baselinePreferences = try XCTUnwrap(defaults.object(forKey: BLETrustedIdentities.key) as? [String]).map { $0.unicodeScalars.map(\.value) }
            store.connect(a)
            deadline = try XCTUnwrap(store.testCaptureConnectionTimeout(a))
            deadlineToken = try XCTUnwrap(store.testConnectionDeadlineToken(a))
            XCTAssertEqual(deadline?.state, "active")
            store.testDidConnect(a)
            XCTAssertTrue(adapter.discoverySubmissions.contains { $0.id == a && $0.service == nil })
            XCTAssertEqual(try device(a).profiles, [])
            XCTAssertNil(store.testIdentityChannel(a)); XCTAssertEqual(store.testDeclarations(a).read, false)
            XCTAssertEqual(store.testDeclarations(a).alert, false)
            adapter.commands.removeAll(); adapter.discoverySubmissions.removeAll(); adapter.notifyEndpoints.removeAll()
            meter.watchDevices(store); meter.watchStatus(store); started = Date()
        }
    }

    @MainActor private func snapshot(_ run: Run, devicesDelta: Int, statusDelta: Int) throws -> [String: Any] {
        let a = try run.device(run.a), b = try run.device(run.b)
        let aDecl = run.store.testDeclarations(run.a), bDecl = run.store.testDeclarations(run.b)
        XCTAssertEqual(a.allowRead, aDecl.read); XCTAssertEqual(a.allowAlert, aDecl.alert)
        XCTAssertEqual(b.allowRead, bDecl.read); XCTAssertEqual(b.allowAlert, bDecl.alert)
        let submissions = run.adapter.discoverySubmissions.filter { $0.id == run.a }
        let serviceRequests = submissions.filter { $0.service == nil }.count
        let characteristicRequests = submissions.compactMap { $0.service.map(run.objectName) }
        let notify = run.adapter.notifyEndpoints.map(run.endpointName)
        let channel = run.store.testIdentityChannel(run.a)
        let link: String
        if channel != nil {
            link = "active"
            let endpoints = try XCTUnwrap(run.store.testDiscoveryLinkEndpoints(run.a))
            XCTAssertTrue(endpoints.service === run.objects["L1"])
            XCTAssertTrue(endpoints.rx === run.objects["rx"])
            XCTAssertTrue(endpoints.tx === run.objects["tx"])
            XCTAssertTrue(endpoints.audio === run.objects["audio"])
        } else if a.linkState == "发现多个 Link 服务，暂不可用" { link = "ambiguous" }
        else if a.linkState == "Link 特征不完整或存在歧义" { link = "incomplete" }
        else { link = "absent" }
        if channel == nil {
            XCTAssertTrue(run.store.testDiscoveryRawLinkStorageEmpty(run.a), "non-active Link must not retain raw service or endpoint maps")
        }
        let expectedEndpoints: [StandardBLEProfile: String] = [.battery: "bat1", .temperature: "temp"]
        for profile in StandardBLEProfile.allCases {
            let endpoint = run.store.testDiscoveryProfileEndpoint(run.a, profile: profile)
            if a.profiles.contains(profile) {
                let name = try XCTUnwrap(expectedEndpoints[profile], "fixture published an unexpected profile")
                XCTAssertTrue(endpoint === run.objects[name], "wrong actual profile endpoint")
            } else {
                XCTAssertNil(endpoint, "unpublished profile retained a real store endpoint: \(profile)")
            }
        }
        let batteryAvailable = aDecl.read && a.profiles.contains(.battery) && !run.store.testPending(run.a) &&
            run.adapter.poweredOn && run.store.testPhase(run.a) == "connected"
        let admitted: Bool
        do { try run.store.testReadAdmission(run.a, profile: .battery); admitted = true } catch { admitted = false }
        XCTAssertEqual(admitted, batteryAvailable, "actual battery admission must match the real profile, grant and busy state")
        XCTAssertThrowsError(try run.store.authorizeLink(run.a, name: "light.get", arguments: nil), "discovery must not grant a tool")
        let bBattery = run.store.testDiscoveryProfileEndpoint(run.b, profile: .battery)
        let bAlert = run.store.testDiscoveryProfileEndpoint(run.b, profile: .alert)
        let bBase = bBattery === run.bBatteryEndpoint && bAlert === run.bAlertEndpoint &&
            run.store.testOwner(run.b) == run.bOwner && run.store.testPhysicalPeer(run.b) === run.bPeer &&
            run.store.testPhase(run.b) == "connected" && run.store.testIdentityChannel(run.b) == run.bChannel &&
            run.store.testIdentityClient(run.b) == run.bClient && b.taskIdentity.unicodeScalars.elementsEqual(run.bIdentity.unicodeScalars) &&
            b.pendingIdentity.unicodeScalars.elementsEqual(run.bPendingIdentity.unicodeScalars) && b.state == run.bState && b.linkState == run.bLinkState && b.profiles == run.bProfiles &&
            b.grantedTools == run.bTools && run.bDeadline?.state == "cancelled" && bDecl.read
        let peerB: String
        if bBase && !run.store.testPending(run.a) && !run.store.testPending(run.b) && run.adapter.poweredOn {
            XCTAssertNoThrow(try run.store.testReadAdmission(run.b, profile: .battery), "B read remains available when no read is pending")
        }
        if bBase && bDecl.alert { peerB = "unchanged" }
        else if bBase && !bDecl.alert { peerB = "alert-revoked" }
        else if run.store.testPhase(run.b) == "quarantined", !bDecl.read, !bDecl.alert, bBattery == nil, bAlert == nil,
                run.store.testIdentityChannel(run.b) == nil, run.store.testIdentityClient(run.b) == nil,
                b.taskIdentity.isEmpty, b.pendingIdentity.isEmpty, b.grantedTools.isEmpty { peerB = "quarantined" }
        else { peerB = "changed" }
        let preferences = try XCTUnwrap(run.defaults.object(forKey: BLETrustedIdentities.key) as? [String]).map { $0.unicodeScalars.map(\.value) }
        XCTAssertEqual(preferences, run.baselinePreferences, "legacy preferences changed")
        let pending: String
        if let read = run.activeRead {
            if let result = read.result {
                switch result {
                case .success(let value):
                    XCTAssertTrue(value.hasPrefix("37 % @ "))
                    let date = ISO8601DateFormatter().date(from: String(value.dropFirst("37 % @ ".count)))
                    XCTAssertNotNil(date)
                    if let date { XCTAssertGreaterThanOrEqual(date, run.started.addingTimeInterval(-1)); XCTAssertLessThanOrEqual(date, Date().addingTimeInterval(1)) }
                    pending = "value-once"
                case .failure(let error):
                    if !read.wasPending { pending = "rejected" }
                    else if error is CancellationError { pending = "cancelled-once" }
                    else if let failure = error as? BLEFailure, failure.message == "Device disconnected" { pending = "disconnected-once" }
                    else if (error as NSError).domain == "draft.read" && (error as NSError).code == 731 { pending = "error-once" }
                    else { pending = "unexpected-error" }
                }
            } else if run.store.testReadClaim(run.a) == "cancelled" { pending = "cancel-claimed" }
            else if run.store.testPending(run.a) { pending = "active" }
            else { pending = "missing" }
        } else { pending = "none" }
        func count(_ predicate: (BLEDeviceStore.TestCommand) -> Bool) -> Int { run.adapter.commands.filter(predicate).count }
        let timerIdentity = run.deadlineToken != nil && run.store.testConnectionDeadlineToken(run.a) == run.deadlineToken ? "same" : "changed"
        return [
            "phase": run.store.testPhase(run.a), "device_state": a.state, "timer": run.deadline?.state ?? "none",
            "timer_identity": timerIdentity, "profiles": a.profiles.map(\.rawValue), "link": link, "link_text": a.linkState,
            "characteristic_requests": characteristicRequests, "notify_endpoints": notify,
            "disconnects": count { if case .disconnect(let id) = $0 { return id == run.a }; return false },
            "service_requests": serviceRequests,
            "connect_submissions": count { if case .connect(let id) = $0 { return id == run.a }; return false },
            "read_submissions": count { if case .read(let id, _) = $0 { return id == run.a }; return false },
            "pending": pending, "read_completions": run.reads.map(\.completions).reduce(0,+), "peer_b": peerB,
            "grants_a": ["read": aDecl.read, "alert": aDecl.alert, "tools": a.grantedTools.sorted(), "task": a.allowDeviceTasks],
            "devices_notifications_delta": devicesDelta, "status_notifications_delta": statusDelta,
        ]
    }

    @MainActor private func executeSync(_ run: Run, _ event: [String: Any]) throws {
        let action = try string(event, "action")
        let peerName = event["peer"] as? String ?? "A"
        let id = run.id(peerName)
        func error() -> Error? {
            guard let value = event["error"] as? [String: Any], let domain = value["domain"] as? String,
                  let code = value["code"] as? Int else { return nil }
            return NSError(domain: domain, code: code, userInfo: [NSLocalizedDescriptionKey: value["message"] as? String ?? domain])
        }
        switch action {
        case "services":
            let values = (event["items"] as? [String]).map { names in try? names.map(run.service) } ?? nil
            if event["items"] is [String], values == nil { throw BLEFailure("unknown service object") }
            run.store.testDiscoveryServices(id, peer: try run.peer(peerName), services: values, error: error())
        case "characteristics":
            let values = (event["items"] as? [String]).map { names in try? names.map(run.characteristic) } ?? nil
            if event["items"] is [String], values == nil { throw BLEFailure("unknown characteristic object") }
            run.store.testDiscoveryCharacteristics(id, peer: try run.peer(peerName), service: try run.service(string(event, "service")), characteristics: values, error: error())
        case "physical_properties":
            let object = try run.characteristic(string(event, "object"))
            object.properties = Run.properties(try XCTUnwrap(event["properties"] as? [String]))
        case "physical_primary":
            try run.service(string(event, "object")).primary = XCTUnwrap(event["primary"] as? Bool)
        case "physical_uuid":
            let object = try XCTUnwrap(run.objects[string(event, "object")])
            if let characteristic = object as? BLEDeviceStore.TestCharacteristic { characteristic.uuid = try string(event, "uuid") }
            else if let service = object as? BLEDeviceStore.TestService { service.uuid = try string(event, "uuid") }
            else { throw BLEFailure("cannot mutate UUID on this physical object") }
        case "fire_discovery_timeout": try XCTUnwrap(run.deadline).invoke()
        case "grant_read": run.store.grant(id, read: true)
        case "grant_b_alert": run.store.grant(run.b, alert: try XCTUnwrap(event["enabled"] as? Bool))
        case "set_powered": run.adapter.poweredOn = try XCTUnwrap(event["powered"] as? Bool)
        case "service_change":
            let services = try XCTUnwrap(event["items"] as? [String]).map(run.service)
            run.store.testServicesModified(id, invalidated: services)
        case "read_value":
            let bytes = try XCTUnwrap(event["bytes"] as? [Int]).map { UInt8($0) }
            run.store.testValue(id, profile: .battery, data: Data(bytes), error: error())
        case "cancel_read_background_and_wait":
            let task = try XCTUnwrap(run.activeRead?.task)
            XCTAssertTrue(run.cancelOffMain(task))
            XCTAssertEqual(run.store.testReadClaim(run.a), "cancelled", "real cancellation must claim before cleanup")
        default: throw BLEFailure("unknown synchronous fixture action: \(action)")
        }
    }

    @MainActor private func runStep(_ run: Run, _ step: [String: Any], index: Int) async throws -> [String: Any] {
        let action = try string(step, "action")
        let beforeDevices = run.meter.devices, beforeStatus = run.meter.status
        if let inject = step["inject"] as? [String: Any] {
            let point = try string(inject, "point"), nested = try dict(inject, "event")
            let target = (inject["service"] as? String).flatMap { run.objects[$0] }
            let trigger = {
                guard run.injectedActions[index, default: 0] == 0 else { return }
                run.injectedActions[index, default: 0] += 1
                let devices = run.meter.devices, status = run.meter.status
                do {
                    try self.executeSync(run, nested)
                    run.injectedSnapshots[index] = try self.snapshot(run,
                        devicesDelta: run.meter.devices - devices, statusDelta: run.meter.status - status)
                } catch { XCTFail("nested step \(index): \(error)") }
            }
            switch point {
            case "before_characteristic_reservation":
                run.adapter.beforeCharacteristicReserve = { id, service in if id == run.a && service === target { trigger() } }
            case "after_characteristic_submit":
                run.adapter.afterCharacteristicSubmit = { id, service in if id == run.a && service === target { trigger() } }
            case "devices_will_change": run.meter.actionCount = 0; run.meter.deviceAction = trigger
            case "after_read_value_claim": run.adapter.afterReadValueClaim = trigger
            default: throw BLEFailure("unknown injection point: \(point)")
            }
        }
        if action == "start_read" {
            let probe = ReadProbe(); run.activeRead = probe; run.reads.append(probe); probe.start(run.store, id: run.a)
            try await run.wait({ run.store.testPending(run.a) || probe.result != nil }, label: "real read admission")
            probe.wasPending = run.store.testPending(run.a)
        } else { try executeSync(run, step) }
        let expected = try dict(step, "expect")
        let expectedPending = expected["pending"] as? String ?? "none"
        if ["value-once", "error-once", "cancelled-once", "disconnected-once"].contains(expectedPending), let probe = run.activeRead {
            try await run.wait({ probe.result != nil }, label: "read completion")
        }
        run.adapter.beforeCharacteristicReserve = nil; run.adapter.afterCharacteristicSubmit = nil
        run.adapter.afterReadValueClaim = nil; run.meter.deviceAction = nil
        let actual = try snapshot(run, devicesDelta: run.meter.devices - beforeDevices, statusDelta: run.meter.status - beforeStatus)
        if expectedPending == "rejected" { run.activeRead = nil }
        return actual
    }

    func testComparatorRejectsTypeConfusion() {
        XCTAssertFalse(sameValue("1", ["1"]))
        XCTAssertFalse(sameValue(NSNull(), ["x": 1]))
        XCTAssertFalse(sameValue(true, 1))
        XCTAssertFalse(sameValue(false, 0))
        XCTAssertFalse(matches(["result": true], ["result": 1]))
        XCTAssertFalse(matches(["result": "x"], ["result": ["x"]]))
        XCTAssertTrue(sameValue(["values": [1, 2], "flag": true], ["values": [1, 2], "flag": true]))
    }

    @MainActor func testAllSharedDiscoveryVectorsAndSemanticMutations() async throws {
        let rows = try vectors()
        XCTAssertEqual(rows.count, 66)
        XCTAssertEqual(Set(rows.compactMap { $0["id"] as? String }).count, rows.count)
        let mutations = try XCTUnwrap(try json("standard-gatt-discovery-mutations") as? [[String: Any]])
        let semantic = mutations.filter { $0["category"] as? String == "semantic" }
        XCTAssertEqual(semantic.count, 10)
        var comparedMutations = Set<String>()
        for row in rows {
            let id = try string(row, "id")
            let run = try Run(row)
            defer { run.cleanup() }
            do {
                try await run.setup()
                let steps = try array(row, "steps")
                var top: [Int: [String: Any]] = [:]
                for (index, step) in steps.enumerated() {
                    let actual = try await runStep(run, step, index: index)
                    let expected = try dict(step, "expect")
                    XCTAssertTrue(matches(actual, expected), "\(id) step \(index): actual \(actual), expected \(expected)")
                    top[index] = actual
                    if let inject = step["inject"] as? [String: Any] {
                        XCTAssertEqual(run.injectedActions[index], 1, "\(id) step \(index): actual hook")
                        if let nestedExpected = inject["expect"] as? [String: Any] {
                            let nestedActual = try XCTUnwrap(run.injectedSnapshots[index], "\(id) missing nested checkpoint")
                            XCTAssertTrue(matches(nestedActual, nestedExpected), "\(id) nested step \(index): actual \(nestedActual), expected \(nestedExpected)")
                        }
                    }
                    XCTAssertLessThan(run.meter.devices, 100, id); XCTAssertLessThan(run.meter.status, 100, id)
                }
                for mutation in semantic where mutation["base"] as? String == id {
                    let name = try string(mutation, "name")
                    let path = try XCTUnwrap(mutation["path"] as? [Any])
                    XCTAssertEqual(path.first as? String, "steps", name)
                    let index = try XCTUnwrap(path[1] as? Int, name)
                    let field = try XCTUnwrap(path.last as? String, name)
                    let nested = path.contains { ($0 as? String) == "inject" }
                    let actual = try XCTUnwrap(nested ? run.injectedSnapshots[index] : top[index], name)
                    var expected: [String: Any]
                    if nested { expected = try dict(try dict(steps[index], "inject"), "expect") }
                    else { expected = try dict(steps[index], "expect") }
                    expected[field] = try XCTUnwrap(mutation["value"], name)
                    XCTAssertFalse(matches(actual, expected), "real comparator accepted mutation \(name)")
                    comparedMutations.insert(name)
                }
                run.activeRead?.task?.cancel()
            } catch {
                run.activeRead?.task?.cancel()
                XCTFail("\(id): \(error)")
            }
        }
        XCTAssertEqual(comparedMutations, Set(semantic.compactMap { $0["name"] as? String }))
    }

    @MainActor private func freshRun() async throws -> Run {
        let rows = try vectors()
        let row = try XCTUnwrap(rows.first { $0["id"] as? String == "one-link-complete" })
        let run = try Run(row); try await run.setup(); return run
    }
    @MainActor private func activateA(_ run: Run) async throws -> PhysicalPeer {
        let physical = try run.peer("A"), service = try run.service("L1")
        run.store.testDiscoveryServices(run.a, peer: physical, services: [service])
        run.store.testDiscoveryCharacteristics(run.a, peer: physical, service: service,
            characteristics: try [run.characteristic("rx"), run.characteristic("tx"), run.characteristic("audio")])
        let fake = try run.attachPhysicalPeer(run.a)
        run.store.testDiscoveryNotification(run.a, peer: physical, characteristic: try run.characteristic("tx"), notifying: true)
        run.store.testDiscoveryNotification(run.a, peer: physical, characteristic: try run.characteristic("audio"), notifying: true)
        try await run.wait({ run.store.testIdentityClient(run.a) != nil || fake.failed != nil }, label: "A real Link handshake/tools-list")
        if let error = fake.failed { throw error }
        XCTAssertNotNil(run.store.testIdentityClient(run.a))
        run.store.grantLinkTool(run.a, name: "light.get", enabled: true)
        try run.store.authorizeLink(run.a, name: "light.get", arguments: nil)
        return fake
    }

    @MainActor func testActualLinkInFlightFailsOnceOnChangedDiscovery() async throws {
        let run = try await freshRun(); defer { run.cleanup() }
        let fake = try await activateA(run)
        let beforeEvents = run.store.testCommittedLinkEventCount(run.a)
        let eventText = "{\"boot_id\":1,\"device_id\":\"\(run.a.uuidString.lowercased())\",\"event_id\":\"00000001-00000001\",\"seq\":1,\"type\":\"status\",\"payload\":{}}"
        for frame in try PDSHLink.Envelope(opcode: 0x6c, requestID: 0, body: Data(eventText.utf8)).segments(writeLimit: 20) {
            run.store.testLinkSegment(run.a, physical: fake.physical, endpoint: fake.tx, data: frame)
        }
        XCTAssertEqual(run.store.testCommittedLinkEventCount(run.a), beforeEvents + 1)
        let request = UUID(); fake.resultRequest = request; fake.holdNextQuery = true
        var result: Result<JSONValue?, Error>?, completions = 0
        let task = Task { @MainActor in
            do { result = .success(try await run.store.queryLink(run.a, requestID: request, name: "light.get")) }
            catch { result = .failure(error) }
            completions += 1
        }
        try await run.wait({ fake.heldResponse != nil && run.store.testLinkExchangePending(run.a) }, label: "actual Link continuation")
        let oldReceive = try XCTUnwrap(run.store.testCaptureLinkReceiveCount(run.a)), beforeReceive = oldReceive()
        let writes = fake.writeCount
        run.adapter.commands.removeAll()
        run.store.testDiscoveryCharacteristics(run.a, peer: try run.peer("A"), service: try run.service("L1"),
                                               characteristics: try [run.characteristic("rx"), run.characteristic("tx")])
        await task.value
        XCTAssertEqual(completions, 1)
        guard case .failure(let error)? = result else { XCTFail("submitted Link result must be outcome unknown"); return }
        XCTAssertTrue(((error as? BLEFailure)?.message ?? error.localizedDescription).contains("outcome_unknown"))
        XCTAssertEqual(run.store.testPhase(run.a), "quarantined")
        XCTAssertEqual(run.adapter.commands.filter { if case .disconnect(let id) = $0 { return id == run.a }; return false }.count, 1)
        fake.deliverHeld()
        XCTAssertEqual(completions, 1); XCTAssertEqual(oldReceive(), beforeReceive)
        XCTAssertEqual(fake.writeCount, writes, "old response must not replay physical requests")
        XCTAssertEqual(fake.submittedOpcodes.filter { $0 == 0x55 }.count, 1, "only setup tools/list was committed")
        XCTAssertEqual(run.store.testOwner(run.b), run.bOwner); XCTAssertEqual(run.store.testIdentityChannel(run.b), run.bChannel)
    }

    @MainActor func testClosingLateCallbackAndUnrequestedOldServiceAfterReconnect() async throws {
        let run = try await freshRun(); defer { run.cleanup() }
        let physical = try run.peer("A"), service = try run.service("S1"), oldValue = try run.characteristic("bat1")
        run.store.testDiscoveryServices(run.a, peer: physical, services: [service])
        run.store.testDiscoveryCharacteristics(run.a, peer: physical, service: service, characteristics: [oldValue])
        XCTAssertTrue(try run.device(run.a).profiles.contains(.battery))
        let owner = try XCTUnwrap(run.store.testOwner(run.a))
        run.adapter.commands.removeAll(); run.store.disconnect(run.a)
        let afterDisconnectRequest = run.adapter.commands.count
        run.store.testDiscoveryCharacteristics(run.a, peer: physical, service: service, characteristics: [oldValue])
        XCTAssertEqual(run.store.testPhase(run.a), "closing")
        XCTAssertEqual(run.adapter.commands.count, afterDisconnectRequest)
        run.store.testDidDisconnect(run.a, during: {
            let count = run.adapter.commands.count; run.store.connect(run.a)
            XCTAssertEqual(run.adapter.commands.count, count, "cannot reconnect inside didDisconnect")
        })
        try await run.wait({ run.store.testPhase(run.a) == "idle" }, label: "disconnect callback return")
        run.store.connect(run.a); run.store.testDidConnect(run.a)
        XCTAssertNotEqual(run.store.testOwner(run.a), owner)
        run.store.testDiscoveryServices(run.a, peer: physical, services: try [run.service("S2")])
        run.adapter.commands.removeAll()
        // The distinct old service was not submitted in the new ledger.
        run.store.testDiscoveryCharacteristics(run.a, peer: physical, service: service, characteristics: [oldValue])
        XCTAssertEqual(run.store.testPhase(run.a), "quarantined")
        XCTAssertEqual(run.adapter.commands.filter { if case .disconnect(let id) = $0 { return id == run.a }; return false }.count, 1)
        XCTAssertEqual(run.store.testOwner(run.b), run.bOwner); XCTAssertEqual(run.store.testIdentityChannel(run.b), run.bChannel)
    }

    @MainActor func testExpectedDiscoveryErrorClaimsBeforeStatusObserverReentry() async throws {
        for kind in ["services", "characteristics"] {
            let run = try await freshRun(); defer { run.cleanup() }
            let physical = try run.peer("A"), service = try run.service("S1")
            if kind == "characteristics" { run.store.testDiscoveryServices(run.a, peer: physical, services: [service]) }
            run.adapter.commands.removeAll(); run.adapter.discoverySubmissions.removeAll(); run.adapter.notifyEndpoints.removeAll()
            run.meter.statusAction = {
                XCTAssertEqual(run.store.testPhase(run.a), "closing", kind)
                if kind == "services" { run.store.testDiscoveryServices(run.a, peer: physical, services: [service]) }
                else {
                    do { run.store.testDiscoveryCharacteristics(run.a, peer: physical, service: service, characteristics: try [run.characteristic("bat1")]) }
                    catch { XCTFail("\(kind): \(error)") }
                }
            }
            let error = NSError(domain: "draft.discovery", code: 17, userInfo: [NSLocalizedDescriptionKey: "expected discovery error"])
            if kind == "services" { run.store.testDiscoveryServices(run.a, peer: physical, services: nil, error: error) }
            else { run.store.testDiscoveryCharacteristics(run.a, peer: physical, service: service, characteristics: nil, error: error) }
            run.meter.statusAction = nil
            XCTAssertEqual(run.meter.statusActionCount, 1, kind)
            XCTAssertEqual(run.store.testPhase(run.a), "closing", kind)
            XCTAssertEqual(try run.device(run.a).profiles, [], kind)
            XCTAssertNil(run.store.testIdentityChannel(run.a), kind)
            XCTAssertEqual(run.adapter.discoverySubmissions.filter { $0.id == run.a }.count, 0, kind)
            XCTAssertTrue(run.adapter.notifyEndpoints.isEmpty, kind)
            XCTAssertEqual(run.adapter.commands.filter { if case .disconnect(let id) = $0 { return id == run.a }; return false }.count, 1, kind)
            XCTAssertEqual(run.store.status, "expected discovery error", kind)
            XCTAssertEqual(run.store.testOwner(run.b), run.bOwner, kind)
        }
    }

    @MainActor func testErrorObserverCannotReconnectUntilRealDisconnectReturns() async throws {
        let run = try await freshRun(); defer { run.cleanup() }
        let physical = try run.peer("A"), oldOwner = try XCTUnwrap(run.store.testOwner(run.a))
        let oldDeadline = try XCTUnwrap(run.deadline)
        run.adapter.commands.removeAll()
        run.meter.statusAction = {
            run.store.testDidDisconnect(run.a, during: {
                let before = run.adapter.commands.count
                run.store.connect(run.a)
                XCTAssertEqual(run.adapter.commands.count, before)
            })
        }
        run.store.testDiscoveryServices(run.a, peer: physical, services: nil,
            error: NSError(domain: "draft.discovery", code: 17, userInfo: [NSLocalizedDescriptionKey: "expected discovery error"]))
        run.meter.statusAction = nil
        XCTAssertEqual(run.meter.statusActionCount, 1)
        try await run.wait({ run.store.testPhase(run.a) == "idle" }, label: "real disconnect boundary")
        run.store.connect(run.a); run.store.testDidConnect(run.a)
        let newOwner = try XCTUnwrap(run.store.testOwner(run.a))
        XCTAssertNotEqual(newOwner, oldOwner)
        let before = run.adapter.commands.count
        oldDeadline.invoke()
        XCTAssertEqual(run.store.testOwner(run.a), newOwner)
        XCTAssertEqual(run.store.testPhase(run.a), "connected")
        XCTAssertEqual(run.adapter.commands.count, before)
    }

    @MainActor func testPowerOffInsideLinkInstallationStopsAllOldPublication() async throws {
        let run = try await freshRun(); defer { run.cleanup() }
        let physical = try run.peer("A"), service = try run.service("L1")
        run.store.testDiscoveryServices(run.a, peer: physical, services: [service])
        run.adapter.notifyEndpoints.removeAll(); run.adapter.commands.removeAll()
        let beforeState = try run.device(run.a)
        run.meter.actionCount = 0
        run.meter.deviceAction = { run.adapter.poweredOn = false }
        run.store.testDiscoveryCharacteristics(run.a, peer: physical, service: service,
            characteristics: try [run.characteristic("rx"), run.characteristic("tx"), run.characteristic("audio")])
        run.meter.deviceAction = nil
        XCTAssertEqual(run.meter.actionCount, 1)
        XCTAssertTrue(run.adapter.notifyEndpoints.isEmpty)
        XCTAssertFalse(run.adapter.commands.contains { if case .notify(let id) = $0 { return id == run.a }; return false })
        XCTAssertEqual(run.store.testPhase(run.a), "quarantined"); XCTAssertEqual(run.store.testPhase(run.b), "quarantined")
        XCTAssertNil(run.store.testIdentityChannel(run.a)); XCTAssertNil(run.store.testIdentityClient(run.a))
        XCTAssertNil(run.store.testIdentityChannel(run.b)); XCTAssertNil(run.store.testIdentityClient(run.b))
        let a = try run.device(run.a), b = try run.device(run.b)
        XCTAssertTrue(a.taskIdentity.isEmpty); XCTAssertTrue(a.pendingIdentity.isEmpty); XCTAssertTrue(a.linkIdentity.isEmpty)
        XCTAssertTrue(b.taskIdentity.isEmpty); XCTAssertTrue(b.pendingIdentity.isEmpty)
        XCTAssertFalse(b.allowRead); XCTAssertFalse(b.allowAlert)
        XCTAssertTrue(beforeState.taskIdentity.isEmpty && beforeState.pendingIdentity.isEmpty)
        XCTAssertFalse(run.adapter.commands.contains { if case .disconnect = $0 { return true }; return false })
    }
}
#endif
