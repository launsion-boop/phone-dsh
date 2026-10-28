// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — G2 scenario runner: host-oracle false failures from
// source284 (G2-A08 category normalization and G2-C09 BSD `wc` formatting).
//
// Root cause 1 (G2-A08): the host oracle hard-coded lowercase object keys
// (`d['food']`) although the second user turn only asked to normalize the
// category *spelling* before regrouping; it did not require lowercase keys.
// A correct TitleCase `tally.json` therefore raised `KeyError` and was
// reported as a failure. The oracle now folds the actual keys for comparison
// and explicitly rejects two categories that only differ by case, so a file
// that still contains `Food` and `food` cannot pass by overwriting one entry.
//
// Root cause 2 (G2-C09): BSD `wc -l < file` pads its number to a column, while
// the old oracle interpolated that padded output into `grep -qw`, requiring
// `NOTES.md` to contain the same leading spaces. The oracle now strips the
// number's formatting whitespace before the unchanged whole-word numeric
// match, still computes the value from the actual file and still requires the
// file to be non-empty.
//
// These tests load the shipped catalog assertion commands themselves (no
// copied command strings) and run them through the production
// `ScenarioWorkspaceCommand` `/bin/bash` executor on temporary workspaces.
// They do not add a second evaluator. The `PhoneDSH` prefix keeps the suite in
// the CI gate filter `swift test --filter 'PhoneDSH|PhoneDSHShell'`.

import Foundation
import XCTest
@testable import PhoneDSHScenario

final class PhoneDSHScenarioHostOracleTests: XCTestCase {
    private static let readmeWithThreeLines = "Alpha\nBeta\nGamma\n"
    private static let c09NotesWithThree = "line count (wc -l): 3\nword count (wc -w): 4\n"

    private static var repositoryRoot: URL {
        guard let root = scenarioRepositoryRoot(startingAt: URL(fileURLWithPath: #filePath)) else {
            preconditionFailure("cannot locate the repository root from #filePath")
        }
        return root
    }

    private struct CatalogCommands {
        var a08Tally: String
        var c09LineCount: String
    }

    /// Read the two shipped assertion commands from the catalog. Matching by
    /// the artifact each command checks makes this independent of assertion
    /// order while still failing if the catalog entry is removed or renamed.
    private func shippedCommands() throws -> CatalogCommands {
        let catalog = try ScenarioCatalog.load(
            from: Self.repositoryRoot.appendingPathComponent("scripts/ci/scenarios/catalog.json"))
        let a08 = try XCTUnwrap(catalog.scenarios.first { $0.id == "G2-A08" })
        let c09 = try XCTUnwrap(catalog.scenarios.first { $0.id == "G2-C09" })
        let a08Command = try XCTUnwrap(
            a08.assertions.first {
                $0.type == "workspace_command"
                    && ($0.command ?? "").contains("tally.json")
                    && ($0.command ?? "").contains("food")
            }?.command,
            "G2-A08 must carry the tally.json total/count host oracle")
        let c09Command = try XCTUnwrap(
            c09.assertions.first {
                $0.type == "workspace_command"
                    && ($0.command ?? "").contains("linux-readme.md")
                    && ($0.command ?? "").contains("wc -l")
            }?.command,
            "G2-C09 must carry the wc -l host oracle")
        return CatalogCommands(a08Tally: a08Command, c09LineCount: c09Command)
    }

    // MARK: Fixtures

    private func withWorkspace(files: [String: String],
                               _ body: (URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-host-oracle-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace,
                                                withIntermediateDirectories: true)
        for (path, content) in files {
            let url = workspace.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(content.utf8).write(to: url)
        }
        let results = root.appendingPathComponent("results", isDirectory: true)
        try FileManager.default.createDirectory(at: results,
                                                withIntermediateDirectories: true)
        try body(workspace, results)
    }

    /// The one production host executor, shared with the macOS runner and the
    /// simulator host phase. It is a no-op skip on a platform that cannot
    /// spawn `/bin/bash`; the catalog oracle is a macOS host acceptance check.
    private func evaluate(_ command: String,
                          workspace: URL,
                          results: URL) throws -> ScenarioWorkspaceCommandOutcome {
        guard ScenarioWorkspaceCommand.hostProcessesAvailable else {
            throw XCTSkip("host /bin/bash execution is unavailable on this platform; "
                + "the catalog host oracle is a macOS acceptance check")
        }
        return try ScenarioWorkspaceCommand.evaluate(command: command,
                                                     workspace: workspace,
                                                     resultsDirectory: results,
                                                     timeout: 30)
    }

    private func tallyJSON(_ entries: [(String, Double, Double)]) throws -> String {
        var object: [String: Any] = [:]
        for (category, total, count) in entries {
            object[category] = ["total": total, "count": count]
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func assertPass(_ outcome: ScenarioWorkspaceCommandOutcome,
                            _ label: String,
                            file: StaticString = #filePath,
                            line: UInt = #line) {
        XCTAssertTrue(outcome.ok, "\(label) must pass: \(outcome.detail)",
                      file: file, line: line)
    }

    private func assertFail(_ outcome: ScenarioWorkspaceCommandOutcome,
                            _ label: String,
                            file: StaticString = #filePath,
                            line: UInt = #line) {
        XCTAssertFalse(outcome.ok, "\(label) must fail: \(outcome.detail)",
                       file: file, line: line)
    }

    // MARK: G2-A08 — category normalization

    /// The real source284 file used TitleCase keys with the correct totals and
    /// counts. The second turn asked only to normalize the category spelling,
    /// so both the actual TitleCase shape and a lowercase normalization must
    /// pass. The totals and all four rubric counts are unchanged requirements.
    func testA08CatalogCommandAcceptsTitleCaseAndLowercaseCategoryKeys() throws {
        let command = try shippedCommands().a08Tally
        let cases: [(String, [(String, Double, Double)])] = [
            ("TitleCase", [
                ("Food", 438.5, 3),
                ("Transport", 105.0, 2),
                ("Books", 128.0, 2),
                ("Coffee", 50.5, 2),
            ]),
            ("lowercase", [
                ("food", 438.5, 3),
                ("transport", 105.0, 2),
                ("books", 128.0, 2),
                ("coffee", 50.5, 2),
            ]),
        ]
        for (label, entries) in cases {
            let tally = try tallyJSON(entries)
            try withWorkspace(files: ["tally.json": tally]) { workspace, results in
                let outcome = try evaluate(command, workspace: workspace, results: results)
                assertPass(outcome, "\(label) category keys with the correct totals/counts")
            }
        }
    }

    /// Case folding must not let `Food` and `food` coexist and silently
    /// overwrite each other. Both entries carry the correct value here, so a
    /// fold-only lookup would pass; the explicit duplicate rejection must not.
    func testA08CatalogCommandRejectsCategoriesThatOnlyDifferByCase() throws {
        let command = try shippedCommands().a08Tally
        let entries: [(String, Double, Double)] = [
            ("Food", 438.5, 3),
            ("food", 438.5, 3),
            ("Transport", 105.0, 2),
            ("Books", 128.0, 2),
            ("Coffee", 50.5, 2),
        ]
        let tally = try tallyJSON(entries)
        try withWorkspace(files: ["tally.json": tally]) { workspace, results in
            let outcome = try evaluate(command, workspace: workspace, results: results)
            assertFail(outcome, "a tally with both Food and food (ambiguous after folding)")
        }
    }

    /// Missing categories and wrong required numbers remain failures; the
    /// case-insensitive lookup is not a relaxation of the rubric totals.
    func testA08CatalogCommandRejectsMissingCategoriesAndWrongTotalsOrCounts() throws {
        let command = try shippedCommands().a08Tally
        let cases: [(String, [(String, Double, Double)])] = [
            ("missing Books", [
                ("Food", 438.5, 3),
                ("Transport", 105.0, 2),
                ("Coffee", 50.5, 2),
            ]),
            ("wrong Food total", [
                ("Food", 438.0, 3),
                ("Transport", 105.0, 2),
                ("Books", 128.0, 2),
                ("Coffee", 50.5, 2),
            ]),
            ("wrong Coffee count", [
                ("Food", 438.5, 3),
                ("Transport", 105.0, 2),
                ("Books", 128.0, 2),
                ("Coffee", 50.5, 1),
            ]),
            // Compare the parsed count itself, not `int(count)`: a 2.9 or
            // 3.9 tally used to truncate to the expected integer and pass.
            ("fractional Coffee count", [
                ("Food", 438.5, 3),
                ("Transport", 105.0, 2),
                ("Books", 128.0, 2),
                ("Coffee", 50.5, 2.9),
            ]),
            ("fractional Food count", [
                ("Food", 438.5, 3.9),
                ("Transport", 105.0, 2),
                ("Books", 128.0, 2),
                ("Coffee", 50.5, 2),
            ]),
            ("wrong Food count", [
                ("Food", 438.5, 4),
                ("Transport", 105.0, 2),
                ("Books", 128.0, 2),
                ("Coffee", 50.5, 2),
            ]),
        ]
        for (label, entries) in cases {
            let tally = try tallyJSON(entries)
            try withWorkspace(files: ["tally.json": tally]) { workspace, results in
                let outcome = try evaluate(command, workspace: workspace, results: results)
                assertFail(outcome, label)
            }
        }
    }

    // MARK: G2-C09 — `wc -l` formatting

    /// The count comes from the actual file and is matched as the whole number
    /// in NOTES.md. This is the shape a real non-empty three-line file has.
    func testC09CatalogCommandAcceptsTheActualLineCount() throws {
        let command = try shippedCommands().c09LineCount
        try withWorkspace(files: [
            "linux-readme.md": Self.readmeWithThreeLines,
            "NOTES.md": Self.c09NotesWithThree,
        ]) { workspace, results in
            let outcome = try evaluate(command, workspace: workspace, results: results)
            assertPass(outcome, "NOTES.md naming the real three-line count")
        }
    }

    /// Only a whole-word numeric match counts: the same digits embedded in 13
    /// or 30 must not satisfy the line-count oracle.
    func testC09CatalogCommandRejectsEmbeddedLineCountDigits() throws {
        let command = try shippedCommands().c09LineCount
        try withWorkspace(files: [
            "linux-readme.md": Self.readmeWithThreeLines,
            "NOTES.md": "line count (wc -l): 13\nword count (wc -w): 30\n",
        ]) { workspace, results in
            let outcome = try evaluate(command, workspace: workspace, results: results)
            assertFail(outcome, "NOTES.md containing 13 and 30 but no standalone 3")
        }
    }

    /// A wrong line count and an empty source file both stay failures.
    func testC09CatalogCommandRejectsWrongLineCountAndEmptyFile() throws {
        let command = try shippedCommands().c09LineCount
        let cases: [(String, [String: String])] = [
            ("wrong line count", [
                "linux-readme.md": Self.readmeWithThreeLines,
                "NOTES.md": "line count (wc -l): 4\nword count (wc -w): 4\n",
            ]),
            ("empty linux-readme.md", [
                "linux-readme.md": "",
                "NOTES.md": "line count (wc -l): 0\nword count (wc -w): 0\n",
            ]),
        ]
        for (label, files) in cases {
            try withWorkspace(files: files) { workspace, results in
                let outcome = try evaluate(command, workspace: workspace, results: results)
                assertFail(outcome, label)
            }
        }
    }

    /// BSD `wc` pads the number in front of the value. This runs the shipped
    /// command through the production host executor with an emulated padded
    /// `wc` first on PATH; the fake `wc` still reads the real file from stdin
    /// via `/usr/bin/wc`, and only its printed number carries the padding. The
    /// old interpolation would fail here because NOTES.md has no leading
    /// spaces; the normalized command must pass.
    func testC09CatalogCommandToleratesPaddedWCNumberOutput() throws {
        let command = try shippedCommands().c09LineCount
        try withWorkspace(files: [
            "linux-readme.md": Self.readmeWithThreeLines,
            "NOTES.md": Self.c09NotesWithThree,
        ]) { workspace, results in
            let bin = results.appendingPathComponent("fake-bin", isDirectory: true)
            try FileManager.default.createDirectory(at: bin,
                                                    withIntermediateDirectories: true)
            let wc = bin.appendingPathComponent("wc")
            let script = """
            #!/bin/bash
            count=$(/usr/bin/wc -l)
            count=${count//[[:space:]]/}
            printf '     %s\\n' "$count"
            """
            try Data(script.utf8).write(to: wc)
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: wc.path)
            let paddedCommand = "PATH=\"\(bin.path):$PATH\"; " + command
            let outcome = try evaluate(paddedCommand, workspace: workspace, results: results)
            assertPass(outcome, "the shipped command with BSD-style padded wc output")
            XCTAssertTrue(command.contains("${lines//[[:space:]]/}"),
                          "G2-C09 must strip wc's formatting whitespace before "
                          + "the whole-word numeric match")
        }
    }
}
