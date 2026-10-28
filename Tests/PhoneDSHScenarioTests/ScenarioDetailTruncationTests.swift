// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — G2 scenario runner: bounded, marked process-output
// truncation for assertion details.
//
// The G2 real-model batch exposed G2-B03-shaped reports whose assertion detail
// began mid-identifier ("workspace/test_parser.py\", line 11, ...") because the
// runner applied two silent tail truncations in a row: first
// `ScenarioProcessResult.combinedTail` kept the last 2000 characters, then the
// `workspace_command` detail kept 1200 of those. The unittest traceback header
// was dropped with no trace, so reviewers read the detail as a corrupted prefix.
//
// The fix keeps at most one bound (1200 characters) and, whenever the output is
// longer, prepends an explicit marker line that names the truncation and the
// original length. These tests are pure in-process value checks: they spawn no
// host process and boot no WebView.

import Foundation
import XCTest
@testable import PhoneDSHScenario

final class ScenarioDetailTruncationTests: XCTestCase {
    /// The exact header the G2-B03 evidence lost.
    private static let tracebackHeader = "Traceback (most recent call last):"

    /// G2-FIX-35 appends one explicit host-environment line after the verdict.
    /// It is not a second truncation pass: the output tail is still the one
    /// marked 1200-character bound from `ScenarioProcessOutput`.
    private static let environmentLine = ScenarioHostCommandSemantics.hostBash.detailMarker

    /// A long unittest traceback shaped like G2-B03's: the head carries the
    /// header and first frames, the tail carries the final assertion.
    private static let unittestFailure: String = {
        var lines = [tracebackHeader,
                     "  File \"/dsh/workspace/test_parser.py\", line 11, in test_parse_timestamp"]
        lines.append("    self.assertEqual(parse_timestamp(\"2026-01-02T03:04:05Z\"), expected)")
        for index in 0..<28 {
            lines.append("  File \"/dsh/workspace/parser.py\", line \(90 + index), in _parse")
            lines.append("    value = normalize_timestamp(raw_value, index=\(index), zone=utc)")
        }
        lines.append("ValueError: timestamp is not in the expected normalized form")
        lines.append("AssertionError: '2026-01-02T03:04:05Z' != '2026-01-02T03:04:05+00:00'")
        return lines.joined(separator: "\n")
    }()

    // MARK: 1. The G2-B03 shape

    /// A failed `workspace_command` whose output starts with the unittest
    /// traceback header and far exceeds the bound must carry exactly one
    /// explicit marker line, keep the final 1200 characters, and never present
    /// the dropped head as if it were the start of the evidence.
    func testLongUnittestTracebackKeepsAMarkedBoundedTail() {
        let output = Self.unittestFailure
        XCTAssertGreaterThan(output.count, 1200, "the fixture must overflow the bound")
        let outcome = ScenarioWorkspaceCommandOutcome(status: 1,
                                                      timedOut: false,
                                                      durationMs: 12,
                                                      stdout: output,
                                                      stderr: "")
        let detail = outcome.detail
        let marker = "...[truncated: last 1200 of \(output.count) chars]...\n"
        XCTAssertTrue(detail.hasPrefix("exit 1: " + marker), detail)
        XCTAssertEqual(detail, "exit 1: " + marker + String(output.suffix(1200))
            + "\n" + Self.environmentLine)
        XCTAssertTrue(detail.hasPrefix("exit 1: " + marker
            + String(output.suffix(1200)) + "\n" + Self.environmentLine), detail)
        XCTAssertTrue(detail.contains("AssertionError: '2026-01-02T03:04:05Z' != "
            + "'2026-01-02T03:04:05+00:00'"), detail)
        XCTAssertFalse(detail.contains(Self.tracebackHeader),
                       "the dropped head must not reappear: \(detail)")
        XCTAssertEqual(detail.components(separatedBy: "[truncated:").count, 2,
                       "there must be exactly one truncation marker: \(detail)")
    }

    // MARK: 2. At or under the bound

    /// Output that fits the bound is embedded in full with no marker, at the
    /// boundary too. The marker is evidence, not decoration.
    func testOutputAtOrUnderTheBoundKeepsTheFullTextWithoutAMarker() {
        let short = "tests failed: expected 1"
        let atBound = String(repeating: "z", count: 1200)
        for text in [short, atBound] {
            let outcome = ScenarioWorkspaceCommandOutcome(status: 1,
                                                          timedOut: false,
                                                          durationMs: 1,
                                                          stdout: text,
                                                          stderr: "")
            XCTAssertEqual(outcome.detail,
                           "exit 1: \(text)\n\(Self.environmentLine)")
            XCTAssertFalse(outcome.detail.contains("[truncated"),
                           "no marker at or below the bound: \(outcome.detail)")
        }
    }

    /// One character over the bound is already truncated: the helper must
    /// never silently drop the head and present the remainder as a clean start.
    func testOneCharacterOverTheBoundIsMarkedAndKeepsTheTail() {
        let text = "X" + String(repeating: "z", count: 1200)
        XCTAssertEqual(text.count, 1201)
        let outcome = ScenarioWorkspaceCommandOutcome(status: 1,
                                                      timedOut: false,
                                                      durationMs: 1,
                                                      stdout: text,
                                                      stderr: "")
        XCTAssertEqual(outcome.detail,
                       "exit 1: ...[truncated: last 1200 of 1201 chars]...\n"
                        + String(text.suffix(1200)) + "\n" + Self.environmentLine)
        XCTAssertFalse(outcome.detail.contains("X"),
                       "the one dropped character must not look like the output start")
    }

    // MARK: 3. stdout and stderr each overflow

    /// The bound applies to the combined `stdout + stderr` text as a whole: two
    /// 900-character streams fit the bound individually, but their 1800
    /// characters must still be tail-truncated once and marked once.
    func testCombinedOutputIsBoundedAsAWholeEvenWhenEachStreamFits() {
        let stdout = String(repeating: "o", count: 900)
        let stderr = String(repeating: "e", count: 900)
        let combined = stdout + stderr
        let outcome = ScenarioWorkspaceCommandOutcome(status: 1,
                                                      timedOut: false,
                                                      durationMs: 2,
                                                      stdout: stdout,
                                                      stderr: stderr)
        XCTAssertEqual(outcome.combinedTail,
                       "...[truncated: last 1200 of 1800 chars]...\n"
                        + String(combined.suffix(1200)))
        XCTAssertEqual(outcome.detail,
                       "exit 1: " + outcome.combinedTail + "\n" + Self.environmentLine)
        XCTAssertFalse(outcome.detail.hasPrefix("exit 1: o"),
                       "the whole-output bound must drop the head of stdout")
        XCTAssertEqual(outcome.detail.components(separatedBy: "[truncated:").count, 2,
                       "two streams must not add a second truncation pass: \(outcome.detail)")
    }

    /// stdout and stderr each exceed the bound on their own. The combined tail
    /// is the end of stderr; the marker counts the whole combined output and
    /// appears once.
    func testStdoutAndStderrEachOverflowTheBoundAndTheLastTailWins() {
        let stdout = "stdout-head\n" + String(repeating: "o", count: 1500) + "\n"
        let stderr = "stderr-head\n" + String(repeating: "e", count: 1800) + "\n"
            + "final stderr tail\n"
        let combined = (stdout + stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertGreaterThan(stdout.count, 1200, "stdout alone must overflow")
        XCTAssertGreaterThan(stderr.count, 1200, "stderr alone must overflow")
        let outcome = ScenarioWorkspaceCommandOutcome(status: 1,
                                                      timedOut: false,
                                                      durationMs: 3,
                                                      stdout: stdout,
                                                      stderr: stderr)
        let marker = "...[truncated: last 1200 of \(combined.count) chars]...\n"
        let detail = outcome.detail
        XCTAssertTrue(detail.hasPrefix("exit 1: " + marker), detail)
        XCTAssertEqual(detail, "exit 1: " + marker + String(combined.suffix(1200))
            + "\n" + Self.environmentLine)
        XCTAssertTrue(detail.contains("final stderr tail"), detail)
        XCTAssertFalse(detail.contains("stdout-head"), detail)
        XCTAssertEqual(detail.components(separatedBy: "[truncated:").count, 2,
                       "stdout and stderr must not add separate truncation passes: \(detail)")
    }

    // MARK: 4. Every process-output detail uses the same bound

    /// `ScenarioProcessResult.combinedTail` feeds the non-assertion error
    /// details (fixture git failures, artifact archiving); it must use the same
    /// marked bound instead of a second silent 2000-character suffix.
    func testProcessResultTailUsesTheSameMarkedBound() {
        let output = Self.unittestFailure
        let result = ScenarioProcessResult(status: 1,
                                           stdout: output,
                                           stderr: "",
                                           timedOut: false)
        XCTAssertEqual(result.combinedTail,
                       "...[truncated: last 1200 of \(output.count) chars]...\n"
                        + String(output.suffix(1200)))
    }
}
