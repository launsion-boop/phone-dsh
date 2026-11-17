// SPDX-License-Identifier: MIT

import CryptoKit
import XCTest
@testable import PhoneDSHBot

/// P lane R2: the file producer must re-read the real file on every call and
/// never confuse a record's readable-text digest with raw file bytes.
final class BotFileSourceRecheckTests: XCTestCase {
    private var root: URL!
    private let now: Int64 = 1_760_000_030_000
    private let resource = BotFileResourceIdentity(key: "imports/attachments-a/report.txt")

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("file-recheck-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("imports/attachments-a", isDirectory: true),
            withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testRealFileChangesAreDetectedAndRestoresReturnUnchanged() async throws {
        try write("alpha")
        let baseline = BotFileBaseline.fileBytes("sha256:" + sha256("alpha"))
        let rechecker = makeRechecker()
        let first = await rechecker.recheck(resource, botID: "bot-a", baseline: baseline)
        guard case let .unchanged(version, at) = first else {
            return XCTFail("expected unchanged, got \(first)")
        }
        XCTAssertEqual(version.value, "sha256:" + sha256("alpha"))
        XCTAssertEqual(at, now)

        try write("beta")
        let changed = await rechecker.recheck(resource, botID: "bot-a", baseline: baseline)
        guard case let .changed(previous, current, _) = changed else {
            return XCTFail("expected changed, got \(changed)")
        }
        XCTAssertEqual(previous, baseline)
        XCTAssertEqual(current.value, "sha256:" + sha256("beta"))

        // Restoring the original bytes is unchanged relative to the original
        // baseline; a later read must not keep reporting the beta version.
        try write("alpha")
        let restored = await rechecker.recheck(resource, botID: "bot-a", baseline: baseline)
        guard case let .unchanged(restoredVersion, _) = restored else {
            return XCTFail("expected unchanged after restore, got \(restored)")
        }
        XCTAssertEqual(restoredVersion.value, "sha256:" + sha256("alpha"))
    }

    func testDeletedAndNonRegularFilesAreUnavailable() async throws {
        let rechecker = makeRechecker()
        let baseline = BotFileBaseline.fileBytes("sha256:" + sha256("alpha"))
        try write("alpha")
        try FileManager.default.removeItem(
            at: root.appendingPathComponent(resource.key))
        let deleted = await rechecker.recheck(resource, botID: "bot-a", baseline: baseline)
        guard case let .unavailable(reason) = deleted else {
            return XCTFail("expected unavailable, got \(deleted)")
        }
        XCTAssertEqual(reason, .notFound)

        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("imports/attachments-a/folder"),
            withIntermediateDirectories: true)
        let directory = await rechecker.recheck(
            BotFileResourceIdentity(key: "imports/attachments-a/folder"),
            botID: "bot-a", baseline: baseline)
        guard case let .unavailable(directoryReason) = directory else {
            return XCTFail("expected unavailable for a directory, got \(directory)")
        }
        XCTAssertEqual(directoryReason, .notRegularFile)
    }

    func testOutOfWorkspaceAndWrongKindAreDenied() async throws {
        let rechecker = makeRechecker()
        let baseline = BotFileBaseline.fileBytes("sha256:" + sha256("alpha"))
        let traversal = await rechecker.recheck(
            BotFileResourceIdentity(key: "../outside.txt"),
            botID: "bot-a", baseline: baseline)
        guard case let .denied(reason) = traversal else {
            return XCTFail("expected denied, got \(traversal)")
        }
        XCTAssertEqual(reason, .noResourceIdentity)

        let wrongKind = await rechecker.recheck(
            BotFileResourceIdentity(kind: "web-url", key: "https://example.com/a"),
            botID: "bot-a", baseline: baseline)
        guard case let .denied(kindReason) = wrongKind else {
            return XCTFail("expected denied, got \(wrongKind)")
        }
        XCTAssertEqual(kindReason, .noResourceIdentity)
    }

    func testRecordTextBaselineIsOnlyComparedForFullUTF8Files() async throws {
        try write("hello")
        let rechecker = makeRechecker()
        let textBaseline = BotFileBaseline.recordText("sha256:" + sha256("hello"))
        let same = await rechecker.recheck(resource, botID: "bot-a", baseline: textBaseline)
        guard case .unchanged = same else {
            return XCTFail("a full UTF-8 file can be compared, got \(same)")
        }

        try write("hello2")
        let changedText = await rechecker.recheck(
            resource, botID: "bot-a", baseline: textBaseline)
        guard case let .notPerformed(reason) = changedText else {
            return XCTFail("record-text vs file text must not claim changed, got \(changedText)")
        }
        XCTAssertEqual(reason, .baselineNotComparable)

        let binary = Data([0xFF, 0xFE, 0x00, 0x01])
        try binary.write(to: root.appendingPathComponent(resource.key))
        let binaryResult = await rechecker.recheck(
            resource, botID: "bot-a", baseline: textBaseline)
        guard case let .notPerformed(binaryReason) = binaryResult else {
            return XCTFail("binary file must not be compared to record text, got \(binaryResult)")
        }
        XCTAssertEqual(binaryReason, .baselineNotComparable)
    }

    func testNoBaselineAndNoConfiguredProviderAreNotCurrent() async throws {
        try write("alpha")
        let rechecker = makeRechecker()
        let noBaseline = await rechecker.recheck(resource, botID: "bot-a", baseline: nil)
        guard case let .notPerformed(reason) = noBaseline else {
            return XCTFail("expected notPerformed, got \(noBaseline)")
        }
        XCTAssertEqual(reason, .noBaseline)

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("file-recheck-service-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = try SQLiteDomainStore(
            fileURL: folder.appendingPathComponent("domain.sqlite"), now: { 1_000 })
        let gateway = BotGateway(now: { 1_000 })
        try await gateway.issueSession(botId: "bot-a", sessionId: "gb-main", kind: .chat)
        let withoutProvider = BotRecordService(
            store: store, gateway: gateway, workspaceRoot: folder)
        let absent = await withoutProvider.recheckFile(
            resource, botID: "bot-a", baseline: nil)
        XCTAssertNil(absent, "an unwired App must report refresh-not-performed, not current")
        let withProvider = BotRecordService(
            store: store, gateway: gateway, workspaceRoot: folder,
            fileRechecks: BotFileSourceRechecker(locator: TestLocator(root: root), now: { self.now }))
        let present = await withProvider.recheckFile(
            resource, botID: "bot-a",
            baseline: .fileBytes("sha256:" + sha256("alpha")))
        guard case .unchanged = present else {
            return XCTFail("expected unchanged from the injected producer, got \(String(describing: present))")
        }
        try? await store.close()
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - Helpers

    private struct TestLocator: BotFileURLResolving {
        let root: URL
        func fileURL(for resource: BotFileResourceIdentity, botID: String) -> URL? {
            guard resource.kind == "file", !resource.key.isEmpty,
                  !resource.key.hasPrefix("/"), !resource.key.contains("..") else {
                return nil
            }
            return root.appendingPathComponent(resource.key)
        }
    }

    private func makeRechecker() -> BotFileSourceRechecker {
        BotFileSourceRechecker(locator: TestLocator(root: root), now: { self.now })
    }

    private func write(_ text: String) throws {
        try Data(text.utf8).write(
            to: root.appendingPathComponent(resource.key), options: .atomic)
    }

    private func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
