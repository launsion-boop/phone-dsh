// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSH: handoff fence seam.
//
// PLAN §2.5 (D15) and spec/v1/handoff.md §1/§2/§5. The controller's
// ``FenceAuthority`` owns the persisted `{owner, generation, wal_seq}`. The
// handoff coordinator records the remote generation locally and installs the
// reclaimed phone generation after the returned segments were applied. A
// transfer adds one to the generation and never lowers `wal_seq`.

import Foundation
import PhoneDSHController
import PhoneDSHWire

/// Persistence seam of the handoff fence.
public protocol HandoffFenceStoring: Sendable {
    /// The persisted authority.
    func currentFence() async -> Fence
    /// Non-secret stable binding of this fence store to one workspace. The
    /// reclaim credential carries the same value so a shared App vault cannot
    /// apply another workspace's token/segments here.
    var workspaceIdentifier: String { get }
    /// Persists non-secret "authority may now be remote" evidence *before* the
    /// generation CAS is sent.
    func markHandoffUncertain(expectedGeneration: UInt64, walSeq: UInt64,
                              endpoint: String) async throws
    /// Persists a durable definite-rejection marker after `409`/`401` so a
    /// later reset or cold start can distinguish "the remote changed nothing"
    /// from "the CAS outcome is unknown".
    func markHandoffDefinitelyRejected() async throws
    /// Clears the definite-rejection marker after that proven rejection. It is
    /// never used for an unresolved CAS: the authority refuses to remove an
    /// unmarked intent unless this process already holds the definite-rejection
    /// proof from the same attempt (for example after a failed marker rewrite).
    func clearHandoffUncertain() async throws
    /// Records the fence installed by the remote after the generation CAS.
    func recordHandoff(_ remoteFence: Fence) async throws
    /// Installs the phone authority returned by reclaim; idempotent when the
    /// same fence is already persisted.
    func installReclaimedFence(_ fence: Fence) async throws
}

/// ``FenceAuthority`` adapter.
///
/// D15 puts reclaim-token minting on the remote. The local token digest is
/// still cleared once the reclaimed phone fence is issued. The remote token
/// itself lives only in the injected ``HandoffReclaimTokenStore`` (with a
/// process-lifetime fallback) and is never part of the fence record.
public struct FenceAuthorityHandoffStore: HandoffFenceStoring {
    public let authority: FenceAuthority

    public init(authority: FenceAuthority) {
        self.authority = authority
    }

    public func currentFence() async -> Fence {
        let token = await authority.current
        return token.wireFence
    }

    public nonisolated var workspaceIdentifier: String {
        HandoffReclaimToken.workspaceIdentifier(for: authority.root)
    }

    public func markHandoffUncertain(expectedGeneration: UInt64, walSeq: UInt64,
                                     endpoint: String) async throws {
        do {
            try await authority.markHandoffAuthorityUncertain(
                expectedGeneration: expectedGeneration, walSeq: walSeq,
                endpoint: endpoint)
        } catch {
            throw HandoffError.fenceMismatch(
                "cannot persist the handoff authority evidence")
        }
    }

    public func markHandoffDefinitelyRejected() async throws {
        do {
            try await authority.markHandoffDefinitelyRejected()
        } catch {
            throw HandoffError.fenceMismatch(
                "cannot persist the definite handoff rejection evidence")
        }
    }

    public func clearHandoffUncertain() async throws {
        do {
            try await authority.clearDefinitelyRejectedHandoffIntent()
        } catch {
            throw HandoffError.fenceMismatch(
                "cannot clear the handoff authority evidence")
        }
    }

    public func recordHandoff(_ remoteFence: Fence) async throws {
        guard remoteFence.owner == HandoffLimits.remoteOwner else {
            throw HandoffError.fenceMismatch("remote fence owner is not remote")
        }
        do {
            try await authority.recordRemoteFence(remoteFence)
        } catch {
            throw HandoffError.fenceMismatch("cannot persist the handoff fence")
        }
    }

    public func installReclaimedFence(_ fence: Fence) async throws {
        guard fence.owner == HandoffLimits.phoneOwner else {
            throw HandoffError.fenceMismatch("reclaim fence owner is not phone")
        }
        do {
            try await authority.installReclaimedFence(fence)
        } catch {
            throw HandoffError.fenceMismatch("cannot persist the reclaimed fence")
        }
    }
}
