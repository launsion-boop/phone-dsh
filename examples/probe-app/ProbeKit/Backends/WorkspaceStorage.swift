// SPDX-License-Identifier: MIT
// P18 persistence for the two-workspace drawer (D2).
//
// All legacy phone keys are bare session IDs. A PC workspace can reuse the same
// DSH session ID, so every session-scoped value moves to
// `<BackendID.storageScope>|<sessionID>` (`phone|…`, `pc:<machineId>|…`). The
// migration is a one-time, non-destructive copy: legacy keys and snapshot files
// stay in place so rolling the build back still reads the old state. New writes
// only go to the scoped keys; the migration marker makes a second run a no-op.
//
// This file is compiled into ProbeKit so PhoneDSHSimTests can drive the real
// migration with an isolated UserDefaults suite and a temporary Documents
// directory. Key names and the `phone-dsh.drawer.backend` value domain are P18
// contract (spec/README.md §3.1 P18, change record
// docs/protocol-changes/PC-20261110-pclink-ios-app.md).

import Foundation

public enum WorkspaceStorageKeys {
    // P18: drawer backend selection. Closed domain "phone" | "pc", default "phone".
    public static let drawerBackend = "phone-dsh.drawer.backend"

    // Legacy bare-sessionID stores (read-only after migration; never deleted).
    public static let legacyCurrentSession = "chat.dsh.currentSessionID"
    public static let legacyDrafts = "chat.drafts.v1"
    public static let legacyTitleHints = "phone-dsh.session.title-hints"
    public static let legacyCollapsedWorkspaces = "phone-dsh.sidebar.collapsed-workspaces"

    // Scoped stores (D2).
    public static let currentSessionPrefix = "chat.dsh.currentSession."
    public static let drafts = "chat.drafts.v2"
    public static let titleHints = "phone-dsh.session.title-hints.v2"
    public static let collapsedWorkspaces = "phone-dsh.sidebar.collapsed-workspaces.v2"

    /// Set to true by the one-time migration. Not a feature flag.
    public static let scopeMigrationMarker = "phone-dsh.storage.scope-migration.v1"

    /// P18 (pclink-pacing): the last DSH workspace the user chose for a new PC
    /// session, one key per paired PC machine. Value: one workspaceId string.
    public static let pcLastWorkspacePrefix = "phone-dsh.pc.last-workspace."

    public static func pcLastWorkspace(for backend: BackendID) -> String? {
        guard case .pc(let machineId) = backend, !machineId.isEmpty else { return nil }
        return pcLastWorkspacePrefix + machineId
    }

    /// Content fingerprints → DSH requestId. Kept unscoped on disk; the
    /// fingerprint itself carries the backend scope and session ID.
    public static let retryableRequestIDs = "chat.dsh.retryableRequestIDs"

    /// The phone's session-list snapshot. Bare `ChatSessionSnapshot` value; it
    /// is not migrated so a rollback keeps reading it
    /// (PC-20261110-pclink-pc-roster-snapshot).
    public static let phoneSessionSnapshot = "dsh.management.sessionSnapshot.v1"

    /// The PC's session-list snapshot, one key per paired machine. The value is
    /// a `CachedSessionSnapshotEnvelope`; readers also accept the bare format.
    public static let pcSessionSnapshotPrefix = "phone-dsh.pc.session-snapshot."

    /// The roster-cache key for one backend. The phone keeps its historical
    /// key; a PC is scoped by machineId so two computers cannot share rows.
    public static func sessionSnapshotKey(for backend: BackendID) -> String {
        switch backend {
        case .phone: return phoneSessionSnapshot
        case .pc(let machineId): return pcSessionSnapshotPrefix + machineId
        }
    }

    public static func currentSession(for backend: BackendID) -> String {
        currentSessionPrefix + backend.storageScope
    }
}

/// A persisted session-scoped key: `(BackendID, sessionID)`.
public struct SessionStorageKey: Hashable, Codable, Sendable {
    public var backend: BackendID
    public var sessionID: String

    public init(backend: BackendID, sessionID: String) {
        self.backend = backend
        self.sessionID = sessionID
    }

    /// DSH session IDs are server-issued and do not contain `|`; a synthetic
    /// `new` key is used by the composer before the first turn.
    public var encoded: String { "\(backend.storageScope)|\(sessionID)" }

    public init?(encoded: String) {
        guard let separator = encoded.firstIndex(of: "|") else { return nil }
        let scope = String(encoded[..<separator])
        let sessionID = String(encoded[encoded.index(after: separator)...])
        guard !sessionID.isEmpty else { return nil }
        if scope == "phone" {
            backend = .phone
        } else if scope.hasPrefix("pc:"), scope.count > 3 {
            backend = .pc(machineId: String(scope.dropFirst(3)))
        } else {
            return nil
        }
        self.sessionID = sessionID
    }
}

/// The P18 drawer selection. Unknown stored values (including a future "multi")
/// read as `.phone`; writing only ever writes the two closed values.
public enum DrawerBackendSetting: String, Sendable, CaseIterable {
    case phone
    case pc

    public static let `default`: DrawerBackendSetting = .phone

    public static func load(from defaults: UserDefaults = .standard) -> DrawerBackendSetting {
        guard let raw = defaults.string(forKey: WorkspaceStorageKeys.drawerBackend),
              let value = DrawerBackendSetting(rawValue: raw) else {
            return .default
        }
        return value
    }

    public static func save(_ value: DrawerBackendSetting,
                            to defaults: UserDefaults = .standard) {
        defaults.set(value.rawValue, forKey: WorkspaceStorageKeys.drawerBackend)
    }
}

public struct WorkspaceStorageMigrationReport: Equatable, Sendable {
    public var alreadyMigrated = false
    public var currentSession = false
    public var drafts = 0
    public var titleHints = 0
    public var collapsedWorkspaces = 0
    public var snapshots = 0

    public var didChange: Bool {
        currentSession || drafts > 0 || titleHints > 0
            || collapsedWorkspaces > 0 || snapshots > 0
    }
}

/// One-time migration from the bare sessionID keys to `phone|…` scoped keys.
public enum WorkspaceStorageMigration {
    /// Runs the migration unless the marker is already set. Idempotent:
    /// re-running under `force` copies only missing values.
    @discardableResult
    public static func runIfNeeded(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        documentsDirectory: URL? = nil,
        force: Bool = false
    ) -> WorkspaceStorageMigrationReport {
        var report = WorkspaceStorageMigrationReport()
        if defaults.bool(forKey: WorkspaceStorageKeys.scopeMigrationMarker), !force {
            report.alreadyMigrated = true
            return report
        }

        // 1. Current session: old bare value becomes the phone scope's value.
        let phoneCurrentKey = WorkspaceStorageKeys.currentSession(for: .phone)
        if let legacy = defaults.string(forKey: WorkspaceStorageKeys.legacyCurrentSession),
           !legacy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           defaults.string(forKey: phoneCurrentKey) == nil {
            defaults.set(legacy, forKey: phoneCurrentKey)
            report.currentSession = true
        }

        // 2. drafts [sessionID: draft] → [phone|sessionID: draft].
        let legacyDrafts = WorkspaceStorage.legacyDraftsMap(defaults: defaults)
        if !legacyDrafts.isEmpty {
            var scoped = defaults.dictionary(forKey: WorkspaceStorageKeys.drafts) as? [String: String] ?? [:]
            for (sessionID, draft) in legacyDrafts.sorted(by: { $0.key < $1.key }) {
                guard !sessionID.isEmpty else { continue }
                let key = SessionStorageKey(backend: .phone, sessionID: sessionID).encoded
                if scoped[key] == nil {
                    scoped[key] = draft
                    report.drafts += 1
                }
            }
            if report.drafts > 0 {
                defaults.set(scoped, forKey: WorkspaceStorageKeys.drafts)
            }
        }

        // 3. title hints [sessionID: title] → [phone|sessionID: title].
        if let legacy = defaults.dictionary(forKey: WorkspaceStorageKeys.legacyTitleHints) as? [String: String],
           !legacy.isEmpty {
            var scoped = defaults.dictionary(forKey: WorkspaceStorageKeys.titleHints) as? [String: String] ?? [:]
            for (sessionID, title) in legacy.sorted(by: { $0.key < $1.key }) {
                guard !sessionID.isEmpty else { continue }
                let key = SessionStorageKey(backend: .phone, sessionID: sessionID).encoded
                if scoped[key] == nil {
                    scoped[key] = title
                    report.titleHints += 1
                }
            }
            if report.titleHints > 0 {
                defaults.set(scoped, forKey: WorkspaceStorageKeys.titleHints)
            }
        }

        // 4. collapsed folder IDs [workspaceID] → [phone|workspaceID].
        if let legacy = defaults.stringArray(forKey: WorkspaceStorageKeys.legacyCollapsedWorkspaces),
           !legacy.isEmpty {
            var scoped = defaults.stringArray(forKey: WorkspaceStorageKeys.collapsedWorkspaces) ?? []
            let existing = Set(scoped)
            var appended: [String] = []
            for workspaceID in legacy where !workspaceID.isEmpty {
                let key = SessionStorageKey(backend: .phone, sessionID: workspaceID).encoded
                if !existing.contains(key) {
                    appended.append(key)
                }
            }
            if !appended.isEmpty {
                scoped.append(contentsOf: appended)
                defaults.set(scoped, forKey: WorkspaceStorageKeys.collapsedWorkspaces)
                report.collapsedWorkspaces = appended.count
            }
        }

        // 5. transcript snapshot files: copy (not move) `snapshots/<id>.json`
        // into `snapshots/phone/<id>.json` so a rollback still finds the old
        // file at the legacy path. The scoped copy is what new code reads.
        if let documents = documentsDirectory ?? defaultDocumentsDirectory(fileManager),
           let legacyFiles = try? fileManager.contentsOfDirectory(
               at: documents.appendingPathComponent("transcript-snapshots", isDirectory: true),
               includingPropertiesForKeys: [.isRegularFileKey],
               options: [.skipsHiddenFiles]) {
            let scopedDirectory = WorkspaceStorage.transcriptsDirectory(
                for: .phone,
                documentsDirectory: documents,
                fileManager: fileManager)
            for source in legacyFiles where source.pathExtension == "json" {
                guard (try? source.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
                    continue
                }
                let destination = scopedDirectory.appendingPathComponent(source.lastPathComponent)
                guard !fileManager.fileExists(atPath: destination.path) else { continue }
                // Data.write(.atomic) writes a sibling temp file and renames
                // it, so a crash never leaves a partial snapshot behind.
                if let data = try? Data(contentsOf: source),
                   (try? data.write(to: destination, options: .atomic)) != nil {
                    report.snapshots += 1
                }
            }
        }

        defaults.set(true, forKey: WorkspaceStorageKeys.scopeMigrationMarker)
        return report
    }

    private static func defaultDocumentsDirectory(_ fileManager: FileManager) -> URL? {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
    }
}

/// Typed readers/writers over the scoped keys. The views and ChatModel use these
/// instead of open-coding `UserDefaults` keys, so the scope prefix is applied
/// exactly once.
public enum WorkspaceStorage {
    /// The legacy `chat.drafts.v1` value was written by `@AppStorage` as a JSON
    /// **string**. A dictionary is accepted as a compatibility fallback for
    /// early builds, but the string form is authoritative.
    static func legacyDraftsMap(defaults: UserDefaults) -> [String: String] {
        if let raw = defaults.string(forKey: WorkspaceStorageKeys.legacyDrafts),
           let data = raw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            return decoded
        }
        if let legacy = defaults.dictionary(forKey: WorkspaceStorageKeys.legacyDrafts)
            as? [String: String] {
            return legacy
        }
        return [:]
    }

    /// Legacy bare keys are a pre-migration fallback only. Once the one-time
    /// marker is set, a value the new code deliberately cleared must not be
    /// resurrected from the old key.
    static func legacyFallbackAllowed(defaults: UserDefaults) -> Bool {
        !defaults.bool(forKey: WorkspaceStorageKeys.scopeMigrationMarker)
    }

    // MARK: Current session

    public static func currentSessionID(for backend: BackendID,
                                        defaults: UserDefaults = .standard) -> String? {
        if let scoped = defaults.string(forKey: WorkspaceStorageKeys.currentSession(for: backend)),
           !scoped.isEmpty {
            return scoped
        }
        // Phone read fallback for builds that have not run the migration yet
        // (or when the marker was cleared). PC never reads the bare key: it is
        // the phone's session and could collide.
        if backend == .phone,
           legacyFallbackAllowed(defaults: defaults),
           let legacy = defaults.string(forKey: WorkspaceStorageKeys.legacyCurrentSession),
           !legacy.isEmpty {
            return legacy
        }
        return nil
    }

    public static func setCurrentSessionID(_ sessionID: String?,
                                           for backend: BackendID,
                                           defaults: UserDefaults = .standard) {
        let key = WorkspaceStorageKeys.currentSession(for: backend)
        if let sessionID, !sessionID.isEmpty {
            defaults.set(sessionID, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: Drafts

    public static func draftKey(backend: BackendID, sessionID: String?) -> String {
        SessionStorageKey(backend: backend, sessionID: sessionID ?? "new").encoded
    }

    public static func draft(for backend: BackendID,
                             sessionID: String?,
                             defaults: UserDefaults = .standard) -> String? {
        let key = draftKey(backend: backend, sessionID: sessionID)
        let scoped = draftsMap(defaults: defaults)
        if let value = scoped[key] { return value }
        // Pre-migration previews/tests: the legacy map is only the phone's.
        if backend == .phone, legacyFallbackAllowed(defaults: defaults) {
            let legacy = legacyDraftsMap(defaults: defaults)
            if let value = legacy[sessionID ?? "new"] { return value }
        }
        return nil
    }

    public static func setDraft(_ draft: String,
                                for backend: BackendID,
                                sessionID: String?,
                                defaults: UserDefaults = .standard) {
        var map = draftsMap(defaults: defaults)
        let key = draftKey(backend: backend, sessionID: sessionID)
        if draft.isEmpty {
            map[key] = nil
        } else {
            map[key] = draft
        }
        defaults.set(map, forKey: WorkspaceStorageKeys.drafts)
    }

    public static func draftsMap(defaults: UserDefaults = .standard) -> [String: String] {
        defaults.dictionary(forKey: WorkspaceStorageKeys.drafts) as? [String: String] ?? [:]
    }

    // MARK: Title hints

    public static func titleHintKey(backend: BackendID, sessionID: String) -> String {
        SessionStorageKey(backend: backend, sessionID: sessionID).encoded
    }

    public static func titleHints(for backend: BackendID,
                                  defaults: UserDefaults = .standard) -> [String: String] {
        let scopePrefix = backend.storageScope + "|"
        let map = defaults.dictionary(forKey: WorkspaceStorageKeys.titleHints) as? [String: String] ?? [:]
        var result: [String: String] = [:]
        for (key, value) in map where key.hasPrefix(scopePrefix) {
            result[String(key.dropFirst(scopePrefix.count))] = value
        }
        if result.isEmpty, backend == .phone,
           legacyFallbackAllowed(defaults: defaults),
           let legacy = defaults.dictionary(forKey: WorkspaceStorageKeys.legacyTitleHints) as? [String: String] {
            return legacy
        }
        return result
    }

    public static func setTitleHint(_ title: String,
                                    for backend: BackendID,
                                    sessionID: String,
                                    defaults: UserDefaults = .standard) {
        var map = defaults.dictionary(forKey: WorkspaceStorageKeys.titleHints) as? [String: String] ?? [:]
        map[titleHintKey(backend: backend, sessionID: sessionID)] = title
        defaults.set(map, forKey: WorkspaceStorageKeys.titleHints)
    }

    public static func removeTitleHints(for backend: BackendID,
                                        sessionIDs: [String],
                                        defaults: UserDefaults = .standard) {
        var map = defaults.dictionary(forKey: WorkspaceStorageKeys.titleHints) as? [String: String] ?? [:]
        for sessionID in sessionIDs {
            map[titleHintKey(backend: backend, sessionID: sessionID)] = nil
        }
        defaults.set(map, forKey: WorkspaceStorageKeys.titleHints)
    }

    // MARK: Collapsed folders

    public static func collapsedWorkspaceIDs(for backend: BackendID,
                                             defaults: UserDefaults = .standard) -> Set<String> {
        let scopePrefix = backend.storageScope + "|"
        let values = defaults.stringArray(forKey: WorkspaceStorageKeys.collapsedWorkspaces) ?? []
        let scoped = values.compactMap { encoded -> String? in
            guard encoded.hasPrefix(scopePrefix) else { return nil }
            return String(encoded.dropFirst(scopePrefix.count))
        }
        if scoped.isEmpty, backend == .phone, legacyFallbackAllowed(defaults: defaults) {
            return Set(defaults.stringArray(forKey: WorkspaceStorageKeys.legacyCollapsedWorkspaces) ?? [])
        }
        return Set(scoped)
    }

    public static func setCollapsedWorkspaceIDs(_ ids: Set<String>,
                                                for backend: BackendID,
                                                defaults: UserDefaults = .standard) {
        var values = defaults.stringArray(forKey: WorkspaceStorageKeys.collapsedWorkspaces) ?? []
        let scopePrefix = backend.storageScope + "|"
        values.removeAll { $0.hasPrefix(scopePrefix) }
        values.append(contentsOf: ids.map { SessionStorageKey(backend: backend, sessionID: $0).encoded }.sorted())
        defaults.set(values.sorted(), forKey: WorkspaceStorageKeys.collapsedWorkspaces)
    }

    // MARK: PC new-session workspace (pclink-pacing, P18)

    /// The last workspace chosen for a new PC session. The phone backend never
    /// reads or writes this key (it has one workspace).
    public static func lastWorkspaceID(for backend: BackendID,
                                       defaults: UserDefaults = .standard) -> String? {
        guard let key = WorkspaceStorageKeys.pcLastWorkspace(for: backend) else { return nil }
        let raw = defaults.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (raw?.isEmpty ?? true) ? nil : raw
    }

    public static func setLastWorkspaceID(_ workspaceID: String?,
                                          for backend: BackendID,
                                          defaults: UserDefaults = .standard) {
        guard let key = WorkspaceStorageKeys.pcLastWorkspace(for: backend) else { return }
        let trimmed = workspaceID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            defaults.set(trimmed, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: Transcript snapshots

    /// The DSH sessionId charset. A PC-issued id is concatenated into a file
    /// name, so `/`, `..` and every other path metacharacter is rejected before
    /// the write (§P18).
    public static func isValidSessionID(_ sessionID: String) -> Bool {
        let bytes = Array(sessionID.utf8)
        guard (1...128).contains(bytes.count), sessionID != ".", sessionID != ".." else {
            return false
        }
        return bytes.allSatisfy { byte in
            (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                || (byte >= 0x30 && byte <= 0x39) || byte == 0x2E || byte == 0x5F
                || byte == 0x3A || byte == 0x2D
        }
    }

    /// Removes the local data owned by one backend when the user confirms the
    /// pairing record deletion: scoped drafts and transcript snapshots. The
    /// legacy/unscoped phone data and every other backend's scope are untouched.
    public static func removeLocalData(for backend: BackendID,
                                       defaults: UserDefaults = .standard,
                                       documentsDirectory: URL? = nil,
                                       fileManager: FileManager = .default) {
        let prefix = backend.storageScope + "|"
        var drafts = draftsMap(defaults: defaults)
        drafts = drafts.filter { !$0.key.hasPrefix(prefix) }
        defaults.set(drafts, forKey: WorkspaceStorageKeys.drafts)
        if let documents = documentsDirectory ?? defaultDocumentsDirectory(fileManager) {
            let directory = transcriptsDirectoryURL(for: backend,
                                                    documentsDirectory: documents)
            try? fileManager.removeItem(at: directory)
        }
        if documentsDirectory == nil, let caches = defaultCachesDirectory(fileManager) {
            let directory = caches
                .appendingPathComponent("pdsh", isDirectory: true)
                .appendingPathComponent("transcript-snapshots", isDirectory: true)
                .appendingPathComponent(backend.storageScope, isDirectory: true)
            try? fileManager.removeItem(at: directory)
        }
        setLastWorkspaceID(nil, for: backend, defaults: defaults)
        // The roster cache describes the removed pairing; a stale list must not
        // come back if the same machine is paired again later.
        defaults.removeObject(forKey: WorkspaceStorageKeys.sessionSnapshotKey(for: backend))
    }

    private static func defaultDocumentsDirectory(_ fileManager: FileManager) -> URL? {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    private static func defaultCachesDirectory(_ fileManager: FileManager) -> URL? {
        fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
    }

    /// Production snapshots are derived and rebuildable, so they live under
    /// `Library/Caches/pdsh/transcript-snapshots/<scope>`. A test or caller
    /// that passes an explicit documents directory keeps the historical path;
    /// the old build can still read its files there.
    private static func productionTranscriptsDirectory(for backend: BackendID,
                                                       fileManager: FileManager) -> URL? {
        guard let caches = defaultCachesDirectory(fileManager) else { return nil }
        let directory = caches
            .appendingPathComponent("pdsh", isDirectory: true)
            .appendingPathComponent("transcript-snapshots", isDirectory: true)
            .appendingPathComponent(backend.storageScope, isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Copies (never moves) legacy snapshots into the cache tree. Re-entrant:
    /// a file already present in the cache is left alone, and the old copy is
    /// retained for rollback until the normal eviction bound removes it.
    private static func migrateTranscriptSnapshotsIfNeeded(
        for backend: BackendID,
        documentsDirectory: URL?,
        fileManager: FileManager) {
        guard let documents = documentsDirectory ?? defaultDocumentsDirectory(fileManager),
              let destination = productionTranscriptsDirectory(for: backend,
                                                               fileManager: fileManager) else {
            return
        }
        let legacy = transcriptsDirectoryURL(for: backend, documentsDirectory: documents)
        guard let files = try? fileManager.contentsOfDirectory(at: legacy,
                                                               includingPropertiesForKeys: nil,
                                                               options: [.skipsHiddenFiles]) else {
            return
        }
        for source in files where source.pathExtension == "json" {
            let target = destination.appendingPathComponent(source.lastPathComponent)
            guard !fileManager.fileExists(atPath: target.path),
                  let data = try? Data(contentsOf: source) else { continue }
            _ = try? data.write(to: target, options: .atomic)
        }
    }

    private static func transcriptsDirectoryURL(for backend: BackendID,
                                                documentsDirectory: URL) -> URL {
        documentsDirectory
            .appendingPathComponent("transcript-snapshots", isDirectory: true)
            .appendingPathComponent(backend.storageScope, isDirectory: true)
    }

    public static func transcriptsDirectory(for backend: BackendID,
                                            documentsDirectory: URL,
                                            fileManager: FileManager = .default) -> URL {
        let directory = transcriptsDirectoryURL(for: backend,
                                                documentsDirectory: documentsDirectory)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    public static func transcriptSnapshotURL(for backend: BackendID,
                                             sessionID: String,
                                             documentsDirectory: URL? = nil,
                                             fileManager: FileManager = .default) -> URL? {
        guard isValidSessionID(sessionID) else { return nil }
        if let documentsDirectory {
            return transcriptsDirectory(for: backend,
                                        documentsDirectory: documentsDirectory,
                                        fileManager: fileManager)
                .appendingPathComponent("\(sessionID).json")
        }
        migrateTranscriptSnapshotsIfNeeded(for: backend,
                                           documentsDirectory: nil,
                                           fileManager: fileManager)
        guard let directory = productionTranscriptsDirectory(for: backend,
                                                             fileManager: fileManager) else {
            return nil
        }
        return directory.appendingPathComponent("\(sessionID).json")
    }

    /// The interrupted-stream draft lives beside the transcript snapshot and
    /// shares its scope/backup rules. The distinct suffix keeps it out of the
    /// snapshot eviction count and makes a stale draft easy to identify.
    public static func streamDraftURL(for backend: BackendID,
                                      sessionID: String,
                                      documentsDirectory: URL? = nil,
                                      fileManager: FileManager = .default) -> URL? {
        guard isValidSessionID(sessionID) else { return nil }
        let documents = documentsDirectory
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return transcriptsDirectory(for: backend,
                                    documentsDirectory: documents,
                                    fileManager: fileManager)
            .appendingPathComponent("\(sessionID).draft.json")
    }

    /// Removes one session's local cache files: its snapshot and its
    /// interrupted-stream draft. Used when the App removes a session (archive)
    /// or a caller explicitly drops the local tail.
    public static func removeTranscriptArtifacts(for backend: BackendID,
                                                 sessionID: String,
                                                 documentsDirectory: URL? = nil,
                                                 fileManager: FileManager = .default) {
        for url in [transcriptSnapshotURL(for: backend, sessionID: sessionID,
                                          documentsDirectory: documentsDirectory,
                                          fileManager: fileManager),
                    streamDraftURL(for: backend, sessionID: sessionID,
                                   documentsDirectory: documentsDirectory,
                                   fileManager: fileManager)]
        .compactMap({ $0 }) {
            try? fileManager.removeItem(at: url)
        }
    }

    /// Marks the snapshot tree as rebuildable local data so it is never part of
    /// an iCloud or Finder backup (P05/P17 backup attributes, P18 cache).
    public static func excludeFromBackup(_ url: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var target = url
        try? target.setResourceValues(values)
    }

    /// Keeps the transcript cache bounded: one file per session and at most
    /// `limit` files overall. `currentSessionID` is never evicted, so reopening
    /// the same session always has a tail to paint even when it is older than
    /// the other cached sessions. Eviction runs off the main thread.
    public static func evictTranscriptSnapshots(for backend: BackendID,
                                                documentsDirectory: URL? = nil,
                                                fileManager: FileManager = .default,
                                                keeping currentSessionID: String? = nil,
                                                limit: Int = 200) {
        guard limit > 0 else { return }
        let directory: URL
        if let documentsDirectory {
            directory = transcriptsDirectoryURL(for: backend,
                                                documentsDirectory: documentsDirectory)
        } else if let cacheDirectory = productionTranscriptsDirectory(for: backend,
                                                                      fileManager: fileManager) {
            directory = cacheDirectory
        } else {
            return
        }
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let entries = try? fileManager.contentsOfDirectory(at: directory,
                                                                 includingPropertiesForKeys: keys,
                                                                 options: [.skipsHiddenFiles])
        else { return }
        // Draft files share the directory but are companions of a snapshot, not
        // entries in the 200-file budget. Counting them would evict snapshots
        // twice as fast and could leave orphaned drafts.
        let json = entries.filter {
            $0.pathExtension == "json" && !$0.lastPathComponent.hasSuffix(".draft.json")
        }
        guard json.count > limit else { return }
        let ordered = json.sorted { lhs, rhs in
            let left = (try? lhs.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast
            let right = (try? rhs.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast
            return left < right
        }
        let protectedName = currentSessionID.map { "\($0).json" }
        var excess = json.count - limit
        for url in ordered where excess > 0 {
            if url.lastPathComponent == protectedName { continue }
            if (try? fileManager.removeItem(at: url)) != nil {
                // The draft belongs to the snapshot being evicted. Removing it
                // here is what keeps the cache from retaining interrupted text
                // for a session whose settled tail is already gone.
                let draft = directory.appendingPathComponent(
                    url.deletingPathExtension().lastPathComponent + ".draft.json")
                try? fileManager.removeItem(at: draft)
                excess -= 1
            }
        }
    }

    /// Legacy snapshot path for the phone scope; read-only fallback so a build
    /// that has not migrated yet can still paint the cached transcript.
    public static func legacyTranscriptSnapshotURL(for backend: BackendID,
                                                   sessionID: String,
                                                   documentsDirectory: URL? = nil,
                                                   fileManager: FileManager = .default) -> URL? {
        guard backend == .phone, isValidSessionID(sessionID) else { return nil }
        let documents = documentsDirectory
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents
            .appendingPathComponent("transcript-snapshots", isDirectory: true)
            .appendingPathComponent("\(sessionID).json")
    }
}
