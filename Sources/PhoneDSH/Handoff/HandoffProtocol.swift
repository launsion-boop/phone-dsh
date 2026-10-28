// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSH: handoff protocol types.
//
// PLAN §2.5 (D15) and spec/v1/handoff.md. This file owns the four
// `/v1/handoff/*` payloads, the `meta_len | metadata JSON | payload` binary
// frame of §3–§5, the fixed limits of §6 and the error classification shared
// by the client, the reclaim path and the in-process remote simulator.
//
// Every request the phone makes is TLS-only and carries the DSH Remote Bearer
// credential; the credential never appears in this module's logs or payloads.

import Foundation
import PhoneDSHLog
import PhoneDSHWire

// MARK: - Limits (handoff.md §3, §4, §6)

/// Fixed limits of phone-dsh-v1 handoff.
public enum HandoffLimits {
    /// Largest snapshot or segments tar (§3/§4: 272 MiB).
    public static let maximumPayloadBytes = 272 * 1024 * 1024
    /// `1 ≤ meta_len ≤ 65536` (§3).
    public static let maximumMetadataBytes = 65_536
    /// Largest single WAL segment file descriptor (§4: 16 MiB).
    public static let maximumSegmentFileBytes = 16 * 1024 * 1024
    /// Defensive bound on one segments request; the tar limit is authoritative.
    public static let maximumSegmentCount = 1_024
    /// The remote caches a reclaim response per token for 24 h (§5).
    public static let reclaimCacheLifetime: TimeInterval = 24 * 60 * 60
    /// Upper bound on the handoff's live page/Worker stop. It never extends a
    /// caller's configured drain deadline; a stop that does not finish in the
    /// window is cancelled and the CAS is not sent.
    public static let workerStopTimeout: TimeInterval = 20
    /// Fence owner while the phone holds execution authority.
    public static let phoneOwner = "phone"
    /// Fence owner while the remote holds execution authority.
    public static let remoteOwner = "remote"
}

// MARK: - Errors

/// A handoff/reclaim failure. Every value is a value so tests and the
/// coordinator can branch without parsing strings.
public enum HandoffError: Error, Equatable, Sendable {
    /// The configured endpoint is not `https`.
    case cleartextEndpoint
    /// The endpoint carries URL credentials, a query or a fragment. The remote
    /// credential belongs in the Authorization header, never in the URL; such
    /// an endpoint is refused before any request or authority intent is written.
    case invalidEndpoint(String)
    /// 401: missing/invalid Bearer credential or invalid reclaim token.
    case unauthorized
    /// 409 `fence_conflict`: the generation CAS lost.
    case fenceConflict
    /// 409 `stale_generation`: a snapshot/segments request names another
    /// generation than the one installed by the CAS.
    case staleGeneration
    /// 409 `snapshot_conflict`: a different snapshot hash for the generation.
    case snapshotConflict
    /// 409 `segments_gap`: the segment ranges do not cover `(base, wal_seq]`.
    case segmentsGap
    /// 400 `bad_request`.
    case badRequest(String)
    /// 400 `payload_mismatch`: length, hash, header or record CRC mismatch.
    case payloadMismatch(String)
    /// 5xx `internal`.
    case internalFailure(String)
    /// The transport failed before an HTTP response was available.
    case transport(String)
    /// A 2xx response body was not a valid handoff payload.
    case invalidResponse(String)
    /// A payload exceeds the 272 MiB limit of §6.
    case payloadTooLarge(bytes: Int)
    /// No closed epoch covers the WAL tail; a snapshot must not be taken.
    case notQuiescent(String)
    /// The injected engine cannot prove it terminated the Worker (no
    /// ``WebEngineShutdownRequesting`` conformance). The host must fail closed
    /// before stopping the loopback or sending the CAS.
    case engineShutdownUnsupported
    /// The selected/returned segments are not contiguous.
    case segmentContinuity(String)
    /// The installed fence does not match the required authority.
    case fenceMismatch(String)
    /// Applying the returned segments failed.
    case applyFailed(String)
    /// The coordinator has no stored reclaim token.
    case noReclaimToken
    /// The App's secure vault could not store/load/remove the token.
    case reclaimTokenStoreFailed(String)
    /// A generation CAS may have succeeded but no safe token/known-fence
    /// evidence exists. Local admission must stay closed; a human must run the
    /// documented manual recovery (handoff.md §5).
    case manualReclaimRequired(String)
    /// The controller is not in a state that allows the operation.
    case invalidControllerState(String)
    /// The task was cancelled while retrying.
    case cancelled
}

extension HandoffError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .cleartextEndpoint:
            return "handoff endpoints must use TLS (https)"
        case .invalidEndpoint(let detail):
            return "invalid handoff endpoint: \(detail)"
        case .unauthorized:
            return "handoff credential was rejected"
        case .fenceConflict:
            return "the handoff fence generation changed"
        case .staleGeneration:
            return "the handoff request names a stale generation"
        case .snapshotConflict:
            return "the snapshot hash conflicts with the stored snapshot"
        case .segmentsGap:
            return "the returned WAL segments are not contiguous"
        case .badRequest(let detail):
            return "invalid handoff request: \(detail)"
        case .payloadMismatch(let detail):
            return "handoff payload mismatch: \(detail)"
        case .internalFailure(let detail):
            return "the remote handoff endpoint failed: \(detail)"
        case .transport(let detail):
            return "handoff transport failed: \(detail)"
        case .invalidResponse(let detail):
            return "invalid handoff response: \(detail)"
        case .payloadTooLarge(let bytes):
            return "handoff payload of \(bytes) bytes exceeds the 272 MiB limit"
        case .notQuiescent(let detail):
            return "the workspace is not quiescent for a handoff: \(detail)"
        case .engineShutdownUnsupported:
            return "the engine cannot terminate the Worker for a handoff"
        case .segmentContinuity(let detail):
            return "WAL segments are not contiguous: \(detail)"
        case .fenceMismatch(let detail):
            return "handoff fence mismatch: \(detail)"
        case .applyFailed(let detail):
            return "applying reclaimed WAL segments failed: \(detail)"
        case .noReclaimToken:
            return "no reclaim token is stored"
        case .reclaimTokenStoreFailed(let detail):
            return "the reclaim token vault failed: \(detail)"
        case .manualReclaimRequired(let detail):
            return "manual reclaim is required: \(detail)"
        case .invalidControllerState(let detail):
            return "the controller state does not allow the handoff: \(detail)"
        case .cancelled:
            return "the handoff operation was cancelled"
        }
    }

    /// `true` when a retry with the same request can succeed (handoff.md §6:
    /// `500` is a remote failure, retry with backoff; transport failures too).
    public var isRetryable: Bool {
        switch self {
        case .transport, .internalFailure:
            return true
        default:
            return false
        }
    }

    /// `true` only when the fence CAS certainly did not change the remote
    /// authority. handoff.md §2 fixes `409 fence_conflict` as "changes
    /// nothing"; a `401` and a locally detected cleartext URL precede any
    /// request. Every other outcome (transport, 5xx, 400, malformed 2xx) is
    /// authority-uncertain because the remote may have applied the CAS before
    /// the response was lost.
    public var isDefiniteFenceRejection: Bool {
        switch self {
        case .fenceConflict, .unauthorized, .cleartextEndpoint, .invalidEndpoint:
            return true
        default:
            return false
        }
    }
}

// MARK: - Endpoint payloads

/// `POST /v1/handoff/fence` request (§2).
public struct HandoffFenceRequest: Codable, Equatable, Sendable {
    public var expectedGeneration: UInt64
    public var walSeq: UInt64

    public init(expectedGeneration: UInt64, walSeq: UInt64) {
        self.expectedGeneration = expectedGeneration
        self.walSeq = walSeq
    }

    enum CodingKeys: String, CodingKey {
        case expectedGeneration = "expected_generation"
        case walSeq = "wal_seq"
    }
}

/// `POST /v1/handoff/fence` response (§2).
public struct HandoffFenceResponse: Codable, Equatable, Sendable {
    public var fence: Fence
    /// 32 lowercase hex characters; the only credential for reclaim.
    public var reclaimToken: String

    public init(fence: Fence, reclaimToken: String) {
        self.fence = fence
        self.reclaimToken = reclaimToken
    }

    enum CodingKeys: String, CodingKey {
        case fence
        case reclaimToken = "reclaim_token"
    }

    /// Structural checks of §2: the returned authority is the remote's next
    /// generation at the phone's target `wal_seq`; the token is 128-bit hex.
    public func validate(expectedGeneration: UInt64, walSeq: UInt64) throws {
        guard fence.owner == HandoffLimits.remoteOwner else {
            throw HandoffError.invalidResponse("handoff fence owner is not remote")
        }
        guard fence.generation == expectedGeneration + 1 else {
            throw HandoffError.invalidResponse(
                "handoff fence generation is not expected_generation + 1")
        }
        guard fence.walSeq == walSeq else {
            throw HandoffError.invalidResponse("handoff fence wal_seq changed")
        }
        guard HandoffHex.isLowercaseHex(reclaimToken, count: 32) else {
            throw HandoffError.invalidResponse("reclaim token is not 128-bit lowercase hex")
        }
    }
}

/// `POST /v1/handoff/snapshot` metadata (§3).
public struct HandoffSnapshotMetadata: Codable, Equatable, Sendable {
    public var generation: UInt64
    public var materializedUptoMseq: UInt64
    public var walSeq: UInt64
    public var payloadBytes: UInt64
    public var payloadSha256: String

    public init(generation: UInt64, materializedUptoMseq: UInt64, walSeq: UInt64,
                payloadBytes: UInt64, payloadSha256: String) {
        self.generation = generation
        self.materializedUptoMseq = materializedUptoMseq
        self.walSeq = walSeq
        self.payloadBytes = payloadBytes
        self.payloadSha256 = payloadSha256
    }

    enum CodingKeys: String, CodingKey {
        case generation
        case materializedUptoMseq = "materialized_upto_mseq"
        case walSeq = "wal_seq"
        case payloadBytes = "payload_bytes"
        case payloadSha256 = "payload_sha256"
    }

    /// Structural checks of §3.
    public func validate() throws {
        guard materializedUptoMseq <= walSeq else {
            throw HandoffError.badRequest("snapshot base is above wal_seq")
        }
        guard payloadBytes <= UInt64(HandoffLimits.maximumPayloadBytes) else {
            throw HandoffError.payloadTooLarge(bytes: Int(clamping: payloadBytes))
        }
        guard HandoffHex.isLowercaseHex(payloadSha256, count: 64) else {
            throw HandoffError.badRequest("payload_sha256 is not lowercase sha256 hex")
        }
    }
}

/// `POST /v1/handoff/snapshot` response (§3).
public struct HandoffSnapshotResponse: Codable, Equatable, Sendable {
    public var materializedUptoMseq: UInt64
    public var fence: Fence
    public var snapshotSha256: String

    public init(materializedUptoMseq: UInt64, fence: Fence, snapshotSha256: String) {
        self.materializedUptoMseq = materializedUptoMseq
        self.fence = fence
        self.snapshotSha256 = snapshotSha256
    }

    enum CodingKeys: String, CodingKey {
        case materializedUptoMseq = "materialized_upto_mseq"
        case fence
        case snapshotSha256 = "snapshot_sha256"
    }
}

/// One WAL segment descriptor of §4.
public struct HandoffSegmentDescriptor: Codable, Equatable, Sendable {
    /// `wal/<epoch:08d>.<segment:06d>.xlwal` (no local absolute path).
    public var file: String
    public var firstMseq: UInt64
    public var lastMseq: UInt64
    public var bytes: UInt64

    public init(file: String, firstMseq: UInt64, lastMseq: UInt64, bytes: UInt64) {
        self.file = file
        self.firstMseq = firstMseq
        self.lastMseq = lastMseq
        self.bytes = bytes
    }

    enum CodingKeys: String, CodingKey {
        case file
        case firstMseq = "first_mseq"
        case lastMseq = "last_mseq"
        case bytes
    }

    /// Structural checks of §4/schema: a relative `wal/` segment name, a
    /// non-empty mutation range, at most 16 MiB.
    public func validate() throws {
        guard Self.isValidFileName(file) else {
            throw HandoffError.badRequest("segment file is not wal/<epoch>.<segment>.xlwal")
        }
        guard firstMseq >= 1, firstMseq <= lastMseq else {
            throw HandoffError.badRequest("segment mseq range is invalid")
        }
        guard bytes >= UInt64(WALSegmentHeader.byteCount),
              bytes <= UInt64(HandoffLimits.maximumSegmentFileBytes) else {
            throw HandoffError.badRequest("segment byte count is outside 40...16 MiB")
        }
    }

    /// `^wal/[0-9]{8}\.[0-9]{6}\.xlwal$`.
    public static func isValidFileName(_ value: String) -> Bool {
        guard value.hasPrefix("wal/") else { return false }
        let name = String(value.dropFirst(4))
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[2] == "xlwal",
              parts[0].count == 8, parts[1].count == 6 else { return false }
        return parts[0].allSatisfy(isASCIIDigit)
            && parts[1].allSatisfy(isASCIIDigit)
    }

    private static func isASCIIDigit(_ byte: Character) -> Bool {
        byte >= "0" && byte <= "9"
    }
}

/// `POST /v1/handoff/segments` metadata (§4).
public struct HandoffSegmentsMetadata: Codable, Equatable, Sendable {
    public var generation: UInt64
    public var baseMseq: UInt64
    public var walSeq: UInt64
    public var segments: [HandoffSegmentDescriptor]
    public var payloadBytes: UInt64
    public var payloadSha256: String

    public init(generation: UInt64, baseMseq: UInt64, walSeq: UInt64,
                segments: [HandoffSegmentDescriptor], payloadBytes: UInt64,
                payloadSha256: String) {
        self.generation = generation
        self.baseMseq = baseMseq
        self.walSeq = walSeq
        self.segments = segments
        self.payloadBytes = payloadBytes
        self.payloadSha256 = payloadSha256
    }

    enum CodingKeys: String, CodingKey {
        case generation
        case baseMseq = "base_mseq"
        case walSeq = "wal_seq"
        case segments
        case payloadBytes = "payload_bytes"
        case payloadSha256 = "payload_sha256"
    }

    /// Structural checks of §4 (the contiguity check needs the segment bytes).
    public func validate() throws {
        guard baseMseq <= walSeq else {
            throw HandoffError.badRequest("segments base is above wal_seq")
        }
        guard segments.count <= HandoffLimits.maximumSegmentCount else {
            throw HandoffError.badRequest("too many segments in one request")
        }
        for descriptor in segments { try descriptor.validate() }
        guard payloadBytes <= UInt64(HandoffLimits.maximumPayloadBytes) else {
            throw HandoffError.payloadTooLarge(bytes: Int(clamping: payloadBytes))
        }
        guard HandoffHex.isLowercaseHex(payloadSha256, count: 64) else {
            throw HandoffError.badRequest("payload_sha256 is not lowercase sha256 hex")
        }
    }
}

/// `POST /v1/handoff/segments` response (§4).
public struct HandoffSegmentsResponse: Codable, Equatable, Sendable {
    public var baseMseq: UInt64
    public var appliedMseq: UInt64
    public var walSeq: UInt64
    public var admission: Admission

    public init(baseMseq: UInt64, appliedMseq: UInt64, walSeq: UInt64,
                admission: Admission) {
        self.baseMseq = baseMseq
        self.appliedMseq = appliedMseq
        self.walSeq = walSeq
        self.admission = admission
    }

    enum CodingKeys: String, CodingKey {
        case baseMseq = "base_mseq"
        case appliedMseq = "applied_mseq"
        case walSeq = "wal_seq"
        case admission
    }

    public func validate(expectedBase: UInt64, expectedWalSeq: UInt64) throws {
        guard baseMseq == expectedBase else {
            throw HandoffError.invalidResponse("segments response names another base")
        }
        guard walSeq == expectedWalSeq else {
            throw HandoffError.invalidResponse("segments response names another wal_seq")
        }
        let open = appliedMseq == walSeq
        guard (admission == .open) == open else {
            throw HandoffError.invalidResponse(
                "remote admission does not match applied_mseq == wal_seq")
        }
    }
}

/// `POST /v1/handoff/reclaim` request (§5).
public struct HandoffReclaimRequest: Codable, Equatable, Sendable {
    public var reclaimToken: String

    public init(reclaimToken: String) {
        self.reclaimToken = reclaimToken
    }

    enum CodingKeys: String, CodingKey {
        case reclaimToken = "reclaim_token"
    }
}

/// `POST /v1/handoff/reclaim` metadata (§5).
public struct HandoffReclaimMetadata: Codable, Equatable, Sendable {
    public var fence: Fence
    public var baseMseq: UInt64
    public var segments: [HandoffSegmentDescriptor]
    public var payloadBytes: UInt64
    public var payloadSha256: String

    public init(fence: Fence, baseMseq: UInt64,
                segments: [HandoffSegmentDescriptor], payloadBytes: UInt64,
                payloadSha256: String) {
        self.fence = fence
        self.baseMseq = baseMseq
        self.segments = segments
        self.payloadBytes = payloadBytes
        self.payloadSha256 = payloadSha256
    }

    enum CodingKeys: String, CodingKey {
        case fence
        case baseMseq = "base_mseq"
        case segments
        case payloadBytes = "payload_bytes"
        case payloadSha256 = "payload_sha256"
    }

    public func validate() throws {
        guard fence.owner == HandoffLimits.phoneOwner else {
            throw HandoffError.invalidResponse("reclaim fence owner is not phone")
        }
        guard baseMseq <= fence.walSeq else {
            throw HandoffError.invalidResponse("reclaim base is above fence.wal_seq")
        }
        guard segments.count <= HandoffLimits.maximumSegmentCount else {
            throw HandoffError.invalidResponse("too many reclaim segments")
        }
        for descriptor in segments { try descriptor.validate() }
        guard payloadBytes <= UInt64(HandoffLimits.maximumPayloadBytes) else {
            throw HandoffError.payloadTooLarge(bytes: Int(clamping: payloadBytes))
        }
        guard HandoffHex.isLowercaseHex(payloadSha256, count: 64) else {
            throw HandoffError.invalidResponse("reclaim payload_sha256 is malformed")
        }
    }
}

/// Error envelope of every endpoint (schema/handoff-error.schema.json).
public struct HandoffErrorEnvelope: Codable, Equatable, Sendable {
    public struct Body: Codable, Equatable, Sendable {
        public var code: String
        public var message: String
        public var generation: UInt64?
        public var appliedMseq: UInt64?
        public var expectedMseq: UInt64?

        public init(code: String, message: String, generation: UInt64? = nil,
                    appliedMseq: UInt64? = nil, expectedMseq: UInt64? = nil) {
            self.code = code
            self.message = message
            self.generation = generation
            self.appliedMseq = appliedMseq
            self.expectedMseq = expectedMseq
        }

        enum CodingKeys: String, CodingKey {
            case code
            case message
            case generation
            case appliedMseq = "applied_mseq"
            case expectedMseq = "expected_mseq"
        }
    }

    public var error: Body

    public init(error: Body) {
        self.error = error
    }
}

// MARK: - Binary frame (§3)

/// The `meta_len u32 | metadata JSON | payload` frame shared by the snapshot,
/// segments and reclaim bodies.
public enum HandoffFrameCodec {
    /// Serializes one complete frame into memory. The client uses
    /// ``HandoffHTTPBody/framed(prefix:payloadFile:)`` instead for large
    /// payloads so the tar is never copied into the address space.
    public static func encode(metadata: Data, payload: Data) throws -> Data {
        try validateMetadataLength(metadata.count)
        guard payload.count <= HandoffLimits.maximumPayloadBytes else {
            throw HandoffError.payloadTooLarge(bytes: payload.count)
        }
        var data = Data(capacity: 4 + metadata.count + payload.count)
        data.appendHandoffUInt32(UInt32(metadata.count))
        data.append(metadata)
        data.append(payload)
        return data
    }

    /// The streamed frame prefix: `meta_len u32 | metadata JSON`. The payload
    /// tar follows from its own file, so the client never materializes the
    /// whole frame in memory.
    public static func prefix(metadata: Data) throws -> Data {
        try validateMetadataLength(metadata.count)
        var data = Data(capacity: 4 + metadata.count)
        data.appendHandoffUInt32(UInt32(metadata.count))
        data.append(metadata)
        return data
    }

    /// Splits a complete frame; `1 ≤ meta_len ≤ 65536` (§3).
    public static func decode(_ data: Data) throws -> (metadata: Data, payload: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else {
            throw HandoffError.badRequest("handoff frame is shorter than meta_len")
        }
        let length = Int(bytes[0]) << 24 | Int(bytes[1]) << 16
            | Int(bytes[2]) << 8 | Int(bytes[3])
        try validateMetadataLength(length)
        guard bytes.count >= 4 + length else {
            throw HandoffError.badRequest("handoff frame metadata is truncated")
        }
        let metadata = Data(bytes[4..<(4 + length)])
        let payload = Data(bytes[(4 + length)...])
        guard payload.count <= HandoffLimits.maximumPayloadBytes else {
            throw HandoffError.payloadTooLarge(bytes: payload.count)
        }
        return (metadata, payload)
    }

    private static func validateMetadataLength(_ length: Int) throws {
        guard length >= 1, length <= HandoffLimits.maximumMetadataBytes else {
            throw HandoffError.badRequest("meta_len \(length) is outside 1...65536")
        }
    }
}

// MARK: - JSON codec

/// Canonical JSON (D5) for every metadata object. Decoding accepts any legal
/// member order and whitespace, as the spec requires.
enum HandoffJSON {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        do {
            return try CanonicalJSON.encode(value)
        } catch let error as HandoffError {
            throw error
        } catch {
            throw HandoffError.invalidResponse("cannot encode handoff JSON")
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw HandoffError.badRequest("malformed handoff JSON metadata")
        }
    }
}

// MARK: - Hex and byte helpers

enum HandoffHex {
    static func encode(_ data: Data) -> String {
        var output = String()
        output.reserveCapacity(data.count * 2)
        let digits = Array("0123456789abcdef".utf8)
        for byte in data {
            output.append(Character(UnicodeScalar(digits[Int(byte >> 4)])))
            output.append(Character(UnicodeScalar(digits[Int(byte & 0x0F)])))
        }
        return output
    }

    static func decode(_ value: String) -> Data? {
        let bytes = Array(value.utf8)
        guard bytes.count % 2 == 0 else { return nil }
        var output = [UInt8]()
        output.reserveCapacity(bytes.count / 2)
        var index = 0
        while index < bytes.count {
            guard let high = nibble(bytes[index]), let low = nibble(bytes[index + 1]) else {
                return nil
            }
            output.append(high << 4 | low)
            index += 2
        }
        return Data(output)
    }

    static func isLowercaseHex(_ value: String, count: Int) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == count else { return false }
        return bytes.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
    }

    private static func nibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: return byte - 48
        case 97...102: return byte - 87
        default: return nil
        }
    }
}

extension Data {
    mutating func appendHandoffUInt32(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendHandoffUInt64(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            append(UInt8((value >> UInt64(shift)) & 0xFF))
        }
    }
}

// MARK: - Retry policy

/// Idempotent retry policy used by ``ReclaimClient`` (handoff.md §5/§6).
public struct HandoffRetryPolicy: Equatable, Sendable {
    /// Total attempts, including the first one.
    public var maximumAttempts: Int
    /// First backoff delay in seconds.
    public var baseDelay: TimeInterval
    /// Upper bound of the exponential backoff.
    public var maximumDelay: TimeInterval

    public init(maximumAttempts: Int = 3, baseDelay: TimeInterval = 0.25,
                maximumDelay: TimeInterval = 4) {
        self.maximumAttempts = max(1, maximumAttempts)
        self.baseDelay = max(0, baseDelay)
        self.maximumDelay = max(self.baseDelay, maximumDelay)
    }

    /// Delay before attempt `attempt` (1-based; attempt 1 has no delay).
    public func delay(beforeAttempt attempt: Int) -> TimeInterval {
        guard attempt > 1, baseDelay > 0 else { return 0 }
        let exponent = min(attempt - 2, 10)
        return min(maximumDelay, baseDelay * pow(2, Double(exponent)))
    }
}
