// SPDX-License-Identifier: MIT

import CoreGraphics

/// Deterministic geometry for the Bot transcript's adaptive bubble
/// (`BotAdaptiveBubbleLayout` in the probe app).
///
/// The custom `Layout` is evaluated inside the AttributeGraph many times per
/// pass. Its result must depend only on the proposed **width**: the keyboard
/// and safe-area changes alter the available height, and a child re-proposed
/// with that height can report a different natural height between passes.
/// That difference is what keeps the transcript's lazy stack re-measuring.
public enum BotAdaptiveBubbleGeometry {
    /// The width proposed to the bubble's content: the `ratio` cap of the
    /// available column. `nil` means the parent has not proposed a width yet;
    /// callers should measure the child's ideal size instead of collapsing to
    /// zero.
    public static func contentWidth(availableWidth: CGFloat?, ratio: CGFloat) -> CGFloat? {
        guard let availableWidth, availableWidth.isFinite, availableWidth > 0,
              ratio.isFinite, ratio > 0 else { return nil }
        return availableWidth * ratio
    }

    /// The proposal sent to the bubble's content. The parent's height proposal
    /// is deliberately **not** forwarded: the bubble is content-sized, so the
    /// keyboard changing the available height must not change this proposal.
    public static func contentProposal(availableWidth: CGFloat?, availableHeight: CGFloat?,
                                       ratio: CGFloat) -> (width: CGFloat?, height: CGFloat?)? {
        guard let width = contentWidth(availableWidth: availableWidth, ratio: ratio) else {
            return nil
        }
        // Height is intentionally not forwarded; the bubble is content-sized.
        _ = availableHeight
        return (width, nil)
    }

    /// The bubble occupies the full column width and the child's natural
    /// height. The parent's proposed height is not an input.
    public static func bubbleSize(availableWidth: CGFloat, contentHeight: CGFloat) -> CGSize {
        CGSize(width: max(0, availableWidth), height: max(0, contentHeight))
    }

    /// Leading/trailing origin for a content-sized child inside `bounds`. The
    /// width is always derived from the bounds, never from a measurement made
    /// for a different proposal.
    public static func contentOriginX(bounds: CGRect, contentWidth: CGFloat,
                                      trailing: Bool) -> CGFloat {
        trailing ? max(bounds.minX, bounds.maxX - contentWidth) : bounds.minX
    }

    /// The height to place at for the current bounds. A cache measured for the
    /// same width is reused; a stale cache is re-measured against the bounds
    /// width. This keeps placement and measurement on the same proposal.
    public static func contentHeight(boundsWidth: CGFloat,
                                     cachedWidth: CGFloat,
                                     cachedHeight: CGFloat,
                                     measure: (CGFloat) -> CGFloat) -> CGFloat {
        if abs(cachedWidth - boundsWidth) <= 0.5 {
            return cachedHeight
        }
        return measure(boundsWidth)
    }
}

/// The two heights measured by the card-heading probes.
public struct BotCardTextHeights: Equatable, Sendable {
    /// Height of an unclamped copy of the text.
    public var full: CGFloat
    /// Height of the line-limited copy that is actually visible.
    public var limited: CGFloat

    public init(full: CGFloat = 0, limited: CGFloat = 0) {
        self.full = full
        self.limited = limited
    }

    /// The 展开/收起 control is needed only when the full text is taller than
    /// the clamped copy. The half-point tolerance absorbs text rounding.
    public var needsExpansionControl: Bool {
        full > limited + 0.5
    }
}

/// Coordinates the card-heading measurement probes.
///
/// `onPreferenceChange` runs inside SwiftUI's layout transaction. Writing a
/// `@State`/`@Published` value there (even a task handle) dirties the same
/// graph that is measuring the card, which can keep the lazy transcript
/// placing subviews indefinitely. The view therefore only mutates this plain
/// value during the callback and applies the result later, outside layout.
public struct BotCardTextMeasurement: Equatable, Sendable {
    /// The latest value reported by the probes.
    public private(set) var reported: BotCardTextHeights
    /// The value whose visible effect was already applied.
    public private(set) var applied: BotCardTextHeights

    public init(applied: BotCardTextHeights = BotCardTextHeights()) {
        self.reported = applied
        self.applied = applied
    }

    /// Records a probe report from the layout pass.
    /// - Returns: `true` when the caller must schedule one deferred apply.
    public mutating func report(_ next: BotCardTextHeights) -> Bool {
        guard !Self.matches(next, reported) else { return false }
        reported = next
        return !Self.matches(next, applied)
    }

    /// Applies the latest report. Only call this outside the layout pass.
    /// - Returns: the heights to write to view state, or `nil` when the value
    ///   is already current.
    public mutating func commit() -> BotCardTextHeights? {
        guard !Self.matches(reported, applied) else { return nil }
        applied = reported
        return applied
    }

    public var needsCommit: Bool { !Self.matches(reported, applied) }

    /// Text layout rounds to fractions of a point; a sub-half-point report is
    /// the same measurement and must not schedule another layout pass.
    private static func matches(_ lhs: BotCardTextHeights,
                                _ rhs: BotCardTextHeights) -> Bool {
        abs(lhs.full - rhs.full) <= 0.5 && abs(lhs.limited - rhs.limited) <= 0.5
    }
}
