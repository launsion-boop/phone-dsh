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
///
/// v1.6 has no "waiting for the user to approve on the PC" state: scanning or
/// submitting the code is the approval. `.connecting` covers both auto-auth
/// submission and a pre-v1.6 PC that still asks its operator to confirm.
public enum PCPairingPageState: Equatable, Sendable {
    case idle
    case joining
    case connecting(PCPairingApproval)
    case paired(PCLinkPairingRecord)
    case failed(String)

    public var isBusy: Bool {
        switch self {
        case .joining, .connecting: return true
        default: return false
        }
    }

    public var prompt: PCPairingApproval? {
        if case .connecting(let prompt) = self { return prompt }
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
            state = .connecting(prompt)
            observePairingUpdates()
            // The QR scan is the consent and the approval. Submit `pair.auth`
            // immediately; the PC auto-approves it and sends `pair.confirm`.
            await confirm()
        } catch {
            state = .failed(Self.message(for: error))
            stopObserving()
        }
    }

    public func beginManual(code: String, relayOrigin: String) async {
        guard case .idle = state else { return }
        state = .joining
        do {
            let prompt = try await client.startManualPairing(
                code: code, relayOrigin: relayOrigin, pcName: nil)
            state = .connecting(prompt)
            observePairingUpdates()
            await confirm()
        } catch {
            state = .failed(Self.message(for: error))
            stopObserving()
        }
    }

    /// Submit `pair.auth` and wait for the authenticated `pair.confirm`. The
    /// page calls this automatically after `begin`; it stays public as the
    /// retry entry for a failed submit that did not destroy the slot.
    public func confirm() async {
        guard case .connecting(let prompt) = state else { return }
        do {
            let record = try await client.confirmPairingApproval(prompt.id)
            finish(record)
        } catch {
            if case .paired = state { return }
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

    /// Completion is driven by the client's pairing stream as well as by the
    /// pending `confirm()` call: after the authenticated `pair.confirm`, the
    /// client emits `.completed` and the page moves to `.paired` even while
    /// the submit call is still returning.
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
                    if case .connecting = state {
                        state = .failed(Self.message(for: error))
                        return
                    }
                    return
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
    /// and the page is still connecting, show the error instead of a spinner
    /// forever. Called from the page's state-stream observation.
    public func sync(clientStatus status: PCLinkClientStatus) {
        guard case .connecting(let prompt) = state else { return }
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
            if case .pairing(.failed(let error)) = status.state {
                stopObserving()
                state = .failed(Self.message(for: error))
            }
            return
        }
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func message(for error: Error) -> String {
        if let error = error as? PCLinkError {
            switch error {
            case .peerOffline, .unavailable:
                // A phone lock/background during the hand-off drops the relay
                // socket; tell the user to keep the page open and retry.
                if error == .peerOffline || error.message.localizedCaseInsensitiveContains("peer_offline")
                    || error.message.localizedCaseInsensitiveContains("connection") {
                    return PCLinkWorkspaceText.pairingInterrupted
                }
                return "连接没有完成，请重试。"
            case .badFrame:
                return "配对链接或配对码无效，请重新扫码或粘贴。"
            case .authFailed:
                return "连接没有被电脑接受，请重新配对。"
            case .pairingRejected:
                return "电脑拒绝了这次配对。"
            case .pairingTimedOut:
                return "配对超时，请重新扫码。"
            case .rendezvousExpired:
                return "二维码已过期，请在电脑上重新显示后再扫。"
            case .rendezvousExhausted:
                return "二维码已被使用，请重新显示后再扫。"
            case .alreadyPaired:
                return "这台手机已经配对了一台电脑，请先在「已连接的电脑」解除。"
            default:
                return error.description
            }
        }
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

    /// Inline progress on the pairing page (the connector replaces the name).
    public static func pairingConnecting(_ pcName: String) -> String {
        "正在连接 \(pcName)…"
    }

    /// Covers a pre-v1.6 PC that still asks its own operator to confirm; it
    /// deliberately never mentions a fingerprint.
    public static let pairingOldPCConfirm = "如果这台电脑仍要求确认，请在电脑上完成确认。"

    /// Phone lock/background or a dropped relay connection.
    public static let pairingInterrupted = "连接中断，请保持此页面打开后重试。"

    /// Pairing mode shown on the completed-computer page.
    public static func pairingMode(_ mode: PCLinkPairingMode?) -> String {
        switch mode {
        case .qr: return "扫码"
        case .manual: return "手动码"
        case nil: return "旧版配对（未记录方式）"
        }
    }

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

// MARK: - Drawer list state (pclink-pacing)

/// What the list region shows once the PC segment is `.ready`: a read in
/// flight, a failed read (never the "no sessions" empty state), an empty
/// list, or rows. The error wins over an empty list so a failed
/// `session/list` is not presented as "还没有 PC 会话".
public enum PCDrawerListState: Equatable, Sendable {
    case loading
    case error
    case empty
    case rows
}

public extension PCLinkDrawerPolicy {
    static func listState(isLoading: Bool, error: String?, sessionCount: Int) -> PCDrawerListState {
        if isLoading && sessionCount == 0 { return .loading }
        if error != nil && sessionCount == 0 { return .error }
        if sessionCount == 0 { return .empty }
        return .rows
    }
}

// MARK: - PC workspace grouping (pclink-pacing)

/// Pure grouping rules for the PC segment. A session's workspace is the
/// explicit `workspace/follow` membership first, then the longest matching
/// workspace path against the session's cwd. The group title is the DSH
/// workspace title (never the synthetic "PC 工作区 · <computer>"), so the
/// drawer shows the computer's real working folders.
public enum PCLinkWorkspaceGrouping {
    public static func title(_ raw: String, fallback: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    /// Longest matching workspace path for a cwd; `nil` when no workspace owns
    /// the directory. Paths are canonical host paths and compare by path
    /// component boundary, so `/work/a` does not match `/work/ab`.
    public static func workspaceID(for session: ManagedSession,
                                   in workspaces: [ManagedWorkspace]) -> String? {
        if let explicit = workspaces.first(where: { $0.sessionIDs.contains(session.id) }) {
            return explicit.id
        }
        guard let cwd = session.cwd, !cwd.isEmpty else { return nil }
        let matches = workspaces.filter { workspace in
            let path = workspace.path
            return path == cwd || cwd.hasPrefix(path.hasSuffix("/") ? path : path + "/")
        }
        return matches.max { $0.path.count < $1.path.count }?.id
    }
}

/// The workspace chip/selection rule: the explicit picker choice if it still
/// exists, else the P18 last-used value for this PC, else the most recently
/// active workspace. All values are validated against the current
/// `workspace/follow` baseline before use.
public enum PCLinkWorkspaceSelection {
    public static func resolve(pending: String?, stored: String?, recent: String?,
                               workspaces: [ManagedWorkspace]) -> String? {
        let IDs = Set(workspaces.map(\.id))
        if let pending, IDs.contains(pending) { return pending }
        if let stored, IDs.contains(stored) { return stored }
        if let recent, IDs.contains(recent) { return recent }
        return nil
    }
}

// The install/pairing command strings live in PCLinkRelayConfiguration.swift
// with the relay origin (one configuration point).
