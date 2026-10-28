// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — G2 scenario runner: catalog and fixtures.
//
// Decodes `scripts/ci/scenarios/catalog.json` (SCHEMA in
// `scripts/ci/scenarios/README.md`) and resolves the run environment the
// `scenarios.sh` launcher exports. The runner is catalog-driven: no scenario
// id, prompt or assertion is compiled into this file.
//
// This is the regular `PhoneDSHScenario` library, not a test target:
// the macOS `PhoneDSHScenarioTests` suite and the iOS Simulator
// `PhoneDSHScenarioSimTests` bundle both link it (W13-SIM-SCENARIOS).

import Foundation
import PhoneDSH

// MARK: - Repository root

/// Locates the checkout root by walking up from a source file instead of
/// counting fixed parent hops. The checked-in layout has `spec/` at the
/// repository root; after the open-source extraction drops the `sdk/` level the
/// package root itself carries `spec/` (or, when the spec is not shipped,
/// `Package.swift`).
func scenarioRepositoryRoot(startingAt file: URL) -> URL? {
    let fileManager = FileManager.default
    func firstAncestor(withMarker marker: String) -> URL? {
        // Standardize first and bound the walk by the path component count:
        // deleting the last component of a URL that was built by appending a
        // slash-containing path component can produce a relative `..` segment
        // instead of reaching `/`, which would make a `parent == candidate`
        // test loop forever.
        var candidate = file.standardizedFileURL.deletingLastPathComponent()
        while candidate.pathComponents.count > 1 {
            if fileManager.fileExists(atPath: candidate.appendingPathComponent(marker).path) {
                return candidate
            }
            candidate = candidate.deletingLastPathComponent()
        }
        return nil
    }
    return firstAncestor(withMarker: "spec") ?? firstAncestor(withMarker: "Package.swift")
}

// MARK: - Catalog

/// One scenario document from the catalog.
public struct Scenario: Decodable, Sendable {
    public struct Workspace: Decodable, Sendable {
        /// Relative path -> file content, seeded into the Worker VFS before boot.
        public var files: [String: String]?
        /// Fixture directory name under `scripts/ci/scenarios/fixtures/`.
        public var fixture: String?
    }

    public struct Turn: Decodable, Sendable {
        public var prompt: String
    }

    public struct Assertion: Decodable, Sendable {
        public var type: String
        public var path: String?
        public var value: String?
        public var command: String?
        public var max: Int?
        /// `worker_command` only: `bash` (default), `sh` or `python3`.
        public var program: String? = nil
        /// `worker_command` only: the Worker VFS working directory.
        public var cwd: String? = nil
        /// `worker_command` only: the per-command wall-clock budget.
        public var timeoutMilliseconds: Int? = nil

        private enum CodingKeys: String, CodingKey {
            case type, path, value, command, max, program, cwd
            case timeoutMilliseconds = "timeout_ms"
        }
    }

    public struct Budget: Decodable, Sendable {
        public var maxMinutes: Int
        public var maxModelRequests: Int

        private enum CodingKeys: String, CodingKey {
            case maxMinutes = "max_minutes"
            case maxModelRequests = "max_model_requests"
        }
    }

    public struct Perturbation: Decodable, Sendable {
        /// `after_turn:<n>`, `during_first_tool` or `minute:<n>`. The runner
        /// validates the spelling against its capability matrix before the run;
        /// an unknown point is a runner-INFRA result, never a verdict.
        public var at: String
        /// `planned_restart`, `park_resume`, `worker_kill`, `webcontent_kill`.
        /// Whether the kind is executable depends on the execution target and
        /// is validated before the run (G2-FIX-65).
        public var kind: String
    }

    /// Optional mock-upstream script (`--upstream mock` runs only). It is test
    /// harness configuration: the shape of the scripted model replies, not a
    /// scenario branch in production code.
    public struct Mock: Decodable, Sendable {
        /// Replies that call the fixed tool before the final text reply.
        public var toolCallRounds: Int?
        public var toolCommand: String?
        public var toolDescription: String?
        public var toolText: String?
        public var finalText: String?
        /// Target SSE body size per reply; the last value repeats.
        public var responseByteSizes: [Int]?
        public var chunkBytes: Int?
        public var chunkDelayMs: Int?
        /// 1-based reply number from which every response stalls mid-body.
        public var stallFromResponse: Int?
        /// Bytes written before a stalled reply goes silent.
        public var stallAfterBytes: Int?
        /// Resume a stalled reply after this pause (ms) instead of holding it
        /// open forever; models a downstream consumer that stopped pulling
        /// while the host already owns the complete response body.
        public var resumeAfterMs: Int?
        /// Worker host-route delivery inactivity interval for this run; the
        /// stall self-test uses a short one so the typed failure is bounded.
        public var deliveryIdleTimeoutMs: Int?

        private enum CodingKeys: String, CodingKey {
            case toolCallRounds = "tool_call_rounds"
            case toolCommand = "tool_command"
            case toolDescription = "tool_description"
            case toolText = "tool_text"
            case finalText = "final_text"
            case responseByteSizes = "response_bytes"
            case chunkBytes = "chunk_bytes"
            case chunkDelayMs = "chunk_delay_ms"
            case stallFromResponse = "stall_from_response"
            case stallAfterBytes = "stall_after_bytes"
            case resumeAfterMs = "resume_after_ms"
            case deliveryIdleTimeoutMs = "delivery_idle_timeout_ms"
        }

        /// The executable mock script with the generic defaults filled in.
        var script: ScenarioMockScript {
            var script = ScenarioMockScript.generic
            if let toolCallRounds { script.toolCallRounds = max(0, toolCallRounds) }
            if let toolCommand { script.toolCommand = toolCommand }
            if let toolDescription { script.toolDescription = toolDescription }
            if let toolText { script.toolText = toolText }
            if let finalText { script.finalText = finalText }
            if let responseByteSizes, !responseByteSizes.isEmpty {
                script.responseByteSizes = responseByteSizes.map { max(0, $0) }
            }
            if let chunkBytes { script.chunkBytes = max(1, chunkBytes) }
            if let chunkDelayMs { script.chunkDelay = max(0, Double(chunkDelayMs) / 1000) }
            if let stallFromResponse { script.stallFromResponse = max(1, stallFromResponse) }
            if let stallAfterBytes { script.stallAfterBytes = max(0, stallAfterBytes) }
            if let resumeAfterMs { script.resumeAfterPause = max(0, Double(resumeAfterMs) / 1000) }
            return script
        }
    }

    public var id: String
    public var category: String
    public var title: String
    public var userStory: String
    public var workspace: Workspace
    public var turns: [Turn]
    public var assertions: [Assertion]
    public var rubric: [String]?
    public var budget: Budget
    public var perturbations: [Perturbation]?
    public var mock: Mock?
    public var network: ScenarioNetwork?
    public var tags: [String]?
    public var target: String?
    /// Optional resource-budget declaration (G2-FIX-115). The runner injects
    /// it into the host configuration and verifies the effective value; it is
    /// also the single source for `{{budgets.*}}` figures in prompts, rubrics
    /// and assertions. A default of `nil` keeps every memberwise fixture that
    /// predates the block compiling.
    public var budgets: ScenarioBudgets? = nil
    /// The source catalog object, retained so the run can write its exact
    /// definition (including additive fields this version does not interpret)
    /// beside the evidence. Budget placeholders are patched to the resolved
    /// values when the artifact is encoded.
    var sourceDocument: Data? = nil

    private enum CodingKeys: String, CodingKey {
        case id, category, title, workspace, turns, assertions, rubric
        case budget, budgets, perturbations, mock, network, tags, target
        case userStory = "user_story"
    }

    /// Expands every `{{budgets.<name>}}` reference from this scenario's own
    /// declaration. Called once by ``ScenarioCatalog/load(from:)`` so the
    /// harness prompt, the assertion evaluator and the simulator host phase
    /// all see the same concrete figures.
    mutating func resolveBudgetReferences() throws {
        func expand(_ text: String, _ location: String) throws -> String {
            try ScenarioBudgetPlaceholders.expand(
                text, budgets: budgets, label: "scenario \(id) \(location)")
        }
        title = try expand(title, "title")
        userStory = try expand(userStory, "user_story")
        for index in turns.indices {
            turns[index].prompt = try expand(turns[index].prompt,
                                             "turn[\(index)] prompt")
        }
        for index in assertions.indices {
            if let value = assertions[index].value {
                assertions[index].value = try expand(value,
                                                     "assertion[\(index)] value")
            }
            if let command = assertions[index].command {
                assertions[index].command = try expand(command,
                                                       "assertion[\(index)] command")
            }
        }
        if let rubric {
            self.rubric = try rubric.enumerated().map { index, criterion in
                try expand(criterion, "rubric[\(index)]")
            }
        }
    }

    /// The exact catalog object used by this runner, with the textual values
    /// expanded by `resolveBudgetReferences`. Unknown additive catalog keys
    /// remain intact for reviewers and future runner versions.
    func evidenceDocumentData() throws -> Data {
        var object: [String: Any]
        if let sourceDocument,
           let decoded = try JSONSerialization.jsonObject(with: sourceDocument) as? [String: Any] {
            object = decoded
        } else {
            object = [
                "id": id,
                "category": category,
                "title": title,
                "user_story": userStory,
                "workspace": [
                    "files": workspace.files ?? [:],
                    "fixture": workspace.fixture as Any? ?? NSNull(),
                ],
                "turns": turns.map { ["prompt": $0.prompt] },
                "assertions": assertions.map { assertion in
                    var value: [String: Any] = ["type": assertion.type]
                    if let path = assertion.path { value["path"] = path }
                    if let content = assertion.value { value["value"] = content }
                    if let command = assertion.command { value["command"] = command }
                    if let max = assertion.max { value["max"] = max }
                    if let program = assertion.program { value["program"] = program }
                    if let cwd = assertion.cwd { value["cwd"] = cwd }
                    if let timeout = assertion.timeoutMilliseconds {
                        value["timeout_ms"] = timeout
                    }
                    return value
                },
                "budget": [
                    "max_minutes": budget.maxMinutes,
                    "max_model_requests": budget.maxModelRequests,
                ],
            ]
            if let rubric { object["rubric"] = rubric }
            if let target { object["target"] = target }
            if let tags { object["tags"] = tags }
        }

        object["title"] = title
        object["user_story"] = userStory
        if var rawTurns = object["turns"] as? [[String: Any]], rawTurns.count == turns.count {
            for index in turns.indices { rawTurns[index]["prompt"] = turns[index].prompt }
            object["turns"] = rawTurns
        } else {
            object["turns"] = turns.map { ["prompt": $0.prompt] }
        }
        if var rawAssertions = object["assertions"] as? [[String: Any]],
           rawAssertions.count == assertions.count {
            for index in assertions.indices {
                if let value = assertions[index].value { rawAssertions[index]["value"] = value }
                if let command = assertions[index].command { rawAssertions[index]["command"] = command }
                if let program = assertions[index].program { rawAssertions[index]["program"] = program }
                if let cwd = assertions[index].cwd { rawAssertions[index]["cwd"] = cwd }
                if let timeout = assertions[index].timeoutMilliseconds {
                    rawAssertions[index]["timeout_ms"] = timeout
                }
            }
            object["assertions"] = rawAssertions
        }
        if let rubric { object["rubric"] = rubric }
        return try JSONSerialization.data(withJSONObject: object,
                                         options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
    }
}

/// Writes the scenario definition used by one run next to that run's report.
enum ScenarioDefinitionArtifact {
    static func write(_ scenario: Scenario, to url: URL,
                      redactor: ScenarioRedactor = ScenarioRedactor()) throws {
        let document = try JSONSerialization.jsonObject(with: scenario.evidenceDocumentData())
        let safeDocument = redactStrings(in: document, using: redactor)
        let data = try JSONSerialization.data(withJSONObject: safeDocument,
                                              options: [.sortedKeys, .prettyPrinted,
                                                        .withoutEscapingSlashes])
        try scenarioWrite(data, to: url)
    }

    private static func redactStrings(in value: Any,
                                      using redactor: ScenarioRedactor) -> Any {
        if let text = value as? String { return redactor.redact(text) }
        if let object = value as? [String: Any] {
            // Unknown additive fields may include headers. Preserve their
            // shape without losing the credential-name context while walking
            // individual values (which need not carry a Bearer/sk- prefix).
            let credentialNames: Set<String> = ["authorization", "proxy-authorization", "x-api-key"]
            return object.mapValues { redactStrings(in: $0, using: redactor) }
                .merging(object.filter { credentialNames.contains($0.key.lowercased()) }
                    .mapValues { _ in "<redacted>" as Any }) { _, protected in protected }
        }
        if let array = value as? [Any] {
            return array.map { redactStrings(in: $0, using: redactor) }
        }
        return value
    }
}

extension Scenario.Assertion {
    /// Every key an assertion of a given type may carry in the catalog.
    ///
    /// `Scenario.Assertion` uses the synthesized decoder, which ignores unknown
    /// keys by design (additive fields stay forward-compatible). That is the
    /// wrong default for a catalog assertion: a misspelled bound key such as
    /// `"3": 0` decodes to `max == nil` and turns the check into a silent
    /// no-op. `ScenarioCatalog.load` validates the raw keys against this table
    /// before any scenario can run.
    static let allowedKeysByType: [String: Set<String>] = [
        "file_exists": ["type", "path"],
        "no_file": ["type", "path"],
        "file_contains": ["type", "path", "value"],
        "file_regex": ["type", "path", "value"],
        "file_json_path": ["type", "path", "value"],
        "workspace_command": ["type", "command"],
        "worker_command": ["type", "command", "program", "cwd", "timeout_ms"],
        "turn_count_lte": ["type", "max"],
        "model_requests_lte": ["type", "max"],
        "no_console_error": ["type"],
        "session_error": ["type", "value"],
        "restart_recovered": ["type"],
    ]

    /// Keys an assertion of the type cannot omit. These are the inputs the
    /// evaluators need; a missing `max` on a `*_lte` assertion (or a missing
    /// `value` on a content assertion) would otherwise evaluate true on every
    /// run instead of failing the configuration.
    static let requiredKeysByType: [String: Set<String>] = [
        "file_exists": ["path"],
        "no_file": ["path"],
        "file_contains": ["path", "value"],
        "file_regex": ["path", "value"],
        "file_json_path": ["path", "value"],
        "workspace_command": ["command"],
        "worker_command": ["command"],
        "turn_count_lte": ["max"],
        "model_requests_lte": ["max"],
        "no_console_error": [],
        "session_error": [],
        "restart_recovered": [],
    ]
}

/// `network: "none"` or `network: { "allow": ["host", ...] }`.
public enum ScenarioNetwork: Decodable, Sendable {
    case none
    case allow([String])

    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let text = try? single.decode(String.self) {
            self = text == "none" ? .none : .allow([text])
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self = .allow(try container.decodeIfPresent([String].self, forKey: .allow) ?? [])
    }

    private enum CodingKeys: String, CodingKey {
        case allow
    }

    /// Hosts the scenario explicitly allows (empty for `none`).
    var allowedHosts: [String] {
        switch self {
        case .none: return []
        case .allow(let hosts): return hosts
        }
    }
}

/// The catalog document.
public struct ScenarioCatalog: Decodable, Sendable {
    public struct Fixture: Decodable, Sendable {
        public var name: String
        public var description: String?
    }

    public var version: Int?
    public var scenarios: [Scenario]
    public var fixtures: [Fixture]?

    public static func load(from url: URL) throws -> ScenarioCatalog {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ScenarioError.environment("cannot read the scenario catalog at \(url.path): \(error)")
        }
        let catalog: ScenarioCatalog
        do {
            catalog = try JSONDecoder().decode(ScenarioCatalog.self, from: data)
        } catch {
            throw ScenarioError.environment("cannot decode the scenario catalog at \(url.path): \(error)")
        }
        try validateAssertions(in: data)
        var resolved = catalog
        let rawScenarioDocuments: [Data]
        do {
            let root = try JSONSerialization.jsonObject(with: data)
            let rawScenarios = (root as? [String: Any])?["scenarios"] as? [[String: Any]] ?? []
            rawScenarioDocuments = try rawScenarios.map {
                try JSONSerialization.data(withJSONObject: $0,
                                           options: [.sortedKeys, .withoutEscapingSlashes])
            }
        } catch {
            throw ScenarioError.environment(
                "cannot preserve scenario catalog objects from \(url.path): \(error)")
        }
        for index in resolved.scenarios.indices where index < rawScenarioDocuments.count {
            resolved.scenarios[index].sourceDocument = rawScenarioDocuments[index]
        }
        for index in resolved.scenarios.indices {
            try resolved.scenarios[index].resolveBudgetReferences()
        }
        return resolved
    }

    /// Validates every scenario's declared perturbations against the execution
    /// target's capability matrix. Called immediately after the catalog is
    /// loaded and before any scenario runs (G2-FIX-65); a scenario with a
    /// declaration the target cannot execute is reported as runner-INFRA.
    public func perturbationRejections(
        capabilities: ScenarioPerturbationCapabilities = .current
    ) -> [String: ScenarioInfraRejection] {
        ScenarioPerturbationPreflight.rejections(in: scenarios,
                                                 capabilities: capabilities)
    }

    /// Strict assertion-schema validation over the raw catalog JSON.
    ///
    /// The typed decode has already proven the document shape; this pass sees
    /// the keys `Decodable` silently drops. A violation is a configuration
    /// error and fails the load before any scenario runs, naming the scenario
    /// id, assertion index, type and offending key.
    static func validateAssertions(in data: Data) throws {
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ScenarioError.environment(
                "cannot parse the scenario catalog for assertion validation: \(error)")
        }
        guard let document = root as? [String: Any],
              let rawScenarios = document["scenarios"] as? [Any] else {
            // The typed decode above already enforces the document shape.
            return
        }
        for (scenarioIndex, rawScenario) in rawScenarios.enumerated() {
            guard let scenario = rawScenario as? [String: Any] else { continue }
            let id = scenario["id"] as? String ?? "scenarios[\(scenarioIndex)]"
            guard let rawAssertions = scenario["assertions"] as? [Any] else { continue }
            for (index, rawAssertion) in rawAssertions.enumerated() {
                guard let assertion = rawAssertion as? [String: Any] else { continue }
                let type = assertion["type"] as? String ?? "<missing>"
                guard let allowed = Scenario.Assertion.allowedKeysByType[type] else {
                    throw ScenarioError.environment(
                        "scenario \(id) assertion[\(index)] (type \(type)): unknown "
                        + "assertion type; allowed types: "
                        + Scenario.Assertion.allowedKeysByType.keys.sorted()
                            .joined(separator: ", "))
                }
                if let key = Set(assertion.keys).subtracting(allowed).sorted().first {
                    throw ScenarioError.environment(
                        "scenario \(id) assertion[\(index)] (type \(type)): unknown key "
                        + "\"\(key)\"; allowed keys: "
                        + allowed.sorted().joined(separator: ", "))
                }
                let required = Scenario.Assertion.requiredKeysByType[type] ?? []
                for key in required.sorted()
                where assertion[key] == nil || assertion[key] is NSNull {
                    throw ScenarioError.environment(
                        "scenario \(id) assertion[\(index)] (type \(type)): missing "
                        + "required key \"\(key)\"")
                }
            }
        }
    }
}

/// One fixture's on-disk payload plus optional deterministic git history.
struct FixtureSpec: Decodable, Sendable {
    struct Git: Decodable, Sendable {
        struct Identity: Decodable, Sendable {
            /// `user.name` for the fixture's commits.
            var name: String
            /// `user.email` is assembled from these two fields at runtime, so
            /// no address is checked into the public tree.
            var emailUser: String
            var emailHost: String

            private enum CodingKeys: String, CodingKey {
                case name
                case emailUser = "email_user"
                case emailHost = "email_host"
            }

            var email: String { "\(emailUser)@\(emailHost)" }
        }

        struct Commit: Decodable, Sendable {
            var message: String
            /// Files (relative to the fixture payload) added or changed here.
            var files: [String]
        }

        var branch: String
        var identity: Identity?
        var commits: [Commit]
    }

    var name: String
    var description: String?
    var git: Git?
}

// MARK: - Staged configuration (iOS Simulator runner)

/// `Documents/pdsh-scenarios/config.json`, written by `scenarios.sh --run-on sim`.
///
/// The model credentials are deliberately not part of this document: the host
/// driver passes them only through the `xcodebuild` test-runner environment.
public struct StagedScenarioConfiguration: Decodable, Sendable {
    /// `mock` or `real`.
    public var upstream: String?
    /// Scenario ids selected for this batch.
    public var only: [String]?
    /// Optional tag filter.
    public var tag: String?
    /// Catalog target filter (`macos`, `sim` or `both`).
    public var target: String?
    /// Keep redacted model request/response bodies.
    public var keepBodies: Bool?

    private enum CodingKeys: String, CodingKey {
        case upstream, only, tag, target
        case keepBodies = "keep_bodies"
    }
}

// MARK: - Run environment

/// Everything the runner resolves for one test process.
///
/// The macOS path is resolved from the environment `scripts/ci/
/// scenarios.sh` exports; the iOS Simulator path is resolved from the staged
/// `Documents/pdsh-scenarios/` tree the same script copies into the probe app
/// container (`resolveStaged(root:workerBundle:environment:fileManager:)`).
public struct ScenarioEnvironment: Sendable {
    public let repoRoot: URL
    public let catalogURL: URL
    public let resultsRoot: URL
    public let fixturesRoot: URL
    public let only: [String]
    public let tag: String?
    public let target: String
    public let upstream: String
    public let keepBodies: Bool
    public let staticDirectory: URL
    public let imageArchive: URL
    /// `host` or `host:port` of the real model endpoint (nil for mock).
    public let modelBaseURL: URL?
    public let modelName: String?
    public let modelAPIKey: String?

    public var isRealUpstream: Bool { upstream == "real" }

    /// The perturbation capability matrix of the process executing this run.
    /// Resolved from the physical target (`#if os(macOS)` / simulator) and the
    /// watcher arming flag; see ``ScenarioPerturbationCapabilities``.
    public var perturbationCapabilities: ScenarioPerturbationCapabilities {
        ScenarioPerturbationCapabilities.current
    }

    /// macOS `swift test` path: every input comes from the launcher environment.
    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment,
                               fileManager: FileManager = .default) throws -> ScenarioEnvironment {
        let rootPath = environment["PDSH_SCENARIO_ROOT"]
            ?? Self.defaultRepoRoot
        let repoRoot = URL(fileURLWithPath: rootPath, isDirectory: true)
        let catalogURL = URL(fileURLWithPath: environment["PDSH_SCENARIO_CATALOG"]
            ?? repoRoot.appendingPathComponent("scripts/ci/scenarios/catalog.json").path)
        let resultsRoot = URL(fileURLWithPath: environment["PDSH_SCENARIO_RESULTS"]
            ?? fileManager.temporaryDirectory.appendingPathComponent("pdsh-scenarios").path,
                              isDirectory: true)
        let fixturesRoot = URL(fileURLWithPath: environment["PDSH_SCENARIO_FIXTURES"]
            ?? repoRoot.appendingPathComponent("scripts/ci/scenarios/fixtures").path,
                               isDirectory: true)
        let only = (environment["PDSH_SCENARIO_ONLY"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let upstream = environment["PDSH_SCENARIO_UPSTREAM"] ?? "mock"
        guard upstream == "mock" || upstream == "real" else {
            throw ScenarioError.environment("PDSH_SCENARIO_UPSTREAM must be mock or real")
        }
        guard let staticPath = environment["PDSH_DSH_WWW"], !staticPath.isEmpty else {
            throw ScenarioError.environment(
                "PDSH_DSH_WWW is not exported; run scenarios.sh (it builds the Worker bundle)")
        }
        guard let imagePath = environment["PDSH_DSH_IMAGE"], !imagePath.isEmpty else {
            throw ScenarioError.environment(
                "PDSH_DSH_IMAGE is not exported; run scenarios.sh (it builds the Worker image)")
        }
        let staticDirectory = URL(fileURLWithPath: staticPath, isDirectory: true)
        let imageArchive = URL(fileURLWithPath: imagePath)
        try validateBundle(staticDirectory: staticDirectory,
                           imageArchive: imageArchive,
                           fileManager: fileManager)
        let credentials = try resolveCredentials(upstream: upstream, environment: environment)

        try fileManager.createDirectory(at: resultsRoot, withIntermediateDirectories: true)
        return ScenarioEnvironment(
            repoRoot: repoRoot,
            catalogURL: catalogURL,
            resultsRoot: resultsRoot,
            fixturesRoot: fixturesRoot,
            only: only,
            tag: environment["PDSH_SCENARIO_TAG"].flatMap { $0.isEmpty ? nil : $0 },
            target: environment["PDSH_SCENARIO_TARGET"] ?? "macos",
            upstream: upstream,
            keepBodies: environment["PDSH_SCENARIO_KEEP_BODIES"] == "1",
            staticDirectory: staticDirectory,
            imageArchive: imageArchive,
            modelBaseURL: credentials.baseURL,
            modelName: credentials.name,
            modelAPIKey: credentials.key)
    }

    /// iOS Simulator path: the same catalog/fixtures and report tree, staged by
    /// the host driver into the probe app container.
    ///
    /// `root` is the app container's `Documents/pdsh-scenarios/`; the Worker
    /// bundle comes from the installed probe app (`Bundle/worker`) rather than
    /// from host paths the simulator sandbox cannot read. Model credentials are
    /// read only from the test-runner environment: `xcodebuild` exports
    /// `TEST_RUNNER_PDSH_MODEL_*` to the test runner (the prefix is stripped in
    /// the runner), and the `simctl spawn` fallback exports `PDSH_MODEL_*`
    /// through `SIMCTL_CHILD_`. Both spellings are accepted; neither is ever
    /// written to a staged file or a report.
    public static func resolveStaged(
        root: URL,
        workerBundle: PhoneDSHBundleLocation,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> ScenarioEnvironment {
        let catalogURL = root.appendingPathComponent("catalog.json")
        guard fileManager.fileExists(atPath: catalogURL.path) else {
            throw ScenarioError.environment(
                "the staged scenario catalog is missing: \(catalogURL.path)")
        }
        let configurationURL = root.appendingPathComponent("config.json")
        let configuration: StagedScenarioConfiguration
        if fileManager.fileExists(atPath: configurationURL.path) {
            do {
                configuration = try JSONDecoder().decode(
                    StagedScenarioConfiguration.self,
                    from: Data(contentsOf: configurationURL))
            } catch {
                throw ScenarioError.environment(
                    "cannot decode the staged runner configuration: \(error)")
            }
        } else {
            configuration = StagedScenarioConfiguration()
        }
        let upstream = configuration.upstream ?? "mock"
        guard upstream == "mock" || upstream == "real" else {
            throw ScenarioError.environment("staged upstream must be mock or real")
        }
        let imageArchive = workerBundle.imageArchive
        try validateBundle(staticDirectory: workerBundle.staticDirectory,
                           imageArchive: imageArchive,
                           fileManager: fileManager)
        let credentials = try resolveCredentials(upstream: upstream, environment: environment)
        let resultsRoot = root.appendingPathComponent("results", isDirectory: true)
        try fileManager.createDirectory(at: resultsRoot, withIntermediateDirectories: true)
        return ScenarioEnvironment(
            repoRoot: root,
            catalogURL: catalogURL,
            resultsRoot: resultsRoot,
            fixturesRoot: root.appendingPathComponent("fixtures", isDirectory: true),
            only: configuration.only ?? [],
            tag: configuration.tag.flatMap { $0.isEmpty ? nil : $0 },
            target: configuration.target ?? "both",
            upstream: upstream,
            keepBodies: configuration.keepBodies ?? false,
            staticDirectory: workerBundle.staticDirectory,
            imageArchive: imageArchive,
            modelBaseURL: credentials.baseURL,
            modelName: credentials.name,
            modelAPIKey: credentials.key)
    }

    // MARK: Resolution helpers

    private static func validateBundle(staticDirectory: URL, imageArchive: URL,
                                       fileManager: FileManager) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: staticDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ScenarioError.environment(
                "the Worker static directory is not a directory: \(staticDirectory.path)")
        }
        for required in ["index.html", "boot.js", "worker-entry.js"] {
            guard fileManager.fileExists(atPath: staticDirectory.appendingPathComponent(required).path) else {
                throw ScenarioError.environment("the Worker bundle has no \(required)")
            }
        }
        guard fileManager.fileExists(atPath: imageArchive.path) else {
            throw ScenarioError.environment(
                "the Worker image does not exist: \(imageArchive.path)")
        }
    }

    private struct Credentials {
        var baseURL: URL?
        var name: String?
        var key: String?
    }

    private static func resolveCredentials(
        upstream: String,
        environment: [String: String]
    ) throws -> Credentials {
        guard upstream == "real" else { return Credentials() }
        func value(_ name: String) -> String? {
            // xcodebuild may or may not strip the TEST_RUNNER_ prefix; the
            // simctl fallback exports the bare name through SIMCTL_CHILD_.
            for key in ["TEST_RUNNER_\(name)", name] {
                if let value = environment[key], !value.isEmpty { return value }
            }
            return nil
        }
        guard let base = value("PDSH_MODEL_BASE_URL"),
              let url = URL(string: base), let host = url.host, !host.isEmpty else {
            throw ScenarioError.environment(
                "PDSH_MODEL_BASE_URL is missing or invalid; run: eval \"$(node scripts/ci/model-env.mjs)\"")
        }
        guard let name = value("PDSH_MODEL_NAME") else {
            throw ScenarioError.environment(
                "PDSH_MODEL_NAME is missing; run: eval \"$(node scripts/ci/model-env.mjs)\"")
        }
        guard let key = value("PDSH_MODEL_API_KEY") else {
            throw ScenarioError.environment(
                "PDSH_MODEL_API_KEY is missing; run: eval \"$(node scripts/ci/model-env.mjs)\"")
        }
        return Credentials(baseURL: url, name: name, key: key)
    }

    /// `#filePath` is `Sources/PhoneDSHScenario/<file>`; three
    /// parents up is the package root, a fourth is the repository root.
    /// Walks up from this source file instead of counting parent hops, so the
    /// runner keeps working when the extracted package drops the `sdk/` level.
    private static var defaultRepoRoot: String {
        guard let root = scenarioRepositoryRoot(startingAt: URL(fileURLWithPath: #filePath)) else {
            preconditionFailure("cannot locate the scenario repository root from #filePath")
        }
        return root.path
    }

    /// Applies `--only`, `--tag` and `--target` to a catalog.
    public func select(from catalog: ScenarioCatalog) -> [Scenario] {
        var scenarios = catalog.scenarios
        if !only.isEmpty {
            let wanted = Set(only)
            scenarios = scenarios.filter { wanted.contains($0.id) }
        }
        if let tag {
            scenarios = scenarios.filter { ($0.tags ?? []).contains(tag) }
        }
        switch target {
        case "macos":
            scenarios = scenarios.filter { $0.target != "sim" }
        case "sim":
            scenarios = scenarios.filter { $0.target != "macos" }
        default:
            break
        }
        return scenarios
    }
}

// MARK: - Errors

/// A fail-loud scenario-runner error.
public enum ScenarioError: Error, CustomStringConvertible {
    case environment(String)
    case artifact(String)
    case timeout(String)
    case budget(String)
    case perturbation(String)
    case assertion(String)
    /// The runner cannot execute the scenario on this target (an unsupported
    /// perturbation kind/point or an unarmed mechanism). This is a
    /// test-infrastructure result, not a product failure (G2-FIX-65).
    case infra(String)

    public var description: String {
        switch self {
        case .environment(let detail): return "environment: \(detail)"
        case .artifact(let detail): return "artifact: \(detail)"
        case .timeout(let detail): return "timeout: \(detail)"
        case .budget(let detail): return "budget: \(detail)"
        case .perturbation(let detail): return "perturbation: \(detail)"
        case .assertion(let detail): return "assertion: \(detail)"
        case .infra(let detail):
            return "\(ScenarioInfraRejection.classification): \(detail)"
        }
    }
}
