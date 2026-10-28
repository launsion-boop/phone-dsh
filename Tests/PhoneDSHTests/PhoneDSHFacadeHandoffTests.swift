// SPDX-License-Identifier: MIT
// D15 facade handoff/reclaim tests.
//
// These exercise the public PhoneDSHHost surface (not the coordinator in
// isolation): a real ordered-channel Worker, the real controller/WAL/fence,
// and the in-process remote through the facade's injected transport seam.

import Foundation
import XCTest
import PhoneDSHController
@testable import PhoneDSH
import PhoneDSHLog
import PhoneDSHWire

/// Ordered D14 transition recorder for the facade event stream.
final class FacadeTransitionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [HostTransitionRecord] = []
    private var task: Task<Void, Never>? = nil

    init(_ stream: AsyncStream<PhoneDSHEvent>) {
        task = Task { [weak self] in
            for await event in stream {
                guard case .hostTransition(let record) = event else { continue }
                guard let self else { return }
                self.lock.withLock { self.stored.append(record) }
            }
        }
    }

    var records: [HostTransitionRecord] {
        lock.withLock { stored }
    }

    var targets: [HostState] {
        records.map(\.to)
    }

    func stop() {
        task?.cancel()
    }
}

/// One deterministic pause in the facade handoff path.
///
/// The test installs it through the host's internal preparation seam, so a
/// lifecycle call or a WebContent termination can be injected while the
/// handoff still owns the exclusive operation but before the local runtime is
/// suspended.
actor FacadeHandoffGate {
    private var entered = false
    private var released = false
    private var enterWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        entered = true
        let waiters = enterWaiters
        enterWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        if released { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitForEnter() async {
        if entered { return }
        await withCheckedContinuation { continuation in
            enterWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

final class PhoneDSHFacadeHandoffTests: XCTestCase {
    // MARK: - Fixture

    private func makeConfiguration(_ fixture: FacadeFixture) throws
        -> PhoneDSHConfiguration {
        let endpoint = try XCTUnwrap(URL(string: "https://remote.invalid"))
        let origin = try XCTUnwrap(URL(string: "http://127.0.0.1:1"))
        return PhoneDSHConfiguration(
            workspaceRoot: fixture.workspace,
            token: "test-token",
            origin: origin,
            bundle: fixture.bundle,
            handoff: HandoffClientConfiguration(
                endpoint: endpoint,
                credentialService: HandoffTestCredentials.service),
            credentialProvider: HandoffTestCredentials.provider(),
            drainDeadline: 1,
            helloTimeout: 10)
    }

    private func makeHost(_ fixture: FacadeFixture,
                          engine: MockEngine,
                          transport: any HandoffHTTPTransport) throws
        -> PhoneDSHHost {
        PhoneDSHHost(configuration: try makeConfiguration(fixture),
                     engineFactory: { _ in engine },
                     handoffTransport: transport)
    }

    private func makeRemote(_ fixture: FacadeFixture,
                            initialFence: Fence? = nil) throws
        -> HandoffServerSimulator {
        let root = fixture.root.appendingPathComponent("remote", isDirectory: true)
        if let initialFence {
            return try makeSimulator(root: root, initialFence: initialFence)
        }
        return try makeSimulator(root: root)
    }

    private func writeLocalFile(_ engine: MockEngine,
                                path: String = "/dsh/workspace/local.txt",
                                text: String = "local") async throws -> UInt64 {
        let mseq = try await engine.worker.writeFile(path: path,
                                                     data: Data(text.utf8))
        try await engine.worker.waitForAck(mseq)
        return mseq
    }

    // MARK: - Full D15 cycle through the facade

    func testFacadeRunsFullHandoffAndReclaimCycle() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let remote = try makeRemote(fixture)
        let engine = MockEngine(worker: MockWorker())
        let host = try makeHost(fixture, engine: engine, transport: remote)
        let recorder = FacadeTransitionRecorder(host.eventStream())
        defer { recorder.stop() }

        try await host.start()
        let localMseq = try await writeLocalFile(engine)
        let localURL = fixture.materializedFile("workspace/local.txt")
        try await waitUntil { (try? Data(contentsOf: localURL)) != nil }

        let completion = try await host.beginHandoff()
        XCTAssertEqual(completion.remoteFence.owner, HandoffLimits.remoteOwner)
        XCTAssertEqual(completion.remoteFence.generation, 1)
        XCTAssertEqual(completion.walSeq, localMseq)

        var diagnostics = await host.diagnostics()
        XCTAssertEqual(diagnostics.state, .remote)
        XCTAssertEqual(diagnostics.hostState, .remote)
        XCTAssertEqual(diagnostics.admission, .closed)
        XCTAssertEqual(diagnostics.fence?.wireFence, completion.remoteFence)
        XCTAssertEqual(engine.bootCount, 1, "handoff must stop the local Worker")
        let remoteOpen = await remote.isAdmissionOpen()
        XCTAssertTrue(remoteOpen)
        let remoteFile = await remote.remoteMaterializedFile("workspace/local.txt")
        let remoteLocal = try String(contentsOf: remoteFile, encoding: .utf8)
        XCTAssertEqual(remoteLocal, "local")

        // A second begin while Remote is refused without touching the remote.
        do {
            _ = try await host.beginHandoff()
            XCTFail("beginHandoff while Remote must be refused")
        } catch {
            guard case PhoneDSHError.invalidState = error else {
                return XCTFail("expected invalidState, got \(error)")
            }
        }
        var counters = await remote.endpointCounters()
        XCTAssertEqual(counters.fenceRequests, 1)
        XCTAssertEqual(counters.snapshotUploads, 1)
        XCTAssertEqual(counters.segmentsUploads, 1)

        let remoteMseq = try await remote.appendRemoteMutation(
            HandoffMutations.write("/dsh/workspace/remote.txt", "from-remote"))
        XCTAssertEqual(remoteMseq, completion.walSeq + 1)

        let outcome = try await host.reclaim()
        XCTAssertEqual(outcome.fence.owner, HandoffLimits.phoneOwner)
        XCTAssertEqual(outcome.fence.generation,
                       completion.remoteFence.generation + 1)
        XCTAssertEqual(outcome.fence.walSeq, remoteMseq)
        XCTAssertEqual(outcome.appliedMseq, remoteMseq)
        XCTAssertTrue(outcome.epochClosed)
        XCTAssertEqual(engine.bootCount, 2,
                       "reclaim must boot the local Worker again")

        diagnostics = await host.diagnostics()
        XCTAssertEqual(diagnostics.state, .running)
        XCTAssertEqual(diagnostics.hostState, .running)
        XCTAssertEqual(diagnostics.admission, .open)
        XCTAssertEqual(diagnostics.fence?.wireFence, outcome.fence)
        let remoteAdmission = await remote.isAdmissionOpen()
        XCTAssertFalse(remoteAdmission,
                       "the remote must stay closed after returning authority")
        let remoteContents = try String(
            contentsOf: fixture.materializedFile("workspace/remote.txt"),
            encoding: .utf8)
        XCTAssertEqual(remoteContents, "from-remote")

        // The facade must expose the whole D14 sequence, and admission is
        // closed on every authority-changing edge (open only on Running).
        try await waitUntil {
            var index = 0
            let expected: [HostState] = [.handingOff, .remote, .reclaiming,
                                         .recovering, .running]
            for target in recorder.targets
            where index < expected.count && target == expected[index] {
                index += 1
            }
            return index == expected.count
        }
        let expected: [HostState] = [.handingOff, .remote, .reclaiming,
                                     .recovering, .running]
        var index = 0
        for target in recorder.targets
        where index < expected.count && target == expected[index] {
            index += 1
        }
        XCTAssertEqual(index, expected.count, "transitions: \(recorder.targets)")
        let authorityEdges = recorder.records.filter {
            [.handingOff, .remote, .reclaiming, .recovering].contains($0.to)
        }
        XCTAssertFalse(authorityEdges.isEmpty)
        XCTAssertTrue(authorityEdges.allSatisfy { $0.admission == .closed })
        let reclaimedRunning = recorder.records.last { $0.to == .running }
        XCTAssertEqual(reclaimedRunning?.admission, .open)

        // Reclaim is refused once the host is Running again, and the remote
        // endpoint is not called a second time.
        do {
            _ = try await host.reclaim()
            XCTFail("reclaim while Running must be refused")
        } catch {
            guard case PhoneDSHError.invalidState = error else {
                return XCTFail("expected invalidState, got \(error)")
            }
        }
        counters = await remote.endpointCounters()
        XCTAssertEqual(counters.reclaimRequests, 1)

        try await host.start() // idempotent while Running
        try await host.stop()
    }

    // MARK: - Failure before the fence CAS

    func testHandoffFailsLoudWhenFenceCASLoses() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        // The remote already advanced to generation 1 while the phone is 0.
        let remote = try makeRemote(
            fixture,
            initialFence: Fence(owner: HandoffLimits.remoteOwner,
                                generation: 1, walSeq: 0))
        let engine = MockEngine(worker: MockWorker())
        let host = try makeHost(fixture, engine: engine, transport: remote)

        try await host.start()
        _ = try await writeLocalFile(engine)
        do {
            _ = try await host.beginHandoff()
            XCTFail("a stale fence CAS must fail the handoff")
        } catch {
            XCTAssertEqual(error as? HandoffError, .fenceConflict)
        }

        let state = await host.state
        XCTAssertEqual(state, .failed)
        let diagnostics = await host.diagnostics()
        XCTAssertEqual(diagnostics.hostState, .failed)
        XCTAssertEqual(diagnostics.admission, .closed)
        XCTAssertEqual(diagnostics.fence?.owner, HandoffLimits.phoneOwner)
        XCTAssertEqual(diagnostics.fence?.generation, 0)
        let counters = await remote.endpointCounters()
        XCTAssertEqual(counters.fenceRequests, 1)
        XCTAssertEqual(counters.snapshotUploads, 0)
        XCTAssertEqual(counters.segmentsUploads, 0)
        let remoteOpen = await remote.isAdmissionOpen()
        XCTAssertFalse(remoteOpen)

        // D14 fail-loud: start() stays refused until the user resets.
        do {
            try await host.start()
            XCTFail("a failed host must stay failed")
        } catch let error as PhoneDSHError {
            guard case .hostFailed = error else {
                return XCTFail("expected hostFailed, got \(error)")
            }
        }
        try await host.stop()
    }

    // MARK: - Failure after the fence CAS

    func testHandoffFailureAfterCASReclaimsAndRecovers() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let remote = try makeRemote(fixture)
        let failing = FailingHandoffTransport(base: remote,
                                              pathSuffix: "/snapshot",
                                              times: 1,
                                              error: .transport("offline"))
        let engine = MockEngine(worker: MockWorker())
        let host = try makeHost(fixture, engine: engine, transport: failing)

        try await host.start()
        let mseq = try await writeLocalFile(engine)
        let localURL = fixture.materializedFile("workspace/local.txt")
        try await waitUntil { (try? Data(contentsOf: localURL)) != nil }

        do {
            _ = try await host.beginHandoff()
            XCTFail("the injected snapshot failure must abort the handoff")
        } catch {
            XCTAssertEqual(error as? HandoffError, .transport("offline"))
        }

        var state = await host.state
        XCTAssertEqual(state, .starting)
        var diagnostics = await host.diagnostics()
        XCTAssertEqual(diagnostics.hostState, .reclaiming)
        XCTAssertEqual(diagnostics.admission, .closed)
        XCTAssertEqual(diagnostics.fence?.owner, HandoffLimits.remoteOwner)
        XCTAssertEqual(diagnostics.fence?.generation, 1)
        let countersAfterFailure = await remote.endpointCounters()
        XCTAssertEqual(countersAfterFailure.fenceRequests, 1)
        XCTAssertEqual(countersAfterFailure.snapshotUploads, 0)
        let remoteOpen = await remote.isAdmissionOpen()
        XCTAssertFalse(remoteOpen)
        XCTAssertEqual(engine.bootCount, 1)

        // The fence is already remote; reclaim() must still bring it home.
        let outcome = try await host.reclaim()
        XCTAssertEqual(outcome.fence.owner, HandoffLimits.phoneOwner)
        XCTAssertEqual(outcome.fence.generation, 2)
        XCTAssertEqual(outcome.fence.walSeq, mseq)
        XCTAssertTrue(outcome.epochClosed)
        XCTAssertEqual(engine.bootCount, 2)

        state = await host.state
        XCTAssertEqual(state, .running)
        diagnostics = await host.diagnostics()
        XCTAssertEqual(diagnostics.hostState, .running)
        XCTAssertEqual(diagnostics.admission, .open)
        XCTAssertEqual(diagnostics.fence?.wireFence, outcome.fence)
        XCTAssertNotNil(try? Data(contentsOf: localURL))
        let counters = await remote.endpointCounters()
        XCTAssertEqual(counters.reclaimRequests, 1)
        try await host.stop()
    }

    // MARK: - Same-process host restart in Remote

    func testStoppedRemoteHostReclaimsAfterRestart() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let remote = try makeRemote(fixture)
        let engine = MockEngine(worker: MockWorker())
        let host = try makeHost(fixture, engine: engine, transport: remote)

        try await host.start()
        _ = try await writeLocalFile(engine)
        let localURL = fixture.materializedFile("workspace/local.txt")
        try await waitUntil { (try? Data(contentsOf: localURL)) != nil }
        let completion = try await host.beginHandoff()
        XCTAssertEqual(completion.remoteFence.owner, HandoffLimits.remoteOwner)

        // stop() releases the local runtime but must keep the memory-only
        // reclaim token/coordinator for the same host incarnation.
        try await host.stop()
        var state = await host.state
        XCTAssertEqual(state, .stopped)
        let stoppedDiagnostics = await host.diagnostics()
        XCTAssertEqual(stoppedDiagnostics.state, .stopped)

        let remoteMseq = try await remote.appendRemoteMutation(
            HandoffMutations.write("/dsh/workspace/restarted.txt", "after-stop"))
        let outcome = try await host.reclaim()
        XCTAssertEqual(outcome.fence.owner, HandoffLimits.phoneOwner)
        XCTAssertEqual(outcome.fence.generation,
                       completion.remoteFence.generation + 1)
        XCTAssertEqual(outcome.fence.walSeq, remoteMseq)
        XCTAssertEqual(engine.bootCount, 2)

        state = await host.state
        XCTAssertEqual(state, .running)
        let diagnostics = await host.diagnostics()
        XCTAssertEqual(diagnostics.admission, .open)
        XCTAssertEqual(diagnostics.fence?.wireFence, outcome.fence)
        let contents = try String(
            contentsOf: fixture.materializedFile("workspace/restarted.txt"),
            encoding: .utf8)
        XCTAssertEqual(contents, "after-stop")
        try await host.stop()
    }

    // MARK: - Local fence persistence fails after the remote CAS

    func testHandoffKeepsReclaimTokenWhenLocalFenceWriteFails() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let remote = try makeRemote(fixture)
        let engine = MockEngine(worker: MockWorker())
        let host = try makeHost(fixture, engine: engine, transport: remote)

        try await host.start()
        let localMseq = try await writeLocalFile(engine)
        let localURL = fixture.materializedFile("workspace/local.txt")
        try await waitUntil { (try? Data(contentsOf: localURL)) != nil }

        // Break only the local fence record after the authority was loaded.
        // The remote CAS below still succeeds; the following local write
        // cannot, which is exactly the post-CAS failure window.
        let fenceURL = fixture.workspace.appendingPathComponent("fence.json")
        let fenceTemporaryURL = fixture.workspace.appendingPathComponent("fence.json.tmp")
        try FileManager.default.removeItem(at: fenceURL)
        try FileManager.default.createDirectory(at: fenceURL,
                                                withIntermediateDirectories: false)

        do {
            _ = try await host.beginHandoff()
            XCTFail("the local fence write failure must abort the handoff")
        } catch {
            guard case HandoffError.fenceMismatch = error else {
                return XCTFail("expected a fence persistence failure, got \(error)")
            }
        }

        // The remote owns generation + 1, but the persisted file still says
        // phone. The facade must not classify this as a pre-CAS failure and
        // must keep the reclaim token/coordinator alive.
        var state = await host.state
        XCTAssertEqual(state, .starting)
        var diagnostics = await host.diagnostics()
        XCTAssertEqual(diagnostics.hostState, .reclaiming)
        XCTAssertEqual(diagnostics.admission, .closed)
        XCTAssertEqual(diagnostics.fence?.owner, HandoffLimits.phoneOwner)
        XCTAssertEqual(diagnostics.fence?.generation, 0)
        let counters = await remote.endpointCounters()
        XCTAssertEqual(counters.fenceRequests, 1)
        XCTAssertEqual(counters.snapshotUploads, 0)
        XCTAssertEqual(counters.segmentsUploads, 0)
        let remoteOpen = await remote.isAdmissionOpen()
        XCTAssertFalse(remoteOpen)

        // A local start must refuse while the controller is Reclaiming, even
        // though fence.json still names the phone.
        do {
            try await host.start()
            XCTFail("start must refuse a post-CAS Reclaiming host")
        } catch {
            guard case PhoneDSHError.invalidState = error else {
                return XCTFail("expected invalidState, got \(error)")
            }
        }

        // Repair the local record path: reclaim() must retry the pending remote
        // fence record, use the retained token and return authority home.
        try FileManager.default.removeItem(at: fenceURL)
        try? FileManager.default.removeItem(at: fenceTemporaryURL)

        let outcome = try await host.reclaim()
        XCTAssertEqual(outcome.fence.owner, HandoffLimits.phoneOwner)
        XCTAssertEqual(outcome.fence.generation, 2)
        XCTAssertEqual(outcome.fence.walSeq, localMseq)
        XCTAssertTrue(outcome.epochClosed)
        XCTAssertEqual(engine.bootCount, 2)

        state = await host.state
        XCTAssertEqual(state, .running)
        diagnostics = await host.diagnostics()
        XCTAssertEqual(diagnostics.hostState, .running)
        XCTAssertEqual(diagnostics.admission, .open)
        XCTAssertEqual(diagnostics.fence?.wireFence, outcome.fence)
        let reclaimCounters = await remote.endpointCounters()
        XCTAssertEqual(reclaimCounters.reclaimRequests, 1)
        try await host.stop()
    }

    // MARK: - Lifecycle calls cannot enter a handoff

    func testHandoffRefusesConcurrentLifecycleOperationsAndTermination() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let remote = try makeRemote(fixture)
        let engine = MockEngine(worker: MockWorker())
        let host = try makeHost(fixture, engine: engine, transport: remote)
        let gate = FacadeHandoffGate()
        await host.setHandoffPreparationProbeForTesting {
            await gate.enterAndWait()
        }

        try await host.start()
        _ = try await writeLocalFile(engine)
        let localURL = fixture.materializedFile("workspace/local.txt")
        try await waitUntil { (try? Data(contentsOf: localURL)) != nil }

        let handoff = Task { try await host.beginHandoff() }
        try await gate.waitForEnter()

        // The handoff owns the lifecycle gate before suspending the runtime.
        // Every lifecycle entry must be refused without touching the runtime.
        do {
            try await host.stop()
            XCTFail("stop must not run inside a handoff")
        } catch {
            guard case PhoneDSHError.invalidState = error else {
                return XCTFail("expected invalidState from stop, got \(error)")
            }
        }
        do {
            try await host.park()
            XCTFail("park must not run inside a handoff")
        } catch {
            guard case PhoneDSHError.invalidState = error else {
                return XCTFail("expected invalidState from park, got \(error)")
            }
        }
        do {
            try await host.plannedRestart(reason: "during-handoff")
            XCTFail("plannedRestart must not run inside a handoff")
        } catch {
            guard case PhoneDSHError.invalidState = error else {
                return XCTFail("expected invalidState from plannedRestart, got \(error)")
            }
        }

        // A WebContent termination in the same window must be ignored instead
        // of taking Running -> Recovering under the handoff.
        engine.emit(.terminated(1))
        try await Task.sleep(nanoseconds: 150_000_000)

        var diagnostics = await host.diagnostics()
        XCTAssertEqual(diagnostics.hostState, .running)
        XCTAssertEqual(diagnostics.state, .running)
        XCTAssertEqual(diagnostics.admission, .open)
        XCTAssertEqual(engine.bootCount, 1)

        await gate.release()
        let completion = try await handoff.value
        XCTAssertEqual(completion.remoteFence.owner, HandoffLimits.remoteOwner)
        diagnostics = await host.diagnostics()
        XCTAssertEqual(diagnostics.state, .remote)
        XCTAssertEqual(diagnostics.hostState, .remote)
        XCTAssertEqual(diagnostics.admission, .closed)
        XCTAssertEqual(engine.bootCount, 1,
                       "a termination during handoff must not boot the local Worker")
        try await host.stop()
    }

    // MARK: - Endpoint identity

    func testInvalidHandoffEndpointWritesNoIntentAndSendsNoRequest() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let remote = try makeRemote(fixture)
        let origin = try XCTUnwrap(URL(string: "http://127.0.0.1:1"))
        var credentialComponents = try XCTUnwrap(
            URLComponents(string: "https://remote.invalid/team/dsh"))
        credentialComponents.user = "user"
        credentialComponents.password = "password"
        let credentialEndpoint = try XCTUnwrap(credentialComponents.url)
        let queryEndpoint = try XCTUnwrap(
            URL(string: "https://remote.invalid/team/dsh?access_token=secret"))
        let fragmentEndpoint = try XCTUnwrap(
            URL(string: "https://remote.invalid/team/dsh#secret"))
        let endpoints = [credentialEndpoint, queryEndpoint, fragmentEndpoint]
        for endpoint in endpoints {
            let configuration = PhoneDSHConfiguration(
                workspaceRoot: fixture.workspace,
                token: "test-token",
                origin: origin,
                bundle: fixture.bundle,
                handoff: HandoffClientConfiguration(
                    endpoint: endpoint,
                    credentialService: HandoffTestCredentials.service),
                credentialProvider: HandoffTestCredentials.provider(),
                drainDeadline: 1,
                helloTimeout: 10)
            let engine = MockEngine(worker: MockWorker())
            let host = PhoneDSHHost(configuration: configuration,
                                    engineFactory: { _ in engine },
                                    handoffTransport: remote)
            do {
                try await host.start()
                XCTFail("endpoint \(endpoint.absoluteString) must be rejected "
                    + "before local state opens")
            } catch let error as PhoneDSHError {
                guard case .invalidConfiguration(let detail) = error else {
                    return XCTFail(
                        "unexpected error \(error) for \(endpoint.absoluteString)")
                }
                XCTAssertTrue(detail.contains("endpoint"))
            }
            XCTAssertEqual(engine.bootCount, 0)
            let intent = try FenceAuthority.loadHandoffAuthorityIntent(
                root: fixture.workspace)
            XCTAssertNil(intent,
                         "no authority intent may be written for \(endpoint.absoluteString)")
        }
        let counters = await remote.endpointCounters()
        XCTAssertEqual(counters.fenceRequests, 0)
        XCTAssertEqual(counters.snapshotUploads, 0)
        XCTAssertEqual(counters.segmentsUploads, 0)
        XCTAssertEqual(counters.reclaimRequests, 0)
    }

}
