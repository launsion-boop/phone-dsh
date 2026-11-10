// SPDX-License-Identifier: MIT

import Foundation
import XCTest

/// S1: the workspace mention index must have exactly the old filter's
/// semantics, and must turn the per-code-span scan into a dictionary lookup.
final class WorkspaceFileIndexTests: XCTestCase {
    // MARK: - Semantics

    func testMentionEdgeCasesUseTheOriginalUnionRule() {
        let files = makeFiles([
            "file",              // path and basename both match "file"
            "dir/file",          // second basename match for "file"
            "other/file",        // third basename match for "file"
            "a/unique.txt",      // only a basename match
            "a/file",            // full-path value, even though basename is shared
            "readme.md",
            "docs/readme.md",
            "deep/branch/leaf.md",
            "with space/名字.txt",
        ])
        let index = WorkspaceFileIndex(files: files)

        XCTAssertEqual(index.mention(for: "a/file"), "a/file",
                       "a full path is unique even when its basename is not")
        XCTAssertEqual(index.mention(for: "deep/branch/leaf.md"), "deep/branch/leaf.md")
        XCTAssertEqual(index.mention(for: "unique.txt"), "a/unique.txt")
        XCTAssertEqual(index.mention(for: "文件不存在"), nil)
        XCTAssertEqual(index.mention(for: ""), nil)

        // `file` is the root path plus two basenames: three matches, so nil.
        XCTAssertNil(index.mention(for: "file"))
        // `readme.md` is a root path and a basename in docs: two matches.
        XCTAssertNil(index.mention(for: "readme.md"))
        // `名字.txt` has only one basename match.
        XCTAssertEqual(index.mention(for: "名字.txt"), "with space/名字.txt")

        // Same path and basename match, but only one file: unique.
        let solo = WorkspaceFileIndex(files: makeFiles(["solo"]))
        XCTAssertEqual(solo.mention(for: "solo"), "solo")
    }

    func testMentionMatchesTheOriginalFilterOnOneThousandRandomFiles() {
        var random = SeededRandom(seed: 0x5EED_2026)
        let files = randomWorkspaceFiles(count: 1_000, random: &random)
        let index = WorkspaceFileIndex(files: files)

        let basenames = files.compactMap { WorkspaceFileIndex.basename(of: $0.relativePath) }
        XCTAssertGreaterThan(
            Dictionary(grouping: basenames, by: { $0 }).values.filter { $0.count > 1 }.count,
            0,
            "the fixture must contain duplicate basenames")

        // Query every path and a sample of basenames, then synthetic misses.
        var queries = files.map(\.relativePath)
        queries.append(contentsOf: basenames.shuffled(using: &random))
        for _ in 0..<200 {
            queries.append("missing/\(random.next() % 10_000)/\(random.next() % 10_000).swift")
        }

        for value in queries {
            XCTAssertEqual(index.mention(for: value), originalMention(value, files: files),
                           "mention mismatch for \(value)")
        }
    }

    func testIndexSearchAndOutputReferencesKeepTheOriginalFilterSemantics() {
        let files = makeFiles([
            "README.md", "docs/readme.md", "src/readme-helper.swift",
            "src/main.swift", "build/readme.md",
        ])
        let index = WorkspaceFileIndex(files: files)

        XCTAssertEqual(index.files(matchingCaseInsensitive: "README", limit: 2),
                       Array(files.prefix(2)),
                       "case-insensitive substring search keeps file-list order")
        XCTAssertEqual(index.files(matchingCaseInsensitive: "", limit: 2),
                       Array(files.prefix(2)),
                       "an empty @ token lists the first files")
        XCTAssertEqual(index.files(matchingCaseInsensitive: "README", limit: 0), [])

        XCTAssertEqual(index.filesReferenced(in: "wrote README.md and build/readme.md", limit: 6),
                       [files[0], files[4]],
                       "output references keep the first-six path order")
        XCTAssertEqual(index.filesReferenced(in: "nothing relevant", limit: 6), [])
    }

    func testIndexIsAnImmutableSnapshot() {
        var source = makeFiles(["one/a.txt", "two/a.txt"])
        let index = WorkspaceFileIndex(files: source)
        source.append(WorkspaceFile(relativePath: "three/a.txt", size: 1))

        XCTAssertNil(index.mention(for: "a.txt"),
                     "the index must not observe later mutations of the input")
        XCTAssertEqual(index.file(atPath: "one/a.txt")?.relativePath, "one/a.txt")
        XCTAssertEqual(index.count, 2)
        XCTAssertNotEqual(index.revision,
                          WorkspaceFileIndex(files: source).revision,
                          "each rebuild needs a fresh render-cache revision")
    }

    // MARK: - Performance

    func testMentionIsOrdersOfMagnitudeFasterThanTheLinearOracle() {
        var random = SeededRandom(seed: 0x5000_0200)
        let files = performanceFiles(count: 5_000, random: &random)
        let snippets = performanceSnippets(files: files)
        let index = WorkspaceFileIndex(files: files)

        // Warm both paths once before timing.
        _ = index.mention(for: snippets[0])
        _ = originalMention(snippets[0], files: files)

        let indexIterations = 10
        let oracleIterations = 3
        var indexHits = 0
        var oracleHits = 0

        let indexStart = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<indexIterations {
            for snippet in snippets {
                if index.mention(for: snippet) != nil { indexHits += 1 }
            }
        }
        let indexMs = Double(DispatchTime.now().uptimeNanoseconds - indexStart)
            / 1_000_000 / Double(indexIterations)

        let oracleStart = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<oracleIterations {
            for snippet in snippets {
                if originalMention(snippet, files: files) != nil { oracleHits += 1 }
            }
        }
        let oracleMs = Double(DispatchTime.now().uptimeNanoseconds - oracleStart)
            / 1_000_000 / Double(oracleIterations)

        XCTAssertEqual(Double(indexHits) / Double(indexIterations),
                       Double(oracleHits) / Double(oracleIterations),
                       "both paths must resolve the same snippets")
        let speedup = oracleMs / max(indexMs, 0.000_001)
        print("WorkspaceFileIndex: 5000 files x 200 snippets -> "
              + String(format: "index %.3f ms, oracle %.3f ms, %.1fx", indexMs, oracleMs, speedup))

        XCTAssertLessThan(indexMs, 50, "200 indexed mentions must stay well under 50 ms")
        XCTAssertLessThan(indexMs * 10, oracleMs,
                          "index must be at least 10x faster than the original filter")
    }

    // MARK: - Fixtures and oracle

    private struct SeededRandom: RandomNumberGenerator {
        private var state: UInt64

        init(seed: UInt64) { state = seed }

        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }

        mutating func next(upperBound: Int) -> Int {
            upperBound <= 0 ? 0 : Int(next() % UInt64(upperBound))
        }
    }

    private func makeFiles(_ paths: [String]) -> [WorkspaceFile] {
        paths.map { WorkspaceFile(relativePath: $0, size: $0.utf8.count) }
    }

    private func randomWorkspaceFiles(count: Int, random: inout SeededRandom) -> [WorkspaceFile] {
        let directories = [
            "", "src", "src/components", "src/util", "docs", "docs/zh", "tests",
            "build", "scripts", "examples", "examples/probe-app", "vendor/lib",
            "a", "a/b", "a/b/c", ".git/objects", ".git/refs",
        ]
        let names = [
            "index.ts", "index.tsx", "readme.md", "package.json", "main.swift",
            "model.py", "test.js", "config.yml", "notes.txt", "a", "b", "file",
            "Makefile", "Dockerfile", "App.swift", "组件.tsx", "名字.md",
        ]
        var files: [WorkspaceFile] = []
        var seen = Set<String>()
        while files.count < count {
            let depth = random.next(upperBound: 4)
            var parts: [String] = []
            for _ in 0..<depth {
                let directory = directories[random.next(upperBound: directories.count)]
                guard !directory.isEmpty else { continue }
                parts.append(contentsOf: directory.split(separator: "/").map(String.init))
            }
            parts.append(names[random.next(upperBound: names.count)])
            let path = parts.joined(separator: "/")
            guard !path.isEmpty, seen.insert(path).inserted else { continue }
            files.append(WorkspaceFile(relativePath: path,
                                       size: random.next(upperBound: 200_000)))
        }
        return files
    }

    private func performanceFiles(count: Int, random: inout SeededRandom) -> [WorkspaceFile] {
        var files: [WorkspaceFile] = []
        files.reserveCapacity(count)
        for index in 0..<count {
            let directory = "tree/\(index % 211)/\(index % 37)"
            files.append(WorkspaceFile(relativePath: "\(directory)/file\(index).swift",
                                       size: index))
        }
        return files
    }

    private func performanceSnippets(files: [WorkspaceFile]) -> [String] {
        var snippets: [String] = []
        snippets.reserveCapacity(200)
        for index in 0..<200 {
            let file = files[(index * 197) % files.count]
            switch index % 4 {
            case 0:
                snippets.append(file.relativePath)
            case 1:
                snippets.append(WorkspaceFileIndex.basename(of: file.relativePath)
                                ?? file.relativePath)
            case 2:
                snippets.append("missing-\(index).swift")
            default:
                snippets.append("tree/\(index % 211)/missing\(index).swift")
            }
        }
        return snippets
    }

    /// The exact pre-S1 `NativeMarkdownInlineText.nativeFileMention` filter
    /// (minus URL construction), kept as the oracle.
    private func originalMention(_ value: String, files: [WorkspaceFile]) -> String? {
        let matches = files.filter {
            $0.relativePath == value
                || $0.relativePath.split(separator: "/").last.map(String.init) == value
        }
        guard matches.count == 1 else { return nil }
        return matches[0].relativePath
    }
}
