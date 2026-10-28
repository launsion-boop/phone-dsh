// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSH: reclaim client.
//
// PLAN §2.5 (D15) and spec/v1/handoff.md §5/§6. Reclaim needs only
// the 128-bit token returned by the fence CAS: no generation is sent. The
// remote caches its response per token for 24 h, so every transport/5xx retry
// is safe and returns identical bytes. Once the returned segments are applied,
// the phone persists the new `{owner:"phone", generation, wal_seq}` fence with
// admission still closed until the lease is verified in `Recovering`.

import Foundation
import PhoneDSHController
import PhoneDSHWire

/// Result of one successful reclaim.
public struct HandoffReclaimOutcome: Equatable, Sendable {
    /// The new phone authority `{owner: phone, generation + 1, wal_seq}`.
    public var fence: Fence
    /// Highest contiguous applied mseq (equals `fence.wal_seq`).
    public var appliedMseq: UInt64
    /// Highest mseq ever allocated (D17).
    public var lastMseq: UInt64
    /// A durable epoch covers ``appliedMseq``.
    public var epochClosed: Bool
    public var mutationsApplied: Int
    public var mutationsSkipped: Int

    public init(fence: Fence, appliedMseq: UInt64, lastMseq: UInt64,
                epochClosed: Bool, mutationsApplied: Int = 0,
                mutationsSkipped: Int = 0) {
        self.fence = fence
        self.appliedMseq = appliedMseq
        self.lastMseq = lastMseq
        self.epochClosed = epochClosed
        self.mutationsApplied = mutationsApplied
        self.mutationsSkipped = mutationsSkipped
    }
}

/// Drives the return path: download, apply, install the new fence.
public actor ReclaimClient {
    private let client: HandoffClient
    private let applier: any HandoffSegmentApplying
    private let fences: any HandoffFenceStoring
    private let retryPolicy: HandoffRetryPolicy
    /// The App's secure vault (or the process-lifetime default).
    private let tokenStore: any HandoffReclaimTokenStore

    private var cachedToken: HandoffReclaimToken?
    private var installedFence: Fence?

    public init(client: HandoffClient,
                applier: any HandoffSegmentApplying,
                fences: any HandoffFenceStoring,
                retryPolicy: HandoffRetryPolicy = HandoffRetryPolicy(),
                tokenStore: any HandoffReclaimTokenStore =
                    InMemoryHandoffReclaimTokenStore()) {
        self.client = client
        self.applier = applier
        self.fences = fences
        self.retryPolicy = retryPolicy
        self.tokenStore = tokenStore
    }

    /// Remembers the token returned by the fence CAS together with the
    /// non-secret remote fence. The raw token is written only to the injected
    /// store, never to the workspace/WAL/log (handoff.md §2).
    public func store(token: String, remoteFence: Fence? = nil) async throws {
        guard HandoffHex.isLowercaseHex(token, count: 32) else {
            throw HandoffError.unauthorized
        }
        let credential = HandoffReclaimToken(
            token: token,
            remoteFence: remoteFence,
            endpoint: try client.configuration.endpointIdentity(),
            workspaceIdentifier: fences.workspaceIdentifier)
        // Keep the process-lifetime copy even if the vault write fails: the
        // remote already owns the fence, and losing the token outright would
        // leave only manual recovery. The caller still sees the vault failure.
        do {
            try await tokenStore.store(credential)
        } catch let error as HandoffError {
            cachedToken = credential
            throw error
        } catch {
            cachedToken = credential
            throw HandoffError.reclaimTokenStoreFailed(
                "cannot store the reclaim credential")
        }
        cachedToken = credential
    }

    /// `true` while a token is remembered in this process. A token loaded from
    /// a cold vault is only reflected after ``reclaimStoredToken()``.
    public var hasStoredToken: Bool { cachedToken != nil }

    /// Reclaims with the token in the App's store. Transport and `500`
    /// failures retry with exponential backoff; the remote response is cached
    /// per token, so a lost response is safe to replay.
    public func reclaimStoredToken() async throws -> HandoffReclaimOutcome {
        guard let credential = try await loadCredential() else {
            throw HandoffError.noReclaimToken
        }
        try validate(credential)
        return try await reclaim(credential: credential, removeOnSuccess: true)
    }

    /// Uses a token the App recovered from its own vault. This is the explicit
    /// cold-recovery entry: the response itself is the proof that the CAS took
    /// effect, so a known remote-fence evidence value may be recorded only
    /// after the download succeeded.
    public func reclaim(using credential: HandoffReclaimToken) async throws
        -> HandoffReclaimOutcome {
        try validate(credential)
        cachedToken = credential
        return try await reclaim(credential: credential, removeOnSuccess: true)
    }

    private func loadCredential() async throws -> HandoffReclaimToken? {
        let loaded: HandoffReclaimToken?
        do {
            loaded = try await tokenStore.load()
        } catch let error as HandoffError {
            // A cached credential is already the token the CAS minted; a later
            // vault outage must not discard it before the return path runs.
            if let cachedToken { return cachedToken }
            throw error
        } catch {
            if let cachedToken { return cachedToken }
            throw HandoffError.reclaimTokenStoreFailed(
                "cannot load the reclaim credential")
        }
        guard let loaded else {
            return cachedToken
        }
        if let cachedToken, !Self.isNewer(loaded, than: cachedToken) {
            // The vault can still hold the credential this CAS replaced when
            // `store()` failed: the Keychain store deliberately does not delete
            // the old item first. The new token exists only in memory, so using
            // the stale vault value would lose the only return credential.
            return cachedToken
        }
        do {
            try validate(loaded)
        } catch {
            // A foreign/corrupt higher-generation vault value must not discard
            // the CAS-minted in-process credential.
            if let cachedToken { return cachedToken }
            throw error
        }
        cachedToken = loaded
        return loaded
    }

    /// Whether a vault credential is strictly newer than the in-process one.
    /// Same-generation or evidence-less vault values never displace the token
    /// minted by the current CAS.
    private static func isNewer(_ candidate: HandoffReclaimToken,
                                than current: HandoffReclaimToken) -> Bool {
        if let candidateGeneration = candidate.remoteFence?.generation {
            guard let currentGeneration = current.remoteFence?.generation else {
                return true
            }
            return candidateGeneration > currentGeneration
        }
        return false
    }

    private func validate(_ credential: HandoffReclaimToken) throws {
        guard HandoffHex.isLowercaseHex(credential.token, count: 32) else {
            throw HandoffError.unauthorized
        }
        let expectedEndpoint = try client.configuration.endpointIdentity()
        if let endpoint = credential.endpoint, endpoint != expectedEndpoint {
            throw HandoffError.manualReclaimRequired(
                "the stored reclaim token belongs to another remote endpoint")
        }
        // A vault may be shared by several workspaces. Refuse a foreign token
        // before any network request or segment apply: the workspace binding is
        // non-secret and always written by ``store(token:remoteFence:)``. An
        // unbound legacy credential is manual recovery, not a guessed match.
        guard let workspaceIdentifier = credential.workspaceIdentifier,
              workspaceIdentifier == fences.workspaceIdentifier else {
            throw HandoffError.manualReclaimRequired(
                "the stored reclaim token belongs to another workspace")
        }
        if let fence = credential.remoteFence {
            guard fence.owner == HandoffLimits.remoteOwner else {
                throw HandoffError.manualReclaimRequired(
                    "the stored remote fence is not owned by the remote")
            }
        }
    }

    private func reclaim(credential: HandoffReclaimToken,
                         removeOnSuccess: Bool) async throws
        -> HandoffReclaimOutcome {
        var attempt = 0
        while true {
            attempt += 1
            do {
                let outcome = try await reclaimOnce(credential: credential)
                if removeOnSuccess {
                    try? await tokenStore.remove()
                    cachedToken = nil
                }
                return outcome
            } catch let error as HandoffError
                where error.isRetryable && attempt < retryPolicy.maximumAttempts {
                let delay = retryPolicy.delay(beforeAttempt: attempt + 1)
                if delay > 0 {
                    do {
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    } catch {
                        throw HandoffError.cancelled
                    }
                }
                continue
            } catch is CancellationError {
                throw HandoffError.cancelled
            }
        }
    }

    /// One attempt: download (the token proof), reconcile a post-CAS local
    /// fence that never reached disk, validate, apply and install.
    private func reclaimOnce(credential: HandoffReclaimToken) async throws
        -> HandoffReclaimOutcome {
        let download = try await client.reclaim(token: credential.token)
        defer { download.cleanup() }
        let metadata = download.metadata
        try metadata.validate()

        var current = await fences.currentFence()
        var alreadyReclaimed = false
        if current.owner == HandoffLimits.phoneOwner,
           let remoteFence = credential.remoteFence {
            if remoteFence.generation == current.generation + 1 {
                // The 200 download above proves the CAS took effect. Only now
                // may the known non-secret remote fence be recorded; a guessed
                // generation is never used.
                guard remoteFence.walSeq >= current.walSeq else {
                    throw HandoffError.manualReclaimRequired(
                        "the stored remote fence lowers wal_seq")
                }
                guard metadata.fence.generation == remoteFence.generation + 1 else {
                    throw HandoffError.manualReclaimRequired(
                        "the reclaim response does not follow the stored remote fence")
                }
                do {
                    try await fences.recordHandoff(remoteFence)
                } catch {
                    throw HandoffError.manualReclaimRequired(
                        "cannot record the verified remote fence")
                }
                current = await fences.currentFence()
            } else if current.generation == remoteFence.generation + 1 {
                // A previous attempt already installed the reclaimed phone
                // fence but was interrupted before `handoff-intent.json` was
                // removed (or before the vault entry was dropped). The remote's
                // cached 200 is the same proof, and the fence was only written
                // after the segments were applied. Do not advance the
                // generation again or replay stale segments; retry the
                // idempotent install, which clears the stale intent.
                guard metadata.fence.owner == HandoffLimits.phoneOwner,
                      metadata.fence.generation == current.generation,
                      metadata.fence.walSeq >= remoteFence.walSeq,
                      metadata.fence.walSeq <= current.walSeq else {
                    throw HandoffError.manualReclaimRequired(
                        "the persisted phone fence does not match the reclaimed response")
                }
                alreadyReclaimed = true
            } else {
                throw HandoffError.manualReclaimRequired(
                    "the stored remote fence is neither the current generation + 1 "
                        + "nor the already-installed reclaimed fence")
            }
        } else if current.owner == HandoffLimits.remoteOwner,
                  let remoteFence = credential.remoteFence,
                  remoteFence != current {
            throw HandoffError.manualReclaimRequired(
                "the stored remote fence differs from the persisted authority")
        }

        if alreadyReclaimed {
            do {
                try await fences.installReclaimedFence(current)
            } catch let error as HandoffError {
                throw error
            } catch {
                throw HandoffError.fenceMismatch(
                    "cannot clear the interrupted reclaim evidence")
            }
            installedFence = current
            return HandoffReclaimOutcome(
                fence: current,
                appliedMseq: current.walSeq,
                lastMseq: max(current.walSeq, metadata.fence.walSeq),
                epochClosed: true,
                mutationsApplied: 0,
                mutationsSkipped: 0)
        }

        let alreadyInstalled = installedFence == metadata.fence || current == metadata.fence
        if !alreadyInstalled {
            guard metadata.fence.generation == current.generation + 1 else {
                throw HandoffError.fenceMismatch(
                    "reclaim generation \(metadata.fence.generation) is not "
                        + "\(current.generation) + 1")
            }
            guard current.owner == HandoffLimits.remoteOwner else {
                throw HandoffError.fenceMismatch(
                    "reclaim requires the remote to hold the current fence")
            }
        }
        let result = try await applier.apply(download)
        guard result.appliedMseq == metadata.fence.walSeq else {
            throw HandoffError.applyFailed(
                "applied mseq \(result.appliedMseq) is not fence.wal_seq "
                    + "\(metadata.fence.walSeq)")
        }
        do {
            try await fences.installReclaimedFence(metadata.fence)
        } catch let error as HandoffError {
            throw error
        } catch {
            throw HandoffError.fenceMismatch("cannot install the reclaimed fence")
        }
        installedFence = metadata.fence
        return HandoffReclaimOutcome(fence: metadata.fence,
                                     appliedMseq: result.appliedMseq,
                                     lastMseq: result.lastMseq,
                                     epochClosed: result.epochClosed,
                                     mutationsApplied: result.mutationsApplied,
                                     mutationsSkipped: result.mutationsSkipped)
    }
}
