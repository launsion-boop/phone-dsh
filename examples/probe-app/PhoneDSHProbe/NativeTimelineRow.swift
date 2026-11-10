// SPDX-License-Identifier: MIT

import Foundation
import ProbeKit

/// One rendered transcript row. Group ids are stable for the lifetime of the
/// group: the tool-run suffix is scoped by Turn and the first member id, so
/// appending a tool member (or a streamed delta) never changes it.
enum NativeTranscriptRow: Identifiable, Equatable {
    case item(ChatItem)
    case contexts([ChatItem])
    /// One run of consecutive tool calls/results, folded into a single row.
    case tools([ChatItem])
    /// The per-Turn completion control row (closed Turns only).
    case turnProcess(Int)
    /// The per-Turn footer actions, anchored after all process/content rows.
    case turnTail(Int)

    var id: String {
        switch self {
        case .item(let item): return item.id
        case .contexts(let items): return "context-group-\(items.first?.id ?? "empty")"
        case .tools(let items):
            let turn = items.first?.turn.map(String.init) ?? "na"
            return "tool-run-\(turn)-\(items.first?.id ?? "empty")"
        case .turnProcess(let turn): return "turn-process-\(turn)"
        case .turnTail(let turn): return "turn-tail-\(turn)"
        }
    }

    /// The id used by `ForEach` and by `ScrollViewProxy.scrollTo`; both sides
    /// must use this value so the last row is always scrollable.
    var scrollTargetID: String { id }
}
