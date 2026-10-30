// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHShell: public contract types.
//
// PLAN §2.1/§2.4 (D12) and spec/v1/exec.md §3. The Rust pdsh-shell
// library (shell/) is a read-only accelerator set: it has no write
// operation, so every command it runs is read-only by construction. This file
// holds the value types the provider, the hello capabilities and the injected
// tool bridge expose.

import Foundation
import PhoneDSHAgentCore

/// Read-only accelerator names of PLAN §2.4 (D12).
///
/// `jq` is the alias the Rust registry advertises in addition to the names of
/// the executor-inversion table; it is the same `jaq` command. The enum is
/// informational: the authoritative list is always the capability JSON of the
/// linked library (`pdsh_caps_json`), which the provider republishes verbatim.
public enum PDSHShellAccelerator: String, CaseIterable, Codable, Sendable {
    case rg
    case jaq
    case jq
    case tsParse = "ts-parse"
    case tsQuery = "ts-query"
    case phone
    case ctx
}

/// Failures of the pdsh-shell provider.
public enum PDSHShellError: Error, Equatable, Sendable {
    /// The Rust xcframework is not part of this build.
    case notLinked
    /// The provider has no materialized workspace to mount.
    case notConfigured
    /// The requested `argv[0]` is not an advertised accelerator.
    case unsupportedCommand(String)
    /// The request violates the exec-bridge v1 invariants.
    case invalidRequest(String)
}

extension PDSHShellError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notLinked:
            return "pdsh-shell not linked: build with PDSH_WITH_XZSHELL=1 to enable read-only accelerators"
        case .notConfigured:
            return "pdsh-shell has no materialized workspace mount"
        case .unsupportedCommand(let name):
            return "\(name) is not an advertised pdsh-shell accelerator"
        case .invalidRequest(let reason):
            return "pdsh-shell rejected the request: \(reason)"
        }
    }
}

/// Limits of one accelerator run (spec/exec-bridge-v1 §3/§4.1).
///
/// `timeoutMilliseconds` is used when a request carries no deadline; `0` means
/// "no deadline". A request deadline always wins. The same effective budget
/// bounds a synchronous `phone` / `ctx` host bridge callback, so a bridge that
/// does not answer cannot hold the Rust worker past it. The output budget is
/// per stream and is enforced by the Rust output sink (head/tail truncation).
public struct PDSHShellLimits: Equatable, Sendable {
    /// The 8 GiB tier's default single-file budget (`budgets.md` §4): the
    /// largest materialized file an accelerator may read. A file is published
    /// as several VFS mutations (one mutation carries at most
    /// `WireLimits.maxMutationDataBytes` in the wire layer), so the read limit
    /// follows the host `single_file_limit`, not the per-mutation cap.
    public static let defaultMaxFileBytes: UInt64 = 64 * 1024 * 1024

    public var timeoutMilliseconds: UInt64
    public var maxOutputBytes: Int
    public var maxFiles: Int
    public var maxFileBytes: UInt64

    public init(timeoutMilliseconds: UInt64 = 30_000,
                maxOutputBytes: Int = 1_048_576,
                maxFiles: Int = 10_000,
                maxFileBytes: UInt64 = PDSHShellLimits.defaultMaxFileBytes) {
        self.timeoutMilliseconds = timeoutMilliseconds
        self.maxOutputBytes = maxOutputBytes
        self.maxFiles = maxFiles
        self.maxFileBytes = maxFileBytes
    }

    /// The provider defaults. The Rust library's own defaults agree on
    /// timeout/output/file-count; `maxFileBytes` here is the phone single-file
    /// budget so an accelerator can read a large materialized file.
    public static let `default` = PDSHShellLimits()
}

/// One guest-to-host mount published in the hello capabilities.
public struct PDSHShellMount: Codable, Equatable, Sendable {
    public var hostPath: String
    public var guestPath: String
    public var readOnly: Bool

    public init(hostPath: String, guestPath: String, readOnly: Bool) {
        self.hostPath = hostPath
        self.guestPath = guestPath
        self.readOnly = readOnly
    }

    private enum CodingKeys: String, CodingKey {
        case hostPath = "host_path"
        case guestPath = "guest_path"
        case readOnly = "read_only"
    }
}

/// The capability JSON the linked `pdsh-shell` library publishes
/// (`{"accelerators":[…],"version":…,"limits":{…}}`).
public struct PDSHShellCaps: Codable, Equatable, Sendable {
    public struct Limits: Codable, Equatable, Sendable {
        public var timeout: UInt64
        public var maxOutputBytes: Int
        public var maxFiles: Int
        public var maxFileBytes: UInt64

        public init(timeout: UInt64, maxOutputBytes: Int,
                    maxFiles: Int, maxFileBytes: UInt64) {
            self.timeout = timeout
            self.maxOutputBytes = maxOutputBytes
            self.maxFiles = maxFiles
            self.maxFileBytes = maxFileBytes
        }

        private enum CodingKeys: String, CodingKey {
            case timeout
            case maxOutputBytes = "max_output_bytes"
            case maxFiles = "max_files"
            case maxFileBytes = "max_file_bytes"
        }
    }

    public var accelerators: [String]
    public var version: String
    public var limits: Limits

    public init(accelerators: [String], version: String, limits: Limits) {
        self.accelerators = accelerators
        self.version = version
        self.limits = limits
    }
}

/// Discovery object the App facade publishes for the pdsh-shell provider.
///
/// This is the provider half of the exec-bridge v1 `hello` (spec/exec-bridge-v1
/// §3) plus the read-only statement the executor inversion promises (D12):
/// the accelerator names come from the linked library's `pdsh_caps_json`, the
/// mounts are the materialized copies owned by `WorkspaceLog`, and `confine`
/// advertises both exec-bridge modes because a read-only accelerator makes no
/// host-visible writes in either mode.
public struct PDSHShellHelloCapabilities: Equatable, Sendable {
    /// Version string of the linked `pdsh-shell` library.
    public var version: String
    /// Advertised accelerator names, verbatim from `pdsh_caps_json`.
    public var accelerators: [String]
    /// `capabilities.confine` values of spec/exec-bridge-v1 §3.
    public var confine: [String]
    /// Materialized workspace/home mounts the accelerators read.
    public var mounts: [PDSHShellMount]
    /// Always `true`: the provider cannot write the workspace.
    public var readOnly: Bool
    /// Per-run limits advertised by the library.
    public var limits: PDSHShellCaps.Limits?

    public init(version: String, accelerators: [String], confine: [String],
                mounts: [PDSHShellMount], readOnly: Bool,
                limits: PDSHShellCaps.Limits?) {
        self.version = version
        self.accelerators = accelerators
        self.confine = confine
        self.mounts = mounts
        self.readOnly = readOnly
        self.limits = limits
    }

    /// `accelerator:<name>` entries for the registry this hello describes.
    ///
    /// This is the provider's raw registry (including bridge-only `phone` and
    /// `ctx`). The facade publishes the executable subset through
    /// ``PDSHShellProvider/channelCapabilities``.
    public var acceleratorCapabilities: [String] {
        accelerators.map { "accelerator:\($0)" }
    }
}

extension PDSHShellError: ExecProviderFailure {
    public var code: String {
        switch self {
        case .notLinked: return "not_linked"
        case .notConfigured: return "not_configured"
        case .unsupportedCommand: return "unsupported"
        case .invalidRequest: return "invalid_request"
        }
    }

    public var message: String { localizedDescription }
}

/// Host tool bridge for the `phone` and `ctx` accelerators (D12).
///
/// The Rust side never talks to the network: it calls back into the host, and
/// the App facade implements this protocol over its MCP server. `arguments` is
/// the JSON object the command received (`{}` when omitted); the result must be
/// a JSON document, printed unchanged by the accelerator.
public protocol PhoneToolBridge: Sendable {
    var supportsContext: Bool { get }
    func callTool(name: String, arguments: String) async throws -> String
}

public extension PhoneToolBridge {
    /// Generic hosts keep their existing ctx support. A limited bridge must
    /// explicitly decline it instead of advertising an unimplemented tool.
    var supportsContext: Bool { true }
}

/// Closure-backed ``PhoneToolBridge`` for the facade and for tests.
public struct ClosurePhoneToolBridge: PhoneToolBridge {
    private let handler: @Sendable (String, String) async throws -> String

    public init(_ handler: @escaping @Sendable (String, String) async throws -> String) {
        self.handler = handler
    }

    public func callTool(name: String, arguments: String) async throws -> String {
        try await handler(name, arguments)
    }
}
