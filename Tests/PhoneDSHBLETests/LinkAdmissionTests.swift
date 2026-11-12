// SPDX-License-Identifier: MIT
import XCTest
import PhoneDSHAgentCore
import PhoneDSHLoopback
@testable import PhoneDSHBLE

/// WP2 regressions for ble-link.md「Link 调用准入」: one shared admission point
/// for the Agent (`ble_link_call` / `ble_link_result`) and the device panel.
/// Busy is decided *before* the journal intent, so a rejected call has no
/// request UUID, writes no record and uploads no byte; the winner is untouched.
final class LinkAdmissionTests: XCTestCase {
    // MARK: - Fake Link harness

    /// Answers the real `PDSHLinkClient` handshake, `tools/list` discovery and
    /// tool results. Result queries can be held so one call stays in flight.
    @MainActor
    private final class LinkTransport: PDSHLinkTransport {
        static let deviceID = "CE6EC956-1111-4222-8333-123456789ABC"
        var holdQueries = false
        var commitStatus: UInt8 = 0
        var dropCommit = false
        var uploads = 0, commits = 0, queries = 0
        private(set) var held: [(offset: Int, continuation: CheckedContinuation<Data, Error>)] = []
        private var upload = Data()
        private var result = Data()
        private var lastTool = ""

        func exchange(opcode: UInt8, body: Data) async throws -> Data {
            let bytes = [UInt8](body)
            switch opcode {
            case 1:
                var ack = Data(repeating: 0, count: 25)
                ack[1] = 2; ack[2] = 1; ack[5] = 0x10; ack[24] = 2
                ack.append(contentsOf: Array("PDSH".utf8) + [1, 0, 0, 16])
                return ack
            case 0x54:
                guard bytes.count >= 24 else { throw BLEFailure("short upload") }
                let offset = Int(bytes.u16(18))
                if offset == 0 { upload = Data() }
                guard offset == upload.count else { throw BLEFailure("bad upload offset") }
                uploads += 1
                upload.append(body.dropFirst(24))
                var response = Data([0]); response.put(UInt16(upload.count)); return response
            case 0x55:
                commits += 1
                if dropCommit { throw BLEFailure("connection lost") }
                if commitStatus != 0 { return Data([commitStatus]) }
                let request = try JSONValue.parse(upload)
                let requestID = try XCTUnwrap(request["request_id"]?.stringValue)
                let name = try XCTUnwrap(request["name"]?.stringValue)
                lastTool = name
                if name == "tools/list" {
                    result = try JSONValue.object([
                        "request_id": .string(requestID), "status": .string("completed"),
                        "result": .object([
                            "device_id": .string(Self.deviceID), "boot_id": .number(0),
                            "tools": .array([.object(["name": .string("light.set")]),
                                             .object(["name": .string("light.get")])]),
                        ]),
                    ]).encoded()
                } else {
                    result = try JSONValue.object([
                        "request_id": .string(requestID), "status": .string("completed"),
                        "result": .object(["on": .bool(true)]),
                    ]).encoded()
                }
                return Data([0, 1])
            case 0x56:
                queries += 1
                guard bytes.count >= 18 else { throw BLEFailure("short query") }
                let offset = Int(bytes.u16(16))
                if holdQueries, lastTool != "tools/list" {
                    return try await withCheckedThrowingContinuation { held.append((offset, $0)) }
                }
                return chunk(offset: offset)
            default:
                throw BLEFailure("unexpected opcode")
            }
        }

        private func chunk(offset: Int) -> Data {
            guard offset < result.count else { return Data([0, 0, 0, 0, 0, 0]) }
            var reply = Data([0, 2]); reply.put(UInt16(result.count)); reply.put(UInt16(offset))
            reply.append(result[offset..<min(offset + 499, result.count)])
            return reply
        }

        func releaseHeldQueries() {
            let pending = held
            held.removeAll()
            for item in pending { item.continuation.resume(returning: chunk(offset: item.offset)) }
        }

        /// Resumes the in-flight query with an error; models cancellation and a
        /// transport loss without parking a continuation.
        func failHeldQueries(_ error: Error) {
            let pending = held
            held.removeAll()
            for item in pending { item.continuation.resume(throwing: error) }
        }
    }

    // MARK: - Helpers

    /// Connects a test peripheral and installs a real Link client + tools/list
    /// discovery through the store's normal handshake path.
    @MainActor
    private func makeLink(_ transport: LinkTransport) async throws -> (BLEDeviceStore, UUID) {
        let adapter = BLEDeviceStore.TestAdapter()
        let id = UUID()
        let store = BLEDeviceStore(testAdapter: adapter, testDevices: [.init(id: id, name: "A", rssi: -40)])
        store.connect(id)
        store.testDidConnect(id)
        store.testDiscover(id, profiles: [.battery, .alert])
        let owner = try XCTUnwrap(store.testOwner(id))
        let client = PDSHLinkClient(transport: transport)
        _ = try await client.handshake()
        try await store.discoverLinkTools(id, client: client, bootID: 0) {
            store.testOwner(id) == owner && store.testPhase(id) == "connected"
        }
        store.grantLinkTool(id, name: "light.set", enabled: true)
        store.grantLinkTool(id, name: "light.get", enabled: true)
        XCTAssertTrue(try XCTUnwrap(store.devices.first { $0.id == id }).grantedTools.contains("light.set"))
        return (store, id)
    }

    /// Isolated receipt root: `DeviceMCPServer(receiptDirectory:)` and the
    /// shared entry then use the very same `link-intents` directory.
    private func makeReceiptRoot() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("link-admission-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func journalDirectory(_ root: URL) -> URL { root.appendingPathComponent("link-intents") }

    private func journalFiles(_ directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    private func journalIntents(_ directory: URL) throws -> [LinkToolJournal.Intent] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { try JSONDecoder().decode(LinkToolJournal.Intent.self, from: Data(contentsOf: $0)) }
    }

    @MainActor
    private func waitForHeldQuery(_ transport: LinkTransport) async throws {
        for _ in 0..<400 {
            if !transport.held.isEmpty { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw BLEFailure("Timed out waiting for an in-flight Link query")
    }

    private func request(_ method: String, _ params: JSONValue = .object([:]), key: String? = nil) throws -> LoopbackRequest {
        LoopbackRequest(method: "POST", path: "/mcp/native",
                        headers: key.map { ["x-pdsh-idempotency-key": $0] } ?? [:],
                        body: try JSONValue.object(["jsonrpc": .string("2.0"), "id": .number(1),
                                                    "method": .string(method), "params": params]).encoded())
    }

    private func call(_ name: String, _ args: JSONValue, key: String? = nil) throws -> LoopbackRequest {
        try request("tools/call", .object(["name": .string(name), "arguments": args]), key: key)
    }

    private func responseText(_ response: NativeMCPResponse) throws -> String {
        guard case .object(let root) = try JSONValue.parse(response.body),
              case .object(let result)? = root["result"],
              case .array(let content)? = result["content"],
              case .object(let first)? = content.first,
              case .string(let text)? = first["text"] else {
            throw BLEFailure("missing MCP result text")
        }
        return text
    }

    private var lightOn: JSONValue { .object(["on": .bool(true)]) }

    // MARK: - Admission

    /// Two concurrent callers: the first keeps its Link slot and completes
    /// untouched; the loser gets the busy error, writes nothing, and may retry
    /// with the same idempotency key once the slot is free.
    @MainActor
    func testTwoConcurrentCallersOnlyOneAdmittedAndLoserRetriesSameKey() async throws {
        let transport = LinkTransport()
        let (store, id) = try await makeLink(transport)
        let root = makeReceiptRoot()
        let journal = LinkToolJournal(directory: journalDirectory(root))
        defer { transport.releaseHeldQueries() }

        transport.holdQueries = true
        let winner = Task { @MainActor in
            try await callLinkTool(deviceID: id, name: "light.set", arguments: self.lightOn,
                                   idempotencyKey: "winner", origin: .agent,
                                   store: store, journal: journal)
        }
        try await waitForHeldQuery(transport)
        let journalWhileBusy = journalFiles(journalDirectory(root))
        XCTAssertEqual(journalWhileBusy.count, 1, "only the admitted call persisted an intent")
        // Other Link users see the same slot: a grant change must wait.
        store.grantLinkTool(id, name: "light.set", enabled: false)
        XCTAssertTrue(try XCTUnwrap(store.devices.first { $0.id == id }).grantedTools.contains("light.set"),
                      "grantLinkTool must keep seeing the shared linkBusy slot")

        let uploads = transport.uploads, commits = transport.commits, queries = transport.queries
        do {
            _ = try await callLinkTool(deviceID: id, name: "light.set",
                                       arguments: .object(["on": .bool(false)]),
                                       idempotencyKey: "loser", origin: .agent,
                                       store: store, journal: journal)
            XCTFail("a second caller must be rejected while the Link is busy")
        } catch {
            XCTAssertTrue(error is LinkBusy, "expected LinkBusy, got \(error)")
        }
        XCTAssertEqual(journalFiles(journalDirectory(root)), journalWhileBusy,
                       "a busy rejection must write no journal record")
        XCTAssertEqual(transport.uploads, uploads, "a busy rejection uploads nothing")
        XCTAssertEqual(transport.commits, commits, "a busy rejection commits nothing")
        XCTAssertEqual(transport.queries, queries, "a busy rejection queries nothing")

        // The first caller is unaffected by the rejected attempt.
        transport.holdQueries = false
        transport.releaseHeldQueries()
        let won = try await winner.value
        guard case .completed(let requestID, let reply) = won else {
            return XCTFail("winner did not complete normally: \(won)")
        }
        XCTAssertEqual(reply.fields["status"], .string("completed"))
        XCTAssertEqual(try journalIntents(journalDirectory(root)).map(\.requestID), [requestID])

        // The rejected caller still owns its key: retrying executes normally.
        let retried = try await callLinkTool(deviceID: id, name: "light.set",
                                             arguments: .object(["on": .bool(false)]),
                                             idempotencyKey: "loser", origin: .agent,
                                             store: store, journal: journal)
        guard case .completed(_, let retriedReply) = retried else {
            return XCTFail("loser retry did not execute: \(retried)")
        }
        XCTAssertEqual(retriedReply.fields["status"], .string("completed"))
        XCTAssertEqual(journalFiles(journalDirectory(root)).count, 2,
                       "the retry records its own intent")
        XCTAssertGreaterThan(transport.uploads, uploads)
    }

    /// The Agent-observable behaviour change: `ble_link_call` while another
    /// owner (here: a panel-shaped shared-entry call) holds the Link now
    /// returns the existing busy text with no journal record and no bytes.
    @MainActor
    func testMCPCallWhileLinkIsHeldIsBusyWithoutJournalRecordOrBytes() async throws {
        let transport = LinkTransport()
        let (store, id) = try await makeLink(transport)
        let root = makeReceiptRoot()
        let journal = LinkToolJournal(directory: journalDirectory(root))
        let server = DeviceMCPServer(receiptDirectory: root, store: store)
        defer { transport.releaseHeldQueries() }

        transport.holdQueries = true
        let holder = Task { @MainActor in
            try await callLinkTool(deviceID: id, name: "light.set", arguments: self.lightOn,
                                   idempotencyKey: "panel-send", origin: .user,
                                   store: store, journal: journal)
        }
        try await waitForHeldQuery(transport)
        let journalWhileBusy = journalFiles(journalDirectory(root))
        let uploads = transport.uploads, commits = transport.commits, queries = transport.queries

        let response = await server.handle(try call("ble_link_call",
                                                    .object(["device_id": .string(id.uuidString),
                                                             "name": .string("light.set"),
                                                             "args": self.lightOn]),
                                                    key: "agent-call"))
        let text = try responseText(response)
        XCTAssertEqual(text, "Another Link call is running",
                       "the existing busy text stays byte-identical")
        XCTAssertEqual(journalFiles(journalDirectory(root)), journalWhileBusy,
                       "a busy Agent call must leave no journal record")
        XCTAssertEqual(transport.uploads, uploads)
        XCTAssertEqual(transport.commits, commits)
        XCTAssertEqual(transport.queries, queries)

        transport.holdQueries = false
        transport.releaseHeldQueries()
        guard case .completed = try await holder.value else {
            return XCTFail("the admitted panel call must still complete")
        }
        // The rejected Agent key was never bound, so the same key now executes.
        let retried = await server.handle(try call("ble_link_call",
                                                   .object(["device_id": .string(id.uuidString),
                                                            "name": .string("light.set"),
                                                            "args": self.lightOn]),
                                                   key: "agent-call"))
        XCTAssertEqual(try JSONValue.parse(retried.body).fields["result"]?.fields["isError"], .bool(false))
        XCTAssertEqual(journalFiles(journalDirectory(root)).count, 2)
    }

    /// `ble_link_result` during an in-flight call is rejected before it reads
    /// or writes the journal, through both the shared entry and the MCP path.
    @MainActor
    func testResultQueryDuringInflightCallIsBusyWithoutJournalChange() async throws {
        let transport = LinkTransport()
        let (store, id) = try await makeLink(transport)
        let root = makeReceiptRoot()
        let journal = LinkToolJournal(directory: journalDirectory(root))
        let server = DeviceMCPServer(receiptDirectory: root, store: store)
        defer { transport.releaseHeldQueries() }

        transport.holdQueries = true
        let holder = Task { @MainActor in
            try await callLinkTool(deviceID: id, name: "light.set", arguments: self.lightOn,
                                   idempotencyKey: "inflight", origin: .agent,
                                   store: store, journal: journal)
        }
        try await waitForHeldQuery(transport)
        let intents = try journalIntents(journalDirectory(root))
        XCTAssertEqual(intents.count, 1)
        let requestID = try XCTUnwrap(intents.first?.requestID)
        let journalWhileBusy = journalFiles(journalDirectory(root))
        let queries = transport.queries

        do {
            _ = try await queryLinkTool(deviceID: id, requestID: requestID, origin: .agent,
                                        store: store, journal: journal)
            XCTFail("a result query must be rejected while the Link is busy")
        } catch {
            XCTAssertTrue(error is LinkBusy, "expected LinkBusy, got \(error)")
        }
        let response = await server.handle(try request("tools/call", .object([
            "name": .string("ble_link_result"),
            "arguments": .object(["device_id": .string(id.uuidString),
                                  "request_id": .string(requestID.uuidString)]),
        ])))
        XCTAssertEqual(try responseText(response), "Invalid result query or Link busy")
        XCTAssertEqual(journalFiles(journalDirectory(root)), journalWhileBusy,
                       "busy result queries must not change the journal")
        XCTAssertEqual(transport.queries, queries, "busy result queries must not reach the device")

        transport.holdQueries = false
        transport.releaseHeldQueries()
        guard case .completed = try await holder.value else {
            return XCTFail("the in-flight call must still complete")
        }
        // Once the slot is free the same query is admitted and served.
        let after = try await queryLinkTool(deviceID: id, requestID: requestID, origin: .agent,
                                            store: store, journal: journal)
        guard case .completed(let sameRequest, _) = after else {
            return XCTFail("query after the call should be served: \(after)")
        }
        XCTAssertEqual(sameRequest, requestID)
    }

    /// The panel entry and `DeviceMCPServer` return the same outcome for the
    /// same journal and store, and both report the same busy decision.
    @MainActor
    func testSharedEntryAndMCPServerProduceTheSameOutcome() async throws {
        let transport = LinkTransport()
        let (store, id) = try await makeLink(transport)
        let root = makeReceiptRoot()
        let journal = LinkToolJournal(directory: journalDirectory(root))
        let server = DeviceMCPServer(receiptDirectory: root, store: store)

        let shared = try await callLinkTool(deviceID: id, name: "light.set", arguments: lightOn,
                                            idempotencyKey: "shared-key", origin: .user,
                                            store: store, journal: journal)
        guard case .completed(_, let reply) = shared else {
            return XCTFail("shared entry did not complete: \(shared)")
        }
        let viaMCP = await server.handle(try call("ble_link_call",
                                                  .object(["device_id": .string(id.uuidString),
                                                           "name": .string("light.set"),
                                                           "args": self.lightOn]),
                                                  key: "mcp-key"))
        let mcpReply = try JSONValue.parse(Data(try responseText(viaMCP).utf8))
        XCTAssertEqual(mcpReply.fields["status"], reply.fields["status"])
        XCTAssertEqual(mcpReply.fields["result"], reply.fields["result"],
                       "the MCP path must return the shared entry's raw reply")
        var sharedFields = reply.fields, mcpFields = mcpReply.fields
        sharedFields["request_id"] = nil; mcpFields["request_id"] = nil
        XCTAssertEqual(mcpFields, sharedFields,
                       "only the per-call request UUID differs between the two admitted paths")

        // Same busy decision from both entry points.
        transport.holdQueries = true
        let holder = Task { @MainActor in
            try await callLinkTool(deviceID: id, name: "light.get", arguments: .object([:]),
                                   idempotencyKey: "held", origin: .agent,
                                   store: store, journal: journal)
        }
        defer { transport.releaseHeldQueries() }
        try await waitForHeldQuery(transport)
        do {
            _ = try await callLinkTool(deviceID: id, name: "light.set", arguments: self.lightOn,
                                       idempotencyKey: "also-busy", origin: .agent,
                                       store: store, journal: journal)
            XCTFail("shared entry must report busy")
        } catch {
            XCTAssertTrue(error is LinkBusy)
        }
        let busyResponse = await server.handle(try call("ble_link_call",
                                                        .object(["device_id": .string(id.uuidString),
                                                                 "name": .string("light.set"),
                                                                 "args": self.lightOn]),
                                                        key: "mcp-busy"))
        XCTAssertEqual(try responseText(busyResponse), "Another Link call is running")
        transport.holdQueries = false
        transport.releaseHeldQueries()
        _ = try? await holder.value
    }

    /// Every failure after admission (authorization, journal conflict, a
    /// cancelled/aborted transport) releases the slot for the next caller.
    @MainActor
    func testAdmissionIsReleasedOnEveryFailurePath() async throws {
        let transport = LinkTransport()
        let (store, id) = try await makeLink(transport)
        let root = makeReceiptRoot()
        let journal = LinkToolJournal(directory: journalDirectory(root))

        // Authorization failure: advertised but not granted.
        store.grantLinkTool(id, name: "light.get", enabled: false)
        do {
            _ = try await callLinkTool(deviceID: id, name: "light.get", arguments: .object([:]),
                                       idempotencyKey: "denied", origin: .agent,
                                       store: store, journal: journal)
            XCTFail("an unauthorized tool must not be called")
        } catch {
            XCTAssertFalse(error is LinkBusy, "authorization failure must not look like busy")
            XCTAssertTrue(error.localizedDescription.contains("Authorize this Link tool"))
        }
        XCTAssertTrue(journalFiles(journalDirectory(root)).isEmpty,
                      "authorization failure precedes the journal intent")
        let afterDenied = try await callLinkTool(deviceID: id, name: "light.set", arguments: lightOn,
                                                 idempotencyKey: "after-denied", origin: .agent,
                                                 store: store, journal: journal)
        guard case .completed = afterDenied else {
            return XCTFail("the slot was not released after authorization failure: \(afterDenied)")
        }

        // Journal conflict: same key, different arguments.
        do {
            _ = try await callLinkTool(deviceID: id, name: "light.set",
                                       arguments: .object(["on": .bool(false)]),
                                       idempotencyKey: "after-denied", origin: .agent,
                                       store: store, journal: journal)
            XCTFail("a changed argument set must conflict with the recorded key")
        } catch {
            XCTAssertFalse(error is LinkBusy, "journal conflict must not look like busy")
            XCTAssertTrue(error.localizedDescription.contains("Idempotency key conflict"))
        }
        let afterConflict = try await callLinkTool(deviceID: id, name: "light.set", arguments: lightOn,
                                                   idempotencyKey: "after-conflict", origin: .agent,
                                                   store: store, journal: journal)
        guard case .completed = afterConflict else {
            return XCTFail("the slot was not released after a journal conflict: \(afterConflict)")
        }

        // Aborted/cancelled transport: the admitted call ends, the slot is free.
        transport.holdQueries = true
        defer { transport.releaseHeldQueries() }
        let aborted = Task { @MainActor in
            try await callLinkTool(deviceID: id, name: "light.set", arguments: self.lightOn,
                                   idempotencyKey: "aborted", origin: .agent,
                                   store: store, journal: journal)
        }
        try await waitForHeldQuery(transport)
        aborted.cancel()
        transport.failHeldQueries(CancellationError())
        let abortedOutcome = try await aborted.value
        guard case .outcomeUnknown = abortedOutcome else {
            return XCTFail("an aborted call must report an unknown outcome: \(abortedOutcome)")
        }
        transport.holdQueries = false
        let afterAbort = try await callLinkTool(deviceID: id, name: "light.set", arguments: lightOn,
                                                idempotencyKey: "after-abort", origin: .agent,
                                                store: store, journal: journal)
        guard case .completed = afterAbort else {
            return XCTFail("the slot was not released after an aborted call: \(afterAbort)")
        }
    }

    /// The refactor must not drift the two existing wrapper texts: a refused
    /// COMMIT is `not_executed` (with the lowercased request UUID) and a lost
    /// COMMIT response stays `outcome_unknown` and query-only.
    @MainActor
    func testRefusedAndUnknownOutcomesKeepTheirExistingMCPText() async throws {
        let refusedTransport = LinkTransport()
        let (refusedStore, refusedID) = try await makeLink(refusedTransport)
        let refusedRoot = makeReceiptRoot()
        let refusedServer = DeviceMCPServer(receiptDirectory: refusedRoot, store: refusedStore)
        refusedTransport.commitStatus = 15
        let uploadsBefore = refusedTransport.uploads
        let refused = await refusedServer.handle(try call("ble_link_call",
                                                          .object(["device_id": .string(refusedID.uuidString),
                                                                   "name": .string("light.set"),
                                                                   "args": self.lightOn]),
                                                          key: "refused"))
        let refusedIntent = try XCTUnwrap(try journalIntents(journalDirectory(refusedRoot)).first)
        XCTAssertEqual(try responseText(refused),
                       "request_id=\(refusedIntent.requestID.uuidString.lowercased()) not_executed: the board refused the commit (STORE_FULL) before running it. Nothing ran; a new call may be made.")
        XCTAssertEqual(refusedTransport.uploads, uploadsBefore + 1,
                       "the refused commit was uploaded but never executed")

        let lostTransport = LinkTransport()
        let (lostStore, lostID) = try await makeLink(lostTransport)
        let lostRoot = makeReceiptRoot()
        let lostServer = DeviceMCPServer(receiptDirectory: lostRoot, store: lostStore)
        lostTransport.dropCommit = true
        let lost = await lostServer.handle(try call("ble_link_call",
                                                    .object(["device_id": .string(lostID.uuidString),
                                                             "name": .string("light.set"),
                                                             "args": self.lightOn]),
                                                    key: "lost"))
        let lostIntent = try XCTUnwrap(try journalIntents(journalDirectory(lostRoot)).first)
        XCTAssertEqual(try responseText(lost),
                       "request_id=\(lostIntent.requestID.uuidString.lowercased()) outcome_unknown: connection lost. Query this request; do not replay.")
    }

    /// The raw `tools/list` device ID is preserved verbatim for descriptor
    /// comparison while `linkIdentity` keeps its lowercased meaning, and both
    /// fields clear when the connection ends.
    @MainActor
    func testRawLinkDeviceIDKeepsToolsListCasingAndClearsOnDisconnect() async throws {
        let transport = LinkTransport()
        let (store, id) = try await makeLink(transport)
        let device = try XCTUnwrap(store.devices.first { $0.id == id })
        XCTAssertEqual(device.linkDeviceID, LinkTransport.deviceID)
        XCTAssertEqual(device.linkIdentity, LinkTransport.deviceID.lowercased())

        store.disconnect(id)
        store.testDidDisconnect(id)
        for _ in 0..<200 {
            if store.testPhase(id) == "idle" { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let disconnected = try XCTUnwrap(store.devices.first { $0.id == id })
        XCTAssertEqual(disconnected.linkDeviceID, "")
        XCTAssertEqual(disconnected.linkIdentity, "")

        // The alternate handshake helper used by Link tests keeps the same split.
        let identityID = "AbCdEf01-1111-4222-8333-123456789ABC"
        let adapter = BLEDeviceStore.TestAdapter()
        let other = UUID()
        let second = BLEDeviceStore(testAdapter: adapter,
                                    testDevices: [.init(id: other, name: "B", rssi: -60)])
        second.connect(other)
        second.testDidConnect(other)
        second.testDiscover(other, profiles: [.battery, .alert])
        second.testPrepareLink(other, bootID: 1, deviceID: identityID)
        let prepared = try XCTUnwrap(second.devices.first { $0.id == other })
        XCTAssertEqual(prepared.linkDeviceID, identityID)
        XCTAssertEqual(prepared.linkIdentity, identityID.lowercased())
    }
}

private extension JSONValue {
    var fields: [String: JSONValue] {
        if case .object(let fields) = self { return fields }
        return [:]
    }
}
