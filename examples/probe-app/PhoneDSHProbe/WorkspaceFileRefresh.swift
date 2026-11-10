// SPDX-License-Identifier: MIT
// Off-main workspace traversal and its coalescing scheduler.
//
// `refreshFiles()` used to enumerate the whole materialized workspace on the
// main actor, and the caller did it again for every tool result. The scan now
// runs in a detached utility task; this controller serializes scans (at most
// one traversal at a time), debounces tool-result requests, and drops a result
// whose root changed while it was running.

import Foundation

/// Pure workspace traversal, safe to call off the main actor.
///
/// The materialized root is resolved once. Child entries are already returned
/// under that resolved root by `FileManager.enumerator`; a regular file's path
/// is therefore `root.path + "/" + relativePath` without resolving each file
/// again. The previous per-entry `resolvingSymlinksInPath()` was redundant for
/// this traversal: symlinks are not regular files (`isRegularFile == false`)
/// and the enumerator does not descend into them, so they never contribute a
/// resolved target path. Keeping the root resolution preserves the
/// `/var` → `/private/var` and symlinked-root cases, and the prefix guard keeps
/// excluding anything outside the root.
enum WorkspaceFileScanner {
    static func scan(root rootURL: URL) -> [WorkspaceFile] {
        let root = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let rootPrefix = root.path + "/"
        var found: [WorkspaceFile] = []
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return [] }
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            let path = url.path
            // A path outside the materialized root is not a workspace file; an
            // absolute path here would break the list grouping and every
            // preview/share decision downstream.
            guard path.hasPrefix(rootPrefix) else { continue }
            found.append(WorkspaceFile(relativePath: String(path.dropFirst(rootPrefix.count)),
                                       size: values.fileSize ?? 0))
        }
        return found.sorted { $0.relativePath < $1.relativePath }
    }
}

/// Serializes and debounces workspace scans on the main actor.
///
/// Rules:
/// * one traversal at a time; a request while a scan runs records exactly one
///   rerun that starts when the current scan completes;
/// * `requestDebounced` resets a trailing timer, so a burst of tool results
///   produces one scan;
/// * `requestImmediately` (session switch, foreground, resume, turn end)
///   supersedes a pending debounce and starts as soon as the current scan ends;
/// * equal results are not delivered again;
/// * a result whose root no longer matches the latest request is discarded.
private let workspaceFileRefreshDefaultDebounceNanoseconds: UInt64 = 400_000_000

@MainActor
final class WorkspaceFileRefreshController {
    typealias Scanner = @Sendable (URL) async -> [WorkspaceFile]
    typealias Deliver = @MainActor (URL, [WorkspaceFile]) -> Void
    typealias Sleep = @Sendable (UInt64) async -> Void

    private let debounceNanoseconds: UInt64
    private let scanner: Scanner
    private let deliver: Deliver
    private let sleep: Sleep

    private var requestedRoot: URL?
    private var scanTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var scanning = false
    private var rerunRequested = false
    private var scanGeneration = 0
    private var completedScans = 0
    private var lastDeliveredRoot: URL?
    private var lastDeliveredFiles: [WorkspaceFile]?
    private var waiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(debounceNanoseconds: UInt64 = workspaceFileRefreshDefaultDebounceNanoseconds,
         scanner: @escaping Scanner,
         deliver: @escaping Deliver,
         sleep: @escaping Sleep = { nanoseconds in
             try? await Task.sleep(nanoseconds: nanoseconds)
         }) {
        self.debounceNanoseconds = debounceNanoseconds
        self.scanner = scanner
        self.deliver = deliver
        self.sleep = sleep
    }

    /// A request that should start as soon as no scan is running. This cancels
    /// a pending trailing debounce because the immediate request supersedes it.
    func requestImmediately(root: URL) {
        requestedRoot = root
        cancelDebounce()
        guard !scanning else {
            rerunRequested = true
            return
        }
        startScan(root: root)
    }

    /// A tool-result request: one trailing timer for the whole burst.
    func requestDebounced(root: URL) {
        requestedRoot = root
        debounceTask?.cancel()
        let nanoseconds = debounceNanoseconds
        let sleep = self.sleep
        debounceTask = Task { @MainActor [weak self] in
            await sleep(nanoseconds)
            guard !Task.isCancelled, let self else { return }
            self.debounceTask = nil
            guard let root = self.requestedRoot else { return }
            if self.scanning {
                self.rerunRequested = true
            } else {
                self.startScan(root: root)
            }
        }
    }

    /// Immediate refresh whose completion the caller can await: the returned
    /// value is current once a scan started at (or after) this request has run.
    func requestImmediatelyAndWait(root: URL) async {
        let target = completedScans + (scanning ? 2 : 1)
        requestImmediately(root: root)
        guard completedScans < target else { return }
        await withCheckedContinuation { continuation in
            if completedScans >= target {
                continuation.resume()
            } else {
                waiters.append((target: target, continuation: continuation))
            }
        }
    }

    private func cancelDebounce() {
        debounceTask?.cancel()
        debounceTask = nil
    }

    private func startScan(root: URL) {
        cancelDebounce()
        scanning = true
        rerunRequested = false
        scanGeneration &+= 1
        let generation = scanGeneration
        let scanner = self.scanner
        scanTask = Task { @MainActor [weak self] in
            let files = await scanner(root)
            guard !Task.isCancelled, let self else { return }
            self.finishScan(root: root, generation: generation, files: files)
        }
    }

    private func finishScan(root: URL, generation: Int, files: [WorkspaceFile]) {
        guard scanning, generation == scanGeneration else { return }
        scanning = false
        scanTask = nil
        completedScans += 1

        let stale = root != requestedRoot
        if !stale,
           lastDeliveredRoot == root,
           let lastDeliveredFiles,
           lastDeliveredFiles == files {
            // Same sorted list: do not rebuild fileIndex or invalidate views.
        } else if !stale {
            lastDeliveredRoot = root
            lastDeliveredFiles = files
            deliver(root, files)
        }

        resumeWaiters()

        if rerunRequested {
            rerunRequested = false
            if let nextRoot = requestedRoot {
                startScan(root: nextRoot)
            }
        }
    }

    private func resumeWaiters() {
        guard !waiters.isEmpty else { return }
        var remaining: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in waiters {
            if waiter.target <= completedScans {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        waiters = remaining
    }
}
