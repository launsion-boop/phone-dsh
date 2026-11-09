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

    /// Content fingerprints → DSH requestId. Kept unscoped on disk; the
    /// fingerprint itself carries the backend scope and session ID.
    public static let retryableRequestIDs = "chat.dsh.retryableRequestIDs"

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
        if let legacy = defaults.dictionary(forKey: WorkspaceStorageKeys.legacyDrafts) as? [String: String],
           !legacy.isEmpty {
            var scoped = defaults.dictionary(forKey: WorkspaceStorageKeys.drafts) as? [String: String] ?? [:]
            for (sessionID, draft) in legacy.sorted(by: { $0.key < $1.key }) {
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
                if (try? fileManager.copyItem(at: source, to: destination)) != nil {
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
        if backend == .phone,
           let legacy = defaults.dictionary(forKey: WorkspaceStorageKeys.legacyDrafts) as? [String: String] {
            return legacy[sessionID ?? "new"]
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
        if scoped.isEmpty, backend == .phone {
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

    // MARK: Transcript snapshots

    public static func transcriptsDirectory(for backend: BackendID,
                                            documentsDirectory: URL,
                                            fileManager: FileManager = .default) -> URL {
        let directory = documentsDirectory
            .appendingPathComponent("transcript-snapshots", isDirectory: true)
            .appendingPathComponent(backend.storageScope, isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    public static func transcriptSnapshotURL(for backend: BackendID,
                                             sessionID: String,
                                             documentsDirectory: URL? = nil,
                                             fileManager: FileManager = .default) -> URL {
        let documents = documentsDirectory
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return transcriptsDirectory(for: backend,
                                    documentsDirectory: documents,
                                    fileManager: fileManager)
            .appendingPathComponent("\(sessionID).json")
    }

    /// Legacy snapshot path for the phone scope; read-only fallback so a build
    /// that has not migrated yet can still paint the cached transcript.
    public static func legacyTranscriptSnapshotURL(for backend: BackendID,
                                                   sessionID: String,
                                                   documentsDirectory: URL? = nil,
                                                   fileManager: FileManager = .default) -> URL? {
        guard backend == .phone else { return nil }
        let documents = documentsDirectory
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents
            .appendingPathComponent("transcript-snapshots", isDirectory: true)
            .appendingPathComponent("\(sessionID).json")
    }
}
