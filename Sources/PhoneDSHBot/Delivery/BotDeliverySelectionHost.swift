// SPDX-License-Identifier: MIT

// Durable host state machine for G-2 delivery selection.
//
// Producer: an approval row is built from the real pre-delivery material block.
// Only workspace-ref materials are candidates, because only those have a real
// host path the final attachment call can name.
//
// Persistence: the same `approval.requested` event is re-emitted with the same
// approval id/row id, a monotonically increasing revision and the new digest.
// The existing row projector therefore updates the same approval row; no new
// durable type, row store or schema is introduced.
//
// Consumer: the MCP runtime asks `confirm` immediately before a delivery tool
// runs. A changed/revoked/unselected source is refused; the runtime must not
// rewrite the model's arguments.

import CryptoKit
import Foundation

public actor BotDeliverySelectionHost {
    public typealias WorkspaceStateResolver =
        @Sendable (_ ref: String, _ botID: String) async -> BotDeliveryWorkspaceState

    private struct LoadedDraft {
        var draft: BotDeliverySelectionDraft
        var event: BotEvent
    }

    /// A durable approval row that claims to carry a delivery block but cannot
    /// be parsed. It must block delivery for that Bot/session; silently
    /// dropping it would turn a corrupt selection into "no restriction".
    private struct MalformedDelivery {
        var botID: String
        var sessionID: String
        var rowID: String
        var approvalID: String
        var reason: String
    }

    private let eventLog: any BotEventLog
    private let workspaceState: WorkspaceStateResolver?
    private let now: @Sendable () -> Int64
    private var bridge: BotDeliveryApprovalBridge?

    public init(eventLog: any BotEventLog,
                workspaceState: WorkspaceStateResolver? = nil,
                now: @escaping @Sendable () -> Int64 = {
                    Int64(Date().timeIntervalSince1970 * 1_000)
                }) {
        self.eventLog = eventLog
        self.workspaceState = workspaceState
        self.now = now
    }

    /// Runtime installs the coordinator bridge once; a nil bridge keeps the
    /// host usable for producer/read-model tests but refuses to mutate a live
    /// approval (`approval_not_pending`).
    public func installApprovalBridge(_ bridge: BotDeliveryApprovalBridge?) {
        self.bridge = bridge
    }

    /// The production workspace recheck: read the file again and compare its
    /// content digest with the digest embedded in the `workspace:` ref. C
    /// composition builds one host from this resolver; D never invents a
    /// workspace version.
    public static func workspaceStateResolver(
        workspace: WorkspaceDecisionContextService
    ) -> WorkspaceStateResolver {
        { ref, botID in
            guard let expected = WorkspaceDecisionContextService.workspaceDigest(
                fromRef: ref) else { return .unknown() }
            guard let current = await workspace.currentContentSHA256(
                forWorkspaceRef: ref, botID: botID) else { return .unavailable() }
            let version = BotProvenanceSourceVersion.known(
                basis: .contentSHA256, value: current,
                observedAtMS: nil, subject: .fileBytes)
            if current == expected {
                return BotDeliveryWorkspaceState(
                    state: .current, currentVersion: version)
            }
            return .changed(version)
        }
    }

    // MARK: - Producer

    /// Build the delivery block for one approval row from the real pre-delivery
    /// material block. Returns nil when no workspace material is available, so
    /// ordinary approvals keep their previous shape.
    public func offer(approvalID: String, botID: String, sessionID: String,
                      action: String, detail: String, command: String,
                      materials: [BotDecisionMaterial],
                      turnID: String? = nil, goalDigest: String? = nil,
                      nowMS: Int64? = nil) async -> BotDeliverySelectionOffer? {
        let timestamp = nowMS ?? now()
        var seen = Set<String>()
        var resources: [BotDeliverySelectionResource] = []
        for material in materials {
            guard material.ref.hasPrefix("workspace:"),
                  let path = WorkspaceDecisionContextService.workspacePath(fromRef: material.ref),
                  seen.insert(material.ref).inserted else { continue }
            if resources.count >= 8 { break }
            let state = await recheck(material.ref, botID: botID)
            let name = String((path as NSString).lastPathComponent.prefix(200))
            let reason = Self.selectionReason(material.selectionReason)
            let source = BotDeliverySelectionSource(
                ref: material.ref,
                label: name.isEmpty ? "工作区文件" : name,
                kind: "file",
                trust: "observation",
                state: state.state,
                reason: reason,
                stateDetail: state.note,
                observedAtMS: material.updatedAtMS > 0 ? material.updatedAtMS : nil,
                versionLabel: Self.versionLabel(material.updatedAtMS),
                sourceVersion: Self.selectedVersion(ref: material.ref,
                                                    observedAtMS: material.updatedAtMS))
            resources.append(BotDeliverySelectionResource(
                id: "r\(resources.count + 1)",
                name: name.isEmpty ? "工作区文件" : name,
                reason: reason,
                selected: false,
                state: state.state,
                stateReason: state.note,
                source: source))
        }
        guard !resources.isEmpty else { return nil }
        let binding: BotDeliverySelectionBinding?
        if let turnID {
            guard BotDeliverySelectionBinding.validTurnID(turnID) else { return nil }
            binding = BotDeliverySelectionBinding(
                approvalID: approvalID, turnID: turnID, goalDigest: goalDigest)
        } else {
            binding = nil
        }
        let parameters = Self.parameters(action: action, detail: detail)
        let draftID = Self.draftID(approvalID: approvalID)
        let draft = BotDeliverySelectionDraft(
            botID: botID, sessionID: sessionID, approvalID: approvalID,
            rowID: "e-\(botID)-approval-\(approvalID)",
            draftID: draftID, revision: 1, status: "pending",
            parameters: parameters, resources: resources,
            binding: binding,
            digest: BotDeliverySelectionDigest.approvalDigest(
                draftID: draftID, revision: 1, selectedResourceIDs: [],
                parameters: parameters),
            requestedAtMS: timestamp, expiresAtMS: nil, persistent: false,
            requestSeq: 0)
        return BotDeliverySelectionOffer(draft: draft)
    }

    /// The initial approval event data the coordinator/runtime stores. Keeping
    /// this next to `offer` means producer and consumer cannot disagree about
    /// the row fields.
    public func approvalEventData(offer: BotDeliverySelectionOffer,
                                  action: String, detail: String, command: String,
                                  alwaysScope: String, deferConsumption: Bool,
                                  effects: [BotToolEffect], persistent: Bool,
                                  kind: String, origin: String, requestedAtMS: Int64,
                                  expiresAtMS: Int64?) -> BotJSONValue {
        var data: [String: BotJSONValue] = [
            "approvalID": .string(offer.draft.approvalID),
            "status": .string("pending"),
            "action": .string(action),
            "detail": .string(detail),
            "command": .string(command),
            "digest": .string(offer.draft.digest),
            "alwaysScope": .string(alwaysScope),
            "deferConsumption": .bool(deferConsumption),
            "effects": .array(effects.map(Self.effectJSON)),
            "persistent": .bool(persistent),
            "kind": .string(kind),
            "origin": .string(origin),
            "requestedAt": .number(Double(requestedAtMS)),
            "delivery": offer.deliveryJSON,
        ]
        if let expiresAtMS { data["expiresAt"] = .number(Double(expiresAtMS)) }
        return .object(data)
    }

    // MARK: - Read model

    public func draft(botID: String, rowID: String) async throws -> BotDeliverySelectionDraft? {
        try await scan(botID: botID).drafts
            .first(where: { $0.draft.rowID == rowID })
            .map(\.draft)
    }

    public func draft(approvalID: String, botID: String) async throws
        -> BotDeliverySelectionDraft? {
        try await scan(botID: botID).drafts
            .first(where: { $0.draft.approvalID == approvalID })
            .map(\.draft)
    }

    /// Every approval draft for one Bot, newest first. Used by tests/history;
    /// the row projection still comes from the shared row projector.
    public func drafts(botID: String) async throws -> [BotDeliverySelectionDraft] {
        try await scan(botID: botID).drafts.map(\.draft)
    }

    // MARK: - Selection submit

    public func apply(_ submission: BotDeliverySelectionSubmission,
                      nowMS: Int64? = nil) async throws -> BotDeliverySelectionApplyResult {
        let timestamp = nowMS ?? now()
        let eventID = "delivery-selection:\(submission.nonce)"
        let snapshot = try await scan(botID: submission.botID)
        if let corrupt = snapshot.malformed.first(where: { $0.rowID == submission.rowID }) {
            throw BotDeliverySelectionFailure.corruptRecord(corrupt.reason)
        }
        let events = try await allEvents()
        if let existing = events.first(where: { $0.eventId == eventID }) {
            guard let latest = snapshot.drafts.first(where: {
                $0.draft.rowID == submission.rowID
            }) else { return .stale("unknown_row") }
            guard case .object(let data) = existing.data,
                  let existingDraft = BotDeliverySelectionDraft.parse(
                    botID: latest.draft.botID, sessionID: latest.draft.sessionID,
                    approvalID: latest.draft.approvalID, data: data,
                    requestSeq: existing.commitSeq ?? 0) else {
                return .stale("duplicate_unreadable")
            }
            if existingDraft.revision == latest.draft.revision,
               existingDraft.digest == latest.draft.digest {
                return .duplicate(eventID: eventID, draft: latest.draft)
            }
            return .stale("superseded")
        }

        guard let loaded = snapshot.drafts.first(where: {
            $0.draft.rowID == submission.rowID
        }) else {
            throw BotDeliverySelectionFailure.unknownRow
        }
        var draft = loaded.draft
        guard draft.draftID == submission.draftID else {
            throw BotDeliverySelectionFailure.staleDraft
        }
        guard draft.revision == submission.expectedRevision else {
            throw BotDeliverySelectionFailure.staleRevision
        }
        if draft.status != "pending" {
            throw BotDeliverySelectionFailure.alreadyDecided
        }
        if let expiresAt = draft.expiresAtMS, expiresAt > 0, timestamp >= expiresAt {
            throw BotDeliverySelectionFailure.approvalExpired
        }
        if let bridge {
            let pending = await bridge.pendingDigest(draft.approvalID)
            guard let pending else { throw BotDeliverySelectionFailure.approvalNotPending }
            guard Self.digestKey(pending) == Self.digestKey(draft.digest) else {
                throw BotDeliverySelectionFailure.digestMismatch
            }
        }

        let requested = submission.selectedResourceIDs
        guard Set(requested).count == requested.count else {
            throw BotDeliverySelectionFailure.invalidSelection
        }
        var revalidated: [BotDeliverySelectionResource] = []
        let selected = Set(requested)
        for var resource in draft.resources {
            let state = await recheck(resource.source.ref, botID: draft.botID)
            resource.state = state.state
            resource.stateReason = state.note
            if let version = state.currentVersion, state.state == .current {
                resource.source.sourceVersion = version
            }
            resource.selected = selected.contains(resource.id)
            revalidated.append(resource)
        }
        for id in selected {
            guard let resource = revalidated.first(where: { $0.id == id }) else {
                throw BotDeliverySelectionFailure.unknownResource(id)
            }
            guard resource.isSelectable else {
                throw BotDeliverySelectionFailure.resourceUnavailable(id)
            }
        }
        guard Set(draft.selectedIDs) != selected else {
            return .stale("selection_unchanged")
        }

        // The actor is re-entrant across the awaits above. Re-read the durable
        // revision before mutating; two submissions with different nonces and
        // the same expectedRevision must not both append.
        let latestScan = try await scan(botID: submission.botID)
        guard let latest = latestScan.drafts.first(where: {
            $0.draft.rowID == submission.rowID
        }), latest.draft.revision == draft.revision else {
            if let duplicate = try await duplicateIfCommitted(
                eventID: eventID, botID: submission.botID,
                rowID: submission.rowID) {
                return duplicate
            }
            return .stale("concurrent_selection")
        }
        if let corrupt = latestScan.malformed.first(where: { $0.rowID == submission.rowID }) {
            throw BotDeliverySelectionFailure.corruptRecord(corrupt.reason)
        }

        let revision = draft.revision + 1
        let digest = BotDeliverySelectionDigest.approvalDigest(
            draftID: draft.draftID, revision: revision,
            selectedResourceIDs: Array(selected), parameters: draft.parameters)
        draft.revision = revision
        draft.status = "pending"
        draft.resources = revalidated
        draft.digest = digest
        draft.requestedAtMS = timestamp

        // Compare-and-swap the live coordinator. A second concurrent submit
        // sees the first digest and fails instead of overwriting it.
        if let bridge {
            let rebound = await bridge.rebindDigest(
                draft.approvalID, latest.draft.digest, digest, draft.deliveryJSON)
            guard rebound else {
                if let duplicate = try await duplicateIfCommitted(
                    eventID: eventID, botID: submission.botID,
                    rowID: submission.rowID) {
                    return duplicate
                }
                return .stale("concurrent_selection")
            }
        }
        var data = loaded.event.data.objectValue ?? [:]
        data["delivery"] = draft.deliveryJSON
        data["digest"] = .string(digest)
        data["status"] = .string("pending")
        data["requestedAt"] = .number(Double(timestamp))
        data["deliverySelection"] = .bool(true)
        data["deliverySelectionNonce"] = .string(submission.nonce)
        data["deliverySelectionPreviousDigest"] = .string(latest.draft.digest)
        let event = BotEvent(
            type: "approval.requested", eventId: eventID, time: timestamp,
            origin: .local(source: "card-bridge"), traceId: eventID,
            principal: loaded.event.principal,
            causationId: loaded.event.eventId, correlationId: submission.nonce,
            data: .object(data))
        let seq: Int
        do {
            seq = try await eventLog.append(event)
        } catch {
            if let bridge {
                _ = await bridge.rebindDigest(
                    draft.approvalID, digest, latest.draft.digest,
                    latest.draft.deliveryJSON)
            }
            // A concurrent identical nonce may have won the append; report it
            // as a duplicate rather than a storage failure.
            let after = try await allEvents()
            if let existing = after.first(where: { $0.eventId == eventID }),
               case .object(let existingData) = existing.data {
                let current = try await scan(botID: submission.botID).drafts.first {
                    $0.draft.rowID == submission.rowID
                }
                if let current,
                   let existingDraft = BotDeliverySelectionDraft.parse(
                    botID: current.draft.botID, sessionID: current.draft.sessionID,
                    approvalID: current.draft.approvalID, data: existingData,
                    requestSeq: existing.commitSeq ?? 0),
                   existingDraft.revision == current.draft.revision,
                   existingDraft.digest == current.draft.digest {
                    return .duplicate(eventID: eventID, draft: current.draft)
                }
                return .stale("concurrent_selection")
            }
            throw BotDeliverySelectionFailure.storage(String(describing: error))
        }
        draft.requestSeq = seq
        return .accepted(eventID: eventID, draft: draft)
    }

    /// A concurrent call with the same nonce may have won the append after
    /// this call lost the CAS. If the committed event is exactly the current
    /// durable revision, the idempotent answer is duplicate, not stale.
    private func duplicateIfCommitted(eventID: String, botID: String,
                                      rowID: String) async throws
        -> BotDeliverySelectionApplyResult? {
        let events = try await allEvents()
        guard let existing = events.first(where: { $0.eventId == eventID }),
              case .object(let data) = existing.data,
              let current = try await scan(botID: botID).drafts.first(where: {
                  $0.draft.rowID == rowID
              }),
              let existingDraft = BotDeliverySelectionDraft.parse(
                botID: current.draft.botID, sessionID: current.draft.sessionID,
                approvalID: current.draft.approvalID, data: data,
                requestSeq: existing.commitSeq ?? 0),
              existingDraft.revision == current.draft.revision,
              existingDraft.digest == current.draft.digest else { return nil }
        return .duplicate(eventID: eventID, draft: current.draft)
    }

    // MARK: - Execution-point confirmation

    /// Recheck the approved draft immediately before a delivery tool runs.
    /// `ok(nil)` means no delivery draft applies to this call.
    public func confirm(name: String, arguments: BotJSONValue, botID: String,
                        sessionID: String, turnID: String? = nil,
                        goalDigest: String? = nil,
                        nowMS: Int64? = nil) async throws -> BotDeliveryConfirmation {
        let timestamp = nowMS ?? now()
        let snapshot = try await scan(botID: botID)
        let sessionDrafts = snapshot.drafts.filter { $0.draft.sessionID == sessionID }
        if snapshot.malformed.contains(where: { $0.sessionID == sessionID }) {
            return .rejected(code: "delivery_selection_corrupt",
                             message: "这条交付的选择记录损坏，无法核对，动作没有执行。")
        }
        let applicable = sessionDrafts.filter {
            $0.draft.binding?.matches(turnID: turnID, goalDigest: goalDigest) ?? true
        }

        let rawPath = arguments["path"]?.stringValue
        if name == "show_attachment" || name == "show_document" {
            if let rawPath, !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard let path = BotDeliverySelectionPath.canonical(rawPath) else {
                    if !sessionDrafts.isEmpty {
                        return .rejected(
                            code: "delivery_path_unverifiable",
                            message: "这个附件路径无法按工作区规则核对，动作没有执行。")
                    }
                    return .ok(nil)
                }
                let owned = sessionDrafts.filter { loaded in
                    loaded.draft.resources.contains { $0.workspacePath == path }
                }
                let matching = applicable.filter { loaded in
                    loaded.draft.resources.contains { $0.workspacePath == path }
                }
                if matching.isEmpty {
                    if !owned.isEmpty {
                        // The file belongs to an earlier turn's or another
                        // target's draft. It is not a new artifact; require a
                        // fresh confirmation rather than treat it as unowned.
                        return .rejected(
                            code: "delivery_selection_stale",
                            message: "这项资料属于另一次交付选择，需要重新确认后才能发出。")
                    }
                    // A genuinely new file the model created itself is not
                    // owned by the old suggestion list.
                    return .ok(nil)
                }
                let approved = matching.filter { $0.draft.status == "allowed" }
                if approved.count > 1 {
                    return .rejected(
                        code: "delivery_selection_ambiguous",
                        message: "同一份资料对应多个待确认的交付，无法确定该用哪一个。")
                }
                let chosen = approved.first ?? matching.max {
                    $0.draft.requestSeq < $1.draft.requestSeq
                }
                guard let chosen else { return .ok(nil) }
                return try await confirmResource(
                    draft: chosen.draft, path: path, turnID: turnID,
                    goalDigest: goalDigest, nowMS: timestamp)
            }
            // Inline document content has no path to compare with a selected
            // resource; it is not an attachment and is not gated by the
            // attachment selection.
            return .ok(nil)
        }
        // Text has no resource set. Do not let an old attachment selection
        // gate an unrelated text delivery.
        if name == "SendToUser" { return .ok(nil) }
        return .ok(nil)
    }

    private func confirmResource(draft: BotDeliverySelectionDraft, path: String,
                                 turnID: String?, goalDigest: String?,
                                 nowMS: Int64) async throws -> BotDeliveryConfirmation {
        guard draft.status == "allowed" else {
            return .rejected(code: "delivery_selection_not_approved",
                             message: "这份交付还没有得到确认，不能直接发出。")
        }
        if let expiresAt = draft.expiresAtMS, expiresAt > 0, nowMS >= expiresAt {
            return .rejected(code: "approval_expired",
                             message: "这次审批已经过期，需要重新确认后再发。")
        }
        guard let resource = draft.resources.first(where: {
            $0.workspacePath == path
        }) else {
            return .ok(draft)
        }
        guard resource.selected else {
            return .rejected(code: "delivery_resource_not_selected",
                             message: "这项资料没有出现在用户确认的选择里，没有发出。")
        }
        let expected = BotDeliverySelectionDigest.approvalDigest(
            draftID: draft.draftID, revision: draft.revision,
            selectedResourceIDs: draft.selectedIDs, parameters: draft.parameters)
        guard expected == draft.digest else {
            return .rejected(code: "digest_mismatch",
                             message: "交付绑定已经变化，需要重新确认。")
        }
        let state = await recheck(resource.source.ref, botID: draft.botID)
        guard state.matchesSelectedVersion else {
            return .rejected(code: Self.recheckCode(state.state),
                             message: Self.recheckMessage(resource: resource, state: state))
        }
        // Another submit may have moved the durable revision while the source
        // provider was pending. Confirm the exact revision we validated is
        // still the latest and still approved; do not return `ok` for a draft
        // that was replaced after the check started.
        guard try await unchanged(draft: draft, turnID: turnID,
                                  goalDigest: goalDigest) else {
            return .rejected(code: "delivery_selection_changed",
                             message: "交付选择在核对期间发生了变化，需要重新确认。")
        }
        return .ok(draft)
    }

    /// True when `draft` is still the latest request for its approval id, is
    /// still approved, and still binds the current turn/goal.
    private func unchanged(draft: BotDeliverySelectionDraft, turnID: String?,
                           goalDigest: String?) async throws -> Bool {
        let snapshot = try await scan(botID: draft.botID)
        if snapshot.malformed.contains(where: {
            $0.sessionID == draft.sessionID && $0.approvalID == draft.approvalID
        }) { return false }
        guard let latest = snapshot.drafts.first(where: {
            $0.draft.approvalID == draft.approvalID
        }) else { return false }
        return latest.draft.requestSeq == draft.requestSeq
            && latest.draft.revision == draft.revision
            && latest.draft.status == "allowed"
            && latest.draft.digest == draft.digest
            && (latest.draft.binding?.matches(turnID: turnID, goalDigest: goalDigest) ?? true)
    }

    /// What the model receives after the user allows the approval: the selected
    /// resources with the host paths it must name in the delivery call. Only an
    /// approved revision is exposed.
    public func approvedSelectionJSON(approvalID: String, botID: String) async throws
        -> BotJSONValue? {
        guard let draft = try await draft(approvalID: approvalID, botID: botID),
              draft.status == "allowed" else { return nil }
        return .object([
            "draft_id": .string(draft.draftID),
            "revision": .number(Double(draft.revision)),
            "digest": .string(draft.digest),
            "selected": .array(draft.selectedResources.map {
                $0.json(includePath: true)
            }),
        ])
    }

    // MARK: - Loading

    private func loadedDrafts(botID: String) async throws -> [LoadedDraft] {
        try await scan(botID: botID).drafts
    }

    private func scan(botID: String) async throws
        -> (drafts: [LoadedDraft], malformed: [MalformedDelivery]) {
        let events = try await allEvents()
        var latest: [String: LoadedDraft] = [:]
        var malformed: [MalformedDelivery] = []
        for event in events {
            guard event.principal.botId == botID,
                  let data = event.data.objectValue,
                  let approvalID = data["approvalID"]?.stringValue,
                  !approvalID.isEmpty else { continue }
            let claimsDelivery = data["delivery"] != nil
                || data["deliverySelection"]?.boolValue == true
            switch event.type {
            case "approval.requested":
                guard claimsDelivery else { continue }
                let sessionID = event.principal.sessionId ?? ""
                let rowID = data["id"]?.stringValue ?? "e-\(botID)-approval-\(approvalID)"
                guard var draft = BotDeliverySelectionDraft.parse(
                    botID: botID, sessionID: sessionID, approvalID: approvalID,
                    data: data, requestSeq: event.commitSeq ?? 0) else {
                    malformed.append(MalformedDelivery(
                        botID: botID, sessionID: sessionID, rowID: rowID,
                        approvalID: approvalID, reason: "delivery_header_unreadable"))
                    continue
                }
                if let existing = latest[approvalID],
                   existing.draft.revision > draft.revision {
                    draft = existing.draft
                }
                latest[approvalID] = LoadedDraft(draft: draft, event: event)
            case "approval.decided":
                guard var loaded = latest[approvalID],
                      (event.commitSeq ?? 0) > loaded.draft.requestSeq else { continue }
                let status = Self.decisionStatus(data)
                loaded.draft.status = status
                if status == "allowed" { loaded.draft.approvedAtMS = event.time }
                latest[approvalID] = loaded
            default:
                continue
            }
        }
        return (latest.values.sorted { $0.draft.requestSeq > $1.draft.requestSeq },
                malformed)
    }

    private func allEvents() async throws -> [BotEvent] {
        var result: [BotEvent] = []
        var cursor = 0
        while true {
            let page = try await eventLog.events(after: cursor, limit: 500)
            result.append(contentsOf: page)
            guard page.count == 500, let last = page.last?.commitSeq else { break }
            cursor = last
        }
        return result
    }

    private func recheck(_ ref: String, botID: String) async -> BotDeliveryWorkspaceState {
        guard let workspaceState else { return .unknown("没有可用的来源核对器") }
        return await workspaceState(ref, botID)
    }

    // MARK: - Pure helpers

    static func digestKey(_ value: String) -> String {
        var key = value.lowercased()
        if key.hasPrefix("sha256:") { key.removeFirst("sha256:".count) }
        return key
    }

    static func decisionStatus(_ data: [String: BotJSONValue]) -> String {
        if let status = data["status"]?.stringValue {
            switch status {
            case "allowed", "denied", "expired", "cancelled": return status
            default: break
            }
        }
        switch data["decision"]?.stringValue {
        case "deny": return "denied"
        case "allowOnce", "always", "allowed": return "allowed"
        default: return "denied"
        }
    }

    static func recheckCode(_ state: BotProvenanceStatus) -> String {
        switch state {
        case .current: return "delivery_source_current"
        case .changed: return "delivery_source_changed"
        case .unavailable: return "delivery_source_unavailable"
        case .revoked: return "delivery_source_revoked"
        case .erased: return "delivery_source_erased"
        case .unknown: return "delivery_source_unknown"
        }
    }

    static func recheckMessage(resource: BotDeliverySelectionResource,
                               state: BotDeliveryWorkspaceState) -> String {
        switch state.state {
        case .changed:
            return "「\(resource.name)」在确认后出现了更新版本，这次没有发出；请重新确认。"
        case .unavailable:
            return "「\(resource.name)」现在读不到，这次没有发出。"
        case .revoked:
            return "「\(resource.name)」的访问授权已被撤回，这次没有发出。"
        case .erased:
            return "「\(resource.name)」的原始记录已被抹除，这次没有发出。"
        case .unknown:
            return "「\(resource.name)」的当前状态无法核对，这次没有发出。"
        case .current:
            return "「\(resource.name)」当前可读。"
        }
    }

    static func selectionReason(_ reason: BotDecisionSelectionReason) -> String {
        switch reason {
        case .match: return "和当前任务匹配"
        case .recipient: return "和接收方相关"
        case .goal: return "和当前目标相关"
        case .recency: return "最近更新的资料"
        }
    }

    static func parameters(action: String, detail: String) -> [BotDeliverySelectionParameter] {
        var result: [BotDeliverySelectionParameter] = []
        let trimmedAction = action.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedAction.isEmpty {
            result.append(BotDeliverySelectionParameter(
                label: "动作", value: String(trimmedAction.prefix(200))))
        }
        if !trimmedDetail.isEmpty, trimmedDetail != trimmedAction, result.count < 8 {
            result.append(BotDeliverySelectionParameter(
                label: "说明", value: String(trimmedDetail.prefix(200))))
        }
        return result
    }

    static func draftID(approvalID: String) -> String {
        let digest = SHA256.hash(data: Data(approvalID.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return "draft-" + digest.prefix(24)
    }

    static func selectedVersion(ref: String, observedAtMS: Int64)
        -> BotProvenanceSourceVersion? {
        guard let digest = WorkspaceDecisionContextService.workspaceDigest(fromRef: ref) else {
            return nil
        }
        return .known(
            basis: .contentSHA256, value: digest,
            observedAtMS: observedAtMS > 0 ? observedAtMS : nil,
            basisRef: nil, subject: .fileBytes)
    }

    static func versionLabel(_ timestamp: Int64) -> String? {
        guard timestamp > 0 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date(timeIntervalSince1970: Double(timestamp) / 1_000))
    }

    static func effectJSON(_ effect: BotToolEffect) -> BotJSONValue {
        .object([
            "tool": .string(effect.tool),
            "operation": .string(effect.operation),
            "resource": .string(effect.resource),
            "target": .string(effect.target),
            "mutability": .string(effect.mutability.rawValue),
            "policy": .string(effect.policy.rawValue),
            "label": .string(effect.label),
            "detail": .string(effect.detail),
            "ui": .bool(effect.ui),
            "known": .bool(effect.known),
            "isMcp": .bool(effect.isMcp),
            "execution": effect.execution.map(BotJSONValue.string) ?? .null,
        ])
    }
}
