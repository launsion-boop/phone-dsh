// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — G2 scenario runner: G2-D05 stop-word test oracle.
//
// The source284 report's only failed G2-D05 assertion was a `file_regex` on
// `test_textstats.py` that required the literal spelling `ignore_stopwords`.
// The real test file covered the default stop-word filtering and called
// `top_words(..., False)` positionally, so the spelling-only assertion
// reported a correct test as a failure. The user asked for the two behaviours
// (default filtering and explicit False), not for a particular keyword.
//
// The replacement shipped in the catalog runs the real `unittest` discovery
// with an observer wrapped around the public `textstats.top_words` and the
// same function in its defining module (resolved through `__module__`, never a
// hard-coded `core.py`). The observer uses `inspect.signature(...).bind_partial`
// so both `top_words(text, n, False)` and
// `top_words(text, n, ignore_stopwords=False)` are seen, forwards to the
// original function unchanged, and requires the suite to pass. Calls are only
// counted while a loaded `unittest.TestCase.run` is executing, so a module-level
// call during discovery is not coverage; a default/True call only counts when
// disabling the filter on the same call changes the result, so the fixture's
// old tests on stop-word-free input are not default-filtering coverage. The
// command also checks the default-filtering and explicit-False behaviour
// itself. A correct API with no loaded-test call is a failure: the oracle never
// calls the observer to manufacture coverage.
//
// These tests load the shipped catalog command itself (no copied command
// string) and run it through the production `ScenarioWorkspaceCommand`
// `/bin/bash` executor on temporary workspaces. They do not add a second
// evaluator. The `PhoneDSH` prefix keeps the suite in the CI gate filter
// `swift test --filter 'PhoneDSH|PhoneDSHShell'`.

import Foundation
import XCTest
@testable import PhoneDSHScenario

final class PhoneDSHScenarioStopwordOracleTests: XCTestCase {
    private static var repositoryRoot: URL {
        guard let root = scenarioRepositoryRoot(startingAt: URL(fileURLWithPath: #filePath)) else {
            preconditionFailure("cannot locate the repository root from #filePath")
        }
        return root
    }

    // MARK: Shipped catalog command

    /// Reads the G2-D05 execution oracle from the catalog. Matching by the
    /// behaviours it mentions keeps this independent of assertion order while
    /// still failing if the command is removed or stops running the suite.
    private func shippedCommand() throws -> String {
        let catalog = try ScenarioCatalog.load(
            from: Self.repositoryRoot.appendingPathComponent("scripts/ci/scenarios/catalog.json"))
        let scenario = try XCTUnwrap(catalog.scenarios.first { $0.id == "G2-D05" })
        XCTAssertNil(
            scenario.assertions.first {
                $0.type == "file_regex"
                    && $0.path == "test_textstats.py"
                    && $0.value == "ignore_stopwords"
            },
            "G2-D05 must not require the literal `ignore_stopwords` spelling in "
                + "test_textstats.py; a correct positional `top_words(..., False)` "
                + "test was the source284 false failure")
        return try XCTUnwrap(
            scenario.assertions.first {
                $0.type == "workspace_command"
                    && ($0.command ?? "").contains("unittest")
                    && ($0.command ?? "").contains("ignore_stopwords")
            }?.command,
            "G2-D05 must carry the executing stop-word test oracle")
    }

    // MARK: Fixtures

    /// Base package from the textstats fixture, with the v2 `top_words`
    /// signature the user asked for. The defining module is a normal package
    /// module; the oracle must resolve it through the exported function.
    private static let packageInit = #"""
    from .core import count_words, top_words

    __all__ = ["count_words", "top_words"]
    """#

    private static let packageInitRanking = #"""
    from .ranking import count_words, top_words

    __all__ = ["count_words", "top_words"]
    """#

    private static let stopwordsSource = #"""
    STOPWORDS = {"the", "a", "an", "and", "or", "of", "to", "in", "is"}
    """#

    private static let coreV2 = #"""
    import string
    from .stopwords import STOPWORDS


    def _tokenize(text):
        words = text.lower().split()
        return [word.strip(string.punctuation) for word in words if word.strip(string.punctuation)]


    def count_words(text):
        counts = {}
        for word in _tokenize(text):
            counts[word] = counts.get(word, 0) + 1
        return counts


    def top_words(text, n, ignore_stopwords=True):
        counts = count_words(text)
        if ignore_stopwords:
            counts = {word: count for word, count in counts.items() if word not in STOPWORDS}
        ordered = sorted(counts.items(), key=lambda item: (-item[1], item[0]))
        return ordered[:n]
    """#

    /// Imports the function from its defining module instead of the package
    /// export, exercising the second observer installation.
    private static var definingModuleImportTests: String {
        Self.keywordFalseTests.replacingOccurrences(
            of: "from textstats import top_words",
            with: "from textstats.core import top_words")
    }

    /// A wrong implementation that keeps v1's full-count default. The test
    /// below asserts only the explicit-False direction, so the suite passes and
    /// the oracle's own behaviour check must still reject the wrong default.
    private static var coreDefaultOff: String {
        Self.coreV2.replacingOccurrences(of: "ignore_stopwords=True",
                                         with: "ignore_stopwords=False")
    }

    private static let positionalFalseTests = #"""
    import unittest
    from textstats import top_words


    class TextStatsTests(unittest.TestCase):
        def test_default_filters_stop_words(self):
            self.assertEqual(top_words('the cat and the dog', 2),
                             [('cat', 1), ('dog', 1)])

        def test_explicit_false_keeps_all_words(self):
            self.assertEqual(top_words('the cat and the dog', 2, False),
                             [('the', 2), ('and', 1)])
    """#

    private static let keywordFalseTests = #"""
    import unittest
    from textstats import top_words


    class TextStatsTests(unittest.TestCase):
        def test_default_filters_stop_words(self):
            self.assertEqual(top_words('the cat and the dog', 2),
                             [('cat', 1), ('dog', 1)])

        def test_explicit_false_keeps_all_words(self):
            self.assertEqual(top_words('the cat and the dog', 2, ignore_stopwords=False),
                             [('the', 2), ('and', 1)])
    """#

    private static let noFalseTests = #"""
    import unittest
    from textstats import top_words


    class TextStatsTests(unittest.TestCase):
        def test_default_filters_stop_words(self):
            self.assertEqual(top_words('the cat and the dog', 2),
                             [('cat', 1), ('dog', 1)])

        def test_explicit_true_filters_stop_words(self):
            self.assertEqual(top_words('the cat and the dog', 2, ignore_stopwords=True),
                             [('cat', 1), ('dog', 1)])
    """#

    /// The old false positive in one fixture: the exact literal
    /// `ignore_stopwords=False` appears only in a comment, and `assertFalse`
    /// is unrelated. The loaded test calls `top_words` only with its default,
    /// so the oracle must not count the text as coverage.
    private static let unrelatedFalseTextTests = #"""
    import unittest
    from textstats import top_words


    class TextStatsTests(unittest.TestCase):
        def test_default_filters_stop_words(self):
            # ignore_stopwords=False only appears in this comment.
            self.assertFalse(False)
            self.assertEqual(top_words('the cat and the dog', 2),
                             [('cat', 1), ('dog', 1)])
    """#

    private static let failingSuiteTests = #"""
    import unittest
    from textstats import top_words


    class TextStatsTests(unittest.TestCase):
        def test_default_filters_stop_words(self):
            self.assertEqual(top_words('the cat and the dog', 2),
                             [('cat', 1), ('dog', 1)])

        def test_explicit_false_keeps_all_words(self):
            self.assertEqual(top_words('the cat and the dog', 2, ignore_stopwords=False),
                             [('the', 1)])
    """#

    /// The package has the right API and the suite passes, but no loaded test
    /// call reaches `top_words`. The oracle must fail instead of adding its own
    /// observer call.
    private static let noCallTests = #"""
    import unittest
    from textstats import top_words


    class TextStatsTests(unittest.TestCase):
        def test_api_is_importable(self):
            self.assertTrue(callable(top_words))
    """#

    /// Both directions run at module import time, before any test starts, and
    /// the only test is a no-op. Discovery-time calls are not loaded-test
    /// coverage, so the oracle must reject this even though both directions
    /// were invoked while the module was imported.
    private static let moduleLevelCoverageTests = #"""
    import unittest
    from textstats import top_words

    top_words('the cat and the dog', 2)
    top_words('the cat and the dog', 2, False)


    class TextStatsTests(unittest.TestCase):
        def test_nothing(self):
            self.assertTrue(True)
    """#

    /// The fixture's old v1 tests call `top_words` on inputs without stop
    /// words. Appending only an explicit-False test must not satisfy the
    /// default-filtering requirement: those old calls return the same result
    /// with filtering disabled, so they are not coverage of the new default.
    private static let legacyV1TestsPlusOnlyFalseTests = #"""
    import unittest
    from textstats import top_words


    class TextStatsTests(unittest.TestCase):
        def test_top_words_sorting(self):
            self.assertEqual(top_words('apple banana apple', 3),
                             [('apple', 2), ('banana', 1)])

        def test_top_words_truncation(self):
            self.assertEqual(top_words('kiwi apple mango', 2),
                             [('apple', 1), ('kiwi', 1)])

        def test_explicit_false_keeps_all_words(self):
            self.assertEqual(top_words('the cat and the dog', 2, ignore_stopwords=False),
                             [('the', 2), ('and', 1)])
    """#

    /// Exercises both directions but does not assert the default result; only
    /// the oracle's own behaviour check can reject the wrong default.
    private static let weakDefaultTests = #"""
    import unittest
    from textstats import top_words


    class TextStatsTests(unittest.TestCase):
        def test_default_is_callable(self):
            top_words('the cat and the dog', 2)

        def test_explicit_false_keeps_all_words(self):
            self.assertEqual(top_words('the cat and the dog', 2, ignore_stopwords=False),
                             [('the', 2), ('and', 1)])
    """#

    private static func workspace(test: String,
                                  implementation: String = "core") -> [String: String] {
        var files: [String: String] = [
            "textstats/stopwords.py": Self.stopwordsSource,
            "textstats/__init__.py": Self.packageInit,
            "test_textstats.py": test,
        ]
        switch implementation {
        case "ranking":
            files["textstats/ranking.py"] = Self.coreV2
            files["textstats/__init__.py"] = Self.packageInitRanking
        case "defaultOff":
            files["textstats/core.py"] = Self.coreDefaultOff
        default:
            files["textstats/core.py"] = Self.coreV2
        }
        return files
    }

    private func withWorkspace(files: [String: String],
                               _ body: (URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-stopword-oracle-\(UUID().uuidString)",
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

    private func assertPass(_ outcome: ScenarioWorkspaceCommandOutcome,
                            _ label: String,
                            file: StaticString = #filePath,
                            line: UInt = #line) {
        XCTAssertTrue(outcome.ok, "\(label) must pass: \(outcome.detail)",
                      file: file, line: line)
    }

    private func assertFails(_ outcome: ScenarioWorkspaceCommandOutcome,
                             _ label: String,
                             because marker: String,
                             file: StaticString = #filePath,
                             line: UInt = #line) {
        XCTAssertFalse(outcome.ok, "\(label) must fail: \(outcome.detail)",
                       file: file, line: line)
        XCTAssertTrue(outcome.detail.contains(marker),
                      "\(label) failed for the wrong reason (wanted \(marker)): "
                          + "\(outcome.detail)",
                      file: file, line: line)
    }

    // MARK: Acceptance

    /// The real source284 test used the positional third argument. Both the
    /// positional and keyword spellings, together with a default-filtering
    /// test, must pass.
    func testCatalogCommandAcceptsPositionalAndKeywordFalse() throws {
        let command = try shippedCommand()
        let cases: [(String, String)] = [
            ("positional False", Self.positionalFalseTests),
            ("keyword False", Self.keywordFalseTests),
        ]
        for (label, test) in cases {
            try withWorkspace(files: Self.workspace(test: test)) { workspace, results in
                let outcome = try evaluate(command, workspace: workspace, results: results)
                assertPass(outcome, "\(label) with a default-filtering test")
            }
        }
    }

    func testCatalogCommandObservesTheDefiningModuleImport() throws {
        let command = try shippedCommand()
        try withWorkspace(files: Self.workspace(test: Self.definingModuleImportTests)) {
            workspace, results in
            let outcome = try evaluate(command, workspace: workspace, results: results)
            assertPass(outcome, "tests importing top_words from textstats.core")
        }
    }

    /// The oracle resolves the defining module through the exported function,
    /// so a legitimate package that defines `top_words` outside `core.py`
    /// still passes.
    func testCatalogCommandUsesTheDefiningModuleNotAHardCodedCorePath() throws {
        let command = try shippedCommand()
        try withWorkspace(files: Self.workspace(test: Self.keywordFalseTests,
                                                implementation: "ranking")) {
            workspace, results in
            let outcome = try evaluate(command, workspace: workspace, results: results)
            assertPass(outcome, "top_words defined in textstats.ranking and re-exported")
        }
    }

    // MARK: Rejection

    func testCatalogCommandRejectsTestsWithNoExplicitFalse() throws {
        let command = try shippedCommand()
        try withWorkspace(files: Self.workspace(test: Self.noFalseTests)) { workspace, results in
            let outcome = try evaluate(command, workspace: workspace, results: results)
            assertFails(outcome, "a suite that only tests the default and True filtering",
                        because: "no test passed ignore_stopwords=False")
        }
    }

    func testCatalogCommandRejectsUnrelatedFalseText() throws {
        let command = try shippedCommand()
        try withWorkspace(files: Self.workspace(test: Self.unrelatedFalseTextTests)) {
            workspace, results in
            let outcome = try evaluate(command, workspace: workspace, results: results)
            assertFails(outcome, "a suite with only a comment and an unrelated assertFalse",
                        because: "no test passed ignore_stopwords=False")
        }
    }

    func testCatalogCommandRejectsAFailingSuite() throws {
        let command = try shippedCommand()
        try withWorkspace(files: Self.workspace(test: Self.failingSuiteTests)) {
            workspace, results in
            let outcome = try evaluate(command, workspace: workspace, results: results)
            assertFails(outcome, "a suite whose explicit-False assertion is wrong",
                        because: "the loaded unittest suite failed")
        }
    }

    func testCatalogCommandIgnoresModuleLevelCallsDuringDiscovery() throws {
        let command = try shippedCommand()
        try withWorkspace(files: Self.workspace(test: Self.moduleLevelCoverageTests)) {
            workspace, results in
            let outcome = try evaluate(command, workspace: workspace, results: results)
            assertFails(outcome, "module-level calls plus a no-op test",
                        because: "the loaded tests never called top_words")
        }
    }

    func testCatalogCommandRejectsLegacyTestsPlusOnlyAnExplicitFalseTest() throws {
        let command = try shippedCommand()
        try withWorkspace(files: Self.workspace(test: Self.legacyV1TestsPlusOnlyFalseTests)) {
            workspace, results in
            let outcome = try evaluate(command, workspace: workspace, results: results)
            assertFails(outcome, "old stop-word-free tests plus only an explicit-False test",
                        because: "no loaded test exercised default or explicit True filtering")
        }
    }

    func testCatalogCommandRejectsATestThatNeverCallsTopWords() throws {
        let command = try shippedCommand()
        try withWorkspace(files: Self.workspace(test: Self.noCallTests)) { workspace, results in
            let outcome = try evaluate(command, workspace: workspace, results: results)
            assertFails(outcome, "a passing suite that never calls top_words",
                        because: "the loaded tests never called top_words")
        }
    }

    func testCatalogCommandRejectsWrongDefaultFunctionality() throws {
        let command = try shippedCommand()
        try withWorkspace(files: Self.workspace(test: Self.weakDefaultTests,
                                                implementation: "defaultOff")) {
            workspace, results in
            let outcome = try evaluate(command, workspace: workspace, results: results)
            assertFails(outcome, "a weak suite over a default that does not filter",
                        because: "default top_words does not filter STOPWORDS")
        }
    }
}
