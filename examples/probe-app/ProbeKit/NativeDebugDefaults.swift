// SPDX-License-Identifier: MIT
// Debug-only UI defaults. The environment variable is read only in DEBUG
// builds; Release always returns the production default.

import Foundation

public enum NativeDebugDefaults {
    /// `PDSH_DEBUG_DRAWER=1` opens the sidebar at launch in DEBUG builds only.
    public static func drawerOpen(environment: [String: String]) -> Bool {
        #if DEBUG
        return environment["PDSH_DEBUG_DRAWER"] == "1"
        #else
        _ = environment
        return false
        #endif
    }
}
