// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSH: handoff coordinator.
//
// PLAN §2.5 (D14/D15) and spec/v1/handoff.md §1–§5. The coordinator
// drives the controller through `HandingOff -> Remote` and, on the return path,
// `Remote -> Reclaiming -> Recovering`; admission is closed for every one of
// those transitions by the state machine. The reclaim token is written only to
// the injected ``HandoffReclaimTokenStore`` (the App's secure vault, with a
// process-lifetime fallback) before any fallible post-CAS step; it never enters
// the workspace, WAL, a URL or a log.

import Foundation
import PhoneDSHController
import PhoneDSHLog
import PhoneDSHWire

/// One completed handoff to the remote.
public struct HandoffCompletion: Equatable, Sendable {
    /// `{owner:"remote", generation, wal_seq}` installed by the CAS.
    public var remoteFence: Fence
    /// Snapshot base of this handoff.
    public var baseMseq: UInt64
    /// Replication target (`fence.wal_seq`).
    public var walSeq: UInt64
}

/// Facade phase of the handoff coordinator.
public enum HandoffCoordinatorPhase: String, Equatable, Sendable {
    case idle
    case handingOff
    case remote
    case reclaiming
}

/// Wires the landed controller, fence authority, snapshot source and clients
/// into the D15 sequence.
public actor HandoffCoordinator {
    private let machine: HostStateMachine
    private let fences: any HandoffFenceStoring
    private let source: any HandoffSourceProviding
    private let client: HandoffClient
    private let reclaimClient: ReclaimClient

    public private(set) var phase: HandoffCoordinatorPhase = .idle
    private var pendingUpload: HandoffPreparedUpload?
    /// The remote fence returned by the CAS. It is kept until the local
    /// `fence.json` records it, so a local persistence failure does not lose
    /// the authority that the remote already owns.
    private var pendingRemoteFence: Fence?
    private var remoteFenceRecorded = false
    private var fenceInstalled = false
    /// `true` when the fence CAS was sent and its outcome is not known to be a
    /// definite rejection. The remote may own generation + 1; admission must
    /// stay closed until a token-based reclaim or manual recovery.
    private var authorityUncertain = false

    public init(machine: HostStateMachine,
                fences: any HandoffFenceStoring,
                source: any HandoffSourceProviding,
                client: HandoffClient,
                reclaimClient: ReclaimClient) {
        self.machine = machine
        self.fences = fences
        self.source = source
        self.client = client
        self.reclaimClient = reclaimClient
    }

    // MARK: - Handoff

    /// Runs `HandingOff -> Remote` and returns the installed remote fence.
    /// On success the phone holds no authority and admission stays closed.
    public func beginHandoff() async throws -> HandoffCompletion {
        guard phase == .idle else {
            throw HandoffError.invalidControllerState(
                "a handoff is already in progress")
        }
        let initial = await machine.currentState()
        guard initial == .running || initial == .draining else {
            throw HandoffError.invalidControllerState(
                "handoff requires Running or Draining, not \(initial.rawValue)")
        }
        // Refuse a URL that could put a credential/query into the authority
        // intent before the controller leaves Running or any local evidence is
        // written. A legal https base path is preserved.
        let endpointIdentity = try client.configuration.endpointIdentity()
        phase = .handingOff
        fenceInstalled = false
        authorityUncertain = false
        pendingRemoteFence = nil
        remoteFenceRecorded = false
        do {
            _ = try await machine.handle(.handoffRequested)
        } catch {
            phase = .idle
            throw HandoffError.invalidControllerState(
                "the controller refused the handoff transition")
        }

        var prepared: HandoffPreparedUpload?
        do {
            let upload = try await source.prepareHandoff()
            prepared = upload
            pendingUpload = upload
            // The preparation may have completed after the caller cancelled.
            // No authority evidence or request exists yet; the outer catch
            // removes the scratch upload.
            try Task.checkCancellation()
            try upload.validate()
            let current = await fences.currentFence()
            guard current.owner == HandoffLimits.phoneOwner else {
                throw HandoffError.fenceMismatch("the phone does not hold the fence")
            }
            // Cover a cancellation that arrived while the fence was read.
            try Task.checkCancellation()
            // Persist non-secret "authority may be remote" evidence *before*
            // the request. If the response is lost, a new host must not reopen
            // local admission over the old phone fence (handoff.md §2).
            try await fences.markHandoffUncertain(
                expectedGeneration: current.generation,
                walSeq: upload.walSeq,
                endpoint: endpointIdentity)
            do {
                // The request has not been sent yet. A cancellation proven
                // here must not leave the fresh intent looking like an
                // uncertain CAS: rewrite it as a definite rejection and clear
                // it. If cleanup itself fails, keep the record and stay fail
                // closed; an explicit reset retries the definite-marker path.
                try Task.checkCancellation()
            } catch {
                try? await fences.markHandoffDefinitelyRejected()
                try? await fences.clearHandoffUncertain()
                throw CancellationError()
            }
            let fence: HandoffFenceResponse
            do {
                fence = try await client.fence(expectedGeneration: current.generation,
                                               walSeq: upload.walSeq)
            } catch let error as HandoffError where error.isDefiniteFenceRejection {
                // Proven pre-state rejection: the remote changed nothing, so
                // the normal Failed -> user reset path stays available. Persist
                // a durable marker before unwinding; a later removal failure
                // must not turn this proven rejection into an unresolved CAS
                // that permanently locks local admission. If the marker itself
                // cannot be written, retain the in-process definite outcome and
                // try to remove the stale unmarked intent; never reclassify a
                // confirmed rejection as authority-uncertain.
                do {
                    try await fences.markHandoffDefinitelyRejected()
                } catch {
                    do {
                        try await fences.clearHandoffUncertain()
                    } catch {
                        throw HandoffError.fenceMismatch(
                            "the CAS was definitely rejected, but neither the "
                                + "durable rejection marker nor the stale intent "
                                + "could be written/removed; fix workspace storage "
                                + "and call reset() (this process still treats the "
                                + "CAS as definitely rejected)")
                    }
                }
                throw error
            } catch {
                authorityUncertain = true
                throw error
            }
            // The CAS response is the point of no return: the remote owns
            // generation + 1 even if every local step below fails. Keep the
            // fence and the token first so a persisted-fence failure leaves a
            // reclaimable `Reclaiming` host instead of a "pre-CAS" failure.
            pendingRemoteFence = fence.fence
            fenceInstalled = true
            // The token must be in the App's secure vault before any step that
            // can fail (including the controller transition), otherwise a
            // refused transition loses the only return credential.
            try await reclaimClient.store(token: fence.reclaimToken,
                                          remoteFence: fence.fence)
            _ = try await machine.handle(.handoffFenceInstalled)
            try await fences.recordHandoff(fence.fence)
            remoteFenceRecorded = true
            _ = try await client.uploadSnapshot(upload,
                                               generation: fence.fence.generation)
            let segments = try await client.uploadSegments(
                upload, generation: fence.fence.generation)
            guard segments.admission == .open else {
                throw HandoffError.applyFailed("the remote did not confirm admission")
            }
            try await machine.handle(.handoffCompleted(remoteAdmission: .open))
            pendingUpload = nil
            await source.cleanUp(upload)
            authorityUncertain = false
            phase = .remote
            return HandoffCompletion(remoteFence: fence.fence,
                                     baseMseq: upload.baseMseq,
                                     walSeq: upload.walSeq)
        } catch {
            if let prepared {
                pendingUpload = nil
                await source.cleanUp(prepared)
            }
            if fenceInstalled {
                // D15: the remote owns generation + 1, so the token must be
                // reclaimed; the state machine's handoffFailed edge enters
                // Reclaiming and a later reclaim() can finish the return path.
                // A local fence write that failed after the CAS is retried by
                // reclaim() before the token is consumed.
                if await machine.currentState() == .handingOff {
                    _ = try? await machine.handle(.handoffFailed)
                }
                phase = .reclaiming
            } else if authorityUncertain {
                // The CAS may have taken effect but no response arrived, so no
                // token exists. Stay fail closed; the controller/Observer and
                // the persisted intent keep local admission shut.
                phase = .reclaiming
            } else {
                _ = try? await machine.handle(
                    .failure(reason: "handoff failed before the fence CAS"))
                phase = .idle
            }
            throw error
        }
    }

    /// Abandons a partially prepared handoff before the fence CAS.
    public func cancelHandoff() async {
        if let pendingUpload {
            await source.cleanUp(pendingUpload)
            self.pendingUpload = nil
        }
        phase = .idle
    }

    // MARK: - Reclaim

    /// Runs `Remote -> Reclaiming -> Recovering`: downloads the return
    /// segments, applies them, installs the new phone fence and leaves
    /// admission closed for the lease check.
    public func reclaim() async throws -> HandoffReclaimOutcome {
        try await reclaim(credential: nil)
    }

    /// Reclaims with a token the App recovered from its secure vault. The
    /// response itself proves a previously uncertain CAS, so a live
    /// `HandingOff` controller can be moved through the D14 failure edge only
    /// after the token exists.
    public func reclaim(using credential: HandoffReclaimToken) async throws
        -> HandoffReclaimOutcome {
        try await reclaim(credential: credential)
    }

    private func reclaim(credential: HandoffReclaimToken?) async throws
        -> HandoffReclaimOutcome {
        guard phase == .remote || phase == .reclaiming else {
            throw HandoffError.invalidControllerState(
                "reclaim requires the remote or reclaiming phase")
        }
        // A token-based reclaim of an uncertain CAS must first move the live
        // controller out of HandingOff. The D14 `handoffFailed` guard is
        // satisfied by `handoffFenceInstalled`; doing this only here means no
        // guessed generation can ever enter the fence.
        if await machine.currentState() == .handingOff {
            let hasStoredToken = await reclaimClient.hasStoredToken
            guard credential != nil || hasStoredToken else {
                throw HandoffError.manualReclaimRequired(
                    "the generation CAS is unresolved and no reclaim token is "
                        + "available from the App vault")
            }
            do {
                _ = try await machine.handle(.handoffFenceInstalled)
                _ = try await machine.handle(.handoffFailed)
            } catch {
                throw HandoffError.invalidControllerState(
                    "the controller could not enter Reclaiming from HandingOff")
            }
            phase = .reclaiming
        }
        // The remote already installed its fence; a local `fence.json` write
        // failure must not leave the reclaim path unable to see it. Retrying
        // the local record before the token is used keeps the D15 generation
        // chain intact and leaves the token untouched when the write still
        // fails.
        if let pendingRemoteFence, !remoteFenceRecorded {
            do {
                let current = await fences.currentFence()
                if current != pendingRemoteFence {
                    try await fences.recordHandoff(pendingRemoteFence)
                }
                remoteFenceRecorded = true
            } catch {
                phase = .reclaiming
                throw error
            }
        }
        if phase == .remote {
            do {
                _ = try await machine.handle(.reclaimRequested)
            } catch {
                throw HandoffError.invalidControllerState(
                    "the controller refused the reclaim transition")
            }
        }
        phase = .reclaiming
        let outcome: HandoffReclaimOutcome
        do {
            if let credential {
                outcome = try await reclaimClient.reclaim(using: credential)
            } else {
                outcome = try await reclaimClient.reclaimStoredToken()
            }
        } catch {
            // Stay in Reclaiming: the token and the remote cache still allow
            // another idempotent attempt.
            throw error
        }
        do {
            _ = try await machine.handle(.reclaimResponseApplied)
            _ = try await machine.handle(
                .reclaimCompleted(fencePersisted: true,
                                  epochClosed: outcome.epochClosed))
        } catch {
            phase = .reclaiming
            throw HandoffError.invalidControllerState(
                "the controller refused the reclaim completion")
        }
        phase = .idle
        authorityUncertain = false
        pendingRemoteFence = nil
        remoteFenceRecorded = false
        return outcome
    }

    /// `true` when the last CAS may have installed the remote fence without a
    /// stored token. The facade uses it to keep local admission closed.
    public var isAuthorityUncertain: Bool { authorityUncertain }

    /// Current controller state, for the App's handoff button.
    public func controllerState() async -> HostState {
        await machine.currentState()
    }
}
