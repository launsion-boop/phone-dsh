// SPDX-License-Identifier: MIT
// Cached PC/phone workspace grouping.
//
// A paired PC can expose thousands of Sessions across dozens of Workspaces.
// The drawer used to recompute membership by scanning the whole Session array
// for every Workspace on every SwiftUI body evaluation (O(sessions ×
// workspaces)) and by asking `PCLinkWorkspaceGrouping` for the longest cwd
// prefix once more per ungrouped row. With 3,500 Sessions that was measured at
// ~137 ms per body on a fast Mac; a workspace/follow event storm re-ran it.
//
// `PCWorkspaceIndex` builds the same grouping in one pass (O(sessions +
// memberships + ungrouped × workspaces for the cwd fallback)) and the model
// caches it until Sessions, Workspaces, order, pins or the archive set change.
// The ordering rules are identical to the previous computed properties:
//   * `sessions(in:)` follows `workspace.sessionIDs` order and omits archived;
//   * explicit membership wins over the cwd guess;
//   * the cwd guess is the longest matching workspace path at a component
//     boundary;
//   * `ungroupedSessions` is active order minus every explicit member.

import Foundation

/// One immutable grouping snapshot for a backend's Session/Workspace arrays.
public struct PCWorkspaceIndex: Sendable {
    /// Every Session, in the host's order.
    public let sessions: [ManagedSession]
    /// Sessions not in `archivedIDs`, in host order.
    public let activeSessions: [ManagedSession]
    /// Sessions in `archivedIDs`, in host order.
    public let archivedSessions: [ManagedSession]
    /// Pinned active Sessions in pin order.
    public let pinnedSessions: [ManagedSession]
    /// Active Sessions that no Workspace lists explicitly, in host order.
    public let ungroupedSessions: [ManagedSession]
    /// Active ungrouped Sessions whose cwd owns no Workspace path.
    public let looseSessions: [ManagedSession]
    /// Workspaces in `workspaceOrder`, then any unlisted Workspaces in input
    /// order. Each id appears once.
    public let orderedWorkspaces: [ManagedWorkspace]
    /// Explicit `workspace.sessionIDs` rows, archived omitted, membership order.
    public let sessionsByWorkspaceID: [String: [ManagedSession]]
    /// Ungrouped rows whose cwd matches a Workspace path, in ungrouped order.
    public let extraSessionsByWorkspaceID: [String: [ManagedSession]]
    /// Explicit membership first, then the longest cwd match.
    public let workspaceIDBySessionID: [String: String]
    /// Latest `updatedAt` over the Workspace's explicit membership (including
    /// archived rows), matching the old `latestActivity(in:)` oracle.
    public let latestActivityByWorkspaceID: [String: Date]
    /// The most recently active Workspace, or nil when there are none.
    public let recentWorkspaceID: String?

    public init(sessions: [ManagedSession],
                workspaces: [ManagedWorkspace],
                workspaceOrder: [String] = [],
                pinnedSessionIDs: [String] = [],
                archivedIDs: Set<String> = []) {
        self.sessions = sessions

        // First occurrence wins, like `sessions.first(where:)` in the old code.
        var allByID: [String: ManagedSession] = [:]
        allByID.reserveCapacity(sessions.count)
        var activeByID: [String: ManagedSession] = [:]
        activeByID.reserveCapacity(sessions.count)
        var active: [ManagedSession] = []
        active.reserveCapacity(sessions.count)
        var archived: [ManagedSession] = []
        for session in sessions {
            if allByID[session.id] == nil { allByID[session.id] = session }
            if archivedIDs.contains(session.id) {
                archived.append(session)
                continue
            }
            if activeByID[session.id] == nil { activeByID[session.id] = session }
            active.append(session)
        }
        self.activeSessions = active
        self.archivedSessions = archived

        self.pinnedSessions = pinnedSessionIDs.compactMap { activeByID[$0] }

        // Explicit membership is first-workspace-wins, matching
        // `workspaces.first(where: { $0.sessionIDs.contains(id) })`.
        var explicitWorkspaceID: [String: String] = [:]
        explicitWorkspaceID.reserveCapacity(sessions.count)
        var memberIDs = Set<String>()
        memberIDs.reserveCapacity(sessions.count)
        for workspace in workspaces {
            for id in workspace.sessionIDs {
                memberIDs.insert(id)
                if explicitWorkspaceID[id] == nil { explicitWorkspaceID[id] = workspace.id }
            }
        }
        self.ungroupedSessions = active.filter { !memberIDs.contains($0.id) }

        // Longest matching path at a component boundary. Paths ending in "/"
        // keep the old `path == cwd || cwd.hasPrefix(path + "/")` meaning.
        let pathOrderedWorkspaces = workspaces.sorted { $0.path.count > $1.path.count }
        var cwdWorkspaceID: [String: String] = [:]
        cwdWorkspaceID.reserveCapacity(sessions.count)
        for session in sessions where explicitWorkspaceID[session.id] == nil {
            guard let cwd = session.cwd, !cwd.isEmpty else { continue }
            for workspace in pathOrderedWorkspaces {
                let path = workspace.path
                guard path == cwd || cwd.hasPrefix(path.hasSuffix("/") ? path : path + "/") else {
                    continue
                }
                cwdWorkspaceID[session.id] = workspace.id
                break
            }
        }

        var resolvedWorkspaceID = explicitWorkspaceID
        for (id, workspaceID) in cwdWorkspaceID where resolvedWorkspaceID[id] == nil {
            resolvedWorkspaceID[id] = workspaceID
        }
        self.workspaceIDBySessionID = resolvedWorkspaceID

        var own: [String: [ManagedSession]] = [:]
        own.reserveCapacity(workspaces.count)
        for workspace in workspaces {
            var rows: [ManagedSession] = []
            rows.reserveCapacity(workspace.sessionIDs.count)
            for id in workspace.sessionIDs {
                if let session = activeByID[id] { rows.append(session) }
            }
            own[workspace.id] = rows
        }
        self.sessionsByWorkspaceID = own

        var extra: [String: [ManagedSession]] = [:]
        for session in self.ungroupedSessions {
            guard let workspaceID = cwdWorkspaceID[session.id] else { continue }
            extra[workspaceID, default: []].append(session)
        }
        self.extraSessionsByWorkspaceID = extra
        self.looseSessions = self.ungroupedSessions.filter { cwdWorkspaceID[$0.id] == nil }

        var ordered: [ManagedWorkspace] = []
        ordered.reserveCapacity(workspaces.count)
        var workspaceByID: [String: ManagedWorkspace] = [:]
        workspaceByID.reserveCapacity(workspaces.count)
        for workspace in workspaces where workspaceByID[workspace.id] == nil {
            workspaceByID[workspace.id] = workspace
        }
        var seen = Set<String>()
        seen.reserveCapacity(workspaces.count)
        for id in workspaceOrder {
            guard let workspace = workspaceByID[id], seen.insert(id).inserted else { continue }
            ordered.append(workspace)
        }
        for workspace in workspaces where seen.insert(workspace.id).inserted {
            ordered.append(workspace)
        }
        self.orderedWorkspaces = ordered

        var latest: [String: Date] = [:]
        latest.reserveCapacity(workspaces.count)
        for workspace in workspaces {
            var value = Date.distantPast
            for id in workspace.sessionIDs {
                guard let session = allByID[id], session.updatedAt > value else { continue }
                value = session.updatedAt
            }
            latest[workspace.id] = value
        }
        self.latestActivityByWorkspaceID = latest
        self.recentWorkspaceID = workspaces.max {
            (latest[$0.id] ?? .distantPast) < (latest[$1.id] ?? .distantPast)
        }?.id
    }

    /// Explicit rows for one Workspace in membership order, archived omitted.
    public func sessions(in workspace: ManagedWorkspace) -> [ManagedSession] {
        sessionsByWorkspaceID[workspace.id] ?? []
    }

    /// Ungrouped rows whose cwd matches one Workspace path.
    public func extraSessions(in workspaceID: String) -> [ManagedSession] {
        extraSessionsByWorkspaceID[workspaceID] ?? []
    }

    /// Explicit membership first, then the longest matching cwd.
    public func workspaceID(for session: ManagedSession) -> String? {
        workspaceIDBySessionID[session.id]
    }

    /// Latest activity over a Workspace's explicit membership.
    public func latestActivity(in workspace: ManagedWorkspace) -> Date {
        latestActivityByWorkspaceID[workspace.id] ?? .distantPast
    }
}

/// Revision-keyed cache for the grouping snapshot. The owner bumps `revision`
/// only when a grouping input changes; a SwiftUI body that reads the index
/// twice in one frame (drawer rows, counts, remember-order) gets the same
/// value without rebuilding.
public final class PCWorkspaceIndexCache {
    public private(set) var rebuildCount = 0
    private var cachedRevision: UInt64 = .max
    private var cachedIndex: PCWorkspaceIndex?

    public init() {}

    public func index(revision: UInt64,
                      sessions: [ManagedSession],
                      workspaces: [ManagedWorkspace],
                      workspaceOrder: [String],
                      pinnedSessionIDs: [String],
                      archivedIDs: Set<String>) -> PCWorkspaceIndex {
        if let cachedIndex, cachedRevision == revision { return cachedIndex }
        rebuildCount += 1
        let index = PCWorkspaceIndex(
            sessions: sessions,
            workspaces: workspaces,
            workspaceOrder: workspaceOrder,
            pinnedSessionIDs: pinnedSessionIDs,
            archivedIDs: archivedIDs)
        cachedIndex = index
        cachedRevision = revision
        return index
    }
}
