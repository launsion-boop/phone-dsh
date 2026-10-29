// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHController: the VIDEO accelerator budget
// (spec-render-media-v1 §A.2, §A.5).
//
// The encoder itself is not implemented yet (Part D step 7); these are the
// contract constants the `video/begin|frame|end` protocol will enforce. The
// nominal duration is 60 s with a 75 s booked budget for drain and the last
// frame, and the output is bounded well under the tier's single-file limit
// (the 8 GiB row publishes 128 MiB files, so a 96 MiB output fits).
//
// Video artefacts are a fourth persistent store next to the WAL, journal and
// response log: during encoding they never touch the WAL or the VFS, and only
// after `video/read` puts the file into the workspace do the ordinary
// workspace/single-file budgets apply (spec §A.5).

import Foundation

/// Per-tier VIDEO constants (spec-render-media-v1 §A.2).
public struct VideoBudget: Equatable, Sendable {
    /// Longest accepted `video/begin` duration.
    public static let nominalDurationSeconds = 60
    /// Longest accepted duration including drain and the last frame.
    public static let budgetedDurationSeconds = 75

    public let maximumFrames: Int
    public let maximumFrameBytes: Int
    public let maximumOutputBytes: Int
    public let maximumWidth: Int
    public let maximumHeight: Int
    public let inFlightFrames: Int
    /// Footprint the encoder adds to the app process row.
    public let appProcessIncrementBytes: Int
    /// Quota of the separate `video/` store (spec §A.5).
    public let storeQuotaBytes: Int

    public init(maximumFrames: Int, maximumFrameBytes: Int, maximumOutputBytes: Int,
                maximumWidth: Int, maximumHeight: Int, inFlightFrames: Int,
                appProcessIncrementBytes: Int, storeQuotaBytes: Int) {
        self.maximumFrames = maximumFrames
        self.maximumFrameBytes = maximumFrameBytes
        self.maximumOutputBytes = maximumOutputBytes
        self.maximumWidth = maximumWidth
        self.maximumHeight = maximumHeight
        self.inFlightFrames = inFlightFrames
        self.appProcessIncrementBytes = appProcessIncrementBytes
        self.storeQuotaBytes = storeQuotaBytes
    }

    /// Frames one budgeted duration admits at `maxFPS`; both the 8 and 12 GiB
    /// rows run 60 fps, so they both get 75 × 60 = 4500 frames.
    public static func frames(forBudgetedSeconds seconds: Int, maxFPS: Int) -> Int {
        seconds * maxFPS
    }

    /// The 8 GiB row: 1080p30, 6 Mbps ≈ 45 MB for 60 s, 96 MiB output cap.
    public static let eightGB = VideoBudget(
        maximumFrames: frames(forBudgetedSeconds: budgetedDurationSeconds, maxFPS: 60),
        maximumFrameBytes: 8 * 1024 * 1024,
        maximumOutputBytes: 96 * 1024 * 1024,
        maximumWidth: 1920,
        maximumHeight: 1080,
        inFlightFrames: 3,
        appProcessIncrementBytes: 80 * 1024 * 1024,
        storeQuotaBytes: 512 * 1024 * 1024
    )

    /// The 12 GiB row: 4K, 128 MiB output cap.
    public static let twelveGB = VideoBudget(
        maximumFrames: frames(forBudgetedSeconds: budgetedDurationSeconds, maxFPS: 60),
        maximumFrameBytes: 16 * 1024 * 1024,
        maximumOutputBytes: 128 * 1024 * 1024,
        maximumWidth: 3840,
        maximumHeight: 2160,
        inFlightFrames: 4,
        appProcessIncrementBytes: 140 * 1024 * 1024,
        storeQuotaBytes: 512 * 1024 * 1024
    )

    /// The 6 GiB row: the 8 GiB contract with a smaller `video/` store.
    public static let sixGB = VideoBudget(
        maximumFrames: frames(forBudgetedSeconds: budgetedDurationSeconds, maxFPS: 60),
        maximumFrameBytes: 8 * 1024 * 1024,
        maximumOutputBytes: 96 * 1024 * 1024,
        maximumWidth: 1920,
        maximumHeight: 1080,
        inFlightFrames: 3,
        appProcessIncrementBytes: 80 * 1024 * 1024,
        storeQuotaBytes: 384 * 1024 * 1024
    )

    /// The 4 GiB row: the 8 GiB contract with a smaller `video/` store; the
    /// 32 MiB single-file cap clamps the effective output.
    public static let fourGB = VideoBudget(
        maximumFrames: frames(forBudgetedSeconds: budgetedDurationSeconds, maxFPS: 60),
        maximumFrameBytes: 8 * 1024 * 1024,
        maximumOutputBytes: 96 * 1024 * 1024,
        maximumWidth: 1920,
        maximumHeight: 1080,
        inFlightFrames: 3,
        appProcessIncrementBytes: 80 * 1024 * 1024,
        storeQuotaBytes: 256 * 1024 * 1024
    )

    /// The ≤ 3 GiB row: the 8 GiB contract with the smallest `video/` store.
    public static let threeGB = VideoBudget(
        maximumFrames: frames(forBudgetedSeconds: budgetedDurationSeconds, maxFPS: 60),
        maximumFrameBytes: 8 * 1024 * 1024,
        maximumOutputBytes: 96 * 1024 * 1024,
        maximumWidth: 1920,
        maximumHeight: 1080,
        inFlightFrames: 3,
        appProcessIncrementBytes: 80 * 1024 * 1024,
        storeQuotaBytes: 192 * 1024 * 1024
    )

    public static let byTier: [DeviceTier: VideoBudget] = [
        .twelveGB: .twelveGB,
        .eightGB: .eightGB,
        .sixGB: .sixGB,
        .fourGB: .fourGB,
        .threeGB: .threeGB,
    ]

    /// The budget row for a tier (the 8 GiB row when unknown), clamped by the
    /// tier's own single-file maximum through ``effectiveOutputBytes(for:)``.
    public static func table(for tier: DeviceTier) -> VideoBudget {
        byTier[tier] ?? .eightGB
    }

    /// The output cap a tier can actually persist: the smaller tiers' 32 / 16
    /// MiB file maximums bound it below the 96 MiB nominal value.
    public func effectiveOutputBytes(for budgets: BudgetTable) -> Int {
        min(maximumOutputBytes, budgets.maximumSingleFileBytes)
    }
}
