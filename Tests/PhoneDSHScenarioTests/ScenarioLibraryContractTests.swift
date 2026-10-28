// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — G2 scenario runner: library contract regression tests.
//
// W13-SIM-SCENARIOS root cause: the scenario engine lived only in the macOS
// XCTest target, so `scenarios.sh --target sim` could only filter the catalog
// and the whole real-model line stopped when the Mac console was locked. These
// tests pin the two mechanisms that made the engine reusable:
//
//   * the engine sources are a regular library (no XCTest import) and are
//     reachable from an XCTest target through the ordinary module import;
//   * the staged iOS input layout resolves the catalog/config/Worker bundle and
//     takes model credentials only from the test-runner environment, so a key
//     can never reach a staged file.
//
// They fail on the pre-fix tree: `PhoneDSHScenario` did not exist and
// the engine files lived under `Tests/PhoneDSHScenarioTests`.

import Foundation
import XCTest
import PhoneDSH
@testable import PhoneDSHScenario

// The `PhoneDSH` prefix is deliberate: the CI gate runs
// `swift test --filter 'PhoneDSH|PhoneDSHShell'`, which matches
// test specifiers by target/class name. Without the prefix this regression
// suite (formerly `PhoneDSHScenarioLibraryContractTests`) never ran in a gate;
// it was only reachable through the ungated `scenarios.sh --run-on macos` path.
final class PhoneDSHScenarioLibraryContractTests: XCTestCase {
    /// Repository root, found by walking up from this source file to the directory that holds `spec/`
    /// (W11-TESTS): the extracted phone-dsh package has no `sdk/` level, so counting parent hops breaks there.
    private static var repositoryRoot: URL {
        guard let root = scenarioRepositoryRoot(startingAt: URL(fileURLWithPath: #filePath)) else {
            preconditionFailure("cannot locate the repository root (a directory containing spec/) from #filePath")
        }
        return root
    }

    /// The scenario engine must be a regular library, not XCTest glue.
    func testScenarioEngineLivesInALibraryWithoutXCTest() throws {
        let repositoryRoot = Self.repositoryRoot
        let engine = repositoryRoot
            .appendingPathComponent("Sources/PhoneDSHScenario",
                                    isDirectory: true)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: engine.path, isDirectory: &isDirectory)
                && isDirectory.boolValue,
            "the scenario engine must live in Sources/PhoneDSHScenario")
        guard isDirectory.boolValue else { return }
        let files = try FileManager.default.contentsOfDirectory(
            at: engine, includingPropertiesForKeys: nil).filter {
                $0.pathExtension == "swift"
            }
        XCTAssertFalse(files.isEmpty, "the scenario library has no Swift sources")
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains("import XCTest"),
                           "\(file.lastPathComponent) imports XCTest; the engine must "
                           + "compile as a regular library for the iOS Simulator suite")
            XCTAssertTrue(text.hasPrefix("// SPDX-License-Identifier: MIT"),
                          "\(file.lastPathComponent) has no MIT SPDX header")
        }
        // Compile-time reachability: these symbols are the shared engine surface
        // the macOS glue and the simulator bundle both call.
        _ = ScenarioEnvironment.self
        _ = ScenarioRun.self
        _ = ScenarioSlotPlan.self
        _ = ScenarioCatalog.self
    }

    /// Regression (integration audit P0): the shipped catalog grew to 56
    /// scenarios while the fixed slot bank still had 48, so the documented
    /// full-catalog run executed only the first 48 and left eight scenarios
    /// without a report (`report_check` then failed the batch with exit 4).
    ///
    /// The shared slot plan and both XCTest suites must cover the catalog, and
    /// an over-capacity selection must be rejected before the first scenario
    /// executes instead of partially running the prefix of the selection.
    func testSlotBankCoversTheShippedCatalogAndRejectsOverflow() throws {
        let root = Self.repositoryRoot
        let catalog = try ScenarioCatalog.load(
            from: root.appendingPathComponent("scripts/ci/scenarios/catalog.json"))
        XCTAssertLessThanOrEqual(
            catalog.scenarios.count, ScenarioSlotPlan.slotCount,
            "the shipped catalog has \(catalog.scenarios.count) scenarios but the "
            + "fixed slot bank only has \(ScenarioSlotPlan.slotCount) slots")
        XCTAssertNil(ScenarioSlotPlan.capacityError(selectionCount: catalog.scenarios.count),
                     "a selection that fits the slot bank must not be rejected")
        let selftest = try ScenarioCatalog.load(
            from: root.appendingPathComponent("scripts/ci/scenarios/selftest.json"))
        XCTAssertLessThanOrEqual(selftest.scenarios.count, ScenarioSlotPlan.slotCount)

        let overflow = ScenarioSlotPlan.capacityError(
            selectionCount: ScenarioSlotPlan.slotCount + 1)
        XCTAssertNotNil(overflow, "an over-capacity selection must be rejected")
        XCTAssertTrue(overflow?.contains("\(ScenarioSlotPlan.slotCount)") ?? false,
                      "the rejection must name the slot capacity: \(overflow ?? "nil")")

        // Every slot needs a static XCTest method in both suites. A missing
        // slot silently drops a selected scenario; an unused slot skips.
        let suites = [
            "Tests/PhoneDSHScenarioTests/PhoneDSHScenarioTests.swift",
            "examples/probe-app/PhoneDSHScenarioSimTests/"
                + "PhoneDSHScenarioSimTests.swift",
        ]
        for relativePath in suites {
            let source = try String(
                contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
            for index in 0..<ScenarioSlotPlan.slotCount {
                let method = String(format: "func testScenarioSlot%02d()", index)
                XCTAssertTrue(source.contains(method),
                              "\(relativePath) is missing \(method)")
            }
            XCTAssertTrue(
                source.contains("ScenarioSlotPlan.capacityError"),
                "\(relativePath) must reject an over-capacity batch before "
                + "executing any scenario")
        }
    }

    #if os(macOS)
    /// The simulator runner writes `workspace.tar` with the library's ustar
    /// writer (iOS has no `Process`). The archive must be readable by the same
    /// tar tooling the judge uses on the macOS artifact.
    func testSwiftTarWriterProducesAnExtractableArchive() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-scenario-tar-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let nested = workspace.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: nested,
                                                withIntermediateDirectories: true)
        try Data("alpha\n".utf8).write(to: workspace.appendingPathComponent("a.txt"))
        try Data("beta\n".utf8).write(to: nested.appendingPathComponent("b.txt"))
        let archive = root.appendingPathComponent("workspace.tar")
        try ScenarioTar.archive(directory: workspace, to: archive)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-tf", archive.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0,
                       "the ustar writer produced an archive tar cannot read")
        let listing = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(),
                             as: UTF8.self)
        XCTAssertTrue(listing.contains("a.txt"), listing)
        XCTAssertTrue(listing.contains("sub/b.txt"), listing)
    }
    #endif

    /// G2-FIX-5: `workspace.tar` is written by the library's ustar writer on
    /// every platform. The macOS `/usr/bin/tar` branch could add AppleDouble
    /// `._` members depending on the external environment; the archive must
    /// keep `.git` entries as ordinary files.
    func testWorkspaceArchiveHasNoAppleDoubleMembersAndKeepsGit() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-scenario-git-tar-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace.appendingPathComponent(".git/refs/heads", isDirectory: true),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: workspace.appendingPathComponent(".git/objects/ab", isDirectory: true),
            withIntermediateDirectories: true)
        try Data("ref: refs/heads/main\n".utf8)
            .write(to: workspace.appendingPathComponent(".git/HEAD"))
        try Data("0123456789abcdef\n".utf8)
            .write(to: workspace.appendingPathComponent(".git/refs/heads/main"))
        try Data("object\n".utf8)
            .write(to: workspace.appendingPathComponent(".git/objects/ab/cdef"))
        try Data("alpha\n".utf8).write(to: workspace.appendingPathComponent("a.txt"))
        let archive = root.appendingPathComponent("workspace.tar")
        try ScenarioTar.archive(directory: workspace, to: archive)

        let names = tarMemberNames(try Data(contentsOf: archive))
        XCTAssertTrue(names.contains("a.txt"), names.joined(separator: ","))
        XCTAssertTrue(names.contains(".git/HEAD"), names.joined(separator: ","))
        XCTAssertTrue(names.contains(".git/refs/heads/main"), names.joined(separator: ","))
        XCTAssertTrue(names.contains(".git/objects/ab/cdef"), names.joined(separator: ","))
        for name in names {
            XCTAssertFalse(name.hasPrefix("._"), "AppleDouble member: \(name)")
            XCTAssertFalse(name.contains("/._"), "AppleDouble member: \(name)")
        }

        let source = try String(
            contentsOf: Self.repositoryRoot.appendingPathComponent(
                "Sources/PhoneDSHScenario/ScenarioRun.swift"),
            encoding: .utf8)
        XCTAssertFalse(source.contains("/usr/bin/tar"),
                       "the macOS external-tar branch must be gone")
        XCTAssertFalse(source.contains("COPYFILE_DISABLE"),
                       "archive membership must not depend on the host environment")
    }

    /// Minimal ustar member reader for the writer's own regression: names only,
    /// no extraction and no host `tar`.
    private func tarMemberNames(_ data: Data) -> [String] {
        var names: [String] = []
        var offset = 0
        while offset + 512 <= data.count {
            let header = data.subdata(in: offset..<(offset + 512))
            if header.allSatisfy({ $0 == 0 }) { break }
            let name = cString(header, from: 0, count: 100)
            let prefix = cString(header, from: 345, count: 155)
            names.append(prefix.isEmpty ? name : prefix + "/" + name)
            let sizeText = cString(header, from: 124, count: 12)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let size = Int(sizeText, radix: 8) ?? 0
            offset += 512 + ((size + 511) / 512) * 512
        }
        return names
    }

    private func cString(_ data: Data, from offset: Int, count: Int) -> String {
        let bytes = Array(data[offset..<(offset + count)])
        let end = bytes.firstIndex(of: 0) ?? bytes.count
        return String(decoding: bytes[..<end], as: UTF8.self)
    }

    /// `Documents/pdsh-scenarios/` (catalog + fixtures + config + worker bundle)
    /// resolves the same environment on the simulator path as the launcher
    /// environment does on macOS. Credentials come only from the runner env.
    func testStagedEnvironmentReadsCredentialsOnlyFromTheRunnerEnvironment() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-scenario-contract-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixtures = root.appendingPathComponent("fixtures", isDirectory: true)
        let results = root.appendingPathComponent("results", isDirectory: true)
        let worker = root.appendingPathComponent("worker", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: results, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: worker.appendingPathComponent("lazy", isDirectory: true),
            withIntermediateDirectories: true)
        for name in ["index.html", "boot.js", "worker-entry.js", "image.tar.gz"] {
            try Data("x".utf8).write(to: worker.appendingPathComponent(name))
        }
        let catalog: [String: Any] = [
            "version": 1,
            "scenarios": [
                [
                    "id": "G2-STAGED",
                    "category": "recovery",
                    "title": "staged",
                    "user_story": "staged",
                    "workspace": ["files": ["a.txt": "a"]],
                    "turns": [["prompt": "hello"]],
                    "assertions": [["type": "file_exists", "path": "a.txt"]],
                    "budget": ["max_minutes": 1, "max_model_requests": 2],
                    "tags": ["recovery"],
                    "target": "macos",
                ],
            ],
        ]
        let catalogData = try JSONSerialization.data(withJSONObject: catalog)
        try catalogData.write(to: root.appendingPathComponent("catalog.json"))
        let config: [String: Any] = [
            "version": 1,
            "upstream": "real",
            "only": ["G2-STAGED"],
            "tag": "recovery",
            "target": "both",
            "keep_bodies": true,
        ]
        let configData = try JSONSerialization.data(withJSONObject: config,
                                                    options: [.sortedKeys])
        let configURL = root.appendingPathComponent("config.json")
        try configData.write(to: configURL)

        let key = "sk-contract-test-not-a-real-key"
        let environment = try ScenarioEnvironment.resolveStaged(
            root: root,
            workerBundle: PhoneDSHBundleLocation(staticDirectory: worker),
            environment: [
                "TEST_RUNNER_PDSH_MODEL_BASE_URL": "https://model.example.invalid/v1",
                "TEST_RUNNER_PDSH_MODEL_NAME": "deepseek-flash",
                "TEST_RUNNER_PDSH_MODEL_API_KEY": key,
            ])
        XCTAssertEqual(environment.upstream, "real")
        XCTAssertEqual(environment.only, ["G2-STAGED"])
        XCTAssertEqual(environment.target, "both")
        XCTAssertTrue(environment.keepBodies)
        XCTAssertEqual(environment.resultsRoot, results)
        XCTAssertEqual(environment.fixturesRoot, fixtures)
        XCTAssertEqual(environment.modelBaseURL?.host, "model.example.invalid")
        XCTAssertEqual(environment.modelName, "deepseek-flash")
        XCTAssertEqual(environment.modelAPIKey, key)

        // A target=both run must include a scenario whose catalog target says
        // macos; that is exactly what makes the simulator selftest execute the
        // same catalog.
        let decoded = try ScenarioCatalog.load(from: environment.catalogURL)
        XCTAssertEqual(environment.select(from: decoded).map(\.id), ["G2-STAGED"])

        // The credential exists only in this process's runner environment.
        let staged = try String(contentsOf: configURL, encoding: .utf8)
            + (try String(contentsOf: root.appendingPathComponent("catalog.json"),
                          encoding: .utf8))
        XCTAssertFalse(staged.contains(key),
                       "a model credential was written into a staged runner file")
    }
}
