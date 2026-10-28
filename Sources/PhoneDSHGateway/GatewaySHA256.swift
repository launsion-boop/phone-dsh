// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHGateway: SHA-256.
//
// The response log key is the SHA-256 of the canonical request identity
// (PLAN §2.5, W1-GATEWAY). The gateway module otherwise depends on Foundation
// only; this small implementation keeps the key derivation dependency-free so
// the same code can run wherever the phone host is built.

import Foundation

/// Minimal SHA-256 (FIPS 180-4) used for response-log keys.
enum GatewaySHA256 {
    /// Lowercase hexadecimal SHA-256 digest of `data`.
    static func hexDigest(_ data: Data) -> String {
        digest(data).map { String(format: "%02x", $0) }.joined()
    }

    /// Raw 32-byte SHA-256 digest of `data`.
    static func digest(_ data: Data) -> [UInt8] {
        var message = [UInt8](data)
        let bitLength = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 {
            message.append(0)
        }
        for shift in stride(from: 56, through: 0, by: -8) {
            message.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift)))
        }

        var state: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
        ]
        var schedule = [UInt32](repeating: 0, count: 64)

        for chunk in stride(from: 0, to: message.count, by: 64) {
            for index in 0..<16 {
                let base = chunk + index * 4
                schedule[index] = (UInt32(message[base]) << 24)
                    | (UInt32(message[base + 1]) << 16)
                    | (UInt32(message[base + 2]) << 8)
                    | UInt32(message[base + 3])
            }
            for index in 16..<64 {
                let s0 = rotateRight(schedule[index - 15], 7)
                    ^ rotateRight(schedule[index - 15], 18)
                    ^ (schedule[index - 15] >> 3)
                let s1 = rotateRight(schedule[index - 2], 17)
                    ^ rotateRight(schedule[index - 2], 19)
                    ^ (schedule[index - 2] >> 10)
                schedule[index] = schedule[index - 16] &+ s0
                    &+ schedule[index - 7] &+ s1
            }

            var a = state[0], b = state[1], c = state[2], d = state[3]
            var e = state[4], f = state[5], g = state[6], h = state[7]
            for index in 0..<64 {
                let s1 = rotateRight(e, 6) ^ rotateRight(e, 11) ^ rotateRight(e, 25)
                let choice = (e & f) ^ (~e & g)
                let temp1 = h &+ s1 &+ choice &+ roundConstants[index] &+ schedule[index]
                let s0 = rotateRight(a, 2) ^ rotateRight(a, 13) ^ rotateRight(a, 22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ majority
                h = g
                g = f
                f = e
                e = d &+ temp1
                d = c
                c = b
                b = a
                a = temp1 &+ temp2
            }
            state[0] &+= a
            state[1] &+= b
            state[2] &+= c
            state[3] &+= d
            state[4] &+= e
            state[5] &+= f
            state[6] &+= g
            state[7] &+= h
        }

        var output = [UInt8]()
        output.reserveCapacity(32)
        for word in state {
            output.append(UInt8(truncatingIfNeeded: word >> 24))
            output.append(UInt8(truncatingIfNeeded: word >> 16))
            output.append(UInt8(truncatingIfNeeded: word >> 8))
            output.append(UInt8(truncatingIfNeeded: word))
        }
        return output
    }

    private static func rotateRight(_ value: UInt32, _ amount: UInt32) -> UInt32 {
        (value >> amount) | (value << (32 - amount))
    }

    private static let roundConstants: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
        0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
        0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
        0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
        0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]
}
