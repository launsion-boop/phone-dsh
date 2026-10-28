// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHGateway: bounded response log.
//
// PLAN §2.5 and the W1-GATEWAY work package. The log stores complete model
// responses under `<root>/response-log/<key>/` (status, response headers and
// body) together with an LRU index. A response is visible for replay only
// after `finish`; an aborted stream, a transport failure or a process kill
// leaves nothing replayable.
//
// Replay policy is owned by the host state machine: the controller opens the
// window while it is Recovering. Opening the window is not part of this type;
// the gateway consults it and answers a matching request from here without
// contacting the upstream.
//
// The W0 skeleton declared `begin(requestID:status:headers:)` and
// `replay(requestID:)` as a chunk-oriented stream. The key that identifies a
// replay is the content hash of the request, not a per-connection request id,
// so `begin` also takes `key` and `replay` returns the complete recorded
// response (status, headers and body). The public names are unchanged.

import Foundation

/// One logged response body chunk.
public struct ResponseLogEntry: Equatable, Sendable {
    /// Per-connection request id of the recording.
    public var requestID: String
    /// Zero-based order inside that recording.
    public var sequence: UInt64
    public var body: Data
    /// Set on the last chunk of a complete response.
    public var isFinal: Bool

    public init(requestID: String, sequence: UInt64, body: Data, isFinal: Bool = false) {
        self.requestID = requestID
        self.sequence = sequence
        self.body = body
        self.isFinal = isFinal
    }
}

/// A complete recorded response, ready to be served without touching the
/// upstream.
public struct ResponseLogReplay: Equatable, Sendable {
    public var key: String
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(key: String, status: Int, headers: [String: String], body: Data) {
        self.key = key
        self.status = status
        self.headers = headers
        self.body = body
    }
}

/// Outcome of a resume read at a byte offset.
///
/// Validation happens before any delivery accounting: `.offsetOutOfRange`
/// means the committed body is shorter than the requested offset and nothing
/// was delivered or counted.
public enum ResponseLogResumeOutcome: Equatable, Sendable {
    /// No complete committed response exists for the key (yet).
    case missing
    /// The committed body is shorter than the requested offset.
    case offsetOutOfRange(bodyBytes: Int)
    /// The complete recorded response; the caller serves `body.dropFirst(offset)`.
    case replay(ResponseLogReplay)
}

/// Delivery facts that a single committed `<key>/entry.json` directory proves
/// on its own.
///
/// `key`, `status` and `bodyBytes` identify the recorded response;
/// `lastUsed` and `deliveryCount` record that `replay` actually served it.
/// The receipt never carries the body, request headers or credentials.
public struct ResponseLogReceipt: Equatable, Sendable {
    public var key: String
    public var status: Int
    public var bodyBytes: Int
    /// Monotonic access ordinal, `0` until the committed response is replayed.
    public var lastUsed: UInt64
    /// Number of successful `replay` deliveries of this committed response.
    public var deliveryCount: Int

    public init(key: String,
                status: Int,
                bodyBytes: Int,
                lastUsed: UInt64,
                deliveryCount: Int) {
        self.key = key
        self.status = status
        self.bodyBytes = bodyBytes
        self.lastUsed = lastUsed
        self.deliveryCount = deliveryCount
    }
}

/// Health of the response log's LRU index file.
///
/// `index.json` is a cache over the committed `<key>/entry.json` directories,
/// never the source of truth: a failed write cannot lose a committed response,
/// and the next successful write (or the next start's directory scan) repairs
/// it. `ResponseLog.indexStatus()` exposes a persisting failure so the host can
/// report it at runtime instead of waiting for a restart.
public struct ResponseLogIndexStatus: Equatable, Sendable {
    /// True when the most recent index write succeeded.
    public var isPersisted: Bool
    /// Failed index-persistence calls since the last success.
    public var consecutiveFailures: Int

    public init(isPersisted: Bool, consecutiveFailures: Int) {
        self.isPersisted = isPersisted
        self.consecutiveFailures = consecutiveFailures
    }
}

/// Bounded response log used to replay a model stream after a WebContent
/// restart (PLAN §2.5, response log quota 128 MB).
public protocol ResponseLogging: Sendable {
    /// Starts recording a response for the content-addressed `key`.
    ///
    /// The recording is invisible to `replay` until `finish` commits it.
    func begin(requestID: String, key: String, status: Int, headers: [String: String]) async throws
    /// Appends one body chunk in sequence order.
    func append(_ entry: ResponseLogEntry) async throws
    /// Commits the recording; only now can the key be replayed.
    ///
    /// Returns the committed receipt when the entry is still retained after
    /// quota eviction, or `nil` when this commit was dropped (a response larger
    /// than the whole quota, or a concurrent commit that made it the LRU
    /// victim). The return value is the atomic proof that the key is present;
    /// callers must not follow this with a separate `receipt(key:)` call and
    /// treat a `nil` there as a committed outcome.
    func finish(requestID: String) async throws -> ResponseLogReceipt?
    /// Discards an incomplete recording (transport error or truncated stream).
    func abort(requestID: String) async
    /// Returns the complete recorded response for `key`, or `nil`.
    func replay(key: String) async -> ResponseLogReplay?
    /// Reads the committed response for a resume at `offset`.
    ///
    /// The offset is validated against the on-disk body size before any
    /// delivery is counted. Only an in-range offset is a delivery; an
    /// out-of-range request returns ``ResponseLogResumeOutcome/offsetOutOfRange(bodyBytes:)``
    /// without changing `lastUsed` or `deliveryCount`.
    func replay(key: String, offset: Int) async -> ResponseLogResumeOutcome
    /// Returns the delivery facts stored beside the committed body, or `nil`
    /// when the entry or its complete body is missing.
    func receipt(key: String) async -> ResponseLogReceipt?
    /// Current body bytes held by the log.
    func totalBytes() async -> Int
}

/// Errors raised by the response log itself. They never carry request bodies,
/// URLs or credentials.
public enum ResponseLogError: Error, Equatable, Sendable {
    case invalidKey
    case duplicateRequest(String)
    case unknownRequest(String)
    case invalidSequence(expected: UInt64, got: UInt64)
    case ioFailure
}

/// Disk-backed response log with an LRU index.
///
/// Layout under `root`:
///
///     response-log/index.json                 LRU index and access counter
///     response-log/<key>/entry.json           status, headers, body byte count
///     response-log/<key>/body                raw response body
///     response-log/.pending/<uuid>/body      not yet committed
///     response-log/.staging/<uuid>/          commit staging area
///     response-log/.replacing/<uuid>/<key>/  old commit moved aside for a
///                                            same-key replacement
///
/// Eviction is by least recent use (a replay counts as use) until the total
/// body bytes are within the quota. A single response larger than the whole
/// quota is dropped rather than kept.
public actor ResponseLog: ResponseLogging {
    /// Root of one workspace (`Library/xl/<workspace_id>/`).
    public nonisolated let root: URL
    /// Body-byte quota of the log.
    public nonisolated let quotaBytes: Int

    private nonisolated let logDirectory: URL
    private nonisolated let pendingDirectory: URL
    private nonisolated let stagingDirectory: URL
    private nonisolated let replacingDirectory: URL
    private let fileManager = FileManager.default
    /// Test-only fault injection at the one non-atomic point of a same-key
    /// replacement: after the old commit is moved aside and before the staged
    /// commit is installed. Production leaves it `nil`.
    private var replacementInstallProbe: (@Sendable () throws -> Void)?
    /// Test-only fault injection for the rollback path. Production leaves it
    /// `nil`; a failure here must preserve the aside copy for startup recovery.
    private var replacementRestoreProbe: (@Sendable (ReplacementRestoreStep) throws -> Void)?

    /// Rollback points at which a filesystem operation can fail.
    enum ReplacementRestoreStep: Sendable, Equatable {
        /// Removing an unusable destination left by a failed install.
        case removeUnusableDestination
        /// Moving the aside backup back to the destination.
        case restoreBackup
    }

    private struct Pending {
        var key: String
        var status: Int
        var headers: [String: String]
        var nextSequence: UInt64
        var bodyBytes: Int
        var bodyURL: URL
        var handle: FileHandle?
    }

    private struct IndexEntry: Codable, Equatable {
        var key: String
        var status: Int
        var headers: [String: String]
        var bodyBytes: Int
        /// Monotonic access ordinal, highest is most recently used.
        var lastUsed: UInt64
        /// Number of replay deliveries. Optional so pre-receipt entry files
        /// decode as zero instead of failing.
        var deliveryCount: Int?
    }

    private struct IndexFile: Codable {
        var format: Int
        var accessCounter: UInt64
        var entries: [IndexEntry]
    }

    private var pending: [String: Pending] = [:]
    private var entries: [String: IndexEntry] = [:]
    private var accessCounter: UInt64 = 0
    private var bytes: Int = 0
    private var indexWriteFailures = 0

    public init(root: URL,
                quotaBytes: Int = ModelGatewayConfiguration.defaultResponseLogQuotaBytes) throws {
        self.root = root
        self.quotaBytes = max(0, quotaBytes)
        self.logDirectory = root.appendingPathComponent("response-log", isDirectory: true)
        self.pendingDirectory = logDirectory.appendingPathComponent(".pending", isDirectory: true)
        self.stagingDirectory = logDirectory.appendingPathComponent(".staging", isDirectory: true)
        self.replacingDirectory = logDirectory.appendingPathComponent(".replacing", isDirectory: true)
        try fileManager.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        // A same-key replacement moves the old commit aside before it installs
        // the staged one. Recover that crash window before discarding the
        // staging area, so the old or the fully installed new commit survives.
        // Keys whose destination is the installed replacement must not inherit
        // the displaced commit's LRU facts from the stale index below. Their
        // `.replacing` markers stay until the corrected facts are durable.
        let recovery = try Self.recoverInterruptedReplacements(
            logDirectory: logDirectory,
            fileManager: fileManager)
        // A fresh start owns the workspace: recordings that never finished
        // (process kill during streaming) are not replayable and must not
        // accumulate against the quota. `.replacing` is not wiped here: an
        // installed replacement keeps its marker until the next index write.
        for directory in [pendingDirectory, stagingDirectory] {
            if fileManager.fileExists(atPath: directory.path) {
                try? fileManager.removeItem(at: directory)
            }
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try fileManager.createDirectory(at: replacingDirectory, withIntermediateDirectories: true)
        let loaded = Self.loadIndex(from: logDirectory,
                                    installedReplacements: recovery.installedKeys,
                                    fileManager: fileManager)
        self.entries = loaded.entries
        self.accessCounter = loaded.accessCounter
        self.bytes = loaded.entries.values.reduce(0) { $0 + $1.bodyBytes }
        // A fresh ordinal assigned by `loadIndex` exists only in memory until
        // it is written. Persist it before clearing the replacement marker:
        // otherwise a second restart (with no replay/finish in between) would
        // merge the displaced response's facts from the stale index into the
        // installed replacement.
        if !loaded.freshKeys.isEmpty || !recovery.installedKeys.isEmpty {
            let persisted = Self.persistRecoveredFacts(
                freshKeys: loaded.freshKeys,
                installedKeys: recovery.installedKeys,
                entries: loaded.entries,
                accessCounter: loaded.accessCounter,
                logDirectory: logDirectory,
                fileManager: fileManager)
            if persisted {
                Self.removeReplacementMarkers(recovery.markers, fileManager: fileManager)
            } else {
                self.indexWriteFailures = 1
            }
        }
    }

    // MARK: - Recording

    public func begin(requestID: String, key: String, status: Int, headers: [String: String]) async throws {
        try Self.validateKey(key)
        guard pending[requestID] == nil else {
            throw ResponseLogError.duplicateRequest(requestID)
        }
        let pendingID = UUID().uuidString
        let directory = pendingDirectory.appendingPathComponent(pendingID, isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let bodyURL = directory.appendingPathComponent("body", isDirectory: false)
            guard fileManager.createFile(atPath: bodyURL.path, contents: nil) else {
                throw ResponseLogError.ioFailure
            }
            let handle = try FileHandle(forWritingTo: bodyURL)
            pending[requestID] = Pending(key: key,
                                         status: status,
                                         headers: Self.normalizedHeaders(headers),
                                         nextSequence: 0,
                                         bodyBytes: 0,
                                         bodyURL: bodyURL,
                                         handle: handle)
        } catch let error as ResponseLogError {
            throw error
        } catch {
            throw ResponseLogError.ioFailure
        }
    }

    public func append(_ entry: ResponseLogEntry) async throws {
        guard var recording = pending[entry.requestID] else {
            throw ResponseLogError.unknownRequest(entry.requestID)
        }
        guard entry.sequence == recording.nextSequence else {
            throw ResponseLogError.invalidSequence(expected: recording.nextSequence,
                                                   got: entry.sequence)
        }
        if !entry.body.isEmpty {
            do {
                try recording.handle?.write(contentsOf: entry.body)
            } catch {
                try? recording.handle?.close()
                try? fileManager.removeItem(at: recording.bodyURL.deletingLastPathComponent())
                pending.removeValue(forKey: entry.requestID)
                throw ResponseLogError.ioFailure
            }
        }
        recording.nextSequence &+= 1
        recording.bodyBytes += entry.body.count
        pending[entry.requestID] = recording
    }

    public func finish(requestID: String) async throws -> ResponseLogReceipt? {
        guard let recording = pending.removeValue(forKey: requestID) else {
            throw ResponseLogError.unknownRequest(requestID)
        }
        try? recording.handle?.close()
        let stagingID = UUID().uuidString
        let staging = stagingDirectory.appendingPathComponent(stagingID, isDirectory: true)
        let destination = logDirectory.appendingPathComponent(recording.key, isDirectory: true)
        let replacement = replacingDirectory.appendingPathComponent(UUID().uuidString,
                                                                    isDirectory: true)
        let backup = replacement.appendingPathComponent(recording.key, isDirectory: true)
        var oldMovedAside = false
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            let body = staging.appendingPathComponent("body", isDirectory: false)
            try fileManager.moveItem(at: recording.bodyURL, to: body)
            try? fileManager.removeItem(at: recording.bodyURL.deletingLastPathComponent())
            let metadata = IndexEntry(key: recording.key,
                                      status: recording.status,
                                      headers: recording.headers,
                                      bodyBytes: recording.bodyBytes,
                                      lastUsed: 0,
                                      deliveryCount: 0)
            try Self.makeEncoder().encode(metadata)
                .write(to: staging.appendingPathComponent("entry.json"), options: .atomic)
            // A same-key replacement must keep the old committed directory
            // until the staged one is actually installed. `removeItem` +
            // `moveItem` is two operations: a crash between them would lose
            // both copies. Move the old directory aside instead; startup
            // recovery restores it when the install did not complete.
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.createDirectory(at: replacement, withIntermediateDirectories: true)
                try fileManager.moveItem(at: destination, to: backup)
                oldMovedAside = true
            }
            try replacementInstallProbe?()
            try fileManager.moveItem(at: staging, to: destination)
            // Keep the old backup until the new commit has been accounted for
            // and its index write has succeeded below. If this process dies
            // after the install but before the index write, the surviving
            // `.replacing` directory tells startup that the destination is the
            // installed replacement, so it must not inherit the displaced
            // commit's LRU facts.
        } catch {
            try? fileManager.removeItem(at: staging)
            if oldMovedAside {
                // The install did not succeed: put the old commit back. A
                // successful `moveItem` is the only proof that the old commit
                // is restored; the mere presence of `destination` is not,
                // because a failed removal leaves an unusable directory there.
                // If either rollback step fails, leave `.replacing` intact for
                // the next startup instead of deleting the only committed copy.
                var destinationCleared = !fileManager.fileExists(atPath: destination.path)
                if !destinationCleared {
                    do {
                        try replacementRestoreProbe?(.removeUnusableDestination)
                        try fileManager.removeItem(at: destination)
                        destinationCleared = true
                    } catch {
                        destinationCleared = false
                    }
                }
                var restored = false
                if destinationCleared {
                    do {
                        try replacementRestoreProbe?(.restoreBackup)
                        try fileManager.moveItem(at: backup, to: destination)
                        restored = !fileManager.fileExists(atPath: backup.path)
                            && Self.committedEntry(at: destination, key: recording.key) != nil
                    } catch {
                        restored = false
                    }
                }
                if restored {
                    try? fileManager.removeItem(at: replacement)
                }
            } else {
                try? fileManager.removeItem(at: replacement)
            }
            throw ResponseLogError.ioFailure
        }

        accessCounter &+= 1
        if let previous = entries.removeValue(forKey: recording.key) {
            bytes -= previous.bodyBytes
        }
        entries[recording.key] = IndexEntry(key: recording.key,
                                            status: recording.status,
                                            headers: recording.headers,
                                            bodyBytes: recording.bodyBytes,
                                            lastUsed: accessCounter,
                                            deliveryCount: 0)
        bytes += recording.bodyBytes
        evictIfNeeded()
        let indexPersisted = persistIndex()
        let isRetained = entries[recording.key] != nil
        // A persisted index (or a dropped new commit) makes every backup for
        // this key stale. Clear all of them, not only the container created by
        // this call: an earlier failed index write may have left another
        // marker, and restoring it on the next start would resurrect an old or
        // already-evicted response. A failed index write with the new commit
        // retained keeps the markers as the recovery signal.
        if indexPersisted || !isRetained {
            removeReplacementMarkers(for: recording.key)
        }
        // `finish` is one actor call, so the retained check and the return are
        // atomic with the eviction above. A caller that sees a non-nil receipt
        // knows this commit was present when it returned; a nil receipt is the
        // bounded signal that the entry was dropped (typically a single
        // response larger than the whole quota).
        guard let retained = entries[recording.key] else { return nil }
        return ResponseLogReceipt(key: retained.key,
                                  status: retained.status,
                                  bodyBytes: retained.bodyBytes,
                                  lastUsed: 0,
                                  deliveryCount: 0)
    }

    public func abort(requestID: String) async {
        guard let recording = pending.removeValue(forKey: requestID) else { return }
        try? recording.handle?.close()
        try? fileManager.removeItem(at: recording.bodyURL.deletingLastPathComponent())
    }

    // MARK: - Replay and accounting

    public func replay(key: String) async -> ResponseLogReplay? {
        guard case .replay(let replay) = await deliver(key: key, offset: nil) else {
            return nil
        }
        return replay
    }

    public func replay(key: String, offset: Int) async -> ResponseLogResumeOutcome {
        await deliver(key: key, offset: offset)
    }

    public func receipt(key: String) async -> ResponseLogReceipt? {
        guard Self.isValidKey(key) else { return nil }
        let directory = logDirectory.appendingPathComponent(key, isDirectory: true)
        // Validate the complete body by its file attributes, not by reading
        // the whole body into memory: a quota-sized response would otherwise
        // peak at 128 MiB for a metadata-only receipt.
        guard let entry = Self.committedEntry(at: directory, key: key) else {
            return nil
        }
        return ResponseLogReceipt(key: key,
                                  status: entry.status,
                                  bodyBytes: entry.bodyBytes,
                                  lastUsed: entry.lastUsed,
                                  deliveryCount: entry.deliveryCount ?? 0)
    }

    public func totalBytes() async -> Int {
        bytes
    }

    /// Whether the LRU index file is currently in sync with the entries.
    ///
    /// A failed index write never affects committed responses; `finish` and
    /// `replay` retry the write, and a restart rebuilds the index by scanning
    /// the entry directories. Callers can surface a persisting failure instead
    /// of waiting for that restart.
    public func indexStatus() -> ResponseLogIndexStatus {
        ResponseLogIndexStatus(isPersisted: indexWriteFailures == 0,
                               consecutiveFailures: indexWriteFailures)
    }

    /// Removes every committed and pending entry. Used by host recovery.
    public func removeAll() async {
        for recording in pending.values {
            try? recording.handle?.close()
        }
        pending.removeAll()
        entries.removeAll()
        bytes = 0
        accessCounter = 0
        indexWriteFailures = 0
        try? fileManager.removeItem(at: logDirectory)
        try? fileManager.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: pendingDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: replacingDirectory, withIntermediateDirectories: true)
    }

    /// Content-addressed key of one gateway request.
    ///
    /// SHA-256 over method, absolute URL, the allow-listed request headers and
    /// the canonicalised body. Header names are compared case-insensitively;
    /// only names in `headerAllowList` participate, so volatile headers
    /// (`authorization`, traces, dates) never split the cache. A body that is
    /// JSON is canonicalised (sorted keys, no whitespace, no escaped slashes)
    /// before hashing.
    public nonisolated static func cacheKey(method: String,
                                            url: URL,
                                            headers: [String: String],
                                            body: Data,
                                            headerAllowList: Set<String>) -> String {
        var canonical = Data()
        canonical.append(Data("\(method.uppercased())\n".utf8))
        canonical.append(Data("\(canonicalURL(url).absoluteString)\n".utf8))
        let allowed = Set(headerAllowList.map { $0.lowercased() })
        let selected = headers
            .map { (name: $0.key.lowercased(), value: $0.value) }
            .filter { allowed.contains($0.name) }
            .sorted { $0.name < $1.name }
        for header in selected {
            let value = header.value.trimmingCharacters(in: .whitespaces)
            canonical.append(Data("\(header.name):\(value)\n".utf8))
        }
        canonical.append(Data("\n".utf8))
        canonical.append(canonicalBody(body))
        return GatewaySHA256.hexDigest(canonical)
    }

    /// Canonical body used by `cacheKey`: JSON bodies are re-encoded with
    /// sorted keys and no insignificant whitespace; every other body is hashed
    /// byte-for-byte.
    public nonisolated static func canonicalBody(_ body: Data) -> Data {
        guard !body.isEmpty else { return body }
        guard let object = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) else {
            return body
        }
        var options: JSONSerialization.WritingOptions = [.sortedKeys, .fragmentsAllowed]
        options.insert(.withoutEscapingSlashes)
        guard let encoded = try? JSONSerialization.data(withJSONObject: object, options: options) else {
            return body
        }
        return encoded
    }

    /// True when `value` is a lowercase 64-character hex key.
    public nonisolated static func isValidKey(_ value: String) -> Bool {
        guard value.count == 64 else { return false }
        return value.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x66)
        }
    }

    // MARK: - Private

    /// Validates the resume offset against the on-disk body size before any
    /// delivery accounting. Only the `.replay` outcome advances `lastUsed` and
    /// `deliveryCount`.
    private func deliver(key: String, offset: Int?) async -> ResponseLogResumeOutcome {
        guard Self.isValidKey(key), let entry = entries[key] else { return .missing }
        let directory = logDirectory.appendingPathComponent(key, isDirectory: true)
        let bodyURL = directory.appendingPathComponent("body", isDirectory: false)
        guard let bodyBytes = Self.bodySize(at: bodyURL),
              bodyBytes == entry.bodyBytes else {
            return .missing
        }
        if let offset {
            guard offset >= 0, offset <= bodyBytes else {
                return .offsetOutOfRange(bodyBytes: bodyBytes)
            }
        }
        guard let body = try? Data(contentsOf: bodyURL), body.count == entry.bodyBytes else {
            return .missing
        }
        accessCounter &+= 1
        var touched = entry
        touched.lastUsed = accessCounter
        touched.deliveryCount = (entry.deliveryCount ?? 0) + 1
        // The entry directory is the source of truth: a single committed
        // response proves its own delivery even when `index.json` is lost.
        // The index write below remains the LRU cache.
        try? writeEntryMetadata(touched)
        entries[key] = touched
        persistIndex()
        return .replay(ResponseLogReplay(key: key,
                                         status: entry.status,
                                         headers: entry.headers,
                                         body: body))
    }

    /// Test-only fault injection for the recoverable same-key replacement.
    internal func setReplacementInstallProbeForTesting(
        _ probe: (@Sendable () throws -> Void)?) {
        replacementInstallProbe = probe
    }

    /// Test-only fault injection for the replacement rollback path.
    internal func setReplacementRestoreProbeForTesting(
        _ probe: (@Sendable (ReplacementRestoreStep) throws -> Void)?) {
        replacementRestoreProbe = probe
    }

    /// Reads and validates one committed entry without loading its body.
    ///
    /// The regular-file check plus `fileSize == entry.bodyBytes` keeps the
    /// missing/truncated rejection of the old whole-body read while avoiding a
    /// quota-sized allocation for a metadata-only receipt.
    private nonisolated static func committedEntry(at directory: URL,
                                                   key: String) -> IndexEntry? {
        let metadataURL = directory.appendingPathComponent("entry.json", isDirectory: false)
        let bodyURL = directory.appendingPathComponent("body", isDirectory: false)
        guard let data = try? Data(contentsOf: metadataURL),
              let entry = try? JSONDecoder().decode(IndexEntry.self, from: data),
              entry.key == key,
              let bodyBytes = bodySize(at: bodyURL),
              bodyBytes == entry.bodyBytes else {
            return nil
        }
        return entry
    }

    private nonisolated static func bodySize(at url: URL) -> Int? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize else {
            return nil
        }
        return size
    }

    /// Recovers a same-key replacement interrupted between moving the old
    /// commit aside and installing the staged one.
    ///
    /// - destination valid: the install completed; keep one deterministic old
    ///   backup as the marker until the caller has persisted the corrected
    ///   index/entry facts.
    /// - destination missing/invalid and at least one backup valid: restore the
    ///   most recent valid old commit and remove every other backup.
    /// - neither valid: remove the unusable copies.
    ///
    /// The returned markers are removed only after the corrected facts are
    /// durable, so a second restart cannot merge the displaced response's LRU
    /// facts into the installed replacement. More than one backup for a key is
    /// never left behind: the newest valid one is chosen by a deterministic
    /// order, not by directory enumeration order.
    private nonisolated static func recoverInterruptedReplacements(
        logDirectory: URL,
        fileManager: FileManager) throws -> (installedKeys: Set<String>, markers: [URL]) {
        var installedKeys: Set<String> = []
        var markers: [URL] = []
        let replacing = logDirectory.appendingPathComponent(".replacing", isDirectory: true)
        guard fileManager.fileExists(atPath: replacing.path) else {
            return (installedKeys, markers)
        }
        let containers: [URL]
        do {
            containers = try fileManager.contentsOfDirectory(
                at: replacing,
                includingPropertiesForKeys: [.isDirectoryKey])
        } catch {
            // Do not let a later `.replacing` cleanup delete an unread backup.
            throw ResponseLogError.ioFailure
        }
        var candidatesByKey: [String: [(container: URL, child: URL)]] = [:]
        for container in containers {
            guard let containerValues = try? container.resourceValues(
                forKeys: [.isDirectoryKey]),
                  containerValues.isDirectory == true else {
                try? fileManager.removeItem(at: container)
                continue
            }
            let children: [URL]
            do {
                children = try fileManager.contentsOfDirectory(
                    at: container,
                    includingPropertiesForKeys: [.isDirectoryKey])
            } catch {
                throw ResponseLogError.ioFailure
            }
            for child in children {
                guard let childValues = try? child.resourceValues(
                    forKeys: [.isDirectoryKey]),
                      childValues.isDirectory == true else {
                    try? fileManager.removeItem(at: child)
                    continue
                }
                let key = child.lastPathComponent
                guard isValidKey(key) else {
                    try? fileManager.removeItem(at: child)
                    continue
                }
                candidatesByKey[key, default: []].append((container: container, child: child))
            }
        }
        var failed = false
        for key in candidatesByKey.keys.sorted() {
            guard let candidates = candidatesByKey[key] else { continue }
            let destination = logDirectory.appendingPathComponent(key, isDirectory: true)
            let destinationValid = committedEntry(at: destination, key: key) != nil
            let validBackups = candidates.filter {
                committedEntry(at: $0.child, key: key) != nil
            }
            if destinationValid {
                // The staged install completed. Keep exactly one marker until
                // the caller has persisted the corrected facts; every other
                // backup is stale and must not win a later recovery.
                installedKeys.insert(key)
                // Even a damaged leftover can serve as the marker that the
                // destination is an installed replacement; it is never used to
                // restore data while the destination is valid.
                if let newest = newestReplacement(validBackups) ?? newestReplacement(candidates) {
                    markers.append(newest)
                    for candidate in candidates where candidate.child.path != newest.path {
                        try? fileManager.removeItem(at: candidate.child)
                    }
                } else {
                    for candidate in candidates {
                        try? fileManager.removeItem(at: candidate.child)
                    }
                }
                continue
            }
            // The install did not complete. Remove an unusable destination and
            // restore the newest valid old commit, if any.
            if fileManager.fileExists(atPath: destination.path) {
                do {
                    try fileManager.removeItem(at: destination)
                } catch {
                    failed = true
                }
            }
            if let newest = newestReplacement(validBackups) {
                do {
                    try fileManager.moveItem(at: newest, to: destination)
                } catch {
                    failed = true
                }
                for candidate in candidates where candidate.child.path != newest.path {
                    try? fileManager.removeItem(at: candidate.child)
                }
            } else {
                for candidate in candidates {
                    try? fileManager.removeItem(at: candidate.child)
                }
            }
        }
        for container in containers {
            let remaining = (try? fileManager.contentsOfDirectory(
                at: container,
                includingPropertiesForKeys: nil)) ?? []
            if remaining.isEmpty {
                try? fileManager.removeItem(at: container)
            }
        }
        if failed {
            throw ResponseLogError.ioFailure
        }
        return (installedKeys, markers)
    }

    /// Deterministic newest backup: the container's modification time records
    /// when the old commit was moved aside, so it orders replacement attempts.
    /// The child time and then the path break ties, so directory read order
    /// never decides which old commit survives.
    private nonisolated static func newestReplacement(
        _ candidates: [(container: URL, child: URL)]) -> URL? {
        candidates.max { lhs, rhs in
            let leftContainer = modificationDate(of: lhs.container)
            let rightContainer = modificationDate(of: rhs.container)
            if leftContainer != rightContainer {
                return leftContainer < rightContainer
            }
            let leftChild = modificationDate(of: lhs.child)
            let rightChild = modificationDate(of: rhs.child)
            if leftChild != rightChild {
                return leftChild < rightChild
            }
            return lhs.child.path < rhs.child.path
        }.map { $0.child }
    }

    private nonisolated static func modificationDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
    }

    /// Removes the retained markers after the corrected facts have been
    /// persisted, together with any container they leave empty.
    private nonisolated static func removeReplacementMarkers(_ markers: [URL],
                                                             fileManager: FileManager) {
        var containers: Set<String> = []
        for marker in markers {
            try? fileManager.removeItem(at: marker)
            containers.insert(marker.deletingLastPathComponent().path)
        }
        for path in containers {
            let container = URL(fileURLWithPath: path, isDirectory: true)
            let remaining = (try? fileManager.contentsOfDirectory(
                at: container,
                includingPropertiesForKeys: nil)) ?? []
            if remaining.isEmpty {
                try? fileManager.removeItem(at: container)
            }
        }
    }

    private nonisolated static func canonicalURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.fragment = nil
        return components.url ?? url
    }

    private func evictIfNeeded() {
        guard quotaBytes >= 0 else { return }
        var blockedKeys: Set<String> = []
        while bytes > quotaBytes {
            guard let victim = entries.values
                .filter({ !blockedKeys.contains($0.key) })
                .min(by: { $0.lastUsed < $1.lastUsed }) else {
                break
            }
            let directory = logDirectory.appendingPathComponent(victim.key, isDirectory: true)
            // Remove the backups before the live directory: if their removal
            // fails, the live committed entry must remain the recovery source;
            // deleting it would let startup restore a stale backup. Skip this
            // victim and try the next LRU entry instead.
            guard removeReplacementMarkers(for: victim.key) else {
                blockedKeys.insert(victim.key)
                continue
            }
            do {
                if fileManager.fileExists(atPath: directory.path) {
                    try fileManager.removeItem(at: directory)
                }
            } catch {
                blockedKeys.insert(victim.key)
                continue
            }
            entries.removeValue(forKey: victim.key)
            bytes -= victim.bodyBytes
        }
    }

    /// Removes every `.replacing` backup for one key and any container it
    /// leaves empty. A stale marker for an evicted or replaced response must
    /// never be restored (and re-counted) on the next start.
    @discardableResult
    private func removeReplacementMarkers(for key: String) -> Bool {
        guard fileManager.fileExists(atPath: replacingDirectory.path) else { return true }
        let containers: [URL]
        do {
            containers = try fileManager.contentsOfDirectory(
                at: replacingDirectory,
                includingPropertiesForKeys: [.isDirectoryKey])
        } catch {
            return false
        }
        for container in containers {
            guard let values = try? container.resourceValues(forKeys: [.isDirectoryKey]),
                  values.isDirectory == true else {
                do {
                    try fileManager.removeItem(at: container)
                } catch {
                    return false
                }
                continue
            }
            let child = container.appendingPathComponent(key, isDirectory: true)
            if fileManager.fileExists(atPath: child.path) {
                do {
                    try fileManager.removeItem(at: child)
                } catch {
                    return false
                }
            }
            let remaining: [URL]
            do {
                remaining = try fileManager.contentsOfDirectory(
                    at: container,
                    includingPropertiesForKeys: nil)
            } catch {
                return false
            }
            if remaining.contains(where: { $0.lastPathComponent == key }) {
                return false
            }
            if remaining.isEmpty {
                // A leftover empty container cannot restore this key, so its
                // cleanup is best effort and does not block a safe eviction.
                try? fileManager.removeItem(at: container)
            }
        }
        return true
    }

    /// Atomically rewrites one committed entry's metadata, so the facts live
    /// beside the body instead of only in the shared LRU index.
    private func writeEntryMetadata(_ entry: IndexEntry) throws {
        let directory = logDirectory.appendingPathComponent(entry.key, isDirectory: true)
        let target = directory.appendingPathComponent("entry.json", isDirectory: false)
        let data = try Self.makeEncoder().encode(entry)
        try data.write(to: target, options: .atomic)
    }

    /// Makes the ordinals assigned during startup recovery durable before the
    /// `.replacing` markers are cleared. A failure keeps the markers so the
    /// next start repeats the correction instead of merging the displaced
    /// response's facts into the installed one.
    private nonisolated static func persistRecoveredFacts(
        freshKeys: Set<String>,
        installedKeys: Set<String>,
        entries: [String: IndexEntry],
        accessCounter: UInt64,
        logDirectory: URL,
        fileManager: FileManager) -> Bool {
        var metadataPersisted = true
        for key in freshKeys.union(installedKeys) {
            guard let entry = entries[key] else { continue }
            let directory = logDirectory.appendingPathComponent(key, isDirectory: true)
            let target = directory.appendingPathComponent("entry.json", isDirectory: false)
            guard let data = try? makeEncoder().encode(entry) else {
                metadataPersisted = false
                continue
            }
            do {
                try data.write(to: target, options: .atomic)
            } catch {
                metadataPersisted = false
            }
        }
        let indexPersisted = persistIndex(entries: entries,
                                          accessCounter: accessCounter,
                                          logDirectory: logDirectory,
                                          fileManager: fileManager)
        return metadataPersisted && indexPersisted
    }

    /// Atomically rewrites `index.json`. Shared by the runtime actor method and
    /// startup recovery, which must persist a corrected index before releasing
    /// a replacement marker.
    private nonisolated static func persistIndex(entries: [String: IndexEntry],
                                                 accessCounter: UInt64,
                                                 logDirectory: URL,
                                                 fileManager: FileManager) -> Bool {
        let index = IndexFile(format: 1,
                              accessCounter: accessCounter,
                              entries: entries.values.sorted { $0.key < $1.key })
        guard let data = try? makeEncoder().encode(index) else { return false }
        let target = logDirectory.appendingPathComponent("index.json", isDirectory: false)
        let temporary = logDirectory.appendingPathComponent("index.json.tmp", isDirectory: false)
        // Retry once immediately: most failures are transient (a racing
        // directory scan, a momentary disk error), and the next `finish` or
        // `replay` tries again. `indexStatus()` reports a persistent failure.
        for attempt in 0..<2 {
            do {
                try data.write(to: temporary, options: .atomic)
                if fileManager.fileExists(atPath: target.path) {
                    try fileManager.removeItem(at: target)
                }
                try fileManager.moveItem(at: temporary, to: target)
                return true
            } catch {
                if attempt == 0 { continue }
            }
        }
        // The index is a cache of the directory contents, never the source of
        // truth: a failed write is repaired by the next successful write or on
        // the next start by scanning `response-log/<key>/entry.json`.
        return false
    }

    @discardableResult
    private func persistIndex() -> Bool {
        let persisted = Self.persistIndex(entries: entries,
                                          accessCounter: accessCounter,
                                          logDirectory: logDirectory,
                                          fileManager: fileManager)
        if persisted {
            indexWriteFailures = 0
        } else {
            indexWriteFailures += 1
        }
        return persisted
    }

    private nonisolated static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// Loads committed entries from the index and reconciles them with the
    /// directory: a crash between the entry rename and the index write is
    /// repaired by scanning, and an entry whose body is missing is dropped.
    ///
    /// `installedReplacements` are keys whose same-key replacement was already
    /// installed before the crash. The stale index still describes the
    /// displaced commit, so those entries must not inherit its `lastUsed` or
    /// `deliveryCount`; a fresh `lastUsed: 0` replacement receives a new
    /// ordinal above the counter so quota eviction cannot prefer the old one.
    private nonisolated static func loadIndex(from directory: URL,
                                              installedReplacements: Set<String>,
                                              fileManager: FileManager) -> (entries: [String: IndexEntry],
                                                                            accessCounter: UInt64,
                                                                            freshKeys: Set<String>) {
        var counter: UInt64 = 0
        var freshKeys: Set<String> = []
        var indexed: [String: IndexEntry] = [:]
        let indexURL = directory.appendingPathComponent("index.json", isDirectory: false)
        if let data = try? Data(contentsOf: indexURL),
           let index = try? JSONDecoder().decode(IndexFile.self, from: data),
           index.format == 1 {
            counter = index.accessCounter
            for entry in index.entries where isValidKey(entry.key) {
                indexed[entry.key] = entry
                counter = max(counter, entry.lastUsed)
            }
        }

        var entries: [String: IndexEntry] = [:]
        let children = (try? fileManager.contentsOfDirectory(at: directory,
                                                             includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for child in children {
            let key = child.lastPathComponent
            guard isValidKey(key),
                  var entry = committedEntry(at: child, key: key) else { continue }
            if let known = indexed[key], !installedReplacements.contains(key) {
                // The index is only a cache: merge it with the facts stored
                // beside the body, so neither a stale index nor a missing one
                // loses the last-use ordinal or the delivery count.
                entry.lastUsed = max(entry.lastUsed, known.lastUsed)
                entry.deliveryCount = max(entry.deliveryCount ?? 0,
                                          known.deliveryCount ?? 0)
            } else {
                entry.deliveryCount = entry.deliveryCount ?? 0
            }
            // Advance the ordinal from every entry, not only the ones absent
            // from the index: a process killed between a `replay` entry-file
            // rewrite and the index write leaves `entry.json` ahead of the
            // cached `accessCounter`. Restarting with the stale counter would
            // let the next replay overwrite a newer ordinal with an older one.
            counter = max(counter, entry.lastUsed)
            entries[key] = entry
        }
        // `finish` writes the write-once entry file with `lastUsed: 0`, then
        // commits the LRU ordinal to `index.json`. A crash (or a failed index
        // write) between those two steps leaves a committed response that the
        // stale index does not know and whose entry file has no ordinal yet.
        // Giving it an ordinal above every known fact keeps it newer than the
        // genuinely older entries, so quota eviction cannot drop the fresh
        // commit first. Replay-written `lastUsed > 0` facts are preserved.
        let unindexedFresh = entries.keys
            .filter { key in
                guard entries[key]?.lastUsed == 0 else { return false }
                return indexed[key] == nil || installedReplacements.contains(key)
            }
            .sorted()
        for key in unindexedFresh {
            guard var entry = entries[key] else { continue }
            counter &+= 1
            entry.lastUsed = counter
            entries[key] = entry
            freshKeys.insert(key)
        }
        return (entries, counter, freshKeys)
    }

    private nonisolated static func normalizedHeaders(_ headers: [String: String]) -> [String: String] {
        var normalized: [String: String] = [:]
        for (name, value) in headers {
            normalized[name.lowercased()] = value
        }
        return normalized
    }

    private nonisolated static func validateKey(_ key: String) throws {
        guard isValidKey(key) else { throw ResponseLogError.invalidKey }
    }
}
