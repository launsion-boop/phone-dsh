// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHController: execution authority.
//
// PLAN §2.4/§2.5 (D15) and spec/v1/handoff.md §1/§2/§5. The fence is
// `{owner, generation, wal_seq}`; a transfer adds one to the generation and
// never lowers `wal_seq`. Handoff mints a fresh 128-bit reclaim token and keeps
// only its SHA-256 on disk; the plaintext token is returned once to the caller
// and must never be persisted, logged or put in a URL.

import Foundation
import PhoneDSHLog
import PhoneDSHWire

/// The result of a fence CAS: the new authority and the reclaim credential.
public struct ReclaimGrant: Equatable, Sendable {
    public var fence: FenceToken
    /// 32 lowercase hex characters; never persisted.
    public var reclaimToken: String

    public init(fence: FenceToken, reclaimToken: String) {
        self.fence = fence
        self.reclaimToken = reclaimToken
    }
}

/// Non-secret evidence that a generation CAS may have taken effect.
///
/// It is written before `POST /v1/handoff/fence` and cleared only by a definite
/// CAS rejection or by persisting the remote/reclaimed fence. It never carries
/// a reclaim token (handoff.md §2/§5) and never lives in the WAL, a workspace
/// file or a log.
public struct HandoffAuthorityIntent: Codable, Equatable, Sendable {
    public var version: Int
    public var expectedGeneration: UInt64
    public var walSeq: UInt64
    public var endpoint: String
    public var recordedAtMilliseconds: Int64
    /// Set only after a definite pre-state CAS rejection (`409 fence_conflict`
    /// or `401`). A marked record is durable proof that the remote changed
    /// nothing, so a reset/new process may clear it and boot locally. It is
    /// never set for a transport/`5xx`/malformed outcome, where the remote may
    /// own generation + 1. Absent on the pre-CAS record and on older files.
    public var definiteRejection: Bool?

    public init(version: Int = 1, expectedGeneration: UInt64, walSeq: UInt64,
                endpoint: String, recordedAtMilliseconds: Int64,
                definiteRejection: Bool? = nil) {
        self.version = version
        self.expectedGeneration = expectedGeneration
        self.walSeq = walSeq
        self.endpoint = endpoint
        self.recordedAtMilliseconds = recordedAtMilliseconds
        self.definiteRejection = definiteRejection
    }

    /// `true` only for the durable definite-rejection form.
    public var isDefiniteRejection: Bool { definiteRejection == true }

    enum CodingKeys: String, CodingKey {
        case version
        case expectedGeneration = "expected_generation"
        case walSeq = "wal_seq"
        case endpoint
        case recordedAtMilliseconds = "recorded_at_ms"
        case definiteRejection = "definite_rejection"
    }
}

/// Errors of ``FenceAuthority``.
public enum FenceAuthorityError: Error, Equatable, Sendable {
    case staleGeneration(current: UInt64, presented: UInt64)
    case ownerMismatch(current: String, presented: String)
    case walSeqRegression(current: UInt64, presented: UInt64)
    case invalidReclaimToken
    case invalidOwner(String)
    case corruptRecord(String)
    /// A previous generation CAS is still unresolved. The caller must not
    /// overwrite it with another handoff or reopen local admission.
    case handoffAuthorityUncertain
}

/// Result of clearing a persisted definite-rejection marker.
///
/// The caller must not treat "the file is gone or is still a definite marker"
/// and "another host replaced it with an unresolved intent" as the same
/// outcome: the second case must keep local admission closed.
public enum HandoffIntentCleanupOutcome: Equatable, Sendable {
    /// No intent exists after the operation.
    case noIntent
    /// A definite-rejection marker was removed.
    case definiteRejectionRemoved
    /// The file holds an unresolved (non-rejection) intent and was not cleared.
    case unmarkedIntentPresent
}

/// Persisted `fence.json`. The reclaim token is stored only as a SHA-256
/// digest; `reclaimed` makes a repeated reclaim with the same token idempotent
/// (handoff.md §5: the remote caches the response, the phone applies it once).
struct PersistedFence: Codable, Equatable {
    var version: Int
    var fence: Fence
    var reclaimTokenSHA256: String?
    var reclaimed: Bool?

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case fence
        case reclaimTokenSHA256 = "reclaim_token_sha256"
        case reclaimed
    }
}

/// Issues, validates, hands off and reclaims the phone's fence token.
public actor FenceAuthority {
    /// Workspace root, `Library/xl/<workspace_id>/`.
    public nonisolated let root: URL
    /// The current authority.
    public private(set) var current: FenceToken
    /// SHA-256 of the outstanding reclaim token, when one was minted.
    public private(set) var reclaimTokenDigest: String?

    private let fenceURL: URL
    private let authorityIntentURL: URL
    private var reclaimed = false
    /// Non-secret CAS evidence. Present means a previous handoff may have
    /// installed the remote authority even when the local fence still says
    /// `phone`; admission must stay closed until a token-based reclaim or a
    /// manual recovery proves otherwise.
    public private(set) var handoffAuthorityIntent: HandoffAuthorityIntent?
    /// `true` only when this process observed a definite CAS rejection but the
    /// durable `definite_rejection` rewrite failed. The in-memory record still
    /// proves the remote changed nothing, so the current process may clean the
    /// stale unmarked intent and reset; a new process trusts only the file.
    private var definiteRejectionWriteFailed = false

    /// Whether a definite rejection is held only in memory because its durable
    /// rewrite failed. The facade uses this to keep a confirmed 409 from
    /// becoming a permanent reset lockout in the same process.
    public var hasUnsavedDefiniteRejectionProof: Bool {
        definiteRejectionWriteFailed && handoffAuthorityIntent?.isDefiniteRejection == true
    }

    /// Loads `<root>/fence.json` or issues the initial `{owner, generation,
    /// wal_seq}` record (handoff.md §2: a fresh pairing is generation 0).
    public init(root: URL, owner: String = "phone",
                generation: UInt64 = 0, walSeq: UInt64 = 0) throws {
        self.root = root
        self.fenceURL = root.appendingPathComponent("fence.json")
        self.authorityIntentURL = root.appendingPathComponent("handoff-intent.json")
        self.handoffAuthorityIntent = try Self.loadHandoffAuthorityIntent(root: root)
        if let persisted = try ControllerFileStore.readJSON(PersistedFence.self,
                                                            from: fenceURL),
           persisted.version == 1 {
            let token = FenceToken(owner: persisted.fence.owner,
                                   generation: persisted.fence.generation,
                                   walSeq: persisted.fence.walSeq)
            try Self.validateOwner(token.owner)
            self.current = token
            self.reclaimTokenDigest = persisted.reclaimTokenSHA256
            self.reclaimed = persisted.reclaimed ?? false
        } else {
            try Self.validateOwner(owner)
            self.current = FenceToken(owner: owner, generation: generation,
                                      walSeq: walSeq)
            try Self.persist(current, digest: nil, reclaimed: false, to: fenceURL)
        }
    }

    /// Reads the non-secret CAS evidence without opening or creating a fence.
    public static func loadHandoffAuthorityIntent(root: URL) throws
        -> HandoffAuthorityIntent? {
        let url = root.appendingPathComponent("handoff-intent.json")
        guard ControllerFileStore.exists(url) else { return nil }
        guard let record = try ControllerFileStore.readJSON(
            HandoffAuthorityIntent.self, from: url),
              record.version == 1 else {
            throw FenceAuthorityError.corruptRecord(
                "handoff-intent.json has an unsupported version")
        }
        return record
    }

    // MARK: - Validation

    /// Validates a presented fence. The generation must equal the current
    /// generation; a lower (or higher) generation is stale authority.
    public func validate(_ fence: Fence) throws {
        try validate(FenceToken(owner: fence.owner, generation: fence.generation,
                                walSeq: fence.walSeq))
    }

    /// Validates a token against the current authority (D15, channel.md
    /// §4.1): a HELLO whose generation is not the current one or whose owner
    /// differs is `FENCE_STALE`.
    public func validate(_ token: FenceToken) throws {
        guard token.generation == current.generation else {
            throw FenceAuthorityError.staleGeneration(current: current.generation,
                                                      presented: token.generation)
        }
        guard token.owner == current.owner else {
            throw FenceAuthorityError.ownerMismatch(current: current.owner,
                                                    presented: token.owner)
        }
    }

    /// Builds the "lease check" of budgets.md §2 `Backoff -> Running`.
    ///
    /// The facade supplies the fence presented by the active connection (the
    /// last accepted HELLO/FENCE, or a fresh remote authority read). The
    /// returned closure runs the real ``validate(_:)`` against the persisted
    /// authority and is injected as `HostStateMachine(leaseVerifier:)`; a stale
    /// generation keeps admission closed instead of reopening it from Backoff.
    public func backoffLeaseVerifier(
        presented: @escaping @Sendable () async -> Fence
    ) -> @Sendable () async throws -> Bool {
        {
            try await self.validate(presented())
            return true
        }
    }

    /// The wire form of the current authority for HELLO/FENCE frames.
    public func wireFence() -> Fence {
        Fence(owner: current.owner, generation: current.generation,
              walSeq: current.walSeq)
    }

    // MARK: - Issuing and replication position

    /// Issues the next generation to `owner`, persists it and returns it.
    public func issue(owner: String, walSeq: UInt64) throws -> FenceToken {
        try Self.validateOwner(owner)
        try requireNonDecreasing(walSeq)
        let next = FenceToken(owner: owner, generation: current.generation + 1,
                              walSeq: walSeq)
        try install(next, digest: nil, reclaimed: false)
        return next
    }

    /// Records the replication watermark without changing the generation.
    /// `wal_seq` never decreases (handoff.md §1).
    @discardableResult
    public func recordWalSeq(_ walSeq: UInt64) throws -> FenceToken {
        try requireNonDecreasing(walSeq)
        let updated = FenceToken(owner: current.owner,
                                 generation: current.generation, walSeq: walSeq)
        try install(updated, digest: reclaimTokenDigest, reclaimed: reclaimed)
        return updated
    }

    // MARK: - Handoff and reclaim

    /// Persists non-secret "authority may now be remote" evidence before the
    /// generation CAS is sent. A second unresolved handoff is refused: the
    /// caller must reclaim or recover manually first.
    public func markHandoffAuthorityUncertain(expectedGeneration: UInt64,
                                             walSeq: UInt64,
                                             endpoint: String) throws {
        if let existing = handoffAuthorityIntent,
           !existing.isDefiniteRejection {
            guard existing.expectedGeneration == expectedGeneration,
                  existing.walSeq == walSeq,
                  existing.endpoint == endpoint else {
                throw FenceAuthorityError.handoffAuthorityUncertain
            }
            return
        }
        // A definite-rejection marker from an earlier attempt is not a fence
        // for this CAS. Replace it with a fresh unresolved intent: if the file
        // write fails, no request is sent; if it succeeds, a lost response is
        // once again treated as uncertain (never as a proven rejection).
        let intent = HandoffAuthorityIntent(
            expectedGeneration: expectedGeneration,
            walSeq: walSeq,
            endpoint: endpoint,
            recordedAtMilliseconds: Date().millisecondsSinceEpoch)
        let data = try ControllerFileStore.encode(intent)
        do {
            try ControllerFileStore.writeAtomic(data, to: authorityIntentURL)
        } catch {
            throw FenceAuthorityError.corruptRecord(
                "cannot persist handoff-intent.json")
        }
        handoffAuthorityIntent = intent
        definiteRejectionWriteFailed = false
    }

    /// Rewrites the pre-CAS evidence as a durable definite rejection before
    /// the caller regains control. The file keeps no token. `409 fence_conflict`
    /// (and a pre-request `401`/cleartext refusal) proves the remote changed
    /// nothing, so even if a later removal fails, a reset/new process can
    /// recognise the marker and boot locally instead of staying locked out.
    /// If this rewrite itself fails, the in-process definite outcome is kept:
    /// the current process can still remove the unmarked intent and reset; a
    /// new process remains fail-closed on the unmarked file.
    public func markHandoffDefinitelyRejected() throws {
        guard let existing = handoffAuthorityIntent else { return }
        if existing.isDefiniteRejection && !definiteRejectionWriteFailed { return }
        var rejected = existing
        rejected.definiteRejection = true
        let data = try ControllerFileStore.encode(rejected)
        do {
            try ControllerFileStore.writeAtomic(data, to: authorityIntentURL)
        } catch {
            handoffAuthorityIntent = rejected
            definiteRejectionWriteFailed = true
            throw FenceAuthorityError.corruptRecord(
                "cannot persist the definite handoff rejection evidence")
        }
        handoffAuthorityIntent = rejected
        definiteRejectionWriteFailed = false
    }

    /// Removes a definite-rejection marker left in the workspace. The persisted
    /// file is re-read first: an unresolved (non-rejection) intent must never be
    /// cleared by this path, even if memory is stale. The one exception is a
    /// definite rejection observed by this process whose durable rewrite failed
    /// (`hasUnsavedDefiniteRejectionProof`): that is still proof the remote
    /// changed nothing, so the stale unmarked intent may be removed.
    @discardableResult
    public func clearDefinitelyRejectedHandoffIntent()
        throws -> HandoffIntentCleanupOutcome {
        let unsavedProof = hasUnsavedDefiniteRejectionProof
        let persisted: HandoffAuthorityIntent?
        do {
            persisted = try Self.loadHandoffAuthorityIntent(root: root)
        } catch {
            guard unsavedProof else {
                throw FenceAuthorityError.corruptRecord(
                    "cannot read handoff-intent.json")
            }
            try Self.removeHandoffAuthorityIntent(root: root)
            handoffAuthorityIntent = nil
            definiteRejectionWriteFailed = false
            return .definiteRejectionRemoved
        }
        guard let persisted else {
            handoffAuthorityIntent = nil
            definiteRejectionWriteFailed = false
            return .noIntent
        }
        guard persisted.isDefiniteRejection || unsavedProof else {
            return .unmarkedIntentPresent
        }
        try Self.removeHandoffAuthorityIntent(root: root)
        handoffAuthorityIntent = nil
        definiteRejectionWriteFailed = false
        return .definiteRejectionRemoved
    }

    /// Static form for the pre-runtime `beginStart()` guard. It never clears an
    /// unresolved intent and reports that case so the caller can fail closed
    /// even if another host wrote a fresh intent after the marker was read.
    @discardableResult
    public static func clearDefinitelyRejectedHandoffIntent(root: URL) throws
        -> HandoffIntentCleanupOutcome {
        guard let persisted = try loadHandoffAuthorityIntent(root: root) else {
            return .noIntent
        }
        guard persisted.isDefiniteRejection else {
            return .unmarkedIntentPresent
        }
        try removeHandoffAuthorityIntent(root: root)
        return .definiteRejectionRemoved
    }

    private static func removeHandoffAuthorityIntent(root: URL) throws {
        do {
            try ControllerFileStore.removeIfExists(
                root.appendingPathComponent("handoff-intent.json"))
        } catch {
            throw FenceAuthorityError.corruptRecord(
                "cannot clear handoff-intent.json")
        }
    }

    /// Clears CAS evidence only when the caller can prove the remote did not
    /// acquire authority (a definite `409 fence_conflict`/`401`). The
    /// coordinator uses ``markHandoffDefinitelyRejected()`` first so a removal
    /// failure cannot misclassify a proven rejection as unresolved.
    public func clearHandoffAuthorityUncertain() throws {
        guard handoffAuthorityIntent != nil else { return }
        do {
            try ControllerFileStore.removeIfExists(authorityIntentURL)
        } catch {
            throw FenceAuthorityError.corruptRecord(
                "cannot clear handoff-intent.json")
        }
        handoffAuthorityIntent = nil
        definiteRejectionWriteFailed = false
    }

    /// Records the remote fence returned by the CAS. This is only called after
    /// the reclaim token was durably stored in the App's secure vault.
    public func recordRemoteFence(_ fence: Fence) throws {
        guard fence.owner == "remote" else {
            throw FenceAuthorityError.ownerMismatch(current: current.owner,
                                                    presented: fence.owner)
        }
        guard fence.generation == current.generation + 1 else {
            throw FenceAuthorityError.staleGeneration(current: current.generation,
                                                      presented: fence.generation)
        }
        guard fence.walSeq >= current.walSeq else {
            throw FenceAuthorityError.walSeqRegression(current: current.walSeq,
                                                       presented: fence.walSeq)
        }
        let next = FenceToken(owner: fence.owner, generation: fence.generation,
                              walSeq: fence.walSeq)
        try install(next, digest: nil, reclaimed: false)
        try clearHandoffAuthorityUncertain()
    }

    /// Installs the phone fence returned by a successful reclaim and clears the
    /// CAS evidence. Idempotent when the reclaimed generation is already
    /// installed; a later local `wal_seq` advance at the same generation is
    /// still the same reclaimed authority and must not be rolled back.
    public func installReclaimedFence(_ fence: Fence) throws {
        guard fence.owner == "phone" else {
            throw FenceAuthorityError.ownerMismatch(current: current.owner,
                                                    presented: fence.owner)
        }
        if current.owner == fence.owner,
           current.generation == fence.generation,
           current.walSeq >= fence.walSeq {
            try clearHandoffAuthorityUncertain()
            return
        }
        guard fence.generation == current.generation + 1 else {
            throw FenceAuthorityError.staleGeneration(current: current.generation,
                                                      presented: fence.generation)
        }
        guard fence.walSeq >= current.walSeq else {
            throw FenceAuthorityError.walSeqRegression(current: current.walSeq,
                                                       presented: fence.walSeq)
        }
        let next = FenceToken(owner: fence.owner, generation: fence.generation,
                              walSeq: fence.walSeq)
        try install(next, digest: nil, reclaimed: false)
        try clearHandoffAuthorityUncertain()
    }

    /// Hands authority to `owner` (normally `remote`) at generation + 1 and
    /// mints a fresh 128-bit reclaim token. Only the token digest is stored.
    public func handOff(to owner: String, walSeq: UInt64) throws -> ReclaimGrant {
        try Self.validateOwner(owner)
        try requireNonDecreasing(walSeq)
        let token = Self.randomReclaimToken()
        let digest = SHA256.hash(Data(token.utf8))
        let next = FenceToken(owner: owner, generation: current.generation + 1,
                              walSeq: walSeq)
        try install(next, digest: digest, reclaimed: false)
        return ReclaimGrant(fence: next, reclaimToken: token)
    }

    /// Reclaims authority with the token returned by `handOff`. The new fence
    /// is `{owner, generation + 1, walSeq}` and is persisted. A repeated call
    /// with the same token after a successful reclaim returns the same fence
    /// instead of advancing the generation again (idempotent apply).
    public func reclaim(token: String, owner: String = "phone",
                        walSeq: UInt64) throws -> FenceToken {
        try Self.validateOwner(owner)
        try requireNonDecreasing(walSeq)
        guard ControllerHex.isLowercaseHex(token, count: 32),
              let digest = reclaimTokenDigest else {
            throw FenceAuthorityError.invalidReclaimToken
        }
        guard ControllerHex.equalsConstantTime(digest, SHA256.hash(Data(token.utf8))) else {
            throw FenceAuthorityError.invalidReclaimToken
        }
        if reclaimed {
            return current
        }
        let next = FenceToken(owner: owner, generation: current.generation + 1,
                              walSeq: walSeq)
        try install(next, digest: digest, reclaimed: true)
        return next
    }

    /// `true` when a reclaim token was minted and not yet used.
    public var isReclaimOutstanding: Bool {
        reclaimTokenDigest != nil && !reclaimed
    }

    // MARK: - Internals

    private func requireNonDecreasing(_ walSeq: UInt64) throws {
        guard walSeq >= current.walSeq else {
            throw FenceAuthorityError.walSeqRegression(current: current.walSeq,
                                                       presented: walSeq)
        }
    }

    private func install(_ token: FenceToken, digest: String?,
                         reclaimed: Bool) throws {
        try Self.persist(token, digest: digest, reclaimed: reclaimed, to: fenceURL)
        current = token
        reclaimTokenDigest = digest
        self.reclaimed = reclaimed
    }

    private static func validateOwner(_ owner: String) throws {
        guard WireValidation.isValidFenceOwner(owner) else {
            throw FenceAuthorityError.invalidOwner(owner)
        }
    }

    private static func persist(_ token: FenceToken, digest: String?,
                                reclaimed: Bool, to url: URL) throws {
        let record = PersistedFence(
            version: 1,
            fence: Fence(owner: token.owner, generation: token.generation,
                         walSeq: token.walSeq),
            reclaimTokenSHA256: digest, reclaimed: reclaimed ? true : nil)
        let data = try ControllerFileStore.encode(record)
        do {
            try ControllerFileStore.writeAtomic(data, to: url)
        } catch {
            throw FenceAuthorityError.corruptRecord("cannot persist fence.json")
        }
    }

    /// 128 random bits from the system CSPRNG, lowercase hex.
    static func randomReclaimToken() -> String {
        var generator = SystemRandomNumberGenerator()
        var bytes = [UInt8]()
        bytes.reserveCapacity(16)
        for _ in 0..<16 {
            bytes.append(UInt8.random(in: UInt8.min...UInt8.max, using: &generator))
        }
        return ControllerHex.encode(bytes)
    }
}
