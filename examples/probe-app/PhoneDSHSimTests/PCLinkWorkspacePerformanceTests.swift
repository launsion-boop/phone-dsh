// SPDX-License-Identifier: MIT
// pclink-pc-lag performance regressions.
//
// Synthetic fixture: 3,500 Sessions across 60 Workspaces, the size of the real
// PC `session/list` projection (~5.5 MB on the wire). The tests print the
// measured milliseconds so a run leaves a before/after record instead of an
// unverifiable claim.

import Foundation
import PhoneDSHAgentCore
import ProbeKit
import XCTest

final class PCLinkWorkspacePerformanceTests: XCTestCase {
    private let sessionCount = 3_500
    private let workspaceCount = 60

    // MARK: - Fixture

    private func makeSession(_ index: Int, cwd: String?) -> ManagedSession {
        ManagedSession(
            id: "session-\(index)-0123456789abcdef",
            title: "Session \(index)",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
            running: index % 7 == 0,
            blank: index % 11 == 0,
            cwd: cwd,
            parentSessionID: nil,
            searchSnippet: nil)
    }

    private func makeFixture() -> ([ManagedSession], [ManagedWorkspace]) {
        let paths = (0..<workspaceCount).map { "/Users/example/projects/team-\($0)" }
        var sessions: [ManagedSession] = []
        sessions.reserveCapacity(sessionCount)
        var members: [[String]] = Array(repeating: [], count: workspaceCount)
        for index in 0..<sessionCount {
            let workspace = index % workspaceCount
            let session = makeSession(index, cwd: paths[workspace])
            sessions.append(session)
            members[workspace].append(session.id)
        }
        let workspaces = (0..<workspaceCount).map { workspace in
            ManagedWorkspace(id: "ws-\(workspace)",
                             title: "Workspace \(workspace)",
                             path: paths[workspace],
                             sessionIDs: members[workspace])
        }
        return (sessions, workspaces)
    }

    /// The pre-fix drawer computation, kept only as the measurement oracle.
    private func legacyGroupedRows(_ sessions: [ManagedSession],
                                   _ workspaces: [ManagedWorkspace],
                                   archived: Set<String>) -> [ManagedSession] {
        let active = sessions.filter { !archived.contains($0.id) }
        let members = Set(workspaces.flatMap(\.sessionIDs))
        let ungrouped = active.filter { !members.contains($0.id) }
        var rows: [ManagedSession] = []
        rows.reserveCapacity(sessions.count)
        for workspace in workspaces {
            let own = workspace.sessionIDs.compactMap { id in
                sessions.first(where: { $0.id == id && !archived.contains(id) })
            }
            let extra = ungrouped.filter {
                PCLinkWorkspaceGrouping.workspaceID(for: $0, in: workspaces) == workspace.id
            }
            rows.append(contentsOf: own + extra)
        }
        rows.append(contentsOf: ungrouped.filter {
            PCLinkWorkspaceGrouping.workspaceID(for: $0, in: workspaces) == nil
        })
        return rows
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private func milliseconds(_ body: () -> Void) -> Double {
        let start = CFAbsoluteTimeGetCurrent()
        body()
        return (CFAbsoluteTimeGetCurrent() - start) * 1_000
    }

    // MARK: - Equivalence

    func testCachedIndexMatchesLegacyGroupingOracle() {
        let (sessions, workspaces) = makeFixture()
        let archived: Set<String> = [sessions[3].id, sessions[777].id]
        let pinned = [sessions[10].id, sessions[1].id]
        let index = PCWorkspaceIndex(sessions: sessions,
                                     workspaces: workspaces,
                                     workspaceOrder: workspaces.map(\.id),
                                     pinnedSessionIDs: pinned,
                                     archivedIDs: archived)

        let legacy = legacyGroupedRows(sessions, workspaces, archived: archived)
        XCTAssertEqual(index.activeSessions.count, sessions.count - archived.count)
        XCTAssertEqual(index.pinnedSessions.map(\.id), pinned)
        XCTAssertEqual(index.ungroupedSessions.map(\.id), [])
        XCTAssertEqual(index.looseSessions.map(\.id), [])
        let grouped = index.orderedWorkspaces.flatMap { index.sessions(in: $0).map(\.id) }
        XCTAssertEqual(grouped, legacy.map(\.id),
                       "cached membership must preserve the old workspace/member order")
        XCTAssertEqual(index.orderedWorkspaces.first?.id, "ws-0")
        XCTAssertEqual(index.recentWorkspaceID, "ws-19")
        let reversed = PCWorkspaceIndex(sessions: sessions,
                                        workspaces: workspaces,
                                        workspaceOrder: Array(workspaces.map(\.id).reversed()),
                                        pinnedSessionIDs: [], archivedIDs: [])
        XCTAssertEqual(reversed.orderedWorkspaces.first?.id, "ws-59",
                       "workspaceOrder wins over the input order")

        // Explicit membership wins; the longest cwd prefix wins; a sibling path
        // with a shared string prefix does not match.
        let explicit = makeSession(10_001, cwd: "/work/beta/sub")
        let cwdOnly = makeSession(10_002, cwd: "/work/alpha/sub/x")
        let sibling = makeSession(10_003, cwd: "/work/alphabet")
        let alpha = ManagedWorkspace(id: "alpha", title: "Alpha", path: "/work/alpha",
                                     sessionIDs: [explicit.id])
        let beta = ManagedWorkspace(id: "beta", title: "Beta", path: "/work/alpha/sub",
                                    sessionIDs: [])
        let small = PCWorkspaceIndex(sessions: [explicit, cwdOnly, sibling],
                                     workspaces: [alpha, beta],
                                     workspaceOrder: [],
                                     pinnedSessionIDs: [],
                                     archivedIDs: [])
        XCTAssertEqual(small.workspaceID(for: explicit), "alpha")
        XCTAssertEqual(small.workspaceID(for: cwdOnly), "beta")
        XCTAssertNil(small.workspaceID(for: sibling))
        XCTAssertEqual(small.extraSessions(in: "beta").map(\.id), [cwdOnly.id])
        XCTAssertEqual(small.looseSessions.map(\.id), [sibling.id])
    }

    func testIndexCacheRebuildsOnlyWhenInputRevisionChanges() {
        let (sessions, workspaces) = makeFixture()
        let cache = PCWorkspaceIndexCache()
        for _ in 0..<100 {
            _ = cache.index(revision: 7, sessions: sessions, workspaces: workspaces,
                            workspaceOrder: workspaces.map(\.id),
                            pinnedSessionIDs: [], archivedIDs: [])
        }
        XCTAssertEqual(cache.rebuildCount, 1,
                       "a workspace/follow event storm must not rebuild an unchanged grouping")
        _ = cache.index(revision: 8, sessions: sessions, workspaces: workspaces,
                        workspaceOrder: workspaces.map(\.id),
                        pinnedSessionIDs: [], archivedIDs: [])
        XCTAssertEqual(cache.rebuildCount, 2,
                       "a real input change must rebuild once")
    }

    // MARK: - Performance records

    /// The old drawer body scan vs the cached read. Printed for the report; the
    /// assertion is intentionally loose (a shared CI host may be noisy).
    func testGroupingPerformanceLegacyVersusCachedIndex() {
        let (sessions, workspaces) = makeFixture()
        var legacyTimes: [Double] = []
        for _ in 0..<3 {
            legacyTimes.append(milliseconds {
                let rows = legacyGroupedRows(sessions, workspaces, archived: [])
                XCTAssertEqual(rows.count, sessions.count)
            })
        }

        let cache = PCWorkspaceIndexCache()
        var buildTimes: [Double] = []
        for revision in 0..<5 {
            buildTimes.append(milliseconds {
                _ = cache.index(revision: UInt64(revision), sessions: sessions,
                                workspaces: workspaces,
                                workspaceOrder: workspaces.map(\.id),
                                pinnedSessionIDs: [], archivedIDs: [])
            })
        }
        let index = cache.index(revision: 99, sessions: sessions, workspaces: workspaces,
                                workspaceOrder: workspaces.map(\.id),
                                pinnedSessionIDs: [], archivedIDs: [])
        let readTime = milliseconds {
            for _ in 0..<100 {
                var count = 0
                for workspace in index.orderedWorkspaces {
                    count += index.sessions(in: workspace).count
                    count += index.extraSessions(in: workspace.id).count
                }
                count += index.looseSessions.count
                XCTAssertEqual(count, sessions.count)
            }
        }

        let legacy = median(legacyTimes)
        let build = median(buildTimes)
        print(String(format: "PCLINK-PERF grouping legacy=%.1fms indexBuild=%.1fms cachedRead100x=%.2fms",
                     legacy, build, readTime))
        XCTAssertLessThan(build, max(1, legacy / 4),
                          "the cached one-pass build must be much cheaper than the old O(S×W) body scan")
    }

    /// 3,500 rows with a title projection and a large metadata block (roughly
    /// the real 5.5 MB list once encoded). The row decoder must run off the
    /// MainActor and must be cheap enough to keep the drawer responsive.
    @MainActor
    func testSessionDecodeRunsOffMainAndPerformance() async {
        var items: [JSONValue] = []
        items.reserveCapacity(sessionCount)
        let filler = String(repeating: "x", count: 1_100)
        for index in 0..<sessionCount {
            items.append(.object([
                "sessionId": .string("session-\(index)-0123456789abcdef"),
                "updatedAt": .number(1_700_000_000_000 + Double(index)),
                "running": .bool(index % 7 == 0),
                "blank": .bool(index % 11 == 0),
                "cwd": .string("/Users/example/projects/team-\(index % workspaceCount)"),
                "projections": .object(["values": .object([
                    "title": .string("Session \(index) title"),
                    "agentPreset": .string("standard"),
                    "preview": .string(filler),
                ])]),
            ]))
        }
        let value = JSONValue.object(["items": .array(items)])

        final class ThreadRecorder: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var mainThreads: [Bool] = []
            func record(_ isMain: Bool) {
                lock.lock(); defer { lock.unlock() }
                mainThreads.append(isMain)
            }
        }
        let recorder = ThreadRecorder()
        let start = CFAbsoluteTimeGetCurrent()
        let rows = await PCWorkspaceDecoding.decodeSessionsOffMain(
            value, titleHints: [:], onDecodeThread: { recorder.record($0) })
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1_000
        print(String(format: "PCLINK-PERF decodeSessions rows=%d offMain=%.1fms", rows.count, elapsed))
        XCTAssertEqual(rows.count, sessionCount)
        XCTAssertEqual(rows.first?.id, "session-3499-0123456789abcdef",
                       "decodeSessions keeps the host's newest-first ordering")
        XCTAssertEqual(rows.last?.id, "session-0-0123456789abcdef")
        XCTAssertFalse(recorder.mainThreads.contains(true),
                       "session/list row decoding must not run on the MainActor")
        XCTAssertLessThan(elapsed, 2_000)
    }

    /// Event storm regression: 100 triggers inside the debounce window start
    /// one management read, not 100.
    @MainActor
    func testRefreshDebouncerCoalescesBurst() async {
        let debouncer = PCLinkRefreshDebouncer(delay: .milliseconds(80))
        for _ in 0..<100 {
            debouncer.schedule {}
        }
        XCTAssertEqual(debouncer.requestedCount, 100)
        XCTAssertEqual(debouncer.runCount, 0)
        try? await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(debouncer.runCount, 1,
                       "a burst inside the window must start one refresh")
    }

    /// Regression for the real main-thread trap: `SessionTitleHints.title(for:)`
    /// used to call `WorkspaceStorage.titleHints(for:)` per row, which reads and
    /// filters the whole UserDefaults map each time. The bulk load keeps the
    /// per-row dictionary lookup.
    @MainActor
    func testTitleHintsBulkLoadAvoidsPerRowUserDefaultsScan() throws {
        let suite = "pclink-perf-hints-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let backend = BackendID.pc(machineId: "aaaaaaaaaaaaaaaaaaaaaaaaaa")
        var hints: [String: String] = [:]
        hints.reserveCapacity(sessionCount)
        for index in 0..<sessionCount {
            hints["session-\(index)"] = "Title \(index)"
        }
        var stored: [String: String] = [
            WorkspaceStorage.titleHintKey(backend: backend, sessionID: "seed"): "seed",
        ]
        for (id, title) in hints {
            stored[WorkspaceStorage.titleHintKey(backend: backend, sessionID: id)] = title
        }
        defaults.set(stored, forKey: WorkspaceStorageKeys.titleHints)

        let perRow = milliseconds {
            for index in 0..<sessionCount {
                _ = WorkspaceStorage.titleHints(for: backend, defaults: defaults)["session-\(index)"]
            }
        }
        var bulk: [String: String] = [:]
        let bulkTime = milliseconds {
            bulk = WorkspaceStorage.titleHints(for: backend, defaults: defaults)
            for index in 0..<sessionCount {
                _ = bulk["session-\(index)"]
            }
        }
        print(String(format: "PCLINK-PERF titleHints perRow=%.1fms bulkOnce=%.2fms", perRow, bulkTime))
        XCTAssertEqual(bulk.count, sessionCount + 1)
        XCTAssertLessThan(bulkTime, perRow,
                          "loading the hint map once must beat the per-row UserDefaults scan")
    }
}
