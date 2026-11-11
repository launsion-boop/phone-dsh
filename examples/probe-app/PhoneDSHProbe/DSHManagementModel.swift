// SPDX-License-Identifier: MIT
// Native management surfaces over the pinned DSH Remote contract.

import Foundation
import Observation
import PhoneDSHAgentCore
import PhoneDSH
import PhoneDSHEngine
import PhoneDSHWire
import ProbeKit

// `ManagedSession` / `ManagedWorkspace` and their decoders live in
// ProbeKit/Management so a second WorkspaceBackend and the simulator suite can
// consume them; they arrive through `import ProbeKit` above.

struct ManagedReasoningEffort: Identifiable, Hashable {
    let id: String
    let name: String
}

struct ManagedModelRoute: Identifiable, Hashable {
    let provider: String
    let providerName: String
    let model: String
    let reasoningEfforts: [ManagedReasoningEffort]
    let defaultEffort: String?
    var id: String { "\(provider)/\(model)" }
    var label: String { "\(providerName) · \(model)" }
}

struct ManagedModelSelection: Hashable {
    let provider: String
    let model: String
    let reasoningEffort: String?
    var label: String { "\(provider) · \(model)" + (reasoningEffort.map { " · \($0)" } ?? "") }
}

struct ManagedQueueItem: Identifiable, Hashable {
    let id: String
    let sessionID: String
    let lane: String
    var text: String
}

struct ManagedSchedule: Identifiable {
    let id: String
    let sessionID: String
    var title: String
    var prompt: String
    var kind: String
    var scheduledAt: String
    var status: String
    var latestDeliveryAt: String?
    var timingRecord: JSONValue
    var detail: String { "\(kind) · \(scheduledAt)" }
}

struct ManagedDelivery: Identifiable, Hashable {
    let id: String
    var scheduledAt: String
    var deliveredAt: String
    var prompt: String?
}

struct ManagedTool: Identifiable, Hashable {
    let id: String
    var description: String
}

struct ActivityRow: Identifiable, Hashable {
    let id: String
    var title: String
    var detail: String
    var status: String?
}

struct ManagedGoal: Hashable {
    let id: String
    let revision: Int
    var objective: String
    var phase: String
    var roundsStarted: Int
    var maxGoalRounds: Int
}

@MainActor
@Observable
final class DSHManagementModel {
    /// The phone instance. D2 creates one per backend through
    /// `init(chat:)`; this singleton stays the phone one.
    static let shared = DSHManagementModel()

    private let chatProvider: @MainActor () -> ChatModel

    /// Every instance restores its own backend's snapshot before the first
    /// paint. A PC instance is created through `init(chat:)` when the pairing
    /// record appears, so the drawer can render the last known roster while the
    /// relay is still re-handshaking.
    private init() {
        self.chatProvider = { ChatModel.shared }
        restoreCachedSnapshot()
    }

    init(chat: @escaping @MainActor () -> ChatModel) {
        self.chatProvider = chat
        restoreCachedSnapshot()
    }

    private var chat: ChatModel { chatProvider() }
    private var backendID: BackendID { chat.backendID }

    private(set) var sessions: [ManagedSession] = [] {
        didSet { workspaceRevision &+= 1 }
    }
    private(set) var workspaces: [ManagedWorkspace] = [] {
        didSet { workspaceRevision &+= 1 }
    }
    private(set) var workspaceOrder: [String] = [] {
        didSet { workspaceRevision &+= 1 }
    }
    /// The host's authoritative default workspace id, when `workspace/follow`
    /// reports it. The phone still falls back to the title policy for hosts
    /// that predate the field.
    private(set) var defaultWorkspaceID: String? {
        didSet { workspaceRevision &+= 1 }
    }
    #if DEBUG
    /// 预览造了假数据之后,refresh() 不许把界面冲空。
    private(set) var previewDataInstalled = false
    #endif
    private(set) var pinnedSessionIDs: [String] = [] {
        didSet { workspaceRevision &+= 1 }
    }
    private(set) var archivedIDs: Set<String> = [] {
        didSet { workspaceRevision &+= 1 }
    }
    /// Bumped whenever a grouping input changes. `workspaceIndex` reads it so
    /// SwiftUI observes the cache too, and only rebuilds on a real change.
    private(set) var workspaceRevision: UInt64 = 0
    @ObservationIgnored private let workspaceIndexCache = PCWorkspaceIndexCache()
    @ObservationIgnored private var sessionTitleOrdinalCache: [String: Int]?
    @ObservationIgnored private var sessionTitleOrdinalRevision: UInt64 = .max
    private(set) var modelRoutes: [ManagedModelRoute] = []
    private(set) var currentModelSelection: ManagedModelSelection?
    private(set) var searchSnippets: [String: String] = [:]
    private(set) var searchResultIDs: Set<String>?
    private(set) var queueItems: [ManagedQueueItem] = []
    private(set) var queueSessionID: String?
    private(set) var scheduleRecords: [ManagedSchedule] = []
    private(set) var scheduleHistory: [ManagedDelivery] = []
    private(set) var scheduleHistorySessionID: String?
    private(set) var scheduleHistoryHasMore = false
    private(set) var scheduleHistoryCursor: String?
    private(set) var scheduleHistoryNotice: String?
    private(set) var tools: [ManagedTool] = []
    private(set) var planActive: Bool?
    private(set) var planPending = false
    private(set) var todos: [ActivityRow] = []
    private(set) var goal: ManagedGoal?
    private(set) var subagents: [ActivityRow] = []
    private(set) var schedules: [ActivityRow] = []
    private(set) var skills: [ActivityRow] = []
    private(set) var jobs: [ActivityRow] = []
    private(set) var activityErrors: [String: String] = [:]
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var notice: String?
    private var transport: (any DSHRemoteTransport)?
    private var workspaceMux: (any DSHMuxConnection)?
    private var workspaceTask: Task<Void, Never>?
    /// The last drawer tap that still needs to run. One worker owns the switch
    /// so two opens never overlap; a newer tap replaces this request and the
    /// in-flight one abandons at its next generation check. This is the only
    /// pending-switch structure: the ChatModel's optimistic target is the same
    /// intent, and its lifecycle gate makes the worker wait for recovery
    /// instead of keeping a second queue.
    private struct OptimisticSelect {
        let session: ManagedSession
        let generation: Int
    }
    private var pendingOptimisticSelect: OptimisticSelect?
    private var optimisticSelectTask: Task<Void, Never>?
    /// Event-driven refresh coalescing. A drawer open + session switch + online
    /// transition used to fire several full 5.5 MB `session/list` reads in a
    /// row; `refreshSoon()` collapses them into one run.
    @ObservationIgnored private let refreshDebouncer = PCLinkRefreshDebouncer()
    @ObservationIgnored private var refreshPending = false
    @ObservationIgnored private var lastRefreshCompletedAt: Date?

    /// Last successful `session/list` projection, restored on launch and after
    /// a park so the drawer and the chat title never wait for the engine.
    ///
    /// P18: the key is backend-scoped. The phone keeps its historical bare key;
    /// a PC writes a dated envelope under `pc:<machineId>`
    /// (PC-20261110-pclink-pc-roster-snapshot). It is a session-list cache, so
    /// the scope is the backend, not `(BackendID, sessionID)`.
    private var cachedSnapshotKey: String {
        WorkspaceStorageKeys.sessionSnapshotKey(for: backendID)
    }

    /// When the restored snapshot was captured. `nil` for the phone's bare
    /// value and for a live (uncached) list. Wired to the drawer's staleness
    /// copy in the next work package.
    private(set) var cacheCapturedAt: Date?

    /// One cached grouping snapshot. All drawer/list accessors below read it,
    /// so a SwiftUI body evaluation is O(1) after the first build and a
    /// workspace/follow event storm only rebuilds when its input really
    /// changed (one O(sessions) pass instead of O(sessions × workspaces)).
    var workspaceIndex: PCWorkspaceIndex {
        workspaceIndexCache.index(
            revision: workspaceRevision,
            sessions: sessions,
            workspaces: workspaces,
            workspaceOrder: workspaceOrder,
            pinnedSessionIDs: pinnedSessionIDs,
            archivedIDs: archivedIDs)
    }

    /// Duplicate-title ordinals used by the full Sessions page. That page used
    /// to rebuild `workspaces.flatMap(all sessions)` for every row it drew
    /// (O(sessions²)); this snapshot is built once per grouping revision and
    /// each row then does one dictionary lookup.
    var sessionTitleOrdinals: [String: Int] {
        let revision = workspaceRevision
        if let cache = sessionTitleOrdinalCache, sessionTitleOrdinalRevision == revision {
            return cache
        }
        var ordinals: [String: Int] = [:]
        var counts: [String: Int] = [:]
        let index = workspaceIndex
        for workspace in index.orderedWorkspaces {
            var rows = index.sessions(in: workspace)
            if isDefaultWorkspace(workspace) { rows += index.ungroupedSessions }
            for session in rows {
                let base = DrawerTitles.sessionTitle(session.title, index: 1)
                let next = (counts[base] ?? 0) + 1
                counts[base] = next
                ordinals[session.id] = next
            }
        }
        sessionTitleOrdinalCache = ordinals
        sessionTitleOrdinalRevision = revision
        return ordinals
    }

    var activeSessions: [ManagedSession] { workspaceIndex.activeSessions }
    var archivedSessions: [ManagedSession] { workspaceIndex.archivedSessions }
    var pinnedSessions: [ManagedSession] { workspaceIndex.pinnedSessions }
    func sessions(in workspace: ManagedWorkspace) -> [ManagedSession] {
        workspaceIndex.sessions(in: workspace)
    }
    var ungroupedSessions: [ManagedSession] { workspaceIndex.ungroupedSessions }

    var currentWorkspaceID: String? {
        guard let sessionID = chat.currentSessionID else { return nil }
        return workspaceIndex.workspaceIDBySessionID[sessionID]
    }
    var recentWorkspaceID: String? { workspaceIndex.recentWorkspaceID }

    /// The explicit picker choice for the next PC session; nil means "use the
    /// P18 last-used value, then the most recent workspace".
    private(set) var pendingWorkspaceID: String?

    /// The PC new-session default: picker choice → P18 last-used → recent.
    /// The phone has one workspace and never reads the P18 key.
    var newSessionWorkspaceID: String? {
        guard backendID != .phone else { return currentWorkspaceID ?? recentWorkspaceID }
        return PCLinkWorkspaceSelection.resolve(
            pending: pendingWorkspaceID,
            stored: WorkspaceStorage.lastWorkspaceID(for: backendID),
            recent: recentWorkspaceID,
            workspaces: workspaces)
    }

    /// The workspace chip is useful only before the session has a turn. Once
    /// the first turn exists the selection is fixed for that session.
    var isCurrentSessionBlank: Bool {
        guard let sessionID = chat.currentSessionID else { return true }
        return sessions.first(where: { $0.id == sessionID })?.blank ?? false
    }

    func workspaceID(for session: ManagedSession) -> String? {
        workspaceIndex.workspaceID(for: session)
    }

    /// Choose the workspace for the next/empty PC session and persist it for
    /// this paired computer (P18). Changing it while a blank session already
    /// exists opens a fresh blank session in the chosen workspace, so the next
    /// prompt really runs there; a session with a turn only displays its
    /// workspace.
    func selectWorkspaceForNewSession(_ workspaceID: String) async {
        guard backendID != .phone,
              workspaces.contains(where: { $0.id == workspaceID }) else { return }
        pendingWorkspaceID = workspaceID
        WorkspaceStorage.setLastWorkspaceID(workspaceID, for: backendID)
        // A fresh page with no DSH session yet: remember the choice; the
        // drawer's 新会话 creates the session in it.
        guard let currentID = chat.currentSessionID, isCurrentSessionBlank else { return }
        let current = sessions.first(where: { $0.id == currentID })
        let currentWorkspace = current.flatMap { self.workspaceID(for: $0) }
        guard currentWorkspace != workspaceID else { return }
        // A blank DSH session cannot move between workspaces; open a new blank
        // one in the chosen workspace so the next prompt really runs there.
        _ = await createSession(workspaceID: workspaceID)
    }

    private func rememberWorkspace(_ workspaceID: String?) {
        guard backendID != .phone, let workspaceID,
              workspaces.contains(where: { $0.id == workspaceID }) else { return }
        pendingWorkspaceID = workspaceID
        WorkspaceStorage.setLastWorkspaceID(workspaceID, for: backendID)
    }

    /// Read the live management projection. Concurrent callers are coalesced:
    /// a call that arrives while a read is in flight sets `refreshPending` and
    /// the running loop performs exactly one more pass after it finishes.
    func refresh() async {
        #if DEBUG
        // 预览造的假数据不许被宿主刷新冲掉,否则预览一进去就空了。
        if previewDataInstalled { return }
        #endif
        if isLoading {
            refreshPending = true
            return
        }
        isLoading = true
        repeat {
            refreshPending = false
            await performRefresh()
        } while refreshPending && !Task.isCancelled
        isLoading = false
        lastRefreshCompletedAt = Date()
    }

    /// Debounced entry for event-driven callers (drawer open, session switch,
    /// online transition). A burst of triggers inside the window produces one
    /// `session/list` read; explicit user retries still call `refresh()`.
    func refreshSoon() {
        let scheduledAt = Date()
        refreshDebouncer.schedule { [weak self] in
            guard let self else { return }
            // A first-paint/explicit refresh may have completed while this
            // event was inside the debounce window; do not pay for the list
            // twice. If it is still running, `refresh()` records one pending
            // pass instead.
            if let completed = self.lastRefreshCompletedAt, completed >= scheduledAt {
                return
            }
            await self.refresh()
        }
    }

    private func performRefresh() async {
        guard chat.isStarted else {
            // W1-A: while the phone engine is stopped/starting, list the
            // read-only materialized projection instead of an empty drawer.
            // The engine's own `session/list` replaces it on the next success.
            if chat.backendID == .phone {
                let projected = await chat.projectedSessions()
                if !projected.isEmpty {
                    let hints = SessionTitleHints.titles(for: backendID)
                    sessions = projected.map { item in
                        ManagedSession(
                            id: item.id,
                            title: hints[item.id] ?? item.title ?? Self.newSessionName,
                            updatedAt: item.updatedAt,
                            running: item.running,
                            blank: item.blank,
                            cwd: nil,
                            parentSessionID: nil,
                            searchSnippet: nil)
                    }
                    error = nil
                    return
                }
            }
            // Nothing to read yet: keep the last known roster visible instead of
            // blanking, for both backends. Each one restores its own scoped key,
            // so a PC list can never be filled from the phone's cache (P18).
            // Only fill an empty list: a live list must not be rolled back to an
            // older cache because the backend went away.
            if sessions.isEmpty { restoreCachedSnapshot() }
            error = nil
            return
        }
        do {
            let client = try await chat.workspaceBackend.transport()
            transport = client
            // DSH 0.2.2-rc.1's generated gateway descriptor requires the
            // reserved `_request` member even though it carries no fields.
            let sessionValue = try await client.call("session/list", args: .object(["_request": .object([:])]))
            // Optional catalog failures must not hide the valid session list.
            // Start it before the row decode so the two overlapped waits do not
            // add together.
            async let catalogResponse = try? client.call("session/modelCatalog", args: .object([:]))
            // Load the title hints once, not once per Session: the old closure
            // called `WorkspaceStorage.titleHints(for:)` for every row, which
            // reads and filters the whole UserDefaults hint map per row
            // (measured at ~3.3 s for 3,500 hinted rows on a Mac).
            let hints = SessionTitleHints.titles(for: backendID)
            let decoded = await PCWorkspaceDecoding.decodeSessionsOffMain(
                sessionValue,
                titleHints: hints,
                newSessionName: Self.newSessionName,
                untitledSessionName: Self.untitledSessionName)
            // Phone-local session filters do not exist on a PC: the phone Bot
            // registry and device-session mapping describe sessions created by
            // this phone, not by the paired computer (plan v2 §6.1 capability
            // hiding). On the phone the single read point keeps filtering so
            // every DSH surface is protected.
            let phoneOnlyFilters = backendID == .phone
            let deviceSessionIDs = phoneOnlyFilters
                ? DeviceSessionCoordinator.shared.mappedSessionIDs : []
            sessions = decoded.filter {
                !deviceSessionIDs.contains($0.id)
                    && !(phoneOnlyFilters && Self.isBotSessionID($0.id))
            }
            if let catalogValue = await catalogResponse {
                modelRoutes = Self.decodeModelRoutes(catalogValue)
            } else { modelRoutes = [] }
            if let currentSessionID = chat.currentSessionID {
                await refreshModelSelection(for: currentSessionID, using: client)
            } else { currentModelSelection = nil }
            await observeWorkspaceState(using: client)
            // The P18 selection is validated against the live baseline so a
            // deleted workspace cannot block 新会话 or the picker.
            if let pending = pendingWorkspaceID,
               !workspaces.contains(where: { $0.id == pending }) {
                pendingWorkspaceID = nil
            }
            if backendID != .phone,
               let stored = WorkspaceStorage.lastWorkspaceID(for: backendID),
               !workspaces.contains(where: { $0.id == stored }) {
                WorkspaceStorage.setLastWorkspaceID(nil, for: backendID)
            }
            // Every backend writes only its own scoped key, and only after a
            // successful refresh (P18, PC-20261110-pclink-pc-roster-snapshot).
            persistCachedSnapshot()
            error = nil
        } catch {
            // A failed refresh is not a reason to erase the usable snapshot;
            // the next successful engine answer replaces it.
            if sessions.isEmpty { restoreCachedSnapshot() }
            self.error = error.localizedDescription
        }
    }

    /// Restores the last successful session/list projection. Safe to call
    /// repeatedly; an empty or corrupt snapshot leaves the live values alone.
    private func restoreCachedSnapshot() {
        // `CachedSessionSnapshotCodec` accepts the PC envelope and the phone's
        // bare value, and returns nil for an unknown version or corrupt bytes so
        // the live list is never erased by a bad cache.
        guard let data = UserDefaults.standard.data(forKey: cachedSnapshotKey),
              let stored = CachedSessionSnapshotCodec.decode(data),
              stored.snapshot.isEmpty == false else { return }
        let snapshot = stored.snapshot
        cacheCapturedAt = stored.capturedAt
        sessions = snapshot.sessions.map { row in
            ManagedSession(
                id: row.id, title: row.title,
                updatedAt: Date(timeIntervalSince1970: row.updatedAtMilliseconds / 1_000),
                running: row.running, blank: row.blank, cwd: row.cwd,
                parentSessionID: row.parentSessionID,
                searchSnippet: row.searchSnippet)
        }
        workspaces = snapshot.workspaces.map { row in
            ManagedWorkspace(id: row.id, title: row.title, path: row.path,
                             sessionIDs: row.sessionIDs)
        }
        workspaceOrder = snapshot.workspaceOrder
        pinnedSessionIDs = snapshot.pinnedSessionIDs
        archivedIDs = Set(snapshot.archivedIDs)
    }

    /// Persists the last engine projection only after a successful refresh, so
    /// a failed call never overwrites good cache with a partial list.
    private func persistCachedSnapshot() {
        let snapshot = ChatSessionSnapshot(
            sessions: sessions.map { row in
                ChatSessionSnapshot.Session(
                    id: row.id, title: row.title,
                    updatedAtMilliseconds: row.updatedAt.timeIntervalSince1970 * 1_000,
                    running: row.running, blank: row.blank, cwd: row.cwd,
                    parentSessionID: row.parentSessionID,
                    searchSnippet: row.searchSnippet)
            },
            workspaces: workspaces.map { row in
                ChatSessionSnapshot.Workspace(id: row.id, title: row.title,
                                              path: row.path, sessionIDs: row.sessionIDs)
            },
            workspaceOrder: workspaceOrder,
            pinnedSessionIDs: pinnedSessionIDs,
            archivedIDs: Array(archivedIDs))
        let capturedAt = Date()
        guard let data = CachedSessionSnapshotCodec.encode(snapshot,
                                                           backend: backendID,
                                                           capturedAt: capturedAt) else { return }
        UserDefaults.standard.set(data, forKey: cachedSnapshotKey)
        cacheCapturedAt = capturedAt
    }

    func createSession(workspaceID: String? = nil) async -> String? {
        do {
            guard !chat.turnRunning && !chat.keepingAlive && !chat.busy else {
                throw ManagementError.sessionBusy
            }
            // PC: the picker/last-used workspace is the default for a new
            // session, not the workspace of the session being left. Phone:
            // unchanged (current → recent).
            let targetWorkspaceID = backendID == .phone
                ? (workspaceID ?? currentWorkspaceID ?? recentWorkspaceID)
                : (workspaceID ?? newSessionWorkspaceID)
            if let targetWorkspaceID {
                guard let transport else { throw ManagementError.notConnected }
                let result = try await transport.call("session/create", args: .object(["request": .object([
                    "workspaceId": .string(targetWorkspaceID),
                ])]))
                guard let id = result["sessionId"]?.stringValue else { throw ManagementError.invalidResponse }
                await chat.selectSession(id)
                guard chat.currentSessionID == id else {
                    throw ManagementError.openFailed(chat.userFacingError)
                }
                notice = "会话已添加到工作区"
                rememberWorkspace(targetWorkspaceID)
                await refresh()
                return id
            }
            let priorID = chat.currentSessionID
            await chat.newSession()
            guard let id = chat.currentSessionID, id != priorID else {
                throw ManagementError.openFailed(chat.userFacingError)
            }
            notice = "已创建新会话"
            await refresh()
            return id
        } catch { self.error = error.localizedDescription; return nil }
    }

    /// Creates a new workspace folder inside the VFS and registers it.
    ///
    /// A host folder path cannot be registered: `workspace/create` stats the
    /// path in the Worker's VFS, where only `/dsh/workspace/...` exists. The
    /// folder is materialized through the import service and then registered,
    /// so its cwd is a real VFS path (and the page origin can serve it).
    func createWorkspaceFolder(named rawName: String) async -> ManagedWorkspace? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), name.count <= 64 else {
            error = "名字不能为空、不能包含 /，且不超过 64 个字符。"
            return nil
        }
        do {
            if chat.currentSessionID == nil {
                await chat.newSession()
            }
            guard let sessionID = chat.currentSessionID else {
                throw ManagementError.noActiveSession
            }
            guard let transport else { throw ManagementError.notConnected }
            let sink = PhoneDSHWorkspaceImportSink(transport: transport)
            let manifest = WebEngineDirectoryImportManifest(
                sessionID: sessionID,
                targetDirectory: "/dsh/workspace",
                entryName: name,
                directories: [],
                files: [],
                totalBytes: 0)
            let importID = try await sink.begin(manifest)
            let result = try await sink.commit(importID: importID)
            let path = "/dsh/workspace/" + result.workspacePath
            let response = try await transport.call(
                "workspace/create",
                args: .object(["request": .object(["path": .string(path)])]))
            let row = response["workspace"] ?? .null
            guard let workspace = Self.decodeWorkspace(row) else {
                throw ManagementError.invalidResponse
            }
            if !workspaceOrder.contains(workspace.id) { workspaceOrder.append(workspace.id) }
            upsertWorkspace(workspace)
            notice = "工作区已添加"
            await refresh()
            return workspace
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    func createWorkspace(at path: String) async -> ManagedWorkspace? {
        do {
            guard let transport else { throw ManagementError.notConnected }
            let result = try await transport.call("workspace/create", args: .object(["request": .object(["path": .string(path)])]))
            let row = result["workspace"] ?? .null
            guard let workspace = Self.decodeWorkspace(row) else { throw ManagementError.invalidResponse }
            if !workspaceOrder.contains(workspace.id) { workspaceOrder.append(workspace.id) }
            upsertWorkspace(workspace)
            notice = "工作区已添加"
            return workspace
        } catch { self.error = error.localizedDescription; return nil }
    }

    func renameWorkspace(_ workspace: ManagedWorkspace, to title: String) async {
        do {
            guard let transport else { throw ManagementError.notConnected }
            let result = try await transport.call("workspace/rename", args: .object(["request": .object([
                "workspaceId": .string(workspace.id), "title": .string(title),
            ])]))
            if let updated = Self.decodeWorkspace(result["workspace"] ?? result) { upsertWorkspace(updated) }
            notice = "工作区已重命名"
        } catch { self.error = error.localizedDescription }
    }

    /// 删掉的只是「文件夹」这个分组,里面的会话不跟着走:从 registry 里拿掉之后,
    /// 它们自动落回不归属文件夹的那一段(ungroupedSessions 是按 folders 反推的)。
    func deleteWorkspace(_ workspace: ManagedWorkspace) async {
        // 预览(没连宿主)时只在本地拿掉,好把「删完会话落到上面那一段」看到;
        // 真机上没有本地兜底,删就是宿主说了算。
        if transport == nil {
            workspaces.removeAll { $0.id == workspace.id }
            workspaceOrder.removeAll { $0 == workspace.id }
            notice = "工作文件夹已删除"
            return
        }
        do {
            guard let transport else { throw ManagementError.notConnected }
            _ = try await transport.call("workspace/delete", args: .object(["request": .object([
                "workspaceId": .string(workspace.id),
            ])]))
            workspaces.removeAll { $0.id == workspace.id }
            workspaceOrder.removeAll { $0 == workspace.id }
            notice = "工作文件夹已删除"
        } catch { self.error = error.localizedDescription }
    }

    func insertSession(_ session: ManagedSession, into workspace: ManagedWorkspace) async {
        do {
            guard let transport else { throw ManagementError.notConnected }
            let result = try await transport.call("workspace/insertSessionBefore", args: .object(["request": .object([
                "workspaceId": .string(workspace.id), "sessionId": .string(session.id),
            ])]))
            if let updated = Self.decodeWorkspace(result["workspace"] ?? result) { upsertWorkspace(updated) }
            notice = "会话已移入工作区"
        } catch { self.error = error.localizedDescription }
    }

    func setPinned(_ session: ManagedSession, pinned: Bool) async {
        do {
            guard let transport else { throw ManagementError.notConnected }
            let result = try await transport.call(pinned ? "workspace/pinSession" : "workspace/unpinSession", args: .object(["request": .object([
                "sessionId": .string(session.id),
            ])]))
            pinnedSessionIDs = result["pinnedSessionIds"]?.arrayValue?.compactMap(\.stringValue) ?? []
            notice = pinned ? "会话已置顶" : "已取消置顶"
        } catch { self.error = error.localizedDescription }
    }

    /// Opens a session from a page that keeps its own presentation (the session
    /// browser). It waits for the open, like before; the drawer stages the
    /// switch with ``stageOptimisticSelect(_:title:)`` instead.
    func select(_ session: ManagedSession) async -> Bool {
        switch await performSelect(session, generation: nil) {
        case .opened:
            return true
        case .failed(let message):
            error = message
            return false
        case .superseded:
            return false
        }
    }

    /// The drawer's optimistic tap, lightweight half: paint the target
    /// selected/titled now and remember what to open. No engine or Worker work
    /// runs until ``startStagedOptimisticSelect()`` releases it, after the phone
    /// drawer's close animation (or one runloop for the persistent sidebar).
    @discardableResult
    func stageOptimisticSelect(_ session: ManagedSession, title: String) -> Int {
        let generation = chat.beginSessionSwitch(sessionID: session.id, title: title)
        pendingOptimisticSelect = OptimisticSelect(session: session, generation: generation)
        return generation
    }

    /// Starts the single switch worker for whatever target is staged. Safe to
    /// call more than once: the worker is created once and always reads the
    /// latest staged target, so a newer tap replaces an in-flight one without
    /// opening two sessions at once.
    func startStagedOptimisticSelect() {
        guard pendingOptimisticSelect != nil, optimisticSelectTask == nil else { return }
        optimisticSelectTask = Task { @MainActor [weak self] in
            await self?.runOptimisticSelectWorker()
        }
    }

    /// The wide sidebar does not close, so its tap just needs one runloop for
    /// SwiftUI to commit the highlighted row/title before the open starts.
    func startStagedOptimisticSelectOnNextRunloop() {
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.startStagedOptimisticSelect()
        }
    }

    private enum SelectOutcome: Equatable {
        case opened
        case failed(String)
        case superseded
    }

    private func runOptimisticSelectWorker() async {
        defer { optimisticSelectTask = nil }
        // The per-backend instance owns its own ChatModel: a PC drawer tap must
        // stage/wait on the PC model, never on the phone singleton.
        let chat = self.chat
        while let request = pendingOptimisticSelect {
            pendingOptimisticSelect = nil
            // The drawer has closed (or the sidebar yielded): only now does the
            // 300ms loading-pill timer start, and only now may heavy open work
            // run. A superseded request cannot mark a newer tap as started.
            chat.markSessionSwitchWorkStarted(request.generation)
            let outcome = await performSelect(request.session, generation: request.generation)
            // A newer tap is now the latest intent. Loop to it; do not let this
            // completion clear or overwrite its pending title/selection.
            guard chat.isSessionSwitchCurrent(request.generation) else {
                continue
            }
            switch outcome {
            case .opened:
                chat.finishSessionSwitch(request.generation)
            case .failed(let message):
                chat.finishSessionSwitch(request.generation)
                error = message
                // The drawer is closed and must not be reopened; the chat
                // page's existing error banner is the lightweight notice.
                chat.reportSessionSwitchFailure(message)
            case .superseded:
                chat.finishSessionSwitch(request.generation)
            }
        }
    }

    private func performSelect(_ session: ManagedSession,
                               generation: Int?) async -> SelectOutcome {
        let chat = self.chat
        let isStillWanted: () -> Bool = {
            guard let generation else { return true }
            return chat.isSessionSwitchCurrent(generation)
        }
        guard isStillWanted() else { return .superseded }
        if chat.currentSessionID == session.id { error = nil; return .opened }
        // The optimistic target is already painted. A PC switch still waits on
        // its recovery lifecycle; the phone views the materialized projection
        // immediately and never blocks on a boot or a running turn (W1-B).
        if chat.backendID != .phone {
            guard await chat.waitForSessionSwitchLifecycle(isStillWanted: isStillWanted) else {
                return .superseded
            }
        }
        if !chat.isStarted, chat.backendID != .phone {
            // A PC session this phone cached opens read-only while the computer
            // is unreachable; a session it never opened cannot, and the copy
            // says which. Without this the drawer tap died on `isStarted` and
            // reported the phone's "主机没有启动" text
            // (review of PR #98, problem B).
            guard isStillWanted() else { return .superseded }
            if chat.showCachedPreview(for: session.id) {
                rememberWorkspace(workspaceID(for: session))
                error = nil
                return .opened
            }
            return .failed(chat.userFacingError ?? "电脑暂时连不上，这个会话还没有本地缓存")
        }
        if !chat.isStarted, chat.backendID != .phone {
            await chat.start()
            guard isStillWanted() else { return .superseded }
            guard chat.isStarted else {
                return .failed(chat.userFacingError ?? "主机没有启动，无法打开会话")
            }
        }
        if chat.parked, chat.backendID != .phone {
            await chat.resumeParkedHost()
            guard isStillWanted() else { return .superseded }
        }
        if chat.backendID != .phone,
           chat.turnRunning || chat.pendingPermission != nil || chat.pendingQuestion != nil {
            await chat.cancelTurn()
            chat.dismissPendingRequests()
            guard isStillWanted() else { return .superseded }
            guard !chat.turnRunning else {
                return .failed("当前回合停不下来，请稍后重试或重启主机")
            }
        }
        // On the phone a running turn is never interrupted: `selectSession`
        // paints the projection, and a later send activates the target once the
        // turn ends.
        await chat.selectSession(session.id, switchGeneration: generation)
        guard isStillWanted() else { return .superseded }
        guard chat.currentSessionID == session.id else {
            return .failed(chat.userFacingError ?? "无法打开会话 \(session.id.prefix(8))")
        }
        // Opening a PC session makes its workspace the next new-session
        // default (P18); the phone keeps its single workspace.
        rememberWorkspace(workspaceID(for: session))
        error = nil
        return .opened
    }

    func rename(_ session: ManagedSession, to title: String) async {
        do {
            guard let transport else { throw ManagementError.notConnected }
            _ = try await transport.call("session/rename", args: .object(["request": .object([
                "sessionId": .string(session.id), "title": .string(title),
            ])]))
            notice = "Session renamed"
            await refresh()
        } catch { self.error = error.localizedDescription }
    }

    func fork(_ session: ManagedSession) async -> String? {
        do {
            guard !chat.turnRunning && !chat.keepingAlive && !chat.busy else {
                throw ManagementError.sessionBusy
            }
            guard let transport else { throw ManagementError.notConnected }
            let result = try await transport.call("session/fork", args: .object(["request": .object(["sessionId": .string(session.id)])]))
            guard let id = result["sessionId"]?.stringValue else { throw ManagementError.invalidResponse }
            await chat.selectSession(id)
            guard chat.currentSessionID == id else {
                throw ManagementError.openFailed(chat.userFacingError)
            }
            notice = "Fork created from the latest completed turn"
            await refresh()
            return id
        } catch { self.error = error.localizedDescription; return nil }
    }

    func search(_ query: String) async {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            searchResultIDs = nil
            searchSnippets = [:]
            return
        }
        do {
            guard let transport else { throw ManagementError.notConnected }
            let value = try await transport.call("session/search", args: .object(["request": .object(["query": .string(normalized)])]))
            let rows = value["items"]?.arrayValue ?? []
            searchResultIDs = Set(rows.compactMap { $0["sessionId"]?.stringValue })
            searchSnippets = Dictionary(uniqueKeysWithValues: rows.compactMap { row in
                guard let id = row["sessionId"]?.stringValue, let snippet = row["snippet"]?.stringValue else { return nil }
                return (id, snippet)
            })
        } catch {
            // Retain local title/ID filtering when full-text search is unavailable.
            searchResultIDs = []
        }
    }

    func selectModel(_ route: ManagedModelRoute, reasoningEffort: String? = nil) async {
        do {
            guard let transport else { throw ManagementError.notConnected }
            guard let sessionID = chat.currentSessionID else { throw ManagementError.noActiveSession }
            var request: [String: JSONValue] = [
                "sessionId": .string(sessionID), "provider": .string(route.provider), "model": .string(route.model),
            ]
            if let reasoningEffort { request["reasoningEffort"] = .string(reasoningEffort) }
            let result = try await transport.call("session/selectModel", args: .object(["request": .object(request)]))
            let selected = result["selected"] ?? .object(request)
            currentModelSelection = Self.decodeModelSelection(selected)
            notice = "已为当前会话选择模型"
        } catch { self.error = error.localizedDescription }
    }

    func reportError(_ message: String) { error = message }

    private func refreshModelSelection(for sessionID: String, using transport: any DSHRemoteTransport) async {
        do {
            let result = try await transport.call("session/projections", args: .object(["request": .object(["sessionId": .string(sessionID)])]))
            let projection = result["values"]?["modelSelection"]
            currentModelSelection = Self.decodeModelSelection(projection?["next"] ?? projection?["lastUsed"] ?? .null)
        } catch { currentModelSelection = nil }
    }

    func refreshQueue(for sessionID: String) async {
        do {
            let client: any DSHRemoteTransport
            if let transport { client = transport }
            else {
                client = try await chat.workspaceBackend.transport()
                transport = client
            }
            let result = try await client.call("session/projections", args: .object(["request": .object(["sessionId": .string(sessionID)])]))
            let values = result["values"] ?? .null
            queueItems = ["next-turn", "next-step"].flatMap { lane in
                (values["inbox"]?[lane]?.arrayValue ?? []).compactMap { item in
                    guard let id = item["id"]?.stringValue else { return nil }
                    let text = (item["content"]?.arrayValue ?? []).compactMap { part -> String? in
                        guard part["type"]?.stringValue == "text" else { return nil }
                        return part["text"]?.stringValue
                    }.joined(separator: "\n")
                    return ManagedQueueItem(id: id, sessionID: sessionID, lane: lane, text: text)
                }
            }
            queueSessionID = sessionID
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func updateQueue(_ item: ManagedQueueItem, action: String, replacement: String? = nil) async {
        do {
            guard let transport else { throw ManagementError.notConnected }
            var value: [String: JSONValue] = ["kind": .string(action)]
            if action == "edit" {
                value["content"] = .array([.object(["type": .string("text"), "text": .string(replacement ?? "")])])
            }
            _ = try await transport.call("session/updateQueue", args: .object(["request": .object([
                "sessionId": .string(item.sessionID), "itemId": .string(item.id), "action": .object(value),
            ])]))
            notice = action == "remove" ? "已从队列移除" : (action == "steer" ? "已将消息设为当前引导" : "队列内容已更新")
            await refreshQueue(for: item.sessionID)
        } catch { self.error = error.localizedDescription }
    }

    func refreshActivity(sessionID: String) async {
        do {
            let client: any DSHRemoteTransport
            if let transport { client = transport }
            else {
                client = try await chat.workspaceBackend.transport()
                transport = client
            }
            activityErrors = [:]
            async let projectionResponse = try? client.call("session/projections", args: .object(["request": .object(["sessionId": .string(sessionID)])]))
            async let skillResponse = try? client.call("skills/list", args: .object(["request": .object(["sessionId": .string(sessionID)])]))
            async let scheduleResponse = try? client.call("schedule/catalog", args: .object([:]))
            // `goals/get` resolves the session's agent (pin
            // session-controller/src/agent.ts:138-190) and can wake it. Every
            // caller here is the open session: ChatPage's current-session
            // `task(id:)`/job/schedule sheets and SessionActivityPage opened
            // from that page. A session list must use the passive
            // `session/projections.values.goal` instead, never this call.
            async let goalResponse = Self.readOptional(client, "goals/get", args: .object(["agentId": .string(sessionID)]))
            let (projectionValue, skillValue, scheduleValue, goalValue) = await
                (projectionResponse, skillResponse, scheduleResponse, goalResponse)

            if let projectionValue {
                decodeActivityProjections(projectionValue["values"] ?? .null)
            } else {
                activityErrors["状态"] = "DSH 没有返回此会话的投影数据。"
            }
            skills = skillValue?["skills"]?.arrayValue?.compactMap { row in
                guard let name = row["name"]?.stringValue else { return nil }
                return ActivityRow(id: name, title: name,
                                   detail: [row["description"]?.stringValue, row["whenToUse"]?.stringValue]
                                    .compactMap { $0 }.joined(separator: "\n"), status: row["modelInvocable"]?.boolValue == true ? "可由模型调用" : "仅用户调用")
            } ?? []
            if skillValue == nil { activityErrors["技能"] = "技能目录暂不可用；请检查当前预设的技能配置。" }
            schedules = scheduleValue?.arrayValue?.compactMap { row in
                guard row["id"]?.stringValue != nil else { return nil }
                guard row["target"]?["sessionId"]?.stringValue == sessionID else { return nil }
                let id = row["id"]?.stringValue ?? UUID().uuidString
                let title = row["title"]?.stringValue ?? "计划任务"
                let rule = row["kind"]?.stringValue ?? row["type"]?.stringValue ?? "提醒"
                return ActivityRow(id: id, title: title,
                                   detail: "\(rule) · \(sessionID)",
                                   status: row["status"]?.stringValue)
            } ?? []
            scheduleRecords = (scheduleValue?.arrayValue ?? []).compactMap(Self.decodeSchedule)
                .filter { $0.sessionID == sessionID && !Self.isBotSessionID($0.sessionID) }
            if scheduleValue == nil { activityErrors["计划任务"] = "schedule/catalog 未返回数据。" }
            if let goalValue, goalValue != .null {
                let ref = goalValue["goal"] ?? goalValue
                goal = ManagedGoal(id: ref["id"]?.stringValue ?? "",
                                   revision: ref["revision"]?.intValue ?? 0,
                                   objective: ref["objective"]?.stringValue ?? "",
                                   phase: ref["phase"]?.stringValue ?? "unknown",
                                   roundsStarted: goalValue["roundsStarted"]?.intValue ?? 0,
                                   maxGoalRounds: ref["maxGoalRounds"]?.intValue ?? 0)
            } else {
                goal = nil
            }
            jobs = await readJobs(sessionID: sessionID, using: client)
        } catch {
            activityErrors["运行活动"] = error.localizedDescription
        }
    }

    private func decodeActivityProjections(_ values: JSONValue) {
        let plan = values["plan"]
        planActive = plan?["active"]?.boolValue
        planPending = plan?["pending"]?.boolValue ?? false
        todos = (values["todos"]?.arrayValue ?? []).enumerated().compactMap { index, row in
            guard let content = row["content"]?.stringValue else { return nil }
            return ActivityRow(id: String(index), title: content, detail: "", status: row["status"]?.stringValue)
        }
        let goalValue = values["goal"]?["goal"]
        if let goalValue, goalValue != .null {
            goal = ManagedGoal(id: goalValue["id"]?.stringValue ?? "",
                               revision: goalValue["revision"]?.intValue ?? 0,
                               objective: goalValue["objective"]?.stringValue ?? "",
                               phase: goalValue["phase"]?.stringValue ?? "unknown",
                               roundsStarted: values["goal"]?["roundsStarted"]?.intValue ?? 0,
                               maxGoalRounds: goalValue["maxGoalRounds"]?.intValue ?? 0)
        } else { goal = nil }
        subagents = (values["subagentCatalog"]?.arrayValue ?? []).compactMap { row in
            guard let id = row["id"]?.stringValue else { return nil }
            return ActivityRow(id: id,
                               title: row["label"]?.stringValue ?? "子 Agent \(id.prefix(8))",
                               detail: "\(row["mode"]?.stringValue ?? "unknown") · \(id)", status: row["mode"]?.stringValue)
        }
    }

    private func readJobs(sessionID: String, using client: any DSHRemoteTransport) async -> [ActivityRow] {
        do {
            let mux = try await client.openMux()
            defer { Task { await mux.close() } }
            let streamID = "jobs-\(UUID().uuidString)"
            try await mux.send(.object([
                "type": .string("open"), "streamId": .string(streamID),
                "endpoint": .string("job/list"),
                "payload": .object(["args": .object(["request": .object(["sessionId": .string(sessionID)])])]),
            ]))
            while let frame = try await mux.receive() {
                guard frame["streamId"]?.stringValue == streamID else { continue }
                switch frame["type"]?.stringValue {
                case "error": throw ManagementError.remoteStream(frame["error"]?["message"]?.stringValue ?? "DSH job stream failed")
                case "end": return []
                case "item":
                    let value = frame["value"] ?? .null
                    if value["type"]?.stringValue == "rows" {
                        return (value["jobs"]?.arrayValue ?? []).compactMap { job in
                            guard let id = job["id"]?.stringValue else { return nil }
                            return ActivityRow(id: id, title: job["label"]?.stringValue ?? id,
                                               detail: job["kind"]?.stringValue ?? "job",
                                               status: job["status"]?.stringValue)
                        }
                    }
                default: continue
                }
            }
            return []
        } catch {
            activityErrors["Background jobs"] = error.localizedDescription
            return []
        }
    }

    func mutateGoal(_ operation: String, sessionID: String, goal: ManagedGoal) async {
        do {
            guard let transport else { throw ManagementError.notConnected }
            _ = try await transport.call("goals/\(operation)", args: .object([
                "agentId": .string(sessionID),
                "ref": .object(["id": .string(goal.id), "revision": .number(Double(goal.revision))]),
            ]))
            await refreshActivity(sessionID: sessionID)
        } catch { activityErrors["Goal"] = error.localizedDescription }
    }

    func deleteSchedule(_ row: ActivityRow, sessionID: String) async {
        do {
            guard let transport else { throw ManagementError.notConnected }
            _ = try await transport.call("schedule/edit", args: .object(["request": .object([
                "id": .string(row.id), "action": .string("delete"),
            ])]))
            await refreshActivity(sessionID: sessionID)
        } catch { activityErrors["计划任务"] = error.localizedDescription }
    }

    func deleteSchedule(_ schedule: ManagedSchedule) async {
        do {
            guard let transport else { throw ManagementError.notConnected }
            _ = try await transport.call("schedule/edit", args: .object(["request": .object([
                "id": .string(schedule.id), "action": .string("delete"),
            ])]))
            await refreshAutomations()
        } catch { self.error = error.localizedDescription }
    }

    func killJob(_ row: ActivityRow, sessionID: String) async {
        do {
            guard let transport else { throw ManagementError.notConnected }
            _ = try await transport.call("job/kill", args: .object(["request": .object([
                "jobId": .string(row.id), "sessionId": .string(sessionID),
            ])]))
            jobs = await readJobs(sessionID: sessionID, using: transport)
        } catch { activityErrors["Background jobs"] = error.localizedDescription }
    }

    func interruptSubagent(_ row: ActivityRow, parentSessionID: String) async {
        do {
            guard let transport else { throw ManagementError.notConnected }
            _ = try await transport.call("subagents/interruptByParent", args: .object([
                "childSessionId": .string(row.id), "parentSessionId": .string(parentSessionID), "mode": .string("continuable"),
            ]))
            notice = "已向子 Agent 发送中断请求"
        } catch { activityErrors["子 Agent"] = error.localizedDescription }
    }

    func createSchedule(sessionID: String, title: String, prompt: String, afterSeconds: Int) async -> Bool {
        await createSchedule(request: [
            "sessionId": .string(sessionID),
            "title": .string(title),
            "prompt": .string(prompt),
            "after_seconds": .number(Double(afterSeconds)),
        ])
    }

    func createSchedule(request: [String: JSONValue]) async -> Bool {
        // PHONE-ONLY (plan v2 §6.1 capability hiding). The settings/schedule
        // surfaces stay on the phone; a PC workspace never calls `phone/*`.
        guard backendID == .phone else {
            self.error = "定时任务是手机工作区的功能，PC 工作区不提供。"
            return false
        }
        do {
            guard let transport else { throw ManagementError.notConnected }
            // PHONE-ONLY: schedule creation is a phone endpoint in v1.
            _ = try await transport.call("phone/createSchedule", args: .object(["request": .object(request)]))
            await refreshAutomations()
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func refreshAutomations() async {
        guard backendID == .phone else {
            scheduleRecords = []
            tools = []
            return
        }
        do {
            let client: any DSHRemoteTransport
            if let transport { client = transport }
            else {
                client = try await chat.workspaceBackend.transport()
                transport = client
            }
            async let schedulesResponse = try? client.call("schedule/catalog", args: .object([:]))
            async let toolsResponse = try? client.call("phone/listTools", args: .object([:]))
            let (schedulesValue, toolsValue) = await (schedulesResponse, toolsResponse)
            var failures: [String] = []
            if let schedulesValue {
                scheduleRecords = schedulesValue.arrayValue?.compactMap(Self.decodeSchedule)
                    .filter { !Self.isBotSessionID($0.sessionID) } ?? []
            } else {
                failures.append("DSH schedule catalog is unavailable.")
            }
            if let toolsValue {
                tools = toolsValue["tools"]?.arrayValue?.compactMap { row in
                    guard let name = row["name"]?.stringValue else { return nil }
                    return ManagedTool(id: name, description: row["description"]?.stringValue ?? "")
                } ?? []
            } else {
                failures.append("DSH tool inventory is unavailable.")
            }
            error = failures.isEmpty ? nil : failures.joined(separator: "\n")
        } catch { self.error = error.localizedDescription }
    }

    func updateSchedule(_ schedule: ManagedSchedule, title: String, prompt: String, timing: JSONValue? = nil) async -> Bool {
        do {
            guard let transport else { throw ManagementError.notConnected }
            var patch: [String: JSONValue] = ["title": .string(title), "prompt": .string(prompt)]
            if let timing { patch["timing"] = timing }
            let result = try await transport.call("schedule/edit", args: .object(["request": .object([
                "id": .string(schedule.id), "action": .string("update"), "patch": .object(patch),
                "expectedUpdatedAt": schedule.timingRecord["updatedAt"] ?? .null,
            ])]))
            if result["code"] != nil || result["id"]?.stringValue != schedule.id {
                error = "计划任务已变化或停止，请刷新后再编辑。"
                return false
            }
            await refreshAutomations()
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func loadScheduleHistory(_ schedule: ManagedSchedule, before: String? = nil) async {
        do {
            guard let transport else { throw ManagementError.notConnected }
            let cursor = scheduleHistorySessionID == schedule.id ? before : nil
            if cursor == nil {
                scheduleHistorySessionID = schedule.id
                scheduleHistory = []
                scheduleHistoryCursor = nil
                scheduleHistoryHasMore = false
                scheduleHistoryNotice = nil
            }
            var request: [String: JSONValue] = [
                "id": .string(schedule.id),
                "limit": .number(50),
            ]
            if let cursor { request["before"] = .string(cursor) }
            let result = try await transport.call("schedule/history", args: .object(["request": .object(request)]))
            guard result["code"] == nil else {
                scheduleHistory = []
                scheduleHistoryHasMore = false
                scheduleHistoryNotice = "此计划任务不存在，或历史游标已失效。"
                return
            }
            let rows = (result["records"]?.arrayValue ?? []).compactMap { row -> ManagedDelivery? in
                guard let id = row["messageId"]?.stringValue else { return nil }
                return ManagedDelivery(id: id,
                                       scheduledAt: row["scheduledAt"]?.stringValue ?? "",
                                       deliveredAt: row["deliveredAt"]?.stringValue ?? "",
                                       prompt: row["prompt"]?.stringValue)
            }
            if cursor == nil { scheduleHistory = rows }
            else { scheduleHistory.append(contentsOf: rows) }
            scheduleHistoryCursor = result["nextBefore"]?.stringValue
            scheduleHistoryHasMore = scheduleHistoryCursor != nil
            scheduleHistoryNotice = result["earlierRecordsUnavailable"]?.boolValue == true
                ? "部分较早记录不可用（保留期或旧版本数据）。"
                : nil
        } catch { self.error = error.localizedDescription }
    }

    func loadToolInventory() async {
        guard backendID == .phone else {
            tools = []
            return
        }
        do {
            guard let transport else { throw ManagementError.notConnected }
            // PHONE-ONLY: `phone/*` endpoints exist only on the phone backend.
            let result = try await transport.call("phone/listTools", args: .object([:]))
            tools = result["tools"]?.arrayValue?.compactMap { row in
                guard let name = row["name"]?.stringValue else { return nil }
                return ManagedTool(id: name, description: row["description"]?.stringValue ?? "")
            } ?? []
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func archive(_ session: ManagedSession, stopActivity: Bool = false) async {
        do {
            guard let transport else { throw ManagementError.notConnected }
            let result = try await transport.call("workspace/archiveSession", args: .object(["request": .object([
                "sessionId": .string(session.id), "stopActivity": .bool(stopActivity),
            ])]))
            archivedIDs = Set(result["archivedSessionIds"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            notice = "Session archived"
            await refresh()
        } catch { self.error = error.localizedDescription }
    }

    func unarchive(_ session: ManagedSession) async {
        do {
            guard let transport else { throw ManagementError.notConnected }
            let result = try await transport.call("workspace/unarchiveSession", args: .object(["request": .object(["sessionId": .string(session.id)])]))
            archivedIDs = Set(result["archivedSessionIds"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            notice = "Session restored"
            await refresh()
        } catch { self.error = error.localizedDescription }
    }

    private func observeWorkspaceState(using client: any DSHRemoteTransport) async {
        guard workspaceTask == nil else { return }
        do {
            let mux = try await client.openMux()
            workspaceMux = mux
            try await mux.send(.object([
                "type": .string("open"), "streamId": .string("workspace"),
                "endpoint": .string("workspace/follow"),
                "payload": .object(["args": .object([:])]),
            ]))
            workspaceTask = Task { [weak self] in
                while !Task.isCancelled {
                    do {
                        guard let frame = try await mux.receive() else { break }
                        guard frame["streamId"]?.stringValue == "workspace",
                              frame["type"]?.stringValue == "item",
                              let value = frame["value"] else { continue }
                        await self?.applyWorkspaceFrame(value)
                    } catch { await self?.setStreamError(error); break }
                }
            }
            // Allow the initial Host baseline to arrive before the refresh returns.
            for _ in 0..<40 where !workspaceBaselineReceived {
                try? await Task.sleep(for: .milliseconds(50))
                if Task.isCancelled { break }
            }
        } catch { self.error = error.localizedDescription }
    }

    private func applyWorkspaceFrame(_ frame: JSONValue) {
        switch frame["type"]?.stringValue {
        case "baseline":
            workspaceBaselineReceived = true
            applyWorkspaceBaseline(frame["value"] ?? .null)
        case "replace":
            applyWorkspaceBaseline(frame["value"] ?? .null)
        case "upsert":
            if let workspace = Self.decodeWorkspace(frame["workspace"] ?? .null) { upsertWorkspace(workspace) }
        case "remove":
            if let id = frame["workspaceId"]?.stringValue {
                workspaces.removeAll { $0.id == id }
                workspaceOrder.removeAll { $0 == id }
            }
        case "order":
            workspaceOrder = frame["workspaceIds"]?.arrayValue?.compactMap(\.stringValue) ?? []
        case "archived":
            archivedIDs = Set(frame["archivedSessionIds"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        case "pinned":
            pinnedSessionIDs = frame["pinnedSessionIds"]?.arrayValue?.compactMap(\.stringValue) ?? []
        default:
            break
        }
    }

    private func applyWorkspaceBaseline(_ value: JSONValue) {
        if let id = value["defaultWorkspaceId"]?.stringValue, !id.isEmpty {
            defaultWorkspaceID = id
        }
        workspaces = (value["items"]?.arrayValue ?? []).compactMap(Self.decodeWorkspace)
            .filter { !Self.isBotWorkspacePath($0) }
        workspaceOrder = workspaces.map(\.id)
        archivedIDs = Set(value["archivedSessionIds"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        pinnedSessionIDs = value["pinnedSessionIds"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    private func upsertWorkspace(_ workspace: ManagedWorkspace) {
        guard !Self.isBotWorkspacePath(workspace) else {
            workspaces.removeAll { $0.id == workspace.id }
            workspaceOrder.removeAll { $0 == workspace.id }
            return
        }
        if let index = workspaces.firstIndex(where: { $0.id == workspace.id }) { workspaces[index] = workspace }
        else {
            workspaces.append(workspace)
            workspaceOrder.append(workspace.id)
        }
    }

    /// The host default is authoritative; older Workers only expose a title.
    /// A user-renamed default folder still groups loose sessions here, but its
    /// visible custom name is kept because the title policy only rewrites the
    /// host's placeholder names.
    func isDefaultWorkspace(_ workspace: ManagedWorkspace) -> Bool {
        if let defaultWorkspaceID, defaultWorkspaceID == workspace.id { return true }
        return DrawerTitles.isDefaultWorkspace(workspace.title)
    }

    private static func isBotSessionID(_ sessionID: String) -> Bool {
        sessionID.hasPrefix(BotSessionRegistry.sessionIDPrefix)
            || BotSessionRegistry.shared.isBotSession(sessionID)
    }

    private static func isBotWorkspacePath(_ workspace: ManagedWorkspace) -> Bool {
        BotSessionRegistry.shared.isBotWorkspacePath(workspace.path)
    }

    private static func decodeWorkspace(_ value: JSONValue) -> ManagedWorkspace? {
        ManagementDecoding.decodeWorkspace(value, isExcludedSessionID: isBotSessionID)
    }

    private func setStreamError(_ error: Error) { self.error = error.localizedDescription }
    private var workspaceBaselineReceived = false

    /// Default session names. The host sends no title for a fresh session, so
    /// these are the only names the user ever sees for one.
    static let newSessionName = ManagementDecoding.newSessionName
    static let untitledSessionName = ManagementDecoding.untitledSessionName

    private func decodeSessions(_ value: JSONValue) -> [ManagedSession] {
        let backend = backendID
        return ManagementDecoding.decodeSessions(
            value,
            titleHint: { SessionTitleHints.title(for: $0, backend: backend) },
            newSessionName: Self.newSessionName,
            untitledSessionName: Self.untitledSessionName)
    }

    /// Optional management read whose failure must not hide the valid rows, but
    /// must still leave a diagnostic trail (previously `try?` erased it).
    private static func readOptional(_ client: any DSHRemoteTransport,
                                     _ endpoint: String,
                                     args: JSONValue) async -> JSONValue? {
        do {
            return try await client.call(endpoint, args: args)
        } catch {
            ChatModel.appendDiagnostic("\(endpoint) failed: \(error)")
            return nil
        }
    }

    private static func decodeModelRoutes(_ value: JSONValue) -> [ManagedModelRoute] {
        (value["groups"]?.arrayValue ?? []).flatMap { group in
            (group["models"]?.arrayValue ?? []).compactMap { model in
                guard let modelName = model["id"]?.stringValue else { return nil }
                return ManagedModelRoute(
                    provider: group["id"]?.stringValue ?? "",
                    providerName: group["name"]?.stringValue ?? group["id"]?.stringValue ?? "Provider",
                    model: modelName,
                    reasoningEfforts: model["reasoning"]?["efforts"]?.arrayValue?.compactMap { effort in
                        guard let id = effort["id"]?.stringValue else { return nil }
                        return ManagedReasoningEffort(id: id, name: effort["name"]?.stringValue ?? id)
                    } ?? [],
                    defaultEffort: model["reasoning"]?["defaultEffort"]?.stringValue)
            }
        }
    }

    private static func decodeModelSelection(_ value: JSONValue) -> ManagedModelSelection? {
        guard value != .null,
              let provider = value["provider"]?.stringValue,
              let model = value["model"]?.stringValue else { return nil }
        return ManagedModelSelection(provider: provider, model: model,
                                     reasoningEffort: value["reasoningEffort"]?.stringValue)
    }

    private static func decodeSchedule(_ value: JSONValue) -> ManagedSchedule? {
        guard let id = value["id"]?.stringValue,
              let kind = value["kind"]?.stringValue else { return nil }
        return ManagedSchedule(id: id, sessionID: value["target"]?["sessionId"]?.stringValue ?? "",
                               title: value["title"]?.stringValue ?? "提醒",
                               prompt: value["prompt"]?.stringValue ?? "",
                               kind: kind,
                               scheduledAt: value["scheduledAt"]?.stringValue ?? "",
                               status: value["status"]?.stringValue ?? "active",
                               latestDeliveryAt: value["lastDelivery"]?["deliveredAt"]?.stringValue,
                               timingRecord: value)
    }
}

private enum ManagementError: LocalizedError {
    case notConnected
    case invalidResponse
    case openFailed(String?)
    case noActiveSession
    case sessionBusy
    case remoteStream(String)
    var errorDescription: String? {
        switch self {
        // 界面上不出现宿主的英文原话:认不出的只说这一句,原话进诊断。
        case .notConnected: "本地引擎还没起来。"
        case .invalidResponse: "本地引擎这次的回答不完整。"
        case .openFailed: "这个会话打不开。"
        case .noActiveSession: "先打开一个会话,再换它的模型。"
        case .sessionBusy: "这一轮还在跑,等它结束再换会话。"
        case .remoteStream: "这一步没做成,重试一次。"
        }
    }

}

#if DEBUG
// 只给 -uiPreview 用:造 N 个会话和 M 个工作文件夹,不碰宿主,不进正式包。
extension DSHManagementModel {
    /// 只给 -uiPreview 用:把「读不到会话」那一行摆出来,不碰宿主。
    func installPreviewError(_ text: String) { error = text }

    func installPreviewData(sessionCount: Int, workspaceCount: Int = 2) {
        previewDataInstalled = true
        let base = chat.workspaceRoot.path
        workspaces = (0..<max(workspaceCount, 0)).map { index in
            let title = index == 0 ? "项目资料" : "设计稿 \(index)"
            return ManagedWorkspace(id: "preview-ws-\(index)",
                                    title: title,
                                    path: base + "/" + title,
                                    sessionIDs: [])
        }
        let now = Date()
        let count = max(workspaceCount, 1)
        sessions = (0..<sessionCount).map { index in
            ManagedSession(id: "preview-s-\(index)",
                           title: index % 7 == 3 ? "" : "预览会话 \(index + 1)",
                           updatedAt: now.addingTimeInterval(Double(-index) * 3600),
                           running: index == 1,
                           blank: false,
                           cwd: workspaces.isEmpty ? base : workspaces[index % count].path,
                           parentSessionID: nil,
                           searchSnippet: nil)
        }
        for index in workspaces.indices {
            workspaces[index].sessionIDs = sessions
                .filter { $0.cwd == workspaces[index].path }
                .map(\.id)
        }
        workspaceOrder = workspaces.map(\.id)
    }
}
#endif

/// Local, first-prompt title hints.
///
/// DSH fills the `title` projection when its title row runs; until then (or
/// when the phone profile omits it) the drawer would show every row as
/// "新会话". Remember the first prompt per session so the list is readable
/// immediately, and prefer the projection whenever DSH provides one.
enum SessionTitleHints {
    private static let limit = 18

    /// D2: title hints are session-scoped per backend (P18). The legacy bare
    /// key is read for the phone until `WorkspaceStorageMigration` has copied
    /// it into the scoped store.
    static func remember(_ prompt: String, for sessionID: String,
                         backend: BackendID = .phone) {
        let line = prompt
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !line.isEmpty else { return }
        var hints = WorkspaceStorage.titleHints(for: backend)
        guard hints[sessionID] == nil else { return }
        hints[sessionID] = line.count > limit ? String(line.prefix(limit)) + "…" : line
        WorkspaceStorage.setTitleHint(hints[sessionID] ?? "", for: backend, sessionID: sessionID)
    }

    static func title(for sessionID: String, backend: BackendID = .phone) -> String? {
        WorkspaceStorage.titleHints(for: backend)[sessionID]
    }

    /// Load the whole hint map once for a list decode. Do not call `title(for:)`
    /// per row: that re-reads and re-filters the UserDefaults map each time.
    static func titles(for backend: BackendID) -> [String: String] {
        WorkspaceStorage.titleHints(for: backend)
    }
}
