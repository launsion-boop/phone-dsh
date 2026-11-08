// SPDX-License-Identifier: MIT
// secure-session-v2 §5/§8.2 phone transport through the real BLEDeviceStore
// with its DEBUG test adapter (no radio): the secure service is discovered
// only for the selected, enrolled device; the PSM is read afresh for every
// CoC; one channel per connection; bounded stream; fail-closed teardown on
// disconnect, service change, manager loss and selection change; the
// shipping grant gate refuses.
import CoreBluetooth
import Foundation
import XCTest
@testable import PhoneDSHBLE

final class BLESecureFakeIO: BLESecureStreamIO {
    var space = true
    var inbound: [UInt8] = []
    var written: [UInt8] = []
    var writeLimit = Int.max
    var failWrite = false
    var closed = false
    var hasSpaceAvailable: Bool { space && !closed }
    var hasBytesAvailable: Bool { !inbound.isEmpty && !closed }
    func write(_ bytes: UnsafePointer<UInt8>, count: Int) -> Int {
        if failWrite { return -1 }
        let n = min(count, writeLimit)
        written += UnsafeBufferPointer(start: bytes, count: n)
        return n
    }
    func read(_ buffer: UnsafeMutablePointer<UInt8>, count: Int) -> Int {
        let n = min(count, inbound.count)
        for i in 0..<n { buffer[i] = inbound[i] }
        inbound.removeFirst(n)
        return n
    }
    func closeIO() { closed = true }
}

#if DEBUG
final class BLESecureCoCAdapterTests: XCTestCase {
    let deviceFP = String(repeating: "ab", count: 32)
    let id = UUID(uuidString: "00000000-0000-4000-8000-0000000000c1")!

    @MainActor private func store() -> (BLEDeviceStore, BLEDeviceStore.TestAdapter) {
        let adapter = BLEDeviceStore.TestAdapter()
        let store = BLEDeviceStore(testAdapter: adapter, testDevices: [.init(id: id, name: "PDSH board", rssi: -40)])
        return (store, adapter)
    }

    /// Connects and completes discovery with a battery service and `secureServices` secure services.
    @MainActor @discardableResult
    private func connect(_ store: BLEDeviceStore, secureServices: Int = 1,
                         psmProperties: CBCharacteristicProperties = [.read], psmCount: Int = 1) -> [BLEDeviceStore.TestService] {
        store.connect(id)
        store.testDidConnect(id)
        let peer = store.testPhysicalPeer(id)!
        let battery = BLEDeviceStore.TestService(parent: peer, uuid: "180F")
        let secure = (0..<secureServices).map { _ in BLEDeviceStore.TestService(parent: peer, uuid: BLESecureServiceProfile.serviceUUID) }
        store.testDiscoveryServices(id, peer: peer, services: [battery] + secure)
        store.testDiscoveryCharacteristics(id, peer: peer, service: battery,
                                           characteristics: [.init(parent: battery, uuid: "2A19", properties: [.read])])
        if secureServices == 1 {
            let psm = (0..<psmCount).map { _ in BLEDeviceStore.TestCharacteristic(parent: secure[0], uuid: BLESecureServiceProfile.psmCharacteristicUUID, properties: psmProperties) }
            store.testDiscoveryCharacteristics(id, peer: peer, service: secure[0], characteristics: psm)
        }
        return secure
    }

    @MainActor private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "condition not reached", file: file, line: line)
    }

    private func count(_ adapter: BLEDeviceStore.TestAdapter, _ match: (BLEDeviceStore.TestCommand) -> Bool) -> Int {
        adapter.commands.filter(match).count
    }

    @MainActor private final class Opening {
        var result: Result<BLESecureByteStream, Error>?
        init(_ store: BLEDeviceStore, _ id: UUID, _ lease: BLESecureLease) {
            Task { @MainActor in
                do { self.result = .success(try await store.openSecureStream(id, lease: lease)) }
                catch { self.result = .failure(error) }
            }
        }
    }

    @MainActor func testSecureServiceIsDiscoveredOnlyForTheSelectedDevice() async throws {
        let (plain, plainAdapter) = store()
        connect(plain)
        XCTAssertFalse(plainAdapter.serviceDiscoveryUUIDs[id]!.contains(BLESecureServiceProfile.serviceUUID))
        let securePlanned = plainAdapter.discoverySubmissions.filter { ($0.service as? BLEDeviceStore.TestService)?.uuid == BLESecureServiceProfile.serviceUUID }
        XCTAssertTrue(securePlanned.isEmpty, "unselected device: the secure service is never discovered")
        XCTAssertNil(plain.testSecurePSMEndpoint(id))
        XCTAssertNil(plain.secureLease(id))
        XCTAssertEqual(plain.devices[0].secureState, "")

        let (selected, adapter) = store()
        XCTAssertFalse(selected.selectSecureDevice(id, device: "ble:" + deviceFP), "bare fingerprint only")
        XCTAssertTrue(selected.selectSecureDevice(id, device: deviceFP))
        connect(selected)
        XCTAssertTrue(adapter.serviceDiscoveryUUIDs[id]!.contains(BLESecureServiceProfile.serviceUUID))
        XCTAssertEqual(adapter.discoverySubmissions.filter { ($0.service as? BLEDeviceStore.TestService)?.uuid == BLESecureServiceProfile.serviceUUID }.count, 1)
        XCTAssertNotNil(selected.testSecurePSMEndpoint(id))
        XCTAssertNotNil(selected.secureLease(id))
        XCTAssertEqual(selected.devices[0].secureDevice, "ble:" + deviceFP)
        XCTAssertEqual(selected.devices[0].secureState, "安全会话服务可用")
        XCTAssertEqual(selected.devices[0].profiles, [.battery], "standard discovery is unchanged")
        XCTAssertNil(selected.testConnectionDeadlineToken(id), "discovery deadline completes with the secure request")
    }

    @MainActor func testAmbiguousOrIncompleteSecureServiceIsUnavailable() async throws {
        for (services, count, properties, state) in [(2, 1, CBCharacteristicProperties.read, "发现多个安全会话服务，暂不可用"),
                                                     (1, 2, .read, "安全会话特征不完整或存在歧义"),
                                                     (1, 1, .notify, "安全会话特征不完整或存在歧义"),
                                                     (0, 1, .read, "设备不支持安全任务会话")] {
            let (store, _) = store()
            store.selectSecureDevice(id, device: deviceFP)
            connect(store, secureServices: services, psmProperties: properties, psmCount: count)
            XCTAssertNil(store.secureLease(id), state)
            XCTAssertEqual(store.devices[0].secureState, state)
            XCTAssertEqual(store.testPhase(id), "connected", "the LE link and standard GATT continue")
        }
    }

    @MainActor func testPSMIsReadFreshForEveryChannelAndOnlyOneChannelIsLive() async throws {
        let (store, adapter) = store()
        store.selectSecureDevice(id, device: deviceFP)
        connect(store)
        let lease = try XCTUnwrap(store.secureLease(id))
        let first = Opening(store, id, lease)
        await waitUntil { count(adapter) { $0 == .secureRead(id) } == 1 }
        store.testSecurePSMValue(id, data: Data([0x81, 0x00]))
        await waitUntil { count(adapter) { $0 == .secureOpen(id, 0x81) } == 1 }
        let io = BLESecureFakeIO()
        store.testSecureDidOpen(id, psm: 0x81, io: io)
        await waitUntil { first.result != nil }
        let stream = try XCTUnwrap(try first.result?.get() as? BLESecureBoundedStream)
        // A second CoC on the same connection is refused while one is live.
        let second = Opening(store, id, lease)
        await waitUntil { second.result != nil }
        XCTAssertThrowsError(try second.result!.get())
        XCTAssertEqual(count(adapter) { $0 == .secureRead(id) }, 1)
        // Bytes flow through the bounded stream to the channel.
        try stream.write([1, 2, 3])
        await waitUntil { io.written == [1, 2, 3] }
        // The channel closes (CoC loss); a renewal reads the PSM again.
        io.inbound = []; stream.endEncountered()
        await waitUntil { !store.testSecureSlotLive(id) }
        let third = Opening(store, id, lease)
        await waitUntil { count(adapter) { $0 == .secureRead(id) } == 2 }
        store.testSecurePSMValue(id, data: Data([0x80, 0x00]))
        await waitUntil { count(adapter) { $0 == .secureOpen(id, 0x80) } == 1 }
        // An open for another PSM is not adopted.
        store.testSecureDidOpen(id, psm: 0x81, io: BLESecureFakeIO())
        await waitUntil { third.result != nil }
        XCTAssertThrowsError(try third.result!.get())
        XCTAssertEqual(store.testPhase(id), "connected")
    }

    @MainActor func testInvalidPSMMakesTheSecureSessionUnavailableOnThisConnection() async throws {
        for value in [[0x7F, 0x00], [0x00, 0x01], [0x80], [0x80, 0x00, 0x00], []] as [[UInt8]] {
            let (store, adapter) = store()
            store.selectSecureDevice(id, device: deviceFP)
            connect(store)
            let lease = try XCTUnwrap(store.secureLease(id))
            let open = Opening(store, id, lease)
            await waitUntil { count(adapter) { $0 == .secureRead(id) } == 1 }
            store.testSecurePSMValue(id, data: Data(value))
            await waitUntil { open.result != nil }
            XCTAssertThrowsError(try open.result!.get(), "\(value)")
            XCTAssertFalse(adapter.commands.contains { if case .secureOpen = $0 { return true }; return false })
            XCTAssertNil(store.secureLease(id))
            XCTAssertEqual(store.devices[0].secureState, "安全会话端口无效，本次连接不可用")
            XCTAssertEqual(store.testPhase(id), "connected")
        }
    }

    @MainActor func testTeardownFailsClosedAndInvalidatesTheGeneration() async throws {
        enum Teardown: CaseIterable { case serviceChange, disconnect, radioOff, selectionChange, notifyingPSM }
        for teardown in Teardown.allCases {
            let (store, adapter) = store()
            store.selectSecureDevice(id, device: deviceFP)
            connect(store)
            let lease = try XCTUnwrap(store.secureLease(id))
            let invalidated = expectation(description: "lease \(teardown)")
            lease.onInvalidate { invalidated.fulfill() }
            let open = Opening(store, id, lease)
            await waitUntil { count(adapter) { $0 == .secureRead(id) } == 1 }
            store.testSecurePSMValue(id, data: Data([0x81, 0x00]))
            await waitUntil { count(adapter) { $0 == .secureOpen(id, 0x81) } == 1 }
            let io = BLESecureFakeIO()
            store.testSecureDidOpen(id, psm: 0x81, io: io)
            await waitUntil { open.result != nil }
            let stream = try XCTUnwrap(try open.result?.get() as? BLESecureBoundedStream)
            switch teardown {
            case .serviceChange: store.testServicesModified(id)
            case .disconnect: store.testDidDisconnect(id)
            case .radioOff: store.testRadioUnavailable(reset: false)
            case .selectionChange: store.selectSecureDevice(id, device: String(repeating: "cd", count: 32))
            case .notifyingPSM: store.testSecurePSMValue(id, data: Data([0x81, 0x00]), notifying: true)
            }
            await fulfillment(of: [invalidated], timeout: 2)
            XCTAssertFalse(lease.isValid)
            XCTAssertEqual(stream.closeReason, .owner, "\(teardown)")
            await waitUntil { io.closed }
            XCTAssertThrowsError(try stream.write([1]))
            let late = try await stream.read()
            XCTAssertNil(late)
            XCTAssertNil(store.secureLease(id))
            XCTAssertFalse(store.secureGrantAdmitted(id, lease: lease))
            // A late open of the old lease is refused.
            let again = Opening(store, id, lease)
            await waitUntil { again.result != nil }
            XCTAssertThrowsError(try again.result!.get())
        }
    }

    @MainActor func testPendingPSMReadFailsOnDisconnect() async throws {
        let (store, adapter) = store()
        store.selectSecureDevice(id, device: deviceFP)
        connect(store)
        let lease = try XCTUnwrap(store.secureLease(id))
        let open = Opening(store, id, lease)
        await waitUntil { count(adapter) { $0 == .secureRead(id) } == 1 }
        store.testDidDisconnect(id)
        await waitUntil { open.result != nil }
        XCTAssertThrowsError(try open.result!.get())
        XCTAssertFalse(lease.isValid)
    }

    /// The phone rollback / containment row: in every build of this package
    /// (none defines PDSH_ENABLE_DEVICE_TASKS) the grant is refused even for a
    /// live, selected secure connection, and the plaintext grant stays off.
    @MainActor func testShippingBuildRefusesEveryDeviceTaskGrant() async throws {
        #if PDSH_ENABLE_DEVICE_TASKS
        throw XCTSkip("this package build defines PDSH_ENABLE_DEVICE_TASKS")
        #else
        let (store, _) = store()
        store.selectSecureDevice(id, device: deviceFP)
        connect(store)
        let lease = try XCTUnwrap(store.secureLease(id))
        XCTAssertThrowsError(try store.grantDeviceTasks(id, enabled: true)) {
            XCTAssertEqual(($0 as? BLEFailure)?.message, "设备身份认证尚未完成验证，暂不能授权蓝牙设备派任务")
        }
        XCTAssertFalse(store.secureGrantAdmitted(id, lease: lease))
        XCTAssertFalse(store.devices[0].allowDeviceTasks)
        XCTAssertNoThrow(try store.grantDeviceTasks(id, enabled: false), "revocation stays available")
        #endif
    }

    // MARK: bounded stream

    func testBoundedStreamBackpressureAndSendOverflowFailClosed() async throws {
        var limits = BLESecureBoundedStream.Limits()
        limits.receive = 8; limits.send = 16; limits.chunk = 4
        let io = BLESecureFakeIO()
        let stream = BLESecureBoundedStream(io: io, limits: limits, schedule: { $0() })
        // Receive: the pump stops pulling at the bound; the OS keeps the rest.
        io.inbound = Array(0..<20)
        stream.pump()
        XCTAssertEqual(stream.bufferedReceiveBytes, 8)
        XCTAssertEqual(io.inbound.count, 12, "unread bytes stay in the channel (credits withheld)")
        var got: [UInt8] = []
        while got.count < 20, let chunk = try await stream.read() { got += chunk }
        XCTAssertEqual(got, Array(0..<20), "order preserved, nothing duplicated")
        // Send: a short write keeps the tail queued; never re-sent.
        io.writeLimit = 3
        io.space = false
        try stream.write(Array(100..<110))
        XCTAssertEqual(stream.bufferedSendBytes, 10)
        io.space = true
        stream.pump()
        XCTAssertEqual(io.written, Array(100..<110))
        // Overflow closes instead of growing.
        io.space = false
        try stream.write(Array(repeating: 1, count: 16))
        XCTAssertThrowsError(try stream.write([2]))
        XCTAssertEqual(stream.closeReason, .sendOverflow)
        XCTAssertTrue(io.closed)
        let eof = try await stream.read()
        XCTAssertNil(eof)
    }

    /// On-air regression (2026-11-08): with the production asynchronous
    /// scheduler, `write` only queues; a local close right after it (TLS
    /// close_notify, fatal alert) must still hand those bytes to the channel
    /// before closing it, once and in order, and nothing written after close.
    func testLocalCloseFlushesQueuedFinalRecordBeforeClosingTheChannel() async throws {
        final class Deferred: @unchecked Sendable {
            var work: [@Sendable () -> Void] = []
            func run() { while !work.isEmpty { work.removeFirst()() } }
        }
        let closeNotify: [UInt8] = [0x17, 0x03, 0x03, 0x00, 0x13] + Array(repeating: 0xaa, count: 19)
        for spaceNow in [true, false] {
            let io = BLESecureFakeIO()
            io.space = spaceNow
            let queue = Deferred()
            var limits = BLESecureBoundedStream.Limits()
            limits.chunk = 7
            let stream = BLESecureBoundedStream(io: io, limits: limits, schedule: { queue.work.append($0) })
            try stream.write(closeNotify)
            stream.close()
            XCTAssertThrowsError(try stream.write([1]), "nothing is queued after close")
            XCTAssertTrue(io.written.isEmpty, "the pump has not run yet")
            queue.run()
            XCTAssertTrue(io.closed)
            XCTAssertEqual(stream.closeReason, .local)
            // Bounded: with no space now the record is dropped, never retried.
            XCTAssertEqual(io.written, spaceNow ? closeNotify : [], "space=\(spaceNow)")
        }
        // Owner teardown and stream errors do not flush.
        let io = BLESecureFakeIO()
        let queue = Deferred()
        let stream = BLESecureBoundedStream(io: io, schedule: { queue.work.append($0) })
        try stream.write([9, 9, 9])
        stream.ownerClosed()
        queue.run()
        XCTAssertTrue(io.written.isEmpty)
        XCTAssertTrue(io.closed)
    }

    func testBoundedStreamErrorsCloseBothDirections() async throws {
        for failure in ["write", "read", "eof"] {
            let io = BLESecureFakeIO()
            let stream = BLESecureBoundedStream(io: io, schedule: { $0() })
            let reader = Task { try await stream.read() }
            try await Task.sleep(for: .milliseconds(20))
            switch failure {
            case "write": io.failWrite = true; try? stream.write([1])
            case "read": stream.errorOccurred()
            default: stream.endEncountered()
            }
            let value = try await reader.value
            XCTAssertNil(value, failure)
            XCTAssertTrue(stream.isClosed)
            XCTAssertTrue(io.closed)
            XCTAssertThrowsError(try stream.write([1]))
        }
    }
}
#endif
