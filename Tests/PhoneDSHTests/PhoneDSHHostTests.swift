// SPDX-License-Identifier: MIT
// PhoneDSHHost assembly and lifecycle tests.
//
// MockEngine implements WebEngineControlling; MockWorker drives a real ordered
// channel against the loopback server. The scripted Worker sends a real HELLO,
// VFS_MUT and API round trips, so the assembly is exercised end to end on
// macOS without WebKit.

import Foundation
import XCTest
import PhoneDSHController
import PhoneDSH
import PhoneDSHEngine
import PhoneDSHLoopback
import PhoneDSHShell
import PhoneDSHAgentCore

private func producerJournalRecord(_ wireType: String, key: String,
                                  callID: String,
                                  action: String? = nil) -> [String: Any] {
    let localType: String
    switch wireType {
    case "dispatched": localType = "start"
    case "executed": localType = "executed"
    case "completed": localType = "done"
    default: localType = "resolved"
    }
    var record: [String: Any] = [
        "v": 1, "t": localType, "type": wireType,
        "key": key, "call_id": callID, "at": 1_700_000_000_000,
    ]
    if wireType == "executed" || wireType == "completed" {
        record["result"] = [
            "content": [["type": "text", "text": "ok"]],
            "isError": false,
        ]
    }
    if let action { record["action"] = action }
    return record
}

final class PhoneDSHHostTests: XCTestCase {
    private func makeHost(_ fixture: FacadeFixture, engine: MockEngine,
                          configuration: PhoneDSHConfiguration? = nil) throws -> PhoneDSHHost {
        let resolved = try configuration ?? fixture.configuration()
        return PhoneDSHHost(configuration: resolved,
                            engineFactory: { _ in engine })
    }

    func testStartBootsWorkerAndOpensAdmission() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let engine = MockEngine(worker: MockWorker())
        let host = try makeHost(fixture, engine: engine)
        try await host.start()

        let state = await host.state
        XCTAssertEqual(state, .running)
        let diagnostics = await host.diagnostics()
        XCTAssertEqual(diagnostics.state, .running)
        XCTAssertEqual(diagnostics.hostState, .running)
        XCTAssertEqual(diagnostics.admission, .open)
        XCTAssertEqual(diagnostics.fence?.owner, "phone")
        XCTAssertEqual(diagnostics.channelConnectionCount, 1)
        XCTAssertGreaterThanOrEqual(diagnostics.workerHelloCount, 1)
        XCTAssertEqual(engine.bootCount, 1)
        XCTAssertNotNil(engine.lastConfiguration?.token)
        XCTAssertEqual(engine.lastConfiguration?.bootID?.count, 32)
        try await host.stop()
    }

    func testPDSHShellHostHelloPublishesOnlyRunnableAcceleratorCaps() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let shell = PDSHShellProvider(workspaceRoot: fixture.workspace)
        let configuration = try fixture.configuration(
            execProvider: shell,
            acceleratorNames: shell.channelAcceleratorNames)
        let engine = MockEngine(worker: MockWorker())
        let host = try makeHost(fixture, engine: engine, configuration: configuration)
        try await host.start()

        let caps = await engine.worker.hostHelloCaps()
        XCTAssertEqual(caps.filter { $0.hasPrefix("accelerator:") },
                       shell.channelCapabilities)
        XCTAssertFalse(caps.contains("accelerator:phone"),
                       "no PhoneToolBridge is injected, so phone must not be advertised")
        XCTAssertFalse(caps.contains("accelerator:ctx"),
                       "no PhoneToolBridge is injected, so ctx must not be advertised")

        // The HTTP host HELLO must publish the same executable subset.
        let endpoint = try XCTUnwrap(engine.lastConfiguration)
        var components = try XCTUnwrap(
            URLComponents(url: endpoint.origin, resolvingAgainstBaseURL: false))
        components.path = "/v1/hello"
        components.queryItems = [URLQueryItem(name: "token", value: endpoint.token)]
        let (data, response) = try await URLSession.shared.data(
            from: try XCTUnwrap(components.url))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let capabilities = try XCTUnwrap(object["capabilities"] as? [String: Any])
        XCTAssertEqual(capabilities["accelerators"] as? [String] ?? [],
                       shell.channelAcceleratorNames)
        try await host.stop()
    }

    func testEngineBootURLUsesLoopbackStaticRoute() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let engine = MockEngine(worker: MockWorker())
        let host = try makeHost(fixture, engine: engine)
        try await host.start()

        let configuration = try XCTUnwrap(engine.lastConfiguration)
        // The bundle is served only under `/static/*`; booting `/index.html`
        // would 404 and the page-relative worker entry would not resolve.
        XCTAssertEqual(configuration.pagePath, "/static/index.html")
        XCTAssertEqual(configuration.workerPath, "/static/worker-entry.js")

        let pageURL = try configuration.makePageURL()
        XCTAssertEqual(pageURL.path, "/static/index.html")
        var workerComponents = try XCTUnwrap(
            URLComponents(url: pageURL, resolvingAgainstBaseURL: false))
        workerComponents.path = configuration.workerPath
        let workerURL = try XCTUnwrap(workerComponents.url)
        XCTAssertEqual(workerURL.path, "/static/worker-entry.js")

        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (pageData, pageResponse) = try await session.data(from: pageURL)
        XCTAssertEqual((pageResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: pageData, as: UTF8.self), "<html>boot</html>")
        let (_, workerResponse) = try await session.data(from: workerURL)
        XCTAssertEqual((workerResponse as? HTTPURLResponse)?.statusCode, 200)
        try await host.stop()
    }

    func testEngineBootURLKeepsBootstrapWhenCompletePageIsStaged() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let web = fixture.bundle.staticDirectory.appendingPathComponent("web",
                                                                       isDirectory: true)
        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        try Data("<html>complete</html>".utf8)
            .write(to: web.appendingPathComponent("index.html"))

        let engine = MockEngine(worker: MockWorker())
        let host = try makeHost(fixture, engine: engine)
        try await host.start()

        let configuration = try XCTUnwrap(engine.lastConfiguration)
        // Staging the complete page must not change the default route used by
        // the native ChatModel and the smoke/kill suites. Only an explicit
        // pagePath (the App Web surface) selects `/static/web/index.html`.
        XCTAssertEqual(configuration.pagePath, "/static/index.html")
        let pageURL = try configuration.makePageURL()
        XCTAssertEqual(pageURL.path, "/static/index.html")
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (pageData, pageResponse) = try await session.data(from: pageURL)
        XCTAssertEqual((pageResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: pageData, as: UTF8.self), "<html>boot</html>")
        try await host.stop()
    }

    func testEngineBootURLHonoursExplicitCompletePagePath() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let web = fixture.bundle.staticDirectory.appendingPathComponent("web",
                                                                       isDirectory: true)
        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        try Data("<html>explicit</html>".utf8)
            .write(to: web.appendingPathComponent("index.html"))

        var configuration = try fixture.configuration()
        configuration.engine.pagePath = "/static/web/index.html"
        let engine = MockEngine(worker: MockWorker())
        let host = try makeHost(fixture, engine: engine, configuration: configuration)
        try await host.start()

        let booted = try XCTUnwrap(engine.lastConfiguration)
        // A caller-configured page path is an integration contract, not a
        // placeholder: the host must not overwrite it with `/static/index.html`.
        XCTAssertEqual(booted.pagePath, "/static/web/index.html")
        let pageURL = try booted.makePageURL()
        XCTAssertEqual(pageURL.path, "/static/web/index.html")
        try await host.stop()
    }

    func testCallerPagePathIsHonored() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        var configuration = try fixture.configuration()
        configuration.engine.pagePath = "/static/web/index.html"
        let engine = MockEngine(worker: MockWorker())
        let host = try makeHost(fixture, engine: engine, configuration: configuration)
        try await host.start()

        let booted = try XCTUnwrap(engine.lastConfiguration)
        XCTAssertEqual(booted.pagePath, "/static/web/index.html")
        let pageURL = try booted.makePageURL()
        XCTAssertEqual(pageURL.path, "/static/web/index.html")
        try await host.stop()
    }

    func testStartIsIdempotentWhileRunning() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let engine = MockEngine(worker: MockWorker())
        let host = try makeHost(fixture, engine: engine)
        try await host.start()
        try await host.start()
        XCTAssertEqual(engine.bootCount, 1)
        let diagnostics = await host.diagnostics()
        XCTAssertEqual(diagnostics.channelConnectionCount, 1)
        try await host.stop()
    }

    func testScriptedWorkerRoundTripWritesWALAndServesAPI() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let engine = MockEngine(worker: MockWorker())
        let host = try makeHost(fixture, engine: engine)
        try await host.start()

        let mseq = try await engine.worker.writeFile(
            path: "/dsh/workspace/hello.txt",
            data: Data("hello".utf8))
        try await engine.worker.waitForAck(mseq)
        try await engine.worker.waitForOpenFrames()

        let materialized = fixture.materializedFile("workspace/hello.txt")
        try await waitUntil {
            guard let data = try? Data(contentsOf: materialized) else { return false }
            return String(decoding: data, as: UTF8.self) == "hello"
        }

        let harness = try await host.harness()
        let session = try await harness.openSession(HarnessSessionRequest())
        XCTAssertEqual(session.id, "mock-session")

        let diagnostics = await host.diagnostics()
        XCTAssertGreaterThanOrEqual(diagnostics.ackedMseq, mseq)
        XCTAssertGreaterThanOrEqual(diagnostics.materializedUptoMseq, mseq)
        XCTAssertEqual(diagnostics.state, .running)
        try await host.stop()
    }

    func testStartRejectsLockdownMode() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let engine = MockEngine(worker: MockWorker(), lockdown: true)
        let host = try makeHost(fixture, engine: engine)
        do {
            try await host.start()
            XCTFail("expected lockdownMode")
        } catch let error as PhoneDSHError {
            XCTAssertEqual(error, .lockdownMode)
        }
        let state = await host.state
        XCTAssertEqual(state, .failed)
        let diagnostics = await host.diagnostics()
        XCTAssertTrue(diagnostics.lastError?.contains("Lockdown") == true)
        try? await host.stop()
    }

    func testStartRejectsUnattachedEngine() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let engine = MockEngine(worker: MockWorker(), attached: false)
        let host = try makeHost(fixture, engine: engine)
        do {
            try await host.start()
            XCTFail("expected engineNotAttached")
        } catch let error as PhoneDSHError {
            XCTAssertEqual(error, .engineNotAttached)
        }
        try? await host.stop()
    }

    func testStartFailsOnMissingBundle() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let configuration = PhoneDSHConfiguration(
            workspaceRoot: fixture.workspace,
            token: "test-token",
            origin: URL(string: "http://127.0.0.1:1")!,
            bundle: nil)
        let engine = MockEngine(worker: MockWorker())
        let host = PhoneDSHHost(configuration: configuration,
                                engineFactory: { _ in engine })
        do {
            try await host.start()
            XCTFail("expected invalidBundle")
        } catch let error as PhoneDSHError {
            guard case .invalidBundle = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        let state = await host.state
        XCTAssertEqual(state, .failed)
        try? await host.stop()
    }

    func testParkAndResumeFollowD14() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let engine = MockEngine(worker: MockWorker())
        let host = try makeHost(fixture, engine: engine)
        try await host.start()
        let firstConnections = (await host.diagnostics()).channelConnectionCount

        try await host.park()
        let parkedState = await host.state
        XCTAssertEqual(parkedState, .stopped)
        let parked = await host.diagnostics()
        XCTAssertEqual(parked.hostState, .parked)
        XCTAssertEqual(parked.admission, .closed)

        try await host.resume()
        let resumedState = await host.state
        XCTAssertEqual(resumedState, .running)
        let resumed = await host.diagnostics()
        XCTAssertEqual(resumed.hostState, .running)
        XCTAssertEqual(resumed.admission, .open)
        XCTAssertEqual(engine.bootCount, 2)
        XCTAssertGreaterThan(resumed.channelConnectionCount, firstConnections)
        try await host.stop()
    }

    func testParkFailsLoudWhenTheDescendantDrainRouteFailsWithoutAChildJournal() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let engine = MockEngine(worker: MockWorker())
        let configuration = try fixture.configuration(drainDeadline: 10)
        let host = try makeHost(fixture, engine: engine, configuration: configuration)
        try await host.start()

        // A tracked root is all the host has: the scripted Worker never wrote
        // a child journal. An empty local forest cannot exclude an external or
        // concurrently spawned child, so a route failure here must not be
        // downgraded to a warning.
        let harness = try await host.harness()
        _ = try await harness.openSession(HarnessSessionRequest())
        try await engine.worker.setDescendantDrainFailureStatus(503)

        do {
            try await host.park()
            XCTFail("a failed scoped descendant drain must fail the park")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains("scoped descendant drain failed"),
                "the park error must name the route failure: \(error)")
        }
        let requests = await engine.worker.descendantDrainRequestCount()
        XCTAssertGreaterThanOrEqual(
            requests, 2,
            "the early pre-graceful attempt and the abort's mandatory verification "
                + "attempt must both name the tracked root")
        try? await host.stop()
    }

    /// A successful route receipt is not terminal evidence. If it names a live
    /// child whose journal never materialized, the re-read forest would silently
    /// shrink and the abort loop would see no open turn. The host must fail loud
    /// instead of parking as if that child were gracefully closed.
    func testParkFailsLoudWhenTheRouteReportsALiveDescendantWithoutAJournal() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let engine = MockEngine(worker: MockWorker())
        let configuration = try fixture.configuration(drainDeadline: 10)
        let host = try makeHost(fixture, engine: engine, configuration: configuration)
        try await host.start()

        let harness = try await host.harness()
        _ = try await harness.openSession(HarnessSessionRequest())
        // The receipt names a live child but the scripted Worker never writes
        // its session journal or terminal turn/end.
        await engine.worker.setDescendantDrainDescendants(["child"])

        do {
            try await host.park()
            XCTFail("a route-reported live child without a durable journal "
                        + "must fail the park")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains("cannot be proven terminal"),
                "the park error must name the unverifiable live child: \(error)")
        }
        let requests = await engine.worker.descendantDrainRequestCount()
        XCTAssertGreaterThanOrEqual(
            requests, 2,
            "the early pre-graceful pass and the abort pass must both reject "
                + "the receipt that names an unverifiable child")
        try? await host.stop()
    }

    func testShortDrainStillAttemptsTheScopedRouteBeforeStopping() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let engine = MockEngine(worker: MockWorker())
        let configuration = try fixture.configuration(drainDeadline: 1)
        let host = try makeHost(fixture, engine: engine, configuration: configuration)
        try await host.start()
        let harness = try await host.harness()
        _ = try await harness.openSession(HarnessSessionRequest())
        let createdAt = Int64((Date().timeIntervalSince1970 * 1000).rounded())
        try await writeSessionJournal(
            fixture, worker: engine.worker, id: "mock-session",
            text: try sessionJournalText(id: "mock-session", createdAt: createdAt, closeTurn: true))
        let started = Date()
        try await host.stop()
        let attempts = await engine.worker.descendantDrainRequestCount()
        XCTAssertGreaterThan(attempts, 0, "a short window must not skip the mandatory scoped call")
        XCTAssertLessThan(Date().timeIntervalSince(started), configuration.drainDeadline)
        let state = await host.state
        XCTAssertEqual(state, .stopped)
    }

    /// A failed scoped descendant route must not skip the existing root
    /// `session/cancel` + terminate/reboot escalation path. The route error is
    /// still fail loud, but only after the root path had its chance to settle
    /// (here the scripted root turn never closes, so the escalation runs).
    func testStopRouteFailureStillCancelsTheRootAndEscalates() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let engine = MockEngine(worker: MockWorker())
        let configuration = try fixture.configuration(drainDeadline: 3)
        let host = try makeHost(fixture, engine: engine, configuration: configuration)
        try await host.start()

        let harness = try await host.harness()
        _ = try await harness.openSession(HarnessSessionRequest())
        let createdAt = Int64((Date().timeIntervalSince1970 * 1000).rounded())
        try await writeSessionJournal(
            fixture, worker: engine.worker, id: "mock-session",
            text: try sessionJournalText(id: "mock-session",
                                         createdAt: createdAt,
                                         closeTurn: false))
        try await engine.worker.setDescendantDrainFailureStatus(503)

        do {
            try await host.stop()
            XCTFail("the failed scoped descendant drain must still be fail loud")
        } catch {
            XCTAssertTrue(String(describing: error).contains("scoped descendant drain"),
                          "the stop error must name the route failure: \(error)")
        }

        let requests = await engine.worker.descendantDrainRequestCount()
        XCTAssertGreaterThan(requests, 0,
                             "the abort must actually attempt the scoped route")
        let methods = await engine.worker.unaryMethods()
        XCTAssertTrue(methods.contains("session/cancel"),
                      "the route failure must not skip the root cancel; methods: \(methods)")
        XCTAssertGreaterThanOrEqual(
            engine.bootCount, 2,
            "the route failure must not skip the terminate/reboot escalation "
                + "when the root turn is still open")
    }

    /// A Worker restart (planned restart) opens a new Worker epoch. A child
    /// journal left open by the old Worker has no resident Activation in the
    /// replacement, so it must not make the next park wait for a `turn/end`
    /// that can never be written.
    func testPlannedRestartExcludesAnOldWorkerOrphanChildFromTheNextPark() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let engine = MockEngine(worker: MockWorker())
        let configuration = try fixture.configuration(drainDeadline: 10)
        let host = try makeHost(fixture, engine: engine, configuration: configuration)
        try await host.start()

        let harness = try await host.harness()
        _ = try await harness.openSession(HarnessSessionRequest())
        let createdAt = Int64((Date().timeIntervalSince1970 * 1000).rounded())
        try await writeSessionJournal(
            fixture, worker: engine.worker, id: "mock-session",
            text: try sessionJournalText(id: "mock-session",
                                         createdAt: createdAt,
                                         closeTurn: true))
        try await writeSessionJournal(
            fixture, worker: engine.worker, id: "orphan-child",
            text: try sessionJournalText(id: "orphan-child",
                                         createdAt: createdAt,
                                         parent: "mock-session",
                                         closeTurn: false))

        try await host.plannedRestart(reason: "orphan-child-epoch")
        try await host.park()

        let state = await host.state
        XCTAssertEqual(state, .stopped)
        try? await host.stop()
    }

    /// A child journal written by the old Worker after the planned restart
    /// began (the old Worker page is still being replaced) must be stale for
    /// the replacement. The Worker epoch boundary therefore has to be taken
    /// after the replacement has actually booted, not before the old Worker
    /// is torn down.
    func testPlannedRestartTreatsAChildWrittenDuringOldWorkerShutdownAsStale() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let engine = MockEngine(worker: MockWorker())
        let configuration = try fixture.configuration(drainDeadline: 10)
        let host = try makeHost(fixture, engine: engine, configuration: configuration)
        try await host.start()

        let harness = try await host.harness()
        _ = try await harness.openSession(HarnessSessionRequest())
        let createdAt = Int64((Date().timeIntervalSince1970 * 1000).rounded())
        try await writeSessionJournal(
            fixture, worker: engine.worker, id: "mock-session",
            text: try sessionJournalText(id: "mock-session",
                                         createdAt: createdAt,
                                         closeTurn: true))

        let childURL = fixture.materializedFile(
            "home/sessions/--dsh-workspace--/shutdown-child/session.v4.jsonl")
        engine.setRestartHook {
            // The old Worker writes its child in the shutdown window, after the
            // controller seal and before the replacement connects. Keep the
            // later epoch boundary strictly after this wall-clock createdAt.
            try Self.writeShutdownChildJournal(at: childURL,
                                               id: "shutdown-child",
                                               parent: "mock-session")
            Thread.sleep(forTimeInterval: 0.02)
        }
        try await host.plannedRestart(reason: "old-worker-shutdown-child")
        engine.setRestartHook(nil)

        try await host.park()
        let state = await host.state
        XCTAssertEqual(state, .stopped,
                       "the old Worker's shutdown child must not be treated as a "
                           + "replacement-Worker descendant")
        try? await host.stop()
    }

    /// The same stale-boundary reset is required on the automatic WebContent
    /// termination recovery, which boots a replacement Worker outside
    /// `beginStart`.
    func testTerminationRecoveryExcludesAnOldWorkerOrphanChildFromTheNextPark() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let engine = MockEngine(worker: MockWorker())
        let configuration = try fixture.configuration(drainDeadline: 10)
        let host = try makeHost(fixture, engine: engine, configuration: configuration)
        try await host.start()

        let harness = try await host.harness()
        _ = try await harness.openSession(HarnessSessionRequest())
        let createdAt = Int64((Date().timeIntervalSince1970 * 1000).rounded())
        try await writeSessionJournal(
            fixture, worker: engine.worker, id: "mock-session",
            text: try sessionJournalText(id: "mock-session",
                                         createdAt: createdAt,
                                         closeTurn: true))
        try await writeSessionJournal(
            fixture, worker: engine.worker, id: "orphan-child",
            text: try sessionJournalText(id: "orphan-child",
                                         createdAt: createdAt,
                                         parent: "mock-session",
                                         closeTurn: false))

        engine.emit(.terminated(1))
        try await waitUntil(timeout: 10) {
            let diagnostics = await host.diagnostics()
            return diagnostics.state == .running
                && diagnostics.webContentTerminations >= 1
                && engine.bootCount >= 2
        }
        try await host.park()

        let state = await host.state
        XCTAssertEqual(state, .stopped)
        try? await host.stop()
    }

    /// `resume()` boots through `bootRuntime`, the same path the user-reset
    /// runtime branch uses. A journal written while the old Worker was parked
    /// is stale for the replacement and must not strand the next park.
    func testResumeBootRuntimeExcludesAParkedWorkerOrphanChildFromTheNextPark() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let engine = MockEngine(worker: MockWorker())
        let configuration = try fixture.configuration(drainDeadline: 10)
        let host = try makeHost(fixture, engine: engine, configuration: configuration)
        try await host.start()

        let harness = try await host.harness()
        _ = try await harness.openSession(HarnessSessionRequest())
        try await host.park()

        // This fixture represents a previous parked Worker, not a child born
        // in the replacement boot's same millisecond (which is intentionally
        // kept by the inclusive production cutoff).
        let createdAt = Int64((Date().timeIntervalSince1970 * 1000).rounded(.down)) - 1_000
        try writeMaterializedSessionJournal(
            fixture, id: "mock-session",
            text: try sessionJournalText(id: "mock-session",
                                         createdAt: createdAt,
                                         closeTurn: true))
        try writeMaterializedSessionJournal(
            fixture, id: "orphan-child",
            text: try sessionJournalText(id: "orphan-child",
                                         createdAt: createdAt,
                                         parent: "mock-session",
                                         closeTurn: false))

        try await host.resume()
        try await host.park()

        let state = await host.state
        XCTAssertEqual(state, .stopped)
        try? await host.stop()
    }

    func testParkFailsLoudWhenTheDrainWindowExpiresBeforeTheMandatoryRoute() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let engine = MockEngine(worker: MockWorker())
        // Shorter than the plan's teardown reserve: the pre-graceful pass and
        // the graceful wait have no usable window left. Returning from the
        // abort on an expired window would park without ever naming a root.
        let configuration = try fixture.configuration(drainDeadline: 0.1)
        let host = try makeHost(fixture, engine: engine, configuration: configuration)
        try await host.start()
        let harness = try await host.harness()
        _ = try await harness.openSession(HarnessSessionRequest())

        do {
            try await host.park()
            XCTFail("an unattempted mandatory descendant route must not park as success")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains("unattempted route is not convergence"),
                "the park error must name the unattempted route: \(error)")
        }
        let requests = await engine.worker.descendantDrainRequestCount()
        XCTAssertEqual(requests, 0,
                       "no route may be reported when the window never allowed one")
        try? await host.stop()
    }

    func testStopReleasesRuntimeAndAllowsRestart() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let engine = MockEngine(worker: MockWorker())
        let host = try makeHost(fixture, engine: engine)
        try await host.start()
        try await host.stop()

        let stopped = await host.state
        XCTAssertEqual(stopped, .stopped)
        do {
            _ = try await host.makeTransport()
            XCTFail("expected notStarted after stop")
        } catch let error as PhoneDSHError {
            XCTAssertEqual(error, .notStarted)
        }

        try await host.start()
        let restarted = await host.state
        XCTAssertEqual(restarted, .running)
        XCTAssertEqual(engine.bootCount, 2)
        try await host.stop()
    }

    func testHarnessRefusesLockdownModeAfterStart() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let engine = MockEngine(worker: MockWorker())
        let host = try makeHost(fixture, engine: engine)
        try await host.start()
        engine.setLockdown(true)
        do {
            _ = try await host.harness()
            XCTFail("expected lockdownMode")
        } catch let error as PhoneDSHError {
            XCTAssertEqual(error, .lockdownMode)
        }
        engine.setLockdown(false)
        let harness = try await host.harness()
        let session = try await harness.openSession(HarnessSessionRequest())
        XCTAssertEqual(session.id, "mock-session")
        try await host.stop()
    }

    func testHarnessExplainsLockdownAfterFailedStart() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let engine = MockEngine(worker: MockWorker(), lockdown: true)
        let host = try makeHost(fixture, engine: engine)
        do {
            try await host.start()
            XCTFail("expected lockdownMode")
        } catch let error as PhoneDSHError {
            XCTAssertEqual(error, .lockdownMode)
        }
        do {
            _ = try await host.harness()
            XCTFail("expected lockdownMode from harness")
        } catch let error as PhoneDSHError {
            XCTAssertEqual(error, .lockdownMode)
        }
        try? await host.stop()
    }

    func testDiagnosticsExposeFenceBudgetAndChannel() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let engine = MockEngine(worker: MockWorker())
        let host = try makeHost(fixture, engine: engine)
        try await host.start()
        _ = try await engine.worker.writeFile(path: "/dsh/workspace/a.txt",
                                              data: Data("a".utf8))
        try await engine.worker.waitForAck(1)

        let diagnostics = await host.diagnostics()
        XCTAssertEqual(diagnostics.hostState, .running)
        XCTAssertEqual(diagnostics.admission, .open)
        XCTAssertEqual(diagnostics.fence?.owner, "phone")
        let budget = try XCTUnwrap(diagnostics.budget)
        XCTAssertEqual(budget.table, .eightGB)
        XCTAssertGreaterThanOrEqual(budget.workspaceBytesUsed, 1)
        XCTAssertTrue(budget.isWithinVFSLimit)
        let channel = try XCTUnwrap(diagnostics.channelMetrics)
        XCTAssertGreaterThan(channel.framesIn, 0)
        XCTAssertGreaterThan(channel.framesOut, 0)
        XCTAssertGreaterThanOrEqual(diagnostics.nextEpoch, 1)
        XCTAssertNotNil(diagnostics.stepMetrics)
        XCTAssertEqual(diagnostics.sideEffectEntries, 0)
        XCTAssertGreaterThanOrEqual(diagnostics.workerHelloCount, 1)
        try await host.stop()
    }

    func testBudgetDecisionCountsHomeBytesOutsideSessions() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        // A one-byte VFS cap with normal per-prefix caps: only a prefix the
        // monitor forgot to sum (here `/dsh/home` outside `sessions/`) can
        // trip the aggregate cap. The diagnostics total always came from
        // `totalVFSBytes`; the monitor decision must use the same basis.
        let configuration = try fixture.configuration(
            budgets: .withVFSLogicalCap(1))
        let engine = MockEngine(worker: MockWorker())
        let host = try makeHost(fixture, engine: engine, configuration: configuration)
        try await host.start()

        _ = try await engine.worker.writeFile(path: "/dsh/home/notes.bin",
                                              data: Data("home".utf8))
        try await engine.worker.waitForAck(1)
        let materialized = fixture.materializedFile("home/notes.bin")
        try await waitUntil {
            (try? Data(contentsOf: materialized)) != nil
        }

        let diagnostics = await host.diagnostics()
        let budget = try XCTUnwrap(diagnostics.budget)
        XCTAssertGreaterThanOrEqual(budget.vfsLogicalBytesUsed, 4)
        XCTAssertFalse(budget.isWithinVFSLimit)
        XCTAssertEqual(budget.lastAction, .clearTmp,
                       "the monitor must count /dsh/home otherBytes like vfsLogicalBytesUsed")
        try await host.stop()
    }

    func testWorkerReconnectKeepsHostRunningAndCountsConnections() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let engine = MockEngine(worker: MockWorker())
        let host = try makeHost(fixture, engine: engine)
        try await host.start()
        let before = await host.diagnostics()

        await engine.worker.disconnect()
        try await engine.worker.reconnect()
        try await waitUntil {
            let diagnostics = await host.diagnostics()
            return diagnostics.channelConnectionCount > before.channelConnectionCount
                && diagnostics.workerHelloCount > before.workerHelloCount
        }
        let diagnostics = await host.diagnostics()
        XCTAssertEqual(diagnostics.state, .running)
        XCTAssertGreaterThanOrEqual(diagnostics.workerHelloCount, 2)
        try await host.stop()
    }

    func testTransportReissuesCallAfterChannelReconnect() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let engine = MockEngine(worker: MockWorker())
        let host = try makeHost(fixture, engine: engine)
        try await host.start()
        let transport = try await host.makeTransport()

        await engine.worker.disconnect()
        let call = Task {
            try await transport.call("session/create", args: JSONValue.object([:]))
        }
        // Give the first attempt time to observe the dead connection and wait
        // for the next one; a faster reconnect still exercises the same path.
        try await Task.sleep(nanoseconds: 100_000_000)
        try await engine.worker.reconnect()
        let value = try await call.value
        XCTAssertEqual(value["sessionId"]?.testString, "mock-session")
        try await host.stop()
    }

    func testWebContentTerminationRecoversToRunning() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let engine = MockEngine(worker: MockWorker())
        let host = try makeHost(fixture, engine: engine)
        try await host.start()

        engine.emit(.terminated(1))
        try await waitUntil(timeout: 10) {
            let diagnostics = await host.diagnostics()
            return diagnostics.state == .running
                && diagnostics.webContentTerminations >= 1
                && engine.bootCount >= 2
        }
        let diagnostics = await host.diagnostics()
        XCTAssertEqual(diagnostics.hostState, .running)
        XCTAssertEqual(diagnostics.admission, .open)
        XCTAssertGreaterThanOrEqual(diagnostics.webContentTerminations, 1)
        try await host.stop()
    }

    func testWebContentTerminationPublishesExactlyOneRestartedEvent() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let engine = MockEngine(worker: MockWorker())
        let host = try makeHost(fixture, engine: engine)
        try await host.start()
        let recorder = RestartEventRecorder(host.eventStream())
        defer { recorder.stop() }

        engine.emit(.terminated(1))
        try await waitUntil(timeout: 10) {
            let state = await host.state
            return state == .running
                && engine.bootCount >= 2
                && recorder.reports.isEmpty == false
        }
        // Let any late duplicate reach the subscription before counting.
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(recorder.reports.count, 1,
                       "a termination recovery must publish exactly one .restarted event")
        XCTAssertEqual(recorder.reports.first?.reason, .webContentTerminated)
        try await host.stop()
    }

    func testMuxRoundTripOnLoopback() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let engine = MockEngine(worker: MockWorker())
        let host = try makeHost(fixture, engine: engine)
        try await host.start()

        let transport = try await host.makeTransport()
        let mux = try await transport.openMux()
        let outbound = JSONValue.object([
            "type": .string("open"),
            "streamId": .string("follow"),
            "endpoint": .string("session/follow"),
        ])
        try await mux.send(outbound)
        try await waitUntil {
            (await engine.worker.muxFrames()).isEmpty == false
        }
        let latestMuxID = await engine.worker.latestMuxID()
        let muxID = try XCTUnwrap(latestMuxID)

        let receiveTask = Task { try await mux.receive() }
        try await engine.worker.waitForMuxReceive(muxID: muxID)
        let inbound = JSONValue.object([
            "type": .string("item"),
            "streamId": .string("follow"),
            "value": .object(["type": .string("snapshot")]),
        ])
        try await engine.worker.pushMuxFrame(inbound, muxID: muxID)
        let received = try await receiveTask.value
        XCTAssertEqual(received?["streamId"]?.testString, "follow")
        XCTAssertEqual(received?["value"]?["type"]?.testString, "snapshot")
        await mux.close()
        try await host.stop()
    }

    func testEventStreamPublishesStateAndHelloInOrder() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let engine = MockEngine(worker: MockWorker())
        let host = try makeHost(fixture, engine: engine)
        let stream = host.eventStream()
        try await host.start()
        try await host.park()

        var events: [PhoneDSHEvent] = []
        for await event in stream {
            events.append(event)
            if case .stateChanged(_, let to) = event, to == .stopped { break }
        }
        let helloIndex = events.firstIndex {
            if case .workerHello = $0 { return true }
            return false
        }
        let runningIndex = events.firstIndex {
            if case .stateChanged(_, let to) = $0 { return to == .running }
            return false
        }
        let stoppedIndex = events.firstIndex {
            if case .stateChanged(_, let to) = $0 { return to == .stopped }
            return false
        }
        let hello = try XCTUnwrap(helloIndex)
        let running = try XCTUnwrap(runningIndex)
        let stopped = try XCTUnwrap(stoppedIndex)
        XCTAssertLessThan(hello, running)
        XCTAssertLessThan(running, stopped)
        try await host.stop()
    }

    func testEventStreamPublishesEngineConsoleAndRestart() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let engine = MockEngine(worker: MockWorker())
        let host = try makeHost(fixture, engine: engine)
        let stream = host.eventStream()
        try await host.start()
        engine.emit(.consoleLine(WebEngineConsoleLine(level: .warning, text: "warn")))
        engine.emit(.restarted(WebEngineRestartReport(reason: .planned,
                                                      bootID: String(repeating: "b", count: 32),
                                                      duration: .seconds(1))))
        var sawConsole = false
        var sawRestart = false
        for await event in stream {
            if case .console(let payload) = event {
                XCTAssertEqual(payload.level, .warn)
                XCTAssertEqual(payload.text, "warn")
                sawConsole = true
            }
            if case .restarted(let report) = event {
                XCTAssertEqual(report.reason, .planned)
                sawRestart = true
            }
            if sawConsole && sawRestart { break }
        }
        XCTAssertTrue(sawConsole)
        XCTAssertTrue(sawRestart)
        try await host.stop()
    }

    func testEventStreamPublishesFailLoudError() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let engine = MockEngine(worker: MockWorker(), lockdown: true)
        let host = try makeHost(fixture, engine: engine)
        let stream = host.eventStream()
        do {
            try await host.start()
        } catch {}
        var sawError = false
        var sawFailed = false
        for await event in stream {
            if case .error = event { sawError = true }
            if case .stateChanged(_, let to) = event, to == .failed { sawFailed = true }
            if sawError && sawFailed { break }
        }
        XCTAssertTrue(sawError)
        XCTAssertTrue(sawFailed)
        try? await host.stop()
    }

    func testStopFinishesEventStreamAndRestartReopensIt() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let engine = MockEngine(worker: MockWorker())
        let host = try makeHost(fixture, engine: engine)
        let first = host.eventStream()
        try await host.start()
        try await host.stop()

        var sawStopped = false
        for await event in first {
            if case .stateChanged(_, let to) = event, to == .stopped {
                sawStopped = true
            }
        }
        XCTAssertTrue(sawStopped, "stop() must finish the event stream")

        // A restarted host publishes on a reopened bus.
        try await host.start()
        let second = host.eventStream()
        try await host.park()
        var sawStoppedAgain = false
        for await event in second {
            if case .stateChanged(_, let to) = event, to == .stopped {
                sawStoppedAgain = true
                break
            }
        }
        XCTAssertTrue(sawStoppedAgain, "start() must reopen the event bus")
        try await host.stop()
    }

    func testResetAfterFailedStartRecoversTheHost() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let engine = MockEngine(worker: MockWorker(), lockdown: true)
        let host = try makeHost(fixture, engine: engine)
        do {
            try await host.start()
            XCTFail("expected lockdownMode")
        } catch let error as PhoneDSHError {
            XCTAssertEqual(error, .lockdownMode)
        }
        // D14: a failed host stays failed until the user acknowledges it.
        do {
            try await host.start()
            XCTFail("start() must keep failing while the host is failed")
        } catch let error as PhoneDSHError {
            guard case .hostFailed = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        engine.setLockdown(false)
        try await host.reset()
        let state = await host.state
        XCTAssertEqual(state, .running)
        let diagnostics = await host.diagnostics()
        XCTAssertEqual(diagnostics.admission, .open)
        XCTAssertNil(diagnostics.lastError)
        try await host.stop()
    }

    func testResetAfterStoppedFailureRebuildsTheHost() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let engine = MockEngine(worker: MockWorker(), lockdown: true)
        let host = try makeHost(fixture, engine: engine)
        do {
            try await host.start()
            XCTFail("expected lockdownMode")
        } catch {}
        try? await host.stop()
        engine.setLockdown(false)

        try await host.reset()
        let state = await host.state
        XCTAssertEqual(state, .running)
        // The failed boot never reached bootWorker (checkEngine fails first),
        // so the rebuilt host produced the first engine boot.
        XCTAssertEqual(engine.bootCount, 1)
        try await host.stop()
    }

    func testExecDedupPersistsAcrossHostRestart() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let provider = TestExecProvider()
        let configuration = try fixture.configuration(execProvider: provider,
                                                      acceleratorNames: ["rg"])
        let engine = MockEngine(worker: MockWorker())
        let host = try makeHost(fixture, engine: engine, configuration: configuration)
        try await host.start()

        let idemKey = String(repeating: "a", count: 64)
        try await engine.worker.requestExec(execID: "e1", idemKey: idemKey,
                                            argv: ["rg", "needle"])
        try await engine.worker.waitForExecEvent("e1", type: "exit")
        XCTAssertEqual(provider.runCount, 1)
        let first = await host.diagnostics()
        XCTAssertGreaterThanOrEqual(first.sideEffectEntries, 1)
        try await host.stop()
        // A new host incarnation reloads the ledger from disk; the repeated
        // idem_key must replay the recorded events and never execute again.
        try await host.start()
        try await engine.worker.requestExec(execID: "e2", idemKey: idemKey,
                                            argv: ["rg", "needle"])
        try await waitUntil {
            let events = await engine.worker.execEvents()
            let replayedStart = events.contains {
                $0.execID == "e1" && $0.type == "start" && $0.replayed
            }
            // One exit from the first execution, one from the replay.
            let exits = events.filter { $0.execID == "e1" && $0.type == "exit" }
            return replayedStart && exits.count >= 2
        }
        XCTAssertEqual(provider.runCount, 1)
        let events = await engine.worker.execEvents()
        XCTAssertTrue(events.contains {
            $0.execID == "e1" && $0.type == "start" && $0.replayed
        }, "the replay must mark its start event")
        XCTAssertGreaterThanOrEqual(
            events.filter { $0.execID == "e1" && $0.type == "exit" }.count, 2,
            "the replayed stream must contain the recorded exit event")
        try await host.stop()
    }

    func testDurableJournalAndExecEvidenceRebuildMissingStepProjectionOnBoot() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let provider = TestExecProvider()
        let configuration = try fixture.configuration(execProvider: provider,
                                                      acceleratorNames: ["rg"])
        let engine = MockEngine(worker: MockWorker())
        let host = try makeHost(fixture, engine: engine, configuration: configuration)
        let sessionID = "recovery-session"
        let toolKey = "xl1-" + String(repeating: "1", count: 32)
        let firstIdemKey = String(repeating: "f", count: 64)
        let secondIdemKey = String(repeating: "e", count: 64)

        try await host.start()
        try await engine.worker.waitForOpenFrames()
        let dispatch = try await engine.worker.sendJournal(
            sessionID: sessionID, record: ["type": "dispatched", "key": toolKey])
        try await engine.worker.waitForJournalAck(sessionID: sessionID, jseq: dispatch)
        let requiresMseq = try await engine.worker.writeFile(
            path: "/dsh/workspace/accelerator-input.txt", data: Data("input".utf8))
        try await engine.worker.waitForAck(requiresMseq)
        try await engine.worker.requestExec(execID: "recovery-exec-1",
                                            idemKey: firstIdemKey,
                                            argv: ["rg", "needle"], journalKey: toolKey,
                                            requiresMseq: requiresMseq)
        try await engine.worker.waitForExecEvent("recovery-exec-1", type: "exit")
        let afterFirstExec = try StepMachine(root: fixture.workspace)
        let afterFirstState = await afterFirstExec.record(sessionID: sessionID,
                                                          stepKey: toolKey)?.state
        XCTAssertEqual(afterFirstState,
                       .execRunning,
                       "one terminal spawn cannot declare the whole D20 tool call exited")
        let secondRequiresMseq = try await engine.worker.writeFile(
            path: "/dsh/workspace/accelerator-input-2.txt", data: Data("input-2".utf8))
        try await engine.worker.waitForAck(secondRequiresMseq)
        try await engine.worker.requestExec(
            execID: "recovery-exec-2", idemKey: secondIdemKey,
            argv: ["rg", "needle-2"], journalKey: toolKey,
            requiresMseq: secondRequiresMseq,
            extraEnv: ["REMOVE_ME": .null])
        try await engine.worker.waitForExecEvent("recovery-exec-2", type: "exit")
        let executed = try await engine.worker.sendJournal(
            sessionID: sessionID, record: ["type": "executed", "key": toolKey])
        try await engine.worker.waitForJournalAck(sessionID: sessionID, jseq: executed)
        let completed = try await engine.worker.sendJournal(
            sessionID: sessionID, record: ["type": "completed", "key": toolKey])
        try await engine.worker.waitForJournalAck(sessionID: sessionID, jseq: completed)

        let beforeBoot = try StepMachine(root: fixture.workspace)
        let live = await beforeBoot.record(sessionID: sessionID, stepKey: toolKey)
        XCTAssertEqual(live?.state, .journaled)
        XCTAssertEqual(live?.execEvidence?.count, 2)
        XCTAssertTrue(live?.execEvidence?.values.allSatisfy {
            $0.started && $0.terminal && $0.walAcknowledged && !$0.persistenceFailed
        } == true)
        XCTAssertEqual(live?.history, Array(acceleratorStepPath.dropFirst()),
                       "the D20 key provides no model-streaming/turn attribution")

        // Simulate loss of the controller projection after all records were
        // durably journaled. Boot must rebuild from CRC-validated JournalLog
        // plus the persisted, explicitly associated exec ledger entry.
        try await host.stop()
        try FileManager.default.removeItem(
            at: fixture.workspace.appendingPathComponent("steps", isDirectory: true))
        try await host.start()
        let recovered = try StepMachine(root: fixture.workspace)
        let rebuilt = await recovered.record(sessionID: sessionID, stepKey: toolKey)
        XCTAssertEqual(rebuilt?.state, .journaled)
        XCTAssertEqual(rebuilt?.execEvidence?.count, 2)
        XCTAssertTrue(rebuilt?.execEvidence?.values.allSatisfy {
            $0.started && $0.terminal && $0.walAcknowledged && !$0.persistenceFailed
        } == true)
        XCTAssertEqual(rebuilt?.mseq, secondRequiresMseq)
        XCTAssertEqual(rebuilt?.history, Array(acceleratorStepPath.dropFirst()),
                       "boot recovery must not invent model-streaming attribution")
        try await host.stop()
    }

    func testFakeDoneAndValidDoneWithoutExecTerminalCannotCheckpoint() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let provider = GatedExecProvider()
        let configuration = try fixture.configuration(execProvider: provider,
                                                      acceleratorNames: ["rg"])
        let engine = MockEngine(worker: MockWorker())
        let host = try makeHost(fixture, engine: engine, configuration: configuration)
        try await host.start()
        defer { provider.finish() }

        let sessionID = "missing-exec-proof-session"
        let toolKey = "xl1-" + String(repeating: "8", count: 32)
        let dispatch = try await engine.worker.sendJournal(
            sessionID: sessionID,
            record: producerJournalRecord("dispatched", key: toolKey,
                                          callID: "missing-proof-call"))
        try await engine.worker.waitForJournalAck(sessionID: sessionID, jseq: dispatch)
        let mseq = try await engine.worker.writeFile(
            path: "/dsh/workspace/missing-proof.txt", data: Data("pending".utf8))
        try await engine.worker.waitForAck(mseq)
        try await engine.worker.requestExec(execID: "exec-missing-proof",
                                            idemKey: String(repeating: "a", count: 64),
                                            argv: ["rg", "pending"], journalKey: toolKey,
                                            requiresMseq: mseq)
        try await engine.worker.waitForExecEvent("exec-missing-proof", type: "start")

        let fake = try await engine.worker.sendJournal(
            sessionID: sessionID, record: ["type": "completed", "key": toolKey])
        try await engine.worker.waitForJournalAck(sessionID: sessionID, jseq: fake)
        let afterFake = try StepMachine(root: fixture.workspace)
        let fakeRecord = await afterFake.record(sessionID: sessionID, stepKey: toolKey)
        XCTAssertNil(fakeRecord?.checkpointJseq,
                     "a type/key-only marker carries no result checkpoint authority")

        let unknownResolution = try await engine.worker.sendJournal(
            sessionID: sessionID,
            record: producerJournalRecord("resolved", key: toolKey,
                                          callID: "missing-proof-call",
                                          action: "invented-action"))
        try await engine.worker.waitForJournalAck(sessionID: sessionID,
                                                  jseq: unknownResolution)
        let afterUnknown = try StepMachine(root: fixture.workspace)
        let unknownRecord = await afterUnknown.record(sessionID: sessionID, stepKey: toolKey)
        XCTAssertNil(unknownRecord?.checkpointJseq,
                     "an unrecognized recovery action is not checkpoint authority")

        let done = try await engine.worker.sendJournal(
            sessionID: sessionID,
            record: producerJournalRecord("completed", key: toolKey,
                                          callID: "missing-proof-call"))
        try await engine.worker.waitForJournalAck(sessionID: sessionID, jseq: done)
        let afterDone = try StepMachine(root: fixture.workspace)
        let record = await afterDone.record(sessionID: sessionID, stepKey: toolKey)
        XCTAssertEqual(record?.checkpointJseq, done)
        XCTAssertEqual(record?.completionJseq, done)
        XCTAssertNotEqual(record?.state, .journaled,
                          "a valid result cannot replace missing durable EXEC_EVT terminal/WAL proof")
        XCTAssertEqual(record?.execEvidence?["exec-missing-proof"]?.terminal, false)
        try await host.stop()
    }

    func testProducerDoneAndResolvedCheckpointWithoutExecuted() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let provider = TestExecProvider()
        let configuration = try fixture.configuration(execProvider: provider,
                                                      acceleratorNames: ["rg"])
        let engine = MockEngine(worker: MockWorker())
        let host = try makeHost(fixture, engine: engine, configuration: configuration)
        try await host.start()

        for (suffix, terminalType, action) in [
            ("done", "completed", nil as String?),
            ("resolved", "resolved", "backfilled-done" as String?),
        ] {
            let sessionID = "checkpoint-\(suffix)"
            let toolKey = "xl1-" + String(repeating: suffix == "done" ? "6" : "7", count: 32)
            let callID = "call-\(suffix)"
            let dispatch = try await engine.worker.sendJournal(
                sessionID: sessionID,
                record: producerJournalRecord("dispatched", key: toolKey, callID: callID))
            try await engine.worker.waitForJournalAck(sessionID: sessionID, jseq: dispatch)
            let mseq = try await engine.worker.writeFile(
                path: "/dsh/workspace/\(suffix)-input.txt", data: Data(suffix.utf8))
            try await engine.worker.waitForAck(mseq)
            let execID = "exec-\(suffix)"
            let idemKey = String(repeating: suffix == "done" ? "8" : "9", count: 64)
            try await engine.worker.requestExec(execID: execID, idemKey: idemKey,
                                                argv: ["rg", suffix], journalKey: toolKey,
                                                requiresMseq: mseq)
            try await engine.worker.waitForExecEvent(execID, type: "exit")

            let terminal = try await engine.worker.sendJournal(
                sessionID: sessionID,
                record: producerJournalRecord(terminalType, key: toolKey,
                                              callID: callID, action: action))
            try await engine.worker.waitForJournalAck(sessionID: sessionID, jseq: terminal)
            let stepMachine = try StepMachine(root: fixture.workspace)
            let record = await stepMachine.record(sessionID: sessionID, stepKey: toolKey)
            XCTAssertEqual(record?.state, .journaled)
            XCTAssertEqual(record?.checkpointJseq, terminal)
            XCTAssertEqual(record?.completionJseq, terminal)
        }
        XCTAssertEqual(provider.runCount, 2)
        try await host.stop()
    }

    func testTypeOnlyDoneAndValidDoneWithoutExecProofCannotCheckpoint() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let provider = GatedExecProvider()
        let configuration = try fixture.configuration(execProvider: provider,
                                                      acceleratorNames: ["rg"])
        let engine = MockEngine(worker: MockWorker())
        let host = try makeHost(fixture, engine: engine, configuration: configuration)
        try await host.start()
        defer { provider.finish() }

        let sessionID = "missing-exec-proof-session"
        let toolKey = "xl1-" + String(repeating: "8", count: 32)
        let callID = "missing-proof-call"
        let dispatch = try await engine.worker.sendJournal(
            sessionID: sessionID,
            record: producerJournalRecord("dispatched", key: toolKey, callID: callID))
        try await engine.worker.waitForJournalAck(sessionID: sessionID, jseq: dispatch)
        let mseq = try await engine.worker.writeFile(
            path: "/dsh/workspace/missing-proof.txt", data: Data("pending".utf8))
        try await engine.worker.waitForAck(mseq)
        try await engine.worker.requestExec(execID: "exec-missing-proof",
                                            idemKey: String(repeating: "a", count: 64),
                                            argv: ["rg", "pending"], journalKey: toolKey,
                                            requiresMseq: mseq)
        try await engine.worker.waitForExecEvent("exec-missing-proof", type: "start")

        let fake = try await engine.worker.sendJournal(
            sessionID: sessionID, record: ["type": "completed", "key": toolKey])
        try await engine.worker.waitForJournalAck(sessionID: sessionID, jseq: fake)
        let afterFake = try StepMachine(root: fixture.workspace)
        let fakeRecord = await afterFake.record(sessionID: sessionID, stepKey: toolKey)
        XCTAssertNil(fakeRecord?.checkpointJseq)

        let unknownResolution = try await engine.worker.sendJournal(
            sessionID: sessionID,
            record: producerJournalRecord("resolved", key: toolKey, callID: callID,
                                          action: "invented-action"))
        try await engine.worker.waitForJournalAck(sessionID: sessionID,
                                                  jseq: unknownResolution)
        let afterUnknown = try StepMachine(root: fixture.workspace)
        let unknownRecord = await afterUnknown.record(sessionID: sessionID, stepKey: toolKey)
        XCTAssertNil(unknownRecord?.checkpointJseq)

        let done = try await engine.worker.sendJournal(
            sessionID: sessionID,
            record: producerJournalRecord("completed", key: toolKey, callID: callID))
        try await engine.worker.waitForJournalAck(sessionID: sessionID, jseq: done)
        let afterDone = try StepMachine(root: fixture.workspace)
        let record = await afterDone.record(sessionID: sessionID, stepKey: toolKey)
        XCTAssertEqual(record?.checkpointJseq, done)
        XCTAssertEqual(record?.completionJseq, done)
        XCTAssertNotEqual(record?.state, .journaled,
                          "a valid result cannot replace missing durable exec terminal/WAL proof")
        XCTAssertEqual(record?.execEvidence?["exec-missing-proof"]?.terminal, false)
        try await host.stop()
    }

    func testSecondExecLedgerFailureBlocksToolCompletionDespiteFirstExecProof() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let provider = TestExecProvider()
        let configuration = try fixture.configuration(execProvider: provider,
                                                      acceleratorNames: ["rg"])
        let engine = MockEngine(worker: MockWorker())
        let host = try makeHost(fixture, engine: engine, configuration: configuration)
        let sessionID = "multi-exec-failure-session"
        let toolKey = "xl1-" + String(repeating: "4", count: 32)
        let firstIdemKey = String(repeating: "a", count: 64)
        let secondIdemKey = String(repeating: "b", count: 64)

        try await host.start()
        let dispatch = try await engine.worker.sendJournal(
            sessionID: sessionID, record: ["type": "dispatched", "key": toolKey])
        try await engine.worker.waitForJournalAck(sessionID: sessionID, jseq: dispatch)
        let firstMseq = try await engine.worker.writeFile(
            path: "/dsh/workspace/first.txt", data: Data("first".utf8))
        try await engine.worker.waitForAck(firstMseq)
        try await engine.worker.requestExec(execID: "multi-exec-1", idemKey: firstIdemKey,
                                            argv: ["rg", "first"], journalKey: toolKey,
                                            requiresMseq: firstMseq)
        try await engine.worker.waitForExecEvent("multi-exec-1", type: "exit")

        // Fail only the second idempotency entry. The first entry and its
        // successful exit/WAL proof remain intact on disk.
        let secondEntryPath = fixture.workspace.appendingPathComponent("exec",
                                                                       isDirectory: true)
            .appendingPathComponent(secondIdemKey + ".json", isDirectory: true)
        try FileManager.default.createDirectory(at: secondEntryPath,
                                                withIntermediateDirectories: false)
        let secondMseq = try await engine.worker.writeFile(
            path: "/dsh/workspace/second.txt", data: Data("second".utf8))
        try await engine.worker.waitForAck(secondMseq)
        try await engine.worker.requestExec(execID: "multi-exec-2", idemKey: secondIdemKey,
                                            argv: ["rg", "second"], journalKey: toolKey,
                                            requiresMseq: secondMseq)
        try await engine.worker.waitForExecEvent("multi-exec-2", type: "exit")

        let executed = try await engine.worker.sendJournal(
            sessionID: sessionID, record: ["type": "executed", "key": toolKey])
        try await engine.worker.waitForJournalAck(sessionID: sessionID, jseq: executed)
        let completed = try await engine.worker.sendJournal(
            sessionID: sessionID, record: ["type": "completed", "key": toolKey])
        try await engine.worker.waitForJournalAck(sessionID: sessionID, jseq: completed)

        let stepMachine = try StepMachine(root: fixture.workspace)
        let failed = await stepMachine.record(sessionID: sessionID, stepKey: toolKey)
        XCTAssertNotEqual(failed?.state, .journaled,
                          "exec 1 cannot conceal exec 2's missing durable ledger events")
        XCTAssertEqual(failed?.execEvidence?.count, 2)
        XCTAssertEqual(failed?.execEvidence?["multi-exec-1"]?.terminal, true)
        XCTAssertEqual(failed?.execEvidence?["multi-exec-1"]?.walAcknowledged, true)
        XCTAssertEqual(failed?.execEvidence?["multi-exec-2"]?.persistenceFailed, true)
        XCTAssertEqual(provider.runCount, 2)
        try FileManager.default.removeItem(at: secondEntryPath)
        try await host.stop()
    }

    func testSecondExecPreflightReleasesOnlyItsReservation() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let provider = TestExecProvider()
        let configuration = try fixture.configuration(execProvider: provider,
                                                      acceleratorNames: ["rg"])
        let engine = MockEngine(worker: MockWorker())
        let host = try makeHost(fixture, engine: engine, configuration: configuration)
        let sessionID = "multi-exec-preflight-session"
        let toolKey = "xl1-" + String(repeating: "5", count: 32)

        try await host.start()
        let dispatch = try await engine.worker.sendJournal(
            sessionID: sessionID, record: ["type": "dispatched", "key": toolKey])
        try await engine.worker.waitForJournalAck(sessionID: sessionID, jseq: dispatch)
        let mseq = try await engine.worker.writeFile(
            path: "/dsh/workspace/first.txt", data: Data("first".utf8))
        try await engine.worker.waitForAck(mseq)
        try await engine.worker.requestExec(execID: "preflight-first",
                                            idemKey: String(repeating: "c", count: 64),
                                            argv: ["rg", "first"], journalKey: toolKey,
                                            requiresMseq: mseq)
        try await engine.worker.waitForExecEvent("preflight-first", type: "exit")
        try await engine.worker.requestExec(execID: "preflight-second",
                                            idemKey: String(repeating: "d", count: 64),
                                            argv: ["jaq", "unsupported"],
                                            journalKey: toolKey)
        try await engine.worker.waitForExecEvent("preflight-second", type: "error")

        let executed = try await engine.worker.sendJournal(
            sessionID: sessionID, record: ["type": "executed", "key": toolKey])
        try await engine.worker.waitForJournalAck(sessionID: sessionID, jseq: executed)
        let completed = try await engine.worker.sendJournal(
            sessionID: sessionID, record: ["type": "completed", "key": toolKey])
        try await engine.worker.waitForJournalAck(sessionID: sessionID, jseq: completed)

        let stepMachine = try StepMachine(root: fixture.workspace)
        let record = await stepMachine.record(sessionID: sessionID, stepKey: toolKey)
        XCTAssertEqual(record?.state, .journaled)
        XCTAssertEqual(record?.execEvidence?.count, 1)
        XCTAssertEqual(record?.execEvidence?["preflight-first"]?.terminal, true)
        XCTAssertNil(record?.execEvidence?["preflight-second"])
        XCTAssertEqual(provider.runCount, 1)
        try await host.stop()
    }

    func testExecDedupConflictReplaysNothing() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let provider = TestExecProvider()
        let configuration = try fixture.configuration(execProvider: provider,
                                                      acceleratorNames: ["rg"])
        let engine = MockEngine(worker: MockWorker())
        let host = try makeHost(fixture, engine: engine, configuration: configuration)
        try await host.start()

        let idemKey = String(repeating: "b", count: 64)
        try await engine.worker.requestExec(execID: "e1", idemKey: idemKey,
                                            argv: ["rg", "needle"])
        try await engine.worker.waitForExecEvent("e1", type: "exit")

        // Same key, different argv: D10 conflict, never another execution.
        try await engine.worker.requestExec(execID: "e2", idemKey: idemKey,
                                            argv: ["rg", "other"])
        try await waitUntil {
            await engine.worker.execEvents().contains {
                $0.execID == "e2" && $0.type == "error"
            }
        }
        XCTAssertEqual(provider.runCount, 1)
        try await host.stop()
    }

    func testPreflightExecErrorDoesNotPersistDedupEntry() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let provider = TestExecProvider()
        let configuration = try fixture.configuration(execProvider: provider,
                                                      acceleratorNames: ["rg"])
        let engine = MockEngine(worker: MockWorker())
        let host = try makeHost(fixture, engine: engine, configuration: configuration)
        try await host.start()

        // `jaq` is not advertised, so the landed handler answers with a
        // terminal error before any process starts (exec.md §2 Admission).
        let sessionID = "preflight-session"
        let toolKey = "xl1-" + String(repeating: "3", count: 32)
        let dispatch = try await engine.worker.sendJournal(
            sessionID: sessionID, record: ["type": "dispatched", "key": toolKey])
        try await engine.worker.waitForJournalAck(sessionID: sessionID, jseq: dispatch)
        let idemKey = String(repeating: "c", count: 64)
        try await engine.worker.requestExec(execID: "e1", idemKey: idemKey,
                                            argv: ["jaq", "needle"], journalKey: toolKey)
        try await engine.worker.waitForExecEvent("e1", type: "error")
        let completed = try await engine.worker.sendJournal(
            sessionID: sessionID, record: ["type": "completed", "key": toolKey])
        try await engine.worker.waitForJournalAck(sessionID: sessionID, jseq: completed)
        let preflightStepMachine = try StepMachine(root: fixture.workspace)
        let preflightRecord = await preflightStepMachine.record(sessionID: sessionID,
                                                                 stepKey: toolKey)
        XCTAssertEqual(preflightRecord?.state, .journaled,
                       "preflight rejection must release the request reservation")
        XCTAssertNil(preflightRecord?.execID)
        let diagnostics = await host.diagnostics()
        XCTAssertEqual(diagnostics.sideEffectEntries, 0,
                       "a preflight error must not enter the dedup table")
        XCTAssertEqual(provider.runCount, 0)
        try await host.stop()
    }

    func testExecLedgerPersistenceFailureIsObservable() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let provider = TestExecProvider()
        let configuration = try fixture.configuration(execProvider: provider,
                                                      acceleratorNames: ["rg"])
        let engine = MockEngine(worker: MockWorker())
        let host = try makeHost(fixture, engine: engine, configuration: configuration)
        try await host.start()
        let events = host.eventStream()
        let sessionID = "ledger-failure-session"
        let toolKey = "xl1-" + String(repeating: "2", count: 32)
        let dispatch = try await engine.worker.sendJournal(
            sessionID: sessionID, record: ["type": "dispatched", "key": toolKey])
        try await engine.worker.waitForJournalAck(sessionID: sessionID, jseq: dispatch)

        // Replace the ledger directory with a regular file: every write to
        // `exec/<idem_key>.json` now fails, while the exec itself can run.
        let ledgerDirectory = fixture.workspace.appendingPathComponent("exec",
                                                                       isDirectory: true)
        try FileManager.default.removeItem(at: ledgerDirectory)
        try Data("not a directory".utf8).write(to: ledgerDirectory)

        let requiredMseq = try await engine.worker.writeFile(
            path: "/dsh/workspace/ledger-failure.txt", data: Data("input".utf8))
        try await engine.worker.waitForAck(requiredMseq)
        let idemKey = String(repeating: "d", count: 64)
        try await engine.worker.requestExec(execID: "ledger-fail", idemKey: idemKey,
                                            argv: ["rg", "needle"], journalKey: toolKey,
                                            requiresMseq: requiredMseq)
        // The live stream must still reach the Worker (fail loud, not stall).
        try await engine.worker.waitForExecEvent("ledger-fail", type: "exit")
        XCTAssertEqual(provider.runCount, 1)

        // The failure is published on the single ordered event stream.
        let sawError = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask {
                for await event in events {
                    if case .error(let message) = event, message.contains("ledger") {
                        return true
                    }
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        XCTAssertTrue(sawError, "a ledger persistence failure must be fail loud")

        let diagnostics = await host.diagnostics()
        let ledgerError = try XCTUnwrap(diagnostics.ledgerPersistenceError)
        XCTAssertTrue(ledgerError.contains("prepareExec"), ledgerError)
        let completed = try await engine.worker.sendJournal(
            sessionID: sessionID, record: ["type": "completed", "key": toolKey])
        try await engine.worker.waitForJournalAck(sessionID: sessionID, jseq: completed)
        let stepMachine = try StepMachine(root: fixture.workspace)
        let failedProjection = await stepMachine.record(sessionID: sessionID,
                                                        stepKey: toolKey)
        XCTAssertNotEqual(failedProjection?.state, .journaled,
                          "a failed ledger write must not become exit/WAL evidence")
        XCTAssertNotNil(failedProjection?.execID,
                        "the exact request association prevents false worker-local completion")
        try await host.stop()
    }

    func testExecLedgerAppendFailureIsObservable() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let provider = GatedExecProvider()
        let configuration = try fixture.configuration(execProvider: provider,
                                                      acceleratorNames: ["rg"])
        let engine = MockEngine(worker: MockWorker())
        let host = try makeHost(fixture, engine: engine, configuration: configuration)
        try await host.start()

        let idemKey = String(repeating: "e", count: 64)
        try await engine.worker.requestExec(execID: "ledger-append", idemKey: idemKey,
                                            argv: ["rg", "needle"])
        try await engine.worker.waitForExecEvent("ledger-append", type: "start")
        try await waitUntil { provider.didStart }

        // The `start` event (and with it the intent entry) is already on disk.
        // Break the directory now so the later stdout/exit appends fail.
        let ledgerDirectory = fixture.workspace.appendingPathComponent("exec",
                                                                       isDirectory: true)
        try FileManager.default.removeItem(at: ledgerDirectory)
        try Data("not a directory".utf8).write(to: ledgerDirectory)

        provider.emit(.stdout(seq: 1, data: Data("out\n".utf8)))
        provider.emit(.exit(code: 0, signal: nil, truncated: false))
        provider.finish()
        try await engine.worker.waitForExecEvent("ledger-append", type: "exit")

        let diagnostics = await host.diagnostics()
        let ledgerError = try XCTUnwrap(diagnostics.ledgerPersistenceError)
        XCTAssertTrue(ledgerError.contains("appendExecEvent"), ledgerError)
        try await host.stop()
    }

    func testParkWaitsForInFlightAPIRequestBeforeParking() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let engine = MockEngine(worker: MockWorker())
        let configuration = try fixture.configuration(drainDeadline: 10)
        let host = try makeHost(fixture, engine: engine, configuration: configuration)
        try await host.start()

        let transport = try await host.makeTransport()
        let call = Task {
            try await transport.call("session/hang", args: JSONValue.object([:]))
        }
        try await engine.worker.waitForHangingRequest()
        // Let the transport register the exchange with the drain tracker.
        try await Task.sleep(nanoseconds: 50_000_000)

        let park = Task { try await host.park() }
        try await waitUntil {
            let diagnostics = await host.diagnostics()
            return diagnostics.hostState == .draining
                && diagnostics.admission == .closed
        }
        let during = await host.diagnostics()
        XCTAssertEqual(during.hostState, .draining)
        XCTAssertEqual(during.admission, .closed)

        try await engine.worker.respondToHanging(sessionID: "drained")
        let value = try await call.value
        XCTAssertEqual(value["sessionId"]?.testString, "drained")
        try await park.value
        let state = await host.state
        XCTAssertEqual(state, .stopped)
        try await host.stop()
    }

    // MARK: - D24 planned restart, environment and Backoff

    func testPlannedRestartRebuildsOverlayAndWorkerAndReopensAdmission() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let engine = MockEngine(worker: MockWorker())
        let host = try makeHost(fixture, engine: engine)
        try await host.start()

        let before = await host.diagnostics()
        _ = try await engine.worker.writeFile(
            path: "/dsh/workspace/persist.txt", data: Data("kept".utf8))
        try await engine.worker.waitForAck(1)
        let materialized = fixture.materializedFile("workspace/persist.txt")
        try await waitUntil { (try? Data(contentsOf: materialized)) != nil }

        try await host.plannedRestart(reason: "host-test")

        let state = await host.state
        XCTAssertEqual(state, .running)
        let diagnostics = await host.diagnostics()
        XCTAssertEqual(diagnostics.hostState, .running)
        XCTAssertEqual(diagnostics.admission, .open)
        XCTAssertEqual(engine.bootCount, 2,
                       "D24: plannedRestart rebuilds the Worker engine")
        XCTAssertGreaterThan(diagnostics.workerHelloCount, before.workerHelloCount)
        XCTAssertTrue(diagnostics.materializedUptoMseq >= 1,
                      "the planned restart keeps the materialized workspace")

        let overlay = fixture.workspace
            .appendingPathComponent("overlay-\(before.bootID).tar")
        let bytes = try Data(contentsOf: overlay)
        XCTAssertEqual([UInt8](bytes.prefix(2)), [0x1f, 0x8b],
                       "D21: the rebuilt boot overlay is gzip")
        XCTAssertNotNil((try? Data(contentsOf: materialized)),
                        "the restart must not drop acknowledged VFS bytes")

        // The new Worker connection serves the remote API again.
        let harness = try await host.harness()
        let session = try await harness.openSession(HarnessSessionRequest())
        XCTAssertEqual(session.id, "mock-session")
        try await host.stop()
    }

    func testPlannedRestartPublishesExactlyOneRestartedEvent() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let engine = MockEngine(worker: MockWorker())
        let host = try makeHost(fixture, engine: engine)
        try await host.start()
        let recorder = RestartEventRecorder(host.eventStream())
        defer { recorder.stop() }

        try await host.plannedRestart(reason: "single-event")

        try await waitUntil(timeout: 10) { recorder.reports.isEmpty == false }
        // The engine's event and the restart call's return value race; let the
        // loser reach the subscription before counting.
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(recorder.reports.count, 1,
                       "a planned restart must publish exactly one .restarted event")
        XCTAssertEqual(recorder.reports.first?.reason, .planned)
        let state = await host.state
        XCTAssertEqual(state, .running)
        try await host.stop()
    }

    func testPlannedRestartWaitsForInFlightAPIRequests() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let engine = MockEngine(worker: MockWorker())
        let configuration = try fixture.configuration(drainDeadline: 10)
        let host = try makeHost(fixture, engine: engine, configuration: configuration)
        try await host.start()

        let transport = try await host.makeTransport()
        let call = Task {
            try await transport.call("session/hang", args: JSONValue.object([:]))
        }
        try await engine.worker.waitForHangingRequest()
        try await Task.sleep(nanoseconds: 50_000_000)

        let restart = Task { try await host.plannedRestart(reason: "drain") }
        try await waitUntil {
            let diagnostics = await host.diagnostics()
            return diagnostics.state == .draining && diagnostics.admission == .closed
        }
        // The old Worker connection is still serving the hung exchange; the
        // restart must not have rebuilt the engine yet.
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(engine.bootCount, 1,
                       "D24: plannedRestart drains before rebuilding the Worker")

        try await engine.worker.respondToHanging(sessionID: "after-restart")
        let value = try await call.value
        XCTAssertEqual(value["sessionId"]?.testString, "after-restart")
        try await restart.value
        let state = await host.state
        XCTAssertEqual(state, .running)
        XCTAssertEqual(engine.bootCount, 2)
        try await host.stop()
    }

    func testPlannedRestartProceedsAfterTheDrainWindow() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let engine = MockEngine(worker: MockWorker())
        let configuration = try fixture.configuration(drainDeadline: 0.3)
        let host = try makeHost(fixture, engine: engine, configuration: configuration)
        try await host.start()

        let transport = try await host.makeTransport()
        let call = Task { () -> JSONValue? in
            try? await transport.call("session/hang", args: JSONValue.object([:]))
        }
        try await engine.worker.waitForHangingRequest()
        try await Task.sleep(nanoseconds: 50_000_000)

        let started = Date()
        try await host.plannedRestart(reason: "deadline")
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertGreaterThanOrEqual(elapsed, 0.2,
                                    "D24: the full drain window is observed")
        let state = await host.state
        XCTAssertEqual(state, .running)
        XCTAssertEqual(engine.bootCount, 2)
        // The initiator re-issues the still-open request on the new connection
        // (D2); the scripted Worker holds it again, so cancel before teardown.
        call.cancel()
        try await host.stop()
    }

    func testHostInjectsWorkerEnvironmentAndKeepsAppOverrides() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        var configuration = try fixture.configuration()
        configuration.engine.environment = [
            "APP_HOME": "/dsh/home",
            PhoneDSHWorkerEnvironment.gatewayURL: "http://app-override.invalid",
        ]
        let engine = MockEngine(worker: MockWorker())
        let host = try makeHost(fixture, engine: engine, configuration: configuration)
        try await host.start()

        let engineConfiguration = try XCTUnwrap(engine.lastConfiguration)
        let environment = engineConfiguration.environment
        let token = engineConfiguration.token
        XCTAssertEqual(token.isEmpty, false)
        XCTAssertEqual(environment[PhoneDSHWorkerEnvironment.launchToken], token)
        XCTAssertEqual(environment[PhoneDSHWorkerEnvironment.channelToken], token)
        let port = try XCTUnwrap(engineConfiguration.origin.port)
        XCTAssertEqual(environment[PhoneDSHWorkerEnvironment.channelURL],
                       "ws://127.0.0.1:\(port)/channel")
        XCTAssertEqual(environment["APP_HOME"], "/dsh/home")
        XCTAssertEqual(environment[PhoneDSHWorkerEnvironment.gatewayURL],
                       "http://app-override.invalid",
                       "an explicit App entry overrides the injected value")
        // The injected launch token reaches the Worker in the page's env input.
        let items = try XCTUnwrap(
            URLComponents(url: try engineConfiguration.makePageURL(),
                          resolvingAgainstBaseURL: false)?.queryItems)
        let envJSON = try XCTUnwrap(items.first(where: { $0.name == "env" })?.value)
        XCTAssertTrue(envJSON.contains(PhoneDSHWorkerEnvironment.launchToken))
        try await host.stop()
    }

    func testStartBootsAPersistedBackoffAfterTheDeadline() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        try writePersistedHostState(fixture,
                                    state: "backoff",
                                    updatedAt: Date().addingTimeInterval(-3600))
        let engine = MockEngine(worker: MockWorker())
        let host = try makeHost(fixture, engine: engine)
        try await host.start()
        let state = await host.state
        XCTAssertEqual(state, .running,
                       "D24: a Backoff past its deadline may start")
        let diagnostics = await host.diagnostics()
        XCTAssertEqual(diagnostics.admission, .open)
        try await host.stop()
    }

    func testStartBeforeThePersistedBackoffDeadlineIsRefusedWithoutFailing() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let updatedAt = Date()
        try writePersistedHostState(fixture, state: "backoff", updatedAt: updatedAt)
        let engine = MockEngine(worker: MockWorker())
        let host = try makeHost(fixture, engine: engine)
        do {
            try await host.start()
            XCTFail("D24: a fresh Backoff must not start before its deadline")
        } catch let error as PhoneDSHError {
            guard case .backoffNotElapsed(let deadline) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertGreaterThan(deadline, updatedAt)
        }
        let state = await host.state
        XCTAssertEqual(state, .stopped,
                       "a Backoff wait is not a fail-loud state")
        let diagnostics = await host.diagnostics()
        XCTAssertNil(diagnostics.lastError)
        XCTAssertEqual(engine.bootCount, 0)
    }

    func testUserResetIsTheD24NameOfReset() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let engine = MockEngine(worker: MockWorker(), lockdown: true)
        let host = try makeHost(fixture, engine: engine)
        do {
            try await host.start()
            XCTFail("expected lockdownMode")
        } catch {}
        engine.setLockdown(false)
        try await host.userReset()
        let state = await host.state
        XCTAssertEqual(state, .running)
        try await host.stop()
    }

    func testPageAssetsAuthenticateWithTheLaunchCookie() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let engine = MockEngine(worker: MockWorker())
        let host = try makeHost(fixture, engine: engine)
        try await host.start()

        let engineConfiguration = try XCTUnwrap(engine.lastConfiguration)
        let pageURL = try engineConfiguration.makePageURL()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (_, pageResponse) = try await session.data(from: pageURL)
        XCTAssertEqual((pageResponse as? HTTPURLResponse)?.statusCode, 200)
        let setCookie = (pageResponse as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Set-Cookie")
        XCTAssertNotNil(setCookie, "D22: the page response seeds the cookie")

        // The page requests boot.js / worker-entry.js relative to itself, with
        // no query token; the cookie set above authenticates them.
        var relative = try XCTUnwrap(
            URLComponents(url: pageURL, resolvingAgainstBaseURL: false))
        relative.path = engineConfiguration.workerPath
        relative.query = nil
        let scriptURL = try XCTUnwrap(relative.url)
        let (script, scriptResponse) = try await session.data(from: scriptURL)
        XCTAssertEqual((scriptResponse as? HTTPURLResponse)?.statusCode, 200,
                       "D22: page-relative assets must not need a token rewrite")
        XCTAssertEqual(String(decoding: script, as: UTF8.self), "// worker entry")
        try await host.stop()
    }

    /// Writes a subagent journal with the wall-clock timestamp of the old
    /// Worker shutdown window, used by the planned-restart epoch regression.
    private static func writeShutdownChildJournal(at url: URL, id: String,
                                                  parent: String) throws {
        let createdAt = Int64((Date().timeIntervalSince1970 * 1000).rounded())
        func record(_ type: String, _ time: Int64,
                    _ fields: [String: Any],
                    data: [String: Any]? = nil) throws -> String {
            var object = fields
            object["type"] = type
            object["time"] = time
            if let data { object["data"] = data }
            let encoded = try JSONSerialization.data(withJSONObject: object,
                                                     options: [.sortedKeys])
            return String(decoding: encoded, as: UTF8.self) + "\n"
        }
        let header: [String: Any] = [
            "id": id,
            "createdAt": createdAt,
            "cwd": "/dsh/workspace",
            "version": 4,
            "parentSession": parent,
            "origin": "subagent",
            "delegationDepth": 1,
        ]
        var text = try record("session", createdAt, header)
        text += try record("turn/start", createdAt + 1, [:], data: ["turn": 1])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// One DSH-shaped journal record for the host verification tests.
    private func sessionRecord(type: String, time: Int64,
                               fields: [String: Any] = [:],
                               data: [String: Any]? = nil) throws -> String {
        var object = fields
        object["type"] = type
        object["time"] = time
        if let data { object["data"] = data }
        let encoded = try JSONSerialization.data(withJSONObject: object,
                                                 options: [.sortedKeys])
        return String(decoding: encoded, as: UTF8.self) + "\n"
    }

    /// A root or subagent journal with one turn; `closeTurn == false` leaves
    /// the same open `turn/start` the G2-F01 child regression produced.
    private func sessionJournalText(id: String, createdAt: Int64,
                                    parent: String? = nil,
                                    closeTurn: Bool) throws -> String {
        var header: [String: Any] = [
            "id": id,
            "createdAt": createdAt,
            "cwd": "/dsh/workspace",
            "version": 4,
        ]
        if let parent {
            header["parentSession"] = parent
            header["origin"] = "subagent"
            header["delegationDepth"] = 1
        }
        var text = try sessionRecord(type: "session", time: createdAt, fields: header)
        text += try sessionRecord(type: "turn/start", time: createdAt + 1,
                                  data: ["turn": 1])
        if closeTurn {
            text += try sessionRecord(
                type: "turn/end", time: createdAt + 2,
                data: ["turn": 1, "reason": ["kind": "completed"]])
        }
        return text
    }

    @discardableResult
    private func writeSessionJournal(_ fixture: FacadeFixture,
                                     worker: MockWorker,
                                     id: String,
                                     text: String) async throws -> URL {
        let path = "/dsh/home/sessions/--dsh-workspace--/\(id)/session.v4.jsonl"
        let mseq = try await worker.writeFile(path: path, data: Data(text.utf8))
        try await worker.waitForAck(mseq)
        let url = fixture.materializedFile(
            "home/sessions/--dsh-workspace--/\(id)/session.v4.jsonl")
        try await waitUntil { FileManager.default.fileExists(atPath: url.path) }
        return url
    }

    @discardableResult
    private func writeMaterializedSessionJournal(_ fixture: FacadeFixture,
                                                 id: String,
                                                 text: String) throws -> URL {
        let url = fixture.materializedFile(
            "home/sessions/--dsh-workspace--/\(id)/session.v4.jsonl")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func writePersistedHostState(_ fixture: FacadeFixture, state: String,
                                         updatedAt: Date) throws {
        let milliseconds = Int64((updatedAt.timeIntervalSince1970 * 1000).rounded())
        let object: [String: Any] = [
            "version": 1,
            "state": state,
            "updated_at_ms": milliseconds,
            "reason": "429",
        ]
        let data = try JSONSerialization.data(withJSONObject: object,
                                              options: [.sortedKeys])
        try data.write(to: fixture.workspace.appendingPathComponent("host-state.json"),
                       options: .atomic)
    }
}

/// Collects every `.restarted` report published on one host event subscription.
private final class RestartEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [WebEngineRestartReport] = []
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<PhoneDSHEvent>) {
        task = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                guard case .restarted(let report) = event else { continue }
                self.lock.lock()
                self.storage.append(report)
                self.lock.unlock()
            }
        }
    }

    var reports: [WebEngineRestartReport] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    deinit {
        task?.cancel()
    }
}
