// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — macOS end-to-end smoke: harness support.
//
// This file owns everything around the test body: resolving the built Worker
// bundle from the environment, collecting the host event stream, polling with
// generous deadlines, reading back the WAL/journal/step evidence in the same
// formats the host persisted, and writing `$TMPDIR/pdsh-smoke/smoke-report.json`.

import Foundation
import PhoneDSHController
import PhoneDSH
import PhoneDSHEngine
import PhoneDSHLog
import PhoneDSHWire
import PhoneDSHAgentCore

// MARK: - Errors

/// A fail-loud smoke assertion with a human-readable reason.
public enum SmokeError: Error, CustomStringConvertible {
    /// One phase did not reach its condition before the deadline.
    case timeout(String)
    /// An evidence assertion failed.
    case assertion(String)
    /// The WKWebView page was not visible to WebKit before a turn.
    case visibility(String)
    /// The environment the smoke script exports is missing or unusable.
    case environment(String)
    /// A persisted artifact could not be read.
    case artifact(String)

    public var description: String {
        switch self {
        case .timeout(let detail):
            return "timeout: \(detail)"
        case .assertion(let detail):
            return "assertion failed: \(detail)"
        case .visibility(let detail):
            return "page visibility: \(detail)"
        case .environment(let detail):
            return "smoke environment is missing: \(detail)"
        case .artifact(let detail):
            return "cannot read smoke evidence: \(detail)"
        }
    }
}

/// Thrown when `PDSH_DSH_WWW` / `PDSH_DSH_IMAGE` are absent.
public struct SmokeSkip: Error, CustomStringConvertible {
    public let detail: String
    public var description: String { "SKIP: \(detail)" }

    public init(detail: String) { self.detail = detail }
}

// MARK: - Environment

/// The built Worker assets the smoke script exports.
public struct SmokeEnvironment {
    public let staticDirectory: URL
    public let imageArchive: URL
    public let smokeDirectory: URL

    /// Resolves `PDSH_DSH_WWW`, `PDSH_DSH_IMAGE` and `PDSH_SMOKE_DIR`.
    ///
    /// - Throws: ``SmokeSkip`` when the script did not export the built
    ///   artifacts, ``SmokeError/environment(_:)`` when they are unusable.
    public static func resolve(fileManager: FileManager = .default,
                        environment: [String: String] = ProcessInfo.processInfo.environment)
        throws -> SmokeEnvironment {
        let smokeDirectory = URL(fileURLWithPath: environment["PDSH_SMOKE_DIR"]
            ?? fileManager.temporaryDirectory.appendingPathComponent("pdsh-smoke").path,
                                 isDirectory: true)
        guard let staticPath = environment["PDSH_DSH_WWW"], staticPath.isEmpty == false,
              let imagePath = environment["PDSH_DSH_IMAGE"], imagePath.isEmpty == false else {
            throw SmokeSkip(detail: "PDSH_DSH_WWW / PDSH_DSH_IMAGE were not exported by scripts/ci/smoke.sh")
        }
        let staticDirectory = URL(fileURLWithPath: staticPath, isDirectory: true)
        let imageArchive = URL(fileURLWithPath: imagePath)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: staticDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw SmokeError.environment("PDSH_DSH_WWW is not a directory: \(staticPath)")
        }
        for required in ["index.html", "boot.js", "worker-entry.js"] {
            guard fileManager.fileExists(atPath: staticDirectory
                .appendingPathComponent(required).path) else {
                throw SmokeError.environment("PDSH_DSH_WWW has no \(required)")
            }
        }
        guard fileManager.fileExists(atPath: imageArchive.path) else {
            throw SmokeError.environment("PDSH_DSH_IMAGE does not exist: \(imagePath)")
        }
        let lazy = staticDirectory.appendingPathComponent("lazy", isDirectory: true)
        if fileManager.fileExists(atPath: lazy.path, isDirectory: &isDirectory) == false
            || isDirectory.boolValue == false {
            try fileManager.createDirectory(at: lazy, withIntermediateDirectories: true)
        }
        try fileManager.createDirectory(at: smokeDirectory, withIntermediateDirectories: true)
        return SmokeEnvironment(staticDirectory: staticDirectory,
                                imageArchive: imageArchive,
                                smokeDirectory: smokeDirectory)
    }
}

// MARK: - Polling

/// Polls `condition` until it is true or `timeout` elapses.
///
/// Every iteration hands the main thread to the shared harness wait: on macOS
/// that dispatches AppKit events (a WKWebView page in an XCTest process stays
/// hidden to WebKit, and is therefore throttled, until the ordered window's
/// events are dequeued); on iOS it sleeps because the simulator app's run loop
/// already services UIKit. See `docs/architecture.md`, page visibility.
public func smokeWait(timeout: TimeInterval, label: String,
               interval: TimeInterval = 0.05,
               _ condition: () async throws -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while true {
        if try await condition() { return }
        if Date() >= deadline {
            throw SmokeError.timeout("\(label) did not complete within \(Int(timeout)) s")
        }
        try await harnessWait(max(0.01, interval))
    }
}

/// Fails loud when the page is not visible to WebKit.
///
/// This is the precondition the smoke and scenario harnesses assert before
/// their first turn: the hosting window must be occlusion-visible and the page
/// must report `document.visibilityState == "visible"`. Without it WebKit
/// throttles the page and the Worker's fetch stalls silently. The pump runs
/// while the precondition is sampled, so a harness that forgot to pump fails
/// with the page state instead of a hung Worker.
@discardableResult
public func harnessAssertPageVisible(_ engine: WebEngine, label: String,
                              timeout: TimeInterval = 12) async throws
    -> WebEnginePageVisibility {
    let visibility = await engine.waitForVisiblePage(timeout: timeout)
    guard visibility.isVisible else {
        throw SmokeError.visibility("\(label): \(visibility.actionableFailure)")
    }
    return visibility
}

/// A JSON-safe description of a visibility sample for run reports.
public func harnessDescribePageVisibility(_ visibility: WebEnginePageVisibility) -> [String: Any] {
    [
        "attached_with_visible_area": visibility.attachedWithVisibleArea,
        "window_occlusion_visible": visibility.windowOcclusionVisible.map { $0 as Any }
            ?? NSNull(),
        "document_visibility_state": visibility.documentVisibilityState.map { $0 as Any }
            ?? NSNull(),
        "is_visible": visibility.isVisible,
    ]
}

// MARK: - Event log

/// One captured console line (level + text).
public struct SmokeConsoleLine: Sendable {
    public var level: String
    public var text: String

    public init(level: String, text: String) {
        self.level = level
        self.text = text
    }
}

/// Collects the host event stream and the harness streams for the report.
public final class SmokeEventLog: @unchecked Sendable {
    public init() {}

    private let lock = NSLock()
    private var consoleStorage: [SmokeConsoleLine] = []
    private var hostErrorStorage: [String] = []
    private var helloStorage: [PhoneDSHWorkerHello] = []
    private var restartStorage: [WebEngineRestartReport] = []
    private var stateStorage: [String] = []
    private var harnessStorage: [HarnessEvent] = []
    private var harnessErrorStorage: [String] = []
    private var tasks: [Task<Void, Never>] = []

    /// Starts consuming the host's ordered event sequence.
    public func attach(host: PhoneDSHHost) {
        let stream = host.eventStream()
        let task = Task { [weak self] in
            for await event in stream {
                self?.record(host: event)
            }
        }
        lock.lock()
        tasks.append(task)
        lock.unlock()
    }

    /// Starts consuming one harness session stream.
    public func attach(harness: any AgentHarness, sessionID: String) {
        let stream = harness.events(sessionID: sessionID, after: nil)
        let task = Task { [weak self] in
            do {
                for try await event in stream {
                    self?.record(harness: event)
                }
            } catch {
                self?.record(harnessError: String(describing: error))
            }
        }
        lock.lock()
        tasks.append(task)
        lock.unlock()
    }

    /// Stops every stream consumer.
    ///
    /// `AsyncStream` iterations do not observe task cancellation, and the host
    /// ends its bus in `stop()`; awaiting the tasks here would hang, so this
    /// only cancels them and lets their streams finish with their producers.
    public func stop() {
        lock.lock()
        let running = tasks
        tasks.removeAll()
        lock.unlock()
        for task in running { task.cancel() }
    }

    private func record(host event: PhoneDSHEvent) {
        lock.lock()
        defer { lock.unlock() }
        switch event {
        case .console(let payload):
            consoleStorage.append(SmokeConsoleLine(level: payload.level.rawValue,
                                                   text: payload.text))
        case .error(let message):
            hostErrorStorage.append(message)
        case .workerHello(let hello):
            helloStorage.append(hello)
        case .restarted(let report):
            restartStorage.append(report)
        case .stateChanged(let from, let to):
            stateStorage.append("\(from.rawValue)->\(to.rawValue)")
        default:
            break
        }
    }

    private func record(harness event: HarnessEvent) {
        lock.lock()
        defer { lock.unlock() }
        harnessStorage.append(event)
    }

    private func record(harnessError: String) {
        lock.lock()
        defer { lock.unlock() }
        harnessErrorStorage.append(harnessError)
    }

    public var console: [SmokeConsoleLine] {
        lock.lock()
        defer { lock.unlock() }
        return consoleStorage
    }

    public var hostErrors: [String] {
        lock.lock()
        defer { lock.unlock() }
        return hostErrorStorage
    }

    public var hellos: [PhoneDSHWorkerHello] {
        lock.lock()
        defer { lock.unlock() }
        return helloStorage
    }

    public var restarts: [WebEngineRestartReport] {
        lock.lock()
        defer { lock.unlock() }
        return restartStorage
    }

    public var stateChanges: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stateStorage
    }

    public var harnessEvents: [HarnessEvent] {
        lock.lock()
        defer { lock.unlock() }
        return harnessStorage
    }

    public var harnessErrors: [String] {
        lock.lock()
        defer { lock.unlock() }
        return harnessErrorStorage
    }

    /// Console lines whose text mentions the runtime's not-implemented path.
    public var notImplementedFailLines: [String] {
        console.filter { $0.text.range(of: "notImplementedFail", options: .caseInsensitive) != nil }
            .map { "\($0.level): \($0.text)" }
    }

    /// The last `count` console lines, formatted for a failure message.
    public func tail(_ count: Int) -> [String] {
        let lines = console.suffix(max(0, count))
        return lines.map { "\($0.level): \($0.text)" }
    }
}

// MARK: - Report

/// Accumulates the smoke report and writes `smoke-report.json` atomically.
public final class SmokeReport: @unchecked Sendable {
    public struct Phase {
        public var name: String
        public var milliseconds: Double
        public var ok: Bool

        public init(name: String, milliseconds: Double, ok: Bool) {
            self.name = name
            self.milliseconds = milliseconds
            self.ok = ok
        }
    }

    private let lock = NSLock()
    private var phases: [Phase] = []
    private var details: [String: Any] = [:]
    private var ok = false
    private var failure: String?
    public let eventLog: SmokeEventLog
    public let environment: SmokeEnvironment
    public let workspace: URL
    public let reportURL: URL

    public init(eventLog: SmokeEventLog, environment: SmokeEnvironment, workspace: URL) {
        self.eventLog = eventLog
        self.environment = environment
        self.workspace = workspace
        self.reportURL = environment.smokeDirectory
            .appendingPathComponent("smoke-report.json")
    }

    /// Records one finished phase.
    public func addPhase(_ name: String, milliseconds: Double, ok: Bool = true) {
        lock.lock()
        phases.append(Phase(name: name, milliseconds: milliseconds, ok: ok))
        lock.unlock()
    }

    /// Records an arbitrary JSON-safe detail.
    public func set(_ key: String, _ value: Any) {
        lock.lock()
        details[key] = value
        lock.unlock()
    }

    public func finish(ok: Bool, failure: String? = nil) {
        lock.lock()
        self.ok = ok
        self.failure = failure
        lock.unlock()
    }

    /// Writes the report and returns its URL.
    @discardableResult
    public func write() throws -> URL {
        lock.lock()
        let snapshotPhases = phases
        let snapshotDetails = details
        let snapshotOK = ok
        let snapshotFailure = failure
        lock.unlock()
        let console = eventLog.console
        let formatter = ISO8601DateFormatter()
        var object: [String: Any] = [
            "version": 1,
            "ok": snapshotOK,
            "generated_at": formatter.string(from: Date()),
            "paths": [
                "www": environment.staticDirectory.path,
                "image": environment.imageArchive.path,
                "workspace": workspace.path,
                "smoke_dir": environment.smokeDirectory.path,
            ],
            "phases": snapshotPhases.map {
                ["name": $0.name, "duration_ms": $0.milliseconds, "ok": $0.ok]
            },
            "console_count": console.count,
            "console": console.map { ["level": $0.level, "text": $0.text] },
            "console_last_50": eventLog.tail(50),
            "not_implemented_fail": eventLog.notImplementedFailLines,
            "host_errors": eventLog.hostErrors,
            "harness_errors": eventLog.harnessErrors,
            "state_changes": eventLog.stateChanges,
            "worker_hellos": eventLog.hellos.map {
                ["boot_id": $0.bootID, "last_mseq": $0.lastMseq, "generation": $0.generation,
                 "wal_seq": $0.walSeq, "count": $0.count]
            },
            "restarts": eventLog.restarts.map {
                ["reason": $0.reason.rawValue, "boot_id": $0.bootID,
                 "duration_seconds": $0.durationSeconds]
            },
            "harness_events": eventLog.harnessEvents.map(Self.describe(event:)),
        ]
        if let snapshotFailure { object["failure"] = snapshotFailure }
        for (key, value) in snapshotDetails { object[key] = value }
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: object,
                                              options: [.prettyPrinted, .sortedKeys])
        } catch {
            throw SmokeError.artifact("the smoke report is not JSON-serializable: \(error)")
        }
        let temporary = reportURL.appendingPathExtension("tmp")
        do {
            try data.write(to: temporary, options: .atomic)
            _ = try FileManager.default.replaceItemAt(reportURL, withItemAt: temporary)
        } catch {
            try data.write(to: reportURL, options: .atomic)
        }
        return reportURL
    }

    private static func describe(event: HarnessEvent) -> [String: Any] {
        var object: [String: Any] = ["kind": String(describing: event.kind)]
        if let seq = event.seq { object["seq"] = seq }
        switch event.kind {
        case .assistantMessage(let text):
            object["text"] = text
        case .assistantDelta(let text):
            object["text"] = text
        case .toolCall(let callID, let name, _):
            object["call_id"] = callID
            object["tool"] = name
        case .toolResult(let callID, let isError, let summary):
            object["call_id"] = callID
            object["is_error"] = isError
            object["summary"] = summary
        case .turnStarted(let turnID):
            object["turn_id"] = turnID
        case .turnEnded(let turnID, let reason):
            object["turn_id"] = turnID
            object["reason"] = String(describing: reason)
        case .sessionStatus(let status):
            object["status"] = status
        case .exited(let reason):
            object["reason"] = reason
        default:
            break
        }
        return object
    }
}

// MARK: - Evidence readers

/// The WAL's view of the smoke target path.
public struct SmokeWALSummary {
    public var segmentCount = 0
    public var mutationCount = 0
    public var mutationMseqs: [UInt64] = []
    public var targetBytes = Data()
    public var targetMseqs: [UInt64] = []
    public var epochCloseCount = 0
    /// Appended records whose base does not match the replayed file (D9).
    ///
    /// The host would answer such a record with `VFS_RESYNC` instead of
    /// applying it; the evidence reader records the same mismatch rather than
    /// appending bytes at the wrong offset.
    public var appendMismatches: [UInt64] = []

    public var targetText: String { String(decoding: targetBytes, as: UTF8.self) }
}

/// Reads and replays the current WAL against `targetPath`.
///
/// Appended writes are replayed with the D9 host semantics: append only when
/// the current size equals the record's `append_from`, skip a chunk whose
/// already-present bytes equal the record, and otherwise record a mismatch
/// (the host's own resync would have handled it during boot).
public func readWALSummary(workspace: URL, targetPath: String) throws -> SmokeWALSummary {
    let directory = workspace.appendingPathComponent("wal", isDirectory: true)
    guard FileManager.default.fileExists(atPath: directory.path) else {
        throw SmokeError.artifact("no wal/ directory under \(workspace.path)")
    }
    let scan = try WALReader.scan(directory: directory)
    var summary = SmokeWALSummary()
    summary.segmentCount = scan.segments.count
    summary.mutationMseqs = scan.mutationMseqs
    summary.mutationCount = summary.mutationMseqs.count
    summary.epochCloseCount = scan.allRecords.filter(\.isEpochClose).count
    var target = Data()
    for record in scan.allRecords where !record.isEpochClose {
        let mutation = try VfsMutationBody.decode(record.body)
        guard mutation.path == targetPath else { continue }
        switch mutation.op {
        case .write:
            if mutation.mflags.contains(.appended) {
                let base = Int(mutation.appendFrom)
                let end = base + mutation.data.count
                if target.count == base {
                    target.append(mutation.data)
                } else if target.count >= end {
                    let existing = target.subdata(in: base..<end)
                    if existing != mutation.data {
                        summary.appendMismatches.append(record.mseq)
                    }
                    // Equal bytes: this append is already applied (D9).
                } else {
                    summary.appendMismatches.append(record.mseq)
                }
            } else {
                target = mutation.data
            }
            summary.targetMseqs.append(record.mseq)
        case .remove:
            target = Data()
            summary.targetMseqs.append(record.mseq)
        case .mkdir, .chmod:
            break
        }
    }
    summary.targetBytes = target
    return summary
}

/// The journal's dispatched/completed evidence for one session.
public struct SmokeJournalSummary {
    public var exists = false
    public var recordCount = 0
    public var types: [String] = []
    public var sessionIDs: Set<String> = []
    public var dispatched = false
    public var completed = false
    public var toolKeys: [String] = []
    public var error: String?
}

/// Parses `journal.xljournal` (wal.md: 16-byte header, then
/// `len u32 · crc u32 · jseq u64 · session_len u16 · session · record bytes`).
public func readJournalSummary(workspace: URL, sessionID: String?) throws -> SmokeJournalSummary {
    let url = workspace.appendingPathComponent("journal.xljournal")
    var summary = SmokeJournalSummary()
    guard FileManager.default.fileExists(atPath: url.path) else { return summary }
    summary.exists = true
    let data = try Data(contentsOf: url)
    guard data.count >= 16 else {
        throw SmokeError.artifact("journal is shorter than its header")
    }
    var offset = 16
    while offset + 8 <= data.count {
        let length = Int(data.smokeUInt32(at: offset))
        guard length > 0, offset + 8 + length <= data.count else { break }
        let payload = data.subdata(in: (offset + 8)..<(offset + 8 + length))
        guard payload.count >= 10 else { break }
        let jseq = payload.smokeUInt64(at: 0)
        let sessionLength = Int((UInt16(payload.smokeUInt8(at: 8)) << 8)
            | UInt16(payload.smokeUInt8(at: 9)))
        guard payload.count >= 10 + sessionLength,
              let session = String(data: payload.subdata(in: 10..<(10 + sessionLength)),
                                   encoding: .utf8) else { break }
        let record = payload.subdata(in: (10 + sessionLength)..<payload.count)
        _ = jseq
        summary.recordCount += 1
        summary.sessionIDs.insert(session)
        if let object = try? JSONSerialization.jsonObject(with: record) as? [String: Any] {
            // The host journal persists the wire projection tool-journal sends
            // (`{...record, type}`): `dispatched` for a local `start`,
            // `completed` for a local `done`. Read only that projection name.
            let type = (object["type"] as? String) ?? "unknown"
            summary.types.append(type)
            if let key = object["key"] as? String { summary.toolKeys.append(key) }
            if sessionID == nil || session == sessionID {
                if type == "dispatched" { summary.dispatched = true }
                if type == "completed" { summary.completed = true }
            }
        } else {
            summary.types.append("unparsed")
        }
        offset += 8 + length
    }
    return summary
}

/// The step machine's persisted state (`steps/<session>.ndjson` plus
/// `steps/<session>/<step_key>.json` snapshots).
public struct SmokeStepSummary {
    public var states: [String] = []
    public var sessionIDs: Set<String> = []
    public var stepKeys: [String] = []
    public var reachedJournaled = false
    public var reachedWalWritten = false
    public var reachedToolDispatched = false
}

/// Reads the step evidence for one session.
public func readStepSummary(workspace: URL, sessionID: String) throws -> SmokeStepSummary {
    let directory = workspace.appendingPathComponent("steps", isDirectory: true)
    var summary = SmokeStepSummary()
    guard FileManager.default.fileExists(atPath: directory.path) else { return summary }
    let logURL = directory.appendingPathComponent("\(sessionID).ndjson")
    if let data = try? Data(contentsOf: logURL) {
        for line in data.split(separator: 0x0A) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
            else { continue }
            record(object, into: &summary, sessionID: sessionID)
        }
    }
    func record(_ object: [String: Any], into summary: inout SmokeStepSummary,
                sessionID: String) {
        guard let state = object["state"] as? String else { return }
        if let session = object["session_id"] as? String {
            summary.sessionIDs.insert(session)
            guard session == sessionID else { return }
        }
        summary.states.append(state)
        if let key = object["idem_key"] as? String { summary.stepKeys.append(key) }
        if state == "journaled" { summary.reachedJournaled = true }
        if state == "wal_written" { summary.reachedWalWritten = true }
        if state == "tool_dispatched" { summary.reachedToolDispatched = true }
    }
    let snapshotDirectory = directory.appendingPathComponent(sessionID, isDirectory: true)
    if let files = try? FileManager.default.contentsOfDirectory(at: snapshotDirectory,
                                                                includingPropertiesForKeys: nil) {
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            record(object, into: &summary, sessionID: sessionID)
        }
    }
    return summary
}

/// Returns every regular file below `directory` (non-recursive helper for
/// small evidence trees).
public func smokeFiles(under directory: URL) -> [URL] {
    guard let enumerator = FileManager.default.enumerator(at: directory,
                                                          includingPropertiesForKeys: [.isRegularFileKey],
                                                          options: [.skipsHiddenFiles]) else {
        return []
    }
    var files: [URL] = []
    for case let url as URL in enumerator {
        if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            files.append(url)
        }
    }
    return files
}

// MARK: - Small data helpers

extension Data {
    func smokeUInt32(at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        return self[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    func smokeUInt64(at offset: Int) -> UInt64 {
        guard offset >= 0, offset + 8 <= count else { return 0 }
        return self[offset..<(offset + 8)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    func smokeUInt8(at offset: Int) -> UInt8 {
        guard offset >= 0, offset < count else { return 0 }
        return self[offset]
    }
}
