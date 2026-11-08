// SPDX-License-Identifier: MIT
// Runtime conformance for spec/device/v1/ble-link.md@scan-intent-v1
// (docs/protocol-changes/PC-20261107-ble-scan-reentry-ccr.md). The real store,
// real Observation and the real production scan deadline are driven; the
// DEBUG adapter substitutes only manager construction, scan/stop submission
// and the power bit. No status, scanning flag, intent or timer is set by a test.
// This is simulated-edge evidence, not CoreBluetooth radio evidence.
import CoreBluetooth
import Foundation
import Observation
import XCTest
@testable import PhoneDSHBLE

#if DEBUG
final class BLEScanIntentTests: XCTestCase {
    static let texts = [
        "prompt": "点击扫描以请求蓝牙权限",
        "init": "正在初始化蓝牙",
        "ready": "蓝牙已就绪，请点击扫描",
        "scan": "正在扫描（15 秒）",
    ]

    /// Observation invokes will-change synchronously. A nested write can call
    /// the same outstanding registration again before it unregisters: consume
    /// the ticket before reentry so neither the action nor its count repeats.
    @MainActor private final class Ticket {
        private var consumed = false
        private(set) var deliveries = 0
        func take() -> Bool {
            guard !consumed else { return false }
            consumed = true
            deliveries += 1
            return true
        }
    }

    // MARK: - The four reproduced defects, now asserting the frozen rule

    /// Defect 1: a stop inside the start's status will-change must win; the
    /// older start can neither publish its scan text nor install its timer.
    @MainActor
    func testStopInsideStartStatusWillChangeWins() {
        let adapter = BLEDeviceStore.TestAdapter()
        let store = BLEDeviceStore(testAdapter: adapter, testDevices: [])
        let ticket = Ticket()
        XCTAssertEqual(store.status, Self.texts["prompt"])
        XCTAssertFalse(store.scanning)
        withObservationTracking { _ = store.status } onChange: {
            MainActor.assumeIsolated {
                guard ticket.take() else { return }
                store.stopScan()
            }
        }
        store.scan()
        XCTAssertEqual(ticket.deliveries, 1)
        XCTAssertEqual(adapter.commands, [.scan, .stopScan])
        XCTAssertFalse(store.scanning)
        XCTAssertEqual(store.status, Self.texts["prompt"]) // stop publishes no text
        XCTAssertNil(store.testCaptureScanDeadline())
    }

    /// Defect 2: a stop inside the start's scanning will-change is not
    /// overwritten by the older `true`.
    @MainActor
    func testStopInsideStartScanningWillChangeWins() {
        let adapter = BLEDeviceStore.TestAdapter()
        let store = BLEDeviceStore(testAdapter: adapter, testDevices: [])
        let ticket = Ticket()
        withObservationTracking { _ = store.scanning } onChange: {
            MainActor.assumeIsolated {
                guard ticket.take() else { return }
                store.stopScan()
            }
        }
        store.scan()
        XCTAssertEqual(ticket.deliveries, 1)
        XCTAssertEqual(adapter.commands, [.scan, .stopScan])
        XCTAssertFalse(store.scanning)
        XCTAssertEqual(store.status, Self.texts["prompt"])
        XCTAssertNil(store.testCaptureScanDeadline())
    }

    /// Defect 3: a restart inside a stop's scanning will-change is not
    /// overwritten by the older `false`, and it owns the only live deadline.
    @MainActor
    func testStartInsideStopScanningWillChangeWins() throws {
        let adapter = BLEDeviceStore.TestAdapter()
        let store = BLEDeviceStore(testAdapter: adapter, testDevices: [])
        store.scan()
        XCTAssertTrue(store.scanning)
        XCTAssertEqual(adapter.commands, [.scan])
        let first = try XCTUnwrap(store.testCaptureScanDeadline())
        XCTAssertEqual(first.state, "active")
        adapter.commands.removeAll()
        let ticket = Ticket()
        withObservationTracking { _ = store.scanning } onChange: {
            MainActor.assumeIsolated {
                guard ticket.take() else { return }
                store.scan()
            }
        }
        store.stopScan()
        XCTAssertEqual(ticket.deliveries, 1)
        XCTAssertEqual(adapter.commands, [.stopScan, .scan])
        XCTAssertTrue(store.scanning)
        XCTAssertEqual(store.status, Self.texts["scan"])
        XCTAssertEqual(first.state, "cancelled")
        let second = try XCTUnwrap(store.testCaptureScanDeadline())
        XCTAssertEqual(second.state, "active")
        first.invoke() // the stale deadline is inert
        XCTAssertEqual(adapter.commands, [.stopScan, .scan])
        XCTAssertTrue(store.scanning)
        XCTAssertEqual(second.state, "active")
        second.invoke()
        XCTAssertEqual(adapter.commands, [.stopScan, .scan, .stopScan])
        XCTAssertFalse(store.scanning)
    }

    /// Defect 4: a stop during the initialization status publication cancels
    /// manager construction and the later powered-on auto-start.
    @MainActor
    func testCancelledInitializationDoesNotConstructManager() {
        let adapter = BLEDeviceStore.TestAdapter()
        adapter.managerInitialized = false
        adapter.poweredOn = false
        adapter.managerState = .unknown
        let store = BLEDeviceStore(testAdapter: adapter, testDevices: [])
        let ticket = Ticket()
        withObservationTracking { _ = store.status } onChange: {
            MainActor.assumeIsolated {
                guard ticket.take() else { return }
                store.stopScan()
            }
        }
        store.scan()
        XCTAssertEqual(ticket.deliveries, 1)
        XCTAssertTrue(adapter.commands.isEmpty)
        XCTAssertFalse(store.scanning)
        XCTAssertFalse(adapter.managerInitialized)
        XCTAssertEqual(adapter.managerConstructions, 0)
        XCTAssertEqual(store.status, Self.texts["prompt"])
        store.testRadioOn()
        XCTAssertTrue(adapter.commands.isEmpty)
        XCTAssertFalse(store.scanning)
        XCTAssertEqual(store.status, Self.texts["ready"])
    }

    // MARK: - Shared JSONL cases and semantic mutations

    private var golden: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("spec/device/v1/golden")
    }
    private func lines(_ name: String) throws -> [[String: Any]] {
        try String(contentsOf: golden.appendingPathComponent(name), encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
    }

    /// Type-strict scalar view: a JSON boolean never equals a number or string.
    private enum Value: Equatable {
        case bool(Bool), int(Int), string(String), array([Value]), invalid
        init(_ any: Any) {
            switch any {
            case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID(): self = .bool(number.boolValue)
            case let number as NSNumber where CFNumberIsFloatType(number): self = .invalid
            case let number as NSNumber: self = .int(number.intValue)
            case let text as String: self = .string(text)
            case let list as [Any]: self = .array(list.map(Value.init))
            default: self = .invalid
            }
        }
    }
    /// The single comparator used for both the expected rows and mutations.
    private func matches(_ actual: [String: Value], _ expected: [String: Any]) -> Bool {
        for (key, value) in expected {
            guard let observed = actual[key], observed == Value(value), observed != .invalid else { return false }
        }
        return true
    }

    @MainActor private final class Run {
        let adapter = BLEDeviceStore.TestAdapter()
        let store: BLEDeviceStore
        let row: [String: Any]
        let id: String
        var setupDeadline: BLEDeviceStore.TestTimerProbe?
        var injected = 0

        init(_ row: [String: Any]) throws {
            self.row = row
            id = try XCTUnwrap(row["id"] as? String)
            let setup = try XCTUnwrap(row["setup"] as? String)
            if setup == "uninitialized" {
                adapter.managerInitialized = false; adapter.poweredOn = false; adapter.managerState = .unknown
            }
            store = BLEDeviceStore(testAdapter: adapter, testDevices: [])
            switch setup {
            case "uninitialized":
                XCTAssertEqual(store.status, BLEScanIntentTests.texts["prompt"], id)
            case "ready", "scanning":
                store.testRadioOn()
                XCTAssertEqual(store.status, BLEScanIntentTests.texts["ready"], id)
                if setup == "scanning" {
                    store.scan()
                    XCTAssertTrue(store.scanning, id)
                    XCTAssertEqual(store.status, BLEScanIntentTests.texts["scan"], id)
                    let probe = try XCTUnwrap(store.testCaptureScanDeadline(), id)
                    XCTAssertEqual(probe.state, "active", id)
                    setupDeadline = probe
                }
            default: XCTFail("\(id): unknown setup \(setup)")
            }
            XCTAssertFalse(store.scanning && setup != "scanning", id)
            adapter.commands.removeAll(); adapter.managerConstructions = 0
        }
        func perform(_ event: String) throws {
            switch event {
            case "start": store.scan()
            case "stop": store.stopScan()
            case "manager-powered-on": store.testManagerState(.poweredOn)
            case "fire-setup-deadline": try XCTUnwrap(setupDeadline, id).invoke()
            default: XCTFail("\(id): unknown event \(event)")
            }
        }
        func arm() throws {
            guard let injection = row["injection"] as? [String: Any] else { return }
            let checkpoint = try XCTUnwrap(injection["checkpoint"] as? String)
            let event = try XCTUnwrap(injection["event"] as? String)
            let ticket = Ticket()
            let fire: () -> Void = { [unowned self] in
                MainActor.assumeIsolated {
                    guard ticket.take() else { return }
                    self.injected += 1
                    do { try self.perform(event) } catch { XCTFail("\(self.id) nested: \(error)") }
                }
            }
            switch checkpoint {
            case "status-will-change": withObservationTracking { _ = store.status } onChange: { fire() }
            case "scanning-will-change": withObservationTracking { _ = store.scanning } onChange: { fire() }
            default: XCTFail("\(id): unknown checkpoint \(checkpoint)")
            }
        }
        func snapshot() -> [String: Value] {
            let label = BLEScanIntentTests.texts.first { $0.value == store.status }?.key ?? "other:\(store.status)"
            var result: [String: Value] = [
                "status": .string(label),
                "scanning": .bool(store.scanning),
                "commands": .array(adapter.commands.map {
                    switch $0 {
                    case .scan: return .string("scan")
                    case .stopScan: return .string("stop")
                    default: return .string("other")
                    }
                }),
                "deadline": .string(store.testCaptureScanDeadline()?.state == "active" ? "active" : "none"),
                "manager_constructions": .int(adapter.managerConstructions),
            ]
            if let setupDeadline { result["setup_deadline"] = .string(setupDeadline.state) }
            return result
        }
    }

    @MainActor
    func testSharedScanIntentVectorsAndSemanticMutations() throws {
        let rows = try lines("ble-scan-intent.jsonl")
        let mutations = try lines("ble-scan-intent-mutations.jsonl").filter { $0["category"] as? String == "semantic" }
        XCTAssertEqual(rows.count, 14)
        XCTAssertEqual(Set(rows.compactMap { $0["id"] as? String }).count, 14)
        XCTAssertEqual(mutations.count, 15)
        var tested = Set<String>()
        for row in rows {
            let run = try Run(row)
            try run.arm()
            try run.perform(try XCTUnwrap(row["action"] as? String))
            if row["injection"] != nil { XCTAssertEqual(run.injected, 1, "\(run.id): injection must fire exactly once") }
            for event in try XCTUnwrap(row["then"] as? [String]) { try run.perform(event) }
            let actual = run.snapshot()
            let expected = try XCTUnwrap(row["expect"] as? [String: Any])
            XCTAssertTrue(matches(actual, expected), "\(run.id): actual \(actual), expected \(expected)")
            for mutation in mutations where mutation["base"] as? String == run.id {
                let name = try XCTUnwrap(mutation["name"] as? String)
                let path = try XCTUnwrap(mutation["path"] as? [String])
                XCTAssertEqual(path.count, 2, name); XCTAssertEqual(path.first, "expect", name)
                XCTAssertEqual(mutation["op"] as? String, "replace", name)
                var mutated = expected
                mutated[path[1]] = try XCTUnwrap(mutation["value"])
                XCTAssertFalse(matches(actual, mutated), "real comparator accepted mutation \(name)")
                tested.insert(name)
            }
        }
        XCTAssertEqual(tested, Set(mutations.compactMap { $0["name"] as? String }))
    }

    /// Positive controls for the comparator itself: type confusion and an
    /// unknown key never match.
    func testComparatorIsTypeStrict() {
        let actual: [String: Value] = ["scanning": .bool(false), "manager_constructions": .int(0),
                                       "commands": .array([.string("stop")]), "status": .string("ready")]
        XCTAssertTrue(matches(actual, ["scanning": false, "manager_constructions": 0, "commands": ["stop"]]))
        XCTAssertFalse(matches(actual, ["scanning": 0]))
        XCTAssertFalse(matches(actual, ["scanning": "false"]))
        XCTAssertFalse(matches(actual, ["manager_constructions": false]))
        XCTAssertFalse(matches(actual, ["manager_constructions": 0.0]))
        XCTAssertFalse(matches(actual, ["commands": ["stop", "stop"]]))
        XCTAssertFalse(matches(actual, ["status": "ready\u{200B}"]))
        XCTAssertFalse(matches(actual, ["radio_scanning": true]))
    }
}
#endif
