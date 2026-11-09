// SPDX-License-Identifier: MIT

import Foundation

/// UI-visible connection state of the production Bot runtime. The Bot page
/// renders a disconnect banner for `recovering`/`failed` instead of silently
/// presenting stale rows after the Worker died.
enum BotRuntimeState: Equatable, Sendable {
    case idle
    case preparing
    case connecting
    case ready
    case recovering
    case failed(String)
    case stopped

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
