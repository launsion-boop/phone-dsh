// SPDX-License-Identifier: MIT

// BotDeliveryModels: pure view state for the "建议附上" candidates on a
// delivery/approval row. The durable draft revision and approval digest are
// the authority; local toggles never make an old approval reusable.

import CryptoKit
import Foundation
import PhoneDSHBot

// MARK: - Values

struct BotDeliveryParameter: Equatable, Identifiable {
    var id: String { "\(label)=\(value)" }
    var label: String
    var value: String

    static func parseList(_ value: BotJSONValue?) -> [BotDeliveryParameter] {
        guard let values = value?.array else { return [] }
        return values.prefix(8).compactMap { value in
            if let text = value.string {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : BotDeliveryParameter(label: "参数", value: trimmed)
            }
            guard let object = value.object,
                  let label = object.string("label", "name"),
                  let rawValue = object.string("value", "text") else { return nil }
            let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedLabel.isEmpty, !trimmedValue.isEmpty else { return nil }
            return BotDeliveryParameter(label: trimmedLabel, value: trimmedValue)
        }
    }
}

/// One suggested resource. `state` is G-1's current-state set; only `current`
/// can be selected. The source is the same human source value the inspector
/// renders, so "why this file" has one presentation rule.
struct BotDeliveryResource: Equatable, Identifiable {
    var id: String
    var name: String
    var detail: String?
    var reason: String?
    var selected: Bool
    var state: BotProvenanceState
    var stateReason: String?
    var source: BotProvenanceSource?
    var hasMalformedValue = false

    /// G-2 r5: only unreadable/unavailable resources are barred. A changed or
    /// unknown resource stays selectable but is visibly historical/uncertain;
    /// the model or user decides whether the older version fits this task.
    var isSelectable: Bool {
        switch state {
        case .current, .changed, .unknown: return true
        case .unavailable, .revoked, .erased: return false
        }
    }

    var isCurrent: Bool { state == .current }
    var isHistorical: Bool { isSelectable && !isCurrent }

    var stateLabel: String? {
        state == .current ? nil : state.label
    }

    /// A short label that never hides a selectable historical candidate behind
    /// the same wording as a revoked one.
    var selectionNote: String? {
        switch state {
        case .current: return nil
        case .changed: return "历史版本，仍可选择"
        case .unknown: return "时效未知，仍可选择"
        case .unavailable, .revoked, .erased: return "当前不可读，不可选择"
        }
    }

    static func parse(_ value: BotJSONValue, index: Int) -> BotDeliveryResource? {
        guard let object = value.object else { return nil }
        let id = object.string("id", "resourceID", "resource_id") ?? ""
        let name = object.string("name", "fileName", "title") ?? ""
        guard !id.isEmpty, !name.isEmpty else { return nil }
        let state = BotProvenanceState(raw: object["state"]?.string)
        let source = BotProvenanceSource.parseLink(object["source"], index: index)
        return BotDeliveryResource(
            id: id,
            name: name,
            detail: BotProvenanceText.human(object.string("detail", "size", "kindLabel")),
            reason: BotProvenanceText.human(object.string("reason", "why")),
            selected: object["selected"]?.bool == true,
            state: state,
            stateReason: BotProvenanceText.human(
                object.string("state_reason", "stateReason", "state_detail", "stateDetail")),
            source: source)
    }
}

enum BotDeliveryDraftParse: Equatable {
    case absent
    case ready(BotDeliveryDraft)
    case invalid(String)
}

struct BotDeliveryDraft: Equatable {
    var draftID: String
    var revision: Int
    var parameters: [BotDeliveryParameter]
    var resources: [BotDeliveryResource]
    /// A malformed resource list disables selection rather than silently
    /// dropping one candidate; the row remains visible.
    var hasMalformedResources: Bool

    var selectedIDs: Set<String> {
        Set(resources.filter(\.selected).map(\.id))
    }

    var selectableResources: [BotDeliveryResource] {
        resources.filter(\.isSelectable)
    }

    var selectedCount: Int { selectedIDs.count }

    static func parse(row: BotUIRow) -> BotDeliveryDraftParse {
        guard let raw = row.body["delivery"] else { return .absent }
        guard let object = raw.object else { return .invalid("建议资料信息不完整") }
        let draftID = object.string("draft_id", "draftID") ?? ""
        guard !draftID.isEmpty else { return .invalid("建议资料缺少草稿标识") }
        guard let revision = object["revision"]?.int, revision >= 1 else {
            return .invalid("建议资料缺少有效版本")
        }
        let parameters = BotDeliveryParameter.parseList(object["parameters"])
        var malformed = false
        var resources: [BotDeliveryResource] = []
        if let rawResources = object["resources"] {
            guard let values = rawResources.array else { return .invalid("建议资料信息不完整") }
            for (index, value) in values.prefix(10).enumerated() {
                if let resource = BotDeliveryResource.parse(value, index: index) {
                    resources.append(resource)
                } else {
                    malformed = true
                }
            }
        }
        return .ready(BotDeliveryDraft(
            draftID: draftID, revision: revision, parameters: parameters,
            resources: resources, hasMalformedResources: malformed))
    }
}

// MARK: - Approval binding

struct BotDeliveryApprovalBinding: Equatable {
    var approvalID: String
    var digest: String
    var draftRevision: Int?
    var status: String

    static func parse(row: BotUIRow) -> BotDeliveryApprovalBinding? {
        let ask = row.body["ask"]?.object ?? [:]
        guard let approvalID = row.body.string("approvalID", "requestId", "id")
                ?? ask.string("requestId"),
              !approvalID.isEmpty else { return nil }
        let digest = row.body.string("digest", "approval_digest") ?? ""
        let status = row.body["status"]?.string ?? ask["status"]?.string ?? "pending"
        let revision = row.body["delivery"]?.object.flatMap {
            $0["revision"]?.int
        }
        return BotDeliveryApprovalBinding(approvalID: approvalID, digest: digest,
                                          draftRevision: revision, status: status)
    }
}

enum BotDeliveryApprovalAvailability: Equatable {
    case usable
    case blocked(String)
}

enum BotDeliveryApprovalGate {
    /// A missing `delivery` keeps the existing approval behavior. A malformed
    /// delivery or a row without a usable revision blocks the decision: the
    /// UI must not let an old approval stand in for an unknown draft.
    static func availability(row: BotUIRow) -> BotDeliveryApprovalAvailability {
        switch BotDeliveryDraft.parse(row: row) {
        case .absent:
            return .usable
        case .invalid(let reason):
            return .blocked(reason)
        case .ready(let draft):
            guard !draft.hasMalformedResources else {
                return .blocked("建议资料信息不完整，暂时不能确认")
            }
            guard let binding = BotDeliveryApprovalBinding.parse(row: row),
                  let revision = binding.draftRevision, revision == draft.revision else {
                return .blocked("草稿已更新，请查看最新内容")
            }
            guard !binding.digest.isEmpty else {
                return .blocked("这条审批缺少绑定摘要")
            }
            guard binding.digest.hasPrefix("sha256:") else {
                return .blocked("这条审批的绑定摘要格式不正确")
            }
            return .usable
        }
    }
}

// MARK: - Host-side resolution (C adapter calls this)

/// The durable result of one selection submission. The host stores this on the
/// same row (revision + approval digest), then projects it back; nothing here
/// is a second source of truth.
struct BotDeliveryResolvedSelection: Equatable {
    var draftID: String
    var revision: Int
    var digest: String
    var selectedResourceIDs: [String]
    var parameters: [BotDeliveryParameter]
    var resources: [BotDeliveryResource]

    var selectedResources: [BotDeliveryResource] {
        let ids = Set(selectedResourceIDs)
        return resources.filter { ids.contains($0.id) }
    }
}

enum BotDeliverySelectionFailure: Error, Equatable {
    case staleDraft
    case staleRevision
    case unknownResource(String)
    case resourceUnavailable(String)
    case digestMismatch
    case invalidSelection

    /// Stable planner/service code; the UI maps it to human copy.
    var reasonCode: String {
        switch self {
        case .staleDraft: return "draft_changed"
        case .staleRevision: return "draft_revision_mismatch"
        case .unknownResource: return "unknown_resource"
        case .resourceUnavailable: return "resource_unavailable"
        case .digestMismatch: return "digest_mismatch"
        case .invalidSelection: return "invalid_selection"
        }
    }
}

/// Pure host-side resolution for G-2 delivery selection. The C adapter loads
/// the durable draft, resolves each resource's *current* source state, calls
/// `resolve`, then persists the returned revision/digest. Before the actual
/// delivery it calls `confirm` with fresh states; a resource revoked between
/// UI selection and send makes the send fail instead of delivering the old
/// attachment list.
enum BotDeliverySelectionResolver {
    static func resolve(intent: BotDeliverySelectionIntent,
                        draft: BotDeliveryDraft,
                        currentStates: [String: BotProvenanceState] = [:]) throws
        -> BotDeliveryResolvedSelection {
        guard intent.draftID == draft.draftID else { throw BotDeliverySelectionFailure.staleDraft }
        guard intent.expectedRevision == draft.revision else {
            throw BotDeliverySelectionFailure.staleRevision
        }
        let selected = Array(Set(intent.selectedResourceIDs)).sorted()
        guard selected.count == intent.selectedResourceIDs.count else {
            throw BotDeliverySelectionFailure.invalidSelection
        }
        var revalidated: [BotDeliveryResource] = []
        let selectedSet = Set(selected)
        for resource in draft.resources {
            var next = resource
            if let state = currentStates[resource.id] { next.state = state }
            next.selected = selectedSet.contains(resource.id)
            revalidated.append(next)
        }
        for id in selected {
            guard let resource = revalidated.first(where: { $0.id == id }) else {
                throw BotDeliverySelectionFailure.unknownResource(id)
            }
            guard resource.isSelectable else {
                throw BotDeliverySelectionFailure.resourceUnavailable(id)
            }
        }
        let revision = draft.revision + 1
        let digest = approvalDigest(draftID: draft.draftID, revision: revision,
                                    selectedResourceIDs: selected,
                                    parameters: draft.parameters)
        return BotDeliveryResolvedSelection(
            draftID: draft.draftID, revision: revision, digest: digest,
            selectedResourceIDs: selected, parameters: draft.parameters,
            resources: revalidated)
    }

    /// Rechecks the already-resolved selection immediately before the side
    /// effect. Any unreadable/revoked/erased resource blocks the delivery.
    static func confirm(_ selection: BotDeliveryResolvedSelection,
                        currentStates: [String: BotProvenanceState]) throws {
        let expected = approvalDigest(draftID: selection.draftID,
                                      revision: selection.revision,
                                      selectedResourceIDs: selection.selectedResourceIDs,
                                      parameters: selection.parameters)
        guard expected == selection.digest else {
            throw BotDeliverySelectionFailure.digestMismatch
        }
        for id in selection.selectedResourceIDs {
            guard let resource = selection.resources.first(where: { $0.id == id }) else {
                throw BotDeliverySelectionFailure.unknownResource(id)
            }
            let state = currentStates[id] ?? resource.state
            switch state {
            case .current, .changed, .unknown: continue
            case .unavailable, .revoked, .erased:
                throw BotDeliverySelectionFailure.resourceUnavailable(id)
            }
        }
    }

    /// G-2 formula: sha256 of the compact UTF-8 JSON array
    /// `[draft_id, revision, sorted(selected ids), parameters sorted by label]`.
    static func approvalDigest(draftID: String, revision: Int,
                               selectedResourceIDs: [String],
                               parameters: [BotDeliveryParameter]) -> String {
        let sortedParameters = parameters
            .sorted { $0.label < $1.label }
            .map { ["label": $0.label, "value": $0.value] }
        let object: [Any] = [draftID, revision, selectedResourceIDs.sorted(), sortedParameters]
        let data = (try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return "sha256:" + digest
    }
}

// MARK: - Local selection session

enum BotDeliverySelectionPhase: Equatable {
    case idle
    case submitting
    case awaitingDurable
    case failed(String)
}

struct BotDeliverySelectionIntent: Equatable {
    /// Stable across retries of the same submitted selection; the host uses it
    /// for idempotency. A changed working set gets a new nonce.
    var nonce: String
    var rowID: String
    var botID: String
    var draftID: String
    var expectedRevision: Int
    var selectedResourceIDs: [String]
}

/// One row's local selection state. It is re-created/refreshed from the durable
/// row; it never carries a second durable truth.
struct BotDeliverySelectionSession: Equatable {
    var rowID: String
    var botID: String
    private(set) var draft: BotDeliveryDraft
    private(set) var working: Set<String>
    private(set) var phase: BotDeliverySelectionPhase = .idle
    private var pendingNonce: String?
    private var pendingSelection: Set<String>?
    /// The revision the local view has confirmed with the host. A submitted
    /// change keeps `working` dirty until a row with a larger revision lands.
    private(set) var committedRevision: Int
    private(set) var committedSelected: Set<String>

    init(row: BotUIRow, draft: BotDeliveryDraft) {
        rowID = row.id
        botID = row.botID
        self.draft = draft
        working = draft.selectedIDs
        committedRevision = draft.revision
        committedSelected = draft.selectedIDs
    }

    var hasChanges: Bool {
        // A previously attached resource that became invalid is also a
        // change: the old approval digest still covers it and must not be
        // reused. `eligibleCommitted` drops it, so compare the raw committed
        // set against the eligible working set as well.
        eligibleWorking != eligibleCommitted || committedInvalidCount > 0
    }

    /// Only selectable resources can be part of a submission. A durable
    /// selection that became revoked is dropped from the intent; the UI says
    /// so instead of silently re-attaching it.
    var eligibleWorking: Set<String> {
        working.filter { id in
            draft.resources.first(where: { $0.id == id })?.isSelectable == true
        }
    }

    var eligibleCommitted: Set<String> {
        committedSelected.filter { id in
            draft.resources.first(where: { $0.id == id })?.isSelectable == true
        }
    }

    var droppedInvalidCount: Int {
        working.subtracting(eligibleWorking).count
    }

    /// The durable selection itself still contains a resource that is no
    /// longer attachable; its old approval digest must be re-bound even after
    /// the user removes the row locally.
    var committedInvalidCount: Int {
        committedSelected.subtracting(eligibleCommitted).count
    }

    var selectedCount: Int { eligibleWorking.count }

    var canEdit: Bool {
        switch phase {
        case .idle, .failed: return !draft.hasMalformedResources
        case .submitting, .awaitingDurable: return false
        }
    }

    func isSelected(_ id: String) -> Bool { working.contains(id) }

    enum ResourceAvailability: Equatable {
        case selectable
        case blocked(String)
    }

    func availability(for resourceID: String) -> ResourceAvailability {
        guard let resource = draft.resources.first(where: { $0.id == resourceID }) else {
            return .blocked("这项资料已不可用")
        }
        guard !draft.hasMalformedResources else {
            return .blocked("建议资料信息不完整，暂时不能选择")
        }
        guard resource.isSelectable else {
            return .blocked(resource.stateReason ?? resource.state.label)
        }
        switch phase {
        case .idle, .failed: return .selectable
        case .submitting: return .blocked("正在更新选择")
        case .awaitingDurable: return .blocked("正在等待草稿更新")
        }
    }

    /// Returns true when the working selection changed. A blocked resource
    /// keeps its state; the caller renders the reason from `availability`.
    @discardableResult
    mutating func toggle(_ resourceID: String) -> Bool {
        guard canEdit, availability(for: resourceID) == .selectable else { return false }
        if working.contains(resourceID) {
            working.remove(resourceID)
        } else {
            working.insert(resourceID)
        }
        pendingNonce = nil
        pendingSelection = nil
        if case .failed = phase { phase = .idle }
        return true
    }

    mutating func resetWorking() {
        guard canEdit else { return }
        working = eligibleCommitted
        pendingNonce = nil
        pendingSelection = nil
        if case .failed = phase { phase = .idle }
    }

    /// Starts one idempotent submission. Returns nil when nothing changed or
    /// the session cannot submit.
    mutating func beginSubmit() -> BotDeliverySelectionIntent? {
        guard canEdit, hasChanges else { return nil }
        if let pendingNonce, let pendingSelection, pendingSelection == eligibleWorking {
            phase = .submitting
            return BotDeliverySelectionIntent(
                nonce: pendingNonce, rowID: rowID, botID: botID, draftID: draft.draftID,
                expectedRevision: committedRevision,
                selectedResourceIDs: orderedSelection(eligibleWorking))
        }
        let nonce = UUID().uuidString
        pendingNonce = nonce
        pendingSelection = eligibleWorking
        phase = .submitting
        return BotDeliverySelectionIntent(
            nonce: nonce, rowID: rowID, botID: botID, draftID: draft.draftID,
            expectedRevision: committedRevision,
            selectedResourceIDs: orderedSelection(eligibleWorking))
    }

    /// The host accepted the selection intent. The durable row will carry the
    /// next revision; until it lands, the approval stays blocked.
    mutating func markAccepted() {
        phase = .awaitingDurable
    }

    mutating func markFailed(_ reason: String) {
        phase = .failed(reason)
    }

    /// Applies a newer durable row. A stale row is ignored. A row with the same
    /// revision cannot clear an awaiting-due-to-accepted state unless its
    /// selection exactly matches the submitted one (a no-op host answer).
    @discardableResult
    mutating func applyDurable(_ next: BotDeliveryDraft) -> Bool {
        guard next.draftID == draft.draftID else { return false }
        guard next.revision >= committedRevision else { return false }
        if next.revision == committedRevision {
            if case .awaitingDurable = phase, next.selectedIDs == working {
                phase = .idle
                return true
            }
            return false
        }
        draft = next
        committedRevision = next.revision
        committedSelected = next.selectedIDs
        working = next.selectedIDs
        pendingNonce = nil
        pendingSelection = nil
        phase = .idle
        return true
    }

    /// The approval buttons may only act on the durable revision. While the
    /// local selection differs from the committed one, the old digest is not
    /// reusable.
    func approvalAvailability(binding: BotDeliveryApprovalBinding?) -> BotDeliveryApprovalAvailability {
        guard let binding else {
            return .blocked("这条审批没有可用的绑定信息")
        }
        guard binding.status == "pending" else {
            return .blocked("这条审批已经处理")
        }
        guard !binding.digest.isEmpty else {
            return .blocked("这条审批缺少绑定摘要")
        }
        if binding.draftRevision != nil, !binding.digest.hasPrefix("sha256:") {
            return .blocked("这条审批的绑定摘要格式不正确")
        }
        guard binding.draftRevision == committedRevision else {
            return .blocked("草稿已更新，请查看最新内容")
        }
        switch phase {
        case .submitting:
            return .blocked("正在更新选择，更新后才能确认")
        case .awaitingDurable:
            return .blocked("正在更新草稿，完成后才能确认")
        case .failed:
            return .blocked("选择没有更新成功，请重试或撤销改动")
        case .idle:
            break
        }
        if hasChanges {
            return .blocked("选择已改变，需要重新确认")
        }
        if draft.hasMalformedResources {
            return .blocked("建议资料信息不完整，暂时不能确认")
        }
        return .usable
    }

    private func orderedSelection(_ selection: Set<String>) -> [String] {
        draft.resources.map(\.id).filter { selection.contains($0) }
    }

    var summary: String {
        "已选 \(selectedCount)／\(draft.resources.count) 项"
    }

    var hint: String? {
        if draft.hasMalformedResources { return "建议资料信息不完整，暂时不能选择" }
        if droppedInvalidCount > 0 { return "有 \(droppedInvalidCount) 项资料已失效，将从附上中移除" }
        if hasChanges { return "改动后需要重新确认，旧审批不能继续使用" }
        if case .failed = phase { return "选择没有更新成功，可以重试或撤销改动" }
        return nil
    }
}
