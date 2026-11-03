// SPDX-License-Identifier: MIT

import Foundation

public enum MainConversationRole: String, Codable, Sendable {
    case user
    case assistant
}

public struct MainConversationMessage: Codable, Sendable, Equatable {
    public let id: UUID
    public let sequence: Int
    public let role: MainConversationRole
    public let text: String
    public let createdAt: Date

    public init(id: UUID = UUID(), sequence: Int, role: MainConversationRole,
                text: String, createdAt: Date = Date()) {
        self.id = id
        self.sequence = sequence
        self.role = role
        self.text = text
        self.createdAt = createdAt
    }
}

public struct MainContextDocument: Codable, Sendable, Equatable {
    public let id: String
    public let sourceRef: String
    public let revision: Int
    public let text: String

    public init(id: String, sourceRef: String, revision: Int, text: String) {
        self.id = id
        self.sourceRef = sourceRef
        self.revision = revision
        self.text = text
    }
}

public struct MainArtifactContext: Codable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let locator: String

    public init(id: String, title: String, locator: String) {
        self.id = id
        self.title = title
        self.locator = locator
    }
}

public struct MainConversationSummary: Codable, Sendable, Equatable {
    public let summaryID: UUID
    public let coveredRange: ClosedRange<Int>
    public let revision: Int
    public let sourceCursor: String
    public let text: String

    public init(summaryID: UUID = UUID(), coveredRange: ClosedRange<Int>, revision: Int,
                sourceCursor: String, text: String) {
        self.summaryID = summaryID
        self.coveredRange = coveredRange
        self.revision = revision
        self.sourceCursor = sourceCursor
        self.text = text
    }
}

public struct MainConversationSnapshot: Sendable {
    public let currentText: String
    public let mandate: WorkMandate?
    public let followUps: [FollowUp]
    public let pendingQuestions: [PendingQuestion]
    public let messages: [MainConversationMessage]
    public let rollingSummary: MainConversationSummary?
    public let memory: [MainContextDocument]
    public let connectorDocuments: [MainContextDocument]
    public let userConstraints: [String]
    public let currentArtifacts: [MainArtifactContext]
    public let pendingReconciliations: [String]
    public let responseStylePrompt: String
    public let runtimeContext: MainRuntimeContext?
    public let currentLanguage: String?
    public let toolSchemas: [AnthropicTool]

    public init(currentText: String, mandate: WorkMandate? = nil, followUps: [FollowUp] = [],
                pendingQuestions: [PendingQuestion] = [], messages: [MainConversationMessage] = [],
                rollingSummary: MainConversationSummary? = nil, memory: [MainContextDocument] = [],
                connectorDocuments: [MainContextDocument] = [], userConstraints: [String] = [],
                currentArtifacts: [MainArtifactContext] = [], pendingReconciliations: [String] = [],
                responseStylePrompt: String = "", runtimeContext: MainRuntimeContext? = nil,
                currentLanguage: String? = nil, toolSchemas: [AnthropicTool] = []) {
        self.currentText = currentText
        self.mandate = mandate
        self.followUps = followUps
        self.pendingQuestions = pendingQuestions
        self.messages = messages.sorted { $0.sequence < $1.sequence }
        self.rollingSummary = rollingSummary
        self.memory = memory
        self.connectorDocuments = connectorDocuments
        self.userConstraints = userConstraints
        self.currentArtifacts = currentArtifacts
        self.pendingReconciliations = pendingReconciliations
        self.responseStylePrompt = responseStylePrompt
        self.runtimeContext = runtimeContext
        self.currentLanguage = currentLanguage
        self.toolSchemas = toolSchemas
    }

    public func resolvingRuntimeContext(descriptors: [ConnectorToolDescriptor] = [],
                                        toolSchemas: [AnthropicTool]? = nil) throws
    -> MainConversationSnapshot {
        let runtime = try (runtimeContext ?? MainRuntimeContext()).resolving(
            currentLanguage: currentLanguage, descriptors: descriptors)
        return MainConversationSnapshot(
            currentText: currentText, mandate: mandate, followUps: followUps,
            pendingQuestions: pendingQuestions, messages: messages, rollingSummary: rollingSummary,
            memory: memory, connectorDocuments: connectorDocuments, userConstraints: userConstraints,
            currentArtifacts: currentArtifacts, pendingReconciliations: pendingReconciliations,
            responseStylePrompt: responseStylePrompt, runtimeContext: runtime,
            currentLanguage: currentLanguage, toolSchemas: toolSchemas ?? self.toolSchemas)
    }
}

public struct MainContextBudget: Sendable, Equatable {
    public let totalBytes: Int
    public let protectedBytes: Int
    public let recentBytes: Int
    public let summaryBytes: Int
    public let externalBytes: Int

    public init(totalBytes: Int = 64_000, protectedBytes: Int = 12_000,
                recentBytes: Int = 24_000, summaryBytes: Int = 12_000,
                externalBytes: Int = 16_000) {
        self.totalBytes = totalBytes
        self.protectedBytes = protectedBytes
        self.recentBytes = recentBytes
        self.summaryBytes = summaryBytes
        self.externalBytes = externalBytes
    }

    public static let tokenEstimationMethod = "ceil(UTF-8 bytes / 4), minimum one token per nonempty section"

    public func estimatedTokens(utf8Bytes: Int) -> Int {
        utf8Bytes == 0 ? 0 : max(1, (utf8Bytes + 3) / 4)
    }

    func validated() throws -> MainContextBudget {
        let fields = [totalBytes, protectedBytes, recentBytes, summaryBytes, externalBytes]
        guard fields.allSatisfy({ $0 > 0 }),
              protectedBytes + recentBytes + summaryBytes + externalBytes <= totalBytes else {
            throw MainFailure.invalidResponse("invalid Main context byte budgets")
        }
        return self
    }
}

public struct MainAssembledContext: Sendable {
    public let systemPrompt: String
    public let messages: [AnthropicMessage]
    public let estimatedTokens: Int
    public let tokenEstimationMethod: String
    public let recentMessages: [MainConversationMessage]
    public let rollingSummary: MainConversationSummary?
    public let coreBytes: Int
    public let runtimeContextBytes: Int
    public let toolSchemaBytes: Int
    public let messageBytes: Int
    public let totalBytes: Int
    public let byteBudget: Int

    public init(systemPrompt: String, messages: [AnthropicMessage], estimatedTokens: Int,
                tokenEstimationMethod: String, recentMessages: [MainConversationMessage],
                rollingSummary: MainConversationSummary?, coreBytes: Int = 0, runtimeContextBytes: Int = 0,
                toolSchemaBytes: Int = 0, messageBytes: Int = 0, totalBytes: Int? = nil,
                byteBudget: Int = Int.max) {
        self.systemPrompt = systemPrompt
        self.messages = messages
        self.estimatedTokens = estimatedTokens
        self.tokenEstimationMethod = tokenEstimationMethod
        self.recentMessages = recentMessages
        self.rollingSummary = rollingSummary
        self.coreBytes = coreBytes
        self.runtimeContextBytes = runtimeContextBytes
        self.toolSchemaBytes = toolSchemaBytes
        self.messageBytes = messageBytes
        self.totalBytes = totalBytes ?? systemPrompt.utf8.count + toolSchemaBytes + messageBytes
        self.byteBudget = byteBudget
    }

    public func replacingMessages(_ messages: [AnthropicMessage], tools: [AnthropicTool]) throws
    -> MainAssembledContext {
        let messageBytes = try AnthropicMessagesRequest.encodedMessages(messages).count
        let toolSchemaBytes = try AnthropicMessagesRequest.encodedTools(tools).count
        let totalBytes = systemPrompt.utf8.count + toolSchemaBytes + messageBytes
        guard totalBytes <= byteBudget else {
            throw MainFailure.invalidResponse("Main messages and tool schemas exceed the context byte budget")
        }
        return MainAssembledContext(
            systemPrompt: systemPrompt, messages: messages,
            estimatedTokens: MainContextBudget().estimatedTokens(utf8Bytes: totalBytes),
            tokenEstimationMethod: tokenEstimationMethod, recentMessages: recentMessages,
            rollingSummary: rollingSummary, coreBytes: coreBytes, runtimeContextBytes: runtimeContextBytes,
            toolSchemaBytes: toolSchemaBytes, messageBytes: messageBytes, totalBytes: totalBytes,
            byteBudget: byteBudget)
    }
}

public struct MainSummaryGenerationRequest: Sendable {
    public let previousSummary: MainConversationSummary?
    public let messages: [MainConversationMessage]
    public let mandate: WorkMandate?
    public let pendingQuestions: [PendingQuestion]
    public let userConstraints: [String]
    public let currentArtifacts: [MainArtifactContext]
    public let pendingReconciliations: [String]

    public init(previousSummary: MainConversationSummary?, messages: [MainConversationMessage],
                mandate: WorkMandate?, pendingQuestions: [PendingQuestion], userConstraints: [String],
                currentArtifacts: [MainArtifactContext], pendingReconciliations: [String]) {
        self.previousSummary = previousSummary
        self.messages = messages
        self.mandate = mandate
        self.pendingQuestions = pendingQuestions
        self.userConstraints = userConstraints
        self.currentArtifacts = currentArtifacts
        self.pendingReconciliations = pendingReconciliations
    }
}

public protocol MainSummaryGenerating: Sendable {
    func summarize(_ request: MainSummaryGenerationRequest) async throws -> String
}

public struct DeterministicMainSummaryGenerator: MainSummaryGenerating {
    public init() {}

    public func summarize(_ request: MainSummaryGenerationRequest) async throws -> String {
        guard !request.messages.isEmpty else {
            throw MainFailure.invalidResponse("cannot summarize an empty conversation range")
        }
        var lines: [String] = []
        if let previous = request.previousSummary {
            lines.append("Previous summary revision \(previous.revision): \(previous.text)")
        }
        lines.append("Conversation transcript:")
        for message in request.messages {
            lines.append("[\(message.sequence)] \(message.role.rawValue): \(message.text)")
        }
        if !request.userConstraints.isEmpty {
            lines.append("User constraints: " + request.userConstraints.joined(separator: " | "))
        }
        if !request.pendingQuestions.isEmpty {
            lines.append("Pending questions: " + request.pendingQuestions.map { "\($0.id): \($0.text)" }
                .joined(separator: " | "))
        }
        if !request.currentArtifacts.isEmpty {
            lines.append("Current artifacts: " + request.currentArtifacts.map { "\($0.id): \($0.locator)" }
                .joined(separator: " | "))
        }
        if !request.pendingReconciliations.isEmpty {
            lines.append("Pending reconciliation: " + request.pendingReconciliations.joined(separator: " | "))
        }
        if let mandate = request.mandate {
            lines.append("Mandate \(mandate.mandateID): \(Self.targetDescription(mandate.targets))")
        }
        return lines.joined(separator: "\n")
    }

    private static func targetDescription(_ targets: MandateTargets) -> String {
        "gmailThreads=\(targets.gmailThreadIDs), recipients=\(targets.recipientIdentities), "
            + "repository=\(targets.repository ?? ""), issues=\(targets.issueOrPRNumbers)"
    }
}

public struct MainCompactionResult: Sendable {
    public let context: MainAssembledContext
    public let summary: MainConversationSummary?
    public let originalMessages: [MainConversationMessage]

    public init(context: MainAssembledContext, summary: MainConversationSummary?,
                originalMessages: [MainConversationMessage]) {
        self.context = context
        self.summary = summary
        self.originalMessages = originalMessages
    }

    public func originalMessages(for summary: MainConversationSummary) -> [MainConversationMessage] {
        originalMessages.filter { summary.coveredRange.contains($0.sequence) }
            .sorted { $0.sequence < $1.sequence }
    }
}

public struct MainConversationCompactor: Sendable {
    private let budget: MainContextBudget
    private let summarizer: any MainSummaryGenerating

    public init(budget: MainContextBudget = MainContextBudget(),
                summarizer: any MainSummaryGenerating = DeterministicMainSummaryGenerator()) {
        self.budget = budget
        self.summarizer = summarizer
    }

    public func compact(_ snapshot: MainConversationSnapshot) async throws -> MainCompactionResult {
        let budget = try budget.validated()
        let protected = try Self.protectedSection(snapshot)
        guard protected.utf8.count + snapshot.currentText.utf8.count <= budget.protectedBytes else {
            throw MainFailure.invalidResponse("current task constraints exceed the protected context budget")
        }
        let runtime = try (snapshot.runtimeContext ?? MainRuntimeContext()).resolving(
            currentLanguage: snapshot.currentLanguage)
        let runtimeJSON = try runtime.encodedEnvelope()
        let messageBytes = try AnthropicMessagesRequest.encodedMessages([.text(snapshot.currentText)]).count
        let toolSchemaBytes = try AnthropicMessagesRequest.encodedTools(snapshot.toolSchemas).count
        let fixedBytes = PersonalAgentCorePrompt.utf8Bytes + runtimeJSON.utf8.count
            + protected.utf8.count + messageBytes + toolSchemaBytes
        let variableBytes = budget.totalBytes - fixedBytes - 1_024
        guard variableBytes >= 0 else {
            throw MainFailure.invalidResponse("core, runtime, task, tools and request exceed the context byte budget")
        }
        let limits = Self.variableBudgets(available: variableBytes, budget: budget)
        let external = Self.externalSection(memory: snapshot.memory,
                                            connectors: snapshot.connectorDocuments,
                                            byteLimit: limits.external)
        let recent = Self.recentMessages(snapshot.messages, byteLimit: limits.recent)
        let recentSequences = Set(recent.map(\.sequence))
        let older = snapshot.messages.filter { !recentSequences.contains($0.sequence) }
        var summary = snapshot.rollingSummary
        if !older.isEmpty {
            do {
                let generated = try await summarizer.summarize(MainSummaryGenerationRequest(
                    previousSummary: snapshot.rollingSummary, messages: older, mandate: snapshot.mandate,
                    pendingQuestions: snapshot.pendingQuestions, userConstraints: snapshot.userConstraints,
                    currentArtifacts: snapshot.currentArtifacts,
                    pendingReconciliations: snapshot.pendingReconciliations))
                guard !generated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let first = older.first, let last = older.last else {
                    throw MainFailure.invalidResponse("conversation summary is empty")
                }
                let lower = min(snapshot.rollingSummary?.coveredRange.lowerBound ?? first.sequence,
                                first.sequence)
                summary = MainConversationSummary(
                    summaryID: snapshot.rollingSummary?.summaryID ?? UUID(),
                    coveredRange: lower...last.sequence,
                    revision: (snapshot.rollingSummary?.revision ?? 0) + 1,
                    sourceCursor: last.id.uuidString,
                    text: generated)
            } catch let failure as MainFailure {
                throw failure
            } catch {
                throw MainFailure.provider("conversation compaction failed: \(MainRuntimeJSON.boundedString(error))")
            }
        }
        let context = try MainContextAssembler.assemble(
            snapshot: snapshot, protectedSection: protected, runtimeJSON: runtimeJSON,
            externalSection: external, recentMessages: recent, summary: summary, budget: budget,
            recentByteLimit: limits.recent, summaryByteLimit: limits.summary)
        return MainCompactionResult(context: context, summary: summary,
                                    originalMessages: snapshot.messages)
    }

    private static func variableBudgets(available: Int, budget: MainContextBudget)
    -> (recent: Int, summary: Int, external: Int) {
        let weights = [budget.recentBytes, budget.summaryBytes, budget.externalBytes]
        let weightTotal = weights.reduce(0, +)
        let recent = available * budget.recentBytes / weightTotal
        let summary = available * budget.summaryBytes / weightTotal
        let external = available - recent - summary
        return (recent, summary, external)
    }

    public func originalMessages(for summary: MainConversationSummary,
                                 in messages: [MainConversationMessage]) -> [MainConversationMessage] {
        messages.filter { summary.coveredRange.contains($0.sequence) }
            .sorted { $0.sequence < $1.sequence }
    }

    private static func recentMessages(_ messages: [MainConversationMessage],
                                       byteLimit: Int) -> [MainConversationMessage] {
        var used = 0
        var selected: [MainConversationMessage] = []
        for message in messages.sorted(by: { $0.sequence > $1.sequence }) {
            let size = render(message).utf8.count + 1
            if used + size > byteLimit, !selected.isEmpty { break }
            if size > byteLimit { continue }
            selected.append(message)
            used += size
        }
        return selected.sorted { $0.sequence < $1.sequence }
    }

    private static func externalSection(memory: [MainContextDocument],
                                        connectors: [MainContextDocument], byteLimit: Int) -> String {
        var used = 0
        var lines: [String] = []
        for (heading, documents) in [("Memory", memory), ("Connector materials", connectors)] {
            var headingAdded = false
            for document in documents {
                let metadata = "\(document.id) source=\(document.sourceRef) revision=\(document.revision)"
                let overhead = heading.utf8.count + metadata.utf8.count + 16
                let remaining = byteLimit - used - overhead
                guard remaining > 0 else { break }
                let text = truncate(document.text, byteLimit: remaining)
                if !headingAdded {
                    lines.append("## \(heading)")
                    headingAdded = true
                }
                lines.append("[\(metadata)]\n\(text)")
                used += overhead + text.utf8.count
            }
        }
        return lines.joined(separator: "\n")
    }

    fileprivate static func truncate(_ text: String, byteLimit: Int) -> String {
        guard byteLimit > 0 else { return "" }
        guard text.utf8.count > byteLimit else { return text }
        let marker = "\n…[truncated]"
        guard marker.utf8.count <= byteLimit else { return "" }
        let prefixLimit = byteLimit - marker.utf8.count
        var prefix = ""
        var used = 0
        for scalar in text.unicodeScalars {
            let size = String(scalar).utf8.count
            if used + size > prefixLimit { break }
            prefix.unicodeScalars.append(scalar)
            used += size
        }
        return prefix + marker
    }

    private static func protectedSection(_ snapshot: MainConversationSnapshot) throws -> String {
        var lines = ["## Current WorkMandate, FollowUp and pending questions"]
        if let mandate = snapshot.mandate {
            lines.append("WorkMandate: " + (try encode(mandate)))
            lines.append("Target IDs: " + DeterministicMainSummaryGenerator.targetDescriptionForRuntime(mandate.targets))
        }
        if !snapshot.followUps.isEmpty { lines.append("FollowUp: " + (try encode(snapshot.followUps))) }
        for question in snapshot.pendingQuestions {
            lines.append("Pending question \(question.id): \(question.text) choices=\(question.choices)")
        }
        for constraint in snapshot.userConstraints { lines.append("User constraint: \(constraint)") }
        for artifact in snapshot.currentArtifacts {
            lines.append("Current artifact \(artifact.id): \(artifact.title) \(artifact.locator)")
        }
        for pending in snapshot.pendingReconciliations { lines.append("Pending reconciliation: \(pending)") }
        if !snapshot.responseStylePrompt.isEmpty { lines.append(snapshot.responseStylePrompt) }
        return lines.joined(separator: "\n")
    }

    private static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw MainFailure.invalidResponse("task constraints are not UTF-8")
        }
        return string
    }

    fileprivate static func render(_ message: MainConversationMessage) -> String {
        "[\(message.sequence)] \(message.role.rawValue) \(message.id.uuidString): \(message.text)"
    }
}

private extension DeterministicMainSummaryGenerator {
    static func targetDescriptionForRuntime(_ targets: MandateTargets) -> String {
        "gmailThreads=\(targets.gmailThreadIDs), recipients=\(targets.recipientIdentities), "
            + "repository=\(targets.repository ?? ""), issues=\(targets.issueOrPRNumbers)"
    }
}

public enum MainContextAssembler {
    public static func assemble(_ snapshot: MainConversationSnapshot,
                                budget: MainContextBudget = MainContextBudget()) async throws -> MainAssembledContext {
        try await MainConversationCompactor(budget: budget).compact(snapshot).context
    }

    fileprivate static func assemble(snapshot: MainConversationSnapshot, protectedSection: String,
                                     runtimeJSON: String, externalSection: String,
                                     recentMessages: [MainConversationMessage],
                                     summary: MainConversationSummary?, budget: MainContextBudget,
                                     recentByteLimit: Int, summaryByteLimit: Int) throws
    -> MainAssembledContext {
        var sections = [PersonalAgentCorePrompt.text, "## Runtime context\n" + runtimeJSON, protectedSection]
        if !recentMessages.isEmpty {
            let transcript = recentMessages.map(MainConversationCompactor.render).joined(separator: "\n")
            sections.append("## Recent conversation\n" + MainConversationCompactor.truncate(
                transcript, byteLimit: recentByteLimit))
        }
        if let summary {
            let metadata = "summaryID=\(summary.summaryID) coveredRange=\(summary.coveredRange.lowerBound)...\(summary.coveredRange.upperBound) "
                + "revision=\(summary.revision) sourceCursor=\(summary.sourceCursor)"
            sections.append("## Rolling summary\n[\(metadata)]\n" + MainConversationCompactor.truncate(
                summary.text, byteLimit: summaryByteLimit))
        }
        if !externalSection.isEmpty { sections.append(externalSection) }
        let system = sections.joined(separator: "\n\n")
        let messages = [AnthropicMessage.text(snapshot.currentText)]
        let messageBytes = try AnthropicMessagesRequest.encodedMessages(messages).count
        let toolSchemaBytes = try AnthropicMessagesRequest.encodedTools(snapshot.toolSchemas).count
        let bytes = system.utf8.count + toolSchemaBytes + messageBytes
        guard bytes <= budget.totalBytes else {
            throw MainFailure.invalidResponse("assembled Main context exceeds its total byte budget")
        }
        return MainAssembledContext(
            systemPrompt: system, messages: messages,
            estimatedTokens: budget.estimatedTokens(utf8Bytes: bytes),
            tokenEstimationMethod: MainContextBudget.tokenEstimationMethod,
            recentMessages: recentMessages, rollingSummary: summary,
            coreBytes: PersonalAgentCorePrompt.utf8Bytes, runtimeContextBytes: runtimeJSON.utf8.count,
            toolSchemaBytes: toolSchemaBytes, messageBytes: messageBytes, totalBytes: bytes,
            byteBudget: budget.totalBytes)
    }
}
