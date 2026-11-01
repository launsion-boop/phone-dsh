// SPDX-License-Identifier: MIT
// phone-dsh SDK — PhoneDSHAgentCore: command execution.
//
// The executor seam a harness uses to run commands on the phone's local
// toolbox, a remote sandbox or a read-only accelerator. Field names follow the
// exec bridge (`{exec_id, argv, cwd, env, deadline}`). This is the minimal
// provider contract the phone-DSH modules need; the delegation types built on
// top of it stay in the provider module.

import Foundation

/// Runs commands for an agent: the phone's local toolbox or a remote sandbox.
/// Field names follow the exec bridge (`{exec_id, argv, cwd, env, deadline}`).
public struct ExecRequest: Codable, Equatable, Sendable {
    public enum Tier: String, Codable, Sendable {
        /// User is waiting (foreground).
        case interactive
        /// Short steps inside an active phone session.
        case session
        /// Long work; may be offloaded to a remote sandbox.
        case batch
    }

    public var execID: String
    public var argv: [String]
    public var cwd: String
    public var env: [String: String]
    public var deadline: Date?
    public var tier: Tier

    public init(execID: String, argv: [String], cwd: String, env: [String: String] = [:],
                deadline: Date? = nil, tier: Tier = .interactive) {
        self.execID = execID
        self.argv = argv
        self.cwd = cwd
        self.env = env
        self.deadline = deadline
        self.tier = tier
    }

    private enum CodingKeys: String, CodingKey {
        case execID = "exec_id"
        case argv, cwd, env, deadline, tier
    }
}

public enum ExecEvent: Codable, Equatable, Sendable {
    case stdout(seq: UInt64, data: Data)
    case stderr(seq: UInt64, data: Data)
    /// Final event. `signal` is set when the process was killed.
    case exit(code: Int32?, signal: Int32?, truncated: Bool)
}

public struct ExecCapabilities: Codable, Equatable, Sendable {
    /// Human-readable environment ("alpine-arm64 local", "remote sandbox").
    public var environment: String
    public var network: Bool
    public var persistentWorkspace: Bool
    public var tiers: [ExecRequest.Tier]

    public init(environment: String, network: Bool, persistentWorkspace: Bool,
                tiers: [ExecRequest.Tier]) {
        self.environment = environment
        self.network = network
        self.persistentWorkspace = persistentWorkspace
        self.tiers = tiers
    }
}

public protocol ExecProvider: Sendable {
    var capabilities: ExecCapabilities { get }
    /// Starts (or re-attaches to, same `execID`) a command; the stream ends
    /// with exactly one `.exit`.
    func run(_ request: ExecRequest) -> AsyncThrowingStream<ExecEvent, Error>
    func cancel(execID: String) async
}

/// A provider failure that is safe to expose across the exec-bridge boundary.
public protocol ExecProviderFailure: Error {
    var code: String { get }
    var message: String { get }
}
