// SPDX-License-Identifier: MIT
// phone-dsh SDK — PhoneDSHAgentCore: agent harness.
//
// An agent harness runs long, tool-using agent sessions: a harness on the phone
// (an embedded runtime), a self-hosted harness server, or a commercial cloud.
// The shape follows harness-wire v1 (spec/harness-wire-v1): commands in, an
// ordered event stream out, and declared capabilities so the host UI adapts to
// what the backend can do. Durable events carry a monotonically increasing
// `seq`; after an app kill the host resumes with `events(after:)` from the last
// durable seq it processed. Streaming deltas are best effort and never
// replayed.

import Foundation

/// What a harness backend supports. The host must not offer an action the
/// backend cannot honour (for example "steer" while a turn runs).
public struct HarnessCapabilities: Codable, Equatable, Sendable {
    public enum Resume: String, Codable, Sendable {
        /// The backend replays durable events after a cursor.
        case native
        /// The client re-reads a transcript and reconstructs state.
        case replay
        case none
    }

    public enum Permission: String, Codable, Sendable {
        /// The harness asks before risky tools and waits for `permissionResponse`.
        case native
        /// Approvals are relayed through another channel (for example the
        /// phone's own approval gate for phone tools).
        case relay
        /// The harness never asks; the phone-side gate is the only control.
        case none
    }

    public enum ClientTools: String, Codable, Sendable {
        /// The harness accepts MCP servers at session creation.
        case native
        /// Tools reach the harness through a bridge (relay or proxy).
        case bridge
        case none
    }

    public var cancel: Bool
    public var steer: Bool
    public var resume: Resume
    public var permission: Permission
    public var clientTools: ClientTools
    /// Whether `toolCall` / `toolResult` events are emitted.
    public var toolVisibility: Bool
    /// Whether the harness may keep running while the phone app is suspended
    /// (true for remote harnesses, false for an embedded one).
    public var runsWhileAppSuspended: Bool

    public init(cancel: Bool = true,
                steer: Bool = false,
                resume: Resume = .native,
                permission: Permission = .none,
                clientTools: ClientTools = .none,
                toolVisibility: Bool = true,
                runsWhileAppSuspended: Bool = true) {
        self.cancel = cancel
        self.steer = steer
        self.resume = resume
        self.permission = permission
        self.clientTools = clientTools
        self.toolVisibility = toolVisibility
        self.runsWhileAppSuspended = runsWhileAppSuspended
    }

    private enum CodingKeys: String, CodingKey {
        case cancel, steer, resume, permission
        case clientTools = "client_tools"
        case toolVisibility = "tool_visibility"
        case runsWhileAppSuspended = "runs_while_app_suspended"
    }
}

/// An MCP server the harness should be able to call during the session
/// (normally the phone's own tool server).
public struct MCPServerReference: Codable, Equatable, Sendable {
    public enum Transport: Codable, Equatable, Sendable {
        /// Streamable HTTP endpoint, for example the phone's loopback server.
        case streamableHTTP(url: URL, headers: [String: String])
        /// The phone holds an outbound relay connection (spec/phone-relay-v1);
        /// `relayID` names that connection on the harness side.
        case relay(relayID: String)
        /// Same-process server identified by name (embedded harness).
        case inProcess(name: String)
    }

    public var name: String
    public var transport: Transport
    /// Tool names the harness may call; empty means all tools the server lists.
    public var allowedTools: [String]

    public init(name: String, transport: Transport, allowedTools: [String] = []) {
        self.name = name
        self.transport = transport
        self.allowedTools = allowedTools
    }

    private enum CodingKeys: String, CodingKey {
        case name, transport
        case allowedTools = "allowed_tools"
    }
}

/// Parameters for opening (or resuming) a harness session.
public struct HarnessSessionRequest: Codable, Equatable, Sendable {
    /// Resume this session when set; create a new one when nil.
    public var sessionID: String?
    /// Harness-specific profile / preset name.
    public var preset: String?
    /// Working directory or workspace identifier inside the harness.
    public var workspace: String?
    /// Extra system instructions for this session.
    public var instructions: String?
    /// Tool servers the harness can call back into.
    public var clientTools: [MCPServerReference]
    /// Free-form labels (task origin, device id, locale).
    public var metadata: [String: String]

    public init(sessionID: String? = nil,
                preset: String? = nil,
                workspace: String? = nil,
                instructions: String? = nil,
                clientTools: [MCPServerReference] = [],
                metadata: [String: String] = [:]) {
        self.sessionID = sessionID
        self.preset = preset
        self.workspace = workspace
        self.instructions = instructions
        self.clientTools = clientTools
        self.metadata = metadata
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case preset, workspace, instructions
        case clientTools = "client_tools"
        case metadata
    }
}

/// An open harness session.
public struct HarnessSession: Codable, Equatable, Sendable {
    public var id: String
    public var capabilities: HarnessCapabilities
    /// Highest durable event seq the backend reported at open time.
    public var lastSeq: UInt64?

    public init(id: String, capabilities: HarnessCapabilities, lastSeq: UInt64? = nil) {
        self.id = id
        self.capabilities = capabilities
        self.lastSeq = lastSeq
    }

    private enum CodingKeys: String, CodingKey {
        case id, capabilities
        case lastSeq = "last_seq"
    }
}

/// An attachment sent with a prompt.
public struct HarnessAttachment: Codable, Equatable, Sendable {
    public var name: String
    public var mimeType: String
    public var data: Data

    public init(name: String, mimeType: String, data: Data) {
        self.name = name
        self.mimeType = mimeType
        self.data = data
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case mimeType = "mime_type"
        case data
    }
}

/// Decision for a permission request raised by the harness.
public enum PermissionDecision: String, Codable, Sendable {
    case allowOnce = "allow_once"
    case allowAlways = "allow_always"
    case deny
}

/// Why the host asks a harness to cancel a turn (G2-FIX-76).
///
/// DSH's `session/cancel` request carries the cause, so the session journal
/// and the remote server can tell a user cancel from a hook/budget/timeout
/// cancel. `dshWireValue` is the one encoding: the user cause is
/// `{"kind":"user"}`; every host-side cause is a hook reason, for example
/// `{"kind":"hook","reason":{"kind":"budget","detail":"…"}}`.
public enum AgentCancelCause: Codable, Equatable, Sendable {
    /// The user pressed cancel.
    case user
    /// A host hook cancelled the turn.
    case hook
    /// A model/token/step budget ran out.
    case budget(String)
    /// A wall-clock or delivery deadline expired.
    case timeout(String)

    /// Stable cause kind written to the DSH request.
    public var kind: String {
        switch self {
        case .user: return "user"
        case .hook: return "hook"
        case .budget: return "budget"
        case .timeout: return "timeout"
        }
    }

    /// The exact DSH `session/cancel` cause value.
    public var dshWireValue: JSONValue {
        switch self {
        case .user:
            return .object(["kind": .string("user")])
        case .hook:
            return .object([
                "kind": .string("hook"),
                "reason": .object(["kind": .string("hook")]),
            ])
        case .budget(let detail):
            return .object([
                "kind": .string("hook"),
                "reason": .object([
                    "kind": .string("budget"),
                    "detail": .string(detail),
                ]),
            ])
        case .timeout(let detail):
            return .object([
                "kind": .string("hook"),
                "reason": .object([
                    "kind": .string("timeout"),
                    "detail": .string(detail),
                ]),
            ])
        }
    }
}

/// Commands the host sends to a session.
public enum HarnessCommand: Codable, Equatable, Sendable {
    /// Start a new turn. `requestID` makes the prompt idempotent.
    case prompt(text: String, attachments: [HarnessAttachment], requestID: String)
    /// Add guidance to the running turn (only when `capabilities.steer`).
    case steer(text: String, requestID: String)
    case cancel
    /// Cancel with a reason the backend can journal. A backend that cannot
    /// carry a cause may treat it as ``cancel``; DSH Remote carries it
    /// unchanged in the `session/cancel` request.
    case cancelWithCause(AgentCancelCause)
    case permissionResponse(requestID: String, decision: PermissionDecision)
    case questionResponse(requestID: String, answer: String)
    case shutdown
}

/// Risk class of a tool, used by harness permission prompts and by the phone's
/// own approval gate.
public enum ToolRisk: String, Codable, Sendable {
    /// Reads data, no side effects.
    case readOnly = "read_only"
    /// Changes state outside the conversation (messages, files, calendar).
    case sideEffect = "side_effect"
    /// Operates the phone's user interface; needs a user-granted UI lease.
    case userInterface = "ui"
}

public struct HarnessPermissionRequest: Codable, Equatable, Sendable {
    public var requestID: String
    public var tool: String
    public var summary: String
    public var risk: ToolRisk
    public var expiresAt: Date?

    public init(requestID: String, tool: String, summary: String, risk: ToolRisk, expiresAt: Date? = nil) {
        self.requestID = requestID
        self.tool = tool
        self.summary = summary
        self.risk = risk
        self.expiresAt = expiresAt
    }

    private enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case tool, summary, risk
        case expiresAt = "expires_at"
    }
}

/// One independently answerable question in a DSH request.
public struct HarnessQuestionItem: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var prompt: String
    public var options: [String]
    public var multiple: Bool

    public init(id: String, prompt: String, options: [String] = [], multiple: Bool = false) {
        self.id = id; self.prompt = prompt; self.options = options; self.multiple = multiple
    }
}

public struct HarnessQuestion: Codable, Equatable, Sendable {
    public var requestID: String
    public var prompt: String
    public var options: [String]

    public var questions: [HarnessQuestionItem]?

    public init(requestID: String, prompt: String, options: [String] = [], questions: [HarnessQuestionItem]? = nil) {
        self.requestID = requestID
        self.prompt = prompt
        self.options = options
        self.questions = questions
    }

    private enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case prompt, options, questions
    }
}

/// Why a turn ended.
public enum HarnessTurnEnd: Codable, Equatable, Sendable {
    case completed
    case cancelled
    case failed(String)
    /// The harness stopped because a budget (steps, tokens, time) ran out.
    case budgetExhausted(String)
}

/// One model-visible user-role message carried by a DSH session event.
///
/// `source` is DSH's producer-declared source kind (`user` for a direct human
/// prompt, `goal` for a goal continuation round, `webhook`, …), so a transcript
/// reader can tell who supplied the text. `agent/inbox/spliced` batches several
/// of these in one DSH event.
public struct HarnessUserInput: Codable, Equatable, Sendable {
    /// Concatenated `text` blocks of the message content, exactly as the model
    /// sees them.
    public var text: String
    /// DSH `source.kind`; `unknown` when the journal carried no readable source.
    public var source: String

    public init(text: String, source: String) {
        self.text = text
        self.source = source
    }
}

/// The complete tool-result record for audit and evidence consumers.
///
/// `HarnessEvent.Kind.toolResult` carries the bounded, single-line `summary`
/// that UI and event-stream consumers render. This projection is the same tool
/// result with its line structure intact, bounded only by
/// ``DSHEventMapper/defaultAuditTextLimit``; the scenario recorder serializes it
/// beside `kind` in `transcript.jsonl`, so a reviewer can read a test runner's
/// verdict line or a traceback's root cause without opening the raw session log.
public struct HarnessToolResultDetail: Codable, Equatable, Sendable {
    /// Tool-result text with newlines preserved. When ``truncated`` is true this
    /// is the longest prefix that fits the audit bound, followed by an explicit
    /// spill marker naming the durable session log and the DSH event.
    public var text: String
    /// Whether `text` exceeded the audit bound.
    public var truncated: Bool
    /// DSH session-journal seq (`event.seq`) of the `tool/result` record.
    public var eventSeq: Int
    /// Pointer to the untruncated record in the VFS. DSH appends session
    /// journals below `/dsh/home/sessions/<workspace>/<session-id>/`; the `*`
    /// and `session.*` components are globs because the mapper does not know
    /// the workspace directory or the journal version.
    public var sessionLogPath: String

    public init(text: String, truncated: Bool, eventSeq: Int, sessionLogPath: String) {
        self.text = text
        self.truncated = truncated
        self.eventSeq = eventSeq
        self.sessionLogPath = sessionLogPath
    }
}

/// One event of a session stream.
public struct HarnessEvent: Codable, Equatable, Sendable {
    public enum Kind: Codable, Equatable, Sendable {
        case assistantDelta(text: String)
        /// One streamed reasoning/thinking chunk (DSH `reasoning-delta`).
        case reasoningDelta(text: String)
        case assistantMessage(text: String)
        case toolCall(callID: String, name: String, arguments: JSONValue)
        case toolResult(callID: String, isError: Bool, summary: String)
        case permissionRequested(HarnessPermissionRequest)
        case questionRequested(HarnessQuestion)
        /// A DSH `user/message`: one user-role message the model sees.
        case userMessage(text: String, source: String)
        /// A DSH `agent/inbox/spliced`: the user-role messages one splice
        /// inserted into the session inbox, in insertion order.
        case inboxSpliced(messages: [HarnessUserInput])
        case turnStarted(turnID: String)
        case turnEnded(turnID: String, reason: HarnessTurnEnd)
        /// Progress of a long task; drives background-task progress UI.
        case progress(phase: String, step: Int, of: Int?)
        case sessionStatus(String)
        case usage(inputTokens: Int, outputTokens: Int)
        /// The harness process / session ended for good.
        case exited(reason: String)
    }

    /// Durable sequence number; nil for best-effort events (deltas).
    public var seq: UInt64?
    public var time: Date
    public var kind: Kind
    /// Complete tool-result text for audit consumers; set only on a
    /// `.toolResult` event mapped from a DSH session journal. UI consumers keep
    /// rendering the bounded `kind` summary.
    public var toolResultDetail: HarnessToolResultDetail?
    /// DSH `turn/end.data.reason.kind` (`completed`, `aborted`, `interrupted`,
    /// `max-tokens`, `error`, `blocked`, `forked`, or a newer producer kind),
    /// preserved verbatim on a `.turnEnded` event mapped from DSH. `nil` on
    /// events from other backends and on pre-field transcript lines.
    ///
    /// ``Kind/turnEnded(turnID:reason:)`` remains the stable compatibility
    /// projection; this field keeps the original label so a transcript cannot
    /// disagree with the durable DSH session journal.
    public var rawTurnEndKind: String?
    /// The cause nested under `turn/end.data.reason.reason` (or the structured
    /// `reason.error`), as compact, key-sorted JSON when the cause is an object.
    /// `nil` when the reason carries no cause, for example `interrupted`.
    public var rawTurnEndCause: String?

    public init(seq: UInt64?, time: Date, kind: Kind) {
        self.init(seq: seq, time: time, kind: kind, toolResultDetail: nil,
                  rawTurnEndKind: nil, rawTurnEndCause: nil)
    }

    public init(seq: UInt64?, time: Date, kind: Kind,
                toolResultDetail: HarnessToolResultDetail?,
                rawTurnEndKind: String? = nil,
                rawTurnEndCause: String? = nil) {
        self.seq = seq
        self.time = time
        self.kind = kind
        self.toolResultDetail = toolResultDetail
        self.rawTurnEndKind = rawTurnEndKind
        self.rawTurnEndCause = rawTurnEndCause
    }

    public var isDurable: Bool { seq != nil }
}

/// A harness backend.
public protocol AgentHarness: Sendable {
    /// Static capabilities of this backend (a session may narrow them).
    var capabilities: HarnessCapabilities { get }

    /// Opens a new session or resumes `request.sessionID`.
    func openSession(_ request: HarnessSessionRequest) async throws -> HarnessSession

    /// Sends one command. Prompts and steers are idempotent by `requestID`.
    func send(_ command: HarnessCommand, to sessionID: String) async throws

    /// Event stream starting after the durable `seq` (nil = from the beginning
    /// of what the backend retains). The stream finishes when the session
    /// exits; it throws `ProviderError.unavailable` on a transport loss, after
    /// which the caller re-subscribes from its last durable seq.
    func events(sessionID: String, after seq: UInt64?) -> AsyncThrowingStream<HarnessEvent, Error>

    /// Releases client-side resources; does not delete the remote session.
    func closeSession(_ sessionID: String) async
}

public extension AgentHarness {
    func closeSession(_ sessionID: String) async {}
}
