// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import PhoneDSHAgentCore
import PhoneDSHLoopback
@testable import PhoneDSHMail

final class MIMETests: XCTestCase {
    func testEncodedWordsInUTF8AndGBK() {
        XCTAssertEqual(MIME.decodeEncodedWords("=?UTF-8?B?5L2g5aW9?= =?UTF-8?B?5LiW55WM?="), "你好世界")
        // "测试" in GBK, Q-encoded.
        XCTAssertEqual(MIME.decodeEncodedWords("Re: =?gbk?Q?=B2=E2=CA=D4?="), "Re: 测试")
        XCTAssertEqual(MIME.decodeEncodedWords("plain subject"), "plain subject")
    }

    func testMultipartPrefersPlainAndListsAttachments() {
        let raw = """
        From: =?UTF-8?B?5byg5LiJ?= <zhang@qq.com>\r
        Subject: =?UTF-8?B?5ZGo5oql?=\r
        Content-Type: multipart/mixed; boundary="b1"\r
        \r
        --b1\r
        Content-Type: multipart/alternative; boundary="b2"\r
        \r
        --b2\r
        Content-Type: text/plain; charset=utf-8\r
        Content-Transfer-Encoding: quoted-printable\r
        \r
        =E4=BD=A0=E5=A5=BD\r
        --b2\r
        Content-Type: text/html; charset=utf-8\r
        \r
        <p>ignored</p>\r
        --b2--\r
        --b1\r
        Content-Type: application/pdf; name="=?UTF-8?B?5oql5ZGKLnBkZg==?="\r
        Content-Disposition: attachment; filename="=?UTF-8?B?5oql5ZGKLnBkZg==?="\r
        Content-Transfer-Encoding: base64\r
        \r
        JVBERi0=\r
        --b1--\r
        """
        let message = MIME.parse(Data(raw.utf8))
        XCTAssertEqual(message.headers["from"], "张三 <zhang@qq.com>")
        XCTAssertEqual(message.headers["subject"], "周报")
        XCTAssertEqual(message.text, "你好")
        XCTAssertFalse(message.isHTMLFallback)
        XCTAssertEqual(message.attachments, [MIMEAttachment(filename: "报告.pdf", contentType: "application/pdf", size: 5)])
    }

    func testHTMLOnlyBodyBecomesText() {
        let raw = "Content-Type: text/html; charset=gb2312\r\n\r\n" + "<html><head><style>x{}</style></head><body>A<br>B &amp; C</body></html>"
        let message = MIME.parse(Data(raw.utf8))
        XCTAssertTrue(message.isHTMLFallback)
        XCTAssertEqual(message.text, "A\nB & C")
    }

    func testComposeRoundTripsThroughTheParser() {
        let data = MIME.compose(from: "me@qq.com", to: ["a@163.com"], cc: [], subject: "会议纪要", body: "第一行\n.第二行",
                                inReplyTo: "<x@y>", messageID: "<id@qq.com>")
        let message = MIME.parse(data)
        XCTAssertEqual(message.headers["subject"], "会议纪要")
        XCTAssertEqual(message.headers["in-reply-to"], "<x@y>")
        XCTAssertEqual(message.text, "第一行\n.第二行")
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("Bcc"))
    }

    func testModifiedUTF7() {
        XCTAssertEqual(ModifiedUTF7.encode("已发送"), "&XfJT0ZAB-")
        XCTAssertEqual(ModifiedUTF7.decode("&XfJT0ZAB-"), "已发送")
        XCTAssertEqual(ModifiedUTF7.decode("Sent Messages"), "Sent Messages")
        XCTAssertEqual(ModifiedUTF7.encode("A&B"), "A&-B")
    }

    func testProviderServers() {
        XCTAssertEqual(MailProvider.provider(for: "x@163.com"), .netease)
        XCTAssertEqual(MailProvider.netease.servers(for: "x@126.com")?.imap.host, "imap.126.com")
        XCTAssertEqual(MailProvider.qq.servers(for: "x@foxmail.com")?.smtp.host, "smtp.qq.com")
        XCTAssertNil(MailProvider.qq.servers(for: "x@163.com"))
    }
}

final class MailProtocolTests: XCTestCase {
    func testSearchLogsInIdentifiesExaminesAndFiltersLocally() async throws {
        let server = FakeIMAPServer(messages: [
            (uid: 7, header: "From: boss@corp.com\r\nSubject: =?UTF-8?B?5ZGo5oql?=\r\nMessage-ID: <7@corp>\r\n", body: ""),
            (uid: 9, header: "From: news@shop.com\r\nSubject: Sale\r\n", body: ""),
        ])
        let service = MailService(factory: FakeFactory(imap: server))
        let account = MailAccount(address: "me@163.com", provider: .netease)
        let results = try await service.search(account, secret: "code", MailSearch(query: "周报"))
        XCTAssertEqual(results.map(\.uid), [7])
        XCTAssertEqual(results.first?.messageID, "<7@corp>")
        let commands = await server.commands
        XCTAssertTrue(commands.contains { $0.hasPrefix("LOGIN \"me@163.com\" \"code\"") })
        XCTAssertTrue(commands.contains { $0.hasPrefix("ID (") }, "NetEase needs ID before EXAMINE")
        XCTAssertTrue(commands.contains("EXAMINE \"INBOX\""))
        XCTAssertFalse(commands.contains { $0.hasPrefix("SELECT") }, "reading must stay read-only")
    }

    func testReadFetchesWithPeek() async throws {
        let server = FakeIMAPServer(messages: [
            (uid: 3, header: "From: a@b.com\r\nSubject: hi\r\n", body: "hello there\r\n"),
        ])
        let message = try await MailService(factory: FakeFactory(imap: server))
            .read(MailAccount(address: "me@qq.com", provider: .qq), secret: "c", folder: "INBOX", uid: 3)
        XCTAssertEqual(message.text, "hello there\r\n")
        let commands = await server.commands
        XCTAssertTrue(commands.contains("UID FETCH 3 (UID BODY.PEEK[])"))
    }

    func testRejectedLoginIsAnAuthenticationFailure() async {
        let server = FakeIMAPServer(messages: [], rejectLogin: true)
        do {
            _ = try await MailService(factory: FakeFactory(imap: server))
                .search(MailAccount(address: "me@qq.com", provider: .qq), secret: "bad", MailSearch())
            XCTFail("expected authenticationFailed")
        } catch let error as MailError {
            guard case .authenticationFailed = error else { return XCTFail("got \(error)") }
        } catch { XCTFail("got \(error)") }
    }

    func testSMTPSendAuthenticatesAndDotStuffs() async throws {
        let smtp = FakeSMTPServer()
        let service = MailService(factory: FakeFactory(smtp: smtp))
        let account = MailAccount(address: "me@qq.com", provider: .qq)
        _ = try await service.send(account, secret: "code", MailDraft(to: ["a@163.com"], bcc: ["hidden@x.com"],
                                                                      subject: "Hi", body: ".leading dot"))
        let commands = await smtp.commands
        XCTAssertTrue(commands.contains("AUTH LOGIN"))
        XCTAssertTrue(commands.contains(Data("me@qq.com".utf8).base64EncodedString()))
        XCTAssertTrue(commands.contains("RCPT TO:<a@163.com>"))
        XCTAssertTrue(commands.contains("RCPT TO:<hidden@x.com>"))
        let data = await smtp.data
        XCTAssertFalse(data.contains("hidden@x.com"), "bcc must not appear in the message")
        XCTAssertTrue(data.contains("Subject: Hi"))
    }
}

final class MailMCPServerTests: XCTestCase {
    private func makeStore() throws -> MailAccountStore {
        let defaults = UserDefaults(suiteName: "mail-tests-\(UUID().uuidString)")!
        let store = MailAccountStore(defaults: defaults, secrets: MemorySecrets())
        try store.save(MailAccount(address: "me@qq.com", provider: .qq), secret: "code")
        return store
    }

    private func call(_ server: MailMCPServer, _ name: String, _ arguments: [String: JSONValue],
                      key: String? = "k1") async throws -> [String: JSONValue] {
        let body = try JSONValue.object([
            "jsonrpc": .string("2.0"), "id": .number(1), "method": .string("tools/call"),
            "params": .object(["name": .string(name), "arguments": .object(arguments)]),
        ]).encoded()
        var headers: [String: String] = [:]
        if let key { headers["x-pdsh-idempotency-key"] = key }
        let response = await server.handle(LoopbackRequest(method: "POST", path: "/mcp/native", headers: headers, body: body))
        guard case .object(let root) = try JSONValue.parse(response.body),
              case .object(let result)? = root["result"],
              case .array(let content)? = result["content"],
              case .object(let first)? = content.first,
              case .string(let text)? = first["text"],
              case .object(let payload) = try JSONValue.parse(Data(text.utf8)) else { XCTFail("bad response"); return [:] }
        return payload
    }

    func testToolsAreListedOnlyWithAnAccount() async throws {
        let request = LoopbackRequest(method: "POST", path: "/mcp/native",
                                      body: Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8))
        let empty = MailMCPServer(fallback: EmptyMCP(), store: MailAccountStore(
            defaults: UserDefaults(suiteName: "mail-empty-\(UUID().uuidString)")!, secrets: MemorySecrets()),
                                  approver: Approver(answer: true))
        let emptyBody = await empty.handle(request).body
        XCTAssertFalse(String(decoding: emptyBody, as: UTF8.self).contains("mail_send"))
        let server = MailMCPServer(fallback: EmptyMCP(), store: try makeStore(), approver: Approver(answer: true))
        let body = await server.handle(request).body
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("mail_send"))
    }

    func testDeclinedSendNeverConnects() async throws {
        let smtp = FakeSMTPServer()
        let server = MailMCPServer(fallback: EmptyMCP(), store: try makeStore(),
                                   service: MailService(factory: FakeFactory(smtp: smtp)),
                                   approver: Approver(answer: false), receiptDirectory: tempDirectory())
        let result = try await call(server, "mail_send", ["to": .array([.string("a@163.com")]),
                                                          "subject": .string("s"), "body": .string("b")])
        XCTAssertEqual(result["status"], .string("declined"))
        let commands = await smtp.commands
        XCTAssertTrue(commands.isEmpty)
    }

    func testReplayedSendReturnsTheReceiptWithoutSendingAgain() async throws {
        let smtp = FakeSMTPServer()
        let approver = Approver(answer: true)
        let server = MailMCPServer(fallback: EmptyMCP(), store: try makeStore(),
                                   service: MailService(factory: FakeFactory(smtp: smtp)),
                                   approver: approver, receiptDirectory: tempDirectory())
        let args: [String: JSONValue] = ["to": .array([.string("a@163.com")]), "subject": .string("s"), "body": .string("b")]
        let first = try await call(server, "mail_send", args)
        XCTAssertEqual(first["status"], .string("sent"))
        let second = try await call(server, "mail_send", args)
        XCTAssertEqual(second, first)
        let asked = await approver.count
        XCTAssertEqual(asked, 1)
        let dataCommands = await smtp.commands.filter { $0 == "DATA" }
        XCTAssertEqual(dataCommands.count, 1)

        var changed = args
        changed["body"] = .string("different")
        let conflict = try await call(server, "mail_send", changed)
        XCTAssertEqual(conflict["status"], .string("idempotency_conflict"))
    }

    func testSendWithoutJournalKeyIsRefused() async throws {
        let server = MailMCPServer(fallback: EmptyMCP(), store: try makeStore(),
                                   service: MailService(factory: FakeFactory(smtp: FakeSMTPServer())),
                                   approver: Approver(answer: true), receiptDirectory: tempDirectory())
        let result = try await call(server, "mail_send", ["to": .array([.string("a@163.com")]),
                                                          "subject": .string("s"), "body": .string("b")], key: nil)
        XCTAssertEqual(result["status"], .string("journal_key_required"))
    }

    private func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("mail-receipts-\(UUID().uuidString)")
    }
}

// MARK: - Fakes

private struct FakeFactory: MailTransportFactory {
    var imap: FakeIMAPServer?
    var smtp: FakeSMTPServer?

    func connect(host: String, port: Int) async throws -> any MailLineTransport {
        if port == 993, let imap { await imap.reset(); return imap }
        if port == 465, let smtp { await smtp.reset(); return smtp }
        throw MailError.connectionFailed("no fake for \(host):\(port)")
    }
}

/// Byte-buffer transport whose replies are produced from the commands it receives.
private class ScriptedTransport: @unchecked Sendable {
    let lock = NSLock()
    var buffer = Data()

    func push(_ text: String) { lock.lock(); buffer.append(Data(text.utf8)); lock.unlock() }

    func readLineSync() throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard let newline = buffer.firstIndex(of: 0x0A) else { throw MailError.closed }
        var line = buffer[buffer.startIndex..<newline]
        if line.last == 0x0D { line = line.dropLast() }
        buffer = Data(buffer[(newline + 1)...])
        return Data(line)
    }

    func readSync(count: Int) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard buffer.count >= count else { throw MailError.closed }
        let chunk = Data(buffer.prefix(count))
        buffer = Data(buffer.dropFirst(count))
        return chunk
    }
}

private actor FakeIMAPServer: MailLineTransport {
    private let script = ScriptedTransport()
    private let messages: [(uid: Int, header: String, body: String)]
    private let rejectLogin: Bool
    private(set) var commands: [String] = []

    init(messages: [(uid: Int, header: String, body: String)], rejectLogin: Bool = false) {
        self.messages = messages
        self.rejectLogin = rejectLogin
    }

    func reset() { script.push("* OK ready\r\n") }

    func send(_ data: Data) async throws {
        let line = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
        let space = line.firstIndex(of: " ")!
        let tag = String(line[..<space])
        let command = String(line[line.index(after: space)...])
        commands.append(command)
        if command.hasPrefix("LOGIN") {
            script.push(rejectLogin ? "\(tag) NO [AUTHENTICATIONFAILED] bad\r\n" : "\(tag) OK logged in\r\n")
        } else if command.hasPrefix("EXAMINE") {
            script.push("* \(messages.count) EXISTS\r\n\(tag) OK [READ-ONLY] done\r\n")
        } else if command.hasPrefix("UID SEARCH") {
            script.push("* SEARCH \(messages.map { String($0.uid) }.joined(separator: " "))\r\n\(tag) OK\r\n")
        } else if command.hasPrefix("UID FETCH"), command.contains("BODY.PEEK[]") {
            let uid = Int(command.split(separator: " ")[2])!
            let message = messages.first { $0.uid == uid }!
            let full = message.header + "\r\n" + message.body
            script.push("* 1 FETCH (UID \(uid) BODY[] {\(full.utf8.count)}\r\n\(full))\r\n\(tag) OK\r\n")
        } else if command.hasPrefix("UID FETCH") {
            let set = Set(command.split(separator: " ")[2].split(separator: ",").compactMap { Int($0) })
            var reply = ""
            for message in messages where set.contains(message.uid) {
                let header = message.header + "\r\n"
                let size = (message.header + "\r\n" + message.body).utf8.count
                reply += "* 1 FETCH (UID \(message.uid) FLAGS (\\Seen) RFC822.SIZE \(size) BODY[HEADER.FIELDS (FROM)] {\(header.utf8.count)}\r\n\(header))\r\n"
            }
            script.push(reply + "\(tag) OK\r\n")
        } else if command.hasPrefix("LOGOUT") {
            script.push("* BYE\r\n\(tag) OK\r\n")
        } else {
            script.push("\(tag) OK\r\n")
        }
    }

    func readLine() async throws -> Data { try script.readLineSync() }
    func read(count: Int) async throws -> Data { try script.readSync(count: count) }
    func close() async {}
}

private actor FakeSMTPServer: MailLineTransport {
    private let script = ScriptedTransport()
    private(set) var commands: [String] = []
    private(set) var data = ""
    private var inData = false

    func reset() { inData = false; script.push("220 ready\r\n") }

    func send(_ payload: Data) async throws {
        let text = String(decoding: payload, as: UTF8.self)
        if inData {
            data += text
            if text.hasSuffix("\r\n.\r\n") { inData = false; script.push("250 queued\r\n") }
            return
        }
        let line = text.trimmingCharacters(in: .newlines)
        commands.append(line)
        switch true {
        case line.hasPrefix("EHLO"): script.push("250-hello\r\n250 AUTH LOGIN\r\n")
        case line == "AUTH LOGIN": script.push("334 VXNlcm5hbWU6\r\n")
        case line == Data("me@qq.com".utf8).base64EncodedString(): script.push("334 UGFzc3dvcmQ6\r\n")
        case line == Data("code".utf8).base64EncodedString(): script.push("235 ok\r\n")
        case line == "DATA": inData = true; script.push("354 go\r\n")
        case line == "QUIT": script.push("221 bye\r\n")
        default: script.push("250 ok\r\n")
        }
    }

    func readLine() async throws -> Data { try script.readLineSync() }
    func read(count: Int) async throws -> Data { try script.readSync(count: count) }
    func close() async {}
}

private final class MemorySecrets: MailSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func secret(for account: String) throws -> String? { lock.withLock { values[account] } }
    func setSecret(_ secret: String, for account: String) throws { lock.withLock { values[account] = secret } }
    func deleteSecret(for account: String) throws { _ = lock.withLock { values.removeValue(forKey: account) } }
}

private actor Approver: MailSendApproving {
    let answer: Bool
    private(set) var count = 0
    init(answer: Bool) { self.answer = answer }
    func approve(account: MailAccount, draft: MailDraft) async -> Bool { count += 1; return answer }
}

private final class EmptyMCP: NativeMCPServing, @unchecked Sendable {
    func handle(_ request: LoopbackRequest) async -> NativeMCPResponse {
        NativeMCPResponse(body: Data(#"{"jsonrpc":"2.0","id":1,"result":{"tools":[]}}"#.utf8))
    }
}
