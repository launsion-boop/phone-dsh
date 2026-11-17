// SPDX-License-Identifier: MIT
import XCTest
import PhoneDSHAgentCore
import PhoneDSHLoopback
@testable import PhoneDSHBLE

/// device-app-v1 §7 host-only admission, next to LinkAdmissionTests: an agent-origin call of an
/// install tool is refused as `not_executed` / `host_only` after busy and authorization but before
/// the journal and the radio. A user/host origin is allowed, `app.info` stays open to the agent.
final class DeviceAppAdmissionTests: XCTestCase {
    private static let tools = ["app.info", "app.begin", "app.put", "app.abort", "app.commit", "app.run", "app.stop", "app.remove", "light.set"]

    @MainActor
    private final class LinkTransport: PDSHLinkTransport {
        var holdQueries = false
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
                let request = try JSONValue.parse(upload)
                let requestID = try XCTUnwrap(request["request_id"]?.stringValue)
                let name = try XCTUnwrap(request["name"]?.stringValue)
                lastTool = name
                if name == "tools/list" {
                    result = try JSONValue.object([
                        "request_id": .string(requestID), "status": .string("completed"),
                        "result": .object([
                            "device_id": .string("CE6EC956-1111-4222-8333-123456789ABC"), "boot_id": .number(0),
                            "tools": .array(DeviceAppAdmissionTests.tools.map { .object(["name": .string($0)]) }),
                        ]),
                    ]).encoded()
                } else {
                    result = try JSONValue.object([
                        "request_id": .string(requestID), "status": .string("completed"),
                        "result": .object(["ok": .bool(true)]),
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
    }

    @MainActor
    private func makeLink(_ transport: LinkTransport, granting: Bool = true) async throws -> (BLEDeviceStore, UUID) {
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
        for name in Self.tools { store.grantLinkTool(id, name: name, enabled: granting) }
        return (store, id)
    }

    private func makeRoot() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("device-app-admission-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func journalFiles(_ root: URL) -> [String] {
        let directory = root.appendingPathComponent("link-intents")
        return ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    private func args(for name: String) -> JSONValue {
        name == "light.set" ? .object(["on": .bool(true)]) : .object([:])
    }

    @MainActor
    func testAgentOriginInstallToolsAreHostOnlyBeforeJournalAndRadio() async throws {
        let transport = LinkTransport()
        let (store, id) = try await makeLink(transport)
        let root = makeRoot()
        let journal = LinkToolJournal(directory: root.appendingPathComponent("link-intents"))
        let uploads = transport.uploads, commits = transport.commits, queries = transport.queries

        for name in DeviceAppTools.hostOnly.sorted() {
            do {
                _ = try await callLinkTool(deviceID: id, name: name, arguments: args(for: name),
                                           idempotencyKey: "agent-\(name)", origin: .agent, store: store, journal: journal)
                XCTFail("\(name) must be refused for an agent")
            } catch let refused as LinkHostOnly {
                XCTAssertEqual(refused.name, name)
                XCTAssertTrue(refused.message.contains("host_only") && refused.message.contains("not_executed"))
            }
        }
        XCTAssertEqual(journalFiles(root), [], "refused before any journal record")
        XCTAssertEqual(transport.uploads, uploads)
        XCTAssertEqual(transport.commits, commits)
        XCTAssertEqual(transport.queries, queries)

        // The slot is released: an allowed call still works afterwards.
        let info = try await callLinkTool(deviceID: id, name: "app.info", arguments: .object([:]),
                                          idempotencyKey: "agent-info", origin: .agent, store: store, journal: journal)
        guard case .completed = info else { return XCTFail("app.info stays callable by an agent") }
        XCTAssertEqual(journalFiles(root).count, 1)
    }

    @MainActor
    func testUserOriginMayCallInstallTools() async throws {
        let transport = LinkTransport()
        let (store, id) = try await makeLink(transport)
        let root = makeRoot()
        let journal = LinkToolJournal(directory: root.appendingPathComponent("link-intents"))
        for name in DeviceAppTools.hostOnly.sorted() {
            let outcome = try await callLinkTool(deviceID: id, name: name, arguments: args(for: name),
                                                 idempotencyKey: "host-\(name)", origin: .user, store: store, journal: journal)
            guard case .completed = outcome else { return XCTFail("\(name) must run for the host") }
        }
        XCTAssertEqual(journalFiles(root).count, DeviceAppTools.hostOnly.count)
    }

    /// device-app-v1.3: the install path needs no Settings grant (the per-install approval is the
    /// authorization), but only for a user-origin call of the eight app.* tools.
    @MainActor
    func testUserOriginInstallToolsNeedNoSettingsGrantButAgentAndOtherToolsStillDo() async throws {
        let transport = LinkTransport()
        let (store, id) = try await makeLink(transport, granting: false)
        XCTAssertTrue(store.devices.first { $0.id == id }?.grantedTools.isEmpty == true)
        let root = makeRoot()
        let journal = LinkToolJournal(directory: root.appendingPathComponent("link-intents"))
        for name in DeviceAppTools.all.sorted() {
            let outcome = try await callLinkTool(deviceID: id, name: name, arguments: args(for: name),
                                                 idempotencyKey: "nogrant-\(name)", origin: .user, store: store, journal: journal)
            guard case .completed = outcome else { return XCTFail("\(name) must run for the host without a grant") }
        }
        XCTAssertTrue(store.devices.first { $0.id == id }?.grantedTools.isEmpty == true, "nothing is granted or remembered")
        let before = journalFiles(root)
        // Agent origin: refused with or without grants, before journal and radio.
        for name in DeviceAppTools.all.sorted() {
            do {
                _ = try await callLinkTool(deviceID: id, name: name, arguments: args(for: name),
                                           idempotencyKey: "agent-nogrant-\(name)", origin: .agent, store: store, journal: journal)
                XCTFail("\(name) must be refused for an agent without a grant")
            } catch {}
        }
        // A user-origin call of any other tool still needs its Settings grant.
        do {
            _ = try await callLinkTool(deviceID: id, name: "light.set", arguments: args(for: "light.set"),
                                       idempotencyKey: "nogrant-light", origin: .user, store: store, journal: journal)
            XCTFail("light.set must still need its grant")
        } catch {}
        XCTAssertEqual(journalFiles(root), before)
    }

    @MainActor
    func testBusyIsDecidedBeforeHostOnlyAndLeavesNoRecord() async throws {
        let transport = LinkTransport()
        let (store, id) = try await makeLink(transport)
        let root = makeRoot()
        let journal = LinkToolJournal(directory: root.appendingPathComponent("link-intents"))
        defer { transport.releaseHeldQueries() }
        transport.holdQueries = true
        let holder = Task { @MainActor in
            try await callLinkTool(deviceID: id, name: "light.set", arguments: self.args(for: "light.set"),
                                   idempotencyKey: "panel", origin: .user, store: store, journal: journal)
        }
        for _ in 0..<400 where transport.held.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(transport.held.isEmpty)
        let before = journalFiles(root)
        do {
            _ = try await callLinkTool(deviceID: id, name: "app.put", arguments: .object([:]),
                                       idempotencyKey: "agent-put", origin: .agent, store: store, journal: journal)
            XCTFail("busy expected")
        } catch is LinkBusy {
        } catch { XCTFail("busy must win over host_only: \(error)") }
        XCTAssertEqual(journalFiles(root), before)
        transport.holdQueries = false
        transport.releaseHeldQueries()
        _ = try await holder.value
    }

    @MainActor
    func testMCPLinkCallReportsHostOnlyAsNotExecutedWithoutJournal() async throws {
        let transport = LinkTransport()
        let (store, id) = try await makeLink(transport)
        let root = makeRoot()
        let server = DeviceMCPServer(receiptDirectory: root, store: store)
        let uploadsBefore = transport.uploads
        let body = try JSONValue.object([
            "jsonrpc": .string("2.0"), "id": .number(1), "method": .string("tools/call"),
            "params": .object(["name": .string("ble_link_call"), "arguments": .object([
                "device_id": .string(id.uuidString), "name": .string("app.commit"), "args": .object([:])])]),
        ]).encoded()
        let response = await server.handle(LoopbackRequest(
            method: "POST", path: "/mcp/native", headers: ["x-pdsh-idempotency-key": "agent-commit"], body: body))
        let parsed = try JSONValue.parse(response.body)
        XCTAssertEqual(parsed["result"]?["isError"]?.boolValue, true)
        let text = parsed["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
        XCTAssertTrue(text.contains("not_executed") && text.contains("host_only"), text)
        XCTAssertEqual(journalFiles(root), [])
        XCTAssertEqual(transport.uploads, uploadsBefore)
    }
}
