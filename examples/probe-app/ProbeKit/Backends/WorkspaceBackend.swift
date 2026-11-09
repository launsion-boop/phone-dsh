// SPDX-License-Identifier: MIT
// Workspace backend seam: the phone host today, a paired PC workspace in D2.
//
// The protocol lives in ProbeKit (not the App) so the simulator suite and the
// future PCLink module can import it. `PhoneWorkspaceBackend` is also here but
// stays dependency-injected: the App supplies the closures that reach
// `ChatModel.shared.host` / `PhoneDSHHost.makeTransport()` / `.harness()`, so
// ProbeKit never imports the App target and no singleton is baked into it.

import Foundation
import PhoneDSHAgentCore

/// Which workspace a UI surface or persisted value belongs to.
public enum BackendID: Hashable, Codable, Sendable {
    case phone
    case pc(machineId: String)

    /// Stable scope for `(BackendID, sessionID)` keys. Persistence does not use
    /// this yet (P18 migration is D2); it exists so the mapping is defined once.
    public var storageScope: String {
        switch self {
        case .phone: return "phone"
        case .pc(let machineId): return "pc:\(machineId)"
        }
    }
}

public struct BackendCapabilities: Equatable, Sendable {
    /// `phone/*` endpoints exist (and are hidden in a PC workspace).
    public var phoneOnlyEndpoints: Bool
    /// The backend owns a host process whose pause/resume/keep-alive lifecycle
    /// the App can drive.
    public var supportsHostLifecycle: Bool
    /// Artifacts can be previewed through the phone's local page origin.
    public var localFilePreview: Bool

    public init(phoneOnlyEndpoints: Bool, supportsHostLifecycle: Bool, localFilePreview: Bool) {
        self.phoneOnlyEndpoints = phoneOnlyEndpoints
        self.supportsHostLifecycle = supportsHostLifecycle
        self.localFilePreview = localFilePreview
    }
}

public enum WorkspaceBackendError: LocalizedError, Equatable {
    case notStarted
    case unavailable(String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .notStarted: "本地引擎还没起来。"
        case .unavailable(let reason): reason
        case .unsupported(let feature): "当前工作区不支持 \(feature)。"
        }
    }
}

/// Host lifecycle for the current backend. The phone parks/resumes its host and
/// can hold a silent-audio keep-alive; a PC backend has only connection state
/// (D2 implements it).
@MainActor
public protocol WorkspaceBackendLifecycle: AnyObject {
    var supportsHostPause: Bool { get }
    var supportsKeepAlive: Bool { get }
    func pause() async throws
    func resume() async throws
    func startKeepAlive() async throws
    func stopKeepAlive() async
}

/// One source of DSH transports/harnesses. `ChatModel.transportForManagement()`
/// and `DSHManagementModel` resolve through the current backend; D2 adds a
/// second implementation without touching the 78 `ChatModel.shared` call sites.
@MainActor
public protocol WorkspaceBackend: AnyObject {
    var id: BackendID { get }
    var displayName: String { get }
    var capabilities: BackendCapabilities { get }
    var lifecycle: any WorkspaceBackendLifecycle { get }
    func transport() async throws -> any DSHRemoteTransport
    func harness() async throws -> any AgentHarness
}

/// The only backend this unit enables: the existing in-process `PhoneDSHHost`.
///
/// PHONE-ONLY: Bot runtime, `DeviceTaskManager`, device-session monitoring and
/// the settings pages' MCP/model/Agent-preset paths stay bound to this backend
/// (plan v2 §6.1/§6.2). They are not routed through a PC backend in v1.
@MainActor
public final class PhoneWorkspaceBackend: WorkspaceBackend {
    public let id: BackendID = .phone
    public let displayName: String
    public let capabilities: BackendCapabilities
    public let lifecycle: any WorkspaceBackendLifecycle

    private let transportProvider: () async throws -> any DSHRemoteTransport
    private let harnessProvider: () async throws -> any AgentHarness

    public init(displayName: String,
                capabilities: BackendCapabilities = BackendCapabilities(
                    phoneOnlyEndpoints: true,
                    supportsHostLifecycle: true,
                    localFilePreview: true),
                lifecycle: any WorkspaceBackendLifecycle,
                transport: @escaping () async throws -> any DSHRemoteTransport,
                harness: @escaping () async throws -> any AgentHarness) {
        self.displayName = displayName
        self.capabilities = capabilities
        self.lifecycle = lifecycle
        self.transportProvider = transport
        self.harnessProvider = harness
    }

    public func transport() async throws -> any DSHRemoteTransport {
        try await transportProvider()
    }

    public func harness() async throws -> any AgentHarness {
        try await harnessProvider()
    }
}

/// Phone lifecycle adapter over the existing host/keep-alive primitives. The
/// App's scene-phase path remains the owner until D2 routes it through here;
/// this unit only defines and wires the seam.
@MainActor
public final class PhoneWorkspaceBackendLifecycle: WorkspaceBackendLifecycle {
    public let supportsHostPause = true
    public let supportsKeepAlive = true

    private let pauseAction: () async throws -> Void
    private let resumeAction: () async throws -> Void
    private let keepAliveStart: () async throws -> Void
    private let keepAliveStop: () async -> Void

    public init(pause: @escaping () async throws -> Void,
                resume: @escaping () async throws -> Void,
                startKeepAlive: @escaping () async throws -> Void,
                stopKeepAlive: @escaping () async -> Void) {
        self.pauseAction = pause
        self.resumeAction = resume
        self.keepAliveStart = startKeepAlive
        self.keepAliveStop = stopKeepAlive
    }

    public func pause() async throws { try await pauseAction() }
    public func resume() async throws { try await resumeAction() }
    public func startKeepAlive() async throws { try await keepAliveStart() }
    public func stopKeepAlive() async { await keepAliveStop() }
}
