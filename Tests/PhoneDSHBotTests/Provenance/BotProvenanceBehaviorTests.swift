// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

final class BotProvenanceBehaviorTests: XCTestCase {
    private func service(_ log: BotProvenanceTestLog,
                         resolver: (any BotProvenanceEvidenceResolving)? = nil)
        -> BotProvenanceService {
        BotProvenanceService(eventLog: log, resolver: resolver)
    }

    private func derivation(_ artifact: BotDerivedRef, _ sources: [BotDerivationSource])
        -> BotJSONValue {
        (try? ProvenanceTest.encoded(BotDerivation(artifact: artifact, sources: sources)))
            ?? .object([:])
    }

    /// Erasure propagates to every dependent and a later assertion that still
    /// cites the erased record cannot resurrect it.
    func testErasurePropagationAndNoResurrection() async throws {
        let log = BotProvenanceTestLog()
        let source = try await log.append(ProvenanceTest.event(
            type: "conversation.user_message", eventId: "user-e",
            data: .object(["text": .string("erase me")])))
        let baseline = BotProvenanceSourceVersion.known(
            basis: .providerVersion, value: "rev:v1",
            observedAtMS: ProvenanceTest.now, basisRef: "record://event/\(source)")
        let r1 = BotDerivedRef(kind: .routine, id: "erase-r1", version: 1)
        _ = try await log.append(ProvenanceTest.event(
            type: "routine.defined", eventId: "carrier-r1",
            data: .object(["derivation": derivation(r1, [
                BotDerivationSource(record: "record://event/\(source)",
                                    role: .creator, sourceVersion: baseline),
            ])])))
        _ = try await log.append(ProvenanceTest.erasureEvent(
            erasureId: "e", eventRecords: ["record://event/\(source)"]))
        let r2 = BotDerivedRef(kind: .routine, id: "erase-r2", version: 1)
        _ = try await log.append(ProvenanceTest.event(
            type: "routine.defined", eventId: "carrier-r2",
            data: .object(["derivation": derivation(r2, [
                BotDerivationSource(record: "record://event/\(source)",
                                    role: .creator, sourceVersion: baseline),
            ])])))

        let service = service(log)
        let first = try await service.currentState(for: r1)
        XCTAssertEqual(first.state, .erased)
        XCTAssertEqual(first.reasons, [.recordErased])
        XCTAssertEqual(first.sources.first?.status.state, .erased)
        let second = try await service.currentState(for: r2)
        XCTAssertEqual(second.state, .erased)
        let trace = try await service.trace("record://event/\(source)")
        XCTAssertEqual(Set(trace.map(\.artifact)), [r1, r2])

        let restarted = BotProvenanceService(eventLog: log)
        let again = try await restarted.currentState(for: r1)
        XCTAssertEqual(again.state, .erased)
        XCTAssertEqual(again.reasons, [.recordErased])
    }

    /// A newer observation of the same source identity marks the old baseline
    /// changed and points at the latest record.
    func testNewerObservationMarksChanged() async throws {
        let log = BotProvenanceTestLog()
        let first = try await log.append(ProvenanceTest.event(
            type: "conversation.tool_result", eventId: "obs-1",
            at: 1_000,
            data: .object([
                "observation": .object([
                    "source": .string("web"),
                    "origin": .string("https://example.test/x"),
                ]),
                "version": .object([
                    "basis": .string("etag"), "value": .string("etag:e1"),
                    "observed_at_ms": .number(1_000),
                ]),
            ])))
        let baseline = BotProvenanceSourceVersion.known(
            basis: .etag, value: "etag:e1", observedAtMS: 1_000,
            basisRef: "record://event/\(first)")
        let artifact = BotDerivedRef(kind: .memory, id: "user/m.md", version: 1)
        _ = try await log.append(ProvenanceTest.event(
            type: "memory.document_written", eventId: "carrier-newer",
            at: 1_100,
            data: .object(["derivation": derivation(artifact, [
                BotDerivationSource(record: "record://event/\(first)",
                                    role: .evidence, sourceVersion: baseline),
            ])])))
        let second = try await log.append(ProvenanceTest.event(
            type: "conversation.tool_result", eventId: "obs-2",
            at: 1_200,
            data: .object([
                "observation": .object([
                    "source": .string("web"),
                    "origin": .string("https://example.test/x"),
                ]),
                "version": .object([
                    "basis": .string("etag"), "value": .string("etag:e2"),
                    "observed_at_ms": .number(1_200),
                ]),
            ])))

        let state = try await service(log).currentState(for: artifact)
        XCTAssertEqual(state.state, .changed)
        XCTAssertEqual(state.reasons, [.sourceChanged])
        XCTAssertEqual(state.sources.first?.status.latestRef, "record://event/\(second)")
    }

    func testGrantRevocationInvalidatesOnlyThatBaseline() async throws {
        let log = BotProvenanceTestLog()
        let source = try await log.append(ProvenanceTest.event(
            type: "conversation.tool_result", eventId: "obs-grant",
            at: 1_000,
            data: .object([
                "observation": .object([
                    "source": .string("connector"),
                    "origin": .string("mcp://calendar"),
                ]),
                "version": .object(["reason": .string("source-unversioned")]),
            ])))
        let revoked = BotDerivedRef(kind: .routine, id: "g-revoked", version: 1)
        let kept = BotDerivedRef(kind: .routine, id: "g-kept", version: 1)
        let version = BotProvenanceSourceVersion.unknown(reason: .sourceUnversioned,
                                               basisRef: "record://event/\(source)")
        _ = try await log.append(ProvenanceTest.event(
            type: "routine.defined", eventId: "carrier-g1",
            data: .object(["derivation": derivation(revoked, [
                BotDerivationSource(record: "record://event/\(source)",
                                    role: .trigger, sourceVersion: version,
                                    grantId: "g1"),
            ])])))
        _ = try await log.append(ProvenanceTest.event(
            type: "routine.defined", eventId: "carrier-g2",
            data: .object(["derivation": derivation(kept, [
                BotDerivationSource(record: "record://event/\(source)",
                                    role: .trigger, sourceVersion: version,
                                    grantId: "g2"),
            ])])))
        _ = try await log.append(ProvenanceTest.event(
            type: "grant.revoked", eventId: "revoke-g1",
            data: .object(["grantId": .string("g1")])))
        let service = service(log)
        let state = try await service.currentState(for: revoked)
        XCTAssertEqual(state.state, .revoked)
        XCTAssertEqual(state.reasons, [.grantRevoked])
        // The other baseline has a different grant and remains unknown only
        // because its recorded version is explicitly unversioned.
        let other = try await service.currentState(for: kept)
        XCTAssertEqual(other.state, .unknown)
        XCTAssertEqual(other.reasons, [.sourceVersionUnknown])
    }

    /// A stored verified review is downgraded when its source is erased; the
    /// historical review claim itself is not rewritten by the read model.
    func testVerifiedReviewIsDowngradedByErasedBasis() async throws {
        let log = BotProvenanceTestLog()
        let source = try await log.append(ProvenanceTest.event(
            type: "conversation.tool_result", eventId: "obs-review",
            at: 1_000,
            data: .object([
                "observation": .object([
                    "source": .string("web"),
                    "origin": .string("https://example.test/r"),
                ]),
                "version": .object([
                    "basis": .string("etag"), "value": .string("etag:r1"),
                ]),
            ])))
        let artifact = BotDerivedRef(kind: .memory, id: "user/review.md", version: 1)
        let baseline = BotProvenanceSourceVersion.known(
            basis: .etag, value: "etag:r1", basisRef: "record://event/\(source)")
        _ = try await log.append(ProvenanceTest.event(
            type: "memory.document_written", eventId: "carrier-review",
            data: .object([
                "derivation": derivation(artifact, [
                    BotDerivationSource(record: "record://event/\(source)",
                                        role: .review, sourceVersion: baseline),
                ]),
                "review": .object([
                    "state": .string("verified"),
                    "basis": .string("record-recheck"),
                    "refs": .array([.string("record://event/\(source)")]),
                ]),
            ])))
        _ = try await log.append(ProvenanceTest.erasureEvent(
            erasureId: "review", eventRecords: ["record://event/\(source)"]))

        let state = try await service(log).currentState(for: artifact)
        XCTAssertEqual(state.state, .erased)
        XCTAssertEqual(state.reviewEffective.state, .unverified)
        XCTAssertEqual(state.reviewEffective.reasons, [.recordErased])
    }

    func testCycleTurnsWholeCycleUnavailable() async throws {
        let a = BotDerivedRef(kind: .routine, id: "cycle-a", version: 1)
        let b = BotDerivedRef(kind: .routine, id: "cycle-b", version: 1)
        let eventA = ProvenanceTest.event(
            seq: 1, type: "routine.defined", eventId: "cycle-a-event",
            data: .object(["derivation": derivation(a, [
                BotDerivationSource(record: "record://event/2", role: .basis),
            ])]))
        let eventB = ProvenanceTest.event(
            seq: 2, type: "routine.defined", eventId: "cycle-b-event",
            data: .object(["derivation": derivation(b, [
                BotDerivationSource(record: "record://event/1", role: .basis),
            ])]))
        let snapshot = BotProvenanceSnapshot.build(events: [eventA, eventB])
        let view = snapshot.view(for: a, facts: [:])
        XCTAssertEqual(view.state, .unavailable)
        XCTAssertEqual(view.reasons, [.cycleDetected])
        XCTAssertEqual(view.reviewEffective.state, .unknown)
        XCTAssertEqual(view.upstream.map(\.artifact), [b])
        XCTAssertEqual(view.upstream.first?.state, .unavailable)
    }

    func testReplayOrderAndDuplicatesAreDeterministic() async throws {
        let source = ProvenanceTest.event(
            seq: 1, type: "conversation.user_message", eventId: "replay-source",
            data: .object(["text": .string("replay")]))
        let artifact = BotDerivedRef(kind: .memory, id: "agent/replay.md", version: 1)
        let carrier = ProvenanceTest.event(
            seq: 2, type: "memory.document_written", eventId: "replay-carrier",
            data: .object(["derivation": derivation(artifact, [
                BotDerivationSource(record: "record://event/1", role: .evidence),
            ])]))
        let first = BotProvenanceSnapshot.build(events: [source, carrier])
        let shuffled = BotProvenanceSnapshot.build(
            events: [carrier, source, carrier, source])
        XCTAssertEqual(first.generation, shuffled.generation)
        XCTAssertEqual(first.view(for: artifact, facts: first.eventFacts),
                       shuffled.view(for: artifact, facts: shuffled.eventFacts))
        XCTAssertEqual(first.artifacts(), [artifact])
    }

    func testConcurrentQueriesAndAppendsStayOnOneGeneration() async throws {
        let log = BotProvenanceTestLog()
        let source = try await log.append(ProvenanceTest.event(
            type: "conversation.user_message", eventId: "concurrent-source",
            data: .object(["text": .string("concurrent")])))
        let artifact = BotDerivedRef(kind: .routine, id: "concurrent", version: 1)
        let service = service(log)
        let carrierData: BotJSONValue = .object(["derivation": derivation(artifact, [
            BotDerivationSource(record: "record://event/\(source)", role: .creator),
        ])])
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    _ = try? await service.trace("record://event/\(source)")
                }
            }
            group.addTask {
                _ = try? await log.append(ProvenanceTest.event(
                    type: "routine.defined", eventId: "concurrent-carrier",
                    data: carrierData))
            }
            for _ in 0..<8 {
                group.addTask { _ = try? await service.generation() }
            }
        }
        let state = try await service.currentState(for: artifact)
        XCTAssertEqual(state.state, .current)
        let generation = try await service.generation()
        XCTAssertEqual(generation.headCommitSeq, 2)
    }

    func testPrepareBaselineValidatesWithoutCarrier() async throws {
        let log = BotProvenanceTestLog()
        let service = service(log)
        let artifact = BotDerivedRef(kind: .routine, id: "prepare", version: 1)
        let good = BotDerivationSource(
            record: "record://event/1", role: .evidence,
            sourceVersion: .known(basis: .contentSHA256,
                                  value: "sha256:" + String(repeating: "a", count: 64)))
        let prepared = try await service.prepareBaseline(
            BotDerivation(artifact: artifact, sources: [good]))
        XCTAssertEqual(prepared["artifact"]?["kind"]?.stringValue, "routine")
        XCTAssertEqual(prepared["artifact"]?["version"]?.intValue, 1)
        XCTAssertEqual(prepared["sources"]?.arrayValue?.count, 1)

        // A non-canonical reference is rejected.
        do {
            _ = try await service.prepareBaseline(BotDerivation(
                artifact: artifact,
                sources: [BotDerivationSource(record: "record://EVENT/01")]))
            XCTFail("non-canonical reference accepted")
        } catch {}
        // Duplicate (record, role) is rejected.
        do {
            _ = try await service.prepareBaseline(BotDerivation(
                artifact: artifact,
                sources: [good, good]))
            XCTFail("duplicate (record, role) accepted")
        } catch {}
        // A known revision without its basis prefix is rejected.
        do {
            _ = try await service.prepareBaseline(BotDerivation(
                artifact: artifact,
                sources: [BotDerivationSource(
                    record: "record://event/1", role: .evidence,
                    sourceVersion: .known(basis: .etag, value: "e1"))]))
            XCTFail("unprefixed etag accepted")
        } catch {}
        // No carrier event was appended; prepare itself still succeeds.
        let events = await log.all()
        XCTAssertTrue(events.isEmpty)
    }

    func testSourceStatusesForMaintainer() async throws {
        let log = BotProvenanceTestLog()
        let event = try await log.append(ProvenanceTest.event(
            type: "conversation.user_message", eventId: "m-event",
            data: .object(["text": .string("fact")])))
        let session = "record://session/gb-main#3"
        let resolver = BotProvenanceTestResolver(facts: [
            session: BotProvenanceSourceFact(
                resolved: true, erased: false, observedAtMS: 900,
                recordType: "tool/result", trust: "observation",
                version: .known(basis: .providerVersion, value: "rev:x1")),
        ])
        let service = BotProvenanceService(eventLog: log, resolver: resolver)
        let statuses = try await service.sourceStatuses(
            for: ["record://event/\(event)", session])
        XCTAssertEqual(statuses["record://event/\(event)"]?.state, .current)
        let sessionStatus = try XCTUnwrap(statuses[session])
        XCTAssertEqual(sessionStatus.state, .unknown)
        XCTAssertEqual(sessionStatus.reasons, [.noBaseline])
        XCTAssertEqual(sessionStatus.trust, "observation")
        XCTAssertEqual(sessionStatus.recordType, "tool/result")
        XCTAssertEqual(sessionStatus.sourceVersion?.knownValue, "rev:x1")
    }

    func testEventIDToArtifactResolution() async throws {
        let log = BotProvenanceTestLog()
        let source = try await log.append(ProvenanceTest.event(
            type: "conversation.user_message", eventId: "user-card",
            data: .object(["text": .string("card")])))
        _ = try await log.append(ProvenanceTest.event(
            type: "card.presented", eventId: "card-1",
            data: .object(["evidence": .array([.string("record://event/\(source)")])])))
        _ = try await log.append(ProvenanceTest.event(
            type: "routine.defined", eventId: "snapshot-many",
            data: .object(["document": .object([
                "routines": .array([
                    .object(["id": .string("a")]),
                    .object(["id": .string("b")]),
                ]),
            ])])))
        let service = service(log)
        let card = try await service.derivedRef(forEventID: "card-1")
        XCTAssertEqual(card, BotDerivedRef(kind: .delivery, id: "card-1"))
        let ambiguous = try await service.derivedRef(forEventID: "snapshot-many")
        XCTAssertNil(ambiguous)
        let refs = try await service.derivedRefs(forEventID: "snapshot-many")
        XCTAssertEqual(refs, [
            BotDerivedRef(kind: .routine, id: "a"),
            BotDerivedRef(kind: .routine, id: "b"),
        ])
    }

    /// 100 real memory versions written through the production memory path are
    /// all traceable: each view carries a carrier record and resolves its
    /// evidence refs. Freshness is explicitly current/unknown, never faked.
    func testOneHundredRealMemoryDerivativesAreTraceable() async throws {
        let (store, root) = try makeMemoryTestStore()
        defer { cleanupMemoryTestStore(root) }
        let memory = makeMemory(store: store)
        var sourceSeqs: [Int] = []
        for index in 0..<100 {
            let seq = try await store.append(ProvenanceTest.event(
                type: "conversation.user_message",
                eventId: "real-source-\(index)",
                at: ProvenanceTest.now + Int64(index),
                data: .object(["text": .string("real source \(index)")])))
            sourceSeqs.append(seq)
        }
        let context = BotMemoryWriteContext(
            botID: "main", sessionID: "gb-main", authorKind: .chat,
            source: BotMemorySource(kind: .userTurn, sessionID: "gb-main"),
            trust: .assistant)
        var artifacts: [BotDerivedRef] = []
        for index in 0..<100 {
            let path = "agent/notes/real-\(index).md"
            let result = try await memory.write(
                BotMemoryWriteRequest(
                    path: path, content: "derived note \(index)", expectedVersion: 0,
                    evidence: ["record://event/\(sourceSeqs[index])"]),
                context: context)
            XCTAssertTrue(result.ok, "write \(index): \(String(describing: result.code))")
            artifacts.append(BotDerivedRef(
                kind: .memory, id: path, version: try XCTUnwrap(result.version)))
        }
        let service = BotProvenanceService(eventLog: store)
        let states = try await service.currentStates(for: artifacts)
        XCTAssertEqual(states.count, 100)
        var traceable = 0
        for artifact in artifacts {
            guard let state = states[artifact],
                  BotRecordReference.parse(state.carrier ?? "") != nil,
                  state.sources.count == 1,
                  state.sources[0].status.resolved,
                  state.sources[0].status.recordType == "conversation.user_message" else {
                continue
            }
            XCTAssertEqual(state.state, .current)
            traceable += 1
        }
        XCTAssertEqual(traceable, 100)
        let generation = try await service.generation()
        XCTAssertGreaterThanOrEqual(generation.headCommitSeq, 200)
        try? await store.close()
    }
    /// R1: a tool/channel name is not a resource identity. Two observations
    /// with source=tool are never merged into a freshness claim.
    func testToolChannelIsNotAResourceIdentity() async throws {
        let log = BotProvenanceTestLog()
        let first = try await log.append(ProvenanceTest.event(
            type: "conversation.tool_result", eventId: "tool-1", at: 1_000,
            data: .object([
                "observation": .object([
                    "source": .string("tool"),
                    "origin": .string("web_search"),
                ]),
                "version": .object([
                    "basis": .string("provider-version"), "value": .string("rev:q1"),
                ]),
            ])))
        let artifact = BotDerivedRef(kind: .memory, id: "user/tool.md", version: 1)
        _ = try await log.append(ProvenanceTest.event(
            type: "memory.document_written", eventId: "tool-carrier",
            data: .object(["derivation": derivation(artifact, [
                BotDerivationSource(
                    record: "record://event/\(first)", role: .evidence,
                    sourceVersion: .known(basis: .providerVersion, value: "rev:q1")),
            ])])))
        let state = try await service(log).currentState(for: artifact)
        XCTAssertEqual(state.state, .unknown)
        XCTAssertEqual(state.reasons, [.noResourceIdentity])
    }

    /// R1: the same URL under different owners/scopes is not one resource.
    func testSameURLDifferentOwnerIsNotMerged() async throws {
        let log = BotProvenanceTestLog()
        func observation(_ eventId: String, botID: String, value: String,
                         at: Int64) async throws -> Int {
            try await log.append(ProvenanceTest.event(
                type: "conversation.tool_result", eventId: eventId, at: at,
                data: .object([
                    "observation": .object([
                        "source": .string("web"),
                        "origin": .string("https://shared.example/doc"),
                    ]),
                    "version": .object([
                        "basis": .string("etag"), "value": .string(value),
                    ]),
                ]),
                botID: botID))
        }
        let first = try await observation("owner-a-1", botID: "bot-a",
                                          value: "etag:a1", at: 1_000)
        _ = try await observation("owner-b-2", botID: "bot-b",
                                  value: "etag:b2", at: 1_200)
        let artifact = BotDerivedRef(kind: .memory, id: "user/owner.md", version: 1)
        _ = try await log.append(ProvenanceTest.event(
            type: "memory.document_written", eventId: "owner-carrier",
            data: .object(["derivation": derivation(artifact, [
                BotDerivationSource(
                    record: "record://event/\(first)", role: .evidence,
                    sourceVersion: .known(basis: .etag, value: "etag:a1")),
            ])])))
        let state = try await service(log).currentState(for: artifact)
        XCTAssertEqual(state.state, .unknown)
        XCTAssertEqual(state.reasons, [.resourceScopeMismatch])
        XCTAssertNil(state.sources.first?.status.latestRef)
    }

    /// R1/R2: a P fact with a version but no durable observation carrier has no
    /// resource identity; it is explicitly unverified, not current.
    func testVersionWithoutObservationCarrierIsUnverified() async throws {
        let log = BotProvenanceTestLog()
        let ref = "record://session/gb-main#3"
        let resolver = BotProvenanceTestResolver(facts: [
            ref: BotProvenanceSourceFact(
                resolved: true, erased: false, observedAtMS: 900,
                recordType: "tool/result", trust: "observation",
                version: .known(basis: .contentSHA256,
                                value: "sha256:" + String(repeating: "a", count: 64))),
        ])
        let state = try await BotProvenanceService(eventLog: log, resolver: resolver)
            .sourceStatuses(for: [ref])[ref]
        XCTAssertEqual(state?.state, .unknown)
        XCTAssertEqual(state?.reasons, [.noBaseline])
        XCTAssertNotEqual(state?.state, .current)
    }

    /// R1: different real resources of the same tool are separate identities.
    func testSameToolDifferentResourcesDoNotSupersede() async throws {
        let log = BotProvenanceTestLog()
        func observation(_ eventId: String, origin: String, value: String,
                         at: Int64) async throws -> Int {
            try await log.append(ProvenanceTest.event(
                type: "conversation.tool_result", eventId: eventId, at: at,
                data: .object([
                    "observation": .object([
                        "source": .string("web"), "origin": .string(origin),
                    ]),
                    "version": .object([
                        "basis": .string("etag"), "value": .string(value),
                    ]),
                ])))
        }
        let first = try await observation("resource-a", origin: "https://a.example/x",
                                          value: "etag:a1", at: 1_000)
        _ = try await observation("resource-b", origin: "https://b.example/y",
                                  value: "etag:b2", at: 1_200)
        let artifact = BotDerivedRef(kind: .memory, id: "user/resource.md", version: 1)
        _ = try await log.append(ProvenanceTest.event(
            type: "memory.document_written", eventId: "resource-carrier",
            data: .object(["derivation": derivation(artifact, [
                BotDerivationSource(
                    record: "record://event/\(first)", role: .evidence,
                    sourceVersion: .known(basis: .etag, value: "etag:a1")),
            ])])))
        let state = try await service(log).currentState(for: artifact)
        XCTAssertEqual(state.state, .unknown)
        XCTAssertEqual(state.reasons, [.refreshNotPerformed])
        XCTAssertNil(state.sources.first?.status.latestRef)
    }

}
