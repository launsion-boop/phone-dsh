// SPDX-License-Identifier: MIT
// The three independent chat states W1-B separates:
//
//   * engine lifecycle — stopped / starting / running / failed;
//   * the session switch — idle / switching;
//   * the send — idle / sending.
//
// Before W1 one `busy` flag stood for all three, so booting the Worker blocked
// opening another session and reading history. These predicates are pure so the
// App and the simulator tests share one table; they never touch the host.

import Foundation

public enum ChatEnginePhase: String, Equatable, Sendable {
    case stopped
    case starting
    case running
    case failed
}

public enum ChatSwitchPhase: String, Equatable, Sendable {
    case idle
    case switching
}

public enum ChatSendPhase: String, Equatable, Sendable {
    case idle
    case sending
}

public struct ChatStateSnapshot: Equatable, Sendable {
    public var engine: ChatEnginePhase
    public var sessionSwitch: ChatSwitchPhase
    public var send: ChatSendPhase

    public init(engine: ChatEnginePhase,
                sessionSwitch: ChatSwitchPhase = .idle,
                send: ChatSendPhase = .idle) {
        self.engine = engine
        self.sessionSwitch = sessionSwitch
        self.send = send
    }
}

public enum ChatStatePolicy {
    /// `startInProgress` is the model's start path, not `busy`: a send or a
    /// switch that happens to hold the old flag is not engine boot.
    public static func enginePhase(hostPresent: Bool,
                                   startInProgress: Bool,
                                   needsReset: Bool,
                                   failed: Bool,
                                   parked: Bool) -> ChatEnginePhase {
        if startInProgress { return .starting }
        if failed || needsReset { return .failed }
        if hostPresent { return parked ? .stopped : .running }
        return .stopped
    }

    /// Browsing the materialized projection never needs the engine. A viewer
    /// may list, open any session and page backwards in every phase.
    public static func canBrowse(_ phase: ChatEnginePhase) -> Bool {
        true
    }

    /// Activating a session as the engine's active one still needs a running
    /// engine and no in-flight switch or host lifecycle transition.
    public static func canActivateSession(phase: ChatEnginePhase,
                                          switchPhase: ChatSwitchPhase,
                                          hostTransition: Bool) -> Bool {
        phase == .running && switchPhase == .idle && !hostTransition
    }

    /// A send is always accepted into the durable outbox; the engine phase only
    /// decides when it is delivered, never whether the person may submit.
    public static func canAcceptSend(_ phase: ChatEnginePhase) -> Bool {
        true
    }

    /// A running turn is never interrupted to activate another session. A send
    /// to a non-active session waits in the outbox instead.
    public static func mayActivateDuringTurn(_ running: Bool) -> Bool {
        !running
    }
}
