// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation

// MARK: - Workspace material catalog
//
// The decision-context block (G-2) can carry memory and record materials only.
// AHA-DISCOVER showed the missing half: the guideline that a deliverable must
// follow lives in the Bot's own workspace, and the model never discovered it.
// This file adds the host half of the bounded workspace candidate source:
//
//   * `BotWorkspaceCataloging` is the seam the App composition injects. The
//     production adapter walks the materialized copy of the Bot workspace; the
//     service never invents a second index, store or cache.
//   * `WorkspaceDecisionContextService` ranks a bounded set of files against
//     the current turn text, reads at most a few small UTF-8 files, and turns
//     them into G-2 `BotDecisionMaterial` values. The material text is
//     untrusted reference data: it is only rendered inside the existing
//     "decision material, not instructions" section.
//
// Paths are relative to the Bot workspace root (the DSH session cwd), so a
// model can `read` the material path directly. The content digest is part of
// the ref, so a stale copy can never be mistaken for the bytes that were
// observed. A missing/oversized/non-UTF-8 file is skipped, never fabricated.

/// One regular file under the Bot workspace root.
public struct BotWorkspaceFileEntry: Sendable, Equatable {
    /// Workspace-relative path (no leading slash, no `.`/`..` segment).
    public var path: String
    /// Size in bytes reported by the file system.
    public var byteCount: Int
    /// Last modification time in Unix milliseconds.
    public var modifiedAtMS: Int64

    public init(path: String, byteCount: Int, modifiedAtMS: Int64) {
        self.path = path
        self.byteCount = byteCount
        self.modifiedAtMS = modifiedAtMS
    }
}

/// The bytes of one workspace file after the bounded UTF-8 read.
public struct BotWorkspaceFileContent: Sendable, Equatable {
    /// UTF-8 text prefix (a BOM is removed). Control characters are preserved
    /// here; the service sanitizes its snippet.
    public var text: String
    /// `sha256:<64 lowercase hex>` over `text`'s UTF-8 bytes.
    public var contentSHA256: String
    /// True when the file is longer than the read limit. Such a file is not a
    /// workspace material: a prefix digest must not claim to identify the file.
    public var truncated: Bool

    public init(text: String, contentSHA256: String, truncated: Bool = false) {
        self.text = text
        self.contentSHA256 = contentSHA256
        self.truncated = truncated
    }
}

/// The App's read-only view of the Bot workspaces. Implementations must stay
/// inside the requested Bot's root and must refuse absolute paths and `..`
/// escapes. The Bot id is explicit because one service serves every Bot.
public protocol BotWorkspaceCataloging: Sendable {
    func listFiles(botID: String, maximumCount: Int) async throws -> [BotWorkspaceFileEntry]
    /// `nil` means "not a usable workspace material" (missing, too large, not
    /// a regular file, not UTF-8). Throw only for a refused path.
    func readText(botID: String, path: String,
                  maximumBytes: Int) async throws -> BotWorkspaceFileContent?
}

public enum BotWorkspaceCatalogError: Error, Equatable, Sendable {
    /// The path is absolute, contains `..`, a backslash or a control character.
    case invalidPath
    /// The Bot root itself is not a `/dsh/workspace/...` path.
    case invalidBotRoot
    /// A resolved path escaped the Bot root (for example through a symlink).
    case pathOutsideWorkspace
    /// The path exists but is not a regular readable file.
    case notRegularFile
}

/// Production adapter over the materialized `/dsh/workspace` mount.
///
/// `workspaceRoot` is the App's host log root (`Library/xl/<workspace_id>/`);
/// the VFS `/dsh/workspace` is its `materialized/workspace` child. The adapter
/// enumerates only the Bot's own root, so another Bot's workspace and
/// `/dsh/home` are out of scope.
public struct BotWorkspaceDirectoryCatalog: BotWorkspaceCataloging {
    public static let defaultMaximumBytes = 64 * 1024
    public static let defaultMaximumListedFiles = 4_096

    public let workspaceRoot: URL
    /// The Bot data directory below `/dsh/workspace` (normally `.dshbot`).
    public let dataDirectory: String
    private let maximumListedFiles: Int

    public init(workspaceRoot: URL,
                dataDirectory: String = BotWorkspaceLayout.defaultBotDataDirectory,
                maximumListedFiles: Int = BotWorkspaceDirectoryCatalog.defaultMaximumListedFiles) {
        self.workspaceRoot = workspaceRoot
        self.dataDirectory = dataDirectory
        self.maximumListedFiles = max(1, maximumListedFiles)
    }

    /// Host directory of one Bot's materialized root, or `nil` for a root
    /// that is not below `/dsh/workspace`.
    public func directoryURL(forBotID botID: String) -> URL? {
        let botRoot = BotWorkspaceLayout.botRoot(botId: botID, dataDirectory: dataDirectory)
        let prefix = "/dsh/workspace/"
        guard botRoot.hasPrefix(prefix) else { return nil }
        let relativeRoot = String(botRoot.dropFirst(prefix.count))
        guard !relativeRoot.isEmpty else { return nil }
        let segments = relativeRoot.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        let root = workspaceRoot
            .appendingPathComponent("materialized", isDirectory: true)
            .appendingPathComponent("workspace", isDirectory: true)
        return segments.reduce(root) { $0.appendingPathComponent(String($1), isDirectory: true) }
    }

    public func listFiles(botID: String,
                          maximumCount: Int) async throws -> [BotWorkspaceFileEntry] {
        guard let directory = directoryURL(forBotID: botID) else {
            throw BotWorkspaceCatalogError.invalidBotRoot
        }
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let limit = max(1, min(maximumCount, maximumListedFiles))
        // DirectoryEnumerator's iterator is not available from an async
        // context (a Swift 6 error); the bounded traversal runs synchronously
        // and only the caller awaits the result.
        return Self.listFiles(in: root, limit: limit)
    }

    private static func listFiles(in root: URL, limit: Int) -> [BotWorkspaceFileEntry] {
        let rootPrefix = root.path + "/"
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return []
        }
        var entries: [BotWorkspaceFileEntry] = []
        entries.reserveCapacity(min(limit, 256))
        for case let url as URL in enumerator {
            if entries.count >= limit { break }
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let size = values.fileSize, size > 0 else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPrefix) else { continue }
            let relative = String(path.dropFirst(rootPrefix.count))
            guard Self.validRelativePath(relative) else { continue }
            let modified = values.contentModificationDate
                .map { Int64(($0.timeIntervalSince1970 * 1_000).rounded()) } ?? 0
            entries.append(BotWorkspaceFileEntry(
                path: relative, byteCount: size, modifiedAtMS: max(0, modified)))
        }
        return entries.sorted { $0.path < $1.path }
    }

    public func readText(botID: String, path: String,
                         maximumBytes: Int) async throws -> BotWorkspaceFileContent? {
        guard let directory = directoryURL(forBotID: botID) else {
            throw BotWorkspaceCatalogError.invalidBotRoot
        }
        guard Self.validRelativePath(path) else {
            throw BotWorkspaceCatalogError.invalidPath
        }
        let limit = max(1, maximumBytes)
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let url = directory.appendingPathComponent(path).standardizedFileURL
        let resolved = url.resolvingSymlinksInPath()
        guard resolved.path != root.path, resolved.path.hasPrefix(root.path + "/") else {
            throw BotWorkspaceCatalogError.pathOutsideWorkspace
        }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let before = try? resolved.resourceValues(forKeys: keys) else { return nil }
        guard before.isRegularFile == true else { return nil }
        guard let size = before.fileSize, size > 0, size <= limit else { return nil }
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: resolved)
        } catch {
            return nil
        }
        defer { try? handle.close() }
        let data: Data
        do {
            data = try handle.read(upToCount: limit + 1) ?? Data()
        } catch {
            return nil
        }
        // G-2 r6: the digest is over the exact bytes read, and an oversized
        // file is not a material (a prefix digest must not claim the file).
        guard data.count == size, data.count <= limit, !data.isEmpty else { return nil }
        guard var text = String(data: data, encoding: .utf8) else { return nil }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        // Re-stat: a file that changed during the read has no stable version.
        guard let after = try? resolved.resourceValues(forKeys: keys),
              after.isRegularFile == true,
              after.fileSize == before.fileSize,
              after.contentModificationDate == before.contentModificationDate else {
            return nil
        }
        let digest = SHA256.hash(data: data)
        let sha = "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
        return BotWorkspaceFileContent(text: text, contentSHA256: sha, truncated: false)
    }

    static func validRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, path.unicodeScalars.count <= 512,
              !path.hasPrefix("/"), !path.hasSuffix("/"),
              !path.contains("\\"), !path.contains("@"),
              !path.unicodeScalars.contains(where: {
                  $0.properties.isWhitespace || CharacterSet.controlCharacters.contains($0)
              })
        else { return false }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        return !segments.isEmpty
            && segments.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

// MARK: - Selection

public struct BotWorkspaceSelection: Sendable, Equatable {
    public var materials: [BotDecisionMaterial]
    /// True when at least one matching candidate did not fit the budget.
    public var truncated: Bool
    /// Characters this selection charged against the shared block budget. It
    /// uses the same cost convention as the memory materials (snippet + ref +
    /// path + 64), so a caller can subtract it before selecting more material.
    public var consumedCharacters: Int

    public init(materials: [BotDecisionMaterial] = [], truncated: Bool = false,
                consumedCharacters: Int = 0) {
        self.materials = materials
        self.truncated = truncated
        self.consumedCharacters = consumedCharacters
    }
}

/// Bounded workspace candidate discovery for one pre-step decision block.
///
/// The service is deliberately not an index: each call lists the injected
/// catalog (bounded count), ranks paths and a small number of contents against
/// the turn text, and returns at most `maximumMaterials` materials. It has no
/// cache and no cross-turn state, so a new turn can never reuse an old file
/// list or an old copy.
public struct WorkspaceDecisionContextService: Sendable {
    public struct Caps: Sendable, Equatable {
        public var maximumListedFiles: Int
        public var maximumReads: Int
        public var maximumBytesPerFile: Int
        public var maximumTotalBytes: Int
        public var maximumQueryTokens: Int

        public init(maximumListedFiles: Int = 4_096,
                    maximumReads: Int = 16,
                    maximumBytesPerFile: Int = BotWorkspaceDirectoryCatalog.defaultMaximumBytes,
                    maximumTotalBytes: Int = 256 * 1024,
                    maximumQueryTokens: Int = 48) {
            self.maximumListedFiles = max(1, maximumListedFiles)
            self.maximumReads = max(1, maximumReads)
            self.maximumBytesPerFile = max(1, maximumBytesPerFile)
            self.maximumTotalBytes = max(1, maximumTotalBytes)
            self.maximumQueryTokens = max(1, maximumQueryTokens)
        }

        public static let `default` = Caps()
    }

    /// Workspace refs must stay inside the G-2 256-scalar ref bound:
    /// `workspace:` (10) + path + `@sha256:` (8) + 64 hex. G-2 r6 allows a
    /// 200-scalar path in principle, but the ref cap makes 174 the real bound.
    public static let maximumRefPathScalars = 174
    public static let maximumPathScalars = 200
    /// G-2 r6 caps workspace materials, independently of the memory slots.
    public static let maximumMaterials = 2

    private let catalog: any BotWorkspaceCataloging
    private let now: @Sendable () -> Int64

    public init(catalog: any BotWorkspaceCataloging,
                now: @escaping @Sendable () -> Int64 = {
                    Int64(Date().timeIntervalSince1970 * 1_000)
                }) {
        self.catalog = catalog
        self.now = now
    }

    /// Rank and read bounded candidates for `query`/`goal`.
    ///
    /// * `materialPrefix` is the block/request id R uses for the memory
    ///   materials; workspace ids become `mat:<prefix>:w<n>` so they cannot
    ///   collide with `mat:<prefix>:<n>`.
    /// * `limits.maxCharacters` is shared with the caller's memory materials:
    ///   the caller passes the remaining budget, and this service stops before
    ///   exceeding it.
    /// * Cancellation and the supplied deadline stop further reads; an empty
    ///   selection is always safe and never blocks the turn.
    public func selection(query: String,
                          goal: String? = nil,
                          botID: String,
                          materialPrefix: String,
                          limits: BotDecisionLimits,
                          caps: Caps = .default) async -> BotWorkspaceSelection {
        let queryTokens = Self.tokens(query)
        let goalTokens = Self.tokens(goal ?? "")
        var seen = Set<String>()
        let tokens = (queryTokens + goalTokens)
            .filter { seen.insert($0).inserted }
            .prefix(caps.maximumQueryTokens)
        guard !tokens.isEmpty else { return BotWorkspaceSelection() }
        let tokenList = Array(tokens)

        let started = now()
        let deadline = Int64(max(100, min(limits.deadlineMilliseconds, 3_000)))
        func expired() -> Bool { now() - started >= deadline }
        func cancelled() -> Bool { Task.isCancelled }

        guard !cancelled(), !expired() else { return BotWorkspaceSelection() }
        let entries = (try? await catalog.listFiles(
            botID: botID, maximumCount: caps.maximumListedFiles)) ?? []
        guard !cancelled() else { return BotWorkspaceSelection() }

        let usable = entries.filter {
            $0.byteCount > 0 && $0.byteCount <= caps.maximumBytesPerFile
                && Self.validWorkspacePath($0.path)
                && $0.path.unicodeScalars.count <= Self.maximumRefPathScalars
        }.map { entry -> (BotWorkspaceFileEntry, Int) in
            (entry, Self.matchCount(tokens: tokenList, in: entry.path.lowercased()))
        }

        // Path matches first; then recent files (a current guideline can be
        // found by content even when the query language and path disagree).
        let pathMatched = usable.filter { $0.1 > 0 }
            .sorted { left, right in
                if left.1 != right.1 { return left.1 > right.1 }
                if left.0.modifiedAtMS != right.0.modifiedAtMS {
                    return left.0.modifiedAtMS > right.0.modifiedAtMS
                }
                return left.0.path < right.0.path
            }
        let rest = usable.filter { $0.1 == 0 }
            .sorted { left, right in
                if left.0.modifiedAtMS != right.0.modifiedAtMS {
                    return left.0.modifiedAtMS > right.0.modifiedAtMS
                }
                return left.0.path < right.0.path
            }
        let toRead = Array((pathMatched + rest).prefix(caps.maximumReads))

        struct Scored {
            let entry: BotWorkspaceFileEntry
            let score: Int
            let snippet: String
            let reason: BotDecisionSelectionReason
            let ref: String
        }
        var scored: [Scored] = []
        var readBytes = 0
        var omitted = 0
        var stoppedEarly = false
        for (entry, pathScore) in toRead {
            if cancelled() || expired() { stoppedEarly = true; break }
            if readBytes + entry.byteCount > caps.maximumTotalBytes {
                stoppedEarly = true
                break
            }
            guard let content = try? await catalog.readText(
                botID: botID, path: entry.path,
                maximumBytes: caps.maximumBytesPerFile) else { continue }
            guard !content.truncated,
                  content.contentSHA256.hasPrefix("sha256:"),
                  content.contentSHA256.unicodeScalars.count == 71,
                  Self.validWorkspacePath(entry.path),
                  let snippet = Self.snippet(
                    content.text, tokens: tokenList,
                    limit: limits.maxSnippetCharacters),
                  !snippet.isEmpty else { continue }
            readBytes += entry.byteCount
            let contentMatches = Self.matchCount(
                tokens: tokenList, in: content.text.lowercased())
            let score = pathScore * 3 + contentMatches * 2
            guard score > 0 else { continue }
            let ref = "workspace:\(entry.path)@\(content.contentSHA256)"
            guard ref.unicodeScalars.count <= 256 else { continue }
            let reason: BotDecisionSelectionReason
            if !goalTokens.isEmpty,
               Self.matchCount(tokens: goalTokens,
                              in: content.text.lowercased() + " " + entry.path.lowercased()) > 0 {
                reason = .goal
            } else {
                reason = .match
            }
            scored.append(Scored(entry: entry, score: score, snippet: snippet,
                                 reason: reason, ref: ref))
        }

        scored.sort { left, right in
            if left.score != right.score { return left.score > right.score }
            if left.entry.modifiedAtMS != right.entry.modifiedAtMS {
                return left.entry.modifiedAtMS > right.entry.modifiedAtMS
            }
            return left.entry.path < right.entry.path
        }

        let prefix = Self.safeMaterialPrefix(materialPrefix)
        var materials: [BotDecisionMaterial] = []
        var usedCharacters = 0
        for candidate in scored {
            if materials.count >= Self.maximumMaterials { omitted += 1; continue }
            if materials.count >= limits.maxMaterials { omitted += 1; continue }
            let cost = candidate.snippet.unicodeScalars.count
                + candidate.ref.unicodeScalars.count
                + candidate.entry.path.unicodeScalars.count + 64
            if usedCharacters + cost > limits.maxCharacters { omitted += 1; continue }
            usedCharacters += cost
            materials.append(BotDecisionMaterial(
                materialID: "mat:\(prefix):w\(materials.count + 1)",
                ref: candidate.ref,
                path: candidate.entry.path,
                scope: .agent,
                version: Self.version(for: candidate.entry),
                updatedAtMS: candidate.entry.modifiedAtMS,
                snippet: candidate.snippet,
                evidence: [],
                selectionReason: candidate.reason,
                state: .current,
                reason: nil))
        }
        return BotWorkspaceSelection(
            materials: materials,
            truncated: omitted > 0 || stoppedEarly,
            consumedCharacters: usedCharacters)
    }

    /// Current content digest of a `workspace:` ref. The pre-delivery review
    /// uses this instead of pretending a workspace file is a memory document.
    /// Returns `nil` when the ref is not a workspace ref or the file is no
    /// longer a usable material.
    public func currentContentSHA256(forWorkspaceRef ref: String,
                                     botID: String) async -> String? {
        guard let path = Self.workspacePath(fromRef: ref) else { return nil }
        guard let content = try? await catalog.readText(
            botID: botID, path: path,
            maximumBytes: BotWorkspaceDirectoryCatalog.defaultMaximumBytes) else {
            return nil
        }
        guard !content.truncated, content.contentSHA256.hasPrefix("sha256:") else { return nil }
        return content.contentSHA256
    }

    // MARK: pure helpers

    static func validWorkspacePath(_ path: String) -> Bool {
        guard !path.isEmpty, path.unicodeScalars.count <= maximumPathScalars,
              !path.hasPrefix("/"), !path.hasSuffix("/"),
              !path.contains("\\"), !path.contains("@"),
              !path.unicodeScalars.contains(where: {
                  $0.properties.isWhitespace || CharacterSet.controlCharacters.contains($0)
              })
        else { return false }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        return !segments.isEmpty
            && segments.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// The digest stored in a `workspace:` ref (`sha256:<64hex>`), or `nil`
    /// for any other ref. The pre-delivery review compares it with a fresh
    /// read instead of treating the workspace file as a memory document.
    public static func workspaceDigest(fromRef ref: String) -> String? {
        guard ref.hasPrefix("workspace:") else { return nil }
        guard let marker = ref.range(of: "@sha256:", options: .backwards) else { return nil }
        let digest = String(ref[marker.upperBound...])
        guard digest.count == 64,
              digest.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
        return "sha256:" + digest
    }

    static func workspacePath(fromRef ref: String) -> String? {
        let prefix = "workspace:"
        guard ref.hasPrefix(prefix), ref.unicodeScalars.count <= 256 else { return nil }
        let rest = String(ref.dropFirst(prefix.count))
        guard let marker = rest.range(of: "@sha256:", options: .backwards) else { return nil }
        let path = String(rest[..<marker.lowerBound])
        let digest = String(rest[marker.upperBound...])
        guard validWorkspacePath(path),
              path.unicodeScalars.count <= maximumRefPathScalars,
              digest.count == 64,
              digest.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
        return path
    }

    static func tokens(_ value: String) -> [String] {
        var tokens: [String] = []
        var current: [Unicode.Scalar] = []
        func flush() {
            guard !current.isEmpty else { return }
            let run = current
            current.removeAll(keepingCapacity: true)
            let ascii = run.allSatisfy { $0.isASCII }
            if ascii {
                let text = String(run.map { Character($0) }).lowercased()
                if text.count >= 2 { tokens.append(text) }
            } else {
                let characters = run.map(Character.init)
                if characters.count == 1 {
                    tokens.append(String(characters[0]).lowercased())
                } else if characters.count > 1 {
                    for index in 0..<(characters.count - 1) {
                        tokens.append(String(characters[index...index + 1]).lowercased())
                    }
                }
            }
        }
        for scalar in value.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.append(scalar)
            } else {
                flush()
            }
        }
        flush()
        var seen = Set<String>()
        return tokens.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func matchCount(tokens: [String], in haystack: String) -> Int {
        guard !haystack.isEmpty else { return 0 }
        return tokens.reduce(0) { count, token in
            haystack.range(of: token) == nil ? count : count + 1
        }
    }

    static func version(for entry: BotWorkspaceFileEntry) -> Int {
        let seconds = entry.modifiedAtMS / 1_000
        guard seconds >= 1 else { return 1 }
        return min(Int(seconds), Int(Int32.max))
    }

    static func safeMaterialPrefix(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._:-"))
        var output = ""
        for scalar in raw.unicodeScalars {
            output.append(allowed.contains(scalar) ? String(scalar) : "_")
        }
        if output.isEmpty { output = "ws" }
        return String(output.prefix(40))
    }

    static func snippet(_ text: String, tokens: [String], limit: Int) -> String? {
        let limit = max(1, limit)
        guard !text.isEmpty else { return nil }
        let scalars = text.unicodeScalars.count
        if scalars <= limit {
            return sanitized(text, limit: limit)
        }
        // A short guideline is more useful as its beginning (title + rules)
        // than as one line around a query word: the model must be able to see
        // the actual requirement, not just that the file matched. A long file
        // keeps the matching window instead.
        if scalars <= limit * 3 {
            let prefix = sanitized(text, limit: limit)
            if !prefix.isEmpty { return prefix }
        }
        var firstRange: Range<String.Index>?
        for token in tokens {
            guard let range = text.range(of: token, options: [.caseInsensitive, .diacriticInsensitive])
            else { continue }
            if firstRange == nil || range.lowerBound < firstRange!.lowerBound {
                firstRange = range
            }
        }
        if let range = firstRange {
            let line = text.lineRange(for: range)
            var value = String(text[line]).trimmingCharacters(in: .whitespacesAndNewlines)
            if value.unicodeScalars.count > limit {
                let offset = text.distance(from: line.lowerBound, to: range.lowerBound)
                let startOffset = max(0, offset - limit / 3)
                let start = text.index(line.lowerBound, offsetBy: startOffset)
                let available = text.distance(from: start, to: line.upperBound)
                let end = text.index(start, offsetBy: min(limit, available))
                value = String(text[start..<end])
            }
            return sanitized(value, limit: limit)
        }
        return sanitized(text, limit: limit)
    }

    static func sanitized(_ value: String, limit: Int) -> String {
        let folded = value
            .components(separatedBy: .controlCharacters).joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return boundedScalars(folded, limit)
    }

    static func boundedScalars(_ value: String, _ limit: Int) -> String {
        let scalars = value.unicodeScalars
        guard scalars.count > limit else { return value }
        var view = String.UnicodeScalarView()
        view.reserveCapacity(limit)
        for scalar in scalars {
            if view.count >= limit { break }
            view.append(scalar)
        }
        return String(view)
    }
}
