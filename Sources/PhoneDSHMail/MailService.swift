// SPDX-License-Identifier: MIT
// One connection per operation: connect, log in, do one thing, log out.

import Foundation

public struct MailSearch: Sendable, Equatable {
    public var folder: String = "INBOX"
    /// Matched case-insensitively against subject, from, to and cc.
    public var query: String?
    public var unreadOnly = false
    public var sinceDays: Int?
    public var limit = 20

    public init(folder: String = "INBOX", query: String? = nil, unreadOnly: Bool = false,
                sinceDays: Int? = nil, limit: Int = 20) {
        self.folder = folder
        self.query = query
        self.unreadOnly = unreadOnly
        self.sinceDays = sinceDays
        self.limit = limit
    }
}

public struct MailDraft: Sendable, Equatable {
    public var to: [String]
    public var cc: [String]
    public var bcc: [String]
    public var subject: String
    public var body: String
    public var inReplyTo: String?

    public init(to: [String], cc: [String] = [], bcc: [String] = [], subject: String, body: String, inReplyTo: String? = nil) {
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.body = body
        self.inReplyTo = inReplyTo
    }
}

public struct MailService: Sendable {
    /// Newest messages a search looks at before filtering locally. Local
    /// filtering avoids server-specific CHARSET support for Chinese queries.
    public static let scanWindow = 300
    public static let maxMessageBytes = 8 << 20

    private let factory: any MailTransportFactory
    private let now: @Sendable () -> Date

    public init(factory: any MailTransportFactory = TLSMailTransportFactory(),
                now: @escaping @Sendable () -> Date = Date.init) {
        self.factory = factory
        self.now = now
    }

    /// Log in to both IMAP and SMTP; nothing is stored.
    public func verify(_ account: MailAccount, secret: String) async throws {
        try await withIMAP(account, secret: secret) { _ in }
        try await withSMTP(account, secret: secret) { _ in }
    }

    public func folders(_ account: MailAccount, secret: String) async throws -> [MailFolder] {
        try await withIMAP(account, secret: secret) { try await $0.listFolders() }
    }

    public func search(_ account: MailAccount, secret: String, _ search: MailSearch) async throws -> [MailSummary] {
        try await withIMAP(account, secret: secret) { session in
            try await session.examine(search.folder)
            var criteria: [String] = []
            if let days = search.sinceDays, days > 0 {
                criteria.append("SINCE \(IMAPSession.searchDate(now().addingTimeInterval(-Double(days) * 86_400)))")
            }
            if search.unreadOnly { criteria.append("UNSEEN") }
            let uids = try await session.uidSearch(criteria.isEmpty ? "ALL" : criteria.joined(separator: " "))
            let window = Array(uids.suffix(Self.scanWindow))
            var summaries: [MailSummary] = []
            // Fetch in chunks so one command line stays short.
            for chunk in stride(from: 0, to: window.count, by: 100) {
                summaries += try await session.fetchSummaries(Array(window[chunk..<min(chunk + 100, window.count)]))
            }
            let needle = search.query?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            let matching = needle.isEmpty ? summaries : summaries.filter {
                [$0.subject, $0.from, $0.to, $0.cc].contains { $0.lowercased().contains(needle) }
            }
            return Array(matching.sorted { $0.uid > $1.uid }.prefix(max(1, search.limit)))
        }
    }

    public func read(_ account: MailAccount, secret: String, folder: String, uid: UInt32) async throws -> MIMEMessage {
        let raw = try await withIMAP(account, secret: secret) { session in
            try await session.examine(folder)
            return try await session.fetchMessage(uid, maxBytes: Self.maxMessageBytes)
        }
        return MIME.parse(raw)
    }

    /// Returns the Message-ID that was sent.
    public func send(_ account: MailAccount, secret: String, _ draft: MailDraft) async throws -> String {
        let domain = account.address.split(separator: "@").last.map(String.init) ?? "localhost"
        let messageID = "<\(UUID().uuidString.lowercased())@\(domain)>"
        let message = MIME.compose(from: account.address, to: draft.to, cc: draft.cc, subject: draft.subject,
                                   body: draft.body, inReplyTo: draft.inReplyTo, date: now(), messageID: messageID)
        try await withSMTP(account, secret: secret) { session in
            try await session.send(from: account.address, recipients: draft.to + draft.cc + draft.bcc, message: message)
        }
        return messageID
    }

    // MARK: Sessions

    private func withIMAP<T: Sendable>(_ account: MailAccount, secret: String,
                                       _ body: (IMAPSession) async throws -> T) async throws -> T {
        guard let servers = account.provider.servers(for: account.address) else {
            throw MailError.invalidArguments("不支持的邮箱地址 \(account.address)")
        }
        let session = IMAPSession(transport: try await factory.connect(host: servers.imap.host, port: servers.imap.port))
        do {
            try await session.greeting()
            try await session.login(user: account.address, password: secret)
            await session.identify()
            let result = try await body(session)
            await session.logout()
            return result
        } catch {
            await session.logout()
            throw error
        }
    }

    private func withSMTP<T: Sendable>(_ account: MailAccount, secret: String,
                                       _ body: (SMTPSession) async throws -> T) async throws -> T {
        guard let servers = account.provider.servers(for: account.address) else {
            throw MailError.invalidArguments("不支持的邮箱地址 \(account.address)")
        }
        let session = SMTPSession(transport: try await factory.connect(host: servers.smtp.host, port: servers.smtp.port))
        do {
            try await session.greeting()
            try await session.hello()
            try await session.login(user: account.address, password: secret)
            let result = try await body(session)
            await session.quit()
            return result
        } catch {
            await session.quit()
            throw error
        }
    }
}
