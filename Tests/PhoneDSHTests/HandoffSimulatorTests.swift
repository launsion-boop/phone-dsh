// SPDX-License-Identifier: MIT
// In-process remote simulator tests (spec/v1/handoff.md §2–§6).

import XCTest
import PhoneDSH
import PhoneDSHLog
import PhoneDSHWire

final class HandoffSimulatorTests: XCTestCase {
    // MARK: - Fixtures

    private func simulator(_ directory: HandoffTemporaryDirectory,
                           clock: @escaping @Sendable () -> Date = { Date() },
                           cacheLifetime: TimeInterval = HandoffLimits.reclaimCacheLifetime)
        throws -> HandoffServerSimulator {
        try makeSimulator(root: directory.url.appendingPathComponent("remote"),
                          clock: clock, cacheLifetime: cacheLifetime)
    }

    private func phoneUpload(_ directory: HandoffTemporaryDirectory,
                             mutations: [VfsMutationBody],
                             materializedCount: Int = 0) async throws
        -> HandoffPreparedUpload {
        let root = directory.url.appendingPathComponent("phone-\(UUID().uuidString)")
        try HandoffWorkspaceFixture.makeOfflineLaggingWorkspace(
            root: root,
            mutations: mutations,
            materializedCount: materializedCount)
        let source = HandoffWorkspaceSnapshotter(
            root: root,
            configuration: WorkspaceLogConfiguration(root: root),
            scratchDirectory: directory.url.appendingPathComponent("scratch-\(UUID().uuidString)"))
        return try await source.prepareHandoff()
    }

    private func simpleMutations(_ count: Int) -> [VfsMutationBody] {
        (1...count).map { index in
            HandoffMutations.write("/dsh/workspace/file-\(index).txt", "content-\(index)")
        }
    }

    private func bytes(_ upload: HandoffPreparedUpload) throws -> Data {
        try Data(contentsOf: upload.snapshotURL)
    }

    // MARK: - Fence (§2)

    func testFenceCASInstallsRemoteGenerationAndStaleFenceRejected() async throws {
        let directory = try HandoffTemporaryDirectory("fence")
        defer { directory.cleanUp() }
        let remote = try simulator(directory)
        let client = try makeHandoffClient(transport: remote)

        let first = try await client.fence(expectedGeneration: 0, walSeq: 12)
        XCTAssertEqual(first.fence, Fence(owner: "remote", generation: 1, walSeq: 12))
        XCTAssertEqual(first.reclaimToken.count, 32)
        XCTAssertNotNil(first.reclaimToken.range(of: "^[0-9a-f]{32}$",
                                                 options: .regularExpression))
        let counters = await remote.endpointCounters()
        XCTAssertEqual(counters.fenceRequests, 1)

        // A second CAS with the old generation is rejected and changes nothing.
        do {
            _ = try await client.fence(expectedGeneration: 0, walSeq: 13)
            XCTFail("a stale generation must not install a second authority")
        } catch {
            XCTAssertEqual(error as? HandoffError, .fenceConflict)
        }
        let fence = await remote.currentFence()
        XCTAssertEqual(fence, Fence(owner: "remote", generation: 1, walSeq: 12))
    }

    func testFenceRejectsWALSeqRegression() async throws {
        let directory = try HandoffTemporaryDirectory("fence-regress")
        defer { directory.cleanUp() }
        let remote = try simulator(directory)
        let client = try makeHandoffClient(transport: remote)
        _ = try await client.fence(expectedGeneration: 0, walSeq: 5)
        // The remote owns generation 1; a second CAS cannot be made by the
        // phone with a lower wal_seq because the generation is stale first.
        do {
            _ = try await client.fence(expectedGeneration: 1, walSeq: 4)
            XCTFail("regressing wal_seq must not be installed")
        } catch {
            XCTAssertEqual(error as? HandoffError, .fenceConflict)
        }
    }

    // MARK: - Snapshot (§3)

    func testSnapshotRetryIsIdempotentAndDifferentHashConflicts() async throws {
        let directory = try HandoffTemporaryDirectory("snapshot")
        defer { directory.cleanUp() }
        let remote = try simulator(directory)
        let client = try makeHandoffClient(transport: remote)
        let firstUpload = try await phoneUpload(directory,
                                                mutations: simpleMutations(2),
                                                materializedCount: 1)
        let fence = try await client.fence(expectedGeneration: 0,
                                           walSeq: firstUpload.walSeq)
        let first = try await client.uploadSnapshot(firstUpload,
                                                    generation: fence.fence.generation)
        let retry = try await client.uploadSnapshot(firstUpload,
                                                    generation: fence.fence.generation)
        XCTAssertEqual(first, retry)
        XCTAssertEqual(first.materializedUptoMseq, firstUpload.baseMseq)
        XCTAssertEqual(first.snapshotSha256, firstUpload.snapshotSHA256)

        let secondUpload = try await phoneUpload(directory,
                                                 mutations: [
                                                     HandoffMutations.write(
                                                        "/dsh/workspace/file-1.txt", "different-1"),
                                                     HandoffMutations.write(
                                                        "/dsh/workspace/file-2.txt", "different-2"),
                                                 ],
                                                 materializedCount: 1)
        do {
            _ = try await client.uploadSnapshot(secondUpload,
                                                generation: fence.fence.generation)
            XCTFail("a different hash for one generation must conflict")
        } catch {
            XCTAssertEqual(error as? HandoffError, .snapshotConflict)
        }
        await clientCleanUp(firstUpload, secondUpload)
    }

    // MARK: - Segments (§4)

    func testSegmentsGapIsRejectedWithoutApplying() async throws {
        let directory = try HandoffTemporaryDirectory("segments-gap")
        defer { directory.cleanUp() }
        let remote = try simulator(directory)
        let client = try makeHandoffClient(transport: remote)
        let mutations = simpleMutations(5)
        let upload = try await phoneUpload(directory, mutations: mutations)
        let fence = try await client.fence(expectedGeneration: 0, walSeq: 5)
        _ = try await client.uploadSnapshot(upload, generation: fence.fence.generation)

        // A frame that only covers mseq 1...2 while the fence target is 5.
        let partial = try HandoffSegmentWriter.encode(
            firstMseq: 1,
            bootID: Data(repeating: 0x66, count: 16),
            records: [
                try WALRecord(mseq: 1, mutation: mutations[0]),
                try WALRecord(mseq: 2, mutation: mutations[1]),
            ])
        let partialFile = try HandoffSegmentFile(file: "wal/00000009.000000.xlwal",
                                                 bytes: partial)
        let descriptor = try partialFile.descriptor()
        let archive = try HandoffSegmentWriter.archive([partialFile])
        let metadata = HandoffSegmentsMetadata(
            generation: fence.fence.generation,
            baseMseq: 0,
            walSeq: 5,
            segments: [descriptor],
            payloadBytes: UInt64(archive.count),
            payloadSha256: SHA256.hash(archive))
        let request = try handoffFrameRequest(path: "segments",
                                              metadata: try CanonicalJSON.encode(metadata),
                                              payload: archive)
        let response = try await remote.send(request)
        XCTAssertEqual(response.status, 409)
        let envelope = try JSONDecoder().decode(HandoffErrorEnvelope.self,
                                                from: response.bodyData)
        XCTAssertEqual(envelope.error.code, "segments_gap")
        let afterGap = await remote.appliedMseqValue()
        let admissionAfterGap = await remote.isAdmissionOpen()
        XCTAssertEqual(afterGap, 0)
        XCTAssertFalse(admissionAfterGap)

        // The correct tail then applies normally: nothing past the gap stuck.
        let valid = try await client.uploadSegments(upload,
                                                    generation: fence.fence.generation)
        XCTAssertEqual(valid.appliedMseq, 5)
        XCTAssertEqual(valid.admission, .open)
        let appliedAfterValid = await remote.appliedMseqValue()
        XCTAssertEqual(appliedAfterValid, 5)
    }

    func testSegmentsApplyOpensAdmissionAndReplayIsIdempotent() async throws {
        let directory = try HandoffTemporaryDirectory("segments-apply")
        defer { directory.cleanUp() }
        let remote = try simulator(directory)
        let client = try makeHandoffClient(transport: remote)
        let upload = try await phoneUpload(directory,
                                           mutations: simpleMutations(3))
        let fence = try await client.fence(expectedGeneration: 0, walSeq: 3)
        _ = try await client.uploadSnapshot(upload, generation: fence.fence.generation)
        let first = try await client.uploadSegments(upload,
                                                    generation: fence.fence.generation)
        XCTAssertEqual(first.baseMseq, 0)
        XCTAssertEqual(first.appliedMseq, 3)
        XCTAssertEqual(first.walSeq, 3)
        XCTAssertEqual(first.admission, .open)
        let second = try await client.uploadSegments(upload,
                                                     generation: fence.fence.generation)
        XCTAssertEqual(first, second)
        let counters = await remote.endpointCounters()
        XCTAssertEqual(counters.segmentsUploads, 2)
        let materialized = await remote.remoteMaterializedFile("workspace/file-3.txt")
        let contents = try String(contentsOf: materialized, encoding: .utf8)
        XCTAssertEqual(contents, "content-3")
    }

    func testSnapshotBeforeSegmentsIsRequired() async throws {
        let directory = try HandoffTemporaryDirectory("segments-order")
        defer { directory.cleanUp() }
        let remote = try simulator(directory)
        let client = try makeHandoffClient(transport: remote)
        let upload = try await phoneUpload(directory, mutations: simpleMutations(1))
        let fence = try await client.fence(expectedGeneration: 0, walSeq: 1)
        do {
            _ = try await client.uploadSegments(upload,
                                                generation: fence.fence.generation)
            XCTFail("segments before the snapshot must be rejected")
        } catch {
            XCTAssertEqual(error as? HandoffError, .snapshotConflict)
        }
    }

    // MARK: - Reclaim (§5)

    func testReclaimReturnsSegmentsCachesResponseAndRejectsInvalidToken() async throws {
        let directory = try HandoffTemporaryDirectory("reclaim")
        defer { directory.cleanUp() }
        let remote = try simulator(directory)
        let client = try makeHandoffClient(transport: remote)
        let upload = try await phoneUpload(directory, mutations: simpleMutations(3))
        let fence = try await client.fence(expectedGeneration: 0, walSeq: 3)
        _ = try await client.uploadSnapshot(upload, generation: fence.fence.generation)
        _ = try await client.uploadSegments(upload, generation: fence.fence.generation)

        _ = try await remote.appendRemoteMutation(
            HandoffMutations.write("/dsh/workspace/remote.txt", "from remote"))

        let download = try await client.reclaim(token: fence.reclaimToken)
        defer { download.cleanup() }
        XCTAssertEqual(download.metadata.fence,
                       Fence(owner: "phone", generation: 2, walSeq: 4))
        XCTAssertEqual(download.metadata.baseMseq, 0)
        XCTAssertEqual(download.metadata.segments.count, 1)
        XCTAssertEqual(download.metadata.payloadSha256, download.payloadSHA256)
        XCTAssertEqual(download.metadata.payloadBytes, UInt64(download.payloadBytes))
        let files = try HandoffSegmentArchive.read(from: download.payloadURL)
        let validated = try HandoffSegmentArchive.validate(
            files: files, descriptors: download.metadata.segments)
        let records = try HandoffSegmentArchive.mutationRecords(
            validated, baseMseq: 0, walSeq: 4)
        XCTAssertEqual(records.map(\.mseq), [1, 2, 3, 4])

        // Repeat with the same token returns the cached bytes even though the
        // remote generation already advanced.
        let retry = try await client.reclaim(token: fence.reclaimToken)
        defer { retry.cleanup() }
        XCTAssertEqual(retry.metadata.fence, download.metadata.fence)
        XCTAssertEqual(retry.payloadSHA256, download.payloadSHA256)
        let remoteCounters = await remote.endpointCounters()
        XCTAssertEqual(remoteCounters.reclaimRequests, 2)
        let cachedEntries = await remote.cachedReclaimEntries()
        XCTAssertEqual(cachedEntries, 1)

        do {
            _ = try await client.reclaim(token: String(repeating: "0", count: 32))
            XCTFail("an unknown reclaim token must be rejected")
        } catch {
            XCTAssertEqual(error as? HandoffError, .unauthorized)
        }
        let finalFence = await remote.currentFence()
        XCTAssertEqual(finalFence, download.metadata.fence)
    }

    func testReclaimTokenExpiresAfterCacheLifetime() async throws {
        let directory = try HandoffTemporaryDirectory("reclaim-expiry")
        defer { directory.cleanUp() }
        let clock = MutableHandoffClock()
        let remote = try simulator(directory, clock: { clock.now })
        let client = try makeHandoffClient(transport: remote)
        let upload = try await phoneUpload(directory, mutations: simpleMutations(1))
        let fence = try await client.fence(expectedGeneration: 0, walSeq: 1)
        _ = try await client.uploadSnapshot(upload, generation: fence.fence.generation)
        _ = try await client.uploadSegments(upload, generation: fence.fence.generation)
        clock.advance(HandoffLimits.reclaimCacheLifetime + 1)
        do {
            _ = try await client.reclaim(token: fence.reclaimToken)
            XCTFail("an expired reclaim token must be rejected")
        } catch {
            XCTAssertEqual(error as? HandoffError, .unauthorized)
        }
    }

    // MARK: - Transport security (§1/§6)

    func testFenceEndpointRejectsMissingOrWrongBearer() async throws {
        let directory = try HandoffTemporaryDirectory("auth")
        defer { directory.cleanUp() }
        let remote = try simulator(directory)
        let body = try CanonicalJSON.encode(HandoffFenceRequest(
            expectedGeneration: 0, walSeq: 0))
        let without = try handoffJSONRequest(path: "fence", body: body, token: "wrong")
        let response = try await remote.send(without)
        XCTAssertEqual(response.status, 401)
        let envelope = try JSONDecoder().decode(HandoffErrorEnvelope.self,
                                                from: response.bodyData)
        XCTAssertEqual(envelope.error.code, "unauthorized")
        XCTAssertEqual(response.header("Cache-Control"), "no-store")

        var noAuthorization = without
        noAuthorization.headers = [:]
        let missing = try await remote.send(noAuthorization)
        XCTAssertEqual(missing.status, 401)
    }

    // MARK: - Lost responses and large payloads (§4/§6)

    func testLostSegmentsResponseIsSafeToReplay() async throws {
        let directory = try HandoffTemporaryDirectory("lost-response")
        defer { directory.cleanUp() }
        let remote = try simulator(directory)
        let dropping = DroppingHandoffTransport(base: remote,
                                                pathSuffix: "/segments",
                                                times: 1)
        let client = try makeHandoffClient(transport: dropping)
        let upload = try await phoneUpload(directory, mutations: simpleMutations(2))
        let fence = try await client.fence(expectedGeneration: 0, walSeq: 2)
        _ = try await client.uploadSnapshot(upload, generation: fence.fence.generation)
        do {
            _ = try await client.uploadSegments(upload, generation: fence.fence.generation)
            XCTFail("the first segments response is dropped")
        } catch {
            XCTAssertEqual(error as? HandoffError, .transport("the response was lost"))
        }
        let retry = try await client.uploadSegments(upload,
                                                    generation: fence.fence.generation)
        XCTAssertEqual(retry.appliedMseq, 2)
        XCTAssertEqual(retry.admission, .open)
        let counters = await remote.endpointCounters()
        XCTAssertEqual(counters.segmentsUploads, 2)
    }

    func testLargeSnapshotIsStreamedAsAFramedBody() async throws {
        let directory = try HandoffTemporaryDirectory("large-snapshot")
        defer { directory.cleanUp() }
        let remote = try simulator(directory)
        let recording = RecordingHandoffTransport(base: remote)
        let client = try makeHandoffClient(transport: recording)
        let big = Data(repeating: 0xA5, count: 2 * 1024 * 1024)
        let phoneRoot = directory.url.appendingPathComponent("phone")
        _ = try await HandoffWorkspaceFixture.makeLiveWorkspace(
            root: phoneRoot,
            mutations: [
                HandoffMutations.write("/dsh/workspace/big.bin", data: big),
            ])
        let source = HandoffWorkspaceSnapshotter(
            root: phoneRoot,
            configuration: WorkspaceLogConfiguration(root: phoneRoot),
            scratchDirectory: directory.url.appendingPathComponent("scratch"))
        let upload = try await source.prepareHandoff()
        let fence = try await client.fence(expectedGeneration: 0,
                                           walSeq: upload.walSeq)
        _ = try await client.uploadSnapshot(upload, generation: fence.fence.generation)
        let snapshotRequests = recording.requests.filter {
            $0.path.hasSuffix("/snapshot")
        }
        XCTAssertEqual(snapshotRequests.count, 1)
        let request = try XCTUnwrap(snapshotRequests.first)
        XCTAssertEqual(request.contentType, "application/octet-stream")
        XCTAssertTrue(request.authorizationPresent)
        XCTAssertEqual(request.framedPayloadBytes, upload.snapshotBytes)
        let prefixBytes = try XCTUnwrap(request.framedPrefixBytes)
        XCTAssertEqual(request.bodyByteCount, prefixBytes + upload.snapshotBytes)
        XCTAssertGreaterThan(upload.snapshotBytes, 1024 * 1024)
        let remoteFile = await remote.remoteMaterializedFile("workspace/big.bin")
        let remoteData = try Data(contentsOf: remoteFile)
        XCTAssertEqual(remoteData, big)
        await source.cleanUp(upload)
    }

    private func clientCleanUp(_ uploads: HandoffPreparedUpload...) async {
        for upload in uploads {
            for url in upload.temporaryFiles {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
