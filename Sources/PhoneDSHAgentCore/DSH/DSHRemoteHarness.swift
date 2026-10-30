// SPDX-License-Identifier: MIT
// PhoneDSHAgentCore: `AgentHarness` for a self-hosted DeepSeek Harness
// (`dsh web`).
//
//   let transport = DSHWebTransport(baseURL: URL(string: "http://127.0.0.1:3080")!,
//                                   credentials: launchTokenProvider)
//   let harness = DSHRemoteHarness(transport: transport)
//
// Mapping:
//   openSession  → session/create for a new session; session/page at throughSeq
//                  -1 validates an existing id without creating a replacement.
//                  The first session/prompt resolves and resumes that Session's Agent.
//   prompt/steer → session/prompt {mode: queue|steer}, requestId dedupe
//   cancel       → session/cancel
//   events       → `session/follow` on the WebSocket mux (snapshot, then
//                  durable events, then live `text-delta` frames as
//                  best-effort deltas) plus the `$events` stream for approval
//                  and question requests and running status.
//   Resume       → the follow snapshot window, extended backwards with
//                  `session/page` until the caller's last seq is covered.
//   permission   → the `approval/request` waterfall becomes a best-effort
//                  `permissionRequested` (request id = DSH event id); the
//                  answer goes to `$events/result`. DSH re-delivers pending
//                  requests to every new connection.
//
// Not supported by DSH Remote (reported honestly in `capabilities` or as
// `ProviderError.unsupported`): per-session MCP client tools (configure the
// phone's relay in DSH itself), "allow always" (sent as allow once),
// non-image attachments, `shutdown`.

import Foundation

public actor DSHRemoteHarness: AgentHarness {
    public nonisolated let capabilities = HarnessCapabilities(
        cancel: true, steer: true, resume: .native, permission: .native,
        clientTools: .none, toolVisibility: true, runsWhileAppSuspended: true)

    public struct Configuration: Sendable {
        public var reconnect: ReconnectPolicy
        /// Messages in the opening snapshot window (and per gap-fill page).
        public var pageMessages: Int
        public var timeZone: String?

        public init(reconnect: ReconnectPolicy = ReconnectPolicy(),
                    pageMessages: Int = 50,
                    timeZone: String? = TimeZone.current.identifier) {
            self.reconnect = reconnect
            self.pageMessages = pageMessages
            self.timeZone = Self.normalizedClientTimeZone(timeZone)
        }

        static func normalizedClientTimeZone(_ identifier: String?) -> String? {
            guard let identifier = identifier?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !identifier.isEmpty else { return nil }
            return identifier == "UTC" || TimeZone.knownTimeZoneIdentifiers.contains(identifier)
                ? identifier : "UTC"
        }
    }

    private struct PendingRequest {
        var clientID: String
        var sessionID: String
        var questions: JSONValue?
    }

    private let transport: any DSHRemoteTransport
    private let configuration: Configuration
    private var instructions: [String: String] = [:]
    private var pending: [String: PendingRequest] = [:]

    public init(transport: any DSHRemoteTransport, configuration: Configuration = Configuration()) {
        self.transport = transport
        self.configuration = configuration
    }

    // MARK: - AgentHarness

    public func openSession(_ request: HarnessSessionRequest) async throws -> HarnessSession {
        guard request.clientTools.isEmpty else {
            throw ProviderError.unsupported("dsh web takes MCP servers from its own configuration, not per session")
        }
        if let id = request.sessionID {
            // DSH session/create only reuses a named Session while it remains
            // blank/reusable; naming a Session that already has a turn creates
            // a different Session. Read an empty page to validate identity
            // without activating its Agent or mutating the session list.
            _ = try await call("session/page", ["request": .object([
                "address": .object(["kind": .string("session"), "sessionId": .string(id)]),
                "throughSeq": .number(-1),
                "maxMessages": .number(1),
            ])])
            if let text = request.instructions, !text.isEmpty { instructions[id] = text }
            return HarnessSession(id: id, capabilities: capabilities, lastSeq: nil)
        }
        var create: [String: JSONValue] = [:]
        if let workspace = request.workspace { create["cwd"] = .string(workspace) }
        if let preset = request.preset { create["agentPreset"] = .string(preset) }
        let value = try await call("session/create", ["request": .object(create)])
        guard let id = value["sessionId"]?.stringValue else {
            throw ProviderError.invalidResponse("session/create returned no sessionId")
        }
        if let text = request.instructions, !text.isEmpty { instructions[id] = text }
        return HarnessSession(id: id, capabilities: capabilities, lastSeq: nil)
    }

    public func goal(sessionID: String) async throws -> HarnessGoal? {
        let value = try await call("session/projections", [
            "request": .object(["sessionId": .string(sessionID)]),
        ])
        guard let current = value["values"]?["goal"]?["current"],
              current.objectValue != nil,
              let goal = current["goal"],
              let objective = goal["objective"]?.stringValue, !objective.isEmpty else {
            return nil
        }
        let phase = HarnessGoal.Phase(rawValue: goal["phase"]?.stringValue ?? "active") ?? .active
        return HarnessGoal(
            objective: objective,
            phase: phase,
            blockedReason: goal["blockedReason"]?["message"]?.stringValue,
            roundsStarted: current["roundsStarted"]?.intValue ?? 0,
            maxGoalRounds: goal["maxGoalRounds"]?.intValue ?? 0)
    }

    public func send(_ command: HarnessCommand, to sessionID: String) async throws {
        switch command {
        case .prompt(let text, let attachments, let requestID):
            try await prompt(text, attachments: attachments, requestID: requestID, mode: "queue", sessionID: sessionID)
        case .steer(let text, let requestID):
            try await prompt(text, attachments: [], requestID: requestID, mode: "steer", sessionID: sessionID)
        case .cancel:
            _ = try await call("session/cancel", ["request": .object(["sessionId": .string(sessionID)])])
        case .cancelWithCause(let cause):
            // The cause travels with the request so DSH can journal it as the
            // turn's terminal reason instead of an anonymous user cancel
            // (G2-FIX-76).
            _ = try await call("session/cancel", ["request": .object([
                "sessionId": .string(sessionID),
                "cause": cause.dshWireValue,
            ])])
        case .permissionResponse(let requestID, let decision):
            // DSH has no "always" outcome; the user is asked again next time.
            let value = decision == .deny ? "rejected" : "allowed-once"
            try await answer(requestID, outcome: .object(["kind": .string("result"), "value": .string(value)]))
        case .questionResponse(let requestID, let answerText):
            guard let request = pending[requestID] else {
                throw ProviderError.invalidRequest("no pending question \(requestID)")
            }
            try await answer(requestID, outcome: .object([
                "kind": .string("result"),
                "value": Self.questionAnswer(answerText, questions: request.questions),
            ]))
        case .shutdown:
            throw ProviderError.unsupported("dsh web sessions persist; there is no remote shutdown")
        }
    }

    public nonisolated func events(sessionID: String, after seq: UInt64?) -> AsyncThrowingStream<HarnessEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { await self.follow(sessionID: sessionID, after: seq, into: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func closeSession(_ sessionID: String) async {
        instructions[sessionID] = nil
        pending = pending.filter { $0.value.sessionID != sessionID }
    }

    // MARK: - Commands

    private func prompt(_ text: String, attachments: [HarnessAttachment], requestID: String,
                        mode: String, sessionID: String) async throws {
        var body = text
        if mode == "queue", let preface = instructions.removeValue(forKey: sessionID) {
            body = preface + "\n\n" + text
        }
        var content: [JSONValue] = [.object(["type": .string("text"), "text": .string(body)])]
        for attachment in attachments {
            guard attachment.mimeType.hasPrefix("image/") else {
                throw ProviderError.unsupported("dsh web prompts accept image attachments only")
            }
            content.append(.object(["type": .string("image"), "mediaType": .string(attachment.mimeType),
                                    "data": .string(attachment.data.base64EncodedString()),
                                    "name": .string(attachment.name)]))
        }
        var request: [String: JSONValue] = [
            "requestId": .string(requestID), "sessionId": .string(sessionID),
            "mode": .string(mode), "content": .array(content),
        ]
        if let zone = configuration.timeZone { request["clientTimeZone"] = .string(zone) }
        _ = try await call("session/prompt", ["request": .object(request)])
    }

    private func answer(_ requestID: String, outcome: JSONValue) async throws {
        guard let request = pending[requestID] else {
            throw ProviderError.invalidRequest("no pending request \(requestID) (already answered or reconnected)")
        }
        _ = try await call("$events/result", ["clientId": .string(request.clientID), "eventId": .string(requestID),
                                               "outcome": outcome])
        pending[requestID] = nil
    }

    private func call(_ endpoint: String, _ args: [String: JSONValue]) async throws -> JSONValue {
        do {
            return try await transport.call(endpoint, args: .object(args))
        } catch let error as DSHRemoteError {
            throw error.providerError
        }
    }

    static func questionAnswer(_ answer: String, questions: JSONValue?) -> JSONValue {
        let items = questions?.arrayValue ?? []
        // A JSON object answer maps question ids to answers.
        let perQuestion = (try? JSONValue.parse(Data(answer.utf8)))?.objectValue
        return .object(["answers": .array(items.map { question in
            let id = question["id"]?.stringValue ?? ""
            let text = perQuestion?[id]?.stringValue ?? (perQuestion == nil ? answer : "")
            let selections = perQuestion?[id]?.arrayValue?.compactMap(\.stringValue)
            let labels = (question["options"]?.arrayValue ?? []).compactMap { $0["label"]?.stringValue }
            var item: [String: JSONValue] = ["id": .string(id)]
            if let selections {
                item["selected"] = .array(selections.filter { labels.contains($0) }.map(JSONValue.string))
                let custom = selections.filter { !labels.contains($0) }.joined(separator: "\n")
                if !custom.isEmpty { item["custom"] = .string(custom) }
            } else if labels.contains(text) {
                item["selected"] = .array([.string(text)])
            } else {
                item["selected"] = .array([])
                item["custom"] = .string(text)
            }
            return .object(item)
        })])
    }

    // MARK: - Follow

    private func remember(_ eventID: String, _ request: PendingRequest) { pending[eventID] = request }
    private func forget(_ eventID: String) { pending[eventID] = nil }

    private nonisolated func follow(sessionID: String, after: UInt64?,
                                    into continuation: AsyncThrowingStream<HarnessEvent, Error>.Continuation) async {
        var state = FollowState(delivered: after)
        var failures = 0
        var reauthenticated = false
        while !Task.isCancelled {
            do {
                let mux = try await transport.openMux()
                let progressed = try await runConnection(mux, sessionID: sessionID, state: &state,
                                                         continuation: continuation)
                await mux.close()
                failures = progressed ? 0 : failures + 1
                if progressed { reauthenticated = false }
            } catch ProviderError.unauthorized(_) where !reauthenticated {
                // An expired cookie: exchange the launch token once more.
                reauthenticated = true
                await transport.authenticationFailed()
                continue
            } catch let error as ProviderError where !error.isRetryable {
                continuation.finish(throwing: error)
                return
            } catch let error as DSHRemoteError where !error.providerError.isRetryable {
                continuation.finish(throwing: error.providerError)
                return
            } catch {
                if Task.isCancelled { break }
                failures += 1
            }
            if failures > configuration.reconnect.maxAttempts {
                continuation.finish(throwing: ProviderError.unavailable(retryAfter: nil))
                return
            }
            let delay = configuration.reconnect.delay(attempt: max(1, failures))
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        continuation.finish(throwing: ProviderError.cancelled)
    }

    struct FollowState {
        /// Highest harness seq handed to the caller.
        var delivered: UInt64?
    }

    /// Serves one WebSocket connection; returns whether anything was received.
    private nonisolated func runConnection(_ mux: any DSHMuxConnection, sessionID: String, state: inout FollowState,
                                           continuation: AsyncThrowingStream<HarnessEvent, Error>.Continuation)
        async throws -> Bool {
        try await mux.send(.object(["type": .string("open"), "streamId": .string("events"),
                                    "endpoint": .string("$events"), "payload": .object(["args": .object([:])])]))
        try await mux.send(.object([
            "type": .string("open"), "streamId": .string("follow"), "endpoint": .string("session/follow"),
            "payload": .object(["args": .object(["request": .object([
                "address": .object(["kind": .string("session"), "sessionId": .string(sessionID)]),
                "maxMessages": .number(Double(configuration.pageMessages)),
                "assistantStream": .bool(true),
            ])])]),
        ]))
        var clientID: String?
        var progressed = false
        while !Task.isCancelled {
            guard let frame = try await mux.receive() else { return progressed }
            let streamID = frame["streamId"]?.stringValue
            switch frame["type"]?.stringValue {
            case "item":
                progressed = true
                let value = frame["value"] ?? .null
                if streamID == "events" {
                    if value["type"]?.stringValue == "ready" { clientID = value["clientId"]?.stringValue }
                    await handleRemoteEvent(value, clientID: clientID, sessionID: sessionID, mux: mux,
                                            continuation: continuation)
                } else if streamID == "follow" {
                    try await handleFollow(value, sessionID: sessionID, state: &state, continuation: continuation)
                }
            case "error":
                let error = DSHRemoteError(code: frame["error"]?["code"]?.stringValue ?? "gateway/internal",
                                           message: frame["error"]?["message"]?.stringValue ?? "")
                throw error
            case "end":
                return progressed
            default:
                continue
            }
        }
        return progressed
    }

    private nonisolated func handleFollow(_ value: JSONValue, sessionID: String, state: inout FollowState,
                                          continuation: AsyncThrowingStream<HarnessEvent, Error>.Continuation)
        async throws {
        switch value["type"]?.stringValue {
        case "snapshot":
            let cursor = value["cursor"]?.intValue ?? -1
            var records = (value["records"]?.arrayValue ?? []).compactMap { $0["event"] }
            var hasMore = value["hasMore"]?.boolValue ?? false
            // Extend the window backwards until it covers what the caller
            // has not seen yet.
            if let delivered = state.delivered {
                let needFrom = DSHEventMapper.position(of: delivered).dshSeq
                while hasMore, let first = records.first?["seq"]?.intValue, first > needFrom {
                    let page = try await transport.call("session/page", args: .object(["request": .object([
                        "address": .object(["kind": .string("session"), "sessionId": .string(sessionID)]),
                        "throughSeq": .number(Double(cursor)),
                        "beforeSeq": .number(Double(first)),
                        "maxMessages": .number(Double(configuration.pageMessages)),
                    ])]))
                    let older = (page["records"]?.arrayValue ?? []).compactMap { $0["event"] }
                    guard !older.isEmpty else { break }
                    records = older + records
                    hasMore = page["hasMore"]?.boolValue ?? false
                }
            }
            for record in records { deliver(record, sessionID: sessionID, state: &state, continuation: continuation) }
        case "event":
            if let event = value["event"] {
                deliver(event, sessionID: sessionID, state: &state, continuation: continuation)
            }
        case "assistant-stream":
            let frame = value["frame"] ?? .null
            guard frame["type"]?.stringValue == "chunk",
                  let chunkType = frame["chunk"]?["type"]?.stringValue,
                  let text = frame["chunk"]?["text"]?.stringValue else { break }
            switch chunkType {
            case "text-delta":
                continuation.yield(HarnessEvent(seq: nil, time: Date(), kind: .assistantDelta(text: text)))
            case "reasoning-delta":
                // The model's thinking arrives before the answer; forwarding it
                // turns the silent TTFT wait into visible progress.
                continuation.yield(HarnessEvent(seq: nil, time: Date(), kind: .reasoningDelta(text: text)))
            default:
                break
            }
        default:
            break
        }
    }

    private nonisolated func deliver(_ event: JSONValue, sessionID: String, state: inout FollowState,
                                     continuation: AsyncThrowingStream<HarnessEvent, Error>.Continuation) {
        for mapped in DSHEventMapper.map(event, sessionID: sessionID) {
            guard let seq = mapped.seq else { continue }
            if let delivered = state.delivered, seq <= delivered { continue }
            state.delivered = seq
            continuation.yield(mapped)
        }
    }

    private func handleRemoteEvent(_ value: JSONValue, clientID: String?, sessionID: String,
                                   mux: any DSHMuxConnection,
                                   continuation: AsyncThrowingStream<HarnessEvent, Error>.Continuation) async {
        switch value["type"]?.stringValue {
        case "emit":
            let args = value["args"]?.arrayValue ?? []
            guard args.first?.stringValue == sessionID else { return }
            switch value["event"]?.stringValue {
            case "api-session/status":
                let running = args.count > 1 ? args[1].boolValue ?? false : false
                continuation.yield(HarnessEvent(seq: nil, time: Date(), kind: .sessionStatus(running ? "running" : "idle")))
            case "api-session/error":
                let message = args.count > 1 ? args[1].stringValue ?? "" : ""
                continuation.yield(HarnessEvent(seq: nil, time: Date(), kind: .sessionStatus("error: \(message)")))
            default:
                break
            }
        case "waterfall":
            // Requests of other sessions stay pending for the clients that follow them.
            guard value["agentId"]?.stringValue == sessionID, let eventID = value["eventId"]?.stringValue,
                  let clientID else { return }
            let request = value["request"] ?? .null
            switch value["event"]?.stringValue {
            case "approval/request":
                remember(eventID, PendingRequest(clientID: clientID, sessionID: sessionID, questions: nil))
                let tool = request["toolName"]?.stringValue ?? "tool"
                continuation.yield(HarnessEvent(seq: nil, time: Date(), kind: .permissionRequested(
                    HarnessPermissionRequest(requestID: eventID, tool: tool,
                                             summary: request["reason"]?.stringValue ?? "Allow \(tool)?",
                                             risk: .sideEffect))))
            case "user-questions/request":
                let questions = request["questions"] ?? .array([])
                remember(eventID, PendingRequest(clientID: clientID, sessionID: sessionID, questions: questions))
                let items = questions.arrayValue ?? []
                let prompt = items.compactMap { $0["question"]?.stringValue }.joined(separator: "\n")
                let options = (items.first?["options"]?.arrayValue ?? []).compactMap { $0["label"]?.stringValue }
                continuation.yield(HarnessEvent(seq: nil, time: Date(), kind: .questionRequested(
                    HarnessQuestion(requestID: eventID, prompt: prompt, options: options, questions: items.map {
                        HarnessQuestionItem(id: $0["id"]?.stringValue ?? "",
                                            prompt: $0["question"]?.stringValue ?? "",
                                            options: ($0["options"]?.arrayValue ?? []).compactMap { $0["label"]?.stringValue },
                                            multiple: $0["multiSelect"]?.boolValue ?? false)
                    }))))
            default:
                // Not ours to answer: let the next listener handle it.
                _ = try? await transport.call("$events/result", args: .object([
                    "clientId": .string(clientID), "eventId": .string(eventID),
                    "outcome": .object(["kind": .string("next")]),
                ]))
            }
        case "cancel":
            guard let eventID = value["eventId"]?.stringValue, pending[eventID] != nil else { return }
            forget(eventID)
            continuation.yield(HarnessEvent(seq: nil, time: Date(), kind: .sessionStatus("permission.resolved \(eventID)")))
        default:
            break
        }
    }
}
