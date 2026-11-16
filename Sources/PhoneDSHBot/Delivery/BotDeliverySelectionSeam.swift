// SPDX-License-Identifier: MIT

// G-2 delivery selection, host side.
//
// The approval row is the durable draft. Its `delivery` block is projected by
// the existing `approval.requested` row projector (no second store, no second
// row type). This file owns the seam types the MCP runtime and the App adapter
// share; `BotDeliverySelectionHost` owns the state machine.

import CryptoKit
import Foundation

// MARK: - Frozen digest

/// G-2 §2.2: `sha256(canonical JSON of [draft_id, revision,
/// sorted(selected_resource_ids), parameters sorted by label])`, `sha256:`
/// prefixed. One implementation; the App's view-side resolver must produce the
/// same golden vector (asserted by both suites).
public enum BotDeliverySelectionDigest {
    public static func approvalDigest(
        draftID: String,
        revision: Int,
        selectedResourceIDs: [String],
        parameters: [BotDeliverySelectionParameter]
    ) -> String {
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

// MARK: - Workspace source state

/// Current state of one workspace-ref source at recheck time. The production
/// resolver re-reads the file and compares the content digest embedded in the
/// `workspace:` ref; it never guesses.
public struct BotDeliveryWorkspaceState: Sendable, Equatable {
    public var state: BotProvenanceStatus
    /// The content version the resolver saw just now.
    public var currentVersion: BotProvenanceSourceVersion?
    /// Human reason shown next to a non-current resource.
    public var note: String?

    public init(state: BotProvenanceStatus,
                currentVersion: BotProvenanceSourceVersion? = nil,
                note: String? = nil) {
        self.state = state
        self.currentVersion = currentVersion
        self.note = note
    }

    public static let current = BotDeliveryWorkspaceState(state: .current)
    public static func changed(_ current: BotProvenanceSourceVersion?,
                               note: String = "来源出现了更新版本") -> Self {
        Self(state: .changed, currentVersion: current, note: note)
    }
    public static func unavailable(_ note: String = "来源当前不可读") -> Self {
        Self(state: .unavailable, note: note)
    }
    public static func revoked(_ note: String = "来源授权已撤回") -> Self {
        Self(state: .revoked, note: note)
    }
    public static func erased(_ note: String = "原始记录已被抹除") -> Self {
        Self(state: .erased, note: note)
    }
    public static func unknown(_ note: String = "来源时效未知") -> Self {
        Self(state: .unknown, note: note)
    }

    public var isSelectable: Bool {
        switch state {
        case .current, .changed, .unknown: return true
        case .unavailable, .revoked, .erased: return false
        }
    }

    /// The bytes the user selected are still the bytes on disk. `changed` and
    /// `unknown` are reviewable candidates, but they cannot be delivered as if
    /// they were the selected version.
    public var matchesSelectedVersion: Bool { state == .current }
}

// MARK: - Row projection values

public struct BotDeliverySelectionSource: Sendable, Equatable {
    public var ref: String
    public var label: String
    public var kind: String
    public var trust: String
    public var state: BotProvenanceStatus
    public var reason: String?
    public var stateDetail: String?
    public var observedAtMS: Int64?
    public var versionLabel: String?
    public var latestRef: String?
    public var sourceVersion: BotProvenanceSourceVersion?

    public init(ref: String, label: String, kind: String = "file",
                trust: String = "observation", state: BotProvenanceStatus = .current,
                reason: String? = nil, stateDetail: String? = nil,
                observedAtMS: Int64? = nil, versionLabel: String? = nil,
                latestRef: String? = nil,
                sourceVersion: BotProvenanceSourceVersion? = nil) {
        self.ref = ref
        self.label = label
        self.kind = kind
        self.trust = trust
        self.state = state
        self.reason = reason
        self.stateDetail = stateDetail
        self.observedAtMS = observedAtMS
        self.versionLabel = versionLabel
        self.latestRef = latestRef
        self.sourceVersion = sourceVersion
    }

    public var json: BotJSONValue {
        var object: [String: BotJSONValue] = [
            "ref": .string(ref),
            "label": .string(label),
            "kind": .string(kind),
            "trust": .string(trust),
            "verification": .string("unknown"),
            "state": .string(state.rawValue),
        ]
        if let reason { object["reason"] = .string(reason) }
        if let stateDetail { object["state_detail"] = .string(stateDetail) }
        if let observedAtMS { object["observed_at_ms"] = .number(Double(observedAtMS)) }
        if let versionLabel { object["version_label"] = .string(versionLabel) }
        if let latestRef { object["latest_ref"] = .string(latestRef) }
        if let sourceVersion {
            let encoded = try? JSONEncoder().encode(sourceVersion)
            if let encoded, let value = try? BotJSONValue.parse(encoded) {
                object["source_version"] = value
            }
        }
        return .object(object)
    }

    /// The shared `JSONValue.intValue` never traps, but it rounds a fractional
    /// double (`1.5` -> `2`). A revision/timestamp is an integer domain, so D
    /// requires an exact integral double and an exact Int64 range check here.
    static func int64(_ value: BotJSONValue?) -> Int64? {
        guard let value, case .number(let number) = value,
              number.isFinite, number.rounded() == number else { return nil }
        return Int64(exactly: number)
    }

    public static func parse(_ value: BotJSONValue?) -> BotDeliverySelectionSource? {
        guard case .object(let object)? = value,
              let ref = object["ref"]?.stringValue, !ref.isEmpty else { return nil }
        let label = object["label"]?.stringValue ?? "工作区文件"
        let version = object["source_version"].flatMap {
            try? JSONDecoder().decode(BotProvenanceSourceVersion.self, from: $0.encoded())
        }
        let observedAtMS: Int64?
        if let rawObserved = object["observed_at_ms"] ?? object["observed_at"] {
            if case .null = rawObserved {
                observedAtMS = nil
            } else {
                guard let value = Self.int64(rawObserved) else { return nil }
                observedAtMS = value
            }
        } else {
            observedAtMS = nil
        }
        return BotDeliverySelectionSource(
            ref: ref,
            label: label,
            kind: object["kind"]?.stringValue ?? "file",
            trust: object["trust"]?.stringValue ?? "observation",
            state: BotProvenanceStatus(rawValue: object["state"]?.stringValue ?? "") ?? .unknown,
            reason: object["reason"]?.stringValue,
            stateDetail: object["state_detail"]?.stringValue
                ?? object["state_reason"]?.stringValue,
            observedAtMS: observedAtMS,
            versionLabel: object["version_label"]?.stringValue,
            latestRef: object["latest_ref"]?.stringValue,
            sourceVersion: version)
    }
}

public struct BotDeliverySelectionResource: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var detail: String?
    public var reason: String?
    public var selected: Bool
    public var state: BotProvenanceStatus
    public var stateReason: String?
    public var source: BotDeliverySelectionSource

    public init(id: String, name: String, detail: String? = nil, reason: String? = nil,
                selected: Bool = false, state: BotProvenanceStatus = .current,
                stateReason: String? = nil, source: BotDeliverySelectionSource) {
        self.id = id
        self.name = name
        self.detail = detail
        self.reason = reason
        self.selected = selected
        self.state = state
        self.stateReason = stateReason
        self.source = source
    }

    public var isSelectable: Bool {
        switch state {
        case .current, .changed, .unknown: return true
        case .unavailable, .revoked, .erased: return false
        }
    }

    /// Workspace-relative path encoded in the ref. This is the path the final
    /// `show_attachment`/`show_document` call must name; the raw ref is never
    /// shown in the user UI.
    public var workspacePath: String? {
        WorkspaceDecisionContextService.workspacePath(fromRef: source.ref)
    }

    public func json(includePath: Bool = false) -> BotJSONValue {
        var object: [String: BotJSONValue] = [
            "id": .string(id),
            "name": .string(name),
            "selected": .bool(selected),
            "state": .string(state.rawValue),
            "source": source.json,
        ]
        if let detail { object["detail"] = .string(detail) }
        if let reason { object["reason"] = .string(reason) }
        if let stateReason { object["state_reason"] = .string(stateReason) }
        if includePath, let path = workspacePath {
            object["path"] = .string(path)
        }
        return .object(object)
    }

    public static func parse(_ value: BotJSONValue) -> BotDeliverySelectionResource? {
        guard case .object(let object) = value,
              let id = object["id"]?.stringValue, !id.isEmpty,
              let name = object["name"]?.stringValue, !name.isEmpty,
              let source = BotDeliverySelectionSource.parse(object["source"]) else { return nil }
        return BotDeliverySelectionResource(
            id: id, name: name,
            detail: object["detail"]?.stringValue,
            reason: object["reason"]?.stringValue,
            selected: object["selected"]?.boolValue == true,
            state: BotProvenanceStatus(rawValue: object["state"]?.stringValue ?? "") ?? .unknown,
            stateReason: object["state_reason"]?.stringValue,
            source: source)
    }
}

public struct BotDeliverySelectionParameter: Sendable, Equatable, Identifiable {
    public var label: String
    public var value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }

    public var id: String { "\(label)=\(value)" }

    public var json: BotJSONValue {
        .object(["label": .string(label), "value": .string(value)])
    }

    public static func parseList(_ value: BotJSONValue?) -> [BotDeliverySelectionParameter] {
        guard case .array(let values)? = value else { return [] }
        return values.prefix(8).compactMap { value in
            guard case .object(let object) = value,
                  let label = object["label"]?.stringValue, !label.isEmpty,
                  let value = object["value"]?.stringValue else { return nil }
            return BotDeliverySelectionParameter(label: label, value: value)
        }
    }
}

// MARK: - Durable draft

/// Metadata that binds one delivery draft to the turn and goal it was offered
/// for. It is not part of the approval digest; the digest stays exactly the
/// frozen G-2 formula. Extra metadata is needed so an old turn's approved
/// selection cannot gate a later, unrelated delivery.
public struct BotDeliverySelectionBinding: Sendable, Equatable {
    public var approvalID: String
    public var turnID: String
    public var goalDigest: String?

    public init(approvalID: String, turnID: String, goalDigest: String? = nil) {
        self.approvalID = approvalID
        self.turnID = turnID
        self.goalDigest = goalDigest
    }

    public var json: BotJSONValue {
        var object: [String: BotJSONValue] = [
            "approval_id": .string(approvalID),
            "turn_id": .string(turnID),
        ]
        if let goalDigest, !goalDigest.isEmpty {
            object["goal_digest"] = .string(goalDigest)
        }
        return .object(object)
    }

    /// G-2 §66: when the block is present, `approval_id` and `turn_id` are
    /// required and no other member is allowed. A malformed block returns nil;
    /// the draft parser then treats the durable record as corrupt and fails
    /// closed. An absent block is the documented legacy "no constraint" case.
    public static func parse(_ value: BotJSONValue?) -> BotDeliverySelectionBinding? {
        guard case .object(let object)? = value else { return nil }
        let allowed: Set<String> = ["approval_id", "turn_id", "goal_digest"]
        guard object.keys.allSatisfy({ allowed.contains($0) }),
              let approvalID = object["approval_id"]?.stringValue,
              !approvalID.isEmpty,
              let turnID = object["turn_id"]?.stringValue,
              Self.validTurnID(turnID) else { return nil }
        var goal: String?
        if let raw = object["goal_digest"] {
            guard case .string(let value) = raw, !value.isEmpty else { return nil }
            goal = value
        }
        return BotDeliverySelectionBinding(
            approvalID: approvalID, turnID: turnID, goalDigest: goal)
    }

    /// `<session>#<turn>`: a non-empty session and a non-negative integer turn.
    public static func validTurnID(_ value: String) -> Bool {
        guard let hash = value.lastIndex(of: "#") else { return false }
        let session = value[..<hash]
        let turn = value[value.index(after: hash)...]
        return !session.isEmpty && !turn.isEmpty
            && turn.allSatisfy({ $0.isNumber })
    }

    public func matches(turnID: String?, goalDigest: String?) -> Bool {
        guard let turnID, !turnID.isEmpty, turnID == self.turnID else { return false }
        if let goalDigest, !goalDigest.isEmpty, let bound = self.goalDigest {
            guard goalDigest == bound else { return false }
        }
        return true
    }
}

public struct BotDeliverySelectionDraft: Sendable, Equatable {
    public var botID: String
    public var sessionID: String
    public var approvalID: String
    public var rowID: String
    public var draftID: String
    public var revision: Int
    public var status: String
    public var parameters: [BotDeliverySelectionParameter]
    public var resources: [BotDeliverySelectionResource]
    public var binding: BotDeliverySelectionBinding?
    public var digest: String
    public var requestedAtMS: Int64
    public var expiresAtMS: Int64?
    public var persistent: Bool
    /// Commit sequence of the event that produced this revision.
    public var requestSeq: Int
    public var approvedAtMS: Int64?

    public init(botID: String, sessionID: String, approvalID: String, rowID: String,
                draftID: String, revision: Int, status: String,
                parameters: [BotDeliverySelectionParameter],
                resources: [BotDeliverySelectionResource],
                binding: BotDeliverySelectionBinding?, digest: String,
                requestedAtMS: Int64, expiresAtMS: Int64?, persistent: Bool,
                requestSeq: Int, approvedAtMS: Int64? = nil) {
        self.botID = botID
        self.sessionID = sessionID
        self.approvalID = approvalID
        self.rowID = rowID
        self.draftID = draftID
        self.revision = revision
        self.status = status
        self.parameters = parameters
        self.resources = resources
        self.binding = binding
        self.digest = digest
        self.requestedAtMS = requestedAtMS
        self.expiresAtMS = expiresAtMS
        self.persistent = persistent
        self.requestSeq = requestSeq
        self.approvedAtMS = approvedAtMS
    }

    public var selectedIDs: [String] {
        resources.filter(\.selected).map(\.id).sorted()
    }

    public var selectedResources: [BotDeliverySelectionResource] {
        resources.filter(\.selected)
    }

    public var isPending: Bool { status == "pending" }
    public var isApproved: Bool { status == "allowed" }

    public var deliveryJSON: BotJSONValue {
        var object: [String: BotJSONValue] = [
            "draft_id": .string(draftID),
            "revision": .number(Double(revision)),
            "parameters": .array(parameters.map(\.json)),
            "resources": .array(resources.map { $0.json() }),
        ]
        if let binding { object["binding"] = binding.json }
        return .object(object)
    }

    public static func parse(botID: String, sessionID: String, approvalID: String,
                             data: [String: BotJSONValue],
                             requestSeq: Int) -> BotDeliverySelectionDraft? {
        guard case .object(let delivery)? = data["delivery"],
              let draftID = delivery["draft_id"]?.stringValue, !draftID.isEmpty,
              let revision64 = BotDeliverySelectionSource.int64(delivery["revision"]),
              let revision = Int(exactly: revision64), revision >= 1 else { return nil }
        var resources: [BotDeliverySelectionResource] = []
        if let rawResources = delivery["resources"] {
            guard case .array(let values) = rawResources, values.count <= 10 else {
                return nil
            }
            for value in values {
                guard let resource = BotDeliverySelectionResource.parse(value) else {
                    return nil
                }
                resources.append(resource)
            }
        }
        var parameters: [BotDeliverySelectionParameter] = []
        if let rawParameters = delivery["parameters"] {
            guard case .array(let values) = rawParameters, values.count <= 8 else {
                return nil
            }
            for value in values {
                guard case .object(let object) = value,
                      let label = object["label"]?.stringValue, !label.isEmpty,
                      label.unicodeScalars.count <= 60,
                      let parameterValue = object["value"]?.stringValue,
                      parameterValue.unicodeScalars.count <= 200 else { return nil }
                parameters.append(BotDeliverySelectionParameter(
                    label: label, value: parameterValue))
            }
        }
        var binding: BotDeliverySelectionBinding?
        if delivery["binding"] != nil {
            guard let parsed = BotDeliverySelectionBinding.parse(
                delivery["binding"]),
                  parsed.approvalID == approvalID,
                  parsed.turnID.hasPrefix(sessionID + "#") else { return nil }
            binding = parsed
        }
        let requestedAtMS: Int64
        if let raw = data["requestedAt"] {
            guard let value = BotDeliverySelectionSource.int64(raw) else { return nil }
            requestedAtMS = value
        } else {
            requestedAtMS = 0
        }
        var expiresAtMS: Int64?
        if let raw = data["expiresAt"] {
            guard let value = BotDeliverySelectionSource.int64(raw) else { return nil }
            expiresAtMS = value
        }
        let rowID = data["id"]?.stringValue ?? "e-\(botID)-approval-\(approvalID)"
        return BotDeliverySelectionDraft(
            botID: botID,
            sessionID: sessionID,
            approvalID: approvalID,
            rowID: rowID,
            draftID: draftID,
            revision: revision,
            status: data["status"]?.stringValue ?? "pending",
            parameters: parameters,
            resources: resources,
            binding: binding,
            digest: data["digest"]?.stringValue ?? "",
            requestedAtMS: requestedAtMS,
            expiresAtMS: expiresAtMS,
            persistent: data["persistent"]?.boolValue == true,
            requestSeq: requestSeq)
    }
}

// MARK: - Producer / consumer values

public struct BotDeliverySelectionOffer: Sendable, Equatable {
    public var draft: BotDeliverySelectionDraft
    public var deliveryJSON: BotJSONValue

    public init(draft: BotDeliverySelectionDraft) {
        self.draft = draft
        deliveryJSON = draft.deliveryJSON
    }
}

public struct BotDeliverySelectionSubmission: Sendable, Equatable {
    public var nonce: String
    public var botID: String
    public var rowID: String
    public var draftID: String
    public var expectedRevision: Int
    public var selectedResourceIDs: [String]

    public init(nonce: String, botID: String, rowID: String, draftID: String,
                expectedRevision: Int, selectedResourceIDs: [String]) {
        self.nonce = nonce
        self.botID = botID
        self.rowID = rowID
        self.draftID = draftID
        self.expectedRevision = expectedRevision
        self.selectedResourceIDs = selectedResourceIDs
    }
}

public enum BotDeliverySelectionApplyResult: Sendable, Equatable {
    case accepted(eventID: String, draft: BotDeliverySelectionDraft)
    case duplicate(eventID: String, draft: BotDeliverySelectionDraft)
    case stale(String)
    case rejected(String)
}

public enum BotDeliverySelectionFailure: Error, Sendable, Equatable {
    case unknownRow
    case staleDraft
    case staleRevision
    case unknownResource(String)
    case resourceUnavailable(String)
    case invalidSelection
    case approvalNotPending
    case approvalExpired
    case alreadyDecided
    case digestMismatch
    case corruptRecord(String)
    case storage(String)

    public var code: String {
        switch self {
        case .unknownRow: return "unknown_row"
        case .staleDraft: return "draft_changed"
        case .staleRevision: return "draft_revision_mismatch"
        case .unknownResource: return "unknown_resource"
        case .resourceUnavailable: return "resource_unavailable"
        case .invalidSelection: return "invalid_selection"
        case .approvalNotPending: return "approval_not_pending"
        case .approvalExpired: return "approval_expired"
        case .alreadyDecided: return "already_decided"
        case .digestMismatch: return "digest_mismatch"
        case .corruptRecord: return "delivery_selection_corrupt"
        case .storage: return "delivery_selection_storage_failed"
        }
    }
}

public enum BotDeliveryConfirmation: Sendable, Equatable {
    case ok(BotDeliverySelectionDraft?)
    /// The resource path was part of a delivery draft but the user did not
    /// select it, or the approval is no longer the one the draft was confirmed
    /// under.
    case rejected(code: String, message: String)

    public var isAllowed: Bool {
        if case .ok = self { return true }
        return false
    }
}

/// Installed by `BotMCPRuntime`. The host only reads the current pending digest
/// and rebinds it to the new revision; the coordinator stays the only owner of
/// the approval's pending state.
public struct BotDeliveryApprovalBridge: Sendable {
    public var pendingDigest: @Sendable (String) async -> String?
    /// Compare-and-swap: only replace the pending digest when it still equals
    /// the draft digest the caller validated. Two concurrent selections can
    /// therefore never both rebind the same approval.
    public var rebindDigest: @Sendable (String, String, String, BotJSONValue?) async -> Bool

    public init(pendingDigest: @escaping @Sendable (String) async -> String?,
                rebindDigest: @escaping @Sendable (String, String, String,
                                                    BotJSONValue?) async -> Bool) {
        self.pendingDigest = pendingDigest
        self.rebindDigest = rebindDigest
    }
}

/// The one canonical path spelling used to compare a selected `workspace:` ref
/// with a `show_attachment`/`show_document` argument. It mirrors the App
/// preview namespace (VFS `/dsh/workspace/...` or a relative path) and reuses
/// the workspace contract's own validity rule; it is not an allow-list of
/// files.
public enum BotDeliverySelectionPath {
    public static func canonical(_ raw: String) -> String? {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["file://", "sandbox:"] where path.hasPrefix(prefix) {
            path = String(path.dropFirst(prefix.count))
        }
        if let decoded = path.removingPercentEncoding { path = decoded }
        if path.hasPrefix("/dsh/workspace/") {
            path = String(path.dropFirst("/dsh/workspace/".count))
        } else if path.hasPrefix("/") {
            // An absolute host path is not the workspace namespace the card
            // resolves; do not guess that it aliases a selected file.
            return nil
        }
        while path.hasPrefix("./") { path = String(path.dropFirst(2)) }
        path = path.precomposedStringWithCanonicalMapping
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard WorkspaceDecisionContextService.validWorkspacePath(path) else { return nil }
        return path
    }
}
