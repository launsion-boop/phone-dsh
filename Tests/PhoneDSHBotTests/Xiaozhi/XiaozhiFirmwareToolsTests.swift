// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

/// Everything the fake app records, in call order, so approval-first ordering is observable.
private actor Ledger {
    var events: [String] = []
    var stageRequests: [XiaozhiStageRequest] = []
    var buildRequests: [XiaozhiBuildRequest] = []
    var polls = 0
    var relayOn = true
    var existingBuilds: Set<String> = [elf]
    func log(_ event: String) { events.append(event) }
    func record(_ request: XiaozhiStageRequest) { stageRequests.append(request); events.append("stage") }
    func record(_ request: XiaozhiBuildRequest) { buildRequests.append(request); events.append("build") }
    func poll() -> Int { polls += 1; return polls }
    func setRelay(_ on: Bool) { relayOn = on }
}

private let mac = "98:c3:77:f4:ff:38"
private let elf = String(repeating: "1", count: 64)
private let sha = String(repeating: "2", count: 64)

private func image() -> XiaozhiImageInfo {
    XiaozhiImageInfo(bytes: 1_500_000, sha256: sha, elfSha256: elf, version: "2.6.0", matchesReference: false)
}

final class XiaozhiFirmwareToolsTests: XCTestCase {
    private struct Rig {
        let fixture: BotMCPTestFixture
        let ledger: Ledger
        var runtime: BotMCPRuntime { fixture.runtime }
    }

    /// bot-x: bound to `xiaozhi:<mac>`; bot-d: bound to a plain device key; bot-n: unbound.
    private func makeRig(installDeviceApp: Bool = true,
                         startOutcome: XiaozhiBuildStartOutcome? = nil,
                         jobs: [XiaozhiBuildJob] = []) async throws -> Rig {
        let fixture = try makeBotMCPFixture()
        let ledger = Ledger()
        let keys: @Sendable (String) async -> String? = { id in
            switch id {
            case "bot-x": return "xiaozhi:\(mac)"
            case "bot-d": return "dev-1"
            default: return nil
            }
        }
        let queue = JobQueue(jobs)
        let host = XiaozhiFirmwareToolHost(
            deviceKey: keys,
            exportSources: { _ in
                await ledger.log("export")
                return .exported(directory: "/ws/imports/xiaozhi-src", files: 12, bytes: 4096,
                                 project: "xiaozhi", target: "esp32c3")
            },
            startBuild: { request in
                await ledger.record(request)
                return startOutcome ?? .started(XiaozhiBuildJob(jobId: "job-1", state: .running))
            },
            pollBuild: { _ in _ = await ledger.poll(); return await queue.next() },
            deviceRecord: { _ in
                XiaozhiDeviceRecord(mac: mac, version: "2.6.0", elfSha256: sha,
                                    lastSeen: Date(timeIntervalSince1970: 0), lastDecision: "hold")
            },
            stagedImage: { _ in nil },
            relayState: { XiaozhiRelayState(on: await ledger.relayOn, otaURL: "http://10.0.0.2:8781/xiaozhi/ota/") },
            buildExists: { await ledger.existingBuilds.contains($0) },
            stageImage: { request in
                await ledger.record(request)
                return .staged(XiaozhiStagedImage(sha256: sha, elfSha256: request.elfSha256,
                                                  url: "http://10.0.0.2:8781/xiaozhi/firmware/\(sha).bin"))
            },
            buildWait: 0.3, pollInterval: 0.01)
        await fixture.runtime.setXiaozhiFirmwareTools(host)
        if installDeviceApp {
            await fixture.runtime.setDeviceAppTools(DeviceAppToolHost(
                deviceKey: keys, validate: { _, _ in nil }, digester: { _ in "" },
                installer: { .installed(digest: $0.digest) }, audit: { _ in }))
        }
        for (bot, session) in [("bot-x", "gb-x"), ("bot-d", "gb-d"), ("bot-n", "gb-n")] {
            _ = try await fixture.runtime.issueSession(botId: bot, sessionId: session, kind: .chat)
            await beginUserTurn(fixture.runtime, sessionId: session, rpcId: "rpc-\(session)")
        }
        return Rig(fixture: fixture, ledger: ledger)
    }

    private actor JobQueue {
        var jobs: [XiaozhiBuildJob]
        init(_ jobs: [XiaozhiBuildJob]) { self.jobs = jobs }
        func next() -> XiaozhiBuildJob? { jobs.count > 1 ? jobs.removeFirst() : jobs.first }
    }

    private func flash(_ rig: Rig, elf digest: String = elf, session: String = "gb-x",
                       decision: BotApprovalDecision?) async throws -> (BotMCPCallResult, [String]) {
        let args: BotJSONValue = .object(["elfSha256": .string(digest)])
        let runtime = rig.runtime
        let task = Task {
            try await registerAndExecute(runtime, name: "XiaozhiFirmwareFlash", arguments: args,
                                         sessionId: session)
        }
        var id: String?
        for _ in 0..<500 {
            if let first = await runtime.approvals.pendingIDs.first { id = first; break }
            if decision == nil { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let before = await rig.ledger.events
        if let id, let decision {
            _ = await runtime.approvals.resolve(
                approvalId: id, decision: decision, digest: try BotArgumentsDigest.string(for: args))
        }
        return (try await task.value, before)
    }

    // MARK: (e) listing

    func testBoundXiaozhiBotListsTheFourToolsAndNoDeviceAppTools() async throws {
        let rig = try await makeRig(); defer { rig.fixture.cleanup() }
        let names = await rig.runtime.toolDefinitions(callerBotID: "bot-x").map(\.name)
        for name in XiaozhiFirmwareToolNames.all { XCTAssertTrue(names.contains(name), name) }
        XCTAssertFalse(names.contains { $0.hasPrefix("DeviceApp") }, "device-app tools must not be listed")
        // A plain device-bound Bot keeps the device-app tools and never sees the xiaozhi ones.
        let plain = await rig.runtime.toolDefinitions(callerBotID: "bot-d").map(\.name)
        XCTAssertTrue(plain.contains("DeviceAppStage"))
        XCTAssertTrue(Set(plain).isDisjoint(with: XiaozhiFirmwareToolNames.all))
        let unbound = await rig.runtime.toolDefinitions(callerBotID: "bot-n").map(\.name)
        XCTAssertTrue(Set(unbound).isDisjoint(with: XiaozhiFirmwareToolNames.all))
        XCTAssertFalse(unbound.contains("DeviceAppStage"))
        // Present in the all-callers list while the host is installed (spec §6 r2), like the
        // device-app tools: the Worker registers from this list and hides them per caller.
        let anonymous = await rig.runtime.toolDefinitions(callerBotID: nil).map(\.name)
        XCTAssertTrue(XiaozhiFirmwareToolNames.all.allSatisfy(anonymous.contains))
    }

    func testNothingIsListedWithoutTheHost() async throws {
        let rig = try await makeRig(); defer { rig.fixture.cleanup() }
        await rig.runtime.setXiaozhiFirmwareTools(nil)
        let names = await rig.runtime.toolDefinitions(callerBotID: "bot-x").map(\.name)
        XCTAssertTrue(Set(names).isDisjoint(with: XiaozhiFirmwareToolNames.all))
        // Without the host the tool is unknown: identity registration or execute refuses it.
        do {
            let call = try await registerAndExecute(rig.runtime, name: "XiaozhiFirmwareStatus", sessionId: "gb-x")
            XCTAssertEqual(call.isError, true)
        } catch {
            XCTAssertEqual(error as? BotMCPError, .unknownTool("XiaozhiFirmwareStatus"))
        }
    }

    func testXiaozhiBotCannotCallDeviceAppToolsAndOthersCannotCallXiaozhiTools() async throws {
        let rig = try await makeRig(); defer { rig.fixture.cleanup() }
        let stage = try await registerAndExecute(
            rig.runtime, name: "DeviceAppList", sessionId: "gb-x")
        XCTAssertEqual(stage.isError, true)
        for session in ["gb-d", "gb-n"] {
            for name in ["XiaozhiSourceExport", "XiaozhiFirmwareBuild", "XiaozhiFirmwareStatus"] {
                let result = try await registerAndExecute(rig.runtime, name: name, sessionId: session)
                XCTAssertEqual(result.isError, true, "\(session) \(name)")
            }
            let (flashed, _) = try await flash(rig, session: session, decision: nil)
            XCTAssertEqual(flashed.isError, true)
        }
        let ledger = await rig.ledger.events
        XCTAssertEqual(ledger, [])
        let pending = await rig.runtime.approvals.pendingIDs
        XCTAssertTrue(pending.isEmpty)
    }

    // MARK: auto tools

    func testExportBuildAndStatusRunWithoutAnApprovalCard() async throws {
        let done = XiaozhiBuildJob(jobId: "job-1", state: .done, changed: ["main/a.cc"],
                                   ignored: ["notes.txt"], image: image())
        let rig = try await makeRig(jobs: [XiaozhiBuildJob(jobId: "job-1", state: .running), done])
        defer { rig.fixture.cleanup() }

        let export = try await registerAndExecute(rig.runtime, name: "XiaozhiSourceExport", sessionId: "gb-x")
        XCTAssertNil(export.isError)
        XCTAssertEqual(export.structuredContent?["directory"]?.stringValue, "/ws/imports/xiaozhi-src")
        XCTAssertEqual(export.structuredContent?["files"], .number(12))
        XCTAssertEqual(export.structuredContent?["pack"]?["target"]?.stringValue, "esp32c3")

        let build = try await registerAndExecute(
            rig.runtime, name: "XiaozhiFirmwareBuild",
            arguments: .object(["directory": .string("/ws/imports/xiaozhi-src")]), sessionId: "gb-x")
        XCTAssertNil(build.isError)
        XCTAssertEqual(build.structuredContent?["state"]?.stringValue, "done")
        XCTAssertEqual(build.structuredContent?["image"]?["elfSha256"]?.stringValue, elf)
        XCTAssertEqual(build.structuredContent?["changed"], .array([.string("main/a.cc")]))
        let request = await rig.ledger.buildRequests.first
        XCTAssertEqual(request?.directory, "/ws/imports/xiaozhi-src")

        let status = try await registerAndExecute(rig.runtime, name: "XiaozhiFirmwareStatus", sessionId: "gb-x")
        XCTAssertNil(status.isError)
        XCTAssertEqual(status.structuredContent?["device"]?["mac"]?.stringValue, mac)
        XCTAssertEqual(status.structuredContent?["device"]?["seen"], .bool(true))
        XCTAssertEqual(status.structuredContent?["device"]?["lastDecision"]?.stringValue, "hold")
        XCTAssertEqual(status.structuredContent?["relay"]?["on"], .bool(true))
        XCTAssertNil(status.structuredContent?["staged"])
        XCTAssertEqual(status.structuredContent?["job"]?["jobId"]?.stringValue, "job-1")
        let pending = await rig.runtime.approvals.pendingIDs
        XCTAssertTrue(pending.isEmpty)
    }

    func testBuildStillRunningAfterTheWaitReturnsRunning() async throws {
        let rig = try await makeRig(jobs: [XiaozhiBuildJob(jobId: "job-1", state: .running)])
        defer { rig.fixture.cleanup() }
        let build = try await registerAndExecute(rig.runtime, name: "XiaozhiFirmwareBuild", sessionId: "gb-x")
        XCTAssertNil(build.isError)
        XCTAssertEqual(build.structuredContent?["state"]?.stringValue, "running")
        XCTAssertEqual(build.structuredContent?["jobId"]?.stringValue, "job-1")
        let polls = await rig.ledger.polls
        XCTAssertGreaterThan(polls, 1)
    }

    func testBuildBusyAndInvalidArguments() async throws {
        let rig = try await makeRig(startOutcome: .busy(jobId: "job-9")); defer { rig.fixture.cleanup() }
        let busy = try await registerAndExecute(rig.runtime, name: "XiaozhiFirmwareBuild", sessionId: "gb-x")
        XCTAssertEqual(busy.isError, true)
        XCTAssertEqual(busy.structuredContent?["code"]?.stringValue, "busy")
        XCTAssertEqual(busy.structuredContent?["jobId"]?.stringValue, "job-9")
        for bad: BotJSONValue in [.object(["directory": .string("")]), .object(["directory": .number(1)]),
                                  .object(["other": .string("x")])] {
            let result = try await registerAndExecute(
                rig.runtime, name: "XiaozhiFirmwareBuild", arguments: bad, sessionId: "gb-x")
            XCTAssertEqual(result.structuredContent?["error"]?["code"]?.stringValue, "invalid_arguments")
        }
    }

    // MARK: (d) flash: approval first, denied path

    func testFlashAsksBeforeAnySideEffectAndStagesOnce() async throws {
        let rig = try await makeRig(); defer { rig.fixture.cleanup() }
        let (result, beforeApproval) = try await flash(rig, decision: .allowOnce)
        XCTAssertEqual(beforeApproval, [], "nothing may happen before the user answers")
        XCTAssertNil(result.isError, "\(result)")
        XCTAssertEqual(result.structuredContent?["ok"], .bool(true))
        XCTAssertEqual(result.structuredContent?["staged"]?["elfSha256"]?.stringValue, elf)
        XCTAssertEqual(result.structuredContent?["staged"]?["sha256"]?.stringValue, sha)
        XCTAssertEqual(result.structuredContent?["device"]?["mac"]?.stringValue, mac)
        XCTAssertEqual(result.structuredContent?["next"]?.stringValue, XiaozhiFirmwareToolHost.flashNext)
        let requests = await rig.ledger.stageRequests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.mac, mac)
        XCTAssertFalse(requests.first?.approvalID.isEmpty ?? true)
    }

    func testFlashDeniedStagesNothing() async throws {
        let rig = try await makeRig(); defer { rig.fixture.cleanup() }
        let (result, _) = try await flash(rig, decision: .deny)
        XCTAssertEqual(result.isError, true)
        XCTAssertEqual(result.structuredContent?["error"]?["code"]?.stringValue, "approval_denied")
        let requests = await rig.ledger.stageRequests
        XCTAssertTrue(requests.isEmpty)
    }

    func testFlashNeverAcceptsAnOutcomeWithoutAnApprovalID() async throws {
        let fixture = try makeBotMCPFixture(); defer { fixture.cleanup() }
        let ledger = Ledger()
        let host = XiaozhiFirmwareToolHost(
            deviceKey: { _ in "xiaozhi:\(mac)" },
            exportSources: { _ in .failed(code: "export_failed", message: "x") },
            startBuild: { _ in .failed(code: "build_failed", message: "x") },
            pollBuild: { _ in nil }, deviceRecord: { _ in nil }, stagedImage: { _ in nil },
            relayState: { XiaozhiRelayState(on: true) }, buildExists: { _ in true },
            stageImage: { request in await ledger.record(request); return .noBuild })
        let principal = BotGatewayPrincipal(botId: "bot-x", sessionId: "s", kind: .chat, expiresAt: 1)
        let authority = BotTurnAuthority(rpcId: "r", turnId: "t", sessionId: "s", origin: .user, isUserTurn: true)
        let args: BotJSONValue = .object(["elfSha256": .string(elf)])
        var asked: BotToolEffect?
        for outcome in [BotApprovalOutcome(ok: true, allowed: true, approvalId: nil),
                        BotApprovalOutcome(ok: true, allowed: true, approvalId: ""),
                        BotApprovalOutcome(ok: true, allowed: false, approvalId: "a1"),
                        BotApprovalOutcome(ok: true, allowed: false, approvalId: "a1", pending: true)] {
            let result = await host.flash(arguments: args, principal: principal, authority: authority) { effect in
                asked = effect
                return outcome
            }
            XCTAssertEqual(result.structuredContent?["error"]?["code"]?.stringValue, "approval_denied")
        }
        let requests = await ledger.stageRequests
        XCTAssertTrue(requests.isEmpty)
        // The card: once-only (no standing grant), label, MAC and the first 12 hex of the ELF digest.
        let effect = try XCTUnwrap(asked)
        XCTAssertEqual(effect.label, "给小智刷入固件")
        XCTAssertEqual(effect.operation, "device.xiaozhi.flash")
        XCTAssertEqual(effect.policy, .ask)
        XCTAssertEqual(effect.mutability, .destructive)
        XCTAssertFalse(effect.canUseStandingGrant)
        XCTAssertEqual(effect.resource, "xiaozhi:flash&elf=\(elf)")
        XCTAssertTrue(effect.detail.contains(mac))
        XCTAssertTrue(effect.detail.contains(String(elf.prefix(12))))
        XCTAssertFalse(effect.detail.contains(String(elf.prefix(13))))
    }

    func testFlashChecksThatCannotSucceedRaiseNoCard() async throws {
        let rig = try await makeRig(); defer { rig.fixture.cleanup() }
        let unknown = String(repeating: "3", count: 64)
        let (missing, _) = try await flash(rig, elf: unknown, decision: nil)
        XCTAssertEqual(missing.structuredContent?["error"]?["code"]?.stringValue, "no_build")
        await rig.ledger.setRelay(false)
        let (off, _) = try await flash(rig, decision: nil)
        XCTAssertEqual(off.structuredContent?["error"]?["code"]?.stringValue, "relay_off")
        for bad in ["", "ABC", String(repeating: "A", count: 64), String(repeating: "1", count: 63)] {
            let (invalid, _) = try await flash(rig, elf: bad, decision: nil)
            XCTAssertEqual(invalid.structuredContent?["error"]?["code"]?.stringValue, "invalid_arguments", bad)
        }
        let pending = await rig.runtime.approvals.pendingIDs
        XCTAssertTrue(pending.isEmpty)
        let requests = await rig.ledger.stageRequests
        XCTAssertTrue(requests.isEmpty)
    }
}
