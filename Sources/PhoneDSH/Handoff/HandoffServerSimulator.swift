// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSH: in-process remote simulator.
//
// PLAN §2.5 (D15) and spec/v1/handoff.md §2–§5. The simulator
// implements the four `/v1/handoff/*` endpoints as an in-process
// ``HandoffHTTPTransport`` for the tests and the macOS cycle checks: it
// verifies the Bearer credential, enforces the fence CAS, unpacks the snapshot
// atomically, validates segment contiguity/headers/CRCs, applies each mutation
// exactly once with the wal.md §6 rules, opens admission only when
// `applied_mseq == fence.wal_seq`, and caches the reclaim response per token
// for 24 h so a lost response replays byte for byte.
//
// This is a test/verification double for the remote DSH Remote side, not a
// server implementation of the production transport.

import Darwin
import Foundation
import PhoneDSHLog
import PhoneDSHWire

/// Configuration of one simulated remote workspace.
public struct HandoffServerSimulatorConfiguration: Sendable {
    /// Remote workspace root; the simulator owns it.
    public var root: URL
    /// 16 raw bytes used in the returned WAL segment headers.
    public var bootID: Data
    /// Bearer credential the remote accepts.
    public var bearerToken: String
    /// Provisioned authority (`{owner:"phone", generation:0, wal_seq:0}` for a
    /// fresh pairing, handoff.md §2).
    public var initialFence: Fence
    /// How long the reclaim response cache lives (24 h by default).
    public var reclaimCacheLifetime: TimeInterval
    /// Wall clock; injectable so the cache-expiry test is deterministic.
    public var clock: @Sendable () -> Date

    public init(root: URL, bootID: Data, bearerToken: String,
                initialFence: Fence = Fence(owner: HandoffLimits.phoneOwner,
                                           generation: 0, walSeq: 0),
                reclaimCacheLifetime: TimeInterval = HandoffLimits.reclaimCacheLifetime,
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.root = root
        self.bootID = bootID
        self.bearerToken = bearerToken
        self.initialFence = initialFence
        self.reclaimCacheLifetime = reclaimCacheLifetime
        self.clock = clock
    }
}

/// Endpoint counters the tests assert on.
public struct HandoffSimulatorCounters: Equatable, Sendable {
    public var fenceRequests: Int = 0
    public var snapshotUploads: Int = 0
    public var segmentsUploads: Int = 0
    public var reclaimRequests: Int = 0

    public init() {}
}

/// The in-process remote (see the file header).
public actor HandoffServerSimulator: HandoffHTTPTransport {
    public let configuration: HandoffServerSimulatorConfiguration

    private struct ReclaimCacheEntry: Sendable {
        var metadata: HandoffReclaimMetadata
        var payload: Data
        var createdAt: Date
    }

    private struct RemoteError: Error {
        var status: Int
        var code: String
        var message: String
        var generation: UInt64?
        var appliedMseq: UInt64?
        var expectedMseq: UInt64?

        init(status: Int, code: String, message: String,
             generation: UInt64? = nil, appliedMseq: UInt64? = nil,
             expectedMseq: UInt64? = nil) {
            self.status = status
            self.code = code
            self.message = message
            self.generation = generation
            self.appliedMseq = appliedMseq
            self.expectedMseq = expectedMseq
        }
    }

    private let paths: WorkspacePaths
    private var fence: Fence
    private var admissionOpen = false

    private var snapshotBase: UInt64?
    private var snapshotHash: String?
    private var snapshotGeneration: UInt64?
    private var appliedMseq: UInt64 = 0
    private var remoteRecords: [UInt64: WALRecord] = [:]
    private var remoteMaterializer: Materializer?

    private var reclaimToken: String?
    private var reclaimTokenIssuedAt: Date?
    private var reclaimCache: [String: ReclaimCacheEntry] = [:]
    private var reclaimResponseCount = 0

    private var counters = HandoffSimulatorCounters()

    /// Creates the remote workspace directories.
    public init(configuration: HandoffServerSimulatorConfiguration) throws {
        guard configuration.bootID.count == 16 else {
            throw HandoffError.badRequest("simulator boot_id must be 16 raw bytes")
        }
        self.configuration = configuration
        self.paths = WorkspacePaths(root: configuration.root)
        self.fence = configuration.initialFence
        do {
            try paths.createDirectories()
        } catch {
            throw HandoffError.badRequest("cannot create the simulated remote workspace")
        }
    }

    // MARK: - Test conveniences

    public func currentFence() -> Fence { fence }
    public func appliedMseqValue() -> UInt64 { appliedMseq }
    public func isAdmissionOpen() -> Bool { admissionOpen }
    public func endpointCounters() -> HandoffSimulatorCounters { counters }
    public func cachedReclaimEntries() -> Int { reclaimCache.count }
    public func remoteMaterializedDirectory() -> URL { paths.materializedDirectory }
    public func remoteMaterializedFile(_ path: String) -> URL {
        paths.materializedDirectory.appendingPathComponent(path)
    }

    /// Appends one mutation on the remote while it holds execution authority.
    /// Returns the mseq assigned; throws when admission is closed.
    @discardableResult
    public func appendRemoteMutation(_ mutation: VfsMutationBody) async throws -> UInt64 {
        guard fence.owner == HandoffLimits.remoteOwner else {
            throw HandoffError.invalidControllerState("the remote does not hold the fence")
        }
        guard admissionOpen, let materializer = remoteMaterializer else {
            throw HandoffError.invalidControllerState("remote admission is closed")
        }
        let mseq = appliedMseq + 1
        let record: WALRecord
        do {
            record = try WALRecord(mseq: mseq, mutation: mutation)
            _ = try materializer.apply(record)
            try materializer.fsyncEpoch()
        } catch {
            throw HandoffError.applyFailed("the remote could not apply a mutation")
        }
        remoteRecords[mseq] = record
        appliedMseq = max(appliedMseq, materializer.materializedUptoMseq)
        return mseq
    }

    // MARK: - HandoffHTTPTransport

    public func send(_ request: HandoffHTTPRequest) async throws -> HandoffHTTPResponse {
        do {
            try authorize(request)
            guard request.method == "POST" else {
                throw RemoteError(status: 400, code: "bad_request",
                                  message: "handoff endpoints accept POST only")
            }
            switch request.url.path {
            case "/v1/handoff/fence":
                return try handleFence(request)
            case "/v1/handoff/snapshot":
                return try handleSnapshot(request)
            case "/v1/handoff/segments":
                return try handleSegments(request)
            case "/v1/handoff/reclaim":
                return try handleReclaim(request)
            default:
                throw RemoteError(status: 400, code: "bad_request",
                                  message: "unknown handoff endpoint")
            }
        } catch let error as RemoteError {
            return errorResponse(error)
        } catch let error as HandoffError {
            return errorResponse(map(error))
        } catch {
            return errorResponse(RemoteError(status: 500, code: "internal",
                                             message: "simulated remote failure"))
        }
    }

    // MARK: - Endpoints

    private func handleFence(_ request: HandoffHTTPRequest) throws -> HandoffHTTPResponse {
        counters.fenceRequests += 1
        let body = try request.body.materializedData()
        let decoded: HandoffFenceRequest
        do {
            decoded = try JSONDecoder().decode(HandoffFenceRequest.self, from: body)
        } catch {
            throw RemoteError(status: 400, code: "bad_request",
                              message: "malformed fence request")
        }
        guard decoded.expectedGeneration == fence.generation else {
            throw RemoteError(status: 409, code: "fence_conflict",
                              message: "expected_generation does not match the remote fence",
                              generation: fence.generation)
        }
        guard decoded.walSeq >= fence.walSeq else {
            throw RemoteError(status: 409, code: "fence_conflict",
                              message: "wal_seq regresses",
                              generation: fence.generation)
        }
        let token = Self.randomToken()
        fence = Fence(owner: HandoffLimits.remoteOwner,
                      generation: decoded.expectedGeneration + 1,
                      walSeq: decoded.walSeq)
        reclaimToken = token
        reclaimTokenIssuedAt = configuration.clock()
        admissionOpen = false
        do {
            try resetRemoteWorkspace()
        } catch {
            throw RemoteError(status: 500, code: "internal",
                              message: "cannot reset the simulated remote workspace")
        }
        let response = HandoffFenceResponse(fence: fence, reclaimToken: token)
        return try jsonResponse(response)
    }

    private func handleSnapshot(_ request: HandoffHTTPRequest) throws -> HandoffHTTPResponse {
        let payload = try request.body.materializedData()
        let frame: (metadata: Data, payload: Data)
        do {
            frame = try HandoffFrameCodec.decode(payload)
        } catch let error as HandoffError {
            throw map(error)
        } catch {
            throw RemoteError(status: 400, code: "bad_request",
                              message: "malformed snapshot frame")
        }
        let metadata: HandoffSnapshotMetadata
        do {
            metadata = try JSONDecoder().decode(HandoffSnapshotMetadata.self,
                                                from: frame.metadata)
        } catch {
            throw RemoteError(status: 400, code: "bad_request",
                              message: "malformed snapshot metadata")
        }
        try validate(metadata)
        guard metadata.generation == fence.generation,
              fence.owner == HandoffLimits.remoteOwner else {
            throw RemoteError(status: 409, code: "stale_generation",
                              message: "snapshot generation is not current",
                              generation: fence.generation)
        }
        guard metadata.walSeq == fence.walSeq else {
            throw RemoteError(status: 400, code: "bad_request",
                              message: "snapshot wal_seq does not match the fence")
        }
        guard UInt64(frame.payload.count) == metadata.payloadBytes else {
            throw RemoteError(status: 400, code: "payload_mismatch",
                              message: "snapshot payload_bytes does not match the body")
        }
        let digest = SHA256.hash(frame.payload)
        guard digest == metadata.payloadSha256 else {
            throw RemoteError(status: 400, code: "payload_mismatch",
                              message: "snapshot payload_sha256 does not match the body")
        }
        counters.snapshotUploads += 1
        if snapshotGeneration == metadata.generation {
            guard snapshotHash == metadata.payloadSha256,
                  snapshotBase == metadata.materializedUptoMseq else {
                throw RemoteError(status: 409, code: "snapshot_conflict",
                                  message: "a different snapshot is stored for this generation")
            }
            let response = HandoffSnapshotResponse(
                materializedUptoMseq: metadata.materializedUptoMseq,
                fence: fence,
                snapshotSha256: metadata.payloadSha256)
            return try jsonResponse(response)
        }
        let entries: [HandoffTarEntry]
        do {
            entries = try HandoffTar.decode(frame.payload)
        } catch let error as HandoffError {
            throw map(error)
        } catch {
            throw RemoteError(status: 400, code: "payload_mismatch",
                              message: "malformed snapshot tar")
        }
        do {
            try unpackSnapshot(entries: entries)
        } catch let error as HandoffError {
            throw error
        } catch {
            throw RemoteError(status: 500, code: "internal",
                              message: "cannot store the snapshot")
        }
        snapshotBase = metadata.materializedUptoMseq
        snapshotHash = metadata.payloadSha256
        snapshotGeneration = metadata.generation
        appliedMseq = metadata.materializedUptoMseq
        remoteRecords = [:]
        remoteMaterializer = try Materializer(
            root: configuration.root,
            materializedUptoMseq: metadata.materializedUptoMseq)
        admissionOpen = false
        let response = HandoffSnapshotResponse(
            materializedUptoMseq: metadata.materializedUptoMseq,
            fence: fence,
            snapshotSha256: metadata.payloadSha256)
        return try jsonResponse(response)
    }

    private func handleSegments(_ request: HandoffHTTPRequest) throws -> HandoffHTTPResponse {
        let body = try request.body.materializedData()
        let frame: (metadata: Data, payload: Data)
        do {
            frame = try HandoffFrameCodec.decode(body)
        } catch let error as HandoffError {
            throw map(error)
        } catch {
            throw RemoteError(status: 400, code: "bad_request",
                              message: "malformed segments frame")
        }
        let metadata: HandoffSegmentsMetadata
        do {
            metadata = try JSONDecoder().decode(HandoffSegmentsMetadata.self,
                                                from: frame.metadata)
        } catch {
            throw RemoteError(status: 400, code: "bad_request",
                              message: "malformed segments metadata")
        }
        try validate(metadata)
        guard metadata.generation == fence.generation,
              fence.owner == HandoffLimits.remoteOwner else {
            throw RemoteError(status: 409, code: "stale_generation",
                              message: "segments generation is not current",
                              generation: fence.generation)
        }
        guard let base = snapshotBase else {
            throw RemoteError(status: 409, code: "snapshot_conflict",
                              message: "no snapshot was stored for this generation")
        }
        guard metadata.baseMseq == base else {
            throw RemoteError(status: 409, code: "snapshot_conflict",
                              message: "segments base does not match the stored snapshot")
        }
        guard metadata.walSeq == fence.walSeq else {
            throw RemoteError(status: 400, code: "bad_request",
                              message: "segments wal_seq does not match the fence")
        }
        guard UInt64(frame.payload.count) == metadata.payloadBytes else {
            throw RemoteError(status: 400, code: "payload_mismatch",
                              message: "segments payload_bytes does not match the body")
        }
        guard SHA256.hash(frame.payload) == metadata.payloadSha256 else {
            throw RemoteError(status: 400, code: "payload_mismatch",
                              message: "segments payload_sha256 does not match the body")
        }
        counters.segmentsUploads += 1

        let files: [HandoffSegmentFile]
        let validated: [(descriptor: HandoffSegmentDescriptor, segment: WALSegment)]
        let mutations: [WALRecord]
        do {
            files = try HandoffSegmentArchive.decode(frame.payload)
            validated = try HandoffSegmentArchive.validate(files: files,
                                                           descriptors: metadata.segments)
            mutations = try HandoffSegmentArchive.mutationRecords(
                validated, baseMseq: base, walSeq: fence.walSeq)
        } catch HandoffError.segmentContinuity(let detail) {
            throw RemoteError(status: 409, code: "segments_gap",
                              message: detail, appliedMseq: appliedMseq,
                              expectedMseq: appliedMseq + 1)
        } catch let error as HandoffError {
            throw map(error)
        } catch {
            throw RemoteError(status: 400, code: "payload_mismatch",
                              message: "segments payload is invalid")
        }
        guard let materializer = remoteMaterializer else {
            throw RemoteError(status: 500, code: "internal",
                              message: "the snapshot materializer is missing")
        }
        do {
            for record in mutations {
                if record.mseq > base {
                    remoteRecords[record.mseq] = record
                }
                if record.mseq <= appliedMseq { continue }
                guard record.mseq == appliedMseq + 1 else {
                    throw RemoteError(status: 409, code: "segments_gap",
                                      message: "a mutation was not applied in order",
                                      appliedMseq: appliedMseq,
                                      expectedMseq: appliedMseq + 1)
                }
                _ = try materializer.apply(record)
                appliedMseq = max(appliedMseq, materializer.materializedUptoMseq)
            }
            try materializer.fsyncEpoch()
        } catch let error as RemoteError {
            throw error
        } catch {
            throw RemoteError(status: 500, code: "internal",
                              message: "the remote could not apply the segments")
        }
        appliedMseq = materializer.materializedUptoMseq
        admissionOpen = appliedMseq == fence.walSeq
        let response = HandoffSegmentsResponse(
            baseMseq: base,
            appliedMseq: appliedMseq,
            walSeq: fence.walSeq,
            admission: admissionOpen ? .open : .closed)
        return try jsonResponse(response)
    }

    private func handleReclaim(_ request: HandoffHTTPRequest) throws -> HandoffHTTPResponse {
        counters.reclaimRequests += 1
        let body = try request.body.materializedData()
        let decoded: HandoffReclaimRequest
        do {
            decoded = try JSONDecoder().decode(HandoffReclaimRequest.self, from: body)
        } catch {
            throw RemoteError(status: 400, code: "bad_request",
                              message: "malformed reclaim request")
        }
        guard HandoffHex.isLowercaseHex(decoded.reclaimToken, count: 32) else {
            throw RemoteError(status: 401, code: "unauthorized",
                              message: "invalid reclaim token")
        }
        let now = configuration.clock()
        if let cached = reclaimCache[decoded.reclaimToken],
           now.timeIntervalSince(cached.createdAt) < configuration.reclaimCacheLifetime {
            return try framedResponse(cached.metadata, payload: cached.payload)
        } else if reclaimCache.removeValue(forKey: decoded.reclaimToken) != nil {
            // The cached response expired; the token is invalid from now on.
            throw RemoteError(status: 401, code: "unauthorized",
                              message: "the reclaim token expired")
        }
        guard decoded.reclaimToken == reclaimToken else {
            throw RemoteError(status: 401, code: "unauthorized",
                              message: "unknown reclaim token")
        }
        if let issuedAt = reclaimTokenIssuedAt,
           now.timeIntervalSince(issuedAt) >= configuration.reclaimCacheLifetime {
            throw RemoteError(status: 401, code: "unauthorized",
                              message: "the reclaim token expired")
        }
        // §5: close admission, freeze the highest mutation mseq, return every
        // segment in (base, wal_seq] and install the phone's next generation.
        admissionOpen = false
        // If the snapshot never arrived, the fence target from §2 is the
        // retained phone watermark: reclaim must not lower wal_seq. The phone
        // still holds its own workspace and catches up its local WAL.
        let base = snapshotBase ?? fence.walSeq
        let remoteWal = max(appliedMseq, base, remoteRecords.keys.max() ?? 0)
        reclaimResponseCount += 1
        let files: [HandoffSegmentFile]
        do {
            files = try makeReclaimSegments(base: base, walSeq: remoteWal,
                                            epoch: UInt64(reclaimResponseCount))
        } catch let error as HandoffError {
            throw error
        } catch {
            throw RemoteError(status: 500, code: "internal",
                              message: "cannot build the reclaim segments")
        }
        let payload: Data
        let descriptors: [HandoffSegmentDescriptor]
        do {
            payload = try HandoffSegmentWriter.archive(files)
            descriptors = try files.map { try $0.descriptor() }
        } catch {
            throw RemoteError(status: 500, code: "internal",
                              message: "cannot encode the reclaim segments")
        }
        let metadata = HandoffReclaimMetadata(
            fence: Fence(owner: HandoffLimits.phoneOwner,
                         generation: fence.generation + 1,
                         walSeq: remoteWal),
            baseMseq: base,
            segments: descriptors,
            payloadBytes: UInt64(payload.count),
            payloadSha256: SHA256.hash(payload))
        fence = metadata.fence
        reclaimToken = nil
        reclaimTokenIssuedAt = nil
        reclaimCache[decoded.reclaimToken] = ReclaimCacheEntry(
            metadata: metadata, payload: payload, createdAt: now)
        return try framedResponse(metadata, payload: payload)
    }

    // MARK: - Snapshot storage

    private func unpackSnapshot(entries: [HandoffTarEntry]) throws {
        let staging = paths.stagingDirectory
        try? FileManager.default.removeItem(at: staging)
        try HandoffFile.ensureDirectory(staging)
        for entry in entries {
            let name = entry.name.hasSuffix("/")
                ? String(entry.name.dropLast())
                : entry.name
            guard HandoffTar.isSafeRelativeName(name) else {
                throw HandoffError.payloadMismatch("snapshot tar name is unsafe")
            }
            let components = name.split(separator: "/")
            guard let root = components.first, root == "home" || root == "workspace" else {
                throw HandoffError.payloadMismatch(
                    "snapshot tar contains an entry outside home/workspace")
            }
            var target = staging
            for component in components {
                target.appendPathComponent(String(component))
            }
            switch entry.kind {
            case .directory:
                try HandoffFile.ensureDirectory(target)
                _ = target.path.withCString { Darwin.chmod($0, entry.mode) }
            case .file:
                try HandoffFile.ensureDirectory(target.deletingLastPathComponent())
                do {
                    try entry.data.write(to: target, options: .atomic)
                } catch {
                    throw HandoffError.applyFailed("cannot unpack the snapshot file")
                }
                _ = target.path.withCString { Darwin.chmod($0, entry.mode) }
            }
        }
        try HandoffFile.fsyncDirectory(staging)
        let materialized = paths.materializedDirectory
        try? FileManager.default.removeItem(at: materialized)
        try HandoffFile.rename(staging, to: materialized)
        try HandoffFile.fsyncDirectory(configuration.root)
    }

    private func resetRemoteWorkspace() throws {
        // Remove only the derived copy; the WAL/manifest of the simulator are
        // not used (records are kept in memory and re-served on reclaim).
        try? FileManager.default.removeItem(at: paths.materializedDirectory)
        try HandoffFile.ensureDirectory(paths.materializedDirectory)
        try HandoffFile.ensureDirectory(paths.materializedHomeDirectory)
        try HandoffFile.ensureDirectory(paths.materializedWorkspaceDirectory)
        snapshotBase = nil
        snapshotHash = nil
        snapshotGeneration = nil
        appliedMseq = 0
        remoteRecords = [:]
        remoteMaterializer = nil
    }

    // MARK: - Reclaim segments

    private func makeReclaimSegments(base: UInt64, walSeq: UInt64,
                                     epoch: UInt64) throws -> [HandoffSegmentFile] {
        guard walSeq > base else { return [] }
        var records: [WALRecord] = []
        for mseq in (base + 1)...walSeq {
            guard let record = remoteRecords[mseq] else {
                throw HandoffError.segmentContinuity(
                    "the remote has a hole at mseq \(mseq)")
            }
            records.append(record)
        }
        let close = try WALRecord(epochClose: HandoffFile.currentTimeMilliseconds(),
                                  durableUpto: walSeq)
        var all = records
        all.append(close)
        let name = try WALSegmentName(epoch: max(1, epoch), segment: 0)
        let bytes = try HandoffSegmentWriter.encode(firstMseq: base + 1,
                                                    bootID: configuration.bootID,
                                                    records: all)
        return [try HandoffSegmentFile(file: "wal/" + name.fileName, bytes: bytes)]
    }

    // MARK: - HTTP helpers

    private func authorize(_ request: HandoffHTTPRequest) throws {
        let authorization = request.headers["Authorization"]
            ?? request.headers["authorization"]
        guard authorization == "Bearer \(configuration.bearerToken)" else {
            throw RemoteError(status: 401, code: "unauthorized",
                              message: "missing or invalid Bearer credential")
        }
    }

    private func validate(_ metadata: HandoffSnapshotMetadata) throws {
        do {
            try metadata.validate()
        } catch let error as HandoffError {
            throw map(error)
        }
    }

    private func validate(_ metadata: HandoffSegmentsMetadata) throws {
        do {
            try metadata.validate()
        } catch let error as HandoffError {
            throw map(error)
        }
    }

    private func map(_ error: HandoffError) -> RemoteError {
        switch error {
        case .segmentsGap:
            return RemoteError(status: 409, code: "segments_gap",
                               message: "segments do not cover (base, wal_seq]",
                               appliedMseq: appliedMseq,
                               expectedMseq: appliedMseq + 1)
        case .segmentContinuity(let detail):
            return RemoteError(status: 409, code: "segments_gap",
                               message: detail, appliedMseq: appliedMseq,
                               expectedMseq: appliedMseq + 1)
        case .payloadTooLarge(let bytes):
            return RemoteError(status: 400, code: "payload_mismatch",
                               message: "payload of \(bytes) bytes is too large")
        case .payloadMismatch(let detail):
            return RemoteError(status: 400, code: "payload_mismatch",
                               message: detail)
        case .badRequest(let detail), .invalidResponse(let detail):
            return RemoteError(status: 400, code: "bad_request", message: detail)
        default:
            return RemoteError(status: 500, code: "internal",
                               message: "simulated remote failure")
        }
    }

    private func jsonResponse<T: Encodable>(_ value: T) throws -> HandoffHTTPResponse {
        let data: Data
        do {
            data = try HandoffJSON.encode(value)
        } catch {
            throw RemoteError(status: 500, code: "internal",
                              message: "cannot encode the simulated response")
        }
        return HandoffHTTPResponse(status: 200,
                                   headers: ["Cache-Control": "no-store",
                                             "Content-Type": "application/json"],
                                   bodyData: data)
    }

    private func framedResponse(_ metadata: HandoffReclaimMetadata,
                                payload: Data) throws -> HandoffHTTPResponse {
        let metaData: Data
        do {
            metaData = try HandoffJSON.encode(metadata)
            let frame = try HandoffFrameCodec.encode(metadata: metaData,
                                                     payload: payload)
            return HandoffHTTPResponse(status: 200,
                                       headers: ["Cache-Control": "no-store",
                                                 "Content-Type": "application/octet-stream"],
                                       bodyData: frame)
        } catch let error as HandoffError {
            throw map(error)
        } catch {
            throw RemoteError(status: 500, code: "internal",
                              message: "cannot encode the reclaim response")
        }
    }

    private func errorResponse(_ error: RemoteError) -> HandoffHTTPResponse {
        let body = HandoffErrorEnvelope(error: .init(
            code: error.code,
            message: error.message,
            generation: error.generation,
            appliedMseq: error.appliedMseq,
            expectedMseq: error.expectedMseq))
        let data = (try? HandoffJSON.encode(body)) ?? Data()
        return HandoffHTTPResponse(status: error.status,
                                   headers: ["Cache-Control": "no-store",
                                             "Content-Type": "application/json"],
                                   bodyData: data)
    }

    private static func randomToken() -> String {
        var generator = SystemRandomNumberGenerator()
        var bytes = [UInt8]()
        bytes.reserveCapacity(16)
        for _ in 0..<16 {
            bytes.append(UInt8.random(in: UInt8.min...UInt8.max, using: &generator))
        }
        return HandoffHex.encode(Data(bytes))
    }
}
