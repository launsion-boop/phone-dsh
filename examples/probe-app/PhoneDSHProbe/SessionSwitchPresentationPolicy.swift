// SPDX-License-Identifier: MIT
// What the chat page draws while a drawer tap's history is still loading. A
// switch never replaces the old page with a blank placeholder just because the
// new history is not ready, and the lightweight "正在打开会话…" pill waits long
// enough that a fast switch never flashes it.

import Foundation

enum SessionSwitchPresentationPolicy {
    /// What the page was already drawing when the switch began. The empty
    /// state cards (engine / provider / new-session) are content: they stay on
    /// screen exactly like transcript rows do.
    enum OldPage: Equatable {
        case transcriptRows
        case emptyStateCard
        case blank
    }

    enum Backdrop: Equatable {
        case keepOldContent
        /// Nothing was drawn. Keep the transcript viewport height so the pill
        /// and the eventual content cannot move the page.
        case placeholder
    }

    /// Only a page that rendered nothing at all gets the height placeholder.
    static func backdrop(for oldPage: OldPage) -> Backdrop {
        oldPage == .blank ? .placeholder : .keepOldContent
    }

    /// The pill's delay from the moment the switch work actually starts. The
    /// phone drawer's close animation runs before that, so it is not counted as
    /// load time; a switch that lands sooner never shows the pill at all.
    static let indicatorDelay: Duration = .milliseconds(300)

    /// `elapsedSinceWorkStarted` is measured from the worker's start, not the
    /// tap. `nil` means the close is still animating and the worker has not
    /// begun, so the timer has not started and no pill may appear. The pill is
    /// an overlay in the view, so this decision never changes the transcript's
    /// layout.
    static func showsIndicator(isSwitching: Bool,
                               elapsedSinceWorkStarted: Duration?) -> Bool {
        guard isSwitching, let elapsed = elapsedSinceWorkStarted else { return false }
        return elapsed >= indicatorDelay
    }
}
