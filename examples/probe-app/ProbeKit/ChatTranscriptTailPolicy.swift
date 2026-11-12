// SPDX-License-Identifier: MIT
// phone-dsh — transcript tail-anchor policy.
//
// The chat page used to call `scrollToTail` as soon as a session changed. At
// that point the previous session's content height was still cached and the
// new LazyVStack had no laid-out rows, so the scroll target was an estimate and
// the viewport could stop past the real content (a blank page until a drag).
// The page now resets the measurement on a session change and asks this pure
// policy before every initial/again pass, so the behaviour is testable without
// WebKit.

import CoreGraphics

public enum ChatTranscriptTailPolicy {
    /// What a blank viewport needs to become visible again.
    public enum Correction: Equatable {
        /// The viewport overlaps content (or there are no rows to show).
        case none
        /// The content is shorter than the viewport: put its top back in view.
        case scrollToTop
        /// The content overflows: re-anchor the last row at the bottom.
        case scrollToLastRow
    }

    /// A viewport whose top is within this many points of the content's bottom
    /// is treated as blank. One point absorbs sub-pixel layout noise without
    /// hiding a real row.
    public static let blankTolerance: CGFloat = 1

    /// Whether a tail scroll can land on real content.
    /// - Parameters:
    ///   - contentHeight: measured transcript height, 0 before the first pass.
    ///   - viewportHeight: scroll viewport height.
    ///   - hasRows: the timeline has at least one row.
    /// - Returns: true only when the content actually overflows the viewport.
    public static func shouldScrollToTail(contentHeight: CGFloat,
                                          viewportHeight: CGFloat,
                                          hasRows: Bool) -> Bool {
        guard hasRows, contentHeight.isFinite, viewportHeight.isFinite,
              contentHeight > 0, viewportHeight > 0 else { return false }
        return contentHeight > viewportHeight + 1
    }

    /// Whether the deferred second pass after a session switch is justified.
    /// A shorter transcript is already fully visible; scrolling it to a bottom
    /// anchor is what produced the blank band.
    public static func shouldSettleAfterInitial(contentHeight: CGFloat,
                                                viewportHeight: CGFloat,
                                                hasRows: Bool) -> Bool {
        shouldScrollToTail(contentHeight: contentHeight,
                           viewportHeight: viewportHeight,
                           hasRows: hasRows)
    }

    /// Whether the visible rect has fallen entirely outside the transcript.
    ///
    /// This is the invariant the page checks on every scroll-geometry change,
    /// not a one-shot timer: lazy rows can report an estimated height, a scroll
    /// can land past it, and only the next real geometry tells us so.
    ///
    /// - Parameters:
    ///   - contentHeight: measured height of the transcript content.
    ///   - contentOffsetY: the raw scroll-view offset. At the top this is
    ///     `-contentInsetTop`; the insets below normalize it to content space.
    ///   - viewportHeight: the scroll container height.
    ///   - contentInsetTop: top scroll inset (safe area or chrome).
    ///   - contentInsetBottom: bottom scroll inset (keyboard, composer, safe area).
    ///   - hasRows: the timeline has at least one row.
    ///   - tolerance: slop around the bottom edge; defaults to `blankTolerance`.
    /// - Returns: true when the viewport starts at/below the content bottom
    ///   (or a short transcript has been scrolled away from its top).
    public static func viewportIsBlank(contentHeight: CGFloat,
                                       contentOffsetY: CGFloat,
                                       viewportHeight: CGFloat,
                                       contentInsetTop: CGFloat = 0,
                                       contentInsetBottom: CGFloat = 0,
                                       hasRows: Bool,
                                       tolerance: CGFloat = blankTolerance) -> Bool {
        guard let metrics = metrics(contentHeight: contentHeight,
                                    contentOffsetY: contentOffsetY,
                                    viewportHeight: viewportHeight,
                                    contentInsetTop: contentInsetTop,
                                    contentInsetBottom: contentInsetBottom,
                                    hasRows: hasRows,
                                    tolerance: tolerance) else { return false }
        return metrics.isBlank
    }

    /// The scroll action that makes a blank viewport show its transcript again.
    /// Returns `.none` for a visible viewport, no rows, or unusable geometry.
    public static func correction(contentHeight: CGFloat,
                                   contentOffsetY: CGFloat,
                                   viewportHeight: CGFloat,
                                   contentInsetTop: CGFloat = 0,
                                   contentInsetBottom: CGFloat = 0,
                                   hasRows: Bool,
                                   tolerance: CGFloat = blankTolerance) -> Correction {
        guard let metrics = metrics(contentHeight: contentHeight,
                                    contentOffsetY: contentOffsetY,
                                    viewportHeight: viewportHeight,
                                    contentInsetTop: contentInsetTop,
                                    contentInsetBottom: contentInsetBottom,
                                    hasRows: hasRows,
                                    tolerance: tolerance),
              metrics.isBlank else { return .none }
        return metrics.fitsViewport ? .scrollToTop : .scrollToLastRow
    }

    private struct Metrics {
        let contentHeight: CGFloat
        let offset: CGFloat
        let usableViewport: CGFloat
        let tolerance: CGFloat

        var fitsViewport: Bool {
            contentHeight <= usableViewport + tolerance
        }

        /// The visible top is past the content bottom. A short transcript also
        /// counts as blank once it has been pushed away from the top, matching
        /// the bottom-anchor overshoot that produced the empty band.
        var isBlank: Bool {
            fitsViewport ? offset > tolerance : offset > contentHeight - tolerance
        }
    }

    /// Drops non-finite/empty geometry and normalizes the raw scroll offset
    /// (`-topInset` at the top) to content space (`0` at the top).
    private static func metrics(contentHeight: CGFloat,
                                contentOffsetY: CGFloat,
                                viewportHeight: CGFloat,
                                contentInsetTop: CGFloat,
                                contentInsetBottom: CGFloat,
                                hasRows: Bool,
                                tolerance: CGFloat) -> Metrics? {
        guard hasRows,
              contentHeight.isFinite, contentOffsetY.isFinite, viewportHeight.isFinite,
              contentInsetTop.isFinite, contentInsetBottom.isFinite, tolerance.isFinite,
              contentHeight > 0, viewportHeight > 0 else { return nil }
        let top = max(0, contentInsetTop)
        let bottom = max(0, contentInsetBottom)
        let usable = viewportHeight - top - bottom
        guard usable > 0 else { return nil }
        return Metrics(contentHeight: contentHeight,
                       offset: contentOffsetY + top,
                       usableViewport: usable,
                       tolerance: max(0, tolerance))
    }
}
