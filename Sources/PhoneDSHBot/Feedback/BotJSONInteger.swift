// SPDX-License-Identifier: MIT

import Foundation

/// Bot-layer exact JSON-integer conversion. A JSON number is a Double here, so
/// `Int(number)` / `Int64(number)` traps for legal values such as 1e300,
/// `Double.greatestFiniteMagnitude`, NaN or infinity. `Int(exactly:)` returns
/// nil for all non-integral/out-of-range values; callers turn nil into an
/// explicit invalid-arguments result (tools) or omit the corrupt field (event
/// replay), never a crash.
enum BotJSONInteger {
    static func int(_ value: BotJSONValue?) -> Int? {
        guard case .number(let number)? = value else { return nil }
        return Int(exactly: number)
    }

    static func int64(_ value: BotJSONValue?) -> Int64? {
        guard case .number(let number)? = value else { return nil }
        return Int64(exactly: number)
    }
}
