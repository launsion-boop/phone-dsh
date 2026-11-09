// SPDX-License-Identifier: MIT
// D2 simulator regressions: P18 scoped storage/migration, the drawer's
// never-fall-back-to-phone policy, PC backend capabilities and the pairing
// page state machine driven through the injectable PCLink client seam.

import Foundation
import PhoneDSHAgentCore
import PhoneDSHPCLink
import ProbeKit
import XCTest

// MARK: - Fakes

private final class FakePCLinkTransport: DSHRemoteTransport, @unchecked Sendable {
    func call(_ endpoint: String, args: JSONValue) async throws -> JSONValue { .object([:]) }
    func openMux() async throws -> any DSHMuxConnection { FakePCLinkMux() }
    func authenticationFailed() async {}
}

private final class FakePCLinkMux: DSHMuxConnection, @unchecked Sendable {
    func send(_ frame: JSONValue) async throws {}
    func receive() async throws -> JSONValue? { nil }
    func close() async {}
}

private actor FakePCLinkClient: PCLinkClientProtocol {
    var state: PCLinkClientState
    var statusValue: PCLinkClientStatus
    var startPairingResult: Result<PCPairingApproval, Error>
    var confirmResult: Result<PCLinkPairingRecord, Error>
    private(set) var startCalls = 0
    private(set) var confirmCalls = 0
    private let pairingUpdateStream: AsyncStream<PCLinkPairingUpdate>
    private let pairingUpdateContinuation: AsyncStream<PCLinkPairingUpdate>.Continuation
    private var confirmGate: CheckedContinuation<Void, Never>?
    private var confirmIsGated = false

    init(state: PCLinkClientState = .offline(.notStarted),
         status: PCLinkClientStatus = PCLinkClientStatus(),
         startPairingResult: Result<PCPairingApproval, Error> = .failure(PCLinkError.unavailable("not scripted")),
         confirmResult: Result<PCLinkPairingRecord, Error> = .failure(PCLinkError.unavailable("not scripted")),
         gateConfirm: Bool = false) {
        self.state = state
        self.statusValue = status
        self.startPairingResult = startPairingResult
        self.confirmResult = confirmResult
        let (stream, continuation) = AsyncStream.makeStream(of: PCLinkPairingUpdate.self)
        self.pairingUpdateStream = stream
        self.pairingUpdateContinuation = continuation
        self.confirmIsGated = gateConfirm
    }

    nonisolated func makeRelayTransport() -> any DSHRemoteTransport { FakePCLinkTransport() }

    func currentState() async -> PCLinkClientState { state }
    func status() async -> PCLinkClientStatus {
        var value = statusValue
        value.state = state
        return value
    }
    func stateStream() async -> AsyncStream<PCLinkClientState> {
        let state = self.state
        return AsyncStream { continuation in
            continuation.yield(state)
            continuation.finish()
        }
    }
    func noticeStream() async -> AsyncStream<PCLinkNotice> {
        AsyncStream { $0.finish() }
    }
    func pairingUpdates() async -> AsyncStream<PCLinkPairingUpdate> {
        pairingUpdateStream
    }
    func emitPairingUpdate(_ update: PCLinkPairingUpdate) {
        pairingUpdateContinuation.yield(update)
    }
    func releaseConfirm() {
        confirmIsGated = false
        confirmGate?.resume()
        confirmGate = nil
    }

    func start() async throws { startCalls += 1 }
    func stop() async {}
    func connectAndWait() async throws {}

    func startPairing(qrURI: String) async throws -> PCPairingApproval {
        try startPairingResult.get()
    }
    func startManualPairing(code: String, relayOrigin: String,
                            pcName: String?) async throws -> PCPairingApproval {
        try startPairingResult.get()
    }
    func confirmPairingApproval(_ id: UUID) async throws -> PCLinkPairingRecord {
        confirmCalls += 1
        if confirmIsGated {
            await withCheckedContinuation { confirmGate = $0 }
        }
        return try confirmResult.get()
    }
    func cancelPairing() async {}

    func unpair() async throws {}
    func acknowledgePCUnpair() async throws {}
    func removeLocalRecord() async throws {}
    func clearLastError() async {}
}

// MARK: - Fixtures

private func makeRecord(name: String = "My PC",
                        machineId: String = "abcdefghijklmnopqrstuvwxyz") -> PCLinkPairingRecord {
    PCLinkPairingRecord(peerMachineId: machineId,
                        peerPublicKey: Data(repeating: 1, count: 32),
                        peerName: name,
                        pairedAt: "2026-11-10T00:00:00Z",
                        relayOrigin: "ws://127.0.0.1:3240",
                        connectionMode: .relay)
}

private func makeApproval(id: UUID = UUID()) -> PCPairingApproval {
    PCPairingApproval(id: id,
                      mode: .qr,
                      relayOrigin: "ws://127.0.0.1:3240",
                      pcName: "My PC",
                      pcMachineId: "abcdefghijklmnopqrstuvwxyz",
                      ownFingerprint: "abcd-efgh-ijkl",
                      warningText: PCLinkPairingPrompt.fullOwnerWarning,
                      expiresAt: Date().addingTimeInterval(120))
}

/// A UserDefaults suite plus the name needed to delete its persistent domain.
private struct TestDefaults {
    let defaults: UserDefaults
    let suite: String

    init() {
        suite = "pclink-d2-tests-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    func remove() {
        defaults.removePersistentDomain(forName: suite)
    }
}

// MARK: - Tests

@MainActor
final class PCLinkWorkspaceSimTests: XCTestCase {
    // P18: the same DSH session ID on both backends keeps two drafts and two
    // current-session values.
    func testScopedDraftsAndCurrentSessionsSurviveBackendSwitch() {
        let store = TestDefaults()
        defer { store.remove() }
        let defaults = store.defaults
        let phone = BackendID.phone
        let pc = BackendID.pc(machineId: "pc-machine")
        XCTAssertNotEqual(phone.storageScope, pc.storageScope)

        WorkspaceStorage.setDraft("手机草稿", for: phone, sessionID: "shared-session", defaults: defaults)
        WorkspaceStorage.setDraft("PC draft", for: pc, sessionID: "shared-session", defaults: defaults)
        WorkspaceStorage.setDraft("new phone", for: phone, sessionID: nil, defaults: defaults)
        WorkspaceStorage.setDraft("new pc", for: pc, sessionID: nil, defaults: defaults)
        WorkspaceStorage.setCurrentSessionID("phone-session", for: phone, defaults: defaults)
        WorkspaceStorage.setCurrentSessionID("pc-session", for: pc, defaults: defaults)

        // Simulate 手机 → PC → 手机 without touching the models.
        DrawerBackendSetting.save(.pc, to: defaults)
        XCTAssertEqual(DrawerBackendSetting.load(from: defaults), .pc)
        XCTAssertEqual(WorkspaceStorage.draft(for: pc, sessionID: "shared-session", defaults: defaults),
                       "PC draft")
        XCTAssertEqual(WorkspaceStorage.currentSessionID(for: pc, defaults: defaults), "pc-session")

        DrawerBackendSetting.save(.phone, to: defaults)
        XCTAssertEqual(WorkspaceStorage.draft(for: phone, sessionID: "shared-session", defaults: defaults),
                       "手机草稿")
        XCTAssertEqual(WorkspaceStorage.draft(for: phone, sessionID: nil, defaults: defaults), "new phone")
        XCTAssertEqual(WorkspaceStorage.currentSessionID(for: phone, defaults: defaults), "phone-session")
        XCTAssertEqual(WorkspaceStorage.draft(for: pc, sessionID: nil, defaults: defaults), "new pc")
    }

    func testDrawerBackendKeyIsClosedAndDefaultsToPhone() {
        let store = TestDefaults()
        defer { store.remove() }
        let defaults = store.defaults
        XCTAssertEqual(DrawerBackendSetting.load(from: defaults), .phone)
        defaults.set("future-multi", forKey: WorkspaceStorageKeys.drawerBackend)
        XCTAssertEqual(DrawerBackendSetting.load(from: defaults), .phone)
        DrawerBackendSetting.save(.pc, to: defaults)
        XCTAssertEqual(defaults.string(forKey: WorkspaceStorageKeys.drawerBackend), "pc")
    }

    // The selected PC segment must not become the phone because the PC is
    // offline (plan v2 §6.1 / contract §10).
    func testOfflinePCSelectionNeverFallsBackToPhone() {
        let pc = BackendID.pc(machineId: "pc-machine")
        XCTAssertEqual(PCLinkDrawerPolicy.phase(selected: .pc, hasRecord: true,
                                                connection: .offline(.peerOffline)), .offline)
        XCTAssertEqual(PCLinkDrawerPolicy.phase(selected: .pc, hasRecord: true,
                                                connection: .offline(.network)), .offline)
        XCTAssertEqual(PCLinkDrawerPolicy.phase(selected: .pc, hasRecord: false,
                                                connection: .unpaired), .pair)
        XCTAssertEqual(PCLinkDrawerPolicy.phase(selected: .pc, hasRecord: true,
                                                connection: .online), .ready)
        XCTAssertEqual(PCLinkDrawerPolicy.phase(selected: .phone, hasRecord: true,
                                                connection: .offline(.peerOffline)), .phone)
        XCTAssertEqual(WorkspaceStorageKeys.currentSession(for: pc),
                       "chat.dsh.currentSession.pc:pc-machine")
        XCTAssertEqual(SessionStorageKey(backend: pc, sessionID: "abc").encoded,
                       "pc:pc-machine|abc")
        XCTAssertEqual(SessionStorageKey(encoded: "phone|abc"),
                       SessionStorageKey(backend: .phone, sessionID: "abc"))
    }

    // One-time copy old bare keys → phone|…; a second run is a no-op, and the
    // legacy keys/files stay for rollback.
    func testMigrationCopiesLegacyKeysAndIsIdempotent() throws {
        let store = TestDefaults()
        defer { store.remove() }
        let defaults = store.defaults
        let documents = FileManager.default.temporaryDirectory
            .appendingPathComponent("pclink-d2-migration-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: documents) }

        defaults.set("legacy-session", forKey: WorkspaceStorageKeys.legacyCurrentSession)
        defaults.set(["legacy-session": "old draft", "new": "new draft"],
                     forKey: WorkspaceStorageKeys.legacyDrafts)
        defaults.set(["legacy-session": "旧标题"],
                     forKey: WorkspaceStorageKeys.legacyTitleHints)
        defaults.set(["ws-1"], forKey: WorkspaceStorageKeys.legacyCollapsedWorkspaces)

        let legacyDirectory = documents.appendingPathComponent("transcript-snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        let legacySnapshot = legacyDirectory.appendingPathComponent("legacy-session.json")
        try Data("cached".utf8).write(to: legacySnapshot)

        let first = WorkspaceStorageMigration.runIfNeeded(defaults: defaults,
                                                          documentsDirectory: documents)
        XCTAssertFalse(first.alreadyMigrated)
        XCTAssertTrue(first.currentSession)
        XCTAssertEqual(first.drafts, 2)
        XCTAssertEqual(first.titleHints, 1)
        XCTAssertEqual(first.collapsedWorkspaces, 1)
        XCTAssertEqual(first.snapshots, 1)

        XCTAssertEqual(defaults.string(forKey: WorkspaceStorageKeys.currentSession(for: .phone)),
                       "legacy-session")
        XCTAssertEqual(WorkspaceStorage.draft(for: .phone, sessionID: "legacy-session", defaults: defaults),
                       "old draft")
        XCTAssertEqual(WorkspaceStorage.draft(for: .phone, sessionID: nil, defaults: defaults),
                       "new draft")
        XCTAssertEqual(WorkspaceStorage.titleHints(for: .phone, defaults: defaults)["legacy-session"],
                       "旧标题")
        XCTAssertEqual(WorkspaceStorage.collapsedWorkspaceIDs(for: .phone, defaults: defaults),
                       ["ws-1"])
        let scopedSnapshot = documents
            .appendingPathComponent("transcript-snapshots", isDirectory: true)
            .appendingPathComponent(BackendID.phone.storageScope, isDirectory: true)
            .appendingPathComponent("legacy-session.json")
        XCTAssertEqual(try Data(contentsOf: scopedSnapshot), Data("cached".utf8))

        // Legacy data stays in place (rollback still reads the old build).
        XCTAssertEqual(defaults.string(forKey: WorkspaceStorageKeys.legacyCurrentSession),
                       "legacy-session")
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacySnapshot.path))

        let second = WorkspaceStorageMigration.runIfNeeded(defaults: defaults,
                                                           documentsDirectory: documents)
        XCTAssertTrue(second.alreadyMigrated)
        XCTAssertFalse(second.didChange)

        let forced = WorkspaceStorageMigration.runIfNeeded(defaults: defaults,
                                                           documentsDirectory: documents,
                                                           force: true)
        XCTAssertEqual(forced.drafts, 0)
        XCTAssertEqual(forced.titleHints, 0)
        XCTAssertEqual(forced.snapshots, 0)
    }

    func testManualCodeInputFormatsSixteenCharacters() {
        XCTAssertEqual(PCLinkManualCodeInput.format("ab-cd"), "ABCD")
        XCTAssertEqual(PCLinkManualCodeInput.format("ABCDEFGHJKLMNPQR"),
                       "ABCD-EFGH-JKLM-NPQR")
        XCTAssertEqual(PCLinkManualCodeInput.format("abcd efgh jklm npqr"),
                       "ABCD-EFGH-JKLM-NPQR")
        XCTAssertEqual(PCLinkManualCodeInput.format("ABCD-EFGH-JKLM-NPQR-EXTRA"),
                       "ABCD-EFGH-JKLM-NPQR")
    }

    // A signed reject is only actionable after explicit user confirmation.
    func testUnpairedPromptRequiresConfirmation() {
        XCTAssertFalse(PCLinkUnpairedPromptPolicy.shouldRemoveRecord(
            hasAuthenticatedPrompt: false, userConfirmed: true))
        XCTAssertFalse(PCLinkUnpairedPromptPolicy.shouldRemoveRecord(
            hasAuthenticatedPrompt: true, userConfirmed: false))
        XCTAssertTrue(PCLinkUnpairedPromptPolicy.shouldRemoveRecord(
            hasAuthenticatedPrompt: true, userConfirmed: true))
        XCTAssertEqual(PCLinkPCUnpairedPrompt.text, "电脑已解除与此手机的配对")
    }

    func testPCBackendCapabilitiesAndOfflineTransport() async throws {
        let record = makeRecord()
        let offline = FakePCLinkClient(state: .offline(.peerOffline),
                                       status: PCLinkClientStatus(state: .offline(.peerOffline),
                                                                  record: record))
        let backend = PCWorkspaceBackend(machineId: record.peerMachineId,
                                         displayName: record.peerName,
                                         client: offline)
        XCTAssertEqual(backend.id, .pc(machineId: record.peerMachineId))
        XCTAssertFalse(backend.capabilities.phoneOnlyEndpoints)
        XCTAssertFalse(backend.capabilities.supportsHostLifecycle)
        XCTAssertFalse(backend.capabilities.localFilePreview)
        XCTAssertFalse(backend.lifecycle.supportsHostPause)
        XCTAssertFalse(backend.lifecycle.supportsKeepAlive)

        do {
            _ = try await backend.transport()
            XCTFail("offline PC must not hand out a transport")
        } catch let error as WorkspaceBackendError {
            guard case .unavailable(let reason) = error else { return XCTFail("wrong error") }
            XCTAssertEqual(reason, "电脑离线")
        }
        try await backend.lifecycle.pause()   // no-op
        try await backend.lifecycle.resume()  // no-op

        let online = FakePCLinkClient(state: .online, status: PCLinkClientStatus(state: .online,
                                                                                 record: record))
        let onlineBackend = PCWorkspaceBackend(machineId: record.peerMachineId,
                                               displayName: record.peerName,
                                               client: online)
        _ = try await onlineBackend.transport()
        _ = try await onlineBackend.harness()
    }

    func testPairingFlowSuccessAndRefusals() async {
        let approval = makeApproval()
        let record = makeRecord()
        let success = FakePCLinkClient(startPairingResult: .success(approval),
                                       confirmResult: .success(record))
        let flow = PCPairingFlow(client: success)
        await flow.begin(qrURI: "pclink://pair?v=1")
        let began = await flow.state
        guard case .awaitingApproval(let shown) = began else {
            return XCTFail("expected awaitingApproval")
        }
        XCTAssertEqual(shown.id, approval.id)
        await flow.confirm()
        let finished = await flow.state
        guard case .paired(let pairedRecord) = finished else {
            return XCTFail("expected paired")
        }
        XCTAssertEqual(pairedRecord.peerMachineId, record.peerMachineId)
        let confirmCalls = await success.confirmCalls
        XCTAssertEqual(confirmCalls, 1)

        // Timeout / refused / destroyed slot all surface as a failed state.
        let timeout = FakePCLinkClient(startPairingResult: .failure(PCLinkError.pairingTimedOut))
        let timeoutFlow = PCPairingFlow(client: timeout)
        await timeoutFlow.beginManual(code: "ABCD-EFGH-JKLM-NPQR",
                                      relayOrigin: "ws://127.0.0.1:3240")
        let timedOut = await timeoutFlow.state
        guard case .failed(let message) = timedOut else {
            return XCTFail("expected failed")
        }
        XCTAssertFalse(message.isEmpty)

        let destroyed = FakePCLinkClient(startPairingResult: .success(approval))
        let destroyedFlow = PCPairingFlow(client: destroyed)
        await destroyedFlow.begin(qrURI: "pclink://pair?v=1")
        await destroyedFlow.sync(clientStatus: PCLinkClientStatus(
            state: .unpaired(.noRecord),
            record: nil,
            lastError: .pairingCancelled))
        let destroyedState = await destroyedFlow.state
        guard case .failed(let destroyedMessage) = destroyedState else {
            return XCTFail("destroyed slot must fail the page")
        }
        XCTAssertFalse(destroyedMessage.isEmpty)

        // An authenticated unpaired prompt is not a successful pairing.
        let reject = FakePCLinkClient(startPairingResult: .success(approval))
        let rejectFlow = PCPairingFlow(client: reject)
        await rejectFlow.begin(qrURI: "pclink://pair?v=1")
        await rejectFlow.sync(clientStatus: PCLinkClientStatus(
            state: .offline(.unpairedPrompt),
            record: record))
        let rejectState = await rejectFlow.state
        guard case .failed = rejectState else {
            return XCTFail("unpaired prompt must not mark the page paired")
        }
    }

    /// After the PC approves, the authenticated `pair.confirm` reaches the
    /// client's pairing stream while the explicit confirmation call is still
    /// pending; the page must move to paired without a second button press.
    func testPairingCompletesFromClientUpdateStreamAfterPCConfirm() async {
        let approval = makeApproval()
        let record = makeRecord()
        let client = FakePCLinkClient(startPairingResult: .success(approval),
                                      confirmResult: .success(record),
                                      gateConfirm: true)
        let flow = PCPairingFlow(client: client)
        await flow.begin(qrURI: "pclink://pair?v=1")
        guard case .awaitingApproval = flow.state else {
            return XCTFail("expected awaitingApproval")
        }
        let confirmTask = Task { await flow.confirm() }
        let confirming = await waitForPairingState(flow) {
            if case .confirming = $0 { return true }
            return false
        }
        XCTAssertTrue(confirming, "the explicit confirmation should be pending")

        await client.emitPairingUpdate(.completed(record))
        let pairedFromStream = await waitForPairingState(flow) {
            if case .paired = $0 { return true }
            return false
        }
        XCTAssertTrue(pairedFromStream, "the client pairing stream must drive .paired")
        let calls = await client.confirmCalls
        XCTAssertEqual(calls, 1, "no second button press is needed")

        await client.releaseConfirm()
        await confirmTask.value
        guard case .paired(let pairedRecord) = flow.state else {
            return XCTFail("expected paired after the pending call returns")
        }
        XCTAssertEqual(pairedRecord.peerMachineId, record.peerMachineId)
    }

    private func waitForPairingState(_ flow: PCPairingFlow,
                                     _ predicate: (PCPairingPageState) -> Bool,
                                     timeout: TimeInterval = 2) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate(flow.state) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    func testLongOfflineAndNoticeCopy() {
        XCTAssertEqual(PCLinkWorkspaceText.longOffline,
                       "电脑长时间离线。如果电脑已更换身份或解除配对，请手动解除配对。")
        XCTAssertEqual(PCLinkWorkspaceText.noticeBanner(name: "iPhone 15",
                                                        fingerprint: "abcd-efgh-ijkl"),
                       "电脑新配对了一台设备：iPhone 15 abcd-efgh-ijkl")
        XCTAssertTrue(PCLinkNotice.warning.contains("撤销全部配对"))
        XCTAssertEqual(PCLinkPairingPrompt.fullOwnerWarning,
                       "此手机将能完整操作这台电脑上的 DSH：对话、在电脑上执行 Shell 和读写文件、处理审批、修改设置和插件。")
    }
}
