// SPDX-License-Identifier: MIT

#if canImport(Contacts)
import Contacts
import Foundation

/// Contacts source. It never enumerates the address book on subscribe and never
/// copies a full contact record: the only data path is an explicit, bounded
/// query (or a user-supplied identifier) that returns masked contact fields.
public final class ContactsSource: BotContextSource, BotContextSourceStreaming,
                                   BotContextSourceRequesting, BotContextSourceDiagnosing,
                                   BotContextContactsQuerying, BotContextSourceRechecking,
                                   @unchecked Sendable {
    public let kind: BotContextSourceKind = .contacts
    private let lock = NSLock()
    private let buffer = BotContextSourceBuffer()
    private let now: @Sendable () -> Int64
    private var observer: NSObjectProtocol?
    private var activeRevision: Int?
    private var emit: (@Sendable (BotContextObservation) -> Void)?

    public init(now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }) {
        self.now = now
    }

    public func authorization() async -> BotSourceAuthorization {
        let status = CNContactStore.authorizationStatus(for: .contacts)
#if os(iOS)
        if #available(iOS 18.0, *), status == .limited { return .limited }
#endif
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorized: return .authorized
        @unknown default: return .notDetermined
        }
    }

    public func authorizationDiagnostic() async -> String? {
        String(CNContactStore.authorizationStatus(for: .contacts).rawValue)
    }

    public func requestAuthorization() async -> BotSourceAuthorization {
        let current = await authorization()
        // An existing OS decision needs no second TCC prompt. Re-requesting a
        // granted service is invalid on some simulator builds and left App
        // consent unset; only notDetermined may request.
        switch current {
        case .authorized, .limited, .denied, .restricted, .revoked:
            return current
        case .notDetermined:
            break
        }
        let store = CNContactStore()
        _ = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            store.requestAccess(for: .contacts) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
        return await authorization()
    }

    public func start(permissionRevision: Int,
                      emit: @escaping @Sendable (BotContextObservation) -> Void) async throws {
        guard (await authorization()).allowsReading else {
            throw BotContextSourceError.unsupported("contacts access is not authorized")
        }
        lock.lock()
        activeRevision = permissionRevision
        self.emit = emit
        lock.unlock()
        let added = NotificationCenter.default.addObserver(
            forName: .CNContactStoreDidChange, object: nil, queue: nil) { [weak self] _ in
                self?.handleStoreChanged()
            }
        lock.lock()
        observer = added
        lock.unlock()
    }

    public func stop() async {
        lock.lock()
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
        activeRevision = nil
        emit = nil
        buffer.clear()
        lock.unlock()
    }

    public func observations(since: Int64?) async throws -> [BotContextObservation] {
        buffer.observations(since: since)
    }

    /// Bounded query. The predicate is required; an empty/wildcard query is
    /// rejected so this API can never enumerate the whole address book.
    public func contactsObservation(query: String, limit: Int) async throws -> BotContextObservation {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized != "*", normalized.unicodeScalars.count <= 200 else {
            throw BotContextSourceError.invalidRequest("contacts query must be a bounded, non-empty name or email")
        }
        guard (await authorization()).allowsReading else {
            throw BotContextSourceError.notAuthorized(.contacts, permissionRevision: activeRevisionOrZero())
        }
        lock.lock()
        let revision = activeRevision
        lock.unlock()
        guard let revision else { throw BotContextSourceError.revoked(.contacts) }

        let store = CNContactStore()
        let request = CNContactFetchRequest(keysToFetch: Self.keys)
        request.predicate = normalized.contains("@")
            ? CNContact.predicateForContacts(matchingEmailAddress: normalized)
            : CNContact.predicateForContacts(matchingName: normalized)
        var contacts: [CNContact] = []
        try store.enumerateContacts(with: request) { contact, stop in
            contacts.append(contact)
            if contacts.count >= min(max(1, limit), 20) { stop.pointee = true }
        }
        let items = contacts.prefix(min(max(1, limit), 20)).map { contact -> BotJSONValue in
            .object([
                "id": .string(String(contact.identifier.prefix(200))),
                "name": .string(Self.name(contact)),
                "organization": .string(String(contact.organizationName.prefix(200))),
                "emails": .array(contact.emailAddresses.map {
                    .string(Self.maskEmail($0.value as String))
                }),
                "phones": .array(contact.phoneNumbers.map {
                    .string(Self.maskPhone($0.value.stringValue))
                }),
                "masked": .bool(true),
            ])
        }
        let stamp = now()
        return try BotContextObservation(
            id: "contacts:query:\(Self.fingerprint(normalized)):\(stamp)",
            source: .contacts,
            kind: .contactsChanged,
            observedAt: stamp,
            permissionRevision: revision,
            sourceVersion: .unversioned(),
            uncertainty: BotContextUncertainty(
                level: .medium,
                reason: "contact-store-can-change-after-query",
                completeness: contacts.count >= min(max(1, limit), 20) ? .partial : .complete),
            delivery: .os,
            payload: .object([
                "query": .string(normalized),
                "count": .number(Double(contacts.count)),
                "items": .array(items),
            ]),
            dedupeKey: "contacts:query:\(Self.fingerprint(normalized))",
            wakeRequested: false,
            resource: try? BotContextResource(
                kind: .contextSource, key: "contacts:\(Self.fingerprint(normalized))"))
    }

    /// Real r5 recheck of the OS permission. Contacts has no per-contact
    /// version and a query is only run on explicit request, so the producer
    /// reports `refresh-not-performed` rather than inventing a version.
    public func recheck(permissionRevision: Int,
                        baseline: BotContextSourceVersion?,
                        latestKind: BotContextObservationKind?) async -> BotContextRecheckProbe {
        lock.lock()
        let revision = activeRevision
        lock.unlock()
        guard revision == permissionRevision else { return .denied("revoked-generation") }
        guard (await authorization()).allowsReading else { return .denied("contacts-not-authorized") }
        return .notPerformed("contacts-requires-explicit-query")
    }

    private func handleStoreChanged() {
        lock.lock()
        let revision = activeRevision
        let sink = emit
        lock.unlock()
        guard let revision, let sink else { return }
        let stamp = now()
        guard let observation = try? BotContextObservation(
            id: "contacts:changed:\(stamp)",
            source: .contacts,
            kind: .contactsChanged,
            observedAt: stamp,
            permissionRevision: revision,
            sourceVersion: .unversioned(),
            uncertainty: BotContextUncertainty(
                level: .high,
                reason: "contacts-change-notification-cannot-name-changed-contacts",
                completeness: .partial),
            delivery: .os,
            payload: .object(["changed": .bool(true)]),
            dedupeKey: "contacts:changed:\(stamp / 60_000)",
            wakeRequested: true,
            resource: try? BotContextResource(
                kind: .contextSource, key: "contacts:store")) else { return }
        buffer.append(observation)
        sink(observation)
    }

    private func activeRevisionOrZero() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return activeRevision ?? 0
    }

    private static var keys: [CNKeyDescriptor] {
        [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
        ]
    }

    private static func name(_ contact: CNContact) -> String {
        "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)
    }

    private static func maskEmail(_ value: String) -> String {
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, let first = parts[0].first else { return "***" }
        return "\(first)***@\(parts[1])"
    }

    private static func maskPhone(_ value: String) -> String {
        let digits = value.filter(\.isNumber)
        guard digits.count >= 4 else { return "***" }
        return "***\(digits.suffix(4))"
    }

    private static func fingerprint(_ text: String) -> String {
        var hash: UInt64 = 1469598103934665603
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        return String(format: "%016lx", hash)
    }
}
#endif
