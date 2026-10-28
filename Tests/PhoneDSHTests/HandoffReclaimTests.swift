// SPDX-License-Identifier: MIT
// Reclaim applier and reclaim-client tests (spec/v1/handoff.md §5).

import XCTest
import PhoneDSHController
import PhoneDSH
import PhoneDSHLog
import PhoneDSHWire

final class HandoffReclaimTests: XCTestCase {
    // MARK: - Helpers

    /// Builds one reclaim response whose tar carries a single WAL segment with
    /// `records` (and an epoch close at `fence.walSeq`). With no records the
    /// archive is empty, which is legal only when base == wal_seq.
    func makeReclaimDownload(
        directory: URL,
        bootID: Data = Data(repeating: 0x99, count: 16),
        fence: Fence,
        baseMseq: UInt64,
        records: [WALRecord],
        segmentName: String = "wal/00000020.000000.xlwal"
    ) throws -> HandoffReclaimDownload {
        var files: [HandoffSegmentFile] = []
        var descriptors: [HandoffSegmentDescriptor] = []
        if let first = records.first {
            var segmentRecords = records
            segmentRecords.append(try WALRecord(
                epochClose: 1_792_800_000_123, durableUpto: fence.walSeq))
            let bytes = try HandoffSegmentWriter.encode(
                firstMseq: first.mseq, bootID: bootID, records: segmentRecords)
            let file = try HandoffSegmentFile(file: segmentName, bytes: bytes)
            descriptors = [try file.descriptor()]
            files = [file]
        }
        let payload = try HandoffSegmentWriter.archive(files)
        let payloadURL = directory.appendingPathComponent(
            "reclaim-\(UUID().uuidString).tar")
        try payload.write(to: payloadURL)
        let metadata = HandoffReclaimMetadata(
            fence: fence, baseMseq: baseMseq, segments: descriptors,
            payloadBytes: UInt64(payload.count),
            payloadSha256: SHA256.hash(payload))
        return HandoffReclaimDownload(metadata: metadata,
                                      payloadURL: payloadURL,
                                      payloadBytes: payload.count,
                                      payloadSHA256: metadata.payloadSha256)
    }

    func makeApplier(root: URL) throws -> WorkspaceLogSegmentApplier {
        try WorkspaceLogSegmentApplier(
            root: root,
            configuration: WorkspaceLogConfiguration(root: root),
            bootID: Data(repeating: 0x88, count: 16))
    }

    func mutations(_ count: Int) -> [VfsMutationBody] {
        (1...count).map { index in
            HandoffMutations.write("/dsh/workspace/file-\(index).txt",
                                   "content-\(index)")
        }
    }

    // MARK: - Applier

    func testApplierAppliesSegmentsAndIsIdempotent() async throws {
        let directory = try HandoffTemporaryDirectory("applier")
        defer { directory.cleanUp() }
        let root = directory.url.appendingPathComponent("phone")
        let all = mutations(5)
        try HandoffWorkspaceFixture.makeOfflineLaggingWorkspace(
            root: root, mutations: all, materializedCount: 2)
        let applier = try makeApplier(root: root)
        let fence = Fence(owner: "phone", generation: 2, walSeq: 5)
        let records = try (3...5).map { index in
            try WALRecord(mseq: UInt64(index), mutation: all[index - 1])
        }
        let download = try makeReclaimDownload(directory: directory.url,
                                               fence: fence, baseMseq: 2,
                                               records: records)
        let first = try await applier.apply(download)
        XCTAssertEqual(first.appliedMseq, 5)
        XCTAssertEqual(first.lastMseq, 5)
        XCTAssertTrue(first.epochClosed)
        XCTAssertEqual(first.mutationsApplied, 3)
        let file5 = try String(contentsOf:
            HandoffWorkspaceFixture.materialized(root, "workspace/file-5.txt"),
            encoding: .utf8)
        XCTAssertEqual(file5, "content-5")

        let second = try await applier.apply(download)
        XCTAssertEqual(second.appliedMseq, 5)
        XCTAssertEqual(second.lastMseq, 5)
        XCTAssertTrue(second.epochClosed)
        XCTAssertEqual(second.mutationsApplied, 0)

        let log = try HandoffWorkspaceFixture.reopen(root: root)
        let positions = await log.positions()
        XCTAssertEqual(positions.nextMseq, 6)
        XCTAssertEqual(positions.ackedMseq, 5)
        XCTAssertEqual(positions.durableMseq, 5)
    }

    func testApplierRejectsGapInReclaimPayload() async throws {
        let directory = try HandoffTemporaryDirectory("applier-gap")
        defer { directory.cleanUp() }
        let root = directory.url.appendingPathComponent("phone")
        try HandoffWorkspaceFixture.makeOfflineLaggingWorkspace(
            root: root, mutations: mutations(2), materializedCount: 0)
        let applier = try makeApplier(root: root)
        let fence = Fence(owner: "phone", generation: 2, walSeq: 5)
        let records = try (1...2).map { index in
            try WALRecord(mseq: UInt64(index),
                          mutation: HandoffMutations.write(
                            "/dsh/workspace/file-\(index).txt",
                            "content-\(index)"))
        }
        let download = try makeReclaimDownload(directory: directory.url,
                                               fence: fence, baseMseq: 0,
                                               records: records)
        do {
            _ = try await applier.apply(download)
            XCTFail("a payload that stops at mseq 2 cannot satisfy wal_seq 5")
        } catch {
            guard case HandoffError.segmentContinuity = error else {
                return XCTFail("expected a continuity error, got \(error)")
            }
        }
        let manifest = try ManifestStore(root: root).read()
        XCTAssertEqual(manifest?.materializedUptoMseq, 0)
    }

    func testApplierRejectsPayloadHashMismatch() async throws {
        let directory = try HandoffTemporaryDirectory("applier-hash")
        defer { directory.cleanUp() }
        let root = directory.url.appendingPathComponent("phone")
        try HandoffWorkspaceFixture.makeOfflineLaggingWorkspace(
            root: root, mutations: mutations(1), materializedCount: 0)
        let applier = try makeApplier(root: root)
        let fence = Fence(owner: "phone", generation: 1, walSeq: 1)
        var download = try makeReclaimDownload(
            directory: directory.url, fence: fence, baseMseq: 0,
            records: [try WALRecord(mseq: 1,
                                    mutation: mutations(1)[0])])
        download.payloadSHA256 = String(repeating: "0", count: 64)
        do {
            _ = try await applier.apply(download)
            XCTFail("a payload that does not match its descriptor must fail")
        } catch {
            guard case HandoffError.payloadMismatch = error else {
                return XCTFail("expected a payload mismatch, got \(error)")
            }
        }
    }

    func testApplierCatchesUpLocalWALTailFirst() async throws {
        let directory = try HandoffTemporaryDirectory("applier-catchup")
        defer { directory.cleanUp() }
        let root = directory.url.appendingPathComponent("phone")
        try HandoffWorkspaceFixture.makeOfflineLaggingWorkspace(
            root: root, mutations: mutations(2), materializedCount: 0)
        let applier = try makeApplier(root: root)
        let fence = Fence(owner: "phone", generation: 2, walSeq: 3)
        let download = try makeReclaimDownload(
            directory: directory.url, fence: fence, baseMseq: 2,
            records: [try WALRecord(mseq: 3,
                                    mutation: HandoffMutations.write(
                                        "/dsh/workspace/late.txt", "late"))])
        let result = try await applier.apply(download)
        XCTAssertEqual(result.appliedMseq, 3)
        XCTAssertEqual(result.mutationsApplied, 1)
        let contents = try String(contentsOf:
            HandoffWorkspaceFixture.materialized(root, "workspace/file-2.txt"),
            encoding: .utf8)
        XCTAssertEqual(contents, "content-2")
        let lateContents = try String(contentsOf:
            HandoffWorkspaceFixture.materialized(root, "workspace/late.txt"),
            encoding: .utf8)
        XCTAssertEqual(lateContents, "late")
    }

    func testApplierEmptyReclaimClosesEpochAndKeepsNextMseq() async throws {
        let directory = try HandoffTemporaryDirectory("applier-empty")
        defer { directory.cleanUp() }
        let root = directory.url.appendingPathComponent("phone")
        try HandoffWorkspaceFixture.makeOfflineLaggingWorkspace(
            root: root, mutations: mutations(2), materializedCount: 2)
        let applier = try makeApplier(root: root)
        let fence = Fence(owner: "phone", generation: 2, walSeq: 2)
        let download = try makeReclaimDownload(directory: directory.url,
                                               fence: fence, baseMseq: 2,
                                               records: [])
        let result = try await applier.apply(download)
        XCTAssertEqual(result.appliedMseq, 2)
        XCTAssertTrue(result.epochClosed)
        let log = try HandoffWorkspaceFixture.reopen(root: root)
        let positions = await log.positions()
        XCTAssertEqual(positions.nextMseq, 3)
        XCTAssertEqual(positions.durableMseq, 2)
    }

    // MARK: - Reclaim client

    func testReclaimClientWithoutStoredTokenFails() async throws {
        let directory = try HandoffTemporaryDirectory("reclaim-no-token")
        defer { directory.cleanUp() }
        let authority = try FenceAuthority(root: directory.url,
                                           owner: "remote", generation: 1,
                                           walSeq: 0)
        let client = try makeHandoffClient(transport: CountingHandoffTransport())
        let reclaim = ReclaimClient(client: client,
                                    applier: try makeApplier(root: directory.url),
                                    fences: FenceAuthorityHandoffStore(authority: authority))
        do {
            _ = try await reclaim.reclaimStoredToken()
            XCTFail("reclaim without a token must fail")
        } catch {
            XCTAssertEqual(error as? HandoffError, .noReclaimToken)
        }
    }

    func testReclaimClientDoesNotRetryUnauthorized() async throws {
        let directory = try HandoffTemporaryDirectory("reclaim-401")
        defer { directory.cleanUp() }
        let authority = try FenceAuthority(root: directory.url,
                                           owner: "remote", generation: 1,
                                           walSeq: 5)
        let transport = UnauthorizedHandoffTransport()
        let client = try makeHandoffClient(transport: transport)
        let reclaim = ReclaimClient(client: client,
                                    applier: try makeApplier(root: directory.url),
                                    fences: FenceAuthorityHandoffStore(authority: authority),
                                    retryPolicy: HandoffRetryPolicy(maximumAttempts: 3,
                                                                    baseDelay: 0))
        try await reclaim.store(token: String(repeating: "a", count: 32))
        do {
            _ = try await reclaim.reclaimStoredToken()
            XCTFail("401 must not be retried")
        } catch {
            XCTAssertEqual(error as? HandoffError, .unauthorized)
        }
        // The client refreshes the Bearer credential once after the first 401;
        // ReclaimClient itself does not retry a non-retryable failure.
        XCTAssertEqual(transport.callCount, 2)
    }

    func testReclaimClientRejectsInvalidStoredToken() async throws {
        let directory = try HandoffTemporaryDirectory("reclaim-token")
        defer { directory.cleanUp() }
        let authority = try FenceAuthority(root: directory.url, owner: "remote",
                                           generation: 1, walSeq: 0)
        let client = try makeHandoffClient(transport: CountingHandoffTransport())
        let reclaim = ReclaimClient(client: client,
                                    applier: try makeApplier(root: directory.url),
                                    fences: FenceAuthorityHandoffStore(authority: authority))
        do {
            try await reclaim.store(token: "not-a-token")
            XCTFail("a malformed token must not be stored")
        } catch {
            XCTAssertEqual(error as? HandoffError, .unauthorized)
        }
    }

    func testReclaimClientRejectsTokenFromAnotherWorkspaceBeforeTransport() async throws {
        let directory = try HandoffTemporaryDirectory("reclaim-workspace")
        defer { directory.cleanUp() }
        let authority = try FenceAuthority(root: directory.url, owner: "remote",
                                           generation: 1, walSeq: 0)
        let transport = CountingHandoffTransport()
        let client = try makeHandoffClient(transport: transport)
        let store = InMemoryHandoffReclaimTokenStore()
        let otherWorkspace = HandoffReclaimToken.workspaceIdentifier(
            for: directory.url.appendingPathComponent("another-workspace"))
        let credential = HandoffReclaimToken(
            token: String(repeating: "b", count: 32),
            remoteFence: Fence(owner: HandoffLimits.remoteOwner,
                               generation: 1, walSeq: 0),
            endpoint: "https://remote.invalid",
            workspaceIdentifier: otherWorkspace)
        try await store.store(credential)
        let reclaim = ReclaimClient(
            client: client,
            applier: try makeApplier(root: directory.url),
            fences: FenceAuthorityHandoffStore(authority: authority),
            tokenStore: store)
        do {
            _ = try await reclaim.reclaimStoredToken()
            XCTFail("a token bound to another workspace must be refused")
        } catch {
            guard case HandoffError.manualReclaimRequired = error else {
                return XCTFail("expected manualReclaimRequired, got \(error)")
            }
        }
        XCTAssertEqual(transport.callCount, 0,
                       "a foreign workspace token must never reach the remote")
        let remaining = try await store.load()
        XCTAssertEqual(remaining, credential,
                       "a refused token must stay in the vault for manual recovery")
    }

    func testReclaimClientUsesCachedTokenWhenVaultLoadFails() async throws {
        let directory = try HandoffTemporaryDirectory("reclaim-load-fails")
        defer { directory.cleanUp() }
        let authority = try FenceAuthority(root: directory.url,
                                           owner: HandoffLimits.phoneOwner,
                                           generation: 0, walSeq: 0)
        let transport = UnauthorizedHandoffTransport()
        let client = try makeHandoffClient(transport: transport)
        let store = LoadFailingReclaimTokenStore()
        let reclaim = ReclaimClient(
            client: client,
            applier: try makeApplier(root: directory.url),
            fences: FenceAuthorityHandoffStore(authority: authority),
            tokenStore: store)
        try await reclaim.store(
            token: String(repeating: "c", count: 32),
            remoteFence: Fence(owner: HandoffLimits.remoteOwner,
                               generation: 1, walSeq: 0))
        do {
            _ = try await reclaim.reclaimStoredToken()
            XCTFail("the remote 401 must surface")
        } catch {
            XCTAssertEqual(error as? HandoffError, .unauthorized,
                           "a vault read failure must fall back to the cached token")
        }
        XCTAssertGreaterThan(transport.callCount, 0,
                             "the cached token, not the vault error, must reach the dispatch")
    }
}

/// Stores in memory, then fails every read. Models an App vault that became
/// temporarily unavailable after the CAS token was already cached.
final class LoadFailingReclaimTokenStore: HandoffReclaimTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: HandoffReclaimToken?

    func store(_ token: HandoffReclaimToken) async throws {
        lock.withLock { stored = token }
    }

    func load() async throws -> HandoffReclaimToken? {
        throw HandoffError.reclaimTokenStoreFailed("vault read failed")
    }

    func remove() async throws {
        lock.withLock { stored = nil }
    }
}

/// Always answers 401 on reclaim (used to prove the retry classification).
final class UnauthorizedHandoffTransport: HandoffHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var callCount: Int { lock.withLock { calls } }

    private var body: Data {
        Data("""
        {"error":{"code":"unauthorized","message":"invalid reclaim token"}}
        """.utf8)
    }

    func send(_ request: HandoffHTTPRequest) async throws -> HandoffHTTPResponse {
        lock.withLock { calls += 1 }
        return HandoffHTTPResponse(status: 401,
                                   headers: ["Cache-Control": "no-store"],
                                   bodyData: body)
    }

    func download(_ request: HandoffHTTPRequest) async throws -> HandoffHTTPDownload {
        lock.withLock { calls += 1 }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-handoff-401-\(UUID().uuidString)")
        try body.write(to: url)
        return HandoffHTTPDownload(status: 401,
                                   headers: ["Cache-Control": "no-store"],
                                   bodyURL: url)
    }
}
