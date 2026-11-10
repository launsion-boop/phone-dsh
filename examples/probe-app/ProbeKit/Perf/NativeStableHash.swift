// SPDX-License-Identifier: MIT
// Process-local content hash for cache keys. FNV-1a is cheap enough to run on
// a code block or a diff side; SHA-256 is deliberately avoided on the streaming
// Markdown path, where the parser cache keys by item revision instead.

import Foundation

public enum NativeStableHash {
    public static func fnv1a64(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    public static func fnv1a64(_ text: String, seed: UInt64) -> UInt64 {
        var hash = seed
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}
