// SPDX-License-Identifier: MIT
// PhoneDSHEngine tests: WKWebView boot, visibility, termination,
// restart, Lockdown detection, console capture and the informational JIT
// probe. All tests use a real WKWebView against a local Network.framework
// stub origin and wait on the main run loop with XCTest expectations.

import AppKit
import Foundation
import XCTest
import PhoneDSHEngine

final class WebEngineTests: XCTestCase {
    private var servers: [StubLoopbackServer] = []
    private var engines: [WebEngine] = []

    override func setUp() {
        super.setUp()
        onMain { _ = NSApplication.shared }
    }

    override func tearDown() {
        let engines = self.engines
        onMain {
            for engine in engines {
                engine.shutdown()
            }
        }
        self.engines.removeAll()
        for server in servers {
            server.stop()
        }
        servers.removeAll()
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeServer(mode: StubLoopbackServer.BootMode = .direct) throws
        -> StubLoopbackServer {
        let server = try StubLoopbackServer(bootMode: mode)
        try server.start()
        servers.append(server)
        return server
    }

    private func makeConfiguration(origin: URL, bootID: String? = nil,
                                   token: String = "test-token") -> WebEngineConfiguration {
        WebEngineConfiguration(origin: origin,
                               imagePath: "/image/base",
                               token: token,
                               bootID: bootID,
                               bootTimeout: 20)
    }

    @discardableResult
    private func makeEngine(configuration: WebEngineConfiguration,
                            lockdownModeProvider: (@Sendable () -> Bool)? = nil) -> WebEngine {
        let engine = onMain {
            WebEngine(configuration: configuration,
                      lockdownModeProvider: lockdownModeProvider)
        }
        engines.append(engine)
        return engine
    }

    /// Boots the worker and waits for ready plus the caller's expectations.
    private func boot(_ engine: WebEngine,
                      configuration: WebEngineConfiguration,
                      collector: EventCollector) throws -> WebEngineBootStatus {
        let ready = collector.expect("worker reports ready") { event in
            if case .bootReady(let status) = event {
                return status.state == .ready
            }
            return false
        }
        let finished = expectation(description: "bootWorker returned")
        let result = LockedBox<Result<Void, Error>>()
        let task = Task {
            do {
                try await engine.bootWorker(configuration)
                result.value = .success(())
            } catch {
                result.value = .failure(error)
            }
            finished.fulfill()
        }
        wait(for: [ready, finished], timeout: 30)
        withExtendedLifetime(task) {}
        if case .failure(let error)? = result.value {
            throw error
        }
        return try XCTUnwrap(engine.lastBootStatus)
    }

    private func runRestart(_ engine: WebEngine,
                            reason: WebEngineRestartReason) throws -> WebEngineRestartReport {
        let finished = expectation(description: "restart returned")
        let result = LockedBox<Result<WebEngineRestartReport, Error>>()
        let task = Task {
            do {
                result.value = .success(try await engine.restart(reason: reason))
            } catch {
                result.value = .failure(error)
            }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 30)
        withExtendedLifetime(task) {}
        switch try XCTUnwrap(result.value) {
        case .success(let report):
            return report
        case .failure(let error):
            throw error
        }
    }

    private func runProbe(_ engine: WebEngine) throws -> WebEngineJITProbeResult {
        let finished = expectation(description: "JIT probe returned")
        let result = LockedBox<Result<WebEngineJITProbeResult, Error>>()
        let task = Task {
            do {
                result.value = .success(try await engine.runJITProbe())
            } catch {
                result.value = .failure(error)
            }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 30)
        withExtendedLifetime(task) {}
        switch try XCTUnwrap(result.value) {
        case .success(let probe):
            return probe
        case .failure(let error):
            throw error
        }
    }

    private func bootID(in target: String) -> String? {
        URLComponents(string: "http://127.0.0.1" + target)?
            .queryItems?
            .first(where: { $0.name == "boot_id" })?
            .value
    }

    /// Pumps the main run loop while a Network.framework stub origin serves the
    /// page's DedicatedWorker heartbeat.
    private func waitForRecordedPath(_ server: StubLoopbackServer,
                                     prefix: String,
                                     timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if server.recordedPaths.contains(where: { $0.hasPrefix(prefix) }) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return server.recordedPaths.contains(where: { $0.hasPrefix(prefix) })
    }

    private func waitForRunLoop(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(until: min(deadline,
                                           Date().addingTimeInterval(0.05)))
        }
    }

    // MARK: - Boot

    func testBootLoadsPageReachesReadyAndCapturesConsole() throws {
        let server = try makeServer(mode: .direct)
        let expectedBootID = "00112233445566778899aabbccddeeff"
        let configuration = makeConfiguration(origin: server.baseURL,
                                              bootID: expectedBootID)
        let engine = makeEngine(configuration: configuration)
        let collector = EventCollector(engine.events)

        let loaded = collector.expect("navigation completed") { event in
            if case .loaded = event { return true }
            return false
        }
        let console = collector.expect("console line from the page") { event in
            if case .consoleLine(let line) = event {
                return line.text.contains("stub-boot:\(expectedBootID)")
            }
            return false
        }

        let status = try boot(engine, configuration: configuration, collector: collector)
        wait(for: [loaded, console], timeout: 5)

        XCTAssertEqual(status.state, .ready)
        XCTAssertEqual(status.bootID, expectedBootID)
        XCTAssertEqual(engine.lastBootStatus?.state, .ready)
        XCTAssertEqual(engine.terminationCount, 0)

        let paths = server.recordedPaths
        let page = try XCTUnwrap(paths.first(where: { $0.hasPrefix("/index.html") }))
        XCTAssertTrue(page.contains("token=test-token"))
        XCTAssertTrue(page.contains("boot_id=\(expectedBootID)"))
        XCTAssertTrue(page.contains("overlay="))
        XCTAssertTrue(paths.contains(where: { $0.hasPrefix("/boot.js") }))

        let queryItems = URLComponents(string: "http://127.0.0.1" + page)?.queryItems ?? []
        XCTAssertEqual(queryItems.filter { $0.name == "token" }.count, 1,
                       "D22: the page URL carries the launch token exactly once")
        let imageURL = try XCTUnwrap(queryItems.first(where: { $0.name == "image" })?.value)
        XCTAssertEqual(URLComponents(string: imageURL)?
            .queryItems?.first(where: { $0.name == "token" })?.value, "test-token")
        let overlayURL = try XCTUnwrap(queryItems.first(where: { $0.name == "overlay" })?.value)
        XCTAssertEqual(URLComponents(string: overlayURL)?
            .queryItems?.first(where: { $0.name == "token" })?.value, "test-token")
    }

    /// The host creates the engine from a placeholder configuration before it
    /// knows the bound loopback port, then boots it again with the real
    /// origin. The navigation policy must adopt that origin; otherwise the
    /// real `/static/index.html` is classified as external and cancelled.
    func testBootWorkerAdoptsBoundOriginFromPlaceholderEngine() throws {
        let server = try makeServer(mode: .direct)
        let placeholder = WebEngineConfiguration(
            origin: URL(string: "http://127.0.0.1:1")!,
            token: "placeholder-token")
        let engine = makeEngine(configuration: placeholder)
        let collector = EventCollector(engine.events)
        let bootID = "00112233445566778899aabbccddeeff"
        let configuration = makeConfiguration(origin: server.baseURL,
                                              bootID: bootID)

        let status = try boot(engine, configuration: configuration,
                              collector: collector)

        XCTAssertEqual(status.state, .ready)
        XCTAssertEqual(engine.lastBootStatus?.bootID, bootID)
        let origins = onMain { (bridge: engine.fileBridge?.loopbackOrigin,
                                engine: engine.configuration.origin) }
        XCTAssertEqual(origins.bridge, server.baseURL)
        XCTAssertEqual(origins.engine, server.baseURL)
        let pageURL = try XCTUnwrap(
            URL(string: server.baseURL.absoluteString + "/static/index.html"))
        XCTAssertEqual(
            WebEngineFileBridge.route(for: pageURL, loopbackOrigin: server.baseURL),
            .web)
        XCTAssertTrue(server.recordedPaths.contains { $0.hasPrefix("/index.html") })
    }

    func testPageURLCarriesTheLaunchTokenExactlyOnce() throws {
        let origin = try XCTUnwrap(URL(string: "http://127.0.0.1:4321"))
        let configuration = WebEngineConfiguration(origin: origin,
                                                   token: "one-shot-token",
                                                   bootID: "00112233445566778899aabbccddeeff")
        let url = try configuration.makePageURL()
        let items = try XCTUnwrap(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.filter { $0.name == "token" }.map(\.value),
                       ["one-shot-token"])
        XCTAssertEqual(url.path, "/index.html")
    }

    func testBootBridgeObservesW1TitleAndStatus() throws {
        let server = try makeServer(mode: .titleOnly)
        let configuration = makeConfiguration(origin: server.baseURL,
                                              bootID: "ffeeddccbbaa99887766554433221100")
        let engine = makeEngine(configuration: configuration)
        let collector = EventCollector(engine.events)
        let ready = collector.expect("title bridge reports ready") { event in
            if case .bootReady(let status) = event {
                return status.state == .ready && status.detail?.contains("DSH ready") == true
            }
            return false
        }

        let loaded = expectation(description: "load returned")
        let result = LockedBox<Error?>()
        let task = Task {
            do {
                try await engine.load(server.pageURL(token: "test-token",
                                                    bootID: "ffeeddccbbaa99887766554433221100"))
            } catch {
                result.value = error
            }
            loaded.fulfill()
        }
        wait(for: [loaded, ready], timeout: 30)
        withExtendedLifetime(task) {}
        XCTAssertNil(result.value)

        let status = try XCTUnwrap(engine.lastBootStatus)
        XCTAssertEqual(status.state, .ready)
        XCTAssertEqual(status.bootID, "ffeeddccbbaa99887766554433221100")
    }

    // MARK: - Visibility

    func testAttachProducesOnePointFrameInsideWindow() throws {
        let server = try makeServer()
        let engine = makeEngine(configuration: makeConfiguration(origin: server.baseURL))
        XCTAssertFalse(engine.isAttachedWithVisibleArea)

        let measured = onMain { () -> (attached: Bool, inWindow: Bool,
                                       descendant: Bool, width: CGFloat,
                                       height: CGFloat, alpha: CGFloat) in
            _ = NSApplication.shared
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 120, height: 90),
                                  styleMask: [.borderless],
                                  backing: .buffered,
                                  defer: false)
            window.isReleasedWhenClosed = false
            let host = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 90))
            window.contentView = host
            engine.attach(to: host)
            let values = (engine.isAttachedWithVisibleArea,
                          engine.view.window === window,
                          engine.view.isDescendant(of: host),
                          engine.view.frame.width,
                          engine.view.frame.height,
                          engine.view.alphaValue)
            window.close()
            return values
        }

        XCTAssertTrue(measured.attached)
        XCTAssertTrue(measured.inWindow)
        XCTAssertTrue(measured.descendant)
        XCTAssertEqual(measured.width, 1, accuracy: 0.0001)
        XCTAssertEqual(measured.height, 1, accuracy: 0.0001)
        XCTAssertEqual(measured.alpha, 0.01, accuracy: 0.0001)

        onMain { engine.detach() }
        XCTAssertFalse(engine.isAttachedWithVisibleArea)
    }

    // MARK: - Termination

    func testTerminationPublishesCountAndRecoveryReloadsFreshPage() throws {
        let server = try makeServer(mode: .direct)
        let firstBootID = "00112233445566778899aabbccddeeff"
        let configuration = makeConfiguration(origin: server.baseURL, bootID: firstBootID)
        let engine = makeEngine(configuration: configuration)
        let collector = EventCollector(engine.events)
        _ = try boot(engine, configuration: configuration, collector: collector)

        let terminated = collector.expect("termination event") { event in
            if case .terminated(let count) = event { return count == 1 }
            return false
        }
        onMain { engine.webViewWebContentProcessDidTerminate(engine.view) }
        wait(for: [terminated], timeout: 5)
        XCTAssertEqual(engine.terminationCount, 1)
        XCTAssertEqual(engine.lastBootStatus?.state, .booting)

        let restarted = collector.expect("recovery report") { event in
            if case .restarted(let report) = event {
                return report.reason == .webContentTerminated
                    && report.bootID != firstBootID
                    && report.durationSeconds > 0
            }
            return false
        }
        let readyAgain = collector.expect("ready after recovery") { event in
            if case .bootReady(let status) = event {
                return status.state == .ready && status.bootID != firstBootID
            }
            return false
        }
        let finished = expectation(description: "recoverFromTermination returned")
        let result = LockedBox<Result<WebEngineRestartReport, Error>>()
        let task = Task {
            do {
                result.value = .success(try await engine.recoverFromTermination())
            } catch {
                result.value = .failure(error)
            }
            finished.fulfill()
        }
        wait(for: [restarted, readyAgain, finished], timeout: 30)
        withExtendedLifetime(task) {}

        let report = try XCTUnwrap(result.value)
        guard case .success(let value) = report else {
            return XCTFail("recovery failed: \(report)")
        }
        XCTAssertEqual(value.reason, .webContentTerminated)
        XCTAssertGreaterThan(value.durationSeconds, 0)
        XCTAssertEqual(value.bootID, engine.lastBootStatus?.bootID)

        let pageRequests = server.recordedPaths.filter { $0.hasPrefix("/index.html") }
        XCTAssertEqual(pageRequests.count, 2)
        let bootIDs = pageRequests.compactMap(bootID(in:))
        XCTAssertEqual(bootIDs.count, 2)
        XCTAssertNotEqual(bootIDs.first, bootIDs.last)
    }

    // MARK: - Handoff Worker termination

    /// Real WKWebView regression: `terminateWorker()` navigates the live page
    /// to `about:blank`, which destroys its DedicatedWorker. The Worker's
    /// heartbeat is observed before the call and must stop afterwards; the
    /// engine does not start a replacement page.
    func testTerminateWorkerDestroysDedicatedWorkerAndLeavesAboutBlank() throws {
        let server = try makeServer(mode: .dedicatedWorker)
        let configuration = makeConfiguration(
            origin: server.baseURL,
            bootID: "00112233445566778899aabbccddeeff")
        let engine = makeEngine(configuration: configuration)
        let collector = EventCollector(engine.events)
        _ = try boot(engine, configuration: configuration, collector: collector)

        XCTAssertTrue(waitForRecordedPath(server, prefix: "/worker.js"),
                      "the page must start its DedicatedWorker")
        XCTAssertTrue(waitForRecordedPath(server, prefix: "/worker-ping"),
                      "the DedicatedWorker heartbeat must run before termination")

        let finished = expectation(description: "terminateWorker returned")
        let result = LockedBox<Result<Void, Error>>()
        let task = Task {
            do {
                try await engine.terminateWorker()
                result.value = .success(())
            } catch {
                result.value = .failure(error)
            }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 30)
        withExtendedLifetime(task) {}
        if case .failure(let error)? = result.value {
            throw error
        }

        let pageURL = onMain { engine.view.url?.absoluteString }
        XCTAssertEqual(pageURL, "about:blank")
        XCTAssertEqual(engine.lastBootStatus?.state, .booting)
        XCTAssertEqual(engine.terminationCount, 0,
                       "an intentional termination is not a WebContent crash")
        let pageRequests = server.recordedPaths.filter { $0.hasPrefix("/index.html") }
        XCTAssertEqual(pageRequests.count, 1,
                       "terminateWorker must not boot a replacement page")

        // A fetch may already be in flight when the navigation commits. Let
        // that drain, then require the heartbeat to stay stopped.
        waitForRunLoop(0.3)
        let settledPings = server.recordedPaths.filter {
            $0.hasPrefix("/worker-ping")
        }.count
        waitForRunLoop(0.6)
        let finalPings = server.recordedPaths.filter {
            $0.hasPrefix("/worker-ping")
        }.count
        XCTAssertEqual(finalPings, settledPings,
                       "the old DedicatedWorker must be destroyed")
    }

    // MARK: - Planned restart

    func testRestartReloadsAndReportsColdStartDuration() throws {
        let server = try makeServer(mode: .direct)
        let firstBootID = "00112233445566778899aabbccddeeff"
        let configuration = makeConfiguration(origin: server.baseURL, bootID: firstBootID)
        let engine = makeEngine(configuration: configuration)
        let collector = EventCollector(engine.events)
        _ = try boot(engine, configuration: configuration, collector: collector)

        let restarted = collector.expect("planned restart report") { event in
            if case .restarted(let report) = event {
                return report.reason == .planned && report.bootID != firstBootID
            }
            return false
        }
        let readyAgain = collector.expect("ready after planned restart") { event in
            if case .bootReady(let status) = event {
                return status.state == .ready && status.bootID != firstBootID
            }
            return false
        }
        let report = try runRestart(engine, reason: .planned)
        wait(for: [restarted, readyAgain], timeout: 5)

        XCTAssertEqual(report.reason, .planned)
        XCTAssertNotEqual(report.bootID, firstBootID)
        XCTAssertTrue(WebEngineConfiguration.isValidBootID(report.bootID))
        XCTAssertGreaterThan(report.durationSeconds, 0)
        XCTAssertEqual(engine.lastBootStatus?.bootID, report.bootID)

        let pageRequests = server.recordedPaths.filter { $0.hasPrefix("/index.html") }
        XCTAssertEqual(pageRequests.count, 2)
        let bootIDs = pageRequests.compactMap(bootID(in:))
        XCTAssertEqual(Set(bootIDs).count, 2)
    }

    // MARK: - Lockdown

    func testLockdownModeFlagIsSurfacedAsCapability() throws {
        let server = try makeServer()
        let configuration = makeConfiguration(origin: server.baseURL)

        let enabled = makeEngine(configuration: configuration,
                                 lockdownModeProvider: { true })
        XCTAssertTrue(enabled.isLockdownModeEnabled)
        XCTAssertTrue(enabled.capabilities.lockdownModeEnabled)
        XCTAssertFalse(enabled.capabilities.isLocalHarnessAvailable)

        let disabled = makeEngine(configuration: configuration,
                                  lockdownModeProvider: { false })
        XCTAssertFalse(disabled.isLockdownModeEnabled)
        XCTAssertFalse(disabled.capabilities.lockdownModeEnabled)
        XCTAssertTrue(disabled.capabilities.isLocalHarnessAvailable)

        let systemRead = makeEngine(configuration: configuration)
        let webKitValue = onMain {
            systemRead.view.configuration.defaultWebpagePreferences.isLockdownModeEnabled
        }
        XCTAssertEqual(systemRead.isLockdownModeEnabled, webKitValue)
        XCTAssertEqual(systemRead.capabilities.lockdownModeEnabled, webKitValue)
    }

    // MARK: - JIT probe

    func testJITProbeStoresBaselineAndReportsRatio() throws {
        let server = try makeServer(mode: .direct)
        let configuration = makeConfiguration(origin: server.baseURL,
                                              bootID: "00112233445566778899aabbccddeeff")
        let engine = makeEngine(configuration: configuration)
        let collector = EventCollector(engine.events)
        _ = try boot(engine, configuration: configuration, collector: collector)

        let first = try runProbe(engine)
        XCTAssertGreaterThan(first.measuredMilliseconds, 0)
        XCTAssertGreaterThan(first.iterations, 0)
        XCTAssertNil(first.baselineMilliseconds)
        XCTAssertNil(first.ratio)

        let second = try runProbe(engine)
        XCTAssertGreaterThan(second.measuredMilliseconds, 0)
        let baseline = try XCTUnwrap(second.baselineMilliseconds)
        XCTAssertEqual(baseline, first.measuredMilliseconds, accuracy: 0.0001)
        let ratio = try XCTUnwrap(second.ratio)
        XCTAssertGreaterThan(ratio, 0)
        XCTAssertTrue(ratio.isFinite)
    }
}
