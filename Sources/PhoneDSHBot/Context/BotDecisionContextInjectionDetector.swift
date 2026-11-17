// SPDX-License-Identifier: MIT

import Foundation

/// One real injected-material observation parsed from a DSH session
/// `user/message` runtime-context row. The plugin observer is deliberately not
/// a substitute: this value exists only when the host saw the row that the
/// model request carried.
public struct BotDecisionInjectedMaterial: Sendable, Equatable {
    public var blockID: String
    public var turnID: String?
    public var sessionID: String
    public var botID: String
    public var materialIDs: [String]
    public var observedAtMS: Int64

    public init(blockID: String, turnID: String?, sessionID: String,
                botID: String, materialIDs: [String], observedAtMS: Int64) {
        self.blockID = blockID
        self.turnID = turnID
        self.sessionID = sessionID
        self.botID = botID
        self.materialIDs = materialIDs
        self.observedAtMS = observedAtMS
    }
}

/// Detects the real runtime-context row produced by the Worker plugin.
///
/// The row is authoritative only when:
/// - `data.source.kind == "runtime-context"`;
/// - a named section `dshbot:decision-context` exists; and
/// - its text carries the `r<block_id>` marker with a valid `dm:` id.
///
/// The caller supplies the current turn/session/bot identity from the session
/// follow; this detector never reads the model-visible user prose.
public enum BotDecisionContextInjectionDetector {
    public static let sectionName = "dshbot:decision-context"

    public static func detect(eventData: BotJSONValue,
                              sessionID: String,
                              botID: String,
                              turnID: String?,
                              now: Int64 = Int64(Date().timeIntervalSince1970 * 1_000))
        -> BotDecisionInjectedMaterial? {
        guard let source = eventData["source"],
              source["kind"]?.stringValue == "runtime-context",
              let sections = source["sections"]?.arrayValue else { return nil }
        for section in sections {
            guard section["name"]?.stringValue == sectionName,
                  let text = section["text"]?.stringValue else { continue }
            guard let blockID = blockID(in: text) else { return nil }
            return BotDecisionInjectedMaterial(
                blockID: blockID,
                turnID: turnID,
                sessionID: sessionID,
                botID: botID,
                materialIDs: materialIDs(in: text),
                observedAtMS: now)
        }
        return nil
    }

    static func blockID(in text: String) -> String? {
        let pattern = #"dshbot:decision-context\s+r(dm:[A-Za-z0-9._:-]{1,128})"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    static func materialIDs(in text: String) -> [String] {
        let pattern = #"mat:[A-Za-z0-9._:-]{1,128}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var seen = Set<String>()
        var result: [String] = []
        for match in regex.matches(in: text, range: range) {
            guard let matchRange = Range(match.range, in: text) else { continue }
            let value = String(text[matchRange])
            if seen.insert(value).inserted { result.append(value) }
        }
        return result
    }
}
