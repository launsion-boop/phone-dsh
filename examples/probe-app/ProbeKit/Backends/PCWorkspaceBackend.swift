// SPDX-License-Identifier: MIT
// PC workspace backend (PCLink D2).
//
// A paired PC is a second `WorkspaceBackend`: the DSH Remote transport is the
// `RelayDSHTransport` over the PCLink end-to-end session, and the harness is
// the existing `DSHRemoteHarness` pointed at that transport. The PC has no
// phone host process, so pause/resume/keep-alive are no-ops and capability
// flags that describe phone-local features are false.
//
// `PCLinkClientProtocol` exists only as an injection seam for the pairing-page
// state machine and the simulator tests; production always uses `PCLinkClient`.

import Foundation
import Observation
import PhoneDSHAgentCore
import PhoneDSHPCLink

/// The subset of `PCLinkClient` the App and the tests need. Actor methods are
/// declared `async` here so a fake can be a plain class in the test target.
public protocol PCLinkClientProtocol: Sendable {
    /// A transport over the one E2E session. It may be created before the
    /// connection is online; calls fail with the mapped offline error until it
    /// is.
    nonisolated func makeRelayTransport() -> any DSHRemoteTransport

    func currentState() async -> PCLinkClientState
    func status() async -> PCLinkClientStatus
    func stateStream() async -> AsyncStream<PCLinkClientState>
    func noticeStream() async -> AsyncStream<PCLinkNotice>
    func pairingUpdates() async -> AsyncStream<PCLinkPairingUpdate>

    func start() async throws
    func stop() async
    func connectAndWait() async throws
    /// App foreground return: reconnect a suspended relay socket and let the
    /// PC pump resynchronize. Implementations may no-op when terminal.
    func foregroundResumed() async

    func startPairing(qrURI: String) async throws -> PCPairingApproval
    func startManualPairing(code: String, relayOrigin: String,
                            pcName: String?) async throws -> PCPairingApproval
    func confirmPairingApproval(_ id: UUID) async throws -> PCLinkPairingRecord
    func cancelPairing() async

    func unpair() async throws
    func acknowledgePCUnpair() async throws
    func removeLocalRecord() async throws
    func clearLastError() async
}

extension PCLinkClientProtocol {
    /// Safe default for test doubles; the real client overrides this with a
    /// forced reconnect in `PCLinkClient.foregroundResumed()`.
    public func foregroundResumed() async {
        try? await start()
    }
}

extension PCLinkClient: PCLinkClientProtocol {
    public nonisolated func makeRelayTransport() -> any DSHRemoteTransport {
        makeTransport()
    }

    public func startPairing(qrURI: String) async throws -> PCPairingApproval {
        let prompt = try await beginPairing(qrURI: qrURI)
        return PCPairingApproval(prompt)
    }

    public func startManualPairing(code: String, relayOrigin: String,
                                   pcName: String?) async throws -> PCPairingApproval {
        let prompt = try await beginManualPairing(code: code, relayOrigin: relayOrigin, pcName: pcName)
        return PCPairingApproval(prompt)
    }

    public func confirmPairingApproval(_ id: UUID) async throws -> PCLinkPairingRecord {
        try await confirmPairing(id).record
    }
}

/// A pairing prompt projected into a value ProbeKit can construct in tests.
/// Production fields are exactly the client's prompt; `PCLinkPairingPrompt`
/// itself has no public memberwise init, and the App must not fabricate one.
public struct PCPairingApproval: Equatable, Sendable {
    public var id: UUID
    public var mode: PCLinkPairingMode
    public var relayOrigin: String
    public var pcName: String
    public var pcMachineId: String
    public var ownFingerprint: String
    public var warningText: String
    public var expiresAt: Date

    public init(id: UUID, mode: PCLinkPairingMode, relayOrigin: String,
                pcName: String, pcMachineId: String, ownFingerprint: String,
                warningText: String, expiresAt: Date) {
        self.id = id
        self.mode = mode
        self.relayOrigin = relayOrigin
        self.pcName = pcName
        self.pcMachineId = pcMachineId
        self.ownFingerprint = ownFingerprint
        self.warningText = warningText
        self.expiresAt = expiresAt
    }

    public init(_ prompt: PCLinkPairingPrompt) {
        self.init(id: prompt.id, mode: prompt.mode, relayOrigin: prompt.relayOrigin,
                  pcName: prompt.pcName, pcMachineId: prompt.pcMachineId,
                  ownFingerprint: prompt.ownFingerprint,
                  warningText: prompt.warningText, expiresAt: prompt.expiresAt)
    }
}

/// State of the paired PC, projected from `PCLinkClient.stateStream()`.
public enum PCWorkspaceConnection: Equatable, Sendable {
    case unpaired
    case connecting
    case online
    case offline(PCLinkOfflineReason)
    case versionWarning(PCLinkVersionWarning)

    public var isOnline: Bool {
        switch self {
        case .online, .versionWarning: return true
        default: return false
        }
    }

    public var isUnpaired: Bool {
        if case .unpaired = self { return true }
        return false
    }

    public init(_ state: PCLinkClientState) {
        switch state {
        case .unpaired: self = .unpaired
        case .pairing: self = .connecting
        case .connecting: self = .connecting
        case .online: self = .online
        case .offline(let reason): self = .offline(reason)
        case .versionWarning(let warning): self = .versionWarning(warning)
        }
    }
}

@MainActor
public final class PCWorkspaceBackend: WorkspaceBackend {
    public let id: BackendID
    public let displayName: String
    public let capabilities = BackendCapabilities(
        phoneOnlyEndpoints: false,
        supportsHostLifecycle: false,
        localFilePreview: false)
    public let lifecycle: any WorkspaceBackendLifecycle

    private let client: any PCLinkClientProtocol
    private var harnessCache: (any AgentHarness)?

    public init(machineId: String,
                displayName: String,
                client: any PCLinkClientProtocol,
                lifecycle: any WorkspaceBackendLifecycle) {
        self.id = .pc(machineId: machineId)
        self.displayName = displayName
        self.client = client
        self.lifecycle = lifecycle
    }

    /// Convenience for the App; the isolated lifecycle is created on the main
    /// actor instead of as a nonisolated default argument.
    public convenience init(machineId: String,
                            displayName: String,
                            client: any PCLinkClientProtocol) {
        self.init(machineId: machineId, displayName: displayName, client: client,
                  lifecycle: PCWorkspaceBackendLifecycle())
    }

    public func transport() async throws -> any DSHRemoteTransport {
        let state = await client.currentState()
        guard PCWorkspaceConnection(state).isOnline else {
            throw WorkspaceBackendError.unavailable("电脑离线")
        }
        return client.makeRelayTransport()
    }

    public func harness() async throws -> any AgentHarness {
        if let harnessCache { return harnessCache }
        let transport = try await transport()
        let harness = DSHRemoteHarness(transport: transport)
        harnessCache = harness
        return harness
    }
}

/// The PC has no host process whose pause or keep-alive the App can drive.
/// Plan v2 §6.2 / D1b: pause is a no-op, keep-alive unsupported.
@MainActor
public final class PCWorkspaceBackendLifecycle: WorkspaceBackendLifecycle {
    public let supportsHostPause = false
    public let supportsKeepAlive = false

    public init() {}
    public func pause() async throws {}
    public func resume() async throws {}
    public func startKeepAlive() async throws {}
    public func stopKeepAlive() async {}
}

// MARK: - Pairing page state machine (injectable, testable)

/// The pairing page's serialized states. `PCPairingFlow` runs the real
/// `PCLinkClient` pairing calls; the simulator suite drives the same flow with
/// a fake client to cover success, timeout, rejection and a destroyed slot.
public enum PCPairingPageState: Equatable, Sendable {
    case idle
    case joining
    case awaitingApproval(PCPairingApproval)
    case confirming
    case paired(PCLinkPairingRecord)
    case failed(String)

    public var isBusy: Bool {
        switch self {
        case .joining, .confirming: return true
        default: return false
        }
    }

    public var prompt: PCPairingApproval? {
        if case .awaitingApproval(let prompt) = self { return prompt }
        return nil
    }
}

@MainActor
@Observable
public final class PCPairingFlow {
    public private(set) var state: PCPairingPageState = .idle
    public let client: any PCLinkClientProtocol
    @ObservationIgnored private var updateTask: Task<Void, Never>?

    public init(client: any PCLinkClientProtocol) {
        self.client = client
    }

    public func begin(qrURI: String) async {
        guard case .idle = state else { return }
        state = .joining
        do {
            let prompt = try await client.startPairing(qrURI: trimmed(qrURI))
            state = .awaitingApproval(prompt)
            observePairingUpdates()
        } catch {
            state = .failed(Self.message(for: error))
        }
    }

    public func beginManual(code: String, relayOrigin: String) async {
        guard case .idle = state else { return }
        state = .joining
        do {
            let prompt = try await client.startManualPairing(
                code: code, relayOrigin: relayOrigin, pcName: nil)
            state = .awaitingApproval(prompt)
            observePairingUpdates()
        } catch {
            state = .failed(Self.message(for: error))
        }
    }

    /// The user confirmed the full-owner warning. Writes the durable record
    /// only after the PC's `pair.confirm` verifies (§4.4/§4.6).
    public func confirm() async {
        guard case .awaitingApproval(let prompt) = state else { return }
        state = .confirming
        do {
            let record = try await client.confirmPairingApproval(prompt.id)
            finish(record)
        } catch {
            state = .failed(Self.message(for: error))
            stopObserving()
        }
    }

    public func cancel() async {
        stopObserving()
        await client.cancelPairing()
        state = .idle
    }

    public func reset() {
        stopObserving()
        state = .idle
    }

    /// Completion is driven by the client's pairing stream, not by a second
    /// button press: after the PC approval arrives as `pair.confirm`, the
    /// client emits `.completed` and the page moves to `.paired` even while a
    /// pending `confirm()` call is still returning. The approval button stays
    /// as the explicit consent / timeout retry entry.
    private func observePairingUpdates() {
        stopObserving()
        updateTask = Task { [weak self] in
            guard let self else { return }
            let updates = await client.pairingUpdates()
            for await update in updates {
                guard !Task.isCancelled else { return }
                switch update {
                case .completed(let record):
                    finish(record)
                    return
                case .failed(let error):
                    switch state {
                    case .awaitingApproval, .confirming:
                        state = .failed(Self.message(for: error))
                        return
                    default:
                        return
                    }
                case .awaitingApproval:
                    continue
                }
            }
        }
    }

    private func finish(_ record: PCLinkPairingRecord) {
        stopObserving()
        if case .paired = state { return }
        state = .paired(record)
    }

    private func stopObserving() {
        updateTask?.cancel()
        updateTask = nil
    }

    /// The client owns the timeout/rejection clock. When it has left pairing
    /// and the page still waits for approval, show the error instead of a
    /// spinner forever. Called from the page's state-stream observation.
    public func sync(clientStatus status: PCLinkClientStatus) {
        guard case .awaitingApproval(let prompt) = state else { return }
        if let current = status.pairingPrompt, current.id == prompt.id { return }
        if status.pcUnpairedPrompt != nil {
            stopObserving()
            state = .failed(PCLinkPCUnpairedPrompt.text)
            return
        }
        switch status.state {
        case .offline(.unpairedPrompt):
            stopObserving()
            state = .failed(PCLinkPCUnpairedPrompt.text)
            return
        case .online, .versionWarning:
            // Confirmation completed elsewhere and the record is in place.
            if let record = status.record { finish(record) }
        case .unpaired:
            // A destroyed/timed-out/refused slot lands here. The authenticated
            // unpaired prompt is not a pairing result: the record is the old
            // one and must only be removed after the user confirms the alert.
            stopObserving()
            state = .failed(status.lastError.map(Self.message(for:))
                ?? "配对已取消或超时，请重新开始。")
        case .offline, .pairing, .connecting:
            return
        }
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func message(for error: Error) -> String {
        if let error = error as? PCLinkError { return error.description }
        return error.localizedDescription
    }
}

/// Input formatting for the 16-character manual code: display as
/// `XXXX-XXXX-XXXX-XXXX`, tolerate lowercase and extra separators. The
/// authoritative normalization/decoding remains `PCLinkCrockford.normalize`.
public enum PCLinkManualCodeInput {
    public static func format(_ raw: String) -> String {
        var characters: [Character] = []
        for character in raw.uppercased() where character.isLetter || character.isNumber {
            characters.append(character)
            if characters.count == 16 { break }
        }
        var grouped: [String] = []
        var index = 0
        while index < characters.count {
            let end = min(index + 4, characters.count)
            grouped.append(String(characters[index..<end]))
            index = end
        }
        return grouped.joined(separator: "-")
    }
}

/// The record is removed only after the user confirms the authenticated
/// `unpaired` prompt. An unsigned/unauthenticated reject produces no prompt.
public enum PCLinkUnpairedPromptPolicy {
    public static func shouldRemoveRecord(prompt: PCLinkPCUnpairedPrompt?,
                                          userConfirmed: Bool) -> Bool {
        shouldRemoveRecord(hasAuthenticatedPrompt: prompt != nil, userConfirmed: userConfirmed)
    }

    /// Testable core: an unauthenticated reject never yields a prompt, so even
    /// a confirmed UI action must not delete the record in that case.
    public static func shouldRemoveRecord(hasAuthenticatedPrompt: Bool,
                                          userConfirmed: Bool) -> Bool {
        hasAuthenticatedPrompt && userConfirmed
    }
}

// MARK: - Presentation strings (contract §4.6 / §10)

public enum PCLinkWorkspaceText {
    public static let longOffline = PCLinkNotices.longOfflineHint

    public static func noticeBanner(_ notice: PCLinkNotice) -> String {
        noticeBanner(name: notice.name, fingerprint: notice.fingerprint)
    }

    /// Same copy without needing to construct the frozen `PCLinkNotice`
    /// (it has no public memberwise init).
    public static func noticeBanner(name: String, fingerprint: String) -> String {
        "电脑新配对了一台设备：\(name) \(fingerprint)"
    }

    public static func offlineReason(_ reason: PCLinkOfflineReason) -> String {
        switch reason {
        case .notStarted: return "还没有连接电脑。"
        case .network: return "网络断开，正在重连。"
        case .peerOffline: return "电脑离线。"
        case .replaced: return "这台电脑的连接被同一身份的新连接替换了。"
        case .authenticationFailed: return "连接没有被电脑接受，请重新配对。"
        case .versionUnsupported: return "这台电脑的 PCLink 版本或能力不受支持，请升级后再连接。"
        case .unpairedPrompt: return PCLinkPCUnpairedPrompt.text
        case .protocolError(let message): return "连接协议出错：\(message)"
        case .storage(let message): return "读取配对记录失败：\(message)"
        }
    }

    /// Render the §2.1 RFC 3339 `pairedAt` as a localized date-time, never the
    /// ISO string. The timestamp is UTC metadata; display uses the user's
    /// locale/time zone (e.g. `2026年11月10日 03:13` for zh_CN).
    public static func pairedAtDisplay(_ raw: String,
                                       locale: Locale = .current,
                                       timeZone: TimeZone = .current) -> String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]
        guard let date = parser.date(from: raw) else { return raw }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - Drawer policy

/// What the drawer/list region shows for the selected segment. It is a pure
/// function so the offline rule is testable without UI: a selected `.pc` never
/// turns into `.phone` because the connection dropped (plan v2 §6.1).
public enum PCDrawerPhase: Equatable, Sendable {
    case phone
    case pair
    case offline
    case ready
}

public enum PCLinkDrawerPolicy {
    public static func phase(selected: DrawerBackendSetting,
                             hasRecord: Bool,
                             connection: PCWorkspaceConnection) -> PCDrawerPhase {
        guard selected == .pc else { return .phone }
        guard hasRecord else { return .pair }
        return connection.isOnline ? .ready : .offline
    }
}
