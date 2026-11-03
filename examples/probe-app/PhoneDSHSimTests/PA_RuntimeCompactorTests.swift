// SPDX-License-Identifier: MIT

import XCTest
import ProbeKit

final class PA_RuntimeCompactorTests: XCTestCase {
    func testTwoHundredRoundsPreserveTaskConstraintsAndAllowSourceLookup() async throws {
        let mandate = pa_runtimeMandate(repository: "target-owner/target-repo")
        let question = PendingQuestion(text: "Which approved target should I use?", choices: ["42"])
        let artifact = MainArtifactContext(id: "artifact-current", title: "Draft",
                                           locator: "artifact://draft/current")
        let snapshot = MainConversationSnapshot(
            currentText: "Make the first approved draft shorter", mandate: mandate,
            pendingQuestions: [question], messages: Self.messages(rounds: 200),
            memory: [MainContextDocument(id: "memory-style", sourceRef: "user://style",
                                         revision: 3, text: "Use concise language")],
            connectorDocuments: [MainContextDocument(id: "connector-pr", sourceRef: "github://pr/42",
                                                     revision: 7, text: String(repeating: "PR context ", count: 2_000))],
            userConstraints: ["Do not write to any repository"],
            currentArtifacts: [artifact], pendingReconciliations: ["operation-42 is unknown"],
            responseStylePrompt: "Answer with the conclusion first")
        let result = try await MainConversationCompactor().compact(snapshot)
        let prompt = result.context.systemPrompt
        for required in [mandate.mandateID.uuidString, "target-owner/target-repo", "42",
                         question.id.uuidString, question.text, "Do not write to any repository",
                         artifact.id, artifact.locator, "operation-42 is unknown"] {
            XCTAssertTrue(prompt.contains(required), "missing protected context: \(required)")
        }
        let summary = try XCTUnwrap(result.summary)
        XCTAssertEqual(summary.coveredRange.lowerBound, 1)
        XCTAssertLessThan(summary.coveredRange.upperBound, 400)
        XCTAssertEqual(summary.revision, 1)
        let originals = result.originalMessages(for: summary)
        XCTAssertEqual(originals.count, summary.coveredRange.count)
        XCTAssertEqual(originals.last?.id.uuidString, summary.sourceCursor)
        XCTAssertEqual(result.context.messages.first?.content.first, .text(snapshot.currentText))
        XCTAssertLessThanOrEqual(prompt.utf8.count + snapshot.currentText.utf8.count, 64_000)

        let current = try XCTUnwrap(prompt.range(of: "Current WorkMandate")).lowerBound
        let recent = try XCTUnwrap(prompt.range(of: "Recent conversation")).lowerBound
        let rolling = try XCTUnwrap(prompt.range(of: "Rolling summary")).lowerBound
        let memory = try XCTUnwrap(prompt.range(of: "## Memory")).lowerBound
        let connector = try XCTUnwrap(prompt.range(of: "## Connector materials")).lowerBound
        XCTAssertTrue(current < recent && recent < rolling && rolling < memory && memory < connector)
    }

    func testSummaryUpgradeKeepsIdentityAndAdvancesRevisionAndCursor() async throws {
        let compactor = MainConversationCompactor()
        let messages = Self.messages(rounds: 200)
        let first = try await compactor.compact(MainConversationSnapshot(currentText: "next", messages: messages))
        let firstSummary = try XCTUnwrap(first.summary)
        let second = try await compactor.compact(MainConversationSnapshot(
            currentText: "next again", messages: messages, rollingSummary: firstSummary))
        let secondSummary = try XCTUnwrap(second.summary)
        XCTAssertEqual(secondSummary.summaryID, firstSummary.summaryID)
        XCTAssertEqual(secondSummary.revision, firstSummary.revision + 1)
        XCTAssertEqual(secondSummary.coveredRange.lowerBound, firstSummary.coveredRange.lowerBound)
        XCTAssertGreaterThanOrEqual(secondSummary.coveredRange.upperBound, firstSummary.coveredRange.upperBound)
        XCTAssertEqual(compactor.originalMessages(for: secondSummary, in: messages).count,
                       secondSummary.coveredRange.count)
    }

    func testSummaryFailureDoesNotDropCurrentConstraints() async throws {
        let compactor = MainConversationCompactor(summarizer: PA_RuntimeFailingSummarizer())
        let mandate = pa_runtimeMandate()
        do {
            _ = try await compactor.compact(MainConversationSnapshot(
                currentText: "continue", mandate: mandate, messages: Self.messages(rounds: 200),
                userConstraints: ["never send"]))
            XCTFail("expected summary failure")
        } catch let failure as MainFailure {
            guard case .provider(let message) = failure else {
                return XCTFail("expected provider failure, got \(failure)")
            }
            XCTAssertTrue(message.contains("conversation compaction failed"))
        }
    }

    private static func messages(rounds: Int) -> [MainConversationMessage] {
        var messages: [MainConversationMessage] = []
        for round in 1...rounds {
            messages.append(MainConversationMessage(sequence: round * 2 - 1, role: .user,
                                                    text: "round \(round): inspect the approved item"))
            messages.append(MainConversationMessage(sequence: round * 2, role: .assistant,
                                                    text: "round \(round): current result"))
        }
        return messages
    }
}

private struct PA_RuntimeFailingSummarizer: MainSummaryGenerating {
    struct Failure: Error {}
    func summarize(_ request: MainSummaryGenerationRequest) async throws -> String {
        throw Failure()
    }
}
