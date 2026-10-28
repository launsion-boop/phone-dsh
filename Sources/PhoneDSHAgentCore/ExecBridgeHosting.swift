// SPDX-License-Identifier: MIT
// phone-dsh SDK — PhoneDSHAgentCore: the exec-bridge host seam.
//
// The host side of spec/exec-bridge-v1 a loopback origin (or the local DSH
// host) needs: start, stop, the per-start token and the lifecycle gate. The
// server implementation lives in the exec-bridge module and conforms to it.

import Foundation

/// What `/v1/lifecycle` reports to the guest.
public enum ExecBridgeLifecycleState: String, Codable, Sendable {
    /// Work may proceed.
    case run
    /// Park new model / tool steps until `run` (the app is backgrounded with
    /// little budget left).
    case pause
    /// Refuse new work (the app is about to be suspended or the user stopped it).
    case stop
}

/// What `LocalDSHHost` needs from a bridge (the server, or a test double).
public protocol ExecBridgeHosting: Actor {
    var token: String? { get }
    var baseURL: URL? { get }
    func start() async throws -> URL
    func stop() async
    func setLifecycle(_ state: ExecBridgeLifecycleState) async
}
