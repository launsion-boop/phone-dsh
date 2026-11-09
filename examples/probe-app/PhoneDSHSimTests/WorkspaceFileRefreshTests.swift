// SPDX-License-Identifier: MIT

import Foundation
import XCTest

/// S1: the workspace scan must stay off the main actor, keep the old traversal
/// semantics exactly, coalesce concurrent requests and debounce tool results.
@MainActor
final class WorkspaceFileRefreshTests: XCTestCase {
    // MARK: - Scanner semantics

    func testScannerMatchesTheOriginalTraversalOracle() throws {
        let fixture = try makeScanFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }

        let oracle = originalScan(root: fixture.root)
        let scanned = WorkspaceFileScanner.scan(root: fixture.root)
        XCTAssertEqual(scanned, oracle)

        // A root that is itself a symlink is the `/var` vs `/private/var`
        // shape: the scanner must resolve it once and still return the same
        // relative paths as the old per-entry implementation.
        let symlinkedRoot = try XCTUnwrap(fixture.symlinkedRoot)
        XCTAssertEqual(WorkspaceFileScanner.scan(root: symlinkedRoot), oracle)
        XCTAssertEqual(WorkspaceFileScanner.scan(root: symlinkedRoot), scanned)

        XCTAssertEqual(scanned.map(\.relativePath), [
            "a.txt",
            "dir/with space.txt",
            "dir/名字.md",
            "nested/b.txt",
            "nested/deep/c.swift",
        ].sorted())
        XCTAssertEqual(scanned.first(where: { $0.relativePath == "a.txt" })?.size, 3)
        XCTAssertEqual(scanned.first(where: { $0.relativePath == "nested/b.txt" })?.size, 5)
        XCTAssertFalse(scanned.contains { $0.relativePath.hasPrefix("symlink-") },
                       "symlinks themselves are not regular files")
        XCTAssertFalse(scanned.contains { $0.relativePath.hasPrefix("outside") })
        XCTAssertEqual(scanned.filter { $0.relativePath == "nested/deep/c.swift" }.count, 1,
                       "a symlinked directory must not be traversed twice")
    }

    // MARK: - Coalescing

    func testRequestsDuringAScanCoalesceIntoOneRerun() async {
        let gate = ScanGate()
        let delivery = DeliveryRecorder()
        let controller = WorkspaceFileRefreshController(
            debounceNanoseconds: 1_000_000,
            scanner: { root in
                let index = await gate.begin(root: root)
                await gate.waitForRelease()
                return [WorkspaceFile(relativePath: "scan-\(index).txt", size: index)]
            },
            deliver: { root, files in delivery.deliver(root: root, files: files) })
        let root = URL(fileURLWithPath: "/tmp/pdsh-coalesce")

        controller.requestImmediately(root: root)
        let firstStarted = await waitForScanStart(gate, count: 1)
        XCTAssertTrue(firstStarted)
        controller.requestImmediately(root: root)
        controller.requestImmediately(root: root)
        try? await Task.sleep(nanoseconds: 30_000_000)
        let startsWhileRunning = await gate.startCount
        XCTAssertEqual(startsWhileRunning, 1, "only one traversal may run at a time")

        await gate.releaseNext()
        let rerunStarted = await waitForScanStart(gate, count: 2)
        XCTAssertTrue(rerunStarted)
        let startsAfterRerun = await gate.startCount
        XCTAssertEqual(startsAfterRerun, 2,
                       "two requests during the scan collapse into one rerun")
        await gate.releaseNext()
        let delivered = await waitForDeliveryCount(delivery, count: 2)
        XCTAssertTrue(delivered)
        try? await Task.sleep(nanoseconds: 30_000_000)
        let finalStarts = await gate.startCount
        XCTAssertEqual(finalStarts, 2, "the coalesced rerun must not schedule a third scan")
    }

    func testStaleRootResultIsDiscarded() async {
        let gate = ScanGate()
        let delivery = DeliveryRecorder()
        let controller = WorkspaceFileRefreshController(
            debounceNanoseconds: 1_000_000,
            scanner: { root in
                let index = await gate.begin(root: root)
                await gate.waitForRelease()
                return [WorkspaceFile(relativePath: "root-\(index).txt", size: index)]
            },
            deliver: { root, files in delivery.deliver(root: root, files: files) })
        let oldRoot = URL(fileURLWithPath: "/tmp/pdsh-root-old")
        let newRoot = URL(fileURLWithPath: "/tmp/pdsh-root-new")

        controller.requestImmediately(root: oldRoot)
        let oldStarted = await waitForScanStart(gate, count: 1)
        XCTAssertTrue(oldStarted)
        controller.requestImmediately(root: newRoot)
        await gate.releaseNext()
        let newStarted = await waitForScanStart(gate, count: 2)
        XCTAssertTrue(newStarted)
        let scannedRoots = await gate.scannedRoots
        XCTAssertEqual(scannedRoots, [oldRoot, newRoot])

        await gate.releaseNext()
        let delivered = await waitForDeliveryCount(delivery, count: 1)
        XCTAssertTrue(delivered)
        XCTAssertEqual(delivery.deliveries.count, 1)
        XCTAssertEqual(delivery.deliveries.first?.root, newRoot,
                       "the old root's result must never be delivered")
        XCTAssertEqual(delivery.deliveries.first?.files.map(\.relativePath), ["root-2.txt"])
    }

    func testEqualResultIsNotDeliveredAgainAndAwaitReturnsAfterTheScan() async {
        let scanned = ScanCounter()
        let delivery = DeliveryRecorder()
        let file = WorkspaceFile(relativePath: "same.txt", size: 4)
        let controller = WorkspaceFileRefreshController(
            debounceNanoseconds: 1_000_000,
            scanner: { _ in
                await scanned.increment()
                return [file]
            },
            deliver: { root, files in delivery.deliver(root: root, files: files) })
        let root = URL(fileURLWithPath: "/tmp/pdsh-equal")

        await controller.requestImmediatelyAndWait(root: root)
        let firstScanCount = await scanned.count
        XCTAssertEqual(firstScanCount, 1)
        XCTAssertEqual(delivery.deliveries.count, 1)

        // The second scan finishes (so the await must return) but its sorted
        // list is identical, so `files` is not assigned again.
        await controller.requestImmediatelyAndWait(root: root)
        let secondScanCount = await scanned.count
        XCTAssertEqual(secondScanCount, 2)
        XCTAssertEqual(delivery.deliveries.count, 1)
        XCTAssertEqual(delivery.deliveries.first?.files, [file])
    }

    // MARK: - Debounce

    func testToolResultBurstDebouncesToASingleScan() async {
        let sleeper = ManualSleeper()
        let scanned = ScanCounter()
        let delivery = DeliveryRecorder()
        let controller = WorkspaceFileRefreshController(
            debounceNanoseconds: 500_000_000,
            scanner: { _ in
                await scanned.increment()
                return [WorkspaceFile(relativePath: "result.txt", size: 1)]
            },
            deliver: { root, files in delivery.deliver(root: root, files: files) },
            sleep: { nanoseconds in await sleeper.sleep(nanoseconds) })
        let root = URL(fileURLWithPath: "/tmp/pdsh-debounce")

        controller.requestDebounced(root: root)
        let firstRequest = await waitForSleeperRequests(sleeper, count: 1)
        XCTAssertTrue(firstRequest)
        controller.requestDebounced(root: root)
        let secondRequest = await waitForSleeperRequests(sleeper, count: 2)
        XCTAssertTrue(secondRequest)
        let scansBeforeRelease = await scanned.count
        XCTAssertEqual(scansBeforeRelease, 0,
                       "the first trailing timer must be replaced by the second request")

        await sleeper.resumeAll()
        let scannedOnce = await waitForScanCount(scanned, count: 1)
        XCTAssertTrue(scannedOnce)
        try? await Task.sleep(nanoseconds: 30_000_000)
        let scansAfterRelease = await scanned.count
        XCTAssertEqual(scansAfterRelease, 1, "a tool-result burst scans exactly once")
        XCTAssertEqual(delivery.deliveries.count, 1)
    }

    func testImmediateRequestSupersedesADebouncedOne() async {
        let sleeper = ManualSleeper()
        let scanned = ScanCounter()
        let controller = WorkspaceFileRefreshController(
            debounceNanoseconds: 500_000_000,
            scanner: { _ in
                await scanned.increment()
                return []
            },
            deliver: { _, _ in },
            sleep: { nanoseconds in await sleeper.sleep(nanoseconds) })
        let root = URL(fileURLWithPath: "/tmp/pdsh-immediate")

        controller.requestDebounced(root: root)
        let debounceRequested = await waitForSleeperRequests(sleeper, count: 1)
        XCTAssertTrue(debounceRequested)
        controller.requestImmediately(root: root)
        let scannedImmediately = await waitForScanCount(scanned, count: 1)
        XCTAssertTrue(scannedImmediately)

        // Resume the (cancelled) sleeper so its Task can unwind cleanly; it
        // must not start a second scan.
        await sleeper.resumeAll()
        try? await Task.sleep(nanoseconds: 30_000_000)
        let finalScanCount = await scanned.count
        XCTAssertEqual(finalScanCount, 1)
    }

    // MARK: - Fixtures and helpers

    private struct ScanFixture {
        let base: URL
        let root: URL
        let symlinkedRoot: URL?
    }

    private func makeScanFixture() throws -> ScanFixture {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("pdsh-workspace-scan-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("workspace", isDirectory: true)
        try fileManager.createDirectory(at: root.appendingPathComponent("dir"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: root.appendingPathComponent("nested/deep"), withIntermediateDirectories: true)

        try Data("abc".utf8).write(to: root.appendingPathComponent("a.txt"))
        try Data("hello".utf8).write(to: root.appendingPathComponent("nested/b.txt"))
        try Data("swift".utf8).write(to: root.appendingPathComponent("nested/deep/c.swift"))
        try Data("space".utf8).write(to: root.appendingPathComponent("dir/with space.txt"))
        try Data("名字".utf8).write(to: root.appendingPathComponent("dir/名字.md"))

        // Inside, outside, dangling, directory and root symlinks: the original
        // traversal skipped all of them because none is a regular file.
        try fileManager.createSymbolicLink(
            at: root.appendingPathComponent("symlink-inside.txt"),
            withDestinationURL: root.appendingPathComponent("a.txt"))
        try Data("outside".utf8).write(to: base.appendingPathComponent("outside.txt"))
        try fileManager.createSymbolicLink(
            at: root.appendingPathComponent("symlink-outside.txt"),
            withDestinationURL: base.appendingPathComponent("outside.txt"))
        try fileManager.createSymbolicLink(
            at: root.appendingPathComponent("symlink-directory"),
            withDestinationURL: root.appendingPathComponent("nested"))
        try fileManager.createSymbolicLink(
            at: root.appendingPathComponent("symlink-dangling"),
            withDestinationURL: base.appendingPathComponent("missing.txt"))

        let symlinkedRoot = base.appendingPathComponent("workspace-link")
        try fileManager.createSymbolicLink(at: symlinkedRoot, withDestinationURL: root)
        return ScanFixture(base: base, root: root, symlinkedRoot: symlinkedRoot)
    }

    /// The pre-S1 `ChatModel.refreshFiles()` traversal, kept as the oracle.
    private func originalScan(root rootURL: URL) -> [WorkspaceFile] {
        let fileManager = FileManager.default
        let root = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let rootPrefix = root.path + "/"
        var found: [WorkspaceFile] = []
        if let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) {
            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                      values.isRegularFile == true else { continue }
                let path = url.standardizedFileURL.resolvingSymlinksInPath().path
                guard path.hasPrefix(rootPrefix) else { continue }
                found.append(WorkspaceFile(relativePath: String(path.dropFirst(rootPrefix.count)),
                                           size: values.fileSize ?? 0))
            }
        }
        return found.sorted { $0.relativePath < $1.relativePath }
    }

    private func waitForScanStart(_ gate: ScanGate, count: Int,
                                  timeout: TimeInterval = 3) async -> Bool {
        await waitUntil(timeout: timeout) { await gate.startCount >= count }
    }

    private func waitForDeliveryCount(_ delivery: DeliveryRecorder, count: Int,
                                      timeout: TimeInterval = 3) async -> Bool {
        await waitUntil(timeout: timeout) { delivery.deliveries.count >= count }
    }

    private func waitForScanCount(_ scan: ScanCounter, count: Int,
                                  timeout: TimeInterval = 3) async -> Bool {
        await waitUntil(timeout: timeout) { await scan.count >= count }
    }

    private func waitForSleeperRequests(_ sleeper: ManualSleeper, count: Int,
                                        timeout: TimeInterval = 3) async -> Bool {
        await waitUntil(timeout: timeout) { await sleeper.requestCount >= count }
    }

    private func waitUntil(timeout: TimeInterval,
                           _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await condition()
    }
}

// MARK: - Test doubles

@MainActor
private final class DeliveryRecorder {
    struct Delivery {
        let root: URL
        let files: [WorkspaceFile]
    }

    private(set) var deliveries: [Delivery] = []

    func deliver(root: URL, files: [WorkspaceFile]) {
        deliveries.append(Delivery(root: root, files: files))
    }
}

private actor ScanGate {
    private(set) var startCount = 0
    private(set) var scannedRoots: [URL] = []
    private var releases: [CheckedContinuation<Void, Never>] = []

    func begin(root: URL) -> Int {
        startCount += 1
        scannedRoots.append(root)
        return startCount
    }

    func waitForRelease() async {
        await withCheckedContinuation { releases.append($0) }
    }

    func releaseNext() {
        guard !releases.isEmpty else { return }
        releases.removeFirst().resume()
    }
}

private actor ScanCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}

/// A controllable replacement for `Task.sleep`; resuming it lets a debounce
/// timer fire without wall-clock sleeps in the test.
private actor ManualSleeper {
    private(set) var requestCount = 0
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    func sleep(_ nanoseconds: UInt64) async {
        let id = UUID()
        requestCount += 1
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func resumeAll() {
        let pending = Array(waiters.values)
        waiters.removeAll()
        for continuation in pending { continuation.resume() }
    }

    private func cancel(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume()
    }
}
