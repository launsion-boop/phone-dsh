// SPDX-License-Identifier: MIT

// Eval-harness seam for A04 delivery selection. The E runner drives the same
// production row service the App uses; this file only adapts one plan action to
// `BotDeliverySelectionHost`. It is not a second store or a test-only state
// machine: every mutation goes through the host's durable revision/CAS path.

import Foundation
import PhoneDSHBot

struct BotDeliverySelectionHarnessAction: Decodable, Sendable {
    var nonce: String?
    var bot: String?
    var rowID: String?
    var approvalID: String?
    var draftID: String?
    var expectedRevision: Int?
    var selectedResourceIDs: [String]?
    /// `first` (default), `last`, `all`, `none`. Ignored when explicit ids
    /// are supplied.
    var select: String?

    enum CodingKeys: String, CodingKey {
        case nonce, bot, select
        case rowID = "row_id"
        case approvalID = "approval_id"
        case draftID = "draft_id"
        case expectedRevision = "expected_revision"
        case selectedResourceIDs = "selected_resource_ids"
    }
}

struct BotDeliverySelectionHarnessOutcome: Encodable, Sendable {
    struct Selected: Encodable, Sendable {
        var id: String
        var name: String
        var path: String?
        var sourceRef: String
    }

    var status: String
    var reason: String? = nil
    var eventID: String? = nil
    var approvalID: String? = nil
    var rowID: String? = nil
    var draftID: String? = nil
    var revision: Int? = nil
    var digest: String? = nil
    var selected: [Selected] = []

    enum CodingKeys: String, CodingKey {
        case status, reason, revision, digest, selected
        case eventID = "event_id"
        case approvalID = "approval_id"
        case rowID = "row_id"
        case draftID = "draft_id"
    }
}

extension BotProductionRowService {
    /// One plan action: choose resources for the newest (or named) delivery
    /// draft, persist the next revision/digest, and return the durable ids.
    func applyDeliverySelectionHarness(
        _ action: BotDeliverySelectionHarnessAction
    ) async -> BotDeliverySelectionHarnessOutcome {
        guard let host = deliverySelection else {
            return .init(status: "unavailable", reason: "delivery_selection_unavailable",
                         selected: [])
        }
        let botID = action.bot ?? "main"
        let draft: BotDeliverySelectionDraft?
        do {
            if let rowID = action.rowID, !rowID.isEmpty {
                draft = try await host.draft(botID: botID, rowID: rowID)
            } else if let approvalID = action.approvalID, !approvalID.isEmpty {
                draft = try await host.draft(approvalID: approvalID, botID: botID)
            } else {
                draft = try await host.drafts(botID: botID).first
            }
        } catch {
            return .init(status: "unavailable", reason: "delivery_selection_storage_failed",
                         selected: [])
        }
        guard let draft else {
            return .init(status: "unavailable", reason: "unknown_row", selected: [])
        }
        if let expected = action.draftID, !expected.isEmpty, expected != draft.draftID {
            return .init(status: "stale", reason: "draft_changed",
                         approvalID: draft.approvalID,
                         rowID: draft.rowID, draftID: draft.draftID,
                         revision: draft.revision, digest: draft.digest,
                         selected: [])
        }
        let chosen: [String]
        if let explicit = action.selectedResourceIDs, !explicit.isEmpty {
            chosen = explicit
        } else {
            switch (action.select ?? "first").lowercased() {
            case "none": chosen = []
            case "all": chosen = draft.resources.map(\.id)
            case "last": chosen = draft.resources.last.map { [$0.id] } ?? []
            default: chosen = draft.resources.first.map { [$0.id] } ?? []
            }
        }
        do {
            let result = try await host.apply(BotDeliverySelectionSubmission(
                nonce: action.nonce?.isEmpty == false
                    ? action.nonce! : UUID().uuidString.lowercased(),
                botID: botID, rowID: draft.rowID, draftID: draft.draftID,
                expectedRevision: action.expectedRevision ?? draft.revision,
                selectedResourceIDs: chosen))
            switch result {
            case .accepted(let eventID, let next):
                return Self.outcome(status: "accepted", eventID: eventID, draft: next)
            case .duplicate(let eventID, let next):
                return Self.outcome(status: "duplicate", eventID: eventID, draft: next)
            case .stale(let reason):
                return .init(status: "stale", reason: reason,
                             approvalID: draft.approvalID,
                             rowID: draft.rowID, draftID: draft.draftID,
                             revision: draft.revision, digest: draft.digest,
                             selected: [])
            case .rejected(let reason):
                return .init(status: "rejected", reason: reason,
                             approvalID: draft.approvalID,
                             rowID: draft.rowID, draftID: draft.draftID,
                             revision: draft.revision, digest: draft.digest,
                             selected: [])
            }
        } catch let failure as PhoneDSHBot.BotDeliverySelectionFailure {
            return .init(status: "stale", reason: failure.code,
                         approvalID: draft.approvalID,
                         rowID: draft.rowID, draftID: draft.draftID,
                         revision: draft.revision, digest: draft.digest,
                         selected: [])
        } catch {
            return .init(status: "rejected", reason: "delivery_selection_failed",
                         approvalID: draft.approvalID,
                         rowID: draft.rowID, draftID: draft.draftID,
                         revision: draft.revision, digest: draft.digest,
                         selected: [])
        }
    }

    private static func outcome(status: String, eventID: String,
                                draft: BotDeliverySelectionDraft)
        -> BotDeliverySelectionHarnessOutcome {
        .init(status: status, reason: nil, eventID: eventID,
              approvalID: draft.approvalID,
              rowID: draft.rowID, draftID: draft.draftID,
              revision: draft.revision, digest: draft.digest,
              selected: draft.selectedResources.map {
                  .init(id: $0.id, name: $0.name,
                        path: $0.workspacePath, sourceRef: $0.source.ref)
              })
    }
}
