// SPDX-License-Identifier: MIT

import ProbeKit

/// The one invariant every tool-row list needs before it reaches `ForEach`:
/// `ChatItem.id` is the journal-sequencing identity and must be unique.
///
/// A live observer can be re-attached across a park/resume and replay the open
/// turn. If both the original frame and the replay reach the projection, two
/// `ChatItem`s carry the same id. SwiftUI's `ForEach` silently accepts the
/// collection but the lazy transcript then keeps placing the duplicate row and
/// the app hangs on the main thread. Deduplicate at the row boundary as a
/// defence in depth, after the live/journal projections have done the same.
enum NativeToolRowIdentity {
    static func unique(_ items: [ChatItem]) -> [ChatItem] {
        var seen: Set<String> = []
        return items.filter { seen.insert($0.id).inserted }
    }
}
