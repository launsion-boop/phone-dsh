// SPDX-License-Identifier: MIT
// Read-only projection of `materialized/home/sessions` (P02/P18, W1-A).
//
// The worker's in-memory VFS stays the single authority. This reader never
// writes, renames or repairs anything below `materialized/`; it opens the
// materialized session JSONL copies for display only. Its pages are a snapshot
// and may lag the WAL/worker by up to an open epoch, so the caller must align
// with the engine's `session/list` / `session/page` once the engine is ready and
// keep the engine as the winner on disagreement.
//
// Layout follows DSH 0.2.2-rc.1:
//   <root>/<sessionID>/session.v*.jsonl
//   <root>/<project>/<sessionID>/session.v*.jsonl
// The newest version file of the newest matching directory wins. Every read
// tolerates a torn final line and skips unparseable lines instead of failing.

import Foundation
import PhoneDSHAgentCore

public struct SessionProjectionSummary: Identifiable, Equatable, Sendable {
    public let id: String
    public let project: String?
    public let title: String?
    public let updatedAt: Date
    public let running: Bool
    public let blank: Bool
    public let path: URL
    public let fileSize: Int64

    public init(id: String, project: String?, title: String?,
                updatedAt: Date, running: Bool, blank: Bool,
                path: URL, fileSize: Int64) {
        self.id = id
        self.project = project
        self.title = title
        self.updatedAt = updatedAt
        self.running = running
        self.blank = blank
        self.path = path
        self.fileSize = fileSize
    }
}

/// One display page of a projected session. `items` are presentation rows; the
/// raw records are intentionally not exposed because no write path may replay
/// this projection as a VFS/WAL/journal input (wal.md §11 "Not an input").
public struct SessionProjectionPage: Equatable {
    public let sessionID: String
    public let items: [ChatItem]
    public let beforeSeq: Int?
    public let throughSeq: Int?
    public let hasMore: Bool

    public init(sessionID: String, items: [ChatItem],
                beforeSeq: Int?, throughSeq: Int?, hasMore: Bool) {
        self.sessionID = sessionID
        self.items = items
        self.beforeSeq = beforeSeq
        self.throughSeq = throughSeq
        self.hasMore = hasMore
    }
}

public struct SessionProjectionReader: Sendable {
    public let sessionsRoot: URL
    /// Bounds the per-file prefix/suffix read for `listSessions`; a file larger
    /// than this is summarized from its head and tail without loading it all.
    public static let summaryWindowBytes = 64 * 1024
    /// Default page size, matching the App's existing `session/page` request.
    public static let defaultPageRecords = 60

    public init(sessionsRoot: URL) {
        self.sessionsRoot = sessionsRoot
    }

    // MARK: - Listing

    public func listSessions(limit: Int = 1_000) -> [SessionProjectionSummary] {
        let manager = FileManager.default
        guard let children = try? manager.contentsOfDirectory(
            at: sessionsRoot, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return [] }
        var result: [SessionProjectionSummary] = []
        for child in children {
            guard Self.isDirectory(child) else { continue }
            if let file = newestSessionFile(in: child) {
                result.append(summary(sessionID: child.lastPathComponent,
                                      project: nil, file: file))
                continue
            }
            // One project level, matching BotRecordService's locator.
            guard let nested = try? manager.contentsOfDirectory(
                at: child, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]) else { continue }
            for grandchild in nested {
                guard Self.isDirectory(grandchild),
                      let file = newestSessionFile(in: grandchild) else { continue }
                result.append(summary(sessionID: grandchild.lastPathComponent,
                                      project: child.lastPathComponent, file: file))
            }
        }
        return result
            .sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                return lhs.id < rhs.id
            }
            .prefix(max(0, limit))
            .map { $0 }
    }

    // MARK: - Pages

    public func latestPage(sessionID: String,
                           maxRecords: Int = defaultPageRecords) -> SessionProjectionPage? {
        guard let file = sessionFile(for: sessionID) else { return nil }
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        // A large session is read from its tail first so opening it stays a
        // small parse instead of a full-file one. If the window cannot fill the
        // page, the full file is read and its real `hasMore` is used.
        if size > Self.summaryWindowBytes * 4 {
            let tail = Self.decodeRecords(
                readWindow(at: file, fromEnd: true,
                           byteCount: Self.summaryWindowBytes * 4),
                dropFirstPartial: true, dropLastPartial: true)
            if tail.count >= maxRecords {
                let page = Array(tail.suffix(max(0, maxRecords)))
                return Self.page(sessionID: sessionID, records: page,
                                 hasMore: true)
            }
        }
        guard let records = allRecords(at: file) else { return nil }
        let page = Array(records.suffix(max(0, maxRecords)))
        return Self.page(sessionID: sessionID, records: page,
                         hasMore: records.count > page.count)
    }

    public func page(sessionID: String,
                     beforeSeq: Int,
                     maxRecords: Int = defaultPageRecords) -> SessionProjectionPage? {
        guard let file = sessionFile(for: sessionID),
              let scanned = recordsBefore(at: file, beforeSeq: beforeSeq,
                                          maxRecords: max(0, maxRecords))
        else { return nil }
        return Self.page(sessionID: sessionID, records: scanned.records,
                         hasMore: scanned.hasMore)
    }

    /// Scans JSONL from the end and decodes only the records older than
    /// `beforeSeq`, up to `maxRecords`. A long PC/DSH session therefore pages
    /// from its tail instead of parsing the whole file on every scroll.
    private func recordsBefore(at url: URL, beforeSeq: Int,
                               maxRecords: Int) -> (records: [JSONValue], hasMore: Bool)? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return nil
        }
        guard maxRecords > 0, !data.isEmpty else {
            return ([], data.contains(0x0A))
        }
        var cursor = data.endIndex
        var found: [JSONValue] = []
        var hasMore = false
        while cursor > data.startIndex {
            guard let newline = data[data.startIndex..<cursor].lastIndex(of: 0x0A) else {
                break
            }
            let start = data.index(after: newline)
            defer { cursor = newline }
            guard start < cursor else { continue }
            var line = data[start..<cursor]
            line = line.drop(while: { $0 == 0x20 || $0 == 0x09 || $0 == 0x0D })
            guard !line.isEmpty,
                  let record = try? JSONValue.parse(Data(line)),
                  let seq = record["seq"]?.intValue,
                  seq < beforeSeq else { continue }
            if found.count == maxRecords {
                hasMore = true
                break
            }
            found.append(record)
        }
        return (found.reversed(), hasMore)
    }

    private static func page(sessionID: String,
                             records: [JSONValue],
                             hasMore: Bool) -> SessionProjectionPage {
        let items = NativeTranscriptProjector.items(from: records, sessionID: sessionID)
        return SessionProjectionPage(
            sessionID: sessionID,
            items: items,
            beforeSeq: records.compactMap { $0["seq"]?.intValue }.min(),
            throughSeq: records.compactMap { $0["seq"]?.intValue }.max(),
            hasMore: hasMore)
    }

    // MARK: - File location

    public func sessionFile(for sessionID: String) -> URL? {
        guard !sessionID.isEmpty,
              !sessionID.contains("/"),
              sessionID != ".",
              sessionID != ".." else { return nil }
        let direct = sessionsRoot.appendingPathComponent(sessionID, isDirectory: true)
        if let file = newestSessionFile(in: direct) { return file }
        let manager = FileManager.default
        guard let projects = try? manager.contentsOfDirectory(
            at: sessionsRoot, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return nil }
        for project in projects where Self.isDirectory(project) {
            let nested = project.appendingPathComponent(sessionID, isDirectory: true)
            if let file = newestSessionFile(in: nested) { return file }
        }
        return nil
    }

    private func newestSessionFile(in directory: URL) -> URL? {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else {
            return nil
        }
        let candidates = names.filter {
            $0.hasPrefix("session.v") && $0.hasSuffix(".jsonl")
        }
        guard !candidates.isEmpty else { return nil }
        return candidates
            .map { directory.appendingPathComponent($0) }
            .sorted { lhs, rhs in
                let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                if left != right { return left > right }
                return lhs.lastPathComponent > rhs.lastPathComponent
            }
            .first
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    // MARK: - Decoding

    private func allRecords(at url: URL) -> [JSONValue]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return Self.decodeRecords(data, dropFirstPartial: false, dropLastPartial: true)
    }

    /// Decodes complete JSONL lines. `dropFirstPartial` is for a tail read that
    /// started mid-record; `dropLastPartial` ignores a torn final line (wal.md
    /// §11: a line that is not complete is ignored).
    static func decodeRecords(_ data: Data,
                              dropFirstPartial: Bool,
                              dropLastPartial: Bool) -> [JSONValue] {
        guard !data.isEmpty else { return [] }
        var slice = data[data.startIndex..<data.endIndex]
        if dropFirstPartial, let newline = slice.firstIndex(of: 0x0A) {
            slice = slice[slice.index(after: newline)..<slice.endIndex]
        }
        if dropLastPartial, slice.last != 0x0A,
           let newline = slice.lastIndex(of: 0x0A) {
            slice = slice[slice.startIndex...newline]
        }
        var records: [JSONValue] = []
        for rawLine in slice.split(separator: 0x0A, omittingEmptySubsequences: true) {
            let line = rawLine.drop(while: { $0 == 0x20 || $0 == 0x09 || $0 == 0x0D })
            guard !line.isEmpty, let value = try? JSONValue.parse(Data(line)) else {
                // A corrupt line is skipped; it is never repaired on disk.
                continue
            }
            records.append(value)
        }
        return records
    }

    // MARK: - Summary

    private func summary(sessionID: String, project: String?, file: URL) -> SessionProjectionSummary {
        let attributes = try? file.resourceValues(forKeys: [
            .fileSizeKey, .contentModificationDateKey,
        ])
        let fileSize = Int64(attributes?.fileSize ?? 0)
        let modified = attributes?.contentModificationDate ?? .distantPast
        let head: [JSONValue]
        let tail: [JSONValue]
        if fileSize <= Int64(Self.summaryWindowBytes * 2) {
            let records = allRecords(at: file) ?? []
            head = records
            tail = records
        } else {
            head = Self.decodeRecords(readWindow(at: file, fromEnd: false),
                                      dropFirstPartial: false, dropLastPartial: true)
            tail = Self.decodeRecords(readWindow(at: file, fromEnd: true),
                                      dropFirstPartial: true, dropLastPartial: true)
        }
        let title = head.compactMap(Self.firstUserText).first
        var running = false
        var lastTime: Double?
        var lastSeq: Int?
        for record in tail {
            switch record["type"]?.stringValue {
            case "turn/start": running = true
            case "turn/end": running = false
            default: break
            }
            if let time = record["time"]?.numberValue {
                lastTime = max(lastTime ?? time, time)
            }
            if let seq = record["seq"]?.intValue {
                lastSeq = max(lastSeq ?? seq, seq)
            }
        }
        let updatedAt = lastTime.map { Date(timeIntervalSince1970: $0 / 1_000) } ?? modified
        let blank = title == nil
        return SessionProjectionSummary(
            id: sessionID, project: project, title: title,
            updatedAt: updatedAt, running: running, blank: blank,
            path: file, fileSize: fileSize)
    }

    private func readWindow(at url: URL, fromEnd: Bool,
                            byteCount: Int = summaryWindowBytes) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        do {
            let size = try handle.seekToEnd()
            let window = UInt64(max(1, byteCount))
            let offset = fromEnd ? (size > window ? size - window : 0) : 0
            try handle.seek(toOffset: offset)
            return try handle.read(upToCount: max(1, byteCount)) ?? Data()
        } catch {
            return Data()
        }
    }

    private static func firstUserText(_ record: JSONValue) -> String? {
        guard record["type"]?.stringValue == "user/message" else { return nil }
        let text = contentText(record["data"]?["content"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let collapsed = text.split(whereSeparator: { $0.isNewline })
            .joined(separator: " ")
        return collapsed.count > 80 ? String(collapsed.prefix(80)) + "…" : collapsed
    }

    private static func contentText(_ content: JSONValue?) -> String {
        guard let content else { return "" }
        switch content {
        case .string(let text): return text
        case .array(let blocks):
            return blocks.compactMap { block -> String? in
                switch block["type"]?.stringValue {
                case "text": return block["text"]?.stringValue
                case "image": return nil
                default: return block["text"]?.stringValue
                }
            }.joined(separator: "\n")
        default:
            return ""
        }
    }
}
