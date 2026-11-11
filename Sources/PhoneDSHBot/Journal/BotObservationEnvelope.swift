// SPDX-License-Identifier: MIT

import Foundation

/// The decoded header and body of one system-generated observation envelope.
///
/// The model-visible encoding is fixed by `spec/bot/v1/README.md` §4.3:
/// one attribute line in the order source/origin/at/owner/ref, one body line
/// block and one closing line. The Worker produces it at `tools/post-execute`;
/// the host never treats the same text written by a model as an envelope.
public struct BotObservationEnvelope: Sendable, Equatable {
    public static let sources: Set<String> = [
        "tool", "connector", "device", "device-task", "web", "subagent", "agent", "attachment",
    ]
    public static let attributes = ["source", "origin", "at", "owner", "ref"]

    public var source: String
    public var origin: String
    public var at: String
    public var owner: String
    public var ref: String
    public var text: String

    public init(source: String, origin: String, at: String, owner: String,
                ref: String, text: String) {
        self.source = source
        self.origin = origin
        self.at = at
        self.owner = owner
        self.ref = ref
        self.text = text
    }

    public init?(source: String, origin: String, at: String, owner: String,
                 reference: BotRecordReference, text: String) {
        self.init(validatedSource: source, origin: origin, at: at, owner: owner,
                  ref: reference.canonical, text: text)
    }

    /// Validates every header member, including a canonical reference string.
    public init?(validatedSource source: String, origin: String, at: String, owner: String,
                 ref: String, text: String) {
        guard Self.sources.contains(source), !origin.isEmpty, !owner.isEmpty,
              Self.isUTCInstant(at), origin.unicodeScalars.count <= 512,
              owner.unicodeScalars.count <= 200,
              BotRecordReference.parse(ref) != nil else { return nil }
        self.init(source: source, origin: origin, at: at, owner: owner,
                  ref: BotRecordReference.parse(ref)!.canonical, text: text)
    }

    /// Encodes the envelope exactly as the shared golden expects.
    public func encoded() -> String {
        let attributes = Self.attributes.map { name -> String in
            let value: String
            switch name {
            case "source": value = source
            case "origin": value = origin
            case "at": value = at
            case "owner": value = owner
            default: value = ref
            }
            return "\(name)=\"\(Self.escapeAttribute(value))\""
        }.joined(separator: " ")
        return "<observation \(attributes)>\n\(Self.escapeBody(text))\n</observation>"
    }

    /// Decodes one complete envelope; any malformed or non-canonical header,
    /// unknown source, bad time or bad reference returns nil.
    public static func decode(_ encoded: String) -> BotObservationEnvelope? {
        let open = "<observation "
        let close = "\n</observation>"
        guard encoded.hasPrefix(open), encoded.hasSuffix(close) else { return nil }
        let bodyStart = encoded.index(encoded.startIndex, offsetBy: open.count)
        guard let headerEnd = encoded[bodyStart...].firstIndex(of: "\n") else { return nil }
        var header = String(encoded[bodyStart..<headerEnd])
        guard header.hasSuffix(">") else { return nil }
        header.removeLast()
        let bodyStartIndex = encoded.index(after: headerEnd)
        let bodyEnd = encoded.index(encoded.endIndex, offsetBy: -close.count)
        guard bodyStartIndex <= bodyEnd else { return nil }
        let body = String(encoded[bodyStartIndex..<bodyEnd])
        let fields = parseAttributes(header)
        guard fields.count == attributes.count,
              fields.map(\.0) == attributes else { return nil }
        let values = Dictionary(uniqueKeysWithValues: fields)
        guard let source = values["source"], sources.contains(source),
              let origin = values["origin"], !origin.isEmpty,
              let at = values["at"], isUTCInstant(at),
              let owner = values["owner"], !owner.isEmpty,
              let ref = values["ref"],
              BotRecordReference.parse(ref) != nil else { return nil }
        return BotObservationEnvelope(
            source: source, origin: origin, at: at, owner: owner, ref: ref,
            text: unescapeBody(body))
    }

    public static func escapeBody(_ text: String) -> String {
        // Escape only a marker-looking `<`, leaving ordinary angle brackets
        // and `&` in the body alone.
        let pattern = #"(?i)<(\s*/?\s*observation)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.stringByReplacingMatches(in: text, range: range,
                                               withTemplate: "\\\\u003c$1")
    }

    public static func unescapeBody(_ text: String) -> String {
        let pattern = #"(?i)\\u003c(\s*/?\s*observation)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "<$1")
    }

    private static func parseAttributes(_ header: String) -> [(String, String)] {
        var result: [(String, String)] = []
        var cursor = header.startIndex
        while cursor < header.endIndex {
            guard let equals = header[cursor...].firstIndex(of: "=") else { return [] }
            let name = String(header[cursor..<equals])
            guard !name.isEmpty, name.allSatisfy({ $0.isASCII && $0.isLetter }),
                  equals < header.endIndex else { return [] }
            let quoteIndex = header.index(after: equals)
            guard quoteIndex < header.endIndex, header[quoteIndex] == "\"" else { return [] }
            guard let endQuote = header[header.index(after: quoteIndex)...].firstIndex(of: "\"") else {
                return []
            }
            let value = String(header[header.index(after: quoteIndex)..<endQuote])
            result.append((name, unescapeAttribute(value)))
            let after = header.index(after: endQuote)
            if after == header.endIndex { break }
            guard header[after] == " " else { return [] }
            cursor = header.index(after: after)
        }
        return result
    }

    public static func escapeAttribute(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.utf8.count)
        for scalar in value.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "\"": result += "&quot;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            default:
                if scalar.properties.generalCategory == .control {
                    result += String(format: "\\u%04x", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result
    }

    public static func unescapeAttribute(_ value: String) -> String {
        var result = value.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
        let pattern = #"\\u([0-9a-fA-F]{4})"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: (result as NSString).length))
            for match in matches.reversed() {
                let text = result as NSString
                guard let scalarValue = UInt32(text.substring(with: match.range(at: 1)), radix: 16),
                      let scalar = Unicode.Scalar(scalarValue) else { continue }
                result = (result as NSString).replacingCharacters(
                    in: match.range, with: String(Character(scalar)))
            }
        }
        return result
    }

    static func isUTCInstant(_ value: String) -> Bool {
        let pattern = #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z$"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }
}
