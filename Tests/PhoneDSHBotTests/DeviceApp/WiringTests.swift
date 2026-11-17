// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

private actor Log {
    var order: [String] = []
    var requests: [DeviceAppInstallRequest] = []
    var events: [BotEvent] = []
    func add(_ step: String) { order.append(step) }
    func add(_ request: DeviceAppInstallRequest) { requests.append(request); order.append("transfer") }
    func add(_ event: BotEvent) { events.append(event) }
}

final class DeviceAppWiringTests: XCTestCase {
    private let manifest = #"{"name":"counter","title":"计数器","version":1,"perms":[]}"#
    private let program = "import lcd, keys\nwhile keys.get() != \"back\":\n    pass\n"
    private static let allTools = DeviceAppWiring.requiredTools

    private func goldenRows() throws -> [[String: Any]] {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<8 {
            dir.deleteLastPathComponent()
            let url = dir.appendingPathComponent("spec/device/v1/golden/device-app.jsonl")
            if FileManager.default.fileExists(atPath: url.path) {
                return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
                    try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
                }
            }
        }
        throw NSError(domain: "DeviceAppWiringTests", code: 1)
    }

    private func request(deviceKey: String = "dev-1") -> DeviceAppInstallRequest {
        let host = DeviceAppToolHost(deviceKey: { _ in deviceKey }, validate: DeviceAppWiring.validator,
                                     digester: DeviceAppWiring.digester,
                                     installer: { _ in .failed(code: "x", message: "x") }, audit: { _ in })
        _ = host
        let files = [DeviceAppFile(path: "main.py", content: program),
                     DeviceAppFile(path: "app.json", content: manifest)]
        let entries = files.map {
            DeviceAppFileEntry(path: $0.path, size: $0.data.count, sha256: DeviceAppToolHost.sha256Hex($0.data))
        }
        return DeviceAppInstallRequest(
            installID: "i1", deviceKey: deviceKey,
            manifest: DeviceAppToolHost.manifest(in: files)!, files: files, entries: entries,
            digest: DeviceAppWiring.digester(entries))
    }

    // MARK: shared golden through the adapters

    func testGoldenDigestAndCheckVectorsRunThroughTheWiredAdapters() throws {
        var digests = 0, checks = 0
        for row in try goldenRows() {
            let id = row["id"] as? String ?? "?"
            switch row["kind"] as? String {
            case "digest":
                let entries = (row["files"] as! [[String: Any]]).map {
                    DeviceAppFileEntry(path: $0["path"] as! String, size: $0["size"] as! Int, sha256: $0["sha256"] as! String)
                }
                XCTAssertEqual(DeviceAppWiring.digester(entries), row["digest"] as? String, id)
                digests += 1
            case "check":
                guard let files = row["files"] as? [String: String] else { continue }
                let perms = row["perms"] as? [String] ?? []
                let got = DeviceAppWiring.validator(files.map { DeviceAppFile(path: $0.key, content: $0.value) }, perms)
                // The adapter must report exactly the validator's first violation.
                XCTAssertEqual(got?.code, DeviceAppValidator.check(files: files, perms: perms)?.code.rawValue, id)
                if row["ok"] as? Bool == true { XCTAssertNil(got, id) }
                checks += 1
            default: break
            }
        }
        XCTAssertGreaterThan(digests, 0)
        XCTAssertGreaterThan(checks, 0)
    }

    // MARK: preflight

    func testPreflightCodes() {
        XCTAssertEqual(DeviceAppWiring.preflight(nil)?.code, "device_not_found")
        XCTAssertEqual(DeviceAppWiring.preflight(.init(connected: false, tools: Self.allTools,
                                                       granted: Set(Self.allTools)))?.code, "device_not_connected")
        XCTAssertEqual(DeviceAppWiring.preflight(.init(connected: true, tools: ["app.info", "app.begin"],
                                                       granted: Set(Self.allTools)))?.code, "device_tools_missing")
        XCTAssertEqual(DeviceAppWiring.preflight(.init(connected: true, tools: Self.allTools,
                                                       granted: ["app.info"]))?.code, "device_not_authorized")
        XCTAssertNil(DeviceAppWiring.preflight(.init(connected: true, tools: Self.allTools,
                                                     granted: Set(Self.allTools))))
    }

    func testInfoMustReportTheProtocol() {
        XCTAssertNil(DeviceAppWiring.checkInfo(.reply(protocolName: "device-app-v1", running: [])))
        XCTAssertEqual(DeviceAppWiring.checkInfo(.reply(protocolName: "device-app-v2", running: []))?.code, "device_protocol_mismatch")
        XCTAssertEqual(DeviceAppWiring.checkInfo(.reply(protocolName: nil, running: []))?.code, "device_protocol_mismatch")
        XCTAssertEqual(DeviceAppWiring.checkInfo(.unavailable("busy"))?.code, "device_info_failed")
    }

    private func installer(log: Log, state: DeviceAppLinkState?, info: DeviceAppInfoResult,
                           stopFails: Bool = false) -> DeviceAppToolHost.Installer {
        DeviceAppWiring.installer(
            linkState: { _ in await log.add("state"); return state },
            info: { _ in await log.add("info"); return info },
            stopRunning: { _ in await log.add("stop"); return stopFails ? "busy" : nil },
            transfer: { await log.add($0); return .installed(digest: $0.digest) })
    }

    private let good = DeviceAppLinkState(connected: true, tools: DeviceAppWiringTests.allTools,
                                          granted: Set(DeviceAppWiringTests.allTools))

    func testInstallerOrdersStateInfoTransfer() async {
        let log = Log()
        let request = request()
        let outcome = await installer(log: log, state: good, info: .reply(protocolName: "device-app-v1", running: []))(request)
        XCTAssertEqual(outcome, .installed(digest: request.digest))
        let order = await log.order
        XCTAssertEqual(order, ["state", "info", "transfer"])
    }

    func testRunningSameAppIsStoppedBeforeTransferAndOtherAppIsNot() async {
        let log = Log()
        _ = await installer(log: log, state: good,
                            info: .reply(protocolName: "device-app-v1", running: ["counter"]))(request())
        let order = await log.order
        XCTAssertEqual(order, ["state", "info", "stop", "transfer"])
        let other = Log()
        _ = await installer(log: other, state: good,
                            info: .reply(protocolName: "device-app-v1", running: ["other"]))(request())
        let otherOrder = await other.order
        XCTAssertEqual(otherOrder, ["state", "info", "transfer"])
        let failing = Log()
        let outcome = await installer(log: failing, state: good,
                                      info: .reply(protocolName: "device-app-v1", running: ["counter"]),
                                      stopFails: true)(request())
        guard case .failed(let code, _) = outcome else { return XCTFail() }
        XCTAssertEqual(code, "stop_failed")
        let failOrder = await failing.order
        XCTAssertFalse(failOrder.contains("transfer"))
    }

    func testInstallerNeverTransfersWhenAnyGateFails() async {
        let cases: [(DeviceAppLinkState?, DeviceAppInfoResult, String)] = [
            (nil, .reply(protocolName: "device-app-v1", running: []), "device_not_found"),
            (DeviceAppLinkState(connected: false, tools: Self.allTools, granted: Set(Self.allTools)),
             .reply(protocolName: "device-app-v1", running: []), "device_not_connected"),
            (DeviceAppLinkState(connected: true, tools: ["app.info"], granted: Set(Self.allTools)),
             .reply(protocolName: "device-app-v1", running: []), "device_tools_missing"),
            (good, .reply(protocolName: "other", running: []), "device_protocol_mismatch"),
            (good, .unavailable("x"), "device_info_failed"),
        ]
        for (state, info, code) in cases {
            let log = Log()
            let outcome = await installer(log: log, state: state, info: info)(request())
            guard case .failed(let got, let message) = outcome else { return XCTFail(code) }
            XCTAssertEqual(got, code)
            XCTAssertFalse(message.isEmpty)
            let order = await log.order
            XCTAssertFalse(order.contains("transfer"), code)
            // No radio (info) before the phone-side state is known good.
            if code != "device_protocol_mismatch" && code != "device_info_failed" {
                XCTAssertFalse(order.contains("info"), code)
            }
        }
    }

    func testInstallerRefusesADigestThatDoesNotMatchTheEntries() async {
        let log = Log()
        let base = request()
        let bad = DeviceAppInstallRequest(installID: base.installID, deviceKey: base.deviceKey,
                                          manifest: base.manifest, files: base.files, entries: base.entries,
                                          digest: String(repeating: "0", count: 64))
        let outcome = await installer(log: log, state: good, info: .reply(protocolName: "device-app-v1", running: []))(bad)
        guard case .failed(let code, _) = outcome else { return XCTFail() }
        XCTAssertEqual(code, "digest_mismatch")
        let order = await log.order
        XCTAssertFalse(order.contains("transfer"))
    }

    // MARK: audit

    private func audit(_ request: DeviceAppInstallRequest) -> DeviceAppInstallAudit {
        DeviceAppInstallAudit(
            deviceKey: request.deviceKey, manifest: request.manifest, digest: request.digest,
            files: request.entries,
            author: BotTeammateAuthor(rpcId: "rpc", turnId: "t", sessionId: "s", origin: .user,
                                      authorization: .userConfirmed, approvalID: "ap-1"))
    }

    func testAuditEventShape() async throws {
        let log = Log()
        let request = request()
        let auditor = DeviceAppWiring.auditor(botForDevice: { _ in "bot-a" },
                                              append: { await log.add($0) }, now: { 42 })
        try await auditor(audit(request))
        let events = await log.events
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(event.type, "ui.system_event")
        // Found on the board: the event used an origin source the store refuses, so the install audit
        // was never recorded. The event must pass the same validation the store applies.
        XCTAssertNoThrow(try BotEventEnvelopeCodec.validate(event, mode: .append))
        XCTAssertEqual(event.principal.botId, "bot-a")
        XCTAssertEqual(event.time, 42)
        XCTAssertEqual(event.data["event"]?.stringValue, "device.app.install")
        XCTAssertEqual(event.data["digest"]?.stringValue, request.digest)
        XCTAssertEqual(event.data["device"]?.stringValue, "dev-1")
        XCTAssertEqual(event.data["author"]?["approvalID"]?.stringValue, "ap-1")
        XCTAssertEqual(event.data["files"]?.arrayValue?.count, 2)
    }

    func testAuditThrowsWhenTheWriteFailsOrNoBotIsBound() async {
        let request = request()
        let failing = DeviceAppWiring.auditor(botForDevice: { _ in "bot-a" },
                                              append: { _ in throw BotMCPError.unavailable("db down") })
        do { try await failing(audit(request)); XCTFail("must throw") } catch {}
        let log = Log()
        let orphan = DeviceAppWiring.auditor(botForDevice: { _ in nil }, append: { await log.add($0) })
        do { try await orphan(audit(request)); XCTFail("must throw") } catch {
            XCTAssertEqual(error as? DeviceAppWiring.AuditError, .noBot)
        }
        let events = await log.events
        XCTAssertTrue(events.isEmpty)
    }

    func testHostReportsAuditNotRecordedWhenTheWriteFails() async throws {
        let fixture = try makeBotMCPFixture(); defer { fixture.cleanup() }
        let host = DeviceAppWiring.toolHost(
            deviceKey: { $0 == "bot-a" ? "dev-1" : nil },
            installer: installer(log: Log(), state: good, info: .reply(protocolName: "device-app-v1", running: [])),
            audit: DeviceAppWiring.auditor(botForDevice: { _ in "bot-a" },
                                           append: { _ in throw BotMCPError.unavailable("db down") }))
        await fixture.runtime.setDeviceAppTools(host)
        _ = try await fixture.runtime.issueSession(botId: "bot-a", sessionId: "gb-a", kind: .chat)
        await beginUserTurn(fixture.runtime, sessionId: "gb-a", rpcId: "rpc-1")
        let staged = try await registerAndExecute(
            fixture.runtime, name: "DeviceAppStage",
            arguments: .object(["files": .array([
                .object(["path": .string("main.py"), "content": .string(program)]),
                .object(["path": .string("app.json"), "content": .string(manifest)]),
            ])]), sessionId: "gb-a")
        let digest = try XCTUnwrap(staged.structuredContent?["digest"]?.stringValue)
        let args: BotJSONValue = .object(["digest": .string(digest)])
        let runtime = fixture.runtime
        let task = Task { try await registerAndExecute(runtime, name: "DeviceAppInstall", arguments: args,
                                                       sessionId: "gb-a", callId: UUID().uuidString) }
        var id: String?
        for _ in 0..<500 {
            if let first = await runtime.approvals.pendingIDs.first { id = first; break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        _ = await runtime.approvals.resolve(approvalId: try XCTUnwrap(id), decision: .allowOnce,
                                            digest: try BotArgumentsDigest.string(for: args))
        let result = try await task.value
        XCTAssertEqual(result.structuredContent?["installed"]?.boolValue, true)
        XCTAssertEqual(result.structuredContent?["audit_recorded"]?.boolValue, false)
    }

    // MARK: persona

    func testPersonaGuideOnlyForBoundBots() async throws {
        DeviceAppWiring.setBoundDeviceResolver { $0 == "bot-a" ? "dev-1" : nil }
        defer { DeviceAppWiring.setBoundDeviceResolver(nil) }
        let persona = DeviceAppWiring.decoratePersona { _, _, _ in "base" }
        let bound = try await persona("bot-a", "s", .chat)
        let unbound = try await persona("bot-b", "s", .chat)
        XCTAssertTrue(bound.hasPrefix("base") && bound.contains("设备应用作者指南"))
        XCTAssertEqual(unbound, "base")
        DeviceAppWiring.setBoundDeviceResolver(nil)
        let none = try await persona("bot-a", "s", .chat)
        XCTAssertEqual(none, "base")
    }
}
