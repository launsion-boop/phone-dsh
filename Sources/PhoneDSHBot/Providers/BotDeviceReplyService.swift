// SPDX-License-Identifier: MIT

import Foundation

public struct BotDeviceReply: Codable, Sendable, Equatable {
    public let envelope: BotDeviceEnvelope
    public let transport: BotDeviceTransport
    public let sourceMessageID: String

    public init(source: BotDeviceEnvelope, transport: BotDeviceTransport,
                sessionID: String, text: String, downSeq: Int64 = 0) throws {
        self.envelope = try BotDeviceEnvelope(
            msgID: BotDeviceIdentifiers.downMessageID(
                deviceID: source.deviceID, epoch: source.epoch, msgID: source.msgID),
            deviceID: source.deviceID, sessionID: sessionID, dir: "down", kind: "text",
            origin: "agent", audience: "device", seq: downSeq, epoch: source.epoch, text: text)
        self.transport = transport
        self.sourceMessageID = source.msgID
    }

    public init(envelope: BotDeviceEnvelope, transport: BotDeviceTransport, sourceMessageID: String) {
        self.envelope = envelope
        self.transport = transport
        self.sourceMessageID = sourceMessageID
    }

    public var effectKey: String {
        BotDeviceIdentifiers.durableID(
            deviceID: envelope.deviceID, epoch: envelope.epoch, msgID: sourceMessageID)
    }

    func replacingDownSeq(_ seq: Int64) throws -> BotDeviceReply {
        let replaced = try BotDeviceEnvelope(
            msgID: envelope.msgID, deviceID: envelope.deviceID, sessionID: envelope.sessionID,
            dir: envelope.dir, kind: envelope.kind, origin: envelope.origin,
            audience: envelope.audience, seq: seq, epoch: envelope.epoch,
            tsMs: envelope.tsMs, text: envelope.text, audio: envelope.audio)
        return BotDeviceReply(envelope: replaced, transport: transport, sourceMessageID: sourceMessageID)
    }
}

public protocol BotDeviceReplyWriting: Sendable {
    func send(_ reply: BotDeviceReply) async throws -> String?
}

/// A transport adapter uses these classes to tell apart "confirmed not sent"
/// (safe to retry) from "may have been sent" (reconcile, never blind-resend).
public enum BotDeviceReplyWriteError: Error, Sendable, Equatable {
    case transient(String)
    case unknown(String)
}

public enum BotDeviceDownlinkReceipt: Sendable, Equatable {
    case applied(resultRef: String?)
    case notApplied
    case unknown
}

public protocol BotDeviceReceiptQuerying: Sendable {
    func receipt(for reply: BotDeviceReply) async throws -> BotDeviceDownlinkReceipt
}

public enum BotDeviceReplyError: Error, Sendable, Equatable {
    case unauthorized
    case payloadConflict
    case invalidSource(String)
    case sequence(String)
}

public struct BotDeviceReconciliationSummary: Sendable, Equatable {
    public var applied = 0
    public var retried = 0
    public var unconfirmed = 0

    public init() {}
}

public actor BotDeviceReplyService {
    public let store: SQLiteDomainStore
    private let writer: any BotDeviceReplyWriting
    private let reconciler: (any BotDeviceReceiptQuerying)?
    private let now: @Sendable () -> Int64
    private let owner: String
    private var requests: [String: BotDeviceReply] = [:]
    private var loaded = false

    public init(store: SQLiteDomainStore, writer: any BotDeviceReplyWriting,
                reconciler: (any BotDeviceReceiptQuerying)? = nil,
                now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) },
                owner: String = "bot-device-reply") {
        self.store = store
        self.writer = writer
        self.reconciler = reconciler
        self.now = now
        self.owner = owner
    }

    @discardableResult
    public func stage(_ reply: BotDeviceReply, authorized: BotExecutionDecision) async throws -> String {
        let receipt = try await BotDeviceReplyStager.shared.stage(
            reply, authorized: authorized, store: store, now: now())
        requests[receipt.effectKey] = receipt.reply
        return receipt.effectKey
    }

    public func runNext() async throws -> BotEffectState? {
        try await restore()
        let pending = try await store.effects(state: .pending)
        let failed = try await store.effects(state: .failed)
        let candidates = pending + failed
        guard let next = candidates.filter({ $0.effect.kind == "device-reply" }).sorted(by: {
            ($0.effect.notBefore ?? 0, $0.enqueuedCommitSeq, $0.effectKey)
                < ($1.effect.notBefore ?? 0, $1.enqueuedCommitSeq, $1.effectKey)
        }).first else { return nil }
        guard let lease = try await store.lease(owner: owner, now: now()) else { return nil }
        guard let leasedRecord = try await store.effect(lease.effectKey),
              leasedRecord.effect.kind == "device-reply" else { return nil }
        guard next.effectKey == lease.effectKey else { return nil }
        return try await deliver(lease)
    }

    public func deliver(_ lease: BotEffectLease) async throws -> BotEffectState {
        try await restore()
        guard let request = requests[lease.effectKey] else {
            if let record = try await store.effect(lease.effectKey),
               record.effect.kind == "device-reply" {
                try await store.fail(lease, errorClass: "permanent", reason: "device reply payload is missing")
                return .deadLetter
            }
            return .failed
        }
        do {
            guard let resultRef = try await writer.send(request) else {
                // A missing receipt is not success: the bytes may have reached
                // the device. Keep the effect for reconciliation, never ack it.
                try await store.fail(lease, errorClass: "unknown", reason: "writer returned no receipt")
                return .needsReconciliation
            }
            try await store.ack(lease, resultRef: resultRef)
            return .acked
        } catch let error as BotDeviceReplyWriteError {
            switch error {
            case .transient(let reason):
                try await store.fail(lease, errorClass: "transient", reason: reason)
                return .failed
            case .unknown(let reason):
                try await store.fail(lease, errorClass: "unknown", reason: reason)
                return .needsReconciliation
            }
        } catch {
            try await store.fail(lease, errorClass: "unknown", reason: String(describing: error))
            return .needsReconciliation
        }
    }

    /// Reconnect entry point. Applied receipts are acknowledged, definitively
    /// not-applied effects are retried, and everything else stays
    /// `needs_reconciliation` with one user-visible notice per attempt.
    @discardableResult
    public func reconcile(
        _ query: (any BotDeviceReceiptQuerying)? = nil
    ) async throws -> BotDeviceReconciliationSummary {
        try await restore()
        let query = query ?? reconciler
        var summary = BotDeviceReconciliationSummary()
        for record in try await store.effects(state: .needsReconciliation)
        where record.effect.kind == "device-reply" {
            let request = requests[record.effectKey]
            var outcome: BotDeviceDownlinkReceipt = .unknown
            if let request, let query {
                do {
                    outcome = try await query.receipt(for: request)
                } catch {
                    outcome = .unknown
                }
            }
            switch outcome {
            case .applied(let resultRef):
                do {
                    try await store.ackReconciled(
                        effectKey: record.effectKey, generation: record.generation,
                        attempt: record.attempt, resultRef: resultRef)
                    summary.applied += 1
                } catch {
                    // A concurrent ack/retry already moved the row; the next
                    // pass will see the new state.
                }
            case .notApplied:
                do {
                    try await store.retryNeedsReconciliation(record.effectKey, notBefore: now())
                    summary.retried += 1
                } catch {
                    // Same race as above; leave the row untouched.
                }
            case .unknown:
                try await recordReconciliationNotice(record, request: request)
                summary.unconfirmed += 1
            }
        }
        return summary
    }

    public func restore() async throws {
        guard !loaded else { return }
        var cursor = 0
        while true {
            let events = try await store.events(after: cursor, limit: 500)
            for event in events where event.type == "device.reply.staged" {
                guard let data = try? event.data["envelope"]?.encoded(),
                      let envelope = try? BotDeviceEnvelope(data: data),
                      let rawTransport = event.data["transport"]?.stringValue,
                      let transport = BotDeviceTransport(rawValue: rawTransport),
                      let sourceMessageID = event.data["sourceMessageID"]?.stringValue else {
                    throw SQLiteDomainStoreError.corrupted("invalid device reply projection")
                }
                let reply = BotDeviceReply(
                    envelope: envelope, transport: transport, sourceMessageID: sourceMessageID)
                requests[reply.effectKey] = reply
                if try await store.effect(reply.effectKey) == nil {
                    _ = try await store.enqueue(try Self.effect(reply))
                }
            }
            guard events.count == 500, let last = events.last?.commitSeq else { break }
            cursor = last
        }
        loaded = true
    }

    private func recordReconciliationNotice(_ record: BotEffectRecord,
                                            request: BotDeviceReply?) async throws {
        let sourceEvent = try await store.event(withId: record.effectKey)
        let botID = sourceEvent?.principal.botId
        let sessionID = sourceEvent?.principal.sessionId
        let deviceID = request?.envelope.deviceID ?? "device"
        let transport = request?.transport.rawValue ?? "unknown"
        let source = BotDeviceTransport(rawValue: transport) != nil
            ? "device:\(transport):\(deviceID)" : "comm-service"
        let eventID = "device-reconcile:\(record.effectKey):\(record.generation):\(record.attempt)"
        let text = "设备 \(deviceID) 的一条回复结果未知（可能已送达）。请先在设备上确认；确认前不会重发。"
        let event = BotEvent(
            type: "ui.notice", eventId: eventID, time: now(),
            origin: .local(source: source), traceId: eventID,
            principal: BotPrincipal(botId: botID, sessionId: sessionID, kind: "device"),
            causationId: nil, correlationId: record.effectKey,
            data: .object([
                "kind": .string("device.reconcile"),
                "tone": .string("warning"),
                "text": .string(text),
                "effectKey": .string(record.effectKey),
                "deviceID": .string(deviceID),
                "generation": .number(Double(record.generation)),
                "attempt": .number(Double(record.attempt)),
            ]))
        _ = try await store.append(event)
    }

    static func effect(_ reply: BotDeviceReply) throws -> BotEffect {
        let resource = "device:\(reply.transport.rawValue):\(reply.envelope.deviceID)"
        let digest = try BotArgumentsDigest.string(for: .object([
            "envelope": try reply.envelope.jsonValue,
            "transport": .string(reply.transport.rawValue),
        ]))
        return BotEffect(
            effectKey: reply.effectKey, kind: "device-reply", operation: "device.reply",
            target: resource, canonicalResource: resource, argsDigest: digest,
            logicalKey: reply.effectKey, idempotent: true, retryPolicy: "network-idempotent")
    }

    public static func requiredEffect(for reply: BotDeviceReply,
                                      sessionID: String) -> BotToolEffect {
        let resource = "device:\(reply.transport.rawValue):\(reply.envelope.deviceID)"
        return BotToolEffect(
            tool: "ReplyToDevice", operation: "device.reply", resource: resource,
            target: sessionID, mutability: .externalSend, policy: .ask,
            label: "Reply to source device",
            detail: "Replies only through the host-mapped source device transport session.")
    }
}
