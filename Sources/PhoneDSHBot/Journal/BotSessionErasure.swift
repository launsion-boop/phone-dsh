// SPDX-License-Identifier: MIT

import Foundation

/// The one tombstone event the host writes into an erased session-log line.
/// DSH admits an unknown event only when it carries `ignorable: true`; the
/// surface projector then skips it. The payload is part of P02 §5.3 / P25 §4.6
/// and must not gain a second spelling.
public enum BotSessionErasureTombstone {
    public static let type = "phone-dsh/session-erasure"
    public static let marker = "<session_continuation>"

    public static func line(sessionID: String, seq: Int, time: Int64,
                            erasureID: String) throws -> Data {
        let object: [String: Any] = [
            "type": type,
            "seq": seq,
            "time": time,
            "ignorable": true,
            "data": [
                "erased": true,
                "erasureId": erasureID,
                "record": "record://session/\(sessionID)#\(seq)",
            ],
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

/// One parsed DSH session-log line. `raw` is the canonical one-line JSON text;
/// a tombstone is marked `erased` and never contributes searchable content.
public struct BotSessionLogLine: Sendable, Equatable {
    public var seq: Int
    public var raw: String
    public var type: String
    public var time: Int64
    public var surfaceOp: BotDSHSurfaceOp?
    public var searchable: String
    /// Every string value in the line, including `arguments`, `rawOutput`, and
    /// other fields the search projection hides. Erasure matching uses this,
    /// never the narrower search projection.
    public var allText: String
    public var erased: Bool

    public init(seq: Int, raw: String, type: String, time: Int64,
                surfaceOp: BotDSHSurfaceOp?, searchable: String,
                allText: String = "", erased: Bool) {
        self.seq = seq
        self.raw = raw
        self.type = type
        self.time = time
        self.surfaceOp = surfaceOp
        self.searchable = searchable
        self.allText = allText
        self.erased = erased
    }
}

/// The single session-log line reader used by `phone record`, erasure and the
/// continuity seam. It owns the skipped-record and tombstone rules so neither
/// caller can invent a second parser.
public enum BotSessionLogReader {
    public static func lines(from data: Data) -> [BotSessionLogLine] {
        var result: [BotSessionLogLine] = []
        var first = true
        for rawLine in data.split(separator: 0x0A, omittingEmptySubsequences: false) {
            let line = String(decoding: rawLine, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(
                    with: Data(line.utf8)) as? [String: Any] else { continue }
            if first {
                first = false
                if object["type"] as? String == "session" { continue }
            }
            guard let seq = object["seq"] as? Int,
                  let type = object["type"] as? String else { continue }
            let time = (object["time"] as? NSNumber)?.int64Value ?? 0
            var surface: BotDSHSurfaceOp?
            if let op = object["surfaceOp"] as? [String: Any],
               op["op"] as? String == "replace",
               let start = op["startSeq"] as? Int,
               let end = op["endSeq"] as? Int, start <= end {
                surface = .replace(startSeq: start, endSeq: end)
            }
            let decodedData = object["data"]
            result.append(BotSessionLogLine(
                seq: seq, raw: line, type: type, time: time, surfaceOp: surface,
                searchable: searchable(decodedData ?? [:]),
                allText: allStrings(decodedData ?? [:]),
                erased: type == BotSessionErasureTombstone.type))
        }
        return result
    }

    public static func searchable(_ value: Any) -> String {
        var parts: [String] = []
        func walk(_ value: Any, depth: Int) {
            guard depth < 12, parts.reduce(0, { $0 + $1.utf8.count }) < 64 * 1024 else { return }
            switch value {
            case let text as String: parts.append(text)
            case let number as NSNumber: parts.append(number.stringValue)
            case let array as [Any]: array.forEach { walk($0, depth: depth + 1) }
            case let object as [String: Any]:
                for (key, item) in object
                where !["rawOutput", "raw", "stream", "usage", "arguments"].contains(key) {
                    parts.append(key)
                    walk(item, depth: depth + 1)
                }
            default: break
            }
        }
        walk(value, depth: 0)
        return parts.joined(separator: " ")
    }

    public static func allStrings(_ value: Any) -> String {
        var parts: [String] = []
        func walk(_ value: Any, depth: Int) {
            guard depth < 16, parts.reduce(0, { $0 + $1.utf8.count }) < 1024 * 1024 else { return }
            switch value {
            case let text as String: parts.append(text)
            case let array as [Any]: array.forEach { walk($0, depth: depth + 1) }
            case let object as [String: Any]: object.values.forEach { walk($0, depth: depth + 1) }
            default: break
            }
        }
        walk(value, depth: 0)
        return parts.joined(separator: " ")
    }

    public static func locate(sessionID: String, workspaceRoot: URL) -> URL? {
        let sessionsPath = workspaceRoot
            .appendingPathComponent("materialized/home/sessions", isDirectory: true)
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: sessionsPath, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return nil }
        var candidates: [(url: URL, modified: Date)] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent.hasPrefix("session.v"),
                  (url.pathExtension == "jsonl" || url.lastPathComponent.hasSuffix(".jsonl.zstd")),
                  url.deletingLastPathComponent().lastPathComponent == sessionID,
                  let values = try? url.resourceValues(
                    forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  values.isRegularFile == true else { continue }
            candidates.append((url, values.contentModificationDate ?? .distantPast))
        }
        return candidates.sorted { $0.modified > $1.modified }.first?.url
    }
}

/// One Bot-owned session log whose lines match an erasure request.
public struct BotSessionErasureTarget: Sendable, Equatable {
    public var sessionID: String
    public var seqs: [Int]
    public var records: [String]

    public init(sessionID: String, seqs: [Int], records: [String]) {
        self.sessionID = sessionID
        self.seqs = seqs
        self.records = records
    }
}

public struct BotSessionErasureScan: Sendable, Equatable {
    public var targets: [BotSessionErasureTarget]
    public var uncovered: [BotErasureEventData.UncoveredRecord]
    public var missingSessions: [String]

    public init(targets: [BotSessionErasureTarget],
                uncovered: [BotErasureEventData.UncoveredRecord] = [],
                missingSessions: [String] = []) {
        self.targets = targets
        self.uncovered = uncovered
        self.missingSessions = missingSessions
    }
}

/// Plans which Bot-owned session lines an erasure hits. The caller owns the
/// epoch switch; this type only reads materialized logs and builds the
/// tombstone replacement bytes the host applies.
public struct BotSessionErasurePlanner: Sendable {
    public let workspaceRoot: URL

    public init(workspaceRoot: URL) {
        self.workspaceRoot = workspaceRoot
    }

    public func scan(botID: String, ownedSessionIDs: Set<String>,
                     needles: [String], records: [String]) -> BotSessionErasureScan {
        var refsBySession: [String: Set<Int>] = [:]
        var invalid: [BotErasureEventData.UncoveredRecord] = []
        for raw in records {
            guard let reference = BotRecordReference.parse(raw) else { continue }
            switch reference {
            case let .session(sessionID, seq):
                refsBySession[sessionID, default: []].insert(seq)
            case .event:
                continue
            }
        }
        var targets: [BotSessionErasureTarget] = []
        var uncovered: [BotErasureEventData.UncoveredRecord] = []
        var missing: [String] = []
        let foreign = refsBySession.keys.filter { !ownedSessionIDs.contains($0) }
        for sessionID in foreign {
            for seq in refsBySession[sessionID, default: []].sorted() {
                invalid.append(.init(
                    record: "record://session/\(sessionID)#\(seq)",
                    reason: "session-log-session-not-closed"))
            }
            refsBySession.removeValue(forKey: sessionID)
        }
        for sessionID in ownedSessionIDs.sorted() {
            guard let url = BotSessionLogReader.locate(
                sessionID: sessionID, workspaceRoot: workspaceRoot),
                  url.lastPathComponent.hasSuffix(".jsonl"),
                  let data = try? Data(contentsOf: url) else {
                if refsBySession[sessionID] != nil { missing.append(sessionID) }
                continue
            }
            let lines = BotSessionLogReader.lines(from: data)
            var seqs = refsBySession[sessionID] ?? []
            for line in lines where !line.erased {
                if needles.contains(where: { line.allText.contains($0) }) {
                    seqs.insert(line.seq)
                }
            }
            // DSH copies one user-role message into the inbox as
            // `agent/inbox/spliced` before it becomes the canonical
            // `user/message` line. Tombstoning only the canonical record leaves
            // the same original text in the splice line (F4). A splice line is
            // an erased line when any inserted message is the same message as
            // one already selected here (same DSH message id / source rpcId, or
            // the exact same text with its producer kind).
            if !seqs.isEmpty {
                var erased = seqs
                var changed = true
                while changed {
                    changed = false
                    let fingerprints = messageFingerprints(
                        of: lines.filter { erased.contains($0.seq) })
                    for line in lines where !line.erased && !erased.contains(line.seq)
                        && line.type == "agent/inbox/spliced" {
                        guard !spliceFingerprints(line).isDisjoint(with: fingerprints) else {
                            continue
                        }
                        erased.insert(line.seq)
                        changed = true
                    }
                }
                seqs = erased
            }
            guard !seqs.isEmpty else { continue }
            targets.append(BotSessionErasureTarget(
                sessionID: sessionID,
                seqs: seqs.sorted(),
                records: seqs.sorted().map { "record://session/\(sessionID)#\($0)" }))
        }
        uncovered.append(contentsOf: invalid)
        for sessionID in missing {
            let refs = refsBySession[sessionID] ?? []
            for seq in refs.sorted() {
                uncovered.append(.init(
                    record: "record://session/\(sessionID)#\(seq)",
                    reason: "session-log-session-not-closed"))
            }
        }
        return BotSessionErasureScan(
            targets: targets, uncovered: uncovered,
            missingSessions: missing.sorted())
    }

    /// Tombstone bytes for one target session. The caller supplies them to the
    /// host rewrite; the host verifies each line's seq but never invents the
    /// tombstone shape itself.
    public func tombstoneLines(sessionID: String, erasedSeqs: Set<Int>,
                               erasureID: String) -> [(seq: Int, time: Int64, data: Data)] {
        guard let url = BotSessionLogReader.locate(
            sessionID: sessionID, workspaceRoot: workspaceRoot),
              let data = try? Data(contentsOf: url) else { return [] }
        var result: [(Int, Int64, Data)] = []
        for line in BotSessionLogReader.lines(from: data) where erasedSeqs.contains(line.seq) {
            guard let replacement = try? BotSessionErasureTombstone.line(
                sessionID: sessionID, seq: line.seq, time: line.time,
                erasureID: erasureID) else { continue }
            result.append((line.seq, line.time, replacement))
        }
        return result.sorted { $0.0 < $1.0 }
    }

    /// Builds the one-shot seam the new epoch receives before its first user
    /// message. Erased/tombstoned lines are skipped; only unerased user and
    /// assistant text is retained, bounded from the tail.
    public func continuation(sessionID: String, erasedSeqs: Set<Int>,
                             limit: Int = 12_000) -> String? {
        guard let url = BotSessionLogReader.locate(
            sessionID: sessionID, workspaceRoot: workspaceRoot),
              let data = try? Data(contentsOf: url) else { return nil }
        var parts: [String] = []
        for line in BotSessionLogReader.lines(from: data) {
            guard !line.erased, !erasedSeqs.contains(line.seq) else { continue }
            guard line.type == "user/message" || line.type == "assistant/message",
                  let object = try? JSONSerialization.jsonObject(
                    with: Data(line.raw.utf8)) as? [String: Any],
                  let text = messageText(object["data"]),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let escaped = text
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            parts.append((line.type == "user/message" ? "User: " : "Assistant: ") + escaped)
        }
        guard !parts.isEmpty else { return nil }
        var joined = parts.joined(separator: "\n")
        if joined.count > limit { joined = String(joined.suffix(limit)) }
        return BotSessionErasureTombstone.marker
            + "\nThe previous conversation continues below. Lines the user erased are omitted.\n"
            + joined
            + "\n</session_continuation>"
    }

    /// Every fingerprint carried by a line selected for erasure. The tokens are
    /// intentionally narrow: a DSH message id, the producer's rpcId, or the
    /// exact visible text together with the producer kind. Short text is never
    /// a fingerprint on its own.
    private func messageFingerprints(of lines: [BotSessionLogLine]) -> Set<String> {
        var result = Set<String>()
        for line in lines {
            guard let object = jsonObject(line) else { continue }
            if line.type == "user/message" || line.type == "assistant/message" {
                let data = object["data"] as? [String: Any]
                let message = data?["message"] as? [String: Any] ?? data
                result.formUnion(fingerprints(message: message))
            } else if line.type == "agent/inbox/spliced" {
                result.formUnion(spliceFingerprints(line))
            }
        }
        return result
    }

    private func spliceFingerprints(_ line: BotSessionLogLine) -> Set<String> {
        guard let object = jsonObject(line),
              let data = object["data"] as? [String: Any],
              let inserted = data["inserted"] as? [[String: Any]] else { return [] }
        var result = Set<String>()
        for message in inserted {
            result.formUnion(fingerprints(message: message))
        }
        return result
    }

    private func fingerprints(message: [String: Any]?) -> Set<String> {
        guard let message else { return [] }
        var result = Set<String>()
        if let id = message["id"] as? String, !id.isEmpty {
            result.insert("id:\(id)")
        }
        let source = message["source"] as? [String: Any]
        if let rpcId = source?["rpcId"] as? String, !rpcId.isEmpty {
            result.insert("rpc:\(rpcId)")
        }
        if let text = messageText(message)?.trimmingCharacters(in: .whitespacesAndNewlines),
           text.unicodeScalars.count >= 8 {
            let kind = source?["kind"] as? String ?? "unknown"
            result.insert("text:\(kind):\(text)")
        }
        return result
    }

    private func jsonObject(_ line: BotSessionLogLine) -> [String: Any]? {
        guard let value = try? JSONSerialization.jsonObject(with: Data(line.raw.utf8)) else {
            return nil
        }
        return value as? [String: Any]
    }

    private func messageText(_ value: Any?) -> String? {
        guard let object = value as? [String: Any] else { return nil }
        let message = object["message"] as? [String: Any] ?? object
        guard let content = message["content"] as? [Any] else { return nil }
        var texts: [String] = []
        for block in content {
            guard let block = block as? [String: Any],
                  block["type"] as? String == "text",
                  let text = block["text"] as? String else { continue }
            texts.append(text)
        }
        return texts.joined(separator: "\n")
    }
}

/// Strips the one-shot continuation block from a projected user row. The block
/// is model-visible context, not a user bubble.
public enum BotSessionContinuation {
    public static func strip(_ text: String) -> String {
        let marker = BotSessionErasureTombstone.marker
        guard text.hasPrefix(marker) else { return text }
        guard let close = text.range(of: "</session_continuation>") else { return "" }
        return String(text[close.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
