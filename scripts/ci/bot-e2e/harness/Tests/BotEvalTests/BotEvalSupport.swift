// SPDX-License-Identifier: MIT
// phone-dsh Bot eval runner — host-side support: scripted upstream helpers,
// credential routing, VFS seeding, JSONL evidence and small value types.

import AppKit
import CryptoKit
import Foundation
import PhoneDSH
import PhoneDSHBot
import PhoneDSHHarness
import PhoneDSHLog
import PhoneDSHScenario
import PhoneDSHWire
import PhoneDSHAgentCore

enum EvalRunnerError: LocalizedError {
    case invalid(String)
    case timeout(String)
    case unimplemented(String)
    case action(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let detail): return detail
        case .timeout(let detail): return "timeout: \(detail)"
        case .unimplemented(let detail): return "unimplemented: \(detail)"
        case .action(let detail): return detail
        }
    }

    var isUnimplemented: Bool {
        if case .unimplemented = self { return true }
        return false
    }
}

/// Routes the real model key only to the configured model host. Egress hosts a
/// scenario explicitly allows get an anonymous credential, exactly like the G2
/// runner; every other host is denied. The live key is never logged.
final class EvalModelCredentialProvider: CredentialProvider, @unchecked Sendable {
    private let lock = NSLock()
    private let modelHost: String
    private let modelKey: String
    private let anonymousHosts: Set<String>
    private var modelAttempts = 0
    private var deniedHosts = 0

    init(modelBaseURL: URL, modelKey: String, anonymousHosts: Set<String>) {
        self.modelHost = Self.bareHost(modelBaseURL.absoluteString)
        self.modelKey = modelKey
        self.anonymousHosts = Set(anonymousHosts.map(Self.bareHost))
    }

    var modelRequests: Int {
        lock.lock()
        defer { lock.unlock() }
        return modelAttempts
    }

    var denied: Int {
        lock.lock()
        defer { lock.unlock() }
        return deniedHosts
    }

    func credential(for scope: CredentialScope) async throws -> Credential {
        let host = Self.bareHost(scope.service)
        if host == modelHost {
            lock.lock()
            modelAttempts += 1
            lock.unlock()
            return Credential(kind: .apiKey(header: "x-api-key"), value: modelKey)
        }
        if anonymousHosts.contains(host) {
            return .none
        }
        lock.lock()
        deniedHosts += 1
        lock.unlock()
        throw ProviderError.unauthorized("host \(host) is not on this scenario's allow-list")
    }

    func invalidate(_ credential: Credential, for scope: CredentialScope) async {}

    static func bareHost(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let separator = value.range(of: "://") {
            value = String(value[separator.upperBound...])
        }
        if let slash = value.firstIndex(of: "/") {
            value = String(value[..<slash])
        }
        if let colon = value.lastIndex(of: ":"), value.filter({ $0 == ":" }).count == 1 {
            let port = value[value.index(after: colon)...]
            if port.allSatisfy({ $0.isNumber }) {
                value = String(value[..<colon])
            }
        }
        return value
    }
}

struct EvalSeed {
    var path: String
    var data: Data
}

enum EvalWorkspaceSeed {
    static func collect(scenario: EvalScenario, fixturesRoot: URL) throws -> [EvalSeed] {
        var seeds: [String: Data] = [:]
        if let fixture = scenario.workspace.fixture, !fixture.isEmpty {
            let directory = fixturesRoot.appendingPathComponent(fixture, isDirectory: true)
            var payload = directory
            let files = directory.appendingPathComponent("files", isDirectory: true)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: files.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                payload = files
            }
            guard FileManager.default.fileExists(atPath: payload.path) else {
                throw EvalRunnerError.invalid("fixture \(fixture) not found at \(payload.path)")
            }
            let keys: [URLResourceKey] = [.isRegularFileKey]
            guard let enumerator = FileManager.default.enumerator(
                at: payload, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
                throw EvalRunnerError.invalid("cannot enumerate fixture \(fixture)")
            }
            let prefix = payload.standardizedFileURL.path + "/"
            for case let url as URL in enumerator {
                let values = try? url.resourceValues(forKeys: Set(keys))
                guard values?.isRegularFile == true else { continue }
                let full = url.standardizedFileURL.path
                guard full.hasPrefix(prefix) else { continue }
                let relative = String(full.dropFirst(prefix.count))
                if relative == "fixture.json" { continue }
                seeds[relative] = try Data(contentsOf: url)
            }
        }
        for (path, content) in scenario.workspace.files {
            try validateRelative(path)
            seeds[path] = Data(content.utf8)
        }
        return seeds.keys.sorted().map { EvalSeed(path: $0, data: seeds[$0] ?? Data()) }
    }

    static func validateRelative(_ path: String) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("\\") else {
            throw EvalRunnerError.invalid("workspace path must be relative: \(path)")
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.contains("..") else {
            throw EvalRunnerError.invalid("workspace path escapes the Bot root: \(path)")
        }
    }

    static func vfsPath(for seed: EvalSeed, scenario: EvalScenario, botID: String) -> String {
        if scenario.workspace.root == "host" {
            return "/dsh/workspace/\(seed.path)"
        }
        return "/dsh/workspace/\(BotWorkspaceLayout.botRoot(botId: botID).dropFirst("/dsh/workspace/".count))/\(seed.path)"
    }

    /// Seeds a fresh host workspace through the landed WAL, before the host
    /// boots. This is the G2 seeding path, not a host-filesystem copy.
    static func seed(workspaceRoot: URL, seeds: [EvalSeed], scenario: EvalScenario,
                     botID: String) async throws {
        guard !seeds.isEmpty else { return }
        if FileManager.default.fileExists(atPath: workspaceRoot.path) {
            try FileManager.default.removeItem(at: workspaceRoot)
        }
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        var bootID = Data(count: 16)
        for index in 0..<bootID.count { bootID[index] = UInt8.random(in: 0...255) }
        let log = try WorkspaceLog(
            configuration: WorkspaceLogConfiguration(root: workspaceRoot), bootID: bootID)
        _ = try await log.recover()
        for seed in seeds {
            let path = vfsPath(for: seed, scenario: scenario, botID: botID)
            let mutation = VfsMutationBody(op: .write, mode: 0o644, path: path, data: seed.data)
            _ = try await log.append(mutation)
        }
        _ = try await log.closeEpoch()
    }

    /// After the host is running a newly created Bot's materialized root is the
    /// only writable copy of its workspace. This fallback is deliberately
    /// limited to `workspace.bot` aliases created inside the scenario; the main
    /// Bot and host-root seeds always go through the WAL above.
    static func seedMaterialized(workspaceRoot: URL, seeds: [EvalSeed], scenario: EvalScenario,
                                 botID: String) throws {
        guard !seeds.isEmpty, scenario.workspace.root != "host" else { return }
        let root = workspaceRoot
            .appendingPathComponent("materialized/workspace", isDirectory: true)
            .appendingPathComponent(
                String(BotWorkspaceLayout.botRoot(botId: botID).dropFirst("/dsh/workspace/".count)),
                isDirectory: true)
        for seed in seeds {
            let url = root.appendingPathComponent(seed.path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try seed.data.write(to: url)
        }
    }

    static func materializedWorkspaces(workspaceRoot: URL) -> URL {
        workspaceRoot.appendingPathComponent("materialized/workspace", isDirectory: true)
    }
}

/// Session kinds a `tool_surface` assertion can select. `main` is the default.
/// The eval host does not link the Rust `pdsh-shell`, so the production
/// `phone record` accelerator would be absent and a verifier could never read
/// the raw records its contract requires. This provider serves exactly the
/// `phone record search|read` argv through the same BotRecordService the App
/// uses; every other argv fails closed. It is a test-host seam, not a product
/// wire surface.
struct EvalPhoneRecordExecProvider: ExecProvider {
    let service: BotRecordService
    static let sessionKey = "PDSH_TOOL_CALL_SESSION"

    var capabilities: ExecCapabilities {
        ExecCapabilities(environment: "bot-eval record bridge", network: false,
                         persistentWorkspace: true, tiers: [.interactive, .session, .batch])
    }

    func run(_ request: ExecRequest) -> AsyncThrowingStream<ExecEvent, Error> {
        AsyncThrowingStream { continuation in
            guard request.argv.first == "phone", request.argv.count >= 3,
                  request.argv[1] == "record" else {
                continuation.yield(.stderr(
                    seq: 0, data: Data("phone: this eval host only serves `phone record search|read`\n".utf8)))
                continuation.yield(.exit(code: 64, signal: nil, truncated: false))
                continuation.finish()
                return
            }
            guard let session = request.env[Self.sessionKey], !session.isEmpty else {
                continuation.yield(.stderr(
                    seq: 0, data: Data("phone: record requires a claimed tool-call session\n".utf8)))
                continuation.yield(.exit(code: 1, signal: nil, truncated: false))
                continuation.finish()
                return
            }
            let arguments = Array(request.argv.dropFirst(2))
            let service = self.service
            Task {
                let output = await BotRecordService.bridge(
                    arguments: arguments, callerSessionID: session, service: service)
                if !output.stdout.isEmpty {
                    continuation.yield(.stdout(seq: 0, data: Data(output.stdout.utf8)))
                }
                if !output.stderr.isEmpty {
                    continuation.yield(.stderr(seq: 1, data: Data(output.stderr.utf8)))
                }
                continuation.yield(.exit(code: output.exitCode, signal: nil, truncated: false))
                continuation.finish()
            }
        }
    }

    func cancel(execID: String) async {}
}

enum EvalSessionKinds {
    static let main = "main"
    static let task = "task"
    static let verifier = "verifier"
    static let maintainer = "maintainer"
    static let all = [main, task, verifier, maintainer]
}

enum EvalMockScripts {
    static func script(for mock: EvalMock?, fallback: String = "BOT_EVAL_OK") -> MockModelScript {
        guard let mock else {
            return .sequence(tools: [], finalText: fallback)
        }
        let finalText = mock.finalText ?? fallback
        if let tools = mock.tools {
            return .sequence(
                tools: tools.map { MockModelToolCall(name: $0.name, arguments: $0.arguments) },
                finalText: finalText)
        }
        if let tool = mock.tool {
            let data = (try? tool.arguments.encoded()) ?? Data("{}".utf8)
            return .tool(name: tool.name, argumentsJSON: data, finalText: finalText)
        }
        return .sequence(tools: [], finalText: finalText)
    }

    static func promptRules(_ mock: EvalMock?) -> [EvalPromptRule] {
        mock?.promptRules ?? []
    }

    /// Classify one recorded model request by the host-minted session kind
    /// that produced it. The title request runs before the turn and carries
    /// the same first user message, so both fall into the same bucket.
    ///
    /// The markers are the host-built prompt envelopes and preset personas:
    /// the verifier gets `<verification_request>` and the read-only persona;
    /// the maintainer gets its batch prompt and memory-maintainer persona; a
    /// Task session gets `<task_authorization>`/`<task_contract>`. Everything
    /// else is the ordinary main chat.
    static func sessionKind(from body: Data) -> String {
        let text = String(decoding: body, as: UTF8.self)
        if text.contains("<verification_request>")
            || text.contains("You are a read-only verifier") {
            return EvalSessionKinds.verifier
        }
        if text.contains("这次后台整理是一个批次") || text.contains("记忆维护者") {
            return EvalSessionKinds.maintainer
        }
        if text.contains("<task_authorization>") || text.contains("<task_contract>") {
            return EvalSessionKinds.task
        }
        return EvalSessionKinds.main
    }

    /// Tool names the model request advertised (`tools[].name`). The Bot eval
    /// uses this as the model-facing tool surface: the Worker's tools/list is
    /// what a turn actually runs with, regardless of session storage format.
    static func advertisedTools(from body: Data) -> Set<String> {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let tools = object["tools"] as? [[String: Any]] else { return [] }
        return Set(tools.compactMap { $0["name"] as? String })
    }

    static func lastUserText(from body: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let messages = object["messages"] as? [[String: Any]] else { return "" }
        for message in messages.reversed() where (message["role"] as? String) == "user" {
            if let text = message["content"] as? String { return text }
            guard let content = message["content"] as? [[String: Any]] else { continue }
            return content.compactMap { block -> String? in
                guard (block["type"] as? String) == "text" else { return nil }
                return block["text"] as? String
            }.joined()
        }
        return ""
    }

    static func ruleScript(for rules: [EvalPromptRule], body: Data) -> MockModelScript? {
        let prompt = lastUserText(from: body)
        guard !rules.isEmpty else { return nil }
        for rule in rules where prompt.contains(rule.contains) {
            return .sequence(tools: [], finalText: replacingRecordRef(rule.finalText, in: prompt))
        }
        return nil
    }

    /// Scripted verifier output cannot know a runtime session id. The eval
    /// harness lets one rule echo the last canonical record:// reference the
    /// host itself supplied in the prompt; the host still validates existence.
    static func replacingRecordRef(_ text: String, in prompt: String) -> String {
        guard text.contains("{{record_ref}}") else { return text }
        let pattern = try? NSRegularExpression(
            pattern: #"record://(session/[A-Za-z0-9._-]{1,64}#[0-9]+|event/[0-9]+)"#)
        let range = NSRange(prompt.startIndex..<prompt.endIndex, in: prompt)
        let matches = pattern?.matches(in: prompt, range: range) ?? []
        guard let match = matches.last,
              let matchRange = Range(match.range, in: prompt) else {
            return text.replacingOccurrences(of: "{{record_ref}}", with: "record://event/1")
        }
        return text.replacingOccurrences(of: "{{record_ref}}", with: String(prompt[matchRange]))
    }
}

/// One JSONL writer. The runner opens it before the first repeat so a failed
/// repeat still leaves the lines already emitted.
final class EvalJSONLWriter {
    let url: URL
    private let handle: FileHandle
    private let redactor: (String) -> String

    init(url: URL, redactor: @escaping (String) -> String) throws {
        self.url = url
        self.redactor = redactor
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: url.path) else {
            throw EvalRunnerError.invalid("cannot open \(url.path) for writing")
        }
        self.handle = handle
    }

    func append(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys]),
            var text = String(data: data, encoding: .utf8) else {
            return
        }
        text = redactor(text)
        data = Data((text + "\n").utf8)
        try? handle.write(contentsOf: data)
    }

    func close() {
        try? handle.close()
    }
}

enum EvalJSON {
    static func date(_ date: Date = Date()) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    static func write(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    static func eventObject(_ event: BotEvent) -> Any? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(event),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return object
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
