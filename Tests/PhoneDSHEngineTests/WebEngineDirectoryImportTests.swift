// SPDX-License-Identifier: MIT
// Native staging tests for the iPhone Files directory import.
//
// These are real temporary-directory tests: bytes are copied and compared,
// empty directories are inspected, symbolic links and path escapes are
// refused, cancellation cleans the Caches staging child, and the source tree
// is snapshotted before/after to prove it was only read.

import Foundation
import WebKit
import XCTest
@testable import PhoneDSHEngine

/// Test picker that returns one already-created source directory immediately.
@MainActor
private final class ImmediateDirectoryImportPresenter: WebEngineDirectoryImportPresenting {
    private let url: URL

    init(url: URL) {
        self.url = url
    }

    func present(completion: @escaping (Result<URL, WebEngineDirectoryImportError>) -> Void) {
        completion(.success(url))
    }
}

/// Sink whose first write or commit parks until the test releases it, so a
/// cancel can be scheduled at a precise point in the real import task.
private actor GatedImportSink: WebEngineDirectoryImportSink {
    enum Gate: Sendable {
        case firstWrite
        case commit
    }

    struct Snapshot: Sendable {
        let beginCalls: Int
        let writeCalls: Int
        let commitCalls: Int
        let abortCalls: Int
        let gateSawCancellation: Bool
    }

    private let gate: Gate
    private var beginCalls = 0
    private var writeCalls = 0
    private var commitCalls = 0
    private var abortCalls = 0
    private var gateStarted = false
    private var gateReleased = false
    private var gateFinished = false
    private var gateSawCancellation = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var finishWaiter: CheckedContinuation<Void, Never>?

    init(gate: Gate) {
        self.gate = gate
    }

    func begin(_ manifest: WebEngineDirectoryImportManifest) async throws -> String {
        beginCalls += 1
        return "worker-import"
    }

    func write(importID: String, path: String, offset: Int, data: Data) async throws {
        writeCalls += 1
        if gate == .firstWrite && writeCalls == 1 {
            await waitAtGate()
            // A cancellation-aware transport would stop here. The native task
            // must already have been cancelled before the release for this to
            // throw; otherwise the write succeeds and the import continues.
            if Task.isCancelled { throw CancellationError() }
        }
    }

    func commit(importID: String) async throws -> WebEngineDirectoryImportResult {
        commitCalls += 1
        if gate == .commit {
            await waitAtGate()
        }
        return WebEngineDirectoryImportResult(
            workspacePath: "imports/source",
            absolutePath: "/workspace/imports/source",
            fileCount: 1,
            totalBytes: 7)
    }

    func abort(importID: String) async {
        abortCalls += 1
    }

    func waitForGateStart() async {
        if gateStarted { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func waitForGateFinish() async {
        if gateFinished { return }
        await withCheckedContinuation { finishWaiter = $0 }
    }

    func releaseGate() {
        gateReleased = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }

    func snapshot() -> Snapshot {
        Snapshot(beginCalls: beginCalls,
                 writeCalls: writeCalls,
                 commitCalls: commitCalls,
                 abortCalls: abortCalls,
                 gateSawCancellation: gateSawCancellation)
    }

    private func waitAtGate() async {
        gateStarted = true
        startWaiter?.resume()
        startWaiter = nil
        await withCheckedContinuation { continuation in
            if gateReleased {
                continuation.resume()
            } else {
                releaseWaiter = continuation
            }
        }
        gateSawCancellation = Task.isCancelled
        gateFinished = true
        finishWaiter?.resume()
        finishWaiter = nil
    }
}

/// Sink that fails the commit after `beginCommit()` won, recording whether the
/// native side still tried to abort a commit the Worker owns.
private actor FailingCommitSink: WebEngineDirectoryImportSink {
    struct Snapshot: Sendable {
        let beginCalls: Int
        let writeCalls: Int
        let commitCalls: Int
        let abortCalls: Int
    }

    private var beginCalls = 0
    private var writeCalls = 0
    private var commitCalls = 0
    private var abortCalls = 0
    private var commitFinished = false
    private var finishWaiter: CheckedContinuation<Void, Never>?

    func begin(_ manifest: WebEngineDirectoryImportManifest) async throws -> String {
        beginCalls += 1
        return "worker-import"
    }

    func write(importID: String, path: String, offset: Int, data: Data) async throws {
        writeCalls += 1
    }

    func commit(importID: String) async throws -> WebEngineDirectoryImportResult {
        commitCalls += 1
        commitFinished = true
        finishWaiter?.resume()
        finishWaiter = nil
        throw WebEngineDirectoryImportError.sinkFailed("worker commit failed")
    }

    func abort(importID: String) async {
        abortCalls += 1
    }

    func waitForCommitFinish() async {
        if commitFinished { return }
        await withCheckedContinuation { finishWaiter = $0 }
    }

    func snapshot() -> Snapshot {
        Snapshot(beginCalls: beginCalls, writeCalls: writeCalls,
                 commitCalls: commitCalls, abortCalls: abortCalls)
    }
}

final class WebEngineDirectoryImportTests: XCTestCase {
    private var temporaryRoots: [URL] = []

    override func tearDownWithError() throws {
        for root in temporaryRoots {
            try? FileManager.default.removeItem(at: root)
        }
        temporaryRoots.removeAll()
        try super.tearDownWithError()
    }

    private func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-directory-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        temporaryRoots.append(root)
        return root
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func makeDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func snapshot(_ root: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [])
        while let url = enumerator?.nextObject() as? URL {
            let relative = url.path.replacingOccurrences(of: root.path.hasSuffix("/") ? root.path : root.path + "/",
                                                         with: "")
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            result[relative] = values.isDirectory == true ? Data() : try Data(contentsOf: url)
        }
        return result
    }

    private func bytePattern(count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    }

    private func assertImportError(_ expected: WebEngineDirectoryImportError,
                                   file: StaticString = #filePath,
                                   line: UInt = #line,
                                   _ body: () throws -> Void) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual(error as? WebEngineDirectoryImportError, expected, file: file, line: line)
        }
    }

    /// Polls the real Caches staging root so the test observes the importer
    /// finishing instead of guessing with a fixed sleep.
    private func waitForStagingEmpty(_ stagingRoot: URL,
                                     timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let entries = try? FileManager.default.contentsOfDirectory(atPath: stagingRoot.path)
            if entries?.isEmpty == true { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Caches staging was not cleaned within \(timeout)s")
    }

    func testDefaultLimitsMatchTheWorkerContract() {
        let limits = WebEngineDirectoryImportLimits.default
        XCTAssertEqual(limits.maxFiles, 500)
        XCTAssertEqual(limits.maxDirectories, 2_000)
        XCTAssertEqual(limits.maxTotalBytes, 128 * 1024 * 1024)
        XCTAssertEqual(limits.maxFileBytes, 64 * 1024 * 1024)
        XCTAssertEqual(limits.chunkBytes, 1024 * 1024)
        XCTAssertEqual(limits.maxPathBytes, 1024)
        XCTAssertEqual(limits.maxEntryNameLength, 128)
    }

    func testStageCopiesBytesAndPreservesEmptyDirectoriesAndHiddenFiles() throws {
        let root = try makeTemporaryRoot()
        let source = root.appendingPathComponent("Selected Folder", isDirectory: true)
        try makeDirectory(source.appendingPathComponent("nested/deeper", isDirectory: true))
        try makeDirectory(source.appendingPathComponent("empty/deep", isDirectory: true))
        let binary = bytePattern(count: 2_500_000)
        try write(binary, to: source.appendingPathComponent("nested/alpha.bin"))
        try write(Data("hidden".utf8), to: source.appendingPathComponent(".hidden"))
        let before = try snapshot(source)
        let stagingRoot = root.appendingPathComponent("Caches/PhoneDSHImport", isDirectory: true)

        let staged = try WebEngineDirectoryImporter.stageDirectory(source: source, stagingRoot: stagingRoot)

        XCTAssertEqual(staged.entryName, "Selected Folder")
        XCTAssertEqual(staged.totalBytes, binary.count + 6)
        XCTAssertEqual(Set(staged.directories), Set(["nested", "nested/deeper", "empty", "empty/deep"]))
        XCTAssertEqual(Set(staged.files.map(\.path)), Set(["nested/alpha.bin", ".hidden"]))
        XCTAssertEqual(try Data(contentsOf: staged.root.appendingPathComponent("nested/alpha.bin")), binary)
        XCTAssertEqual(try Data(contentsOf: staged.root.appendingPathComponent(".hidden")), Data("hidden".utf8))
        XCTAssertTrue(isDirectory(staged.root.appendingPathComponent("empty/deep")))
        let stagingSnapshot = try snapshot(stagingRoot)
        XCTAssertTrue(stagingSnapshot.keys.contains { $0.contains(staged.root.lastPathComponent) })

        // The chunked copy itself: every read is <= 1 MiB and the destination
        // concatenates to the exact source bytes.
        let copy = root.appendingPathComponent("copy.bin")
        var reads: [Int] = []
        let copied = try WebEngineDirectoryImporter.copyFile(
            from: source.appendingPathComponent("nested/alpha.bin"),
            to: copy,
            limits: .default,
            isCancelled: { false },
            didRead: { reads.append($0) })
        XCTAssertEqual(copied, binary.count)
        XCTAssertFalse(reads.isEmpty)
        XCTAssertTrue(reads.allSatisfy { $0 <= 1024 * 1024 })
        XCTAssertEqual(reads.reduce(0, +), binary.count)
        XCTAssertEqual(try Data(contentsOf: copy), binary)

        // Removing the staged copy never touches the source.
        staged.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.root.path))
        XCTAssertEqual(try snapshot(source), before)
    }

    func testStageRefusesSymbolicLinksAndLeavesTheSourceUnchanged() throws {
        let root = try makeTemporaryRoot()
        let source = root.appendingPathComponent("source", isDirectory: true)
        try makeDirectory(source)
        try write(Data("target".utf8), to: source.appendingPathComponent("target.txt"))
        try FileManager.default.createSymbolicLink(
            atPath: source.appendingPathComponent("link.txt").path,
            withDestinationPath: "target.txt")
        let before = try snapshot(source)

        assertImportError(.symlink("link.txt")) {
            _ = try WebEngineDirectoryImporter.stageDirectory(
                source: source,
                stagingRoot: root.appendingPathComponent("Caches", isDirectory: true))
        }
        XCTAssertEqual(try snapshot(source), before)
        let stagingRoot = root.appendingPathComponent("Caches", isDirectory: true)
        XCTAssertTrue((try? FileManager.default.contentsOfDirectory(atPath: stagingRoot.path))?.isEmpty ?? true)
    }

    func testUnsafePathsAreRefusedBeforeCopying() {
        let limits = WebEngineDirectoryImportLimits.default
        for path in ["../escape", "/absolute", "a/../b", "a//b", "./a", "a\u{0}b"] {
            XCTAssertThrowsError(try WebEngineDirectoryImportPath.validateRelative(path, limits: limits), path) { error in
                guard let typed = error as? WebEngineDirectoryImportError,
                      case .unsafePath = typed else {
                    XCTFail("expected unsafePath for \(path), got \(error)")
                    return
                }
            }
        }
        XCTAssertThrowsError(try WebEngineDirectoryImportPath.validateEntryName("..", limits: limits))
        XCTAssertThrowsError(try WebEngineDirectoryImportPath.validateEntryName("", limits: limits))
        let longName = String(repeating: "x", count: limits.maxEntryNameLength + 1)
        XCTAssertThrowsError(try WebEngineDirectoryImportPath.validateEntryName(longName, limits: limits)) { error in
            guard let typed = error as? WebEngineDirectoryImportError, case .limit = typed else {
                XCTFail("expected limit, got \(error)")
                return
            }
        }
    }

    func testStageEnforcesFileTotalCountAndDirectoryLimits() throws {
        let root = try makeTemporaryRoot()
        let source = root.appendingPathComponent("source", isDirectory: true)
        try makeDirectory(source)
        try write(Data(repeating: 1, count: 9), to: source.appendingPathComponent("too-large.bin"))
        assertImportError(.limit("too-large.bin exceeds 8 bytes")) {
            _ = try WebEngineDirectoryImporter.stageDirectory(
                source: source,
                stagingRoot: root.appendingPathComponent("Caches", isDirectory: true),
                limits: WebEngineDirectoryImportLimits(maxFileBytes: 8))
        }

        try write(Data(repeating: 1, count: 5), to: source.appendingPathComponent("one.bin"))
        try write(Data(repeating: 1, count: 5), to: source.appendingPathComponent("two.bin"))
        assertImportError(.limit("the folder exceeds 8 bytes")) {
            _ = try WebEngineDirectoryImporter.stageDirectory(
                source: source,
                stagingRoot: root.appendingPathComponent("Caches", isDirectory: true),
                limits: WebEngineDirectoryImportLimits(maxTotalBytes: 8))
        }
        assertImportError(.limit("more than 1 files")) {
            _ = try WebEngineDirectoryImporter.stageDirectory(
                source: source,
                stagingRoot: root.appendingPathComponent("Caches", isDirectory: true),
                limits: WebEngineDirectoryImportLimits(maxFiles: 1))
        }

        try makeDirectory(source.appendingPathComponent("a", isDirectory: true))
        try makeDirectory(source.appendingPathComponent("b", isDirectory: true))
        assertImportError(.limit("more than 1 directories")) {
            _ = try WebEngineDirectoryImporter.stageDirectory(
                source: source,
                stagingRoot: root.appendingPathComponent("Caches", isDirectory: true),
                limits: WebEngineDirectoryImportLimits(maxDirectories: 1))
        }
    }

    func testCancellationCleansTheStagingChild() throws {
        let root = try makeTemporaryRoot()
        let source = root.appendingPathComponent("source", isDirectory: true)
        try makeDirectory(source)
        try write(Data("a".utf8), to: source.appendingPathComponent("a.txt"))
        let stagingRoot = root.appendingPathComponent("Caches", isDirectory: true)

        assertImportError(.cancelled) {
            _ = try WebEngineDirectoryImporter.stageDirectory(
                source: source,
                stagingRoot: stagingRoot,
                isCancelled: { true })
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingRoot.appendingPathComponent("source").path))
        XCTAssertTrue((try? FileManager.default.contentsOfDirectory(atPath: stagingRoot.path))?.isEmpty ?? true)
    }

    func testAFileURLThatIsNotAFolderIsRefused() throws {
        let root = try makeTemporaryRoot()
        let file = root.appendingPathComponent("not-a-folder.txt")
        try write(Data("x".utf8), to: file)
        assertImportError(.notAFolder) {
            _ = try WebEngineDirectoryImporter.stageDirectory(
                source: file,
                stagingRoot: root.appendingPathComponent("Caches", isDirectory: true))
        }
    }

    @MainActor
    func testCancelBeforeCommitAbortsAndNeverCallsCommit() async throws {
        let root = try makeTemporaryRoot()
        let source = root.appendingPathComponent("source", isDirectory: true)
        try makeDirectory(source)
        try write(Data("payload".utf8), to: source.appendingPathComponent("a.txt"))
        let stagingRoot = root.appendingPathComponent("Caches", isDirectory: true)
        let webView = WKWebView(frame: .zero)
        let sink = GatedImportSink(gate: .firstWrite)
        let importer = WebEngineDirectoryImport(
            webView: webView,
            sink: sink,
            fileManager: .default,
            stagingRoot: stagingRoot,
            presenter: ImmediateDirectoryImportPresenter(url: source))
        let id = "cancel-before-commit"

        importer.start(id: id, sessionID: "session-1", targetDirectory: "/workspace")
        await sink.waitForGateStart()
        importer.cancel(id: id)
        await sink.releaseGate()
        await sink.waitForGateFinish()
        await waitForStagingEmpty(stagingRoot)

        let snapshot = await sink.snapshot()
        XCTAssertTrue(snapshot.gateSawCancellation,
                      "a cancel before commit must reach the write task")
        XCTAssertEqual(snapshot.beginCalls, 1)
        XCTAssertEqual(snapshot.commitCalls, 0,
                       "a cancelled upload must never enter the atomic commit")
        XCTAssertEqual(snapshot.abortCalls, 1,
                       "cancelled staging must be aborted instead of published")
    }

    @MainActor
    func testCancelAfterAtomicCommitStartsIsIgnored() async throws {
        let root = try makeTemporaryRoot()
        let source = root.appendingPathComponent("source", isDirectory: true)
        try makeDirectory(source)
        try write(Data("payload".utf8), to: source.appendingPathComponent("a.txt"))
        let stagingRoot = root.appendingPathComponent("Caches", isDirectory: true)
        let webView = WKWebView(frame: .zero)
        let sink = GatedImportSink(gate: .commit)
        let importer = WebEngineDirectoryImport(
            webView: webView,
            sink: sink,
            fileManager: .default,
            stagingRoot: stagingRoot,
            presenter: ImmediateDirectoryImportPresenter(url: source))
        let id = "cancel-after-commit"

        importer.start(id: id, sessionID: "session-1", targetDirectory: "/workspace")
        await sink.waitForGateStart()
        importer.cancel(id: id)
        await sink.releaseGate()
        await sink.waitForGateFinish()

        let duringCommit = await sink.snapshot()
        XCTAssertFalse(duringCommit.gateSawCancellation,
                       "the commit task must not be cancelled after the point of no return")
        await waitForStagingEmpty(stagingRoot)

        let afterCommit = await sink.snapshot()
        XCTAssertEqual(afterCommit.beginCalls, 1)
        XCTAssertEqual(afterCommit.commitCalls, 1)
        XCTAssertEqual(afterCommit.abortCalls, 0,
                       "a successful atomic commit must not be aborted by a late cancel")
    }

    @MainActor
    func testFailedCommitAfterPointOfNoReturnIsNotAborted() async throws {
        let root = try makeTemporaryRoot()
        let source = root.appendingPathComponent("source", isDirectory: true)
        try makeDirectory(source)
        try write(Data("payload".utf8), to: source.appendingPathComponent("a.txt"))
        let stagingRoot = root.appendingPathComponent("Caches", isDirectory: true)
        let webView = WKWebView(frame: .zero)
        let sink = FailingCommitSink()
        let importer = WebEngineDirectoryImport(
            webView: webView,
            sink: sink,
            fileManager: .default,
            stagingRoot: stagingRoot,
            presenter: ImmediateDirectoryImportPresenter(url: source))
        let id = "failed-commit"

        importer.start(id: id, sessionID: "session-1", targetDirectory: "/workspace")
        await sink.waitForCommitFinish()
        await waitForStagingEmpty(stagingRoot)

        let snapshot = await sink.snapshot()
        XCTAssertEqual(snapshot.beginCalls, 1)
        XCTAssertEqual(snapshot.commitCalls, 1)
        XCTAssertEqual(snapshot.abortCalls, 0,
                       "after the point of no return the Worker commit owns rollback; native abort must not race it")
    }
}
