// SPDX-License-Identifier: MIT
// PCLink connection owner for the App (D2).
//
// One `PCLinkClient` per app launch. It starts only when a pairing record
// exists (the call is harmless otherwise and loads/creates the phone identity
// the pairing page displays). The workspace models read `connection` and
// `status`; the UI never talks to the relay or the PC directly.

import Foundation
import PhoneDSHPCLink
import ProbeKit
import UIKit

#if DEBUG
/// File-backed identity seed for unsigned simulator E2E runs only. The
/// production store stays `PCLinkKeychainIdentityStore`.
struct PCLinkFileIdentityStore: PCLinkIdentityStore {
    let url: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.url = base.appendingPathComponent("pclink-identity-debug.seed")
    }

    func loadSeed() throws -> Data? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return data.count == 32 ? data : nil
    }

    func saveSeed(_ seed: Data) throws {
        try seed.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func deleteSeed() throws {
        try? FileManager.default.removeItem(at: url)
    }
}
#endif

@MainActor
@Observable
final class PCLinkWorkspace {
    /// The production client. `PCLinkClient` is the only implementation that
    /// dials the relay; the injectable protocol exists for the pairing-page
    /// state machine and simulator tests.
    static func makeClient() -> PCLinkClient {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let configuration = PCLinkClientConfiguration(
            phoneName: UIDevice.current.name,
            appName: "phoneDSH",
            appVersion: version,
            // The phone app's DSH Worker pin. The PC's own version is checked
            // by the handshake; out-of-range values only produce a warning.
            phoneDshVersion: "0.2.2-rc.1")
        #if DEBUG
        // Unsigned simulator builds cannot reach the Keychain (errSec error 1
        // without applied entitlements). The E2E opt-in keeps the same
        // protocol/store semantics in a 0600 file; production still uses the
        // Keychain store.
        if ProcessInfo.processInfo.environment["PDSH_PCLINK_FILE_IDENTITY"] == "1" {
            return PCLinkClient(identityStore: PCLinkFileIdentityStore(),
                                configuration: configuration)
        }
        #endif
        return PCLinkClient(configuration: configuration)
    }

    let client: any PCLinkClientProtocol
    private(set) var status = PCLinkClientStatus()
    private(set) var connection: PCWorkspaceConnection = .unpaired
    private(set) var notice: PCLinkNotice?
    /// Set after 10 minutes of failed reconnects, or immediately when the user
    /// opens the connection screen while offline (contract §5.5/§10).
    private(set) var longOffline = false
    private(set) var started = false
    /// The user chose to keep the local record after a signed `unpaired`; the
    /// alert stays dismissed until a new prompt arrives.
    private(set) var suppressedUnpairedPrompt = false

    /// Called after every status refresh so `WorkspaceModels` can create or
    /// replace the PC `ChatModel`/`DSHManagementModel` when the record changes.
    var onStatusChanged: ((PCLinkClientStatus) -> Void)?

    @ObservationIgnored private var stateTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var offlineSince: Date?
    @ObservationIgnored private var longOfflineTask: Task<Void, Never>?

    init(client: any PCLinkClientProtocol) {
        self.client = client
    }

    convenience init() {
        self.init(client: Self.makeClient())
    }

    var record: PCLinkPairingRecord? { status.record }
    var peerName: String { status.record?.peerName ?? "" }
    var pcMachineId: String? { status.record?.peerMachineId }
    var ownFingerprint: String { status.fingerprint ?? "" }
    var versionWarning: PCLinkVersionWarning? { status.versionWarning }
    var unpairedPrompt: PCLinkPCUnpairedPrompt? {
        suppressedUnpairedPrompt ? nil : status.pcUnpairedPrompt
    }

    var isOnline: Bool { status.record != nil && connection.isOnline }
    var isUnpaired: Bool { status.record == nil }

    /// DSH version of the paired PC from the verified `peer.hello` (CCR-2).
    /// `versionWarning` stays the UI banner for out-of-range versions.
    var pcDSHVersion: String? { status.peerDshVersion ?? status.versionWarning?.dshVersion }
    var pcAppName: String? { status.peerAppName }
    var pcAppVersion: String? { status.peerAppVersion }

    func startAtLaunch() async {
        guard !started else { return }
        started = true
        observeState()
        observeNotices()
        do {
            try await client.start()
        } catch {
            // A missing identity while a record exists is reported by the
            // client's own state; keep the UI on the PC segment.
        }
        await refreshStatus()
        #if DEBUG
        writeDebugStatusFile()
        #endif
    }

    #if DEBUG
    /// Unattended simulator E2E reads the phone's own (non-secret) fingerprint
    /// from the app container to type it at the PC's compare-the-phone prompt.
    /// Only the 12-character public fingerprint and state name are written.
    private func writeDebugStatusFile() {
        guard ProcessInfo.processInfo.environment["PDSH_PCLINK_WRITE_STATUS"] == "1",
              let documents = FileManager.default.urls(for: .documentDirectory,
                                                       in: .userDomainMask).first else { return }
        let lines = [
            "fingerprint=\(status.fingerprint ?? "")",
            "machineId=\(status.machineId ?? "")",
            "state=\(String(describing: status.state))",
            "paired=\(status.record != nil)",
        ].joined(separator: "\n") + "\n"
        try? lines.write(to: documents.appendingPathComponent("pclink-d2-status.txt"),
                         atomically: true, encoding: .utf8)
    }
    #endif

    func retry() async {
        do {
            try await client.start()
        } catch {
            await refreshStatus()
            return
        }
        await refreshStatus()
    }

    func markConnectionScreenOpened() {
        if status.record != nil, !connection.isOnline {
            longOffline = true
        }
    }

    func dismissNotice() {
        notice = nil
    }

    /// Keep the local record for now. The next signed reject from the PC asks
    /// again; this only dismisses the current prompt (§5.5).
    func keepLocalRecordDespiteUnpaired() {
        suppressedUnpairedPrompt = true
    }

    func clearError() {
        Task { await client.clearLastError() }
    }

    func unpair() async throws {
        let backend = status.record.map { BackendID.pc(machineId: $0.peerMachineId) }
        try await client.unpair()
        if let backend { WorkspaceStorage.removeLocalData(for: backend) }
        await refreshStatus()
    }

    func acknowledgePCUnpair() async throws {
        let backend = status.record.map { BackendID.pc(machineId: $0.peerMachineId) }
        try await client.acknowledgePCUnpair()
        if let backend { WorkspaceStorage.removeLocalData(for: backend) }
        await refreshStatus()
    }

    func removeLocalRecord() async throws {
        let backend = status.record.map { BackendID.pc(machineId: $0.peerMachineId) }
        try await client.removeLocalRecord()
        if let backend { WorkspaceStorage.removeLocalData(for: backend) }
        await refreshStatus()
    }

    /// Foreground return: replace a possibly suspended relay socket and let
    /// the PC backend's pump resynchronize (contract §10). `WorkspaceModels`
    /// also restarts the PC ChatModel pump.
    func scenePhaseChanged(_ isActive: Bool) async {
        guard isActive, started, status.record != nil else { return }
        await client.foregroundResumed()
        await refreshStatus()
    }

    // MARK: Observation

    private func observeState() {
        stateTask?.cancel()
        stateTask = Task { [weak self] in
            guard let self else { return }
            let stream = await client.stateStream()
            for await state in stream {
                guard !Task.isCancelled else { return }
                self.apply(state)
                await self.refreshStatus()
            }
        }
    }

    private func observeNotices() {
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            guard let self else { return }
            let stream = await client.noticeStream()
            for await notice in stream {
                guard !Task.isCancelled else { return }
                self.notice = notice
            }
        }
    }

    private func apply(_ state: PCLinkClientState) {
        connection = PCWorkspaceConnection(state)
        switch connection {
        case .online, .versionWarning:
            offlineSince = nil
            longOffline = false
            longOfflineTask?.cancel()
            longOfflineTask = nil
        case .offline:
            guard status.record != nil else { break }
            if offlineSince == nil { offlineSince = Date() }
            armLongOfflineTimerIfNeeded()
        case .unpaired, .connecting:
            break
        }
    }

    private func armLongOfflineTimerIfNeeded() {
        guard longOfflineTask == nil, !longOffline else { return }
        longOfflineTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(600))
            guard !Task.isCancelled, let self else { return }
            if !self.connection.isOnline, self.status.record != nil {
                self.longOffline = true
            }
        }
    }

    private func refreshStatus() async {
        status = await client.status()
        connection = PCWorkspaceConnection(status.state)
        if status.pcUnpairedPrompt == nil { suppressedUnpairedPrompt = false }
        if status.record == nil {
            longOffline = false
            offlineSince = nil
            longOfflineTask?.cancel()
            longOfflineTask = nil
        } else if !connection.isOnline {
            if offlineSince == nil { offlineSince = Date() }
            armLongOfflineTimerIfNeeded()
        }
        onStatusChanged?(status)
    }
}
