// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHWire: VFS resource refusals.
//
// PLAN §2.2/§2.3 (D4, D8) and spec/v1/channel.md §4.8, §6 and §8.
// A mutation that the host refuses because it would grow one file past the
// configured `single_file_limit` is a first-class protocol answer, not a
// protocol violation: the host sends one non-closing `ERROR VFS_REFUSED`,
// appends nothing, consumes no mseq, and the Worker shrinks the mutation and
// resends it on the same connection with the same mseq.
//
// The Loopback target may not depend on the Log target (PLAN §2.1), so the
// classification lives here in Wire: a workspace-log error exposes a
// ``VFSResourceRefusalProviding`` value and the ordered channel routes it
// before the generic protocol-error catch.

/// One resource refusal of a VFS mutation (channel.md §4.8, §8).
///
/// `limitBytes` is the policy bound the mutation would exceed and
/// `projectedBytes` the logical size it would have produced. The refused
/// mutation never consumed an mseq.
public struct VFSResourceRefusal: Error, Equatable, Sendable {
    /// Refused mutation path (`/dsh/home/**` or `/dsh/workspace/**`).
    public var path: String
    /// Policy bound in bytes (`single_file_limit` for `file-too-large`).
    public var limitBytes: UInt64
    /// Logical file size the refused mutation would have produced.
    public var projectedBytes: UInt64
    /// Resource class carried to the peer.
    public var reason: PhoneWireRefusalReason
    /// Diagnostic detail; never contains a host filesystem path.
    public var message: String

    public init(path: String,
                limitBytes: UInt64,
                projectedBytes: UInt64,
                reason: PhoneWireRefusalReason = .fileTooLarge,
                message: String) {
        self.path = path
        self.limitBytes = limitBytes
        self.projectedBytes = projectedBytes
        self.reason = reason
        self.message = message
    }
}

/// An error that carries a resource refusal across the workspace-log seam.
///
/// ``PhoneDSHLog/LogError/vfsRefused(path:limit:projected:)`` conforms
/// in the Log target; the ordered channel only needs this Wire protocol so the
/// two targets keep the dependency direction fixed by PLAN §2.1.
public protocol VFSResourceRefusalProviding: Error {
    /// The refusal carried by this error, or `nil` for a protocol or host
    /// failure that must keep the existing fail-loud path.
    var vfsResourceRefusal: VFSResourceRefusal? { get }
}

extension VFSResourceRefusal: VFSResourceRefusalProviding {
    public var vfsResourceRefusal: VFSResourceRefusal? { self }
}

extension ErrorPayload {
    /// The host's non-closing answer to one refused VFS_MUT (channel.md §4.8,
    /// §8).
    ///
    /// The refused mutation is the one the host did not advance past; `refSeq`
    /// names its frame, and the structured `mseq`/`accepted_bytes` members name
    /// the refused mutation and the accepted prefix (a complete write replaces
    /// the file, accepted prefix 0; an appended write keeps the bytes before
    /// `append_from`, bounded by the limit). The `message` repeats the same
    /// facts for diagnostics.
    public init(hostRefusal refusal: VFSResourceRefusal,
                mseq: UInt64,
                acceptedBytes: UInt64,
                refSeq: UInt64) {
        self.init(code: .vfsRefused,
                  message: "host refused mseq \(mseq) with \(acceptedBytes) accepted bytes: \(refusal.message)",
                  refSeq: refSeq,
                  path: refusal.path,
                  limit: refusal.limitBytes,
                  reason: refusal.reason,
                  acceptedBytes: acceptedBytes,
                  mseq: mseq)
    }
}
