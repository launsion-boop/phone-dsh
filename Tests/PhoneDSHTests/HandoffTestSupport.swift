// SPDX-License-Identifier: MIT
// Shared fixtures for the Handoff tests.
//
// The tests drive the real PhoneDSHLog workspace types and the real
// controller state machine; only the remote host is the in-process simulator.

import Darwin
import Foundation
import XCTest
import PhoneDSHController
import PhoneDSH
import PhoneDSHLog
import PhoneDSHWire
import PhoneDSHAgentCore

enum HandoffTestError: Error, Equatable {
    case timeout
    case fixture(String)
}

// MARK: - Temporary directories

struct HandoffTemporaryDirectory {
    let url: URL

    init(_ label: String = "handoff") throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-handoff-tests-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Mutations

enum HandoffMutations {
    static func write(_ path: String, _ text: String,
                      mode: UInt32 = 0o644) -> VfsMutationBody {
        VfsMutationBody(op: .write, mode: mode, path: path,
                        data: Data(text.utf8))
    }

    static func write(_ path: String, data: Data,
                      mode: UInt32 = 0o644) -> VfsMutationBody {
        VfsMutationBody(op: .write, mode: mode, path: path, data: data)
    }

    static func append(_ path: String, from: UInt64, _ text: String,
                       mode: UInt32 = 0o644) -> VfsMutationBody {
        VfsMutationBody(op: .write, mode: mode, mflags: [.appended],
                        appendFrom: from, path: path, data: Data(text.utf8))
    }

    static func mkdir(_ path: String, mode: UInt32 = 0o755) -> VfsMutationBody {
        VfsMutationBody(op: .mkdir, mode: mode, path: path)
    }

    static func remove(_ path: String) -> VfsMutationBody {
        VfsMutationBody(op: .remove, mode: 0, path: path)
    }
}

// MARK: - Credentials

enum HandoffTestCredentials {
    static let service = "dsh-remote"
    static let token = "remote-bearer-token"

    static func provider(_ token: String = HandoffTestCredentials.token)
        -> any CredentialProvider {
        StaticCredentialProvider([
            CredentialScope(service: service): Credential(kind: .bearer, value: token),
        ])
    }
}

func makeHandoffClient(transport: any HandoffHTTPTransport,
                       token: String = HandoffTestCredentials.token) throws
    -> HandoffClient {
    let endpoint = try XCTUnwrap(URL(string: "https://remote.invalid"))
    return try HandoffClient(
        configuration: HandoffClientConfiguration(endpoint: endpoint,
                                                  credentialService: HandoffTestCredentials.service),
        transport: transport,
        credentialProvider: HandoffTestCredentials.provider(token))
}

// MARK: - Simulator

func makeSimulator(root: URL,
                   token: String = HandoffTestCredentials.token,
                   bootID: Data = Data(repeating: 0x42, count: 16),
                   clock: @escaping @Sendable () -> Date = { Date() },
                   cacheLifetime: TimeInterval = HandoffLimits.reclaimCacheLifetime,
                   initialFence: Fence = Fence(owner: "phone", generation: 0, walSeq: 0))
    throws -> HandoffServerSimulator {
    let configuration = HandoffServerSimulatorConfiguration(
        root: root, bootID: bootID, bearerToken: token,
        initialFence: initialFence,
        reclaimCacheLifetime: cacheLifetime,
        clock: clock)
    return try HandoffServerSimulator(configuration: configuration)
}

// MARK: - Workspaces

enum HandoffWorkspaceFixture {
    static let phoneBootID = Data(repeating: 0x11, count: 16)
    static let phoneBootIDHex = String(repeating: "11", count: 16)

    static func materialized(_ root: URL, _ path: String) -> URL {
        root.appendingPathComponent("materialized").appendingPathComponent(path)
    }

    static func walDirectory(_ root: URL) -> URL {
        root.appendingPathComponent("wal")
    }

    /// Creates a live workspace with `mutations`, materializes them and closes
    /// one epoch. The caller owns (and later stops using) the returned log.
    static func makeLiveWorkspace(root: URL,
                                  bootID: Data = phoneBootID,
                                  mutations: [VfsMutationBody],
                                  closeEpoch: Bool = true) async throws
        -> WorkspaceLog {
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
        let log = try WorkspaceLog(
            configuration: WorkspaceLogConfiguration(root: root,
                                                     groupCommitDelay: 0,
                                                     groupCommitBytes: 1),
            bootID: bootID)
        for mutation in mutations {
            _ = try await log.append(mutation)
        }
        if closeEpoch {
            _ = try await log.closeEpoch()
        }
        return log
    }

    /// Builds a closed-epoch workspace without a running ``WorkspaceLog``:
    /// mutations `1...N` are in one WAL segment, the first `materializedCount`
    /// are on disk and the manifest records `materialized_upto_mseq = K` with
    /// the WAL tail `N`. This is the state a handoff sees when materialization
    /// lags the WAL (the basis for a non-empty segments request).
    static func makeOfflineLaggingWorkspace(
        root: URL,
        mutations: [VfsMutationBody],
        materializedCount: Int,
        bootID: Data = phoneBootID,
        epoch: UInt64 = 1,
        closeEpoch: Bool = true
    ) throws {
        let paths = WorkspacePaths(root: root)
        try paths.createDirectories()
        guard materializedCount >= 0, materializedCount <= mutations.count else {
            throw HandoffTestError.fixture("materializedCount is outside the mutation list")
        }
        var records: [WALRecord] = []
        for (index, mutation) in mutations.enumerated() {
            records.append(try WALRecord(mseq: UInt64(index + 1), mutation: mutation))
        }
        if closeEpoch {
            records.append(try WALRecord(epochClose: 1_792_800_000_000,
                                         durableUpto: UInt64(mutations.count)))
        }
        let header = try WALSegmentHeader(firstMseq: 1, bootID: bootID)
        let segment = try WALSegment(header: header, records: records)
        let name = try WALSegmentName(epoch: epoch, segment: 0)
        let segmentURL = name.url(in: paths.walDirectory)
        try segment.encoded().write(to: segmentURL, options: .atomic)
        try fsyncFile(segmentURL)
        try fsyncDirectory(paths.walDirectory)

        for (index, mutation) in mutations.prefix(materializedCount).enumerated() {
            _ = index
            try materialize(mutation, into: paths.materializedDirectory)
        }
        try fsyncDirectory(paths.materializedDirectory)

        let lastMseq = UInt64(mutations.count)
        let manifest = Manifest(
            bootID: bootID.map { String(format: "%02x", $0) }.joined(),
            materializedUptoMseq: UInt64(materializedCount),
            lastMseq: lastMseq,
            lastDurableEpoch: closeEpoch ? epoch : 0,
            segments: closeEpoch
                ? [ManifestSegment(file: name.manifestFile, epoch: epoch,
                                   firstMseq: 1, lastMseq: lastMseq)]
                : [])
        try ManifestStore(paths: paths).write(manifest)
    }

    /// Reopens the workspace log (runs wal.md §10 recovery) to verify the
    /// applied state and the D17 positions.
    static func reopen(root: URL,
                       bootID: Data = Data(repeating: 0x77, count: 16)) throws
        -> WorkspaceLog {
        try WorkspaceLog(configuration: WorkspaceLogConfiguration(root: root,
                                                                  groupCommitDelay: 0,
                                                                  groupCommitBytes: 1),
                         bootID: bootID)
    }

    /// Writes one mutation into the materialized copy (the test fixture only
    /// needs the complete-write/mkdir/remove/chmod forms used by the tests).
    static func materialize(_ mutation: VfsMutationBody,
                            into materialized: URL) throws {
        let components = mutation.path.split(separator: "/")
        guard components.count >= 3, components[0] == "dsh" else {
            throw HandoffTestError.fixture("invalid mutation path")
        }
        let rootName = String(components[1])
        guard rootName == "home" || rootName == "workspace" else { return }
        var target = materialized.appendingPathComponent(rootName)
        for component in components.dropFirst(2) {
            target.appendPathComponent(String(component))
        }
        let mode = mode_t(mutation.mode & 0o7777)
        switch mutation.op {
        case .write:
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            if mutation.mflags.contains(.appended) {
                let handle = try FileHandle(forWritingTo: target)
                defer { try? handle.close() }
                try handle.seek(toOffset: mutation.appendFrom)
                try handle.write(contentsOf: mutation.data)
            } else {
                var data = mutation.data
                if mutation.mflags.contains(.appended),
                   let existing = try? Data(contentsOf: target),
                   existing.count >= Int(mutation.appendFrom) {
                    data = Data(existing.prefix(Int(mutation.appendFrom))) + mutation.data
                }
                try data.write(to: target, options: .atomic)
            }
            _ = target.path.withCString { Darwin.chmod($0, mode) }
        case .mkdir:
            try FileManager.default.createDirectory(at: target,
                                                    withIntermediateDirectories: true)
            _ = target.path.withCString { Darwin.chmod($0, mode) }
        case .remove:
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
        case .chmod:
            _ = target.path.withCString { Darwin.chmod($0, mode) }
        }
    }

    static func fsyncFile(_ url: URL) throws {
        let descriptor = url.path.withCString { Darwin.open($0, O_WRONLY) }
        guard descriptor >= 0 else { throw HandoffTestError.fixture("open") }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw HandoffTestError.fixture("fsync")
        }
    }

    static func fsyncDirectory(_ url: URL) throws {
        let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY) }
        guard descriptor >= 0 else { throw HandoffTestError.fixture("open dir") }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw HandoffTestError.fixture("fsync dir")
        }
    }
}

// MARK: - Synthetic segments

func makeSegmentFile(epoch: UInt64, segment: UInt64, bootID: Data,
                     firstMseq: UInt64, records: [WALRecord]) throws
    -> WALSegmentFile {
    let header = try WALSegmentHeader(firstMseq: firstMseq, bootID: bootID)
    let parsed = try WALSegment(header: header, records: records)
    let name = try WALSegmentName(epoch: epoch, segment: segment)
    let bytes = parsed.encoded()
    return WALSegmentFile(name: name,
                          url: name.url(in: FileManager.default.temporaryDirectory),
                          header: header,
                          records: records,
                          byteCount: bytes.count,
                          validByteCount: bytes.count,
                          tornTailBytes: 0)
}

// MARK: - Transports

struct HandoffRecordedRequest: Sendable {
    public var path: String
    public var contentType: String?
    public var authorizationPresent: Bool
    /// `nil` for non-framed bodies.
    public var framedPrefixBytes: Int?
    public var framedPayloadBytes: Int?
    public var bodyByteCount: Int
}

final class RecordingHandoffTransport: HandoffHTTPTransport, @unchecked Sendable {
    let base: any HandoffHTTPTransport
    private let lock = NSLock()
    private var stored: [HandoffRecordedRequest] = []

    init(base: any HandoffHTTPTransport) {
        self.base = base
    }

    var requests: [HandoffRecordedRequest] {
        lock.withLock { stored }
    }

    func send(_ request: HandoffHTTPRequest) async throws -> HandoffHTTPResponse {
        record(request)
        return try await base.send(request)
    }

    func download(_ request: HandoffHTTPRequest) async throws -> HandoffHTTPDownload {
        record(request)
        return try await base.download(request)
    }

    private func record(_ request: HandoffHTTPRequest) {
        var prefixBytes: Int?
        var payloadBytes: Int?
        switch request.body {
        case .framed(let prefix, let file):
            prefixBytes = prefix.count
            let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
            payloadBytes = (attributes?[.size] as? NSNumber)?.intValue
        default:
            break
        }
        let entry = HandoffRecordedRequest(
            path: request.url.path,
            contentType: request.headers["Content-Type"],
            authorizationPresent: (request.headers["Authorization"] ?? "")
                .hasPrefix("Bearer "),
            framedPrefixBytes: prefixBytes,
            framedPayloadBytes: payloadBytes,
            bodyByteCount: request.body.byteCount)
        lock.withLock { stored.append(entry) }
    }
}

/// Drops a response after the wrapped remote already produced it (a lost
/// response) for the first `times` requests whose path has `pathSuffix`.
final class DroppingHandoffTransport: HandoffHTTPTransport, @unchecked Sendable {
    let base: any HandoffHTTPTransport
    private let lock = NSLock()
    private var remaining: Int
    private let pathSuffix: String

    init(base: any HandoffHTTPTransport, pathSuffix: String, times: Int = 1) {
        self.base = base
        self.pathSuffix = pathSuffix
        self.remaining = times
    }

    private func shouldDrop(_ request: HandoffHTTPRequest) -> Bool {
        lock.withLock {
            guard remaining > 0, request.url.path.hasSuffix(pathSuffix) else {
                return false
            }
            remaining -= 1
            return true
        }
    }

    func send(_ request: HandoffHTTPRequest) async throws -> HandoffHTTPResponse {
        let response = try await base.send(request)
        if shouldDrop(request) {
            throw HandoffError.transport("the response was lost")
        }
        return response
    }

    func download(_ request: HandoffHTTPRequest) async throws -> HandoffHTTPDownload {
        let response = try await base.download(request)
        if shouldDrop(request) {
            response.cleanup()
            throw HandoffError.transport("the response was lost")
        }
        return response
    }
}

/// Fails the first `times` matching requests without contacting the remote.
final class FailingHandoffTransport: HandoffHTTPTransport, @unchecked Sendable {
    let base: any HandoffHTTPTransport
    private let lock = NSLock()
    private var remaining: Int
    private let pathSuffix: String
    private let error: HandoffError

    init(base: any HandoffHTTPTransport, pathSuffix: String, times: Int = 1,
         error: HandoffError = .transport("offline")) {
        self.base = base
        self.pathSuffix = pathSuffix
        self.remaining = times
        self.error = error
    }

    private func shouldFail(_ request: HandoffHTTPRequest) -> Bool {
        lock.withLock {
            guard remaining > 0, request.url.path.hasSuffix(pathSuffix) else {
                return false
            }
            remaining -= 1
            return true
        }
    }

    func send(_ request: HandoffHTTPRequest) async throws -> HandoffHTTPResponse {
        if shouldFail(request) { throw error }
        return try await base.send(request)
    }

    func download(_ request: HandoffHTTPRequest) async throws -> HandoffHTTPDownload {
        if shouldFail(request) { throw error }
        return try await base.download(request)
    }
}

/// Counts calls; used to prove that a request is never built without a
/// credential.
final class CountingHandoffTransport: HandoffHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var callCount: Int { lock.withLock { count } }

    func send(_ request: HandoffHTTPRequest) async throws -> HandoffHTTPResponse {
        lock.withLock { count += 1 }
        return HandoffHTTPResponse(status: 500,
                                   bodyData: Data("internal".utf8))
    }

    func download(_ request: HandoffHTTPRequest) async throws -> HandoffHTTPDownload {
        lock.withLock { count += 1 }
        throw HandoffError.transport("not expected")
    }
}

// MARK: - HTTP request builders

func handoffJSONRequest(path: String, body: Data,
                        token: String = HandoffTestCredentials.token) throws
    -> HandoffHTTPRequest {
    let url = try XCTUnwrap(URL(string: "https://remote.invalid/v1/handoff/\(path)"))
    return HandoffHTTPRequest(method: "POST",
                              url: url,
                              headers: ["Authorization": "Bearer \(token)",
                                        "Content-Type": "application/json"],
                              body: .data(body))
}

func handoffFrameRequest(path: String, metadata: Data, payload: Data,
                         token: String = HandoffTestCredentials.token) throws
    -> HandoffHTTPRequest {
    let url = try XCTUnwrap(URL(string: "https://remote.invalid/v1/handoff/\(path)"))
    let body = try HandoffFrameCodec.encode(metadata: metadata, payload: payload)
    return HandoffHTTPRequest(method: "POST",
                              url: url,
                              headers: ["Authorization": "Bearer \(token)",
                                        "Content-Type": "application/octet-stream"],
                              body: .data(body))
}

// MARK: - Golden vectors

struct GoldenWALVector: Decodable {
    struct Header: Decodable {
        var format: Int
        var reserved: Int
        var firstMseq: UInt64
        var bootIDHex: String
        var headerCRC32C: UInt32
        var headerHex: String

        enum CodingKeys: String, CodingKey {
            case format
            case reserved
            case firstMseq = "first_mseq"
            case bootIDHex = "boot_id_hex"
            case headerCRC32C = "header_crc32c"
            case headerHex = "header_hex"
        }
    }

    struct Record: Decodable {
        var kind: String
        var crc32c: UInt32
        var recordHex: String

        enum CodingKeys: String, CodingKey {
            case kind
            case crc32c
            case recordHex = "record_hex"
        }
    }

    var header: Header
    var records: [Record]
    var fileHex: String

    enum CodingKeys: String, CodingKey {
        case header
        case records
        case fileHex = "file_hex"
    }
}

/// Locates the checkout root by walking up from a source file instead of
/// counting fixed parent hops. The checked-in layout has `spec/` at the
/// repository root; after the open-source extraction drops the `sdk/` level the
/// package root itself carries `spec/` (or, when the spec is not shipped,
/// `Package.swift`).
func repositoryRoot(startingAt file: URL) -> URL? {
    let fileManager = FileManager.default
    func firstAncestor(withMarker marker: String) -> URL? {
        // Standardize first and bound the walk by the path component count:
        // deleting the last component of a URL that was built by appending a
        // slash-containing path component can produce a relative `..` segment
        // instead of reaching `/`, which would make a `parent == candidate`
        // test loop forever.
        var candidate = file.standardizedFileURL.deletingLastPathComponent()
        while candidate.pathComponents.count > 1 {
            if fileManager.fileExists(atPath: candidate.appendingPathComponent(marker).path) {
                return candidate
            }
            candidate = candidate.deletingLastPathComponent()
        }
        return nil
    }
    return firstAncestor(withMarker: "spec") ?? firstAncestor(withMarker: "Package.swift")
}

func repoRoot() -> URL {
    guard let root = repositoryRoot(startingAt: URL(fileURLWithPath: #filePath)) else {
        preconditionFailure("cannot locate the repository root from #filePath")
    }
    return root
}

func goldenWALVector(_ name: String) throws -> GoldenWALVector {
    let url = repoRoot()
        .appendingPathComponent("spec/v1/golden/wal/\(name).json")
    return try JSONDecoder().decode(GoldenWALVector.self,
                                    from: Data(contentsOf: url))
}

// MARK: - Polling

func handoffWaitUntil(timeout: TimeInterval = 5,
                      _ condition: @escaping @Sendable () async throws -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while true {
        if try await condition() { return }
        if Date() >= deadline { throw HandoffTestError.timeout }
        try await Task.sleep(nanoseconds: 3_000_000)
    }
}

// MARK: - Mutable clock

final class MutableHandoffClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date = Date(timeIntervalSince1970: 1_792_800_000)) {
        self.value = value
    }

    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) {
        lock.withLock { value = value.addingTimeInterval(seconds) }
    }
}
