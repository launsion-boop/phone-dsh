// SPDX-License-Identifier: MIT

import Foundation

/// Owns the single App-level connector and Personal Agent composition root.
public struct AppComposition: Sendable {
    public static let shared = AppComposition()

    public init() {}
}
