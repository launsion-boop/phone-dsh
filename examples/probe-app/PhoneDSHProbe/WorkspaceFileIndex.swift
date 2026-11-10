// SPDX-License-Identifier: MIT
// Workspace mention lookup, built once per file-list change.
//
// The inline Markdown renderer used to scan every workspace file (and split
// every path on "/") for each code span. On a repository-sized workspace that
// is `code spans × files` work inside every visible row body. The index keeps
// the two lookups the old filter implemented, so a mention is two dictionary
// reads instead of a full scan.

import Foundation

/// One file under the materialized workspace.
struct WorkspaceFile: Identifiable, Hashable, Sendable {
    let relativePath: String
    let size: Int
    var id: String { relativePath }
}

/// Immutable lookup tables over a workspace file list.
///
/// `mention(for:)` has exactly the semantics of the original filter:
/// a file matches when its relative path equals `value` or its final "/"
/// component equals `value`; the match must be unique after de-duplicating the
/// union of both conditions. File paths are unique in a real workspace (the
/// workspace tree is a filesystem), and construction de-duplicates a repeated
/// path as well.
struct WorkspaceFileIndex: Sendable {
    /// Only the basename count and first path are needed: a mention is unique
    /// when the count is one, and then the first path is the answer.
    struct BasenameEntry: Sendable {
        let count: Int
        let firstPath: String
    }

    static let empty = WorkspaceFileIndex(files: [])

    let byPath: [String: WorkspaceFile]
    let byBasename: [String: BasenameEntry]
    /// Read-order copy for the two output-text searches that cannot be
    /// expressed as an exact path lookup. Existing filters kept the input order.
    let orderedFiles: [WorkspaceFile]
    /// Monotonic identity used by render caches; changes on every rebuild.
    let revision: Int

    private static let revisionLock = NSLock()
    private static var revisionCounter = 0

    init(files: [WorkspaceFile]) {
        var byPath: [String: WorkspaceFile] = [:]
        var byBasename: [String: BasenameEntry] = [:]
        var orderedFiles: [WorkspaceFile] = []
        byPath.reserveCapacity(files.count)
        orderedFiles.reserveCapacity(files.count)

        for file in files {
            // A duplicated path must not count twice: `mention` is defined over
            // the de-duplicated union, and the old filter saw unique paths.
            guard byPath[file.relativePath] == nil else { continue }
            byPath[file.relativePath] = file
            orderedFiles.append(file)
            guard let basename = Self.basename(of: file.relativePath) else { continue }
            if let entry = byBasename[basename] {
                byBasename[basename] = BasenameEntry(count: entry.count + 1,
                                                     firstPath: entry.firstPath)
            } else {
                byBasename[basename] = BasenameEntry(count: 1,
                                                     firstPath: file.relativePath)
            }
        }

        self.byPath = byPath
        self.byBasename = byBasename
        self.orderedFiles = orderedFiles
        self.revision = Self.nextRevision()
    }

    var count: Int { byPath.count }
    var isEmpty: Bool { byPath.isEmpty }

    func file(atPath path: String) -> WorkspaceFile? {
        byPath[path]
    }

    /// The composer's `@` menu: case-insensitive substring search over the
    /// paths in the original list order. It is still a text scan, so callers
    /// that run inside a SwiftUI body cache the result by `revision` + token.
    func files(matchingCaseInsensitive token: String, limit: Int) -> [WorkspaceFile] {
        guard limit > 0 else { return [] }
        if token.isEmpty { return Array(orderedFiles.prefix(limit)) }
        var result: [WorkspaceFile] = []
        result.reserveCapacity(min(limit, orderedFiles.count))
        for file in orderedFiles where file.relativePath.localizedCaseInsensitiveContains(token) {
            result.append(file)
            if result.count == limit { break }
        }
        return result
    }

    /// The output/command-result surface: the first files whose full path
    /// appears in `text`. This is the unchanged `localizedStandardContains`
    /// filter, with the same first-six order; callers cache it by revision and
    /// text hash because it is a text scan, not a path lookup.
    func filesReferenced(in text: String, limit: Int) -> [WorkspaceFile] {
        guard limit > 0 else { return [] }
        var result: [WorkspaceFile] = []
        result.reserveCapacity(min(limit, orderedFiles.count))
        for file in orderedFiles where text.localizedStandardContains(file.relativePath) {
            result.append(file)
            if result.count == limit { break }
        }
        return result
    }

    /// The path a `code span` names when exactly one file matches, else nil.
    ///
    /// The union is de-duplicated: a root file named `x` matches both by path
    /// and by basename, but that is one match, while `x` plus `dir/x` is two.
    func mention(for value: String) -> String? {
        guard !value.isEmpty else { return nil }
        let exact = byPath[value]
        let basenameEntry = byBasename[value]
        // A basename can never contain "/", so `byBasename[value]` already
        // ignores path-shaped values. The exact path must only be added to the
        // basename count when it is not also one of those basename matches.
        let exactIsAlsoBasename = exact.map { Self.basename(of: $0.relativePath) == value } ?? false
        let matches = (basenameEntry?.count ?? 0)
            + (exact == nil || exactIsAlsoBasename ? 0 : 1)
        guard matches == 1 else { return nil }
        return exact?.relativePath ?? basenameEntry?.firstPath
    }

    /// The same final-component rule the old filter used. `nil` for a path
    /// made only of separators.
    static func basename(of path: String) -> String? {
        path.split(separator: "/").last.map(String.init)
    }

    private static func nextRevision() -> Int {
        revisionLock.lock()
        defer { revisionLock.unlock() }
        revisionCounter &+= 1
        return revisionCounter
    }
}
