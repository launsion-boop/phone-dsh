// SPDX-License-Identifier: MIT
import CoreBluetooth
import Foundation
import Observation
import PhoneDSHAgentCore
import XCTest
@testable import PhoneDSHBLE

#if DEBUG
/// Frozen service-change-v1 vectors; simulated objects are not OS tokens.
final class StandardGattServiceChangeTests: XCTestCase {
    private struct Vector: Decodable, Equatable {
        let scenario: String, invalidated: String, hook: String, initialPending: String
        var aPhase: String, bPhase: String
        var aRead: Bool, aAlert: Bool, bRead: Bool, bAlert: Bool
        var aIdentity: String, aLink: String, bIdentity: String, bLink: String
        var pendingResult: String, timer: String, linkOutcome: String
        var aDisconnects: Int, bDisconnects: Int, aConnects: Int
        var extraReads: Int, extraAlerts: Int, extraNotifies: Int, extraLinks: Int
        var lateLinkEvents: Int, currentLinkEvents: Int, pendingCompletions: Int
        var legacyUnchanged: Bool, admissionCheck: String, prepublication: String
        let identityVariant: String
    }
    private func vectors() throws -> [Vector] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("spec/device/v1/golden/standard-gatt-service-change.jsonl")
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try String(contentsOf: url, encoding: .utf8).split(whereSeparator: \.isNewline)
            .map { try decoder.decode(Vector.self, from: Data($0.utf8)) }
    }
    @MainActor private final class ReadProbe {
        var task: Task<Void, Never>?
        var result: Result<String, Error>?
        var completions = 0
        func start(_ store: BLEDeviceStore, id: UUID) {
            task = Task { @MainActor in
                do { result = .success(try await store.read(id, profile: .battery)) }
                catch { result = .failure(error) }
                completions += 1
            }
        }
    }
    @MainActor private final class AdmissionProbe {
        var continuation: CheckedContinuation<String, Error>?
        var task: Task<Void, Never>?
        var completed = false
        func prepare() async throws {
            task = Task { @MainActor in
                _ = try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                    self.continuation = continuation
                }
                completed = true
            }
            for _ in 0..<200 {
                if continuation != nil { return }
                try await Task.sleep(for: .milliseconds(5))
            }
            throw BLEFailure("admission continuation not prepared")
        }
        func attempt(_ store: BLEDeviceStore, id: UUID) -> Bool {
            guard let current = continuation else { XCTFail("admission attempted twice"); return false }
            continuation = nil
            do {
                try store.testInstallPending(id, profile: .battery, continuation: current)
                return false
            } catch {
                current.resume(throwing: error)
                return true
            }
        }
    }
    @MainActor private final class Watch {
        var calls = 0, actions = 0
        var action: (() -> Void)?
        func install(_ store: BLEDeviceStore) {
            withObservationTracking { _ = store.devices } onChange: {
                MainActor.assumeIsolated {
                    self.calls += 1
                    if self.calls < 9 { self.install(store) }
                    if self.actions == 0, let action = self.action { self.actions += 1; action() }
                }
            }
        }
    }
    /// Physical bytes only: the production channel retains framing, write
    /// sequencing, continuation, timeout and response reassembly ownership.
    @MainActor private final class PhysicalPeer {
        let id: UUID
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
            self.id = id; self.store = store; self.physical = physical; self.tx = tx; self.rx = rx
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
                    "result": .object(["device_id": .string("ce6ec956-1111-4222-8333-123456789abc"),
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
        let a = UUID(), b = UUID()
        let deviceID = "ce6ec956-1111-4222-8333-123456789abc"
        let suite: String
        let defaults: UserDefaults
        let adapter: BLEDeviceStore.TestAdapter
        let store: BLEDeviceStore
        let watch = Watch()
        let admissionProbe = AdmissionProbe()
        var knownServices: [UUID: AnyObject] = [:]
        let unrelatedService = NSObject()
        var read: ReadProbe?
        var timer: BLEDeviceStore.TestTimerProbe?
        var baselineLegacy: [[UInt32]]?
        var baselineAEvents = 0, baselineBEvents = 0
        var aChannel: ObjectIdentifier?, bChannel: ObjectIdentifier?
        var aClient: ObjectIdentifier?, bClient: ObjectIdentifier?
        var aRevision: ObjectIdentifier?, bRevision: ObjectIdentifier?
        var aIdentity = "", aPendingIdentity = "", bIdentity = "", bPendingIdentity = ""
        var aTools: Set<String> = [], bTools: Set<String> = []
        var prepublication = "no-publish", admission = "not-tested"
        var began = Date(), ended = Date()
        var linkOutcomes: [UUID: String] = [:]
        var linkTask: Task<Void, Never>?
        var linkCompletions: [UUID: Int] = [:]
        var baselineLinkWrites: [UUID: Int] = [:]
        var hookActions = 0, pendingAdmissionAttempts = 0
        var peers: [UUID: PhysicalPeer] = [:]
        var oldTX: AnyObject?, oldPhysical: AnyObject?
        var oldReceiveCount: (() -> Int)?
        var baselineOldReceive = 0

        init() throws {
            suite = "PhoneDSH.ServiceChange." + UUID().uuidString
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            adapter = BLEDeviceStore.TestAdapter(); adapter.identityDefaults = defaults
            store = BLEDeviceStore(testAdapter: adapter, testDevices: [
                .init(id: a, name: "A", rssi: -40), .init(id: b, name: "B", rssi: -50)
            ])
        }
        func cleanup() { defaults.removePersistentDomain(forName: suite) }
        func device(_ id: UUID) throws -> BLEDeviceStore.Device { try XCTUnwrap(store.devices.first { $0.id == id }) }
        func connect(_ id: UUID, pendingIdentity: Bool = false, writeLimit: Int = 244) {
            store.connect(id); store.testDidConnect(id); store.testDiscover(id, profiles: [.battery, .alert])
            store.grant(id, read: true, alert: true)
            store.testPrepareLink(id, bootID: 1, deviceID: deviceID, writeLimit: writeLimit)
            store.testInstallIdentityClient(id, reuse: false)
            store.testSetIdentityPending(id, label: "legacy:" + id.uuidString)
            if !pendingIdentity { store.trustPendingIdentity(id) }
            store.grantLinkTool(id, name: "light.get", enabled: true)
        }
        func startRead() async throws {
            let probe = ReadProbe(); read = probe; probe.start(store, id: a)
            for _ in 0..<200 {
                if store.testPending(a) { timer = store.testCaptureReadTimeout(); return }
                if probe.result != nil { throw BLEFailure("read failed before becoming pending") }
                try await Task.sleep(for: .milliseconds(5))
            }
            throw BLEFailure("read did not become pending")
        }
        func waitRead() async throws {
            guard let read else { throw BLEFailure("missing read") }
            for _ in 0..<200 {
                if read.result != nil { return }
                try await Task.sleep(for: .milliseconds(5))
            }
            throw BLEFailure("read did not finish")
        }
        func waitPhase(_ expected: String) async throws {
            for _ in 0..<200 {
                if store.testPhase(a) == expected { return }
                try await Task.sleep(for: .milliseconds(5))
            }
            throw BLEFailure("phase did not become \(expected)")
        }
        func cancelOffMain(_ task: Task<Void, Never>) -> Bool {
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async { task.cancel(); done.signal() }
            return done.wait(timeout: .now() + 2) == .success
        }
        func event(_ id: UUID, sequence: UInt32) throws {
            let body = "{\"boot_id\":1,\"device_id\":\"\(deviceID)\",\"event_id\":\"00000001-\(String(format: "%08x", sequence))\",\"seq\":\(sequence),\"type\":\"status\",\"payload\":{}}"
            let envelope = PDSHLink.Envelope(opcode: 0x6c, requestID: 0, body: Data(body.utf8))
            for segment in try envelope.segments(writeLimit: 20) { store.testLinkEvent(id, segment: segment) }
        }
        func sendOldFrame(_ target: UUID) throws {
            let tx = try XCTUnwrap(oldTX), physical = try XCTUnwrap(oldPhysical)
            let receive = try XCTUnwrap(oldReceiveCount)
            let before = receive()
            let body = "{\"boot_id\":1,\"device_id\":\"\(deviceID)\",\"event_id\":\"00000001-00000002\",\"seq\":2,\"type\":\"status\",\"payload\":{}}"
            let envelope = PDSHLink.Envelope(opcode: 0x6c, requestID: 0, body: Data(body.utf8))
            for frame in try envelope.segments(writeLimit: 20) {
                store.testLinkSegment(target, physical: physical, endpoint: tx, data: frame)
            }
            XCTAssertEqual(receive(), before, "old channel receiver must not be called")
        }
        func serviceObjects(_ kind: String, device: UUID) -> [AnyObject] {
            switch kind {
            case "empty": return []
            case "known": return knownServices[device == b ? b : a].map { [$0] } ?? []
            default: return [unrelatedService]
            }
        }
        func change(_ id: UUID, invalidated: String, matching: Bool = true) {
            let objects = serviceObjects(invalidated, device: id)
            if invalidated == "known" { XCTAssertEqual(objects.count, 1, "fixture requires the device's discovered service") }
            if id == b, invalidated == "known" {
                XCTAssertTrue(objects.first === knownServices[b])
                XCTAssertFalse(objects.first === knownServices[a])
            }
            store.testServicesModified(id, matchingPeer: matching, invalidated: objects)
        }
        func installPhysicalPeer(_ id: UUID, pendingIdentity: Bool = false) async throws {
            let tx = try XCTUnwrap(store.testLinkTXEndpoint(id))
            let transport = try XCTUnwrap(store.testCurrentLinkTransport(id))
            let rx = try XCTUnwrap(store.testLinkRXEndpoint(id))
            let physical = try XCTUnwrap(store.testLinkPhysicalPeer(id))
            let fake = PhysicalPeer(id: id, store: store, physical: physical, tx: tx, rx: rx); peers[id] = fake
            adapter.onLinkWrite = { [weak self] device, bytes in self?.peers[device]?.wrote(bytes) }
            let client = PDSHLinkClient(transport: transport)
            let hello = try await client.handshake()
            let owner = try XCTUnwrap(store.testOwner(id)), channel = try XCTUnwrap(store.testIdentityChannel(id))
            try await store.discoverLinkTools(id, client: client, bootID: hello.bootID) {
                self.store.testOwner(id) == owner && self.store.testIdentityChannel(id) == channel
            }
            store.grantLinkTool(id, name: "light.get", enabled: true)
            store.testSetIdentityPending(id, label: "legacy:" + id.uuidString)
            if !pendingIdentity { store.trustPendingIdentity(id) }
            XCTAssertTrue(try device(id).grantedTools.contains("light.get"))
            try store.authorizeLink(id, name: "light.get", arguments: nil)
            if let failed = fake.failed { throw failed }
        }
        func startLinkQuery(hold: Bool) async throws {
            guard let peer = peers[a] else { throw BLEFailure("missing physical peer") }
            let id = UUID(); peer.resultRequest = id; peer.holdNextQuery = hold
            linkTask = Task { @MainActor in
                do {
                    let value = try await store.queryLink(a, requestID: id, name: "light.get")
                    if value?["status"]?.stringValue == "completed", value?["result"]?["value"]?.intValue == 42 {
                        linkOutcomes[a] = "completed"
                    } else { linkOutcomes[a] = "unexpected-result" }
                } catch {
                    let text = (error as? BLEFailure)?.message ?? error.localizedDescription
                    linkOutcomes[a] = text.contains("outcome_unknown") ? "outcome-unknown" : "unexpected-error: \(text)"
                }
                linkCompletions[a, default: 0] += 1
            }
            for _ in 0..<200 {
                if hold && peer.heldResponse != nil && store.testLinkExchangePending(a) { return }
                if !hold && linkCompletions[a] == 1 { return }
                if let failed = peer.failed { throw failed }
                try await Task.sleep(for: .milliseconds(5))
            }
            throw BLEFailure("real Link query failed to reach controlled checkpoint")
        }
        func prepare(_ row: Vector) async throws {
            store.testRadioOn(); defaults.set(["legacy:café", "legacy:cafe\u{301}"], forKey: BLETrustedIdentities.key)
            connect(b); try await installPhysicalPeer(b)
            knownServices[b] = try XCTUnwrap(store.testKnownService(b), row.scenario)
            if row.scenario == "connecting-modification" {
                // Retain an actually discovered A service from a prior local
                // connection; it is not proof of the new radio attempt's epoch.
                connect(a)
                knownServices[a] = try XCTUnwrap(store.testKnownService(a), row.scenario)
                oldTX = try XCTUnwrap(store.testLinkTXEndpoint(a), row.scenario)
                oldPhysical = try XCTUnwrap(store.testLinkPhysicalPeer(a), row.scenario)
                oldReceiveCount = try XCTUnwrap(store.testCaptureLinkReceiveCount(a), row.scenario)
                store.disconnect(a); store.testDidDisconnect(a)
                try await waitPhase("idle")
                store.connect(a)
            } else {
                connect(a, pendingIdentity: row.identityVariant == "pending")
                try await installPhysicalPeer(a, pendingIdentity: row.identityVariant == "pending")
            }
            if row.scenario != "connecting-modification" {
                knownServices[a] = try XCTUnwrap(store.testKnownService(a), row.scenario)
                try event(a, sequence: 1); XCTAssertEqual(store.testLinkDeliveries(a), 1)
            }
            try event(b, sequence: 1); XCTAssertEqual(store.testLinkDeliveries(b), 1)
            XCTAssertFalse(knownServices[a] === knownServices[b], row.scenario)
            aChannel = store.testIdentityChannel(a); bChannel = store.testIdentityChannel(b)
            aClient = store.testIdentityClient(a); bClient = store.testIdentityClient(b)
            aRevision = store.testIdentityRevision(a); bRevision = store.testIdentityRevision(b)
            let av = try device(a), bv = try device(b)
            aIdentity = av.taskIdentity; aPendingIdentity = av.pendingIdentity
            bIdentity = bv.taskIdentity; bPendingIdentity = bv.pendingIdentity
            aTools = av.grantedTools; bTools = bv.grantedTools
            func scalarValues(_ text: String) -> [UInt32] { text.unicodeScalars.map(\.value) }
            let expectedA = "legacy:" + a.uuidString, expectedB = "legacy:" + b.uuidString
            XCTAssertEqual(scalarValues(bIdentity), scalarValues(expectedB), row.scenario)
            XCTAssertTrue(bPendingIdentity.isEmpty, row.scenario)
            XCTAssertEqual(bTools, ["light.get"], row.scenario)
            switch row.identityVariant {
            case "recorded":
                XCTAssertEqual(scalarValues(aIdentity), scalarValues(expectedA), row.scenario)
                XCTAssertTrue(aPendingIdentity.isEmpty, row.scenario)
                XCTAssertEqual(aTools, ["light.get"], row.scenario)
            case "pending":
                XCTAssertTrue(aIdentity.isEmpty, row.scenario)
                XCTAssertEqual(scalarValues(aPendingIdentity), scalarValues(expectedA), row.scenario)
                XCTAssertEqual(aTools, ["light.get"], row.scenario)
            case "none":
                XCTAssertTrue(aIdentity.isEmpty && aPendingIdentity.isEmpty && aTools.isEmpty, row.scenario)
            default: XCTFail("Unknown identity setup variant: \(row.identityVariant)")
            }
            baselineLegacy = (defaults.object(forKey: BLETrustedIdentities.key) as? [String])?.map { $0.unicodeScalars.map(\.value) }
            XCTAssertNotNil(baselineLegacy)
            if row.initialPending == "a", !["before-reserve", "after-reserve"].contains(row.hook) { try await startRead() }
            if row.scenario == "link-inflight" { try await startLinkQuery(hold: true) }
            if row.scenario == "link-completed" { try await startLinkQuery(hold: false) }
            let oldDevice = row.scenario == "other-device-change" ? b : a
            if row.scenario != "connecting-modification" {
                oldTX = store.testLinkTXEndpoint(oldDevice)
                oldPhysical = store.testLinkPhysicalPeer(oldDevice)
                oldReceiveCount = store.testCaptureLinkReceiveCount(oldDevice)
            }
            baselineOldReceive = oldReceiveCount?() ?? 0
            baselineAEvents = store.testCommittedLinkEventCount(a); baselineBEvents = store.testCommittedLinkEventCount(b)
            baselineLinkWrites[a] = adapter.linkWrites.filter { $0.0 == a }.count
            baselineLinkWrites[b] = adapter.linkWrites.filter { $0.0 == b }.count
            adapter.commands.removeAll(); began = Date()
        }
        func snapshotPrepublication(_ row: Vector) {
            let target = row.scenario == "other-device-change" ? b : a
            let unavailable = ["closing", "quarantined"].contains(store.testPhase(target))
            let declarations = store.testDeclarations(target)
            let channelGone = store.testIdentityChannel(target) == nil && store.testIdentityClient(target) == nil
            let oldRevision = target == a ? aRevision : bRevision
            let provenanceInvalidated = oldRevision != nil && store.testIdentityRevision(target) != oldRevision
            let pendingDetached = !store.testPending(target)
            let timerDone = target != a || timer == nil || ["none", "cancelled"].contains(timer!.state)
            var okay = unavailable && !declarations.read && !declarations.alert && channelGone && provenanceInvalidated && pendingDetached && timerDone
            if row.scenario.hasPrefix("manager-off") || row.scenario == "unknown-device-off" {
                let bGrant = store.testDeclarations(b)
                let bLinkDenied: Bool
                do { try store.authorizeLink(b, name: "light.get", arguments: nil); bLinkDenied = false }
                catch { bLinkDenied = true }
                okay = okay && bLinkDenied && store.testPhase(b) == "quarantined" && !bGrant.read && !bGrant.alert &&
                    store.testIdentityChannel(b) == nil && store.testIdentityClient(b) == nil &&
                    bRevision != nil && store.testIdentityRevision(b) != bRevision
            }
            prepublication = okay ? "revoked" : "not-revoked"
        }
        func deniedSynchronously(_ id: UUID) -> Bool {
            let deniedRead = admissionProbe.attempt(store, id: id)
            let deniedAlert: Bool
            do { _ = try store.alert(id, level: 1); deniedAlert = false } catch { deniedAlert = true }
            let deniedLink: Bool
            do { try store.authorizeLink(id, name: "light.get", arguments: nil); deniedLink = false } catch { deniedLink = true }
            let before = adapter.commands.count
            store.testAttemptLink(id); store.testAttemptDiscovery(id); store.testAttemptNotify(id); store.connect(id)
            return deniedRead && deniedAlert && deniedLink && adapter.commands.dropFirst(before).isEmpty
        }
    }

    @MainActor private func runScenario(_ run: Run, _ row: Vector) async throws {
        if row.admissionCheck == "denied" { try await run.admissionProbe.prepare() }
        run.watch.action = {
            run.snapshotPrepublication(row)
            if row.scenario == "connected-pending-identity" {
                run.pendingAdmissionAttempts += 1
                let before = (run.defaults.object(forKey: BLETrustedIdentities.key) as? [String])?.map { $0.unicodeScalars.map(\.value) }
                XCTAssertEqual((try? run.device(run.a).pendingIdentity), run.aPendingIdentity, row.scenario)
                run.store.trustPendingIdentity(run.a)
                let after = (run.defaults.object(forKey: BLETrustedIdentities.key) as? [String])?.map { $0.unicodeScalars.map(\.value) }
                XCTAssertEqual(after, before, row.scenario)
                XCTAssertFalse((try? run.device(run.a).allowDeviceTasks) ?? true, row.scenario)
            }
            if row.scenario == "reentrant-admission" {
                run.hookActions += 1
                run.admission = run.deniedSynchronously(run.a) ? "denied" : "allowed"
                do { try run.sendOldFrame(run.a) } catch { XCTFail("\(row.scenario): \(error)") }
                run.store.grant(run.b, alert: false)
            }
        }
        run.watch.install(run.store)
        let changeA = { run.change(run.a, invalidated: row.invalidated) }
        switch row.hook {
        case "none": changeA()
        case "value-claimed", "error-claimed":
            run.adapter.afterReadValueClaim = { run.hookActions += 1; changeA() }
            let failure = row.hook == "error-claimed" ? NSError(domain: "ServiceChange.Controlled", code: 731) : nil
            run.store.testValue(run.a, profile: .battery, data: Data([37]), error: failure)
            run.adapter.afterReadValueClaim = nil
        case "cancel-claimed":
            let task = try XCTUnwrap(run.read?.task)
            XCTAssertTrue(run.cancelOffMain(task), row.scenario); changeA()
        case "late-cancel":
            let task = try XCTUnwrap(run.read?.task)
            run.adapter.afterReadOutcomeClaim = { run.hookActions += 1; XCTAssertTrue(run.cancelOffMain(task)) }
            changeA(); run.adapter.afterReadOutcomeClaim = nil
        case "before-reserve", "after-reserve":
            let probe = ReadProbe(); run.read = probe
            let hook = { run.hookActions += 1; run.timer = run.store.testCaptureReadTimeout(); changeA() }
            if row.hook == "before-reserve" { run.adapter.beforeReadReserve = hook }
            else { run.adapter.afterReadReserve = hook }
            probe.start(run.store, id: run.a)
            try await run.waitRead()
            run.adapter.beforeReadReserve = nil; run.adapter.afterReadReserve = nil
        case "will-change": changeA()
        case "repeat":
            changeA(); run.change(run.a, invalidated: row.invalidated == "empty" ? "known" : "empty")
        case "disconnect-boundary":
            changeA()
            run.store.testDidDisconnect(run.a, during: {
                run.hookActions += 1
                run.admission = run.deniedSynchronously(run.a) ? "denied" : "allowed"
            })
            try await run.waitPhase("idle")
            run.store.connect(run.a)
        case "different-peer": run.change(run.a, invalidated: row.invalidated, matching: false)
        case "power-off-before": run.adapter.poweredOn = false; changeA()
        case "power-off-claim":
            run.adapter.afterReadOutcomeClaim = { run.hookActions += 1; run.adapter.poweredOn = false }
            changeA(); run.adapter.afterReadOutcomeClaim = nil
        case "other-device":
            let token = try XCTUnwrap(run.store.testPendingToken(run.a))
            run.change(run.b, invalidated: row.invalidated)
            XCTAssertEqual(run.store.testPendingToken(run.a), token, row.scenario)
            let readsBefore = run.adapter.commands.filter { if case .read = $0 { return true }; return false }.count
            let secondRead = Task { @MainActor in
                do { _ = try await run.store.read(run.a, profile: .battery); return false }
                catch { return true }
            }
            let secondDenied = await secondRead.value
            XCTAssertTrue(secondDenied, row.scenario)
            XCTAssertEqual(run.store.testPendingToken(run.a), token, row.scenario)
            XCTAssertEqual(run.adapter.commands.filter { if case .read = $0 { return true }; return false }.count, readsBefore, row.scenario)
            XCTAssertEqual(run.timer?.state, "active", row.scenario)
            _ = try run.store.alert(run.a, level: 1)
            try await run.startLinkQuery(hold: false)
            XCTAssertEqual(run.linkOutcomes[run.a], "completed", row.scenario)
            XCTAssertEqual(run.linkCompletions[run.a], 1, row.scenario)
            XCTAssertNil(run.linkOutcomes[run.b], row.scenario)
            XCTAssertNil(run.linkCompletions[run.b], row.scenario)
            try run.event(run.a, sequence: 2)
            XCTAssertEqual(run.store.testPendingToken(run.a), token, row.scenario)
            run.admission = "other-active"
            run.store.testValue(run.a, profile: .battery, data: Data([37]))
        case "unknown-device": run.change(UUID(), invalidated: row.invalidated)
        case "unknown-device-off":
            run.adapter.poweredOn = false; run.change(UUID(), invalidated: row.invalidated)
        case "connecting": changeA()
        case "link-inflight", "link-completed": changeA()
        default: XCTFail("Unhandled frozen hook \(row.hook)")
        }
        if row.initialPending == "a" { try await run.waitRead() }
        if row.scenario == "link-inflight" {
            await run.linkTask?.value
            XCTAssertEqual(run.linkCompletions[run.a], 1, row.scenario)
            run.peers[run.a]?.deliverHeld()
            XCTAssertEqual(run.linkCompletions[run.a], 1, row.scenario)
        }
        if row.admissionCheck == "denied" {
            if run.admission == "not-tested" { run.admission = run.deniedSynchronously(run.a) ? "denied" : "allowed" }
            if run.admission != "denied" { run.store.cancelRead() }
            await run.admissionProbe.task?.value
            XCTAssertTrue(run.admissionProbe.completed, row.scenario)
            let before = run.adapter.commands.count
            let failed = Task { @MainActor in
                do { _ = try await run.store.read(run.a, profile: .battery); return false }
                catch { return true }
            }
            let denied = await failed.value
            XCTAssertTrue(denied, row.scenario)
            let physicalWrites = run.adapter.linkWrites.count
            let failedLink = Task { @MainActor in
                do { _ = try await run.store.queryLink(run.a, requestID: UUID(), name: "light.get"); return false }
                catch { return true }
            }
            let linkDenied = await failedLink.value
            XCTAssertTrue(linkDenied, row.scenario)
            XCTAssertEqual(run.adapter.linkWrites.count, physicalWrites, row.scenario)
            XCTAssertEqual(run.adapter.commands.count, before, row.scenario)
        }
        if run.oldTX != nil, run.oldPhysical != nil, run.oldReceiveCount != nil,
           row.aLink == "cleared" || row.scenario == "other-device-change" {
            let target = row.scenario == "other-device-change" ? run.b : run.a
            try run.sendOldFrame(target)
        }
        run.ended = Date()
    }

    @MainActor private func observed(_ run: Run, _ row: Vector) throws -> Vector {
        var actual = row
        let a = try run.device(run.a), b = try run.device(run.b)
        let aDecl = run.store.testDeclarations(run.a), bDecl = run.store.testDeclarations(run.b)
        actual.aPhase = run.store.testPhase(run.a); actual.bPhase = run.store.testPhase(run.b)
        actual.aRead = aDecl.read; actual.aAlert = aDecl.alert
        actual.bRead = bDecl.read; actual.bAlert = bDecl.alert
        XCTAssertEqual(a.allowRead, aDecl.read, row.scenario); XCTAssertEqual(a.allowAlert, aDecl.alert, row.scenario)
        XCTAssertEqual(b.allowRead, bDecl.read, row.scenario); XCTAssertEqual(b.allowAlert, bDecl.alert, row.scenario)
        func scalars(_ s: String) -> [UInt32] { s.unicodeScalars.map(\.value) }
        actual.aIdentity = a.taskIdentity.isEmpty && a.pendingIdentity.isEmpty ? "cleared" :
            (scalars(a.taskIdentity) == scalars(run.aIdentity) && scalars(a.pendingIdentity) == scalars(run.aPendingIdentity) ? "retained" : "changed")
        actual.bIdentity = b.taskIdentity.isEmpty && b.pendingIdentity.isEmpty ? "cleared" :
            (scalars(b.taskIdentity) == scalars(run.bIdentity) && scalars(b.pendingIdentity) == scalars(run.bPendingIdentity) ? "retained" : "changed")
        let aChannel = run.store.testIdentityChannel(run.a), aClient = run.store.testIdentityClient(run.a)
        let bChannel = run.store.testIdentityChannel(run.b), bClient = run.store.testIdentityClient(run.b)
        actual.aLink = aChannel == nil && aClient == nil ? "cleared" :
            (aChannel == run.aChannel && aClient == run.aClient ? "retained" : "changed")
        actual.bLink = bChannel == nil && bClient == nil ? "cleared" :
            (bChannel == run.bChannel && bClient == run.bClient ? "retained" : "changed")
        XCTAssertEqual(a.grantedTools, actual.aLink == "cleared" ? [] : run.aTools, row.scenario)
        XCTAssertEqual(b.grantedTools, actual.bLink == "cleared" ? [] : run.bTools, row.scenario)
        func authorized(_ id: UUID) -> Bool {
            do { try run.store.authorizeLink(id, name: "light.get", arguments: nil); return true }
            catch { return false }
        }
        XCTAssertEqual(authorized(run.a), actual.aLink == "retained" && actual.aPhase == "connected", row.scenario)
        XCTAssertEqual(authorized(run.b), actual.bLink == "retained" && actual.bPhase == "connected", row.scenario)
        if let read = run.read, let result = read.result {
            switch result {
            case .success(let text):
                XCTAssertTrue(text.hasPrefix("37 % @ "), row.scenario)
                let date = ISO8601DateFormatter().date(from: String(text.dropFirst("37 % @ ".count)))
                XCTAssertNotNil(date, row.scenario)
                if let date { XCTAssertGreaterThanOrEqual(date, run.began.addingTimeInterval(-1)); XCTAssertLessThanOrEqual(date, run.ended.addingTimeInterval(1)) }
                actual.pendingResult = "value"
            case .failure(let error):
                if error is CancellationError { actual.pendingResult = "cancelled" }
                else if let failure = error as? BLEFailure, failure.message == "Device disconnected" { actual.pendingResult = "disconnected" }
                else if let failure = error as? BLEFailure, failure.message == "Bluetooth unavailable" { actual.pendingResult = "bluetooth-unavailable" }
                else if (error as NSError).domain == "ServiceChange.Controlled" && (error as NSError).code == 731 { actual.pendingResult = "read-error" }
                else { actual.pendingResult = "unexpected-error" }
            }
        } else { actual.pendingResult = "none" }
        let timer = run.timer?.state ?? "none"
        actual.timer = row.timer == "absent-or-cancelled" && ["none", "cancelled"].contains(timer) ? "absent-or-cancelled" : timer
        actual.pendingCompletions = run.read?.completions ?? 0
        let affectedLinkOwner = row.hook == "other-device" ? run.b : run.a
        actual.linkOutcome = run.linkOutcomes[affectedLinkOwner] ?? "none"
        if actual.linkOutcome == "none" {
            XCTAssertNil(run.linkCompletions[affectedLinkOwner], row.scenario)
            let submitted = run.adapter.commands.filter {
                if case .link(let id) = $0 { return id == affectedLinkOwner }; return false
            }.count
            let writes = run.adapter.linkWrites.filter { $0.0 == affectedLinkOwner }.count
            XCTAssertEqual(submitted, 0, row.scenario)
            XCTAssertEqual(writes, run.baselineLinkWrites[affectedLinkOwner], row.scenario)
        }
        func count(_ predicate: (BLEDeviceStore.TestCommand) -> Bool) -> Int { run.adapter.commands.filter(predicate).count }
        actual.aDisconnects = count { if case .disconnect(let id) = $0 { return id == run.a }; return false }
        actual.bDisconnects = count { if case .disconnect(let id) = $0 { return id == run.b }; return false }
        actual.aConnects = count { if case .connect(let id) = $0 { return id == run.a }; return false }
        actual.extraReads = count { if case .read = $0 { return true }; return false }
        actual.extraAlerts = count { if case .alert = $0 { return true }; return false }
        actual.extraNotifies = count { if case .notify = $0 { return true }; return false }
        actual.extraLinks = count { if case .link = $0 { return true }; return false }
        actual.lateLinkEvents = max(0, (run.oldReceiveCount?() ?? run.baselineOldReceive) - run.baselineOldReceive)
        actual.currentLinkEvents = run.store.testCommittedLinkEventCount(run.a) - run.baselineAEvents +
            run.store.testCommittedLinkEventCount(run.b) - run.baselineBEvents
        actual.legacyUnchanged = (run.defaults.object(forKey: BLETrustedIdentities.key) as? [String])?.map { $0.unicodeScalars.map(\.value) } == run.baselineLegacy
        actual.admissionCheck = run.admission; actual.prepublication = run.prepublication
        XCTAssertFalse(a.allowDeviceTasks, row.scenario); XCTAssertFalse(b.allowDeviceTasks, row.scenario)
        return actual
    }

    @MainActor func testPhysicalLinkReadinessIsDeniedDuringInstallationNotification() async throws {
        let run = try Run()
        defer { run.cleanup() }
        run.store.testRadioOn(); run.connect(run.a)
        let old = try XCTUnwrap(run.store.testIdentityChannel(run.a))
        run.adapter.linkWrites.removeAll()
        var readinessDuring: Bool?
        var channelDuring: ObjectIdentifier?
        run.watch.action = {
            channelDuring = run.store.testIdentityChannel(run.a)
            readinessDuring = run.store.testLinkPhysicalReady(run.a)
            XCTAssertEqual(run.adapter.linkWrites.count, 0)
            XCTAssertFalse(run.store.testLinkExchangePending(run.a))
        }
        run.watch.install(run.store)
        run.store.testPrepareLink(run.a, bootID: 1, deviceID: run.deviceID)
        XCTAssertEqual(run.watch.actions, 1)
        XCTAssertNotNil(channelDuring); XCTAssertNotEqual(channelDuring, old)
        XCTAssertEqual(readinessDuring, false)
        XCTAssertEqual(run.store.testIdentityChannel(run.a), channelDuring)
        XCTAssertEqual(run.store.testLinkPhysicalReady(run.a), true)
        let tx = try XCTUnwrap(run.store.testLinkTXEndpoint(run.a))
        let rx = try XCTUnwrap(run.store.testLinkRXEndpoint(run.a))
        let physical = try XCTUnwrap(run.store.testLinkPhysicalPeer(run.a))
        let peer = PhysicalPeer(id: run.a, store: run.store, physical: physical, tx: tx, rx: rx)
        run.adapter.onLinkWrite = { id, bytes in if id == run.a { peer.wrote(bytes) } }
        let client = PDSHLinkClient(transport: try XCTUnwrap(run.store.testCurrentLinkTransport(run.a)))
        let result = try await client.handshake()
        XCTAssertTrue(result.supportsTools)
        XCTAssertGreaterThan(peer.writeCount, 0)
        XCTAssertNil(peer.failed)
    }

    @MainActor func testOldPhysicalWriteCallbackDoesNotAdvanceReplacement() async throws {
        for scenario in ["same-peer-old-rx", "old-peer-current-rx"] {
            let run = try Run()
            defer { run.cleanup() }
            run.store.testRadioOn(); run.connect(run.a, writeLimit: 20)
            try await run.installPhysicalPeer(run.a)
            let oldPeer = try XCTUnwrap(run.peers[run.a])
            oldPeer.holdNextAck = true
            let oldID = UUID(); oldPeer.resultRequest = oldID
            let oldQuery = Task { @MainActor in try await run.store.queryLink(run.a, requestID: oldID, name: "light.get") }
            for _ in 0..<200 {
                if oldPeer.heldAck != nil { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertNotNil(oldPeer.heldAck, scenario)
            XCTAssertTrue(run.store.testLinkExchangePending(run.a), scenario)
            let oldOwner = try XCTUnwrap(run.store.testOwner(run.a))
            if scenario == "same-peer-old-rx" {
                run.store.testPrepareLink(run.a, bootID: 1, deviceID: run.deviceID, writeLimit: 20)
                XCTAssertEqual(run.store.testOwner(run.a), oldOwner, scenario)
            } else {
                run.store.disconnect(run.a); run.store.testDidDisconnect(run.a)
                try await run.waitPhase("idle")
                run.store.testRediscover(run.a)
                run.connect(run.a, writeLimit: 20)
                XCTAssertNotEqual(run.store.testOwner(run.a), oldOwner, scenario)
            }
            _ = try? await oldQuery.value
            try await run.installPhysicalPeer(run.a)
            let currentPeer = try XCTUnwrap(run.peers[run.a])
            if scenario == "same-peer-old-rx" {
                XCTAssertTrue(oldPeer.physical === currentPeer.physical, scenario)
                XCTAssertFalse(oldPeer.rx === currentPeer.rx, scenario)
            } else { XCTAssertFalse(oldPeer.physical === currentPeer.physical, scenario) }
            currentPeer.holdNextAck = true
            let currentID = UUID(); currentPeer.resultRequest = currentID
            let query = Task { @MainActor in try await run.store.queryLink(run.a, requestID: currentID, name: "light.get") }
            for _ in 0..<200 {
                if currentPeer.heldAck != nil { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertNotNil(currentPeer.heldAck, scenario)
            XCTAssertTrue(run.store.testLinkExchangePending(run.a), scenario)
            let before = currentPeer.writeCount
            run.adapter.commands.removeAll()
            let reportedRX = scenario == "same-peer-old-rx" ? oldPeer.rx : currentPeer.rx
            run.store.testLinkWriteComplete(run.a, physical: oldPeer.physical, endpoint: reportedRX)
            XCTAssertEqual(currentPeer.writeCount, before, "\(scenario): old ACK must not advance current channel")
            if scenario == "same-peer-old-rx" {
                XCTAssertEqual(run.store.testPhase(run.a), "connected", scenario)
                let currentAck = try XCTUnwrap(currentPeer.heldAck, scenario)
                currentPeer.heldAck = nil; currentAck()
                XCTAssertGreaterThan(currentPeer.writeCount, before, scenario)
                let result = try await query.value
                XCTAssertEqual(result?["status"]?.stringValue, "completed", scenario)
            } else {
                XCTAssertEqual(run.store.testPhase(run.a), "quarantined", scenario)
                XCTAssertEqual(run.adapter.commands.filter { if case .disconnect(let id) = $0 { return id == run.a }; return false }.count, 1, scenario)
                _ = try? await query.value
            }
            oldPeer.heldAck = nil; currentPeer.heldAck = nil
        }
    }

    @MainActor func testSharedServiceChangeVectors() async throws {
        let rows = try vectors()
        XCTAssertEqual(rows.count, 22)
        XCTAssertEqual(Set(rows.map(\.scenario)).count, rows.count)
        for row in rows {
            let run = try Run()
            defer { run.cleanup() }
            do {
                try await run.prepare(row)
                try await runScenario(run, row)
                let actual = try observed(run, row)
                XCTAssertEqual(actual, row, row.scenario)
                XCTAssertLessThanOrEqual(run.watch.calls, 8, row.scenario)
                if row.prepublication == "revoked" { XCTAssertEqual(run.watch.actions, 1, row.scenario) }
                else { XCTAssertEqual(run.watch.calls, 0, row.scenario) }
                if ["value-claimed", "error-claimed", "late-cancel", "before-reserve", "after-reserve", "will-change", "power-off-claim", "disconnect-boundary"].contains(row.hook) {
                    XCTAssertEqual(run.hookActions, 1, row.scenario)
                }
                if row.scenario == "connected-pending-identity" { XCTAssertEqual(run.pendingAdmissionAttempts, 1, row.scenario) }
                if row.scenario == "connected-known" {
                    var mutation = row; mutation.aDisconnects = 0
                    XCTAssertNotEqual(actual, mutation, "a missing physical disconnect must not match")
                    mutation = row; mutation.pendingResult = "value"
                    XCTAssertNotEqual(actual, mutation, "a wrong read winner must not match")
                    mutation = row; mutation.prepublication = "no-publish"
                    XCTAssertNotEqual(actual, mutation, "a missing prepublication guard must not match")
                }
                if row.scenario == "manager-off-during-claim" {
                    var mutation = row; mutation.pendingResult = "bluetooth-unavailable"
                    XCTAssertNotEqual(actual, mutation, "manager outage must not replace the winning claim")
                }
            } catch {
                run.read?.task?.cancel(); run.linkTask?.cancel()
                XCTFail("\(row.scenario): \(error)")
            }
        }
    }
}
#endif
