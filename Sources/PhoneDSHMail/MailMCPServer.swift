// SPDX-License-Identifier: MIT
// Native MCP tools for the connected mailboxes, chained in front of the app's
// other native MCP servers. Reading is free; every send is approved by the
// user in the app first, and a journal-keyed receipt guarantees that a retried
// or replayed call never sends the same message twice.

import CryptoKit
import Foundation
import PhoneDSHAgentCore
import PhoneDSHLoopback

/// Shows the user exactly what will be sent and returns their decision.
public protocol MailSendApproving: Sendable {
    func approve(account: MailAccount, draft: MailDraft) async -> Bool
}

public actor MailMCPServer: NativeMCPServing {
    private struct Receipt: Codable {
        let fingerprint: String
        var result: JSONValue?
    }

    private let fallback: any NativeMCPServing
    private let store: MailAccountStore
    private let service: MailService
    private let approver: any MailSendApproving
    private let directory: URL

    public static let toolNames: Set<String> = ["mail_accounts", "mail_folders", "mail_search", "mail_read", "mail_send"]
    static let maxBodyBytes = 256 << 10
    static let maxReadChars = 20_000

    public init(fallback: any NativeMCPServing, store: MailAccountStore, service: MailService = MailService(),
                approver: any MailSendApproving, receiptDirectory: URL? = nil) {
        self.fallback = fallback
        self.store = store
        self.service = service
        self.approver = approver
        directory = receiptDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("mail-send-receipts", isDirectory: true)
    }

    public func cancelPendingOperations() async {
        await fallback.cancelPendingOperations()
    }

    public func handle(_ request: LoopbackRequest) async -> NativeMCPResponse {
        guard request.method == "POST", request.body.count <= Self.maxBodyBytes,
              let message = try? JSONValue.parse(request.body),
              case .object(let root) = message, root["jsonrpc"] == .string("2.0"),
              case .string(let method)? = root["method"] else { return await fallback.handle(request) }
        let params = root["params"]
        let hasAccounts = !store.accounts().isEmpty
        if method == "initialize" || method == "tools/list" {
            var response = await fallback.handle(request)
            guard hasAccounts, case .object(var body)? = try? JSONValue.parse(response.body),
                  case .object(var result)? = body["result"] else { return response }
            if method == "tools/list" {
                if case .array(let tools)? = result["tools"] { result["tools"] = .array(tools + Self.descriptors) }
            } else {
                let existing: String
                if case .string(let text)? = result["instructions"] { existing = text + " " } else { existing = "" }
                result["instructions"] = .string(existing + Self.instructions)
            }
            body["result"] = .object(result)
            response.body = (try? JSONValue.object(body).encoded()) ?? response.body
            return response
        }
        guard method == "tools/call", case .object(let call)? = params, case .string(let name)? = call["name"],
              Self.toolNames.contains(name) else { return await fallback.handle(request) }
        guard let id = root["id"] else { return NativeMCPResponse(status: 202) }
        let arguments: [String: JSONValue]
        if case .object(let object)? = call["arguments"] { arguments = object } else { arguments = [:] }
        let key = request.headers.first { $0.key.lowercased() == "x-pdsh-idempotency-key" }?.value
        let result: JSONValue
        do {
            result = try await run(name, arguments, key: key)
        } catch let error as MailError {
            result = Self.failure(Self.code(error), error.errorDescription ?? "mail error")
        } catch {
            result = Self.failure("mail_failed", String(describing: error))
        }
        return NativeMCPResponse(body: (try? JSONValue.object([
            "jsonrpc": .string("2.0"), "id": id, "result": result,
        ]).encoded()) ?? Data())
    }

    // MARK: Tools

    private func run(_ name: String, _ args: [String: JSONValue], key: String?) async throws -> JSONValue {
        switch name {
        case "mail_accounts":
            return Self.success(.object(["accounts": .array(store.accounts().map {
                .object(["address": .string($0.address), "provider": .string($0.provider.rawValue)])
            })]))
        case "mail_folders":
            let account = try resolveAccount(args)
            let folders = try await service.folders(account, secret: try store.secret(for: account))
            return Self.success(.object(["account": .string(account.address), "folders": .array(folders.map {
                .object(["name": .string($0.name), "flags": .array($0.flags.map { .string($0) })])
            })]))
        case "mail_search":
            let account = try resolveAccount(args)
            let search = MailSearch(folder: Self.string(args["folder"]) ?? "INBOX",
                                    query: Self.string(args["query"]),
                                    unreadOnly: Self.bool(args["unread_only"]) ?? false,
                                    sinceDays: Self.int(args["since_days"]).map { min(max($0, 1), 3650) },
                                    limit: min(max(Self.int(args["limit"]) ?? 20, 1), 50))
            let items = try await service.search(account, secret: try store.secret(for: account), search)
            return Self.success(.object([
                "account": .string(account.address), "folder": .string(search.folder),
                "scanned_newest": .number(Double(MailService.scanWindow)),
                "messages": .array(items.map(Self.summary)),
            ]))
        case "mail_read":
            let account = try resolveAccount(args)
            guard let uid = Self.int(args["uid"]), uid > 0, uid <= Int(UInt32.max) else {
                throw MailError.invalidArguments("uid 必须是 mail_search 返回的正整数")
            }
            let folder = Self.string(args["folder"]) ?? "INBOX"
            let message = try await service.read(account, secret: try store.secret(for: account), folder: folder, uid: UInt32(uid))
            let truncated = message.text.count > Self.maxReadChars
            return Self.success(.object([
                "account": .string(account.address), "folder": .string(folder), "uid": .number(Double(uid)),
                "from": .string(message.headers["from"] ?? ""), "to": .string(message.headers["to"] ?? ""),
                "cc": .string(message.headers["cc"] ?? ""), "subject": .string(message.headers["subject"] ?? ""),
                "date": .string(message.headers["date"] ?? ""),
                "message_id": .string(message.headers.raw("message-id") ?? ""),
                "text": .string(String(message.text.prefix(Self.maxReadChars))),
                "text_truncated": .bool(truncated), "from_html": .bool(message.isHTMLFallback),
                "attachments": .array(message.attachments.map {
                    .object(["filename": .string($0.filename), "content_type": .string($0.contentType),
                             "size": .number(Double($0.size))])
                }),
            ]))
        case "mail_send":
            return try await send(args, key: key)
        default:
            throw MailError.invalidArguments("unknown tool")
        }
    }

    private func send(_ args: [String: JSONValue], key: String?) async throws -> JSONValue {
        let account = try resolveAccount(args)
        let draft = MailDraft(to: try Self.addresses(args["to"], field: "to", required: true),
                              cc: try Self.addresses(args["cc"], field: "cc", required: false),
                              bcc: try Self.addresses(args["bcc"], field: "bcc", required: false),
                              subject: Self.string(args["subject"]) ?? "",
                              body: Self.string(args["body"]) ?? "",
                              inReplyTo: Self.string(args["in_reply_to"]))
        guard !draft.subject.isEmpty || !draft.body.isEmpty else {
            throw MailError.invalidArguments("subject 和 body 不能都为空")
        }
        guard draft.to.count + draft.cc.count + draft.bcc.count <= 50 else {
            throw MailError.invalidArguments("收件人最多 50 个")
        }
        guard let key, !key.isEmpty, key.utf8.count <= 256 else {
            return Self.failure("journal_key_required", "发送需要工具调用的幂等键")
        }
        let fingerprint = Self.fingerprint(account: account, draft: draft)
        let file = directory.appendingPathComponent(
            SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined() + ".json")
        if FileManager.default.fileExists(atPath: file.path) {
            let receipt = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: file))
            guard receipt.fingerprint == fingerprint else {
                return Self.failure("idempotency_conflict", "同一个调用键对应了不同的邮件")
            }
            // A finished call returns its result; an interrupted one may or may
            // not have reached the server, so it is never re-sent automatically.
            return receipt.result ?? Self.failure("outcome_unknown", "上一次发送被中断，无法确定是否已发出。请到已发送文件夹确认，不要自动重发。")
        }
        guard await approver.approve(account: account, draft: draft) else {
            return Self.failure("declined", "用户没有同意发送这封邮件。")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.save(Receipt(fingerprint: fingerprint, result: nil), to: file)
        let result: JSONValue
        do {
            let messageID = try await service.send(account, secret: try store.secret(for: account), draft)
            result = Self.success(.object([
                "status": .string("sent"), "account": .string(account.address),
                "message_id": .string(messageID),
                "recipients": .number(Double(draft.to.count + draft.cc.count + draft.bcc.count)),
            ]))
        } catch let error as MailError {
            switch error {
            case .timeout, .closed, .connectionFailed:
                // The connection may have dropped after the server accepted
                // the message; never report this as a clean failure.
                result = Self.failure("outcome_unknown", "发送过程中连接中断，无法确定邮件是否已发出。请到已发送文件夹确认，不要自动重发。")
            default:
                // The server refused (auth, recipient, policy): nothing was accepted.
                result = Self.failure(Self.code(error), error.errorDescription ?? "send failed")
            }
        }
        try? Self.save(Receipt(fingerprint: fingerprint, result: result), to: file)
        return result
    }

    private func resolveAccount(_ args: [String: JSONValue]) throws -> MailAccount {
        let accounts = store.accounts()
        if let address = Self.string(args["account"]), !address.isEmpty {
            guard let account = store.account(address) else {
                throw MailError.invalidArguments("没有连接邮箱 \(address)。可用账号：\(accounts.map(\.address).joined(separator: ", "))")
            }
            return account
        }
        guard accounts.count == 1, let only = accounts.first else {
            throw MailError.invalidArguments(accounts.isEmpty
                ? "还没有连接邮箱"
                : "连接了多个邮箱，请用 account 指定：\(accounts.map(\.address).joined(separator: ", "))")
        }
        return only
    }

    // MARK: Encoding

    private static func summary(_ item: MailSummary) -> JSONValue {
        .object(["uid": .number(Double(item.uid)), "from": .string(item.from), "to": .string(item.to),
                 "subject": .string(item.subject), "date": .string(item.date), "seen": .bool(item.seen),
                 "size": .number(Double(item.size)), "message_id": .string(item.messageID)])
    }

    static func success(_ value: JSONValue) -> JSONValue {
        .object(["content": .array([.object([
            "type": .string("text"), "text": .string(String(decoding: (try? value.encoded()) ?? Data(), as: UTF8.self)),
        ])]), "isError": .bool(false)])
    }

    static func failure(_ code: String, _ message: String) -> JSONValue {
        let value: JSONValue = .object(["status": .string(code), "message": .string(String(message.prefix(600))),
                                        "automatic_retry": .bool(false)])
        return .object(["content": .array([.object([
            "type": .string("text"), "text": .string(String(decoding: (try? value.encoded()) ?? Data(), as: UTF8.self)),
        ])]), "isError": .bool(true)])
    }

    static func code(_ error: MailError) -> String {
        switch error {
        case .authenticationFailed: return "authentication_failed"
        case .connectionFailed, .closed: return "connection_failed"
        case .timeout: return "timeout"
        case .messageTooLarge: return "message_too_large"
        case .notFound: return "not_found"
        case .invalidArguments: return "invalid_arguments"
        case .protocolError: return "server_error"
        case .store: return "account_unavailable"
        }
    }

    static func fingerprint(account: MailAccount, draft: MailDraft) -> String {
        let parts = [account.address, draft.to.joined(separator: ","), draft.cc.joined(separator: ","),
                     draft.bcc.joined(separator: ","), draft.subject, draft.body, draft.inReplyTo ?? ""]
        return SHA256.hash(data: Data(parts.joined(separator: "\u{1F}").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func save(_ receipt: Receipt, to file: URL) throws {
        try JSONEncoder().encode(receipt).write(to: file, options: .atomic)
    }

    static func string(_ value: JSONValue?) -> String? {
        if case .string(let text)? = value { return text }
        return nil
    }

    static func bool(_ value: JSONValue?) -> Bool? {
        if case .bool(let flag)? = value { return flag }
        return nil
    }

    static func int(_ value: JSONValue?) -> Int? {
        switch value {
        case .number(let number)?: return number.isFinite && number == number.rounded() ? Int(number) : nil
        case .string(let text)?: return Int(text)
        default: return nil
        }
    }

    static func addresses(_ value: JSONValue?, field: String, required: Bool) throws -> [String] {
        var raw: [String] = []
        switch value {
        case .array(let items)?: raw = items.compactMap { string($0) }
        case .string(let text)?: raw = [text]
        case nil, .null?: raw = []
        default: throw MailError.invalidArguments("\(field) 必须是邮箱地址数组")
        }
        guard raw.allSatisfy({ !MIME.addresses($0).isEmpty }) else {
            throw MailError.invalidArguments("\(field) 里有无效的邮箱地址")
        }
        let parsed = raw.flatMap(MIME.addresses)
        if required, parsed.isEmpty { throw MailError.invalidArguments("\(field) 至少需要一个邮箱地址") }
        return parsed
    }

    // MARK: Descriptors

    static let instructions = "Mail tools read and send mail for the mailboxes the user connected on this phone (QQ Mail, NetEase, Gmail). Use mail_search to find messages (it matches subject and addresses in the newest messages, not body text), then mail_read with the returned uid. mail_send asks the user to confirm on the phone before sending; if the result is declined, do not retry. If a send result is outcome_unknown, tell the user to check the Sent folder and never resend automatically. Do not send mail the user did not ask for."

    static let descriptors: [JSONValue] = [
        tool("mail_accounts", "List the connected mailboxes.", [:], required: [], readOnly: true),
        tool("mail_folders", "List the folders of one mailbox (inbox, sent, drafts…).",
             ["account": accountSchema], required: [], readOnly: true),
        tool("mail_search", "Find recent messages in a folder. Matches subject, from, to and cc among the newest \(MailService.scanWindow) messages.",
             ["account": accountSchema,
              "folder": .object(["type": .string("string"), "description": .string("Folder name from mail_folders; default INBOX.")]),
              "query": .object(["type": .string("string"), "description": .string("Text to match in subject or addresses.")]),
              "unread_only": .object(["type": .string("boolean")]),
              "since_days": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(3650)]),
              "limit": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(50)])],
             required: [], readOnly: true),
        tool("mail_read", "Read one message as text, with its attachment list. Does not mark it read.",
             ["account": accountSchema,
              "folder": .object(["type": .string("string"), "description": .string("Same folder as the search; default INBOX.")]),
              "uid": .object(["type": .string("integer"), "minimum": .number(1)])],
             required: ["uid"], readOnly: true),
        tool("mail_send", "Send a plain-text email. The user confirms on the phone before it is sent. To reply, pass the original message_id as in_reply_to and a subject starting with Re:.",
             ["account": accountSchema,
              "to": addressList, "cc": addressList, "bcc": addressList,
              "subject": .object(["type": .string("string"), "maxLength": .number(998)]),
              "body": .object(["type": .string("string"), "maxLength": .number(100_000)]),
              "in_reply_to": .object(["type": .string("string")])],
             required: ["to", "subject", "body"], readOnly: false),
    ]

    private static let accountSchema: JSONValue = .object([
        "type": .string("string"),
        "description": .string("Mailbox address from mail_accounts; optional when only one is connected."),
    ])
    private static let addressList: JSONValue = .object([
        "type": .string("array"), "items": .object(["type": .string("string")]), "maxItems": .number(50),
    ])

    private static func tool(_ name: String, _ description: String, _ properties: [String: JSONValue],
                             required: [String], readOnly: Bool) -> JSONValue {
        .object([
            "name": .string(name), "description": .string(description),
            "inputSchema": .object([
                "type": .string("object"), "properties": .object(properties),
                "required": .array(required.map { .string($0) }), "additionalProperties": .bool(false),
            ]),
            "annotations": .object(["readOnlyHint": .bool(readOnly), "idempotentHint": .bool(readOnly)]),
        ])
    }
}
