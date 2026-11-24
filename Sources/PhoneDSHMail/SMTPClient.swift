// SPDX-License-Identifier: MIT
// Minimal SMTP submission over implicit TLS: EHLO, AUTH LOGIN, MAIL, RCPT, DATA.

import Foundation

actor SMTPSession {
    private let transport: any MailLineTransport

    init(transport: any MailLineTransport) {
        self.transport = transport
    }

    func greeting() async throws {
        let (code, text) = try await readReply()
        guard code == 220 else { throw MailError.protocolError("\(code) \(text)") }
    }

    func hello() async throws {
        try await expect("EHLO phonedsh.local", 250)
    }

    func login(user: String, password: String) async throws {
        do {
            try await expect("AUTH LOGIN", 334)
            try await expect(Data(user.utf8).base64EncodedString(), 334, redacted: true)
            try await expect(Data(password.utf8).base64EncodedString(), 235, redacted: true)
        } catch MailError.protocolError(let detail) {
            throw MailError.authenticationFailed(detail)
        }
    }

    func send(from: String, recipients: [String], message: Data) async throws {
        try await expect("MAIL FROM:<\(from)>", 250)
        for recipient in recipients {
            let (code, text) = try await exchange("RCPT TO:<\(recipient)>")
            guard code == 250 || code == 251 else {
                throw MailError.protocolError("收件人 \(recipient) 被拒绝：\(code) \(text)")
            }
        }
        try await expect("DATA", 354)
        try await transport.send(Self.dotStuffed(message) + Data("\r\n.\r\n".utf8))
        let (code, text) = try await readReply()
        guard code == 250 else { throw MailError.protocolError("\(code) \(text)") }
    }

    func quit() async {
        _ = try? await exchange("QUIT")
        await transport.close()
    }

    // MARK: Wire

    private func expect(_ line: String, _ code: Int, redacted: Bool = false) async throws {
        let (received, text) = try await exchange(line)
        guard received == code else {
            throw MailError.protocolError("\(received) \(text)\(redacted ? "" : " (\(line.prefix(40)))")")
        }
    }

    private func exchange(_ line: String) async throws -> (Int, String) {
        try await transport.send(Data((line + "\r\n").utf8))
        return try await readReply()
    }

    /// One reply: `250-...` continuation lines end with `250 ...`.
    private func readReply() async throws -> (Int, String) {
        var lines: [String] = []
        while true {
            let raw = try await transport.readLine()
            let line = String(data: raw, encoding: .utf8) ?? MIME.decodeLatin1(raw)
            guard line.count >= 3, let code = Int(line.prefix(3)) else {
                throw MailError.protocolError(String(line.prefix(200)))
            }
            lines.append(String(line.dropFirst(4)))
            if line.count == 3 || line[line.index(line.startIndex, offsetBy: 3)] == " " {
                return (code, lines.joined(separator: " "))
            }
        }
    }

    /// RFC 5321 §4.5.2: a line starting with "." gets one more ".".
    static func dotStuffed(_ message: Data) -> Data {
        var text = MIME.decodeLatin1(message)
        if text.hasPrefix(".") { text = "." + text }
        text = text.replacingOccurrences(of: "\r\n.", with: "\r\n..")
        if text.hasSuffix("\r\n") { text.removeLast() } // one grapheme
        return MIME.encodeLatin1(text)
    }
}
