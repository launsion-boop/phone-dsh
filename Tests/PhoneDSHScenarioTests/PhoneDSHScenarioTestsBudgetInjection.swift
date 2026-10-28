// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — G2 scenario runner: declared resource-budget
// regression (G2-FIX-115).
//
// The G2-A09 evidence showed the runner always built `PhoneDSHHost` with the
// host default budget: the catalog declared a premise (a forced EFBIG at a
// non-default single-file cap) that never reached the machine. These tests are
// the component-level regression for the whole class:
//
//   (a) a scenario declaration reaches the real host configuration, the Worker
//       environment and the materialized capabilities.json the Worker
//       publishes;
//   (b) a write over the declared cap is refused with the structured
//       `ERROR VFS_REFUSED` while a smaller write succeeds and a later mutation
//       reuses the refused mseq (the channel stays usable);
//   (c) a declared/effective mismatch fails loud and records both values;
//   (d) the catalog schema is strict and `{{budgets.*}}` figures resolve from
//       the declaration (never from a hard-coded legacy value).
//
// The host test uses the real `PhoneDSHHost`, loopback origin, ordered-channel
// frames and WAL materialization with a scripted Worker; no WKWebView and no
// model are involved, so it is deterministic and part of the normal
// `swift test` gate.

import Foundation
import XCTest
import PhoneDSHAgentCore
import PhoneDSH
import PhoneDSHEngine
import PhoneDSHWire
@testable import PhoneDSHScenario

// MARK: - Temporary workspace and bundle

private struct BudgetFixture {
    let root: URL
    let workspace: URL
    let bundle: PhoneDSHBundleLocation

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-budget-host-\(UUID().uuidString)",
                                    isDirectory: true)
        let staticDirectory = root.appendingPathComponent("www", isDirectory: true)
        let lazy = staticDirectory.appendingPathComponent("lazy", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: staticDirectory,
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: lazy,
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace,
                                                withIntermediateDirectories: true)
        let image = staticDirectory.appendingPathComponent("image.tar.gz")
        try Data("image".utf8).write(to: image)
        try Data("<html>boot</html>".utf8)
            .write(to: staticDirectory.appendingPathComponent("index.html"))
        try Data("// worker entry".utf8)
            .write(to: staticDirectory.appendingPathComponent("worker-entry.js"))
        try Data("// boot".utf8)
            .write(to: staticDirectory.appendingPathComponent("boot.js"))
        self.root = root
        self.workspace = workspace
        self.bundle = PhoneDSHBundleLocation(staticDirectory: staticDirectory,
                                             imageArchive: image,
                                             lazyDirectory: lazy)
    }

    /// The exact configuration builder the scenario runner boots.
    func configuration(budgets: ScenarioBudgets?) -> PhoneDSHConfiguration {
        ScenarioRun.hostConfiguration(
            workspaceRoot: workspace,
            bundle: bundle,
            allowedModelHosts: [],
            credentialProvider: StaticCredentialProvider([:]),
            budgets: budgets,
            drainDeadline: 3,
            helloTimeout: 20)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

// MARK: - Scripted Worker

private enum BudgetProbeError: Error, CustomStringConvertible {
    case failed(String)
    var description: String {
        switch self {
        case .failed(let detail): return detail
        }
    }
}

/// The Worker side of the ordered channel for the budget regression.
///
/// It reads the host-injected `PDSH_SINGLE_FILE_LIMIT_BYTES` from the engine
/// configuration (the same value the packed Worker entry reads), publishes a
/// capability manifest carrying it through the real VFS sink, then drives the
/// accepted/refused write sequence. It never talks to a model.
private actor BudgetProbeWorker {
    private var configuration: WebEngineConfiguration?
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var decoder = FrameDecoder()
    private var sendSeq: UInt64 = 0
    private var sentWorkerHello = false
    private var probeStarted = false
    private var recordedRefusals: [ErrorPayload] = []
    private var hostInjectedLimit: Int?
    private var sentMseqs: [UInt64] = []
    private var connectionToken = UUID()

    // MARK: Connection

    func connect(_ configuration: WebEngineConfiguration) throws {
        self.configuration = configuration
        cancelConnection()
        hostInjectedLimit = configuration.environment["PDSH_SINGLE_FILE_LIMIT_BYTES"]
            .flatMap(Int.init)
        guard var components = URLComponents(url: configuration.origin,
                                             resolvingAgainstBaseURL: false) else {
            throw BudgetProbeError.failed("bad origin")
        }
        components.scheme = "ws"
        components.path = configuration.channelPath
        components.queryItems = [URLQueryItem(name: "token",
                                              value: configuration.token)]
        guard let url = components.url else {
            throw BudgetProbeError.failed("bad channel URL")
        }
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: url)
        task.resume()
        self.session = session
        self.task = task
        self.decoder = FrameDecoder()
        self.sendSeq = 0
        self.sentWorkerHello = false
        self.probeStarted = false
        self.recordedRefusals = []
        self.sentMseqs = []
        self.connectionToken = UUID()
        let token = connectionToken
        receiveTask = Task { await self.receiveLoop(task, token: token) }
    }

    func disconnect() {
        cancelConnection()
    }

    private func cancelConnection() {
        receiveTask?.cancel()
        receiveTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        sendSeq = 0
    }

    // MARK: Observation

    func refusals() -> [ErrorPayload] { recordedRefusals }
    func injectedLimit() -> Int? { hostInjectedLimit }
    func mseqs() -> [UInt64] { sentMseqs }

    // MARK: Receive loop

    private func receiveLoop(_ task: URLSessionWebSocketTask, token: UUID) async {
        while !Task.isCancelled {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                return
            }
            guard token == connectionToken else { return }
            let data: Data
            switch message {
            case .data(let bytes): data = bytes
            case .string(let text): data = Data(text.utf8)
            @unknown default: return
            }
            guard let frames = try? decoder.feed(data) else { return }
            for frame in frames {
                do {
                    try await handle(frame)
                } catch {
                    return
                }
            }
        }
    }

    private func handle(_ frame: Frame) async throws {
        switch frame.type {
        case .hello:
            if !sentWorkerHello { try await sendWorkerHello() }
        case .fence:
            // The host sends FENCE after the lease is verified and admission
            // opens; running the probe here keeps the test off wall-clock
            // sleeps while still exercising the real channel order.
            if !probeStarted {
                probeStarted = true
                try await runProbe()
            }
        case .error:
            let payload = try JSONDecoder().decode(ErrorPayload.self,
                                                   from: frame.payload)
            recordedRefusals.append(payload)
        default:
            break
        }
    }

    private func sendWorkerHello() async throws {
        guard let configuration else {
            throw BudgetProbeError.failed("never connected")
        }
        let fence = configuration.fence ?? WebEngineFence()
        let bootID = configuration.bootID ?? UUID().uuidString
            .replacingOccurrences(of: "-", with: "").lowercased()
        let hello = try HelloPayload(
            role: .worker,
            bootID: bootID,
            sessionEpoch: configuration.sessionEpoch ?? 1,
            fence: Fence(owner: fence.owner,
                         generation: fence.generation,
                         walSeq: fence.walSeq),
            caps: ["channel/1", "vfs-sink/1", "journal/1", "api/1"],
            lastMseq: 0)
        sentWorkerHello = true
        try await enqueueJSON(.hello, hello)
    }

    // MARK: Budget probe

    /// Writes the capability manifest the packed Worker would publish, then
    /// proves the host accepts a mutation below the cap, refuses one above it
    /// with the structured `VFS_REFUSED`, and accepts the next mutation at the
    /// refused mseq.
    private func runProbe() async throws {
        guard let limit = hostInjectedLimit, limit > 0 else {
            throw BudgetProbeError.failed(
                "the host did not inject PDSH_SINGLE_FILE_LIMIT_BYTES")
        }
        // The manifest shape is the machine-readable fact the runner verifies:
        // exactly the value the Worker read from the host environment.
        let manifest = "{\"limits\":{\"single_file_bytes\":\(limit)}}\n"
        try await mutate(mseq: 1, body: VfsMutationBody(
            op: .write, mode: 0o644, mflags: [.entryChanged], appendFrom: 0,
            path: "/dsh/home/capabilities.json",
            data: Data(manifest.utf8)))
        let initial = Data(repeating: 0x61, count: 1024)
        try await mutate(mseq: 2, body: VfsMutationBody(
            op: .write, mode: 0o644, mflags: [.entryChanged], appendFrom: 0,
            path: "/dsh/workspace/small.bin", data: initial))
        // 1024 + 15 MiB is still below 16 MiB: accepted.
        let extended = 1024 + 15 * 1024 * 1024
        try await mutate(mseq: 3, body: VfsMutationBody(
            op: .write, mode: 0o644, mflags: [.appended],
            appendFrom: UInt64(initial.count),
            path: "/dsh/workspace/small.bin",
            data: Data(repeating: 0x62, count: 15 * 1024 * 1024)))
        // This append would grow the file to 16 MiB + 1 KiB: refused.
        try await mutate(mseq: 4, body: VfsMutationBody(
            op: .write, mode: 0o644, mflags: [.appended],
            appendFrom: UInt64(extended),
            path: "/dsh/workspace/small.bin",
            data: Data(repeating: 0x63, count: 2 * 1024 * 1024)))
        // A refused mutation consumes no mseq, so the channel is expected to
        // accept the next legal write at the same mseq.
        try await mutate(mseq: 4, body: VfsMutationBody(
            op: .write, mode: 0o644, mflags: [.entryChanged], appendFrom: 0,
            path: "/dsh/workspace/small2.bin",
            data: Data(repeating: 0x64, count: 512)))
    }

    private func mutate(mseq: UInt64, body: VfsMutationBody) async throws {
        sentMseqs.append(mseq)
        try await enqueueFrame(.vfsMutation,
                               payload: try VfsMutationPayload.encode(mseq: mseq,
                                                                      body: body))
    }

    // MARK: Frame sends

    private func enqueueJSON<T: Encodable>(_ type: FrameType, _ value: T) async throws {
        try await enqueueFrame(type, payload: try CanonicalJSON.encode(value))
    }

    private func enqueueFrame(_ type: FrameType, payload: Data) async throws {
        guard let task else { throw BudgetProbeError.failed("channel is closed") }
        sendSeq += 1
        let encoded = try FrameEncoder.encode(type: type, seq: sendSeq,
                                              payload: payload)
        try await task.send(.data(encoded))
    }
}

// MARK: - Scripted engine

private final class BudgetProbeEngine: WebEngineControlling, @unchecked Sendable {
    let worker: BudgetProbeWorker

    init(worker: BudgetProbeWorker) {
        self.worker = worker
    }

    var isLockdownModeEnabled: Bool { false }
    var isAttachedWithVisibleArea: Bool { true }

    func load(_ url: URL) async throws {}
    func bootWorker(_ configuration: WebEngineConfiguration) async throws {
        try await worker.connect(configuration)
    }
    func restart() async throws {}
}

// MARK: - Tests

final class PhoneDSHScenarioTestsBudgetInjection: XCTestCase {
    private static let mebibyte = 1024 * 1024
    private static let declaredBytes = 16 * 1024 * 1024

    /// Regression (a) + (b) for G2-FIX-115.
    ///
    /// Before the fix the runner ignored the declaration: the host
    /// configuration resolved to its 64 MiB default, the Worker environment
    /// carried 67108864, the materialized manifest reported 67108864 and the
    /// 16 MiB host acceptance check accepted the 2 MiB append that this test
    /// requires to be refused.
    func testDeclaredBudgetReachesHostEnvironmentAndMaterializedManifest() async throws {
        let fixture = try BudgetFixture()
        defer { fixture.cleanup() }
        let declared = ScenarioBudgets(singleFileBytes: Self.declaredBytes)
        let configuration = fixture.configuration(budgets: declared)

        // The declaration is the only input: the host still owns defaults,
        // the runner never mutates them.
        XCTAssertEqual(configuration.singleFileLimitBytes, Self.declaredBytes)
        XCTAssertEqual(configuration.log.singleFileLimitBytes, Self.declaredBytes)
        XCTAssertEqual(configuration.budgets.singleFileBytes, Self.declaredBytes)
        // The landed 8 GB row default remains 64 MiB; only the declaration is
        // injected, the tier row is not rewritten in the catalog.
        XCTAssertEqual(configuration.deviceTier, .eightGB)

        let worker = BudgetProbeWorker()
        let engine = BudgetProbeEngine(worker: worker)
        let host = PhoneDSHHost(configuration: configuration,
                                engineFactory: { _ in engine })
        do {
            try await host.start()
            let deadline = Date().addingTimeInterval(20)
            var diagnostics = await host.diagnostics()
            while Date() < deadline {
                diagnostics = await host.diagnostics()
                let refusals = await worker.refusals().count
                if refusals >= 1, diagnostics.materializedUptoMseq >= 4 { break }
                try await Task.sleep(nanoseconds: 25_000_000)
            }
            XCTAssertEqual(diagnostics.state, .running)
            XCTAssertEqual(diagnostics.admission, .open)
            XCTAssertEqual(diagnostics.materializedUptoMseq, 4,
                           "accepted mutations 1...4 must materialize; the refused "
                               + "mutation must consume no mseq")
            XCTAssertEqual(diagnostics.channelMetrics?.vfsRefusalsSent, 1,
                           "the host must answer the over-limit mutation with one "
                               + "structured VFS_REFUSED")

            // (a) The Worker read the injected limit and published it through
            // the real VFS sink; the host materialized that exact document.
            let injected = await worker.injectedLimit()
            XCTAssertEqual(injected, Self.declaredBytes,
                           "the host must inject the declared limit into the "
                               + "Worker environment")
            let manifestURL = fixture.workspace.appendingPathComponent(
                ScenarioBudgetCheck.capabilitiesRelativePath)
            let manifest = try Data(contentsOf: manifestURL)
            let effective = try ScenarioBudgetCheck.effectiveSingleFileBytes(
                inCapabilityManifest: manifest)
            XCTAssertEqual(effective, Self.declaredBytes,
                           "the materialized capabilities.json must report the "
                               + "declared single-file budget")
            let provenance = ScenarioBudgetCheck.inspect(
                declaredSingleFileBytes: Self.declaredBytes,
                hostConfigurationSingleFileBytes: configuration.singleFileLimitBytes,
                effectiveSingleFileBytes: effective,
                source: "host/" + ScenarioBudgetCheck.capabilitiesRelativePath)
            XCTAssertTrue(provenance.matches)
            XCTAssertNoThrow(try ScenarioBudgetCheck.validateEffective(provenance))

            // (b) The smaller write succeeded, the over-cap append was refused
            // with the structured error, and the next write reused the refused
            // mseq (the channel is still usable).
            let small = try Data(contentsOf: fixture.workspace.appendingPathComponent(
                "materialized/workspace/small.bin"))
            XCTAssertEqual(small.count, 1024 + 15 * 1024 * 1024,
                           "the below-cap write and append must both be accepted")
            let small2 = try Data(contentsOf: fixture.workspace.appendingPathComponent(
                "materialized/workspace/small2.bin"))
            XCTAssertEqual(small2.count, 512,
                           "the mutation after the refusal must materialize at the "
                               + "refused mseq")

            let refusals = await worker.refusals()
            XCTAssertEqual(refusals.count, 1)
            guard let refusal = refusals.first else { return }
            XCTAssertEqual(refusal.code, .vfsRefused)
            XCTAssertTrue(refusal.isVFSRefused)
            XCTAssertEqual(refusal.path, "/dsh/workspace/small.bin")
            XCTAssertEqual(refusal.limit, UInt64(Self.declaredBytes))
            XCTAssertEqual(refusal.reason, .fileTooLarge)
            XCTAssertEqual(refusal.mseq, 4)
            XCTAssertEqual(refusal.acceptedBytes, 1024 + 15 * 1024 * 1024)
            XCTAssertTrue(refusal.message.contains("16777216"),
                          "the refusal must name the enforced limit: \(refusal.message)")
            let mseqs = await worker.mseqs()
            XCTAssertEqual(mseqs, [1, 2, 3, 4, 4],
                           "the refused mutation must not consume its mseq")
        } catch {
            try? await host.stop()
            throw error
        }
        try await host.stop()
        await worker.disconnect()
    }

    /// Regression (c): a declaration that does not equal the effective Worker
    /// report fails loud and both values survive in the machine-readable
    /// provenance.
    func testDeclaredEffectiveLimitDriftFailsLoudWithBothValues() throws {
        let declared = Self.declaredBytes
        let drift = ScenarioBudgetCheck.inspect(
            declaredSingleFileBytes: declared,
            hostConfigurationSingleFileBytes: declared,
            effectiveSingleFileBytes: 64 * Self.mebibyte,
            source: "host/" + ScenarioBudgetCheck.capabilitiesRelativePath)
        XCTAssertFalse(drift.matches)
        do {
            try ScenarioBudgetCheck.validateEffective(drift)
            XCTFail("a declared/effective limit drift must fail the run loud")
        } catch {
            let text = String(describing: error)
            XCTAssertTrue(text.contains("\(declared)"),
                          "the failure must record the declared value: \(text)")
            XCTAssertTrue(text.contains("\(64 * Self.mebibyte)"),
                          "the failure must record the effective value: \(text)")
            XCTAssertTrue(text.contains("drift"), text)
        }

        // A host tier gate that clamped the declaration fails before boot.
        let clamped = ScenarioBudgetCheck.inspect(
            declaredSingleFileBytes: 64 * Self.mebibyte,
            hostConfigurationSingleFileBytes: 32 * Self.mebibyte,
            effectiveSingleFileBytes: nil,
            source: "host configuration")
        XCTAssertThrowsError(try ScenarioBudgetCheck.validateHostConfiguration(clamped)) {
            let text = String(describing: $0)
            XCTAssertTrue(text.contains("67108864"), text)
            XCTAssertTrue(text.contains("33554432"), text)
        }

        // A missing manifest is a loud verification failure, not a silent pass.
        let missing = ScenarioBudgetCheck.inspect(
            declaredSingleFileBytes: declared,
            hostConfigurationSingleFileBytes: declared,
            effectiveSingleFileBytes: nil,
            source: "host/" + ScenarioBudgetCheck.capabilitiesRelativePath)
        XCTAssertFalse(missing.matches)
        XCTAssertThrowsError(try ScenarioBudgetCheck.validateEffective(missing)) {
            XCTAssertTrue(String(describing: $0).contains("cannot be verified"))
        }

        // The parser reads the exact field the Worker publishes.
        let manifest = Data("{\"limits\":{\"single_file_bytes\":67108864}}".utf8)
        XCTAssertEqual(try ScenarioBudgetCheck.effectiveSingleFileBytes(
            inCapabilityManifest: manifest), 64 * Self.mebibyte)
        XCTAssertThrowsError(try ScenarioBudgetCheck.effectiveSingleFileBytes(
            inCapabilityManifest: Data("{\"limits\":{}}".utf8)))
    }

    // MARK: Catalog schema and reference expansion

    /// The drift failure is machine-checkable after the fact: report.json must
    /// carry both the declaration and the effective value, not only a prose
    /// error string.
    func testReportEncodesBudgetProvenanceWithBothValues() throws {
        let provenance = ScenarioBudgetCheck.inspect(
            declaredSingleFileBytes: Self.declaredBytes,
            hostConfigurationSingleFileBytes: Self.declaredBytes,
            effectiveSingleFileBytes: 64 * Self.mebibyte,
            source: "host/" + ScenarioBudgetCheck.capabilitiesRelativePath)
        let report = ScenarioReport(
            id: "G2-BUDGET-REPORT",
            status: "BUDGET",
            assertions: [],
            turns: [],
            perturbations: [],
            usage: ScenarioUsageReport(modelRequests: 0, upstreamBytesIn: 0,
                                       upstreamBytesOut: 0, wallS: 0),
            pageVisibility: nil,
            deferred: nil,
            runnerInfra: nil,
            webContentTerminations: 0,
            hostEvaluated: nil,
            consoleErrors: [],
            runnerErrors: ["runner: budget: declared singleFileBytes=16777216 "
                + "but the Worker reports effective singleFileBytes=67108864"],
            hostStates: [],
            runCompleted: false,
            runIncompleteReason: "the run ended with status BUDGET",
            budgets: provenance)
        let data = try JSONEncoder().encode(report)
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        let budgets = try XCTUnwrap(root["budgets"] as? [String: Any])
        XCTAssertEqual(budgets["declared_single_file_bytes"] as? Int,
                       Self.declaredBytes)
        XCTAssertEqual(budgets["host_configuration_single_file_bytes"] as? Int,
                       Self.declaredBytes)
        XCTAssertEqual(budgets["effective_single_file_bytes"] as? Int,
                       64 * Self.mebibyte)
        XCTAssertEqual(budgets["matches"] as? Bool, false)
        XCTAssertEqual(budgets["source"] as? String,
                       "host/" + ScenarioBudgetCheck.capabilitiesRelativePath)
    }

    private func catalogData(budgets: [String: Any]? = ["singleFileBytes": 16777216],
                             prompt: String = "limit is {{budgets.singleFileBytes}} bytes "
                                 + "({{budgets.singleFileMiB}} MiB, "
                                 + "{{budgets.singleFileBytesGrouped}})",
                             assertionValue: String = "{{budgets.singleFileBytes}}|"
                                 + "{{budgets.singleFileBytesGrouped}}",
                             assertionCommand: String = "test -le {{budgets.singleFileBytes}}",
                             rubric: String = "limit {{budgets.singleFileBytes}}") throws -> Data {
        var scenario: [String: Any] = [
            "id": "G2-BUDGET-SCHEMA",
            "category": "edge",
            "title": "budget schema",
            "user_story": "budget reference expansion",
            "workspace": ["files": [String: String]()],
            "turns": [["prompt": prompt]],
            "assertions": [
                ["type": "file_regex", "path": "LIMITS.md", "value": assertionValue],
                ["type": "workspace_command", "command": assertionCommand],
            ],
            "rubric": [rubric],
            "budget": ["max_minutes": 1, "max_model_requests": 1],
            "network": "none",
            "target": "both",
        ]
        if let budgets { scenario["budgets"] = budgets }
        let document: [String: Any] = ["version": 1, "scenarios": [scenario]]
        return try JSONSerialization.data(withJSONObject: document,
                                          options: [.sortedKeys])
    }

    private func loadCatalog(_ data: Data) throws -> ScenarioCatalog {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-budget-catalog-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("catalog.json")
        try data.write(to: url)
        return try ScenarioCatalog.load(from: url)
    }

    func testBudgetBlockIsStrictlyDecodedAndReferencesResolve() throws {
        let catalog = try loadCatalog(catalogData())
        guard let scenario = catalog.scenarios.first else {
            return XCTFail("the fixture catalog decoded no scenario")
        }
        XCTAssertEqual(scenario.budgets?.singleFileBytes, 16 * Self.mebibyte)
        XCTAssertEqual(scenario.turns[0].prompt,
                       "limit is 16777216 bytes (16 MiB, 16,777,216)")
        XCTAssertEqual(scenario.assertions[0].value, "16777216|16,777,216")
        XCTAssertEqual(scenario.assertions[1].command, "test -le 16777216")
        XCTAssertEqual(scenario.rubric, ["limit 16777216"])

        // Unknown keys and out-of-range values fail the load loudly.
        XCTAssertThrowsError(try loadCatalog(
            catalogData(budgets: ["singleFileBytse": 16777216]))) {
            XCTAssertTrue(String(describing: $0).contains("unknown budgets key"))
        }
        XCTAssertThrowsError(try loadCatalog(
            catalogData(budgets: ["singleFileBytes": 15 * Self.mebibyte]))) {
            let text = String(describing: $0)
            XCTAssertTrue(text.contains("outside the supported range"), text)
            XCTAssertTrue(text.contains("15728640"), text)
        }
        XCTAssertThrowsError(try loadCatalog(
            catalogData(budgets: ["singleFileBytes": 129 * Self.mebibyte]))) {
            XCTAssertTrue(String(describing: $0)
                .contains("outside the supported range"))
        }
        // A reference with no declaration (or an unknown name) is never left
        // as a literal figure.
        XCTAssertThrowsError(try loadCatalog(
            catalogData(budgets: nil,
                        prompt: "limit {{budgets.singleFileBytes}}"))) {
            XCTAssertTrue(String(describing: $0).contains("no budgets.singleFileBytes"))
        }
        XCTAssertThrowsError(try loadCatalog(
            catalogData(prompt: "limit {{budgets.unknownFigure}}"))) {
            XCTAssertTrue(String(describing: $0).contains("unknown budget reference"))
        }
        // A malformed reference must not survive the load as literal text.
        XCTAssertThrowsError(try loadCatalog(
            catalogData(prompt: "limit {{budgets.}} bytes"))) {
            XCTAssertTrue(String(describing: $0)
                .contains("malformed budget reference"))
        }
        // A non-MiB limit cannot render the MiB spelling; fail loud.
        XCTAssertThrowsError(try loadCatalog(
            catalogData(budgets: ["singleFileBytes": 16 * Self.mebibyte + 1],
                        prompt: "limit {{budgets.singleFileMiB}} MiB"))) {
            XCTAssertTrue(String(describing: $0)
                .contains("not a whole number of MiB"))
        }
    }

    /// The shipped catalog must not reintroduce the superseded 15 MiB D4 value
    /// and every declared budget reference must resolve before a run starts.
    func testShippedCatalogUsesTheDeclaredBudgetAsTheOnlyLimitSource() throws {
        let root = try XCTUnwrap(
            scenarioRepositoryRoot(startingAt: URL(fileURLWithPath: #filePath)))
        let url = root.appendingPathComponent("scripts/ci/scenarios/catalog.json")
        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(raw.contains("15728640"),
                       "the catalog still hard-codes the superseded 15 MiB D4 value")
        let catalog = try ScenarioCatalog.load(from: url)
        var declared = 0
        for scenario in catalog.scenarios {
            guard let budget = scenario.budgets?.singleFileBytes else { continue }
            declared += 1
            XCTAssertGreaterThanOrEqual(budget, 16 * Self.mebibyte)
            XCTAssertLessThanOrEqual(budget, 128 * Self.mebibyte)
            for turn in scenario.turns {
                XCTAssertFalse(turn.prompt.contains("{{budgets."),
                               "\(scenario.id) prompt left a budget reference unresolved")
            }
            for assertion in scenario.assertions {
                XCTAssertFalse((assertion.value ?? "").contains("{{budgets."))
                XCTAssertFalse((assertion.command ?? "").contains("{{budgets."))
            }
            for criterion in scenario.rubric ?? [] {
                XCTAssertFalse(criterion.contains("{{budgets."))
            }
        }
        XCTAssertGreaterThan(declared, 0,
                             "the shipped catalog must exercise the budgets path")
    }
}
