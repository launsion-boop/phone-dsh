// SPDX-License-Identifier: MIT

import Contacts
import EventKit
import Foundation
import MessageUI

public struct OfficeSystemTools: Sendable {
    private let store: OfficeArtifactStore
    private let presenter: (any OfficePresenting)?

    public init(store: OfficeArtifactStore, presenter: (any OfficePresenting)? = nil) {
        self.store = store
        self.presenter = presenter
    }

    public func mailDraft(object: [String: Any]) async throws -> [String: Any] {
        let to = try OfficeJSON.string(object, "to", required: false) ?? ""
        let subject = try OfficeJSON.string(object, "subject") ?? ""
        let body = try OfficeJSON.string(object, "body") ?? ""
        try OfficeIR.text(subject, limit: 200, label: "subject")
        try OfficeIR.text(body, limit: 100_000, label: "body")
        let recipients = to.split(separator: ",", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard recipients.count <= 10, recipients.allSatisfy(Self.validRecipient) else {
            throw OfficeToolError.invalidArguments("to 需要最多 10 个合法邮箱，逗号分隔")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("phone-dsh-draft.eml")
        let eml = "From: \r\nTo: \(recipients.joined(separator: ", "))\r\nSubject: =?UTF-8?B?\(Data(subject.utf8).base64EncodedString())?=\r\nMIME-Version: 1.0\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\nX-Phone-DSH-Draft: true\r\n\r\n\(Data(body.utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn]))\r\n"
        try Data(eml.utf8).write(to: url, options: .atomic)
        let ref = try await store.importFile(at: url)
        var status = "draft_created"
        if MFMailComposeViewController.canSendMail(), let presenter {
            status = try await presenter.composeMail(to: recipients, subject: subject, body: body)
        }
        return ["fileId": ref.artifactID, "status": status, "sent": false,
                "draft": Self.reference(ref)]
    }

    public func createCalendarEvent(object: [String: Any]) async throws -> [String: Any] {
        guard object["confirmed"] as? Bool == true else {
            throw OfficeToolError.invalidArguments("日历写入必须显式 confirmed=true")
        }
        let title = try OfficeJSON.string(object, "title") ?? ""
        let start = try OfficeJSON.string(object, "start") ?? ""
        let end = try OfficeJSON.string(object, "end") ?? ""
        let idempotencyKey = try OfficeJSON.string(object, "idempotencyKey") ?? ""
        try OfficeIR.text(title, limit: 200, label: "title")
        guard idempotencyKey.count <= 80 else { throw OfficeToolError.invalidArguments("idempotencyKey 过长") }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let startDate = formatter.date(from: start), let endDate = formatter.date(from: end),
              endDate.timeIntervalSince(startDate) >= 60,
              endDate.timeIntervalSince(startDate) <= 7 * 86400 else {
            throw OfficeToolError.invalidArguments("start/end 需要带时区的 ISO8601，持续 1 分钟至 7 天")
        }
        let notes = try OfficeJSON.string(object, "notes", required: false)
        if let notes { try OfficeIR.text(notes, limit: 4000, label: "notes") }
        let eventStore = EKEventStore()
        guard try await Self.calendarAccess(eventStore) else {
            throw OfficeToolError.unavailable("未获得日历写入权限")
        }
        guard let presenter,
              await presenter.confirmCalendarEvent(title: title, start: start, end: end) else {
            throw OfficeToolError.cancelled
        }
        let recordKey = "pdsh.office.calendar.\(idempotencyKey)"
        if let identifier = UserDefaults.standard.string(forKey: recordKey),
           let existing = eventStore.event(withIdentifier: identifier) {
            guard existing.title == title, existing.startDate == startDate,
                  existing.endDate == endDate, existing.notes == notes else {
                throw OfficeToolError.invalidArguments("idempotencyKey 已用于不同的日程")
            }
            return ["status": "already_created", "eventId": identifier,
                    "title": existing.title ?? title, "idempotent": true]
        }
        guard let calendar = eventStore.defaultCalendarForNewEvents else {
            throw OfficeToolError.unavailable("没有可写入的默认日历")
        }
        let event = EKEvent(eventStore: eventStore)
        event.title = title
        event.startDate = startDate
        event.endDate = endDate
        event.notes = notes
        event.calendar = calendar
        try eventStore.save(event, span: .thisEvent)
        UserDefaults.standard.set(event.eventIdentifier, forKey: recordKey)
        return ["status": "created", "eventId": event.eventIdentifier ?? "",
                "title": title, "start": start, "end": end, "idempotent": false]
    }

    public func searchContacts(object: [String: Any]) async throws -> [String: Any] {
        let query = try OfficeJSON.string(object, "query") ?? ""
        try OfficeIR.text(query, limit: 100, label: "query")
        let contactStore = CNContactStore()
        guard try await Self.contactAccess(contactStore) else {
            throw OfficeToolError.unavailable("未获得通讯录读取权限")
        }
        let keys: [CNKeyDescriptor] = [CNContactGivenNameKey as CNKeyDescriptor,
                                       CNContactFamilyNameKey as CNKeyDescriptor,
                                       CNContactOrganizationNameKey as CNKeyDescriptor,
                                       CNContactEmailAddressesKey as CNKeyDescriptor,
                                       CNContactPhoneNumbersKey as CNKeyDescriptor]
        let contacts = try contactStore.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: query),
                                                        keysToFetch: keys)
        let items = contacts.prefix(20).map { contact in
            [
                "name": "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces),
                "organization": contact.organizationName,
                "emails": contact.emailAddresses.map { $0.value as String },
                "phones": contact.phoneNumbers.map { $0.value.stringValue },
            ]
        }
        return ["items": items, "count": items.count, "notFound": items.isEmpty]
    }

    public func translate(object: [String: Any]) async throws -> [String: Any] {
        guard let presenter else { throw OfficeToolError.unavailable("系统翻译页面不可用") }
        let text = try OfficeJSON.string(object, "text") ?? ""
        try OfficeIR.text(text, limit: 4000, label: "text")
        let source = try OfficeJSON.string(object, "source", required: false)
        let target = try OfficeJSON.string(object, "target") ?? "zh-Hans"
        let result = try await presenter.translate(text: text, source: source, target: target)
        return ["text": result, "source": source ?? "automatic", "target": target,
                "engine": "Apple Translation"]
    }

    private static func validRecipient(_ recipient: String) -> Bool {
        let parts = recipient.split(separator: "@", omittingEmptySubsequences: false)
        return recipient.count <= 320 && parts.count == 2 && !parts[0].isEmpty
            && parts[1].contains(".") && !recipient.contains(where: { $0.isWhitespace || $0.isNewline })
    }

    private static func calendarAccess(_ store: EKEventStore) async throws -> Bool {
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess { return true }
        return try await withCheckedThrowingContinuation { continuation in
            store.requestFullAccessToEvents { granted, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: granted) }
            }
        }
    }

    private static func contactAccess(_ store: CNContactStore) async throws -> Bool {
        if CNContactStore.authorizationStatus(for: .contacts) == .authorized { return true }
        return try await withCheckedThrowingContinuation { continuation in
            store.requestAccess(for: .contacts) { granted, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: granted) }
            }
        }
    }

    private static func reference(_ ref: OfficeArtifactRef) -> [String: Any] {
        ["fileId": ref.artifactID, "name": ref.name, "mediaType": ref.mediaType,
         "byteCount": ref.byteCount, "sha256": ref.sha256]
    }
}
