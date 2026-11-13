// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — host-only closed-session rewrite (wal.md §5.3).
//
// The Worker never calls this path. The App parks the Worker, asks the host to
// replace erased session-log lines with tombstones supplied by the Bot layer,
// removes older generations, closes the rewrite epoch and compacts every older
// WAL segment. The proof step rescans the WAL and the operation fails loud if
// any pre-rewrite segment survives.

import Foundation
import PhoneDSHLog
import PhoneDSHWire

/// One session-log line to replace. `line` is a complete JSON object without
/// the trailing newline; the host verifies that its `seq` matches.
public struct PhoneDSHSessionLineReplacement: Sendable, Equatable {
    public var seq: Int
    public var line: Data

    public init(seq: Int, line: Data) {
        self.seq = seq
        self.line = line
    }
}

/// One closed-session rewrite request.
public struct PhoneDSHSessionErasureRequest: Sendable, Equatable {
    public var sessionID: String
    public var replacements: [PhoneDSHSessionLineReplacement]
    /// Remove every older `session.v<N>.jsonl(.zstd)` generation in the same
    /// session directory after the current generation is rewritten.
    public var removeOlderGenerations: Bool

    public init(sessionID: String,
                replacements: [PhoneDSHSessionLineReplacement],
                removeOlderGenerations: Bool = true) {
        self.sessionID = sessionID
        self.replacements = replacements
        self.removeOlderGenerations = removeOlderGenerations
    }
}

public struct PhoneDSHSessionErasureResult: Sendable, Equatable {
    public var sessionID: String
    public var erasedSeqs: [Int]
    public var rewrittenFiles: [String]
    public var removedFiles: [String]
    public var rewriteStartMseq: UInt64
    public var rewriteMseq: UInt64
    public var droppedSegments: [String]

    public init(sessionID: String, erasedSeqs: [Int], rewrittenFiles: [String],
                removedFiles: [String], rewriteStartMseq: UInt64,
                rewriteMseq: UInt64, droppedSegments: [String]) {
        self.rewriteStartMseq = rewriteStartMseq
        self.sessionID = sessionID
        self.erasedSeqs = erasedSeqs
        self.rewrittenFiles = rewrittenFiles
        self.removedFiles = removedFiles
        self.rewriteMseq = rewriteMseq
        self.droppedSegments = droppedSegments
    }
}

enum SessionLogErasureError: Error, CustomStringConvertible {
    case invalidSessionID(String)
    case pendingReconcile
    case unsupportedCompressedGeneration(String)
    case sessionNotFound(String)
    case unknownLine(sessionID: String, seq: Int)
    case invalidReplacement(sessionID: String, seq: Int, reason: String)
    case retainedHistory(sessionID: String, segments: [String])

    var description: String {
        switch self {
        case .invalidSessionID(let value):
            return "invalid closed-session id \(value)"
        case .pendingReconcile:
            return "a reconcile is pending; recover the workspace before rewriting a session log"
        case .unsupportedCompressedGeneration(let path):
            return "session log \(path) is zstd-compressed; this host cannot rewrite it"
        case .sessionNotFound(let sessionID):
            return "no materialized session log exists for \(sessionID)"
        case .unknownLine(let sessionID, let seq):
            return "session \(sessionID) has no line at seq \(seq)"
        case .invalidReplacement(let sessionID, let seq, let reason):
            return "replacement for \(sessionID)#\(seq) is invalid: \(reason)"
        case .retainedHistory(let sessionID, let segments):
            return "closed-session rewrite for \(sessionID) left pre-rewrite WAL segments: "
                + segments.joined(separator: ", ")
        }
    }
}

/// Pure helpers shared by the host method and its tests.
enum SessionLogErasure {
    private struct SessionLogFile {
        var url: URL
        var relativePath: String
        var version: UInt64
        var data: Data
    }

    static func validSessionID(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 64,
              value != ".", value != ".." else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII
                && (CharacterSet.alphanumerics.contains(scalar)
                    || scalar == "." || scalar == "_" || scalar == "-")
        }
    }

    private static func sessionLogFiles(in sessionDirectory: URL,
                                        sessionsRoot: URL) throws -> [SessionLogFile] {
        let names = try FileManager.default.contentsOfDirectory(atPath: sessionDirectory.path)
        var files: [SessionLogFile] = []
        for name in names {
            var versionText = ""
            var compressed = false
            if name.hasPrefix("session.v") && name.hasSuffix(".jsonl") {
                versionText = String(name.dropFirst("session.v".count).dropLast(".jsonl".count))
            } else if name.hasPrefix("session.v") && name.hasSuffix(".jsonl.zstd") {
                versionText = String(name.dropFirst("session.v".count).dropLast(".jsonl.zstd".count))
                compressed = true
            } else {
                continue
            }
            guard let version = UInt64(versionText) else { continue }
            if compressed {
                throw SessionLogErasureError.unsupportedCompressedGeneration(
                    sessionDirectory.appendingPathComponent(name).path)
            }
            let url = sessionDirectory.appendingPathComponent(name)
            let data = try Data(contentsOf: url)
            let rootPath = sessionsRoot.standardizedFileURL.path
            let filePath = url.standardizedFileURL.path
            let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            guard filePath.hasPrefix(prefix) else { continue }
            let relative = String(filePath.dropFirst(prefix.count))
            files.append(SessionLogFile(url: url, relativePath: relative,
                                        version: version, data: data))
        }
        return files.sorted { $0.version > $1.version }
    }

    private static func splitLines(_ data: Data) -> (lines: [Data], trailingNewline: Bool) {
        var lines: [Data] = []
        var current = Data()
        for byte in data {
            if byte == 0x0A {
                lines.append(current)
                current = Data()
            } else {
                current.append(byte)
            }
        }
        let trailingNewline = !current.isEmpty
        if !current.isEmpty { lines.append(current) }
        return (lines, trailingNewline)
    }

    private static func seq(of line: Data) -> Int? {
        guard !line.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let number = object["seq"] as? NSNumber,
              number.doubleValue.rounded() == number.doubleValue,
              number.intValue >= 0 else { return nil }
        return number.intValue
    }

    private static func joined(_ lines: [Data], trailingNewline: Bool) -> Data {
        var data = Data()
        for (index, line) in lines.enumerated() {
            if index > 0 { data.append(0x0A) }
            data.append(line)
        }
        if trailingNewline || (!lines.isEmpty && data.last != 0x0A) {
            data.append(0x0A)
        }
        return data
    }

    private static func replacementMap(_ request: PhoneDSHSessionErasureRequest) throws
        -> [Int: Data] {
        var result: [Int: Data] = [:]
        for replacement in request.replacements {
            guard replacement.seq >= 0 else {
                throw SessionLogErasureError.invalidReplacement(
                    sessionID: request.sessionID, seq: replacement.seq,
                    reason: "negative seq")
            }
            guard !replacement.line.isEmpty,
                  !replacement.line.contains(0x0A),
                  let object = try? JSONSerialization.jsonObject(with: replacement.line)
                    as? [String: Any],
                  let number = object["seq"] as? NSNumber,
                  number.intValue == replacement.seq else {
                throw SessionLogErasureError.invalidReplacement(
                    sessionID: request.sessionID, seq: replacement.seq,
                    reason: "not a JSON object carrying the same seq")
            }
            guard result[replacement.seq] == nil else {
                throw SessionLogErasureError.invalidReplacement(
                    sessionID: request.sessionID, seq: replacement.seq,
                    reason: "duplicate replacement")
            }
            result[replacement.seq] = replacement.line
        }
        return result
    }

    /// Rewrites the newest generation and returns the mutations to append plus
    /// the paths to remove. The current generation must be uncompressed.
    static func plan(request: PhoneDSHSessionErasureRequest,
                     workspaceRoot: URL) throws -> (writes: [VfsMutationBody],
                                                    removes: [VfsMutationBody],
                                                    rewritten: [String],
                                                    removed: [String],
                                                    erasedSeqs: [Int]) {
        guard validSessionID(request.sessionID) else {
            throw SessionLogErasureError.invalidSessionID(request.sessionID)
        }
        let replacements = try replacementMap(request)
        let sessionsRoot = workspaceRoot
            .appendingPathComponent("materialized/home/sessions", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else {
            throw SessionLogErasureError.sessionNotFound(request.sessionID)
        }
        var directories: [URL] = []
        for case let url as URL in enumerator where url.lastPathComponent == request.sessionID {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true {
                directories.append(url)
                enumerator.skipDescendants()
            }
        }
        guard !directories.isEmpty else {
            throw SessionLogErasureError.sessionNotFound(request.sessionID)
        }

        var writes: [VfsMutationBody] = []
        var removes: [VfsMutationBody] = []
        var rewritten: [String] = []
        var removed: [String] = []
        var erased = Set<Int>()
        for directory in directories.sorted(by: { $0.path < $1.path }) {
            let files = try sessionLogFiles(in: directory, sessionsRoot: sessionsRoot)
            guard let newest = files.first else { continue }
            let lines = splitLines(newest.data)
            var changed = false
            var replacementLines: [Data] = []
            var directoryErased = Set<Int>()
            for line in lines.lines {
                guard let lineSeq = seq(of: line), let replacement = replacements[lineSeq] else {
                    replacementLines.append(line)
                    continue
                }
                replacementLines.append(replacement)
                directoryErased.insert(lineSeq)
                erased.insert(lineSeq)
                changed = true
            }
            for requested in replacements.keys where !directoryErased.contains(requested) {
                // A missing seq can be a retry after a partial rewrite; accept
                // it only when the line is already gone. A request that never
                // existed is not silently covered.
                let present = lines.lines.contains { seq(of: $0) == requested }
                if present {
                    throw SessionLogErasureError.unknownLine(
                        sessionID: request.sessionID, seq: requested)
                }
            }
            if changed {
                let data = joined(replacementLines, trailingNewline: lines.trailingNewline)
                let vfsPath = "/dsh/home/sessions/" + newest.relativePath
                writes.append(VfsMutationBody(op: .write, mode: 0o644,
                                              path: vfsPath, data: data))
                rewritten.append(newest.relativePath)
            }
            if request.removeOlderGenerations {
                for file in files.dropFirst() {
                    let vfsPath = "/dsh/home/sessions/" + file.relativePath
                    removes.append(VfsMutationBody(op: .remove, mode: 0,
                                                   path: vfsPath, data: Data()))
                    removed.append(file.relativePath)
                }
            }
        }
        return (writes, removes, rewritten, removed, erased.sorted())
    }

    private static func chunks(_ data: Data,
                               limit: Int = WireLimits.maxMutationDataBytes) -> [Data] {
        guard data.count > limit else { return [data] }
        var result: [Data] = []
        var offset = 0
        while offset < data.count {
            let end = min(offset + limit, data.count)
            result.append(data.subdata(in: offset..<end))
            offset = end
        }
        return result
    }

    static func writeMutations(path: String, data: Data) -> [VfsMutationBody] {
        let parts = chunks(data)
        guard let first = parts.first else {
            return [VfsMutationBody(op: .write, mode: 0o644, path: path, data: Data())]
        }
        var result = [VfsMutationBody(op: .write, mode: 0o644, path: path, data: first)]
        var offset = first.count
        for part in parts.dropFirst() {
            result.append(VfsMutationBody(op: .write, mode: 0o644,
                                          mflags: [.appended],
                                          appendFrom: UInt64(offset),
                                          path: path, data: part))
            offset += part.count
        }
        return result
    }

    /// Applies one request against the parked host's log. The caller owns the
    /// parked-state precondition.
    static func apply(request: PhoneDSHSessionErasureRequest,
                      workspaceRoot: URL,
                      log: WorkspaceLog) async throws -> PhoneDSHSessionErasureResult {
        let paths = WorkspacePaths(root: workspaceRoot)
        guard !FileManager.default.fileExists(atPath: paths.reconcileMarkerURL.path) else {
            throw SessionLogErasureError.pendingReconcile
        }
        let plan = try plan(request: request, workspaceRoot: workspaceRoot)

        // Close the current epoch so the first rewrite record starts a fresh
        // segment that no pre-rewrite record shares (wal.md §5.3 step 2).
        _ = try await log.closeEpoch()
        let positions = await log.positions()
        let rewriteStart = UInt64(positions.nextMseq)

        var rewriteMseq: UInt64 = rewriteStart
        for write in plan.writes {
            let path = write.path
            let data = write.data
            var mutations = [write]
            // A complete write larger than one mutation is split according to
            // the same rule the Worker uses (wal.md §3 appended suffixes).
            if data.count > WireLimits.maxMutationDataBytes {
                mutations = writeMutations(path: path, data: data)
            }
            for mutation in mutations {
                rewriteMseq = try await log.append(mutation)
            }
        }
        for remove in plan.removes {
            rewriteMseq = try await log.append(remove)
        }
        _ = try await log.closeEpoch()
        let dropped = try await log.compactDroppableSegments()

        let scan = try WALReader.scan(directory: paths.walDirectory)
        let retained = scan.segments.filter { segment in
            guard let first = segment.firstMutationMseq else { return false }
            return first < rewriteStart
        }
        if !retained.isEmpty {
            throw SessionLogErasureError.retainedHistory(
                sessionID: request.sessionID,
                segments: retained.map(\.fileName))
        }
        if let old = scan.allRecords.first(where: { record in
            guard !record.isEpochClose, record.mseq < rewriteStart,
                  let body = try? record.mutationBody() else { return false }
            return body.path.contains("/home/sessions/")
        }) {
            throw SessionLogErasureError.retainedHistory(
                sessionID: request.sessionID,
                segments: ["record mseq \(old.mseq)"])
        }

        removeDerivedCopies(root: workspaceRoot, sessionIDs: [request.sessionID])
        return PhoneDSHSessionErasureResult(
            sessionID: request.sessionID,
            erasedSeqs: plan.erasedSeqs,
            rewrittenFiles: plan.rewritten,
            removedFiles: plan.removed,
            rewriteStartMseq: rewriteStart,
            rewriteMseq: rewriteMseq,
            droppedSegments: dropped)
    }

    /// The boot overlay, reconcile scratch trees and the DSH session projection
    /// cache are derived copies of the materialized sessions. A successful
    /// rewrite must not leave the old session bytes in them (wal.md §5.3
    /// step 5). The projection cache is keyed by session id and is rebuilt on
    /// demand, so removing only the erased sessions is enough.
    static func removeDerivedCopies(root: URL, sessionIDs: Set<String> = []) {
        let manager = FileManager.default
        for name in ["overlay-cache.tar", "overlay-cache.json"] {
            try? manager.removeItem(at: root.appendingPathComponent(name))
        }
        // The per-file fragment cache holds derived file bytes as well; a
        // rewrite must not leave the old session content in it (wal.md §5.3
        // step 5). Rebuilt on the next boot overlay.
        try? manager.removeItem(at: root.appendingPathComponent("overlay-frags",
                                                                isDirectory: true))
        if let names = try? manager.contentsOfDirectory(atPath: root.path) {
            for name in names where name.hasPrefix("overlay-") && name.hasSuffix(".tar") {
                try? manager.removeItem(at: root.appendingPathComponent(name))
            }
        }
        for name in ["materialized.staging", "recovery-backup"] {
            try? manager.removeItem(at: root.appendingPathComponent(name, isDirectory: true))
        }
        let projectionRoot = root
            .appendingPathComponent("materialized/home/storages/session_projcache/sessions",
                                    isDirectory: true)
        for sessionID in sessionIDs {
            try? manager.removeItem(
                at: projectionRoot.appendingPathComponent("\(sessionID).json"))
        }
    }
}
