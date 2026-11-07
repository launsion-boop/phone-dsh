// SPDX-License-Identifier: MIT
import Foundation
import SwiftUI
import UIKit
import XCTest
import PhoneDSHDeviceTasks

@MainActor
final class LegacyTaskInspectionModelTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.lock(); count += 1; lock.unlock() }
        func value() -> Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    private actor PausedInspector {
        private(set) var calls = 0
        private var continuation: CheckedContinuation<Void, Never>?
        func inspect() async -> DeviceTaskLegacyInspection {
            calls += 1
            await withCheckedContinuation { continuation = $0 }
            return DeviceTaskLegacyInspection(status: .incomplete, entries: [], cancelled: true, reasons: [.cancelled])
        }
        func release() { continuation?.resume(); continuation = nil }
    }

    private func waitUntil(_ predicate: @escaping @MainActor () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for inspection", file: file, line: line)
    }

    func testNoInspectionUntilExplicitStart() async throws {
        let calls = Counter()
        let model = LegacyTaskInspectionModel(inspect: {
            calls.increment()
            return DeviceTaskLegacyInspection(status: .busy, entries: [], cancelled: false, reasons: [])
        })
        await Task.yield()
        XCTAssertEqual(calls.value(), 0)
        XCTAssertNil(model.result)
        model.start()
        try await waitUntil { !model.isInspecting }
        XCTAssertEqual(calls.value(), 1)
        XCTAssertEqual(model.result?.status, .busy)
    }

    func testCancellationDoesNotPermitAnotherScanUntilInspectorReturns() async throws {
        let paused = PausedInspector()
        let model = LegacyTaskInspectionModel(inspect: { await paused.inspect() })
        model.start()
        for _ in 0..<200 {
            if await paused.calls == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let startedCalls = await paused.calls
        XCTAssertEqual(startedCalls, 1)
        model.cancel()
        XCTAssertTrue(model.isInspecting)
        XCTAssertTrue(model.cancellationRequested)
        model.start()
        let callsAfterSecondStart = await paused.calls
        XCTAssertEqual(callsAfterSecondStart, 1)
        await paused.release()
        try await waitUntil { !model.isInspecting }
        XCTAssertEqual(model.result?.status, .incomplete)
        XCTAssertEqual(model.result?.cancelled, true)
        XCTAssertFalse(model.cancellationRequested)
    }

    func testRealScannerLeavesEvidenceUnchangedAndDoesNotCreateLock() async throws {
        let support = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        let root = support.appendingPathComponent("device-task-journal", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "The isolated test container must start without a journal")
        guard !FileManager.default.fileExists(atPath: root.path) else { return }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("history.json")
        let bytes = Data(#"{"device_id":"ble:old","task":{"id":"task-1","body":{"text":"SECRET_NOT_FOR_UI"}},"phase":"running"}"#.utf8)
        try bytes.write(to: file)
        let model = LegacyTaskInspectionModel()
        model.start()
        try await waitUntil { !model.isInspecting }
        XCTAssertEqual(model.result?.status, .incomplete)
        let entry = try XCTUnwrap(model.result?.entries.first { $0.label == "history.json" })
        XCTAssertEqual(entry.claims?.deviceID, "ble%3Aold")
        XCTAssertEqual(entry.claims?.taskID, "task-1")
        XCTAssertEqual(entry.claims?.phase, "running")
        XCTAssertFalse(String(reflecting: model.result).contains("SECRET_NOT_FOR_UI"))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".lock").path))
    }

    func testLongEscapedClaimExpandsTheRealSectionInsteadOfClipping() async throws {
        let encoded = String(repeating: "%C3%A9", count: 128) // 256 UTF-8 bytes before escaping.
        let entry = DeviceTaskLegacyInspection.Entry(
            id: "history.json", label: "history.json", kind: .observed,
            claims: .init(deviceID: encoded, taskID: "task-1", phase: "running", outcomeKind: nil))
        let model = LegacyTaskInspectionModel(inspect: {
            .init(status: .incomplete, entries: [entry], cancelled: false, reasons: [])
        })
        func height() -> CGFloat {
            let host = UIHostingController(rootView: VStack { LegacyTaskInspectionSection(model: model, language: .en) })
            return host.sizeThatFits(in: CGSize(width: 300, height: 10_000)).height
        }
        let before = height()
        model.start()
        try await waitUntil { !model.isInspecting }
        let after = height()
        XCTAssertGreaterThan(after, before + 100, "The full escaped claim must have room to wrap.")
    }

    func testSectionHonorsManualLanguageOverrideWithoutWritingPreferences() {
        let model = LegacyTaskInspectionModel()
        let suite = "legacy-language-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = NativeChatPreferences(defaults: defaults)
        preferences.setLanguage(.zh)
        let beforeChinese = defaults.persistentDomain(forName: suite) ?? [:]
        let chinese = LegacyTaskInspectionSection(model: model, language: preferences.language)
        XCTAssertEqual(chinese.localized("中文", "English"), "中文")
        XCTAssertEqual(NSDictionary(dictionary: beforeChinese), NSDictionary(dictionary: defaults.persistentDomain(forName: suite) ?? [:]))
        preferences.setLanguage(.en)
        let beforeEnglish = defaults.persistentDomain(forName: suite) ?? [:]
        let english = LegacyTaskInspectionSection(model: model, language: preferences.language)
        let system = LegacyTaskInspectionSection(model: model, language: .system)
        XCTAssertEqual(english.localized("中文", "English"), "English")
        XCTAssertEqual(system.localized("中文", "English"),
                       Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "中文" : "English")
        let chineseHost = UIHostingController(rootView: VStack { chinese }.environment(\.locale, Locale(identifier: "en")))
        let englishHost = UIHostingController(rootView: VStack { english }.environment(\.locale, Locale(identifier: "zh")))
        XCTAssertGreaterThan(chineseHost.sizeThatFits(in: CGSize(width: 300, height: 10_000)).height, 0)
        XCTAssertGreaterThan(englishHost.sizeThatFits(in: CGSize(width: 300, height: 10_000)).height, 0)
        XCTAssertEqual(NSDictionary(dictionary: beforeEnglish), NSDictionary(dictionary: defaults.persistentDomain(forName: suite) ?? [:]))
    }
}
