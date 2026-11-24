// SPDX-License-Identifier: MIT
// Minimal IMAP4rev1 client: LOGIN, ID, LIST, SELECT/EXAMINE, UID SEARCH,
// UID FETCH. Mailboxes are opened read-only (EXAMINE) and bodies are fetched
// with BODY.PEEK, so reading never changes a message's \Seen flag.

import Foundation

public struct MailSummary: Sendable, Equatable {
    public var uid: UInt32
    public var from: String
    public var to: String
    public var cc: String
    public var subject: String
    public var date: String
    public var messageID: String
    public var seen: Bool
    public var size: Int
}

public struct MailFolder: Sendable, Equatable {
    public var name: String
    public var flags: [String]
}

struct IMAPLine: Sendable {
    var text: String
    var literals: [Data]
}

actor IMAPSession {
    private let transport: any MailLineTransport
    private var counter = 0

    init(transport: any MailLineTransport) {
        self.transport = transport
    }

    func greeting() async throws {
        let line = try await readResponseLine()
        guard line.text.hasPrefix("* OK") || line.text.hasPrefix("* PREAUTH") else {
            throw MailError.protocolError(String(line.text.prefix(200)))
        }
    }

    func login(user: String, password: String) async throws {
        do {
            _ = try await command("LOGIN \(Self.quote(user)) \(Self.quote(password))")
        } catch MailError.protocolError(let detail) {
            throw MailError.authenticationFailed(detail)
        }
    }

    /// RFC 2971 ID. NetEase (163/126/yeah) refuses SELECT with "Unsafe Login"
    /// until the client identifies itself; other servers may ignore or reject it.
    func identify() async {
        _ = try? await command(#"ID ("name" "PhoneDSH" "version" "1.0" "vendor" "PhoneDSH")"#)
    }

    func listFolders() async throws -> [MailFolder] {
        let lines = try await command(#"LIST "" "*""#)
        return lines.compactMap { line -> MailFolder? in
            guard line.text.hasPrefix("* LIST ") else { return nil }
            return Self.parseList(line)
        }
    }

    /// EXAMINE (read-only). Returns EXISTS.
    @discardableResult
    func examine(_ folder: String) async throws -> Int {
        let lines = try await command("EXAMINE \(Self.quote(ModifiedUTF7.encode(folder)))")
        for line in lines {
            let parts = line.text.split(separator: " ")
            if parts.count >= 3, parts[0] == "*", parts[2].uppercased() == "EXISTS", let count = Int(parts[1]) {
                return count
            }
        }
        return 0
    }

    func uidSearch(_ criteria: String) async throws -> [UInt32] {
        let lines = try await command("UID SEARCH \(criteria)")
        var uids: [UInt32] = []
        for line in lines where line.text.uppercased().hasPrefix("* SEARCH") {
            uids += line.text.split(separator: " ").dropFirst(2).compactMap { UInt32($0) }
        }
        return uids.sorted()
    }

    func fetchSummaries(_ uids: [UInt32]) async throws -> [MailSummary] {
        guard !uids.isEmpty else { return [] }
        let set = uids.map(String.init).joined(separator: ",")
        let lines = try await command(
            "UID FETCH \(set) (UID FLAGS RFC822.SIZE BODY.PEEK[HEADER.FIELDS (FROM TO CC SUBJECT DATE MESSAGE-ID)])")
        return lines.compactMap { line -> MailSummary? in
            guard line.text.uppercased().contains(" FETCH "), let uid = Self.number(after: "UID", in: line.text) else { return nil }
            let headers = MIMEHeaders(raw: line.literals.first ?? Data())
            return MailSummary(
                uid: UInt32(uid),
                from: headers["from"] ?? "",
                to: headers["to"] ?? "",
                cc: headers["cc"] ?? "",
                subject: headers["subject"] ?? "",
                date: headers["date"] ?? "",
                messageID: headers.raw("message-id") ?? "",
                seen: Self.flags(in: line.text).contains { $0.caseInsensitiveCompare("\\Seen") == .orderedSame },
                size: Self.number(after: "RFC822.SIZE", in: line.text) ?? 0)
        }
    }

    func fetchMessage(_ uid: UInt32, maxBytes: Int) async throws -> Data {
        guard let summary = try await fetchSummaries([uid]).first else { throw MailError.notFound }
        guard summary.size <= maxBytes else { throw MailError.messageTooLarge(summary.size) }
        let lines = try await command("UID FETCH \(uid) (UID BODY.PEEK[])")
        guard let data = lines.first(where: { $0.text.uppercased().contains(" FETCH ") && !$0.literals.isEmpty })?.literals.first else {
            throw MailError.notFound
        }
        return data
    }

    func logout() async {
        _ = try? await command("LOGOUT")
        await transport.close()
    }

    // MARK: Wire

    /// Send one tagged command and collect untagged lines until its completion.
    func command(_ text: String) async throws -> [IMAPLine] {
        counter += 1
        let tag = String(format: "A%03d", counter)
        try await transport.send(Data("\(tag) \(text)\r\n".utf8))
        var lines: [IMAPLine] = []
        while true {
            let line = try await readResponseLine()
            if line.text.hasPrefix(tag + " ") {
                let status = line.text.dropFirst(tag.count + 1)
                if status.uppercased().hasPrefix("OK") { return lines }
                throw MailError.protocolError(String(status.prefix(300)))
            }
            if line.text.hasPrefix("* BYE"), !text.hasPrefix("LOGOUT") {
                throw MailError.closed
            }
            lines.append(line)
        }
    }

    /// One response line with every `{n}` literal read inline.
    private func readResponseLine() async throws -> IMAPLine {
        var text = ""
        var literals: [Data] = []
        while true {
            let raw = try await transport.readLine()
            let piece = String(data: raw, encoding: .utf8) ?? MIME.decodeLatin1(raw)
            text += piece
            guard let size = Self.trailingLiteral(piece) else { return IMAPLine(text: text, literals: literals) }
            guard size <= 64 << 20 else { throw MailError.messageTooLarge(size) }
            literals.append(try await transport.read(count: size))
            text += " "
        }
    }

    // MARK: Parsing helpers

    static func trailingLiteral(_ line: String) -> Int? {
        guard line.hasSuffix("}"), let open = line.lastIndex(of: "{") else { return nil }
        return Int(line[line.index(after: open)..<line.index(before: line.endIndex)])
    }

    static func number(after keyword: String, in text: String) -> Int? {
        let pattern = "\(NSRegularExpression.escapedPattern(for: keyword)) (\\d+)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[range])
    }

    static func flags(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"FLAGS \(([^)]*)\)"#, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return [] }
        return text[range].split(separator: " ").map(String.init)
    }

    static func parseList(_ line: IMAPLine) -> MailFolder? {
        let text = line.text
        guard let open = text.firstIndex(of: "("), let close = text[open...].firstIndex(of: ")") else { return nil }
        let flags = text[text.index(after: open)..<close].split(separator: " ").map(String.init)
        var rest = text[text.index(after: close)...].trimmingCharacters(in: .whitespaces)
        // Skip the hierarchy delimiter: "/" or NIL.
        if rest.hasPrefix("\"") {
            if let end = rest.dropFirst().firstIndex(of: "\"") { rest = String(rest[rest.index(after: end)...]) }
        } else if rest.uppercased().hasPrefix("NIL") {
            rest = String(rest.dropFirst(3))
        }
        rest = rest.trimmingCharacters(in: .whitespaces)
        let rawName: String
        if let literal = line.literals.last, rest.isEmpty || rest.hasPrefix("{") {
            rawName = String(data: literal, encoding: .utf8) ?? ""
        } else if rest.hasPrefix("\""), rest.hasSuffix("\""), rest.count >= 2 {
            rawName = String(rest.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        } else {
            rawName = rest
        }
        guard !rawName.isEmpty else { return nil }
        return MailFolder(name: ModifiedUTF7.decode(rawName), flags: flags)
    }

    static func quote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// `01-Jan-2026` for SEARCH SINCE.
    static func searchDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "dd-MMM-yyyy"
        return formatter.string(from: date)
    }
}

/// RFC 3501 §5.1.3 modified UTF-7 for mailbox names (e.g. NetEase "已发送").
public enum ModifiedUTF7 {
    public static func encode(_ value: String) -> String {
        var out = ""
        var pending: [UInt16] = []
        func flush() {
            guard !pending.isEmpty else { return }
            let bytes = pending.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
            let b64 = Data(bytes).base64EncodedString()
                .replacingOccurrences(of: "/", with: ",")
                .replacingOccurrences(of: "=", with: "")
            out += "&" + b64 + "-"
            pending.removeAll()
        }
        for scalar in value.unicodeScalars {
            if scalar.value >= 0x20, scalar.value <= 0x7E {
                flush()
                out += scalar == "&" ? "&-" : String(scalar)
            } else {
                pending.append(contentsOf: Array(String(scalar).utf16))
            }
        }
        flush()
        return out
    }

    public static func decode(_ value: String) -> String {
        var out = ""
        var index = value.startIndex
        while index < value.endIndex {
            let character = value[index]
            guard character == "&", let end = value[index...].firstIndex(of: "-") else {
                out.append(character); index = value.index(after: index); continue
            }
            let payload = value[value.index(after: index)..<end]
            if payload.isEmpty {
                out += "&"
            } else {
                var b64 = payload.replacingOccurrences(of: ",", with: "/")
                while b64.count % 4 != 0 { b64 += "=" }
                if let data = Data(base64Encoded: b64) {
                    let units = stride(from: 0, to: data.count - 1, by: 2).map { UInt16(data[$0]) << 8 | UInt16(data[$0 + 1]) }
                    out += String(decoding: units, as: UTF16.self)
                }
            }
            index = value.index(after: end)
        }
        return out
    }
}
