// SPDX-License-Identifier: MIT
// PhoneDSHPCLink: frozen PCLink v1 limits and timers.

import Foundation

public enum PCLinkLimits {
    public static let maxRelayFrameBytes = 16 << 20            // 16 MiB
    public static let maxValueBytes = 8 << 20                  // 8 MiB
    public static let chunkThresholdBytes = 1 << 20            // 1 MiB
    public static let maxChunkCharacters = 1_500_000
    public static let chunkReassemblyTimeout: TimeInterval = 30
    /// §3.8 sender pacing reference values (margin under the relay pair limit).
    public static let sendRateBytesPerSecond: Double = PCLinkOutboundPacer.referenceRateBytesPerSecond
    public static let sendBurstBytes: Double = PCLinkOutboundPacer.referenceBurstBytes
    public static let softFrameThreshold: UInt64 = 1 << 19     // 524,288
    public static let hardFrameThreshold: UInt64 = 1 << 20     // 1,048,576
    public static let softByteThreshold: UInt64 = 1 << 30      // 1 GiB
    public static let hardByteThreshold: UInt64 = 1 << 31      // 2 GiB
    public static let handshakeStepTimeout: TimeInterval = 10
    public static let pairingApprovalTimeout: TimeInterval = 120
    public static let pairingSlotLifetime: TimeInterval = 300
    public static let pairingJoinLimit = 10
    public static let pairingSlotsPerConnection = 2
    public static let pcSIDCacheLimit = 4096
    public static let pcSIDCacheLifetime: TimeInterval = 300
    public static let pcPendingHandshakeLimit = 64
    public static let pcE2EIdleTimeout: TimeInterval = 15 * 60
    public static let relayPhoneIdleTimeout: TimeInterval = 10 * 60
    public static let reconnectResetAfter: TimeInterval = 60
    public static let pairingQRLengthLimit = 512
    public static let maxPairingRecords = 1024
    public static let heartbeatRange: ClosedRange<TimeInterval> = 20...30
}
