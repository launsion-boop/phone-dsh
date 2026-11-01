// SPDX-License-Identifier: MIT

import Foundation

public struct PhoneToolPayload {
    public var data: [String: Any]
    public var nextCursor: Any
    public var truncated: Bool

    public init(data: [String: Any], nextCursor: Any = NSNull(), truncated: Bool = false) {
        self.data = data
        self.nextCursor = nextCursor
        self.truncated = truncated
    }
}
