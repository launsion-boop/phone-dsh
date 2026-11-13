// SPDX-License-Identifier: MIT

import CoreGraphics

/// Pure layout decisions for the Bot transcript container, shared by the
/// probe app and the SwiftPM regression tests.
///
/// The field loop lived in SwiftUI's lazy placement, not in a single card.
/// The app therefore mounts an eager stack by default, renders a bounded
/// suffix of the already-loaded rows, and only auto-scrolls while the reader
/// is at the tail. These three decisions are pure values so the package tests
/// can pin them without a simulator.
public enum BotTranscriptLayoutSupport {
    /// The rows an eager stack renders, plus how many loaded rows are behind
    /// the "显示更早的消息" affordance.
    ///
    /// - Parameters:
    ///   - rows: all loaded rows, oldest first.
    ///   - limit: maximum rows to render eagerly; values below 1 are treated
    ///     as 1 so the newest row can never disappear.
    ///   - eager: lazy mode keeps the old full list.
    public static func window<T>(_ rows: [T], limit: Int, eager: Bool) -> (rows: [T], hidden: Int) {
        guard eager else { return (rows, 0) }
        let clamped = max(1, limit)
        guard rows.count > clamped else { return (rows, 0) }
        return (Array(rows.suffix(clamped)), rows.count - clamped)
    }

    /// Whether the tail probe is at (or just above) the viewport bottom.
    /// A one-point negative tolerance absorbs sub-pixel scroll rounding; the
    /// positive tolerance keeps following through a newly appended row whose
    /// height is not in the previous layout yet.
    public static func isNearTail(tailY: CGFloat, viewportHeight: CGFloat,
                                  tolerance: CGFloat = 60) -> Bool {
        guard isMeasured(tailY), isMeasured(viewportHeight), viewportHeight > 0 else {
            return false
        }
        return tailY >= -1 && tailY <= viewportHeight + max(0, tolerance)
    }

    /// Whether scrolling to the tail is safe. A transcript shorter than the
    /// viewport is already fully visible; a bottom-anchored scroll on it
    /// overshoots and leaves the messages pushed up under a blank band. This
    /// is the Bot page's equivalent of the main chat's
    /// `ChatTranscriptTailPolicy.shouldScrollToTail`.
    public static func shouldScrollToTail(contentHeight: CGFloat,
                                          viewportHeight: CGFloat,
                                          hasRows: Bool = true,
                                          tolerance: CGFloat = 1) -> Bool {
        guard hasRows, contentHeight.isFinite, viewportHeight.isFinite,
              contentHeight > 0, viewportHeight > 0 else { return false }
        return contentHeight > viewportHeight + max(0, tolerance)
    }

    /// Resolves the follow flag after a user-driven scroll settles.
    ///
    /// Only a user-driven transition may turn following off: the keyboard and
    /// the growing composer also change the viewport, and those resizes must
    /// not strand the transcript away from its tail. Returning `nil` means
    /// "keep the current value" (unknown metrics, or not a user-driven step).
    public static func updatedFollowsTail(current: Bool, userDriven: Bool,
                                          tailY: CGFloat, viewportHeight: CGFloat,
                                          tolerance: CGFloat = 60) -> Bool? {
        guard userDriven, isMeasured(tailY), isMeasured(viewportHeight), viewportHeight > 0 else {
            return nil
        }
        return isNearTail(tailY: tailY, viewportHeight: viewportHeight, tolerance: tolerance)
    }

    /// The untouched preference default is `.greatestFiniteMagnitude`; it is
    /// finite but not a measurement. Layout can also briefly report sentinel
    /// values during rotation/keyboard transitions.
    private static func isMeasured(_ value: CGFloat) -> Bool {
        value.isFinite && abs(value) < 1e9
    }
}
