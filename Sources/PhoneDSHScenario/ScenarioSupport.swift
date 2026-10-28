// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — G2 scenario runner: support services.
//
// Credential provider, event recorder, redaction, fixture/workspace seeding,
// assertion helpers, host-side process helpers and the WebContent process
// locator. No scenario-specific content lives here.

import CryptoKit
import Darwin
import Foundation
import WebKit
import PhoneDSHHarness
import PhoneDSHAgentCore
import PhoneDSHController
import PhoneDSH
import PhoneDSHEngine
import PhoneDSHLog
import PhoneDSHWire

#if canImport(AppKit)
import AppKit
#endif

// MARK: - Credentials

/// Serves the host-side model credential for the model host only.
///
/// The Worker never sees the key: the gateway resolves it per upstream attempt
/// from this provider. Hosts a scenario's `network.allow` list opens get an
/// anonymous credential (`Credential.none`), which lets a public repository be
/// fetched without ever handing it the model key. Every other host is denied.
final class ScenarioCredentialProvider: CredentialProvider, @unchecked Sendable {
    private let lock = NSLock()
    private let modelHost: String
    private let modelKey: String?
    private let anonymousHosts: Set<String>
    private var modelRequestCount = 0
    private var deniedHostCount = 0

    /// - Parameters:
    ///   - modelHost: bare host of the model base URL (`url.host`).
    ///   - modelKey: `PDSH_MODEL_API_KEY` (real) or a fixed mock key.
    ///   - anonymousHosts: hosts a scenario's network allow-list admits.
    init(modelHost: String, modelKey: String?, anonymousHosts: Set<String>) {
        self.modelHost = Self.bareHost(modelHost)
        self.modelKey = modelKey
        self.anonymousHosts = Set(anonymousHosts.map(Self.bareHost))
    }

    /// Number of upstream model attempts the gateway asked a credential for.
    var modelRequests: Int {
        lock.lock()
        defer { lock.unlock() }
        return modelRequestCount
    }

    var deniedHosts: Int {
        lock.lock()
        defer { lock.unlock() }
        return deniedHostCount
    }

    func credential(for scope: CredentialScope) async throws -> Credential {
        let host = Self.bareHost(scope.service)
        if host == modelHost {
            recordModelRequest()
            guard let modelKey, !modelKey.isEmpty else {
                throw ProviderError.unauthorized("no host model credential is configured")
            }
            return Credential(kind: .apiKey(header: "x-api-key"), value: modelKey)
        }
        if anonymousHosts.contains(host) {
            // A public fetch needs no key; the gateway applies the `.none`
            // credential without adding an Authorization header.
            return Credential.none
        }
        recordDeniedHost()
        throw ProviderError.unauthorized("host \(host) is not on this scenario's allow-list")
    }

    private func recordModelRequest() {
        lock.lock()
        modelRequestCount += 1
        lock.unlock()
    }

    private func recordDeniedHost() {
        lock.lock()
        deniedHostCount += 1
        lock.unlock()
    }

    func invalidate(_ credential: Credential, for scope: CredentialScope) async {}

    /// `host`, `host:port` or `scheme://host[:port]` -> bare lowercase host.
    static func bareHost(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let separator = value.range(of: "://") {
            value = String(value[separator.upperBound...])
        }
        if let slash = value.firstIndex(of: "/") {
            value = String(value[..<slash])
        }
        if let colon = value.lastIndex(of: ":"), value.filter({ $0 == ":" }).count == 1 {
            let port = value[value.index(after: colon)...]
            if port.allSatisfy({ $0.isNumber }) {
                value = String(value[..<colon])
            }
        }
        return value
    }
}

// MARK: - Redaction

/// Removes credentials and authorization material from anything written to
/// disk. The runner knows the live API key, so exact-value replacement is the
/// strongest rule; the regexes cover values the runner never received.
struct ScenarioRedactor: Sendable {
    private let secrets: [String]

    init(secrets: [String] = []) {
        self.secrets = secrets.filter { !$0.isEmpty }
    }

    func redact(_ text: String) -> String {
        var value = text
        for secret in secrets {
            value = value.replacingOccurrences(of: secret, with: "<redacted>")
        }
        value = value.replacingOccurrences(
            of: #"sk-[A-Za-z0-9]{8,}"#,
            with: "sk-<redacted>",
            options: .regularExpression)
        value = value.replacingOccurrences(
            of: #"(?i)authorization\s*:\s*[^\r\n]+"#,
            with: "authorization: <redacted>",
            options: .regularExpression)
        value = value.replacingOccurrences(
            of: #"(?i)bearer\s+[A-Za-z0-9._~+/-]{8,}"#,
            with: "Bearer <redacted>",
            options: .regularExpression)
        value = value.replacingOccurrences(
            of: #"(?i)x-api-key\s*[=:]\s*[^\s"',;]+"#,
            with: "x-api-key=<redacted>",
            options: .regularExpression)
        return value
    }

    /// Redacts the values of headers that carry credentials, leaves the rest.
    func redact(headers: [String: String]) -> [String: String] {
        let credentialHeaders: Set<String> = ["authorization", "x-api-key", "proxy-authorization"]
        var result: [String: String] = [:]
        for (name, value) in headers {
            result[name] = credentialHeaders.contains(name.lowercased()) ? "<redacted>" : redact(value)
        }
        return result
    }
}

// MARK: - Event recorder

/// One durable or best-effort harness event, kept in arrival order.
struct ScenarioHarnessRecord: Sendable {
    var event: HarnessEvent
}

/// One `turnEnded` event as the report needs it: the DSH turn id, the event's
/// own timestamp (never the runner's clock) and the stable terminal reason
/// (G2-FIX-91/G2-FIX-92).
struct ScenarioTurnEndRecord: Equatable, Sendable {
    var turnID: String
    var time: Date
    var reason: HarnessTurnEnd
    /// `completed`, `cancelled`, `failed` or `budget`. DSH maps
    /// `aborted`/`interrupted` to `.cancelled`; the raw DSH kind is owned by
    /// `HarnessEvent.rawTurnEndKind` in the mapper task.
    var terminalReason: String
    /// Human-readable reason including a failure/budget detail.
    var detail: String
}

/// Collects the host's ordered event stream and one harness session stream.
final class ScenarioRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var consoleErrorsStorage: [String] = []
    private var hostStatesStorage: [String] = []
    private var hostErrorsStorage: [String] = []
    private var hellosStorage: [PhoneDSHWorkerHello] = []
    private var restartsStorage: [WebEngineRestartReport] = []
    private var terminations: UInt64 = 0
    private var lastPageVisibilityStorage: WebEnginePageVisibility?
    private var recordsStorage: [ScenarioHarnessRecord] = []
    private var harnessErrorsStorage: [String] = []
    private var seenDurableSeqs: Set<UInt64> = []
    private var turnStartedStorage = 0
    private var turnEndedStorage = 0
    private var turnEndReasonsStorage: [String] = []
    private var turnEndsStorage: [ScenarioTurnEndRecord] = []
    private var toolCallsStorage = 0
    private var toolResultsStorage = 0
    private var usageEventsStorage = 0
    private var eventsStorage = 0
    private var tasks: [Task<Void, Never>] = []
    private var stopped = false

    // MARK: Attach

    /// Subscribes to the host event sequence (state changes, console errors,
    /// terminations, restarts, HELLOs).
    func attach(host: PhoneDSHHost) {
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

    /// Subscribes to a harness session and re-subscribes after a transport loss
    /// from the last durable sequence number.
    ///
    /// - Parameter after: first durable sequence to deliver (nil starts at the
    ///   backend's retention window). A fresh harness object after a host
    ///   restart must resume past everything already recorded.
    /// - Returns: the pump task so the caller can cancel it when it replaces
    ///   the harness object.
    @discardableResult
    func attach(harness: any AgentHarness, sessionID: String,
                after start: UInt64? = nil) -> Task<Void, Never> {
        let task = Task { [weak self] in
            var after = start
            while !Task.isCancelled {
                do {
                    for try await event in harness.events(sessionID: sessionID, after: after) {
                        if let seq = event.seq, let current = after, seq <= current { continue }
                        self?.record(harness: event)
                        if let seq = event.seq { after = seq }
                    }
                } catch {
                    self?.record(harnessError: String(describing: error))
                }
                if Task.isCancelled { break }
                // Pump AppKit events between event-stream retries: the harness
                // window must stay visible to WebKit for the Worker to run.
                try? await harnessWait(0.3)
            }
        }
        lock.lock()
        tasks.append(task)
        lock.unlock()
        return task
    }

    /// Highest durable harness sequence recorded so far.
    var lastDurableSeq: UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return seenDurableSeqs.max()
    }

    /// Stops the stream consumers. Their producers end when the host stops.
    func stop() {
        lock.lock()
        stopped = true
        let running = tasks
        tasks.removeAll()
        lock.unlock()
        for task in running { task.cancel() }
    }

    // MARK: Recording

    private func record(host event: PhoneDSHEvent) {
        lock.lock()
        defer { lock.unlock() }
        switch event {
        case .stateChanged(let from, let to):
            hostStatesStorage.append("\(from.rawValue)->\(to.rawValue)")
        case .hostTransition(let record):
            hostStatesStorage.append("controller:\(record.from.rawValue)->\(record.to.rawValue)")
        case .console(let payload):
            if payload.level == .error {
                consoleErrorsStorage.append("console.\(payload.level.rawValue): \(payload.text)")
            }
        case .error(let message):
            hostErrorsStorage.append(message)
            consoleErrorsStorage.append("host error: \(message)")
        case .workerHello(let hello):
            hellosStorage.append(hello)
        case .restarted(let report):
            restartsStorage.append(report)
        case .webContentTerminated(let count):
            terminations = max(terminations, count)
        default:
            break
        }
    }

    func record(harness event: HarnessEvent) {
        lock.lock()
        defer { lock.unlock() }
        if let seq = event.seq {
            guard seenDurableSeqs.insert(seq).inserted else { return }
        }
        recordsStorage.append(ScenarioHarnessRecord(event: event))
        eventsStorage += 1
        switch event.kind {
        case .turnStarted:
            turnStartedStorage += 1
        case .turnEnded(let turnID, let reason):
            turnEndedStorage += 1
            turnEndReasonsStorage.append(Self.describe(reason))
            turnEndsStorage.append(ScenarioTurnEndRecord(
                turnID: turnID,
                time: event.time,
                reason: reason,
                terminalReason: Self.terminalReason(reason),
                detail: Self.describe(reason)))
        case .toolCall:
            toolCallsStorage += 1
        case .toolResult:
            toolResultsStorage += 1
        case .usage:
            usageEventsStorage += 1
        case .sessionStatus(let status) where status.hasPrefix("error"):
            consoleErrorsStorage.append("session: \(status)")
        case .exited(let reason):
            consoleErrorsStorage.append("session exited: \(reason)")
        default:
            break
        }
    }

    private func record(harnessError: String) {
        lock.lock()
        harnessErrorsStorage.append(harnessError)
        lock.unlock()
    }

    private static func describe(_ reason: HarnessTurnEnd) -> String {
        switch reason {
        case .completed: return "completed"
        case .cancelled: return "cancelled"
        case .failed(let detail): return "failed: \(detail)"
        case .budgetExhausted(let detail): return "budget: \(detail)"
        }
    }

    /// The stable terminal reason stored on a turn report. The human-readable
    /// detail stays in ``ScenarioTurnEndRecord/detail``.
    private static func terminalReason(_ reason: HarnessTurnEnd) -> String {
        switch reason {
        case .completed: return "completed"
        case .cancelled: return "cancelled"
        case .failed: return "failed"
        case .budgetExhausted: return "budget"
        }
    }

    // MARK: Snapshots

    var consoleErrors: [String] {
        lock.lock()
        defer { lock.unlock() }
        return consoleErrorsStorage
    }

    var hostStates: [String] {
        lock.lock()
        defer { lock.unlock() }
        return hostStatesStorage
    }

    var hostErrors: [String] {
        lock.lock()
        defer { lock.unlock() }
        return hostErrorsStorage
    }

    var hellos: [PhoneDSHWorkerHello] {
        lock.lock()
        defer { lock.unlock() }
        return hellosStorage
    }

    var restarts: [WebEngineRestartReport] {
        lock.lock()
        defer { lock.unlock() }
        return restartsStorage
    }

    var webContentTerminations: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return terminations
    }

    /// The last pre-turn page-visibility sample (G2-FIX-21).
    var lastPageVisibility: WebEnginePageVisibility? {
        lock.lock()
        defer { lock.unlock() }
        return lastPageVisibilityStorage
    }

    /// Records the pre-turn page-visibility sample for the run report.
    func recordPageVisibility(_ visibility: WebEnginePageVisibility) {
        lock.lock()
        lastPageVisibilityStorage = visibility
        lock.unlock()
    }

    var turnStartedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return turnStartedStorage
    }

    var turnEndedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return turnEndedStorage
    }

    var lastTurnEndReason: String? {
        lock.lock()
        defer { lock.unlock() }
        return turnEndReasonsStorage.last
    }

    /// Every terminal event in arrival order. The runner reads the event at
    /// the index it snapshotted before sending a prompt.
    var turnEnds: [ScenarioTurnEndRecord] {
        lock.lock()
        defer { lock.unlock() }
        return turnEndsStorage
    }

    /// The first terminal event after `index`, or nil when none has arrived.
    func turnEnd(after index: Int) -> ScenarioTurnEndRecord? {
        lock.lock()
        defer { lock.unlock() }
        guard index >= 0, index < turnEndsStorage.count else { return nil }
        return turnEndsStorage[index]
    }

    var toolCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return toolCallsStorage
    }

    var toolResultCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return toolResultsStorage
    }

    /// Consumed assistant messages that carried provider usage. One per fully
    /// consumed model response; a response that stalls before `message_stop`
    /// never produces one.
    var usageEventCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return usageEventsStorage
    }

    var harnessEventCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return eventsStorage
    }

    var harnessErrors: [String] {
        lock.lock()
        defer { lock.unlock() }
        return harnessErrorsStorage
    }

    var records: [ScenarioHarnessRecord] {
        lock.lock()
        defer { lock.unlock() }
        return recordsStorage
    }
}

// MARK: - Materialized workspace

/// Snapshot of the materialized workspace: relative path -> size + SHA-256.
struct MaterializedSnapshot: Equatable {
    struct Entry: Equatable {
        var size: Int
        var sha256: String
    }

    var entries: [String: Entry]

    /// Byte-identity comparison of the files present in `self`: every
    /// pre-existing file must still exist with the same bytes, while files that
    /// did not exist before are not listed.
    ///
    /// This is a generic snapshot helper, not the recovery verdict: a legal
    /// drain-window write changes bytes without any recovery defect. Recovery
    /// uses the WAL-accounted replay in `ScenarioRecovery`, which explains each
    /// observed change by its mseq.
    func differences(after newer: MaterializedSnapshot) -> [String] {
        var differences: [String] = []
        for (path, entry) in entries {
            guard let current = newer.entries[path] else {
                differences.append("\(path) disappeared")
                continue
            }
            if current != entry {
                differences.append("\(path) changed")
            }
        }
        return differences.sorted()
    }

    static func read(workspaceRoot: URL) -> MaterializedSnapshot {
        let root = workspaceRoot.appendingPathComponent("materialized/workspace", isDirectory: true)
        var entries: [String: Entry] = [:]
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(at: root,
                                                  includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                                  options: []) else {
            return MaterializedSnapshot(entries: entries)
        }
        let prefix = root.standardizedFileURL.path + "/"
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
                continue
            }
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(prefix) else { continue }
            let relative = String(full.dropFirst(prefix.count))
            let data = (try? Data(contentsOf: url)) ?? Data()
            entries[relative] = Entry(size: data.count, sha256: Self.hex(of: data))
        }
        return MaterializedSnapshot(entries: entries)
    }

    static func hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Host-side process helper

/// Bounds process output embedded in an assertion detail.
///
/// This is deliberately the only truncation: two stacked `suffix` calls with
/// no marker made a failed command's evidence look like a corrupted prefix
/// (the G2-B03 report lost the unittest traceback header that way). A truncated
/// detail now always starts its output block with an explicit marker naming the
/// bound and the original length, so a reader can tell a tail from the whole
/// output and knows which direction was dropped.
enum ScenarioProcessOutput {
    /// Maximum number of output characters embedded in one assertion detail.
    static let detailCharacterLimit = 1200

    /// Returns `text` unchanged when it fits `limit` characters; otherwise the
    /// last `limit` characters prefixed with one explicit marker line.
    static func detailTail(_ text: String,
                           limit: Int = detailCharacterLimit) -> String {
        guard limit >= 0, text.count > limit else { return text }
        return "...[truncated: last \(limit) of \(text.count) chars]...\n"
            + String(text.suffix(limit))
    }

    /// The one entry point for embedding a process's combined output in a
    /// detail: the bound applies to `stdout + stderr` as a whole, so two
    /// individually-short streams cannot slip past it unmarked, and no caller
    /// applies a second `suffix` to the result.
    static func combinedTail(stdout: String,
                             stderr: String,
                             limit: Int = detailCharacterLimit) -> String {
        detailTail((stdout + stderr).trimmingCharacters(in: .whitespacesAndNewlines),
                   limit: limit)
    }
}

/// Result of one host process run.
struct ScenarioProcessResult: Sendable {
    var status: Int32
    var stdout: String
    var stderr: String
    var timedOut: Bool

    var combinedTail: String {
        ScenarioProcessOutput.combinedTail(stdout: stdout, stderr: stderr)
    }
}

enum ScenarioProcess {
    /// Runs an executable, capturing stdout/stderr. A watchdog terminates the
    /// child at `timeout`.
    ///
    /// Only the macOS test process can spawn host processes. The iOS Simulator
    /// bundle has no `Process`; `workspace_command` never reaches this call
    /// there (it records `pending_host` for the host phase), and any other
    /// caller that needs one gets a typed failure that is reported per
    /// scenario, never a silent pass.
    static func run(_ executable: String, _ arguments: [String],
                    in directory: URL?,
                    timeout: TimeInterval,
                    environment: [String: String] = [:]) -> ScenarioProcessResult {
        #if os(macOS)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = directory }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        for (name, value) in environment { env[name] = value }
        process.environment = env
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let timedOut = LockedFlag()
        do {
            try process.run()
        } catch {
            return ScenarioProcessResult(status: -1, stdout: "",
                                         stderr: "cannot start \(executable): \(error)",
                                         timedOut: false)
        }
        let watchdog = DispatchWorkItem {
            if process.isRunning {
                timedOut.set()
                process.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        return ScenarioProcessResult(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self),
            timedOut: timedOut.value)
        #else
        return ScenarioProcessResult(
            status: -1, stdout: "",
            stderr: "host process execution is not available in the iOS scenario runner "
                + "(\(executable) cannot be spawned from the simulator test process)",
            timedOut: false)
        #endif
    }
}

/// Small thread-safe boolean for the process watchdog.
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set() {
        lock.lock()
        storage = true
        lock.unlock()
    }
}

// MARK: - Fixtures and seeding

/// Builds one fixture (payload + deterministic git history) in a scratch
/// directory and turns it into VFS mutations.
enum ScenarioFixtures {
    struct Seed {
        /// Relative path under the scenario workspace.
        var path: String
        var data: Data
        var mode: UInt32 = 0o644
    }

    /// Assembles the scenario's workspace: fixture payload first, then the
    /// catalog's inline files (which override).
    static func seeds(for scenario: Scenario,
                      fixturesRoot: URL,
                      scratch: URL,
                      fileManager: FileManager = .default) throws -> [Seed] {
        var seeds: [String: Seed] = [:]
        if let fixture = scenario.workspace.fixture, !fixture.isEmpty {
            for seed in try fixtureSeeds(name: fixture, fixturesRoot: fixturesRoot,
                                         scratch: scratch, fileManager: fileManager) {
                seeds[seed.path] = seed
            }
        }
        for (path, content) in scenario.workspace.files ?? [:] {
            seeds[path] = Seed(path: path, data: Data(content.utf8))
        }
        return seeds.values.sorted { $0.path < $1.path }
    }

    /// Copies one fixture's `files/` payload and, when `fixture.json` declares
    /// git history, builds it with plumbing commands (`init` / `add` /
    /// `write-tree` / `commit-tree` / `update-ref`; no `commit`, `checkout`,
    /// `branch` or `reset` is used).
    static func fixtureSeeds(name: String, fixturesRoot: URL, scratch: URL,
                             fileManager: FileManager = .default) throws -> [Seed] {
        let fixtureRoot = fixturesRoot.appendingPathComponent(name, isDirectory: true)
        let payload = fixtureRoot.appendingPathComponent("files", isDirectory: true)
        guard fileManager.fileExists(atPath: payload.path) else {
            throw ScenarioError.artifact("fixture \(name) has no files/ directory at \(payload.path)")
        }
        let specURL = fixtureRoot.appendingPathComponent("fixture.json")
        let spec: FixtureSpec
        if fileManager.fileExists(atPath: specURL.path) {
            spec = try JSONDecoder().decode(FixtureSpec.self, from: Data(contentsOf: specURL))
        } else {
            spec = FixtureSpec(name: name, description: nil, git: nil)
        }

        let buildRoot = scratch.appendingPathComponent("fixture-\(name)", isDirectory: true)
        if fileManager.fileExists(atPath: buildRoot.path) {
            try fileManager.removeItem(at: buildRoot)
        }
        try fileManager.createDirectory(at: buildRoot.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        try fileManager.copyItem(at: payload, to: buildRoot)

        if let git = spec.git {
            try buildGitHistory(spec: git, branch: git.branch, in: buildRoot, fixture: name)
        }

        var seeds: [Seed] = []
        let prefix = buildRoot.standardizedFileURL.path + "/"
        guard let enumerator = fileManager.enumerator(
            at: buildRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []) else {
            throw ScenarioError.artifact("cannot enumerate fixture \(name)")
        }
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { continue }
            guard values?.isRegularFile == true else { continue }
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(prefix) else { continue }
            let relative = String(full.dropFirst(prefix.count))
            try validate(relativePath: relative)
            let attributes = try fileManager.attributesOfItem(atPath: full)
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint32Value ?? 0o644
            seeds.append(Seed(path: relative,
                              data: try Data(contentsOf: url),
                              mode: permissions & 0o777))
        }
        return seeds.sorted { $0.path < $1.path }
    }

    private static func buildGitHistory(spec: FixtureSpec.Git, branch: String,
                                        in directory: URL, fixture: String) throws {
        func git(_ arguments: [String], identity: FixtureSpec.Git.Identity? = nil) throws -> String {
            var full = ["-C", directory.path]
            if let identity {
                full += ["-c", "user.name=\(identity.name)",
                         "-c", "user.email=\(identity.email)"]
            }
            full += arguments
            let result = ScenarioProcess.run("/usr/bin/git", full, in: nil, timeout: 120)
            guard result.status == 0, !result.timedOut else {
                throw ScenarioError.artifact(
                    "fixture \(fixture): git \(arguments.first ?? "") failed: \(result.combinedTail)")
            }
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let branchName = branch.isEmpty ? "main" : branch
        _ = try git(["init", "--quiet", "--initial-branch=\(branchName)"])
        if let identity = spec.identity {
            // Local repository identity, so the model can commit without
            // passing author flags (the Worker's git has no `git config`).
            _ = try git(["config", "user.name", identity.name])
            _ = try git(["config", "user.email", identity.email])
        }
        var parent: String?
        for (index, commit) in spec.commits.enumerated() {
            guard !commit.files.isEmpty else {
                throw ScenarioError.artifact("fixture \(fixture): commit \(index) has no files")
            }
            _ = try git(["add", "--"] + commit.files)
            let tree = try git(["write-tree"])
            var commitArguments = ["commit-tree", tree]
            if let parent { commitArguments += ["-p", parent] }
            commitArguments += ["-m", commit.message]
            // Even a fixture with no stored identity needs a committer for its
            // own history; identity flags here do not write .git/config.
            let builderIdentity = spec.identity ?? FixtureSpec.Git.Identity(
                name: "fixture builder",
                emailUser: "fixture",
                emailHost: "example.invalid")
            let sha = try git(commitArguments, identity: builderIdentity)
            _ = try git(["update-ref", "refs/heads/\(branchName)", sha])
            parent = sha
        }
        _ = try git(["symbolic-ref", "HEAD", "refs/heads/\(branchName)"])
        let status = try git(["status", "--porcelain"])
        if !status.isEmpty {
            throw ScenarioError.artifact(
                "fixture \(fixture): the generated repository is not clean: \(status)")
        }
    }

    /// Rejects workspace escape and the VFS path grammar before seeding.
    static func validate(relativePath: String) throws {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else {
            throw ScenarioError.artifact("workspace seed path is not relative and clean: \(relativePath)")
        }
    }
}

// MARK: - Workspace seeding through the landed WAL

enum ScenarioWorkspace {
    /// Seeds `workspaceRoot` with the scenario's files by appending real
    /// `VFS_MUT` records through ``WorkspaceLog`` and closing one epoch. The
    /// host then starts against a normal materialized tree, exactly as it would
    /// after a user prepared the workspace on the device.
    static func seed(roots: [ScenarioFixtures.Seed], workspaceRoot: URL,
                     fileManager: FileManager = .default) async throws -> [String] {
        if fileManager.fileExists(atPath: workspaceRoot.path) {
            try fileManager.removeItem(at: workspaceRoot)
        }
        try fileManager.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        var bootID = Data(count: 16)
        for index in 0..<bootID.count {
            bootID[index] = UInt8.random(in: 0...255)
        }
        let log = try WorkspaceLog(
            configuration: WorkspaceLogConfiguration(root: workspaceRoot),
            bootID: bootID)
        _ = try await log.recover()
        var paths: [String] = []
        for seed in roots {
            let path = "/dsh/workspace/\(seed.path)"
            let mutation = VfsMutationBody(
                op: .write,
                mode: seed.mode == 0 ? 0o644 : seed.mode,
                path: path,
                data: seed.data)
            _ = try await log.append(mutation)
            paths.append(seed.path)
        }
        _ = try await log.closeEpoch()
        return paths
    }
}

// MARK: - WebContent process locator

#if os(macOS)
/// Finds the macOS WebContent process that hosts this test's WKWebView.
///
/// The process is selected by evidence, never by name across the host: only a
/// `com.apple.WebKit.WebContent` process that currently holds a TCP connection
/// to one of this process's own listening ports (the loopback origin) is
/// eligible. A process from another simulator or another test lane has neither
/// this loopback port nor this origin, so it can never be selected.
enum ScenarioWebContent {
    struct Process {
        var pid: pid_t
        var foreignPorts: [UInt16]
    }

    /// All macOS WebContent processes (simulator WebContent excluded).
    static func allProcesses() -> [Process] {
        var pids = [pid_t](repeating: 0, count: 16384)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }
        var result: [Process] = []
        for index in 0..<min(Int(count), pids.count) {
            let pid = pids[index]
            guard pid > 0, isMacWebContent(pid) else { continue }
            result.append(Process(pid: pid, foreignPorts: foreignPorts(of: pid)))
        }
        return result
    }

    /// The WebContent process connected to this process's loopback listener.
    static func current() -> Process? {
        let listeners = listeningPorts()
        guard !listeners.isEmpty else { return nil }
        let candidates = allProcesses().filter { !$0.foreignPorts.isEmpty }
        let matches = candidates.filter { process in
            !Set(process.foreignPorts).isDisjoint(with: listeners)
        }
        return matches.first
    }

    /// The PID of a WebContent process known by path (used to validate a
    /// remembered boot PID).
    static func isAliveWebContent(_ pid: pid_t) -> Bool {
        pid > 0 && kill(pid, 0) == 0 && isMacWebContent(pid)
    }

    /// SIGKILLs one already-resolved WebContent process. Extracted from the
    /// runner's inline kill so the locator and the signal stay one mechanism
    /// and any test that links this library can reuse it; the caller resolves
    /// the process by evidence (loopback connection / this run's pid), this
    /// function only delivers the signal and surfaces failures.
    static func terminate(_ pid: pid_t) throws {
        guard pid > 0, isMacWebContent(pid) else {
            throw ScenarioError.infra(
                "pid \(pid) is not a live macOS WebContent process")
        }
        guard kill(pid, SIGKILL) == 0 else {
            throw ScenarioError.infra(
                "SIGKILL to WebContent pid \(pid) failed (errno \(errno))")
        }
    }

    /// PIDs of every macOS WebContent process right now.
    static func allPids() -> Set<pid_t> {
        Set(allProcesses().map(\.pid))
    }

    /// The newest process of a candidate set, by recorded start time. Used
    /// after a boot/restart: only the WKWebView this process created should be
    /// new, so this resolves a residual tie deterministically.
    static func newestPid(among candidates: Set<pid_t>) -> pid_t? {
        var best: (pid: pid_t, start: Double)?
        for pid in candidates {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) > 0 else { continue }
            let start = Double(info.pbi_start_tvsec)
                + Double(info.pbi_start_tvusec) / 1_000_000
            if best == nil || start > best!.start {
                best = (pid, start)
            }
        }
        return best?.pid
    }

    // MARK: Internals

    private static func isMacWebContent(_ pid: pid_t) -> Bool {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
        let path = String(cString: buffer)
        return path.contains("com.apple.WebKit.WebContent") && !path.contains("CoreSimulator")
    }

    /// TCP local ports this process listens on.
    private static func listeningPorts() -> Set<UInt16> {
        var ports: Set<UInt16> = []
        for socket in sockets(of: getpid()) where socket.isTCP {
            if socket.foreignPort == 0 && socket.localPort != 0 {
                ports.insert(socket.localPort)
            }
        }
        return ports
    }

    private static func foreignPorts(of pid: pid_t) -> [UInt16] {
        sockets(of: pid).filter { $0.isTCP && $0.foreignPort != 0 }.map(\.foreignPort)
    }

    private struct Socket {
        var isTCP: Bool
        var localPort: UInt16
        var foreignPort: UInt16
    }

    private static func sockets(of pid: pid_t) -> [Socket] {
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: 8192)
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds,
                                 Int32(fds.count * MemoryLayout<proc_fdinfo>.size))
        guard bytes > 0 else { return [] }
        let count = Int(bytes) / MemoryLayout<proc_fdinfo>.size
        var result: [Socket] = []
        for index in 0..<min(count, fds.count) {
            let fd = fds[index]
            guard fd.proc_fdtype == PROX_FDTYPE_SOCKET else { continue }
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) > 0 else {
                continue
            }
            let isTCP = info.psi.soi_kind == SOCKINFO_TCP
            var local: UInt16 = 0
            var foreign: UInt16 = 0
            if isTCP {
                let tcp = info.psi.soi_proto.pri_tcp
                local = UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport))
                foreign = UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_fport))
            }
            result.append(Socket(isTCP: isTCP, localPort: local, foreignPort: foreign))
        }
        return result
    }
}

#else

/// The iOS Simulator runner has no host-process API: the test process cannot
/// enumerate or signal the simulator's WebContent processes. `webcontent_kill`
/// is therefore executed through the host-side device-scoped watcher
/// (`scripts/ci/scenarios.sh --run-on sim` arms
/// `scripts/ci/webcontent-watch.sh`); the capability matrix rejects the
/// kind before the run when that watcher is not armed, so the runner never
/// records "not available" at verdict time (G2-FIX-65). This stub only keeps
/// the cross-platform type surface compiling.
enum ScenarioWebContent {
    struct Process {
        var pid: pid_t
        var foreignPorts: [UInt16]
    }

    static func allProcesses() -> [Process] { [] }
    static func current() -> Process? { nil }
    static func isAliveWebContent(_ pid: pid_t) -> Bool { false }
    static func allPids() -> Set<pid_t> { [] }
    static func newestPid(among candidates: Set<pid_t>) -> pid_t? { nil }
    /// Unreachable on this target (the capability matrix routes
    /// `webcontent_kill` through the host watcher); kept so the shared
    /// `ScenarioRun` code compiles on iOS.
    static func terminate(_ pid: pid_t) throws {
        throw ScenarioError.infra(
            "the iOS test process cannot signal WebContent pid \(pid); "
            + "use the device-scoped watcher handshake")
    }
}

#endif

/// Cross-process lock around a WKWebView boot/restart.
///
/// The batch orchestrator runs several scenario processes in parallel; only
/// the process holding this lock creates or restarts a WKWebView. That makes
/// the WebContent baseline diff unambiguous: a newly appeared macOS WebContent
/// process in the locked window belongs to this run.
#if os(macOS)
final class ScenarioBootLock: @unchecked Sendable {
    private var descriptor: Int32
    private let path: String

    init(path: URL, timeout: TimeInterval = 300) throws {
        self.path = path.path
        descriptor = open(path.path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else {
            throw ScenarioError.environment("cannot open the WebContent lock at \(path.path)")
        }
        let deadline = Date().addingTimeInterval(timeout)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            if Date() >= deadline {
                close(descriptor)
                descriptor = -1
                throw ScenarioError.environment("timed out waiting for the WebContent lock")
            }
            // The lock can be held by another lane's boot/restart; keep this
            // lane's page visible while waiting instead of blocking AppKit.
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    WebEngineAppKitEventPump.pump(for: 0.1)
                }
            } else {
                usleep(100_000)
            }
        }
    }

    func release() {
        guard descriptor >= 0 else { return }
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    deinit { release() }

    /// The shared lock every scenario lane uses.
    static var sharedPath: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-scenarios-webcontent.lock")
    }
}
#else
/// iOS Simulator: one test process runs one lane, so there is no concurrent
/// WKWebView boot to serialize and no host-process API to acquire a flock with.
final class ScenarioBootLock: @unchecked Sendable {
    init(path: URL, timeout: TimeInterval = 0) throws {
        _ = path
        _ = timeout
    }

    func release() {}

    /// The shared lock every scenario lane uses.
    static var sharedPath: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-scenarios-webcontent.lock")
    }
}
#endif

// MARK: - Console session precondition

/// The macOS console-session precondition for any real WKWebView run.
///
/// While the console is locked the window server marks every window
/// occlusion-hidden, so no AppKit event pump can make the page visible and
/// WebKit reports `document.visibilityState == "hidden"`. A hidden page is
/// throttled (timers, fetch-body reads and Worker scheduling stop), so a
/// scenario cannot exercise the stack at all. That is an environment state, not
/// a scenario result: the runner records it in `report.json` (status `SKIP`)
/// and the XCTest case skips loudly, leaving the fail-loud page-visibility
/// assertion untouched for an unlocked session where a hidden page is a
/// harness defect. This mirrors `WebEngineVisibilityTests`, which skips its
/// visibility cases for the same reason.
enum ScenarioConsoleSession {
    /// `true` while the graphical login session is locked.
    static var isLocked: Bool {
#if os(macOS)
        guard let dictionary = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }
        if let locked = dictionary["CGSSessionScreenIsLocked"] as? Bool {
            return locked
        }
        return (dictionary["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
#else
        // iOS / the Simulator: WKWebView visibility follows UIKit's scene state, not the Mac console; no lock precondition.
        return false
#endif
    }

    /// Why a locked session defers the run; `nil` when the console is unlocked.
    static var lockedReason: String? {
        guard isLocked else { return nil }
        return "the Mac console session is locked (CGSSessionScreenIsLocked=1); "
            + "the window server marks every window occlusion-hidden, so WebKit "
            + "throttles the WKWebView page (timers, fetch-body reads and Worker "
            + "scheduling stop) and no event pump can make it visible. Unlock the "
            + "console and rerun; the page-visibility precondition is not weakened."
    }
}

// MARK: - Execution helpers

/// Polls `condition` until true or `deadline` elapsed.
///
/// Each iteration dispatches AppKit events through the shared pump instead of
/// sleeping: the macOS scenario harness has no `NSApplication.run`, and a page
/// WebKit considers hidden is throttled (timers, fetch-body reads and Worker
/// scheduling stop). See `docs/architecture.md`, page visibility.
@MainActor
func scenarioWait(timeout: TimeInterval, label: String,
                  interval: TimeInterval = 0.05,
                  deadline: Date? = nil,
                  _ condition: () async throws -> Bool) async throws {
    let end = min(Date().addingTimeInterval(timeout), deadline ?? Date.distantFuture)
    while true {
        // G2-FIX-Q3: a termination request from outside the scenario fails the
        // wait loud; it must never be lost in a silently truncated XCTest log.
        try ScenarioProcessSignals.throwIfTerminationRequested()
        if try await condition() { return }
        if Date() >= end {
            throw ScenarioError.timeout("\(label) did not complete within \(Int(timeout)) s")
        }
        try await harnessWait(max(0.01, interval))
    }
}

/// Copies a directory tree, preserving regular files and directories.
func scenarioCopyTree(from source: URL, to destination: URL,
                      fileManager: FileManager = .default) throws {
    if fileManager.fileExists(atPath: destination.path) {
        try fileManager.removeItem(at: destination)
    }
    try fileManager.createDirectory(at: destination.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
    try fileManager.copyItem(at: source, to: destination)
}

/// Writes an atomically-replaced file under a results directory.
func scenarioWrite(_ data: Data, to url: URL,
                   fileManager: FileManager = .default) throws {
    try fileManager.createDirectory(at: url.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
    let temporary = url.deletingLastPathComponent()
        .appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
    try data.write(to: temporary, options: .atomic)
    if fileManager.fileExists(atPath: url.path) {
        try fileManager.removeItem(at: url)
    }
    try fileManager.moveItem(at: temporary, to: url)
}

/// ISO-8601 timestamp used in reports.
func scenarioTimestamp(_ date: Date = Date()) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}
