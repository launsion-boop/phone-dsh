// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHShell: the read-only `ExecProvider`.
//
// PLAN §2.1/§2.4 (D12) and spec/exec-bridge-v1. The Rust pdsh-shell library is
// the host-side executor for the read-only accelerators `rg`, `jaq`,
// `ts-parse`, `ts-query`, `phone` and `ctx`. It has no write operation, so a
// command cannot modify the workspace by construction; the provider publishes
// that guarantee in its hello capabilities and never mounts a writable root.
//
// With `PDSH_WITH_XZSHELL` the provider links shell/dist/PDSHShell.xcframework.
// Without the switch it compiles against the pure-Swift stub of the same C
// surface and fails every run with ``PDSHShellError/notLinked`` instead of
// silently claiming an accelerator that is not present.

import Foundation
import PhoneDSHAgentCore

/// `ExecProvider` for the Rust pdsh-shell read-only accelerators.
///
/// The provider reads the materialized copies owned by `WorkspaceLog`
/// (`materialized/workspace` and `materialized/home` below the workspace root)
/// and mounts them at the guest paths `/dsh/workspace` and `/dsh/home`; it
/// never opens a host path the WAL applier does not own. Commands, paths and
/// environment are the exec-bridge v1 shapes (guest paths), so the Worker can
/// forward an `EXEC_REQ` cwd without rewriting it.
public struct PDSHShellProvider: ExecProvider, Equatable, Sendable {
    /// Host directory of the materialized `/dsh/workspace` mount.
    public let materializedWorkspace: URL?
    /// Host directory of the materialized `/dsh/home` mount.
    public let materializedHome: URL?
    /// Deadline/output/file limits passed to the Rust library.
    public let limits: PDSHShellLimits
    /// Injected host tool bridge for `phone` / `ctx` (normally the App's MCP
    /// server). `nil` makes those commands fail with exit 69.
    public let toolBridge: (any PhoneToolBridge)?

    private let mounts: [PDSHShellMount]
    private let linkedCaps: PDSHShellCaps?
    private let advertisedAccelerators: [String]
    private let engine: PDSHShellEngine

    /// Creates the provider over the materialized workspace that
    /// `WorkspaceLog` owns (PLAN §2.3). The App facade normally passes
    /// `WorkspaceLog.paths.materializedWorkspaceDirectory` and
    /// `.materializedHomeDirectory`; the ``init(workspaceRoot:)`` convenience
    /// derives both from `Library/xl/<workspace_id>/`.
    ///
    /// With no workspace the provider is "not configured": it advertises no
    /// names it cannot run and ``run(_:)`` fails with
    /// ``PDSHShellError/notConfigured`` once the library is linked.
    public init(materializedWorkspace: URL? = nil,
                materializedHome: URL? = nil,
                limits: PDSHShellLimits = .default,
                toolBridge: (any PhoneToolBridge)? = nil) {
        self.materializedWorkspace = materializedWorkspace
        self.materializedHome = materializedHome
        self.limits = limits
        self.toolBridge = toolBridge
        let mounts = Self.makeMounts(workspace: materializedWorkspace, home: materializedHome)
        self.mounts = mounts
        let caps = PDSHShellC.caps(hasToolBridge: toolBridge != nil)
        let names = Self.executableAcceleratorNames(caps: caps, hasMounts: !mounts.isEmpty)
        self.linkedCaps = caps
        self.advertisedAccelerators = names
        self.engine = PDSHShellEngine(limits: limits,
                                    mounts: mounts,
                                    acceleratorNames: Set(names),
                                    toolBridge: toolBridge)
    }

    /// Creates the provider from the `Library/xl/<workspace_id>/` log root
    /// (PLAN §2.3), deriving the materialized copies of both mounts.
    public init(workspaceRoot: URL,
                limits: PDSHShellLimits = .default,
                toolBridge: (any PhoneToolBridge)? = nil) {
        self.init(materializedWorkspace: workspaceRoot.appendingPathComponent(
                      "materialized/workspace", isDirectory: true),
                  materializedHome: workspaceRoot.appendingPathComponent(
                      "materialized/home", isDirectory: true),
                  limits: limits,
                  toolBridge: toolBridge)
    }

    // MARK: - Accelerators and hello

    /// Accelerator names this provider can actually execute; empty in the stub.
    ///
    /// The list is the linked `pdsh_caps_json_with_bridge` capability set
    /// reported verbatim for diagnostics. The host HELLO should publish
    /// ``channelAcceleratorNames`` instead, because `phone` and `ctx` need an
    /// injected ``PhoneToolBridge``; a provider without a materialized
    /// mount advertises nothing because its engine rejects every run.
    public var acceleratorNames: [String] {
        advertisedAccelerators
    }

    /// Known accelerator cases the linked library can run without a host
    /// bridge. `phone` and `ctx` require a ``PhoneToolBridge`` and therefore do
    /// not appear here.
    public static let availableAccelerators: [PDSHShellAccelerator] = {
        let names = Set(PDSHShellC.caps(hasToolBridge: false)?.accelerators ?? [])
        return PDSHShellAccelerator.allCases.filter { names.contains($0.rawValue) }
    }()

    /// The mounts the provider published in its hello.
    public var helloMounts: [PDSHShellMount] {
        mounts
    }

    /// Hello/discovery half of the exec-bridge v1 `hello` for this provider
    /// (spec/exec-bridge-v1 §3): the accelerators of `pdsh_caps_json`, the
    /// confine modes the read-only accelerators satisfy, and the materialized
    /// workspace path as the single mount.
    public var helloCapabilities: PDSHShellHelloCapabilities {
        let caps = linkedCaps
        let hasExecutableAccelerators = !advertisedAccelerators.isEmpty
        return PDSHShellHelloCapabilities(
            version: caps?.version ?? PDSHShellC.version,
            accelerators: advertisedAccelerators,
            // An accelerator has no write path in the Rust VFS, so both
            // exec-bridge modes are satisfied: `read-only` makes no
            // host-visible writes; `workspace-write` can only write under the
            // workspace, and it writes nothing at all.
            confine: PDSHShellC.linked && hasExecutableAccelerators
                ? ["read-only", "workspace-write"] : [],
            mounts: mounts,
            readOnly: true,
            limits: caps?.limits)
    }

    /// Accelerator names this host can actually execute with the current
    /// bridge configuration.
    ///
    /// `pdsh_caps_json` also registers `phone` and `ctx`, but those commands
    /// call back into an injected ``PhoneToolBridge``. They are filtered out
    /// without a bridge, and `ctx` additionally requires explicit support from
    /// the bridge. Raw library capabilities remain available for diagnostics.
    public var channelAcceleratorNames: [String] {
        let names = acceleratorNames
        guard let toolBridge else {
            return names.filter {
                $0 != PDSHShellAccelerator.phone.rawValue
                    && $0 != PDSHShellAccelerator.ctx.rawValue
            }
        }
        return names.filter { $0 != PDSHShellAccelerator.ctx.rawValue || toolBridge.supportsContext }
    }

    /// Host HELLO `caps[]` entries (`accelerator:<name>`) for the commands this
    /// provider can execute, for the facade.
    public var channelCapabilities: [String] {
        channelAcceleratorNames.map { "accelerator:\($0)" }
    }

    /// `ExecProvider` capabilities. The provider has no network and reads the
    /// persistent workspace; both command tiers can use it.
    public var capabilities: ExecCapabilities {
        let environment: String
        if PDSHShellC.linked {
            environment = "pdsh-shell \(PDSHShellC.version) (read-only accelerators)"
        } else {
            environment = "pdsh-shell not linked"
        }
        return ExecCapabilities(environment: environment,
                                network: false,
                                persistentWorkspace: true,
                                tiers: [.interactive, .session])
    }

    // MARK: - ExecProvider

    /// Starts one accelerator. The stream ends with exactly one `.exit`; a
    /// timed-out run exits 124 and a cancelled run 130 (the pdsh-ffi codes), and
    /// the Rust worker is joined rather than abandoned.
    public func run(_ request: ExecRequest) -> AsyncThrowingStream<ExecEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.onTermination = { [engine] termination in
                // A consumer that walks away cancels the underlying command so
                // no Rust worker thread outlives its stream. The host-level
                // event retention that keeps an execution alive across a
                // client disconnect lives in the channel layer.
                if case .cancelled = termination {
                    engine.cancel(execID: request.execID)
                }
            }
            engine.start(request, continuation: continuation)
        }
    }

    /// Forwards to `pdsh_cancel`; the cancelled run reports exit 130.
    public func cancel(execID: String) async {
        engine.cancel(execID: execID)
    }

    // MARK: - Equatable

    /// Providers are equal when they describe the same mounts, limits and
    /// capability set; bridge instances are compared by presence only.
    public static func == (lhs: PDSHShellProvider, rhs: PDSHShellProvider) -> Bool {
        lhs.materializedWorkspace == rhs.materializedWorkspace
            && lhs.materializedHome == rhs.materializedHome
            && lhs.limits == rhs.limits
            && (lhs.toolBridge == nil) == (rhs.toolBridge == nil)
            && lhs.helloCapabilities == rhs.helloCapabilities
    }

    // MARK: - Advertised names

    /// The names the provider may publish and execute.
    ///
    /// The linked capability JSON already excludes `phone` / `ctx` when no
    /// bridge was supplied. With no mount the engine rejects every request, so
    /// the provider publishes no accelerator at all rather than claiming one
    /// that cannot run.
    private static func executableAcceleratorNames(caps: PDSHShellCaps?,
                                               hasMounts: Bool) -> [String] {
        guard hasMounts, let caps else { return [] }
        return caps.accelerators
    }

    // MARK: - Mounts

    private static func makeMounts(workspace: URL?, home: URL?) -> [PDSHShellMount] {
        var mounts: [PDSHShellMount] = []
        if let workspace {
            mounts.append(PDSHShellMount(hostPath: workspace.standardizedFileURL.path,
                                       guestPath: "/dsh/workspace",
                                       readOnly: true))
        }
        if let home {
            mounts.append(PDSHShellMount(hostPath: home.standardizedFileURL.path,
                                       guestPath: "/dsh/home",
                                       readOnly: true))
        }
        return mounts
    }
}
