// SPDX-License-Identifier: MIT

import Foundation

public struct BotDeviceReplySource: Sendable, Equatable {
    public let envelope: BotDeviceEnvelope
    public let transport: BotDeviceTransport
    public let heldItemID: String
    public let mainSessionID: String?
    public let botID: String
}

public struct BotDeviceReplyStaged: Sendable, Equatable {
    public let effectKey: String
    public let reply: BotDeviceReply
    public let duplicate: Bool
}

/// Resolves and stages a reply to the fact that triggered this turn. The model
/// supplies only text: the source device, epoch, transport and mapped transport
/// session always come from the currently staged `device-event` held items.
public enum BotDeviceReplyTool {
    public static let toolName = "ReplyToDevice"

    public static func resolveSource(store: SQLiteDomainStore,
                                     botID: String) async throws -> BotDeviceReplySource {
        let inbox = WakeInbox(store: SQLiteWakeInboxStore(domainStore: store, botId: botID))
        let staged = try await inbox.items().filter {
            $0.kind == "device-event" && $0.state == .staged
        }
        guard !staged.isEmpty else {
            throw BotMCPError.invalidRequest(
                "ReplyToDevice is only available while answering a staged device message")
        }
        let sources = Set(staged.map { "\($0.deviceID ?? "")\u{1F}\($0.deviceEpoch ?? 0)" })
        guard sources.count == 1, let group = staged.first else {
            throw BotMCPError.invalidRequest(
                "ReplyToDevice is ambiguous: this turn has more than one source device")
        }
        let ordered = staged.filter {
            ($0.deviceID ?? "") == (group.deviceID ?? "")
                && ($0.deviceEpoch ?? 0) == (group.deviceEpoch ?? 0)
        }.sorted { ($0.deviceSeq ?? 0, $0.id) < ($1.deviceSeq ?? 0, $1.id) }
        for item in ordered {
            guard let eventID = item.requestId,
                  let event = try await store.event(withId: eventID),
                  event.type == "device.event",
                  event.principal.botId == botID,
                  let rawTransport = event.data["transport"]?.stringValue,
                  let transport = BotDeviceTransport(rawValue: rawTransport),
                  let envelopeValue = event.data["envelope"],
                  let rawEnvelope = try? envelopeValue.encoded(),
                  let envelope = try? BotDeviceEnvelope(data: rawEnvelope),
                  item.deviceID == envelope.deviceID,
                  item.transport == transport.rawValue,
                  (item.deviceEpoch ?? 0) == envelope.epoch,
                  item.deviceSeq == envelope.seq else {
                continue
            }
            return BotDeviceReplySource(
                envelope: envelope, transport: transport, heldItemID: item.id,
                mainSessionID: event.principal.sessionId, botID: botID)
        }
        throw BotMCPError.invalidRequest(
            "ReplyToDevice source no longer matches a committed device event")
    }

    public static func requiredEffect(for source: BotDeviceReplySource) -> BotToolEffect {
        let resource = "device:\(source.transport.rawValue):\(source.envelope.deviceID)"
        return BotToolEffect(
            tool: toolName, operation: "device.reply", resource: resource,
            target: source.envelope.sessionID, mutability: .externalSend, policy: .ask,
            label: "Reply to source device",
            detail: "Replies only through the host-mapped source device transport session.",
            execution: "device-reply")
    }

    /// The concrete effect is resolved from server-side staged state before the
    /// generic authorization step; the tool then executes that same decision.
    public struct Authorization: Sendable {
        public let source: BotDeviceReplySource
        public let decision: BotExecutionDecision

        public init(source: BotDeviceReplySource, decision: BotExecutionDecision) {
            self.source = source
            self.decision = decision
        }
    }

    /// Used by the approval path before the tool call; [] means the source is
    /// not resolvable and the later execution will fail closed.
    public static func requiredEffects(store: SQLiteDomainStore, botID: String) async -> [BotToolEffect] {
        guard let source = try? await resolveSource(store: store, botID: botID) else { return [] }
        return [requiredEffect(for: source)]
    }

    /// Validates the model-supplied arguments before any source resolution or
    /// authorization, so an invalid call keeps its `invalid_arguments` code
    /// instead of surfacing as an authorization failure.
    @discardableResult
    public static func validatedMessage(_ arguments: BotJSONValue) throws -> String {
        guard case .object(let args) = arguments,
              Set(args.keys).isSubset(of: ["message"]),
              case .string(let message)? = args["message"],
              !message.isEmpty, message.count <= 1_000 else {
            throw BotMCPError.invalidRequest(
                "ReplyToDevice requires only a non-empty message of at most 1000 characters")
        }
        return message
    }

    public static func reply(arguments: BotJSONValue, call: BotResolvedToolCall,
                             store: SQLiteDomainStore,
                             authorizer: BotExecutionAuthorizer,
                             authorization: Authorization? = nil) async throws -> BotJSONValue {
        let message = try validatedMessage(arguments)
        let source: BotDeviceReplySource
        let decision: BotExecutionDecision
        if let authorization {
            // The caller already resolved the concrete source and authorized
            // this exact effect through the generic classify → authorize path.
            source = authorization.source
            decision = authorization.decision
        } else {
            source = try await resolveSource(store: store, botID: call.principal.botId)
            if let mainSessionID = source.mainSessionID, call.sessionId != mainSessionID {
                throw BotMCPError.unauthorized
            }
            let effect = requiredEffect(for: source)
            let digest = try BotArgumentsDigest.string(for: arguments)
            decision = await authorizer.authorizeExecution(
                principal: BotExecutionPrincipal(gateway: call.principal), effects: [effect],
                source: "bot-device-reply", argsDigest: digest)
            guard decision.allowed else {
                throw BotMCPError.unavailable("device-reply-\(decision.reason)")
            }
        }
        if let mainSessionID = source.mainSessionID, call.sessionId != mainSessionID {
            throw BotMCPError.unauthorized
        }
        let reply = try BotDeviceReply(
            source: source.envelope, transport: source.transport,
            sessionID: source.envelope.sessionID, text: message)
        let staged = try await BotDeviceReplyStager.shared.stage(
            reply, authorized: decision, store: store, now: Int64(Date().timeIntervalSince1970 * 1_000))
        return .object([
            "ok": .bool(true),
            "queued": .bool(true),
            "deviceID": .string(staged.reply.envelope.deviceID),
            "seq": .number(Double(staged.reply.envelope.seq)),
        ])
    }
}

/// Serializes downlink seq allocation across all ingress/tool callers, then
/// persists the staged event before enqueueing the effect.
public actor BotDeviceReplyStager {
    public static let shared = BotDeviceReplyStager()

    public func stage(_ reply: BotDeviceReply, authorized: BotExecutionDecision,
                      store: SQLiteDomainStore, now: Int64) async throws -> BotDeviceReplyStaged {
        guard let sourceEvent = try await store.event(withId: reply.effectKey),
              sourceEvent.type == "device.event",
              sourceEvent.principal.botId == authorized.principal.botId,
              sourceEvent.principal.sessionId == authorized.principal.sessionId,
              let rawTransport = sourceEvent.data["transport"]?.stringValue,
              let sourceTransport = BotDeviceTransport(rawValue: rawTransport),
              sourceTransport == reply.transport,
              let envelopeValue = sourceEvent.data["envelope"],
              let rawEnvelope = try? envelopeValue.encoded(),
              let sourceEnvelope = try? BotDeviceEnvelope(data: rawEnvelope),
              sourceEnvelope.msgID == reply.sourceMessageID,
              sourceEnvelope.deviceID == reply.envelope.deviceID,
              sourceEnvelope.epoch == reply.envelope.epoch,
              sourceEnvelope.sessionID == reply.envelope.sessionID else {
            throw BotDeviceReplyError.invalidSource("device reply source does not match device.event")
        }
        let required = BotDeviceReplyService.requiredEffect(
            for: reply, sessionID: reply.envelope.sessionID)
        let requiredResource = BotResourceNormalizer.normalize(required.resource)
        guard authorized.allowed, authorized.effects.count == 1,
              let authorizedEffect = authorized.effects.first,
              authorizedEffect.tool == required.tool,
              authorizedEffect.operation == required.operation,
              BotResourceNormalizer.normalize(authorizedEffect.resource) == requiredResource,
              authorizedEffect.target == required.target,
              authorizedEffect.mutability == .externalSend,
              authorizedEffect.policy == .ask else {
            throw BotDeviceReplyError.unauthorized
        }

        let stagedEventID = "staged:\(reply.effectKey)"
        if let existing = try await store.event(withId: stagedEventID) {
            guard let previous = Self.decodeReply(existing) else {
                throw SQLiteDomainStoreError.corrupted("invalid staged device reply")
            }
            guard previous.transport == reply.transport,
                  previous.sourceMessageID == reply.sourceMessageID,
                  previous.envelope.deviceID == reply.envelope.deviceID,
                  previous.envelope.epoch == reply.envelope.epoch,
                  previous.envelope.sessionID == reply.envelope.sessionID,
                  previous.envelope.text == reply.envelope.text else {
                throw BotDeviceReplyError.payloadConflict
            }
            return BotDeviceReplyStaged(
                effectKey: previous.effectKey, reply: previous, duplicate: true)
        }

        let maxSeq = try await latestDownSeq(
            store: store, deviceID: reply.envelope.deviceID, transport: reply.transport)
        let seq: Int64
        if let maxSeq {
            guard maxSeq < Int64.max else {
                throw BotDeviceReplyError.sequence("downlink sequence exhausted")
            }
            seq = max(reply.envelope.seq, maxSeq + 1)
        } else {
            seq = max(reply.envelope.seq, 0)
        }
        guard seq >= 0, seq < Int64.max else {
            throw BotDeviceReplyError.sequence("invalid downlink sequence")
        }
        let final = try reply.replacingDownSeq(seq)
        let event = BotEvent(
            type: "device.reply.staged", eventId: stagedEventID, time: now,
            origin: .local(source: "device:\(final.transport.rawValue):\(final.envelope.deviceID)"),
            traceId: final.effectKey,
            principal: BotPrincipal(
                botId: authorized.principal.botId, sessionId: authorized.principal.sessionId,
                kind: "device"),
            causationId: nil, correlationId: final.effectKey,
            data: .object([
                "envelope": try final.envelope.jsonValue,
                "transport": .string(final.transport.rawValue),
                "sourceMessageID": .string(final.sourceMessageID),
            ]))
        _ = try await store.append(event)
        if try await store.effect(final.effectKey) == nil {
            _ = try await store.enqueue(try BotDeviceReplyService.effect(final))
        }
        return BotDeviceReplyStaged(effectKey: final.effectKey, reply: final, duplicate: false)
    }

    private func latestDownSeq(store: SQLiteDomainStore, deviceID: String,
                               transport: BotDeviceTransport) async throws -> Int64? {
        var cursor = 0
        var latest: Int64?
        while true {
            let events = try await store.events(after: cursor, limit: 500)
            for event in events where event.type == "device.reply.staged" {
                guard let reply = Self.decodeReply(event) else { continue }
                guard reply.envelope.deviceID == deviceID, reply.transport == transport else { continue }
                latest = max(latest ?? 0, reply.envelope.seq)
            }
            guard events.count == 500, let last = events.last?.commitSeq else { break }
            cursor = last
        }
        return latest
    }

    private static func decodeReply(_ event: BotEvent) -> BotDeviceReply? {
        guard let data = try? event.data["envelope"]?.encoded(),
              let envelope = try? BotDeviceEnvelope(data: data),
              let rawTransport = event.data["transport"]?.stringValue,
              let transport = BotDeviceTransport(rawValue: rawTransport),
              let sourceMessageID = event.data["sourceMessageID"]?.stringValue else {
            return nil
        }
        return BotDeviceReply(envelope: envelope, transport: transport,
                              sourceMessageID: sourceMessageID)
    }
}
