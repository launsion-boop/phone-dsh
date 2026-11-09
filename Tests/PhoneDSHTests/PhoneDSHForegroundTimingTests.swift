// SPDX-License-Identifier: MIT
// Foreground-only timing, boot-phase parsing and resume cancellation.

import Foundation
import XCTest
@testable import PhoneDSH

final class PhoneDSHForegroundClockTests: XCTestCase {
    func testBackgroundIntervalIsNotForegroundTime() {
        let start = Date(timeIntervalSince1970: 1_000)
        let clock = PhoneDSHForegroundClock(isForeground: true, now: start)
        XCTAssertEqual(clock.activeSeconds(at: start.addingTimeInterval(9)), 9, accuracy: 0.0001)
        clock.setForeground(false, at: start.addingTimeInterval(10))
        XCTAssertEqual(clock.activeSeconds(at: start.addingTimeInterval(70)), 10, accuracy: 0.0001,
                       "a 60 s frozen interval must not be reported as work")
        clock.setForeground(true, at: start.addingTimeInterval(70))
        XCTAssertEqual(clock.activeSeconds(at: start.addingTimeInterval(75)), 15, accuracy: 0.0001)
    }

    func testRepeatingTheSamePhaseDoesNotLoseElapsedTime() {
        let start = Date(timeIntervalSince1970: 2_000)
        let clock = PhoneDSHForegroundClock(isForeground: true, now: start)
        clock.setForeground(true, at: start.addingTimeInterval(5))
        clock.setForeground(false, at: start.addingTimeInterval(8))
        clock.setForeground(false, at: start.addingTimeInterval(9))
        XCTAssertEqual(clock.activeSeconds(at: start.addingTimeInterval(9)), 8, accuracy: 0.0001)
    }
}

final class PhoneDSHBootPhaseTests: XCTestCase {
    func testParsesThePageAndWorkerConsoleShape() throws {
        let page = try XCTUnwrap(PhoneDSHBootPhase.parse(
            "pdsh-boot-phase scope=page phase=worker-spawned active_ms=42"))
        XCTAssertEqual(page.scope, "page")
        XCTAssertEqual(page.phase, "worker-spawned")
        XCTAssertEqual(page.activeMilliseconds, 42)
        let worker = try XCTUnwrap(PhoneDSHBootPhase.parse(
            "pdsh-boot-phase scope=worker phase=channel-connected active_ms=381"))
        XCTAssertEqual(worker.scope, "worker")
        XCTAssertEqual(worker.phase, "channel-connected")
        XCTAssertEqual(worker.activeMilliseconds, 381)
    }

    func testRejectsUnrelatedOrUnboundedLines() {
        XCTAssertNil(PhoneDSHBootPhase.parse("worker boot ready"))
        XCTAssertNil(PhoneDSHBootPhase.parse("pdsh-boot-phase scope=page phase=bad token active_ms=1"))
        XCTAssertNil(PhoneDSHBootPhase.parse("pdsh-boot-phase scope=page phase=ok active_ms=NaN"))
        XCTAssertNil(PhoneDSHBootPhase.parse("pdsh-boot-phase scope=page active_ms=1"))
        XCTAssertNil(PhoneDSHBootPhase.parse(
            "pdsh-boot-phase scope=page phase=" + String(repeating: "x", count: 80)
                + " active_ms=1"))
    }

    func testRecorderWritesAWorkerPhasesLineBesideBootTimings() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-boot-phases-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let recorder = PhoneDSHBootPhaseRecorder()
        recorder.begin(bootID: "a" + String(repeating: "0", count: 31), workspaceRoot: workspace)
        recorder.record(PhoneDSHBootPhase(scope: "page", phase: "worker-spawned",
                                          activeMilliseconds: 42))
        XCTAssertEqual(recorder.recordedCount, 1)
        let text = try String(contentsOf: root.appendingPathComponent("boot-timings.log"),
                              encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("worker-phases "), "unexpected line: \(text)")
        XCTAssertTrue(text.contains("scope=page phase=worker-spawned active_ms=42"),
                      "unexpected line: \(text)")
    }
}
