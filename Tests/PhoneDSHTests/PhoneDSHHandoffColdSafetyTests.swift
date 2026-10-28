// SPDX-License-Identifier: MIT
// Cold-process handoff safety regressions.
//
// The first facade pass kept the reclaim token only in the live
// HandoffCoordinator/ReclaimClient. These tests exercise the remaining gaps:
// a fresh PhoneDSHHost (no same-object context) reclaims through the injected
// secure token store; a lost CAS response leaves non-secret authority evidence
// and never boots a new host; an explicit App-held token is a complete cold
// recovery entry; and the real engine teardown happens before the CAS.

import Foundation
import XCTest
import PhoneDSHController
@testable import PhoneDSH
import PhoneDSHEngine
import PhoneDSHLog
import PhoneDSHWire

/// Drops the fence-CAS response *after* the wrapped remote applied it, keeping
/// the response token so a test can play the App that has a saved credential.
final class CASResponseDroppingTransport: HandoffHTTPTransport, @unchecked Sendable {
    let base: any HandoffHTTPTransport
    private let lock = NSLock()
    private var token: String?

    init(base: any HandoffHTTPTransport) {
        self.base = base
    }

    var capturedReclaimToken: String? {
        lock.withLock { token }
    }

    func send(_ request: HandoffHTTPRequest) async throws -> HandoffHTTPResponse {
        let response = try await base.send(request)
        if request.url.path.hasSuffix("/fence"),
           (200..<300).contains(response.status),
           let decoded = try? JSONDecoder().decode(HandoffFenceResponse.self,
                                                   from: response.bodyData) {
            lock.withLock { token = decoded.reclaimToken }
            throw HandoffError.transport("the CAS response was lost")
        }
        return response
    }

    func download(_ request: HandoffHTTPRequest) async throws -> HandoffHTTPDownload {
        try await base.download(request)
    }
}

/// Records the engine shutdown count observed at the moment the fence CAS
/// request reaches the remote, proving the Worker was torn down first.
final class FenceShutdownOrderTransport: HandoffHTTPTransport, @unchecked Sendable {
    let base: any HandoffHTTPTransport
    let engine: MockEngine
    private let lock = NSLock()
    private var observedTerminations: Int?
    private var observedShutdowns: Int?

    init(base: any HandoffHTTPTransport, engine: MockEngine) {
        self.base = base
        self.engine = engine
    }

    var terminateCountAtFence: Int? {
        lock.withLock { observedTerminations }
    }

    var shutdownCountAtFence: Int? {
        lock.withLock { observedShutdowns }
    }

    func send(_ request: HandoffHTTPRequest) async throws -> HandoffHTTPResponse {
        if request.url.path.hasSuffix("/fence") {
            lock.withLock {
                observedTerminations = engine.terminateCount
                observedShutdowns = engine.shutdownCount
            }
        }
        return try await base.send(request)
    }

    func download(_ request: HandoffHTTPRequest) async throws -> HandoffHTTPDownload {
        try await base.download(request)
    }
}


/// Records the persisted controller state and whether the vault token is still
/// present at the moment the cold reclaim request reaches the remote. The
/// controller must already be `Reclaiming`, and the token must not be consumed
/// before that transition is durable.
final class ReclaimStateProbeTransport: HandoffHTTPTransport, @unchecked Sendable {
    struct Observation: Sendable {
        var state: String?
        var tokenStillStored: Bool
    }

    let base: any HandoffHTTPTransport
    let stateURL: URL
    let store: any HandoffReclaimTokenStore
    private let lock = NSLock()
    private var observed: Observation?

    init(base: any HandoffHTTPTransport, stateURL: URL,
         store: any HandoffReclaimTokenStore) {
        self.base = base
        self.stateURL = stateURL
        self.store = store
    }

    var observation: Observation? { lock.withLock { observed } }

    func send(_ request: HandoffHTTPRequest) async throws -> HandoffHTTPResponse {
        try await base.send(request)
    }

    func download(_ request: HandoffHTTPRequest) async throws -> HandoffHTTPDownload {
        if request.url.path.hasSuffix("/reclaim") {
            let state = Self.readState(stateURL)
            let tokenStillStored = (try? await store.load()) != nil
            lock.withLock {
                observed = Observation(state: state,
                                       tokenStillStored: tokenStillStored)
            }
        }
        return try await base.download(request)
    }

    private static func readState(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any] else {
            return nil
        }
        return object["state"] as? String
    }
}

/// Reads `host-state.json` when the vault token is removed. That is after the
/// reclaimed fence was installed but before the host can write its completion
/// edges, so a cold reclaim must already have persisted a bootable state.
final class ReclaimRemovalStateProbeStore: HandoffReclaimTokenStore,
                                          @unchecked Sendable {
    private let base = InMemoryHandoffReclaimTokenStore()
    let stateURL: URL
    private let lock = NSLock()
    private var observed: String?

    init(stateURL: URL) {
        self.stateURL = stateURL
    }

    var stateAtRemoval: String? { lock.withLock { observed } }

    func store(_ token: HandoffReclaimToken) async throws {
        try await base.store(token)
    }

    func load() async throws -> HandoffReclaimToken? {
        try await base.load()
    }

    func remove() async throws {
        let state = Self.readState(stateURL)
        lock.withLock { observed = state }
        try await base.remove()
    }

    private static func readState(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any] else {
            return nil
        }
        return object["state"] as? String
    }
}

/// Deliberately omits ``WebEngineShutdownRequesting`` to prove a facade cannot
/// silently skip terminal Worker teardown behind an App wrapper.
final class EngineWithoutShutdown: WebEngineControlling, @unchecked Sendable {
    private let base: MockEngine

    init(base: MockEngine) { self.base = base }

    var isLockdownModeEnabled: Bool { base.isLockdownModeEnabled }
    var isAttachedWithVisibleArea: Bool { base.isAttachedWithVisibleArea }

    func load(_ url: URL) async throws {
        try await base.load(url)
    }

    func bootWorker(_ configuration: WebEngineConfiguration) async throws {
        try await base.bootWorker(configuration)
    }

    func restart() async throws {
        try await base.restart()
    }
}

/// A vault that is unavailable for writes but has no saved entry. The facade
/// must keep the token in process memory and still reclaim rather than losing
/// the only return credential.
final class FailingReclaimTokenStore: HandoffReclaimTokenStore, @unchecked Sendable {
    func store(_ token: HandoffReclaimToken) async throws {
        throw HandoffError.reclaimTokenStoreFailed("vault offline")
    }

    func load() async throws -> HandoffReclaimToken? { nil }

    func remove() async throws {}
}

/// Loses the fence-CAS response without retaining the token: this is a real
/// process that has no way to learn the secret, not a test side channel.
final class CASResponseLostTransport: HandoffHTTPTransport, @unchecked Sendable {
    let base: any HandoffHTTPTransport

    init(base: any HandoffHTTPTransport) {
        self.base = base
    }

    func send(_ request: HandoffHTTPRequest) async throws -> HandoffHTTPResponse {
        let response = try await base.send(request)
        if request.url.path.hasSuffix("/fence"),
           (200..<300).contains(response.status) {
            throw HandoffError.transport("the CAS response was lost with the token")
        }
        return response
    }

    func download(_ request: HandoffHTTPRequest) async throws -> HandoffHTTPDownload {
        try await base.download(request)
    }
}

/// A write-failing vault that still returns a stale credential from a previous
/// CAS. This is the Keychain behaviour after a failed replacement: the old item
/// is deliberately not deleted. The in-memory token minted by the current CAS
/// must win, or the only return credential is lost.
final class StaleCredentialFailingReclaimTokenStore: HandoffReclaimTokenStore,
                                                    @unchecked Sendable {
    private let lock = NSLock()
    private var stored: HandoffReclaimToken?

    init(_ initial: HandoffReclaimToken?) {
        self.stored = initial
    }

    func store(_ token: HandoffReclaimToken) async throws {
        throw HandoffError.reclaimTokenStoreFailed("vault write failed")
    }

    func load() async throws -> HandoffReclaimToken? {
        lock.withLock { stored }
    }

    func remove() async throws {
        lock.withLock { stored = nil }
    }
}

/// Makes the durable definite-rejection rewrite fail by replacing
/// `handoff-intent.json` with a directory at the moment the fence CAS is sent.
/// The 409 still arrives, so the coordinator must keep the in-process definite
/// outcome and clear the stale path instead of entering an uncertain CAS.
final class MarkerWriteBlockingTransport: HandoffHTTPTransport, @unchecked Sendable {
    let base: any HandoffHTTPTransport
    let intentURL: URL
    private let lock = NSLock()
    private var blocked = false
    private var setupFailure: String?

    init(base: any HandoffHTTPTransport, intentURL: URL) {
        self.base = base
        self.intentURL = intentURL
    }

    var didBlockMarkerWrite: Bool { lock.withLock { blocked } }
    var setupError: String? { lock.withLock { setupFailure } }

    func send(_ request: HandoffHTTPRequest) async throws -> HandoffHTTPResponse {
        if request.url.path.hasSuffix("/fence") {
            let manager = FileManager.default
            do {
                if manager.fileExists(atPath: intentURL.path) {
                    try manager.removeItem(at: intentURL)
                }
                try manager.createDirectory(at: intentURL,
                                            withIntermediateDirectories: false)
                lock.withLock { blocked = true }
            } catch {
                lock.withLock { setupFailure = String(describing: error) }
            }
        }
        return try await base.send(request)
    }

    func download(_ request: HandoffHTTPRequest) async throws -> HandoffHTTPDownload {
        try await base.download(request)
    }
}

/// A custom engine with the old shutdown-only surface. It cannot destroy the
/// page/Worker, so the host must refuse a handoff instead of treating
/// `engine = nil` as a stop.
final class ShutdownOnlyEngine: WebEngineControlling, WebEngineShutdownRequesting,
    @unchecked Sendable {
    let base: MockEngine

    init(base: MockEngine) {
        self.base = base
    }

    var isLockdownModeEnabled: Bool { base.isLockdownModeEnabled }
    var isAttachedWithVisibleArea: Bool { base.isAttachedWithVisibleArea }

    func load(_ url: URL) async throws {
        try await base.load(url)
    }

    func bootWorker(_ configuration: WebEngineConfiguration) async throws {
        try await base.bootWorker(configuration)
    }

    func restart() async throws {
        try await base.restart()
    }

    func shutdownWorker() async throws {
        try await base.shutdownWorker()
    }
}

/// A custom engine with the termination hook but no bridge shutdown hook. The
/// host requires both hooks, so this must be refused before either runs.
final class TerminateOnlyEngine: WebEngineControlling, WebEngineWorkerTerminating,
    @unchecked Sendable {
    let base: MockEngine

    init(base: MockEngine) {
        self.base = base
    }

    var isLockdownModeEnabled: Bool { base.isLockdownModeEnabled }
    var isAttachedWithVisibleArea: Bool { base.isAttachedWithVisibleArea }

    func load(_ url: URL) async throws {
        try await base.load(url)
    }

    func bootWorker(_ configuration: WebEngineConfiguration) async throws {
        try await base.bootWorker(configuration)
    }

    func restart() async throws {
        try await base.restart()
    }

    func terminateWorker() async throws {
        try await base.terminateWorker()
    }
}

enum StopRefusedError: Error, Equatable {
    case pageStillLive
}

/// A stop hook that blocks until the caller is cancelled. `terminateWorker()`
/// does not complete successfully while the caller is cancelling, so the host
/// must fail closed instead of proceeding to the CAS.
actor WorkerStopCancellationGate {
    private var entered = false
    private var cancelled = false
    private var enterWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopWaiters: [CheckedContinuation<Void, Error>] = []

    func enterAndWaitForCancellation() async throws {
        entered = true
        let waiters = enterWaiters
        enterWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        try await withTaskCancellationHandler {
            if cancelled { throw CancellationError() }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if cancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    stopWaiters.append(continuation)
                }
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    func waitForEnter() async {
        if entered { return }
        await withCheckedContinuation { continuation in
            enterWaiters.append(continuation)
        }
    }

    private func cancel() {
        cancelled = true
        let waiters = stopWaiters
        stopWaiters.removeAll()
        for waiter in waiters { waiter.resume(throwing: CancellationError()) }
    }
}

/// Forwards the engine surface but replaces only the termination phase with a
/// cancellation barrier. Its `shutdownWorker()` must never run in the
/// cancelled-stop regression.
final class CancellationGatedStopEngine: WebEngineControlling,
    WebEngineWorkerTerminating, WebEngineShutdownRequesting, @unchecked Sendable {
    let base: MockEngine
    let gate: WorkerStopCancellationGate

    init(base: MockEngine, gate: WorkerStopCancellationGate) {
        self.base = base
        self.gate = gate
    }

    var isLockdownModeEnabled: Bool { base.isLockdownModeEnabled }
    var isAttachedWithVisibleArea: Bool { base.isAttachedWithVisibleArea }

    func load(_ url: URL) async throws {
        try await base.load(url)
    }

    func bootWorker(_ configuration: WebEngineConfiguration) async throws {
        try await base.bootWorker(configuration)
    }

    func restart() async throws {
        try await base.restart()
    }

    func terminateWorker() async throws {
        try await gate.enterAndWaitForCancellation()
    }

    func shutdownWorker() async throws {
        try await base.shutdownWorker()
    }
}

final class PhoneDSHHandoffColdSafetyTests: XCTestCase {
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
                          engine: any WebEngineControlling,
                          transport: any HandoffHTTPTransport,
                          store: any HandoffReclaimTokenStore) throws
        -> PhoneDSHHost {
        PhoneDSHHost(configuration: try makeConfiguration(fixture),
                     engineFactory: { _ in engine },
                     handoffTransport: transport,
                     reclaimTokenStore: store)
    }

    private func makeRemote(_ fixture: FacadeFixture,
                            initialFence: Fence = Fence(owner: HandoffLimits.phoneOwner,
                                                       generation: 0, walSeq: 0)) throws
        -> HandoffServerSimulator {
        try makeSimulator(root: fixture.root.appendingPathComponent("remote",
                                                                   isDirectory: true),
                          initialFence: initialFence)
    }

    @discardableResult
    private func writeLocalFile(_ engine: MockEngine) async throws -> UInt64 {
        let mseq = try await engine.worker.writeFile(
            path: "/dsh/workspace/local.txt", data: Data("local".utf8))
        try await engine.worker.waitForAck(mseq)
        return mseq
    }

    // MARK: - New host cold reclaim

    func testNewHostReclaimsPersistedRemoteThroughSecureStore() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let remote = try makeRemote(fixture)
        let store = InMemoryHandoffReclaimTokenStore()
        let firstEngine = MockEngine(worker: MockWorker())
        let firstHost = try makeHost(fixture, engine: firstEngine,
                                     transport: remote, store: store)

        try await firstHost.start()
        let localMseq = try await writeLocalFile(firstEngine)
        try await waitUntil {
            (try? Data(contentsOf: fixture.materializedFile(
                "workspace/local.txt"))) != nil
        }
        let completion = try await firstHost.beginHandoff()
        XCTAssertEqual(completion.remoteFence.owner, HandoffLimits.remoteOwner)
        XCTAssertEqual(firstEngine.shutdownCount, 1,
                       "handoff must actually shut the engine down")
        // The live coordinator must write the injected vault, not an internal
        // per-client fallback: this is the credential a fresh process loads.
        let storedByLiveHandoff = try await store.load()
        XCTAssertEqual(storedByLiveHandoff?.remoteFence, completion.remoteFence)
        XCTAssertEqual(storedByLiveHandoff?.token.count, 32)
        try await firstHost.stop()

        let loaded = try await store.load()
        let saved = try XCTUnwrap(loaded)
        XCTAssertEqual(saved.remoteFence, completion.remoteFence)
        let remoteMseq = try await remote.appendRemoteMutation(
            HandoffMutations.write("/dsh/workspace/after-cold-start.txt",
                                   "from-remote"))

        // A brand-new host object, as after a process death: no coordinator,
        // no machine and no same-object token.
        let secondEngine = MockEngine(worker: MockWorker())
        let secondHost = try makeHost(fixture, engine: secondEngine,
                                      transport: remote, store: store)
        let outcome = try await secondHost.reclaim()
        XCTAssertEqual(outcome.fence.owner, HandoffLimits.phoneOwner)
        XCTAssertEqual(outcome.fence.generation,
                       completion.remoteFence.generation + 1)
        XCTAssertEqual(outcome.fence.walSeq, remoteMseq)
        XCTAssertEqual(outcome.appliedMseq, remoteMseq)
        XCTAssertGreaterThanOrEqual(outcome.fence.walSeq, localMseq)
        XCTAssertEqual(secondEngine.bootCount, 1,
                       "cold reclaim must boot the reclaimed workspace")
        let remaining = try await store.load()
        XCTAssertNil(remaining, "a consumed token must leave the secure store")

        let diagnostics = await secondHost.diagnostics()
        XCTAssertEqual(diagnostics.state, .running)
        XCTAssertEqual(diagnostics.admission, .open)
        let contents = try String(
            contentsOf: fixture.materializedFile("workspace/after-cold-start.txt"),
            encoding: .utf8)
        XCTAssertEqual(contents, "from-remote")
        let clearedIntent = try FenceAuthority.loadHandoffAuthorityIntent(
            root: fixture.workspace)
        XCTAssertNil(clearedIntent)
        try await secondHost.stop()
    }

    // MARK: - Cold reclaim ordering and interrupted cleanup

    func testColdReclaimPersistsReclaimingBeforeConsumingToken() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let remote = try makeRemote(fixture)
        let store = InMemoryHandoffReclaimTokenStore()
        let firstEngine = MockEngine(worker: MockWorker())
        let firstHost = try makeHost(fixture, engine: firstEngine,
                                     transport: remote, store: store)
        try await firstHost.start()
        _ = try await writeLocalFile(firstEngine)
        try await waitUntil {
            (try? Data(contentsOf: fixture.materializedFile(
                "workspace/local.txt"))) != nil
        }
        _ = try await firstHost.beginHandoff()
        try await firstHost.stop()
        let beforeColdReclaim = try await store.load()
        XCTAssertNotNil(beforeColdReclaim)

        let probe = ReclaimStateProbeTransport(
            base: remote,
            stateURL: fixture.workspace.appendingPathComponent("host-state.json"),
            store: store)
        let secondEngine = MockEngine(worker: MockWorker())
        let secondHost = try makeHost(fixture, engine: secondEngine,
                                      transport: probe, store: store)
        _ = try await secondHost.reclaim()

        let observed = try XCTUnwrap(probe.observation)
        XCTAssertEqual(observed.state, HostState.reclaiming.rawValue,
                       "the cold reclaim must persist Reclaiming before the token is used")
        XCTAssertTrue(observed.tokenStillStored,
                      "the token must be consumed only after Reclaiming is durable")
        XCTAssertEqual(secondEngine.bootCount, 1)
        try await secondHost.stop()
    }

    func testColdReclaimFromPersistedFailedPersistsRecoveryBeforeConsumingToken() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let remote = try makeRemote(fixture)
        let dropping = CASResponseDroppingTransport(base: remote)
        let firstStore = InMemoryHandoffReclaimTokenStore()
        let firstEngine = MockEngine(worker: MockWorker())
        let firstHost = try makeHost(fixture, engine: firstEngine,
                                     transport: dropping, store: firstStore)
        try await firstHost.start()
        _ = try await writeLocalFile(firstEngine)
        try await waitUntil {
            (try? Data(contentsOf: fixture.materializedFile(
                "workspace/local.txt"))) != nil
        }
        do {
            _ = try await firstHost.beginHandoff()
            XCTFail("the dropped CAS response must fail the handoff")
        } catch {
            XCTAssertEqual(error as? HandoffError,
                           .transport("the CAS response was lost"))
        }
        let token = try XCTUnwrap(dropping.capturedReclaimToken)
        try await firstHost.stop()

        // The persisted controller is `HandingOff`; the next boot maps that to
        // `Failed`. The App saved the token the remote minted before the
        // response was lost. The cold reclaim must persist a bootable state
        // before it consumes that token.
        let stateURL = fixture.workspace.appendingPathComponent("host-state.json")
        let removalStore = ReclaimRemovalStateProbeStore(stateURL: stateURL)
        let remoteFence = await remote.currentFence()
        XCTAssertEqual(remoteFence.owner, HandoffLimits.remoteOwner)
        let credential = HandoffReclaimToken(
            token: token,
            remoteFence: remoteFence,
            endpoint: "https://remote.invalid",
            workspaceIdentifier: HandoffReclaimToken.workspaceIdentifier(
                for: fixture.workspace))
        try await removalStore.store(credential)

        let probe = ReclaimStateProbeTransport(base: remote,
                                               stateURL: stateURL,
                                               store: removalStore)
        let secondEngine = MockEngine(worker: MockWorker())
        let secondHost = try makeHost(fixture, engine: secondEngine,
                                      transport: probe, store: removalStore)
        let outcome = try await secondHost.reclaim()
        XCTAssertEqual(outcome.fence.owner, HandoffLimits.phoneOwner)
        XCTAssertEqual(outcome.fence.generation, remoteFence.generation + 1)

        // At the reclaim download and again when the vault entry is removed
        // (after installReclaimedFence), the persisted state must already be
        // Recovering. A crash in that window therefore resumes rather than
        // leaving a persisted Failed controller with no token.
        let atDownload = try XCTUnwrap(probe.observation)
        XCTAssertEqual(atDownload.state, HostState.recovering.rawValue,
                       "Failed must become a bootable recovery state before the CAS proof")
        XCTAssertTrue(atDownload.tokenStillStored,
                      "the token must survive until the recovery edge is durable")
        let atRemoval = try XCTUnwrap(removalStore.stateAtRemoval)
        XCTAssertEqual(atRemoval, HostState.recovering.rawValue,
                       "the reclaimed fence must not be consumed over persisted Failed")
        XCTAssertEqual(secondEngine.bootCount, 1)
        let state = await secondHost.state
        XCTAssertEqual(state, .running)
        let remaining = try await removalStore.load()
        XCTAssertNil(remaining)
        try await secondHost.stop()
    }

    func testInterruptedIntentCleanupAfterReclaimedFenceRetries() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let remote = try makeRemote(fixture)
        let store = InMemoryHandoffReclaimTokenStore()
        let firstEngine = MockEngine(worker: MockWorker())
        let firstHost = try makeHost(fixture, engine: firstEngine,
                                     transport: remote, store: store)
        try await firstHost.start()
        _ = try await writeLocalFile(firstEngine)
        try await waitUntil {
            (try? Data(contentsOf: fixture.materializedFile(
                "workspace/local.txt"))) != nil
        }
        let completion = try await firstHost.beginHandoff()
        try await firstHost.stop()
        let loadedSaved = try await store.load()
        let saved = try XCTUnwrap(loadedSaved)
        let remoteFence = try XCTUnwrap(saved.remoteFence)

        // Reconstruct the crash window: the reclaimed phone fence is already
        // installed (segments applied), but the stale pre-CAS intent was left
        // behind and the vault token was not removed.
        let authority = try FenceAuthority(root: fixture.workspace,
                                           owner: HandoffLimits.phoneOwner,
                                           walSeq: 0)
        let reclaimed = Fence(owner: HandoffLimits.phoneOwner,
                              generation: remoteFence.generation + 1,
                              walSeq: remoteFence.walSeq)
        try await authority.installReclaimedFence(reclaimed)
        try await authority.markHandoffAuthorityUncertain(
            expectedGeneration: completion.remoteFence.generation - 1,
            walSeq: completion.remoteFence.walSeq,
            endpoint: "https://remote.invalid")
        XCTAssertNotNil(try FenceAuthority.loadHandoffAuthorityIntent(
            root: fixture.workspace))

        // Retrying with the saved token must recognise the already installed
        // generation, clear the stale intent and boot instead of returning
        // manualReclaimRequired forever.
        let secondEngine = MockEngine(worker: MockWorker())
        let secondHost = try makeHost(fixture, engine: secondEngine,
                                      transport: remote, store: store)
        let outcome = try await secondHost.reclaim()
        XCTAssertEqual(outcome.fence, reclaimed)
        XCTAssertEqual(secondEngine.bootCount, 1)
        XCTAssertNil(try FenceAuthority.loadHandoffAuthorityIntent(
            root: fixture.workspace))
        let remaining = try await store.load()
        XCTAssertNil(remaining)
        let state = await secondHost.state
        XCTAssertEqual(state, .running)
        try await secondHost.stop()
    }

    func testExplicitCredentialRecoversInterruptedIntentCleanup() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let remote = try makeRemote(fixture)
        let store = InMemoryHandoffReclaimTokenStore()
        let firstEngine = MockEngine(worker: MockWorker())
        let firstHost = try makeHost(fixture, engine: firstEngine,
                                     transport: remote, store: store)
        try await firstHost.start()
        _ = try await writeLocalFile(firstEngine)
        try await waitUntil {
            (try? Data(contentsOf: fixture.materializedFile(
                "workspace/local.txt"))) != nil
        }
        let completion = try await firstHost.beginHandoff()
        try await firstHost.stop()
        let loadedSaved = try await store.load()
        let saved = try XCTUnwrap(loadedSaved)
        let remoteFence = try XCTUnwrap(saved.remoteFence)

        // The reclaimed phone fence is already installed, but the stale intent
        // and the App vault entry were left behind. The explicit entry must
        // derive the *remote predecessor* (current.generation - 1) from the
        // intent and let the cached 200 prove the already-reclaimed branch.
        let authority = try FenceAuthority(root: fixture.workspace,
                                           owner: HandoffLimits.phoneOwner,
                                           walSeq: 0)
        let reclaimed = Fence(owner: HandoffLimits.phoneOwner,
                              generation: remoteFence.generation + 1,
                              walSeq: remoteFence.walSeq)
        try await authority.installReclaimedFence(reclaimed)
        try await authority.markHandoffAuthorityUncertain(
            expectedGeneration: completion.remoteFence.generation - 1,
            walSeq: completion.remoteFence.walSeq,
            endpoint: "https://remote.invalid")
        // The App has only its own token copy; no vault token is available.
        try await store.remove()

        let credential = HandoffReclaimToken(
            token: saved.token,
            remoteFence: remoteFence,
            endpoint: "https://remote.invalid",
            workspaceIdentifier: HandoffReclaimToken.workspaceIdentifier(
                for: fixture.workspace))
        let secondEngine = MockEngine(worker: MockWorker())
        let secondHost = try makeHost(fixture, engine: secondEngine,
                                      transport: remote, store: store)
        let outcome = try await secondHost.reclaim(using: credential)
        XCTAssertEqual(outcome.fence, reclaimed)
        XCTAssertEqual(secondEngine.bootCount, 1,
                       "the explicit entry must resume the interrupted cleanup")
        XCTAssertNil(try FenceAuthority.loadHandoffAuthorityIntent(
            root: fixture.workspace))
        let remaining = try await store.load()
        XCTAssertNil(remaining)
        let state = await secondHost.state
        XCTAssertEqual(state, .running)
        try await secondHost.stop()
    }

    func testColdReclaimAfterRemoteWalSeqAdvanceRecognisesInstalledFence() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let remote = try makeRemote(fixture)
        let store = InMemoryHandoffReclaimTokenStore()
        let firstEngine = MockEngine(worker: MockWorker())
        let firstHost = try makeHost(fixture, engine: firstEngine,
                                     transport: remote, store: store)
        try await firstHost.start()
        _ = try await writeLocalFile(firstEngine)
        try await waitUntil {
            (try? Data(contentsOf: fixture.materializedFile(
                "workspace/local.txt"))) != nil
        }
        let completion = try await firstHost.beginHandoff()
        try await firstHost.stop()
        let loadedSaved = try await store.load()
        let saved = try XCTUnwrap(loadedSaved)
        let remoteFence = try XCTUnwrap(saved.remoteFence)

        // The remote appends after the CAS and before the reclaim. Its cached
        // reclaim response therefore carries a larger wal_seq than the remote
        // fence stored with the token.
        let remoteMseq = try await remote.appendRemoteMutation(
            HandoffMutations.write("/dsh/workspace/remote-before-reclaim.txt",
                                   "remote"))
        XCTAssertGreaterThan(remoteMseq, remoteFence.walSeq)

        // Reconstruct the crash after the reclaimed fence was written but
        // before the stale intent/token cleanup. The installed phone wal_seq is
        // legitimately ahead of the stored CAS fence.
        let authority = try FenceAuthority(root: fixture.workspace,
                                           owner: HandoffLimits.phoneOwner,
                                           walSeq: 0)
        let reclaimed = Fence(owner: HandoffLimits.phoneOwner,
                              generation: remoteFence.generation + 1,
                              walSeq: remoteMseq)
        // Reach the real durable boundary before synthesizing the crash in
        // intent cleanup: remote segments must be applied before the fence.
        let client = try HandoffClient(
            configuration: XCTUnwrap(makeConfiguration(fixture).handoff),
            transport: remote, credentialProvider: HandoffTestCredentials.provider())
        let download = try await client.reclaim(token: saved.token)
        defer { try? FileManager.default.removeItem(at: download.payloadURL) }
        let applier = try WorkspaceLogSegmentApplier(
            root: fixture.workspace,
            configuration: WorkspaceLogConfiguration(root: fixture.workspace),
            bootID: Data(repeating: 0x88, count: 16))
        let applied = try await applier.apply(download)
        XCTAssertEqual(applied.appliedMseq, remoteMseq)
        XCTAssertTrue(applied.epochClosed)
        XCTAssertTrue(FileManager.default.fileExists(atPath:
            fixture.materializedFile("workspace/remote-before-reclaim.txt").path))
        try await authority.installReclaimedFence(reclaimed)
        try await authority.markHandoffAuthorityUncertain(
            expectedGeneration: completion.remoteFence.generation - 1,
            walSeq: completion.remoteFence.walSeq,
            endpoint: "https://remote.invalid")
        XCTAssertNotNil(try FenceAuthority.loadHandoffAuthorityIntent(
            root: fixture.workspace))

        // The generation branch (already installed) must allow the remote to
        // have advanced, then let ReclaimClient validate the cached metadata.
        let secondEngine = MockEngine(worker: MockWorker())
        let secondHost = try makeHost(fixture, engine: secondEngine,
                                      transport: remote, store: store)
        let outcome = try await secondHost.reclaim()
        XCTAssertEqual(outcome.fence, reclaimed)
        XCTAssertEqual(outcome.appliedMseq, remoteMseq)
        XCTAssertTrue(outcome.epochClosed)
        XCTAssertEqual(secondEngine.bootCount, 1)
        XCTAssertNil(try FenceAuthority.loadHandoffAuthorityIntent(
            root: fixture.workspace))
        let remaining = try await store.load()
        XCTAssertNil(remaining)
        let state = await secondHost.state
        XCTAssertEqual(state, .running)
        try await secondHost.stop()
    }

    func testPersistedRemoteControllerWithCompletedReclaimedFenceStarts() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let remote = try makeRemote(fixture)
        let store = InMemoryHandoffReclaimTokenStore()
        let firstEngine = MockEngine(worker: MockWorker())
        let firstHost = try makeHost(fixture, engine: firstEngine,
                                     transport: remote, store: store)
        try await firstHost.start()
        _ = try await writeLocalFile(firstEngine)
        try await waitUntil {
            (try? Data(contentsOf: fixture.materializedFile(
                "workspace/local.txt"))) != nil
        }
        let completion = try await firstHost.beginHandoff()
        try await firstHost.stop()

        // The earlier ordering could install the phone fence and delete the
        // token while host-state.json still said Remote. The persisted phone
        // fence plus no intent is proof the reclaim completed; a new host must
        // enter Recovering instead of refusing the workspace forever.
        let authority = try FenceAuthority(root: fixture.workspace,
                                           owner: HandoffLimits.phoneOwner,
                                           walSeq: 0)
        let reclaimed = Fence(owner: HandoffLimits.phoneOwner,
                              generation: completion.remoteFence.generation + 1,
                              walSeq: completion.remoteFence.walSeq)
        try await authority.installReclaimedFence(reclaimed)
        try await store.remove()
        XCTAssertNil(try FenceAuthority.loadHandoffAuthorityIntent(
            root: fixture.workspace))

        let secondEngine = MockEngine(worker: MockWorker())
        let secondHost = try makeHost(fixture, engine: secondEngine,
                                      transport: remote, store: store)
        try await secondHost.start()
        XCTAssertEqual(secondEngine.bootCount, 1)
        let diagnostics = await secondHost.diagnostics()
        XCTAssertEqual(diagnostics.state, .running)
        XCTAssertEqual(diagnostics.fence?.wireFence, reclaimed)
        try await secondHost.stop()
    }

    // MARK: - Lost CAS response and explicit token recovery

    func testLostCASResponseBlocksNewHostAndExplicitTokenRecovers() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let remote = try makeRemote(fixture)
        let dropping = CASResponseDroppingTransport(base: remote)
        let store = InMemoryHandoffReclaimTokenStore()
        let firstEngine = MockEngine(worker: MockWorker())
        let firstHost = try makeHost(fixture, engine: firstEngine,
                                     transport: dropping, store: store)

        try await firstHost.start()
        _ = try await writeLocalFile(firstEngine)
        try await waitUntil {
            (try? Data(contentsOf: fixture.materializedFile(
                "workspace/local.txt"))) != nil
        }
        do {
            _ = try await firstHost.beginHandoff()
            XCTFail("the dropped CAS response must fail the handoff")
        } catch {
            XCTAssertEqual(error as? HandoffError,
                           .transport("the CAS response was lost"))
        }
        let token = try XCTUnwrap(dropping.capturedReclaimToken)
        let remoteFence = await remote.currentFence()
        XCTAssertEqual(remoteFence.owner, HandoffLimits.remoteOwner)

        // The old host is torn down. A new process must not boot over the old
        // phone fence even though the local CAS response was lost.
        try await firstHost.stop()
        let secondEngine = MockEngine(worker: MockWorker())
        let secondHost = try makeHost(fixture, engine: secondEngine,
                                      transport: remote, store: store)
        do {
            try await secondHost.start()
            XCTFail("an unresolved CAS must refuse a local start")
        } catch {
            guard case PhoneDSHError.invalidState = error else {
                return XCTFail("expected invalidState, got \(error)")
            }
        }
        XCTAssertEqual(secondEngine.bootCount, 0)
        let intentBefore = try FenceAuthority.loadHandoffAuthorityIntent(
            root: fixture.workspace)
        XCTAssertNotNil(intentBefore)

        // Without a token there is no verifiable recovery action: fail closed
        // and keep the evidence instead of guessing a generation.
        do {
            _ = try await secondHost.reclaim()
            XCTFail("reclaim without a token must stay blocked")
        } catch {
            guard case HandoffError.manualReclaimRequired = error else {
                return XCTFail("expected manualReclaimRequired, got \(error)")
            }
        }
        XCTAssertEqual(secondEngine.bootCount, 0)
        let intentAfter = try FenceAuthority.loadHandoffAuthorityIntent(
            root: fixture.workspace)
        XCTAssertNotNil(intentAfter)

        // The complete App-held credential is the cold recovery entry: the
        // remote's 200 proves the CAS before the local remote fence is
        // recorded, and the workspace/endpoint/fence binding is checked first.
        let credential = HandoffReclaimToken(
            token: token,
            remoteFence: remoteFence,
            endpoint: "https://remote.invalid",
            workspaceIdentifier: HandoffReclaimToken.workspaceIdentifier(
                for: fixture.workspace))
        let outcome = try await secondHost.reclaim(using: credential)
        XCTAssertEqual(outcome.fence.owner, HandoffLimits.phoneOwner)
        XCTAssertEqual(outcome.fence.generation, 2)
        XCTAssertEqual(secondEngine.bootCount, 1)
        let diagnostics = await secondHost.diagnostics()
        XCTAssertEqual(diagnostics.state, .running)
        XCTAssertEqual(diagnostics.admission, .open)
        let clearedIntent = try FenceAuthority.loadHandoffAuthorityIntent(
            root: fixture.workspace)
        XCTAssertNil(clearedIntent)
        try await secondHost.stop()
    }

    func testCompletelyLostCASResponseWithoutTokenStaysManualBlocked() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let remote = try makeRemote(fixture)
        let lost = CASResponseLostTransport(base: remote)
        let store = InMemoryHandoffReclaimTokenStore()
        let firstEngine = MockEngine(worker: MockWorker())
        let firstHost = try makeHost(fixture, engine: firstEngine,
                                     transport: lost, store: store)

        try await firstHost.start()
        _ = try await writeLocalFile(firstEngine)
        do {
            _ = try await firstHost.beginHandoff()
            XCTFail("a lost CAS response must fail the handoff")
        } catch {
            XCTAssertEqual(error as? HandoffError,
                           .transport("the CAS response was lost with the token"))
        }
        let noToken = try await store.load()
        XCTAssertNil(noToken,
                     "a fully lost response cannot plant a token in the App vault")
        let remoteFence = await remote.currentFence()
        XCTAssertEqual(remoteFence.owner, HandoffLimits.remoteOwner)
        try await firstHost.stop()

        let secondEngine = MockEngine(worker: MockWorker())
        let secondHost = try makeHost(fixture, engine: secondEngine,
                                      transport: remote, store: store)
        do {
            try await secondHost.start()
            XCTFail("an unresolved CAS must refuse a local start")
        } catch {
            guard case PhoneDSHError.invalidState = error else {
                return XCTFail("expected invalidState, got \(error)")
            }
        }
        do {
            _ = try await secondHost.reclaim()
            XCTFail("without a token the host must stay in manual recovery")
        } catch {
            guard case HandoffError.manualReclaimRequired = error else {
                return XCTFail("expected manualReclaimRequired, got \(error)")
            }
        }
        XCTAssertEqual(secondEngine.bootCount, 0)
        let intent = try FenceAuthority.loadHandoffAuthorityIntent(
            root: fixture.workspace)
        let unresolved = try XCTUnwrap(intent)
        XCTAssertFalse(unresolved.isDefiniteRejection,
                       "the remote may own generation + 1; the evidence must remain")
        let counters = await remote.endpointCounters()
        XCTAssertEqual(counters.reclaimRequests, 0,
                       "manual BLOCKED must not invent an automatic reclaim call")
        try await secondHost.stop()
    }

    func testExplicitCredentialForAnotherWorkspaceOrEndpointIsRefusedBeforeTransport() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let remote = try makeRemote(fixture)
        let dropping = CASResponseDroppingTransport(base: remote)
        let store = InMemoryHandoffReclaimTokenStore()
        let firstEngine = MockEngine(worker: MockWorker())
        let firstHost = try makeHost(fixture, engine: firstEngine,
                                     transport: dropping, store: store)
        try await firstHost.start()
        _ = try await writeLocalFile(firstEngine)
        try await waitUntil {
            (try? Data(contentsOf: fixture.materializedFile(
                "workspace/local.txt"))) != nil
        }
        do {
            _ = try await firstHost.beginHandoff()
            XCTFail("the dropped CAS response must fail the handoff")
        } catch {
            XCTAssertEqual(error as? HandoffError,
                           .transport("the CAS response was lost"))
        }
        let token = try XCTUnwrap(dropping.capturedReclaimToken)
        let remoteFence = await remote.currentFence()
        try await firstHost.stop()
        let before = await remote.endpointCounters()
        let workspaceIdentifier = HandoffReclaimToken.workspaceIdentifier(
            for: fixture.workspace)

        // A token from another workspace on the same endpoint must be refused
        // before any request or segment apply, and must leave the unresolved
        // intent in place for a manual/complete-credential recovery.
        let foreignWorkspace = HandoffReclaimToken(
            token: token,
            remoteFence: remoteFence,
            endpoint: "https://remote.invalid",
            workspaceIdentifier: HandoffReclaimToken.workspaceIdentifier(
                for: fixture.root.appendingPathComponent("another-workspace")))
        let workspaceEngine = MockEngine(worker: MockWorker())
        let workspaceHost = try makeHost(fixture, engine: workspaceEngine,
                                         transport: remote, store: store)
        do {
            _ = try await workspaceHost.reclaim(using: foreignWorkspace)
            XCTFail("a credential bound to another workspace must be refused")
        } catch {
            guard case HandoffError.manualReclaimRequired = error else {
                return XCTFail("expected manualReclaimRequired, got \(error)")
            }
        }
        XCTAssertEqual(workspaceEngine.bootCount, 0)
        let afterWorkspace = await remote.endpointCounters()
        XCTAssertEqual(afterWorkspace.reclaimRequests, before.reclaimRequests,
                       "a foreign workspace credential must never reach the remote")
        XCTAssertNotNil(try FenceAuthority.loadHandoffAuthorityIntent(
            root: fixture.workspace))

        // The same token with a foreign endpoint is refused as well.
        let foreignEndpoint = HandoffReclaimToken(
            token: token,
            remoteFence: remoteFence,
            endpoint: "https://other.invalid",
            workspaceIdentifier: workspaceIdentifier)
        let endpointEngine = MockEngine(worker: MockWorker())
        let endpointHost = try makeHost(fixture, engine: endpointEngine,
                                        transport: remote, store: store)
        do {
            _ = try await endpointHost.reclaim(using: foreignEndpoint)
            XCTFail("a credential bound to another endpoint must be refused")
        } catch {
            guard case HandoffError.manualReclaimRequired = error else {
                return XCTFail("expected manualReclaimRequired, got \(error)")
            }
        }
        XCTAssertEqual(endpointEngine.bootCount, 0)
        let afterEndpoint = await remote.endpointCounters()
        XCTAssertEqual(afterEndpoint.reclaimRequests, before.reclaimRequests,
                       "a foreign endpoint credential must never reach the remote")
        XCTAssertNotNil(try FenceAuthority.loadHandoffAuthorityIntent(
            root: fixture.workspace))

        // Finally the complete, correctly bound credential recovers.
        let credential = HandoffReclaimToken(
            token: token,
            remoteFence: remoteFence,
            endpoint: "https://remote.invalid",
            workspaceIdentifier: workspaceIdentifier)
        let recoveredEngine = MockEngine(worker: MockWorker())
        let recoveredHost = try makeHost(fixture, engine: recoveredEngine,
                                         transport: remote, store: store)
        _ = try await recoveredHost.reclaim(using: credential)
        XCTAssertEqual(recoveredEngine.bootCount, 1)
        XCTAssertNil(try FenceAuthority.loadHandoffAuthorityIntent(
            root: fixture.workspace))
        try await recoveredHost.stop()
    }

    // MARK: - Engine shutdown happens before the CAS

    func testHandoffShutsDownEngineBeforeFenceCAS() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let remote = try makeRemote(fixture)
        let engine = MockEngine(worker: MockWorker())
        let ordered = FenceShutdownOrderTransport(base: remote, engine: engine)
        let host = try makeHost(fixture, engine: engine, transport: ordered,
                                store: InMemoryHandoffReclaimTokenStore())

        try await host.start()
        _ = try await writeLocalFile(engine)
        try await waitUntil {
            (try? Data(contentsOf: fixture.materializedFile(
                "workspace/local.txt"))) != nil
        }
        _ = try await host.beginHandoff()
        XCTAssertEqual(ordered.terminateCountAtFence, 1,
                       "the page/Worker termination must precede the CAS request")
        XCTAssertEqual(ordered.shutdownCountAtFence, 1,
                       "the bridge shutdown must follow a successful termination")
        XCTAssertEqual(engine.terminateCount, 1)
        XCTAssertEqual(engine.shutdownCount, 1)
        try await host.stop()
    }

    // MARK: - Refused Worker stop

    func testRefusedWorkerStopSendsNoFenceCAS() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let remote = try makeRemote(fixture)
        let engine = MockEngine(worker: MockWorker())
        engine.setStopError(StopRefusedError.pageStillLive)
        let host = try makeHost(fixture, engine: engine, transport: remote,
                                store: InMemoryHandoffReclaimTokenStore())

        try await host.start()
        _ = try await writeLocalFile(engine)
        do {
            _ = try await host.beginHandoff()
            XCTFail("a page that did not terminate must refuse the handoff")
        } catch {
            XCTAssertEqual(error as? StopRefusedError, .pageStillLive)
        }
        XCTAssertEqual(engine.terminateCount, 1)
        XCTAssertEqual(engine.shutdownCount, 0,
                       "a failed termination must not be followed by shutdown")
        let counters = await remote.endpointCounters()
        XCTAssertEqual(counters.fenceRequests, 0,
                       "no CAS may be sent after a failed Worker stop")
        XCTAssertEqual(counters.snapshotUploads, 0)
        XCTAssertEqual(counters.segmentsUploads, 0)
        let intent = try FenceAuthority.loadHandoffAuthorityIntent(
            root: fixture.workspace)
        XCTAssertNil(intent)
        let state = await host.state
        XCTAssertEqual(state, .failed)
        try await host.stop()
    }

    func testCustomEngineWithTerminateOnlyHookRefusesHandoff() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let remote = try makeRemote(fixture)
        let base = MockEngine(worker: MockWorker())
        let engine = TerminateOnlyEngine(base: base)
        let host = try makeHost(fixture, engine: engine, transport: remote,
                                store: InMemoryHandoffReclaimTokenStore())

        try await host.start()
        _ = try await writeLocalFile(base)
        do {
            _ = try await host.beginHandoff()
            XCTFail("a terminate-only engine must not be treated as stopped")
        } catch {
            guard case HandoffError.invalidControllerState(let detail) = error else {
                return XCTFail("expected invalidControllerState, got \(error)")
            }
            XCTAssertTrue(detail.contains("shutdown hook"))
        }
        XCTAssertEqual(base.terminateCount, 0,
                       "both hooks must be verified before either runs")
        XCTAssertEqual(base.shutdownCount, 0)
        let counters = await remote.endpointCounters()
        XCTAssertEqual(counters.fenceRequests, 0)
        XCTAssertEqual(counters.snapshotUploads, 0)
        XCTAssertEqual(counters.segmentsUploads, 0)
        let intent = try FenceAuthority.loadHandoffAuthorityIntent(
            root: fixture.workspace)
        XCTAssertNil(intent)
        let state = await host.state
        XCTAssertEqual(state, .failed)
        try await host.stop()
    }

    func testShutdownHookFailureSendsNoFenceCAS() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let remote = try makeRemote(fixture)
        let engine = MockEngine(worker: MockWorker())
        engine.setShutdownError(StopRefusedError.pageStillLive)
        let host = try makeHost(fixture, engine: engine, transport: remote,
                                store: InMemoryHandoffReclaimTokenStore())

        try await host.start()
        _ = try await writeLocalFile(engine)
        do {
            _ = try await host.beginHandoff()
            XCTFail("a failed bridge shutdown must refuse the handoff")
        } catch {
            XCTAssertEqual(error as? StopRefusedError, .pageStillLive)
        }
        XCTAssertEqual(engine.terminateCount, 1)
        XCTAssertEqual(engine.shutdownCount, 1,
                       "the shutdown hook is required and its failure is propagated")
        let counters = await remote.endpointCounters()
        XCTAssertEqual(counters.fenceRequests, 0,
                       "no CAS may be sent after a failed shutdown")
        XCTAssertEqual(counters.snapshotUploads, 0)
        XCTAssertEqual(counters.segmentsUploads, 0)
        let intent = try FenceAuthority.loadHandoffAuthorityIntent(
            root: fixture.workspace)
        XCTAssertNil(intent)
        let state = await host.state
        XCTAssertEqual(state, .failed)
        let diagnostics = await host.diagnostics()
        XCTAssertEqual(diagnostics.admission, .closed)
        try await host.stop()
    }

    func testCallerCancellationDuringWorkerStopSendsNoCAS() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let remote = try makeRemote(fixture)
        let gate = WorkerStopCancellationGate()
        let base = MockEngine(worker: MockWorker())
        let engine = CancellationGatedStopEngine(base: base, gate: gate)
        let host = try makeHost(fixture, engine: engine, transport: remote,
                                store: InMemoryHandoffReclaimTokenStore())

        try await host.start()
        _ = try await writeLocalFile(base)
        try await waitUntil {
            (try? Data(contentsOf: fixture.materializedFile(
                "workspace/local.txt"))) != nil
        }

        let handoff = Task { try await host.beginHandoff() }
        await gate.waitForEnter()
        handoff.cancel()
        do {
            _ = try await handoff.value
            XCTFail("a cancelled caller must not complete the handoff")
        } catch {
            XCTAssertTrue(error is CancellationError,
                          "expected cancellation, got \(error)")
        }

        let counters = await remote.endpointCounters()
        XCTAssertEqual(counters.fenceRequests, 0,
                       "cancellation during the Worker stop must not send the CAS")
        XCTAssertEqual(counters.snapshotUploads, 0)
        XCTAssertEqual(counters.segmentsUploads, 0)
        XCTAssertEqual(base.shutdownCount, 0,
                       "the bridge shutdown must not run after a cancelled stop")
        let intent = try FenceAuthority.loadHandoffAuthorityIntent(
            root: fixture.workspace)
        XCTAssertNil(intent)
        let state = await host.state
        XCTAssertEqual(state, .failed)
        let diagnostics = await host.diagnostics()
        XCTAssertEqual(diagnostics.admission, .closed,
                       "a cancelled stop must not reopen local admission")
        try await host.stop()
    }

    func testCustomEngineWithoutTerminationHookRefusesHandoff() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let remote = try makeRemote(fixture)
        let base = MockEngine(worker: MockWorker())
        let engine = ShutdownOnlyEngine(base: base)
        let host = try makeHost(fixture, engine: engine, transport: remote,
                                store: InMemoryHandoffReclaimTokenStore())

        try await host.start()
        _ = try await writeLocalFile(base)
        do {
            _ = try await host.beginHandoff()
            XCTFail("a shutdown-only engine must not be treated as a stop")
        } catch {
            guard case HandoffError.invalidControllerState(let detail) = error else {
                return XCTFail("expected invalidControllerState, got \(error)")
            }
            XCTAssertTrue(detail.contains("termination hook"))
        }
        XCTAssertEqual(base.terminateCount, 0)
        XCTAssertEqual(base.shutdownCount, 0,
                       "without a termination hook neither phase may run")
        let counters = await remote.endpointCounters()
        XCTAssertEqual(counters.fenceRequests, 0)
        let intent = try FenceAuthority.loadHandoffAuthorityIntent(
            root: fixture.workspace)
        XCTAssertNil(intent)
        let state = await host.state
        XCTAssertEqual(state, .failed)
        try await host.stop()
    }

    func testEngineWithoutShutdownHookFailsClosedBeforeCAS() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let remote = try makeRemote(fixture)
        let baseEngine = MockEngine(worker: MockWorker())
        let wrapper = EngineWithoutShutdown(base: baseEngine)
        let host = PhoneDSHHost(
            configuration: try makeConfiguration(fixture),
            engineFactory: { _ in wrapper },
            handoffTransport: remote,
            reclaimTokenStore: InMemoryHandoffReclaimTokenStore())

        try await host.start()
        _ = try await writeLocalFile(baseEngine)
        try await waitUntil {
            (try? Data(contentsOf: fixture.materializedFile(
                "workspace/local.txt"))) != nil
        }

        do {
            _ = try await host.beginHandoff()
            XCTFail("an engine without terminal teardown must fail the handoff")
        } catch {
            XCTAssertEqual(error as? HandoffError,
                           .engineShutdownUnsupported)
        }
        let counters = await remote.endpointCounters()
        XCTAssertEqual(counters.fenceRequests, 0,
                       "the CAS must not be sent when the Worker cannot be stopped")
        XCTAssertEqual(counters.snapshotUploads, 0)
        XCTAssertEqual(counters.segmentsUploads, 0)
        XCTAssertEqual(baseEngine.shutdownCount, 0)
        let state = await host.state
        XCTAssertEqual(state, .failed)
        await baseEngine.worker.disconnect()
        try await host.stop()
    }

    // MARK: - Vault failure keeps the in-process token

    func testFailedVaultWriteStillReclaimsWithTheCachedToken() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let remote = try makeRemote(fixture)
        let engine = MockEngine(worker: MockWorker())
        let host = try makeHost(fixture, engine: engine, transport: remote,
                                store: FailingReclaimTokenStore())

        try await host.start()
        let localMseq = try await writeLocalFile(engine)
        try await waitUntil {
            (try? Data(contentsOf: fixture.materializedFile(
                "workspace/local.txt"))) != nil
        }
        do {
            _ = try await host.beginHandoff()
            XCTFail("the failing vault must abort the handoff")
        } catch {
            guard case HandoffError.reclaimTokenStoreFailed = error else {
                return XCTFail("expected reclaimTokenStoreFailed, got \(error)")
            }
        }

        var diagnostics = await host.diagnostics()
        XCTAssertEqual(diagnostics.hostState, .handingOff)
        XCTAssertEqual(diagnostics.admission, .closed)
        let fence = await host.diagnostics().fence?.wireFence
        XCTAssertEqual(fence?.owner, HandoffLimits.phoneOwner)
        XCTAssertEqual(fence?.generation, 0)

        // The token was cached before the failing store call, so the same
        // process can still reclaim through the remote cache.
        let outcome = try await host.reclaim()
        XCTAssertEqual(outcome.fence.owner, HandoffLimits.phoneOwner)
        XCTAssertEqual(outcome.fence.generation, 2)
        XCTAssertEqual(outcome.fence.walSeq, localMseq)
        XCTAssertEqual(engine.bootCount, 2)
        diagnostics = await host.diagnostics()
        XCTAssertEqual(diagnostics.state, .running)
        XCTAssertEqual(diagnostics.admission, .open)
        try await host.stop()
    }

    func testFailedVaultReplacementUsesCachedNewTokenNotStaleVaultItem() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let remote = try makeRemote(fixture)
        let workspaceIdentifier = HandoffReclaimToken.workspaceIdentifier(
            for: fixture.workspace)
        let stale = HandoffReclaimToken(
            token: String(repeating: "b", count: 32),
            remoteFence: Fence(owner: HandoffLimits.remoteOwner,
                               generation: 0, walSeq: 0),
            endpoint: "https://remote.invalid",
            workspaceIdentifier: workspaceIdentifier)
        let store = StaleCredentialFailingReclaimTokenStore(stale)
        let engine = MockEngine(worker: MockWorker())
        let host = try makeHost(fixture, engine: engine, transport: remote,
                                store: store)

        try await host.start()
        _ = try await writeLocalFile(engine)
        try await waitUntil {
            (try? Data(contentsOf: fixture.materializedFile(
                "workspace/local.txt"))) != nil
        }
        do {
            _ = try await host.beginHandoff()
            XCTFail("the failing vault replacement must abort the handoff")
        } catch {
            guard case HandoffError.reclaimTokenStoreFailed = error else {
                return XCTFail("expected reclaimTokenStoreFailed, got \(error)")
            }
        }
        let stillStale = try await store.load()
        XCTAssertEqual(stillStale, stale,
                       "the failed replacement deliberately kept the old item")

        // The new CAS token exists only in ReclaimClient's memory. Loading the
        // stale vault item must not overwrite it; the remote's cached 200 for
        // the new token is the proof that completes the reclaim.
        let outcome = try await host.reclaim()
        XCTAssertEqual(outcome.fence.owner, HandoffLimits.phoneOwner)
        XCTAssertEqual(outcome.fence.generation, 2)
        let remaining = try await store.load()
        XCTAssertNil(remaining)
        let diagnostics = await host.diagnostics()
        XCTAssertEqual(diagnostics.state, .running)
        XCTAssertEqual(diagnostics.admission, .open)
        try await host.stop()
    }

    // MARK: - Definite CAS rejection recovery

    func testDefiniteCASRejectionMarkerAllowsLiveReset() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        // The provisioned remote already advanced to generation 1, so the
        // generation CAS is a definite 409 and no reclaim token exists.
        let remote = try makeRemote(
            fixture,
            initialFence: Fence(owner: HandoffLimits.remoteOwner,
                                generation: 1, walSeq: 0))
        let engine = MockEngine(worker: MockWorker())
        let host = try makeHost(fixture, engine: engine, transport: remote,
                                store: InMemoryHandoffReclaimTokenStore())

        try await host.start()
        XCTAssertEqual(engine.bootCount, 1)
        do {
            _ = try await host.beginHandoff()
            XCTFail("a stale fence CAS must fail the handoff")
        } catch {
            XCTAssertEqual(error as? HandoffError, .fenceConflict)
        }
        let failedState = await host.state
        XCTAssertEqual(failedState, .failed)

        // A definite rejection leaves durable proof, not an unresolved CAS.
        let marker = try FenceAuthority.loadHandoffAuthorityIntent(
            root: fixture.workspace)
        let recorded = try XCTUnwrap(marker)
        XCTAssertTrue(recorded.isDefiniteRejection)
        XCTAssertEqual(recorded.expectedGeneration, 0)

        // The live-runtime reset path must clean the marker and boot; the old
        // code bypassed the intent guard and reopened local admission.
        try await host.reset()
        XCTAssertEqual(engine.bootCount, 2)
        let resetState = await host.state
        XCTAssertEqual(resetState, .running)
        let cleared = try FenceAuthority.loadHandoffAuthorityIntent(
            root: fixture.workspace)
        XCTAssertNil(cleared)
        try await host.stop()
    }

    func testDefiniteCASRejectionSurvivesMarkerWriteFailureAndAllowsReset() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        // A provisioned generation-1 remote makes the CAS a definite 409.
        let remote = try makeRemote(
            fixture,
            initialFence: Fence(owner: HandoffLimits.remoteOwner,
                                generation: 1, walSeq: 0))
        let intentURL = fixture.workspace.appendingPathComponent(
            "handoff-intent.json")
        let transport = MarkerWriteBlockingTransport(base: remote,
                                                     intentURL: intentURL)
        let engine = MockEngine(worker: MockWorker())
        let host = try makeHost(fixture, engine: engine, transport: transport,
                                store: InMemoryHandoffReclaimTokenStore())

        try await host.start()
        do {
            _ = try await host.beginHandoff()
            XCTFail("a stale fence CAS must fail the handoff")
        } catch {
            // The 409 is still a definite rejection even though rewriting the
            // durable marker failed.
            XCTAssertEqual(error as? HandoffError, .fenceConflict)
        }
        XCTAssertNil(transport.setupError)
        XCTAssertTrue(transport.didBlockMarkerWrite,
                      "the durable marker rewrite must actually fail")
        let failedState = await host.state
        XCTAssertEqual(failedState, .failed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: intentURL.path),
                       "the stale unmarked intent must not keep the process locked")

        // The in-process definite outcome makes the ordinary reset usable
        // instead of leaving state == .starting with no token or intent path.
        try await host.reset()
        XCTAssertEqual(engine.bootCount, 2)
        let resetState = await host.state
        XCTAssertEqual(resetState, .running)
        XCTAssertNil(try FenceAuthority.loadHandoffAuthorityIntent(
            root: fixture.workspace))
        try await host.stop()
    }

    func testDefiniteCASRejectionMarkerAllowsNewHostColdStart() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let remote = try makeRemote(
            fixture,
            initialFence: Fence(owner: HandoffLimits.remoteOwner,
                                generation: 1, walSeq: 0))
        let firstEngine = MockEngine(worker: MockWorker())
        let firstHost = try makeHost(fixture, engine: firstEngine,
                                     transport: remote,
                                     store: InMemoryHandoffReclaimTokenStore())
        try await firstHost.start()
        do {
            _ = try await firstHost.beginHandoff()
            XCTFail("a stale fence CAS must fail the handoff")
        } catch {
            XCTAssertEqual(error as? HandoffError, .fenceConflict)
        }
        try await firstHost.stop()
        let marker = try FenceAuthority.loadHandoffAuthorityIntent(
            root: fixture.workspace)
        let recordedMarker = try XCTUnwrap(marker)
        XCTAssertTrue(recordedMarker.isDefiniteRejection)

        let secondEngine = MockEngine(worker: MockWorker())
        let secondHost = try makeHost(fixture, engine: secondEngine,
                                      transport: remote,
                                      store: InMemoryHandoffReclaimTokenStore())
        // The controller is persisted Failed, so D14 still makes start() fail
        // loud. The point is that the definite marker no longer blocks the
        // explicit user reset (the old failure would have been a dead end).
        do {
            try await secondHost.start()
            XCTFail("a persisted Failed controller must refuse a plain start")
        } catch {
            guard case PhoneDSHError.hostFailed = error else {
                return XCTFail("expected hostFailed, got \(error)")
            }
        }
        XCTAssertEqual(secondEngine.bootCount, 0)
        let cleared = try FenceAuthority.loadHandoffAuthorityIntent(
            root: fixture.workspace)
        XCTAssertNil(cleared)
        try await secondHost.reset()
        XCTAssertEqual(secondEngine.bootCount, 1)
        let state = await secondHost.state
        XCTAssertEqual(state, .running)
        try await secondHost.stop()
    }

    func testUnresolvedIntentIsNotBypassedByLiveUserReset() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let remote = try makeRemote(
            fixture,
            initialFence: Fence(owner: HandoffLimits.remoteOwner,
                                generation: 1, walSeq: 0))
        let engine = MockEngine(worker: MockWorker())
        let host = try makeHost(fixture, engine: engine, transport: remote,
                                store: InMemoryHandoffReclaimTokenStore())
        try await host.start()
        do {
            _ = try await host.beginHandoff()
            XCTFail("a stale fence CAS must fail the handoff")
        } catch {
            XCTAssertEqual(error as? HandoffError, .fenceConflict)
        }

        // Replace the definite marker with an unresolved intent: this is what
        // an interrupted CAS (or a failed marker cleanup) leaves behind.
        let intentURL = fixture.workspace.appendingPathComponent(
            "handoff-intent.json")
        try FileManager.default.removeItem(at: intentURL)
        let authority = try FenceAuthority(root: fixture.workspace,
                                           owner: HandoffLimits.phoneOwner,
                                           walSeq: 0)
        try await authority.markHandoffAuthorityUncertain(
            expectedGeneration: 0, walSeq: 0,
            endpoint: "https://remote.invalid")

        do {
            try await host.reset()
            XCTFail("an unresolved CAS intent must keep the live reset closed")
        } catch {
            guard case PhoneDSHError.invalidState = error else {
                return XCTFail("expected invalidState, got \(error)")
            }
        }
        XCTAssertEqual(engine.bootCount, 1,
                       "reset must not boot the local Worker over an unresolved CAS")
        let stillThere = try FenceAuthority.loadHandoffAuthorityIntent(
            root: fixture.workspace)
        let unresolved = try XCTUnwrap(stillThere)
        XCTAssertFalse(unresolved.isDefiniteRejection)
        try await host.stop()
    }

    func testBootGuardFailsClosedWhenDefiniteMarkerIsReplacedBeforeCleanup() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let firstEngine = MockEngine(worker: MockWorker())
        let firstHost = try makeHost(
            fixture, engine: firstEngine, transport: CountingHandoffTransport(),
            store: InMemoryHandoffReclaimTokenStore())
        try await firstHost.start()
        try await firstHost.stop()

        // A durable definite marker from a previous proven 409.
        let authority = try FenceAuthority(root: fixture.workspace,
                                           owner: HandoffLimits.phoneOwner,
                                           walSeq: 0)
        try await authority.markHandoffAuthorityUncertain(
            expectedGeneration: 0, walSeq: 0,
            endpoint: "https://remote.invalid")
        try await authority.markHandoffDefinitelyRejected()
        let root = fixture.workspace

        let secondEngine = MockEngine(worker: MockWorker())
        let secondHost = try makeHost(
            fixture, engine: secondEngine, transport: CountingHandoffTransport(),
            store: InMemoryHandoffReclaimTokenStore())
        // Another host writes a fresh unresolved intent in the window between
        // the boot guard's load and its cleanup call. The guard must re-read
        // and fail closed instead of trusting the earlier definite marker.
        await secondHost.setHandoffBootIntentProbeForTesting {
            let racer = try FenceAuthority(root: root,
                                           owner: HandoffLimits.phoneOwner,
                                           walSeq: 0)
            try await racer.markHandoffAuthorityUncertain(
                expectedGeneration: 0, walSeq: 0,
                endpoint: "https://remote.invalid")
        }
        do {
            try await secondHost.start()
            XCTFail("a fresh unresolved intent must keep local admission closed")
        } catch {
            guard case PhoneDSHError.invalidState = error else {
                return XCTFail("expected invalidState, got \(error)")
            }
        }
        XCTAssertEqual(secondEngine.bootCount, 0,
                       "the host must not boot after losing the load/clear race")
        let remaining = try FenceAuthority.loadHandoffAuthorityIntent(root: root)
        let unresolved = try XCTUnwrap(remaining)
        XCTAssertFalse(unresolved.isDefiniteRejection,
                       "the replacement intent must remain for token recovery")
        try? await secondHost.stop()
    }

    // MARK: - Quiescence before the CAS

    func testHandoffDoesNotSendCASWhileInboundWriteIsUnsettled() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let remote = try makeRemote(fixture)
        let engine = MockEngine(worker: MockWorker())
        let host = try makeHost(fixture, engine: engine, transport: remote,
                                store: InMemoryHandoffReclaimTokenStore())
        try await host.start()
        _ = try await writeLocalFile(engine)
        try await waitUntil {
            (try? Data(contentsOf: fixture.materializedFile(
                "workspace/local.txt"))) != nil
        }
        let held = await host.holdInboundWriteForTesting()
        XCTAssertTrue(held)

        do {
            _ = try await host.beginHandoff()
            XCTFail("an unsettled inbound write must fail the handoff")
        } catch {
            guard case HandoffError.notQuiescent = error else {
                return XCTFail("expected notQuiescent, got \(error)")
            }
        }
        let counters = await remote.endpointCounters()
        XCTAssertEqual(counters.fenceRequests, 0,
                       "the CAS must not be sent while an old write is unsettled")
        XCTAssertEqual(counters.snapshotUploads, 0)
        XCTAssertEqual(counters.segmentsUploads, 0)
        XCTAssertEqual(engine.shutdownCount, 1,
                       "the engine teardown still precedes the refused CAS")
        let state = await host.state
        XCTAssertEqual(state, .failed)
        await host.releaseInboundWriteForTesting()
        try await host.stop()
    }

    // MARK: - Vault lifecycle

    func testInMemoryTokenStoreStoreLoadRemove() async throws {
        let store = InMemoryHandoffReclaimTokenStore()
        let credential = HandoffReclaimToken(
            token: String(repeating: "a", count: 32),
            remoteFence: Fence(owner: HandoffLimits.remoteOwner,
                               generation: 1, walSeq: 7),
            endpoint: "https://remote.invalid",
            workspaceIdentifier: HandoffReclaimToken.workspaceIdentifier(
                for: URL(fileURLWithPath: "/tmp/cold-safety-workspace")))
        try await store.store(credential)
        let loaded = try await store.load()
        XCTAssertEqual(loaded, credential)
        try await store.remove()
        let removed = try await store.load()
        XCTAssertNil(removed)
    }
}
