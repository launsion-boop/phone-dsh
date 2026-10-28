// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHWire: protocol limits, identifier
// syntax and errors.
//
// PLAN §2.2 (D4/D6) and spec/v1/channel.md §1, §6 and §10. This file
// is the single source of the size caps and of the syntax checks the host must
// run before an identifier or a VFS path reaches the filesystem.

import Foundation

/// Byte limits of phone-dsh-v1 channel and WAL formats.
public enum WireLimits {
    /// One mebibyte: `MB`/`MiB` of budgets.md §4 are 1 048 576 bytes.
    public static let mebibyte = 1024 * 1024
    /// Fixed frame header size, channel.md §1.
    public static let headerBytes = 16
    /// Frame header magic, channel.md §1.
    public static let magic: UInt16 = 0x5A4C
    /// Maximum frame payload; channel.md §1 (`len ≤ 16 MiB`).
    public static let maxFramePayloadBytes = 16 * mebibyte
    /// Maximum data of one complete VFS write; channel.md §3.1. The large-file
    /// budget does not raise this per-mutation cap (`15 MiB`); a larger file is
    /// published as complete/append chunks below the single-file limit.
    public static let maxMutationDataBytes = 15 * mebibyte
    /// Default single-file budget of the 8 GiB tier (budgets.md §4). The host
    /// may configure `single_file_limit` in 16 MiB ... 128 MiB, gated by the
    /// device tier; this is the one default the log and the wire agree on.
    public static let defaultSingleFileLimitBytes = 64 * mebibyte
    /// Maximum API_REQ body; channel.md §3.7 (`4 MiB`).
    public static let maxAPIBodyBytes = 4 * mebibyte
    /// Maximum length of a D6 identifier, in bytes; channel.md §6.
    public static let maxIdentifierBytes = 64
    /// A boot id is exactly 32 lowercase hexadecimal characters; D6.
    public static let bootIDCharacters = 32
    /// `path_len` is a `u16`; channel.md §3.1.
    public static let maxPathBytes = Int(UInt16.max)
    /// An `idem_key` is 64 lowercase hexadecimal characters; channel.md §4.2.
    public static let idemKeyCharacters = 64
    /// WAL segment header size; wal.md §2.
    public static let walHeaderBytes = 40
    /// WAL segment-header format number; wal.md §2.
    public static let walFormat: UInt16 = 1
    /// Epoch-close record op byte; wal.md §4.
    public static let walEpochCloseOp: UInt8 = 0xFF
}

/// Identifier, capability, path and digest syntax of phone-dsh-v1.
///
/// These are pure checks with no filesystem access, so the channel and WAL
/// layers can validate untrusted bytes before touching the workspace.
public enum WireValidation {
    /// D6 identifiers: `^[A-Za-z0-9._-]{1,64}$`.
    public static func isValidIdentifier(_ value: String) -> Bool {
        let bytes = value.utf8
        guard !bytes.isEmpty, bytes.count <= WireLimits.maxIdentifierBytes else { return false }
        return bytes.allSatisfy(isIdentifierByte)
    }

    /// Fence owners: `^[A-Za-z0-9._:-]{1,64}$` (channel.md §4.1).
    public static func isValidFenceOwner(_ value: String) -> Bool {
        let bytes = value.utf8
        guard !bytes.isEmpty, bytes.count <= WireLimits.maxIdentifierBytes else { return false }
        return bytes.allSatisfy { isIdentifierByte($0) || $0 == UInt8(ascii: ":") }
    }

    /// A boot id is exactly 32 lowercase hexadecimal characters (D6).
    public static func isValidBootID(_ value: String) -> Bool {
        let bytes = value.utf8
        guard bytes.count == WireLimits.bootIDCharacters else { return false }
        return bytes.allSatisfy { ($0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9")) ||
            ($0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "f")) }
    }

    /// `idem_key`: 64 lowercase hexadecimal characters (channel.md §4.2).
    public static func isValidIdemKey(_ value: String) -> Bool {
        let bytes = value.utf8
        guard bytes.count == WireLimits.idemKeyCharacters else { return false }
        return bytes.allSatisfy { ($0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9")) ||
            ($0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "f")) }
    }

    /// Mutation paths: `^/dsh/(home|workspace)(/[^/]+)+$` with no `.` or `..`
    /// component and no empty component (D4, channel.md §6).
    public static func isValidMutationPath(_ path: String) -> Bool {
        guard path.utf8.count <= WireLimits.maxPathBytes else { return false }
        let prefix: String
        if path.hasPrefix("/dsh/home/") {
            prefix = "/dsh/home/"
        } else if path.hasPrefix("/dsh/workspace/") {
            prefix = "/dsh/workspace/"
        } else {
            return false
        }
        let relative = path.dropFirst(prefix.count)
        guard !relative.isEmpty else { return false }
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty else { return false }
        return components.allSatisfy { component in
            !component.isEmpty && component != "." && component != ".."
        }
    }

    /// Capability strings: `<name>/<integer>` or `accelerator:<name>`
    /// (channel.md §4.1).
    public static func isValidCapability(_ value: String) -> Bool {
        if let name = value.split(separator: ":", maxSplits: 1).first,
           name == "accelerator", value.hasPrefix("accelerator:") {
            let accelerator = value.dropFirst("accelerator:".count)
            guard !accelerator.isEmpty, accelerator.utf8.count <= WireLimits.maxIdentifierBytes else {
                return false
            }
            return accelerator.utf8.allSatisfy(isIdentifierByte)
        }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        guard let name = parts.first, !name.isEmpty, name.utf8.count <= WireLimits.maxIdentifierBytes,
              name.utf8.allSatisfy({ ($0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "z")) ||
                  ($0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9")) || $0 == UInt8(ascii: "-") })
        else { return false }
        return !parts[1].isEmpty && parts[1].allSatisfy { $0 >= "0" && $0 <= "9" }
    }

    /// Lowercase HTTP token used for API header names in heads
    /// (spec/v1/schema/api-request-head.schema.json).
    public static func isValidLowercaseHeaderName(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        let allowedPunctuation = Set("!#$%&'*+.^_`|~-")
        return value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x61...0x7A, 0x30...0x39:
                return true
            default:
                return allowedPunctuation.contains(Character(scalar))
            }
        }
    }

    private static func isIdentifierByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "-"):
            return true
        default:
            return false
        }
    }
}

/// Error codes of the ordered channel (channel.md §10).
public enum PhoneWireErrorCode: String, Codable, CaseIterable, Sendable {
    case badMagic = "BAD_MAGIC"
    case badSeq = "BAD_SEQ"
    case badMseq = "BAD_MSEQ"
    case badPath = "BAD_PATH"
    case badPayload = "BAD_PAYLOAD"
    case fenceStale = "FENCE_STALE"
    case vfsConflict = "VFS_CONFLICT"
    /// Worker: the VFS sink refused a mutation for a resource limit
    /// (`EFBIG`, `ENOSPC`, quota). The only non-closing ERROR code; it carries
    /// `path`/`limit`/`reason` and consumes no mseq (channel.md §4.8, §10).
    case vfsRefused = "VFS_REFUSED"
    case ringTimeout = "RING_TIMEOUT"
    case protoMismatch = "PROTO_MISMATCH"

    /// True when sending this ERROR closes the ordered channel (channel.md §10).
    ///
    /// A resource refusal is a diagnostic, not a protocol violation: the host
    /// records it and keeps the connection open.
    public var closesConnection: Bool { self != .vfsRefused }
}

/// A protocol violation carrying the ERROR code it maps to.
public struct PhoneWireError: Error, Equatable, Sendable {
    /// The channel.md §10 code to report to the peer.
    public var code: PhoneWireErrorCode
    /// Human-readable diagnostic; never contains a local path or credential.
    public var message: String
    /// Sequence number of the offending frame, when known.
    public var refSeq: UInt64?

    public init(code: PhoneWireErrorCode, message: String, refSeq: UInt64? = nil) {
        self.code = code
        self.message = message
        self.refSeq = refSeq
    }
}

extension PhoneWireError: CustomStringConvertible {
    public var description: String {
        if let refSeq {
            return "\(code.rawValue) (seq \(refSeq)): \(message)"
        }
        return "\(code.rawValue): \(message)"
    }
}
