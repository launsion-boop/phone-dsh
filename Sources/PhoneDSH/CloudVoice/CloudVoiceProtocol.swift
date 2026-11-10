// SPDX-License-Identifier: MIT
// phone-dsh — cloud speech for the TonoLink voice turn (spec/v1/cloud-voice.md;
// cases golden/cloud-voice/cases.json). Consumer subset of the cloud's
// pdsh-asr.v1 and /v1/tts/speech (TonoTeam/phone-dsh-cloud@64a3d2098ca2).

import Foundation

public enum CloudVoice {
    public static let asrURL = URL(string: "wss://pdsh.tonoai.cn/v1/asr/stream")!
    public static let asrSubprotocol = "pdsh-asr.v1"
    public static let ttsURL = URL(string: "https://pdsh.tonoai.cn/v1/tts/speech")!
    public static let ttsVoice = "zh-female-vv"
    public static let ttsSampleRate = 16_000
    public static let ttsInputMaxScalars = 1000
    public static let preStartQueueMax = 100
    public static let connectTimeoutMs = 10_000
    public static let startedTimeoutMs = 5000
    public static let finishTimeoutDefaultMs = 15_000
    public static let finishGraceMs = 5000

    /// The `start` message (§2): interactive Chinese, raw 20 ms Opus, one utterance.
    public static func startMessage(turnID: UInt32) -> Data {
        let object: [String: Any] = [
            "type": "start", "mode": "interactive", "language": "zh",
            "format": ["codec": "opus", "sample_rate": 16_000, "channels": 1, "frame_ms": 20],
            "single_utterance": true, "hotwords": ["小智", "托诺"], "client_ref": "tonolink-\(turnID)",
        ]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    public static let finishMessage = Data(#"{"type":"finish"}"#.utf8)
    public static let cancelMessage = Data(#"{"type":"cancel"}"#.utf8)

    /// TTS request body (§3).
    public static func speechRequest(_ text: String) -> Data {
        let object: [String: Any] = ["input": text, "voice": ttsVoice, "response_format": "pcm"]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }
}

/// One server text message, classified (§2).
public enum CloudASRMessage: Equatable, Sendable {
    case started(finishTimeoutMs: Int)
    case partial(text: String)
    case final(segmentID: Int, text: String)
    case completed(endReason: String)
    case cancelled
    case error(code: String)
    /// A known non-terminal the phone does not use, or an unknown non-terminal type.
    case ignored
    /// Not JSON, no type, or a known type with a missing or mistyped member.
    case invalid

    public var isTerminal: Bool {
        switch self {
        case .completed, .cancelled, .error, .invalid: return true
        default: return false
        }
    }

    public static func decode(_ text: String) -> CloudASRMessage {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return .invalid }
        switch type {
        case "started":
            guard object["session_id"] is String else { return .invalid }
            let limits = object["limits"] as? [String: Any]
            let timeout = (limits?["finish_timeout_ms"] as? NSNumber).flatMap { $0.intValue > 0 ? $0.intValue : nil }
            return .started(finishTimeoutMs: timeout ?? CloudVoice.finishTimeoutDefaultMs)
        case "partial":
            guard let text = object["text"] as? String else { return .invalid }
            return .partial(text: text)
        case "final":
            guard let text = object["text"] as? String, let segment = integer(object["segment_id"]) else { return .invalid }
            return .final(segmentID: segment, text: text)
        case "completed":
            guard let reason = object["end_reason"] as? String, object["final"] as? Bool == true else { return .invalid }
            return .completed(endReason: reason)
        case "cancelled":
            return .cancelled
        case "error":
            guard let code = object["code"] as? String else { return .invalid }
            return .error(code: code)
        default:
            return .ignored
        }
    }

    /// A JSON integer (not a string, bool or fraction).
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue == Double(number.intValue) else { return nil }
        return number.intValue
    }
}

/// Collects one session's finals; yields text only after `completed` (§2).
public struct CloudASRTranscript: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case pending
        case text(String)
        /// `no_speech`, or nothing recognisable: end the turn silently.
        case silent
        case failed(String)
    }

    private var finals: [Int: String] = [:]
    public private(set) var outcome: Outcome = .pending

    public init() {}

    public mutating func apply(_ message: CloudASRMessage) {
        guard outcome == .pending else { return }
        switch message {
        case .final(let segment, let text):
            if finals[segment] == nil { finals[segment] = text }
        case .completed(let reason):
            let text = finals.keys.sorted().compactMap { finals[$0] }.joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            outcome = (reason == "no_speech" || text.isEmpty) ? .silent : .text(text)
        case .cancelled: outcome = .failed("cancelled")
        case .error(let code): outcome = .failed(code)
        case .invalid: outcome = .failed("invalid server message")
        case .started, .partial, .ignored: break
        }
    }

    /// Ended on the phone (cancel, missed deadline): no text is used.
    public mutating func fail(_ reason: String) {
        if outcome == .pending { outcome = .failed(reason) }
    }

    /// The connection closed without a terminal message: incomplete, never used.
    public mutating func closed() {
        if outcome == .pending { outcome = .failed("closed without a result") }
    }
}

/// Reply text → what TTS reads (§3).
public enum CloudVoiceSpeech {
    public static func speakable(_ text: String) -> String {
        var lines: [String] = []
        var inFence = false
        for raw in text.components(separatedBy: .newlines) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { inFence.toggle(); continue }
            if inFence { continue }
            var line = trimmed
            while line.hasPrefix("#") { line.removeFirst() }
            for bullet in ["- ", "* ", "+ ", "> "] where line.hasPrefix(bullet) { line.removeFirst(bullet.count) }
            lines.append(line)
        }
        var out = lines.joined(separator: " ")
        // [label](target) → label
        if let links = try? NSRegularExpression(pattern: #"\[([^\]]*)\]\([^)]*\)"#) {
            out = links.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "$1")
        }
        for mark in ["**", "__", "`"] { out = out.replacingOccurrences(of: mark, with: "") }
        let words = out.split(whereSeparator: { $0.isWhitespace })
        return words.joined(separator: " ")
    }

    /// Splits at the last sentence end within `max` scalars, else cuts at `max` (§3).
    public static func chunks(_ text: String, max: Int = CloudVoice.ttsInputMaxScalars) -> [String] {
        let enders: Set<Unicode.Scalar> = ["。", "！", "？", "；", ".", "!", "?", ";", "\n"]
        var scalars = Array(text.unicodeScalars)
        var result: [String] = []
        while !scalars.isEmpty {
            if scalars.count <= max { result.append(String(String.UnicodeScalarView(scalars))); break }
            var cut = max
            if let end = scalars[..<max].lastIndex(where: { enders.contains($0) }) { cut = end + 1 }
            result.append(String(String.UnicodeScalarView(scalars[..<cut])))
            scalars.removeFirst(cut)
        }
        return result.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

/// Which credential a voice turn uses (§1). Pure, so the shared cases judge it.
public enum CloudVoiceCredential {
    public enum Account: Equatable, Sendable {
        case signedOut
        case token(String)
        /// Signed in but no token could be obtained: fail closed.
        case unavailable
    }

    public static func resolve(account: Account, profileBaseURL: String?, profileKey: String?) -> String? {
        switch account {
        case .token(let token): return token.isEmpty ? nil : token
        case .unavailable: return nil
        case .signedOut:
            guard let profileBaseURL, isCloudOrigin(profileBaseURL),
                  let key = profileKey, !key.isEmpty else { return nil }
            return key
        }
    }

    public static func isCloudOrigin(_ raw: String) -> Bool {
        guard let components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "pdsh.tonoai.cn",
              components.user == nil, components.password == nil else { return false }
        return components.port == nil || components.port == 443
    }
}

public struct CloudVoiceError: LocalizedError, Equatable, Sendable {
    public var status: Int?
    public var code: String?
    public var message: String

    public init(status: Int? = nil, code: String? = nil, _ message: String) {
        self.status = status; self.code = code; self.message = message
    }

    public var errorDescription: String? { message }

    /// The tono-account §5 rule: only a user-token expiry is worth one re-send.
    public var isCredentialExpired: Bool { status == 401 }
}
