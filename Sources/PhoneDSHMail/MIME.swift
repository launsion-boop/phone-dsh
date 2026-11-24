// SPDX-License-Identifier: MIT
// Minimal RFC 5322 / MIME reading and writing for the mail connectors.
// Reading covers what Chinese and international providers actually send:
// folded headers, RFC 2047 encoded words (B/Q) in UTF-8, GBK/GB2312/GB18030
// and Big5, multipart trees, base64 and quoted-printable bodies. Writing only
// produces UTF-8 text/plain messages.

import Foundation

public struct MIMEHeaders: Sendable, Equatable {
    /// Lower-cased name → decoded values, in order.
    public private(set) var fields: [(name: String, value: String)] = []

    public static func == (lhs: MIMEHeaders, rhs: MIMEHeaders) -> Bool {
        lhs.fields.map(\.name) == rhs.fields.map(\.name) && lhs.fields.map(\.value) == rhs.fields.map(\.value)
    }

    public init() {}

    /// Parse a raw header block (bytes before the first empty line).
    public init(raw: Data) {
        let text = MIME.decodeLatin1(raw)
        var current: (String, String)?
        for line in text.components(separatedBy: "\n") {
            let line = line.hasSuffix("\r") ? String(line.dropLast()) : line
            if line.isEmpty { continue }
            if line.first == " " || line.first == "\t" {
                if current != nil { current!.1 += " " + line.trimmingCharacters(in: .whitespaces) }
                continue
            }
            if let current { fields.append((current.0, current.1)) }
            guard let colon = line.firstIndex(of: ":") else { current = nil; continue }
            current = (line[..<colon].lowercased().trimmingCharacters(in: .whitespaces),
                       String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
        }
        if let current { fields.append((current.0, current.1)) }
    }

    /// The first raw value (RFC 2047 still encoded).
    public func raw(_ name: String) -> String? {
        fields.first { $0.name == name.lowercased() }?.value
    }

    /// The first value with encoded words decoded.
    public subscript(_ name: String) -> String? {
        raw(name).map(MIME.decodeEncodedWords)
    }
}

public struct MIMEAttachment: Sendable, Equatable {
    public var filename: String
    public var contentType: String
    public var size: Int
}

/// The readable parts of one message.
public struct MIMEMessage: Sendable, Equatable {
    public var headers: MIMEHeaders
    public var text: String
    public var isHTMLFallback: Bool
    public var attachments: [MIMEAttachment]
}

public enum MIME {
    // MARK: Reading

    public static func parse(_ data: Data) -> MIMEMessage {
        let (headerData, body) = splitHeaderBody(data)
        let headers = MIMEHeaders(raw: headerData)
        var plain: String?
        var html: String?
        var attachments: [MIMEAttachment] = []
        walk(headers: headers, body: body, plain: &plain, html: &html, attachments: &attachments, depth: 0)
        if let plain, !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return MIMEMessage(headers: headers, text: plain, isHTMLFallback: false, attachments: attachments)
        }
        return MIMEMessage(headers: headers, text: html.map(htmlToText) ?? (plain ?? ""),
                           isHTMLFallback: html != nil, attachments: attachments)
    }

    private static func walk(headers: MIMEHeaders, body: Data,
                             plain: inout String?, html: inout String?,
                             attachments: inout [MIMEAttachment], depth: Int) {
        guard depth < 12 else { return }
        let (type, params) = contentType(headers.raw("content-type") ?? "text/plain")
        let disposition = headers.raw("content-disposition")
        let filename = dispositionFilename(disposition) ?? params["name"].map(decodeEncodedWords)
        if type.hasPrefix("multipart/"), let boundary = params["boundary"] {
            for part in splitMultipart(body, boundary: boundary) {
                let (partHeaderData, partBody) = splitHeaderBody(part)
                walk(headers: MIMEHeaders(raw: partHeaderData), body: partBody,
                     plain: &plain, html: &html, attachments: &attachments, depth: depth + 1)
            }
            return
        }
        if type == "message/rfc822" {
            let (innerHeaders, innerBody) = splitHeaderBody(body)
            walk(headers: MIMEHeaders(raw: innerHeaders), body: innerBody,
                 plain: &plain, html: &html, attachments: &attachments, depth: depth + 1)
            return
        }
        let decoded = decodeTransfer(body, encoding: headers.raw("content-transfer-encoding"))
        let isAttachment = (disposition?.lowercased().hasPrefix("attachment") ?? false)
            || (filename != nil && !type.hasPrefix("text/"))
        if isAttachment {
            attachments.append(MIMEAttachment(filename: filename ?? "attachment", contentType: type, size: decoded.count))
            return
        }
        if type == "text/plain", plain == nil {
            plain = decodeText(decoded, charset: params["charset"])
        } else if type == "text/html", html == nil {
            html = decodeText(decoded, charset: params["charset"])
        } else if !type.hasPrefix("text/") {
            attachments.append(MIMEAttachment(filename: filename ?? "part", contentType: type, size: decoded.count))
        }
    }

    static func splitHeaderBody(_ data: Data) -> (Data, Data) {
        let bytes = [UInt8](data)
        var index = 0
        while index < bytes.count {
            if bytes[index] == 0x0A {
                if index + 1 < bytes.count, bytes[index + 1] == 0x0A {
                    return (Data(bytes[..<index]), Data(bytes[(index + 2)...]))
                }
                if index + 2 < bytes.count, bytes[index + 1] == 0x0D, bytes[index + 2] == 0x0A {
                    return (Data(bytes[..<index]), Data(bytes[(index + 3)...]))
                }
            }
            index += 1
        }
        return (data, Data())
    }

    static func splitMultipart(_ body: Data, boundary: String) -> [Data] {
        let text = decodeLatin1(body)
        let delimiter = "--" + boundary
        var parts: [Data] = []
        var segments = text.components(separatedBy: delimiter)
        guard segments.count > 1 else { return [] }
        segments.removeFirst() // preamble
        for segment in segments {
            if segment.hasPrefix("--") { break } // closing delimiter
            var part = segment
            // "\r\n" is one Character (grapheme), so one removal drops the whole line break.
            if part.hasPrefix("\r\n") || part.hasPrefix("\n") { part.removeFirst() }
            if part.hasSuffix("\r\n") || part.hasSuffix("\n") { part.removeLast() }
            parts.append(encodeLatin1(part))
        }
        return parts
    }

    /// `type/subtype` lower-cased plus parameters (names lower-cased, quotes removed).
    public static func contentType(_ value: String) -> (String, [String: String]) {
        let pieces = splitParameters(value)
        let type = (pieces.first ?? "text/plain").lowercased().trimmingCharacters(in: .whitespaces)
        var params: [String: String] = [:]
        for piece in pieces.dropFirst() {
            guard let equals = piece.firstIndex(of: "=") else { continue }
            var name = piece[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            var value = piece[piece.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = String(value.dropFirst().dropLast()) }
            if name.hasSuffix("*") { // RFC 2231 charset'lang'value
                name.removeLast()
                let parts = value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
                if parts.count == 3 {
                    let bytes = percentDecode(String(parts[2]))
                    value = decodeText(bytes, charset: String(parts[0]))
                }
            }
            if params[name] == nil { params[name] = value }
        }
        return (type, params)
    }

    private static func dispositionFilename(_ value: String?) -> String? {
        guard let value else { return nil }
        let (_, params) = contentType(value)
        return params["filename"].map(decodeEncodedWords)
    }

    private static func splitParameters(_ value: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quoted = false
        for character in value {
            if character == "\"" { quoted.toggle() }
            if character == ";", !quoted { result.append(current); current = ""; continue }
            current.append(character)
        }
        result.append(current)
        return result.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    public static func decodeTransfer(_ data: Data, encoding: String?) -> Data {
        switch encoding?.lowercased().trimmingCharacters(in: .whitespaces) {
        case "base64":
            let cleaned = decodeLatin1(data).filter { !$0.isWhitespace }
            return Data(base64Encoded: cleaned, options: .ignoreUnknownCharacters) ?? Data()
        case "quoted-printable":
            return quotedPrintable(data, underscoreIsSpace: false)
        default:
            return data
        }
    }

    static func quotedPrintable(_ data: Data, underscoreIsSpace: Bool) -> Data {
        let bytes = [UInt8](data)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "=") {
                if index + 1 < bytes.count, bytes[index + 1] == 0x0A { index += 2; continue }
                if index + 2 < bytes.count, bytes[index + 1] == 0x0D, bytes[index + 2] == 0x0A { index += 3; continue }
                if index + 2 < bytes.count, let value = UInt8(String(bytes: bytes[(index + 1)...(index + 2)], encoding: .ascii) ?? "", radix: 16) {
                    out.append(value); index += 3; continue
                }
            }
            out.append(underscoreIsSpace && byte == UInt8(ascii: "_") ? 0x20 : byte)
            index += 1
        }
        return Data(out)
    }

    /// Decode bytes in a declared charset, falling back to UTF-8 then GB18030.
    public static func decodeText(_ data: Data, charset: String?) -> String {
        if let charset, let encoding = encoding(forCharset: charset), let text = String(data: data, encoding: encoding) {
            return text
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: gb18030) { return text }
        return decodeLatin1(data)
    }

    static let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))

    static func encoding(forCharset raw: String) -> String.Encoding? {
        let name = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        switch name {
        case "utf-8", "utf8": return .utf8
        // GBK and GB2312 are subsets of GB18030; senders mislabel them often.
        case "gb2312", "gbk", "gb18030", "x-gbk", "cp936": return gb18030
        case "us-ascii", "ascii": return .utf8
        default:
            let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            guard cf != kCFStringEncodingInvalidId else { return nil }
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
        }
    }

    /// RFC 2047 encoded words; whitespace between adjacent encoded words is dropped.
    public static func decodeEncodedWords(_ value: String) -> String {
        let pattern = #"=\?([^?]+)\?([bBqQ])\?([^?]*)\?="#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
        let ns = value as NSString
        let matches = regex.matches(in: value, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return value }
        var result = ""
        var cursor = 0
        for match in matches {
            let gap = ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            if cursor == 0 || !gap.allSatisfy(\.isWhitespace) { result += gap }
            let charset = ns.substring(with: match.range(at: 1)).split(separator: "*").first.map(String.init) ?? "utf-8"
            let kind = ns.substring(with: match.range(at: 2)).uppercased()
            let payload = ns.substring(with: match.range(at: 3))
            let bytes: Data = kind == "B"
                ? (Data(base64Encoded: payload, options: .ignoreUnknownCharacters) ?? Data())
                : quotedPrintable(Data(payload.utf8), underscoreIsSpace: true)
            result += decodeText(bytes, charset: charset)
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }

    /// Readable text from HTML: drops head/script/style, keeps line breaks.
    public static func htmlToText(_ html: String) -> String {
        var text = html
        for pattern in [#"(?is)<(script|style|head)[^>]*>.*?</\1>"#, #"(?s)<!--.*?-->"#] {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: #"(?i)<br\s*/?>|</p>|</div>|</tr>|</li>|</h[1-6]>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&amp;": "&"]
        for (entity, replacement) in entities { text = text.replacingOccurrences(of: entity, with: replacement) }
        text = text.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\n\s*\n\s*\n+"#, with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func percentDecode(_ value: String) -> Data {
        var out: [UInt8] = []
        var index = value.startIndex
        while index < value.endIndex {
            let character = value[index]
            if character == "%", let end = value.index(index, offsetBy: 3, limitedBy: value.endIndex),
               let byte = UInt8(value[value.index(after: index)..<end], radix: 16) {
                out.append(byte); index = end; continue
            }
            out.append(contentsOf: Array(String(character).utf8))
            index = value.index(after: index)
        }
        return Data(out)
    }

    static func decodeLatin1(_ data: Data) -> String { String(String.UnicodeScalarView(data.map { Unicode.Scalar($0) })) }
    static func encodeLatin1(_ text: String) -> Data { Data(text.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) }) }

    // MARK: Writing

    /// One UTF-8 text/plain message. `bcc` is never written to the headers.
    public static func compose(from: String, to: [String], cc: [String], subject: String, body: String,
                               inReplyTo: String?, date: Date = Date(), messageID: String? = nil) -> Data {
        let domain = from.split(separator: "@").last.map(String.init) ?? "localhost"
        var lines: [String] = [
            "From: \(from)",
            "To: \(to.joined(separator: ", "))",
        ]
        if !cc.isEmpty { lines.append("Cc: \(cc.joined(separator: ", "))") }
        lines += [
            "Subject: \(encodeWord(subject))",
            "Date: \(rfc2822(date))",
            "Message-ID: \(messageID ?? "<\(UUID().uuidString.lowercased())@\(domain)>")",
        ]
        if let inReplyTo, !inReplyTo.isEmpty {
            lines.append("In-Reply-To: \(inReplyTo)")
            lines.append("References: \(inReplyTo)")
        }
        lines += [
            "MIME-Version: 1.0",
            "Content-Type: text/plain; charset=UTF-8",
            "Content-Transfer-Encoding: base64",
            "",
        ]
        let encodedBody = Data(body.utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        return Data((lines.joined(separator: "\r\n") + "\r\n" + encodedBody + "\r\n").utf8)
    }

    /// RFC 2047 B-encoding when the value is not plain printable ASCII.
    public static func encodeWord(_ value: String) -> String {
        if value.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7F }) { return value }
        // Encoded words are at most 75 chars; split on character boundaries.
        var words: [String] = []
        var chunk = ""
        for character in value {
            let candidate = chunk + String(character)
            if Data(candidate.utf8).count > 45 { words.append(chunk); chunk = String(character) } else { chunk = candidate }
        }
        if !chunk.isEmpty { words.append(chunk) }
        return words.map { "=?UTF-8?B?\(Data($0.utf8).base64EncodedString())?=" }.joined(separator: "\r\n ")
    }

    static func rfc2822(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.string(from: date)
    }

    /// Bare addresses from a header value such as `"张三" <a@b.com>, c@d.com`.
    public static func addresses(_ value: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#)
        let ns = value as NSString
        return regex.matches(in: value, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }
}
