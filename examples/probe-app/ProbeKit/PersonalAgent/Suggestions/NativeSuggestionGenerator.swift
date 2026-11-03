// SPDX-License-Identifier: MIT

import Foundation

public struct NativeSuggestionGenerator: SuggestionGenerating {
    private static let systemPrompt = """
    You decide whether a completed Personal Agent turn has genuinely useful next steps. \
    Suggestions are optional: do not provide them merely to fill a card. Return NONE or an \
    empty response when the task is complete, the exchange needs no follow-up, a pending \
    question already owns the next interaction, or the context supports no specific \
    high-value action. Never invent a generic or fixed fallback suggestion. If and only if \
    valuable next steps exist, return at most three short, concrete, executable options. \
    Each option must advance the user's task and must not restate the user's input or the \
    assistant's answer. Use one option per line, labelled A., B., C. or 1., 2., 3. \
    Return no heading, explanation, Markdown, or extra text.
    """

    private let clientResolver: any MainModelClientResolving
    private let contextProvider: any MainContextProviding

    public init(clientResolver: any MainModelClientResolving,
                contextProvider: any MainContextProviding = MainStaticContextProvider()) {
        self.clientResolver = clientResolver
        self.contextProvider = contextProvider
    }

    public func generate(turn: MainTurnInput, answer: AssistantMessage) async throws -> [String] {
        do {
            let resolved = try clientResolver.resolveClient()
            let snapshot = try await contextProvider.snapshot(for: turn)
            let request = AnthropicMessagesRequest(
                model: resolved.model,
                system: Self.systemPrompt,
                messages: [.text(Self.userPrompt(turn: turn, answer: answer, snapshot: snapshot))],
                maxTokens: min(max(1, resolved.maxTokens), 256))
            var accumulator = AnthropicResponseAccumulator()
            for try await event in resolved.client.stream(request) {
                try accumulator.apply(event)
            }
            try accumulator.validated()
            guard accumulator.toolUses.isEmpty else { return [] }
            return Self.parse(accumulator.text)
        } catch {
            return []
        }
    }

    private static func userPrompt(turn: MainTurnInput, answer: AssistantMessage,
                                   snapshot: MainConversationSnapshot) -> String {
        var sections = [
            "Current user input:\n\(turn.text)",
            "Assistant answer just completed:\n\(answer.text)",
        ]
        if !snapshot.messages.isEmpty {
            let transcript = snapshot.messages.suffix(12).map {
                "[\($0.sequence)] \($0.role.rawValue): \($0.text)"
            }.joined(separator: "\n")
            sections.append("Recent conversation:\n\(transcript)")
        }
        if let summary = snapshot.rollingSummary {
            sections.append("Earlier conversation summary:\n\(summary.text)")
        }
        var taskState: [String] = []
        if let mandate = snapshot.mandate {
            taskState.append("Active goal: \(mandate.goal)")
        }
        if !snapshot.followUps.isEmpty {
            taskState.append("Follow-ups: " + snapshot.followUps.map {
                "\($0.goal) (waiting: \($0.waitingReason ?? "none"))"
            }.joined(separator: " | "))
        }
        if !snapshot.pendingQuestions.isEmpty {
            taskState.append("Pending questions: " + snapshot.pendingQuestions.map(\.text)
                .joined(separator: " | "))
        }
        if !snapshot.pendingReconciliations.isEmpty {
            taskState.append("Pending reconciliations: " + snapshot.pendingReconciliations
                .joined(separator: " | "))
        }
        if !snapshot.currentArtifacts.isEmpty {
            taskState.append("Current artifacts: " + snapshot.currentArtifacts.map {
                "\($0.title) (\($0.locator))"
            }.joined(separator: " | "))
        }
        if !snapshot.userConstraints.isEmpty {
            taskState.append("User constraints: " + snapshot.userConstraints.joined(separator: " | "))
        }
        sections.append("Task state:\n" + (taskState.isEmpty ? "No active task state." : taskState.joined(separator: "\n")))
        sections.append("Decide whether any suggestion is worthwhile. It is valid and often preferable to provide none.")
        return sections.joined(separator: "\n\n")
    }

    private static func parse(_ response: String) -> [String] {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if ["none", "no_suggestions", "无建议", "不提供建议"].contains(trimmed.lowercased()) {
            return []
        }
        let lines = trimmed.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty, lines.count <= 3 else { return [] }
        var options: [String] = []
        for (index, line) in lines.enumerated() {
            let expectedLetter = Character(UnicodeScalar(65 + index)!)
            let expectedNumber = Character(UnicodeScalar(49 + index)!)
            guard let marker = line.first,
                  marker == expectedLetter || marker == Character(expectedLetter.lowercased())
                    || marker == expectedNumber else { return [] }
            let remainder = line.dropFirst()
            guard let separator = remainder.first, separator == "." || separator == ")" || separator == ":"
                    || separator == "、" else { return [] }
            let option = remainder.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !option.isEmpty else { return [] }
            options.append(option)
        }
        return options
    }
}
