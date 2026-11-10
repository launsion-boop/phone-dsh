// SPDX-License-Identifier: MIT

import SwiftUI

private struct BotPageActiveKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// True while the Bot page is the selected tab and the app scene is active.
    ///
    /// `NativeShell` computes this once from the selected tab and
    /// `AppModel.isSceneActive`, then injects both this key and the existing
    /// `botFishPaused` key from the same value. The Bot page uses it to stop
    /// its UI-only polling while hidden; the runtime, routines, delivery and
    /// keep-alive never read it.
    var botPageActive: Bool {
        get { self[BotPageActiveKey.self] }
        set { self[BotPageActiveKey.self] = newValue }
    }
}
