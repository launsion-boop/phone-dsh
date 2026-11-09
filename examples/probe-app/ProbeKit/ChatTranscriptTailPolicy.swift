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
}
