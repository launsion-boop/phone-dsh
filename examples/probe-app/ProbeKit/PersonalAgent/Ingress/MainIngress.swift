// SPDX-License-Identifier: MIT

import Foundation

public actor SourceEnvelopeStore {
    private let fileURL: URL
    private var envelopes: [UUID: SourceEnvelope]

    public init(root: URL) throws {
        fileURL = root.appendingPathComponent("ing/envelopes.json")
        envelopes = try S4Persistence.load([UUID: SourceEnvelope].self, from: fileURL) ?? [:]
    }

    public func persist(_ envelope: SourceEnvelope) throws -> Bool {
        if envelopes[envelope.requestID] != nil { return false }
        var updated = envelopes
        updated[envelope.requestID] = envelope
        try S4Persistence.save(updated, to: fileURL)
        envelopes = updated
        return true
    }

    public func envelope(requestID: UUID) -> SourceEnvelope? {
        envelopes[requestID]
    }

    public func count() -> Int {
        envelopes.count
    }
}

public struct MainIngressResult: Sendable {
    public let envelope: SourceEnvelope
    public let mandate: WorkMandate
    public let duplicate: Bool
    public let connectorContent: String?

    public init(envelope: SourceEnvelope, mandate: WorkMandate, duplicate: Bool, connectorContent: String? = nil) {
        self.envelope = envelope
        self.mandate = mandate
        self.duplicate = duplicate
        self.connectorContent = connectorContent
    }
}

public enum MainIngressError: Error, Equatable {
    case envelopeConflict(UUID)
    case unsupportedSource(SourceKind)
}

public actor MainIngress {
    private let envelopes: SourceEnvelopeStore
    private let mandates: MandateStore
    private let factory: RuleBasedMandateFactory
    private let now: @Sendable () -> Date

    public init(envelopes: SourceEnvelopeStore, mandates: MandateStore,
                factory: RuleBasedMandateFactory = RuleBasedMandateFactory(),
                now: @escaping @Sendable () -> Date = Date.init) {
        self.envelopes = envelopes
        self.mandates = mandates
        self.factory = factory
        self.now = now
    }

    public init(root: URL, factory: RuleBasedMandateFactory = RuleBasedMandateFactory(),
                now: @escaping @Sendable () -> Date = Date.init) throws {
        try self.init(envelopes: SourceEnvelopeStore(root: root), mandates: MandateStore(root: root),
                      factory: factory, now: now)
    }

    public func ingest(envelope: SourceEnvelope, userText: String) async throws -> MainIngressResult {
        try await ingest(envelope: envelope, userText: userText, connectorContent: nil)
    }

    public func ingest(envelope: SourceEnvelope, userText: String,
                       connectorContent loadConnectorContent: (@Sendable () async throws -> String)? = nil)
        async throws -> MainIngressResult {
        guard envelope.source == .phone || envelope.source == .device else {
            throw MainIngressError.unsupportedSource(envelope.source)
        }
        let isNew = try await envelopes.persist(envelope)
        if !isNew, await envelopes.envelope(requestID: envelope.requestID) != envelope {
            throw MainIngressError.envelopeConflict(envelope.requestID)
        }
        let mandate: WorkMandate
        if let existing = await mandates.mandate(for: envelope.requestID) {
            mandate = existing
        } else {
            mandate = try await mandates.issue(
                envelope: envelope, draft: factory.draft(userText: userText, now: now()))
        }
        guard isNew else {
            return MainIngressResult(envelope: envelope, mandate: mandate, duplicate: true)
        }
        let content = try await loadConnectorContent?()
        return MainIngressResult(envelope: envelope, mandate: mandate, duplicate: false, connectorContent: content)
    }

    public func ingestSelection(envelope: SourceEnvelope, selection: SuggestionSelection) async throws -> MainIngressResult {
        guard envelope.source == .phone, envelope.principal == selection.principal else {
            throw MainIngressError.unsupportedSource(envelope.source)
        }
        let isNew = try await envelopes.persist(envelope)
        if !isNew, await envelopes.envelope(requestID: envelope.requestID) != envelope {
            throw MainIngressError.envelopeConflict(envelope.requestID)
        }
        if let existing = await mandates.mandate(for: envelope.requestID) {
            return MainIngressResult(envelope: envelope, mandate: existing, duplicate: true)
        }
        let original = selection.originalMandate
        let draft = MandateDraft(
            goal: selection.visibleLabel ?? "Selected suggestion",
            allowedActions: original?.allowedActions ?? [.read],
            allowedEvidenceRefs: original?.allowedEvidenceRefs ?? [],
            targets: original?.targets ?? MandateTargets(origin: .userNamed),
            validUntil: min(original?.validUntil ?? now().addingTimeInterval(factory.validityInterval),
                            now().addingTimeInterval(factory.validityInterval)))
        let mandate = try await mandates.issue(envelope: envelope, draft: draft)
        return MainIngressResult(envelope: envelope, mandate: mandate, duplicate: false)
    }

    public func mandate(for requestID: UUID) async -> WorkMandate? {
        await mandates.mandate(for: requestID)
    }

    public func selectTargets(previous: WorkMandate, envelope: SourceEnvelope,
                              targets: MandateTargets, validUntil: Date? = nil) async throws -> WorkMandate {
        guard targets.origin == .uiSelected else { throw MandateStoreError.invalidVersion }
        let draft = MandateDraft(goal: previous.goal, allowedActions: previous.allowedActions,
                                 allowedEvidenceRefs: previous.allowedEvidenceRefs, targets: targets,
                                 validUntil: validUntil ?? previous.validUntil)
        return try await mandates.revise(previous: previous, envelope: envelope, draft: draft)
    }
}
