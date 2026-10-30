// SPDX-License-Identifier: MIT

import Contacts
import EventKit
import Foundation
import Photos

public enum PhoneContactSerializer {
    public static var keys: [CNKeyDescriptor] {
        [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
        ]
    }

    public static func dictionary(_ contact: CNContact, reveal: Bool = false) -> [String: Any] {
        [
            "id": contact.identifier,
            "name": "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces),
            "organization": contact.organizationName,
            "org": contact.organizationName,
            "emails": contact.emailAddresses.map { reveal ? $0.value as String : maskEmail($0.value as String) },
            "phones": contact.phoneNumbers.map { reveal ? $0.value.stringValue : maskPhone($0.value.stringValue) },
            "masked": !reveal,
            "scope": reveal ? "revealed" : "masked",
        ]
    }

    public static func maskEmail(_ value: String) -> String {
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, let first = parts[0].first else { return "***" }
        return "\(first)***@\(parts[1])"
    }

    public static func maskPhone(_ value: String) -> String {
        let digits = value.filter(\.isNumber)
        guard digits.count >= 4 else { return "***" }
        return "***\(digits.suffix(4))"
    }
}

@MainActor
public struct PhonePersonalTools {
    public init() {}

    public func searchContacts(object: [String: Any]) async throws -> PhoneToolPayload {
        let query = try PhoneToolEnvelope.text(object, "query", limit: 200) ?? ""
        let reveal = try PhoneToolEnvelope.flag(object, "reveal")
        let cursor = try PhoneToolEnvelope.integer(object, "cursor", default: 0, minimum: 0, maximum: 100_000)
        let limit = try PhoneToolEnvelope.integer(object, "limit", default: 20, minimum: 1, maximum: 20)
        let request = CNContactFetchRequest(keysToFetch: PhoneContactSerializer.keys)
        request.predicate = query.contains("@")
            ? CNContact.predicateForContacts(matchingEmailAddress: query)
            : CNContact.predicateForContacts(matchingName: query)
        var matches: [CNContact] = []
        try CNContactStore().enumerateContacts(with: request) { contact, _ in
            matches.append(contact)
        }
        matches.sort { $0.givenName.localizedCaseInsensitiveCompare($1.givenName) == .orderedAscending }
        guard cursor <= matches.count else { throw PhoneToolError.invalidArguments("cursor 超出结果范围") }
        let page = matches.dropFirst(cursor).prefix(limit).map {
            PhoneContactSerializer.dictionary($0, reveal: reveal)
        }
        let next = cursor + page.count
        return PhoneToolPayload(data: ["items": page, "count": page.count, "total": matches.count],
                                nextCursor: next < matches.count ? next : NSNull(),
                                truncated: next < matches.count)
    }

    public func contact(object: [String: Any]) async throws -> PhoneToolPayload {
        let identifier = try PhoneToolEnvelope.text(object, "id", limit: 128) ?? ""
        let reveal = try PhoneToolEnvelope.flag(object, "reveal")
        let contact = try CNContactStore().unifiedContact(withIdentifier: identifier,
                                                          keysToFetch: PhoneContactSerializer.keys)
        return PhoneToolPayload(data: PhoneContactSerializer.dictionary(contact, reveal: reveal))
    }

    public func calendar(object: [String: Any]) async throws -> PhoneToolPayload {
        let start = try PhoneToolEnvelope.date(object, "from", alias: "start", default: Date())
        let end = try PhoneToolEnvelope.date(object, "to", alias: "end",
                                               default: start.addingTimeInterval(30 * 86400))
        guard end > start, end.timeIntervalSince(start) <= 366 * 86400 else {
            throw PhoneToolError.invalidArguments("日历范围必须大于 0 且不超过 366 天")
        }
        let cursor = try PhoneToolEnvelope.integer(object, "cursor", default: 0, minimum: 0, maximum: 100_000)
        let limit = try PhoneToolEnvelope.integer(object, "limit", default: 20, minimum: 1, maximum: 100)
        let store = EKEventStore()
        var calendars: [EKCalendar]?
        if let identifiers = object["calendars"] as? [String] {
            guard identifiers.count <= 20 else { throw PhoneToolError.invalidArguments("calendars 最多 20 项") }
            calendars = store.calendars(for: .event).filter {
                identifiers.contains($0.calendarIdentifier) || identifiers.contains($0.title)
            }
        } else if object["calendars"] != nil {
            throw PhoneToolError.invalidArguments("calendars 必须是日历 ID 或名称数组")
        }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
        let events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
        guard cursor <= events.count else { throw PhoneToolError.invalidArguments("cursor 超出结果范围") }
        let page = events.dropFirst(cursor).prefix(limit)
        let items = page.map { event -> [String: Any] in
            [
                "id": event.eventIdentifier,
                "title": event.title ?? "",
                "start": PhoneToolEnvelope.iso8601(event.startDate),
                "end": PhoneToolEnvelope.iso8601(event.endDate),
                "calendar": event.calendar.title,
                "allDay": event.isAllDay,
                "location": event.location ?? "",
            ]
        }
        let next = cursor + items.count
        return PhoneToolPayload(
            data: ["items": items, "count": items.count, "total": events.count],
            nextCursor: next < events.count ? next : NSNull(), truncated: next < events.count)
    }

    public func reminders(object: [String: Any]) async throws -> PhoneToolPayload {
        let cursor = try PhoneToolEnvelope.integer(object, "cursor", default: 0, minimum: 0, maximum: 100_000)
        let limit = try PhoneToolEnvelope.integer(object, "limit", default: 20, minimum: 1, maximum: 100)
        let listID = try PhoneToolEnvelope.text(object, "listId", required: false, limit: 200)
        let store = EKEventStore()
        var reminders = try await fetchReminders(store)
        if let listID {
            reminders = reminders.filter {
                $0.calendar.calendarIdentifier == listID || $0.calendar.title == listID
            }
        }
        if object["completed"] != nil {
            let completed = try PhoneToolEnvelope.flag(object, "completed")
            reminders = reminders.filter { $0.isCompleted == completed }
        }
        reminders.sort {
            ($0.dueDateComponents?.date ?? .distantFuture) < ($1.dueDateComponents?.date ?? .distantFuture)
        }
        guard cursor <= reminders.count else { throw PhoneToolError.invalidArguments("cursor 超出结果范围") }
        let page = reminders.dropFirst(cursor).prefix(limit)
        let items = page.map { reminder -> [String: Any] in
            [
                "id": reminder.calendarItemIdentifier,
                "title": reminder.title ?? "",
                "completed": reminder.isCompleted,
                "due": reminder.dueDateComponents?.date.map(PhoneToolEnvelope.iso8601) ?? NSNull(),
                "priority": reminder.priority,
                "list": reminder.calendar.title,
                "completionDate": reminder.completionDate.map(PhoneToolEnvelope.iso8601) ?? NSNull(),
            ]
        }
        let next = cursor + items.count
        return PhoneToolPayload(
            data: ["items": items, "count": items.count, "total": reminders.count],
            nextCursor: next < reminders.count ? next : NSNull(), truncated: next < reminders.count)
    }

    public func createReminder(object: [String: Any]) async throws -> PhoneToolPayload {
        try PhoneToolEnvelope.requireConfirmation(object)
        let title = try PhoneToolEnvelope.text(object, "title", limit: 200) ?? ""
        let notes = try PhoneToolEnvelope.text(object, "notes", required: false, limit: 4000)
        let idempotencyKey = try PhoneToolEnvelope.text(object, "idempotencyKey", limit: 128) ?? ""
        let recordKey = "phone-dsh.reminders.\(idempotencyKey)"
        let due = object["due"] == nil ? nil : try PhoneToolEnvelope.date(object, "due")
        let store = EKEventStore()
        if let identifier = UserDefaults.standard.string(forKey: recordKey) {
            guard let existing = store.calendarItem(withIdentifier: identifier) as? EKReminder else {
                throw PhoneToolError.invalidArguments("idempotencyKey 已使用，但原提醒事项已不存在")
            }
            let sameDue = abs((existing.dueDateComponents?.date ?? .distantPast)
                .timeIntervalSince(due ?? .distantPast)) < 1
            guard existing.title == title, existing.notes == notes, sameDue else {
                throw PhoneToolError.invalidArguments("idempotencyKey 已用于另一条提醒事项")
            }
            return PhoneToolPayload(data: [
                "status": "already_created", "id": identifier, "idempotent": true,
            ])
        }
        var calendar = store.defaultCalendarForNewReminders()
        if let listID = try PhoneToolEnvelope.text(object, "listId", required: false, limit: 200) {
            calendar = store.calendars(for: .reminder).first {
                $0.calendarIdentifier == listID || $0.title == listID
            }
            guard calendar != nil else { throw PhoneToolError.invalidArguments("未找到提醒事项列表") }
        }
        guard let calendar else {
            throw PhoneToolError.unavailable(.reminders, "没有可写入的提醒事项列表")
        }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.notes = notes
        reminder.calendar = calendar
        if let due {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second, .timeZone], from: due)
        }
        try store.save(reminder, commit: true)
        let identifier = reminder.calendarItemIdentifier
        UserDefaults.standard.set(identifier, forKey: recordKey)
        return PhoneToolPayload(data: [
            "status": "created", "id": identifier, "title": title,
        ])
    }

    public func completeReminder(object: [String: Any]) async throws -> PhoneToolPayload {
        try PhoneToolEnvelope.requireConfirmation(object)
        let identifier = try PhoneToolEnvelope.text(object, "id", limit: 256) ?? ""
        let store = EKEventStore()
        guard let reminder = store.calendarItem(withIdentifier: identifier) as? EKReminder else {
            throw PhoneToolError.invalidArguments("未找到提醒事项 id")
        }
        reminder.isCompleted = true
        reminder.completionDate = Date()
        try store.save(reminder, commit: true)
        return PhoneToolPayload(data: [
            "status": "completed", "id": identifier,
            "completionDate": PhoneToolEnvelope.iso8601(reminder.completionDate ?? Date()),
        ])
    }

    public func healthSummary(object: [String: Any]) async throws -> PhoneToolPayload {
        try await PhoneHealthTools().summary(object: object)
    }

    public func healthQuery(object: [String: Any]) async throws -> PhoneToolPayload {
        try await PhoneHealthTools().query(object: object)
    }

    public func photos(object: [String: Any], search: Bool) async throws -> PhoneToolPayload {
        let cursor = try PhoneToolEnvelope.integer(object, "cursor", default: 0, minimum: 0, maximum: 100_000)
        let limit = try PhoneToolEnvelope.integer(object, "limit", default: 20, minimum: 1, maximum: 50)
        let end = try PhoneToolEnvelope.date(object, "to", alias: "end", default: Date())
        let start: Date
        if search {
            start = try PhoneToolEnvelope.date(object, "from", alias: "start",
                                               default: end.addingTimeInterval(-30 * 86400))
            guard end.timeIntervalSince(start) <= 366 * 86400 else {
                throw PhoneToolError.invalidArguments("照片搜索范围不能超过 366 天")
            }
        } else {
            let days = try PhoneToolEnvelope.integer(object, "days", default: 30, minimum: 1, maximum: 30)
            start = end.addingTimeInterval(-TimeInterval(days * 86400))
        }
        guard end > start else { throw PhoneToolError.invalidArguments("照片查询的结束时间必须晚于开始时间") }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate < %@", start as NSDate, end as NSDate)
        if let media = try PhoneToolEnvelope.text(object, "mediaType", required: false, limit: 12) {
            let types = ["image": PHAssetMediaType.image.rawValue, "video": PHAssetMediaType.video.rawValue,
                         "audio": PHAssetMediaType.audio.rawValue]
            guard let value = types[media] else { throw PhoneToolError.invalidArguments("mediaType 仅支持 image/video") }
            options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                options.predicate!, NSPredicate(format: "mediaType = %d", value),
            ])
        }
        let assets = PHAsset.fetchAssets(with: options)
        guard cursor <= assets.count else { throw PhoneToolError.invalidArguments("cursor 超出结果范围") }
        var items: [[String: Any]] = []
        let upper = min(cursor + limit, assets.count)
        if cursor < upper {
            for index in cursor..<upper {
                let asset = assets.object(at: index)
                items.append([
                    "id": asset.localIdentifier,
                    "createdAt": asset.creationDate.map(PhoneToolEnvelope.iso8601) ?? NSNull(),
                    "modifiedAt": asset.modificationDate.map(PhoneToolEnvelope.iso8601) ?? NSNull(),
                    "mediaType": asset.mediaType == .video ? "video" : asset.mediaType == .audio ? "audio" : "image",
                    "isScreenshot": asset.mediaSubtypes.contains(.photoScreenshot),
                    "width": asset.pixelWidth,
                    "height": asset.pixelHeight,
                    "pixelWidth": asset.pixelWidth,
                    "pixelHeight": asset.pixelHeight,
                    "duration": asset.duration,
                    "favorite": asset.isFavorite,
                ])
            }
        }
        let next = cursor + items.count
        return PhoneToolPayload(data: ["items": items, "count": items.count, "total": assets.count],
                                nextCursor: next < assets.count ? next : NSNull(), truncated: next < assets.count)
    }

    private func fetchReminders(_ store: EKEventStore) async throws -> [EKReminder] {
        try await withCheckedThrowingContinuation { continuation in
            store.fetchReminders(matching: store.predicateForReminders(in: nil)) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }
    }

}
