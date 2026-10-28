// SPDX-License-Identifier: MIT
// End-to-end handoff cycle and controller-transition tests.

import XCTest
import PhoneDSHController
import PhoneDSH
import PhoneDSHLog
import PhoneDSHWire

/// Shuts the controller down inside `prepareHandoff`, after the coordinator
/// has entered `HandingOff` but before the CAS and every local step after it.
private struct ShutdownDuringPrepareSource: HandoffSourceProviding {
    let base: HandoffWorkspaceSnapshotter
    let machine: HostStateMachine

    func prepareHandoff() async throws -> HandoffPreparedUpload {
        await machine.shutdown()
        return try await base.prepareHandoff()
    }

    func cleanUp(_ upload: HandoffPreparedUpload) async {
        await base.cleanUp(upload)
    }
}

/// Pauses after the source was asked to prepare, so the caller can be
/// cancelled while the coordinator is still before the intent/CAS.
private struct GatedPrepareSource: HandoffSourceProviding {
    let base: HandoffWorkspaceSnapshotter
    let gate: FacadeHandoffGate

    func prepareHandoff() async throws -> HandoffPreparedUpload {
        await gate.enterAndWait()
        return try await base.prepareHandoff()
    }

    func cleanUp(_ upload: HandoffPreparedUpload) async {
        await base.cleanUp(upload)
    }
}

final class HandoffCoordinatorTests: XCTestCase {
    /// One assembled phone: workspace fixture, controller, fence authority, the
    /// snapshot source and the coordinator over a simulated remote.
    struct PhoneFixture {
        let directory: HandoffTemporaryDirectory
        let root: URL
        let machine: HostStateMachine
        let authority: FenceAuthority
        let source: HandoffWorkspaceSnapshotter
        let remote: HandoffServerSimulator
        let coordinator: HandoffCoordinator

        func cleanUp() {
            directory.cleanUp()
        }
    }

    private static let phoneMutations: [VfsMutationBody] = [
        HandoffMutations.write("/dsh/workspace/a.txt", "alpha"),
        HandoffMutations.mkdir("/dsh/workspace/sub"),
        HandoffMutations.write("/dsh/workspace/b.txt", "bravo"),
        HandoffMutations.write("/dsh/workspace/c.txt", "charlie"),
    ]

    /// Builds a lagging phone workspace (base 2, WAL tail 4) so the handoff
    /// exercises a non-empty segments upload, and wires the landed controller
    /// services and the simulated remote around it.
    private func makeFixture(
        transportFactory: (HandoffServerSimulator) -> any HandoffHTTPTransport = { $0 },
        retryPolicy: HandoffRetryPolicy = HandoffRetryPolicy(maximumAttempts: 3,
                                                             baseDelay: 0),
        prepareGate: FacadeHandoffGate? = nil
    ) async throws -> PhoneFixture {
        let directory = try HandoffTemporaryDirectory("coordinator")
        let root = directory.url.appendingPathComponent("phone")
        try HandoffWorkspaceFixture.makeOfflineLaggingWorkspace(
            root: root,
            mutations: Self.phoneMutations,
            materializedCount: 2)
        let configuration = WorkspaceLogConfiguration(root: root)
        let machine = try HostStateMachine(root: root,
                                           epochCloser: nil,
                                           leaseVerifier: nil,
                                           drainDeadlineSeconds: 1)
        _ = try await machine.verifyLease()
        let authority = try FenceAuthority(root: root, owner: "phone",
                                           generation: 0, walSeq: 0)
        let remote = try makeSimulator(
            root: directory.url.appendingPathComponent("remote"))
        let client = try makeHandoffClient(transport: transportFactory(remote))
        let applier = try WorkspaceLogSegmentApplier(
            root: root,
            configuration: configuration,
            bootID: Data(repeating: 0xAA, count: 16))
        let reclaimClient = ReclaimClient(
            client: client,
            applier: applier,
            fences: FenceAuthorityHandoffStore(authority: authority),
            retryPolicy: retryPolicy)
        let source = HandoffWorkspaceSnapshotter(
            root: root,
            configuration: configuration,
            scratchDirectory: directory.url.appendingPathComponent("scratch"))
        let coordinatorSource: any HandoffSourceProviding
        if let prepareGate {
            coordinatorSource = GatedPrepareSource(base: source, gate: prepareGate)
        } else {
            coordinatorSource = source
        }
        let coordinator = HandoffCoordinator(
            machine: machine,
            fences: FenceAuthorityHandoffStore(authority: authority),
            source: coordinatorSource,
            client: client,
            reclaimClient: reclaimClient)
        return PhoneFixture(directory: directory, root: root, machine: machine,
                            authority: authority, source: source, remote: remote,
                            coordinator: coordinator)
    }


    // MARK: - Token precedes a fallible controller step

    func testTokenIsStoredBeforeAControllerTransitionCanFail() async throws {
        let directory = try HandoffTemporaryDirectory("token-before-transition")
        defer { directory.cleanUp() }
        let root = directory.url.appendingPathComponent("phone")
        try HandoffWorkspaceFixture.makeOfflineLaggingWorkspace(
            root: root, mutations: Self.phoneMutations, materializedCount: 2)
        let configuration = WorkspaceLogConfiguration(root: root)
        let machine = try HostStateMachine(root: root,
                                           epochCloser: nil,
                                           leaseVerifier: nil,
                                           drainDeadlineSeconds: 1)
        _ = try await machine.verifyLease()
        let authority = try FenceAuthority(root: root, owner: "phone",
                                           generation: 0, walSeq: 0)
        let remote = try makeSimulator(
            root: directory.url.appendingPathComponent("remote"))
        let client = try makeHandoffClient(transport: remote)
        let applier = try WorkspaceLogSegmentApplier(
            root: root, configuration: configuration,
            bootID: Data(repeating: 0xAC, count: 16))
        let store = InMemoryHandoffReclaimTokenStore()
        let reclaimClient = ReclaimClient(
            client: client, applier: applier,
            fences: FenceAuthorityHandoffStore(authority: authority),
            tokenStore: store)
        let baseSource = HandoffWorkspaceSnapshotter(
            root: root, configuration: configuration,
            scratchDirectory: directory.url.appendingPathComponent("scratch"))
        let coordinator = HandoffCoordinator(
            machine: machine,
            fences: FenceAuthorityHandoffStore(authority: authority),
            source: ShutdownDuringPrepareSource(base: baseSource, machine: machine),
            client: client,
            reclaimClient: reclaimClient)

        do {
            _ = try await coordinator.beginHandoff()
            XCTFail("the shut-down controller must refuse handoffFenceInstalled")
        } catch {
            // Expected: the CAS succeeded, then the controller transition failed.
        }
        let phase = await coordinator.phase
        XCTAssertEqual(phase, .reclaiming)
        let controller = await machine.currentState()
        XCTAssertEqual(controller, .handingOff)
        let loaded = try await store.load()
        let saved = try XCTUnwrap(loaded)
        XCTAssertEqual(saved.token.count, 32)
        XCTAssertEqual(saved.token, saved.token.lowercased())
        XCTAssertEqual(saved.remoteFence?.owner, HandoffLimits.remoteOwner)
        XCTAssertEqual(saved.remoteFence?.generation, 1)
        let fence = await authority.current
        XCTAssertEqual(fence.wireFence,
                       Fence(owner: HandoffLimits.phoneOwner, generation: 0,
                             walSeq: 0),
                       "the local fence write is after the token/transition step")
    }

    // MARK: - Full cycle

    func testFullCyclePhoneRemotePhone() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }

        let completion = try await fixture.coordinator.beginHandoff()
        XCTAssertEqual(completion.baseMseq, 2)
        XCTAssertEqual(completion.walSeq, 4)
        XCTAssertEqual(completion.remoteFence,
                       Fence(owner: "remote", generation: 1, walSeq: 4))
        let handingState = await fixture.machine.currentState()
        XCTAssertEqual(handingState, .remote)
        XCTAssertEqual(fixture.machine.admission.current, .closed)
        let remoteAdmission = await fixture.remote.isAdmissionOpen()
        XCTAssertTrue(remoteAdmission)
        let remoteApplied = await fixture.remote.appliedMseqValue()
        XCTAssertEqual(remoteApplied, 4)
        let remoteBase = await fixture.remote.currentFence()
        XCTAssertEqual(remoteBase, completion.remoteFence)
        let countersAfterHandoff = await fixture.remote.endpointCounters()
        XCTAssertEqual(countersAfterHandoff.fenceRequests, 1)
        XCTAssertEqual(countersAfterHandoff.snapshotUploads, 1)
        XCTAssertEqual(countersAfterHandoff.segmentsUploads, 1)

        // While the phone is Remote, the remote evolves its own WAL.
        let remoteMseq = try await fixture.remote.appendRemoteMutation(
            HandoffMutations.write("/dsh/workspace/remote.txt", "from remote"))
        XCTAssertEqual(remoteMseq, 5)

        let outcome = try await fixture.coordinator.reclaim()
        XCTAssertEqual(outcome.fence,
                       Fence(owner: "phone", generation: 2, walSeq: 5))
        XCTAssertEqual(outcome.appliedMseq, 5)
        XCTAssertEqual(outcome.lastMseq, 5)
        XCTAssertTrue(outcome.epochClosed)
        let reclaimingState = await fixture.machine.currentState()
        XCTAssertEqual(reclaimingState, .recovering)
        XCTAssertEqual(fixture.machine.admission.current, .closed)
        let fence = await fixture.authority.current
        XCTAssertEqual(fence.wireFence, outcome.fence)
        let reclaimCounters = await fixture.remote.endpointCounters()
        XCTAssertEqual(reclaimCounters.reclaimRequests, 1)

        // The next WorkspaceLog open must see the replicated mutations, the new
        // fence and mseq 6 as the next allocation (D17).
        let log = try HandoffWorkspaceFixture.reopen(root: fixture.root)
        let positions = await log.positions()
        XCTAssertEqual(positions.nextMseq, 6)
        XCTAssertEqual(positions.ackedMseq, 5)
        XCTAssertEqual(positions.durableMseq, 5)
        let materialized = try await log.materialize()
        XCTAssertEqual(materialized, 5)
        let remoteFile = HandoffWorkspaceFixture.materialized(
            fixture.root, "workspace/remote.txt")
        let remoteContents = try String(contentsOf: remoteFile, encoding: .utf8)
        XCTAssertEqual(remoteContents, "from remote")
        let phoneFile = HandoffWorkspaceFixture.materialized(
            fixture.root, "workspace/c.txt")
        let phoneContents = try String(contentsOf: phoneFile, encoding: .utf8)
        XCTAssertEqual(phoneContents, "charlie")

        // Recovering -> Running is the only place admission opens (D14/D15).
        _ = try await fixture.machine.verifyLease()
        XCTAssertEqual(fixture.machine.admission.current, .open)
    }

    func testReclaimRequiresTheRemotePhase() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        do {
            _ = try await fixture.coordinator.reclaim()
            XCTFail("reclaim before a handoff must be refused")
        } catch {
            guard case HandoffError.invalidControllerState = error else {
                return XCTFail("expected invalidControllerState, got \(error)")
            }
        }
        let state = await fixture.machine.currentState()
        XCTAssertEqual(state, .running)
    }

    func testCallerCancellationAfterPrepareSendsNoCASOrIntent() async throws {
        let gate = FacadeHandoffGate()
        let fixture = try await makeFixture(prepareGate: gate)
        defer { fixture.cleanUp() }

        let handoff = Task { try await fixture.coordinator.beginHandoff() }
        await gate.waitForEnter()
        handoff.cancel()
        await gate.release()
        do {
            _ = try await handoff.value
            XCTFail("a cancelled caller must not complete the handoff")
        } catch {
            XCTAssertTrue(error is CancellationError,
                          "expected cancellation, got \(error)")
        }

        let counters = await fixture.remote.endpointCounters()
        XCTAssertEqual(counters.fenceRequests, 0,
                       "cancellation after prepare must not send the CAS")
        XCTAssertEqual(counters.snapshotUploads, 0)
        XCTAssertEqual(counters.segmentsUploads, 0)
        let intent = try FenceAuthority.loadHandoffAuthorityIntent(
            root: fixture.root)
        XCTAssertNil(intent,
                     "a cancelled pre-CAS handoff must not leave authority evidence")
        let state = await fixture.machine.currentState()
        XCTAssertEqual(state, .failed)
        XCTAssertEqual(fixture.machine.admission.current, .closed)
    }

    // MARK: - Failure and retry paths

    func testAbortedHandoffReclaimsAndEntersRecovering() async throws {
        let failingFactory: (HandoffServerSimulator) -> any HandoffHTTPTransport = { remote in
            FailingHandoffTransport(base: remote,
                                    pathSuffix: "/snapshot",
                                    times: 1,
                                    error: .transport("offline"))
        }
        let fixture = try await makeFixture(transportFactory: failingFactory)
        defer { fixture.cleanUp() }
        do {
            _ = try await fixture.coordinator.beginHandoff()
            XCTFail("the injected snapshot failure must abort the handoff")
        } catch {
            XCTAssertEqual(error as? HandoffError, .transport("offline"))
        }
        let abortState = await fixture.machine.currentState()
        XCTAssertEqual(abortState, .reclaiming)
        XCTAssertEqual(fixture.machine.admission.current, .closed)

        // The fence was installed, so the return path must still bring the
        // authority home and close an epoch even though no snapshot arrived.
        let outcome = try await fixture.coordinator.reclaim()
        XCTAssertEqual(outcome.fence.owner, "phone")
        XCTAssertEqual(outcome.fence.generation, 2)
        XCTAssertEqual(outcome.fence.walSeq, 4)
        let state = await fixture.machine.currentState()
        XCTAssertEqual(state, .recovering)
        let log = try HandoffWorkspaceFixture.reopen(root: fixture.root)
        let positions = await log.positions()
        XCTAssertEqual(positions.nextMseq, 5)
        let materialized = try await log.materialize()
        XCTAssertEqual(materialized, 4)
    }

    func testLostReclaimResponseRetriesAndAppliesOnce() async throws {
        let droppingFactory: (HandoffServerSimulator) -> any HandoffHTTPTransport = { remote in
            DroppingHandoffTransport(base: remote, pathSuffix: "/reclaim", times: 1)
        }
        let fixture = try await makeFixture(transportFactory: droppingFactory)
        defer { fixture.cleanUp() }
        _ = try await fixture.coordinator.beginHandoff()
        _ = try await fixture.remote.appendRemoteMutation(
            HandoffMutations.write("/dsh/workspace/remote-retry.txt", "retry"))
        let outcome = try await fixture.coordinator.reclaim()
        XCTAssertEqual(outcome.fence.walSeq, 5)
        XCTAssertEqual(outcome.mutationsApplied, 3)
        let counters = await fixture.remote.endpointCounters()
        XCTAssertEqual(counters.reclaimRequests, 2)
        let state = await fixture.machine.currentState()
        XCTAssertEqual(state, .recovering)
        let file = HandoffWorkspaceFixture.materialized(
            fixture.root, "workspace/remote-retry.txt")
        let contents = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(contents, "retry")
    }

    func testStaleFenceCASFailsHandoffLoud() async throws {
        let directory = try HandoffTemporaryDirectory("stale-cas")
        defer { directory.cleanUp() }
        let root = directory.url.appendingPathComponent("phone")
        try HandoffWorkspaceFixture.makeOfflineLaggingWorkspace(
            root: root, mutations: Self.phoneMutations, materializedCount: 2)
        let configuration = WorkspaceLogConfiguration(root: root)
        let machine = try HostStateMachine(root: root, epochCloser: nil,
                                           leaseVerifier: nil,
                                           drainDeadlineSeconds: 1)
        _ = try await machine.verifyLease()
        // The provisioned remote already advanced to generation 1.
        let authority = try FenceAuthority(root: root, owner: "phone",
                                           generation: 0, walSeq: 0)
        let remote = try makeSimulator(
            root: directory.url.appendingPathComponent("remote"),
            initialFence: Fence(owner: "remote", generation: 1, walSeq: 0))
        let client = try makeHandoffClient(transport: remote)
        let applier = try WorkspaceLogSegmentApplier(
            root: root, configuration: configuration,
            bootID: Data(repeating: 0xAB, count: 16))
        let reclaimClient = ReclaimClient(
            client: client, applier: applier,
            fences: FenceAuthorityHandoffStore(authority: authority))
        let source = HandoffWorkspaceSnapshotter(
            root: root, configuration: configuration,
            scratchDirectory: directory.url.appendingPathComponent("scratch"))
        let coordinator = HandoffCoordinator(
            machine: machine,
            fences: FenceAuthorityHandoffStore(authority: authority),
            source: source, client: client, reclaimClient: reclaimClient)
        do {
            _ = try await coordinator.beginHandoff()
            XCTFail("a stale generation CAS must fail")
        } catch {
            XCTAssertEqual(error as? HandoffError, .fenceConflict)
        }
        let state = await machine.currentState()
        XCTAssertEqual(state, .failed)
        let fence = await authority.current
        XCTAssertEqual(fence.wireFence,
                       Fence(owner: "phone", generation: 0, walSeq: 0))
    }
}
