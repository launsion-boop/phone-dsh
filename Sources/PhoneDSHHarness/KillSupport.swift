// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — W3-KILL support: fixtures, the seeded kill plan,
// WAL replay comparison and the forked child helper used for the Log kills.
//
// The matrix is {worker terminate, WebContent restart, host child SIGKILL} x
// {after write, during exec, during checkpoint, during epoch close}. The first
// two kill kinds drive the real PhoneDSHHost facade with a deterministic
// MockEngine + MockWorker; the third forks a child that writes through the
// fork-safe WALSynchronousAppender and is SIGKILLed by the parent.

import Foundation
import PhoneDSHController
import PhoneDSH
import PhoneDSHEngine
import PhoneDSHAgentCore
import PhoneDSHLog
import PhoneDSHWire

// MARK: - Seeded plan

public struct KillSeededRandom: RandomNumberGenerator {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    public mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}

public enum KillKind: String, CaseIterable, Sendable {
    case workerTerminate = "worker-terminate"
    case webContentRestart = "webcontent-restart"
    case hostSIGKILL = "host-child-sigkill"
}

public enum KillTiming: String, CaseIterable, Sendable {
    case afterWrite = "after-write"
    case duringExec = "during-exec"
    case duringCheckpoint = "during-checkpoint"
    case duringEpochClose = "during-epoch-close"
}

public struct KillIteration: Sendable {
    public var kind: KillKind
    public var timing: KillTiming

    public init(kind: KillKind, timing: KillTiming) {
        self.kind = kind
        self.timing = timing
    }
}

/// 20 iterations covering all 12 matrix cells at least once, then random
/// repeats, shuffled with a fixed seed so a failure is reproducible.
public func makeKillPlan(count: Int = 20, seed: UInt64 = 0x5EED_1234_ABCD_0001) -> [KillIteration] {
    var random = KillSeededRandom(seed: seed)
    var all: [KillIteration] = []
    for kind in KillKind.allCases {
        for timing in KillTiming.allCases {
            all.append(KillIteration(kind: kind, timing: timing))
        }
    }
    var plan = Array(all.shuffled(using: &random).prefix(all.count))
    while plan.count < count {
        plan.append(all.randomElement(using: &random)!)
    }
    plan = Array(plan.prefix(count))
    plan.shuffle(using: &random)
    return plan
}

// MARK: - Facade fixture

public struct KillFixture {
    public let root: URL
    public let workspace: URL
    public let bundle: PhoneDSHBundleLocation

    public init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-kill-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let staticDirectory = root.appendingPathComponent("www", isDirectory: true)
        let lazy = staticDirectory.appendingPathComponent("lazy", isDirectory: true)
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: staticDirectory,
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: lazy, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace,
                                                withIntermediateDirectories: true)
        let image = staticDirectory.appendingPathComponent("image.tar.gz")
        try Data("image".utf8).write(to: image)
        try Data("<html>kill</html>".utf8)
            .write(to: staticDirectory.appendingPathComponent("index.html"))
        try Data("// worker entry".utf8)
            .write(to: staticDirectory.appendingPathComponent("worker-entry.js"))
        try Data("// boot".utf8)
            .write(to: staticDirectory.appendingPathComponent("boot.js"))
        bundle = PhoneDSHBundleLocation(staticDirectory: staticDirectory,
                                        imageArchive: image,
                                        lazyDirectory: lazy)
    }

    public func configuration(execProvider: (any ExecProvider)? = nil) throws -> PhoneDSHConfiguration {
        guard let origin = URL(string: "http://127.0.0.1:1") else {
            throw KillError.invalidState("placeholder origin is not a URL")
        }
        return PhoneDSHConfiguration(workspaceRoot: workspace,
                                     token: "kill-token",
                                     origin: origin,
                                     bundle: bundle,
                                     execProvider: execProvider,
                                     acceleratorNames: execProvider == nil ? [] : ["test"],
                                     drainDeadline: 5,
                                     helloTimeout: 20)
    }

    public func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

public enum KillError: Error, CustomStringConvertible {
    case timeout(String)
    case invalidState(String)
    case worker(String)
    case replay(String)

    public var description: String {
        switch self {
        case .timeout(let detail): return "kill-matrix timeout: \(detail)"
        case .invalidState(let detail): return "kill-matrix state: \(detail)"
        case .worker(let detail): return "kill-matrix worker: \(detail)"
        case .replay(let detail): return "kill-matrix replay: \(detail)"
        }
    }
}

// MARK: - Polling

/// Polls `condition` until true or `timeout` elapses.
///
/// The wait goes through the shared harness wait: on macOS that dispatches
/// AppKit events through the engine pump; on iOS it sleeps (the simulator app's
/// run loop already services UIKit). The kill matrix itself drives a mock
/// engine, but it runs in the same XCTest process as the WKWebView harnesses;
/// keeping one wait mechanism here means a future real-WebView iteration, and
/// every harness in this target, cannot silently fall back to a run-loop-only
/// wait that leaves a hosted page hidden (and throttled). See
/// `docs/architecture.md`, page visibility.
public func killWait(timeout: TimeInterval = 10,
              _ condition: @escaping @Sendable () async throws -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while true {
        if try await condition() { return }
        if Date() >= deadline { throw KillError.timeout("condition") }
        try await harnessWait(0.002)
    }
}

// MARK: - WAL replay tree

/// The logical state reconstructed from WAL mutation records (D8/D9).
public struct KillReplayTree {
    public private(set) var files: [String: Data] = [:]
    public private(set) var directories: Set<String> = []

    public init() {}

    /// Applies every non-epoch-close record in mseq order.
    public static func replay(_ records: [WALRecord]) throws -> KillReplayTree {
        var tree = KillReplayTree()
        for record in records.sorted(by: { $0.mseq < $1.mseq }) {
            if record.isEpochClose { continue }
            let mutation = try record.mutationBody()
            try tree.apply(mutation)
        }
        return tree
    }

    public mutating func apply(_ mutation: VfsMutationBody) throws {
        let relative = try Self.relativePath(mutation.path)
        switch mutation.op {
        case .write:
            if mutation.mflags.contains(.appended) {
                var existing = files[relative] ?? Data()
                let start = Int(mutation.appendFrom)
                guard start <= existing.count else {
                    throw KillError.replay(
                        "append base \(start) is beyond \(relative) size \(existing.count)")
                }
                if start < existing.count {
                    existing = Data(existing.prefix(start))
                }
                existing.append(mutation.data)
                files[relative] = existing
            } else {
                files[relative] = mutation.data
            }
            addParents(of: relative)
        case .mkdir:
            directories.insert(relative)
            addParents(of: relative)
        case .remove:
            files.removeValue(forKey: relative)
            directories.remove(relative)
            let prefix = relative + "/"
            files = files.filter { !$0.key.hasPrefix(prefix) }
            directories = directories.filter { !$0.hasPrefix(prefix) && $0 != relative }
        case .chmod:
            break
        }
    }

    private mutating func addParents(of relative: String) {
        // The `home` and `workspace` mount points themselves are not part of
        // the compared tree; only their descendants are.
        var components = relative.split(separator: "/").dropLast().map(String.init)
        while components.count > 1 {
            directories.insert(components.joined(separator: "/"))
            components.removeLast()
        }
    }

    public static func relativePath(_ path: String) throws -> String {
        guard path.hasPrefix("/dsh/") else {
            throw KillError.replay("unexpected mutation path \(path)")
        }
        let relative = String(path.dropFirst("/dsh/".count))
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count >= 2,
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              relative.hasPrefix("home/") || relative.hasPrefix("workspace/") else {
            throw KillError.replay("unexpected mutation path \(path)")
        }
        return relative
    }
}

/// Walks `materialized/` and returns files plus directories rooted at
/// `home/` and `workspace/`. The two mount directories themselves are ignored.
public func scanMaterialized(_ workspace: URL) throws -> (files: [String: Data], directories: Set<String>) {
    let root = workspace.appendingPathComponent("materialized", isDirectory: true)
        .resolvingSymlinksInPath().standardizedFileURL
    guard FileManager.default.fileExists(atPath: root.path) else {
        return ([:], [])
    }
    var files: [String: Data] = [:]
    var directories: Set<String> = []
    let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]
    guard let enumerator = FileManager.default.enumerator(at: root,
                                                          includingPropertiesForKeys: keys,
                                                          options: [],
                                                          errorHandler: { _, _ in false }) else {
        return ([:], [])
    }
    let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
    for case let url as URL in enumerator {
        let values = try url.resourceValues(forKeys: Set(keys))
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasPrefix(rootPath) else { continue }
        let relative = String(resolved.path.dropFirst(rootPath.count))
        guard relative.hasPrefix("home/") || relative.hasPrefix("workspace/") else {
            continue
        }
        if values.isDirectory == true {
            directories.insert(relative)
        } else if values.isRegularFile == true {
            files[relative] = try Data(contentsOf: resolved)
        }
    }
    return (files, directories)
}

// MARK: - Kill acceptance verification

/// Verifies the acked prefix, the WAL/materialized equality and the step
/// reconcile set (the landed W3-KILL acceptance). Shared by the macOS matrix
/// (`Phase0KillMatrixTests`) and the iOS Simulator matrix (`SimKillTests`), so
/// the kill evidence readers have one implementation in both targets.
///
/// `worker` supplies the mutation bodies this process sent; for the forked
/// child the WAL itself is the only sender record.
public func verifyKillWorkspace(_ workspace: URL,
                         worker: KillWorker?,
                         ackedUpto: UInt64,
                         expectedInterrupted: [String],
                         expectedAbandoned: [String] = []) async throws
    -> [String: Any] {
    let paths = WorkspacePaths(root: workspace)
    let records = try WALReader.records(directory: paths.walDirectory, fromMseq: 1)
    var walMutations: [UInt64: VfsMutationBody] = [:]
    for record in records where !record.isEpochClose {
        walMutations[record.mseq] = try record.mutationBody()
    }

    // 1. Every level-1-acked mseq is present (and matches the sent body when
    //    this process is the sender).
    guard ackedUpto >= 1 else {
        throw KillError.replay("no level-1 ack was observed")
    }
    for mseq in 1...ackedUpto {
        guard let present = walMutations[mseq] else {
            throw KillError.replay("acked mseq \(mseq) is missing from the WAL")
        }
        if let sent = await worker?.sentMutation(mseq),
           try sent.encoded() != present.encoded() {
            throw KillError.replay("acked mseq \(mseq) differs from the sent mutation")
        }
    }

    // 2. WAL replay equals the materialized copy, exactly: this catches
    //    rm/rename inconsistencies and ghost writes.
    let replay = try KillReplayTree.replay(records)
    let materialized = try scanMaterialized(workspace)
    guard replay.files == materialized.files else {
        let missing = Set(replay.files.keys).subtracting(materialized.files.keys)
        let extra = Set(materialized.files.keys).subtracting(replay.files.keys)
        throw KillError.replay(
            "materialized files differ (missing \(missing.sorted()), "
            + "ghosts \(extra.sorted()))")
    }
    guard replay.directories == materialized.directories else {
        let missing = replay.directories.subtracting(materialized.directories)
        let extra = materialized.directories.subtracting(replay.directories)
        throw KillError.replay(
            "materialized directories differ (missing \(missing.sorted()), "
            + "ghosts \(extra.sorted()))")
    }

    // 3. Step reconcile lists exactly the interrupted steps, and the terminal
    //    owner record lists exactly the steps the host had to abandon.
    let stepMachine = try StepMachine(root: workspace)
    let stepRecords = await stepMachine.allRecords()
    let interrupted = Set(stepRecords.filter { !$0.state.isTerminal }.map(\.stepKey))
    guard interrupted == Set(expectedInterrupted) else {
        throw KillError.replay(
            "reconcile listed \(interrupted.sorted()), expected "
            + "\(expectedInterrupted.sorted())")
    }
    let abandoned = Set(stepRecords.filter { $0.state == .abandoned }.map(\.stepKey))
    guard abandoned == Set(expectedAbandoned) else {
        throw KillError.replay(
            "abandoned listed \(abandoned.sorted()), expected "
            + "\(expectedAbandoned.sorted())")
    }

    return [
        "wal_mutations": walMutations.count,
        "materialized_files": materialized.files.count,
        "materialized_directories": materialized.directories.count,
        "interrupted_steps": interrupted.count,
        "abandoned_steps": abandoned.count,
        "acked_upto": ackedUpto,
    ]
}

// MARK: - Forked Log child

/// Shared page between the test and the forked child. Only fixed-width integers
/// so the layout is identical in both processes.
public struct KillSharedState {
    public var acked: UInt64
    public var phase: UInt64
    public var attempts: UInt64
    public var reserved: UInt64

    public init(acked: UInt64, phase: UInt64, attempts: UInt64, reserved: UInt64) {
        self.acked = acked
        self.phase = phase
        self.attempts = attempts
        self.reserved = reserved
    }
}

public enum KillFork {
    /// The Swift Darwin overlay marks `fork()` unavailable; resolve the libc
    /// symbol explicitly, like the landed W1 crash test does.
    private static let forkFunction: @convention(c) () -> pid_t = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "fork") else {
            fatalError("fork symbol is unavailable")
        }
        return unsafeBitCast(symbol, to: (@convention(c) () -> pid_t).self)
    }()

    public static func fork() -> pid_t {
        forkFunction()
    }

    public static func sharedState() throws -> (pointer: UnsafeMutablePointer<KillSharedState>,
                                         map: UnsafeMutableRawPointer) {
        let size = max(MemoryLayout<KillSharedState>.size, 4096)
        guard let map = mmap(nil, size, PROT_READ | PROT_WRITE,
                             MAP_SHARED | MAP_ANON, -1, 0),
              map != MAP_FAILED else {
            throw KillError.invalidState("mmap failed")
        }
        let pointer = map.bindMemory(to: KillSharedState.self, capacity: 1)
        pointer.initialize(to: KillSharedState(acked: 0, phase: 0,
                                               attempts: 0, reserved: 0))
        return (pointer, map)
    }

    public static func unmap(_ map: UnsafeMutableRawPointer) {
        munmap(map, max(MemoryLayout<KillSharedState>.size, 4096))
    }

    public static func killBySIGKILL(_ pid: pid_t) {
        _ = Darwin.kill(pid, SIGKILL)
    }
}

// MARK: - Kill report

/// Per-iteration result rows, written to $TMPDIR/pdsh-probes/kill-report.json.
public final class KillReport: @unchecked Sendable {
    public struct Row: Sendable {
        public var index: Int
        public var kind: String
        public var timing: String
        public var passed: Bool
        public var detail: String
        public var metrics: [String: Any]

        public init(index: Int, kind: String, timing: String, passed: Bool,
                    detail: String, metrics: [String: Any]) {
            self.index = index
            self.kind = kind
            self.timing = timing
            self.passed = passed
            self.detail = detail
            self.metrics = metrics
        }
    }

    private let lock = NSLock()
    private var rows: [Row] = []
    public let fileURL: URL

    public init() {
        let environment = ProcessInfo.processInfo.environment
        let directory: URL
        if let configured = environment["PDSH_PROBES_DIR"], !configured.isEmpty {
            directory = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("pdsh-probes", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("kill-report.json")
    }

    public func record(_ row: Row) {
        lock.lock()
        rows.append(row)
        lock.unlock()
        write()
    }

    public func snapshot() -> [Row] {
        lock.lock()
        defer { lock.unlock() }
        return rows
    }

    private func write() {
        lock.lock()
        let snapshot = rows
        lock.unlock()
        let passed = snapshot.filter(\.passed).count
        let failed = snapshot.count - passed
        let object: [String: Any] = [
            "schema": 1,
            "generated_at": ISO8601DateFormatter().string(from: Date()),
            "iterations": snapshot.count,
            "passed": passed,
            "failed": failed,
            "rows": snapshot.map { row -> [String: Any] in
                [
                    "index": row.index,
                    "kind": row.kind,
                    "timing": row.timing,
                    "passed": row.passed,
                    "detail": row.detail,
                    "metrics": row.metrics,
                ]
            },
        ]
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
            return
        }
        try? data.write(to: fileURL, options: Data.WritingOptions.atomic)
    }
}
