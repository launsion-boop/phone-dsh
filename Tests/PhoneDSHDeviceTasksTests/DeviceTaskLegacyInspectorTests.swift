// SPDX-License-Identifier: MIT
import Darwin
import Foundation
import XCTest
@testable import PhoneDSHDeviceTasks

final class DeviceTaskLegacyInspectorTests: XCTestCase {
    private var repo: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private func temporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }
    private func vectors<T: Decodable>(_ name: String, as: T.Type) throws -> [T] {
        let file = repo.appendingPathComponent("spec/device/v1/golden/" + name)
        return try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map { try JSONDecoder().decode(T.self, from: Data($0.utf8)) }
    }
    private struct PathVector: Decodable {
        let name: String
        let components_hex: [String]
        let valid: Bool
        let escaped: String?
        var components: [[UInt8]] {
            components_hex.map { text in
                stride(from: 0, to: text.count, by: 2).map { offset in
                    let a = text.index(text.startIndex, offsetBy: offset)
                    return UInt8(text[a..<text.index(a, offsetBy: 2)], radix: 16)!
                }
            }
        }
    }
    private struct ClaimsVector: Decodable {
        struct Claims: Decodable {
            let deviceID: String?, taskID: String?, phase: String?, outcomeKind: String?
        }
        let name, role, raw: String
        let claims: Claims?
    }
    private struct Scenario: Decodable { let name, scenario, expected: String }
    private struct RootVector: Decodable {
        let name, scenario: String
        let expected_reason: String?
        let sees_record: Bool
    }
    private struct DeepVector: Decodable {
        let name, encoding, mutation, expected: String
        let depth: Int
        let check_valid: Bool
    }

    private func makeTask() throws -> DeviceTask {
        try DeviceTask.decode(Data("{\"id\":\"task-1\",\"idempotency_key\":\"key-1\",\"requester\":\"sensor\",\"created_at\":\"2026-11-06T00:00:00Z\",\"body\":{\"type\":\"goal\",\"text\":\"private body\"}}".utf8))
    }

    private func resetHooks() {
        DeviceTaskJournal.testAfterInitializationReservation = nil
        DeviceTaskJournal.testBeforeOwnerClose = nil
        DeviceTaskLegacyInspector.testAfterReservation = nil
        DeviceTaskLegacyInspector.testAfterStat = nil
        DeviceTaskLegacyInspector.testFileOpened = nil
        DeviceTaskLegacyInspector.testDirectoryOpened = nil
        DeviceTaskLegacyInspector.testBeforeRelease = nil
    }

    func testSharedRawPathVectorsThroughRealEncoder() throws {
        let rows = try vectors("legacy-task-inspection-paths.jsonl", as: PathVector.self)
        XCTAssertEqual(rows.count, 10)
        for row in rows {
            let result = DeviceTaskLegacyInspector.escapedPath(row.components)
            XCTAssertEqual(result, row.escaped, row.name)
            XCTAssertEqual(result != nil, row.valid, row.name)
        }
    }

    func testSharedClaimVectorsThroughRealFilesAndScanner() async throws {
        let rows = try vectors("legacy-task-inspection-claims.jsonl", as: ClaimsVector.self)
        XCTAssertEqual(rows.count, 13)
        for row in rows {
            let root = try temporaryDirectory()
            let dir = row.role == "intent" ? root.appendingPathComponent("ble-ops") : root
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("record.json")
            let original = Data(row.raw.utf8)
            try original.write(to: file)
            let result = await DeviceTaskLegacyInspector.inspect(directory: root)
            XCTAssertEqual(result.status, .incomplete, row.name)
            let entry = try XCTUnwrap(result.entries.first, row.name)
            XCTAssertEqual(entry.id, row.role == "intent" ? "ble-ops/record.json" : "record.json", row.name)
            if let expected = row.claims {
                XCTAssertEqual(entry.kind, .observed, row.name)
                let actual = try XCTUnwrap(entry.claims, row.name)
                XCTAssertEqual(actual.deviceID, expected.deviceID, row.name)
                XCTAssertEqual(actual.taskID, expected.taskID, row.name)
                XCTAssertEqual(actual.phase, expected.phase, row.name)
                XCTAssertEqual(actual.outcomeKind, expected.outcomeKind, row.name)
            } else {
                XCTAssertNil(entry.claims, row.name)
            }
            XCTAssertEqual(try Data(contentsOf: file), original, row.name)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".lock").path), row.name)
        }
    }

    func testMissingRootDoesNotCreateAnything() async throws {
        let parent = try temporaryDirectory()
        let dir = parent.appendingPathComponent("missing")
        let result = await DeviceTaskLegacyInspector.inspect(directory: dir)
        XCTAssertEqual(result.status, .incomplete)
        XCTAssertEqual(result.reasons, [.rootMissing])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    func testSharedRootVectorsThroughRealScanner() async throws {
        let rows = try vectors("legacy-task-inspection-roots.jsonl", as: RootVector.self)
        XCTAssertEqual(rows.count, 22)
        let parent = try temporaryDirectory()
        let normal = parent.appendingPathComponent("normal"), outside = parent.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: normal, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let normalBytes = Data("{\"device_id\":\"normal\"}".utf8), outsideBytes = Data("{\"device_id\":\"outside\"}".utf8)
        try normalBytes.write(to: normal.appendingPathComponent("record.json"))
        try outsideBytes.write(to: outside.appendingPathComponent("secret.json"))
        let link = parent.appendingPathComponent("link")
        XCTAssertEqual(symlink(outside.path, link.path), 0)
        let filePrefix = "file://" + normal.path
        let linkPrefix = "file://" + link.path
        for row in rows {
            let target: URL
            switch row.scenario {
            case "normal", "trusted_ancestor": target = normal
            case "trailing": target = URL(fileURLWithPath: normal.path + "/")
            case "root_link": target = URL(fileURLWithPath: link.path)
            case "link_trailing": target = URL(fileURLWithPath: link.path + "/")
            case "link_dot": target = URL(fileURLWithPath: link.path + "/.")
            case "link_dotdot": target = URL(fileURLWithPath: link.path + "/..")
            case "encoded_dot": target = try XCTUnwrap(URL(string: linkPrefix + "/%2e"))
            case "encoded_dotdot": target = try XCTUnwrap(URL(string: linkPrefix + "/%2e%2e"))
            case "remote_host": target = try XCTUnwrap(URL(string: "file://untrusted-host" + normal.path))
            case "localhost": target = try XCTUnwrap(URL(string: "file://localhost" + normal.path))
            case "encoded_localhost": target = try XCTUnwrap(URL(string: "file://%6co%63alhost" + normal.path))
            case "userinfo_empty": target = try XCTUnwrap(URL(string: "file://@" + normal.path))
            case "password": target = try XCTUnwrap(URL(string: "file://user:secret@host" + normal.path))
            case "port":
                target = try XCTUnwrap(URL(string: "file://:42" + normal.path))
                XCTAssertTrue(target.host?.isEmpty ?? true, row.name)
                XCTAssertNil(target.user, row.name)
                XCTAssertNil(target.password, row.name)
                XCTAssertEqual(target.port, 42, row.name)
            case "query": target = try XCTUnwrap(URL(string: filePrefix + "?query"))
            case "empty_query": target = try XCTUnwrap(URL(string: filePrefix + "?"))
            case "fragment": target = try XCTUnwrap(URL(string: filePrefix + "#fragment"))
            case "empty_fragment": target = try XCTUnwrap(URL(string: filePrefix + "#"))
            case "non_file": target = try XCTUnwrap(URL(string: "https://example.com/"))
            case "relative": target = try XCTUnwrap(URL(string: "file:relative"))
            case "root_only": target = URL(fileURLWithPath: "/")
            default: XCTFail("Unknown root fixture \(row.name)"); continue
            }
            if row.scenario == "trusted_ancestor" {
                // FileManager's real /var/folders temporary root traverses the
                // OS-managed /var -> /private/var symlink on this platform.
                var info = stat()
                XCTAssertEqual(lstat("/var", &info), 0, row.name)
                XCTAssertEqual(info.st_mode & S_IFMT, S_IFLNK, row.name)
                XCTAssertTrue(normal.path.hasPrefix("/var/"), row.name)
            }
            let result = await DeviceTaskLegacyInspector.inspect(directory: target)
            XCTAssertEqual(result.status, .incomplete, row.name)
            XCTAssertEqual(result.reasons.first?.rawValue, row.expected_reason, row.name)
            XCTAssertEqual(result.entries.contains { $0.id == "record.json" }, row.sees_record, row.name)
            XCTAssertFalse(result.entries.contains { $0.claims?.deviceID == "outside" }, row.name)
            XCTAssertEqual(try Data(contentsOf: normal.appendingPathComponent("record.json")), normalBytes, row.name)
            XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("secret.json")), outsideBytes, row.name)
        }
    }

    func testApplicationSupportIntegrationDoesNotCreateStorage() async throws {
        let parent = try temporaryDirectory()
        let missing = parent.appendingPathComponent("missing")
        let noOSDirectory = await DeviceTaskLegacyInspector.inspect(applicationSupport: nil)
        XCTAssertEqual(noOSDirectory.reasons, [.rootUnreadable])
        let absent = await DeviceTaskLegacyInspector.inspect(applicationSupport: missing)
        XCTAssertEqual(absent.reasons, [.rootMissing])
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        let journal = parent.appendingPathComponent("device-task-journal")
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: false)
        try Data("{}".utf8).write(to: journal.appendingPathComponent("record.json"))
        let found = await DeviceTaskLegacyInspector.inspect(applicationSupport: parent)
        XCTAssertEqual(found.entries.map(\.id), ["record.json"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.appendingPathComponent(".lock").path))
    }

    func testCancelledApplicationSupportLookupDoesNotCreateStorage() async throws {
        let parent = try temporaryDirectory()
        let missing = parent.appendingPathComponent("missing")
        let entered = DispatchSemaphore(value: 0), proceed = DispatchSemaphore(value: 0)
        let inspection = Task.detached {
            entered.signal()
            _ = proceed.wait(timeout: .now() + 10)
            return [
                await DeviceTaskLegacyInspector.inspect(applicationSupport: nil),
                await DeviceTaskLegacyInspector.inspect(applicationSupport: missing),
                await DeviceTaskLegacyInspector.inspect()
            ]
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        inspection.cancel()
        proceed.signal()
        for result in await inspection.value {
            XCTAssertEqual(result.status, .incomplete)
            XCTAssertTrue(result.cancelled)
            XCTAssertEqual(result.reasons, [.cancelled])
            XCTAssertTrue(result.entries.isEmpty)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    func testRootSymlinkIsUnsupportedAndNeverFollowed() async throws {
        let parent = try temporaryDirectory(), target = try temporaryDirectory()
        let file = target.appendingPathComponent("private.json"), secret = Data("{\"device_id\":\"outside\"}".utf8)
        try secret.write(to: file)
        let root = parent.appendingPathComponent("journal")
        XCTAssertEqual(symlink(target.path, root.path), 0)
        let result = await DeviceTaskLegacyInspector.inspect(directory: root)
        XCTAssertEqual(result.status, .incomplete)
        XCTAssertEqual(result.reasons, [.rootUnsupported])
        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), secret)
    }

    func testRootReplacementKeepsScanAnchoredToOpenedDirectory() async throws {
        let parent = try temporaryDirectory(), outside = try temporaryDirectory()
        let root = parent.appendingPathComponent("journal"), moved = parent.appendingPathComponent("old-journal")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try Data("{\"device_id\":\"original\"}".utf8).write(to: root.appendingPathComponent("old.json"))
        let secret = Data("{\"device_id\":\"outside\"}".utf8)
        try secret.write(to: outside.appendingPathComponent("outside.json"))
        var first = true
        DeviceTaskLegacyInspector.testDirectoryOpened = { _ in
            guard first else { return }; first = false
            _ = Darwin.rename(root.path, moved.path)
            _ = symlink(outside.path, root.path)
        }
        defer { resetHooks() }
        let result = await DeviceTaskLegacyInspector.inspect(directory: root)
        XCTAssertEqual(result.status, .incomplete)
        XCTAssertEqual(result.entries.map(\.id), ["old.json"])
        XCTAssertEqual(result.entries.first?.claims?.deviceID, "original")
        XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("outside.json")), secret)
    }

    func testIntentDirectoryReplacementDoesNotFollowSymlink() async throws {
        let root = try temporaryDirectory(), outside = try temporaryDirectory()
        let dir = root.appendingPathComponent("ble-ops"), moved = root.appendingPathComponent("moved")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        try Data("{}".utf8).write(to: dir.appendingPathComponent("old.json"))
        let secret = Data("{\"device_id\":\"outside\"}".utf8)
        try secret.write(to: outside.appendingPathComponent("outside.json"))
        DeviceTaskLegacyInspector.testAfterStat = { id in
            guard id == "ble-ops" else { return }
            _ = Darwin.rename(dir.path, moved.path); _ = symlink(outside.path, dir.path)
        }
        defer { resetHooks() }
        let result = await DeviceTaskLegacyInspector.inspect(directory: root)
        XCTAssertEqual(result.status, .incomplete)
        XCTAssertEqual(result.entries.first { $0.id == "ble-ops" }?.kind, .unreadable)
        XCTAssertFalse(result.entries.contains { $0.claims?.deviceID == "outside" })
        XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("outside.json")), secret)
    }

    func testFileReplacementAfterOpenReadsOnlyOpenedInode() async throws {
        let root = try temporaryDirectory(), outside = try temporaryDirectory()
        let victim = root.appendingPathComponent("victim.json"), moved = root.appendingPathComponent("moved.json")
        let original = Data("{\"device_id\":\"original\"}".utf8)
        let secret = Data("{\"device_id\":\"outside\"}".utf8)
        try original.write(to: victim); try secret.write(to: outside.appendingPathComponent("secret.json"))
        var once = false
        DeviceTaskLegacyInspector.testFileOpened = { _ in
            guard !once else { return }; once = true
            _ = Darwin.rename(victim.path, moved.path)
            _ = symlink(outside.appendingPathComponent("secret.json").path, victim.path)
        }
        defer { resetHooks() }
        let result = await DeviceTaskLegacyInspector.inspect(directory: root)
        XCTAssertEqual(result.status, .incomplete)
        XCTAssertEqual(result.entries.first { $0.id == "victim.json" }?.claims?.deviceID, "original")
        XCTAssertFalse(result.entries.contains { $0.claims?.deviceID == "outside" })
        XCTAssertEqual(try Data(contentsOf: moved), original)
        XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("secret.json")), secret)
    }

    func testSharedScenarioManifestThroughRealJournalAndFilesystem() async throws {
        let rows = try vectors("legacy-task-inspection.jsonl", as: Scenario.self)
        XCTAssertEqual(rows.count, 16)
        for row in rows {
            resetHooks()
            let root = try temporaryDirectory()
            switch row.scenario {
            case "child-lock", "child-hardlinked-lock":
                defer { resetHooks() }
                do {
                    let journal = try DeviceTaskJournal(directory: root)
                    XCTAssertNotNil(journal)
                } // Release the actual owner and its lock before inspection.
                let rootLock = root.appendingPathComponent(".lock")
                let rootBytes = Data("historical root lock".utf8)
                try rootBytes.write(to: rootLock)
                let dir = root.appendingPathComponent("ble-ops")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
                let child = dir.appendingPathComponent(".lock")
                let childBytes = row.scenario == "child-lock" ? Data("unrecognized child".utf8) : rootBytes
                if row.scenario == "child-hardlinked-lock" {
                    XCTAssertEqual(Darwin.link(rootLock.path, child.path), 0, row.name)
                    var rootInfo = stat(), childInfo = stat()
                    XCTAssertEqual(lstat(rootLock.path, &rootInfo), 0, row.name)
                    XCTAssertEqual(lstat(child.path, &childInfo), 0, row.name)
                    XCTAssertEqual(rootInfo.st_dev, childInfo.st_dev, row.name)
                    XCTAssertEqual(rootInfo.st_ino, childInfo.st_ino, row.name)
                    XCTAssertEqual(rootInfo.st_nlink, 2, row.name)
                    XCTAssertEqual(childInfo.st_nlink, 2, row.name)
                } else {
                    try childBytes.write(to: child)
                }
                var candidateOpens = 0
                DeviceTaskLegacyInspector.testFileOpened = { _ in candidateOpens += 1 }
                let result = await DeviceTaskLegacyInspector.inspect(directory: root)
                XCTAssertEqual(result.status.rawValue, row.expected, row.name)
                XCTAssertFalse(result.entries.contains { $0.id == ".lock" }, row.name)
                let matches = result.entries.filter { $0.id == "ble-ops/.lock" }
                XCTAssertEqual(matches.count, 1, row.name)
                XCTAssertEqual(matches.first?.label, "ble-ops/.lock", row.name)
                XCTAssertEqual(matches.first?.kind, .unexamined, row.name)
                XCTAssertNil(matches.first?.claims, row.name)
                XCTAssertEqual(candidateOpens, 0, row.name)
                XCTAssertEqual(try Data(contentsOf: rootLock), rootBytes, row.name)
                XCTAssertEqual(try Data(contentsOf: child), childBytes, row.name)
            case "absent":
                let missing = root.appendingPathComponent("absent")
                let r = await DeviceTaskLegacyInspector.inspect(directory: missing)
                XCTAssertEqual(r.status.rawValue, row.expected, row.name)
                XCTAssertEqual(r.reasons, [.rootMissing], row.name)
                XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
            case "ordinary", "mixed":
                do {
                    let journal = try DeviceTaskJournal(directory: root)
                    _ = try journal.create(deviceID: "ble:old", task: makeTask(), sessionID: "s", now: Date())
                    if row.scenario == "mixed" {
                        _ = try journal.create(deviceID: "lan:old", task: makeTask(), sessionID: "t", now: Date())
                    }
                }
                let before = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
                let result = await DeviceTaskLegacyInspector.inspect(directory: root)
                XCTAssertEqual(result.status.rawValue, row.expected, row.name)
                XCTAssertEqual(result.entries.count, row.scenario == "mixed" ? 2 : 1, row.name)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), before)
                XCTAssertTrue(result.entries.allSatisfy { $0.kind == .observed })
                XCTAssertTrue(result.entries.contains { $0.claims?.deviceID == "ble%3Aold" })
                if row.scenario == "mixed" { XCTAssertTrue(result.entries.contains { $0.claims?.deviceID == "lan%3Aold" }) }
            case "malformed":
                let f = root.appendingPathComponent("bad.json"); let bytes = Data("{\"x\":".utf8); try bytes.write(to: f)
                let r = await DeviceTaskLegacyInspector.inspect(directory: root)
                XCTAssertEqual(r.status.rawValue, row.expected); XCTAssertEqual(r.entries.first?.kind, .unparsed)
                XCTAssertEqual(try Data(contentsOf: f), bytes)
            case "orphan":
                let dir = root.appendingPathComponent("ble-ops"); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
                let f = dir.appendingPathComponent("orphan.json"); let bytes = Data("{\"task_id\":\"old\"}".utf8); try bytes.write(to: f)
                let r = await DeviceTaskLegacyInspector.inspect(directory: root)
                XCTAssertEqual(r.status.rawValue, row.expected); XCTAssertEqual(r.entries.first?.claims?.taskID, "old")
                XCTAssertEqual(try Data(contentsOf: f), bytes)
            case "symlink":
                let target = try temporaryDirectory().appendingPathComponent("target")
                let bytes = Data("{\"device_id\":\"secret\"}".utf8); try bytes.write(to: target)
                XCTAssertEqual(symlink(target.path, root.appendingPathComponent("link").path), 0)
                let r = await DeviceTaskLegacyInspector.inspect(directory: root)
                XCTAssertEqual(r.status.rawValue, row.expected); XCTAssertEqual(r.entries.first?.kind, .symlink)
                XCTAssertEqual(try Data(contentsOf: target), bytes)
            case "fifo":
                XCTAssertEqual(mkfifo(root.appendingPathComponent("fifo").path, 0o600), 0)
                let r = await DeviceTaskLegacyInspector.inspect(directory: root)
                XCTAssertEqual(r.status.rawValue, row.expected); XCTAssertEqual(r.entries.first?.kind, .nonRegular)
            case "hardlink-lock", "active-owner":
                var journal: DeviceTaskJournal? = try DeviceTaskJournal(directory: root)
                if row.scenario == "hardlink-lock" {
                    let lock = root.appendingPathComponent(".lock").path
                    XCTAssertEqual(Darwin.link(lock, root.appendingPathComponent("candidate.json").path), 0)
                    XCTAssertEqual(Darwin.unlink(lock), 0)
                }
                let r = await DeviceTaskLegacyInspector.inspect(directory: root)
                XCTAssertEqual(r.status.rawValue, row.expected); XCTAssertTrue(r.entries.isEmpty)
                XCTAssertNotNil(journal); journal = nil
            case "pending-init":
                let entered = DispatchSemaphore(value: 0), proceed = DispatchSemaphore(value: 0)
                DeviceTaskJournal.testAfterInitializationReservation = { entered.signal(); _ = proceed.wait(timeout: .now() + 10) }
                let owner = Task.detached { try DeviceTaskJournal(directory: root) }
                XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
                let r = await DeviceTaskLegacyInspector.inspect(directory: root)
                XCTAssertEqual(r.status.rawValue, row.expected); XCTAssertTrue(r.entries.isEmpty)
                proceed.signal(); _ = try await owner.value
                DeviceTaskJournal.testAfterInitializationReservation = nil
            case "concurrent-scan":
                let entered = DispatchSemaphore(value: 0), proceed = DispatchSemaphore(value: 0)
                DeviceTaskLegacyInspector.testAfterReservation = { entered.signal(); _ = proceed.wait(timeout: .now() + 10) }
                let first = Task.detached { await DeviceTaskLegacyInspector.inspect(directory: root) }
                XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
                let r = await DeviceTaskLegacyInspector.inspect(directory: root)
                XCTAssertEqual(r.status.rawValue, row.expected); XCTAssertTrue(r.entries.isEmpty)
                XCTAssertThrowsError(try DeviceTaskJournal(directory: root)) { XCTAssertEqual($0 as? DeviceTaskError, .deviceBusy) }
                proceed.signal(); _ = await first.value
                DeviceTaskLegacyInspector.testAfterReservation = nil
            case "budget":
                let file = root.appendingPathComponent("large.json"), bytes = Data(repeating: 32, count: 65_537)
                try bytes.write(to: file)
                let r = await DeviceTaskLegacyInspector.inspect(directory: root)
                XCTAssertEqual(r.status.rawValue, row.expected); XCTAssertEqual(r.entries.first?.kind, .unexamined)
                XCTAssertTrue(r.reasons.contains(.byteBudget)); XCTAssertEqual(try Data(contentsOf: file), bytes)
            case "cancel":
                let entered = DispatchSemaphore(value: 0), proceed = DispatchSemaphore(value: 0), beforeRelease = DispatchSemaphore(value: 0), finish = DispatchSemaphore(value: 0)
                let file = root.appendingPathComponent("record.json"); try Data("{}".utf8).write(to: file)
                var captured: Int32 = -1; var directories: [Int32] = []; var closedBeforeRelease = false
                DeviceTaskLegacyInspector.testDirectoryOpened = { directories.append($0) }
                DeviceTaskLegacyInspector.testFileOpened = { fd in captured = fd; entered.signal(); _ = proceed.wait(timeout: .now() + 10) }
                DeviceTaskLegacyInspector.testBeforeRelease = {
                    closedBeforeRelease = ([captured] + directories).allSatisfy { Darwin.fcntl($0, F_GETFD) == -1 && errno == EBADF }
                    beforeRelease.signal(); _ = finish.wait(timeout: .now() + 10)
                }
                let inspection = Task.detached { await DeviceTaskLegacyInspector.inspect(directory: root) }
                XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
                inspection.cancel()
                XCTAssertThrowsError(try DeviceTaskJournal(directory: root)) { XCTAssertEqual($0 as? DeviceTaskError, .deviceBusy) }
                proceed.signal(); XCTAssertEqual(beforeRelease.wait(timeout: .now() + 5), .success)
                XCTAssertTrue(closedBeforeRelease, "file fd must be closed before reservation release")
                XCTAssertThrowsError(try DeviceTaskJournal(directory: root)) { XCTAssertEqual($0 as? DeviceTaskError, .deviceBusy) }
                finish.signal(); let r = await inspection.value
                XCTAssertEqual(r.status.rawValue, row.expected); XCTAssertTrue(r.cancelled); XCTAssertTrue(r.reasons.contains(.cancelled))
                resetHooks(); XCTAssertNoThrow(try DeviceTaskJournal(directory: root))
            case "replace":
                let victim = root.appendingPathComponent("victim.json"), moved = root.appendingPathComponent("moved.json")
                let bytes = Data("{}".utf8); try bytes.write(to: victim)
                let target = try temporaryDirectory().appendingPathComponent("secret")
                let secret = Data("{\"device_id\":\"outside\"}".utf8); try secret.write(to: target)
                DeviceTaskLegacyInspector.testAfterStat = { id in
                    guard id == "victim.json" else { return }
                    _ = Darwin.rename(victim.path, moved.path); _ = symlink(target.path, victim.path)
                }
                let r = await DeviceTaskLegacyInspector.inspect(directory: root)
                XCTAssertEqual(r.status.rawValue, row.expected)
                XCTAssertEqual(r.entries.first { $0.id == "victim.json" }?.kind, .unreadable)
                XCTAssertEqual(try Data(contentsOf: moved), bytes); XCTAssertEqual(try Data(contentsOf: target), secret)
                DeviceTaskLegacyInspector.testAfterStat = nil
            default: XCTFail("Unhandled shared scenario \(row.name)")
            }
        }
        resetHooks()
    }

    func testChildLockSpecialEntriesRemainUnexaminedWithoutOpening() async throws {
        defer { resetHooks() }
        for kind in ["symlink", "fifo", "directory"] {
            let root = try temporaryDirectory()
            let dir = root.appendingPathComponent("ble-ops")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
            let child = dir.appendingPathComponent(".lock")
            let target = try temporaryDirectory().appendingPathComponent("outside")
            let secret = Data("not for inspection".utf8)
            try secret.write(to: target)
            if kind == "symlink" {
                XCTAssertEqual(symlink(target.path, child.path), 0)
            } else if kind == "fifo" {
                XCTAssertEqual(mkfifo(child.path, 0o600), 0)
            } else {
                try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
                try secret.write(to: child.appendingPathComponent("sentinel"))
            }
            var candidateOpens = 0
            var directoryOpens: [String] = []
            func identity(_ info: stat) -> String { "\(info.st_dev):\(info.st_ino)" }
            var rootInfo = stat(), dirInfo = stat()
            XCTAssertEqual(lstat(root.path, &rootInfo), 0, kind)
            XCTAssertEqual(lstat(dir.path, &dirInfo), 0, kind)
            let allowedDirectories = Set([identity(rootInfo), identity(dirInfo)])
            DeviceTaskLegacyInspector.testFileOpened = { _ in candidateOpens += 1 }
            DeviceTaskLegacyInspector.testDirectoryOpened = { fd in
                var info = stat()
                if fstat(fd, &info) == 0 { directoryOpens.append(identity(info)) }
                else { XCTFail("Could not inspect opened directory descriptor") }
            }
            let result = await DeviceTaskLegacyInspector.inspect(directory: root)
            let matches = result.entries.filter { $0.id == "ble-ops/.lock" }
            XCTAssertEqual(matches.count, 1, kind)
            XCTAssertEqual(matches.first?.kind, .unexamined, kind)
            XCTAssertNil(matches.first?.claims, kind)
            XCTAssertEqual(candidateOpens, 0, kind)
            XCTAssertEqual(directoryOpens.count, 4, kind)
            XCTAssertEqual(Set(directoryOpens), allowedDirectories, kind)
            var info = stat()
            XCTAssertEqual(lstat(child.path, &info), 0, kind)
            let expectedType = kind == "symlink" ? S_IFLNK : (kind == "fifo" ? S_IFIFO : S_IFDIR)
            XCTAssertEqual(info.st_mode & S_IFMT, expectedType, kind)
            XCTAssertEqual(try Data(contentsOf: target), secret, kind)
            if kind == "directory" {
                XCTAssertEqual(try Data(contentsOf: child.appendingPathComponent("sentinel")), secret)
                XCTAssertFalse(result.entries.contains { $0.id.hasPrefix("ble-ops/.lock/") })
            }
        }
    }

    func testSymlinksFIFOHardlinksAndUnicodeNamesDoNotModifyEvidence() async throws {
        let root = try temporaryDirectory()
        let outside = try temporaryDirectory().appendingPathComponent("secret.json")
        let secret = Data("{\"device_id\":\"not-readable\"}".utf8)
        try secret.write(to: outside)
        let link = root.appendingPathComponent("link.json")
        XCTAssertEqual(symlink(outside.path, link.path), 0)
        let fifo = root.appendingPathComponent("pipe.json")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let original = root.appendingPathComponent("one.json")
        try Data("{}".utf8).write(to: original)
        let alias = root.appendingPathComponent("two.json")
        XCTAssertEqual(Darwin.link(original.path, alias.path), 0)
        let unicode = root.appendingPathComponent("\u{202e}name%.json")
        try Data("{}".utf8).write(to: unicode)
        let result = await DeviceTaskLegacyInspector.inspect(directory: root)
        XCTAssertEqual(result.status, .incomplete)
        let byID = Dictionary(uniqueKeysWithValues: result.entries.map { ($0.id, $0) })
        XCTAssertEqual(byID["link.json"]?.kind, .symlink)
        XCTAssertEqual(byID["pipe.json"]?.kind, .nonRegular)
        XCTAssertEqual(byID["one.json"]?.kind, .unexamined)
        XCTAssertEqual(byID["two.json"]?.kind, .unexamined)
        XCTAssertEqual(byID["%E2%80%AEname%25.json"]?.kind, .observed)
        XCTAssertEqual(try Data(contentsOf: outside), secret)
        XCTAssertEqual(try Data(contentsOf: original), Data("{}".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".lock").path))
    }

    func testExactAndOverBudgetRecordBytesAreRetained() async throws {
        let root = try temporaryDirectory()
        let exact = root.appendingPathComponent("exact.json")
        let above = root.appendingPathComponent("above.json")
        let value = Data(("{\"x\":\"" + String(repeating: "x", count: 65_528) + "\"}").utf8)
        XCTAssertEqual(value.count, 65_536)
        try value.write(to: exact)
        let oversized = value + Data(" ".utf8)
        try oversized.write(to: above)
        let result = await DeviceTaskLegacyInspector.inspect(directory: root)
        let byID = Dictionary(uniqueKeysWithValues: result.entries.map { ($0.id, $0) })
        XCTAssertEqual(byID["exact.json"]?.kind, .observed)
        XCTAssertEqual(byID["above.json"]?.kind, .unexamined)
        XCTAssertTrue(result.reasons.contains(.byteBudget))
        XCTAssertEqual(try Data(contentsOf: exact), value)
        XCTAssertEqual(try Data(contentsOf: above), oversized)
    }

    func testTotalBudgetBoundaryDoesNotLabelOldDataCorrupt() async throws {
        let root = try temporaryDirectory()
        let value = Data(("{\"x\":\"" + String(repeating: "x", count: 65_528) + "\"}").utf8)
        for index in 0..<64 { try value.write(to: root.appendingPathComponent("record-\(index).json")) }
        let result = await DeviceTaskLegacyInspector.inspect(directory: root)
        XCTAssertEqual(result.status, .incomplete)
        XCTAssertEqual(result.entries.count, 64)
        XCTAssertEqual(result.entries.filter { $0.kind == .observed }.count, 63)
        XCTAssertEqual(result.entries.filter { $0.kind == .unexamined }.count, 1)
        XCTAssertTrue(result.reasons.contains(.byteBudget))
        for index in 0..<64 { XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("record-\(index).json")), value) }
    }

    func testEntryBudgetLeavesAllFilesUnchanged() async throws {
        let root = try temporaryDirectory()
        for index in 0..<16_386 {
            let path = root.appendingPathComponent("entry-\(index)").path
            let fd = Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
            XCTAssertGreaterThanOrEqual(fd, 0)
            if fd >= 0 { Darwin.close(fd) }
        }
        let result = await DeviceTaskLegacyInspector.inspect(directory: root)
        XCTAssertEqual(result.status, .incomplete)
        XCTAssertEqual(result.entries.count, 16_385)
        XCTAssertTrue(result.reasons.contains(.entryBudget))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 16_386)
    }

    func testOwnerRemainsReservedUntilRealLockIsClosed() async throws {
        final class Holder: @unchecked Sendable { var journal: DeviceTaskJournal?; init(_ journal: DeviceTaskJournal) { self.journal = journal } }
        let root = try temporaryDirectory()
        let holder = try Holder(DeviceTaskJournal(directory: root))
        let entered = DispatchSemaphore(value: 0), proceed = DispatchSemaphore(value: 0)
        DeviceTaskJournal.testBeforeOwnerClose = { entered.signal(); _ = proceed.wait(timeout: .now() + 10) }
        defer { proceed.signal(); DeviceTaskJournal.testBeforeOwnerClose = nil }
        let close = Task.detached { holder.journal = nil }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        let busy = await DeviceTaskLegacyInspector.inspect(directory: root)
        XCTAssertEqual(busy.status, .busy)
        proceed.signal(); await close.value
        DeviceTaskJournal.testBeforeOwnerClose = nil
        let after = await DeviceTaskLegacyInspector.inspect(directory: root)
        XCTAssertEqual(after.status, .incomplete)
    }

    func testDeepJSONDoesNotCrashScanner() async throws {
        let root = try temporaryDirectory()
        for depth in [999, 1000, 1001, 32_000] {
            let json = "{\"device_id\":\"ble:old\",\"unknown\":" + String(repeating: "[", count: depth) + "0" + String(repeating: "]", count: depth) + "}"
            let file = root.appendingPathComponent("depth-\(depth).json")
            try Data(json.utf8).write(to: file)
            let result = await DeviceTaskLegacyInspector.inspect(directory: root)
            XCTAssertEqual(result.status, .incomplete)
            let entry = try XCTUnwrap(result.entries.first { $0.id == file.lastPathComponent })
            XCTAssertTrue(entry.kind == .observed || entry.kind == .unparsed)
            XCTAssertEqual(try Data(contentsOf: file), Data(json.utf8))
        }
    }

    func testSharedDeepVectorsThroughRealScannerAndValidator() async throws {
        let rows = try vectors("legacy-task-inspection-deep.jsonl", as: DeepVector.self)
        XCTAssertEqual(rows.count, 12)
        for row in rows {
            let root = try temporaryDirectory()
            let leaf: String
            switch row.mutation {
            case "leaf_empty_array": leaf = "[]"
            case "leaf_nonempty_array": leaf = "[0]"
            default: leaf = "0"
            }
            var json = "{\"device_id\":\"ble:old\",\"unknown\":" + String(repeating: "[", count: row.depth) + leaf + String(repeating: "]", count: row.depth) + "}"
            switch row.mutation {
            case "missing_bracket":
                let last = try XCTUnwrap(json.lastIndex(of: "]"), row.name); json.remove(at: last)
            case "duplicate_device": json.insert(contentsOf: ",\"device\\u005fid\":\"other\"", at: json.index(before: json.endIndex))
            case "duplicate_unknown": json.insert(contentsOf: ",\"extra\":{\"x\":1,\"x\":2}", at: json.index(before: json.endIndex))
            default: break
            }
            let utf8 = Data(json.utf8)
            var validator = UniqueJSONKeys(utf8)
            XCTAssertEqual(validator.check(), row.check_valid, row.name)
            let bytes: Data
            switch row.encoding {
            case "utf16le": bytes = Data([0xff, 0xfe]) + (try XCTUnwrap(json.data(using: .utf16LittleEndian)))
            case "utf32be": bytes = Data([0, 0, 0xfe, 0xff]) + (try XCTUnwrap(json.data(using: .utf32BigEndian)))
            default: bytes = utf8
            }
            let file = root.appendingPathComponent("record.json")
            try bytes.write(to: file)
            let result = await DeviceTaskLegacyInspector.inspect(directory: root)
            let entry = try XCTUnwrap(result.entries.first, row.name)
            XCTAssertEqual(entry.kind.rawValue, row.expected, row.name)
            if row.expected == "observed" { XCTAssertEqual(entry.claims?.deviceID, "ble%3Aold", row.name) }
            else { XCTAssertNil(entry.claims, row.name) }
            XCTAssertEqual(try Data(contentsOf: file), bytes, row.name)
        }
    }

    func testActiveJournalBlocksInspectionWithoutReleasingRecordLock() async throws {
        let root = try temporaryDirectory()
        var journal: DeviceTaskJournal? = try DeviceTaskJournal(directory: root)
        XCTAssertNotNil(journal)
        let lockPath = root.appendingPathComponent(".lock").path
        let alias = root.appendingPathComponent("candidate.json").path
        XCTAssertEqual(Darwin.link(lockPath, alias), 0)
        // Unlink the original name so the alias has nlink=1 while it is still locked.
        XCTAssertEqual(Darwin.unlink(lockPath), 0)
        func childBlocked() throws -> Bool {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-c", "import fcntl,sys; f=open(sys.argv[1], 'r+');\ntry:\n fcntl.lockf(f,fcntl.LOCK_EX|fcntl.LOCK_NB); sys.exit(0)\nexcept BlockingIOError: sys.exit(1)", alias]
            try process.run(); process.waitUntilExit(); return process.terminationStatus == 1
        }
        XCTAssertTrue(try childBlocked())
        let result = await DeviceTaskLegacyInspector.inspect(directory: root)
        XCTAssertEqual(result.status, .busy)
        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertTrue(try childBlocked(), "inspection must not open/close a hard link to the held lock")
        journal = nil
        XCTAssertFalse(try childBlocked())
    }
}
