// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — G2-F01: scoped descendant teardown before Worker stop.
//
// A spawned subagent owns its own durable DSH session and activation. A parent
// `session/cancel` (or a host stop after the parent turn ended) therefore does
// not make the child terminal: the child can legitimately continue after its
// parent is cancelled. `PhoneDSHTrackedTransport` only observes the App's root
// `session/create`/`session/prompt`, and `abortOpenSessionTurns` only drains the
// ids in that registry, so before this file the Worker could be torn down with
// a live child `turn/start` and no `turn/end`.
//
// The pinned DSH public service already owns the correct primitive:
// `ctx.subagents.drainDescendants([rootAgent])` closes admission below the
// exact live roots and awaits child-first disposal. The Worker surface exposes
// that public call on the existing authenticated `/api` carrier; this file is
// the host half:
//
//   * ``PhoneDSHDescendantDrainRequest`` / ``PhoneDSHDescendantDrainReceipt``
//     carry the exact root ids and the route's bounded answer;
//   * ``PhoneDSHDescendantSessions`` reads the durable session headers
//     (`origin: "subagent"`, `parentSession`) and walks the real parent chain,
//     so verification includes grandchildren without treating every journal
//     below `sessions/` as this host's child;
//   * ``PhoneDSHDescendantDrain`` performs the one bounded route call and never
//     turns a timeout or a malformed receipt into success.
//
// Swift only reads DSH's session records. The terminal `turn/end` is appended
// by the pinned Worker session layer during its own child disposal.

import Foundation
import PhoneDSHAgentCore
import PhoneDSHWire

/// Wire facts of the phone-only descendant-drain route.
public enum PhoneDSHDescendantDrainProtocol {
    /// Exact shared-API path served by `@phone-dsh/dsh-surface-phone`.
    public static let path = "/api/pdsh-descendant-drain"
    /// Request and response media type.
    public static let contentType = "application/json"
    /// Receipt protocol recorded by the route.
    public static let receiptProtocol = "pdsh-descendant-drain/1"
    /// Default budget for one scoped drain, in milliseconds.
    public static let defaultBudgetMilliseconds = 5_000
    /// Server-side clamp for a host-supplied budget.
    public static let maximumBudgetMilliseconds = 20_000
    /// Smallest positive budget (a deadline always beats no deadline).
    public static let minimumBudgetMilliseconds = 1
    /// Maximum exact roots one route request may name. This mirrors the
    /// Worker route's `DESCENDANT_DRAIN_MAX_ROOTS`; the host batches larger
    /// tracked-root sets instead of letting one 400 abort the teardown.
    public static let maximumRoots = 64
}

/// Bounded time the Worker may spend draining descendants for one request.
public struct PhoneDSHDescendantDrainBudget: Equatable, Sendable {
    /// Milliseconds from request receipt to the route deadline.
    public var timeoutMilliseconds: Int

    /// Creates a budget, clamped to the protocol's accepted range.
    public init(timeoutMilliseconds: Int) {
        self.timeoutMilliseconds = min(
            max(timeoutMilliseconds, PhoneDSHDescendantDrainProtocol.minimumBudgetMilliseconds),
            PhoneDSHDescendantDrainProtocol.maximumBudgetMilliseconds)
    }

    /// The default budget, used by callers that do not have a host deadline.
    public static let standard = PhoneDSHDescendantDrainBudget(
        timeoutMilliseconds: PhoneDSHDescendantDrainProtocol.defaultBudgetMilliseconds)
}

/// One scoped descendant-drain request.
public struct PhoneDSHDescendantDrainRequest: Equatable, Sendable {
    /// Exact live App-owned root sessions; never child ids.
    public var rootSessionIDs: [String]
    /// Bounded route budget.
    public var budget: PhoneDSHDescendantDrainBudget

    /// Creates the request with a stable order (the host's snapshot order).
    public init(rootSessionIDs: [String],
                budget: PhoneDSHDescendantDrainBudget = .standard) {
        self.rootSessionIDs = rootSessionIDs
        self.budget = budget
    }

    /// The exact JSON object the route validates.
    public var json: JSONValue {
        .object([
            "sessionIds": .array(rootSessionIDs.map { .string($0) }),
            "timeoutMs": .number(Double(budget.timeoutMilliseconds)),
        ])
    }
}

/// Typed view of one `pdsh-descendant-drain/1` receipt.
///
/// The receipt is diagnostic only: the durable session journals prove the
/// terminal state. A malformed receipt still fails loud rather than being
/// mistaken for a completed drain.
public struct PhoneDSHDescendantDrainReceipt: Equatable, Sendable {
    /// The receipt object returned by the Worker route.
    public var raw: JSONValue

    /// Parses one receipt value and validates its protocol marker.
    public init(raw: JSONValue) throws {
        guard case .object(let object) = raw,
              object["protocol"]?.stringValue == PhoneDSHDescendantDrainProtocol.receiptProtocol else {
            throw PhoneDSHError.invalidResponse(
                "the Worker returned no pdsh-descendant-drain/1 receipt")
        }
        // The live-descendant set is part of the verification contract: without
        // it the host cannot distinguish a cold-resumed old child from a stale
        // crash journal. A receipt that omits the field, or carries non-string
        // entries, is malformed, not an empty live set.
        guard let descendants = object["descendants"]?.arrayValue,
              descendants.allSatisfy({ $0.stringValue != nil }) else {
            throw PhoneDSHError.invalidResponse(
                "the Worker descendant-drain receipt named no usable live descendants")
        }
        self.raw = raw
    }

    private var object: [String: JSONValue] {
        if case .object(let object) = raw { return object }
        return [:]
    }

    /// Live root session ids the route actually drained.
    public var roots: [String] {
        object["roots"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    /// Requested roots that were no longer live in this Worker incarnation.
    public var missing: [String] {
        object["missing"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    /// Live descendant session ids the route actually drained in this call.
    ///
    /// This set is the host's authority for a descendant whose durable header
    /// predates this Worker incarnation. DSH cold resume reuses the child session
    /// id *and* its persisted header, so `createdAt` alone cannot tell a live
    /// resumed child from a stale crash journal. A reported id is verified even
    /// when its header is old; only an old header the route did **not** report
    /// is treated as stale.
    public var descendants: [String] {
        object["descendants"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    /// Wall-clock duration of the scoped drain in the Worker.
    public var durationMilliseconds: Int? { object["durationMs"]?.intValue }
}

/// A transport that can ask the live Worker to drain descendants of exact roots.
///
/// Kept separate from `DSHRemoteTransport` so ordinary fake transports remain
/// unchanged and an unsupported transport cannot silently claim a child was
/// disposed.
public protocol PhoneDSHDescendantDrainCalling: Sendable {
    /// Whether this transport really exposes the phone route.
    ///
    /// ``PhoneDSHTrackedTransport`` always conforms so the host can keep the
    /// tracked wrapper; it forwards the capability of the channel it wraps. A
    /// scripted/legacy base returns `false`, which lets the host skip the call
    /// only when no descendant journal was observed.
    func supportsDescendantDrain() async -> Bool
    /// Waits on the Worker's public `subagents.drainDescendants(roots)` call.
    func drainDescendantSessions(_ request: PhoneDSHDescendantDrainRequest) async throws
        -> PhoneDSHDescendantDrainReceipt
}

extension PhoneDSHDescendantDrainCalling {
    /// Real transports expose the route unless they explicitly say otherwise.
    public func supportsDescendantDrain() async -> Bool { true }
}

extension ChannelDSHTransport: PhoneDSHDescendantDrainCalling {
    /// Post one scoped drain to the phone-only route. A non-200 answer is a
    /// transport/route failure, never a synthesized terminal record.
    public func drainDescendantSessions(_ request: PhoneDSHDescendantDrainRequest) async throws
        -> PhoneDSHDescendantDrainReceipt {
        let body: Data
        do {
            body = try request.json.encoded()
        } catch {
            throw PhoneDSHError.invalidResponse("cannot encode the descendant-drain request")
        }
        let head = ApiRequestHead(method: "POST", path: PhoneDSHDescendantDrainProtocol.path,
                                  headers: [
                                    PhoneDSHMuxProtocol.contentTypeHeader:
                                        PhoneDSHDescendantDrainProtocol.contentType,
                                    "accept": PhoneDSHDescendantDrainProtocol.contentType,
                                  ])
        let result = try await sendWithReconnect(head: head, body: body)
        guard result.status == 200 else {
            let message = String(decoding: result.body.prefix(256), as: UTF8.self)
            throw DSHRemoteError(code: "descendant-drain/http-\(result.status)",
                                 message: message.isEmpty ? "HTTP \(result.status)" : message)
        }
        guard let envelope = try? JSONValue.parse(result.body),
              envelope["ok"]?.boolValue == true,
              let value = envelope["value"] else {
            throw PhoneDSHError.invalidResponse(
                "the descendant-drain route returned no successful receipt envelope")
        }
        return try PhoneDSHDescendantDrainReceipt(raw: value)
    }
}

// The receipt uses only `.arrayValue`, which the phone module's local
// `JSONValue` helpers did not need before this feature. Keep the helper local
// instead of widening the landed public provider value.
private extension JSONValue {
    var arrayValue: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }
}

// MARK: - Durable session forest

/// The roots and their recursively reachable subagent descendants.
public struct PhoneDSHDescendantForest: Equatable, Sendable {
    /// Full turn state for every root and descendant that has a journal.
    public var states: [String: PhoneDSHSessionTurnState]
    /// Exact roots supplied by the host.
    public var rootSessionIDs: Set<String>
    /// Sessions whose durable header chain reaches a root.
    public var descendantSessionIDs: Set<String>

    /// Every session this teardown must verify (roots plus descendants).
    public var sessionIDs: Set<String> {
        rootSessionIDs.union(descendantSessionIDs)
    }

    /// Open turns across the forest, keyed by session id.
    public var openTurns: [String: Int] {
        states.compactMapValues { $0.isTurnOpen ? $0.openTurn : nil }
    }

    /// Open turns that belong to subagent descendants (never roots).
    ///
    /// A terminal child journal is still part of ``descendantSessionIDs``; the
    /// teardown must not demand a live root for it. Only this subset is
    /// evidence that a child activation may still be running.
    public var openDescendantSessionIDs: Set<String> {
        Set(openTurns.keys).intersection(descendantSessionIDs)
    }

    /// The tracked root whose durable `parentSession` chain reaches a child.
    ///
    /// Returns `nil` when `sessionID` is not a descendant in this forest or
    /// when its lineage does not reach one of the supplied roots.
    public func rootSessionID(forDescendant sessionID: String) -> String? {
        guard descendantSessionIDs.contains(sessionID) else { return nil }
        var seen: Set<String> = []
        var current = states[sessionID]?.parentSessionID
        while let parent = current, seen.insert(parent).inserted {
            if rootSessionIDs.contains(parent) { return parent }
            current = states[parent]?.parentSessionID
        }
        return nil
    }

    /// Roots that still have a durable descendant journal.
    public var rootsWithDescendants: Set<String> {
        Set(descendantSessionIDs.compactMap { rootSessionID(forDescendant: $0) })
    }

    /// Whether every observed root/descendant journal ends on a closed turn.
    public var allTurnsTerminal: Bool {
        states.values.allSatisfy { !$0.isTurnOpen }
    }

    /// Requires every route-reported live descendant to be in the durable
    /// verification closure.
    ///
    /// The forest only contains a session when its journal is readable and its
    /// `origin: "subagent"` / `parentSession` chain reaches a tracked root. A
    /// route receipt is diagnostic, not terminal evidence: if it names a child
    /// whose journal has not materialized (or whose intermediate parent is
    /// missing), silently dropping that id would let the abort verify a smaller
    /// set and park as if the child were closed. A missing id is an unknown
    /// child, never convergence.
    ///
    /// - Parameter liveDescendantIDs: descendant ids the route reported live in
    ///   this Worker incarnation.
    /// - Throws: ``PhoneDSHError/invalidState`` with the first unverifiable id.
    public func requireVerifiableLiveDescendants(
        _ liveDescendantIDs: Set<String>
    ) throws {
        for sessionID in liveDescendantIDs.sorted() {
            guard states[sessionID] != nil,
                  descendantSessionIDs.contains(sessionID) else {
                throw PhoneDSHError.invalidState(
                    "the scoped descendant drain reported live subagent session "
                        + "\(sessionID), but its durable journal or parent "
                        + "lineage is not in the verification forest; an "
                        + "unmaterialized or unlinked child turn cannot be "
                        + "proven terminal")
            }
        }
    }
}

/// Reads the materialized DSH session headers and follows `parentSession`.
public enum PhoneDSHDescendantSessions {
    /// Maximum bytes read from one journal to find its header line.
    ///
    /// The physical header is one small JSON object. A journal that has not
    /// produced a complete header inside this bound is corrupt or still being
    /// written; it is a read failure, not "no descendant".
    public static let maximumHeaderBytes = 64 * 1024

    /// Builds the root + descendant closure from durable session headers.
    ///
    /// Only sessions whose header is `origin: "subagent"`, whose parent chain
    /// reaches one of `rootSessionIDs`, and that are either current
    /// (`createdAt` not older than `incarnationStart`) or explicitly reported
    /// live by this Worker incarnation are descendants. A stale journal from an
    /// earlier boot, or an unrelated root, is never included just because it
    /// lives below the same sessions directory.
    ///
    /// The explicit live set matters because DSH cold resume reuses the same
    /// child session id *and* its persisted header, including the old
    /// `createdAt`. Such a child can own a live Activation and an open turn in
    /// this incarnation while its journal still looks old. Excluding it by
    /// timestamp would skip the durable `turn/end` verification and let a route
    /// that silently missed the drain look converged. The route reports the
    /// exact live descendant ids it drained; an old journal not in that set is
    /// a true stale crash record with no resident Activation, so a live
    /// `drainDescendants` call cannot append its `turn/end`; cold-resume
    /// recovery owns that record instead.
    ///
    /// A directory/file that cannot be read, a journal whose header is
    /// incomplete, or a reachable descendant header that is not reported live
    /// and has no `createdAt` throws: silently dropping it would make an
    /// unreadable, still-materializing or unclassifiable child look like an
    /// empty forest.
    ///
    /// - Parameters:
    ///   - directory: materialized `home/sessions` directory.
    ///   - rootSessionIDs: exact session ids this host incarnation opened.
    ///   - incarnationStart: start of the current Worker incarnation (a new
    ///     Worker boot, not only a new host start); `nil` disables
    ///     the stale-descendant boundary (tests of the pure lineage walk).
    ///   - liveDescendantSessionIDs: descendant ids the Worker route reported
    ///     live/drained in this incarnation. They are included regardless of
    ///     their persisted `createdAt`, and make their own descendants
    ///     reachable.
    ///   - cache: optional full-journal parse cache for the second pass.
    ///   - fileManager: file manager used for the directory walk.
    /// - Returns: the closure and the parsed journal states.
    public static func forest(inSessionsDirectory directory: URL,
                              rootSessionIDs: Set<String>,
                              incarnationStart: Date? = nil,
                              liveDescendantSessionIDs: Set<String> = [],
                              cache: PhoneDSHJournalStateCache? = nil,
                              fileManager: FileManager = .default) throws
        -> PhoneDSHDescendantForest {
        // Pass 1: read only the first JSONL record of every session journal.
        // This discovers the durable lineage without reading a large log for a
        // session that is not part of this teardown.
        var headers: [String: PhoneDSHSessionTurnState] = [:]
        var journals: [String: URL] = [:]
        for sessionDirectory in try sessionDirectories(in: directory,
                                                       fileManager: fileManager) {
            guard let journal = try currentJournal(in: sessionDirectory,
                                                   fileManager: fileManager) else {
                // A directory with no journal yet is not lineage evidence. It
                // is not a read failure either; a later pass can see the file
                // once DSH publishes its header.
                continue
            }
            var state = try headerState(of: journal)
            let directoryID = sessionDirectory.lastPathComponent
            if state.sessionID == nil { state.sessionID = directoryID }
            let id = state.sessionID ?? directoryID
            headers[id] = state
            journals[id] = journal
        }

        // A child header older than the Worker incarnation boundary belongs to
        // the previous crash. Keep the boundary in the same millisecond unit
        // as the physical `createdAt` field; the inclusive comparison keeps a
        // child created in the Worker's start millisecond.
        let incarnationCutoffMillis = incarnationStart.map {
            Int64(($0.timeIntervalSince1970 * 1000).rounded(.down))
        }

        // Pass 2: close over `parentSession`. Repeating the scan handles a
        // grandchild published before its parent was observed in dictionary
        // order; the set is small and bounded by the session tree.
        var reachable = rootSessionIDs
        var changed = true
        while changed {
            changed = false
            for (id, header) in headers where !reachable.contains(id) {
                guard header.origin == "subagent",
                      let parent = header.parentSessionID,
                      reachable.contains(parent) else {
                    continue
                }
                if let cutoff = incarnationCutoffMillis,
                   !liveDescendantSessionIDs.contains(id) {
                    guard let createdAt = header.headerCreatedAtMillis else {
                        throw PhoneDSHError.invalidState(
                            "the DSH subagent session header for \(id) has no "
                                + "createdAt; cannot tell this Worker incarnation's "
                                + "child from a stale crash journal")
                    }
                    // Do not reach through a stale parent either: a journal
                    // created before this incarnation and not reported live by
                    // the Worker has no resident Activation in it. A
                    // cold-resumed child is in the live set above, so it stays
                    // reachable even though its persisted header is old.
                    guard createdAt >= cutoff else { continue }
                }
                reachable.insert(id)
                changed = true
            }
        }

        // Pass 3: parse the full turn boundaries for the closure only. The
        // incremental cache keeps repeated drain polls from re-reading an
        // unchanged journal. A journal in the closure that cannot be read is
        // fail loud; it may hold the only terminal turn/end.
        var states: [String: PhoneDSHSessionTurnState] = [:]
        for id in reachable {
            guard let journal = journals[id] else { continue }
            let freshState: PhoneDSHSessionTurnState
            if let cache {
                guard let cached = cache.state(forJournalAt: journal,
                                               fileManager: fileManager) else {
                    throw PhoneDSHError.invalidState(
                        "cannot read DSH session journal for \(id) at \(journal.path)")
                }
                freshState = cached
            } else {
                let data: Data
                do {
                    data = try Data(contentsOf: journal)
                } catch {
                    throw PhoneDSHError.invalidState(
                        "cannot read DSH session journal for \(id) at "
                            + "\(journal.path): \(error)")
                }
                freshState = PhoneDSHSessionLog.state(of: data)
            }
            var state = freshState
            state.sessionID = id
            states[id] = state
        }
        let descendants = Set(headers.keys.filter { id in
            guard reachable.contains(id), !rootSessionIDs.contains(id) else { return false }
            return headers[id]?.origin == "subagent"
        })
        return PhoneDSHDescendantForest(states: states,
                                        rootSessionIDs: rootSessionIDs,
                                        descendantSessionIDs: descendants)
    }

    /// Enumerates `<sessions>/<encoded-cwd>/<session-id>/` directories.
    ///
    /// A missing sessions directory means the host has not materialized any
    /// session yet and is an empty forest. Any other enumeration/stat error is
    /// fail loud: the caller must not treat an unreadable tree as childless.
    private static func sessionDirectories(in directory: URL,
                                           fileManager: FileManager) throws -> [URL] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let workspaces: [URL]
        do {
            workspaces = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])
        } catch {
            throw PhoneDSHError.invalidState(
                "cannot read the materialized DSH sessions directory at "
                    + "\(directory.path): \(error)")
        }
        var directories: [URL] = []
        for workspace in workspaces {
            let isWorkspace: Bool
            do {
                isWorkspace = try workspace.resourceValues(
                    forKeys: [.isDirectoryKey]).isDirectory == true
            } catch {
                throw PhoneDSHError.invalidState(
                    "cannot stat the DSH workspace directory at "
                        + "\(workspace.path): \(error)")
            }
            guard isWorkspace else { continue }
            let sessions: [URL]
            do {
                sessions = try fileManager.contentsOfDirectory(
                    at: workspace,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles])
            } catch {
                throw PhoneDSHError.invalidState(
                    "cannot read the DSH workspace sessions directory at "
                        + "\(workspace.path): \(error)")
            }
            for session in sessions {
                let isSession: Bool
                do {
                    isSession = try session.resourceValues(
                        forKeys: [.isDirectoryKey]).isDirectory == true
                } catch {
                    throw PhoneDSHError.invalidState(
                        "cannot stat the DSH session directory at "
                            + "\(session.path): \(error)")
                }
                guard isSession else { continue }
                directories.append(session)
            }
        }
        return directories
    }

    /// The highest-version journal in one session directory.
    private static func currentJournal(in directory: URL,
                                       fileManager: FileManager) throws -> URL? {
        let files: [URL]
        do {
            files = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])
        } catch {
            throw PhoneDSHError.invalidState(
                "cannot read the DSH session directory at \(directory.path): \(error)")
        }
        return files
            .filter { PhoneDSHSessionLog.isSessionLogFile($0.lastPathComponent) }
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            .last
    }

    /// Reads and parses the first JSONL record only.
    ///
    /// A missing newline, a short read or a first row that is not a complete
    /// `session` header throws. That is exactly the "not written yet" case the
    /// teardown must not fold into an empty descendant set.
    private static func headerState(of journal: URL) throws -> PhoneDSHSessionTurnState {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: journal)
        } catch {
            throw PhoneDSHError.invalidState(
                "cannot open DSH session header at \(journal.path): \(error)")
        }
        defer { try? handle.close() }
        var data = Data()
        while data.count < maximumHeaderBytes {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: 4 * 1024)
            } catch {
                throw PhoneDSHError.invalidState(
                    "cannot read DSH session header at \(journal.path): \(error)")
            }
            guard let chunk, !chunk.isEmpty else {
                throw PhoneDSHError.invalidState(
                    "the DSH session header at \(journal.path) is incomplete")
            }
            data.append(chunk)
            if data.contains(UInt8(ascii: "\n")) { break }
        }
        guard let newline = data.firstIndex(of: UInt8(ascii: "\n")) else {
            throw PhoneDSHError.invalidState(
                "the DSH session header at \(journal.path) has no complete record")
        }
        var line = Data(data[data.startIndex..<newline])
        line.append(UInt8(ascii: "\n"))
        let state = PhoneDSHSessionLog.state(of: line)
        // A row that is not the `session` header is not lineage evidence, and
        // at teardown it means the materialized journal is not what we think.
        guard state.sessionID != nil else {
            throw PhoneDSHError.invalidState(
                "the DSH session journal at \(journal.path) has no session header")
        }
        return state
    }
}

// MARK: - Bounded host call

/// The one bounded route call the abort drain makes before it verifies turns.
public enum PhoneDSHDescendantDrain {
    /// Splits tracked roots into requests the Worker route accepts.
    ///
    /// The Worker route rejects more than
    /// ``PhoneDSHDescendantDrainProtocol/maximumRoots`` ids with a 400. A
    /// long-lived host can accumulate more roots than one request allows, so
    /// the host batches rather than letting that 400 abort the drain.
    public static func rootBatches(
        _ rootSessionIDs: [String],
        maximum: Int = PhoneDSHDescendantDrainProtocol.maximumRoots
    ) -> [[String]] {
        let limit = max(1, maximum)
        var batches: [[String]] = []
        var current: [String] = []
        for id in rootSessionIDs {
            if current.count == limit {
                batches.append(current)
                current = []
            }
            current.append(id)
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    /// Derives a bounded route budget from a host deadline.
    ///
    /// The budget is carved from the verification window (not the cooperative
    /// cancel budget, which is already zero after the escalation point). The
    /// transport grace is subtracted so the awaited route call cannot overrun
    /// the caller's absolute deadline.
    ///
    /// - Parameters:
    ///   - deadline: absolute host deadline the call must not exceed.
    ///   - now: current instant (injectable for tests).
    ///   - maximumSeconds: host-side cap for one drain.
    ///   - transportGrace: room for the response after the Worker deadline.
    /// - Returns: a positive budget, or `nil` when no usable time remains.
    public static func budget(until deadline: Date,
                              now: Date = Date(),
                              maximumSeconds: TimeInterval = 2.0,
                              transportGrace: TimeInterval = 0.5)
        -> PhoneDSHDescendantDrainBudget? {
        let usable = min(maximumSeconds,
                         deadline.timeIntervalSince(now) - transportGrace)
        guard usable > 0 else { return nil }
        return PhoneDSHDescendantDrainBudget(
            timeoutMilliseconds: max(1, Int(usable * 1000)))
    }

    /// Derives the budget a teardown with `rootCount` roots must use.
    ///
    /// Unlike ``budget(until:now:maximumSeconds:transportGrace:)`` this never
    /// returns "no call". A tracked root means the scoped route is mandatory:
    /// it also closes subagent admission and covers an external/concurrent
    /// child the local forest cannot see. When the materialize/forest scan has
    /// consumed the verification window, an unattempted route is *unknown*,
    /// not convergence, so this throws instead of letting the abort loop park
    /// with no drain attempt. A tiny remaining window still attempts the route
    /// with the protocol minimum.
    ///
    /// - Parameters:
    ///   - deadline: absolute host verification deadline.
    ///   - now: current instant (injectable for tests).
    ///   - rootCount: exact App-owned roots the route must name.
    ///   - openDescendantCount: observed open descendants, used only for the
    ///     fail-loud diagnostic.
    ///   - maximumSeconds: host-side cap for one drain.
    ///   - transportGrace: room for the response after the Worker deadline.
    /// - Returns: a positive budget that requires a route attempt.
    /// - Throws: ``PhoneDSHError/invalidState`` when the window ended before
    ///   the mandatory route could be attempted.
    public static func teardownBudget(
        until deadline: Date,
        now: Date = Date(),
        rootCount: Int,
        openDescendantCount: Int = 0,
        maximumSeconds: TimeInterval = 2.0,
        transportGrace: TimeInterval = 0.5
    ) throws -> PhoneDSHDescendantDrainBudget {
        if let derived = budget(until: deadline, now: now,
                                maximumSeconds: maximumSeconds,
                                transportGrace: transportGrace) {
            return derived
        }
        guard now < deadline else {
            if openDescendantCount > 0 {
                throw PhoneDSHError.invalidState(
                    "the drain window has no cooperative budget left for "
                        + "\(openDescendantCount) open subagent session(s)")
            }
            throw PhoneDSHError.invalidState(
                "the drain window ended before the scoped descendant drain could "
                    + "be attempted for \(rootCount) root session(s); an "
                    + "unattempted route is not convergence")
        }
        // The transport grace is gone but the absolute window is not: one
        // minimal attempt still closes admission and names every root. The
        // outer abort window owns the real bound.
        return PhoneDSHDescendantDrainBudget(timeoutMilliseconds: 1)
    }

    /// Drains the descendants of `rootSessionIDs` and returns the route receipt.
    ///
    /// The call is made even when no descendant journal is visible: the
    /// scoped route also closes subagent admission and covers an external or
    /// concurrently-spawned child whose journal is not in the materialized
    /// tree. A transport that genuinely has no route is skipped only when no
    /// known descendant turn is open; every other transport failure is thrown
    /// even when the local journal is empty, because it cannot exclude a
    /// concurrent child.
    ///
    /// - Parameters:
    ///   - transport: the live host transport.
    ///   - rootSessionIDs: exact App-owned roots for this batch.
    ///   - openDescendantSessionIDs: descendant sessions whose durable journal
    ///     still has an open turn. Only these make an absent route/empty receipt
    ///     mandatory; a route that throws is never tolerated.
    ///   - budget: bounded route budget (the host keeps its outer 20 s window).
    /// - Returns: the receipt, or `nil` when a legacy transport has no route
    ///   and no descendant turn is open.
    /// - Throws: any timeout, transport error or malformed receipt from an
    ///   attempted route call, plus a missing route/empty receipt when a
    ///   descendant turn is still open. It never reports success for those.
    public static func drain(
        transport: any DSHRemoteTransport,
        rootSessionIDs: Set<String>,
        openDescendantSessionIDs: Set<String>,
        budget: PhoneDSHDescendantDrainBudget
    ) async throws -> PhoneDSHDescendantDrainReceipt? {
        guard !rootSessionIDs.isEmpty else { return nil }
        guard let caller = transport as? any PhoneDSHDescendantDrainCalling,
              await caller.supportsDescendantDrain() else {
            if openDescendantSessionIDs.isEmpty { return nil }
            throw PhoneDSHError.invalidState(
                "the active transport has no scoped descendant-drain path, but "
                    + "\(openDescendantSessionIDs.count) subagent session(s) still "
                    + "have an open turn")
        }
        let request = PhoneDSHDescendantDrainRequest(
            rootSessionIDs: rootSessionIDs.sorted(),
            budget: budget)
        // The route enforces its own deadline; the host adds one transport
        // round-trip so a route that answers at its deadline is not cut off
        // before the receipt can be read. The outer abort window still owns
        // the real bound.
        let seconds = TimeInterval(budget.timeoutMilliseconds) / 1000 + 0.5
        guard let outcome = await phoneDSHResultWithinDeadline(seconds, operation: {
            try await caller.drainDescendantSessions(request)
        }) else {
            throw PhoneDSHError.invalidState(
                "the scoped descendant drain did not answer within "
                    + "\(budget.timeoutMilliseconds) ms")
        }
        switch outcome {
        case .success(let receipt):
            // A route that answers but silently drops every requested root
            // cannot explain a still-open child. A terminal child journal is
            // not evidence of a live activation, so it does not make an empty
            // root receipt contradictory.
            if !openDescendantSessionIDs.isEmpty, receipt.roots.isEmpty {
                throw PhoneDSHError.invalidState(
                    "the scoped descendant drain reported no live root for "
                        + "\(openDescendantSessionIDs.count) open subagent session(s)")
            }
            // A descendant can only be live under a live root. If the route
            // names descendants but no root, it drained an unrelated or stale
            // activation (or answered inconsistently); the host cannot verify
            // that as this root's convergence.
            if receipt.roots.isEmpty, !receipt.descendants.isEmpty {
                throw PhoneDSHError.invalidState(
                    "the scoped descendant drain reported "
                        + "\(receipt.descendants.count) live descendant session(s) "
                        + "without a live root")
            }
            return receipt
        case .failure(let error):
            throw PhoneDSHError.invalidState(
                "the scoped descendant drain failed: \(String(describing: error))")
        }
    }
}
