// SPDX-License-Identifier: MIT
// Pure decisions of the external admission journal (P06;
// spec/host/v1/external-admission.md §1–§4). The journal actor calls exactly
// these functions; the shared vectors in
// spec/host/v1/fixtures/external-admission-v1.json run through them too.

import Foundation
import CryptoKit

/// What dispatch ordering needs from a record.
public protocol ExternalAdmissionSchedulable {
    var admissionId: String { get }
    var stage: ExternalAdmissionStage { get }
    var admittedAtMs: Int64 { get }
    var expiresAtMs: Int64 { get }
    var nextAttemptAtMs: Int64? { get }
}

extension ExternalAdmissionRecord: ExternalAdmissionSchedulable {}

/// The scheduling view of a record (the `order` vectors carry only these members).
public struct ExternalAdmissionDispatchCandidate: ExternalAdmissionSchedulable, Equatable, Sendable {
    public var admissionId: String
    public var stage: ExternalAdmissionStage
    public var admittedAtMs: Int64
    public var expiresAtMs: Int64
    public var nextAttemptAtMs: Int64?

    public init(admissionId: String, stage: ExternalAdmissionStage, admittedAtMs: Int64,
                expiresAtMs: Int64, nextAttemptAtMs: Int64? = nil) {
        self.admissionId = admissionId
        self.stage = stage
        self.admittedAtMs = admittedAtMs
        self.expiresAtMs = expiresAtMs
        self.nextAttemptAtMs = nextAttemptAtMs
    }
}

public enum ExternalAdmissionRetryOutcome: Equatable, Sendable {
    /// Back to `admitted` with the incremented count and the earliest next attempt.
    case retry(attempts: Int, nextAttemptAtMs: Int64)
    /// `attempts` would exceed the bound: `failed` with reason `retry_exhausted`.
    case exhausted
}

public enum ExternalAdmissionSweepAction: String, Equatable, Sendable {
    case keep
    case expire
    case delete
    case unknown
}

public enum ExternalAdmissionPolicy {
    public static let retryExhaustedReason = "retry_exhausted"
    public static let expiredReason = "expired"
    public static let accountSignedOutReason = "account_signed_out"

    /// A record is dispatched only for the principal that is present: `local`
    /// always is, an `account:` principal only while it is the signed-in
    /// account (external-admission.md §4). An `admitted` record of any other
    /// account waits; a `dispatching` one is past that check and is redone (§3).
    public static func isWaitingForAccount(_ record: ExternalAdmissionRecord,
                                           signedInPrincipal: String?) -> Bool {
        guard record.principal != "local", record.stage == .admitted else { return false }
        return record.principal != signedInPrincipal
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// `lowercase_hex(SHA-256(principal ‖ 0x00 ‖ source.kind ‖ 0x00 ‖ source.id ‖ 0x00 ‖ sourceRequestId))`
    public static func admissionId(principal: String, source: ExternalAdmissionSource,
                                   sourceRequestId: String) -> String {
        var bytes = Data()
        for (index, part) in [principal, source.kind.rawValue, source.id, sourceRequestId].enumerated() {
            if index > 0 { bytes.append(0) }
            bytes.append(contentsOf: Array(part.utf8))
        }
        return sha256Hex(bytes)
    }

    /// `lowercase_hex(SHA-256(UTF-8 text))`
    public static func contentSha256(_ text: String) -> String {
        sha256Hex(Data(text.utf8))
    }

    /// The candidate record of a request, or nil when a field breaks the
    /// schema, the UTF-8 byte bound or the TTL law (`invalid`).
    public static func candidate(for request: ExternalAdmissionRequest,
                                 nowMs: Int64) -> ExternalAdmissionRecord? {
        let record = ExternalAdmissionRecord(
            admissionId: admissionId(principal: request.principal, source: request.source,
                                     sourceRequestId: request.sourceRequestId),
            principal: request.principal, source: request.source,
            sourceRequestId: request.sourceRequestId, target: request.target,
            contentSha256: contentSha256(request.text), text: request.text,
            downstreamId: request.downstreamId, admittedAtMs: nowMs,
            expiresAtMs: request.expiresAtMs, stage: .admitted, attempts: 0)
        guard record.validationProblem() == nil else { return nil }
        guard request.text.utf8.count <= ExternalAdmissionLimits.maxTextBytes else { return nil }
        // Both operands are within 0 … 2^53−1 here, so the difference cannot overflow.
        let ttl = request.expiresAtMs - nowMs
        guard ttl >= ExternalAdmissionLimits.minTtlMs,
              ttl <= ExternalAdmissionLimits.maxTtlMs else { return nil }
        return record
    }

    /// external-admission.md §3: no other edge exists and none leaves a terminal stage.
    public static func allows(from: ExternalAdmissionStage, to: ExternalAdmissionStage) -> Bool {
        switch (from, to) {
        case (.admitted, .dispatching),
             (.dispatching, .linked),
             (.dispatching, .admitted),
             (.admitted, .expired),
             (.admitted, .cancelled),
             (.admitted, .failed),
             (.dispatching, .failed),
             (.linked, .completed),
             (.linked, .failed),
             (.linked, .unknown):
            return true
        default:
            return false
        }
    }

    /// A definite downstream failure: `attempts += 1`,
    /// `nextAttemptAtMs = now + min(3000·2^(attempts−1), 300000)`.
    public static func retry(attempts: Int, nowMs: Int64) -> ExternalAdmissionRetryOutcome {
        let next = attempts + 1
        guard next <= ExternalAdmissionLimits.maxAttempts else { return .exhausted }
        // 3000·2^7 already exceeds the cap, so the shift never grows past it.
        let delay = next > 7 ? Int64(300_000) : min(Int64(3_000) << Int64(next - 1), 300_000)
        return .retry(attempts: next, nextAttemptAtMs: nowMs + delay)
    }

    public static func sweepAction(for record: ExternalAdmissionRecord,
                                   nowMs: Int64) -> ExternalAdmissionSweepAction {
        switch record.stage {
        case .admitted:
            return nowMs >= record.expiresAtMs ? .expire : .keep
        case .dispatching:
            return .keep
        case .linked:
            return nowMs >= record.admittedAtMs + ExternalAdmissionLimits.linkedTimeoutMs
                ? .unknown : .keep
        case .completed, .failed, .expired, .cancelled, .unknown:
            guard let settledAtMs = record.settledAtMs else { return .keep }
            let limit = max(record.expiresAtMs,
                            settledAtMs + ExternalAdmissionLimits.tombstoneMs)
            return nowMs >= limit ? .delete : .keep
        }
    }

    /// Sequential FIFO by (`admittedAtMs`, `admissionId`), at most 16 per pass,
    /// skipping expired `admitted` records and records still backing off. A record
    /// that is only waiting for execution conditions (`isWaiting`: Bot unit not
    /// started, account not signed in, phone locked) is skipped and does not count
    /// toward the 16, so waiting records never starve later ones (v1.1 §4).
    public static func dispatchOrder<Item: ExternalAdmissionSchedulable>(
        _ items: [Item], nowMs: Int64,
        isWaiting: (Item) -> Bool = { _ in false }) -> [Item] {
        let ready = items.filter { item in
            guard item.stage.isPending else { return false }
            if item.stage == .admitted, nowMs >= item.expiresAtMs { return false }
            guard (item.nextAttemptAtMs ?? 0) <= nowMs else { return false }
            return !isWaiting(item)
        }
        let ordered = ready.sorted {
            if $0.admittedAtMs != $1.admittedAtMs { return $0.admittedAtMs < $1.admittedAtMs }
            return $0.admissionId < $1.admissionId
        }
        return Array(ordered.prefix(ExternalAdmissionLimits.passLimit))
    }
}

/// The downstream owner's terminal evidence for a `dsh-session` record
/// (external-admission.md §3): the authoritative history holds a user message
/// whose `source.rpcId` equals `downstreamId`, and that message's turn ended.
public enum ExternalAdmissionSettlement: Equatable, Sendable {
    case pending
    case completed
    case failed

    public static func resolve(downstreamId: String, items: [ChatItem],
                               endedTurns: Set<Int>, failedTurns: Set<Int>) -> Self {
        guard let input = items.first(where: {
            $0.kind == .user && $0.promptRequestID == downstreamId && $0.promptJournalSeq != nil
        }), let turn = input.turn else { return .pending }
        if failedTurns.contains(turn) { return .failed }
        return endedTurns.contains(turn) ? .completed : .pending
    }
}
