// SPDX-License-Identifier: MIT
// G2-F01: scoped descendant teardown before Worker stop.
//
// These are the host-side component regressions: the durable session header
// walk must include only roots and their `origin: "subagent"` descendants, and
// the bounded route call must never turn a missing route, a malformed receipt
// or an empty root answer into a successful teardown. The real pinned-DSH
// parent/child proof lives in `plugins/tests/descendant-drain.test.ts`; this
// file does not fabricate DSH session records.

import Foundation
import XCTest
import PhoneDSHAgentCore
@testable import PhoneDSH

final class PhoneDSHDescendantDrainTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-descendant-drain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: - Fixtures

    /// One physical JSONL record with the fields this verifier reads.
    private func record(_ type: String,
                        time: Int64,
                        fields: [String: Any] = [:],
                        data: [String: Any]? = nil) -> String {
        var object: [String: Any] = ["type": type, "time": time]
        object.merge(fields) { _, new in new }
        if let data { object["data"] = data }
        let encoded = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: encoded, as: UTF8.self) + "\n"
    }

    private func header(id: String,
                        parent: String? = nil,
                        origin: String? = nil,
                        depth: Int? = nil,
                        createdAt: Int64 = 1_000) -> String {
        var fields: [String: Any] = [
            "version": 4,
            "id": id,
            "createdAt": createdAt,
            "cwd": "/dsh/workspace",
            "isSeeded": false,
        ]
        if let parent { fields["parentSession"] = parent }
        if let origin { fields["origin"] = origin }
        if let depth { fields["delegationDepth"] = depth }
        return record("session", time: createdAt, fields: fields)
    }

    @discardableResult
    private func writeSession(_ id: String,
                              body: String,
                              workspace: String = "--dsh-workspace--") throws -> URL {
        let directory = root.appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(workspace, isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let journal = directory.appendingPathComponent("session.v4.jsonl")
        try Data(body.utf8).write(to: journal)
        return journal
    }

    private func openTurn(_ id: String, parent: String? = nil, origin: String? = nil,
                          depth: Int? = nil, createdAt: Int64 = 1_000,
                          close: Bool = false) throws {
        var body = header(id: id, parent: parent, origin: origin, depth: depth,
                          createdAt: createdAt)
        body += record("turn/start", time: createdAt + 1, data: ["turn": 1])
        if close {
            body += record("turn/end", time: createdAt + 2,
                           data: ["turn": 1, "reason": ["kind": "completed"]])
        }
        try writeSession(id, body: body)
    }

    private var sessionsDirectory: URL {
        root.appendingPathComponent("sessions", isDirectory: true)
    }

    // MARK: - Durable lineage closure

    func testForestFollowsParentSessionRecursivelyAndIgnoresUnrelatedRoots() throws {
        try openTurn("root", close: false)
        try openTurn("child", parent: "root", origin: "subagent", depth: 1, close: false)
        try openTurn("grandchild", parent: "child", origin: "subagent", depth: 2, close: true)
        try openTurn("unrelated-root", close: true)
        try openTurn("unrelated-child", parent: "unrelated-root", origin: "subagent", depth: 1)

        let forest = try PhoneDSHDescendantSessions.forest(
            inSessionsDirectory: sessionsDirectory,
            rootSessionIDs: ["root"])

        XCTAssertEqual(forest.rootSessionIDs, Set(["root"]))
        XCTAssertEqual(forest.descendantSessionIDs, Set(["child", "grandchild"]))
        XCTAssertEqual(Set(forest.states.keys), Set(["root", "child", "grandchild"]))
        XCTAssertEqual(forest.openTurns, ["root": 1, "child": 1])
        XCTAssertEqual(forest.openDescendantSessionIDs, Set(["child"]))
        XCTAssertEqual(forest.rootSessionID(forDescendant: "child"), "root")
        XCTAssertEqual(forest.rootSessionID(forDescendant: "grandchild"), "root")
        XCTAssertEqual(forest.rootsWithDescendants, Set(["root"]))
        XCTAssertFalse(forest.allTurnsTerminal)
        // The unrelated root and its child are below the same sessions tree but
        // are not part of this teardown.
        XCTAssertNil(forest.states["unrelated-root"])
        XCTAssertNil(forest.states["unrelated-child"])
    }

    func testForestExcludesChildJournalsFromAnEarlierHostIncarnation() throws {
        // The same root id is cold-resumed. The previous crash left an open
        // child journal behind, but its Activation is no longer resident, so a
        // live drain can never append its terminal turn/end. It must not make
        // this incarnation's teardown wait (and fail) forever.
        try openTurn("root", createdAt: 900, close: false)
        try openTurn("stale-child", parent: "root", origin: "subagent", depth: 1,
                     createdAt: 999, close: false)
        // Even a later timestamp under the stale parent is not live: DSH
        // cannot have published a current-incarnation grandchild below a child
        // that predates the host boot.
        try openTurn("stale-grandchild", parent: "stale-child", origin: "subagent",
                     depth: 2, createdAt: 1_001, close: true)
        try openTurn("current-child", parent: "root", origin: "subagent", depth: 1,
                     createdAt: 1_000, close: false)
        try openTurn("grandchild", parent: "current-child", origin: "subagent",
                     depth: 2, createdAt: 1_001, close: true)

        let forest = try PhoneDSHDescendantSessions.forest(
            inSessionsDirectory: sessionsDirectory,
            rootSessionIDs: ["root"],
            // Exactly the start millisecond is still this incarnation.
            incarnationStart: Date(timeIntervalSince1970: 1.000))

        XCTAssertEqual(forest.rootSessionIDs, Set(["root"]))
        XCTAssertEqual(forest.descendantSessionIDs,
                       Set(["current-child", "grandchild"]))
        XCTAssertEqual(Set(forest.states.keys),
                       Set(["root", "current-child", "grandchild"]))
        XCTAssertEqual(forest.openDescendantSessionIDs, Set(["current-child"]))
        XCTAssertNil(forest.states["stale-child"])
        XCTAssertNil(forest.states["stale-grandchild"])
    }

    func testForestIncludesAColdResumedChildReportedLiveDespiteAnOldHeader() throws {
        // DSH cold resume reopens the same child session id with the persisted
        // header, so `createdAt` still points at the earlier incarnation. The
        // route reported this exact id live in the current Worker, so the host
        // must still verify its open turn and make its new grandchild
        // reachable instead of excluding the whole branch as stale.
        try openTurn("root", createdAt: 900, close: false)
        try openTurn("resumed-child", parent: "root", origin: "subagent", depth: 1,
                     createdAt: 999, close: false)
        try openTurn("new-grandchild", parent: "resumed-child", origin: "subagent",
                     depth: 2, createdAt: 1_001, close: true)
        try openTurn("stale-child", parent: "root", origin: "subagent", depth: 1,
                     createdAt: 998, close: false)

        let forest = try PhoneDSHDescendantSessions.forest(
            inSessionsDirectory: sessionsDirectory,
            rootSessionIDs: ["root"],
            incarnationStart: Date(timeIntervalSince1970: 1.000),
            liveDescendantSessionIDs: ["resumed-child"])

        XCTAssertEqual(forest.descendantSessionIDs,
                       Set(["resumed-child", "new-grandchild"]))
        XCTAssertEqual(Set(forest.states.keys),
                       Set(["root", "resumed-child", "new-grandchild"]))
        XCTAssertEqual(forest.openDescendantSessionIDs, Set(["resumed-child"]),
                       "the resumed child's live turn must still be verified")
        XCTAssertNil(forest.states["stale-child"],
                     "an old child the route did not report live stays excluded")
    }

    func testForestRejectsARouteReportedLiveChildWithoutMaterializedLineage() throws {
        // The route can report a child before its journal (or a middle parent's
        // journal) is materialized. The forest cannot verify that id, so the
        // host must not silently shrink the set and call the teardown complete.
        try openTurn("root", close: true)
        let missingJournal = try PhoneDSHDescendantSessions.forest(
            inSessionsDirectory: sessionsDirectory,
            rootSessionIDs: ["root"],
            liveDescendantSessionIDs: ["child"])
        XCTAssertFalse(missingJournal.descendantSessionIDs.contains("child"))
        XCTAssertThrowsError(
            try missingJournal.requireVerifiableLiveDescendants(["child"])
        ) { error in
            XCTAssertTrue(String(describing: error).contains("cannot be proven terminal"),
                          "\(error)")
        }

        // A grandchild journal exists, but its parent child journal is missing:
        // the parent chain never reaches the root, so this is not verifiable
        // lineage either.
        try openTurn("grandchild", parent: "child", origin: "subagent",
                     depth: 2, close: false)
        let missingParent = try PhoneDSHDescendantSessions.forest(
            inSessionsDirectory: sessionsDirectory,
            rootSessionIDs: ["root"],
            liveDescendantSessionIDs: ["grandchild"])
        XCTAssertThrowsError(
            try missingParent.requireVerifiableLiveDescendants(["grandchild"])
        ) { error in
            XCTAssertTrue(String(describing: error).contains("cannot be proven terminal"),
                          "\(error)")
        }

        // With the journal and full parent chain present, the route-reported id
        // is in the closure and passes the same check.
        try openTurn("child", parent: "root", origin: "subagent", depth: 1,
                     close: true)
        let complete = try PhoneDSHDescendantSessions.forest(
            inSessionsDirectory: sessionsDirectory,
            rootSessionIDs: ["root"],
            liveDescendantSessionIDs: ["child"])
        XCTAssertNoThrow(
            try complete.requireVerifiableLiveDescendants(["child"]))
    }

    func testForestThrowsWhenAReachableChildHeaderHasNoCreationTime() throws {
        try openTurn("root", close: false)
        // A compliant DSH header always carries the immutable createdAt. If it
        // is absent, the teardown cannot tell this incarnation's child from a
        // stale crash journal and must not fold it into an empty descendant
        // set (which would make the route's success look like convergence).
        let body = record("session", time: 1_000, fields: [
            "version": 4,
            "id": "child",
            "parentSession": "root",
            "origin": "subagent",
            "delegationDepth": 1,
            "cwd": "/dsh/workspace",
            "isSeeded": false,
        ]) + record("turn/start", time: 1_001, data: ["turn": 1])
        try writeSession("child", body: body)
        XCTAssertThrowsError(try PhoneDSHDescendantSessions.forest(
            inSessionsDirectory: sessionsDirectory,
            rootSessionIDs: ["root"],
            incarnationStart: Date(timeIntervalSince1970: 1.000))) { error in
            XCTAssertTrue(String(describing: error).contains("has no createdAt"),
                          "\(error)")
        }
    }

    func testForestRequiresSubagentOriginAndAParentLink() throws {
        try openTurn("root", close: true)
        // Same parent pointer but no `origin: subagent`: a fork/seed row is not
        // a managed child and must not be swept into the drain.
        try openTurn("seed-fork", parent: "root", close: true)
        // Subagent origin but no parent chain: also not reachable.
        try openTurn("orphan", origin: "subagent", depth: 1, close: true)

        let forest = try PhoneDSHDescendantSessions.forest(
            inSessionsDirectory: sessionsDirectory,
            rootSessionIDs: ["root"])
        XCTAssertEqual(forest.descendantSessionIDs, Set<String>())
        XCTAssertEqual(Set(forest.states.keys), Set(["root"]))
    }

    func testForestAllTerminalWhenRootAndChildHaveTurnEnd() throws {
        try openTurn("root", close: true)
        try openTurn("child", parent: "root", origin: "subagent", depth: 1, close: true)
        let forest = try PhoneDSHDescendantSessions.forest(
            inSessionsDirectory: sessionsDirectory,
            rootSessionIDs: ["root"])
        XCTAssertEqual(forest.descendantSessionIDs, Set(["child"]))
        XCTAssertTrue(forest.allTurnsTerminal)
        XCTAssertEqual(forest.openTurns, [:])
    }

    func testForestThrowsWhenTheSessionsDirectoryCannotBeRead() throws {
        // A regular file where the sessions directory should be is a read
        // failure, not an empty descendant set.
        try Data("not a directory".utf8).write(to: sessionsDirectory)
        XCTAssertThrowsError(try PhoneDSHDescendantSessions.forest(
            inSessionsDirectory: sessionsDirectory,
            rootSessionIDs: ["root"]))
    }

    func testForestThrowsOnAnIncompleteHeader() throws {
        try writeSession("incomplete", body: #"{"type":"session","id":"incomplete""#)
        XCTAssertThrowsError(try PhoneDSHDescendantSessions.forest(
            inSessionsDirectory: sessionsDirectory,
            rootSessionIDs: ["incomplete"]))
        let incompleteDirectory = sessionsDirectory
            .appendingPathComponent("--dsh-workspace--", isDirectory: true)
            .appendingPathComponent("incomplete", isDirectory: true)
        try FileManager.default.removeItem(at: incompleteDirectory)

        try writeSession("not-a-header", body: record("turn/start", time: 1,
                                                      data: ["turn": 1]))
        XCTAssertThrowsError(try PhoneDSHDescendantSessions.forest(
            inSessionsDirectory: sessionsDirectory,
            rootSessionIDs: ["not-a-header"]))
    }

    func testRootBatchesKeepEveryRequestWithinTheWorkerLimit() {
        let roots = (0..<130).map { "root-\($0)" }
        let batches = PhoneDSHDescendantDrain.rootBatches(roots)
        XCTAssertEqual(batches.count, 3)
        XCTAssertTrue(batches.allSatisfy {
            $0.count <= PhoneDSHDescendantDrainProtocol.maximumRoots
        })
        XCTAssertEqual(batches.flatMap { $0 }, roots)
        XCTAssertEqual(PhoneDSHDescendantDrainProtocol.maximumRoots, 64)
    }

    func testBudgetUsesTheVerificationWindowAfterTheEscalationPoint() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        // A one second window leaves 0.5 s after the transport grace; the old
        // cancelBudget(now:) is already zero at this point.
        let budget = PhoneDSHDescendantDrain.budget(
            until: now.addingTimeInterval(1.0), now: now)
        XCTAssertEqual(budget?.timeoutMilliseconds, 500)
        // The host cap still applies to a long window.
        XCTAssertEqual(
            PhoneDSHDescendantDrain.budget(
                until: now.addingTimeInterval(10), now: now)?.timeoutMilliseconds,
            2_000)
        // No usable time left means no invented deadline.
        XCTAssertNil(PhoneDSHDescendantDrain.budget(
            until: now.addingTimeInterval(0.25), now: now))
    }

    func testTeardownBudgetNeverSkipsTheMandatoryRoute() throws {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        XCTAssertEqual(
            try PhoneDSHDescendantDrain.teardownBudget(
                until: now.addingTimeInterval(1.0), now: now,
                rootCount: 1).timeoutMilliseconds,
            500)
        // The transport grace is gone but the absolute window is not: the route
        // still gets the protocol minimum instead of being skipped.
        XCTAssertEqual(
            try PhoneDSHDescendantDrain.teardownBudget(
                until: now.addingTimeInterval(0.25), now: now,
                rootCount: 1).timeoutMilliseconds,
            1)
        // A scan that consumed the whole window must fail loud: no route
        // attempt means the child state is unknown, never converged.
        do {
            _ = try PhoneDSHDescendantDrain.teardownBudget(
                until: now, now: now, rootCount: 1)
            XCTFail("an unattempted mandatory route must not become success")
        } catch let error as PhoneDSHError {
            XCTAssertTrue(String(describing: error).contains("unattempted route"),
                          "\(error)")
        }
        // A visible open child keeps the older, more specific diagnostic.
        do {
            _ = try PhoneDSHDescendantDrain.teardownBudget(
                until: now, now: now, rootCount: 1, openDescendantCount: 1)
            XCTFail("an open child past the deadline must be fail loud")
        } catch let error as PhoneDSHError {
            XCTAssertTrue(String(describing: error).contains("open subagent session"),
                          "\(error)")
        }
    }

    // MARK: - Wire values

    func testRequestJSONNamesExactRootsAndBudget() throws {
        let request = PhoneDSHDescendantDrainRequest(
            rootSessionIDs: ["root-b", "root-a"],
            budget: PhoneDSHDescendantDrainBudget(timeoutMilliseconds: 1_234))
        let encoded = try request.json.encoded()
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["sessionIds"] as? [String], ["root-b", "root-a"])
        XCTAssertEqual(object["timeoutMs"] as? Int, 1_234)
        // The route path stays the private phone carrier, not a DSH method.
        XCTAssertEqual(PhoneDSHDescendantDrainProtocol.path, "/api/pdsh-descendant-drain")
    }

    func testBudgetClampsToProtocolRange() {
        XCTAssertEqual(PhoneDSHDescendantDrainBudget(timeoutMilliseconds: 0).timeoutMilliseconds, 1)
        XCTAssertEqual(
            PhoneDSHDescendantDrainBudget(timeoutMilliseconds: 99_999).timeoutMilliseconds,
            PhoneDSHDescendantDrainProtocol.maximumBudgetMilliseconds)
    }

    func testReceiptRejectsAMissingOrForeignProtocol() throws {
        let value = try JSONValue.parse(Data(#"""
            {"protocol":"pdsh-descendant-drain/1","roots":["root"],
             "missing":["gone"],"descendants":["child"],"durationMs":12}
            """#.utf8))
        let receipt = try PhoneDSHDescendantDrainReceipt(raw: value)
        XCTAssertEqual(receipt.roots, ["root"])
        XCTAssertEqual(receipt.missing, ["gone"])
        XCTAssertEqual(receipt.descendants, ["child"])
        XCTAssertEqual(receipt.durationMilliseconds, 12)

        // The live-descendant set is mandatory: without it an old child header
        // cannot be distinguished from a stale crash journal.
        let withoutDescendants = try JSONValue.parse(Data(#"""
            {"protocol":"pdsh-descendant-drain/1","roots":["root"],
             "missing":[],"durationMs":12}
            """#.utf8))
        XCTAssertThrowsError(try PhoneDSHDescendantDrainReceipt(raw: withoutDescendants)) {
            XCTAssertTrue(String(describing: $0).contains("no usable live descendants"), "\($0)")
        }
        let nonStringDescendants = try JSONValue.parse(Data(#"""
            {"protocol":"pdsh-descendant-drain/1","roots":["root"],
             "missing":[],"descendants":[1],"durationMs":12}
            """#.utf8))
        XCTAssertThrowsError(try PhoneDSHDescendantDrainReceipt(raw: nonStringDescendants)) {
            XCTAssertTrue(String(describing: $0).contains("no usable live descendants"), "\($0)")
        }

        for raw in [JSONValue.object([:]), .object(["protocol": .string("other")])] {
            XCTAssertThrowsError(try PhoneDSHDescendantDrainReceipt(raw: raw))
        }
    }

    // MARK: - Bounded call

    private final class UnsupportedTransport: DSHRemoteTransport, @unchecked Sendable {
        func call(_ endpoint: String, args: JSONValue) async throws -> JSONValue {
            throw ProviderError.unsupported("not used by this test")
        }
        func openMux() async throws -> any DSHMuxConnection {
            throw ProviderError.unsupported("not used by this test")
        }
    }

    private final class RecordingDrainTransport: DSHRemoteTransport, PhoneDSHDescendantDrainCalling,
        @unchecked Sendable {
        var requests: [PhoneDSHDescendantDrainRequest] = []
        var receipt: PhoneDSHDescendantDrainReceipt

        init(receipt: PhoneDSHDescendantDrainReceipt) {
            self.receipt = receipt
        }

        func call(_ endpoint: String, args: JSONValue) async throws -> JSONValue {
            throw ProviderError.unsupported("not used by this test")
        }
        func openMux() async throws -> any DSHMuxConnection {
            throw ProviderError.unsupported("not used by this test")
        }
        func drainDescendantSessions(_ request: PhoneDSHDescendantDrainRequest) async throws
            -> PhoneDSHDescendantDrainReceipt {
            requests.append(request)
            return receipt
        }
    }

    func testALegacyTransportIsOnlyToleratedWhenNoDescendantExists() async throws {
        let request = PhoneDSHDescendantDrainRequest(rootSessionIDs: ["root"])
        let none = try await PhoneDSHDescendantDrain.drain(
            transport: UnsupportedTransport(),
            rootSessionIDs: ["root"],
            openDescendantSessionIDs: [],
            budget: request.budget)
        XCTAssertNil(none)

        do {
            _ = try await PhoneDSHDescendantDrain.drain(
                transport: UnsupportedTransport(),
                rootSessionIDs: ["root"],
                openDescendantSessionIDs: ["child"],
                budget: request.budget)
            XCTFail("an observed child with no drain route must be fail loud")
        } catch let error as PhoneDSHError {
            XCTAssertTrue(String(describing: error).contains("subagent session"),
                          "the error must name the stranded child: \(error)")
        }
    }

    func testSuccessfulReceiptIsReturnedAndTheExactRootsAreRequested() async throws {
        let raw = try JSONValue.parse(Data(#"""
            {"protocol":"pdsh-descendant-drain/1","roots":["root"],"missing":[],
             "descendants":["child"],"durationMs":3}
            """#.utf8))
        let transport = RecordingDrainTransport(
            receipt: try PhoneDSHDescendantDrainReceipt(raw: raw))
        let receipt = try await PhoneDSHDescendantDrain.drain(
            transport: transport,
            rootSessionIDs: ["root"],
            openDescendantSessionIDs: ["child"],
            budget: PhoneDSHDescendantDrainBudget(timeoutMilliseconds: 500))
        XCTAssertEqual(receipt?.roots, ["root"])
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(transport.requests.first?.rootSessionIDs, ["root"])
        XCTAssertEqual(transport.requests.first?.budget.timeoutMilliseconds, 500)
    }

    func testARouteThatDropsEveryRootCannotExplainAnObservedChild() async throws {
        let raw = try JSONValue.parse(Data(#"""
            {"protocol":"pdsh-descendant-drain/1","roots":[],"missing":["root"],
             "descendants":[],"durationMs":3}
            """#.utf8))
        let transport = RecordingDrainTransport(
            receipt: try PhoneDSHDescendantDrainReceipt(raw: raw))
        do {
            _ = try await PhoneDSHDescendantDrain.drain(
                transport: transport,
                rootSessionIDs: ["root"],
                openDescendantSessionIDs: ["child"],
                budget: PhoneDSHDescendantDrainBudget(timeoutMilliseconds: 500))
            XCTFail("an empty root answer with an observed child must fail loud")
        } catch let error as PhoneDSHError {
            XCTAssertTrue(String(describing: error).contains("no live root"), "\(error)")
        }
    }

    func testLiveDescendantsWithoutALiveRootCannotBeTreatedAsConvergence() async throws {
        // The route naming descendants but no live root is inconsistent: it
        // cannot have drained them through this root. Failing loud keeps a
        // missing-root answer from silently implying the old child is stale.
        let raw = try JSONValue.parse(Data(#"""
            {"protocol":"pdsh-descendant-drain/1","roots":[],"missing":["root"],
             "descendants":["resumed-child"],"durationMs":3}
            """#.utf8))
        let transport = RecordingDrainTransport(
            receipt: try PhoneDSHDescendantDrainReceipt(raw: raw))
        do {
            _ = try await PhoneDSHDescendantDrain.drain(
                transport: transport,
                rootSessionIDs: ["root"],
                openDescendantSessionIDs: [],
                budget: PhoneDSHDescendantDrainBudget(timeoutMilliseconds: 500))
            XCTFail("live descendants without a live root must be fail loud")
        } catch let error as PhoneDSHError {
            XCTAssertTrue(String(describing: error).contains("without a live root"),
                          "\(error)")
        }
    }

    func testTheRouteIsCalledEvenWhenNoDescendantJournalIsVisible() async throws {
        // The scoped route also closes subagent admission and covers an
        // external/concurrent child, so an empty local forest must not skip it.
        let raw = try JSONValue.parse(Data(#"""
            {"protocol":"pdsh-descendant-drain/1","roots":["root"],"missing":[],
             "descendants":["child"],"durationMs":3}
            """#.utf8))
        let transport = RecordingDrainTransport(
            receipt: try PhoneDSHDescendantDrainReceipt(raw: raw))
        let receipt = try await PhoneDSHDescendantDrain.drain(
            transport: transport,
            rootSessionIDs: ["root"],
            openDescendantSessionIDs: [],
            budget: PhoneDSHDescendantDrainBudget(timeoutMilliseconds: 500))
        XCTAssertEqual(receipt?.roots, ["root"])
        XCTAssertEqual(transport.requests.count, 1)
    }

    private final class FailingDrainTransport: DSHRemoteTransport,
        PhoneDSHDescendantDrainCalling, @unchecked Sendable {
        var calls = 0

        func call(_ endpoint: String, args: JSONValue) async throws -> JSONValue {
            throw ProviderError.unsupported("not used by this test")
        }
        func openMux() async throws -> any DSHMuxConnection {
            throw ProviderError.unsupported("not used by this test")
        }
        func drainDescendantSessions(_ request: PhoneDSHDescendantDrainRequest) async throws
            -> PhoneDSHDescendantDrainReceipt {
            calls += 1
            throw ProviderError.unavailable(retryAfter: nil)
        }
    }

    func testAnAttemptedRouteFailureIsNotToleratedWithoutAnObservedChild() async throws {
        // An empty local forest cannot exclude an external/concurrent child.
        // Returning nil is reserved for a transport that genuinely has no
        // route; once the route is attempted, any failure must stay fail loud.
        let transport = FailingDrainTransport()
        do {
            _ = try await PhoneDSHDescendantDrain.drain(
                transport: transport,
                rootSessionIDs: ["root"],
                openDescendantSessionIDs: [],
                budget: PhoneDSHDescendantDrainBudget(timeoutMilliseconds: 500))
            XCTFail("an attempted route failure must not be treated as success")
        } catch let error as PhoneDSHError {
            XCTAssertTrue(String(describing: error).contains("scoped descendant drain failed"),
                          "\(error)")
        }
        XCTAssertEqual(transport.calls, 1,
                       "the route must have been attempted before it failed")
    }

    func testTerminalDescendantWithMissingRootDoesNotBlockTheAbort() async throws {
        // The root is no longer live (its journal/agent was released) but the
        // child journal is already terminal. The route reports the root as
        // missing; that must not turn a converged child into a failure.
        let raw = try JSONValue.parse(Data(#"""
            {"protocol":"pdsh-descendant-drain/1","roots":[],"missing":["root"],
             "descendants":[],"durationMs":3}
            """#.utf8))
        let transport = RecordingDrainTransport(
            receipt: try PhoneDSHDescendantDrainReceipt(raw: raw))
        let receipt = try await PhoneDSHDescendantDrain.drain(
            transport: transport,
            rootSessionIDs: ["root"],
            openDescendantSessionIDs: [],
            budget: PhoneDSHDescendantDrainBudget(timeoutMilliseconds: 500))
        XCTAssertEqual(receipt?.missing, ["root"])
        XCTAssertEqual(transport.requests.count, 1)
    }

    private final class CapabilitylessDrainTransport: DSHRemoteTransport,
        PhoneDSHDescendantDrainCalling, @unchecked Sendable {
        var calls = 0

        func call(_ endpoint: String, args: JSONValue) async throws -> JSONValue {
            throw ProviderError.unsupported("not used by this test")
        }
        func openMux() async throws -> any DSHMuxConnection {
            throw ProviderError.unsupported("not used by this test")
        }
        func supportsDescendantDrain() async -> Bool { false }
        func drainDescendantSessions(_ request: PhoneDSHDescendantDrainRequest) async throws
            -> PhoneDSHDescendantDrainReceipt {
            calls += 1
            throw ProviderError.unsupported("the route must not be called")
        }
    }

    func testATransportWithoutTheRouteIsSkippedOnlyWhenNoChildIsOpen() async throws {
        let transport = CapabilitylessDrainTransport()
        let none = try await PhoneDSHDescendantDrain.drain(
            transport: transport,
            rootSessionIDs: ["root"],
            openDescendantSessionIDs: [],
            budget: PhoneDSHDescendantDrainBudget(timeoutMilliseconds: 500))
        XCTAssertNil(none)
        XCTAssertEqual(transport.calls, 0)

        do {
            _ = try await PhoneDSHDescendantDrain.drain(
                transport: transport,
                rootSessionIDs: ["root"],
                openDescendantSessionIDs: ["child"],
                budget: PhoneDSHDescendantDrainBudget(timeoutMilliseconds: 500))
            XCTFail("an open child without a route must be fail loud")
        } catch let error as PhoneDSHError {
            XCTAssertTrue(String(describing: error).contains("open turn"), "\(error)")
        }
        XCTAssertEqual(transport.calls, 0)
    }
}
